#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$scripts = Split-Path -Parent $PSScriptRoot
$entry = Join-Path $scripts 'workflow-task.ps1'
. (Join-Path $scripts 'task-context.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('sop-task-tests-' + [guid]::NewGuid().ToString('N'))
$workspace = Join-Path $root 'workspace'
$spec = Join-Path $workspace '.ai-workspace/specs/features/Example'
$saved = @{}
foreach ($key in @('AI_SOP_OWNER_REGISTRY','AI_SOP_SESSION_REGISTRY','AI_SOP_COMMAND_GRANT_REGISTRY','AI_SOP_TRANSACTION_REGISTRY','SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS','CODEX_SESSION_ID','AI_SESSION_ID')) { $saved[$key] = [Environment]::GetEnvironmentVariable($key) }
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function MustFail([scriptblock]$action, [string]$message) {
    $failed = $false
    $output=[Collections.Generic.List[string]]::new()
    try { & $action | ForEach-Object { $output.Add([string]$_) }; if ($LASTEXITCODE -ne 0) { $failed=$true } } catch { $failed=$true }
    Assert $failed $message
    Assert (-not @($output | Where-Object { $_ -match '^TASK_(COMPLETED|RESUMED|SUSPENDED|CANCELLED):' }).Count) 'Failed operation printed a success summary'
}
function Task([string]$op, [string]$id, [hashtable]$extra=@{}) {
    & $entry -Operation $op -WorkspacePath $workspace -Feature Example -TaskId $id -Agent CODEX @extra
    if ($LASTEXITCODE -ne 0) { throw "Task $op failed: $LASTEXITCODE" }
}
try {
    foreach ($kind in @('OWNER','SESSION','COMMAND_GRANT','TRANSACTION')) { [Environment]::SetEnvironmentVariable("AI_SOP_${kind}_REGISTRY", (Join-Path $root $kind)) }
    $env:SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS='15000'
    $env:CODEX_SESSION_ID='task-session-a'
    [IO.Directory]::CreateDirectory($spec) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'src')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $workspace 'src/input.txt'), 'initial')
    git -C $workspace init -b main --quiet
    git -C $workspace -c user.name=Test -c user.email=test@example.invalid add src/input.txt
    git -C $workspace -c user.name=Test -c user.email=test@example.invalid commit --quiet -m initial
    # Project context and feature specifications can be separate nested Git repos.
    $contextRoot = Join-Path $workspace '.ai-workspace'
    $specsRoot = Join-Path $contextRoot 'specs'
    git -C $contextRoot init -b main --quiet
    [IO.File]::WriteAllText((Join-Path $contextRoot '.gitignore'), "specs/`n")
    git -C $contextRoot add .gitignore
    git -C $contextRoot -c user.name=Test -c user.email=test@example.invalid commit --quiet -m 'context repository'
    Assert ((Get-AiSopSpecSyncWarning $workspace) -match 'SPECS_IGNORED') 'Ignored specs without a child repository must warn'
    git -C $specsRoot init -b main --quiet
    [IO.File]::WriteAllText((Join-Path $specsRoot '.gitignore'), "*.log`n")
    git -C $specsRoot add .gitignore
    git -C $specsRoot -c user.name=Test -c user.email=test@example.invalid commit --quiet -m 'specifications repository'
    Assert (-not (Get-AiSopSpecSyncWarning $workspace)) 'Parent ignore rule caused a false warning for independent specs repo'
    $discovery = & $entry -Operation Discover -WorkspacePath $workspace 3>&1 | Out-String
    Assert ($discovery -notmatch 'SPECS_IGNORED') 'Discover ignored the specification repository boundary'
    [IO.File]::AppendAllText((Join-Path $specsRoot '.gitignore'), "features/`n")
    Assert ((Get-AiSopSpecSyncWarning $workspace) -match 'SPECS_IGNORED') 'Specs repository own ignore rule was missed'
    [IO.File]::WriteAllText((Join-Path $specsRoot '.gitignore'), "*.log`n")
    # Historical T3 artifacts must not force an independent T2 task into T3.
    [IO.File]::WriteAllText((Join-Path $spec '06_design_contract.md'), 'legacy design')
    [IO.File]::WriteAllText((Join-Path $spec 'compile-evidence.json'), '{"exitCode":1}')
    Task Start fix-a @{ Tier='T2'; Objective='Independent fix' } | Out-Null
    Task RecordSync fix-a @{ Documentation='UNCHANGED'; Tests='UNCHANGED'; Summary='Fixture restores existing behavior; existing regression command covers it.' } | Out-Null
    $first = Read-AiSopTask $spec 'fix-a'
    Assert ($first.tier -eq 'T2') 'Task tier changed because historical design exists'
    $env:CODEX_SESSION_ID='other-feature-session'
    & $entry -Operation Start -WorkspacePath $workspace -Feature Other -TaskId parallel -Tier T1 -UserRequest '本测试明确选择 T1' -Objective 'Independent feature' -Agent CODEX | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'Different feature was blocked by Example owner'
    & $entry -Operation Cancel -WorkspacePath $workspace -Feature Other -TaskId parallel -Agent CODEX | Out-Null
    $env:CODEX_SESSION_ID='task-session-a'
    MustFail { Task Start fix-b @{ Objective='Conflicting concurrent task' } } 'Concurrent task on same feature should fail'
    MustFail { Task Complete fix-a } 'Missing evidence must block completion'
    [IO.File]::WriteAllText((Join-Path $spec '05_test_coverage.json'), '{broken historical coverage')
    [IO.File]::WriteAllText((Join-Path $workspace 'src/input.txt'), 'before-build')
    Task Run fix-a @{ Kind='compile'; Executable='pwsh'; Arguments=@('-NoProfile','-Command','exit 0') } | Out-Null
    Task Run fix-a @{ Kind='test'; Executable='pwsh'; Arguments=@('-NoProfile','-Command','exit 0') } | Out-Null
    $runContext = (Read-AiSopTask $spec 'fix-a').verifications[-1].context
    $expectedSpecRevision = [string](& git -C $specsRoot rev-parse HEAD)
    $expectedContextRevision = [string](& git -C $contextRoot rev-parse HEAD)
    Assert ($runContext.specGitRevision -ceq $expectedSpecRevision) 'Evidence attributed specs to parent repository commit'
    Assert ($runContext.contextGitRevision -ceq $expectedContextRevision) 'Project context revision missing'
    Assert ($runContext.specGitRoot -ceq (Resolve-PhysicalPathIdentity $specsRoot)) 'Wrong specification repository root'
    Assert ($runContext.contextGitRoot -ceq (Resolve-PhysicalPathIdentity $contextRoot)) 'Wrong context repository root'
    # Complete below must validate T2 without a preceding standalone Verify.
    # Content snapshot ignores staging/commit metadata and generated output.
    $before = Get-AiSopInputSnapshot $workspace
    git -C $workspace add src/input.txt
    git -C $workspace -c user.name=Test -c user.email=test@example.invalid commit --quiet -m 'content checkpoint'
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'build')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $workspace 'build/result.bin'), 'generated')
    $after = Get-AiSopInputSnapshot $workspace
    Assert ($before.digest -eq $after.digest) 'Output or staging changed content snapshot'
    # Dependency lock files are inputs, unlike VCS locks in excluded directories.
    [IO.File]::WriteAllText((Join-Path $workspace 'yarn.lock'), 'dependency-version')
    Assert ((Get-AiSopInputSnapshot $workspace).digest -ne $after.digest) 'Dependency lock file was excluded'
    Remove-Item -LiteralPath (Join-Path $workspace 'yarn.lock')
    $feedback=Task Complete fix-a | Out-String
    Assert ($feedback -match 'TASK_COMPLETED:Example/fix-a tier=T2 status=DONE; ownership released' -and $feedback -notmatch 'example\.json') 'Complete did not summarize the committed task result'
    Assert ((Read-AiSopTask $spec 'fix-a').status -eq 'DONE') 'Task not completed'
    Assert ([IO.File]::ReadAllText((Join-Path $spec '06_design_contract.md')) -eq 'legacy design') 'Historical design was modified'
    Task Start fix-b @{ Tier='T1'; UserRequest='本测试明确选择 T1'; Objective='Quick independent change' } | Out-Null
    Assert ((Read-AiSopTask $spec 'fix-b').verifications.Count -eq 0) 'New task inherited old evidence'
    Task Run fix-b @{ Kind='compile'; Executable='pwsh'; Arguments=@('-NoProfile','-Command','exit 0') } | Out-Null
    $feedback=Task Suspend fix-b @{ NextAction='Resume implementation'; Notes='Waiting for input' } | Out-String
    Assert ($feedback -match 'TASK_SUSPENDED:Example/fix-b tier=T1 status=PAUSED; ownership released') 'Suspend did not summarize release'
    Assert ((Read-AiSopTask $spec 'fix-b').status -eq 'PAUSED') 'Suspend must not mark task DONE'
    # An unrelated sequential task may finish while the previous one is paused.
    Task Start fix-c @{ Tier='T1'; UserRequest='本测试明确选择 T1'; Objective='Another independent fix' } | Out-Null
    $feedback=Task Cancel fix-c | Out-String
    Assert ($feedback -match 'TASK_CANCELLED:Example/fix-c tier=T1 status=CANCELLED; ownership released') 'Cancel did not summarize release'
    $env:CODEX_SESSION_ID='task-session-b'
    $feedback=Task Resume fix-b | Out-String
    Assert ($feedback -match 'TASK_RESUMED:Example/fix-b tier=T1 status=ACTIVE; ownership bound to current session') 'Resume lost the inherited tier or session result'
    Assert ((Read-AiSopTask $spec 'fix-b').ownerId -eq 'task-fix-b') 'Resume changed task identity'
    $env:CODEX_SESSION_ID='task-session-c'
    MustFail { Task Resume fix-b } 'Live session takeover must be explicit'
    Task Resume fix-b @{ ConfirmTakeover=$true } | Out-Null
    $env:AI_SESSION_ID='cursor-task-session'
    & $entry -Operation Resume -WorkspacePath $workspace -Feature Example -TaskId fix-b -Agent CURSOR -ConfirmTakeover | Out-Null
    $cursorOwner = Get-Content -LiteralPath (Join-Path $env:AI_SOP_OWNER_REGISTRY 'example.json') -Raw | ConvertFrom-Json
    Assert ($cursorOwner.agent -eq 'CURSOR' -and $cursorOwner.ownerId -eq 'task-fix-b') 'Cross-agent task transfer lost identity'
    $env:CODEX_SESSION_ID='task-session-d'
    Task Resume fix-b @{ ConfirmTakeover=$true } | Out-Null
    Task Verify fix-b | Out-Null
    Remove-Item -LiteralPath (Join-Path $spec '05_test_coverage.json')
    # Impact review binds the analysis file and inputs, independently of VCS status.
    $impactPath = Join-Path $spec '04_change_impact.json'
    $activeOwner = Get-Content -LiteralPath (Join-Path $env:AI_SOP_OWNER_REGISTRY 'example.json') -Raw | ConvertFrom-Json
    $impact = @{
        schemaVersion='1.0'; feature='Example'; baseline=$activeOwner.baseline; changeSetDigest=('0' * 64)
        changedSymbols=@('src/input.txt'); entryPoints=@('input loader'); upstreamCallers=@()
        downstreamEffects=@(); stateReadsWrites=@(); invariants=@(); requiredRegressionCases=@('TC-01')
    }
    [IO.File]::WriteAllText($impactPath, ($impact | ConvertTo-Json -Depth 10))
    Task ReviewImpact fix-b | Out-Null
    $review = (Read-AiSopTask $spec 'fix-b').impactReview
    Assert ($review.inputDigest -ceq (Get-AiSopInputSnapshot $workspace).digest) 'Impact review did not bind current input'
    & (Join-Path $scripts 'workflow-state.ps1') -Operation ValidateChangeImpact -Path $impactPath -TaskId fix-b | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'Task impact incorrectly used legacy changeset digest'
    [IO.File]::AppendAllText($impactPath, "`n")
    MustFail { & (Join-Path $scripts 'workflow-state.ps1') -Operation ValidateChangeImpact -Path $impactPath -TaskId fix-b } 'Changed analysis retained old review'
    Task ReviewImpact fix-b | Out-Null
    # A successful old compile must not survive a real input change.
    [IO.File]::WriteAllText((Join-Path $workspace 'src/input.txt'), 'changed')
    MustFail { & (Join-Path $scripts 'workflow-state.ps1') -Operation ValidateChangeImpact -Path $impactPath -TaskId fix-b } 'Changed source retained old impact review'
    MustFail { Task Complete fix-b } 'Direct completion accepted stale evidence'
    Task Run fix-b @{ Kind='compile'; Executable='pwsh'; Arguments=@('-NoProfile','-Command','exit 0') } | Out-Null
    Task Complete fix-b | Out-Null
    # Failure in one test batch must not be hidden by a green different batch.
    Task Start fix-d @{ Tier='T2'; Objective='Batch verification' } | Out-Null
    Task RecordSync fix-d @{ Documentation='UNCHANGED'; Tests='UNCHANGED'; Summary='Batch runner fixture; existing test cases remain applicable.' } | Out-Null
    Task Run fix-d @{ Kind='compile'; Executable='pwsh'; Arguments=@('-NoProfile','-Command','exit 0') } | Out-Null
    MustFail { Task Run fix-d @{ Kind='test'; Batch='regression'; Executable='pwsh'; Arguments=@('-NoProfile','-Command','exit 2') } } 'Failed command incorrectly returned success'
    Task Run fix-d @{ Kind='test'; Batch='unit'; Executable='pwsh'; Arguments=@('-NoProfile','-Command','exit 0') } | Out-Null
    MustFail { Task Verify fix-d } 'Green batch hid failed regression'
    MustFail { Task Run fix-d @{ Kind='test'; Batch='regression'; Executable='pwsh'; Arguments=@('-NoProfile','-Command','exit 0') } } 'A changed command hid the failed batch without an explanation'
    Task Run fix-d @{ Kind='test'; Batch='regression'; Executable='pwsh'; Arguments=@('-NoProfile','-Command','exit 0'); Reason='Fixture deliberately replaces the failing command' } | Out-Null
    MustFail { Task Run fix-d @{ Kind='test'; Batch='regression'; Executable='sop-test-nonexistent-executable-7f18'; Reason='Exercise launch failure for this batch' } } 'Missing executable incorrectly returned success'
    MustFail { Task Verify fix-d } 'Launch failure retained older green batch'
    Task Run fix-d @{ Kind='test'; Batch='regression'; Executable='pwsh'; Arguments=@('-NoProfile','-Command','exit 0'); Reason='Restore the fixture command after launch failure' } | Out-Null
    Task Complete fix-d | Out-Null
    # 同一真实命令经历 RED/GREEN：修复输入后复用批次，保留失败历史且能够收尾。
    Task Start tdd-cycle @{ Tier='T2'; Objective='Stable verification batch across repair' } | Out-Null
    Task RecordSync tdd-cycle @{ Documentation='UNCHANGED'; Tests='UNCHANGED'; Summary='Verify the existing input contract after repair.' } | Out-Null
    $tddCommand=@('-NoProfile','-Command',"if ([IO.File]::ReadAllText('src/input.txt') -ne 'repaired') { exit 7 }")
    MustFail { Task Run tdd-cycle @{ Kind='test'; Batch='regression'; Executable='pwsh'; Arguments=$tddCommand } } 'RED command unexpectedly passed'
    [IO.File]::WriteAllText((Join-Path $workspace 'src/input.txt'),'repaired')
    Task Run tdd-cycle @{ Kind='test'; Batch='regression'; Executable='pwsh'; Arguments=$tddCommand } | Out-Null
    Task Run tdd-cycle @{ Kind='compile'; Executable='pwsh'; Arguments=@('-NoProfile','-Command','exit 0') } | Out-Null
    $attempts=@((Read-AiSopTask $spec 'tdd-cycle').verifications | Where-Object { $_.batch -eq 'regression' })
    Assert ($attempts.Count -eq 2 -and $attempts[0].exitCode -eq 7 -and $attempts[1].exitCode -eq 0) 'TDD retry erased RED or failed to retain GREEN'
    Task Complete tdd-cycle | Out-Null
    [IO.File]::WriteAllText((Join-Path $workspace 'src/deleted.txt'), 'old input')
    Task Start fix-e @{ Tier='T1'; UserRequest='本测试明确选择 T1'; Objective='Changing inputs during build' } | Out-Null
    $output=[Collections.Generic.List[string]]::new(); $failure=''
    try {
        Task Run fix-e @{ Kind='compile'; Executable='pwsh'; Arguments=@('-NoProfile','-Command',"[IO.File]::WriteAllText('src/input.txt','changed-during-build'); [IO.File]::WriteAllText('src/added.txt','new'); [IO.File]::Delete('src/deleted.txt')") } 6>&1 | ForEach-Object { $output.Add([string]$_) }
    } catch { $failure=$_.Exception.Message }
    Assert ($failure -match 'INPUTS_CHANGED_DURING_RUN') 'Input mutation during execution was accepted'
    $last=(Read-AiSopTask $spec fix-e).verifications[-1]
    foreach ($detail in @('INPUT_FILE_CHANGED:ADDED:"src/added.txt"','INPUT_FILE_CHANGED:DELETED:"src/deleted.txt"','INPUT_FILE_CHANGED:MODIFIED:"src/input.txt"')) {
        Assert (($output -join "`n").Contains($detail) -and $last.diagnostic.Contains($detail)) "Run did not print and preserve $detail"
    }
    MustFail { Task Complete fix-e } 'Unstable compile record allowed completion'
    Task Cancel fix-e | Out-Null

    # Adopt a legacy owner in the same native session without resetting its tier.
    $legacySpec = Join-Path $workspace '.ai-workspace/specs/features/Legacy'
    [IO.Directory]::CreateDirectory($legacySpec) | Out-Null
    & (Join-Path $scripts 'workflow-owner.ps1') -Operation Claim -SpecDirectory $legacySpec -Feature Legacy -Agent CODEX -Workflow SUPERPOWERS -OwnerId legacy-owner -Tier T2 | Out-Null
    # A synced task can arrive after local legacy ownership was established.
    # Adoption must not create a second ACTIVE task or consume ownership.
    $imported=Read-AiSopTask $spec 'fix-e'
    $imported.feature='Legacy'; $imported.taskId='imported'; $imported.ownerId='task-imported'; $imported.status='ACTIVE'
    $importedPath=Get-AiSopTaskPath $legacySpec 'imported'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $importedPath)) | Out-Null
    [IO.File]::WriteAllText($importedPath,(ConvertTo-AiSopWorkflowCanonicalJson $imported))
    $legacyOwnerPath=Join-Path $env:AI_SOP_OWNER_REGISTRY 'legacy.json'
    $legacyBefore=[IO.File]::ReadAllText($legacyOwnerPath)
    function Assert-LegacyResumeConflict {
        param([switch]$ConfirmTakeover)
        $failure=''
        try { & $entry -Operation Resume -WorkspacePath $workspace -Feature Legacy -Agent CODEX -ConfirmTakeover:$ConfirmTakeover | Out-Null }
        catch { $failure=$_.Exception.Message }
        Assert ($failure -match 'TASK_ACTIVE_CONFLICT:imported') "Expected active sibling diagnostic; got $failure"
    }
    Assert-LegacyResumeConflict
    Assert ([IO.File]::ReadAllText($legacyOwnerPath) -ceq $legacyBefore) 'Rejected adoption changed ownership'
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $legacySpec 'tasks') -Filter task.json -Recurse).Count -eq 1) 'Rejected adoption created a task'
    $imported.status='PAUSED'
    [IO.File]::WriteAllText($importedPath,(ConvertTo-AiSopWorkflowCanonicalJson $imported))
    & $entry -Operation Resume -WorkspacePath $workspace -Feature Legacy -Agent CODEX | Out-Null
    $legacyOwner = Get-Content -LiteralPath (Join-Path $env:AI_SOP_OWNER_REGISTRY 'legacy.json') -Raw | ConvertFrom-Json
    $adopted = Read-AiSopTask $legacySpec $legacyOwner.taskId
    Assert ($adopted.ownerId -eq 'legacy-owner' -and $adopted.tier -eq 'T2') 'Legacy adoption reset identity or tier'
    $imported.status='ACTIVE'
    [IO.File]::WriteAllText($importedPath,(ConvertTo-AiSopWorkflowCanonicalJson $imported))
    Assert-LegacyResumeConflict # Same live session uses Validate.
    $env:CODEX_SESSION_ID='conflicting-transfer-session'
    Assert-LegacyResumeConflict -ConfirmTakeover
    $env:CODEX_SESSION_ID='task-session-d'
    $boundSessionPath=Join-Path $env:AI_SOP_SESSION_REGISTRY ($legacyOwner.sessionBinding.sessionKey + '.json')
    $boundSessionRaw=[IO.File]::ReadAllText($boundSessionPath)
    try {
        $expiredSession=ConvertFrom-AiSopWorkflowJson $boundSessionRaw -AsHashtable
        $expiredSession.expiresAt=[DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')
        [IO.File]::WriteAllText($boundSessionPath,(ConvertTo-AiSopWorkflowCanonicalJson $expiredSession))
        Assert-LegacyResumeConflict # An expired same-session binding uses RebindSession.
    } finally { [IO.File]::WriteAllText($boundSessionPath,$boundSessionRaw) }
    & $entry -Operation Suspend -WorkspacePath $workspace -Feature Legacy -Agent CODEX | Out-Null
    Assert ((Read-AiSopTask $legacySpec $adopted.taskId).status -eq 'PAUSED') 'Conflict blocked cleanup by Suspend'

    # A partial PREPARED transaction restores both ownership and task state;
    # a durable COMMITTED journal finishes applying both, with the usual locks.
    $registryOwner = Join-Path $env:AI_SOP_OWNER_REGISTRY 'example.json'
    $recoveryTaskPath = Get-AiSopTaskPath $spec 'fix-e'
    foreach ($journalPhase in @('PREPARED','COMMITTED')) {
        $taskBeforeJson = Read-AiSopWorkflowCanonicalState -Path $recoveryTaskPath -SchemaId TASK
        $ownerBeforeJson = Read-AiSopWorkflowCanonicalState -Path $registryOwner -SchemaId OWNER
        $taskAfterValue = ConvertFrom-AiSopWorkflowJson $taskBeforeJson -AsHashtable
        $taskAfterValue.notes = "Recovered $journalPhase"
        $taskAfterJson = ConvertTo-AiSopWorkflowCanonicalJson $taskAfterValue
        $ownerAfterValue = ConvertFrom-AiSopWorkflowJson $ownerBeforeJson -AsHashtable
        $ownerAfterValue.lastTransactionId = 'recovery-' + $journalPhase
        $ownerAfterJson = ConvertTo-AiSopWorkflowCanonicalJson $ownerAfterValue
        $journal = @{
            schemaVersion='1.0'; transactionId=('recovery-' + $journalPhase); operation='CHECKPOINT'; phase=$journalPhase
            feature='Example'; ownerPath=$registryOwner; sessionKeys=@(); createdAt=[DateTimeOffset]::UtcNow.ToString('o')
            committedAt=$(if ($journalPhase -eq 'COMMITTED') { [DateTimeOffset]::UtcNow.ToString('o') } else { '' })
            targets=@(
                @{path=$recoveryTaskPath;kind='TASK';schemaId='TASK';before=(New-AiSopWorkflowSnapshot $true $taskBeforeJson);after=(New-AiSopWorkflowSnapshot $true $taskAfterJson)},
                @{path=$registryOwner;kind='OWNER';schemaId='OWNER';before=(New-AiSopWorkflowSnapshot $true $ownerBeforeJson);after=(New-AiSopWorkflowSnapshot $true $ownerAfterJson)}
            )
        }
        $journalPath = Join-Path $env:AI_SOP_TRANSACTION_REGISTRY ("recovery-$journalPhase.json")
        Write-AiSopWorkflowTransactionJournal -JournalPath $journalPath -Journal $journal
        [IO.File]::WriteAllText($recoveryTaskPath, $taskAfterJson)
        Invoke-AiSopWorkflowTransactionRecovery -WorkspacePath $workspace | Out-Null
        $expectedTask = if ($journalPhase -eq 'COMMITTED') { $taskAfterJson } else { $taskBeforeJson }
        $expectedOwner = if ($journalPhase -eq 'COMMITTED') { $ownerAfterJson } else { $ownerBeforeJson }
        Assert ((Read-AiSopWorkflowCanonicalState $recoveryTaskPath TASK) -ceq $expectedTask) 'Task recovery mismatch'
        Assert ((Read-AiSopWorkflowCanonicalState $registryOwner OWNER) -ceq $expectedOwner) 'Owner recovery mismatch'
    }
    MustFail { Read-AiSopTask $spec '../escape' } 'Task path traversal accepted'
    Write-Output 'PASS: task lifecycle, isolation, resume, input identity, and evidence batches'
} finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    $resolvedRoot = [IO.Path]::GetFullPath($root)
    if ($resolvedRoot.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
