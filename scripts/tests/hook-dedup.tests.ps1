#requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$ScriptsRoot = Split-Path -Parent $PSScriptRoot
$NormalizerScript = Join-Path $ScriptsRoot "hook-event-normalizer.ps1"
$DedupScript = Join-Path $ScriptsRoot "hook-dedup.ps1"
$DedupSchema = Join-Path (Split-Path -Parent $ScriptsRoot) "schemas\hook-dedup.schema.json"
$FixtureRoot = Join-Path $PSScriptRoot "fixtures\hooks"

foreach ($requiredPath in @($NormalizerScript, $DedupScript, $DedupSchema)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required Task 2 artifact does not exist: $requiredPath"
    }
}

. $NormalizerScript
. $DedupScript

function Assert-Equal {
    param(
        [AllowNull()]
        [object]$Actual,

        [AllowNull()]
        [object]$Expected,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-ThrowsCode {
    param(
        [scriptblock]$Action,
        [string]$Code,
        [string]$Message
    )

    try {
        & $Action | Out-Null
    } catch {
        if ($_.Exception.Message -notlike "$Code*") {
            throw "$Message Expected '$Code', got '$($_.Exception.Message)'."
        }
        return
    }
    throw "$Message Expected '$Code', but the action succeeded."
}

function Expand-FixtureValue {
    param(
        [AllowNull()]
        [object]$Value,
        [string]$Workspace,
        [string]$Transcript
    )

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [string]) {
        $expanded = $Value.Replace("__WORKSPACE__", $Workspace).Replace(
            "__TRANSCRIPT__",
            $Transcript
        )
        if (-not [System.OperatingSystem]::IsWindows()) {
            $expanded = $expanded.Replace(
                '\',
                [string][System.IO.Path]::DirectorySeparatorChar
            )
        }
        return $expanded
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $expanded = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $expanded[$key] = Expand-FixtureValue `
                -Value $Value[$key] -Workspace $Workspace -Transcript $Transcript
        }
        return $expanded
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        return ,@(
            foreach ($item in $Value) {
                Expand-FixtureValue `
                    -Value $item -Workspace $Workspace -Transcript $Transcript
            }
        )
    }
    return $Value
}

function Get-FixtureRaw {
    param(
        [string]$Name,
        [string]$Workspace,
        [string]$Transcript
    )

    $payload = Get-Content -LiteralPath (Join-Path $FixtureRoot $Name) -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $expanded = Expand-FixtureValue `
        -Value $payload -Workspace $Workspace -Transcript $Transcript
    return $expanded | ConvertTo-Json -Compress -Depth 100
}

function Convert-Fixture {
    param(
        [string]$Name,
        [string]$EventHint,
        [string]$Workspace,
        [string]$Transcript,
        [DateTimeOffset]$AcceptedAt
    )

    return ConvertTo-AiSopHookEvent `
        -RawPayload (Get-FixtureRaw $Name $Workspace $Transcript) `
        -EventHint $EventHint `
        -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
}

$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "hook-dedup-tests-" + [guid]::NewGuid().ToString("N")
)
$Workspace = Join-Path $TestRoot "workspace"
$Transcript = Join-Path $TestRoot "transcript.jsonl"
$PreviousDedupRegistry = $env:SERVER_NEW_HOOK_DEDUP_REGISTRY
$env:SERVER_NEW_HOOK_DEDUP_REGISTRY = Join-Path $TestRoot "dedup-registry"
$AcceptedAt = [DateTimeOffset]::Parse("2026-08-17T08:00:05.000Z")
$AuthorizationHash = ("a" * 64) -join ""
$IntentHash = ("b" * 64) -join ""
$script:DedupSideEffectCount = 0

