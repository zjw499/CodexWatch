param(
    [Parameter(Mandatory=$true)][string] $Version,
    [string] $PipelineRoot = "D:\watch-audio-pipeline",
    [string] $KeyFile = "D:\watch-audio-pipeline\.runtime\scribe-workspace\scribe-pilot-production.key",
    [switch] $InstallVoiceGateway,
    [switch] $VoiceGatewayOnly,
    [switch] $ExposeVoiceGateway,
    [switch] $InstallAppGateway,
    [switch] $AppGatewayOnly,
    [switch] $ExposeAppGateway
)
$ErrorActionPreference = "Stop"
if ($Version -notmatch '^[a-f0-9]{40}$') { throw "Use the verified source commit SHA" }
if ($VoiceGatewayOnly -and -not $InstallVoiceGateway) { throw "Voice-only deployment requires InstallVoiceGateway" }
if ($ExposeVoiceGateway -and -not $InstallVoiceGateway) { throw "Install the scoped voice gateway before exposing it" }
if ($AppGatewayOnly -and -not $InstallAppGateway) { throw "App-only deployment requires InstallAppGateway" }
if ($ExposeAppGateway -and -not $InstallAppGateway) { throw "Install the app gateway before exposing it" }
if ($AppGatewayOnly -and $VoiceGatewayOnly) { throw "Choose one gateway-only deployment mode" }
if ($AppGatewayOnly -and $InstallVoiceGateway) { throw "App-only deployment cannot restart the voice gateway" }
if ($VoiceGatewayOnly -and $InstallAppGateway) { throw "Voice-only deployment cannot restart the app gateway" }
$sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$sourceCommit = (& git -C $sourceRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $sourceCommit -ne $Version) { throw 'Deploy only the selected checkout commit' }
& git -C $sourceRoot diff --quiet HEAD -- server_workspace scripts/deploy_workspace.ps1 scripts/workspace_supervisor.ps1 scripts/install_workspace_supervisor.ps1
if ($LASTEXITCODE -ne 0) { throw 'Commit and verify the scoped workspace deployment files first' }
& git -C $sourceRoot ls-files --error-unmatch server_workspace/voice.py | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'The voice module must be included in the verified source commit' }
$pipeline = (Resolve-Path -LiteralPath $PipelineRoot).Path
$runtimeRoot = Join-Path $pipeline ".runtime"
$privateRoot = Join-Path $runtimeRoot "scribe-workspace"
$releaseRoot = Join-Path $runtimeRoot "workspace-releases\$Version"
$python = Join-Path $pipeline ".venv\Scripts\python.exe"
$tailscale = "C:\Program Files\Tailscale\tailscale.exe"
if (-not (Test-Path -LiteralPath $python) -or -not (Test-Path -LiteralPath $KeyFile) -or -not (Test-Path -LiteralPath $tailscale)) {
    throw "Existing Python environment, organization key file, and Tailscale are required"
}
# Lock down storage before creating an invitation, database, or runtime configuration.
New-Item -ItemType Directory -Path $privateRoot -Force | Out-Null
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$directory = [System.IO.DirectoryInfo]::new($privateRoot)
$acl = [System.IO.FileSystemAclExtensions]::GetAccessControl($directory, [System.Security.AccessControl.AccessControlSections]::Access)
$acl.SetAccessRuleProtection($true, $false)
foreach ($existingRule in $acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])) {
    $acl.RemoveAccessRuleSpecific($existingRule)
}
foreach ($sid in @($identity.User, (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')))) {
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
}
[System.IO.FileSystemAclExtensions]::SetAccessControl($directory, $acl)

New-Item -ItemType Directory -Path $releaseRoot -Force | Out-Null
$moduleDestination = Join-Path $releaseRoot "server_workspace"
New-Item -ItemType Directory -Path $moduleDestination -Force | Out-Null
$files = @('__init__.py', 'workspace.py', 'identity.py', 'release_api.py', 'audio.py', 'voice.py', 'voice_stream.py', 'voice_tools.py', 'voice_diagnostics.py', 'knowledge.py', 'public_app.py', 'run.py', 'requirements.txt')
$manifest = @()
foreach ($name in $files) {
    $source = Join-Path $sourceRoot "server_workspace\$name"
    $destination = Join-Path $moduleDestination $name
    Copy-Item -LiteralPath $source -Destination $destination -Force
    $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $hash) { throw "Release verification failed" }
    $manifest += [pscustomobject]@{ File=$name; SHA256=$hash }
}
$manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $releaseRoot "manifest.json") -Encoding utf8
$configuration = Join-Path $privateRoot "workspace-config.json"
if (-not (Test-Path -LiteralPath $configuration)) {
    [ordered]@{
        root=$privateRoot; key_file=$KeyFile
        organization_id='org-OSni86SzRRzYCZgAuwoalu81'; project_id='proj_qPL4pTthHtsvT7t9aldiqqzg'
        transcription_models=@('gpt-4o-mini-transcribe','gpt-4o-transcribe','gpt-transcribe','whisper-1','gpt-4o-transcribe-diarize')
        generation_models=@('gpt-4.1-mini','gpt-4.1','gpt-4.1-nano','gpt-6-astra','gpt-5.6-sol','gpt-5.6-terra','gpt-5.6-luna','gpt-5.5','gpt-5.4-mini','gpt-5.4-nano')
        baa_verified=$true; retention_verified=$false; safeguards_verified=$false
        approval_evidence='Signed Sky Data Services OpenAI BAA verified October 2, 2026. Project retention and full PC safeguards remain unverified.'
        require_ai_consent=$true
    } | ConvertTo-Json | Set-Content -LiteralPath $configuration -Encoding utf8
}
$existingConfiguration = Get-Content -LiteralPath $configuration -Raw | ConvertFrom-Json
if ($existingConfiguration.key_file -ne $KeyFile) {
    Copy-Item -LiteralPath $configuration -Destination (Join-Path $privateRoot 'workspace-config.previous.json') -Force
    $existingConfiguration.key_file = $KeyFile
    $temporaryConfiguration = Join-Path $privateRoot 'workspace-config.next.json'
    $existingConfiguration | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporaryConfiguration -Encoding utf8
    Move-Item -LiteralPath $temporaryConfiguration -Destination $configuration -Force
}
$decoder = (Get-Command ffmpeg -ErrorAction Stop).Source
Set-Content -LiteralPath (Join-Path $privateRoot 'audio-decoder.txt') -Value $decoder -Encoding utf8 -NoNewline
$env:PYTHONPATH = $releaseRoot
& $python -m pip install -r (Join-Path $moduleDestination 'requirements.txt') --quiet
if ($LASTEXITCODE -ne 0) { throw "Workspace dependency installation failed" }
& $python -m compileall -q $moduleDestination
if ($LASTEXITCODE -ne 0) { throw "Workspace source validation failed" }
if (-not (Test-Path -LiteralPath (Join-Path $privateRoot 'workspace.sqlite3'))) {
    & $python -m server_workspace.run --config $configuration bootstrap
    if ($LASTEXITCODE -ne 0) { throw "Administrator bootstrap failed" }
}
if (-not $VoiceGatewayOnly -and -not $AppGatewayOnly) {
    $pointer = Join-Path $privateRoot "active-source.txt"
    if (Test-Path -LiteralPath $pointer) { Copy-Item -LiteralPath $pointer -Destination (Join-Path $privateRoot 'previous-source.txt') -Force }
    Set-Content -LiteralPath $pointer -Value $releaseRoot -NoNewline
    & (Join-Path $PSScriptRoot 'install_workspace_supervisor.ps1') -PrivateRoot $privateRoot -PythonPath $python
    & $tailscale serve --bg --yes --set-path=/workspace http://127.0.0.1:8790
    if ($LASTEXITCODE -ne 0) { throw "Workspace started locally, but private HTTPS routing failed" }
}
if ($InstallVoiceGateway) {
    $voicePointer = Join-Path $privateRoot 'voice-active-source.txt'
    if (Test-Path -LiteralPath $voicePointer) { Copy-Item -LiteralPath $voicePointer -Destination (Join-Path $privateRoot 'voice-previous-source.txt') -Force }
    Set-Content -LiteralPath $voicePointer -Value $releaseRoot -NoNewline
    & (Join-Path $PSScriptRoot 'install_workspace_supervisor.ps1') -PrivateRoot $privateRoot -PythonPath $python -ServiceMode 'voice-serve'
}
if ($ExposeVoiceGateway) {
    # A separate HTTPS port leaves the private 443 workspace/legacy routes intact.
    & $tailscale funnel --bg --https=8443 http://127.0.0.1:8791
    if ($LASTEXITCODE -ne 0) { throw "Voice is installed locally; the node still needs Tailscale Funnel authorization" }
}
if ($InstallAppGateway) {
    $appPointer = Join-Path $privateRoot 'app-active-source.txt'
    if (Test-Path -LiteralPath $appPointer) { Copy-Item -LiteralPath $appPointer -Destination (Join-Path $privateRoot 'app-previous-source.txt') -Force }
    Set-Content -LiteralPath $appPointer -Value $releaseRoot -NoNewline
    Set-Content -LiteralPath (Join-Path $privateRoot 'public-app.enabled') -Value 'enabled' -NoNewline
    & (Join-Path $PSScriptRoot 'install_workspace_supervisor.ps1') -PrivateRoot $privateRoot -PythonPath $python -ServiceMode 'public-serve'
}
if ($ExposeAppGateway) {
    # Add only the authenticated app path. Existing voice/review handlers and
    # private 443 routes retain their own listeners and service lifetimes.
    & $tailscale funnel --bg --yes --https=8443 --set-path=/app http://127.0.0.1:8793
    if ($LASTEXITCODE -ne 0) { throw "App gateway is installed locally; public HTTPS routing failed" }
    Write-Output 'Internet app connection: https://zwyattpc.tail488e93.ts.net:8443/app'
}
Write-Output "Workspace release installed: $Version"
Write-Output "Private HTTPS: https://zwyattpc.tail488e93.ts.net/workspace"
Write-Output "Administrator invitation: $(Join-Path $privateRoot 'administrator-invitation.txt')"
Write-Output "Processing follows the centrally recorded organization/project approval. New installations require retention and safeguards verification."
