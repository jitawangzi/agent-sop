#requires -Version 7.0
# Shared task identity and validation inputs. No project-domain assumptions.
. (Join-Path $PSScriptRoot 'workflow-transaction.ps1')

function Get-AiSopTaskPath {
    param([string]$SpecDirectory, [string]$TaskId)
    if ($TaskId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$') { throw 'TASK_ID_INVALID' }
    $root = Resolve-PhysicalPathIdentity -Path $SpecDirectory
    $path = Resolve-PhysicalPathIdentity -Path (Join-Path $root "tasks/$TaskId/task.json")
    $prefix = $root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $comparison = if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $path.StartsWith($prefix, $comparison)) { throw 'TASK_PATH_ESCAPE' }
    return $path
}

function Read-AiSopTask {
    param([string]$SpecDirectory, [string]$TaskId)
    $path = Get-AiSopTaskPath $SpecDirectory $TaskId
    if (-not [IO.File]::Exists($path)) { throw "TASK_NOT_FOUND: $TaskId" }
    $raw = [IO.File]::ReadAllText($path)
    Assert-AiSopWorkflowJsonSchema -Json $raw -SchemaId TASK
    $task = ConvertFrom-AiSopWorkflowJson -Json $raw -AsHashtable
    if ($task.taskId -cne $TaskId -or $task.feature -cne (Split-Path -Leaf $SpecDirectory)) { throw 'TASK_IDENTITY_MISMATCH' }
    return $task
}

