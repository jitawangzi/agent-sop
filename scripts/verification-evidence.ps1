#requires -Version 7.0
# Evidence protocol checks shared by the runner, checkpoint and crash recovery.
# This is an integrity boundary for normal APIs, not a trust boundary against a
# caller with unrestricted write access to the engine and its local registries.

function Get-AiSopRunEvidencePath {
    param([string]$SpecDirectory, [string]$TaskId, [string]$RunId)
    if ($RunId -notmatch '^[0-9a-f]{32}$') { throw 'RUN_ID_INVALID' }
    $taskPath = Get-AiSopTaskPath $SpecDirectory $TaskId
    $path = Resolve-PhysicalPathIdentity (Join-Path (Split-Path -Parent $taskPath) "$RunId.pending.json")
    $comparison = if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $prefix = (Split-Path -Parent $taskPath).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $path.StartsWith($prefix, $comparison)) { throw 'EVIDENCE_PATH_ESCAPE' }
    return $path
}

function Get-AiSopRunDefinitionDigest {
    param($Record)
    $definition = @{
        kind=$Record.kind; batch=$Record.batch; command=$Record.command
        executable=[string]$Record.context.executable
        caseIds=@($Record.caseIds | Sort-Object -Unique)
        profile=[string]$Record.context.profile; profileDigest=[string]$Record.context.profileDigest
    }
    # Preserve digests of pre-mapping records when the optional format is absent.
    if ($Record.context.junitConfiguration) { $definition.junitConfiguration=$Record.context.junitConfiguration }
    if ($Record.context.profileDigestAlgorithm) { $definition.profileDigestAlgorithm=$Record.context.profileDigestAlgorithm }
    return Get-AiSopWorkflowSha256 (ConvertTo-AiSopWorkflowCanonicalJson $definition)
}

