param(
    [string]$Workspace = "D:\Projects;D:\Repos",
    [string]$DesktopId = "home-ultra-pc",
    [string]$DesktopName = "Home PC",
    [string]$RelayToken = ""
)

$env:CODEX_WATCH_HOST = "0.0.0.0"
$env:CODEX_WATCH_ALLOWED_ROOTS = $Workspace
$env:CODEX_WATCH_DESKTOP_ID = $DesktopId
$env:CODEX_WATCH_DESKTOP_NAME = $DesktopName

if ($RelayToken) {
    $env:CODEX_WATCH_RELAY_TOKEN = $RelayToken
}

$addresses = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object {
        $_.IPAddress -notlike "127.*" -and
        $_.IPAddress -notlike "169.254.*" -and
        $_.PrefixOrigin -ne "WellKnown"
    } |
    Sort-Object InterfaceMetric, SkipAsSource

if ($addresses) {
    Write-Host "Relay URL: http://$($addresses[0].IPAddress):8790"
}

python D:\CodexWatch\server.py