function Get-AiSopInputSnapshot {
    param([string]$WorkspacePath)
    $root = Resolve-PhysicalPathIdentity -Path $WorkspacePath
    # Conservative workspace-wide content snapshot. VCS status/staging and build
    # output are deliberately absent. Input changes in shared code still invalidate.
    $excludedDirectories = @('.git', '.svn', '.ai-sop', '.ai-workspace', '.claude', '.agents', '.agent', '.gemini', '.cursor', '.idea', '.vscode', '.superpowers', 'node_modules', '.gradle', 'build', 'target', 'bin', 'obj', 'out', 'classes', '__pycache__')
    $excludedFiles = @('AGENTS.md', 'CLAUDE.md', 'ANTIGRAVITY.md', 'GEMINI.md', 'compile-evidence.json', 'test-evidence.json', '.guard-token.json')
    $files = [Collections.Generic.SortedDictionary[string,string]]::new([StringComparer]::Ordinal)
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($root)
    while ($pending.Count) {
        $dir = $pending.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop) {
            if ($item.PSIsContainer -and $item.Name -in $excludedDirectories) { continue }
            if (-not $item.PSIsContainer -and ($item.Name -in $excludedFiles -or $item.Extension -in @('.log', '.tmp'))) { continue }
            # Fail closed for links: silently omitting linked inputs would make a
            # successful snapshot misleading (and could traverse outside the root).
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "INPUT_LINK_UNSUPPORTED: $($item.FullName)" }
            if ($item.PSIsContainer) { $pending.Push($item.FullName); continue }
            $physical = Resolve-PhysicalPathIdentity -Path $item.FullName
            $rel = [IO.Path]::GetRelativePath($root, $physical).Replace('\', '/')
            $files[$rel] = (Get-FileHash -LiteralPath $physical -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $lines = @($files.GetEnumerator() | ForEach-Object { "$($_.Key.Length):$($_.Key):$($_.Value)" })
    return @{ algorithm = 'inputs-v1'; digest = Get-AiSopWorkflowSha256 ($lines -join "`n"); files = $files }
}

function Get-AiSopChangedInputs {
    param($Before, $After)
    return @(@($Before.files.Keys) + @($After.files.Keys) | Sort-Object -Unique | Where-Object {
        $Before.files[$_] -cne $After.files[$_]
    })
}

function Get-AiSopTaskSpecDigest {
    param([string]$SpecDirectory)
    $parts = @()
    foreach ($name in @('01_server_rules.md','06_design_contract.md','05_test_plan.md','05_test_coverage.json')) {
        $path = Join-Path $SpecDirectory $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $parts += "${name}:missing"; continue }
        $raw = [IO.File]::ReadAllText($path)
        if ($name -eq '05_test_coverage.json') {
            $coverage = ConvertFrom-AiSopWorkflowJson -Json $raw -AsHashtable
            $coverage.Remove('executionEvidence')
            $raw = ConvertTo-AiSopWorkflowCanonicalJson $coverage
        } else { $raw = ($raw -replace "`r`n", "`n").TrimEnd() }
        $parts += "${name}:$(Get-AiSopWorkflowSha256 $raw)"
    }
    return Get-AiSopWorkflowSha256 ($parts -join "`n")
}

function Get-AiSopTaskProblems {
    param($Task, [string]$WorkspacePath, [string]$SpecDirectory = '')
    $problems = [Collections.Generic.List[string]]::new()
    $snapshot = Get-AiSopInputSnapshot $WorkspacePath
    foreach ($pending in @($Task.verifications | Where-Object { $_.outcome -eq 'RUNNING' })) { $problems.Add("RUN_UNFINISHED:$($pending.runId):$(Get-AiSopRunActivity $pending $WorkspacePath)") }
    foreach ($kind in @('compile', 'test')) {
        if ($kind -eq 'test' -and $Task.tier -eq 'T1') { continue }
        $records = @($Task.verifications | Where-Object { $_.kind -eq $kind })
        if (-not $records.Count) { $problems.Add("MISSING_EVIDENCE:$kind"); continue }
        # Each named test batch must have a successful latest execution. A later
        # green batch cannot hide an unresolved failure in another batch.
        foreach ($group in @($records | Group-Object batch)) {
            $record = @($group.Group)[-1]
            if ($record.exitCode -ne 0) { $problems.Add("EXECUTION_FAILED:${kind}:$($record.batch):exit=$($record.exitCode)") }
            if ($Task.tier -eq 'T3' -and $kind -eq 'test' -and $SpecDirectory -and $record.specDigest -cne (Get-AiSopTaskSpecDigest $SpecDirectory)) {
                $problems.Add("STALE_SPEC_EVIDENCE:test:$($record.batch):requirement/design/test-definition changed")
            }
            if ($record.inputDigest -cne $snapshot.digest -or -not $record.inputsStable) {
                $changed = Get-AiSopChangedInputs -Before @{ files = $record.inputs } -After $snapshot
                $problems.Add("STALE_EVIDENCE:${kind}:$($record.batch):$($changed -join ',')")
            }
        }
    }
    if ($Task.tier -eq 'T3') {
        $latestTests = @($Task.verifications | Where-Object { $_.kind -eq 'test' } | Group-Object batch | ForEach-Object { @($_.Group)[-1] })
        $covered = @($latestTests | Where-Object { $_.exitCode -eq 0 -and $_.inputDigest -ceq $snapshot.digest -and $_.inputsStable -and (-not $SpecDirectory -or $_.specDigest -ceq (Get-AiSopTaskSpecDigest $SpecDirectory)) } | ForEach-Object { $_.caseIds } | Sort-Object -Unique)
        $missing = @($Task.requiredCaseIds | Where-Object { $_ -notin $covered })
        if ($missing.Count) { $problems.Add("UNCOVERED_CASES:$($missing -join ',')") }
    }
    return $problems.ToArray()
}

# Inspect ignore rules in the repository that owns specs, which may itself be a
# nested repository or worktree. A parent's ignore rule is normal in that layout.
function Get-AiSopSpecSyncWarning {
    param([string]$WorkspacePath)
    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) { return }
    $specRoot = Resolve-PhysicalPathIdentity -Path (Join-Path $WorkspacePath '.ai-workspace/specs')
    $existing = $specRoot
    while (-not (Test-Path -LiteralPath $existing -PathType Container)) {
        $parent = Split-Path -Parent $existing
        if (-not $parent -or $parent -eq $existing) { return }
        $existing = $parent
    }
    $repo = & git -C $existing rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0) { return }
    $repo = Resolve-PhysicalPathIdentity -Path ([string]$repo)
    $probe = [IO.Path]::GetRelativePath($repo, (Join-Path $specRoot 'features/__sop_sync_probe__/06_design_contract.md')).Replace('\', '/')
    $ignored = & git -C $repo check-ignore -- $probe 2>$null
    if ($LASTEXITCODE -eq 0 -and $ignored) {
        return "SPECS_IGNORED: specification paths are ignored by their owning Git repository '$repo'; review tracking there before handoff. No ignore rules or tracked files were changed."
    }
}


function Get-AiSopRunActivity {
    param($Record, [string]$WorkspacePath)
    if ($Record.outcome -ne 'RUNNING') { return 'NONE' }
    if ($Record.context.runnerMachine -cne [Environment]::MachineName -or
        $Record.context.workspace -cne (Resolve-PhysicalPathIdentity $WorkspacePath)) { return 'REMOTE_UNKNOWN' }
    foreach ($prefix in @('runner','child')) {
        if (-not $Record.context["${prefix}Pid"] -or -not $Record.context["${prefix}StartedAt"]) { continue }
        $process = $null
        try {
            $process = [Diagnostics.Process]::GetProcessById([int]$Record.context["${prefix}Pid"])
            if ($process.StartTime.ToUniversalTime().ToString('o') -ceq $Record.context["${prefix}StartedAt"] -and -not $process.HasExited) { return 'RUNNING' }
        } catch [ArgumentException] { } catch { return 'UNCONFIRMED' } finally { if ($process) { $process.Dispose() } }
    }
    return 'INTERRUPTED'
}

