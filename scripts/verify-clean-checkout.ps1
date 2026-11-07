#requires -Version 7.0
<# Explicit build operation: fresh committed sources only; retains logs and checkout on failure. #>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ManifestFile,[Parameter(Mandatory)][string]$Destination)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'task-context.ps1')
. (Join-Path $PSScriptRoot 'review-paths.ps1')
$ManifestFile=Resolve-PhysicalPathIdentity (Resolve-Path -LiteralPath $ManifestFile).Path
$manifestBytes=[IO.File]::ReadAllBytes($ManifestFile)
$manifest=ConvertFrom-AiSopWorkflowJson ([Text.Encoding]::UTF8.GetString($manifestBytes).TrimStart([char]0xfeff)) -AsHashtable
if($manifest.schemaVersion -cne '1.0' -or -not $manifest.repositories.Count -or $manifest.repositories[0].path -cne '.' -or -not $manifest.command.executable){throw 'CLEAN_CHECKOUT_MANIFEST_INVALID'}
$Destination=Resolve-PhysicalPathIdentity $Destination
if(Test-Path -LiteralPath $Destination){throw 'CLEAN_CHECKOUT_DESTINATION_MUST_NOT_EXIST'}
$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($repository in $manifest.repositories){
    if($repository.revision -notmatch '^[0-9a-f]{40}$' -or -not $repository.source -or -not $seen.Add($repository.path)){throw 'CLEAN_CHECKOUT_REPOSITORY_INVALID'}
    if($repository.path -ne '.' -and ($repository.path -match '(^|[/\\])\.git([/\\]|$)' -or [IO.Path]::IsPathRooted($repository.path) -or $repository.path -match '(^|[/\\])\.\.([/\\]|$)')){throw 'CLEAN_CHECKOUT_PATH_ESCAPE'}
}
[IO.Directory]::CreateDirectory($Destination)|Out-Null
$logs=Join-Path $Destination 'evidence';[IO.Directory]::CreateDirectory($logs)|Out-Null
$boundManifest=Join-Path $logs 'manifest.json'
[IO.File]::WriteAllBytes($boundManifest,$manifestBytes)
$checkout=Join-Path $Destination 'checkout'
$result=[ordered]@{schemaVersion='1.0';outcome='FAILED';manifestSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($manifestBytes)).ToLowerInvariant();repositories=@();command=$manifest.command;environmentNotes=$manifest.environmentNotes;exitCode=$null;logs='evidence';limits=@('Fresh source checkout; external dependency caches and environment are not hermetic.','Build success is not runtime or business acceptance.')}
$index=0
function InvokeRecorded([string]$Executable,[string[]]$Arguments,[string]$WorkingDirectory,[int]$Timeout=600){
    $script:index++
    $name=$script:index.ToString('D3')
    $process=Start-AiSopHiddenProcess -FilePath $Executable -ArgumentList $Arguments -RedirectStandardOutput (Join-Path $logs "$name.out.log") -RedirectStandardError (Join-Path $logs "$name.err.log") -FailurePath (Join-Path $logs "$name.failure.json") -TimeoutSeconds $Timeout -HeartbeatSeconds 30 -Label "clean-checkout-$name" -CloseStandardInput -PassThru
    try {$process.WaitForExit();return $process.ExitCode}finally{$process.Dispose()}
}
try {
    foreach($repository in $manifest.repositories){
        $target=if($repository.path -eq '.'){$checkout}else{Resolve-AiSopReviewChild $checkout $repository.path}
        if(Test-Path -LiteralPath $target){
            if(-not [IO.Directory]::Exists($target) -or @(Get-ChildItem -LiteralPath $target -Force).Count){throw 'CLEAN_CHECKOUT_TARGET_ALREADY_EXISTS'}
            $parent=Split-Path -Parent $target
            $gitRoot=& git -C $parent rev-parse --show-toplevel 2>$null
            if($LASTEXITCODE -ne 0){throw 'CLEAN_CHECKOUT_EXISTING_TARGET_NOT_GITLINK'}
            $gitRelative=[IO.Path]::GetRelativePath($gitRoot,$target).Replace('\','/')
            $entry=& git -C $gitRoot ls-files --stage -- $gitRelative
            if($LASTEXITCODE -ne 0 -or @($entry).Count -ne 1 -or $entry -notmatch '^160000 ([0-9a-f]{40}) 0\s' -or $Matches[1] -cne $repository.revision){throw 'CLEAN_CHECKOUT_GITLINK_REVISION_MISMATCH'}
            # Only the verified empty gitlink placeholder is removed; never recursive.
            Remove-Item -LiteralPath $target -Force
        }
        if((InvokeRecorded 'git' @('clone','--no-local','--no-checkout','--',$repository.source,$target) $Destination) -ne 0){throw 'CLEAN_CHECKOUT_CLONE_FAILED'}
        if((InvokeRecorded 'git' @('-C',$target,'checkout','--detach',$repository.revision) $Destination) -ne 0){throw 'CLEAN_CHECKOUT_REVISION_UNAVAILABLE'}
        $actual=(& git -C $target rev-parse HEAD).Trim()
        if($LASTEXITCODE -ne 0 -or $actual -cne $repository.revision){throw 'CLEAN_CHECKOUT_REVISION_MISMATCH'}
        $result.repositories+=@{path=$repository.path;revision=$actual}
    }
    $working=if(-not $manifest.command.workingDirectory -or $manifest.command.workingDirectory -eq '.'){$checkout}else{Resolve-AiSopReviewChild $checkout $manifest.command.workingDirectory}
    $timeout=if($manifest.command.timeoutSeconds){[int]$manifest.command.timeoutSeconds}else{1800}
    $result.exitCode=InvokeRecorded (Get-Process -Id $PID).Path @('-NoProfile','-File',(Join-Path $PSScriptRoot 'invoke-clean-command.ps1'),'-ManifestFile',$boundManifest,'-WorkingDirectory',$working) $working $timeout
    if($result.exitCode -ne 0){throw 'CLEAN_CHECKOUT_BUILD_FAILED'}
    $result.outcome='PASSED'
} catch {$result.diagnostic=$_.Exception.Message;Write-Warning $result.diagnostic}
finally {[IO.File]::WriteAllText((Join-Path $logs 'result.json'),($result|ConvertTo-Json -Depth 12))}
Write-Output "CLEAN_CHECKOUT_RESULT:$($result.outcome) evidence=$(Join-Path $logs 'result.json')"
if($result.outcome -ne 'PASSED'){exit 1}
