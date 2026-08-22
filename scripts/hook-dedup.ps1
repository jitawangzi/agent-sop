#requires -Version 7.0

# Persists only normalized semantic identity and the first authorization
# outcome. Native payloads, tool arguments, commands, transcripts, and secrets
# are intentionally absent from the record schema.

$script:HookDedupSchemaPath = Join-Path (
    Split-Path -Parent $PSScriptRoot
) "schemas\hook-dedup.schema.json"
$script:HookEventNormalizerPath = Join-Path $PSScriptRoot "hook-event-normalizer.ps1"

if (-not (Get-Command Get-AiSopHookSessionKey -ErrorAction SilentlyContinue)) {
    . $script:HookEventNormalizerPath
}

function Get-AiSopHookDedupRegistryRoot {
    [CmdletBinding()]
    param()

    try {
        if (-not [string]::IsNullOrWhiteSpace($env:SERVER_NEW_HOOK_DEDUP_REGISTRY)) {
            return [System.IO.Path]::GetFullPath(
                $env:SERVER_NEW_HOOK_DEDUP_REGISTRY
            )
        }
        return Join-Path $env:LOCALAPPDATA "AIWorkflowHookDedup\server_new"
    } catch {
        Throw-AiSopHookError "REGISTRY_IO_ERROR"
    }
}

function Test-AiSopOptionalSha256 {
    param([AllowEmptyString()][string]$Value)

    return [string]::IsNullOrEmpty($Value) -or $Value -match "^[0-9a-f]{64}$"
}

function Assert-AiSopHookDedupDeadline {
    param([Nullable[DateTimeOffset]]$DeadlineUtc)

    if (
        $null -ne $DeadlineUtc -and
        [DateTimeOffset]::UtcNow -ge ([DateTimeOffset]$DeadlineUtc)
    ) {
        Throw-AiSopHookError "REGISTRY_DEADLINE_EXCEEDED"
    }
}

function Get-AiSopHookDedupRemainingMilliseconds {
    param([Nullable[DateTimeOffset]]$DeadlineUtc)

    if ($null -eq $DeadlineUtc) {
        return [int64]::MaxValue
    }
    $remaining = (
        ([DateTimeOffset]$DeadlineUtc) - [DateTimeOffset]::UtcNow
    ).TotalMilliseconds
    return [int64][Math]::Max(0, [Math]::Floor($remaining))
}