function Get-AiSopTaskSummary {
    param($Task, [string]$WorkspacePath, [string]$SpecDirectory, [switch]$CheckInputs)
    $ownerPath = Join-Path (Get-AiSopWorkflowOwnerRegistryRoot -WorkspacePath $WorkspacePath) ($Task.feature.ToLowerInvariant() + '.json')
    $owner = $null; $sessionStatus = 'MISSING'; $ownerStatus = 'MISSING'; $diagnostics = @()
    if (Test-Path -LiteralPath $ownerPath) {
        try {
            $ownerRaw = [IO.File]::ReadAllText($ownerPath)
            Assert-AiSopWorkflowJsonSchema -Json $ownerRaw -SchemaId OWNER
            $owner = ConvertFrom-AiSopWorkflowJson $ownerRaw -AsHashtable
            $ownerStatus = if ($owner.taskId -ceq $Task.taskId -and $owner.ownerId -ceq $Task.ownerId) { $owner.status } else { 'OTHER_TASK' }
            if ($ownerStatus -eq 'ACTIVE' -and $owner.sessionBinding) {
                $sessionStatus = (Get-AiSopWorkflowSession -SessionKey $owner.sessionBinding.sessionKey -WorkspacePath $WorkspacePath).EffectiveStatus
            }
        } catch { $diagnostics += $_.Exception.Message; $sessionStatus = 'UNAVAILABLE' }
    }
    $runs = @($Task.verifications | Where-Object { $_.outcome -eq 'RUNNING' } | ForEach-Object {
        @{ runId=$_.runId; kind=$_.kind; batch=$_.batch; activity=(Get-AiSopRunActivity $_ $WorkspacePath); logFile=$_.context.logFile }
    })
    $action = if ($Task.status -in @('DONE','CANCELLED')) { 'Start a new task for new work' }
        elseif ($runs.Count -and @($runs | Where-Object activity -eq 'RUNNING').Count) { 'Wait for the running command; inspect its log' }
        elseif ($runs.Count) { 'Recover interrupted/foreign run, then Resume' }
        elseif ($Task.status -eq 'PAUSED') { 'Resume' }
        elseif ($ownerStatus -ne 'ACTIVE' -or $sessionStatus -eq 'UNAVAILABLE') { 'Recover local ownership, then Resume' }
        elseif ($sessionStatus -in @('ACTIVE','IDLE')) { 'Existing session may still be active; Resume only for intentional handoff' }
        else { 'Resume' }
    $verification = 'NOT_CHECKED'
    if ($CheckInputs) {
        try {
            $problems = @(Get-AiSopTaskProblems $Task $WorkspacePath $SpecDirectory)
            $verification = if ($problems.Count) { 'NEEDS_ATTENTION' } else { 'EXECUTION_EVIDENCE_CURRENT' }
            $diagnostics += $problems
        } catch { $verification='UNAVAILABLE'; $diagnostics += $_.Exception.Message }
    }
    return [ordered]@{
        feature=$Task.feature; taskId=$Task.taskId; tier=$Task.tier; status=$Task.status; objective=$Task.objective
        ownerStatus=$ownerStatus; sessionStatus=$sessionStatus; verification=$verification
        recordedApprovals=(Get-AiSopRecordedApprovals $SpecDirectory)
        nextAction=$Task.nextAction; suggestedAction=$action; notes=$Task.notes; runs=$runs
        diagnostics=$diagnostics; updatedAt=$Task.updatedAt
    }
}

function Get-AiSopRecordedApprovals {
    param([string]$SpecDirectory)
    $path=Join-Path $SpecDirectory '00_workflow_state.json'
    if (-not [IO.File]::Exists($path)) { $path=Join-Path $SpecDirectory 'workflow-state.json' }
    if (-not [IO.File]::Exists($path)) { return @{ requirement='NOT_RECORDED'; design='NOT_RECORDED' } }
    try {
        $state=ConvertFrom-AiSopWorkflowJson ([IO.File]::ReadAllText($path)) -AsHashtable
        return @{ requirement=[string]$state.requirement.status; design=[string]$state.design.status }
    } catch { return @{ requirement='UNAVAILABLE'; design='UNAVAILABLE' } }
}

function Get-AiSopVerificationProfile {
    param([string]$WorkspacePath, [string]$Name)
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$') { throw 'PROFILE_NAME_INVALID' }
    $path = Resolve-PhysicalPathIdentity (Join-Path $WorkspacePath '.ai-workspace/context/verification-commands.json')
    $root = (Resolve-PhysicalPathIdentity $WorkspacePath).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $comparison = if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $path.StartsWith($root, $comparison)) { throw 'PROFILE_PATH_ESCAPE' }
    if (-not [IO.File]::Exists($path)) { throw "PROFILE_CONFIG_MISSING: $path" }
    $raw = [IO.File]::ReadAllText($path)
    if (-not ($raw | Test-Json -SchemaFile (Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/verification-commands.schema.json'))) { throw 'PROFILE_CONFIG_INVALID' }
    $config = ConvertFrom-AiSopWorkflowJson $raw -AsHashtable
    if (-not $config.commands.Contains($Name)) { throw "PROFILE_NOT_FOUND: $Name" }
    return @{ command=$config.commands[$Name]; path=$path; digest=(Get-AiSopWorkflowSha256 $raw) }
}
