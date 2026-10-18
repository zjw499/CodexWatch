param([string] $PipelineRoot = 'D:\watch-audio-pipeline')
$ErrorActionPreference = 'Stop'
$pipeline = (Resolve-Path -LiteralPath $PipelineRoot).Path
$privateRoot = Join-Path $pipeline '.runtime\scribe-workspace'
$configuration = Join-Path $privateRoot 'workspace-config.json'
$task = Get-ScheduledTask -TaskName 'Scribe Pilot Voice Gateway' -ErrorAction SilentlyContinue
if ($task) { Stop-ScheduledTask -InputObject $task; Disable-ScheduledTask -InputObject $task | Out-Null }
$pidFile = Join-Path $privateRoot 'voice.pid'
$candidates = @()
if (Test-Path -LiteralPath $pidFile) {
    $voiceID = 0
    if ([int]::TryParse((Get-Content -LiteralPath $pidFile -Raw).Trim(), [ref] $voiceID) -and $voiceID -gt 0) {
        $candidates += $voiceID
    }
}
$candidates += @(Get-NetTCPConnection -LocalPort 8791 -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess)
foreach ($candidate in @($candidates | Sort-Object -Unique)) {
    if ($candidate -gt 0) {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$candidate"
        if ($process -and $process.Name -match '^python' -and $process.CommandLine.Contains($configuration) -and $process.CommandLine -match '\svoice-serve(?:\s|$)') {
            & "$env:SystemRoot\System32\taskkill.exe" /PID $candidate /T /F | Out-Null
        }
    }
}
& 'C:\Program Files\Tailscale\tailscale.exe' funnel --https=8443 off
if ($LASTEXITCODE -ne 0) { throw 'Gateway stopped; verify the 8443 Funnel listener was removed' }
Write-Output 'Watch voice is offline. Private workspace routing, recordings, and encrypted voice history are retained.'