try {
    [System.IO.Directory]::CreateDirectory($Workspace) | Out-Null
    [System.IO.Directory]::CreateDirectory(
        (Join-Path $Workspace ".claude")
    ) | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $Workspace "README.md"),
        "fixture"
    )

    $dedupSource = Get-Content -LiteralPath $DedupScript -Raw
    if (
        $dedupSource -match
        "Invoke-WebRequest|Invoke-RestMethod|Start-BitsTransfer|git\s+(fetch|clone)|svn\s+(checkout|update)"
    ) {
        throw "Hook dedup must be network-free."
    }
    Assert-True `
        -Condition (
            (Get-Command Invoke-AiSopHookDedup).Parameters.ContainsKey(
                "DeadlineUtc"
            )
        ) `
        -Message "Dedup does not accept the shared absolute deadline."
    foreach ($requiredParameter in @("ReconcilePrepared", "SideEffectId")) {
        Assert-True `
            -Condition (
                (Get-Command Invoke-AiSopHookDedup).Parameters.ContainsKey(
                    $requiredParameter
                )
            ) `
            -Message "Dedup is missing $requiredParameter recovery interface."
    }

    $pairs = @(
        [pscustomobject]@{
            Name = "SessionStart"
            EventHint = "SESSION_START"
            Compat = "copilot-claude-compat-session-start.json"
            Native = "copilot-github-session-start.json"
            Decision = "ALLOW"
            Reason = "SESSION_REGISTERED"
            GrantId = ""
            IntentSha256 = ""
        },
        [pscustomobject]@{
            Name = "SAFE_NON_EDIT"
            EventHint = "PRE_TOOL_USE"
            Compat = "copilot-claude-compat-pre-tool-read.json"
            Native = "copilot-github-pre-tool-read.json"
            Decision = "ALLOW"
            Reason = "SAFE_NON_EDIT"
            GrantId = ""
            IntentSha256 = ""
        },
        [pscustomobject]@{
            Name = "FILE_EDIT"
            EventHint = "PRE_TOOL_USE"
            Compat = "copilot-claude-compat-pre-tool-edit.json"
            Native = "copilot-github-pre-tool-edit-object-args.json"
            Decision = "DENY"
            Reason = "OWNER_REQUIRED"
            GrantId = ""
            IntentSha256 = ""
        },
        [pscustomobject]@{
            Name = "OWNER_REQUIRED"
            EventHint = "PRE_TOOL_USE"
            Compat = "copilot-claude-compat-pre-tool-shell.json"
            Native = "copilot-github-pre-tool-shell.json"
            Decision = "ALLOW"
            Reason = "COMMAND_GRANT_ISSUED"
            GrantId = "grant-fixture-001"
            IntentSha256 = $IntentHash
        }
    )

    $registryIoEvent = Convert-Fixture `
        -Name "copilot-github-pre-tool-read.json" `
        -EventHint "PRE_TOOL_USE" -Workspace $Workspace `
        -Transcript $Transcript -AcceptedAt $AcceptedAt
    $validDedupRegistry = $env:SERVER_NEW_HOOK_DEDUP_REGISTRY
    $dedupRegistryFile = Join-Path $TestRoot "dedup-registry-file"
    [System.IO.File]::WriteAllText($dedupRegistryFile, "not-a-directory")
    $env:SERVER_NEW_HOOK_DEDUP_REGISTRY = $dedupRegistryFile
    try {
        Assert-ThrowsCode -Code "REGISTRY_IO_ERROR" `
            -Message "Dedup registry root I/O leaked a raw exception." `
            -Action {
                Invoke-AiSopHookDedup `
                    -HookEvent $registryIoEvent `
                    -Decision "ALLOW" `
                    -ReasonCode "SAFE_NON_EDIT" `
                    -AcceptedAt $AcceptedAt
            }
    } finally {
        $env:SERVER_NEW_HOOK_DEDUP_REGISTRY = $validDedupRegistry
    }

    foreach ($pair in $pairs) {
        $compat = Convert-Fixture `
            -Name $pair.Compat -EventHint $pair.EventHint `
            -Workspace $Workspace -Transcript $Transcript `
            -AcceptedAt $AcceptedAt
        $native = Convert-Fixture `
            -Name $pair.Native -EventHint $pair.EventHint `
            -Workspace $Workspace -Transcript $Transcript `
            -AcceptedAt $AcceptedAt

        Assert-Equal $compat.agent "COPILOT" "$($pair.Name) compat Agent mismatch."
        Assert-Equal $native.agent "COPILOT" "$($pair.Name) native Agent mismatch."
        Assert-Equal `
            (Get-AiSopHookSessionKey -HookEvent $compat) `
            (Get-AiSopHookSessionKey -HookEvent $native) `
            "$($pair.Name) session key mismatch."
        Assert-Equal `
            $compat.canonicalSemanticArgsSha256 `
            $native.canonicalSemanticArgsSha256 `
            "$($pair.Name) semantic args hash mismatch."
        Assert-Equal `
            $compat.canonicalTargetsSha256 `
            $native.canonicalTargetsSha256 `
            "$($pair.Name) target hash mismatch."
        Assert-Equal `
            $compat.dedupKey $native.dedupKey `
            "$($pair.Name) dedup key mismatch."

        $beforeSideEffects = $script:DedupSideEffectCount
        $first = Invoke-AiSopHookDedup `
            -HookEvent $compat `
            -Decision $pair.Decision `
            -ReasonCode $pair.Reason `
            -AuthorizationSnapshotSha256 $AuthorizationHash `
            -BootstrapGrantId $pair.GrantId `
            -IntentSha256 $pair.IntentSha256 `
            -AcceptedAt $AcceptedAt `
            -SideEffect {
                param($record)
                $script:DedupSideEffectCount++
            }
        Assert-Equal $first.IsDuplicate $false "$($pair.Name) first event marked duplicate."
        Assert-Equal `
            $first.SideEffectAppliedNow $true `
            "$($pair.Name) first event skipped side effect."
        Assert-Equal `
            $script:DedupSideEffectCount ($beforeSideEffects + 1) `
            "$($pair.Name) first side effect count mismatch."

        $recordJson = Get-Content -LiteralPath $first.RegistryPath -Raw
        Assert-True `
            -Condition ($recordJson | Test-Json -SchemaFile $DedupSchema) `
            -Message "$($pair.Name) dedup record fails schema validation."
        $recordObject = $recordJson | ConvertFrom-Json
        Assert-Equal `
            $recordObject.sideEffectsApplied $true `
            "$($pair.Name) did not persist sideEffectsApplied."

        foreach ($forbiddenProperty in @(
            "rawPayload",
            "rawPayloadSha256",
            "command",
            "secret",
            "toolArgs",
            "toolInput"
        )) {
            Assert-True `
                -Condition ($forbiddenProperty -notin $recordObject.PSObject.Properties.Name) `
                -Message "$($pair.Name) dedup record persisted forbidden '$forbiddenProperty'."
        }
        foreach ($forbiddenValue in @(
            $compat.rawPayloadSha256,
            "Get-Location",
            "before",
            "after",
            "fixture-secret-value"
        )) {
            Assert-True `
                -Condition (-not $recordJson.Contains($forbiddenValue)) `
                -Message "$($pair.Name) dedup record leaked payload/command/secret content."
        }

        $fixedLastWrite = [DateTime]::SpecifyKind(
            [DateTime]::Parse("2020-01-02T03:04:05"),
            [DateTimeKind]::Utc
        )
        [System.IO.File]::SetLastWriteTimeUtc($first.RegistryPath, $fixedLastWrite)
        $expiresAtBefore = $first.Record.expiresAt

        $second = Invoke-AiSopHookDedup `
            -HookEvent $native `
            -Decision $(if ($pair.Decision -eq "ALLOW") { "DENY" } else { "ALLOW" }) `
            -ReasonCode "SHOULD_NOT_REPLACE" `
            -AuthorizationSnapshotSha256 (("c" * 64) -join "") `
            -BootstrapGrantId "grant-should-not-replace" `
            -IntentSha256 (("d" * 64) -join "") `
            -AcceptedAt $AcceptedAt.AddMilliseconds(1) `
            -SideEffect {
                param($record)
                $script:DedupSideEffectCount++
            }

        Assert-Equal $second.IsDuplicate $true "$($pair.Name) duplicate was not recognized."
        Assert-Equal `
            $second.SideEffectAppliedNow $false `
            "$($pair.Name) duplicate applied a second side effect."
        Assert-Equal `
            $script:DedupSideEffectCount ($beforeSideEffects + 1) `
            "$($pair.Name) duplicate side effect count changed."
        Assert-Equal `
            $second.Record.decision $pair.Decision `
            "$($pair.Name) duplicate did not replay decision."
        Assert-Equal `
            $second.Record.reasonCode $pair.Reason `
            "$($pair.Name) duplicate did not replay reason."
        Assert-Equal `
            $second.Record.bootstrapGrantId $pair.GrantId `
            "$($pair.Name) duplicate did not replay grant ID."
        Assert-Equal `
            $second.Record.expiresAt $expiresAtBefore `
            "$($pair.Name) duplicate renewed TTL."
        Assert-Equal `
            ([System.IO.File]::GetLastWriteTimeUtc($first.RegistryPath)) `
            $fixedLastWrite `
            "$($pair.Name) duplicate touched the stored record."
    }

    Assert-Equal `
        $script:DedupSideEffectCount $pairs.Count `
        "Semantic pairs did not apply exactly one side effect each."

    $forwardRegistry = $env:SERVER_NEW_HOOK_DEDUP_REGISTRY
    $env:SERVER_NEW_HOOK_DEDUP_REGISTRY = Join-Path $TestRoot "reverse-registry"
    $script:ReverseSideEffectCount = 0
    foreach ($pair in $pairs) {
        $nativeFirst = Convert-Fixture `
            -Name $pair.Native -EventHint $pair.EventHint `
            -Workspace $Workspace -Transcript $Transcript `
            -AcceptedAt $AcceptedAt
        $compatSecond = Convert-Fixture `
            -Name $pair.Compat -EventHint $pair.EventHint `
            -Workspace $Workspace -Transcript $Transcript `
            -AcceptedAt $AcceptedAt
        $nativeResult = Invoke-AiSopHookDedup `
            -HookEvent $nativeFirst `
            -Decision $pair.Decision `
            -ReasonCode $pair.Reason `
            -AuthorizationSnapshotSha256 $AuthorizationHash `
            -BootstrapGrantId $pair.GrantId `
            -IntentSha256 $pair.IntentSha256 `
            -AcceptedAt $AcceptedAt `
            -SideEffect { $script:ReverseSideEffectCount++ }
        $compatResult = Invoke-AiSopHookDedup `
            -HookEvent $compatSecond `
            -Decision $(if ($pair.Decision -eq "ALLOW") { "DENY" } else { "ALLOW" }) `
            -ReasonCode "SHOULD_NOT_REPLACE" `
            -AcceptedAt $AcceptedAt.AddMilliseconds(1) `
            -SideEffect { $script:ReverseSideEffectCount++ }
        Assert-Equal `
            $nativeResult.IsDuplicate $false `
            "$($pair.Name) native-first arrival was marked duplicate."
        Assert-Equal `
            $compatResult.IsDuplicate $true `
            "$($pair.Name) native-to-compat replay was not duplicate."
        Assert-Equal `
            $compatResult.Record.decision $pair.Decision `
            "$($pair.Name) native-to-compat replay changed decision."
    }
    Assert-Equal `
        $script:ReverseSideEffectCount $pairs.Count `
        "Native-to-compat pairs did not apply exactly one side effect each."
    $env:SERVER_NEW_HOOK_DEDUP_REGISTRY = $forwardRegistry

    # A fixed dedup key from a native timestamp/occurrence survives the
    # separate five-second lifecycle correlation window and replays the first
    # result without callback or TTL touch.
    $retentionPayload = Get-FixtureRaw `
        -Name "copilot-github-pre-tool-read.json" `
        -Workspace $Workspace -Transcript $Transcript |
        ConvertFrom-Json -AsHashtable -Depth 100
    $retentionPayload.sessionId = "copilot-retention-session"
    $retentionEvent = ConvertTo-AiSopHookEvent `
        -RawPayload ($retentionPayload | ConvertTo-Json -Compress -Depth 100) `
        -EventHint "PRE_TOOL_USE" `
        -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    $script:DedupRetentionCount = 0
    $retentionFirst = Invoke-AiSopHookDedup `
        -HookEvent $retentionEvent `
        -Decision "DENY" `
        -ReasonCode "FIRST_DENY" `
        -AcceptedAt $AcceptedAt `
        -SideEffect { $script:DedupRetentionCount++ }
    $retentionMtime = [System.IO.File]::GetLastWriteTimeUtc(
        $retentionFirst.RegistryPath
    )
    foreach ($delaySeconds in @(5, 6, 10)) {
        $retentionReplay = Invoke-AiSopHookDedup `
            -HookEvent $retentionEvent `
            -Decision "ALLOW" `
            -ReasonCode "SHOULD_NOT_REPLACE" `
            -AcceptedAt $AcceptedAt.AddSeconds($delaySeconds) `
            -SideEffect { $script:DedupRetentionCount++ }
        Assert-Equal `
            $retentionReplay.IsDuplicate $true `
            "Delayed duplicate at +${delaySeconds}s was accepted as new."
        Assert-Equal `
            $retentionReplay.Record.decision "DENY" `
            "Delayed duplicate at +${delaySeconds}s replaced first DENY."
        Assert-Equal `
            $retentionReplay.Record.reasonCode "FIRST_DENY" `
            "Delayed duplicate at +${delaySeconds}s replaced first reason."
        Assert-Equal `
            ([System.IO.File]::GetLastWriteTimeUtc($retentionFirst.RegistryPath)) `
            $retentionMtime `
            "Delayed duplicate at +${delaySeconds}s touched the record."
    }
    Assert-Equal `
        $script:DedupRetentionCount 1 `
        "Delayed duplicate executed a second callback."

    # PREPARED is durable before callback. A callback failure/kill window
    # remains PREPARED and every replay fails closed without another callback.
    $preparedPayload = Get-FixtureRaw `
        -Name "copilot-github-pre-tool-shell.json" `
        -Workspace $Workspace -Transcript $Transcript |
        ConvertFrom-Json -AsHashtable -Depth 100
    $preparedPayload.sessionId = "copilot-prepared-session"
    $preparedEvent = ConvertTo-AiSopHookEvent `
        -RawPayload ($preparedPayload | ConvertTo-Json -Compress -Depth 100) `
        -EventHint "PRE_TOOL_USE" `
        -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    $script:PreparedCallbackCount = 0
    Assert-ThrowsCode -Code "SIDE_EFFECT_FAILED" `
        -Message "Callback failure was not surfaced stably." `
        -Action {
            Invoke-AiSopHookDedup `
                -HookEvent $preparedEvent `
                -Decision "ALLOW" `
                -ReasonCode "COMMAND_GRANT_ISSUED" `
                -BootstrapGrantId "grant-prepared" `
                -SideEffectId "tx-prepared" `
                -AcceptedAt $AcceptedAt `
                -SideEffect {
                    $script:PreparedCallbackCount++
                    throw "simulated kill window"
                }
        }
    $preparedSession = Get-AiSopHookSessionKey -HookEvent $preparedEvent
    $preparedPath = Join-Path (
        Join-Path $env:SERVER_NEW_HOOK_DEDUP_REGISTRY $preparedSession
    ) "$($preparedEvent.dedupKey).json"
    $preparedRecord = Get-Content -LiteralPath $preparedPath -Raw |
        ConvertFrom-Json
    Assert-Equal `
        $preparedRecord.state "PREPARED" `
        "Callback ran before durable PREPARED state."
    Assert-Equal `
        $preparedRecord.sideEffectId "tx-prepared" `
        "PREPARED record lost deterministic sideEffectId."
    $preparedReplay = Invoke-AiSopHookDedup `
        -HookEvent $preparedEvent `
        -Decision "ALLOW" `
        -ReasonCode "COMMAND_GRANT_ISSUED" `
        -AcceptedAt $AcceptedAt.AddSeconds(1) `
        -ReconcilePrepared { "INDETERMINATE" } `
        -SideEffect { $script:PreparedCallbackCount++ }
    Assert-Equal $preparedReplay.IsDuplicate $true "PREPARED replay was not duplicate."
    Assert-Equal $preparedReplay.Record.decision "DENY" "PREPARED replay did not fail closed."
    Assert-Equal `
        $preparedReplay.Record.reasonCode "DEDUP_RECOVERY_REQUIRED" `
        "PREPARED replay reason mismatch."
    Assert-Equal `
        $script:PreparedCallbackCount 1 `
        "PREPARED replay executed callback again."

    $deadlinePayload = Get-FixtureRaw `
        -Name "copilot-github-pre-tool-shell.json" `
        -Workspace $Workspace -Transcript $Transcript |
        ConvertFrom-Json -AsHashtable -Depth 100
    $deadlinePayload.sessionId = "copilot-reconcile-deadline-session"
    $deadlineEvent = ConvertTo-AiSopHookEvent `
        -RawPayload ($deadlinePayload | ConvertTo-Json -Compress -Depth 100) `
        -EventHint "PRE_TOOL_USE" `
        -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    Assert-ThrowsCode -Code "SIDE_EFFECT_FAILED" `
        -Message "Deadline reconcile fixture did not remain PREPARED." `
        -Action {
            Invoke-AiSopHookDedup `
                -HookEvent $deadlineEvent `
                -Decision "ALLOW" `
                -ReasonCode "COMMAND_GRANT_ISSUED" `
                -SideEffectId "tx-reconcile-deadline" `
                -AcceptedAt $AcceptedAt `
                -SideEffect { throw "prepare reconcile deadline fixture" }
        }
    $deadlineSession = Get-AiSopHookSessionKey -HookEvent $deadlineEvent
    $deadlineRecordPath = Join-Path (
        Join-Path $env:SERVER_NEW_HOOK_DEDUP_REGISTRY $deadlineSession
    ) "$($deadlineEvent.dedupKey).json"
    $deadlineMarker = Join-Path $TestRoot "reconcile-deadline-marker"
    $script:ReconcileDeadlineArgument = $null
    $script:ReconcileRemainingArgument = -1
    $callbackDeadline = [DateTimeOffset]::UtcNow.AddMilliseconds(50)
    $callbackStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Assert-ThrowsCode -Code "REGISTRY_DEADLINE_EXCEEDED" `
        -Message "Over-budget reconcile persisted or returned ALLOW." `
        -Action {
            Invoke-AiSopHookDedup `
                -HookEvent $deadlineEvent `
                -Decision "DENY" `
                -ReasonCode "SHOULD_NOT_REPLACE" `
                -AcceptedAt $AcceptedAt.AddSeconds(1) `
                -DeadlineUtc $callbackDeadline `
                -ReconcilePrepared {
                    param($record, $deadlineUtc, $remainingMilliseconds)
                    $script:ReconcileDeadlineArgument = $deadlineUtc
                    $script:ReconcileRemainingArgument = $remainingMilliseconds
                    [System.IO.File]::WriteAllText(
                        $deadlineMarker,
                        $record.sideEffectId
                    )
                    Start-Sleep -Milliseconds 300
                    return "APPLIED"
                } `
                -SideEffect { throw "must not run after APPLIED proof" }
        }
    $callbackStopwatch.Stop()
    Assert-Equal `
        $script:ReconcileDeadlineArgument.ToUniversalTime() `
        $callbackDeadline.ToUniversalTime() `
        "Reconcile callback did not receive shared DeadlineUtc."
    Assert-True `
        -Condition (
            $script:ReconcileRemainingArgument -gt 0 -and
            $script:ReconcileRemainingArgument -le 50
        ) `
        -Message "Reconcile callback did not receive remaining budget."
    Assert-True `
        -Condition (
            $callbackStopwatch.ElapsedMilliseconds -ge 300 -and
            $callbackStopwatch.ElapsedMilliseconds -le 750
        ) `
        -Message "Reconcile deadline runtime was not strictly bounded."
    Assert-Equal `
        ([System.IO.File]::ReadAllText($deadlineMarker)) `
        "tx-reconcile-deadline" `
        "Reconcile deadline marker did not prove callback execution."
    $deadlineRecord = Get-Content -LiteralPath $deadlineRecordPath -Raw |
        ConvertFrom-Json
    Assert-Equal `
        $deadlineRecord.state "PREPARED" `
        "Over-budget reconcile persisted APPLIED."
    $deadlineConverged = Invoke-AiSopHookDedup `
        -HookEvent $deadlineEvent `
        -Decision "DENY" `
        -ReasonCode "SHOULD_NOT_REPLACE" `
        -AcceptedAt $AcceptedAt.AddSeconds(2) `
        -ReconcilePrepared {
            param($record)
            if (
                $record.sideEffectId -eq "tx-reconcile-deadline" -and
                (Test-Path $deadlineMarker)
            ) {
                return "APPLIED"
            }
            return "INDETERMINATE"
        } `
        -SideEffect { throw "proof convergence must not repeat side effect" }
    Assert-Equal `
        $deadlineConverged.Record.decision "ALLOW" `
        "Later durable proof did not converge reconcile timeout."

    $notAppliedDeadlinePayload = Get-FixtureRaw `
        -Name "copilot-github-pre-tool-shell.json" `
        -Workspace $Workspace -Transcript $Transcript |
        ConvertFrom-Json -AsHashtable -Depth 100
    $notAppliedDeadlinePayload.sessionId = "copilot-side-effect-deadline-session"
    $notAppliedDeadlineEvent = ConvertTo-AiSopHookEvent `
        -RawPayload (
            $notAppliedDeadlinePayload |
                ConvertTo-Json -Compress -Depth 100
        ) `
        -EventHint "PRE_TOOL_USE" `
        -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    Assert-ThrowsCode -Code "SIDE_EFFECT_FAILED" `
        -Message "Deadline side-effect fixture did not remain PREPARED." `
        -Action {
            Invoke-AiSopHookDedup `
                -HookEvent $notAppliedDeadlineEvent `
                -Decision "ALLOW" `
                -ReasonCode "COMMAND_GRANT_ISSUED" `
                -SideEffectId "tx-side-effect-deadline" `
                -AcceptedAt $AcceptedAt `
                -SideEffect { throw "prepare side-effect deadline fixture" }
        }
    $sideEffectDeadlineSession = Get-AiSopHookSessionKey `
        -HookEvent $notAppliedDeadlineEvent
    $sideEffectDeadlinePath = Join-Path (
        Join-Path `
            $env:SERVER_NEW_HOOK_DEDUP_REGISTRY `
            $sideEffectDeadlineSession
    ) "$($notAppliedDeadlineEvent.dedupKey).json"
    $sideEffectDeadlineMarker = Join-Path $TestRoot "side-effect-deadline-marker"
    $script:SideEffectDeadlineArgument = $null
    $script:SideEffectRemainingArgument = -1
    $sideEffectDeadline = [DateTimeOffset]::UtcNow.AddMilliseconds(50)
    Assert-ThrowsCode -Code "REGISTRY_DEADLINE_EXCEEDED" `
        -Message "Over-budget NOT_APPLIED side effect persisted APPLIED." `
        -Action {
            Invoke-AiSopHookDedup `
                -HookEvent $notAppliedDeadlineEvent `
                -Decision "DENY" `
                -ReasonCode "SHOULD_NOT_REPLACE" `
                -AcceptedAt $AcceptedAt.AddSeconds(1) `
                -DeadlineUtc $sideEffectDeadline `
                -ReconcilePrepared { "NOT_APPLIED" } `
                -SideEffect {
                    param($record, $deadlineUtc, $remainingMilliseconds)
                    $script:SideEffectDeadlineArgument = $deadlineUtc
                    $script:SideEffectRemainingArgument = $remainingMilliseconds
                    [System.IO.File]::WriteAllText(
                        $sideEffectDeadlineMarker,
                        $record.sideEffectId
                    )
                    Start-Sleep -Milliseconds 300
                }
        }
    Assert-Equal `
        $script:SideEffectDeadlineArgument.ToUniversalTime() `
        $sideEffectDeadline.ToUniversalTime() `
        "NOT_APPLIED side effect did not receive shared DeadlineUtc."
    Assert-True `
        -Condition (
            $script:SideEffectRemainingArgument -gt 0 -and
            $script:SideEffectRemainingArgument -le 50
        ) `
        -Message "NOT_APPLIED side effect did not receive remaining budget."
    $sideEffectDeadlineRecord = Get-Content `
        -LiteralPath $sideEffectDeadlinePath -Raw |
        ConvertFrom-Json
    Assert-Equal `
        $sideEffectDeadlineRecord.state "PREPARED" `
        "Over-budget NOT_APPLIED side effect persisted APPLIED."
    $sideEffectDeadlineConverged = Invoke-AiSopHookDedup `
        -HookEvent $notAppliedDeadlineEvent `
        -Decision "DENY" `
        -ReasonCode "SHOULD_NOT_REPLACE" `
        -AcceptedAt $AcceptedAt.AddSeconds(2) `
        -ReconcilePrepared {
            if (Test-Path $sideEffectDeadlineMarker) {
                return "APPLIED"
            }
            return "INDETERMINATE"
        } `
        -SideEffect { throw "proof convergence repeated timed-out side effect" }
    Assert-Equal `
        $sideEffectDeadlineConverged.Record.decision "ALLOW" `
        "Later proof did not converge timed-out NOT_APPLIED side effect."

    $killPayload = Get-FixtureRaw `
        -Name "copilot-github-pre-tool-shell.json" `
        -Workspace $Workspace -Transcript $Transcript |
        ConvertFrom-Json -AsHashtable -Depth 100
    $killPayload.sessionId = "copilot-kill-window-session"
    $killRaw = $killPayload | ConvertTo-Json -Compress -Depth 100
    $killMarker = Join-Path $TestRoot "kill-window-effect.txt"
    $killJob = Start-Job -ScriptBlock {
        param(
            $NormalizerPath,
            $DedupPath,
            $Raw,
            $TrustedWorkspace,
            $Registry,
            $Clock,
            $Marker
        )
        $ErrorActionPreference = "Stop"
        $env:SERVER_NEW_HOOK_DEDUP_REGISTRY = $Registry
        . $NormalizerPath
        . $DedupPath
        $acceptedAt = [DateTimeOffset]::Parse($Clock)
        $event = ConvertTo-AiSopHookEvent `
            -RawPayload $Raw `
            -EventHint "PRE_TOOL_USE" `
            -TrustedWorkspaceRoot $TrustedWorkspace `
            -AcceptedAt $acceptedAt
        Invoke-AiSopHookDedup `
            -HookEvent $event `
            -Decision "ALLOW" `
            -ReasonCode "COMMAND_GRANT_ISSUED" `
            -BootstrapGrantId "grant-kill-window" `
            -SideEffectId "tx-kill-window" `
            -AcceptedAt $acceptedAt `
            -SideEffect {
                [System.IO.File]::WriteAllText($Marker, "effect")
                Stop-Process -Id $PID -Force
            }
    } -ArgumentList @(
        $NormalizerScript,
        $DedupScript,
        $killRaw,
        $Workspace,
        $env:SERVER_NEW_HOOK_DEDUP_REGISTRY,
        $AcceptedAt.ToString("o"),
        $killMarker
    )
    try {
        $killWaitDeadline = [DateTimeOffset]::UtcNow.AddSeconds(20)
        while (
            -not (Test-Path $killMarker) -and
            [DateTimeOffset]::UtcNow -lt $killWaitDeadline
        ) {
            Start-Sleep -Milliseconds 20
        }
        Assert-True `
            -Condition (Test-Path $killMarker) `
            -Message "Strong-kill callback fixture did not execute."
        $killEvent = ConvertTo-AiSopHookEvent `
            -RawPayload $killRaw `
            -EventHint "PRE_TOOL_USE" `
            -TrustedWorkspaceRoot $Workspace `
            -AcceptedAt $AcceptedAt
        $killSession = Get-AiSopHookSessionKey -HookEvent $killEvent
        $killRecordPath = Join-Path (
            Join-Path $env:SERVER_NEW_HOOK_DEDUP_REGISTRY $killSession
        ) "$($killEvent.dedupKey).json"
        $killRecord = Get-Content -LiteralPath $killRecordPath -Raw |
            ConvertFrom-Json
        Assert-Equal `
            $killRecord.state "PREPARED" `
            "Strong kill did not leave recoverable PREPARED state."
        $script:KillReplayCallbackCount = 0
        $killReplay = Invoke-AiSopHookDedup `
            -HookEvent $killEvent `
            -Decision "ALLOW" `
            -ReasonCode "COMMAND_GRANT_ISSUED" `
            -AcceptedAt $AcceptedAt.AddSeconds(1) `
            -ReconcilePrepared {
                param($record)
                if (
                    $record.sideEffectId -eq "tx-kill-window" -and
                    (Test-Path $killMarker)
                ) {
                    return "APPLIED"
                }
                return "INDETERMINATE"
            } `
            -SideEffect { $script:KillReplayCallbackCount++ }
        Assert-Equal `
            $killReplay.Record.decision "ALLOW" `
            "APPLIED reconcile did not replay first decision."
        Assert-Equal `
            $killReplay.Record.reasonCode "COMMAND_GRANT_ISSUED" `
            "APPLIED reconcile did not replay first reason."
        Assert-Equal `
            $script:KillReplayCallbackCount 0 `
            "Strong-kill PREPARED replay duplicated callback."
        $killAppliedRecord = Get-Content -LiteralPath $killRecordPath -Raw |
            ConvertFrom-Json
        Assert-Equal `
            $killAppliedRecord.state "APPLIED" `
            "APPLIED reconcile was not persisted."
    } finally {
        Remove-Job -Job $killJob -Force -ErrorAction SilentlyContinue
    }

    $notAppliedPayload = Get-FixtureRaw `
        -Name "copilot-github-pre-tool-shell.json" `
        -Workspace $Workspace -Transcript $Transcript |
        ConvertFrom-Json -AsHashtable -Depth 100
    $notAppliedPayload.sessionId = "copilot-not-applied-session"
    $notAppliedEvent = ConvertTo-AiSopHookEvent `
        -RawPayload ($notAppliedPayload | ConvertTo-Json -Compress -Depth 100) `
        -EventHint "PRE_TOOL_USE" `
        -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    Assert-ThrowsCode -Code "SIDE_EFFECT_FAILED" `
        -Message "NOT_APPLIED fixture did not remain PREPARED." `
        -Action {
            Invoke-AiSopHookDedup `
                -HookEvent $notAppliedEvent `
                -Decision "ALLOW" `
                -ReasonCode "COMMAND_GRANT_ISSUED" `
                -SideEffectId "tx-not-applied" `
                -AcceptedAt $AcceptedAt `
                -SideEffect { throw "not applied" }
        }
    $notAppliedMarker = Join-Path $TestRoot "not-applied-marker"
    $notAppliedReplay = Invoke-AiSopHookDedup `
        -HookEvent $notAppliedEvent `
        -Decision "DENY" `
        -ReasonCode "SHOULD_NOT_REPLACE" `
        -AcceptedAt $AcceptedAt.AddSeconds(1) `
        -ReconcilePrepared { "NOT_APPLIED" } `
        -SideEffect {
            param($record)
            [System.IO.File]::WriteAllText(
                $notAppliedMarker,
                $record.sideEffectId
            )
        }
    Assert-Equal `
        $notAppliedReplay.Record.decision "ALLOW" `
        "NOT_APPLIED recovery did not replay first decision."
    Assert-Equal `
        $notAppliedReplay.Record.reasonCode "COMMAND_GRANT_ISSUED" `
        "NOT_APPLIED recovery did not replay first reason."
    Assert-Equal `
        ([System.IO.File]::ReadAllText($notAppliedMarker)) "tx-not-applied" `
        "NOT_APPLIED recovery did not execute deterministic side effect."
    $notAppliedReplayAgain = Invoke-AiSopHookDedup `
        -HookEvent $notAppliedEvent `
        -Decision "DENY" `
        -ReasonCode "SHOULD_NOT_REPLACE" `
        -AcceptedAt $AcceptedAt.AddSeconds(2) `
        -ReconcilePrepared { throw "must not reconcile APPLIED" } `
        -SideEffect { throw "must not repeat APPLIED side effect" }
    Assert-Equal `
        $notAppliedReplayAgain.Record.decision "ALLOW" `
        "Recovered APPLIED record did not replay first result."

    $truncatedPayload = Get-FixtureRaw `
        -Name "copilot-github-pre-tool-read.json" `
        -Workspace $Workspace -Transcript $Transcript |
        ConvertFrom-Json -AsHashtable -Depth 100
    $truncatedPayload.sessionId = "copilot-truncated-session"
    $truncatedEvent = ConvertTo-AiSopHookEvent `
        -RawPayload ($truncatedPayload | ConvertTo-Json -Compress -Depth 100) `
        -EventHint "PRE_TOOL_USE" `
        -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    $truncatedSession = Get-AiSopHookSessionKey -HookEvent $truncatedEvent
    $truncatedDirectory = Join-Path `
        $env:SERVER_NEW_HOOK_DEDUP_REGISTRY $truncatedSession
    [System.IO.Directory]::CreateDirectory($truncatedDirectory) | Out-Null
    $truncatedPath = Join-Path `
        $truncatedDirectory "$($truncatedEvent.dedupKey).json"
    [System.IO.File]::WriteAllText($truncatedPath, "{")
    $script:TruncatedCallbackCount = 0
    Assert-ThrowsCode -Code "REGISTRY_CORRUPT" `
        -Message "Truncated dedup record was treated as a new event." `
        -Action {
            Invoke-AiSopHookDedup `
                -HookEvent $truncatedEvent `
                -Decision "ALLOW" `
                -ReasonCode "SAFE_NON_EDIT" `
                -AcceptedAt $AcceptedAt `
                -SideEffect { $script:TruncatedCallbackCount++ }
        }
    Assert-Equal `
        $script:TruncatedCallbackCount 0 `
        "Truncated record allowed callback execution."

    # Parseable current records must be schema/identity validated while their
    # own dedup lock is held, before a past expiry can make them replaceable.
    $dedupRegistryBeforeCorruptCases = $env:SERVER_NEW_HOOK_DEDUP_REGISTRY
    try {
        $dedupCorruptCases = @(
            [pscustomobject]@{
                Name = "missing-required"
                Mutate = {
                    param($record)
                    $record.Remove("reasonCode") | Out-Null
                }
            },
            [pscustomobject]@{
                Name = "wrong-state"
                Mutate = {
                    param($record)
                    $record.state = "EXPIRED"
                }
            },
            [pscustomobject]@{
                Name = "wrong-identity"
                Mutate = {
                    param($record)
                    $record.dedupKey = ("f" * 64)
                }
            }
        )
        foreach ($corruptCase in $dedupCorruptCases) {
            $caseRegistry = Join-Path `
                $TestRoot "dedup-corrupt-$($corruptCase.Name)"
            $env:SERVER_NEW_HOOK_DEDUP_REGISTRY = $caseRegistry
            $casePayload = Get-FixtureRaw `
                -Name "copilot-github-pre-tool-read.json" `
                -Workspace $Workspace -Transcript $Transcript |
                ConvertFrom-Json -AsHashtable -Depth 100
            $casePayload.sessionId = "dedup-$($corruptCase.Name)-session"
            $caseEvent = ConvertTo-AiSopHookEvent `
                -RawPayload ($casePayload | ConvertTo-Json -Compress -Depth 100) `
                -EventHint "PRE_TOOL_USE" `
                -TrustedWorkspaceRoot $Workspace `
                -AcceptedAt $AcceptedAt
            $caseSeed = Invoke-AiSopHookDedup `
                -HookEvent $caseEvent `
                -Decision "ALLOW" `
                -ReasonCode "SAFE_NON_EDIT" `
                -AcceptedAt $AcceptedAt
            $caseRecord = Get-Content -LiteralPath $caseSeed.RegistryPath -Raw |
                ConvertFrom-Json -AsHashtable -Depth 20
            $caseRecord.expiresAt = $AcceptedAt.AddSeconds(-1).ToString("o")
            $mutate = $corruptCase.Mutate
            & $mutate $caseRecord
            $caseRecordJson = $caseRecord | ConvertTo-Json -Compress -Depth 20
            [System.IO.File]::WriteAllText(
                $caseSeed.RegistryPath,
                $caseRecordJson,
                [System.Text.UTF8Encoding]::new($false)
            )
            $script:ExpiredCorruptCallbackCount = 0
            Assert-ThrowsCode -Code "REGISTRY_CORRUPT" `
                -Message (
                    "Expired dedup $($corruptCase.Name) record was " +
                    "scavenged before strict validation."
                ) `
                -Action {
                    Invoke-AiSopHookDedup `
                        -HookEvent $caseEvent `
                        -Decision "DENY" `
                        -ReasonCode "SHOULD_NOT_REPLACE" `
                        -AcceptedAt $AcceptedAt.AddSeconds(10) `
                        -SideEffect {
                            $script:ExpiredCorruptCallbackCount++
                        }
                }
            Assert-Equal `
                $script:ExpiredCorruptCallbackCount 0 `
                "Expired corrupt dedup record allowed callback execution."
            Assert-True `
                -Condition ([System.IO.File]::Exists($caseSeed.RegistryPath)) `
                -Message "Expired corrupt dedup record was deleted."
            Assert-Equal `
                ([System.IO.File]::ReadAllText($caseSeed.RegistryPath)) `
                $caseRecordJson `
                "Expired corrupt dedup record was replaced."
        }

        # A corrupt non-current record in the same session directory must also
        # stop lazy scavenging before the current event's callback can run.
        $foreignRegistry = Join-Path $TestRoot "dedup-corrupt-foreign"
        $env:SERVER_NEW_HOOK_DEDUP_REGISTRY = $foreignRegistry
        $foreignPayload = Get-FixtureRaw `
            -Name "copilot-github-pre-tool-read.json" `
            -Workspace $Workspace -Transcript $Transcript |
            ConvertFrom-Json -AsHashtable -Depth 100
        $foreignPayload.sessionId = "dedup-foreign-corrupt-session"
        $foreignEvent = ConvertTo-AiSopHookEvent `
            -RawPayload ($foreignPayload | ConvertTo-Json -Compress -Depth 100) `
            -EventHint "PRE_TOOL_USE" `
            -TrustedWorkspaceRoot $Workspace `
            -AcceptedAt $AcceptedAt
        $foreignSeed = Invoke-AiSopHookDedup `
            -HookEvent $foreignEvent `
            -Decision "ALLOW" `
            -ReasonCode "SAFE_NON_EDIT" `
            -AcceptedAt $AcceptedAt
        $foreignRecord = Get-Content -LiteralPath $foreignSeed.RegistryPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 20
        $foreignRecord.state = "EXPIRED"
        $foreignRecord.expiresAt = $AcceptedAt.AddSeconds(-1).ToString("o")
        $foreignRecordJson = $foreignRecord |
            ConvertTo-Json -Compress -Depth 20
        [System.IO.File]::WriteAllText(
            $foreignSeed.RegistryPath,
            $foreignRecordJson,
            [System.Text.UTF8Encoding]::new($false)
        )
        $currentPayload = $foreignPayload |
            ConvertTo-Json -Depth 100 |
            ConvertFrom-Json -AsHashtable -Depth 100
        $currentPayload.toolArgs.path = Join-Path $Workspace ".claude"
        $currentEvent = ConvertTo-AiSopHookEvent `
            -RawPayload ($currentPayload | ConvertTo-Json -Compress -Depth 100) `
            -EventHint "PRE_TOOL_USE" `
            -TrustedWorkspaceRoot $Workspace `
            -AcceptedAt $AcceptedAt
        $script:ForeignCorruptCallbackCount = 0
        Assert-ThrowsCode -Code "REGISTRY_CORRUPT" `
            -Message "Dedup scavenger ignored a schema-invalid record." `
            -Action {
                Invoke-AiSopHookDedup `
                    -HookEvent $currentEvent `
                    -Decision "ALLOW" `
                    -ReasonCode "SAFE_NON_EDIT" `
                    -AcceptedAt $AcceptedAt.AddSeconds(10) `
                    -SideEffect { $script:ForeignCorruptCallbackCount++ }
            }
        Assert-Equal `
            $script:ForeignCorruptCallbackCount 0 `
            "Foreign corrupt record allowed current callback execution."
        Assert-Equal `
            ([System.IO.File]::ReadAllText($foreignSeed.RegistryPath)) `
            $foreignRecordJson `
            "Dedup scavenger deleted or replaced a corrupt record."
    } finally {
        $env:SERVER_NEW_HOOK_DEDUP_REGISTRY = $dedupRegistryBeforeCorruptCases
    }

    $writeFailurePayload = Get-FixtureRaw `
        -Name "copilot-github-pre-tool-read.json" `
        -Workspace $Workspace -Transcript $Transcript |
        ConvertFrom-Json -AsHashtable -Depth 100
    $writeFailurePayload.sessionId = "copilot-write-failure-session"
    $writeFailureEvent = ConvertTo-AiSopHookEvent `
        -RawPayload ($writeFailurePayload | ConvertTo-Json -Compress -Depth 100) `
        -EventHint "PRE_TOOL_USE" `
        -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    $writeFailureSession = Get-AiSopHookSessionKey -HookEvent $writeFailureEvent
    $writeFailureDirectory = Join-Path `
        $env:SERVER_NEW_HOOK_DEDUP_REGISTRY $writeFailureSession
    [System.IO.Directory]::CreateDirectory($writeFailureDirectory) | Out-Null
    $writeFailureRecordPath = Join-Path `
        $writeFailureDirectory "$($writeFailureEvent.dedupKey).json"
    [System.IO.Directory]::CreateDirectory($writeFailureRecordPath) | Out-Null
    $script:WriteFailureCallbackCount = 0
    Assert-ThrowsCode -Code "REGISTRY_IO_ERROR" `
        -Message "PREPARED write failure was not stable/fail-closed." `
        -Action {
            Invoke-AiSopHookDedup `
                -HookEvent $writeFailureEvent `
                -Decision "ALLOW" `
                -ReasonCode "SAFE_NON_EDIT" `
                -AcceptedAt $AcceptedAt `
                -SideEffect { $script:WriteFailureCallbackCount++ }
        }
    Assert-Equal `
        $script:WriteFailureCallbackCount 0 `
        "Callback ran before PREPARED was durable."

    $scavengeDirectory = Join-Path $TestRoot "scavenge"
    [System.IO.Directory]::CreateDirectory($scavengeDirectory) | Out-Null
    $scavengeRecords = @(
        [pscustomobject]@{ Name = "expired"; Key = ("a" * 64) },
        [pscustomobject]@{ Name = "held"; Key = ("b" * 64) }
    )
    foreach ($scavengeRecord in $scavengeRecords) {
        [System.IO.File]::WriteAllText(
            (Join-Path $scavengeDirectory "$($scavengeRecord.Key).json"),
            (@{
                correlationKey = $scavengeRecord.Key
                normalizedTimestampEpochMs = $AcceptedAt.ToUnixTimeMilliseconds()
                expiresAt = $AcceptedAt.AddMinutes(-1).ToString("o")
            } | ConvertTo-Json -Compress)
        )
        [System.IO.File]::WriteAllText(
            (Join-Path $scavengeDirectory "$($scavengeRecord.Key).lock"),
            ""
        )
    }
    $expiredScavengeRecord = $scavengeRecords[0]
    $heldScavengeRecord = $scavengeRecords[1]
    $heldScavengeLock = [System.IO.File]::Open(
        (Join-Path $scavengeDirectory "$($heldScavengeRecord.Key).lock"),
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    try {
        Invoke-AiSopHookRegistryScavenge `
            -Directory $scavengeDirectory `
            -NowUtc $AcceptedAt
        Assert-True `
            -Condition (
                -not (
                    Test-Path (
                        Join-Path `
                            $scavengeDirectory `
                            "$($expiredScavengeRecord.Key).json"
                    )
                )
            ) `
            -Message "Expired registry record was not scavenged."
        Assert-True `
            -Condition (
                Test-Path (
                    Join-Path `
                        $scavengeDirectory `
                        "$($heldScavengeRecord.Key).json"
                )
            ) `
            -Message "Scavenger deleted a held/active registry record."
    } finally {
        $heldScavengeLock.Dispose()
    }
    Invoke-AiSopHookRegistryScavenge `
        -Directory $scavengeDirectory `
        -NowUtc $AcceptedAt
    Assert-True `
        -Condition (
            -not (
                Test-Path (
                    Join-Path `
                        $scavengeDirectory `
                        "$($heldScavengeRecord.Key).json"
                )
            )
        ) `
        -Message "Released expired registry record was not scavenged."

    $deadlinePayload = Get-FixtureRaw `
        -Name "claude-session-start.json" `
        -Workspace $Workspace -Transcript $Transcript |
        ConvertFrom-Json -AsHashtable -Depth 100
    $deadlinePayload.session_id = "claude-shared-deadline"
    $deadlineRaw = $deadlinePayload | ConvertTo-Json -Compress -Depth 100
    $deadlineSeedEvent = ConvertTo-AiSopHookEvent `
        -RawPayload $deadlineRaw `
        -EventHint "SESSION_START" `
        -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    $correlationBasis = [string]::Join(
        [char]0,
        @(
            "lifecycle",
            $deadlineSeedEvent.agent,
            $deadlineSeedEvent.nativeSessionId,
            $deadlineSeedEvent.event,
            $deadlineSeedEvent.workspacePath,
            $deadlineSeedEvent.canonicalSemanticArgsSha256,
            $deadlineSeedEvent.canonicalTargetsSha256
        )
    )
    $correlationKey = Get-AiSopSha256Hex $correlationBasis
    $correlationDirectory = Join-Path `
        $env:SERVER_NEW_HOOK_DEDUP_REGISTRY "correlations"
    $correlationRecordPath = Join-Path $correlationDirectory "$correlationKey.json"
    $correlationLockPath = Join-Path $correlationDirectory "$correlationKey.lock"
    [System.IO.File]::Delete($correlationRecordPath)
    $deadlineSession = Get-AiSopHookSessionKey -HookEvent $deadlineSeedEvent
    $deadlineDedupDirectory = Join-Path `
        $env:SERVER_NEW_HOOK_DEDUP_REGISTRY $deadlineSession
    [System.IO.Directory]::CreateDirectory($deadlineDedupDirectory) | Out-Null
    $deadlineDedupLockPath = Join-Path `
        $deadlineDedupDirectory "$($deadlineSeedEvent.dedupKey).lock"
    $correlationReady = Join-Path $TestRoot "correlation-lock-ready"
    $dedupReady = Join-Path $TestRoot "dedup-lock-ready"
    $lockJobs = @(
        (Start-Job -ScriptBlock {
            param($Path, $Ready)
            $stream = [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
            try {
                [System.IO.File]::WriteAllText($Ready, "ready")
                Start-Sleep -Milliseconds 200
            } finally {
                $stream.Dispose()
            }
        } -ArgumentList $correlationLockPath, $correlationReady),
        (Start-Job -ScriptBlock {
            param($Path, $Ready)
            $stream = [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
            try {
                [System.IO.File]::WriteAllText($Ready, "ready")
                Start-Sleep -Milliseconds 1000
            } finally {
                $stream.Dispose()
            }
        } -ArgumentList $deadlineDedupLockPath, $dedupReady)
    )
    try {
        $readyDeadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
        while (
            (
                -not (Test-Path $correlationReady) -or
                -not (Test-Path $dedupReady)
            ) -and
            [DateTimeOffset]::UtcNow -lt $readyDeadline
        ) {
            Start-Sleep -Milliseconds 10
        }
        Assert-True `
            -Condition (
                (Test-Path $correlationReady) -and
                (Test-Path $dedupReady)
            ) `
            -Message "Shared deadline lock fixtures did not become ready."
        $sharedDeadline = [DateTimeOffset]::UtcNow.AddMilliseconds(400)
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Assert-ThrowsCode -Code "REGISTRY_LOCK_TIMEOUT" `
            -Message "Chained locks reset the shared deadline." `
            -Action {
                $deadlineEvent = ConvertTo-AiSopHookEvent `
                    -RawPayload $deadlineRaw `
                    -EventHint "SESSION_START" `
                    -TrustedWorkspaceRoot $Workspace `
                    -AcceptedAt $AcceptedAt `
                    -DeadlineUtc $sharedDeadline
                Invoke-AiSopHookDedup `
                    -HookEvent $deadlineEvent `
                    -Decision "ALLOW" `
                    -ReasonCode "SESSION_REGISTERED" `
                    -AcceptedAt $AcceptedAt `
                    -DeadlineUtc $sharedDeadline `
                    -SideEffect { }
            }
        $stopwatch.Stop()
        Assert-True `
            -Condition ($stopwatch.ElapsedMilliseconds -le 750) `
            -Message (
                "Shared lock chain exceeded 750ms: " +
                $stopwatch.ElapsedMilliseconds
            )
    } finally {
        foreach ($job in $lockJobs) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }

    # Each approved Copilot semantic group is exercised in both arrival
    # directions above and under concurrent compat/native arrival here.
    foreach ($pair in $pairs) {
        $safeName = $pair.Name -replace "[^A-Za-z0-9]", "_"
        $concurrentRegistry = Join-Path $TestRoot "concurrent-$safeName"
        $concurrentSideEffectPath = Join-Path $TestRoot "effects-$safeName.txt"
        $concurrentRawPayloads = @(
            (Get-FixtureRaw `
                -Name $pair.Compat `
                -Workspace $Workspace `
                -Transcript $Transcript),
            (Get-FixtureRaw `
                -Name $pair.Native `
                -Workspace $Workspace `
                -Transcript $Transcript)
        )
        $jobs = @()
        try {
            foreach ($rawPayload in $concurrentRawPayloads) {
                $jobs += Start-Job -ScriptBlock {
                param(
                    [string]$NormalizerPath,
                    [string]$DedupPath,
                    [string]$Raw,
                    [string]$EventHint,
                    [string]$TrustedWorkspace,
                    [string]$Registry,
                    [string]$SideEffectPath,
                    [string]$Clock,
                    [string]$Authorization,
                    [string]$Decision,
                    [string]$Reason,
                    [string]$GrantId,
                    [string]$Intent
                )

                $ErrorActionPreference = "Stop"
                $env:SERVER_NEW_HOOK_DEDUP_REGISTRY = $Registry
                . $NormalizerPath
                . $DedupPath
                $acceptedAt = [DateTimeOffset]::Parse($Clock)
                $event = ConvertTo-AiSopHookEvent `
                    -RawPayload $Raw `
                    -EventHint $EventHint `
                    -TrustedWorkspaceRoot $TrustedWorkspace `
                    -AcceptedAt $acceptedAt
                $result = Invoke-AiSopHookDedup `
                    -HookEvent $event `
                    -Decision $Decision `
                    -ReasonCode $Reason `
                    -AuthorizationSnapshotSha256 $Authorization `
                    -BootstrapGrantId $GrantId `
                    -IntentSha256 $Intent `
                    -AcceptedAt $acceptedAt `
                    -SideEffect {
                        param($record)
                        [System.IO.File]::AppendAllText(
                            $SideEffectPath,
                            "effect`n",
                            [System.Text.UTF8Encoding]::new($false)
                        )
                    }
                return $result | ConvertTo-Json -Compress -Depth 20
            } -ArgumentList @(
                $NormalizerScript,
                $DedupScript,
                $rawPayload,
                $pair.EventHint,
                $Workspace,
                $concurrentRegistry,
                $concurrentSideEffectPath,
                $AcceptedAt.ToString("o"),
                $AuthorizationHash,
                $pair.Decision,
                $pair.Reason,
                $pair.GrantId,
                $pair.IntentSha256
            )
            }
            $completedJobs = @($jobs | Wait-Job -Timeout 20)
            Assert-Equal `
                $completedJobs.Count 2 `
                "$($pair.Name) concurrent jobs did not finish."
            foreach ($job in $jobs) {
                Assert-Equal `
                    $job.State "Completed" `
                    "$($pair.Name) concurrent job failed."
            }
            $concurrentResults = @(
                foreach ($job in $jobs) {
                    Receive-Job -Job $job -ErrorAction Stop |
                        ConvertFrom-Json
                }
            )
            Assert-Equal `
                @($concurrentResults | Where-Object { -not $_.IsDuplicate }).Count `
                1 `
                "$($pair.Name) concurrent pair produced multiple first events."
            Assert-Equal `
                @($concurrentResults | Where-Object { $_.IsDuplicate }).Count `
                1 `
                "$($pair.Name) concurrent pair did not replay one duplicate."
            Assert-Equal `
                @([System.IO.File]::ReadAllLines($concurrentSideEffectPath)).Count `
                1 `
                "$($pair.Name) concurrent pair applied multiple side effects."
        } finally {
            foreach ($job in $jobs) {
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Output "All hook dedup tests passed."
} finally {
    if ($null -eq $PreviousDedupRegistry) {
        Remove-Item Env:SERVER_NEW_HOOK_DEDUP_REGISTRY -ErrorAction SilentlyContinue
    } else {
        $env:SERVER_NEW_HOOK_DEDUP_REGISTRY = $PreviousDedupRegistry
    }
    if (Test-Path -LiteralPath $TestRoot) {
        [System.IO.Directory]::Delete($TestRoot, $true)
    }
    $script:DedupSideEffectCount = 0
}
