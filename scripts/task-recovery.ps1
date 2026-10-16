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

function Get-AiSopRecoveryGuidance {
    param($Task, $Records, [string]$OwnerStatus, [string]$SessionStatus)
    $steps=[Collections.Generic.List[object]]::new()
    if (-not $Task) { $steps.Add(@{code='INSPECT_AUTHORITY';message='Restore a trusted task record or inspect transaction recovery; do not infer ownership from damaged authority.'}) }
    elseif ($Task.status -in @('DONE','CANCELLED')) { $steps.Add(@{code='START_NEW_TASK';message='Start a new task for new work; historical completion is unchanged.'}) }
    else {
        $runs=@($Records | Where-Object kind -eq 'PENDING')
        if (@($runs | Where-Object activity -eq 'RUNNING').Count) { $steps.Add(@{code='WAIT_FOR_RUN';message='Wait for the running command and inspect its log; do not RetryEvidence or Recover while execution is active.'}) }
        elseif (@($runs | Where-Object { $_.activity -in @('REMOTE_UNKNOWN','UNCONFIRMED') }).Count) { $steps.Add(@{code='CONFIRM_RUN_STOPPED';message='Confirm execution has stopped on the original machine/workspace before recovery; local observation cannot establish this.'}) }
        elseif (@($runs | Where-Object status -eq 'INVALID').Count) { $steps.Add(@{code='INSPECT_PENDING';message='InspectRecovery reports invalid pending evidence. After execution stops, explicitly quarantine it with a reason before Recover and rerunning verification.'}) }
        elseif (@($runs | Where-Object { $_.status -eq 'VALID' -and $_.outcome -ne 'RUNNING' }).Count) { $steps.Add(@{code='RETRY_EVIDENCE';message='RetryEvidence can save the validated terminal result without rerunning. If its session has ended, use Recover after execution stops, then Resume.'}) }
        elseif ($runs.Count) { $steps.Add(@{code='RECOVER_RUN';message='Execution stopped without a valid terminal result. Recover the interrupted attempt, then Resume and rerun verification; RetryEvidence cannot save a RUNNING record.'}) }
        if (@($Records | Where-Object { $_.kind -eq 'BASELINE' -and $_.status -ne 'VALID' }).Count) {
            $steps.Add(@{code='RESTORE_BASELINE';message='T3 original Start inputs are unavailable or incompatible. Restore the recorded Start data/policy, or finish with a compatible original engine after reviewing scope. If no valid original exists, explicitly decide how to close the legacy task before starting independent work. Resume only repairs the session; never adopt current files as the old Start snapshot.'})
        }
        if ($OwnerStatus -eq 'OTHER_TASK') { $steps.Add(@{code='OTHER_TASK_OWNER';message='The feature owner belongs to another task. Resolve that ownership before resuming this task; do not take over another independent task implicitly.'}) }
        elseif (@($Records | Where-Object { $_.kind -in @('TASK','OWNER','SESSION') -and $_.status -in @('UNAVAILABLE','UNVERIFIED','IDENTITY_MISMATCH') }).Count) { $steps.Add(@{code='INSPECT_AUTHORITY';message='InspectRecovery reports unreadable or mismatched authority. Restore trusted records or inspect transaction recovery; do not delete records or guess an owner.'}) }
        elseif (-not $runs.Count) {
            if ($Task.status -eq 'PAUSED') { $steps.Add(@{code='RESUME_SESSION';message='Resume the paused task to bind local ownership and a current session.'}) }
            elseif ($OwnerStatus -ne 'ACTIVE') { $steps.Add(@{code='RECOVER_OWNER';message='Recover local ownership, then Resume; no ownership is changed by this diagnosis.'}) }
            elseif ($SessionStatus -in @('ACTIVE','IDLE')) { $steps.Add(@{code='INTENTIONAL_HANDOFF';message='Existing session may still be active; Resume only for intentional handoff.'}) }
            else { $steps.Add(@{code='RESUME_SESSION';message='Resume to bind a current session. This does not repair a missing T3 baseline or settle unfinished execution.'}) }
        }
    }
    return @($steps.ToArray())
}

