#requires -Version 7.0

[CmdletBinding()]
param(
    [ValidateSet(
        "",
        "SESSION_START",
        "PRE_INVOCATION",
        "PRE_TOOL_USE",
        "SESSION_END",
        "STOP"
    )]
    [string]$EventHint = "",
    [ValidateSet('', 'CODEX', 'PI', 'CURSOR', 'ANTIGRAVITY')][string]$AgentHint = ''
)

$ErrorActionPreference = "Stop"

$script:DispatcherWasDotSourced = $MyInvocation.InvocationName -eq "."
if (-not $script:DispatcherWasDotSourced) {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
}
$script:DispatcherClaudeRoot = Split-Path -Parent $PSScriptRoot
$script:DispatcherWorkspaceRoot = Split-Path -Parent (
    $script:DispatcherClaudeRoot
)

# Missing dispatcher deps: fail-closed on write-ish hook events so production
# edits cannot proceed without Guard. Session lifecycle events still ALLOW so
# `git submodule update --init` / installer can run from a session hook.
$script:DispatcherMissingDeps = [System.Collections.Generic.List[string]]::new()
foreach ($dependency in @(
    "hook-event-normalizer.ps1",
    "hook-dedup.ps1",
    "workflow-transaction.ps1",
    "workflow-session.ps1",
    "workflow-command-grant.ps1",
    'task-entry-command.ps1',
    "guard-production-edit.ps1"
)) {
    $depPath = Join-Path $PSScriptRoot $dependency
    if (-not (Test-Path -LiteralPath $depPath -PathType Leaf)) {
        $script:DispatcherMissingDeps.Add($depPath)
    }
}
if ($script:DispatcherMissingDeps.Count -gt 0) {
    try {
        $logDir = Join-Path ([System.IO.Path]::GetTempPath()) "ai-sop-hook"
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        Add-Content -LiteralPath (Join-Path $logDir "degraded.log") `
            -Value ("[" + [DateTimeOffset]::UtcNow.ToString("o") + "] .ai-sop submodule not initialized or hook deps missing. Run 'git submodule update --init' then the ai-sop installer. Missing: " + ($script:DispatcherMissingDeps -join '; '))
    } catch {}
    $writeish = $EventHint -in @("", "PRE_TOOL_USE", "PRE_INVOCATION")
    if ($writeish) {
        Write-Output '{"decision":"deny","permissionDecision":"deny","reasonCode":"SOP_DEGRADED_MISSING_DEPS"}'
        if ($script:DispatcherWasDotSourced) { return }
        exit 2
    }
    Write-Output '{"decision":"ALLOW","reasonCode":"SOP_DEGRADED_MISSING_DEPS"}'
    if ($script:DispatcherWasDotSourced) { return }
    exit 0
}

foreach ($dependency in @(
    "hook-event-normalizer.ps1",
    "hook-dedup.ps1",
    "workflow-transaction.ps1",
    "workflow-session.ps1",
    "workflow-command-grant.ps1",
    'task-entry-command.ps1',
    "guard-production-edit.ps1"
)) {
    . (Join-Path $PSScriptRoot $dependency)
}

function New-AiSopDispatcherResult {
    param(
        [string]$Agent,
        [ValidateSet("ALLOW", "DENY")]
        [string]$Decision,
        [string]$ReasonCode,
        [string]$GrantId = "",
        [string]$SessionKey = "",
        [string]$DedupKey = "",
        [bool]$IsDuplicate = $false,
        [bool]$SideEffectAppliedNow = $false,
        [string]$Envelope,
        [int]$ExitCode,
        [int64]$DurationMs
    )

    return [pscustomobject][ordered]@{
        Agent = $Agent
        Decision = $Decision
        ReasonCode = $ReasonCode
        GrantId = $GrantId
        SessionKey = $SessionKey
        DedupKey = $DedupKey
        IsDuplicate = $IsDuplicate
        SideEffectAppliedNow = $SideEffectAppliedNow
        Envelope = $Envelope
        ExitCode = $ExitCode
        DurationMs = $DurationMs
    }
}

function Get-AiSopDispatcherDenyReason {
    param([string]$ReasonCode)

    $prefix = "AI_SOP_GUARD_${ReasonCode}:"
    switch ($ReasonCode) {
        "OWNER_REQUIRED" {
            return "$prefix missing active Owner. Run ./ai-sop.ps1 Task -Operation Discover to identify the feature and task; use Start for an independent task or Resume to continue it. For interrupted ownership, inspect Status and InspectRecovery before Recover, then Resume. Confirm the old agent has stopped before any forced recovery; do not auto-Claim or force-release to bypass this guard."
        }
        { $_ -in @('TASK_REQUIRED', 'TASK_NOT_FOUND', 'TASK_INACTIVE', 'SESSION_NOT_FOUND', 'SESSION_INACTIVE', 'SESSION_BINDING_INVALID', 'OWNER_NOT_FOUND') } {
            return "$prefix 写入前必须存在本会话绑定的 ACTIVE 任务和 T1/T2/T3 档位。先运行 ./ai-sop.ps1 Task -Operation Discover；独立任务使用 Start（未指定默认 T2），继续任务或收编历史归属使用 Resume。Start/Resume 成功并向用户说明实际档位后再修改；正常 T1 也必须登记任务，不可用停用防护替代。"
        }
        { $_ -in @('TASK_ID_INVALID', 'TASK_PATH_ESCAPE', 'TASK_IDENTITY_MISMATCH', 'TASK_REGISTRY_CORRUPT', 'TASK_TIER_INVALID') } {
            return "$prefix 任务身份、路径或档位无效，已拒绝修改。运行 ./ai-sop.ps1 Task -Operation Discover，再用 Task -Operation InspectRecovery 核对本工作区及任务；不要手改 task.json 或停用防护来绕过。"
        }
        "WORKFLOW_TRANSACTION_INDETERMINATE" {
            $journalPath = ""
            if (Get-Command Get-AiSopLastIndeterminateJournalPath -ErrorAction SilentlyContinue) {
                $journalPath = Get-AiSopLastIndeterminateJournalPath
            }
            $location = if ([string]::IsNullOrWhiteSpace($journalPath)) {
                "Transaction journal location unavailable."
            } else {
                "Transaction journal: $journalPath."
            }
            return "$prefix $location Preserve the journal and target files. Run ./ai-sop.ps1 Preflight for read-only diagnostics and inspect the journal/targets. After resolving the underlying cause, retry the original operation so transaction recovery can validate the journal. If it remains indeterminate, report the diagnosis and stop edits; do not delete the journal or force-release ownership to bypass this guard. See .ai-sop/SUPERPOWERS_MANUAL.md."
        }
        default { return "$prefix operation denied by policy" }
    }
}

function ConvertTo-AiSopDispatcherEnvelope {
    param(
        [string]$Agent,
        [string]$EventHint,
        [ValidateSet("ALLOW", "DENY")]
        [string]$Decision,
        [string]$ReasonCode
    )

    # Antigravity native contracts (hooks.md):
    #   PRE_INVOCATION / STOP ALLOW -> {}
    #   PRE_TOOL_USE -> {decision:"allow"|"deny", reason?}
    # Do not emit `decision` on PreInvocation: that event only accepts injectSteps.
    if ($Agent -eq "ANTIGRAVITY") {
        if ($EventHint -ne "PRE_TOOL_USE") {
            return "{}"
        }
        $nativeDecision = $Decision.ToLowerInvariant()
        $result = [ordered]@{ decision = $nativeDecision }
        if ($Decision -eq "DENY") {
            $result.reason = Get-AiSopDispatcherDenyReason -ReasonCode $ReasonCode
        }
        return ConvertTo-Json -Compress -InputObject $result
    }

    if ($EventHint -ne "PRE_TOOL_USE" -and $Decision -eq "ALLOW") {
        return "{}"
    }

    $nativeDecision = $Decision.ToLowerInvariant()
    $reason = if ($Decision -eq "DENY") { Get-AiSopDispatcherDenyReason -ReasonCode $ReasonCode }
    switch ($Agent) {
        { $_ -in @('CLAUDE_CODE','CODEX') } {
            $specific = [ordered]@{
                hookEventName = "PreToolUse"
                permissionDecision = $nativeDecision
            }
            if ($Decision -eq "DENY") {
                $specific.permissionDecisionReason = $reason
            }
            return ConvertTo-Json `
                -Compress `
                -Depth 10 `
                -InputObject ([ordered]@{
                    hookSpecificOutput = $specific
                })
        }
        'PI' {
            $result=@{block=($Decision -eq 'DENY')}
            if ($Decision -eq 'DENY') { $result.reason=$reason }
            return ($result | ConvertTo-Json -Compress)
        }
        "COPILOT" {
            $result = [ordered]@{
                permissionDecision = $nativeDecision
            }
            if ($Decision -eq "DENY") {
                $result.permissionDecisionReason = $reason
            }
            return ConvertTo-Json -Compress -InputObject $result
        }
        "CURSOR" {
            $result = [ordered]@{
                permission = $nativeDecision
            }
            if ($Decision -eq "DENY") {
                $result.user_message = $reason
                $result.agent_message = $reason
            }
            return ConvertTo-Json -Compress -InputObject $result
        }
        default {
            $result = [ordered]@{
                decision = $nativeDecision
            }
            if ($Decision -eq "DENY") {
                $result.reason = $reason
                # 载荷损坏时仍给 Cursor 明确的拒绝字段；不能依赖外层 Shell 保留退出码。
                $result.permission = 'deny'
                $result.agent_message = $reason
            }
            return ConvertTo-Json -Compress -InputObject $result
        }
    }
}

