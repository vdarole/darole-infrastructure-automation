# =========================================================
# Script   : update-dns.ps1
# Purpose  : Manage A and PTR records for darole.org
# DNS      : Local Windows DNS Server
# =========================================================

$ErrorActionPreference = "Stop"

$dnsServer = "localhost"
$zoneName  = "darole.org"

$records = @(
    # Container Orchestration
    @{ Name = "dock01";    IP = "172.16.1.214" }
    @{ Name = "kub01";     IP = "172.16.1.230" }
    @{ Name = "kub02";     IP = "172.16.1.231" }
    @{ Name = "kub03";     IP = "172.16.1.232" }

    # Virtual Machines
    @{ Name = "lamp01";    IP = "172.16.1.211" }
    @{ Name = "pup01";     IP = "172.16.1.213" }
    @{ Name = "web01";     IP = "172.16.1.221" }
    @{ Name = "db01";      IP = "172.16.1.222" }
    @{ Name = "gra01";     IP = "172.16.1.241" }
    @{ Name = "zap01";     IP = "172.16.1.242" }
    @{ Name = "tomd01";    IP = "172.16.1.250" }
    @{ Name = "tomp01";    IP = "172.16.1.251" }
    @{ Name = "son01";     IP = "172.16.1.252" }
    @{ Name = "jen01";     IP = "172.16.1.253" }
    @{ Name = "win01";     IP = "172.16.1.200" }
    @{ Name = "ans01";     IP = "172.16.1.223" }
    @{ Name = "jobsearch"; IP = "172.16.1.225" }

    # Website Hosting
    @{ Name = "ninom";            IP = "172.16.1.215" }
    @{ Name = "online-education"; IP = "172.16.1.216" }
    @{ Name = "organic-farm";     IP = "172.16.1.217" }
    @{ Name = "travel";           IP = "172.16.1.218" }
    @{ Name = "jewellery";        IP = "172.16.1.219" }
    @{ Name = "carvilla";         IP = "172.16.1.220" }

    # Database Cluster VIP
    @{ Name = "db";        IP = "172.16.1.226" }

    # VMware Infrastructure
    @{ Name = "esxi01";    IP = "172.16.1.201" }
    @{ Name = "esxi02";    IP = "172.16.1.202" }
    @{ Name = "vcenter01"; IP = "172.16.1.203" }
)

# ---------------------------------------------------------
# Validate forward zone
# ---------------------------------------------------------
try {
    $null = Get-DnsServerZone -ComputerName $dnsServer -Name $zoneName
}
catch {
    Write-Error "DNS zone '$zoneName' not found on '$dnsServer'. $_"
    exit 1
}

# ---------------------------------------------------------
# Ensure reverse zone exists (/24) for every IP in the list
# ---------------------------------------------------------
$networks = $records | ForEach-Object {
    $o = $_.IP.Split(".")
    "$($o[0]).$($o[1]).$($o[2]).0/24"
} | Sort-Object -Unique

foreach ($net in $networks) {
    $o = $net.Split("/")[0].Split(".")
    $revZone = "$($o[2]).$($o[1]).$($o[0]).in-addr.arpa"

    $exists = Get-DnsServerZone -ComputerName $dnsServer -Name $revZone -ErrorAction SilentlyContinue
    if ($exists) {
        Write-Host "[ZONE OK]  $revZone exists" -ForegroundColor Green
        continue
    }

    Write-Host "[ZONE]     Creating reverse zone $revZone" -ForegroundColor Yellow
    try {
        # AD-integrated (server is a domain controller)
        Add-DnsServerPrimaryZone -ComputerName $dnsServer -NetworkId $net -ReplicationScope "Domain"
    }
    catch {
        # Standalone server: file-backed zone
        Add-DnsServerPrimaryZone -ComputerName $dnsServer -NetworkId $net -ZoneFile "$revZone.dns"
    }
    Write-Host "[ZONE ADDED] $revZone" -ForegroundColor Cyan
}

