#requires -Version 7.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../hook-event-normalizer.ps1')
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('sop-antigravity-read-'+[guid]::NewGuid().ToString('N'))
$workspace=Join-Path $fixture 'workspace'
$appRoot=Join-Path $fixture 'app-data'
$skills=Join-Path $appRoot 'builtin/skills'
$conversation='read-fixture-session'
$artifacts=Join-Path $appRoot "brain/$conversation"
$savedDedup=$env:SERVER_NEW_HOOK_DEDUP_REGISTRY
$env:SERVER_NEW_HOOK_DEDUP_REGISTRY=Join-Path $fixture 'dedup'
$originalProvider=(Get-Item Function:Get-AiSopAntigravityAppDataRoots).ScriptBlock
function Get-AiSopAntigravityAppDataRoots { $appRoot }
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Convert-Read([string]$Path,[string]$Session=$conversation,[string]$Tool='read_file',[hashtable]$Metadata=@{}) {
    $arguments=if($Tool -eq 'read_file') { @{Path=$Path} } else { @{TargetFile=$Path;CodeContent='BAD';Overwrite=$true} }
    $payload=@{conversationId=$Session;workspacePaths=@($workspace);toolCall=@{name=$Tool;args=$arguments}}
    foreach($key in $Metadata.Keys){$payload[$key]=$Metadata[$key]}
    ConvertTo-AiSopHookEvent -RawPayload ($payload|ConvertTo-Json -Depth 10) -EventHint PRE_TOOL_USE -TrustedWorkspaceRoot $workspace -AcceptedAt ([DateTimeOffset]::UtcNow)
}
function Denied([scriptblock]$Action) {
    try { & $Action | Out-Null } catch {
        Assert ($_.Exception.Message -eq 'EDIT_PATH_OUTSIDE_WORKSPACE') "非预期拒绝：$($_.Exception.Message)"
        return
    }
    throw '外部路径意外放行'
}
try {
    foreach($dir in @($workspace,$skills,$artifacts,(Join-Path $appRoot 'brain/other-session'))) { [IO.Directory]::CreateDirectory($dir)|Out-Null }
    foreach($path in @((Join-Path $workspace 'README.md'),(Join-Path $skills 'SKILL.md'),(Join-Path $artifacts 'upload.png'))) {
        [IO.File]::WriteAllText($path,'fixture')
        Assert ((Convert-Read $path).toolClass -eq 'SAFE_NON_EDIT') "合法原生资料读取被拒绝：$path"
    }
    Denied { Convert-Read (Join-Path $appRoot 'credentials.json') }
    Denied { Convert-Read (Join-Path $appRoot 'brain/other-session/upload.png') }
    Denied { Convert-Read (Join-Path $artifacts '../other-session/upload.png') }
    Denied { Convert-Read (Join-Path $fixture 'outside.txt') -Metadata @{appDataDir=$fixture;artifactDirectoryPath=$fixture} }
    Denied { Convert-Read (Join-Path $artifacts 'upload.png') -Session '../read-fixture-session' }
    Denied { Convert-Read (Join-Path $skills 'SKILL.md') -Tool write_to_file }
    Denied { Convert-Read (Join-Path $artifacts 'upload.png') -Tool write_to_file }
    $link=Join-Path $skills 'escape'
    $linkType=if([OperatingSystem]::IsWindows()){'Junction'}else{'SymbolicLink'}
    New-Item -ItemType $linkType -Path $link -Target $fixture|Out-Null
    try { Denied { Convert-Read (Join-Path $link 'outside.txt') } }
    finally { Remove-Item -LiteralPath $link -Force }
    # 允许目录本身被替换成链接，也不能把链接目标当作新的授权根。
    $appLink=Join-Path $fixture 'linked-app'
    New-Item -ItemType $linkType -Path $appLink -Target $appRoot|Out-Null
    $normalAppRoot=$appRoot; $appRoot=$appLink
    try { Denied { Convert-Read (Join-Path $appLink 'builtin/skills/SKILL.md') } }
    finally { $appRoot=$normalAppRoot; Remove-Item -LiteralPath $appLink -Force }
    Write-Output 'PASS: built-in skills/current-conversation reads, metadata spoofing, other-session access, writes and physical link escapes'
} finally {
    Set-Item Function:Get-AiSopAntigravityAppDataRoots $originalProvider
    if($null -eq $savedDedup){Remove-Item Env:SERVER_NEW_HOOK_DEDUP_REGISTRY -ErrorAction SilentlyContinue}else{$env:SERVER_NEW_HOOK_DEDUP_REGISTRY=$savedDedup}
    $physical=Resolve-PhysicalPathIdentity $fixture
    $temp=(Resolve-PhysicalPathIdentity ([IO.Path]::GetTempPath())).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if($physical.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $physical) -like 'sop-antigravity-read-*') { Remove-Item -LiteralPath $physical -Recurse -Force }
}