function Get-AiSopTaskRecoveryDiagnostics {
    param([string]$SpecDirectory, [string]$TaskId, [string]$WorkspacePath, [string]$OwnerPath, [ValidateRange(0,200)][int]$LogTailLines=0)
    $items=@(); $task=$null; $owner=$null; $ownerMatches=$false
    $comparison=if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $workspace=Resolve-PhysicalPathIdentity $WorkspacePath
    $spec=Resolve-PhysicalPathIdentity $SpecDirectory
    $taskPath=Get-AiSopTaskPath $SpecDirectory $TaskId
    try { $task=Read-AiSopTask $SpecDirectory $TaskId; $items+=@{kind='TASK';path=$taskPath;status='VALID'} }
    catch { $items+=@{kind='TASK';path=$taskPath;status='UNAVAILABLE';diagnostic=$_.Exception.Message} }
    try {
        $raw=[IO.File]::ReadAllText($OwnerPath); Assert-AiSopWorkflowJsonSchema -Json $raw -SchemaId OWNER
        $owner=ConvertFrom-AiSopWorkflowJson $raw -AsHashtable
        $record=@{kind='OWNER';path=$OwnerPath;status='VALID';ownerTaskId=[string]$owner.taskId;ownerStatus=$owner.status}
        if (-not $task) { $record.status='UNVERIFIED'; $record.diagnostic='TASK_IDENTITY_UNAVAILABLE: task must be readable before associating local authority' }
        elseif ($owner.taskId -cne $TaskId -or $owner.ownerId -cne $task.ownerId -or $owner.feature -cne $task.feature) {
            $record.status='OTHER_TASK'; $record.diagnostic='OWNER_TASK_MISMATCH: this feature registry record belongs to another task/owner'
        } elseif (-not (Resolve-PhysicalPathIdentity $owner.workspacePath).Equals($workspace,$comparison) -or
            -not (Resolve-PhysicalPathIdentity $owner.specDirectory).Equals($spec,$comparison)) {
            $record.status='IDENTITY_MISMATCH'; $record.diagnostic='OWNER_WORKSPACE_MISMATCH'
        } else { $ownerMatches=$true }
        $items+=$record
    } catch { $items+=@{kind='OWNER';path=$OwnerPath;status=$(if ([IO.File]::Exists($OwnerPath)) { 'UNAVAILABLE' } else { 'MISSING' });diagnostic=$_.Exception.Message} }
    if ($ownerMatches -and $owner.status -eq 'ACTIVE' -and $owner.sessionBinding.sessionKey) {
        $sessionPath=Resolve-AiSopWorkspaceChild (Get-AiSopWorkflowSessionRegistryRoot -WorkspacePath $WorkspacePath) ($owner.sessionBinding.sessionKey + '.json')
        try {
            $session=Read-AiSopWorkflowSessionRecord -SessionPath $sessionPath -ExpectedSessionKey $owner.sessionBinding.sessionKey
            $record=@{kind='SESSION';path=$sessionPath;status='VALID'}
            if (-not (Resolve-PhysicalPathIdentity $session.workspacePath).Equals($workspace,$comparison) -or
                $session.sessionEpochId -cne $owner.sessionBinding.sessionEpochId -or
                $session.boundSessionEpochId -cne $owner.sessionBinding.sessionEpochId -or
                $session.boundOwnerId -cne $task.ownerId -or $session.boundFeature -cne $task.feature -or
                $session.boundWorkflow -cne $owner.workflow -or $session.agent -cne $owner.agent) {
                $record.status='IDENTITY_MISMATCH'; $record.diagnostic='LOCAL_SESSION_IDENTITY_MISMATCH'
            } else { $record.effectiveStatus=Get-AiSopWorkflowSessionEffectiveStatus $session ([DateTimeOffset]::UtcNow) }
            $items+=$record
        }
        catch { $items+=@{kind='SESSION';path=$sessionPath;status='UNAVAILABLE';diagnostic=$_.Exception.Message} }
    }
    if ($task) {
        if ($task.tier -eq 'T3' -and $task.status -notin @('DONE','CANCELLED')) {
            $baselineRecord=@{kind='BASELINE';status='VALID'}
            try {
                $baseline=Read-AiSopTaskBaselineInputs $task $WorkspacePath (New-AiSopValidationContext)
                $policy=Get-AiSopInputPolicy $WorkspacePath
                $algorithm=if ($policy.digest) { 'inputs-v4' } else { 'inputs-v2' }
                if ($baseline.algorithm -cne $algorithm -or [string]$baseline.policyDigest -cne [string]$policy.digest) { throw 'TASK_BASELINE_POLICY_MISMATCH: original input policy must be restored; do not replace the Start snapshot' }
            } catch { $baselineRecord.status='UNAVAILABLE'; $baselineRecord.diagnostic=$_.Exception.Message }
            $items+=$baselineRecord
        }
        foreach ($run in @($task.verifications | Where-Object outcome -eq 'RUNNING')) {
            $path=Get-AiSopRunEvidencePath $SpecDirectory $TaskId $run.runId
            $item=@{kind='PENDING';runId=$run.runId;path=$path;activity=(Get-AiSopRunActivity $run $WorkspacePath);status='MISSING';outcome=$null;progress=(Get-AiSopRunProgress $run $WorkspacePath $SpecDirectory $TaskId -LogTailLines $LogTailLines)}
            if ([IO.File]::Exists($path)) {
                try {
                    $pending=ConvertFrom-AiSopWorkflowJson ([IO.File]::ReadAllText($path)) -AsHashtable
                    $probe=ConvertFrom-AiSopWorkflowJson (ConvertTo-AiSopWorkflowCanonicalJson $task) -AsHashtable; $probe.verifications=@($pending)
                    Assert-AiSopWorkflowJsonSchema -Json (ConvertTo-AiSopWorkflowCanonicalJson $probe) -SchemaId TASK
                    if ($pending.outcome -eq 'RUNNING') {
                        if ((ConvertTo-AiSopWorkflowCanonicalJson $pending) -cne (ConvertTo-AiSopWorkflowCanonicalJson $run)) { throw 'RUN_PENDING_IDENTITY_MISMATCH' }
                    } else { Assert-AiSopRunEvidence $pending $run $task $WorkspacePath -Retry }
                    $item.status='VALID'
                    $item.outcome=$pending.outcome
                } catch { $item.status='INVALID'; $item.diagnostic=$_.Exception.Message }
            }
            $items+=$item
        }
    }
    $ownerRecord=@($items | Where-Object kind -eq 'OWNER')[0]
    $ownerStatus=if ($ownerRecord.status -eq 'VALID') { $ownerRecord.ownerStatus } else { $ownerRecord.status }
    $sessionRecord=@($items | Where-Object kind -eq 'SESSION')[0]
    $sessionStatus=if (-not $sessionRecord) { 'MISSING' } elseif ($sessionRecord.status -eq 'VALID') { $sessionRecord.effectiveStatus } else { $sessionRecord.status }
    $steps=@(Get-AiSopRecoveryGuidance $task $items $ownerStatus $sessionStatus)
    return @{schemaVersion='1.0';taskId=$TaskId;records=$items;readOnly=$true;ownerStatus=$ownerStatus;sessionStatus=$sessionStatus;guidanceSteps=$steps;suggestedActionCode=$steps[0].code;guidance=($steps.message -join ' ')}
}