function Enter-AiSopHookDedupLock {
    param(
        [string]$LockPath,
        [Nullable[DateTimeOffset]]$DeadlineUtc,
        [int]$TimeoutMilliseconds = 500
    )

    $deadline = if ($null -ne $DeadlineUtc) {
        ([DateTimeOffset]$DeadlineUtc).ToUniversalTime()
    } else {
        [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    }
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        try {
            return [System.IO.File]::Open(
                $LockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 10
        } catch {
            Throw-AiSopHookError "REGISTRY_IO_ERROR"
        }
    }
    Throw-AiSopHookError "REGISTRY_LOCK_TIMEOUT"
}

function ConvertFrom-AiSopHookDedupRecord {
    param(
        [string]$RecordPath,
        [object]$HookEvent,
        [string]$SessionKey
    )

    try {
        $rawRecord = [System.IO.File]::ReadAllText($RecordPath)
        if (-not ($rawRecord | Test-Json -SchemaFile $script:HookDedupSchemaPath)) {
            Throw-AiSopHookError "REGISTRY_CORRUPT"
        }
        $record = $rawRecord | ConvertFrom-Json -AsHashtable -Depth 20
    } catch {
        if ($_.Exception.Message -eq "REGISTRY_CORRUPT") {
            throw
        }
        Throw-AiSopHookError "REGISTRY_CORRUPT"
    }
    foreach ($comparison in @(
        @([string]$record.dedupKey, [string]$HookEvent.dedupKey),
        @([string]$record.agent, [string]$HookEvent.agent),
        @([string]$record.event, [string]$HookEvent.event),
        @([string]$record.sessionKey, $SessionKey),
        @([string]$record.normalizedTimestampEpochMs, [string]$HookEvent.normalizedTimestampEpochMs),
        @([string]$record.toolClass, [string]$HookEvent.toolClass),
        @([string]$record.canonicalSemanticArgsSha256, [string]$HookEvent.canonicalSemanticArgsSha256),
        @([string]$record.canonicalTargetsSha256, [string]$HookEvent.canonicalTargetsSha256)
    )) {
        if ($comparison[0] -cne $comparison[1]) {
            Throw-AiSopHookError "REGISTRY_CORRUPT"
        }
    }
    return $record
}

function Write-AiSopHookDedupRecord {
    param(
        [string]$RecordPath,
        [System.Collections.IDictionary]$Record
    )

    $temporaryPath = ""
    try {
        $json = $Record | ConvertTo-Json -Compress -Depth 20
        if (-not ($json | Test-Json -SchemaFile $script:HookDedupSchemaPath)) {
            Throw-AiSopHookError "REGISTRY_CORRUPT"
        }
        $temporaryPath = "$RecordPath.$([guid]::NewGuid().ToString('N')).tmp"
        [System.IO.File]::WriteAllText(
            $temporaryPath,
            $json,
            [System.Text.UTF8Encoding]::new($false)
        )
        [System.IO.File]::Move($temporaryPath, $RecordPath, $true)
    } catch {
        if ($_.Exception.Message -eq "REGISTRY_CORRUPT") {
            throw
        }
        Throw-AiSopHookError "REGISTRY_IO_ERROR"
    } finally {
        if (-not [string]::IsNullOrEmpty($temporaryPath)) {
            try {
                if ([System.IO.File]::Exists($temporaryPath)) {
                    [System.IO.File]::Delete($temporaryPath)
                }
            } catch {
                # Primary write result is authoritative; temp cleanup is lazy.
            }
        }
    }
}

function New-AiSopHookDedupResult {
    param(
        [bool]$IsDuplicate,
        [bool]$SideEffectAppliedNow,
        [object]$Record,
        [string]$RegistryPath
    )

    return [pscustomobject][ordered]@{
        IsDuplicate = $IsDuplicate
        SideEffectAppliedNow = $SideEffectAppliedNow
        Record = $Record
        RegistryPath = $RegistryPath
    }
}

function Invoke-AiSopHookDedup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$HookEvent,

        [Parameter(Mandatory)]
        [ValidateSet("ALLOW", "DENY")]
        [string]$Decision,

        [Parameter(Mandatory)]
        [ValidatePattern("^[A-Z][A-Z0-9_]*$")]
        [string]$ReasonCode,

        [AllowEmptyString()]
        [string]$AuthorizationSnapshotSha256 = "",

        [AllowEmptyString()]
        [ValidatePattern("^(?:[A-Za-z0-9._:-]+)?$")]
        [string]$BootstrapGrantId = "",

        [AllowEmptyString()]
        [string]$IntentSha256 = "",

        [AllowEmptyString()]
        [ValidatePattern("^(?:[A-Za-z0-9._:-]+)?$")]
        [string]$SideEffectId = "",

        [Parameter(Mandatory)]
        [DateTimeOffset]$AcceptedAt,

        [Nullable[DateTimeOffset]]$DeadlineUtc,

        [scriptblock]$ReconcilePrepared,

        [scriptblock]$SideEffect
    )

    if (
        -not (Test-AiSopOptionalSha256 $AuthorizationSnapshotSha256) -or
        -not (Test-AiSopOptionalSha256 $IntentSha256)
    ) {
        Throw-AiSopHookError "PAYLOAD_SHAPE_INVALID"
    }
    if (
        [string]::IsNullOrWhiteSpace([string]$HookEvent.dedupKey) -or
        [string]::IsNullOrWhiteSpace([string]$HookEvent.agent) -or
        [string]::IsNullOrWhiteSpace([string]$HookEvent.nativeSessionId) -or
        [string]::IsNullOrWhiteSpace([string]$HookEvent.workspacePath)
    ) {
        Throw-AiSopHookError "PAYLOAD_SHAPE_INVALID"
    }

    if ([string]::IsNullOrEmpty($SideEffectId)) {
        $SideEffectId = "dedup:$($HookEvent.dedupKey)"
    }
    try {
        $sessionKey = Get-AiSopHookSessionKey -HookEvent $HookEvent
        $sessionDirectory = Join-Path (
            Get-AiSopHookDedupRegistryRoot
        ) $sessionKey
        [System.IO.Directory]::CreateDirectory($sessionDirectory) | Out-Null
        $recordPath = Join-Path $sessionDirectory "$($HookEvent.dedupKey).json"
        $lockPath = Join-Path $sessionDirectory "$($HookEvent.dedupKey).lock"
    } catch {
        if ($_.Exception.Message -in @(
            "REGISTRY_IO_ERROR",
            "REGISTRY_CORRUPT",
            "REGISTRY_DEADLINE_EXCEEDED"
        )) {
            throw
        }
        Throw-AiSopHookError "REGISTRY_IO_ERROR"
    }
    $lock = Enter-AiSopHookDedupLock `
        -LockPath $lockPath `
        -DeadlineUtc $DeadlineUtc
    try {
        $stored = $null
        if ([System.IO.File]::Exists($recordPath)) {
            $stored = ConvertFrom-AiSopHookDedupRecord `
                -RecordPath $recordPath `
                -HookEvent $HookEvent `
                -SessionKey $sessionKey
            try {
                $expiresAt = [DateTimeOffset]::Parse(
                    [string]$stored.expiresAt,
                    [System.Globalization.CultureInfo]::InvariantCulture
                )
            } catch {
                Throw-AiSopHookError "REGISTRY_CORRUPT"
            }
            if ($AcceptedAt -ge $expiresAt) {
                try {
                    [System.IO.File]::Delete($recordPath)
                    $stored = $null
                } catch {
                    Throw-AiSopHookError "REGISTRY_IO_ERROR"
                }
            }
        }
        Invoke-AiSopHookRegistryScavenge `
            -Directory $sessionDirectory `
            -NowUtc $AcceptedAt `
            -DeadlineUtc $DeadlineUtc `
            -RecordKind "DEDUP"
        if ($null -ne $stored) {
            if ([string]$stored.state -eq "PREPARED") {
                $reconcileState = "INDETERMINATE"
                if ($null -ne $ReconcilePrepared) {
                    Assert-AiSopHookDedupDeadline $DeadlineUtc
                    $remainingMilliseconds = Get-AiSopHookDedupRemainingMilliseconds `
                        $DeadlineUtc
                    try {
                        $reconcileState = [string](
                            & $ReconcilePrepared `
                                ([pscustomobject]$stored) `
                                $DeadlineUtc `
                                $remainingMilliseconds
                        )
                    } catch {
                        $reconcileState = "INDETERMINATE"
                    }
                    Assert-AiSopHookDedupDeadline $DeadlineUtc
                }
                if ($reconcileState -notin @(
                    "NOT_APPLIED",
                    "APPLIED",
                    "INDETERMINATE"
                )) {
                    $reconcileState = "INDETERMINATE"
                }
                if ($reconcileState -eq "APPLIED") {
                    Assert-AiSopHookDedupDeadline $DeadlineUtc
                    $stored.state = "APPLIED"
                    $stored.sideEffectsApplied = $true
                    Write-AiSopHookDedupRecord `
                        -RecordPath $recordPath `
                        -Record $stored
                    return New-AiSopHookDedupResult `
                        -IsDuplicate $true `
                        -SideEffectAppliedNow $false `
                        -Record ([pscustomobject]$stored) `
                        -RegistryPath $recordPath
                }
                if (
                    $reconcileState -eq "NOT_APPLIED" -and
                    $null -ne $SideEffect
                ) {
                    Assert-AiSopHookDedupDeadline $DeadlineUtc
                    $remainingMilliseconds = Get-AiSopHookDedupRemainingMilliseconds `
                        $DeadlineUtc
                    try {
                        & $SideEffect `
                            ([pscustomobject]$stored) `
                            $DeadlineUtc `
                            $remainingMilliseconds |
                            Out-Null
                    } catch {
                        if (
                            $_.Exception.Message -eq
                                "REGISTRY_DEADLINE_EXCEEDED"
                        ) {
                            throw
                        }
                        Throw-AiSopHookError "SIDE_EFFECT_FAILED"
                    }
                    Assert-AiSopHookDedupDeadline $DeadlineUtc
                    $stored.state = "APPLIED"
                    $stored.sideEffectsApplied = $true
                    Write-AiSopHookDedupRecord `
                        -RecordPath $recordPath `
                        -Record $stored
                    return New-AiSopHookDedupResult `
                        -IsDuplicate $true `
                        -SideEffectAppliedNow $true `
                        -Record ([pscustomobject]$stored) `
                        -RegistryPath $recordPath
                }
                $failClosedRecord = $stored |
                    ConvertTo-Json -Depth 20 |
                    ConvertFrom-Json
                $failClosedRecord.decision = "DENY"
                $failClosedRecord.reasonCode = "DEDUP_RECOVERY_REQUIRED"
                return New-AiSopHookDedupResult `
                    -IsDuplicate $true `
                    -SideEffectAppliedNow $false `
                    -Record $failClosedRecord `
                    -RegistryPath $recordPath
            }
            return New-AiSopHookDedupResult `
                -IsDuplicate $true `
                -SideEffectAppliedNow $false `
                -Record $stored `
                -RegistryPath $recordPath
        }

        $willApplySideEffect = $null -ne $SideEffect
        $record = [ordered]@{
            schemaVersion = "1.0"
            dedupKey = [string]$HookEvent.dedupKey
            agent = [string]$HookEvent.agent
            event = [string]$HookEvent.event
            sessionKey = $sessionKey
            normalizedTimestampEpochMs = [int64]$HookEvent.normalizedTimestampEpochMs
            toolClass = [string]$HookEvent.toolClass
            canonicalSemanticArgsSha256 = [string]$HookEvent.canonicalSemanticArgsSha256
            canonicalTargetsSha256 = [string]$HookEvent.canonicalTargetsSha256
            decision = $Decision
            reasonCode = $ReasonCode
            authorizationSnapshotSha256 = $AuthorizationSnapshotSha256
            sideEffectId = $SideEffectId
            state = if ($willApplySideEffect) { "PREPARED" } else { "APPLIED" }
            sideEffectsApplied = $false
            bootstrapGrantId = $BootstrapGrantId
            intentSha256 = $IntentSha256
            createdAt = $AcceptedAt.ToUniversalTime().ToString("o")
            expiresAt = $AcceptedAt.AddHours(24).ToUniversalTime().ToString("o")
        }

        $recordJson = $record | ConvertTo-Json -Compress -Depth 20
        if (-not ($recordJson | Test-Json -SchemaFile $script:HookDedupSchemaPath)) {
            Throw-AiSopHookError "PAYLOAD_SHAPE_INVALID"
        }
        Write-AiSopHookDedupRecord -RecordPath $recordPath -Record $record
        if ($willApplySideEffect) {
            Assert-AiSopHookDedupDeadline $DeadlineUtc
            $remainingMilliseconds = Get-AiSopHookDedupRemainingMilliseconds `
                $DeadlineUtc
            try {
                & $SideEffect `
                    ([pscustomobject]$record) `
                    $DeadlineUtc `
                    $remainingMilliseconds |
                    Out-Null
            } catch {
                if (
                    $_.Exception.Message -eq
                        "REGISTRY_DEADLINE_EXCEEDED"
                ) {
                    throw
                }
                Throw-AiSopHookError "SIDE_EFFECT_FAILED"
            }
            Assert-AiSopHookDedupDeadline $DeadlineUtc
            $record.state = "APPLIED"
            $record.sideEffectsApplied = $true
            Write-AiSopHookDedupRecord -RecordPath $recordPath -Record $record
        }
        return New-AiSopHookDedupResult `
            -IsDuplicate $false `
            -SideEffectAppliedNow $willApplySideEffect `
            -Record ([pscustomobject]$record) `
            -RegistryPath $recordPath
    } finally {
        $lock.Dispose()
    }
}
