#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Discover','Status','FollowUps','Recover','Start','Resume','Checkpoint','Suspend','Cancel','Run','RetryEvidence','ReviewImpact','Verify','Complete','ChangeTier','RecordSync','SetApplicability','AddFollowUp','CloseFollowUp','ReopenFollowUp','Changes','SetBaseline','SetCaseScope','InspectRecovery')][string]$Operation,
    [string]$WorkspacePath = (Get-Location).Path,
    [string]$SpecDirectory,
    [string]$Feature,
    [string]$TaskId,
    [ValidateSet('T1','T2','T3')][string]$Tier = 'T2',
    [string]$Objective,
    [ValidateSet('CLAUDE_CODE','CODEX','CURSOR','COPILOT','ANTIGRAVITY','PI')][string]$Agent,
    [string]$NextAction,
    [string]$Notes,
    [ValidateSet('compile','test')][string]$Kind,
    [string]$Batch = 'main',
    [string]$Executable,
    [string[]]$Arguments = @(),
    [string[]]$CaseIds = @(),
    [string]$Profile,
    [ValidateRange(0,86400)][int]$TimeoutSeconds = 0,
    [switch]$ForceRecovery,
    [switch]$QuarantineInvalidEvidence,
    [switch]$ConfirmTakeover,
    [string]$RunId,
    [string]$Reason,
    [string]$UserRequest,
    [ValidateSet('UPDATED','UNCHANGED')][string]$Documentation,
    [ValidateSet('UPDATED','UNCHANGED','NOT_APPLICABLE')][string]$Tests,
    [string]$Summary,
    [ValidateSet('REQUIRED','NOT_APPLICABLE')][string]$Applicability,
    [string]$FollowUpId,
    [ValidateSet('documentation','test-cases','verification')][string]$FollowUpKind,
    [string[]]$Scope = @(),
    [string]$SourceTaskId,
    [ValidateSet('RESOLVED','NOT_NEEDED')][string]$Disposition = 'RESOLVED',
    [string]$Resolution,
    [switch]$Json,
    [ValidateSet('Human','JsonLines')][string]$OutputFormat = 'Human',
    [switch]$IncludeHistory,
    [switch]$RecheckHistory,
    [string]$BaselineInputsRef,
    [switch]$CaptureBaseline,
    [string[]]$JUnitReports = @(),
    [string]$CaseMap,
    [ValidateRange(0,200)][int]$LogTailLines=0
)
$ErrorActionPreference = 'Stop'
if ($LogTailLines -and $Operation -notin @('Status','Discover','InspectRecovery')) { throw 'LOG_TAIL_REQUIRES_DIAGNOSTIC_OPERATION' }
. (Join-Path $PSScriptRoot 'task-context.ps1')
. (Join-Path $PSScriptRoot 'workflow-session.ps1')
$WorkspacePath = Resolve-PhysicalPathIdentity -Path $WorkspacePath
if ($CaptureBaseline -and $Operation -ne 'Start') { throw 'CAPTURE_BASELINE_REQUIRES_START: capture before editing; Resume cannot redefine the original inputs' }
if ($RecheckHistory -and $Operation -ne 'Status') { throw 'HISTORY_RECHECK_REQUIRES_STATUS: use Status with a TaskId or IncludeHistory to select historical tasks' }
$featuresRoot = Resolve-AiSopWorkspaceChild $WorkspacePath '.ai-workspace/specs/features'
if (-not $Feature -and $SpecDirectory) { $Feature = Split-Path -Leaf $SpecDirectory }
$Feature = Resolve-AiSopFeatureName $WorkspacePath $Feature
$deploymentWarnings = @(Get-AiSopDeploymentWarnings $WorkspacePath)
if ($Operation -notin @('Discover','Status')) { foreach ($warning in $deploymentWarnings) { Write-Warning $warning } }
if ($Operation -eq 'FollowUps') {
    $items = @(Get-AiSopPendingFollowUps $WorkspacePath | Where-Object { (-not $Feature -or $_.feature -ceq $Feature) -and (-not $TaskId -or $_.taskId -ceq $TaskId) })
    @{ pendingFollowUps=$items; count=$items.Count; blocking=$false } | ConvertTo-Json -Depth 8
    exit 0
}
if ($Operation -in @('Discover','Status')) {
    $dirs = @(Get-ChildItem -LiteralPath $featuresRoot -Directory -ErrorAction SilentlyContinue | Where-Object { -not $Feature -or $_.Name -ceq $Feature })
    if ($SpecDirectory -and (Resolve-PhysicalPathIdentity $SpecDirectory) -cne (Resolve-AiSopWorkspaceChild $WorkspacePath ".ai-workspace/specs/features/$Feature")) { throw 'TASK_WORKSPACE_MISMATCH' }
    $items = [Collections.Generic.List[object]]::new()
    $validationContext = New-AiSopValidationContext
    foreach ($dir in $dirs) {
        $canonicalDir = Resolve-AiSopWorkspaceChild $WorkspacePath ".ai-workspace/specs/features/$($dir.Name)"
        $records = @(Get-ChildItem -LiteralPath (Join-Path $canonicalDir 'tasks') -Directory -ErrorAction SilentlyContinue | Where-Object { -not $TaskId -or $_.Name -ceq $TaskId })
        foreach ($entry in $records) {
            try {
                $task = Read-AiSopTask $canonicalDir $entry.Name
                if (-not $IncludeHistory -and -not $TaskId -and $task.status -in @('DONE','CANCELLED') -and -not @($task.followUps | Where-Object { $_.status -eq 'PENDING' }).Count) { continue }
                $items.Add((Get-AiSopTaskSummary $task $WorkspacePath $canonicalDir -CheckInputs:($Operation -eq 'Status') -ValidationContext $validationContext -RecheckHistory:$RecheckHistory -LogTailLines $LogTailLines))
            } catch { $items.Add(@{ feature=$dir.Name; taskId=$entry.Name; status='CORRUPT'; diagnostic=$_.Exception.Message; suggestedAction='Inspect the task record; do not recreate it or infer ownership from damaged state.' }) }
        }
        if (-not $records.Count) {
            if ($TaskId) { $items.Add(@{ feature=$dir.Name; taskId=$TaskId; status='NOT_FOUND'; suggestedAction='Select an existing TaskId or Start independent work.' }) }
            else { $items.Add((Get-AiSopLegacyTaskSummary $canonicalDir $WorkspacePath)) }
        }
    }
    if (-not $dirs.Count -and ($Feature -or $TaskId)) { $items.Add(@{ feature=$Feature; taskId=$TaskId; status='NOT_FOUND'; suggestedAction='Start a task with an explicit feature and objective.' }) }
    $warnings = @($deploymentWarnings) + @(Get-AiSopSpecSyncWarning $WorkspacePath)
    Write-AiSopTaskStatus -Items $items.ToArray() -WorkspacePath $WorkspacePath -Operation $Operation -Format $(if ($Json) { 'Json' } else { $OutputFormat }) -Warnings $warnings
    exit 0
}
if (-not $Feature -and $SpecDirectory) { $Feature = Split-Path -Leaf $SpecDirectory }
if ($Feature -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9_-])?$') { throw 'FEATURE_REQUIRED' }
if (-not $SpecDirectory) { $SpecDirectory = Join-Path $featuresRoot $Feature }
$SpecDirectory = Resolve-PhysicalPathIdentity -Path $SpecDirectory
$canonicalSpec = Resolve-AiSopWorkspaceChild $WorkspacePath ".ai-workspace/specs/features/$Feature"
if ($SpecDirectory -cne $canonicalSpec) { throw 'TASK_WORKSPACE_MISMATCH' }
$ownerScript = Join-Path $PSScriptRoot 'workflow-owner.ps1'
$ownerPath = Join-Path (Get-AiSopWorkflowOwnerRegistryRoot -WorkspacePath $WorkspacePath) ($Feature.ToLowerInvariant() + '.json')
if ($Operation -eq 'InspectRecovery') { Get-AiSopTaskRecoveryDiagnostics $SpecDirectory $TaskId $WorkspacePath $ownerPath -LogTailLines $LogTailLines | ConvertTo-Json -Depth 12; exit 0 }
$owner = if ($Operation -ne 'Changes' -and (Test-Path -LiteralPath $ownerPath)) { Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json -AsHashtable } else { $null }
if ($Operation -notin @('Verify','Changes')) { $Agent = Resolve-AiSopInvocationAgent $Agent }
$ownerArgs = @{ Feature=$Feature; SpecDirectory=$SpecDirectory; Workflow='SUPERPOWERS'; Agent=$Agent }
if ($PSBoundParameters.ContainsKey('NextAction')) { $ownerArgs.NextAction = $NextAction }
if ($PSBoundParameters.ContainsKey('Notes')) { $ownerArgs.Notes = $Notes }
if ($Operation -eq 'Start') {
    if (-not $TaskId) { $TaskId = 'task-' + [guid]::NewGuid().ToString('N') }
    if ([IO.File]::Exists((Get-AiSopTaskPath $SpecDirectory $TaskId))) { throw 'TASK_ALREADY_EXISTS: Start creates a new TaskId; use Resume to continue the existing task' }
    [IO.Directory]::CreateDirectory($SpecDirectory) | Out-Null
    & $ownerScript -Operation Claim -CreateTaskOnly @ownerArgs -TaskId $TaskId -OwnerId ('task-' + $TaskId) -Tier $Tier -Objective $Objective -CaptureBaseline:$CaptureBaseline
    if ($LASTEXITCODE -ne 0) { throw 'TASK_START_FAILED' }
    Write-Output "TASK_STARTED:$Feature/$TaskId tier=$Tier"
    try { Write-AiSopTaskStartSummary (Read-AiSopTask $SpecDirectory $TaskId) }
    catch { Write-Warning "TASK_START_FEEDBACK_UNAVAILABLE: task was started; use Status to inspect its origin. $($_.Exception.Message)" -WarningAction Continue }
    Write-AiSopFollowUpReminder $WorkspacePath $Feature
    exit 0
}
if (-not $TaskId -and $owner.taskId) { $TaskId = [string]$owner.taskId }
if ($Operation -eq 'Resume' -and -not $TaskId -and $owner -and $owner.status -eq 'ACTIVE') {
    # Legacy adoption is explicit Resume, preserving owner identity and approvals.
    $TaskId = 'legacy-' + [guid]::NewGuid().ToString('N')
    $legacyState = Join-Path $SpecDirectory 'feature-state.json'
    if (-not $PSBoundParameters.ContainsKey('Tier') -and (Test-Path -LiteralPath $legacyState)) {
        $Tier = (Get-Content -LiteralPath $legacyState -Raw | ConvertFrom-Json).tier
    }
    if (-not $PSBoundParameters.ContainsKey('Tier') -and -not (Test-Path -LiteralPath $legacyState)) { throw 'LEGACY_TIER_REQUIRED: inspect original scope and explicitly select its tier before adoption.' }
    if ($Tier -notin @('T1','T2','T3')) { throw 'LEGACY_TIER_REQUIRED: original tier is not T1/T2/T3; select the intended tier explicitly for adoption' }
    if (-not $Objective) { $Objective = "Continue existing feature $Feature" }
    & $ownerScript -Operation Transfer @ownerArgs -OwnerId $owner.ownerId -TaskId $TaskId -Tier $Tier -Objective $Objective -ConfirmTakeover:$ConfirmTakeover | Where-Object { $_ -cne $ownerPath -and $_ -cne 'VALID' }
    if ($LASTEXITCODE -ne 0) { throw 'TASK_ADOPTION_FAILED' }
    Write-AiSopTaskOperationResult Resume $Feature $TaskId $Tier
    Write-AiSopFollowUpReminder $WorkspacePath $Feature
    exit 0
}
if (-not $TaskId) { throw 'TASK_SELECTION_REQUIRED: use Discover and select an existing task; no implicit takeover.' }
$task = Read-AiSopTask $SpecDirectory $TaskId
if ($Operation -eq 'Changes') { Get-AiSopTaskChanges $task $WorkspacePath | ConvertTo-Json -Depth 12; exit 0 }
$ownerArgs.OwnerId = $task.ownerId
$ownerArgs.TaskId = $TaskId
if ($Operation -eq 'Recover') {
    & $ownerScript -Operation Recover @ownerArgs -ForceRecovery:$ForceRecovery -QuarantineInvalidEvidence:$QuarantineInvalidEvidence -RecoveryReason $Reason
    exit $LASTEXITCODE
}
if ($Operation -eq 'Resume') {
    if ($PSBoundParameters.ContainsKey('Objective') -and $Objective -cne $task.objective) { throw 'RESUME_OBJECTIVE_MISMATCH: Resume preserves the existing objective; Start a new TaskId for independent work' }
    if ($PSBoundParameters.ContainsKey('Tier') -and $Tier -cne $task.tier) { throw 'TASK_TIER_CHANGE_REQUIRES_EXPLICIT_OPERATION: Resume preserves the original tier; use ChangeTier after resuming' }
    if (@($task.verifications | Where-Object { $_.outcome -eq 'RUNNING' }).Count) { throw 'RUN_UNFINISHED: inspect Status and Recover after execution stops' }
    if ($task.status -eq 'PAUSED') {
        & $ownerScript -Operation Claim @ownerArgs -Tier $task.tier -Objective $task.objective | Where-Object { $_ -cne $ownerPath -and $_ -cne 'VALID' }
    } elseif ($task.status -eq 'ACTIVE' -and $owner -and $owner.status -eq 'ACTIVE' -and $owner.taskId -ceq $TaskId) {
        $native = Get-AiSopInvocationSessionId $Agent
        $sameSession = $native -and ((Get-AiSopWorkflowSessionKey -Agent $Agent -NativeSessionId $native -WorkspacePath $WorkspacePath) -ceq $owner.sessionBinding.sessionKey)
        if ($sameSession) {
            $boundSession = Get-AiSopWorkflowSession -SessionKey $owner.sessionBinding.sessionKey -WorkspacePath $WorkspacePath
            if ($boundSession.EffectiveStatus -in @('ENDED','EXPIRED')) { & $ownerScript -Operation RebindSession @ownerArgs | Where-Object { $_ -cne $ownerPath -and $_ -cne 'VALID' } }
            else { & $ownerScript -Operation Validate @ownerArgs | Where-Object { $_ -cne $ownerPath -and $_ -cne 'VALID' } }
        } else { & $ownerScript -Operation Transfer @ownerArgs -ConfirmTakeover:$ConfirmTakeover | Where-Object { $_ -cne $ownerPath -and $_ -cne 'VALID' } }
    } else { throw 'TASK_NOT_RESUMABLE: terminal task or missing local ownership; inspect/recover ownership before resuming.' }
    if ($LASTEXITCODE -ne 0) { throw 'TASK_RESUME_FAILED' }
    Write-AiSopTaskOperationResult Resume $Feature $TaskId $task.tier
    Write-AiSopFollowUpReminder $WorkspacePath $Feature
    exit 0
}
if ($Operation -in @('ChangeTier','RecordSync','SetApplicability','AddFollowUp','CloseFollowUp','ReopenFollowUp','SetBaseline','SetCaseScope')) {
    $update = switch ($Operation) {
        'SetBaseline' { @{operation=$Operation;inputsRef=$BaselineInputsRef;reason=$Reason} }
        'SetCaseScope' { @{operation=$Operation;caseIds=@($CaseIds);reason=$Reason} }
        'ChangeTier' {
            if (-not $PSBoundParameters.ContainsKey('Tier')) { throw 'TASK_UPDATE_REQUIRED:tier' }
            @{ operation=$Operation; tier=$Tier; reason=$Reason; userRequest=$UserRequest }
        }
        'RecordSync' { @{ operation=$Operation; documentation=$Documentation; tests=$Tests; summary=$Summary } }
        'SetApplicability' { @{ operation=$Operation; kind=$Kind; status=$Applicability; reason=$Reason } }
        'AddFollowUp' { @{ operation=$Operation; id=$FollowUpId; kind=$FollowUpKind; summary=$Summary; scope=@($Scope) } }
        'CloseFollowUp' { @{ operation=$Operation; sourceTaskId=$SourceTaskId; id=$FollowUpId; status=$Disposition; resolution=$Resolution; userRequest=$UserRequest } }
        'ReopenFollowUp' { @{ operation=$Operation; sourceTaskId=$SourceTaskId; id=$FollowUpId; reason=$Reason } }
    }
    & $ownerScript -Operation Checkpoint @ownerArgs -TaskUpdateJson (ConvertTo-Json -InputObject $update -Depth 8 -Compress)
    if ($LASTEXITCODE -ne 0) { throw 'TASK_POLICY_UPDATE_FAILED' }
    Write-Output "TASK_POLICY_UPDATED:$Operation"
    exit 0
}
if ($Operation -eq 'ReviewImpact') {
    & $ownerScript -Operation Checkpoint @ownerArgs -ImpactReviewed
    exit $LASTEXITCODE
}
if ($Operation -in @('Checkpoint','Suspend','Cancel','Complete')) {
    if ($Operation -eq 'Checkpoint') { & $ownerScript -Operation $Operation @ownerArgs; exit $LASTEXITCODE }
    & $ownerScript -Operation $Operation @ownerArgs | Where-Object { $_ -cne $ownerPath -and $_ -cne 'VALID' }
    $operationExit=$LASTEXITCODE
    if ($operationExit -eq 0) { Write-AiSopTaskOperationResult $Operation $Feature $TaskId $task.tier }
    exit $operationExit
}
if ($Operation -eq 'Verify') {
    & (Join-Path $PSScriptRoot 'workflow-state.ps1') -Operation VerifyCompletion -Path (Resolve-AiSopTaskWorkflowStatePath $SpecDirectory) -TaskId $TaskId
    exit $LASTEXITCODE
}
if ($Operation -eq 'RetryEvidence') {
    $pendingPath = Get-AiSopRunEvidencePath $SpecDirectory $TaskId $RunId
    if (-not [IO.File]::Exists($pendingPath)) { throw 'RUN_PENDING_RESULT_NOT_FOUND' }
    & $ownerScript -Operation Checkpoint @ownerArgs -EvidencePath $pendingPath -RetryEvidence | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'EVIDENCE_CHECKPOINT_FAILED' }
    Remove-Item -LiteralPath $pendingPath
    Write-Output "RUN_EVIDENCE_SAVED:$RunId (command was not rerun)"
    exit 0
}
# Profiles are project-owned command definitions, never engine-specific builds.
$profileInfo = $null
if ($Profile) {
    foreach ($name in @('Executable','Arguments','Kind','Batch','CaseIds','JUnitReports','CaseMap')) {
        if ($PSBoundParameters.ContainsKey($name)) { throw "PROFILE_OVERRIDE_FORBIDDEN: $name; use an explicit command instead" }
    }
    $profileInfo = Get-AiSopVerificationProfile $WorkspacePath $Profile
    $definition = $profileInfo.command
    $Executable = $definition.executable; $Arguments = @($definition.arguments); $Kind = $definition.kind
    $Batch = if ($definition.batch) { $definition.batch } else { $Profile }
    $CaseIds = @($definition.caseIds)
    $JUnitReports = @($definition.junitReports | Where-Object { $null -ne $_ }); $CaseMap = $definition.caseMap
    if (-not $PSBoundParameters.ContainsKey('TimeoutSeconds') -and $definition.timeoutSeconds) { $TimeoutSeconds = $definition.timeoutSeconds }
}
if (-not $Executable -or -not $Kind) { throw 'RUN_REQUIRES_EXECUTABLE_AND_KIND' }
$junit = Get-AiSopJUnitConfiguration $WorkspacePath $JUnitReports $CaseMap
if ($junit) {
    if ($Kind -ne 'test') { throw 'JUNIT_TEST_ONLY' }
    if (@($CaseIds | Where-Object { $_ }).Count) { throw 'JUNIT_CASE_IDS_FROM_MAP: omit CaseIds when using a report map' }
    $CaseIds = @($junit.cases.id)
}
if ($Batch -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$') { throw 'BATCH_ID_INVALID' }
& $ownerScript -Operation Validate @ownerArgs | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'TASK_OWNER_INVALID' }
$runOwner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json -AsHashtable
$before = Get-AiSopInputSnapshot $WorkspacePath
$bindSpecs = $task.tier -eq 'T3' -and $Kind -eq 'test'
$specBefore = if ($bindSpecs) { Get-AiSopTaskSpecDigest $SpecDirectory } else { $null }
$runId = [guid]::NewGuid().ToString('N')
$taskDir = Split-Path -Parent (Get-AiSopTaskPath $SpecDirectory $TaskId)
$context = @{
    protocol='2'; taskId=$TaskId; ownerId=$task.ownerId
    sessionKey=$runOwner.sessionBinding.sessionKey; sessionEpochId=$runOwner.sessionBinding.sessionEpochId
    workspace=$WorkspacePath; runnerMachine=[Environment]::MachineName; runnerPid=[string]$PID
    runnerStartedAt=[Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o')
    engineScriptHash=(Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant(); logPath=".ai-workspace/.runtime/verification/$Feature/$TaskId/$runId.log"
    timeoutSeconds=[string]$TimeoutSeconds
}
if ($junit) {
    $junitBefore=@{}
    foreach ($relative in $junit.reports) { $junitBefore[$relative]=Get-AiSopJUnitFileIdentity (Resolve-AiSopWorkspaceChild $WorkspacePath $relative) }
    $context.junitConfiguration=ConvertTo-AiSopWorkflowCanonicalJson $junit
    $context.junitBefore=ConvertTo-AiSopWorkflowCanonicalJson $junitBefore
}
if ($profileInfo) { $context.profile=$Profile; $context.profileDigest=$profileInfo.digest; $context.profileDigestAlgorithm=$profileInfo.digestAlgorithm }
$git=@(Get-Command git -CommandType Application -ErrorAction SilentlyContinue)[0]
foreach ($repo in @(@{name='code';path=$WorkspacePath}, @{name='context';path=(Join-Path $WorkspacePath '.ai-workspace')}, @{name='spec';path=$SpecDirectory})) {
    if ($git -and (Test-Path -LiteralPath $repo.path -PathType Container)) {
        $gitRoot=Invoke-AiSopMetadataProbe $git.Source @('-C',$repo.path,'rev-parse','--show-toplevel')
        $probe=$gitRoot
        if ($gitRoot.exitCode -eq 0) {
            $context[$repo.name + 'GitRoot'] = Resolve-PhysicalPathIdentity -Path $gitRoot.output
            $probe=Invoke-AiSopMetadataProbe $git.Source @('-C',$repo.path,'rev-parse','HEAD')
            if ($probe.exitCode -eq 0) { $context[$repo.name + 'GitRevision'] = $probe.output }
        }
        if ($probe.diagnostic) {
            $context[$repo.name + 'GitMetadata']='UNAVAILABLE'
            Write-Warning "GIT_METADATA_UNAVAILABLE: $($repo.name); $($probe.diagnostic); verification will continue without a revision annotation"
        }
    }
}
if (Test-Path -LiteralPath (Join-Path $WorkspacePath '.svn')) {
    $svn = @(Get-Command svn -CommandType Application -ErrorAction SilentlyContinue)[0]
    if ($svn) {
        $revision=Invoke-AiSopMetadataProbe $svn.Source @('info','--non-interactive','--show-item','revision',$WorkspacePath)
        if ($revision.exitCode -eq 0) { $context.codeSvnRevision = $revision.output }
        else { $context.codeSvnMetadata='UNAVAILABLE'; Write-Warning "SVN_METADATA_UNAVAILABLE: $($revision.diagnostic); verification will continue without a revision annotation" }
    } else { $context.codeSvnMetadata='CLI_MISSING'; Write-Warning 'SVN_CLI_MISSING: verification will continue without a revision annotation' }
}
$launchError = $null
try { $context.executable = Resolve-AiSopRunExecutable $Executable $WorkspacePath }
catch { $launchError = $_.Exception.Message; $context.executable = $Executable }
$record = @{
    runId=$runId; outcome='RUNNING'; kind=$Kind; batch=$Batch; command=(@($Executable) + $Arguments | ConvertTo-Json -Compress)
    exitCode=-2; executedAt=[DateTimeOffset]::UtcNow.ToString('o'); inputDigest=$before.digest
    context=$context; inputsRef=(Save-AiSopInputManifest $before $WorkspacePath); inputsStable=$false; caseIds=@($CaseIds | Where-Object { $_ } | Sort-Object -Unique)
}
if ($bindSpecs) { $record.specDigest=$specBefore }
$context.definitionDigest = Get-AiSopRunDefinitionDigest $record
$previousBatch = @($task.verifications | Where-Object { $_.kind -ceq $Kind -and $_.batch -ceq $Batch })
if ($previousBatch.Count -and (Get-AiSopRunDefinitionDigest $previousBatch[-1]) -cne $context.definitionDigest) {
    if ([string]::IsNullOrWhiteSpace($Reason)) { throw 'BATCH_DEFINITION_CHANGED: keep the command and case scope, or supply -Reason for an intentional replacement' }
    $context.batchChangeReason = $Reason; $context.previousRunId = [string]$previousBatch[-1].runId
}
function Save-RunEvidence {
    param([Nullable[DateTimeOffset]]$DeadlineUtc)
    $recordPath = Get-AiSopRunEvidencePath $SpecDirectory $TaskId $runId
    # Durable before checkpoint. Keep the result on any commit/transport failure;
    # RetryEvidence or Recover can finish the same run without executing it again.
    Write-AiSopWorkflowTextAtomic -Path $recordPath -Text (ConvertTo-AiSopWorkflowCanonicalJson $record)
    & $ownerScript -Operation Checkpoint @ownerArgs -EvidencePath $recordPath -DeadlineUtc $DeadlineUtc | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "EVIDENCE_CHECKPOINT_FAILED: pending result at $recordPath" }
    Remove-Item -LiteralPath $recordPath
}
$lease = @{ expiresAt=[DateTimeOffset]::MinValue; nextCheckAt=[DateTimeOffset]::MinValue; retryUntil=$null; attempt=0; checkpointPending=$false }
function Update-RunLease {
    try {
        $now=[DateTimeOffset]::UtcNow
        if ($lease.retryUntil -and $now -ge $lease.retryUntil) { throw 'RUN_LEASE_RETRY_EXHAUSTED' }
        $deadline=$now.AddSeconds(3)
        if ($lease.expiresAt -ne [DateTimeOffset]::MinValue -and $lease.expiresAt -lt $deadline) { $deadline=$lease.expiresAt }
        if ($lease.retryUntil -and $lease.retryUntil -lt $deadline) { $deadline=$lease.retryUntil }
        $bound = Get-AiSopWorkflowSession -SessionKey $context.sessionKey -WorkspacePath $WorkspacePath -DeadlineUtc $deadline
        if ($bound.EffectiveStatus -ne 'ACTIVE' -or $bound.Record.sessionEpochId -cne $context.sessionEpochId -or
            $bound.Record.boundOwnerId -cne $task.ownerId -or $bound.Record.boundFeature -cne $Feature) { throw 'RUN_SESSION_LOST: the original session is no longer active and bound' }
        $lease.expiresAt=[DateTimeOffset]::Parse($bound.Record.expiresAt)
        if ([DateTimeOffset]::UtcNow -ge $lease.expiresAt) { throw 'RUN_SESSION_LOST: original lease expired' }
        if ($lease.expiresAt -lt $deadline) { $deadline=$lease.expiresAt }
        if ($lease.checkpointPending -or $lease.expiresAt -le [DateTimeOffset]::UtcNow.AddMinutes(5)) {
            Save-RunEvidence -DeadlineUtc $deadline
            $lease.checkpointPending=$false
            # Read the committed expiry; never infer that a failed save renewed it.
            $bound=Get-AiSopWorkflowSession -SessionKey $context.sessionKey -WorkspacePath $WorkspacePath -DeadlineUtc $deadline
            if ($bound.EffectiveStatus -ne 'ACTIVE' -or $bound.Record.sessionEpochId -cne $context.sessionEpochId -or
                $bound.Record.boundOwnerId -cne $task.ownerId -or $bound.Record.boundFeature -cne $Feature) { throw 'RUN_SESSION_LOST: binding changed during renewal' }
            $lease.expiresAt=[DateTimeOffset]::Parse($bound.Record.expiresAt)
        }
        $lease.attempt=0; $lease.retryUntil=$null
        $lease.nextCheckAt=[DateTimeOffset]::UtcNow.AddSeconds(5)
    } catch {
        $failure=$_.Exception.Message; $now=[DateTimeOffset]::UtcNow
        # Only transient lock/deadline contention is retryable. A lost identity,
        # invalid evidence, IO error or expired lease must stop the child.
        if ($failure -match '(^|[:\s])WORKFLOW_(LOCK_TIMEOUT|DEADLINE_EXCEEDED)(?=$|[:\s])' -and $now -lt $lease.expiresAt) {
            if (-not $lease.retryUntil) { $lease.retryUntil=$now.AddSeconds(30) }
            if ($lease.expiresAt -lt $lease.retryUntil) { $lease.retryUntil=$lease.expiresAt }
            if ($now -lt $lease.retryUntil) {
                $lease.attempt++
                $lease.nextCheckAt=$now.AddSeconds([Math]::Min(5,[Math]::Pow(2,[Math]::Min($lease.attempt-1,3))))
                $message="RUN_LEASE_RETRY: attempt=$($lease.attempt); retryUntil=$($lease.retryUntil.ToString('o')); $failure"
                $writer.WriteLine($message); Write-Host $message
                return
            }
        }
        throw "RUN_CONTROL_INTERRUPTED: $failure"
    }
}
# Prepare the log before registering RUNNING: an unwritable log must not leave
# an attempt that never launched. Registration still precedes Process.Start.
$writer=$null; $logStream=$null
try {
$logPath = Get-AiSopRunLogPath $record $WorkspacePath $SpecDirectory $TaskId
$runtimeIgnore = Resolve-AiSopWorkspaceChild $WorkspacePath '.ai-workspace/.runtime/.gitignore'
if (-not [IO.File]::Exists($runtimeIgnore)) { Write-AiSopWorkflowTextAtomic -Path $runtimeIgnore -Text "*`n" }
[IO.Directory]::CreateDirectory((Split-Path -Parent $logPath)) | Out-Null
$logStream = [IO.FileStream]::new($logPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
$writer = [IO.StreamWriter]::new($logStream, [Text.UTF8Encoding]::new($false)); $writer.AutoFlush = $true
} catch {
    $logFailure=$_.Exception.Message
    $resource=if ($writer) { $writer } else { $logStream }
    $cleanup=Invoke-AiSopProcessCleanup -Started $false -Resources @($resource)
    throw "RUN_LOG_UNAVAILABLE: $logFailure; $($cleanup.diagnostic)"
}
try { Save-RunEvidence; Update-RunLease } catch {
    $cleanup=Invoke-AiSopProcessCleanup -Started $false -Resources @($writer)
    if ($cleanup.diagnostic) { Write-Warning $cleanup.diagnostic }
    throw
}
$process = [Diagnostics.Process]::new()
$info = $process.StartInfo
$info.WorkingDirectory=$WorkspacePath; $info.UseShellExecute=$false; $info.CreateNoWindow=$true
$info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
foreach ($arg in $Arguments) { $info.ArgumentList.Add($arg) }
$started=$false; $finished=$false; $stopwatch=[Diagnostics.Stopwatch]::StartNew()
$exitObservedAt=$null; $nextHeartbeatAt=30
try {
    if ($launchError) { throw $launchError }
    $info.FileName = $context.executable
    $started = $process.Start()
    if (-not $started) { throw 'VERIFICATION_START_FAILED' }
    $context.childPid=[string]$process.Id
    $context.childStartedAt=$process.StartTime.ToUniversalTime().ToString('o')
    $lease.checkpointPending=$true; $lease.nextCheckAt=[DateTimeOffset]::MinValue
    $pipes = @(
        @{ reader=$process.StandardOutput; buffer=[char[]]::new(2048); pending=$null; ended=$false },
        @{ reader=$process.StandardError; buffer=[char[]]::new(2048); pending=$null; ended=$false }
    )
    while ($true) {
        $now=[DateTimeOffset]::UtcNow
        if (-not $process.HasExited -and ($now -ge $lease.nextCheckAt -or $now -ge $lease.expiresAt -or ($lease.retryUntil -and $now -ge $lease.retryUntil))) {
            Update-RunLease
        }
        if ($TimeoutSeconds -gt 0 -and $stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            $record.outcome='TIMED_OUT'; $record.exitCode=124
            $record.diagnostic="VERIFICATION_TIMED_OUT: exceeded $($TimeoutSeconds)s; terminating child process tree"
            $writer.WriteLine($record.diagnostic); Write-Host $record.diagnostic
            break
        }
        foreach ($pipe in $pipes) {
            if ($pipe.ended) { continue }
            if (-not $pipe.pending) { $pipe.pending=$pipe.reader.ReadAsync($pipe.buffer, 0, $pipe.buffer.Length) }
            if ($pipe.pending.IsCompleted) {
                $count=$pipe.pending.GetAwaiter().GetResult(); $pipe.pending=$null
                if ($count -eq 0) { $pipe.ended=$true; continue }
                $chunk=[string]::new($pipe.buffer, 0, $count)
                $writer.Write($chunk); Write-Host -NoNewline $chunk
            }
        }
        if ($process.HasExited -and @($pipes | Where-Object { -not $_.ended }).Count -eq 0) {
            $record.exitCode=$process.ExitCode
            $record.outcome=if ($process.ExitCode -eq 0) { 'PASSED' } else { 'FAILED' }
            break
        }
        if ($process.HasExited) {
            if ($null -eq $exitObservedAt) { $exitObservedAt=$stopwatch.Elapsed.TotalSeconds }
            if ($stopwatch.Elapsed.TotalSeconds - $exitObservedAt -ge 5) { throw 'OUTPUT_DRAIN_TIMED_OUT: child exited but inherited output pipes remained open; reparented descendant cleanup is unconfirmed' }
        }
        if ($stopwatch.Elapsed.TotalSeconds -ge $nextHeartbeatAt) {
            $limit=if ($TimeoutSeconds) { "$($TimeoutSeconds)s" } else { 'unlimited (set -TimeoutSeconds to bound this command)' }
            Write-Host "VERIFICATION_WAIT: $Feature/$TaskId $Kind/$Batch pid=$($process.Id) elapsed=$([int]$stopwatch.Elapsed.TotalSeconds)s limit=$limit log=$logPath"
            $nextHeartbeatAt=$stopwatch.Elapsed.TotalSeconds + 30
        }
        [Threading.Thread]::Sleep(50)
    }
    $finished=$true
} catch {
    $controlInterrupted=$_.Exception.Message.StartsWith('RUN_CONTROL_INTERRUPTED:')
    $record.exitCode=if ($controlInterrupted) { -2 } else { -1 }
    $record.outcome=if ($controlInterrupted) { 'INTERRUPTED' } else { 'FAILED' }
    $record.diagnostic=$_.Exception.Message
    $message=if ($controlInterrupted) { $record.diagnostic } else { 'VERIFICATION_FAILED: ' + $record.diagnostic }
    $writer.WriteLine($message); Write-Host $message
} finally {
    if (-not $finished -and $record.outcome -eq 'RUNNING') { $record.outcome='INTERRUPTED'; $record.exitCode=-2 }
    # Preserve failure before cleanup; RetryEvidence/Recover can see it even
    # if the host is interrupted while disposing native process resources.
    try {
        if ($record.outcome -ne 'PASSED') {
            Write-AiSopWorkflowTextAtomic -Path (Get-AiSopRunEvidencePath $SpecDirectory $TaskId $runId) -Text (ConvertTo-AiSopWorkflowCanonicalJson $record)
        }
    } catch {
        $record.diagnostic=(@($record.diagnostic,"PRE_CLEANUP_EVIDENCE_SAVE_FAILED: $($_.Exception.Message)") | Where-Object { $_ }) -join '; '
    }
    $cleanup=Invoke-AiSopProcessCleanup -Process $process -Started $started -Resources @($writer)
    if ($cleanup.diagnostic) {
        $record.diagnostic=(@($record.diagnostic,$cleanup.diagnostic) | Where-Object { $_ }) -join '; '
        if ($record.outcome -eq 'PASSED') { $record.outcome='FAILED'; $record.exitCode=1 }
        Write-Host $cleanup.diagnostic
        try {
            Write-AiSopWorkflowTextAtomic -Path (Get-AiSopRunEvidencePath $SpecDirectory $TaskId $runId) -Text (ConvertTo-AiSopWorkflowCanonicalJson $record)
        } catch {
            $record.diagnostic+="; CLEANUP_EVIDENCE_SAVE_FAILED: $($_.Exception.Message)"
        }
    }
    $inputDiagnostics=@()
    try {
        $after=Get-AiSopInputSnapshot $WorkspacePath
        $record.inputsStable=$before.digest -ceq $after.digest
        $inputDiagnostics+=@(Get-AiSopRunInputDiagnostics $before $after)
    } catch {
        $record.inputsStable=$false
        $inputDiagnostics+="INPUT_SNAPSHOT_UNAVAILABLE: $($_.Exception.Message)"
    }
    if ($bindSpecs) {
        try {
            if ($specBefore -cne (Get-AiSopTaskSpecDigest $SpecDirectory)) {
                $record.inputsStable=$false
                $inputDiagnostics+='SPEC_CHANGED_DURING_RUN: T3 requirement/design/test-definition changed'
            }
        } catch {
            $record.inputsStable=$false
            $inputDiagnostics+="SPEC_SNAPSHOT_UNAVAILABLE: $($_.Exception.Message)"
        }
    }
    if (-not $record.inputsStable) { $record.outcome='FAILED'; if ($record.exitCode -eq 0) { $record.exitCode=1 } }
    if ($inputDiagnostics.Count) {
        $record.diagnostic=(@($record.diagnostic)+$inputDiagnostics | Where-Object { $_ }) -join '; '
        foreach ($diagnostic in $inputDiagnostics) { Write-Host $diagnostic }
    }
    $definitionProblems=@(Get-AiSopRunDefinitionProblems $record $WorkspacePath)
    if ($definitionProblems.Count) {
        $record.diagnostic=(@($record.diagnostic)+$definitionProblems | Where-Object { $_ }) -join '; '
        $record.inputsStable=$false
        if ($record.outcome -eq 'PASSED') { $record.outcome='FAILED'; $record.exitCode=1 }
        Write-Host $record.diagnostic
    }
    if ($junit) {
        try { $record.reportEvidence=Read-AiSopJUnitEvidence $junit $junitBefore $WorkspacePath }
        catch {
            $record.diagnostic=(@($record.diagnostic,$_.Exception.Message) | Where-Object { $_ }) -join '; '
            if ($record.outcome -eq 'PASSED') { $record.outcome='FAILED'; $record.exitCode=1 }
            Write-Host $record.diagnostic
        }
    }
    Save-RunEvidence
}
Write-Output "RUN_RESULT:$($record.outcome) exit=$($record.exitCode) log=$logPath"
if (-not $record.inputsStable) { throw 'INPUTS_CHANGED_DURING_RUN: verification inputs/definitions changed or could not be read; see the diagnostics above and the saved run record' }
exit $record.exitCode