function Get-AiSopDispatcherDenyExitCode {
    param([string]$Agent)

    # Claude Code's approved protocol requires a non-zero deny exit. Cursor,
    # Copilot and Antigravity consume their native JSON denial on exit zero.
    if ($Agent -in @("COPILOT", "CURSOR", "ANTIGRAVITY", 'CODEX', 'PI')) {
        return 0
    }
    return 2
}

function Get-AiSopDispatcherInferredAgent {
    param([string]$RawPayload)

    try {
        $payload = ConvertFrom-AiSopJson -Json $RawPayload
    } catch {
        return "UNKNOWN"
    }
    if ($payload -isnot [System.Collections.IDictionary]) {
        return "UNKNOWN"
    }

    $candidates = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    if (
        $payload.Contains("conversation_id") -or
        $payload.Contains("generation_id") -or
        $payload.Contains("is_background_agent") -or
        $payload.Contains("duration_ms")
    ) {
        [void]$candidates.Add("CURSOR")
    }
    if (
        $payload.Contains("toolCall") -or
        $payload.Contains("conversationId") -or
        $payload.Contains("workspacePaths") -or
        $payload.Contains("fullyIdle")
    ) {
        [void]$candidates.Add("ANTIGRAVITY")
    }
    if (
        $payload.Contains("sessionId") -or
        $payload.Contains("toolName") -or
        $payload.Contains("toolArgs") -or
        $payload.Contains("timestamp")
    ) {
        [void]$candidates.Add("COPILOT")
    }
    if (-not $candidates.Contains('CURSOR') -and (
        $payload.Contains("tool_use_id") -or
        $payload.Contains("permission_mode") -or
        $payload.Contains("prompt_id") -or
        (
            $payload.Contains("hook_event_name") -and
            -not $payload.Contains("timestamp")
        )
    )) {
        [void]$candidates.Add("CLAUDE_CODE")
    }
    if ($candidates.Count -eq 1) {
        return @($candidates)[0]
    }
    return "UNKNOWN"
}