# ---------------------------------------------------------
# Find the reverse zone covering an IP (/24, /16, /8)
# ---------------------------------------------------------
function Get-ReverseZoneInfo {
    param([string]$IP, [string]$Server)

    $o = $IP.Split(".")
    $candidates = @(
        @{ Zone = "$($o[2]).$($o[1]).$($o[0]).in-addr.arpa"; Ptr = $o[3] },
        @{ Zone = "$($o[1]).$($o[0]).in-addr.arpa";          Ptr = "$($o[3]).$($o[2])" },
        @{ Zone = "$($o[0]).in-addr.arpa";                   Ptr = "$($o[3]).$($o[2]).$($o[1])" }
    )

    foreach ($c in $candidates) {
        $z = Get-DnsServerZone -ComputerName $Server -Name $c.Zone -ErrorAction SilentlyContinue
        if ($z) { return $c }
    }
    return $null
}

# ---------------------------------------------------------
# Process records: A first, then PTR, for each host
# ---------------------------------------------------------
foreach ($record in $records) {

    $name = $record.Name
    $ip   = $record.IP
    $fqdn = "$name.$zoneName."

    # ---------------- A record ----------------
    try {
        $parsedIP = $null
        if (-not [System.Net.IPAddress]::TryParse($ip, [ref]$parsedIP) -or
            $parsedIP.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            throw "Invalid IPv4 address: $ip"
        }

        $existingRecords = @(
            Get-DnsServerResourceRecord -ComputerName $dnsServer -ZoneName $zoneName `
                -Name $name -RRType A -ErrorAction SilentlyContinue
        )

        $matchingRecord = $existingRecords | Where-Object {
            $_.RecordData.IPv4Address.IPAddressToString -eq $ip
        }

        if ($matchingRecord) {
            Write-Host "[OK]      $name.$zoneName -> $ip already exists" -ForegroundColor Green
        }
        else {
            foreach ($old in $existingRecords) {
                Write-Host "[REMOVE]  $name.$zoneName -> $($old.RecordData.IPv4Address)" -ForegroundColor Yellow
                Remove-DnsServerResourceRecord -ComputerName $dnsServer -ZoneName $zoneName `
                    -InputObject $old -Force
            }

            Add-DnsServerResourceRecordA -ComputerName $dnsServer -ZoneName $zoneName `
                -Name $name -IPv4Address $ip

            Write-Host "[ADDED]   $name.$zoneName -> $ip" -ForegroundColor Cyan
        }
    }
    catch {
        Write-Host "[ERROR]   $name.$zoneName : $_" -ForegroundColor Red
        continue
    }

    # ---------------- PTR record ----------------
    try {
        $rz = Get-ReverseZoneInfo -IP $ip -Server $dnsServer
        if (-not $rz) {
            Write-Warning "No reverse zone found for $ip. Skipping PTR for $fqdn"
            continue
        }

        $reverseZone = $rz.Zone
        $ptrName     = $rz.Ptr

        $existingPTR = @(
            Get-DnsServerResourceRecord -ComputerName $dnsServer -ZoneName $reverseZone `
                -Name $ptrName -RRType PTR -ErrorAction SilentlyContinue
        )

        $correctPTR = $existingPTR | Where-Object {
            $_.RecordData.PtrDomainName.TrimEnd(".") -ieq $fqdn.TrimEnd(".")
        }

        if ($correctPTR) {
            Write-Host "[PTR OK]    $ip -> $fqdn" -ForegroundColor Green
            continue
        }

        foreach ($ptr in $existingPTR) {
            Remove-DnsServerResourceRecord -ComputerName $dnsServer -ZoneName $reverseZone `
                -InputObject $ptr -Force
        }

        Add-DnsServerResourceRecordPtr -ComputerName $dnsServer -ZoneName $reverseZone `
            -Name $ptrName -PtrDomainName $fqdn

        Write-Host "[PTR ADDED] $ip -> $fqdn" -ForegroundColor Cyan
    }
    catch {
        Write-Warning "PTR update failed for $ip ($fqdn): $_"
    }
}

Write-Host "`nDNS A and PTR record processing completed." -ForegroundColor Green
