#requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$ScriptsRoot = Split-Path -Parent $PSScriptRoot
$GuardScript = Join-Path $ScriptsRoot "guard-production-edit.ps1"
$SessionScript = Join-Path $ScriptsRoot "workflow-session.ps1"
$TransactionScript = Join-Path $ScriptsRoot "workflow-transaction.ps1"
$OwnerSchema = Join-Path (
    Split-Path -Parent $ScriptsRoot
) "schemas\workflow-owner.schema.json"
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "guard-tests-" + [guid]::NewGuid().ToString("N")
)
$Workspace = Join-Path $TestRoot "workspace"
$t0 = [DateTimeOffset]::UtcNow.AddMinutes(-2)
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$CreatedJunctions = @()
$SavedEnvironment = @{}
$RegistryVariables = @(
    "SERVER_NEW_WORKFLOW_REGISTRY",
    "SERVER_NEW_WORKFLOW_SESSION_REGISTRY",
    "SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY",
    "SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY",
    "SERVER_NEW_HOOK_DEDUP_REGISTRY",
    "SERVER_NEW_HOOK_CORRELATION_REGISTRY",
    "SERVER_NEW_SKIP_OWNER_GUARD"
)

function Assert-Equal {
    param(
        [AllowNull()]
        [object]$Actual,
        [AllowNull()]
        [object]$Expected,
        [string]$Message
    )

    if ($Actual -cne $Expected) {
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

function Copy-Record {
    param([object]$Record)

    $json = $Record | ConvertTo-Json -Compress -Depth 40
    $parameters = @{
        InputObject = $json
        AsHashtable = $true
        Depth = 40
    }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey("DateKind")) {
        $parameters.DateKind = "String"
    }
    return ConvertFrom-Json @parameters
}

function New-TestHookEvent {
    param(
        [ValidateSet("CLAUDE_CODE", "COPILOT", "ANTIGRAVITY", "CURSOR")]
        [string]$Agent = "CURSOR",
        [string]$NativeSessionId = "guard-session",
        [ValidateSet(
            "SAFE_NON_EDIT",
            "FILE_EDIT",
            "OWNER_REQUIRED",
            "UNKNOWN"
        )]
        [string]$ToolClass = "FILE_EDIT",
        [string[]]$TargetPaths = @()
    )

    return [pscustomobject][ordered]@{
        agent = $Agent
        nativeShape = "CURSOR_PRE_TOOL_USE"
        event = "PRE_TOOL_USE"
        nativeSessionId = $NativeSessionId
        generationId = "guard-generation"
        workspacePath = [System.IO.Path]::GetFullPath($Workspace)
        workspaceRoots = @([System.IO.Path]::GetFullPath($Workspace))
        cwd = [System.IO.Path]::GetFullPath($Workspace)
        normalizedTimestampEpochMs = $t0.ToUnixTimeMilliseconds()
        timestampSource = "FIXTURE"
        toolName = if ($ToolClass -eq "OWNER_REQUIRED") { "Shell" } else { "Edit" }
        toolClass = $ToolClass
        targetPaths = @($TargetPaths)
        canonicalSemanticArgsSha256 = "a" * 64
        canonicalTargetsSha256 = "b" * 64
        rawPayloadSha256 = "c" * 64
        dedupKey = "d" * 64
    }
}

function Write-Session {
    param([System.Collections.IDictionary]$Record)

    $path = Get-AiSopWorkflowSessionPath -SessionKey $Record.sessionKey
    Write-AiSopWorkflowSessionRecord -SessionPath $path -Record $Record
}

function Write-Owner {
    param(
        [string]$Feature,
        [System.Collections.IDictionary]$Record
    )

    $json = $Record | ConvertTo-Json -Compress -Depth 40
    Assert-True ($json | Test-Json -SchemaFile $OwnerSchema) (
        "Test owner fixture is not schema-valid for $Feature."
    )
    $path = Join-Path (
        Get-AiSopWorkflowOwnerRegistryRoot
    ) ($Feature.ToLowerInvariant() + ".json")
    [System.IO.Directory]::CreateDirectory(
        [System.IO.Path]::GetDirectoryName($path)
    ) | Out-Null
    [System.IO.File]::WriteAllText($path, $json, $Utf8NoBom)
}

function Remove-TestOwners {
    $root = Get-AiSopWorkflowOwnerRegistryRoot
    if (Test-Path -LiteralPath $root -PathType Container) {
        Get-ChildItem -LiteralPath $root -Filter *.json -File |
            Remove-Item -Force
    }
}

function Invoke-Decision {
    param([object]$HookEvent)

    return Get-AiSopGuardDecision `
        -HookEvent $HookEvent `
        -AcceptedAt $t0.AddSeconds(5) `
        -DeadlineUtc ([DateTimeOffset]::UtcNow.AddSeconds(2))
}

function Assert-AllowDecision {
    param(
        [object]$HookEvent,
        [string]$Message
    )

    $result = Invoke-Decision -HookEvent $HookEvent
    Assert-Equal $result.Decision "ALLOW" $Message
    return $result
}

function Assert-DenyDecision {
    param(
        [object]$HookEvent,
        [string]$Message
    )

    $result = Invoke-Decision -HookEvent $HookEvent
    Assert-Equal $result.Decision "DENY" $Message
    return $result
}

try {
    foreach ($name in $RegistryVariables) {
        $SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    $env:SERVER_NEW_WORKFLOW_REGISTRY = Join-Path $TestRoot "owners"
    $env:SERVER_NEW_WORKFLOW_SESSION_REGISTRY = Join-Path $TestRoot "sessions"
    $env:SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY =
        Join-Path $TestRoot "grants"
    $env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY =
        Join-Path $TestRoot "transactions"
    $env:SERVER_NEW_HOOK_DEDUP_REGISTRY = Join-Path $TestRoot "dedup"
    $env:SERVER_NEW_HOOK_CORRELATION_REGISTRY =
        Join-Path $TestRoot "correlation"
    Remove-Item Env:SERVER_NEW_SKIP_OWNER_GUARD -ErrorAction SilentlyContinue

    foreach ($path in @(
        $Workspace,
        (Join-Path $Workspace ".ai-workspace\specs\features\GuardFeature"),
        (Join-Path $Workspace ".claude\scratch"),
        (Join-Path $Workspace "docs"),
        (Join-Path $Workspace "src\com"),
        (Join-Path $Workspace "WebRoot"),
        (Join-Path $Workspace "config")
    )) {
        [System.IO.Directory]::CreateDirectory($path) | Out-Null
    }

    foreach ($requiredPath in @(
        $GuardScript,
        $SessionScript,
        $TransactionScript,
        $OwnerSchema
    )) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Required Guard dependency does not exist: $requiredPath"
        }
    }

    $guardSource = [System.IO.File]::ReadAllText($GuardScript)
    if ($guardSource -notmatch "(?m)^function Get-AiSopGuardDecision") {
        throw (
            "Guard exact-owner decision interface is missing. " +
            "The old arbitrary-ACTIVE-owner implementation must fail this RED."
        )
    }

    . $TransactionScript
    . $SessionScript
    . $GuardScript

    foreach ($value in @("0", "true", "01", "TRUE", "yes")) {
        $env:SERVER_NEW_SKIP_OWNER_GUARD = $value
        Assert-True (-not (Test-AiSopGuardEscapeEnabled)) (
            "T1 escape accepted non-exact value '$value'."
        )
    }
    $env:SERVER_NEW_SKIP_OWNER_GUARD = "1"
    Assert-True (Test-AiSopGuardEscapeEnabled) (
        "T1 escape did not accept the exact value '1'."
    )
    Remove-Item Env:SERVER_NEW_SKIP_OWNER_GUARD -ErrorAction SilentlyContinue

    $nonProduction = New-TestHookEvent -TargetPaths @(
        (Join-Path $Workspace ".claude\scratch\a.txt"),
        (Join-Path $Workspace "docs\b.md")
    )
    $nonProductionResult = Assert-AllowDecision `
        -HookEvent $nonProduction `
        -Message "All non-production FILE_EDIT targets require no Owner."
    Assert-Equal $nonProductionResult.ReasonCode "NON_PRODUCTION_FILE_EDIT" (
        "Non-production decision returned the wrong stable reason."
    )

    $unknown = New-TestHookEvent -ToolClass UNKNOWN
    Assert-DenyDecision $unknown "UNKNOWN tools must fail closed." | Out-Null

    $missingPath = New-TestHookEvent -ToolClass FILE_EDIT -TargetPaths @()
    $missingResult = Assert-DenyDecision `
        -HookEvent $missingPath `
        -Message "FILE_EDIT with missing paths must fail closed."
    Assert-Equal $missingResult.ReasonCode "EDIT_PATH_MISSING" (
        "Missing FILE_EDIT path did not return a stable deny code."
    )

    $outsidePath = New-TestHookEvent -TargetPaths @(
        (Join-Path $TestRoot "outside.txt")
    )
    Assert-DenyDecision `
        -HookEvent $outsidePath `
        -Message "A target outside the physical workspace must fail closed." |
        Out-Null

    $productionEvent = New-TestHookEvent -TargetPaths @(
        (Join-Path $Workspace "src\com\joyfort\Game.java")
    )
    Assert-DenyDecision `
        -HookEvent $productionEvent `
        -Message "Production FILE_EDIT without an exact Owner must deny." |
        Out-Null

    $session = Invoke-AiSopWorkflowSession `
        -Operation Register `
        -Agent CURSOR `
        -NativeSessionId "guard-session" `
        -WorkspacePath $Workspace `
        -LifecycleProof CONFIRMED `
        -AcceptedAt $t0
    $baselineSession = Read-AiSopWorkflowSessionRecord `
        -SessionPath $session.SessionPath `
        -ExpectedSessionKey $session.Record.sessionKey
    $baselineSession.boundFeature = "GuardFeature"
    $baselineSession.boundWorkflow = "SUPERPOWERS"
    $baselineSession.boundOwnerId = "guard-owner"
    $baselineSession.boundSessionEpochId = $baselineSession.sessionEpochId
    $baselineSession.lastTransactionId = "guard-baseline"
    Write-Session $baselineSession

    $specDirectory = [System.IO.Path]::GetFullPath((
        Join-Path $Workspace ".ai-workspace\specs\features\GuardFeature"
    ))
    $baselineOwner = [ordered]@{
        schemaVersion = "1.1"
        feature = "GuardFeature"
        workflow = "SUPERPOWERS"
        agent = "CURSOR"
        ownerId = "guard-owner"
        specDirectory = $specDirectory
        workspacePath = [System.IO.Path]::GetFullPath($Workspace)
        status = "ACTIVE"
        startedAt = $t0.AddMinutes(-1).ToString("o")
        completedAt = ""
        sessionBinding = [ordered]@{
            sessionKey = [string]$baselineSession.sessionKey
            sessionEpochId = [string]$baselineSession.sessionEpochId
            boundAt = $t0.ToString("o")
        }
        lastTransactionId = "guard-baseline"
    }
    Write-Owner -Feature "GuardFeature" -Record $baselineOwner

    $allowed = Assert-AllowDecision `
        -HookEvent $productionEvent `
        -Message "Exact session-bound Owner 1.1 must allow production edit."
    Assert-Equal $allowed.ReasonCode "EXACT_OWNER_AUTHORIZED" (
        "Exact Owner allow returned the wrong stable reason."
    )
    Assert-True (
        [string]$allowed.AuthorizationSnapshotSha256 -match "^[0-9a-f]{64}$"
    ) "Exact Owner allow did not bind an authorization snapshot hash."

    $shellEvent = New-TestHookEvent -ToolClass OWNER_REQUIRED
    Assert-AllowDecision `
        -HookEvent $shellEvent `
        -Message "OWNER_REQUIRED requires and accepts only the exact Owner." |
        Out-Null

    $mixedEvent = New-TestHookEvent -TargetPaths @(
        (Join-Path $Workspace ".claude\scratch\a.txt"),
        (Join-Path $Workspace "config\mixed.csv")
    )
    Assert-AllowDecision `
        -HookEvent $mixedEvent `
        -Message "A mixed target set must use exact Owner authorization." |
        Out-Null

    Remove-TestOwners
    $otherSpec = Join-Path $Workspace ".ai-workspace\specs\features\OtherFeature"
    [System.IO.Directory]::CreateDirectory($otherSpec) | Out-Null
    $otherOwner = Copy-Record $baselineOwner
    $otherOwner.feature = "OtherFeature"
    $otherOwner.ownerId = "other-owner"
    $otherOwner.specDirectory = [System.IO.Path]::GetFullPath($otherSpec)
    Write-Owner -Feature "OtherFeature" -Record $otherOwner
    Assert-DenyDecision `
        -HookEvent $productionEvent `
        -Message "Another feature's ACTIVE Owner must never authorize." |
        Out-Null

    Remove-TestOwners
    $customOwner = [ordered]@{
        schemaVersion = "1.0"
        feature = "LegacyCustom"
        workflow = "CUSTOM_SKILLS"
        agent = "COPILOT"
        ownerId = "legacy-custom"
        specDirectory = [System.IO.Path]::GetFullPath((
            Join-Path $Workspace ".ai-workspace\specs\features\LegacyCustom"
        ))
        status = "ACTIVE"
        startedAt = $t0.AddMinutes(-1).ToString("o")
        completedAt = ""
    }
    [System.IO.Directory]::CreateDirectory($customOwner.specDirectory) |
        Out-Null
    Write-Owner -Feature "LegacyCustom" -Record $customOwner
    Assert-DenyDecision `
        -HookEvent $productionEvent `
        -Message "An ACTIVE CUSTOM_SKILLS Owner 1.0 must not authorize." |
        Out-Null

    $legacyOwner = [ordered]@{
        schemaVersion = "1.0"
        feature = "GuardFeature"
        workflow = "SUPERPOWERS"
        agent = "CURSOR"
        ownerId = "guard-owner"
        specDirectory = $specDirectory
        status = "ACTIVE"
        startedAt = $t0.AddMinutes(-1).ToString("o")
        completedAt = ""
    }
    Remove-TestOwners
    Write-Owner -Feature "GuardFeature" -Record $legacyOwner
    Assert-DenyDecision `
        -HookEvent $productionEvent `
        -Message "The current real Owner 1.0 must not authorize Guard." |
        Out-Null

    $invalidRows = @(
        @{
            Name = "owner agent"
            Mutate = { param($owner, $sessionRecord) $owner.agent = "COPILOT" }
        },
        @{
            Name = "owner id"
            Mutate = { param($owner, $sessionRecord) $owner.ownerId = "wrong-owner" }
        },
        @{
            Name = "owner feature"
            Mutate = { param($owner, $sessionRecord) $owner.feature = "WrongFeature" }
        },
        @{
            Name = "owner workspace"
            Mutate = {
                param($owner, $sessionRecord)
                $owner.workspacePath = [System.IO.Path]::GetFullPath($TestRoot)
            }
        },
        @{
            Name = "owner spec"
            Mutate = {
                param($owner, $sessionRecord)
                $owner.specDirectory = [System.IO.Path]::GetFullPath((
                    Join-Path $Workspace ".ai-workspace\specs\features\WrongFeature"
                ))
            }
        },
        @{
            Name = "owner session key"
            Mutate = {
                param($owner, $sessionRecord)
                $owner.sessionBinding.sessionKey = "e" * 64
            }
        },
        @{
            Name = "owner session epoch"
            Mutate = {
                param($owner, $sessionRecord)
                $owner.sessionBinding.sessionEpochId = "wrong-epoch"
            }
        },
        @{
            Name = "owner COMPLETE"
            Mutate = {
                param($owner, $sessionRecord)
                $owner.status = "COMPLETE"
                $owner.completedAt = $t0.AddSeconds(1).ToString("o")
            }
        },
        @{
            Name = "session PENDING"
            Mutate = {
                param($owner, $sessionRecord)
                $sessionRecord.lifecycleProof = "PENDING"
            }
        },
        @{
            Name = "session IDLE"
            Mutate = { param($owner, $sessionRecord) $sessionRecord.status = "IDLE" }
        },
        @{
            Name = "session ENDED"
            Mutate = {
                param($owner, $sessionRecord)
                $sessionRecord.status = "ENDED"
                $sessionRecord.endedAt = $t0.AddSeconds(1).ToString("o")
            }
        },
        @{
            Name = "session expired"
            Mutate = {
                param($owner, $sessionRecord)
                $sessionRecord.expiresAt = $t0.AddSeconds(1).ToString("o")
            }
        },
        @{
            Name = "session bound epoch"
            Mutate = {
                param($owner, $sessionRecord)
                $sessionRecord.boundSessionEpochId = "wrong-epoch"
            }
        },
        @{
            Name = "incomplete bound tuple"
            Mutate = {
                param($owner, $sessionRecord)
                $sessionRecord.boundOwnerId = ""
            }
        }
    )
    foreach ($row in $invalidRows) {
        $owner = Copy-Record $baselineOwner
        $sessionRecord = Copy-Record $baselineSession
        & $row.Mutate $owner $sessionRecord
        if ($row.Name -eq "incomplete bound tuple") {
            [System.IO.File]::WriteAllText(
                $session.SessionPath,
                ($sessionRecord | ConvertTo-Json -Compress -Depth 40),
                $Utf8NoBom
            )
        } else {
            Write-Session $sessionRecord
        }
        Remove-TestOwners
        Write-Owner -Feature "GuardFeature" -Record $owner
        Assert-DenyDecision `
            -HookEvent $productionEvent `
            -Message "Exact Guard accepted mismatched $($row.Name)." |
            Out-Null
    }

    Write-Session (Copy-Record $baselineSession)
    Remove-TestOwners
    Write-Owner -Feature "GuardFeature" -Record (
        Copy-Record $baselineOwner
    )

    $safePhysical = Join-Path $Workspace ".claude\safe-physical"
    [System.IO.Directory]::CreateDirectory($safePhysical) | Out-Null
    [System.IO.Directory]::Delete((Join-Path $Workspace "src\com"), $true)
    New-Item `
        -ItemType Junction `
        -Path (Join-Path $Workspace "src\com") `
        -Target $safePhysical | Out-Null
    $CreatedJunctions += Join-Path $Workspace "src\com"
    $lexicalProduction = New-TestHookEvent -TargetPaths @(
        (Join-Path $Workspace "src\com\lexical-production.txt")
    )
    Assert-AllowDecision `
        -HookEvent $lexicalProduction `
        -Message "Lexical production through a safe junction needs exact Owner." |
        Out-Null

    $physicalProductionLink = Join-Path $Workspace ".claude\production-link"
    New-Item `
        -ItemType Junction `
        -Path $physicalProductionLink `
        -Target (Join-Path $Workspace "config") | Out-Null
    $CreatedJunctions += $physicalProductionLink
    $physicalProduction = New-TestHookEvent -TargetPaths @(
        (Join-Path $physicalProductionLink "physical-production.txt")
    )
    Assert-AllowDecision `
        -HookEvent $physicalProduction `
        -Message "Physical production through a safe lexical path needs exact Owner." |
        Out-Null

    Write-Output "All guard production edit tests passed."
} finally {
    foreach ($name in $RegistryVariables) {
        [Environment]::SetEnvironmentVariable(
            $name,
            [string]$SavedEnvironment[$name]
        )
    }
    foreach ($junction in $CreatedJunctions) {
        if (Test-Path -LiteralPath $junction) {
            Remove-Item -LiteralPath $junction -Force
        }
    }
    if (Test-Path -LiteralPath $TestRoot) {
        [System.IO.Directory]::Delete($TestRoot, $true)
    }
}