function Get-AiSopDispatcherSessionKey {
    param([object]$HookEvent)

    return Get-AiSopWorkflowSessionKey `
        -Agent ([string]$HookEvent.agent) `
        -NativeSessionId ([string]$HookEvent.nativeSessionId) `
        -WorkspacePath ([string]$HookEvent.workspacePath)
}

function Get-AiSopDispatcherSession {
    param(
        [object]$HookEvent,
        [DateTimeOffset]$AcceptedAt,
        [Nullable[DateTimeOffset]]$DeadlineUtc
    )

    $sessionKey = Get-AiSopDispatcherSessionKey -HookEvent $HookEvent
    try {
        return Get-AiSopWorkflowSession `
            -SessionKey $sessionKey `
            -AcceptedAt $AcceptedAt `
            -DeadlineUtc $DeadlineUtc `
            -WorkspacePath ([string]$HookEvent.workspacePath)
    } catch {
        if ($_.Exception.Message -eq "SESSION_NOT_FOUND") {
            return $null
        }
        throw
    }
}

function Get-AiSopDispatcherDedupRecordState {
    param(
        [object]$HookEvent,
        [DateTimeOffset]$AcceptedAt,
        [Nullable[DateTimeOffset]]$DeadlineUtc
    )

    $lock = $null
    try {
        $sessionDirectory = Join-Path (
            Get-AiSopHookDedupRegistryRoot
        ) (Get-AiSopHookSessionKey -HookEvent $HookEvent)
        $recordPath = Join-Path (
            $sessionDirectory
        ) "$($HookEvent.dedupKey).json"
        if (-not [System.IO.File]::Exists($recordPath)) {
            return "ABSENT"
        }
        $lock = Enter-AiSopHookDedupLock `
            -LockPath "$recordPath.lock" `
            -DeadlineUtc $DeadlineUtc
        if (-not [System.IO.File]::Exists($recordPath)) {
            return "ABSENT"
        }
        $sessionKey = Get-AiSopHookSessionKey -HookEvent $HookEvent
        $record = ConvertFrom-AiSopHookDedupRecord `
            -RecordPath $recordPath `
            -HookEvent $HookEvent `
            -SessionKey $sessionKey
        try {
            $expiresAt = [DateTimeOffset]::Parse(
                [string]$record.expiresAt,
                [System.Globalization.CultureInfo]::InvariantCulture
            )
        } catch {
            throw "REGISTRY_CORRUPT"
        }
        if ($AcceptedAt -ge $expiresAt) {
            return "EXPIRED"
        }
        return [string]$record.state
    } catch {
        if ($_.Exception.Message -in @(
            "REGISTRY_CORRUPT",
            "REGISTRY_IO_ERROR",
            "REGISTRY_LOCK_TIMEOUT",
            "REGISTRY_DEADLINE_EXCEEDED"
        )) {
            throw
        }
        throw "REGISTRY_IO_ERROR"
    } finally {
        if ($null -ne $lock) {
            $lock.Dispose()
        }
    }
}

function Get-AiSopDispatcherToolContext {
    param(
        [string]$RawPayload,
        [object]$HookEvent
    )

    $payload = ConvertFrom-AiSopJson -Json $RawPayload
    $toolPayload = Get-AiSopToolPayload `
        -Payload $payload `
        -NativeShape ([string]$HookEvent.nativeShape)
    return [pscustomobject]@{
        Name = [string]$toolPayload.ToolName
        Arguments = $toolPayload.Arguments
    }
}

function Get-AiSopDispatcherShellCommandText {
    param($Arguments)

    if ($null -eq $Arguments) {
        return $null
    }
    $keys = @("command", "CommandLine", "commandLine", "cmd")
    foreach ($key in $keys) {
        $value = $null
        if ($Arguments -is [System.Collections.IDictionary]) {
            $match = @(
                $Arguments.Keys | Where-Object { [string]$_ -ieq $key }
            ) | Select-Object -First 1
            if ($null -ne $match) {
                $value = $Arguments[$match]
            }
        } else {
            $prop = $Arguments.PSObject.Properties | Where-Object {
                $_.Name -ieq $key
            } | Select-Object -First 1
            if ($null -ne $prop) {
                $value = $prop.Value
            }
        }
        if ($value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            return [string]$value
        }
    }
    return $null
}

function Test-AiSopDispatcherShellTool {
    param([string]$ToolName)

    return $ToolName -cin @(
        "Bash",
        "Shell",
        "PowerShell",
        "bash",
        "powershell",
        "run_command"
    )
}

function New-AiSopDispatcherPlan {
    param(
        [ValidateSet("ALLOW", "DENY")]
        [string]$Decision,
        [string]$ReasonCode,
        [string]$SideEffectKind = "NONE",
        [AllowNull()]
        [object]$Session,
        [AllowNull()]
        [object]$GrantPlan,
        [string]$CommandText = "",
        [Nullable[bool]]$FullyIdle,
        [string]$AuthorizationSnapshotSha256 = "",
        [bool]$RecheckExactOwner = $false
    )

    return [pscustomobject][ordered]@{
        Decision = $Decision
        ReasonCode = $ReasonCode
        SideEffectKind = $SideEffectKind
        Session = $Session
        GrantPlan = $GrantPlan
        CommandText = $CommandText
        FullyIdle = $FullyIdle
        AuthorizationSnapshotSha256 = $AuthorizationSnapshotSha256
        RecheckExactOwner = $RecheckExactOwner
    }
}

