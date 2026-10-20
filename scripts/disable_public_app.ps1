param([string] $PipelineRoot = 'D:\watch-audio-pipeline')
$ErrorActionPreference = 'Stop'
$pipeline = (Resolve-Path -LiteralPath $PipelineRoot).Path
$privateRoot = Join-Path $pipeline '.runtime\scribe-workspace'
$configuration = Join-Path $privateRoot 'workspace-config.json'
Set-Content -LiteralPath (Join-Path $privateRoot 'public-app.enabled') -Value 'disabled' -NoNewline
$task = Get-ScheduledTask -TaskName 'Scribe Pilot App Gateway' -ErrorAction SilentlyContinue
if ($task) { Stop-ScheduledTask -InputObject $task; Disable-ScheduledTask -InputObject $task | Out-Null }
$candidates = @(Get-NetTCPConnection -LocalPort 8793 -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess)
foreach ($candidate in @($candidates | Sort-Object -Unique)) {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$candidate"
    if ($process -and $process.Name -match '^python' -and $process.CommandLine.Contains($configuration) -and $process.CommandLine -match '\spublic-serve(?:\s|$)') {
        & "$env:SystemRoot\System32\taskkill.exe" /PID $candidate /T /F | Out-Null
    }
}
& 'C:\Program Files\Tailscale\tailscale.exe' serve --bg --yes --https=8443 --set-path=/app off
if ($LASTEXITCODE -ne 0) { throw 'App gateway stopped; verify its /app route was removed' }
Write-Output 'Internet app access disabled. Existing private and voice services retain their own routes.'
