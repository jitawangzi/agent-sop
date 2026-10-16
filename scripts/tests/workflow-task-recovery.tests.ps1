#requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path -Parent $PSScriptRoot
$entry=Join-Path $scripts 'workflow-task.ps1'
. (Join-Path $scripts 'task-context.ps1')
. (Join-Path $scripts 'workflow-session.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('sop-task-recovery-' + [guid]::NewGuid().ToString('N'))
$workspace=Join-Path $root 'workspace'
$spec=Join-Path $workspace '.ai-workspace/specs/features/Example'
$saved=@{}; $runner=$null
foreach ($key in @('AI_SOP_OWNER_REGISTRY','AI_SOP_SESSION_REGISTRY','AI_SOP_COMMAND_GRANT_REGISTRY','AI_SOP_TRANSACTION_REGISTRY','SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS','CODEX_SESSION_ID')) { $saved[$key]=[Environment]::GetEnvironmentVariable($key) }
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Task([string]$op, [hashtable]$extra=@{}) {
    & $entry -Operation $op -WorkspacePath $workspace -Feature Example -TaskId recovery -Agent CODEX @extra
    if ($LASTEXITCODE -ne 0) { throw "Task $op failed: $LASTEXITCODE" }
}
function Fails([scriptblock]$action, [string]$pattern) {
    $failure=''
    try { & $action | Out-Null; if ($LASTEXITCODE -ne 0) { $failure="exit=$LASTEXITCODE" } } catch { $failure=$_.Exception.Message }
    Assert ($failure -match $pattern) "Expected $pattern, received '$failure'"
}
function Read-LiveLog([string]$path) {
    $stream=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    $reader=[IO.StreamReader]::new($stream)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}
try {
    foreach ($kind in @('OWNER','SESSION','COMMAND_GRANT','TRANSACTION')) { [Environment]::SetEnvironmentVariable("AI_SOP_${kind}_REGISTRY", (Join-Path $root $kind)) }
    $env:SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS='15000'; $env:CODEX_SESSION_ID='recovery-native'
    [IO.Directory]::CreateDirectory($spec) | Out-Null
    [IO.File]::WriteAllText((Join-Path $workspace 'input.txt'), 'input')
    $sopRoot=Join-Path $workspace '.ai-sop'
    [IO.Directory]::CreateDirectory($sopRoot) | Out-Null
    Copy-Item -LiteralPath $scripts -Destination $sopRoot -Recurse
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $scripts) 'schemas') -Destination $sopRoot -Recurse
    $rootEntry=Join-Path $workspace 'ai-sop.ps1'
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $scripts) 'distribution/templates/root/ai-sop.ps1') -Destination $rootEntry
    Task Start @{ Tier='T2'; Objective='Recovery and streaming integration' } | Out-Null
    $ownerPath=Join-Path $env:AI_SOP_OWNER_REGISTRY 'example.json'
    $ownerRaw=[IO.File]::ReadAllText($ownerPath)
    $ownerRecord=ConvertFrom-AiSopWorkflowJson $ownerRaw -AsHashtable
    $sessionPath=Join-Path $env:AI_SOP_SESSION_REGISTRY ($ownerRecord.sessionBinding.sessionKey+'.json')
    $sessionRaw=[IO.File]::ReadAllText($sessionPath)
    $inspection=Task InspectRecovery | ConvertFrom-Json
    Assert (@($inspection.records | Where-Object { $_.kind -eq 'OWNER' -and $_.status -eq 'VALID' }).Count -eq 1 -and
        @($inspection.records | Where-Object { $_.kind -eq 'SESSION' -and $_.status -eq 'VALID' }).Count -eq 1) 'Matching live authority was rejected'
    try {
        $ownerRecord.taskId='different-task'
        [IO.File]::WriteAllText($ownerPath,(ConvertTo-AiSopWorkflowCanonicalJson $ownerRecord))
        $before=[IO.File]::ReadAllText($ownerPath)
        $inspection=Task InspectRecovery | ConvertFrom-Json
        Assert (@($inspection.records | Where-Object { $_.kind -eq 'OWNER' -and $_.status -eq 'OTHER_TASK' }).Count -eq 1 -and
            @($inspection.records | Where-Object kind -eq 'SESSION').Count -eq 0) 'Another task owner/session was attributed to the requested task'
        Assert ($before -ceq [IO.File]::ReadAllText($ownerPath) -and $sessionRaw -ceq [IO.File]::ReadAllText($sessionPath)) 'Inspection changed mismatched authority'
        [IO.File]::WriteAllText($ownerPath,$ownerRaw)
        foreach ($field in @('boundOwnerId','boundFeature','sessionEpochId')) {
            $sessionRecord=ConvertFrom-AiSopWorkflowJson $sessionRaw -AsHashtable
            $sessionRecord[$field]='different-identity'
            [IO.File]::WriteAllText($sessionPath,(ConvertTo-AiSopWorkflowCanonicalJson $sessionRecord))
            $inspection=Task InspectRecovery | ConvertFrom-Json
            Assert (@($inspection.records | Where-Object { $_.kind -eq 'SESSION' -and $_.status -in @('IDENTITY_MISMATCH','UNAVAILABLE') }).Count -eq 1) "Session $field mismatch was accepted"
        }
    } finally {
        [IO.File]::WriteAllText($ownerPath,$ownerRaw)
        [IO.File]::WriteAllText($sessionPath,$sessionRaw)
    }
    # A missing historical T3 baseline is independent of an expired session.
    $taskPath=Get-AiSopTaskPath $spec recovery; $taskRaw=[IO.File]::ReadAllText($taskPath)
    try {
        $legacy=ConvertFrom-AiSopWorkflowJson $taskRaw -AsHashtable
        $legacy.tier='T3'; $legacy.Remove('startInputs'); $legacy.baseline.Remove('inputsRef'); $legacy.baseline.Remove('inputDigest')
        [IO.File]::WriteAllText($taskPath,(ConvertTo-AiSopWorkflowCanonicalJson $legacy))
        $legacyRaw=[IO.File]::ReadAllText($taskPath)
        $inspection=Task InspectRecovery | ConvertFrom-Json
        Assert ($inspection.suggestedActionCode -eq 'RESTORE_BASELINE' -and $inspection.guidance -match 'Resume only repairs') 'Missing baseline was reduced to a session handoff'
        $steps=@(Get-AiSopRecoveryGuidance $legacy @(@{kind='BASELINE';status='UNAVAILABLE'}) ACTIVE EXPIRED)
        Assert (($steps.code -join ',') -ceq 'RESTORE_BASELINE,RESUME_SESSION') 'Expired session hid the independent baseline problem'
        $status=Task Discover @{OutputFormat='JsonLines'} | ConvertFrom-Json
        Assert ($status.suggestedActionCode -ceq $inspection.suggestedActionCode) 'Discover and InspectRecovery disagree on missing baseline'
        Assert ($legacyRaw -ceq [IO.File]::ReadAllText($taskPath) -and $ownerRaw -ceq [IO.File]::ReadAllText($ownerPath) -and $sessionRaw -ceq [IO.File]::ReadAllText($sessionPath)) 'Recovery guidance changed authority'
    } finally { [IO.File]::WriteAllText($taskPath,$taskRaw) }
    $steps=@(Get-AiSopRecoveryGuidance @{status='PAUSED'} @() RELEASED MISSING)
    Assert ($steps[0].code -eq 'RESUME_SESSION') 'Normal paused task unnecessarily requires Recover'
    Task RecordSync @{ Documentation='UNCHANGED'; Tests='UNCHANGED'; Summary='Recovery fixture uses existing command scenarios; no contract change.' } | Out-Null
    # A synchronized task record grants no execution ownership in another workspace.
    $remoteWorkspace=Join-Path $root 'receiver'
    $remoteSpec=Join-Path $remoteWorkspace '.ai-workspace/specs/features/Example'
    $remoteTaskPath=Get-AiSopTaskPath $remoteSpec 'recovery'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $remoteTaskPath)) | Out-Null
    Copy-Item -LiteralPath (Get-AiSopTaskPath $spec 'recovery') -Destination $remoteTaskPath
    $localOwnerRegistry=$env:AI_SOP_OWNER_REGISTRY
    try {
        $env:AI_SOP_OWNER_REGISTRY=Join-Path $root 'receiver-owner'
        Fails { & $entry -Operation Resume -WorkspacePath $remoteWorkspace -Feature Example -TaskId recovery -Agent CODEX } 'TASK_NOT_RESUMABLE'
        $before=[IO.File]::ReadAllText($remoteTaskPath)
        Fails { & $entry -Operation Start -WorkspacePath $remoteWorkspace -Feature Example -TaskId independent -Tier T1 -Objective 'Independent work' -Agent CODEX } 'TASK_ACTIVE_CONFLICT:recovery'
        Assert ($before -ceq [IO.File]::ReadAllText($remoteTaskPath) -and -not (Test-Path -LiteralPath (Get-AiSopTaskPath $remoteSpec 'independent'))) 'Rejected orphan conflict mutated tasks'
        Assert (-not (Test-Path -LiteralPath (Join-Path $env:AI_SOP_OWNER_REGISTRY 'example.json'))) 'Rejected orphan conflict acquired ownership'
        # Legacy Claim must not bypass task-level exclusivity either.
        Fails { & (Join-Path $scripts 'workflow-owner.ps1') -Operation Claim -SpecDirectory $remoteSpec -Feature Example -OwnerId legacy -Agent CODEX } 'TASK_ACTIVE_CONFLICT:recovery'
        & $entry -Operation Recover -WorkspacePath $remoteWorkspace -Feature Example -TaskId recovery -Agent CODEX | Out-Null
        & $entry -Operation Start -WorkspacePath $remoteWorkspace -Feature Example -TaskId independent -Tier T1 -Objective 'Independent work after recovery' -Agent CODEX | Out-Null
        Assert ($LASTEXITCODE -eq 0) 'Paused orphan blocked independent work'
        & $entry -Operation Cancel -WorkspacePath $remoteWorkspace -Feature Example -TaskId independent -Agent CODEX | Out-Null
        # Resuming a paused task also checks synced ACTIVE siblings even when
        # the local owner registry contains only an unrelated terminal owner.
        $foreign=ConvertFrom-AiSopWorkflowJson $before -AsHashtable
        $foreign.taskId='imported'; $foreign.ownerId='task-imported'
        $foreign.Remove('startInputs'); $foreign.Remove('startImpact')
        $foreignPath=Get-AiSopTaskPath $remoteSpec 'imported'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $foreignPath)) | Out-Null
        [IO.File]::WriteAllText($foreignPath,(ConvertTo-AiSopWorkflowCanonicalJson $foreign))
        Fails { & $entry -Operation Resume -WorkspacePath $remoteWorkspace -Feature Example -TaskId recovery -Agent CODEX } 'TASK_ACTIVE_CONFLICT:imported'
        & $entry -Operation Recover -WorkspacePath $remoteWorkspace -Feature Example -TaskId imported -Agent CODEX | Out-Null
        & $entry -Operation Resume -WorkspacePath $remoteWorkspace -Feature Example -TaskId recovery -Agent CODEX | Out-Null
        $remoteOwner=Get-Content -LiteralPath (Join-Path $env:AI_SOP_OWNER_REGISTRY 'example.json') -Raw | ConvertFrom-Json
        Assert ($remoteOwner.workspacePath -ceq (Resolve-PhysicalPathIdentity $remoteWorkspace)) 'Receiver inherited sender authority'
        & $entry -Operation Suspend -WorkspacePath $remoteWorkspace -Feature Example -TaskId recovery -Agent CODEX | Out-Null
    } finally { $env:AI_SOP_OWNER_REGISTRY=$localOwnerRegistry }
    Assert ((Read-AiSopTask $spec 'recovery').status -eq 'ACTIVE') 'Receiver changed sender task'
    Fails { Task Recover } 'SESSION_MAY_BE_ACTIVE'
    Task Recover @{ ForceRecovery=$true; Notes='Old agent stopped' } | Out-Null
    Assert ((Read-AiSopTask $spec 'recovery').status -eq 'PAUSED') 'Recover did not pause task'
    $ownerPath=Join-Path $env:AI_SOP_OWNER_REGISTRY 'example.json'
    $released=Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json
    $session=Get-AiSopWorkflowSession -SessionKey $released.sessionBinding.sessionKey -WorkspacePath $workspace
    Assert (-not $session.Record.boundOwnerId) 'Recover left old session bound'
    $status=Task Status @{OutputFormat="JsonLines"} | ConvertFrom-Json
    $discover=Task Discover @{OutputFormat="JsonLines"} | ConvertFrom-Json
    Assert ($status.status -eq 'PAUSED' -and $discover.status -eq $status.status -and $status.ownerStatus -eq 'RELEASED') 'Discover/Status disagree'
    $rootStatus=& $rootEntry Status -Feature Example -TaskId recovery -OutputFormat JsonLines | ConvertFrom-Json
    Assert ($rootStatus.status -eq $status.status -and $rootStatus.ownerStatus -eq $status.ownerStatus) 'Root Status still shows legacy state'
    Task Resume | Out-Null
    & (Join-Path $scripts 'workflow-owner.ps1') -Operation ForceRelease -Feature Example -SpecDirectory $spec -Workflow SUPERPOWERS -Agent CODEX -OwnerId 'task-recovery' | Out-Null
    Assert ((Read-AiSopTask $spec 'recovery').status -eq 'PAUSED') 'Legacy ForceRelease orphaned task state'
    Task Resume | Out-Null
    Invoke-AiSopWorkflowSession -Operation End -Agent CODEX -NativeSessionId $env:CODEX_SESSION_ID -WorkspacePath $workspace -AcceptedAt ([DateTimeOffset]::UtcNow) | Out-Null
    Task Recover | Out-Null
    $env:CODEX_SESSION_ID='recovery-native-new'
    Task Resume | Out-Null
    # Missing local owner must not silently inherit permissions from a mirror.
    Remove-Item -LiteralPath $ownerPath
    Fails { Task Resume } 'TASK_NOT_RESUMABLE'
    Task Recover @{ ForceRecovery=$true } | Out-Null
    Assert (-not (Test-Path -LiteralPath $ownerPath)) 'Recovery recreated active authority from mirror'
    Task Resume | Out-Null

    $contextDir=Join-Path $workspace '.ai-workspace/context'
    [IO.Directory]::CreateDirectory($contextDir) | Out-Null
    $configPath=Join-Path $contextDir 'verification-commands.json'
    $config=@{ schemaVersion='1.0'; commands=@{
        build=@{kind='compile';executable='pwsh';arguments=@('-NoProfile','-Command',"if (-not (Test-Path input.txt)) { exit 2 }; Write-Output 'BUILD_OK'")}
        check=@{kind='test';batch='regression';executable='pwsh';arguments=@('-NoProfile','-Command',"if ([IO.File]::ReadAllText('input.txt') -ne 'input') { exit 2 }; Write-Output 'TEST_OK'")}
        slow=@{kind='test';batch='regression';executable='pwsh';arguments=@('-NoProfile','-Command',"[Console]::WriteLine('READY'); [Console]::Out.Flush(); Start-Sleep -Seconds 60")}
    }}
    [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 10))
    Task Run @{Profile='build'} | Out-Null
    Task Run @{Profile='check'} | Out-Null
    Task Verify | Out-Null
    Fails { Task Run @{ Profile='build'; Executable='pwsh' } } 'PROFILE_OVERRIDE_FORBIDDEN'
    Fails { Task Run @{ Profile='missing' } } 'PROFILE_NOT_FOUND'
    Fails { Task Run @{ Profile='slow'; TimeoutSeconds=1; Reason='Exercise timeout instead of the normal regression command' } } 'Task Run failed'
    $last=(Read-AiSopTask $spec 'recovery').verifications[-1]
    Assert ($last.outcome -eq 'TIMED_OUT' -and $last.exitCode -eq 124) 'Timeout was not recorded'
    Assert ($last.diagnostic -match 'VERIFICATION_TIMED_OUT' -and (Read-LiveLog (Get-AiSopRunLogPath $last $workspace $spec recovery)) -match 'VERIFICATION_TIMED_OUT') 'Timeout reason was lost from evidence/log'
    Fails { Task Verify } 'Task Verify failed'

    # Inject the cleanup outcome only in this disposable installed copy. Real
    # resources are still released; production has no fault-injection switch.
    $installedHelper=Join-Path $sopRoot 'scripts/hidden-process.ps1'
    $helperRaw=[IO.File]::ReadAllText($installedHelper)
    $cleanupFixture=@'

