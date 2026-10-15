#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Discover','Status','FollowUps','Recover','Start','Resume','Checkpoint','Suspend','Cancel','Run','RetryEvidence','ReviewImpact','Verify','Complete','ChangeTier','RecordSync','SetApplicability','AddFollowUp','CloseFollowUp')][string]$Operation,
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
    [string]$Resolution
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'task-context.ps1')
. (Join-Path $PSScriptRoot 'workflow-session.ps1')
$WorkspacePath = Resolve-PhysicalPathIdentity -Path $WorkspacePath
$featuresRoot = Join-Path $WorkspacePath '.ai-workspace/specs/features'
if ($Operation -eq 'FollowUps') {
    $items = @(Get-AiSopPendingFollowUps $WorkspacePath | Where-Object { (-not $Feature -or $_.feature -ceq $Feature) -and (-not $TaskId -or $_.taskId -ceq $TaskId) })
    @{ pendingFollowUps=$items; count=$items.Count; blocking=$false } | ConvertTo-Json -Depth 8
    exit 0
}
if ($Operation -in @('Discover','Status')) {
    if (-not $Feature -and $SpecDirectory) { $Feature = Split-Path -Leaf $SpecDirectory }
    if ($Feature -and $Feature -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9_-])?$') { throw 'FEATURE_INVALID' }
    $dirs = @(Get-ChildItem -LiteralPath $featuresRoot -Directory -ErrorAction SilentlyContinue | Where-Object { -not $Feature -or $_.Name -ceq $Feature })
    if ($SpecDirectory -and (Resolve-PhysicalPathIdentity $SpecDirectory) -cne (Resolve-PhysicalPathIdentity (Join-Path $featuresRoot $Feature))) { throw 'TASK_WORKSPACE_MISMATCH' }
    foreach ($dir in $dirs) {
        $records = @(Get-ChildItem -LiteralPath (Join-Path $dir.FullName 'tasks') -Directory -ErrorAction SilentlyContinue | Where-Object { -not $TaskId -or $_.Name -ceq $TaskId })
        foreach ($entry in $records) {
            try {
                $task = Read-AiSopTask $dir.FullName $entry.Name
                Get-AiSopTaskSummary $task $WorkspacePath $dir.FullName -CheckInputs:($Operation -eq 'Status') | ConvertTo-Json -Depth 12 -Compress
            } catch { @{ feature=$dir.Name; taskId=$entry.Name; status='CORRUPT'; diagnostic=$_.Exception.Message } | ConvertTo-Json -Compress }
        }
        if (-not $records.Count) {
            @{ feature=$dir.Name; taskId=$TaskId; status=$(if ($TaskId) { 'NOT_FOUND' } else { 'LEGACY' }); recordedApprovals=(Get-AiSopRecordedApprovals $dir.FullName); suggestedAction='Inspect existing ownership and approvals; Start independent work or Resume the legacy task.' } | ConvertTo-Json -Depth 5 -Compress
        }
    }
    if (-not $dirs.Count) { @{ feature=$Feature; taskId=$TaskId; status='NOT_FOUND'; suggestedAction='Start a task with an explicit feature and objective.' } | ConvertTo-Json -Compress }
    $syncWarning = Get-AiSopSpecSyncWarning $WorkspacePath
    if ($syncWarning) { Write-Warning $syncWarning }
    exit 0
}
if (-not $Feature -and $SpecDirectory) { $Feature = Split-Path -Leaf $SpecDirectory }
if ($Feature -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9_-])?$') { throw 'FEATURE_REQUIRED' }
if (-not $SpecDirectory) { $SpecDirectory = Join-Path $featuresRoot $Feature }
$SpecDirectory = Resolve-PhysicalPathIdentity -Path $SpecDirectory
$canonicalSpec = Resolve-PhysicalPathIdentity -Path (Join-Path $featuresRoot $Feature)
if ($SpecDirectory -cne $canonicalSpec) { throw 'TASK_WORKSPACE_MISMATCH' }
$ownerScript = Join-Path $PSScriptRoot 'workflow-owner.ps1'
$ownerPath = Join-Path (Get-AiSopWorkflowOwnerRegistryRoot -WorkspacePath $WorkspacePath) ($Feature.ToLowerInvariant() + '.json')
$owner = if (Test-Path -LiteralPath $ownerPath) { Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json -AsHashtable } else { $null }
if ($Operation -ne 'Verify') { $Agent = Resolve-AiSopInvocationAgent $Agent }
$ownerArgs = @{ Feature=$Feature; SpecDirectory=$SpecDirectory; Workflow='SUPERPOWERS'; Agent=$Agent }
if ($PSBoundParameters.ContainsKey('NextAction')) { $ownerArgs.NextAction = $NextAction }
if ($PSBoundParameters.ContainsKey('Notes')) { $ownerArgs.Notes = $Notes }
if ($Operation -eq 'Start') {
    if (-not $TaskId) { $TaskId = 'task-' + [guid]::NewGuid().ToString('N') }
    [IO.Directory]::CreateDirectory($SpecDirectory) | Out-Null
    & $ownerScript -Operation Claim @ownerArgs -TaskId $TaskId -OwnerId ('task-' + $TaskId) -Tier $Tier -Objective $Objective
    if ($LASTEXITCODE -ne 0) { throw 'TASK_START_FAILED' }
    Write-Output "TASK_STARTED:$Feature/$TaskId tier=$Tier"
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
    if (-not $Objective) { $Objective = "Continue existing feature $Feature" }
    & $ownerScript -Operation Transfer @ownerArgs -OwnerId $owner.ownerId -TaskId $TaskId -Tier $Tier -Objective $Objective -ConfirmTakeover:$ConfirmTakeover
    if ($LASTEXITCODE -ne 0) { throw 'TASK_ADOPTION_FAILED' }
    Write-AiSopFollowUpReminder $WorkspacePath $Feature
    exit 0
}
if (-not $TaskId) { throw 'TASK_SELECTION_REQUIRED: use Discover and select an existing task; no implicit takeover.' }
$task = Read-AiSopTask $SpecDirectory $TaskId
$ownerArgs.OwnerId = $task.ownerId
$ownerArgs.TaskId = $TaskId
if ($Operation -eq 'Recover') {
    & $ownerScript -Operation Recover @ownerArgs -ForceRecovery:$ForceRecovery
    exit $LASTEXITCODE
}
if ($Operation -eq 'Resume') {
    if ($PSBoundParameters.ContainsKey('Tier') -and $Tier -cne $task.tier) { throw 'TASK_TIER_CHANGE_REQUIRES_EXPLICIT_OPERATION: Resume preserves the original tier; use ChangeTier after resuming' }
    if (@($task.verifications | Where-Object { $_.outcome -eq 'RUNNING' }).Count) { throw 'RUN_UNFINISHED: inspect Status and Recover after execution stops' }
    if ($task.status -eq 'PAUSED') {
        & $ownerScript -Operation Claim @ownerArgs -Tier $task.tier -Objective $task.objective
    } elseif ($task.status -eq 'ACTIVE' -and $owner -and $owner.status -eq 'ACTIVE' -and $owner.taskId -ceq $TaskId) {
        $native = Get-AiSopInvocationSessionId $Agent
        $sameSession = $native -and ((Get-AiSopWorkflowSessionKey -Agent $Agent -NativeSessionId $native -WorkspacePath $WorkspacePath) -ceq $owner.sessionBinding.sessionKey)
        if ($sameSession) {
            $boundSession = Get-AiSopWorkflowSession -SessionKey $owner.sessionBinding.sessionKey -WorkspacePath $WorkspacePath
            if ($boundSession.EffectiveStatus -in @('ENDED','EXPIRED')) { & $ownerScript -Operation RebindSession @ownerArgs }
            else { & $ownerScript -Operation Validate @ownerArgs }
        } else { & $ownerScript -Operation Transfer @ownerArgs -ConfirmTakeover:$ConfirmTakeover }
    } else { throw 'TASK_NOT_RESUMABLE: terminal task or missing local ownership; inspect/recover ownership before resuming.' }
    if ($LASTEXITCODE -ne 0) { throw 'TASK_RESUME_FAILED' }
    Write-AiSopFollowUpReminder $WorkspacePath $Feature
    exit 0
}
if ($Operation -in @('ChangeTier','RecordSync','SetApplicability','AddFollowUp','CloseFollowUp')) {
    $update = switch ($Operation) {
        'ChangeTier' {
            if (-not $PSBoundParameters.ContainsKey('Tier')) { throw 'TASK_UPDATE_REQUIRED:tier' }
            @{ operation=$Operation; tier=$Tier; reason=$Reason; userRequest=$UserRequest }
        }
        'RecordSync' { @{ operation=$Operation; documentation=$Documentation; tests=$Tests; summary=$Summary } }
        'SetApplicability' { @{ operation=$Operation; kind=$Kind; status=$Applicability; reason=$Reason } }
        'AddFollowUp' { @{ operation=$Operation; id=$FollowUpId; kind=$FollowUpKind; summary=$Summary; scope=@($Scope) } }
        'CloseFollowUp' { @{ operation=$Operation; sourceTaskId=$SourceTaskId; id=$FollowUpId; status=$Disposition; resolution=$Resolution; userRequest=$UserRequest } }
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
    & $ownerScript -Operation $Operation @ownerArgs
    exit $LASTEXITCODE
}
if ($Operation -eq 'Verify') {
    & (Join-Path $PSScriptRoot 'workflow-state.ps1') -Operation VerifyCompletion -Path (Join-Path $SpecDirectory '00_workflow_state.json') -TaskId $TaskId
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
    foreach ($name in @('Executable','Arguments','Kind','Batch','CaseIds')) {
        if ($PSBoundParameters.ContainsKey($name)) { throw "PROFILE_OVERRIDE_FORBIDDEN: $name; use an explicit command instead" }
    }
    $profileInfo = Get-AiSopVerificationProfile $WorkspacePath $Profile
    $definition = $profileInfo.command
    $Executable = $definition.executable; $Arguments = @($definition.arguments); $Kind = $definition.kind
    $Batch = if ($definition.batch) { $definition.batch } else { $Profile }
    $CaseIds = @($definition.caseIds)
    if (-not $PSBoundParameters.ContainsKey('TimeoutSeconds') -and $definition.timeoutSeconds) { $TimeoutSeconds = $definition.timeoutSeconds }
}
if (-not $Executable -or -not $Kind) { throw 'RUN_REQUIRES_EXECUTABLE_AND_KIND' }
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
    engineScriptHash=(Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant(); logFile="$runId.log"
}
if ($profileInfo) { $context.profile=$Profile; $context.profileDigest=$profileInfo.digest }
foreach ($repo in @(@{name='code';path=$WorkspacePath}, @{name='context';path=(Join-Path $WorkspacePath '.ai-workspace')}, @{name='spec';path=$SpecDirectory})) {
    if ((Get-Command git -CommandType Application -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $repo.path -PathType Container)) {
        $gitRoot = & git -C $repo.path rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -eq 0) {
            $context[$repo.name + 'GitRoot'] = Resolve-PhysicalPathIdentity -Path ([string]$gitRoot)
            $revision = & git -C $repo.path rev-parse HEAD 2>$null
            if ($LASTEXITCODE -eq 0) { $context[$repo.name + 'GitRevision'] = [string]$revision }
        }
    }
}
if (Test-Path -LiteralPath (Join-Path $WorkspacePath '.svn')) {
    $svn = Get-Command svn -CommandType Application -ErrorAction SilentlyContinue
    if ($svn) {
        $revision = & $svn.Source info --non-interactive --show-item revision $WorkspacePath 2>$null
        if ($LASTEXITCODE -eq 0) { $context.codeSvnRevision = [string]$revision }
        else { $context.codeSvnMetadata='UNAVAILABLE'; Write-Warning 'SVN_METADATA_UNAVAILABLE: verification will continue without a revision annotation' }
    } else { $context.codeSvnMetadata='CLI_MISSING'; Write-Warning 'SVN_CLI_MISSING: verification will continue without a revision annotation' }
}
$launchError = $null
try { $context.executable = Resolve-AiSopRunExecutable $Executable $WorkspacePath }
catch { $launchError = $_.Exception.Message; $context.executable = $Executable }
$record = @{
    runId=$runId; outcome='RUNNING'; kind=$Kind; batch=$Batch; command=(@($Executable) + $Arguments | ConvertTo-Json -Compress)
    exitCode=-2; executedAt=[DateTimeOffset]::UtcNow.ToString('o'); inputDigest=$before.digest
    context=$context; inputs=$before.files; inputsStable=$false; caseIds=@($CaseIds | Where-Object { $_ } | Sort-Object -Unique)
}
if ($bindSpecs) { $record.specDigest=$specBefore }
$context.definitionDigest = Get-AiSopRunDefinitionDigest $record
$previousBatch = @($task.verifications | Where-Object { $_.kind -ceq $Kind -and $_.batch -ceq $Batch })
if ($previousBatch.Count -and (Get-AiSopRunDefinitionDigest $previousBatch[-1]) -cne $context.definitionDigest) {
    if ([string]::IsNullOrWhiteSpace($Reason)) { throw 'BATCH_DEFINITION_CHANGED: keep the command and case scope, or supply -Reason for an intentional replacement' }
    $context.batchChangeReason = $Reason; $context.previousRunId = [string]$previousBatch[-1].runId
}
function Save-RunEvidence {
    $recordPath = Get-AiSopRunEvidencePath $SpecDirectory $TaskId $runId
    # Durable before checkpoint. Keep the result on any commit/transport failure;
    # RetryEvidence or Recover can finish the same run without executing it again.
    Write-AiSopWorkflowTextAtomic -Path $recordPath -Text (ConvertTo-AiSopWorkflowCanonicalJson $record)
    & $ownerScript -Operation Checkpoint @ownerArgs -EvidencePath $recordPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "EVIDENCE_CHECKPOINT_FAILED: pending result at $recordPath" }
    Remove-Item -LiteralPath $recordPath
}
function Update-RunLease {
    $bound = Get-AiSopWorkflowSession -SessionKey $context.sessionKey -WorkspacePath $WorkspacePath -DeadlineUtc ([DateTimeOffset]::UtcNow.AddSeconds(15))
    if ($bound.EffectiveStatus -ne 'ACTIVE' -or $bound.Record.sessionEpochId -cne $context.sessionEpochId -or
        $bound.Record.boundOwnerId -cne $task.ownerId -or $bound.Record.boundFeature -cne $Feature) { throw 'RUN_SESSION_LOST: the original session is no longer active and bound' }
    if ([DateTimeOffset]::Parse($bound.Record.expiresAt) -le [DateTimeOffset]::UtcNow.AddMinutes(5)) { Save-RunEvidence }
}
# Persist the attempt before launch so an abrupt runner termination cannot leave
# an older successful batch appearing to be the latest execution.
Save-RunEvidence
$logPath = Join-Path $taskDir "$runId.log"
$logStream = [IO.FileStream]::new($logPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
$writer = [IO.StreamWriter]::new($logStream, [Text.UTF8Encoding]::new($false)); $writer.AutoFlush = $true
$process = [Diagnostics.Process]::new()
$info = $process.StartInfo
$info.WorkingDirectory=$WorkspacePath; $info.UseShellExecute=$false; $info.CreateNoWindow=$true
$info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
foreach ($arg in $Arguments) { $info.ArgumentList.Add($arg) }
$started=$false; $finished=$false; $stopwatch=[Diagnostics.Stopwatch]::StartNew()
$lastLeaseCheck = [DateTimeOffset]::MinValue
try {
    if ($launchError) { throw $launchError }
    $info.FileName = $context.executable
    $started = $process.Start()
    if (-not $started) { throw 'VERIFICATION_START_FAILED' }
    $context.childPid=[string]$process.Id
    $context.childStartedAt=$process.StartTime.ToUniversalTime().ToString('o')
    Save-RunEvidence
    $pipes = @(
        @{ reader=$process.StandardOutput; buffer=[char[]]::new(2048); pending=$null; ended=$false },
        @{ reader=$process.StandardError; buffer=[char[]]::new(2048); pending=$null; ended=$false }
    )
    while ($true) {
        if (-not $process.HasExited -and [DateTimeOffset]::UtcNow -ge $lastLeaseCheck.AddSeconds(5)) {
            Update-RunLease
            $lastLeaseCheck = [DateTimeOffset]::UtcNow
        }
        if ($TimeoutSeconds -gt 0 -and $stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            $record.outcome='TIMED_OUT'; $record.exitCode=124
            if (-not $process.HasExited) { $process.Kill($true) }
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
        [Threading.Thread]::Sleep(50)
    }
    $finished=$true
} catch {
    $record.exitCode=-1; $record.outcome='FAILED'
    $message='VERIFICATION_FAILED: ' + $_.Exception.Message
    $writer.WriteLine($message); Write-Host $message
} finally {
    if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit(5000) | Out-Null }
    $process.Dispose(); $writer.Dispose()
    if (-not $finished -and $record.outcome -eq 'RUNNING') { $record.outcome='INTERRUPTED'; $record.exitCode=-2 }
    try {
        $after=Get-AiSopInputSnapshot $WorkspacePath
        $record.inputsStable=($before.digest -ceq $after.digest) -and (-not $bindSpecs -or $specBefore -ceq (Get-AiSopTaskSpecDigest $SpecDirectory))
        if (-not $record.inputsStable) { $record.outcome='FAILED'; if ($record.exitCode -eq 0) { $record.exitCode=1 } }
    } catch { $record.inputsStable=$false; $record.outcome='FAILED'; $record.exitCode=1 }
    Save-RunEvidence
}
Write-Output "RUN_RESULT:$($record.outcome) exit=$($record.exitCode) log=$logPath"
if (-not $record.inputsStable) { throw 'INPUTS_CHANGED_DURING_RUN: inspect task verification diagnostics' }
exit $record.exitCode
