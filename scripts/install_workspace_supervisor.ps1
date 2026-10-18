param(
    [Parameter(Mandatory=$true)][string] $PrivateRoot,
    [Parameter(Mandatory=$true)][string] $PythonPath,
    [ValidateSet('serve','voice-serve')][string] $ServiceMode = 'serve'
)
$ErrorActionPreference = 'Stop'
$PrivateRoot = (Resolve-Path -LiteralPath $PrivateRoot).Path
$PythonPath = (Resolve-Path -LiteralPath $PythonPath).Path
$voice = $ServiceMode -eq 'voice-serve'
$taskName = if ($voice) { 'Scribe Pilot Voice Gateway' } else { 'Scribe Pilot Workspace' }
$servicePrefix = if ($voice) { 'voice' } else { 'service' }
$supervisorName = if ($voice) { 'voice-supervise.ps1' } else { 'supervise.ps1' }
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
if ($existing) {
    Export-ScheduledTask -TaskName $taskName | Set-Content -LiteralPath (Join-Path $PrivateRoot "$servicePrefix-task-before-$stamp.xml") -Encoding utf8
    Stop-ScheduledTask -TaskName $taskName
}
$supervisor = Join-Path $PrivateRoot $supervisorName
# Migrate an older detached supervisor as well as the scheduled task.
$legacy = Get-CimInstance Win32_Process | Where-Object {
    $_.ProcessId -ne $PID -and $_.Name -match '^(powershell|pwsh)\.exe$' -and
    $_.CommandLine -match '(?:^|\s)-File\s' -and $_.CommandLine.Contains($supervisor)
}
foreach ($process in $legacy) {
    & "$env:SystemRoot\System32\taskkill.exe" /PID $process.ProcessId /T /F | Out-Null
}
if (Test-Path -LiteralPath $supervisor) {
    Copy-Item -LiteralPath $supervisor -Destination (Join-Path $PrivateRoot "$servicePrefix-supervise-before-$stamp.ps1") -Force
}
# Stop only this workspace's recorded child, never a process selected just by name.
$pidFile = Join-Path $PrivateRoot "$servicePrefix.pid"
if (Test-Path -LiteralPath $pidFile) {
    $serviceID = [int](Get-Content -LiteralPath $pidFile -Raw)
    $service = Get-CimInstance Win32_Process -Filter "ProcessId=$serviceID"
    if ($service -and $service.CommandLine -like '*server_workspace.run*' -and $service.CommandLine.Contains((Join-Path $PrivateRoot 'workspace-config.json')) -and $service.CommandLine -match "(?:^|\s)$ServiceMode(?:\s|$)") {
        & "$env:SystemRoot\System32\taskkill.exe" /PID $serviceID /T /F | Out-Null
    }
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'workspace_supervisor.ps1') -Destination $supervisor -Force
$arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $supervisor + '" -PrivateRoot "' + $PrivateRoot + '" -PythonPath "' + $PythonPath + '" -ServiceMode ' + $ServiceMode
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $arguments -WorkingDirectory $PrivateRoot
$logon = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
$watchdog = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddSeconds(15)) -RepetitionInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($logon, $watchdog) -Principal $principal -Settings $settings -Force | Out-Null
# Task Scheduler owns the lifetime; detaching a child from a terminal does not provide supervision.
Start-ScheduledTask -TaskName $taskName
Write-Output "$taskName supervision installed and started."
