#requires -Version 7.0
# Damaged execution results can be preserved without treating them as success.
# Authority records remain strict: never guess ownership from malformed JSON.
function Save-AiSopInvalidEvidence {
    param([string]$Path, [string]$WorkspacePath, [string]$Feature, [string]$TaskId, [string]$RunId, [string]$Diagnostic)
    $bytes=[IO.File]::ReadAllBytes($Path)
    $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    $relative=".ai-workspace/.runtime/quarantine/$Feature/$TaskId/$RunId-$digest.bin"
    $backup=Resolve-AiSopWorkspaceChild $WorkspacePath $relative
    [IO.Directory]::CreateDirectory((Split-Path -Parent $backup)) | Out-Null
    $ignore=Resolve-AiSopWorkspaceChild $WorkspacePath '.ai-workspace/.runtime/.gitignore'
    if (-not [IO.File]::Exists($ignore)) { Write-AiSopWorkflowTextAtomic -Path $ignore -Text "*`n" }
    # This is an immutable local backup, not an authority mutation. A failed
    # transaction may leave a harmless backup; the original survives until commit.
    if (-not [IO.File]::Exists($backup)) {
        $stream=[IO.FileStream]::new($backup,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
    }
    if ((Get-FileHash -LiteralPath $backup).Hash.ToLowerInvariant() -cne $digest) { throw 'QUARANTINE_BACKUP_INVALID' }
    return @{ originalPath=[IO.Path]::GetRelativePath($WorkspacePath,$Path).Replace('\','/'); backupPath=$relative; sha256=$digest; diagnostic=$Diagnostic; machine=[Environment]::MachineName; workspace=$WorkspacePath }
}

function Get-AiSopTaskRecoveryDiagnostics {
    param([string]$SpecDirectory, [string]$TaskId, [string]$WorkspacePath, [string]$OwnerPath)
    $items=@(); $task=$null; $owner=$null
    $taskPath=Get-AiSopTaskPath $SpecDirectory $TaskId
    try { $task=Read-AiSopTask $SpecDirectory $TaskId; $items+=@{kind='TASK';path=$taskPath;status='VALID'} }
    catch { $items+=@{kind='TASK';path=$taskPath;status='UNAVAILABLE';diagnostic=$_.Exception.Message} }
    try {
        $raw=[IO.File]::ReadAllText($OwnerPath); Assert-AiSopWorkflowJsonSchema -Json $raw -SchemaId OWNER
        $owner=ConvertFrom-AiSopWorkflowJson $raw -AsHashtable
        $items+=@{kind='OWNER';path=$OwnerPath;status='VALID'}
    } catch { $items+=@{kind='OWNER';path=$OwnerPath;status='UNAVAILABLE';diagnostic=$_.Exception.Message} }
    if ($owner.sessionBinding.sessionKey) {
        $sessionPath=Resolve-AiSopWorkspaceChild (Get-AiSopWorkflowSessionRegistryRoot -WorkspacePath $WorkspacePath) ($owner.sessionBinding.sessionKey + '.json')
        try { Read-AiSopWorkflowSessionRecord -SessionPath $sessionPath | Out-Null; $items+=@{kind='SESSION';path=$sessionPath;status='VALID'} }
        catch { $items+=@{kind='SESSION';path=$sessionPath;status='UNAVAILABLE';diagnostic=$_.Exception.Message} }
    }
    if ($task) {
        foreach ($run in @($task.verifications | Where-Object outcome -eq 'RUNNING')) {
            $path=Get-AiSopRunEvidencePath $SpecDirectory $TaskId $run.runId
            $item=@{kind='PENDING';path=$path;activity=(Get-AiSopRunActivity $run $WorkspacePath);status='MISSING'}
            if ([IO.File]::Exists($path)) {
                try {
                    $pending=ConvertFrom-AiSopWorkflowJson ([IO.File]::ReadAllText($path)) -AsHashtable
                    $probe=ConvertFrom-AiSopWorkflowJson (ConvertTo-AiSopWorkflowCanonicalJson $task) -AsHashtable; $probe.verifications=@($pending)
                    Assert-AiSopWorkflowJsonSchema -Json (ConvertTo-AiSopWorkflowCanonicalJson $probe) -SchemaId TASK
                    if ($pending.outcome -eq 'RUNNING') {
                        if ((ConvertTo-AiSopWorkflowCanonicalJson $pending) -cne (ConvertTo-AiSopWorkflowCanonicalJson $run)) { throw 'RUN_PENDING_IDENTITY_MISMATCH' }
                    } else { Assert-AiSopRunEvidence $pending $run $task $WorkspacePath -Retry }
                    $item.status='VALID'
                } catch { $item.status='INVALID'; $item.diagnostic=$_.Exception.Message }
            }
            $items+=$item
        }
    }
    return @{schemaVersion='1.0';taskId=$TaskId;records=$items;readOnly=$true; guidance='Damaged task/owner/session authority requires a trusted backup or transaction recovery; do not delete it or infer an owner. Invalid pending results can be quarantined explicitly after execution stops; this marks the attempt interrupted and requires a new run.'}
}