function Invoke-AiSopProcessCleanup {
    param([Diagnostics.Process]$Process,[bool]$Started=$true,[bool]$Terminate=$true,
        [Threading.CancellationTokenSource]$Cancellation,[Threading.Tasks.Task[]]$Copies=@(),
        [IDisposable[]]$Resources=@(),[int]$BudgetMilliseconds=5000)
    $isRun=@($Resources | Where-Object { $_ -is [IO.StreamWriter] }).Count -gt 0
    $observed='MISSING'
    if ($isRun) {
        $pending=Get-AiSopRunEvidencePath $SpecDirectory $TaskId $runId
        if ([IO.File]::Exists($pending)) { $observed=(Get-Content -LiteralPath $pending -Raw | ConvertFrom-Json).outcome }
    }
    $result=Invoke-AiSopProcessCleanupReal @PSBoundParameters
    if ($isRun) { $result.confirmed=$false; $result.diagnostic="PROCESS_CLEANUP_TIMED_OUT: injected; preCleanupOutcome=$observed" }
    return $result
}
'@
    try {
        [IO.File]::WriteAllText($installedHelper,($helperRaw.Replace('function Invoke-AiSopProcessCleanup {','function Invoke-AiSopProcessCleanupReal {')+$cleanupFixture))
        foreach ($profileName in @('slow','check')) {
            & (Join-Path $sopRoot 'scripts/workflow-task.ps1') -Operation Run -WorkspacePath $workspace -Feature Example -TaskId recovery -Agent CODEX -Profile $profileName -TimeoutSeconds $(if ($profileName -eq 'slow') { 1 } else { 15 }) -Reason 'Exercise cleanup failure evidence' | Out-Null
            Assert ($LASTEXITCODE -ne 0) 'Unconfirmed cleanup passed verification'
            $last=(Read-AiSopTask $spec recovery).verifications[-1]
            Assert ($last.diagnostic -match 'PROCESS_CLEANUP_TIMED_OUT') 'Cleanup failure diagnosis was lost'
            if ($profileName -eq 'slow') {
                Assert ($last.outcome -eq 'TIMED_OUT' -and $last.exitCode -eq 124 -and $last.diagnostic -match 'preCleanupOutcome=TIMED_OUT') 'Failure was not durable before cleanup or lost its original code'
            } else {
                Assert ($last.outcome -eq 'FAILED' -and $last.exitCode -ne 0) 'Exit-zero child hid cleanup failure'
            }
        }
    } finally { [IO.File]::WriteAllText($installedHelper,$helperRaw) }

    # A successful launcher can leave a descendant holding its stdout pipe.
    # Even TimeoutSeconds=0 must not hang after the launcher has exited, and
    # that incomplete output must not become PASSED evidence.
    $pipeWorker=Join-Path $root 'pipe-worker.ps1'
    $pipeIdentity=Join-Path $root 'pipe-child.json'
    [IO.File]::WriteAllText($pipeWorker, @'
param([string]$IdentityFile)
$info=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
$info.UseShellExecute=$false; $info.CreateNoWindow=$true
foreach ($arg in @('-NoProfile','-Command','Write-Output "pipe-ready"; Start-Sleep 60')) { $info.ArgumentList.Add($arg) }
$child=[Diagnostics.Process]::Start($info)
@{id=$child.Id;startedTicks=$child.StartTime.ToUniversalTime().Ticks} | ConvertTo-Json | Set-Content -LiteralPath $IdentityFile
exit 0
'@)
    try {
        $clock=[Diagnostics.Stopwatch]::StartNew()
        Fails { Task Run @{Kind='test';Batch='regression';Executable='pwsh';Arguments=@('-NoProfile','-File',$pipeWorker,$pipeIdentity);TimeoutSeconds=0;Reason='Exercise inherited output pipe deadline'} } 'Task Run failed'
        $last=(Read-AiSopTask $spec recovery).verifications[-1]
        Assert ($last.outcome -eq 'FAILED' -and $last.diagnostic -match 'OUTPUT_DRAIN_TIMED_OUT' -and $clock.Elapsed.TotalSeconds -lt 20) 'Inherited output pipe escaped deadline or passed verification'
        Fails { Task Verify } 'Task Verify failed'
    } finally {
        if (Test-Path -LiteralPath $pipeIdentity) {
            $identity=Get-Content -LiteralPath $pipeIdentity -Raw | ConvertFrom-Json
            $descendant=Get-Process -Id $identity.id -ErrorAction SilentlyContinue
            if ($descendant) {
                try { if (-not $descendant.HasExited -and $descendant.StartTime.ToUniversalTime().Ticks -eq $identity.startedTicks) { $descendant.Kill($true); [void]$descendant.WaitForExit(3000) } }
                finally { $descendant.Dispose() }
            }
        }
    }
    Task Run @{Profile='check'; Reason='Restore normal regression after timeout'} | Out-Null

    # Launch an actual external runner and inspect its durable log while running.
    $runner=[Diagnostics.Process]::new()
    $runner.StartInfo.FileName=(@(Get-Command pwsh -CommandType Application)[0]).Source
    $runner.StartInfo.UseShellExecute=$false; $runner.StartInfo.CreateNoWindow=$true
    $runner.StartInfo.RedirectStandardOutput=$true; $runner.StartInfo.RedirectStandardError=$true
    foreach ($arg in @('-NoProfile','-File',$entry,'-Operation','Run','-WorkspacePath',$workspace,'-Feature','Example','-TaskId','recovery','-Agent','CODEX','-Profile','slow','-Reason','Exercise interrupted execution')) { $runner.StartInfo.ArgumentList.Add($arg) }
    Assert ($runner.Start()) 'Runner launch failed'
    $stdout=$runner.StandardOutput.ReadToEndAsync(); $stderr=$runner.StandardError.ReadToEndAsync()
    $deadline=[DateTimeOffset]::UtcNow.AddSeconds(20); $streamed=$false
    while ([DateTimeOffset]::UtcNow -lt $deadline -and -not $runner.HasExited) {
        $live=(Read-AiSopTask $spec 'recovery').verifications[-1]
        if ($live.outcome -eq 'RUNNING' -and $live.context.childPid) {
            $log=Get-AiSopRunLogPath $live $workspace $spec 'recovery'
            if ((Test-Path -LiteralPath $log) -and (Read-LiveLog $log).Contains('READY')) { $streamed=$true; break }
        }
        [Threading.Thread]::Sleep(100)
    }
    Assert $streamed "Output was not streamed before exit: $($runner.HasExited)"
    $liveStatus=Task Status @{OutputFormat="JsonLines"} | ConvertFrom-Json
    Assert ($liveStatus.runs[0].activity -eq 'RUNNING') 'Status missed running process'
    Assert ($liveStatus.suggestedActionCode -eq 'WAIT_FOR_RUN') 'Live command suggested recovery'
    Assert ($liveStatus.runs[0].elapsedSeconds -ge 0 -and $liveStatus.runs[0].timeoutSeconds -eq 0 -and
        $liveStatus.runs[0].logBytes -gt 0 -and $liveStatus.runs[0].logUpdatedAt -and
        $liveStatus.runs[0].logTail.Count -eq 0 -and $liveStatus.runs[0].tailBytesRead -eq 0) 'Default status omitted progress or read log contents'
    $rootStatus=& $rootEntry Status -Feature Example -TaskId recovery -LogTailLines 2 -Json | ConvertFrom-Json
    Assert ($LASTEXITCODE -eq 0 -and 'READY' -in $rootStatus.tasks[0].runs[0].logTail) 'Root Status did not forward bounded log tail'
    Fails { Task Recover @{ForceRecovery=$true} } 'RUN_STILL_ACTIVE'
    Fails { Task Resume } 'RUN_UNFINISHED'
    Fails { Task Suspend } 'RUN_UNFINISHED'
    Fails { Task Run @{Profile='build'} } 'RUN_UNFINISHED'
    Fails { Task ChangeTier @{Tier='T1';Reason='Requested quicker handoff';UserRequest='Use T1'} } 'RUN_UNFINISHED'
    Task AddFollowUp @{FollowUpId='runner-doc';FollowUpKind='documentation';Summary='Explain interruption recovery';Scope=@('runtime documentation')} | Out-Null
    Assert ((Read-AiSopTask $spec recovery).verifications[-1].outcome -eq 'RUNNING') 'Recording a follow-up changed the running verification'
    # Only terminate the Process instance created by this test, including its child.
    $runner.Kill($true); $runner.WaitForExit(5000) | Out-Null
    $runner.Dispose(); $runner=$null
    $abandoned=Task Status @{OutputFormat="JsonLines"} | ConvertFrom-Json
    Assert ($abandoned.runs[0].activity -eq 'INTERRUPTED') 'Abrupt termination not diagnosed'
    Fails { Task Complete } 'RUN_UNFINISHED'
    $pendingPath=Get-AiSopRunEvidencePath $spec recovery $live.runId
    $live=(Read-AiSopTask $spec recovery).verifications[-1]
    [IO.File]::WriteAllText($pendingPath,(ConvertTo-AiSopWorkflowCanonicalJson $live))
    $status=Task Status @{OutputFormat='JsonLines'} | ConvertFrom-Json
    Assert ($status.runs[0].pendingStatus -eq 'VALID' -and $status.runs[0].pendingOutcome -eq 'RUNNING' -and $status.suggestedActionCode -eq 'RECOVER_RUN') 'Valid RUNNING pending was treated as a terminal result'
    $terminal=ConvertFrom-AiSopWorkflowJson (ConvertTo-AiSopWorkflowCanonicalJson $live) -AsHashtable
    $terminal.outcome='FAILED'; $terminal.exitCode=1
    [IO.File]::WriteAllText($pendingPath,(ConvertTo-AiSopWorkflowCanonicalJson $terminal))
    $taskBefore=[IO.File]::ReadAllText((Get-AiSopTaskPath $spec recovery)); $ownerBefore=[IO.File]::ReadAllText($ownerPath)
    $status=Task Status @{OutputFormat='JsonLines'} | ConvertFrom-Json
    Assert ($status.runs[0].pendingStatus -eq 'VALID' -and $status.runs[0].pendingOutcome -eq 'FAILED' -and $status.suggestedActionCode -eq 'RETRY_EVIDENCE') 'Validated terminal pending did not suggest saving the result'
    Assert ($taskBefore -ceq [IO.File]::ReadAllText((Get-AiSopTaskPath $spec recovery)) -and $ownerBefore -ceq [IO.File]::ReadAllText($ownerPath)) 'Status saved pending evidence or changed authority'
    # Log inspection is bounded, optional, and never reads a remote run's local namesake.
    $progressRecord=ConvertFrom-AiSopWorkflowJson (ConvertTo-AiSopWorkflowCanonicalJson $live) -AsHashtable
    $progressRecord.context.logPath='.ai-workspace/.runtime/progress.log'; $progressRecord.context.Remove('timeoutSeconds')
    $progressLog=Resolve-AiSopWorkspaceChild $workspace $progressRecord.context.logPath
    [IO.File]::WriteAllText($progressLog,(('x'*65536)+"`nfirst`nlast`n"))
    $progress=Get-AiSopRunProgress $progressRecord $workspace $spec recovery -LogTailLines 2
    Assert ($progress.timeoutSeconds -eq $null -and $progress.tailBytesRead -eq 32768 -and $progress.tailTruncated -and ($progress.logTail -join ',') -ceq 'first,last') 'Log tail exceeded bounds or invented a legacy timeout'
    $progressRecord.context.runnerMachine='remote-fixture'
    $progress=Get-AiSopRunProgress $progressRecord $workspace $spec recovery -LogTailLines 2
    Assert ($progress.logStatus -eq 'REMOTE_UNKNOWN' -and $progress.tailBytesRead -eq 0 -and $progress.logTail.Count -eq 0) 'Remote run read a local log'
    $progressRecord.context.runnerMachine=[Environment]::MachineName; $progressRecord.context.logPath='../outside.log'
    $progress=Get-AiSopRunProgress $progressRecord $workspace $spec recovery -LogTailLines 2
    Assert ($progress.logStatus -eq 'UNAVAILABLE' -and $progress.diagnostics.Count -gt 0) 'Invalid log path did not degrade to a diagnostic'
    [IO.File]::WriteAllText($pendingPath,'{damaged result')
    $diagnostic=Task InspectRecovery | ConvertFrom-Json
    Assert (@($diagnostic.records | Where-Object { $_.kind -eq 'PENDING' -and $_.status -eq 'INVALID' }).Count -eq 1) 'Corrupt pending result not diagnosed'
    $status=Task Status @{OutputFormat='JsonLines'} | ConvertFrom-Json
    Assert ($status.suggestedActionCode -eq 'INSPECT_PENDING' -and $status.suggestedActionCode -ceq $diagnostic.suggestedActionCode) 'Status suggested retrying corrupt pending evidence'
    Fails { Task Recover @{ForceRecovery=$true} } 'PENDING_EVIDENCE_INVALID'
    Assert ((Read-AiSopTask $spec recovery).verifications[-1].outcome -eq 'RUNNING') 'Rejected recovery changed task state'
    Fails { Task Recover @{ForceRecovery=$true;QuarantineInvalidEvidence=$true} } 'QUARANTINE_REASON_REQUIRED'
    Task Recover @{ForceRecovery=$true;QuarantineInvalidEvidence=$true;Reason='Interrupted writer left malformed result; rerun verification'} | Out-Null
    $recovered=Read-AiSopTask $spec 'recovery'
    $backup=Resolve-AiSopWorkspaceChild $workspace $recovered.lastRecovery.quarantinedEvidence[0].backupPath
    Assert ([IO.File]::ReadAllText($backup) -ceq '{damaged result') 'Quarantine did not preserve exact bytes'
    Assert (-not [IO.File]::Exists($pendingPath)) 'Committed quarantine left invalid pending result'
    Assert ($recovered.verifications[-1].outcome -eq 'INTERRUPTED' -and $recovered.status -eq 'PAUSED') 'Interrupted result lost during recovery'
    $taskPath=Get-AiSopTaskPath $spec recovery; $taskRaw=[IO.File]::ReadAllText($taskPath)
    [IO.File]::WriteAllText($taskPath,'{damaged authority')
    try {
        $diagnostic=Task InspectRecovery | ConvertFrom-Json
        Assert (@($diagnostic.records | Where-Object { $_.kind -eq 'TASK' -and $_.status -eq 'UNAVAILABLE' }).Count -eq 1) 'Damaged task authority crashed inspection'
        Assert ([IO.File]::ReadAllText($taskPath) -ceq '{damaged authority') 'Read-only inspection rewrote authority'
    } finally { [IO.File]::WriteAllText($taskPath,$taskRaw) }
    Task Resume | Out-Null
    Fails { Task Verify } 'Task Verify failed'
    Task Run @{Profile='check'; Reason='Restore normal regression after interruption'} | Out-Null
    Task Complete | Out-Null
    Write-Output 'PASS: recovery, status consistency, project profiles, timeout, streaming, abrupt termination'
} finally {
    if ($runner) { if (-not $runner.HasExited) { $runner.Kill($true); $runner.WaitForExit(5000) | Out-Null }; $runner.Dispose() }
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key]) }
    $resolved=[IO.Path]::GetFullPath($root)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
}
