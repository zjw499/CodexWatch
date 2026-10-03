param(
    [Parameter(Mandatory=$true)][string] $Version,
    [string] $PipelineRoot = "D:\watch-audio-pipeline",
    [string] $KeyFile = "C:\Users\zjw49\Desktop\OPENAI_API_KEY.txt"
)
$ErrorActionPreference = "Stop"
if ($Version -notmatch '^[a-f0-9]{40}$') { throw "Use the verified source commit SHA" }
$sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
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
$files = @('__init__.py', 'workspace.py', 'audio.py', 'run.py', 'requirements.txt')
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
        transcription_models=@('gpt-4o-mini-transcribe','gpt-4o-transcribe')
        generation_models=@('gpt-4.1-mini','gpt-4.1')
        baa_verified=$true; retention_verified=$false; safeguards_verified=$false
        approval_evidence='Signed Sky Data Services OpenAI BAA verified October 2, 2026. Project retention and full PC safeguards remain unverified.'
    } | ConvertTo-Json | Set-Content -LiteralPath $configuration -Encoding utf8
}
$decoder = (Get-Command ffmpeg -ErrorAction Stop).Source
Set-Content -LiteralPath (Join-Path $privateRoot 'audio-decoder.txt') -Value $decoder -Encoding utf8 -NoNewline
$env:PYTHONPATH = $releaseRoot
& $python -m compileall -q $moduleDestination
if ($LASTEXITCODE -ne 0) { throw "Workspace source validation failed" }
if (-not (Test-Path -LiteralPath (Join-Path $privateRoot 'workspace.sqlite3'))) {
    & $python -m server_workspace.run --config $configuration bootstrap
    if ($LASTEXITCODE -ne 0) { throw "Administrator bootstrap failed" }
}
$pointer = Join-Path $privateRoot "active-source.txt"
if (Test-Path -LiteralPath $pointer) { Copy-Item -LiteralPath $pointer -Destination (Join-Path $privateRoot 'previous-source.txt') -Force }
Set-Content -LiteralPath $pointer -Value $releaseRoot -NoNewline

& (Join-Path $PSScriptRoot 'install_workspace_supervisor.ps1') -PrivateRoot $privateRoot -PythonPath $python
& $tailscale serve --bg --yes --set-path=/workspace http://127.0.0.1:8790
if ($LASTEXITCODE -ne 0) { throw "Workspace started locally, but private HTTPS routing failed" }
Write-Output "Workspace release installed: $Version"
Write-Output "Private HTTPS: https://zwyattpc.tail488e93.ts.net/workspace"
Write-Output "Administrator invitation: $(Join-Path $privateRoot 'administrator-invitation.txt')"
Write-Output "Processing follows the centrally recorded organization/project approval. New installations require retention and safeguards verification."
