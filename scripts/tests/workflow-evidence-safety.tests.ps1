#requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path -Parent $PSScriptRoot
$entry=Join-Path $scripts 'workflow-task.ps1'
$ownerScript=Join-Path $scripts 'workflow-owner.ps1'
. (Join-Path $scripts 'task-context.ps1')
. (Join-Path $scripts 'workflow-session.ps1')
. (Join-Path $scripts 'workflow-command-grant.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('sop-evidence-safety-' + [guid]::NewGuid().ToString('N'))
$workspace=Join-Path $root 'workspace'
$spec=Join-Path $workspace '.ai-workspace/specs/features/Example'
$pwsh=(@(Get-Command pwsh -CommandType Application)[0]).Source
$saved=@{}; $runner=$null; $heldLock=$null
foreach ($key in @('AI_SOP_OWNER_REGISTRY','AI_SOP_SESSION_REGISTRY','AI_SOP_COMMAND_GRANT_REGISTRY','AI_SOP_TRANSACTION_REGISTRY','SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS','CODEX_SESSION_ID','ANTIGRAVITY_SESSION_ID','AI_SESSION_ID','SESSION_ID','PATH')) { $saved[$key]=[Environment]::GetEnvironmentVariable($key) }
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Fails([scriptblock]$action, [string]$pattern) {
    $failure=''
    try { & $action | Out-Null; if ($LASTEXITCODE -ne 0) { $failure="exit=$LASTEXITCODE" } } catch { $failure=$_.Exception.Message }
    Assert ($failure -match $pattern) "Expected $pattern; received '$failure'"
}
function Task([string]$op, [string]$id, [hashtable]$extra=@{}) {
    & $entry -Operation $op -WorkspacePath $workspace -Feature Example -TaskId $id @extra
    if ($LASTEXITCODE -ne 0) { throw "Task $op failed: $LASTEXITCODE" }
}
function Put([string]$relative, [string]$text) {
    $path=Join-Path $workspace $relative
    [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
    [IO.File]::WriteAllText($path,$text)
}
function Owner { return ConvertFrom-AiSopWorkflowJson ([IO.File]::ReadAllText((Join-Path $env:AI_SOP_OWNER_REGISTRY 'example.json'))) -AsHashtable }
function Read-LiveLog([string]$path) {
    $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    $reader=[IO.StreamReader]::new($stream)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}
function Wait-Until([scriptblock]$condition, [string]$message) {
    $deadline=[DateTimeOffset]::UtcNow.AddSeconds(40)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (& $condition) { return }
        [Threading.Thread]::Sleep(100)
    }
    throw $message
}
function Launch-Runner([string]$id, [string]$child) {
    $p=[Diagnostics.Process]::new()
    $p.StartInfo.FileName=$pwsh; $p.StartInfo.UseShellExecute=$false; $p.StartInfo.CreateNoWindow=$true
    $p.StartInfo.RedirectStandardOutput=$true; $p.StartInfo.RedirectStandardError=$true
    $p.StartInfo.Environment['SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS']='5000'
    # Pass array arguments through a saved wrapper: native -File cannot bind a
    # PowerShell array containing switches to a script's string[] parameter.
    $wrapper=Join-Path $root "$id-runner.ps1"
    $quoted=@($entry,$workspace,$id,$pwsh,$child) | ForEach-Object { "'" + $_.Replace("'","''") + "'" }
    [IO.File]::WriteAllText($wrapper, "& $($quoted[0]) -Operation Run -WorkspacePath $($quoted[1]) -Feature Example -TaskId $($quoted[2]) -Kind compile -Executable $($quoted[3]) -Arguments @('-NoProfile','-File',$($quoted[4])); exit `$LASTEXITCODE")
    $p.StartInfo.ArgumentList.Clear()
    foreach ($arg in @('-NoProfile','-File',$wrapper)) { $p.StartInfo.ArgumentList.Add($arg) }
    Assert ($p.Start()) 'Runner did not start'
    $script:runnerOut=$p.StandardOutput.ReadToEndAsync(); $script:runnerErr=$p.StandardError.ReadToEndAsync()
    return $p
}
try {
    foreach ($kind in @('OWNER','SESSION','COMMAND_GRANT','TRANSACTION')) { [Environment]::SetEnvironmentVariable("AI_SOP_${kind}_REGISTRY", (Join-Path $root $kind)) }
    $env:SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS='15000'; $env:CODEX_SESSION_ID='safety-session'
    $env:ANTIGRAVITY_SESSION_ID=$null; $env:AI_SESSION_ID=$null; $env:SESSION_ID=$null
    [IO.Directory]::CreateDirectory($spec) | Out-Null
    foreach ($name in @('build','bin','out','target','classes','obj')) { Put "src/package/$name/source.txt" 'source' }
    Put 'scripts/bin/helper.txt' 'source'
    Put 'module/pom.xml' '<project/>'
    Put 'webapp/WEB-INF/web.xml' '<web-app/>'
    $before=Get-AiSopInputSnapshot $workspace
    foreach ($name in @('build','bin','out','target','classes','obj')) { Assert ($before.files.ContainsKey("src/package/$name/source.txt")) "Source package $name was excluded" }
    Assert ($before.files.ContainsKey('scripts/bin/helper.txt')) 'Script directory was excluded'
    Put '.git' 'gitdir: /worktree/location'
    Put '.ai-sop-staging/payload.txt' 'staging'
    Put 'build/output.bin' 'output'; Put 'module/target/output.bin' 'output'
    Put 'webapp/WEB-INF/classes/Compiled.class' 'generated'
    foreach ($name in @('app.log','app.log.1','app.log.zip','app.log.2.gz','app.log.2026-10-15.gz','app.log.2026-10-15.2.zip','app.log.2026.10.15','app.log.2026-10-15')) { Put "runtime/$name" 'generated' }
    Assert ((Get-AiSopInputSnapshot $workspace).digest -ceq $before.digest) 'Metadata, module outputs or rotated logs changed input identity'
    Put 'src/package/build/source.txt' 'changed source'
    Assert ((Get-AiSopInputSnapshot $workspace).digest -cne $before.digest) 'Source change failed to invalidate inputs'
    Remove-Item -LiteralPath (Join-Path $workspace '.git')

    # Omitted Agent is inferred from this invocation, never from the old owner.
    Task Start evidence @{Tier='T2';Objective='Exercise evidence integrity'} | Out-Null
    Task RecordSync evidence @{Documentation='UNCHANGED';Tests='UNCHANGED';Summary='Existing contracts and fixture cases apply'} | Out-Null
    $ok=@{Executable=$pwsh;Arguments=@('-NoProfile','-Command','exit 0')}
    Task Run evidence (@{Kind='compile'} + $ok) | Out-Null
    Task Run evidence (@{Kind='test'} + $ok) | Out-Null
    $task=Read-AiSopTask $spec evidence
    $fake=ConvertFrom-AiSopWorkflowJson (ConvertTo-AiSopWorkflowCanonicalJson $task.verifications[-1]) -AsHashtable
    $fake.runId=[guid]::NewGuid().ToString('N')
    $fakePath=Get-AiSopRunEvidencePath $spec evidence $fake.runId
    [IO.File]::WriteAllText($fakePath,(ConvertTo-AiSopWorkflowCanonicalJson $fake))
    Fails { & $ownerScript -Operation Checkpoint -Feature Example -SpecDirectory $spec -OwnerId task-evidence -TaskId evidence -Agent CODEX -EvidencePath $fakePath } 'RUN_BEGIN_REQUIRED'
    Assert ((Read-AiSopTask $spec evidence).verifications.Count -eq 2) 'Forged terminal result was appended'
    Fails { Task Run evidence @{Kind='test';Executable=$pwsh;Arguments=@('-NoProfile','-Command','exit 3')} } 'BATCH_DEFINITION_CHANGED'
    Fails { Task Run evidence (@{Kind='test';CaseIds=@('new-scope')} + $ok) } 'BATCH_DEFINITION_CHANGED'
    Fails { Task Run evidence @{Kind='test';Executable=$pwsh;Arguments=@('-NoProfile','-Command','exit 3');Reason='Exercise a failing replacement'} } 'Task Run failed'
    Fails { Task Verify evidence } 'Task Verify failed'
    Fails { Task Run evidence (@{Kind='test'} + $ok) } 'BATCH_DEFINITION_CHANGED'
    Task Run evidence (@{Kind='test';Reason='Restore fixture command after negative test'} + $ok) | Out-Null
    Assert ((Read-AiSopTask $spec evidence).verifications[-1].context.batchChangeReason) 'Command replacement explanation was lost'
    # Replay after a lost acknowledgement is idempotent and executes no command.
    $result=(Read-AiSopTask $spec evidence).verifications[-1]
    $resultPath=Get-AiSopRunEvidencePath $spec evidence $result.runId
    [IO.File]::WriteAllText($resultPath,(ConvertTo-AiSopWorkflowCanonicalJson $result))
    Task RetryEvidence evidence @{RunId=$result.runId} | Out-Null
    Assert ((Read-AiSopTask $spec evidence).verifications.Count -eq 4) 'Retry duplicated an execution'

    $originalOwner=Owner
    $staleCommand="pwsh -NoProfile -File './.ai-sop/scripts/workflow-owner.ps1' -Operation 'Checkpoint' -SpecDirectory '$spec' -Feature 'Example' -Workflow 'SUPERPOWERS' -Agent 'CODEX' -OwnerId 'task-evidence'"
    $oldGrant=Invoke-AiSopWorkflowCommandGrant -Operation Issue -CommandText $staleCommand -SessionKey $originalOwner.sessionBinding.sessionKey -SessionEpochId $originalOwner.sessionBinding.sessionEpochId -DedupKey (Get-AiSopWorkflowSha256 'stale-checkpoint') -AcceptedAt ([DateTimeOffset]::UtcNow) -TransactionId 'test-stale-checkpoint' -GrantTtlSeconds 300 -WorkspacePath $workspace
    $env:CODEX_SESSION_ID='unrelated-session'
    Fails { Task Checkpoint evidence @{NextAction='not authorized'} } 'WORKFLOW_OWNER_SESSION_MISMATCH'
    Assert ((Get-Content -LiteralPath $oldGrant.GrantPath -Raw | ConvertFrom-Json).status -eq 'ISSUED') 'Unrelated session consumed the old grant'
    Fails { Task Resume evidence } 'SESSION_MAY_BE_ACTIVE'
    Task Resume evidence @{ConfirmTakeover=$true} | Out-Null
    Task Checkpoint evidence @{NextAction='New owner ignores a foreign session grant'} | Out-Null
    $env:CODEX_SESSION_ID='safety-session'
    Fails { Task Checkpoint evidence } 'WORKFLOW_OWNER_SESSION_MISMATCH'
    $env:CODEX_SESSION_ID='unrelated-session'
    Task Complete evidence | Out-Null
    # A terminal owner of another task must neither block recovery nor change.
    $historicalOwner=ConvertTo-AiSopWorkflowCanonicalJson (Owner)
    $imported=Read-AiSopTask $spec evidence
    $imported.taskId='imported'; $imported.ownerId='task-imported'; $imported.status='ACTIVE'; $imported.verifications=@()
    $importPath=Get-AiSopTaskPath $spec imported
    [IO.Directory]::CreateDirectory((Split-Path -Parent $importPath)) | Out-Null
    [IO.File]::WriteAllText($importPath,(ConvertTo-AiSopWorkflowCanonicalJson $imported))
    Task Recover imported | Out-Null
    Assert ((ConvertTo-AiSopWorkflowCanonicalJson (Owner)) -ceq $historicalOwner) 'Recovery rewrote unrelated historical ownership'
    Task Resume imported | Out-Null
    Task Cancel imported | Out-Null

    Task Start paths @{Tier='T1'; UserRequest='本测试明确选择 T1';Objective='Workspace executable and optional VCS metadata'} | Out-Null
    $svnFixture=Join-Path $workspace '.svn'
    [IO.Directory]::CreateDirectory($svnFixture) | Out-Null
    try {
        $env:PATH=Join-Path $root 'empty-path'
        $relative=[IO.Path]::GetRelativePath($workspace,$pwsh)
        Task Run paths @{Kind='compile';Executable=$relative;Arguments=@('-NoProfile','-Command',"if (-not (Test-Path src/package/build/source.txt)) { exit 5 }")} | Out-Null
        Assert ((Read-AiSopTask $spec paths).verifications[-1].context.codeSvnMetadata -eq 'CLI_MISSING') 'Missing SVN did not produce a metadata annotation'
        Fails { New-AiSopTaskBaseline $workspace } 'TASK_BASELINE_UNAVAILABLE: SVN CLI missing'
    } finally {
        $env:PATH=$saved.PATH
        # This empty marker only models optional Run metadata. It must not
        # masquerade as a working copy for the independent Start cases below.
        [IO.Directory]::Delete($svnFixture)
    }
    Fails { Resolve-AiSopRunExecutable './scripts/build.ps1' $workspace } 'RUN_SCRIPT_REQUIRES_HOST'
    Task Complete paths | Out-Null

    # Exercise real subprocesses, short leases and failed final transactions.
    foreach ($scenario in @('lease','contention','expired','revoked','retry','ended')) {
        Write-Output "Evidence safety scenario: $scenario"
        Task Start $scenario @{Tier='T1'; UserRequest='本测试明确选择 T1';Objective="Runtime $scenario"} | Out-Null
        $ready=Join-Path $workspace ".ai-workspace/$scenario.ready"
        $finish=Join-Path $workspace ".ai-workspace/$scenario.finish"
        $child=Join-Path $root "$scenario-child.ps1"
        $readyLiteral=$ready.Replace("'","''"); $finishLiteral=$finish.Replace("'","''")
        [IO.File]::WriteAllText($child, "[IO.File]::WriteAllText('$readyLiteral','once'); while (-not [IO.File]::Exists('$finishLiteral')) { Start-Sleep -Milliseconds 50 }; exit 0")
        $runner=Launch-Runner $scenario $child
        Wait-Until { [IO.File]::Exists($ready) -and (Read-AiSopTask $spec $scenario).verifications[-1].context.childPid } "Child did not start: $scenario"
        $boundOwner=Owner
        $sessionPath=Get-AiSopWorkflowSessionPath -SessionKey $boundOwner.sessionBinding.sessionKey -WorkspacePath $workspace
        $sessionBefore=Read-AiSopWorkflowSessionRecord -SessionPath $sessionPath
        if ($scenario -in @('lease','contention','expired')) {
            # A visible child receipt may precede the runner's transaction commit.
            # Inject the short lease under the same locks/2PC as a real writer;
            # an unlocked edit here would corrupt an in-flight transaction.
            $leaseOwnerPath=Join-Path $env:AI_SOP_OWNER_REGISTRY 'example.json'
            $leaseKeys=@($boundOwner.sessionBinding.sessionKey)
            $leaseLocks=Enter-AiSopWorkflowTransactionLocks -SessionKeys $leaseKeys -OwnerPath $leaseOwnerPath -Targets @(@{kind='SESSION';path=$sessionPath}) -DeadlineUtc ([DateTimeOffset]::UtcNow.AddSeconds(15)) -WorkspacePath $workspace
            try {
                $sessionBefore=Read-AiSopWorkflowSessionRecord -SessionPath $sessionPath
                $beforeJson=ConvertTo-AiSopWorkflowCanonicalJson $sessionBefore
                $short=ConvertFrom-AiSopWorkflowJson $beforeJson -AsHashtable
                $leaseSeconds=if ($scenario -eq 'expired') { 18 } elseif ($scenario -eq 'contention') { 60 } else { 12 }
                $short.expiresAt=[DateTimeOffset]::UtcNow.AddSeconds($leaseSeconds).ToString('o')
                $target=@{path=$sessionPath;kind='SESSION';schemaId='SESSION';afterJson=(ConvertTo-AiSopWorkflowCanonicalJson $short);expectedBeforeExists=$true;expectedBeforeJson=$beforeJson}
                Invoke-AiSopWorkflowTransaction -Operation CHECKPOINT -Feature Example -OwnerPath $leaseOwnerPath -SessionKeys $leaseKeys -Targets @($target) -TransactionId 'test-short-lease' -DeadlineUtc ([DateTimeOffset]::UtcNow.AddSeconds(15)) -WorkspacePath $workspace -LocksAlreadyHeld | Out-Null
            } finally { Exit-AiSopWorkflowLocks $leaseLocks.Locks }
            if ($scenario -ne 'lease') {
                $heldLock=Enter-AiSopWorkflowFileLock -LockPath ($leaseOwnerPath + '.lock') -DeadlineUtc ([DateTimeOffset]::UtcNow.AddSeconds(5))
                $runLog=Get-AiSopRunLogPath (Read-AiSopTask $spec $scenario).verifications[-1] $workspace $spec $scenario
                Wait-Until {
                    if ($runner.HasExited) { throw "Runner exited before retry ($scenario): $($runnerOut.GetAwaiter().GetResult()) $($runnerErr.GetAwaiter().GetResult())" }
                    (Read-LiveLog $runLog) -match 'RUN_LEASE_RETRY:'
                } "Lock contention was not retried: $scenario; log=$runLog"
                Assert (-not $runner.HasExited) 'Transient contention killed the running verification'
                if ($scenario -eq 'contention') { $heldLock.Dispose(); $heldLock=$null }
            }
            if ($scenario -ne 'expired') {
                Wait-Until { [DateTimeOffset]::Parse((Read-AiSopWorkflowSessionRecord -SessionPath $sessionPath).expiresAt) -gt [DateTimeOffset]::UtcNow.AddMinutes(20) } 'Runner failed to renew its short lease'
                Assert ((Read-AiSopWorkflowSessionRecord -SessionPath $sessionPath).sessionEpochId -ceq $sessionBefore.sessionEpochId) 'Heartbeat replaced session epoch'
            }
        } elseif ($scenario -eq 'revoked') {
            Invoke-AiSopWorkflowSession -Operation End -Agent CODEX -NativeSessionId $env:CODEX_SESSION_ID -WorkspacePath $workspace -AcceptedAt ([DateTimeOffset]::UtcNow) | Out-Null
        } else {
            # Hold only the fixture's owner lock while the already-running child
            # exits. Final checkpoint times out; the result must survive locally.
            $heldLock=Enter-AiSopWorkflowFileLock -LockPath ((Join-Path $env:AI_SOP_OWNER_REGISTRY 'example.json') + '.lock') -DeadlineUtc ([DateTimeOffset]::UtcNow.AddSeconds(5))
        }
        if ($scenario -notin @('expired','revoked')) { [IO.File]::WriteAllText($finish,'finish') }
        Wait-Until { $runner.HasExited } "Runner did not finish: $scenario"
        if ($heldLock) { $heldLock.Dispose(); $heldLock=$null }
        $output=$runnerOut.GetAwaiter().GetResult() + $runnerErr.GetAwaiter().GetResult()
        $exit=$runner.ExitCode; $runner.Dispose(); $runner=$null
        if ($scenario -eq 'ended') {
            Invoke-AiSopWorkflowSession -Operation End -Agent CODEX -NativeSessionId $env:CODEX_SESSION_ID -WorkspacePath $workspace -AcceptedAt ([DateTimeOffset]::UtcNow) | Out-Null
        }
        $last=(Read-AiSopTask $spec $scenario).verifications[-1]
        if ($scenario -in @('lease','contention')) {
            Assert ($exit -eq 0 -and $last.outcome -eq 'PASSED') "Renewed run did not finalize: $output"
        } elseif ($scenario -in @('expired','revoked')) {
            $pending=Get-AiSopRunEvidencePath $spec $scenario $last.runId
            Assert ($exit -ne 0 -and [IO.File]::Exists($pending)) "Interrupted result did not survive: $output"
            $durable=ConvertFrom-AiSopWorkflowJson ([IO.File]::ReadAllText($pending)) -AsHashtable
            Assert ($durable.outcome -eq 'INTERRUPTED' -and $durable.exitCode -eq -2 -and $durable.diagnostic -match '^RUN_CONTROL_INTERRUPTED:') 'Lease loss was mislabeled as a test failure'
            Assert (-not (Get-Process -Id ([int]$durable.context.childPid) -ErrorAction SilentlyContinue)) 'Child survived the lost session/lease'
            Task Recover $scenario | Out-Null
            Assert ((Read-AiSopTask $spec $scenario).verifications[-1].outcome -eq 'INTERRUPTED') 'Recovery lost the interruption result'
            $env:CODEX_SESSION_ID="after-$scenario-session"
            Task Resume $scenario | Out-Null
            Task Cancel $scenario | Out-Null
            continue
        } else {
            $pending=Get-AiSopRunEvidencePath $spec $scenario $last.runId
            Assert ($exit -ne 0 -and $last.outcome -eq 'RUNNING' -and [IO.File]::Exists($pending)) "Failed save lost its pending result: $output"
            $durable=ConvertFrom-AiSopWorkflowJson ([IO.File]::ReadAllText($pending)) -AsHashtable
            Assert ($durable.outcome -eq 'PASSED' -and $durable.exitCode -eq 0) "Actual child result was lost: $output"
            if ($scenario -eq 'retry') { Task RetryEvidence $scenario @{RunId=$last.runId} | Out-Null }
            else {
                Fails { Task RetryEvidence $scenario @{RunId=$last.runId} } 'SESSION_INACTIVE|COMMAND_GRANT_SESSION_INACTIVE'
                Assert ((Read-AiSopWorkflowSessionRecord -SessionPath $sessionPath).status -eq 'ENDED') 'Runner reactivated an ended session'
                Task Recover $scenario | Out-Null
                $env:CODEX_SESSION_ID='after-ended-session'
                Task Resume $scenario | Out-Null
            }
            Assert ((Read-AiSopTask $spec $scenario).verifications.Count -eq 1 -and (Read-AiSopTask $spec $scenario).verifications[0].outcome -eq 'PASSED') 'Recovery did not preserve the one successful execution'
        }
        Task Complete $scenario | Out-Null
    }
    Write-Output 'PASS: input boundaries, evidence forgery, batch identity, session fencing, recovery, lease renewal and durable retry'
} catch {
    Write-Output $_.ScriptStackTrace
    throw
} finally {
    if ($heldLock) { $heldLock.Dispose() }
    if ($runner) { if (-not $runner.HasExited) { $runner.Kill($true); $runner.WaitForExit(5000) | Out-Null }; $runner.Dispose() }
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key]) }
    $resolved=[IO.Path]::GetFullPath($root)
    $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sop-evidence-safety-*') { throw 'Unsafe test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
