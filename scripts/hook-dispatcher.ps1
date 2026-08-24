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
    [string]$EventHint = ""
)

$ErrorActionPreference = "Stop"

$script:DispatcherWasDotSourced = $MyInvocation.InvocationName -eq "."
$script:DispatcherClaudeRoot = Split-Path -Parent $PSScriptRoot
$script:DispatcherWorkspaceRoot = Split-Path -Parent (
    $script:DispatcherClaudeRoot
)

# Graceful degradation: if the .ai-sop submodule is not initialized or
# dependency scripts are missing, do NOT block tool calls (exit 0 + warn).
# A missing submodule should not paralyze every AI tool invocation.
$script:DispatcherMissingDeps = [System.Collections.Generic.List[string]]::new()
foreach ($dependency in @(
    "hook-event-normalizer.ps1",
    "hook-dedup.ps1",
    "workflow-transaction.ps1",
    "workflow-session.ps1",
    "workflow-command-grant.ps1",
    "guard-production-edit.ps1"
)) {
    $depPath = Join-Path $PSScriptRoot $dependency
    if (-not (Test-Path -LiteralPath $depPath -PathType Leaf)) {
        $script:DispatcherMissingDeps.Add($depPath)
    }
}
if ($script:DispatcherMissingDeps.Count -gt 0) {
    # Write warning to a log file (NOT stderr) — some harnesses treat any
    # stderr output as command failure. Silent exit 0 + permissive ALLOW on
    # stdout so tool calls are not blocked.
    try {
        $logDir = Join-Path ([System.IO.Path]::GetTempPath()) "ai-sop-hook"
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        Add-Content -LiteralPath (Join-Path $logDir "degraded.log") `
            -Value ("[" + [DateTimeOffset]::UtcNow.ToString("o") + "] .ai-sop submodule not initialized or hook deps missing. Run 'git submodule update --init' then the ai-sop installer. Missing: " + ($script:DispatcherMissingDeps -join '; '))
    } catch {}
    # Permissive ALLOW result on stdout (JSON envelope), exit 0.
    Write-Output '{"decision":"ALLOW","reasonCode":"SOP_DEGRADED_MISSING_DEPS"}'
    exit 0
}

foreach ($dependency in @(
    "hook-event-normalizer.ps1",
    "hook-dedup.ps1",
    "workflow-transaction.ps1",
    "workflow-session.ps1",
    "workflow-command-grant.ps1",
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
            $reason = "AI_SOP_GUARD_${ReasonCode}: operation denied by policy"
            if ($ReasonCode -eq "OWNER_REQUIRED") {
                $reason = "AI_SOP_GUARD_OWNER_REQUIRED: missing active Owner. AI must auto-Claim before retrying edit, do not surface error to user. Hint: input 'takeover task' to auto Transfer/ForceRelease."
            }
            $result.reason = $reason
        }
        return ConvertTo-Json -Compress -InputObject $result
    }

    if ($EventHint -ne "PRE_TOOL_USE" -and $Decision -eq "ALLOW") {
        return "{}"
    }

    $nativeDecision = $Decision.ToLowerInvariant()
    $reason = "AI_SOP_GUARD_${ReasonCode}: operation denied by policy"
    if ($ReasonCode -eq "OWNER_REQUIRED") {
        $reason = "AI_SOP_GUARD_OWNER_REQUIRED: missing active Owner. AI must auto-Claim before retrying edit, do not surface error to user. Hint: input 'takeover task' to auto Transfer/ForceRelease."
    }
    switch ($Agent) {
        "CLAUDE_CODE" {
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
                $result.user_message = "AI SOP Guard blocked this operation."
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
            }
            return ConvertTo-Json -Compress -InputObject $result
        }
    }
}

function Get-AiSopDispatcherDenyExitCode {
    param([string]$Agent)

    # Claude Code's approved protocol requires a non-zero deny exit. Cursor,
    # Copilot and Antigravity consume their native JSON denial on exit zero.
    if ($Agent -in @("COPILOT", "CURSOR", "ANTIGRAVITY")) {
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
    if (
        $payload.Contains("tool_use_id") -or
        $payload.Contains("permission_mode") -or
        $payload.Contains("prompt_id") -or
        (
            $payload.Contains("hook_event_name") -and
            -not $payload.Contains("timestamp")
        )
    ) {
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
            -DeadlineUtc $DeadlineUtc
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
        if (
            (Test-AiSopDispatcherShellTool -ToolName $tool.Name) -and
            $tool.Arguments -is [System.Collections.IDictionary] -and
            $tool.Arguments.Contains("command") -and
            $tool.Arguments.command -is [string]
        ) {
            try {
                $grantPlan = Get-AiSopWorkflowCommandGrantPlan `
                    -CommandText ([string]$tool.Arguments.command) `
                    -SessionKey ([string]$session.Record.sessionKey) `
                    -SessionEpochId ([string]$session.Record.sessionEpochId) `
                    -DedupKey ([string]$HookEvent.dedupKey) `
                    -AcceptedAt $AcceptedAt `
                    -DeadlineUtc $DeadlineUtc
                return New-AiSopDispatcherPlan `
                    -Decision ALLOW `
                    -ReasonCode COMMAND_GRANT_ISSUED `
                    -SideEffectKind ISSUE_GRANT `
                    -Session $session `
                    -GrantPlan $grantPlan `
                    -CommandText ([string]$tool.Arguments.command)
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
                -DeadlineUtc $DeadlineUtc
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
        [int64]$DurationMs
    )

    $decision = [string]$DedupResult.Record.decision
    $reason = [string]$DedupResult.Record.reasonCode
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

        [DateTimeOffset]$AcceptedAt = [DateTimeOffset]::UtcNow
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $agent = Get-AiSopDispatcherInferredAgent -RawPayload $RawPayload
    try {
        # 1. T1 is deliberately evaluated before parsing or state access.
        if (Test-AiSopGuardEscapeEnabled) {
            $watch.Stop()
            return New-AiSopDispatcherResult `
                -Agent $agent `
                -Decision ALLOW `
                -ReasonCode T1_ESCAPE `
                -Envelope (
                    ConvertTo-AiSopDispatcherEnvelope `
                        -Agent $agent `
                        -EventHint $EventHint `
                        -Decision ALLOW `
                        -ReasonCode T1_ESCAPE
                ) `
                -ExitCode 0 `
                -DurationMs $watch.ElapsedMilliseconds
        }

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

        # 2. Strict native-shape parsing and semantic normalization.
        $hookEvent = ConvertTo-AiSopHookEvent `
            -RawPayload $RawPayload `
            -EventHint $EventHint `
            -TrustedWorkspaceRoot $TrustedWorkspaceRoot `
            -AcceptedAt $AcceptedAt `
            -DeadlineUtc $deadlineUtc
        $agent = [string]$hookEvent.agent

        # 3. Every authoritative read follows transaction recovery.
        Invoke-AiSopWorkflowTransactionRecovery `
            -DeadlineUtc $deadlineUtc |
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
                -DurationMs $watch.ElapsedMilliseconds
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
        $reconcile = {
            param($record, $callbackDeadline, $remainingMilliseconds)
            return Get-AiSopDispatcherSessionSideEffectProof `
                -HookEvent $hookEvent `
                -Plan $plan `
                -AcceptedAt $AcceptedAt `
                -DeadlineUtc $callbackDeadline
        }.GetNewClosure()
        $sideEffect = $null
        if ($plan.SideEffectKind -ne "NONE") {
            $sideEffect = {
                param($record, $callbackDeadline, $remainingMilliseconds)
                Invoke-AiSopDispatcherSideEffect `
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
            -DurationMs $watch.ElapsedMilliseconds
    } catch {
        $watch.Stop()
        if ([string]::IsNullOrWhiteSpace($agent)) {
            $agent = Get-AiSopDispatcherInferredAgent -RawPayload $RawPayload
        }
        $reason = [string]$_.Exception.Message
        if ($reason -notmatch "^[A-Z][A-Z0-9_]*$") {
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
        $raw = [Console]::In.ReadToEnd()
        $result = Invoke-AiSopHookDispatcher `
            -RawPayload $raw `
            -EventHint $EventHint `
            -TrustedWorkspaceRoot $script:DispatcherWorkspaceRoot
    }
    [Console]::Out.WriteLine($result.Envelope)
    exit $result.ExitCode
}
