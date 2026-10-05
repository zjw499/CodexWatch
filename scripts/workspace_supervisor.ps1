param(
    [Parameter(Mandatory=$true)][string] $PrivateRoot,
    [Parameter(Mandatory=$true)][string] $PythonPath,
    [ValidateSet('serve','voice-serve')][string] $ServiceMode = 'serve'
)
$ErrorActionPreference = 'Stop'
$PrivateRoot = (Resolve-Path -LiteralPath $PrivateRoot).Path
$configuration = Join-Path $PrivateRoot 'workspace-config.json'
$voice = $ServiceMode -eq 'voice-serve'
$servicePrefix = if ($voice) { 'voice' } else { 'service' }
$servicePort = if ($voice) { 8791 } else { 8790 }
$healthPath = if ($voice) { '/voice/v1/health' } else { '/api/health' }
$supervisorPrefix = if ($voice) { 'voice-supervisor' } else { 'supervisor' }
$lock = $null
try {
    $lock = [System.IO.File]::Open((Join-Path $PrivateRoot "$supervisorPrefix.lock"), 'OpenOrCreate', 'ReadWrite', 'None')
} catch { exit 0 }

function Write-ServiceEvent([string] $Event) {
    $log = Join-Path $PrivateRoot "$supervisorPrefix.log"
    if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 1MB) {
        Move-Item -LiteralPath $log -Destination (Join-Path $PrivateRoot "$supervisorPrefix.previous.log") -Force
    }
    # Events contain fixed labels and process IDs, never exception messages or request data.
    Add-Content -LiteralPath $log -Value ((Get-Date).ToUniversalTime().ToString('o') + ' ' + $Event)
}

function Stop-OrphanedWorkspace {
    $candidates = @()
    $pidFile = Join-Path $PrivateRoot "$servicePrefix.pid"
    if (Test-Path -LiteralPath $pidFile) {
        $savedID = 0
        if ([int]::TryParse((Get-Content -LiteralPath $pidFile -Raw).Trim(), [ref] $savedID)) { $candidates += $savedID }
    }
    $candidates += @(Get-NetTCPConnection -LocalPort $servicePort -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess)
    foreach ($candidate in @($candidates | Sort-Object -Unique)) {
        if ($candidate -le 0) { continue }
        $orphan = Get-CimInstance Win32_Process -Filter "ProcessId=$candidate"
        if ($orphan -and $orphan.Name -match '^python' -and $orphan.CommandLine -like '*server_workspace.run*' -and $orphan.CommandLine.Contains($configuration) -and $orphan.CommandLine -match "(?:^|\s)$ServiceMode(?:\s|$)") {
            Write-ServiceEvent "orphan-reaped pid=$candidate"
            & "$env:SystemRoot\System32\taskkill.exe" /PID $candidate /T /F | Out-Null
        }
    }
}

try {
    while ($true) {
        $service = $null
        try {
            # The venv launcher and Python child can outlive a failed supervisor independently.
            Stop-OrphanedWorkspace
            $selected = (Get-Content -LiteralPath (Join-Path $PrivateRoot 'active-source.txt') -Raw).Trim()
            $env:PYTHONPATH = $selected
            foreach ($stream in @('stdout', 'stderr')) {
                $log = Join-Path $PrivateRoot "$servicePrefix.$stream.log"
                if (Test-Path -LiteralPath $log) {
                    Copy-Item -LiteralPath $log -Destination (Join-Path $PrivateRoot "$servicePrefix.$stream.previous.log") -Force
                }
            }
            $service = Start-Process -FilePath $PythonPath -ArgumentList @('-m','server_workspace.run','--config',('"' + $configuration + '"'),$ServiceMode) -WorkingDirectory $PrivateRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $PrivateRoot "$servicePrefix.stdout.log") -RedirectStandardError (Join-Path $PrivateRoot "$servicePrefix.stderr.log")
            Set-Content -LiteralPath (Join-Path $PrivateRoot "$servicePrefix.pid") -Value $service.Id
            Write-ServiceEvent "started pid=$($service.Id)"
            $started = Get-Date
            $unhealthy = 0
            while (-not $service.WaitForExit(5000)) {
                if (((Get-Date) - $started).TotalSeconds -lt 30) { continue }
                try {
                    $health = Invoke-RestMethod -Uri "http://127.0.0.1:$servicePort$healthPath" -TimeoutSec 3 -UseBasicParsing
                    if ($health.ok -ne $true -and $health.status -ne 'ok') { throw 'unhealthy' }
                    $unhealthy = 0
                } catch { $unhealthy++ }
                if ($unhealthy -ge 3) {
                    Write-ServiceEvent "health-restart pid=$($service.Id)"
                    & "$env:SystemRoot\System32\taskkill.exe" /PID $service.Id /T /F | Out-Null
                    $service.WaitForExit()
                }
            }
            Write-ServiceEvent "exited pid=$($service.Id)"
        } catch {
            Write-ServiceEvent 'launch-retry'
            if ($service -and -not $service.HasExited) {
                & "$env:SystemRoot\System32\taskkill.exe" /PID $service.Id /T /F | Out-Null
            }
        }
        Start-Sleep -Seconds 5
    }
} finally { if ($lock) { $lock.Dispose() } }