function Assert-AiSopRunEvidence {
    param($Evidence, $Previous, $Task, [string]$WorkspacePath, $SessionBinding, [switch]$Retry)
    if ($Evidence.runId -notmatch '^[0-9a-f]{32}$' -or $Evidence.outcome -notin @('RUNNING','PASSED','FAILED','TIMED_OUT','INTERRUPTED')) { throw 'RUN_EVIDENCE_INVALID' }
    if (($Evidence.outcome -eq 'RUNNING' -and ($Evidence.exitCode -ne -2 -or $Evidence.inputsStable)) -or
        ($Evidence.outcome -eq 'PASSED' -and ($Evidence.exitCode -ne 0 -or -not $Evidence.inputsStable)) -or
        ($Evidence.outcome -in @('FAILED','TIMED_OUT','INTERRUPTED') -and $Evidence.exitCode -eq 0)) { throw 'RUN_RESULT_INCONSISTENT' }
    Assert-AiSopJUnitResult $Evidence
    $ctx = $Evidence.context
    foreach ($key in @('protocol','taskId','ownerId','workspace','runnerMachine','runnerPid','runnerStartedAt','engineScriptHash','sessionKey','sessionEpochId','definitionDigest')) {
        if ([string]::IsNullOrWhiteSpace([string]$ctx[$key])) { throw "RUN_CONTEXT_REQUIRED:$key" }
    }
    if ($ctx.protocol -cne '2' -or $ctx.taskId -cne $Task.taskId -or $ctx.ownerId -cne $Task.ownerId -or
        $ctx.workspace -cne (Resolve-PhysicalPathIdentity $WorkspacePath) -or $ctx.runnerMachine -cne [Environment]::MachineName -or
        $ctx.definitionDigest -cne (Get-AiSopRunDefinitionDigest $Evidence)) { throw 'RUN_IDENTITY_MISMATCH' }
    if ($SessionBinding -and ($ctx.sessionKey -cne $SessionBinding.sessionKey -or $ctx.sessionEpochId -cne $SessionBinding.sessionEpochId)) { throw 'RUN_SESSION_MISMATCH' }
    if (-not $Retry) {
        $currentStartedAt = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o')
        if ($ctx.runnerPid -cne [string]$PID -or $ctx.runnerStartedAt -cne $currentStartedAt) { throw "RUN_RUNNER_MISMATCH: expected $PID/$currentStartedAt; received $($ctx.runnerPid)/$($ctx.runnerStartedAt)" }
    }
    if ($Evidence.inputsRef) { Read-AiSopVerificationInputs $Evidence $WorkspacePath | Out-Null }
    if (-not $Previous) {
        if ($Retry -or $Evidence.outcome -ne 'RUNNING') { throw 'RUN_BEGIN_REQUIRED' }
        if ($ctx.engineScriptHash -cne (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'workflow-task.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'RUN_ENGINE_MISMATCH' }
        $priorBatch = @($Task.verifications | Where-Object { $_.kind -ceq $Evidence.kind -and $_.batch -ceq $Evidence.batch })
        if ($priorBatch.Count -and (Get-AiSopRunDefinitionDigest $priorBatch[-1]) -cne $ctx.definitionDigest) {
            if ([string]::IsNullOrWhiteSpace($ctx.batchChangeReason) -or $ctx.previousRunId -cne [string]$priorBatch[-1].runId) { throw 'BATCH_DEFINITION_CHANGED: keep the command and case scope, or supply -Reason for an intentional replacement' }
        }
        return
    }
    # Every execution identity field is immutable after registration. A child
    # identity can be added once, after Process.Start, and cannot be replaced.
    foreach ($field in @('runId','kind','batch','command','executedAt','inputDigest','inputs','inputsRef','caseIds','specDigest')) {
        if ((ConvertTo-AiSopWorkflowCanonicalJson $Previous[$field]) -cne (ConvertTo-AiSopWorkflowCanonicalJson $Evidence[$field])) { throw "RUN_IDENTITY_MISMATCH:$field" }
    }
    $oldContext = @{}; $newContext = @{}
    foreach ($key in $Previous.context.Keys) { if ($key -notin @('childPid','childStartedAt')) { $oldContext[$key]=$Previous.context[$key] } }
    foreach ($key in $ctx.Keys) { if ($key -notin @('childPid','childStartedAt')) { $newContext[$key]=$ctx[$key] } }
    if ((ConvertTo-AiSopWorkflowCanonicalJson $oldContext) -cne (ConvertTo-AiSopWorkflowCanonicalJson $newContext)) { throw 'RUN_IDENTITY_MISMATCH:context' }
    foreach ($key in @('childPid','childStartedAt')) {
        if ($Previous.context[$key] -and $Previous.context[$key] -cne $ctx[$key]) { throw 'RUN_CHILD_MISMATCH' }
    }
    if ([bool]$ctx.childPid -ne [bool]$ctx.childStartedAt) { throw 'RUN_CHILD_MISMATCH' }
    if ($Previous.outcome -ne 'RUNNING' -and (ConvertTo-AiSopWorkflowCanonicalJson $Previous) -cne (ConvertTo-AiSopWorkflowCanonicalJson $Evidence)) { throw 'RUN_ALREADY_FINALIZED' }
    if ($Retry -and $Evidence.outcome -eq 'RUNNING') { throw 'RUN_TERMINAL_RESULT_REQUIRED' }
}

function Resolve-AiSopRunExecutable {
    param([string]$Executable, [string]$WorkspacePath)
    $candidate = $Executable
    if ($Executable -match '[/\\]' -or [IO.Path]::IsPathRooted($Executable) -or [IO.File]::Exists((Join-Path $WorkspacePath $Executable))) {
        $candidate = if ([IO.Path]::IsPathRooted($Executable)) { $Executable } else { Join-Path $WorkspacePath $Executable }
        $candidate = Resolve-PhysicalPathIdentity $candidate
    }
    if ([IO.Path]::GetExtension($candidate) -in @('.ps1','.bat','.cmd')) { throw 'RUN_SCRIPT_REQUIRES_HOST: use -Executable pwsh with -Arguments for -File (PowerShell) or an explicit batch invocation' }
    return (@(Get-Command $candidate -CommandType Application -ErrorAction Stop)[0]).Source
}
