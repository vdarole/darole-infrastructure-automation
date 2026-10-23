# =========================================================
# Script   : update-dns.ps1
# Purpose  : Manage A records for darole.org
# DNS      : Local Windows DNS Server
# =========================================================

$ErrorActionPreference = "Stop"

# DNS Server and Zone
$dnsServer = "localhost"
$zoneName  = "darole.org"

# DNS Records - Latest Home Lab Inventory
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
    @{ Name = "ninom";             IP = "172.16.1.215" }
    @{ Name = "online-education";  IP = "172.16.1.216" }
    @{ Name = "organic-farm";      IP = "172.16.1.217" }
    @{ Name = "travel";             IP = "172.16.1.218" }
    @{ Name = "jewellery";          IP = "172.16.1.219" }
    @{ Name = "carvilla";           IP = "172.16.1.220" }

    # Database Cluster Virtual IP
    # db01 = physical/VM address; db = cluster VIP
    @{ Name = "db";       IP = "172.16.1.226" }

    # VMware Infrastructure
    @{ Name = "esxi01";   IP = "172.16.1.201" }
    @{ Name = "esxi02";   IP = "172.16.1.202" }
    @{ Name = "vcenter01"; IP = "172.16.1.203" }
)

# Validate DNS zone
try {
    $null = Get-DnsServerZone `
        -ComputerName $dnsServer `
        -Name $zoneName
}
catch {
    Write-Error "DNS zone '$zoneName' not found on '$dnsServer'. $_"
    exit 1
}

# Process records
foreach ($record in $records) {

    $name = $record.Name
    $ip   = $record.IP

    try {
        # Validate IPv4 address
        $parsedIP = $null
        if (-not [System.Net.IPAddress]::TryParse($ip, [ref]$parsedIP) -or
            $parsedIP.AddressFamily -ne
            [System.Net.Sockets.AddressFamily]::InterNetwork) {
            throw "Invalid IPv4 address: $ip"
        }

        # Read existing A records for this hostname
        $existingRecords = @(
            Get-DnsServerResourceRecord `
                -ComputerName $dnsServer `
                -ZoneName $zoneName `
                -Name $name `
                -RRType A `
                -ErrorAction SilentlyContinue
        )

        $matchingRecord = $existingRecords |
            Where-Object {
                $_.RecordData.IPv4Address.IPAddressToString -eq $ip
            }

        # Keep the correct record if it already exists
        if ($matchingRecord) {
            Write-Host "[OK]      $name.$zoneName -> $ip already exists" `
                -ForegroundColor Green
            continue
        }

        # Remove stale A records for this hostname only
        foreach ($oldRecord in $existingRecords) {
            Write-Host "[REMOVE]  $name.$zoneName -> $($oldRecord.RecordData.IPv4Address)" `
                -ForegroundColor Yellow

            Remove-DnsServerResourceRecord `
                -ComputerName $dnsServer `
                -ZoneName $zoneName `
                -InputObject $oldRecord `
                -Force
        }

        # Create the required A record
        Add-DnsServerResourceRecordA `
            -ComputerName $dnsServer `
            -ZoneName $zoneName `
            -Name $name `
            -IPv4Address $ip

        Write-Host "[ADDED]   $name.$zoneName -> $ip" `
            -ForegroundColor Cyan
    }
    catch {
        Write-Host "[ERROR]   $name.$zoneName : $_" `
            -ForegroundColor Red
    }
}

Write-Host "`nDNS record processing completed." -ForegroundColor Green