function Get-AiSopDispatcherToolPlan {
    param(
        [string]$RawPayload,
        [object]$HookEvent,
        [DateTimeOffset]$AcceptedAt,
        [Nullable[DateTimeOffset]]$DeadlineUtc
    )

    # 任务登记和恢复入口必须先于会话/任务检查，防止要求先有任务才能 Start。
    # 仅放行限定的本地治理命令；业务执行及任意脚本仍走正常写前授权。
    if ([string]$HookEvent.toolClass -ceq 'OWNER_REQUIRED') {
        $entryTool = Get-AiSopDispatcherToolContext -RawPayload $RawPayload -HookEvent $HookEvent
        if (Test-AiSopDispatcherShellTool -ToolName $entryTool.Name) {
            $entryCommand = Get-AiSopDispatcherShellCommandText -Arguments $entryTool.Arguments
            $entry = Get-AiSopTaskEntryCommand -CommandText $entryCommand -WorkspacePath ([string]$HookEvent.workspacePath) `
                -Cwd ([string]$HookEvent.cwd) -Agent ([string]$HookEvent.agent) -NativeSessionId ([string]$HookEvent.nativeSessionId) -ToolArguments $entryTool.Arguments
            if ($null -ne $entry) {
                return New-AiSopDispatcherPlan -Decision ALLOW -ReasonCode $entry.reasonCode -SideEffectKind NONE
            }
        }
    }

    $session = Get-AiSopDispatcherSession `
        -HookEvent $HookEvent `
        -AcceptedAt $AcceptedAt `
        -DeadlineUtc $DeadlineUtc
    if ($null -eq $session) {
        if ([string]$HookEvent.agent -ceq "CURSOR") {
            return New-AiSopDispatcherPlan `
                -Decision DENY `
                -ReasonCode CURSOR_LIFECYCLE_PENDING `
                -SideEffectKind REGISTER_PENDING
        }
        $targetDecision = Get-AiSopGuardTargetDecision -HookEvent $HookEvent
        if ($targetDecision.RequiresExactOwner) {
            return New-AiSopDispatcherPlan `
                -Decision DENY `
                -ReasonCode SESSION_NOT_FOUND `
                -SideEffectKind REGISTER_CONFIRMED
        }
        return New-AiSopDispatcherPlan `
            -Decision $targetDecision.Decision `
            -ReasonCode $targetDecision.ReasonCode `
            -SideEffectKind REGISTER_CONFIRMED
    }

    if ([string]$session.EffectiveStatus -cne "ACTIVE") {
        $reason = if (
            [string]$HookEvent.agent -ceq "CURSOR" -and
            [string]$session.EffectiveStatus -ceq "PENDING"
        ) {
            "SESSION_IDENTITY_MISMATCH"
        } else {
            "SESSION_INACTIVE"
        }
        return New-AiSopDispatcherPlan `
            -Decision DENY `
            -ReasonCode $reason `
            -Session $session
    }

    if ([string]$HookEvent.toolClass -ceq "OWNER_REQUIRED") {
        $tool = Get-AiSopDispatcherToolContext `
            -RawPayload $RawPayload `
            -HookEvent $HookEvent
        $cmdText = Get-AiSopDispatcherShellCommandText -Arguments $tool.Arguments
        if (
            (Test-AiSopDispatcherShellTool -ToolName $tool.Name) -and
            -not [string]::IsNullOrWhiteSpace($cmdText)
        ) {
            try {
                $grantPlan = Get-AiSopWorkflowCommandGrantPlan `
                    -CommandText $cmdText `
                    -SessionKey ([string]$session.Record.sessionKey) `
                    -SessionEpochId ([string]$session.Record.sessionEpochId) `
                    -DedupKey ([string]$HookEvent.dedupKey) `
                    -AcceptedAt $AcceptedAt `
                    -DeadlineUtc $DeadlineUtc `
                    -WorkspacePath ([string]$HookEvent.workspacePath)
                return New-AiSopDispatcherPlan `
                    -Decision ALLOW `
                    -ReasonCode COMMAND_GRANT_ISSUED `
                    -SideEffectKind ISSUE_GRANT `
                    -Session $session `
                    -GrantPlan $grantPlan `
                    -CommandText $cmdText
            } catch {
                # A non-canonical command remains OWNER_REQUIRED. It can still
                # run under an independently exact Owner 1.1 authorization.
            }
        }
    }

    $guardDecision = Get-AiSopGuardDecision `
        -HookEvent $HookEvent `
        -AcceptedAt $AcceptedAt `
        -DeadlineUtc $DeadlineUtc
    $sideEffect = if ($guardDecision.Decision -eq "ALLOW") {
        "TOUCH"
    } else {
        "NONE"
    }
    return New-AiSopDispatcherPlan `
        -Decision $guardDecision.Decision `
        -ReasonCode $guardDecision.ReasonCode `
        -SideEffectKind $sideEffect `
        -Session $session `
        -AuthorizationSnapshotSha256 (
            [string]$guardDecision.AuthorizationSnapshotSha256
        ) `
        -RecheckExactOwner $guardDecision.RequiresExactOwner
}

function Get-AiSopDispatcherLifecyclePlan {
    param(
        [string]$RawPayload,
        [object]$HookEvent,
        [DateTimeOffset]$AcceptedAt,
        [Nullable[DateTimeOffset]]$DeadlineUtc
    )

    switch ([string]$HookEvent.event) {
        "SESSION_START" {
            return New-AiSopDispatcherPlan `
                -Decision ALLOW `
                -ReasonCode LIFECYCLE_ACCEPTED `
                -SideEffectKind REGISTER_CONFIRMED
        }
        "PRE_INVOCATION" {
            $session = Get-AiSopDispatcherSession `
                -HookEvent $HookEvent `
                -AcceptedAt $AcceptedAt `
                -DeadlineUtc $DeadlineUtc
            if ($null -eq $session) {
                return New-AiSopDispatcherPlan `
                    -Decision ALLOW `
                    -ReasonCode LIFECYCLE_ACCEPTED `
                    -SideEffectKind REGISTER_CONFIRMED
            }
            if ([string]$session.EffectiveStatus -notin @("ACTIVE", "IDLE")) {
                return New-AiSopDispatcherPlan `
                    -Decision DENY `
                    -ReasonCode SESSION_INACTIVE `
                    -Session $session
            }
            return New-AiSopDispatcherPlan `
                -Decision ALLOW `
                -ReasonCode LIFECYCLE_ACCEPTED `
                -SideEffectKind RECOVER_IDLE `
                -Session $session
        }
        "SESSION_END" {
            $session = Get-AiSopDispatcherSession `
                -HookEvent $HookEvent `
                -AcceptedAt $AcceptedAt `
                -DeadlineUtc $DeadlineUtc
            if ($null -eq $session) {
                return New-AiSopDispatcherPlan `
                    -Decision DENY `
                    -ReasonCode SESSION_NOT_FOUND
            }
            return New-AiSopDispatcherPlan `
                -Decision ALLOW `
                -ReasonCode LIFECYCLE_ACCEPTED `
                -SideEffectKind END_SESSION `
                -Session $session
        }
        "STOP" {
            $payload = ConvertFrom-AiSopJson -Json $RawPayload
            if (
                -not $payload.Contains("fullyIdle") -or
                $payload.fullyIdle -isnot [bool]
            ) {
                return New-AiSopDispatcherPlan `
                    -Decision DENY `
                    -ReasonCode PAYLOAD_SHAPE_INVALID
            }
            $session = Get-AiSopDispatcherSession `
                -HookEvent $HookEvent `
                -AcceptedAt $AcceptedAt `
                -DeadlineUtc $DeadlineUtc
            if (
                $null -eq $session -or
                [string]$session.EffectiveStatus -notin @("ACTIVE", "IDLE")
            ) {
                return New-AiSopDispatcherPlan `
                    -Decision DENY `
                    -ReasonCode SESSION_INACTIVE `
                    -Session $session
            }
            return New-AiSopDispatcherPlan `
                -Decision ALLOW `
                -ReasonCode LIFECYCLE_ACCEPTED `
                -SideEffectKind SET_IDLE `
                -Session $session `
                -FullyIdle ([bool]$payload.fullyIdle)
        }
    }
    return New-AiSopDispatcherPlan `
        -Decision DENY `
        -ReasonCode EVENT_HINT_MISMATCH
}

function Get-AiSopDispatcherPlan {
    param(
        [string]$RawPayload,
        [object]$HookEvent,
        [DateTimeOffset]$AcceptedAt,
        [Nullable[DateTimeOffset]]$DeadlineUtc
    )

    if ([string]$HookEvent.event -ceq "PRE_TOOL_USE") {
        return Get-AiSopDispatcherToolPlan `
            -RawPayload $RawPayload `
            -HookEvent $HookEvent `
            -AcceptedAt $AcceptedAt `
            -DeadlineUtc $DeadlineUtc
    }
    return Get-AiSopDispatcherLifecyclePlan `
        -RawPayload $RawPayload `
        -HookEvent $HookEvent `
        -AcceptedAt $AcceptedAt `
        -DeadlineUtc $DeadlineUtc
}

function Get-AiSopDispatcherSessionSideEffectProof {
    param(
        [object]$HookEvent,
        [object]$Plan,
        [DateTimeOffset]$AcceptedAt,
        [Nullable[DateTimeOffset]]$DeadlineUtc
    )

    if ($Plan.SideEffectKind -eq "ISSUE_GRANT") {
        return Get-AiSopWorkflowCommandGrantProofState `
            -TransactionId (
                "hook-grant-" + [string]$HookEvent.dedupKey
            ) `
            -GrantId ([string]$Plan.GrantPlan.GrantId) `
            -DeadlineUtc $DeadlineUtc `
            -RemainingMilliseconds (
                Get-AiSopWorkflowRemainingMilliseconds $DeadlineUtc
            )
    }
    try {
        $session = Get-AiSopDispatcherSession `
            -HookEvent $HookEvent `
            -AcceptedAt $AcceptedAt `
            -DeadlineUtc $DeadlineUtc
        if ($null -eq $session) {
            return "NOT_APPLIED"
        }
        $record = $session.Record
        $eventTime = $AcceptedAt.ToUniversalTime()
        $lastSeen = [DateTimeOffset]::Parse([string]$record.lastSeenAt)
        $stateChanged = [DateTimeOffset]::Parse([string]$record.stateChangedAt)
        switch ([string]$Plan.SideEffectKind) {
            { $_ -in @("REGISTER_PENDING", "REGISTER_CONFIRMED") } {
                $requiredProof = if ($_ -eq "REGISTER_PENDING") {
                    "PENDING"
                } else {
                    "CONFIRMED"
                }
                if (
                    [string]$record.lifecycleProof -eq $requiredProof -or
                    (
                        $requiredProof -eq "PENDING" -and
                        [string]$record.lifecycleProof -eq "CONFIRMED"
                    )
                ) {
                    return "APPLIED"
                }
                return "NOT_APPLIED"
            }
            { $_ -in @("TOUCH", "RECOVER_IDLE") } {
                if ($lastSeen -ge $eventTime -or $stateChanged -gt $eventTime) {
                    return "APPLIED"
                }
                return "NOT_APPLIED"
            }
            "END_SESSION" {
                if (
                    [string]$record.status -eq "ENDED" -and
                    $stateChanged -ge $eventTime
                ) {
                    return "APPLIED"
                }
                if ($stateChanged -gt $eventTime) {
                    return "APPLIED"
                }
                return "NOT_APPLIED"
            }
            "SET_IDLE" {
                if ($stateChanged -gt $eventTime) {
                    return "APPLIED"
                }
                $target = if ([bool]$Plan.FullyIdle) { "IDLE" } else { "ACTIVE" }
                if (
                    [string]$record.status -eq $target -and
                    $stateChanged -ge $eventTime
                ) {
                    return "APPLIED"
                }
                return "NOT_APPLIED"
            }
            default {
                return "APPLIED"
            }
        }
    } catch {
        return "INDETERMINATE"
    }
}

function Invoke-AiSopDispatcherSideEffect {
    param(
        [object]$HookEvent,
        [object]$Plan,
        [DateTimeOffset]$AcceptedAt,
        [Nullable[DateTimeOffset]]$DeadlineUtc
    )

    switch ([string]$Plan.SideEffectKind) {
        "NONE" {
            return
        }
        "REGISTER_PENDING" {
            Invoke-AiSopWorkflowSession `
                -Operation Register `
                -Agent ([string]$HookEvent.agent) `
                -NativeSessionId ([string]$HookEvent.nativeSessionId) `
                -WorkspacePath ([string]$HookEvent.workspacePath) `
                -LifecycleProof PENDING `
                -AcceptedAt $AcceptedAt `
                -DeadlineUtc $DeadlineUtc |
                Out-Null
        }
        "REGISTER_CONFIRMED" {
            Invoke-AiSopWorkflowSession `
                -Operation Register `
                -Agent ([string]$HookEvent.agent) `
                -NativeSessionId ([string]$HookEvent.nativeSessionId) `
                -WorkspacePath ([string]$HookEvent.workspacePath) `
                -LifecycleProof CONFIRMED `
                -AcceptedAt $AcceptedAt `
                -DeadlineUtc $DeadlineUtc |
                Out-Null
        }
        "RECOVER_IDLE" {
            Invoke-AiSopWorkflowSession `
                -Operation Touch `
                -Agent ([string]$HookEvent.agent) `
                -NativeSessionId ([string]$HookEvent.nativeSessionId) `
                -WorkspacePath ([string]$HookEvent.workspacePath) `
                -AcceptedAt $AcceptedAt `
                -AllowIdleRecovery `
                -DeadlineUtc $DeadlineUtc |
                Out-Null
        }
        "END_SESSION" {
            Invoke-AiSopWorkflowSession `
                -Operation End `
                -Agent ([string]$HookEvent.agent) `
                -NativeSessionId ([string]$HookEvent.nativeSessionId) `
                -WorkspacePath ([string]$HookEvent.workspacePath) `
                -AcceptedAt $AcceptedAt `
                -DeadlineUtc $DeadlineUtc |
                Out-Null
        }
        "SET_IDLE" {
            Invoke-AiSopWorkflowSession `
                -Operation Idle `
                -Agent ([string]$HookEvent.agent) `
                -NativeSessionId ([string]$HookEvent.nativeSessionId) `
                -WorkspacePath ([string]$HookEvent.workspacePath) `
                -AcceptedAt $AcceptedAt `
                -FullyIdle ([bool]$Plan.FullyIdle) `
                -DeadlineUtc $DeadlineUtc |
                Out-Null
        }
        "TOUCH" {
            if ($Plan.RecheckExactOwner) {
                $recheck = Get-AiSopGuardDecision `
                    -HookEvent $HookEvent `
                    -AcceptedAt $AcceptedAt `
                    -DeadlineUtc $DeadlineUtc
                if ($recheck.Decision -ne "ALLOW") {
                    throw [string]$recheck.ReasonCode
                }
            }
            Invoke-AiSopWorkflowSession `
                -Operation Touch `
                -Agent ([string]$HookEvent.agent) `
                -NativeSessionId ([string]$HookEvent.nativeSessionId) `
                -WorkspacePath ([string]$HookEvent.workspacePath) `
                -AcceptedAt $AcceptedAt `
                -DeadlineUtc $DeadlineUtc |
                Out-Null
        }
        "ISSUE_GRANT" {
            $transactionId = "hook-grant-" + [string]$HookEvent.dedupKey
            $grant = Invoke-AiSopWorkflowCommandGrant `
                -Operation Issue `
                -CommandText ([string]$Plan.CommandText) `
                -SessionKey ([string]$Plan.Session.Record.sessionKey) `
                -SessionEpochId (
                    [string]$Plan.Session.Record.sessionEpochId
                ) `
                -DedupKey ([string]$HookEvent.dedupKey) `
                -AcceptedAt $AcceptedAt `
                -TransactionId $transactionId `
                -DeadlineUtc $DeadlineUtc `
                -WorkspacePath ([string]$HookEvent.workspacePath)
            if (
                [string]$grant.Record.grantId -cne
                    [string]$Plan.GrantPlan.GrantId
            ) {
                throw "COMMAND_GRANT_IDENTITY_MISMATCH"
            }
            Invoke-AiSopWorkflowSession `
                -Operation Touch `
                -Agent ([string]$HookEvent.agent) `
                -NativeSessionId ([string]$HookEvent.nativeSessionId) `
                -WorkspacePath ([string]$HookEvent.workspacePath) `
                -AcceptedAt $AcceptedAt `
                -DeadlineUtc $DeadlineUtc |
                Out-Null
        }
    }
}

function ConvertFrom-AiSopDispatcherDedupResult {
    param(
        [object]$HookEvent,
        [object]$DedupResult,
        [int64]$DurationMs,
        [DateTimeOffset]$AcceptedAt,
        [Nullable[DateTimeOffset]]$DeadlineUtc
    )

    $decision = [string]$DedupResult.Record.decision
    $reason = [string]$DedupResult.Record.reasonCode
    # 去重记录只证明上次已处理；写入许可必须依据当前任务和档位重新检查。
    # 已登记或恢复任务后，旧拒绝结果同样不能把合法重试永久锁住。
    # 启动/恢复专用命令的授权有独立校验，不在这里阻断无任务的登记入口。
    if ($DedupResult.IsDuplicate -and $DedupResult.Record.state -ceq 'APPLIED' -and
        $HookEvent.event -ceq 'PRE_TOOL_USE' -and $reason -cnotin @('COMMAND_GRANT_ISSUED', 'TASK_BOOTSTRAP_COMMAND') -and
        $HookEvent.toolClass -in @('FILE_EDIT', 'OWNER_REQUIRED')) {
        $current = Get-AiSopGuardDecision -HookEvent $HookEvent -AcceptedAt $AcceptedAt -DeadlineUtc $DeadlineUtc
        $decision = [string]$current.Decision
        $reason = [string]$current.ReasonCode
    }
    if ($reason -in @('GUARD_DISABLED', 'GUARD_DISABLED_FOR_FEATURE')) {
        [Console]::Error.WriteLine("[WARN] ${reason}: 人工维护已停用写前防护，本次放行不代表按 T1/T2/T3 正常执行。")
    }
    $grantId = [string]$DedupResult.Record.bootstrapGrantId
    $agent = [string]$HookEvent.agent
    $envelope = ConvertTo-AiSopDispatcherEnvelope `
        -Agent $agent `
        -EventHint ([string]$HookEvent.event) `
        -Decision $decision `
        -ReasonCode $reason
    $exitCode = if ($decision -eq "ALLOW") {
        0
    } else {
        Get-AiSopDispatcherDenyExitCode -Agent $agent
    }
    return New-AiSopDispatcherResult `
        -Agent $agent `
        -Decision $decision `
        -ReasonCode $reason `
        -GrantId $grantId `
        -SessionKey (Get-AiSopDispatcherSessionKey -HookEvent $HookEvent) `
        -DedupKey ([string]$HookEvent.dedupKey) `
        -IsDuplicate $DedupResult.IsDuplicate `
        -SideEffectAppliedNow $DedupResult.SideEffectAppliedNow `
        -Envelope $envelope `
        -ExitCode $exitCode `
        -DurationMs $DurationMs
}

function Invoke-AiSopHookDispatcher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RawPayload,

        [Parameter(Mandatory)]
        [ValidateSet(
            "SESSION_START",
            "PRE_INVOCATION",
            "PRE_TOOL_USE",
            "SESSION_END",
            "STOP"
        )]
        [string]$EventHint,

        [Parameter(Mandatory)]
        [string]$TrustedWorkspaceRoot,

        [DateTimeOffset]$AcceptedAt = [DateTimeOffset]::UtcNow,
        [ValidateSet('', 'CODEX', 'PI', 'CURSOR', 'ANTIGRAVITY')][string]$AgentHint = ''
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $agent = Get-AiSopDispatcherInferredAgent -RawPayload $RawPayload
    if ($AgentHint) { $agent=$AgentHint }
    try {
        $originalRawPayload=$RawPayload
        # 客户端身份来自安装的入口参数，不能由工具载荷声明或覆盖。
        if ($AgentHint -in @('CODEX','PI')) { $RawPayload = ConvertFrom-AiSopHarnessPayload $RawPayload $AgentHint $EventHint }
        # Total workflow budget for this hook pass. 750ms was too tight for a
        # cold session Register (measured ~915ms including transaction
        # recovery), so default to 5s; overridable for locked-down or very
        # slow environments via SERVER_NEW_WORKFLOW_HOOK_DEADLINE_MS.
        $dispatcherDeadlineMs = 10000
        $dispatcherDeadlineEnv = [string]$env:SERVER_NEW_WORKFLOW_HOOK_DEADLINE_MS
        if (
            -not [string]::IsNullOrWhiteSpace($dispatcherDeadlineEnv) -and
            [int]::TryParse($dispatcherDeadlineEnv, [ref]$dispatcherDeadlineEnv)
        ) {
            $dispatcherDeadlineMs = [int]$dispatcherDeadlineEnv
        }
        $deadlineUtc = [DateTimeOffset]::UtcNow.AddMilliseconds($dispatcherDeadlineMs)

        # 先解析工具分类；人工维护开关随后跳过归属/日志检查。
        # 解析失败时仍保留人工修复入口，但不能将此放行称为正常 T1。
        $hookEvent = ConvertTo-AiSopHookEvent `
            -RawPayload $RawPayload `
            -EventHint $EventHint `
            -TrustedWorkspaceRoot $TrustedWorkspaceRoot `
            -AcceptedAt $AcceptedAt `
            -AgentOverride $(if ($AgentHint -in @('CODEX','PI')) { $AgentHint } else { '' }) `
            -DeadlineUtc $deadlineUtc
        $agent = [string]$hookEvent.agent
        if ($AgentHint -and $agent -cne $AgentHint) { $agent=$AgentHint; throw 'PAYLOAD_AGENT_MISMATCH' }
        if ($AgentHint) { $hookEvent.rawPayloadSha256=Get-AiSopSha256Hex $originalRawPayload }

        if (Test-AiSopGuardEscapeEnabled) {
            [Console]::Error.WriteLine('[WARN] GUARD_DISABLED: 人工维护已停用写前防护，本次放行不代表按 T1/T2/T3 正常执行。')
            $watch.Stop()
            return New-AiSopDispatcherResult `
                -Agent $agent `
                -Decision ALLOW `
                -ReasonCode GUARD_DISABLED `
                -Envelope (
                    ConvertTo-AiSopDispatcherEnvelope `
                        -Agent $agent `
                        -EventHint $EventHint `
                        -Decision ALLOW `
                        -ReasonCode GUARD_DISABLED
                ) `
                -ExitCode 0 `
                -DurationMs $watch.ElapsedMilliseconds
        }

        # 3. Every authoritative read follows transaction recovery.
        Invoke-AiSopWorkflowTransactionRecovery `
            -DeadlineUtc $deadlineUtc `
            -WorkspacePath $TrustedWorkspaceRoot |
            Out-Null

        # 4. Applied duplicates replay before lifecycle, Guard or grant work.
        $dedupState = Get-AiSopDispatcherDedupRecordState `
            -HookEvent $hookEvent `
            -AcceptedAt $AcceptedAt `
            -DeadlineUtc $deadlineUtc
        if ($dedupState -eq "APPLIED") {
            $duplicate = Invoke-AiSopHookDedup `
                -HookEvent $hookEvent `
                -Decision DENY `
                -ReasonCode DUPLICATE_REPLAY `
                -AcceptedAt $AcceptedAt `
                -DeadlineUtc $deadlineUtc
            $watch.Stop()
            return ConvertFrom-AiSopDispatcherDedupResult `
                -HookEvent $hookEvent `
                -DedupResult $duplicate `
                -DurationMs $watch.ElapsedMilliseconds `
                -AcceptedAt $AcceptedAt `
                -DeadlineUtc $deadlineUtc
        }

        # 5-8. Plan lifecycle, four-state target policy, canonical command
        # grant, and exact Owner 1.1 authorization without writing state.
        $plan = Get-AiSopDispatcherPlan `
            -RawPayload $RawPayload `
            -HookEvent $hookEvent `
            -AcceptedAt $AcceptedAt `
            -DeadlineUtc $deadlineUtc
        $grantId = if ($null -ne $plan.GrantPlan) {
            [string]$plan.GrantPlan.GrantId
        } else {
            ""
        }
        $intentSha = if ($null -ne $plan.GrantPlan) {
            [string]$plan.GrantPlan.IntentSha256
        } else {
            ""
        }
        $sideEffectId = if ($plan.SideEffectKind -eq "ISSUE_GRANT") {
            "hook-grant-" + [string]$hookEvent.dedupKey
        } else {
            "hook-session-" + [string]$hookEvent.dedupKey
        }
        $reconcileFunc = ${function:Get-AiSopDispatcherSessionSideEffectProof}
        $reconcile = {
            param($record, $callbackDeadline, $remainingMilliseconds)
            return & $reconcileFunc `
                -HookEvent $hookEvent `
                -Plan $plan `
                -AcceptedAt $AcceptedAt `
                -DeadlineUtc $callbackDeadline
        }.GetNewClosure()
        $sideEffect = $null
        if ($plan.SideEffectKind -ne "NONE") {
            $sideEffectFunc = ${function:Invoke-AiSopDispatcherSideEffect}
            $sideEffect = {
                param($record, $callbackDeadline, $remainingMilliseconds)
                & $sideEffectFunc `
                    -HookEvent $hookEvent `
                    -Plan $plan `
                    -AcceptedAt $AcceptedAt `
                    -DeadlineUtc $callbackDeadline
            }.GetNewClosure()
        }

        $dedup = Invoke-AiSopHookDedup `
            -HookEvent $hookEvent `
            -Decision $plan.Decision `
            -ReasonCode $plan.ReasonCode `
            -AuthorizationSnapshotSha256 (
                [string]$plan.AuthorizationSnapshotSha256
            ) `
            -BootstrapGrantId $grantId `
            -IntentSha256 $intentSha `
            -SideEffectId $sideEffectId `
            -AcceptedAt $AcceptedAt `
            -DeadlineUtc $deadlineUtc `
            -ReconcilePrepared $reconcile `
            -SideEffect $sideEffect

        # 9. Native envelope is selected only from the normalized Agent.
        $watch.Stop()
        return ConvertFrom-AiSopDispatcherDedupResult `
            -HookEvent $hookEvent `
            -DedupResult $dedup `
            -DurationMs $watch.ElapsedMilliseconds `
            -AcceptedAt $AcceptedAt `
            -DeadlineUtc $deadlineUtc
    } catch {
        $watch.Stop()
        if ([string]::IsNullOrWhiteSpace($agent)) {
            $agent = Get-AiSopDispatcherInferredAgent -RawPayload $RawPayload
        }
        if (Test-AiSopGuardEscapeEnabled) {
            [Console]::Error.WriteLine('[WARN] GUARD_DISABLED: 人工维护已停用写前防护，本次放行不代表按 T1/T2/T3 正常执行。')
            return New-AiSopDispatcherResult `
                -Agent $agent `
                -Decision ALLOW `
                -ReasonCode GUARD_DISABLED `
                -Envelope (
                    ConvertTo-AiSopDispatcherEnvelope `
                        -Agent $agent `
                        -EventHint $EventHint `
                        -Decision ALLOW `
                        -ReasonCode GUARD_DISABLED
                ) `
                -ExitCode 0 `
                -DurationMs $watch.ElapsedMilliseconds
        }
        $reason = [string]$_.Exception.Message
        if ($reason -notmatch "^[A-Z][A-Z0-9_]*$") {
            [Console]::Error.WriteLine("[WARN] Hook 内部检查失败：$reason")
            $reason = "GUARD_INTERNAL_ERROR"
        }
        $envelope = ConvertTo-AiSopDispatcherEnvelope `
            -Agent $agent `
            -EventHint $EventHint `
            -Decision DENY `
            -ReasonCode $reason
        return New-AiSopDispatcherResult `
            -Agent $agent `
            -Decision DENY `
            -ReasonCode $reason `
            -Envelope $envelope `
            -ExitCode (Get-AiSopDispatcherDenyExitCode -Agent $agent) `
            -DurationMs $watch.ElapsedMilliseconds
    }
}

function Add-AiSopHarnessSessionContext {
    param($Result, [string]$RawPayload, [string]$EventHint)
    $payload=ConvertFrom-AiSopJson $RawPayload
    $sessionId=if ($payload.Contains('conversationId')) { $payload.conversationId } elseif ($payload.Contains('conversation_id')) { $payload.conversation_id } else { $payload.session_id }
    if ($sessionId -isnot [string] -or $sessionId -notmatch '^[A-Za-z0-9._:-]+$') { return $Result.Envelope }
    $message="AI SOP 当前会话：$sessionId。执行修改前先 Task Start/Resume；所有 Task 命令携带 -Agent $($Result.Agent) -NativeSessionId '$sessionId'，避免子进程另建会话。未指定档位默认 T2；成功后先回显登记档位和流程，再修改。纯讨论不启动任务。"
    $envelope=ConvertFrom-AiSopJson $Result.Envelope
    if ($Result.Decision -eq 'ALLOW' -and $EventHint -in @('SESSION_START','PRE_INVOCATION')) {
        switch ($Result.Agent) {
            { $_ -in @('CLAUDE_CODE','CODEX') } { $envelope.hookSpecificOutput=@{hookEventName='SessionStart';additionalContext=$message} }
            'CURSOR' { $envelope.additional_context=$message }
            'ANTIGRAVITY' { $envelope.injectSteps=@(@{systemMessage=@{systemMessage=$message}}) }
        }
    } elseif ($Result.Decision -eq 'DENY' -and $EventHint -eq 'PRE_TOOL_USE') {
        switch ($Result.Agent) {
            { $_ -in @('CLAUDE_CODE','CODEX') } { $envelope.hookSpecificOutput.permissionDecisionReason+=" $message" }
            'CURSOR' {
                $envelope.agent_message+=" $message"
                # 部分客户端只向模型展示 user_message，两个通道都提供正常启动入口。
                $envelope.user_message=$envelope.agent_message
            }
            default { $envelope.reason+=" $message" }
        }
    }
    return ($envelope | ConvertTo-Json -Compress -Depth 20)
}

if (-not $script:DispatcherWasDotSourced) {
    if ([string]::IsNullOrWhiteSpace($EventHint)) {
        $result = New-AiSopDispatcherResult `
            -Agent UNKNOWN `
            -Decision DENY `
            -ReasonCode EVENT_HINT_MISSING `
            -Envelope (
                ConvertTo-AiSopDispatcherEnvelope `
                    -Agent UNKNOWN `
                    -EventHint PRE_TOOL_USE `
                    -Decision DENY `
                    -ReasonCode EVENT_HINT_MISSING
            ) `
            -ExitCode 2 `
            -DurationMs 0
    } else {
        $raw = [Console]::In.ReadToEnd().TrimStart([char]0xFEFF)
        $result = Invoke-AiSopHookDispatcher `
            -RawPayload $raw `
            -EventHint $EventHint `
            -AgentHint $AgentHint `
            -TrustedWorkspaceRoot $script:DispatcherWorkspaceRoot
        try { $result.Envelope=Add-AiSopHarnessSessionContext $result $raw $EventHint }
        catch { [Console]::Error.WriteLine("[WARN] HOOK_SESSION_CONTEXT_UNAVAILABLE: $($_.Exception.Message)") }
    }
    [Console]::Out.WriteLine($result.Envelope)
    exit $result.ExitCode
}
