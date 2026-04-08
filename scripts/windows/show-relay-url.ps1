$addresses = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object {
        $_.IPAddress -notlike "127.*" -and
        $_.IPAddress -notlike "169.254.*" -and
        $_.PrefixOrigin -ne "WellKnown"
    } |
    Sort-Object InterfaceMetric, SkipAsSource

if (-not $addresses) {
    Write-Error "Could not determine a LAN IPv4 address."
    exit 1
}

$ip = $addresses[0].IPAddress
Write-Output "Relay URL: http://$ip`:8790"
