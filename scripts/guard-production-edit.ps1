#requires -Version 7.0

# Shared Guard policy library. Native payload parsing, transaction recovery,
# deduplication, lifecycle processing and envelope rendering are owned by
# hook-dispatcher.ps1. This file performs only target classification and the
# exact session-bound Owner 1.1 authorization decision.

$script:GuardClaudeRoot = Split-Path -Parent $PSScriptRoot
$script:GuardPathIdentityScript = Join-Path $PSScriptRoot "path-identity.ps1"
$script:GuardTransactionScript = Join-Path (
    $PSScriptRoot
) "workflow-transaction.ps1"
$script:GuardSessionScript = Join-Path $PSScriptRoot "workflow-session.ps1"
$script:GuardOwnerSchema = Join-Path (
    $script:GuardClaudeRoot
) "schemas\workflow-owner.schema.json"

if (-not (Get-Command Resolve-PhysicalPathIdentity -ErrorAction SilentlyContinue)) {
    . $script:GuardPathIdentityScript
}
if (-not (Get-Command Get-AiSopWorkflowSha256 -ErrorAction SilentlyContinue)) {
    . $script:GuardTransactionScript
}
if (-not (Get-Command Get-AiSopWorkflowSessionKey -ErrorAction SilentlyContinue)) {
    . $script:GuardSessionScript
}

function Test-AiSopGuardEscapeEnabled {
    [CmdletBinding()]
    param()

    # Guard manual switch. Three ways to disable the production-edit guard:
    #   1. env AI_SOP_SKIP_OWNER_GUARD=1 (or legacy SERVER_NEW_SKIP_OWNER_GUARD=1)
    #      (per-process; hook subprocesses inherit it only if set at user level before AI tool starts).
    #   2. switch file at the SOP root (reliable across hook subprocesses):
    #      create  .ai-sop/.guard-disabled   to disable guard
    #      remove  .ai-sop/.guard-disabled   to re-enable guard
    #   3. one-time token (preferred for scoped bypass): a JSON file at
    #      .ai-sop/.guard-token.json with {feature, reason, operator, expiresAt}.
    #      Guard honors it only if feature matches the active owner AND not
    #      expired. Auto-expires; won't leak to other features/tasks.
    # Env is authoritative: when set to "1" escape; when set to any other
    # explicit value (e.g. "0") do NOT escape (even if the switch file exists).
    # Only when env is unset/empty does the switch file / token get consulted.
    $envSkip = if (-not [string]::IsNullOrEmpty($env:AI_SOP_SKIP_OWNER_GUARD)) {
        $env:AI_SOP_SKIP_OWNER_GUARD
    } else {
        $env:SERVER_NEW_SKIP_OWNER_GUARD
    }
    if ($envSkip -eq "1") { return $true }
    if (-not [string]::IsNullOrEmpty($envSkip) -and $envSkip -ne "1") { return $false }

    $guardRoot = if (-not [string]::IsNullOrWhiteSpace($script:DispatcherClaudeRoot)) {
        $script:DispatcherClaudeRoot
    } else {
        Split-Path -Parent $PSScriptRoot
    }
    $switchPath = Join-Path $guardRoot ".guard-disabled"
    if (Test-Path -LiteralPath $switchPath) { return $true }
    # One-time token: honored only if not expired (feature check is done
    # by caller via the decision's owner context; here we only check expiry).
    $tokenPath = Join-Path $guardRoot ".guard-token.json"
    if (Test-Path -LiteralPath $tokenPath -PathType Leaf) {
        try {
            $token = Get-Content -LiteralPath $tokenPath -Raw | ConvertFrom-Json
            $expires = [DateTimeOffset]::Parse([string]$token.expiresAt)
            if ([DateTimeOffset]::UtcNow -lt $expires) {
                return $true
            }
            # Expired token: auto-delete to prevent stale bypass.
            Remove-Item -LiteralPath $tokenPath -Force -ErrorAction SilentlyContinue
        } catch {
            # Corrupt token: ignore (fail-safe = guard stays on).
        }
    }
    return $false
}

function New-AiSopGuardDecision {
    param(
        [ValidateSet("ALLOW", "DENY")]
        [string]$Decision,
        [string]$ReasonCode,
        [bool]$RequiresExactOwner = $false,
        [bool]$IsProduction = $false,
        [string]$AuthorizationSnapshotSha256 = ""
    )

    return [pscustomobject][ordered]@{
        Decision = $Decision
        ReasonCode = $ReasonCode
        RequiresExactOwner = $RequiresExactOwner
        IsProduction = $IsProduction
        AuthorizationSnapshotSha256 = $AuthorizationSnapshotSha256
    }
}

function Test-AiSopGuardPathWithinRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    $normalizedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $normalizedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    return (
        $normalizedPath.Equals(
            $normalizedRoot,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        $normalizedPath.StartsWith(
            $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    )
}

function Test-AiSopGuardProductionPath {
    param(
        [string]$Path,
        [string]$WorkspaceRoot
    )

    if (-not (Test-AiSopGuardPathWithinRoot -Path $Path -Root $WorkspaceRoot)) {
        throw "EDIT_PATH_OUTSIDE_WORKSPACE"
    }
    $relative = [System.IO.Path]::GetRelativePath(
        [System.IO.Path]::GetFullPath($WorkspaceRoot),
        [System.IO.Path]::GetFullPath($Path)
    )
    $normalized = ($relative -replace "/", "\").TrimStart(".", "\")
    return (
        $normalized -match "^(?i:src\\com)(?:\\|$)" -or
        $normalized -match "^(?i:WebRoot)(?:\\|$)" -or
        $normalized -match "^(?i:config)(?:\\|$)"
    )
}

function Get-AiSopGuardTargetDecision {
    param([object]$HookEvent)

    $toolClass = [string]$HookEvent.toolClass
    if ($toolClass -eq "SAFE_NON_EDIT") {
        return New-AiSopGuardDecision `
            -Decision ALLOW `
            -ReasonCode SAFE_NON_EDIT
    }
    if ($toolClass -eq "UNKNOWN") {
        return New-AiSopGuardDecision `
            -Decision DENY `
            -ReasonCode TOOL_UNKNOWN
    }
    if ($toolClass -eq "OWNER_REQUIRED") {
        return New-AiSopGuardDecision `
            -Decision DENY `
            -ReasonCode OWNER_REQUIRED `
            -RequiresExactOwner $true
    }
    if ($toolClass -ne "FILE_EDIT") {
        return New-AiSopGuardDecision `
            -Decision DENY `
            -ReasonCode TOOL_UNKNOWN
    }

    $targets = @($HookEvent.targetPaths)
    if (
        $targets.Count -eq 0 -or
        @($targets | Where-Object {
            $_ -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$_)
        }).Count -gt 0
    ) {
        return New-AiSopGuardDecision `
            -Decision DENY `
            -ReasonCode EDIT_PATH_MISSING
    }

    try {
        $workspace = Resolve-PhysicalPathIdentity `
            -Path ([string]$HookEvent.workspacePath)
        $hasProductionTarget = $false
        foreach ($target in $targets) {
            $lexical = [System.IO.Path]::GetFullPath([string]$target)
            if (
                Test-AiSopGuardProductionPath `
                    -Path $lexical `
                    -WorkspaceRoot $workspace
            ) {
                $hasProductionTarget = $true
            }
            $physical = Resolve-PhysicalPathIdentity -Path $lexical
            if (-not (
                Test-AiSopGuardPathWithinRoot `
                    -Path $physical `
                    -Root $workspace
            )) {
                throw "EDIT_PATH_OUTSIDE_WORKSPACE"
            }
            if (
                Test-AiSopGuardProductionPath `
                    -Path $physical `
                    -WorkspaceRoot $workspace
            ) {
                $hasProductionTarget = $true
            }
        }
    } catch {
        $code = if (
            $_.Exception.Message -eq "EDIT_PATH_OUTSIDE_WORKSPACE"
        ) {
            "EDIT_PATH_OUTSIDE_WORKSPACE"
        } else {
            "EDIT_PATH_INVALID"
        }
        return New-AiSopGuardDecision `
            -Decision DENY `
            -ReasonCode $code
    }

    if (-not $hasProductionTarget) {
        return New-AiSopGuardDecision `
            -Decision ALLOW `
            -ReasonCode NON_PRODUCTION_FILE_EDIT
    }
    return New-AiSopGuardDecision `
        -Decision DENY `
        -ReasonCode OWNER_REQUIRED `
        -RequiresExactOwner $true `
        -IsProduction $true
}

function Read-AiSopGuardOwner {
    param(
        [string]$OwnerPath,
        [string]$ExpectedFeature
    )

    if (-not [System.IO.File]::Exists($OwnerPath)) {
        throw "OWNER_NOT_FOUND"
    }
    try {
        $json = [System.IO.File]::ReadAllText($OwnerPath)
        if (-not (
            $json |
                Test-Json `
                    -SchemaFile $script:GuardOwnerSchema `
                    -ErrorAction SilentlyContinue
        )) {
            throw "OWNER_REGISTRY_CORRUPT"
        }
        $owner = ConvertFrom-AiSopWorkflowJson -Json $json -AsHashtable
    } catch {
        if ($_.Exception.Message -eq "OWNER_REGISTRY_CORRUPT") {
            throw
        }
        throw "OWNER_REGISTRY_IO_ERROR"
    }
    if ([string]$owner.feature -cne $ExpectedFeature) {
        throw "OWNER_IDENTITY_MISMATCH"
    }
    return $owner
}

function Test-AiSopGuardTransactionJournalPresent {
    $root = Get-AiSopWorkflowTransactionRegistryRoot
    if (-not [System.IO.Directory]::Exists($root)) {
        if ([System.IO.File]::Exists($root)) {
            throw "WORKFLOW_REGISTRY_IO_ERROR"
        }
        return $false
    }
    try {
        return @(
            [System.IO.Directory]::EnumerateFiles($root, "*.json")
        ).Count -gt 0
    } catch {
        throw "WORKFLOW_REGISTRY_IO_ERROR"
    }
}

function Get-AiSopGuardAuthorizationSnapshot {
    param(
        [System.Collections.IDictionary]$Session,
        [System.Collections.IDictionary]$Owner
    )

    $snapshot = [ordered]@{
        agent = [string]$Owner.agent
        ownerId = [string]$Owner.ownerId
        feature = [string]$Owner.feature
        workflow = [string]$Owner.workflow
        workspacePath = [string]$Owner.workspacePath
        specDirectory = [string]$Owner.specDirectory
        sessionKey = [string]$Owner.sessionBinding.sessionKey
        sessionEpochId = [string]$Owner.sessionBinding.sessionEpochId
        ownerLastTransactionId = [string]$Owner.lastTransactionId
        sessionLastTransactionId = [string]$Session.lastTransactionId
    }
    return Get-AiSopWorkflowSha256 (
        ConvertTo-AiSopWorkflowCanonicalJson $snapshot
    )
}

function Get-AiSopExactOwnerDecision {
    param(
        [object]$HookEvent,
        [DateTimeOffset]$AcceptedAt,
        [Nullable[DateTimeOffset]]$DeadlineUtc
    )

    $sessionLock = $null
    $ownerLock = $null
    $sessionLockPath = ""
    $ownerLockPath = ""
    try {
        Assert-AiSopWorkflowDeadline $DeadlineUtc
        $workspace = Resolve-PhysicalPathIdentity `
            -Path ([string]$HookEvent.workspacePath)
        $sessionKey = Get-AiSopWorkflowSessionKey `
            -Agent ([string]$HookEvent.agent) `
            -NativeSessionId ([string]$HookEvent.nativeSessionId) `
            -WorkspacePath $workspace
        $sessionPath = Get-AiSopWorkflowSessionPath -SessionKey $sessionKey
        $sessionLockPath = "$sessionPath.lock"
        $sessionLock = Enter-AiSopWorkflowFileLock `
            -LockPath $sessionLockPath `
            -DeadlineUtc $DeadlineUtc
        $session = Read-AiSopWorkflowSessionRecord `
            -SessionPath $sessionPath `
            -ExpectedSessionKey $sessionKey
        Assert-AiSopWorkflowSessionIdentity `
            -Record $session `
            -SessionKey $sessionKey `
            -Agent ([string]$HookEvent.agent) `
            -NativeSessionIdSha256 (
                Get-AiSopWorkflowSha256 ([string]$HookEvent.nativeSessionId)
            ) `
            -WorkspacePath $workspace
        $effective = Get-AiSopWorkflowSessionEffectiveStatus `
            -Record $session `
            -AcceptedAt $AcceptedAt
        if (
            $effective -cne "ACTIVE" -or
            [string]$session.status -cne "ACTIVE" -or
            [string]$session.lifecycleProof -cne "CONFIRMED" -or
            -not [string]::IsNullOrEmpty([string]$session.endedAt)
        ) {
            throw "SESSION_INACTIVE"
        }
        if (
            [string]::IsNullOrEmpty([string]$session.boundFeature) -or
            [string]::IsNullOrEmpty([string]$session.boundWorkflow) -or
            [string]::IsNullOrEmpty([string]$session.boundOwnerId) -or
            [string]::IsNullOrEmpty(
                [string]$session.boundSessionEpochId
            ) -or
            [string]$session.boundWorkflow -cne "SUPERPOWERS" -or
            [string]$session.boundSessionEpochId -cne
                [string]$session.sessionEpochId
        ) {
            throw "SESSION_BINDING_INVALID"
        }

        $ownerRoot = Get-AiSopWorkflowOwnerRegistryRoot
        $ownerPath = Join-Path (
            $ownerRoot
        ) (([string]$session.boundFeature).ToLowerInvariant() + ".json")
        $ownerLockPath = "$ownerPath.lock"
        $ownerLock = Enter-AiSopWorkflowFileLock `
            -LockPath $ownerLockPath `
            -DeadlineUtc $DeadlineUtc

        # A transaction that appears after the dispatcher's recovery cannot
        # overlap this exact session/owner lock pair. Its durable journal is
        # therefore evidence of an incomplete or unrelated half-state, and the
        # conservative authorization result is deny.
        if (Test-AiSopGuardTransactionJournalPresent) {
            throw "WORKFLOW_TRANSACTION_PENDING"
        }

        $owner = Read-AiSopGuardOwner `
            -OwnerPath $ownerPath `
            -ExpectedFeature ([string]$session.boundFeature)
        if (
            [string]$owner.schemaVersion -cne "1.1" -or
            [string]$owner.status -cne "ACTIVE" -or
            [string]$owner.workflow -cne "SUPERPOWERS"
        ) {
            throw "OWNER_VERSION_UNAUTHORIZED"
        }

        $expectedSpec = Resolve-PhysicalPathIdentity -Path (
            Join-Path (
                $workspace
            ) ".ai-workspace\specs\features\$($session.boundFeature)"
        )
        $ownerWorkspace = Resolve-PhysicalPathIdentity `
            -Path ([string]$owner.workspacePath)
        $ownerSpec = Resolve-PhysicalPathIdentity `
            -Path ([string]$owner.specDirectory)
        if (
            [string]$owner.agent -cne [string]$HookEvent.agent -or
            [string]$owner.ownerId -cne [string]$session.boundOwnerId -or
            -not $ownerWorkspace.Equals(
                $workspace,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -or
            -not $ownerSpec.Equals(
                $expectedSpec,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -or
            [string]$owner.sessionBinding.sessionKey -cne $sessionKey -or
            [string]$owner.sessionBinding.sessionEpochId -cne
                [string]$session.sessionEpochId -or
            [string]$session.lastTransactionId -cne
                [string]$owner.lastTransactionId
        ) {
            throw "OWNER_IDENTITY_MISMATCH"
        }

        $snapshotHash = Get-AiSopGuardAuthorizationSnapshot `
            -Session $session `
            -Owner $owner
        return New-AiSopGuardDecision `
            -Decision ALLOW `
            -ReasonCode EXACT_OWNER_AUTHORIZED `
            -RequiresExactOwner $true `
            -IsProduction (
                [string]$HookEvent.toolClass -ceq "FILE_EDIT"
            ) `
            -AuthorizationSnapshotSha256 $snapshotHash
    } catch {
        $code = [string]$_.Exception.Message
        if ($code -notmatch "^[A-Z][A-Z0-9_]*$") {
            $code = "GUARD_INTERNAL_ERROR"
        }
        return New-AiSopGuardDecision `
            -Decision DENY `
            -ReasonCode $code `
            -RequiresExactOwner $true `
            -IsProduction (
                [string]$HookEvent.toolClass -ceq "FILE_EDIT"
            )
    } finally {
        if ($null -ne $ownerLock) {
            $ownerLock.Dispose()
            try {
                [System.IO.File]::Delete($ownerLockPath)
            } catch {
                # Lock-file cleanup is not authorization state.
            }
        }
        if ($null -ne $sessionLock) {
            $sessionLock.Dispose()
            try {
                [System.IO.File]::Delete($sessionLockPath)
            } catch {
                # Lock-file cleanup is not authorization state.
            }
        }
    }
}

function Get-AiSopGuardDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$HookEvent,

        [Parameter(Mandatory)]
        [DateTimeOffset]$AcceptedAt,

        [Nullable[DateTimeOffset]]$DeadlineUtc
    )

    if ([string]$HookEvent.event -cne "PRE_TOOL_USE") {
        return New-AiSopGuardDecision `
            -Decision DENY `
            -ReasonCode EVENT_HINT_MISMATCH
    }
    $targetDecision = Get-AiSopGuardTargetDecision -HookEvent $HookEvent
    if (-not $targetDecision.RequiresExactOwner) {
        return $targetDecision
    }
    return Get-AiSopExactOwnerDecision `
        -HookEvent $HookEvent `
        -AcceptedAt $AcceptedAt `
        -DeadlineUtc $DeadlineUtc
}
