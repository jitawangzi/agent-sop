#requires -Version 7.0

function Get-AiSopRunProgress {
    param($Record, [string]$WorkspacePath, [string]$SpecDirectory, [string]$TaskId, [ValidateRange(0,200)][int]$LogTailLines=0)
    $result=@{observationOnly=$true;startedAt=$Record.executedAt;elapsedSeconds=$null;timeoutSeconds=$null;logFile=$null;logStatus='UNKNOWN';logUpdatedAt=$null;logBytes=$null;logTail=@();tailBytesRead=0;tailTruncated=$false;diagnostics=@()}
    try {
        $elapsed=([DateTimeOffset]::UtcNow-[DateTimeOffset]::Parse($Record.executedAt)).TotalSeconds
        if ($elapsed -ge 0) { $result.elapsedSeconds=[long][math]::Floor($elapsed) }
    } catch { $result.diagnostics+=@('RUN_START_TIME_UNAVAILABLE') }
    $limit=0
    if ($null -ne $Record.context.timeoutSeconds -and [int]::TryParse([string]$Record.context.timeoutSeconds,[ref]$limit) -and $limit -ge 0 -and $limit -le 86400) { $result.timeoutSeconds=$limit }
    if ($Record.context.runnerMachine -cne [Environment]::MachineName -or $Record.context.workspace -cne (Resolve-PhysicalPathIdentity $WorkspacePath)) {
        $result.logStatus='REMOTE_UNKNOWN'; return $result
    }
    try {
        $result.logFile=Get-AiSopRunLogPath $Record $WorkspacePath $SpecDirectory $TaskId
        if (-not $result.logFile -or -not [IO.File]::Exists($result.logFile)) { $result.logStatus='MISSING'; return $result }
        $info=[IO.FileInfo]::new($result.logFile)
        $result.logBytes=$info.Length; $result.logUpdatedAt=$info.LastWriteTimeUtc.ToString('o'); $result.logStatus='AVAILABLE'
        if ($LogTailLines) {
            $stream=[IO.FileStream]::new($result.logFile,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try {
                $length=$stream.Length; $start=[math]::Max(0,$length-32768)
                [void]$stream.Seek($start,[IO.SeekOrigin]::Begin)
                $buffer=[byte[]]::new([int]($length-$start)); $read=0
                while ($read -lt $buffer.Length) { $count=$stream.Read($buffer,$read,$buffer.Length-$read); if (-not $count) { break }; $read+=$count }
                $result.tailBytesRead=$read; $result.tailTruncated=$start -gt 0
                $text=[Text.Encoding]::UTF8.GetString($buffer,0,$read)
                if ($start -gt 0 -and $text.Contains("`n")) { $text=$text.Substring($text.IndexOf("`n")+1) }
                $lines=@($text.TrimEnd("`r","`n") -split '\r?\n')
                if ($lines.Count -gt $LogTailLines) { $result.tailTruncated=$true }
                $result.logTail=@($lines | Select-Object -Last $LogTailLines)
            } finally { $stream.Dispose() }
        }
    } catch { $result.logStatus='UNAVAILABLE'; $result.diagnostics+=@($_.Exception.Message) }
    return $result
}

function Resolve-AiSopFeatureName {
    param([string]$WorkspacePath, [string]$Feature)
    if (-not $Feature) { return '' }
    if ($Feature -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9_-])?$') { throw 'FEATURE_INVALID' }
    $root = Resolve-AiSopWorkspaceChild $WorkspacePath '.ai-workspace/specs/features'
    $comparison = if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    foreach ($dir in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
        if ($dir.Name.Equals($Feature, $comparison)) { return $dir.Name }
    }
    return $Feature
}

