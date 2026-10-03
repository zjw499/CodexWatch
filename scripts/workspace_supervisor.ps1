param(
    [Parameter(Mandatory=$true)][string] $PrivateRoot,
    [Parameter(Mandatory=$true)][string] $PythonPath
)
$ErrorActionPreference = 'Stop'
$PrivateRoot = (Resolve-Path -LiteralPath $PrivateRoot).Path
$configuration = Join-Path $PrivateRoot 'workspace-config.json'
$lock = $null
try {
    $lock = [System.IO.File]::Open((Join-Path $PrivateRoot 'supervisor.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
} catch { exit 0 }

function Write-ServiceEvent([string] $Event) {
    $log = Join-Path $PrivateRoot 'supervisor.log'
    if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 1MB) {
        Move-Item -LiteralPath $log -Destination (Join-Path $PrivateRoot 'supervisor.previous.log') -Force
    }
    # Events contain fixed labels and process IDs, never exception messages or request data.
    Add-Content -LiteralPath $log -Value ((Get-Date).ToUniversalTime().ToString('o') + ' ' + $Event)
}

try {
    while ($true) {
        $service = $null
        try {
            $selected = (Get-Content -LiteralPath (Join-Path $PrivateRoot 'active-source.txt') -Raw).Trim()
            $env:PYTHONPATH = $selected
            foreach ($stream in @('stdout', 'stderr')) {
                $log = Join-Path $PrivateRoot "service.$stream.log"
                if (Test-Path -LiteralPath $log) {
                    Copy-Item -LiteralPath $log -Destination (Join-Path $PrivateRoot "service.$stream.previous.log") -Force
                }
            }
            $service = Start-Process -FilePath $PythonPath -ArgumentList @('-m','server_workspace.run','--config',('"' + $configuration + '"'),'serve') -WorkingDirectory $PrivateRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $PrivateRoot 'service.stdout.log') -RedirectStandardError (Join-Path $PrivateRoot 'service.stderr.log')
            Set-Content -LiteralPath (Join-Path $PrivateRoot 'service.pid') -Value $service.Id
            Write-ServiceEvent "started pid=$($service.Id)"
            $started = Get-Date
            $unhealthy = 0
            while (-not $service.WaitForExit(5000)) {
                if (((Get-Date) - $started).TotalSeconds -lt 30) { continue }
                try {
                    $health = Invoke-RestMethod -Uri 'http://127.0.0.1:8790/api/health' -TimeoutSec 3 -UseBasicParsing
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
