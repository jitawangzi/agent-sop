#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Discover','Start','Resume','Checkpoint','Suspend','Cancel','Run','ReviewImpact','Verify','Complete')][string]$Operation,
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
    [string[]]$CaseIds = @()
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'task-context.ps1')
. (Join-Path $PSScriptRoot 'workflow-session.ps1')
$WorkspacePath = Resolve-PhysicalPathIdentity -Path $WorkspacePath
$featuresRoot = Join-Path $WorkspacePath '.ai-workspace/specs/features'
if ($Operation -eq 'Discover') {
    foreach ($dir in @(Get-ChildItem -LiteralPath $featuresRoot -Directory -ErrorAction SilentlyContinue)) {
        $records = @(Get-ChildItem -LiteralPath (Join-Path $dir.FullName 'tasks') -Directory -ErrorAction SilentlyContinue)
        foreach ($entry in $records) {
            $task = Read-AiSopTask $dir.FullName $entry.Name
            [pscustomobject]@{ feature=$task.feature; taskId=$task.taskId; tier=$task.tier; status=$task.status; objective=$task.objective; nextAction=$task.nextAction; updatedAt=$task.updatedAt } | ConvertTo-Json -Compress
        }
        if (-not $records.Count) {
            [pscustomobject]@{ feature=$dir.Name; taskId=$null; status='LEGACY'; action='Inspect existing owner and feature-state; Resume to adopt, never infer completion.' } | ConvertTo-Json -Compress
        }
    }
    $domainRoot = Join-Path $WorkspacePath '.ai-workspace'
    if (Test-Path -LiteralPath (Join-Path $domainRoot '.git')) {
        $ignored = & git -C $domainRoot check-ignore 'specs/features/__sop_sync_probe__/06_design_contract.md' 2>$null
        if ($LASTEXITCODE -eq 0 -and $ignored) { Write-Warning 'SPECS_IGNORED: specs are ignored by .ai-workspace Git; untracked task/spec files will not travel through normal commit/push. Review tracking policy before cross-workspace handoff.' }
    }
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
$ownerArgs = @{ Feature=$Feature; SpecDirectory=$SpecDirectory; Workflow='SUPERPOWERS'; Agent=$Agent }
if ($PSBoundParameters.ContainsKey('NextAction')) { $ownerArgs.NextAction = $NextAction }
if ($PSBoundParameters.ContainsKey('Notes')) { $ownerArgs.Notes = $Notes }
if ($Operation -eq 'Start') {
    if (-not $TaskId) { $TaskId = 'task-' + [guid]::NewGuid().ToString('N') }
    [IO.Directory]::CreateDirectory($SpecDirectory) | Out-Null
    & $ownerScript -Operation Claim @ownerArgs -TaskId $TaskId -OwnerId ('task-' + $TaskId) -Tier $Tier -Objective $Objective
    if ($LASTEXITCODE -ne 0) { throw 'TASK_START_FAILED' }
    Write-Output "TASK_STARTED:$Feature/$TaskId tier=$Tier"
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
    & $ownerScript -Operation Transfer @ownerArgs -OwnerId $owner.ownerId -TaskId $TaskId -Tier $Tier -Objective $Objective
    if ($LASTEXITCODE -ne 0) { throw 'TASK_ADOPTION_FAILED' }
    exit 0
}
if (-not $TaskId) { throw 'TASK_SELECTION_REQUIRED: use Discover and select an existing task; no implicit takeover.' }
$task = Read-AiSopTask $SpecDirectory $TaskId
$ownerArgs.OwnerId = $task.ownerId
$ownerArgs.TaskId = $TaskId
if ($Operation -eq 'Resume') {
    if ($task.status -eq 'PAUSED') {
        & $ownerScript -Operation Claim @ownerArgs -Tier $task.tier -Objective $task.objective
    } elseif ($task.status -eq 'ACTIVE' -and $owner -and $owner.taskId -ceq $TaskId) {
        $native = if ($Agent -eq 'CODEX') { $env:CODEX_SESSION_ID } else { $env:AI_SESSION_ID }
        $sameSession = $native -and ((Get-AiSopWorkflowSessionKey -Agent $Agent -NativeSessionId $native -WorkspacePath $WorkspacePath) -ceq $owner.sessionBinding.sessionKey)
        if ($sameSession) {
            $boundSession = Get-AiSopWorkflowSession -SessionKey $owner.sessionBinding.sessionKey -WorkspacePath $WorkspacePath
            if ($boundSession.EffectiveStatus -in @('ENDED','EXPIRED')) { & $ownerScript -Operation RebindSession @ownerArgs }
            else { & $ownerScript -Operation Validate @ownerArgs }
        } else { & $ownerScript -Operation Transfer @ownerArgs }
    } else { throw 'TASK_NOT_RESUMABLE: terminal task or missing local ownership; inspect/recover ownership before resuming.' }
    if ($LASTEXITCODE -ne 0) { throw 'TASK_RESUME_FAILED' }
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
# Run is the common evidence producer. No shell interpolation or success fabrication.
if (-not $Executable -or -not $Kind) { throw 'RUN_REQUIRES_EXECUTABLE_AND_KIND' }
if ($Batch -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$') { throw 'BATCH_ID_INVALID' }
& $ownerScript -Operation Validate @ownerArgs | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'TASK_OWNER_INVALID' }
$before = Get-AiSopInputSnapshot $WorkspacePath
$specBefore = Get-AiSopTaskSpecDigest $SpecDirectory
$info = [Diagnostics.ProcessStartInfo]::new()
$info.WorkingDirectory = $WorkspacePath
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
foreach ($arg in $Arguments) { $info.ArgumentList.Add($arg) }
$process = [Diagnostics.Process]::new(); $process.StartInfo = $info
try {
    $info.FileName = (@(Get-Command $Executable -CommandType Application -ErrorAction Stop)[0]).Source
    if (-not $process.Start()) { throw 'VERIFICATION_START_FAILED' }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $code = $process.ExitCode
    $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
} catch {
    $code = -1
    $output = 'VERIFICATION_START_FAILED: ' + $_.Exception.Message
} finally { $process.Dispose() }
$after = Get-AiSopInputSnapshot $WorkspacePath
$context = @{ workspace=$WorkspacePath; engineScriptHash=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'workflow-state.ps1')).Hash.ToLowerInvariant(); executable=$info.FileName }
foreach ($repo in @(@{name='codeGitRevision';path=$WorkspacePath}, @{name='specGitRevision';path=(Join-Path $WorkspacePath '.ai-workspace')})) {
    if (Test-Path -LiteralPath (Join-Path $repo.path '.git')) {
        $revision = & git -C $repo.path rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0) { $context[$repo.name] = [string]$revision }
    }
}
if (Test-Path -LiteralPath (Join-Path $WorkspacePath '.svn')) {
    $revision = & svn info --non-interactive --show-item revision $WorkspacePath 2>$null
    if ($LASTEXITCODE -eq 0) { $context['codeSvnRevision'] = [string]$revision }
}
$record = @{
    kind=$Kind; batch=$Batch; command=(@($Executable) + $Arguments | ConvertTo-Json -Compress)
    exitCode=$code; executedAt=[DateTimeOffset]::UtcNow.ToString('o'); inputDigest=$before.digest
    specDigest=$specBefore; context=$context; inputs=$before.files; inputsStable=(($before.digest -ceq $after.digest) -and ($task.tier -ne 'T3' -or $Kind -ne 'test' -or $specBefore -ceq (Get-AiSopTaskSpecDigest $SpecDirectory))); caseIds=@($CaseIds | Sort-Object -Unique)
}
$taskDir = Split-Path -Parent (Get-AiSopTaskPath $SpecDirectory $TaskId)
$runId = [guid]::NewGuid().ToString('N')
$record.context['logFile'] = "$runId.log"
$recordPath = Join-Path $taskDir "$runId.evidence.tmp"
try {
    [IO.File]::WriteAllText((Join-Path $taskDir "$runId.log"), $output, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($recordPath, ($record | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    & $ownerScript -Operation Checkpoint @ownerArgs -EvidencePath $recordPath
    if ($LASTEXITCODE -ne 0) { throw 'EVIDENCE_CHECKPOINT_FAILED' }
} finally { if (Test-Path -LiteralPath $recordPath) { Remove-Item -LiteralPath $recordPath } }
Write-Output $output
if (-not $record.inputsStable) { throw "INPUTS_CHANGED_DURING_RUN: $((Get-AiSopChangedInputs $before $after) -join ',')" }
exit $code