function Get-AiSopDeploymentWarnings {
    param([string]$WorkspacePath)
    $engine = Resolve-AiSopWorkspaceChild $WorkspacePath '.ai-sop'
    if (-not [IO.File]::Exists((Join-Path $engine 'scripts/workflow-task.ps1'))) { return }
    foreach ($name in @('ai-sop.ps1','AGENTS.md')) {
        $template = Resolve-AiSopWorkspaceChild $WorkspacePath ".ai-sop/distribution/templates/root/$name"
        if (-not [IO.File]::Exists($template)) { continue }
        $target = Resolve-AiSopWorkspaceChild $WorkspacePath $name
        if (-not [IO.File]::Exists($target) -or (Get-FileHash -LiteralPath $template).Hash -cne (Get-FileHash -LiteralPath $target).Hash) {
            "DEPLOYMENT_PROJECTION_STALE: $name differs from the installed engine; run the installed tools/ai-sop/install-ai-sop.ps1 installer (-Action Install -Mode Auto) to refresh projections, then Doctor."
        }
    }
    $lockPath = Resolve-AiSopWorkspaceChild $WorkspacePath 'tools/ai-sop/ai-sop.lock.json'
    if ([IO.File]::Exists($lockPath) -and (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        try {
            $lock = ConvertFrom-AiSopWorkflowJson ([IO.File]::ReadAllText($lockPath)) -AsHashtable
            $git=(@(Get-Command git -CommandType Application)[0]).Source
            $gitRoot=Invoke-AiSopMetadataProbe $git @('-C',$engine,'rev-parse','--show-toplevel')
            if ($gitRoot.diagnostic) { "DEPLOYMENT_CHECK_UNAVAILABLE: $($gitRoot.diagnostic)"; return }
            if ($gitRoot.exitCode -eq 0 -and (Resolve-PhysicalPathIdentity $gitRoot.output) -ceq $engine) {
                $head=Invoke-AiSopMetadataProbe $git @('-C',$engine,'rev-parse','HEAD')
                if ($head.diagnostic) { "DEPLOYMENT_CHECK_UNAVAILABLE: $($head.diagnostic)"; return }
                if ($head.exitCode -eq 0 -and $lock.commit -and $lock.commit -cne $head.output) { 'DEPLOYMENT_ENGINE_DRIFT: installed engine HEAD differs from the lock; run ai-sop.ps1 Verify and refresh the installation deliberately.' }
            }
        } catch { "DEPLOYMENT_LOCK_INVALID: $lockPath; $($_.Exception.Message)" }
    }
}

function Get-AiSopLegacyTaskSummary {
    param([string]$SpecDirectory, [string]$WorkspacePath)
    $feature = Split-Path -Leaf $SpecDirectory
    $result = @{ feature=$feature; taskId=$null; status='LEGACY'; tier='UNKNOWN'; phase='UNKNOWN'; recordedApprovals=(Get-AiSopRecordedApprovals $SpecDirectory); diagnostics=@(); suggestedAction='Legacy feature state is not an independent task. Use Start with a new TaskId for new work; use Resume explicitly to adopt unfinished ownership, preserving its tier.' }
    $path = Join-Path $SpecDirectory 'feature-state.json'
    if ([IO.File]::Exists($path)) {
        try {
            $state=ConvertFrom-AiSopWorkflowJson ([IO.File]::ReadAllText($path)) -AsHashtable
            $result.tier=[string]$state.tier; $result.phase=[string]$state.phase
        } catch { $result.diagnostics += "LEGACY_STATE_INVALID: $path; $($_.Exception.Message)" }
    }
    $ownerPath = Join-Path (Get-AiSopWorkflowOwnerRegistryRoot -WorkspacePath $WorkspacePath) ($feature.ToLowerInvariant() + '.json')
    $result.ownerStatus='MISSING'
    if ([IO.File]::Exists($ownerPath)) {
        try {
            $raw=[IO.File]::ReadAllText($ownerPath); Assert-AiSopWorkflowJsonSchema -Json $raw -SchemaId OWNER
            $owner=ConvertFrom-AiSopWorkflowJson $raw -AsHashtable
            $result.ownerStatus=$owner.status; $result.ownerId=$owner.ownerId
        } catch { $result.ownerStatus='UNAVAILABLE'; $result.diagnostics += "LEGACY_OWNER_INVALID: $($_.Exception.Message)" }
    }
    return $result
}

function Write-AiSopTaskOperationResult {
    param([ValidateSet('Resume','Suspend','Cancel','Complete')][string]$Operation,
        [string]$Feature, [string]$TaskId, [string]$Tier)
    # Called only after the owner transaction succeeds. Report that operation's
    # result without a second authority lookup or a business-input scan.
    $result=switch ($Operation) {
        'Resume' { @{code='RESUMED';status='ACTIVE';ownership='bound to current session'} }
        'Suspend' { @{code='SUSPENDED';status='PAUSED';ownership='released'} }
        'Cancel' { @{code='CANCELLED';status='CANCELLED';ownership='released'} }
        'Complete' { @{code='COMPLETED';status='DONE';ownership='released'} }
    }
    Write-Output "TASK_$($result.code):$Feature/$TaskId tier=$Tier status=$($result.status); ownership $($result.ownership)"
}

function Get-AiSopRunInputDiagnostics {
    param($Before, $After)
    # Use the snapshots already captured by Run; never rescan for presentation.
    if ($Before.digest -ceq $After.digest) { return }
    if ($Before.algorithm -cne $After.algorithm -or [string]$Before.policyDigest -cne [string]$After.policyDigest) {
        'INPUT_POLICY_CHANGED_DURING_RUN: input selection policy or fingerprint algorithm changed'
    }
    $changed=@(Get-AiSopChangedInputs $Before $After)
    foreach ($path in @($changed | Select-Object -First 20)) {
        $kind=if (-not $Before.files.ContainsKey($path)) { 'ADDED' } elseif (-not $After.files.ContainsKey($path)) { 'DELETED' } else { 'MODIFIED' }
        "INPUT_FILE_CHANGED:${kind}:$($path | ConvertTo-Json -Compress)"
    }
    if ($changed.Count -gt 20) { "INPUT_CHANGES_TRUNCATED: showing 20 of $($changed.Count) changed paths" }
    if (-not $changed.Count) { 'INPUT_DIGEST_CHANGED_DURING_RUN: no file-content differences; inspect input policy/algorithm' }
}

function Write-AiSopTaskStartSummary {
    param($Task)
    $origin=$Task.startInputs
    if ($origin.status -eq 'CAPTURED') {
        Write-Output "TASK_START_INPUTS: CAPTURED mode=$($origin.mode); original inputs saved. T3 scope and applicability still require their policy checks."
    } else {
        $reason=if ($origin.reason) { [string]$origin.reason } else { 'No complete Start snapshot recorded' }
        $reason=$reason | ConvertTo-Json -Compress
        Write-Output "TASK_START_INPUTS: UNAVAILABLE reason=$reason; normal T1/T2 verification remains available. T3 upgrade and NOT_APPLICABLE require the original Start snapshot; a future task can use Start -CaptureBaseline before edits."
    }
}

function Write-AiSopTaskTierSummary {
    param($Task)
    # 只使用成功事务后读到的任务记录，不为展示扫描业务输入或重新判定档位。
    $source=if ($Task.tierSelection) { [string]$Task.tierSelection.source } else { 'LEGACY_UNRECORDED' }
    $history=@($Task.tierHistory | Where-Object { $null -ne $_ })
    if ($history.Count -and $history[-1].to -ceq $Task.tier) { $source='USER_REQUEST_CHANGE' }
    $requirements=switch ($Task.tier) {
        'T1' { '完成修改及适用的编译检查；仅对实际延期的文档或测试事项留痕。T1 仍受任务归属保护。' }
        'T2' { '完成修改，同步受影响的文档和用例，执行适用的编译及相关测试；无需更新时说明依据。' }
        'T3' { '执行完整流程，保留需求与设计批准、独立审核及完整交付门禁。' }
        default { throw 'TASK_TIER_INVALID' }
    }
    Write-Output "TASK_TIER: $($Task.tier) source=$source; $requirements"
}

function Write-AiSopTaskStatus {
    param($Items, [string]$WorkspacePath, [string]$Operation, [string]$Format, [string[]]$Warnings)
    if ($Format -eq 'Json') {
        # Exactly one JSON document; tasks is always an array (including zero).
        [ordered]@{ schemaVersion='1.0'; operation=$Operation; workspace=$WorkspacePath; tasks=@($Items); warnings=@($Warnings) } | ConvertTo-Json -Depth 20
    } elseif ($Format -eq 'JsonLines') {
        foreach ($item in $Items) { $item | ConvertTo-Json -Depth 20 -Compress }
        foreach ($warning in $Warnings) { Write-Warning $warning }
    } else {
        Write-Output "$Operation — $WorkspacePath"
        if (-not $Items.Count) { Write-Output 'No unfinished tasks or pending follow-ups. Use -IncludeHistory to inspect completed work.' }
        foreach ($item in $Items) {
            Write-Output "[$($item.status)] $($item.feature)/$($item.taskId) $($item.tier) — $($item.objective)"
            Write-Output "  owner=$($item.ownerStatus) session=$($item.sessionStatus) evidence=$($item.verification)"
            if ($item.executionLocation) { Write-Output "  execution=$($item.executionLocality) $($item.executionLocation.machine):$($item.executionLocation.workspace) (synced observation, not permission)" }
            if ($item.status -in @('DONE','CANCELLED')) {
                if ($item.verificationScope -eq 'CURRENT_INPUTS') { Write-Output '  history: explicit current-input recheck; terminal task status is unchanged' }
                else { Write-Output '  history: recorded terminal status retained; current inputs not rechecked; follow-ups remain non-blocking' }
            }
            if ($item.startInputs.status -eq 'UNAVAILABLE') { Write-Output '  start inputs: UNAVAILABLE; normal tier verification remains available; no post-change baseline adoption' }
            if ($item.nextAction) { Write-Output "  checkpoint: $($item.nextAction)" }
            Write-Output "  next: $($item.suggestedAction)"
            foreach ($run in $item.runs) {
                $limit=if ($null -eq $run.timeoutSeconds) { 'UNKNOWN (older record)' } elseif ($run.timeoutSeconds -eq 0) { 'unlimited' } else { "$($run.timeoutSeconds)s" }
                $elapsed=if ($null -eq $run.elapsedSeconds) { 'UNKNOWN' } else { "$($run.elapsedSeconds)s" }
                Write-Output "  run: $($run.kind)/$($run.batch) $($run.activity) elapsed=$elapsed limit=$limit pending=$($run.pendingStatus)/$($run.pendingOutcome)"
                Write-Output "    log=$($run.logFile) status=$($run.logStatus) bytes=$($run.logBytes) updated=$($run.logUpdatedAt)"
                if ($run.logTail.Count) {
                    Write-Output "    log tail (observed output, truncated=$($run.tailTruncated)):"
                    foreach ($line in $run.logTail) { Write-Output "      $line" }
                }
                foreach ($diagnostic in $run.diagnostics) { Write-Output "    ! $diagnostic" }
            }
            foreach ($failed in $item.failedVerifications) { Write-Output "  failed verification: $($failed.kind)/$($failed.batch) exit=$($failed.exitCode) $($failed.outcome)" }
            foreach ($followUp in $item.pendingFollowUps) { Write-Output "  follow-up (non-blocking): $($followUp.id) $($followUp.summary)" }
            foreach ($diagnostic in @($item.diagnostics) + @($item.diagnostic) | Where-Object { $_ }) { Write-Output "  ! $diagnostic" }
        }
        foreach ($warning in $Warnings) { Write-Output "! $warning" }
    }
}
