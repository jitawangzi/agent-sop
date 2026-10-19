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
    "SERVER_NEW_SKIP_OWNER_GUARD",
    'AI_SOP_SKIP_OWNER_GUARD',
    "AI_SOP_GUARD_ROOT"
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

function Write-TestTask {
    param([System.Collections.IDictionary]$Record)
    $path = Join-Path $Workspace '.ai-workspace/specs/features/GuardFeature/tasks/guard-task/task.json'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
    [IO.File]::WriteAllText($path, ($Record | ConvertTo-Json -Compress -Depth 40), $Utf8NoBom)
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
    Remove-Item Env:AI_SOP_SKIP_OWNER_GUARD -ErrorAction SilentlyContinue

    foreach ($path in @(
        $Workspace,
        (Join-Path $Workspace ".ai-workspace\specs\features\GuardFeature"),
        (Join-Path $Workspace ".claude\scratch"),
        (Join-Path $Workspace "docs"),
        (Join-Path $Workspace "src\com"),
        (Join-Path $Workspace "WebRoot"),
        (Join-Path $Workspace "config"),
        (Join-Path $Workspace ".ai-sop")
    )) {
        [System.IO.Directory]::CreateDirectory($path) | Out-Null
    }
    $env:AI_SOP_GUARD_ROOT = Join-Path $Workspace ".ai-sop"

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
            "人工维护开关错误接受 '$value'。"
        )
    }
    $env:SERVER_NEW_SKIP_OWNER_GUARD = "1"
    Assert-True (Test-AiSopGuardEscapeEnabled) (
        "人工维护开关应接受精确值 '1'。"
    )
    Remove-Item Env:SERVER_NEW_SKIP_OWNER_GUARD -ErrorAction SilentlyContinue

    $nonProduction = New-TestHookEvent -TargetPaths @(
        (Join-Path $Workspace ".claude\scratch\a.txt"),
        (Join-Path $Workspace "docs\b.md")
    )
    $nonProductionResult = Assert-DenyDecision `
        -HookEvent $nonProduction `
        -Message '文档和测试等非生产目录也必须先登记任务。'
    Assert-AllowDecision -HookEvent (New-TestHookEvent -ToolClass SAFE_NON_EDIT) -Message '只读操作不要求任务或档位。' | Out-Null

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
        baseline = "0"
        taskId = 'guard-task'
    }
    Write-Owner -Feature "GuardFeature" -Record $baselineOwner

    $noTask = Assert-DenyDecision -HookEvent $productionEvent -Message '只有归属不能替代任务。'
    Assert-Equal $noTask.ReasonCode 'TASK_NOT_FOUND' '缺失 canonical 任务应明确拒绝。'
    $baselineTask = [ordered]@{
        schemaVersion = '1.0'; taskId = 'guard-task'; feature = 'GuardFeature'; ownerId = 'guard-owner'
        tier = 'T2'; objective = '验证写前任务约束'; status = 'ACTIVE'; nextAction = ''; notes = ''
        createdAt = $t0.ToString('o'); updatedAt = $t0.ToString('o'); requiredCaseIds = @(); verifications = @()
    }
    Write-TestTask $baselineTask

    $escapedTaskTarget = Join-Path $TestRoot 'external-task'
    [IO.Directory]::CreateDirectory($escapedTaskTarget) | Out-Null
    $escapedTaskLink = Join-Path $specDirectory 'tasks/escaped-task'
    New-Item -ItemType Junction -Path $escapedTaskLink -Target $escapedTaskTarget | Out-Null
    $CreatedJunctions += $escapedTaskLink
    $escapedTaskOwner = Copy-Record $baselineOwner
    $escapedTaskOwner.taskId = 'escaped-task'
    Write-Owner -Feature 'GuardFeature' -Record $escapedTaskOwner
    $escapedTaskDeny = Assert-DenyDecision -HookEvent $productionEvent -Message '任务目录的链接不能逃逸当前功能。'
    Assert-Equal $escapedTaskDeny.ReasonCode 'TASK_PATH_ESCAPE' '逃逸的任务目录应在读取前拒绝。'
    Write-Owner -Feature 'GuardFeature' -Record $baselineOwner

    $allowed = Assert-AllowDecision `
        -HookEvent $productionEvent `
        -Message "Exact session-bound Owner 1.1 must allow production edit."
    Assert-Equal $allowed.ReasonCode "EXACT_OWNER_AUTHORIZED" (
        "Exact Owner allow returned the wrong stable reason."
    )
    Assert-True (
        [string]$allowed.AuthorizationSnapshotSha256 -match "^[0-9a-f]{64}$"
    ) "Exact Owner allow did not bind an authorization snapshot hash."

    Assert-AllowDecision -HookEvent $nonProduction -Message '合法任务可修改项目文档和测试目录。' | Out-Null
    $legacyBinding = Copy-Record $baselineOwner
    $legacyBinding.Remove('taskId')
    Write-Owner -Feature 'GuardFeature' -Record $legacyBinding
    $legacyTaskDeny = Assert-DenyDecision -HookEvent $productionEvent -Message '历史 owner-only 归属必须先 Resume 收编。'
    Assert-Equal $legacyTaskDeny.ReasonCode 'TASK_REQUIRED' '历史归属应提示任务入口。'
    Write-Owner -Feature 'GuardFeature' -Record $baselineOwner
    foreach ($tier in @('T1','T2','T3')) {
        $task = Copy-Record $baselineTask
        $task.tier = $tier
        Write-TestTask $task
        $tierAllowed = Assert-AllowDecision -HookEvent $productionEvent -Message "正常 $tier 应在任务授权下放行。"
        Assert-Equal $tierAllowed.ReasonCode 'EXACT_OWNER_AUTHORIZED' '正常档位不得被标记为停用防护。'
        if ($tier -ne 'T2') {
            Assert-True ($tierAllowed.AuthorizationSnapshotSha256 -cne $allowed.AuthorizationSnapshotSha256) '授权快照必须绑定档位。'
        }
    }
    foreach ($row in @(
        @{ key='taskId'; value='different-task'; code='TASK_IDENTITY_MISMATCH' },
        @{ key='feature'; value='OtherFeature'; code='TASK_IDENTITY_MISMATCH' },
        @{ key='ownerId'; value='another-owner'; code='TASK_IDENTITY_MISMATCH' },
        @{ key='status'; value='PAUSED'; code='TASK_INACTIVE' },
        @{ key='status'; value='DONE'; code='TASK_INACTIVE' },
        @{ key='status'; value='CANCELLED'; code='TASK_INACTIVE' },
        @{ key='tier'; value='T0'; code='TASK_REGISTRY_CORRUPT' }
    )) {
        $task = Copy-Record $baselineTask
        $task[$row.key] = $row.value
        Write-TestTask $task
        $invalidTask = Assert-DenyDecision -HookEvent $productionEvent -Message "任务 $($row.key)=$($row.value) 不应放行。"
        Assert-Equal $invalidTask.ReasonCode $row.code '任务拒绝原因不一致。'
    }
    Write-TestTask $baselineTask

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
        baseline = "0"
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
        baseline = "0"
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

    $guardDisabledPath = Join-Path $env:AI_SOP_GUARD_ROOT ".guard-disabled"
    $guardTokenPath = Join-Path $env:AI_SOP_GUARD_ROOT ".guard-token.json"
    $disabledEvent = New-TestHookEvent -TargetPaths @($guardDisabledPath)
    $disabledDeny = Assert-DenyDecision `
        -HookEvent $disabledEvent `
        -Message "AI must not create .guard-disabled without env skip."
    Assert-Equal $disabledDeny.ReasonCode "GOVERNANCE_SWITCH_PROTECTED" (
        "Governance switch deny used the wrong reason."
    )
    $tokenEvent = New-TestHookEvent -TargetPaths @($guardTokenPath)
    $tokenDeny = Assert-DenyDecision `
        -HookEvent $tokenEvent `
        -Message "AI must not create .guard-token.json without env skip."
    Assert-Equal $tokenDeny.ReasonCode "GOVERNANCE_SWITCH_PROTECTED" (
        "Governance token deny used the wrong reason."
    )
    $env:AI_SOP_SKIP_OWNER_GUARD = "1"
    Assert-AllowDecision `
        -HookEvent $disabledEvent `
        -Message "Human env skip may write the governance switch." |
        Out-Null
    Remove-Item Env:AI_SOP_SKIP_OWNER_GUARD -ErrorAction SilentlyContinue

    [System.IO.File]::WriteAllText(
        $guardTokenPath,
        (@{
            feature = "GuardFeature"
            reason = "test"
            operator = "test"
            expiresAt = $t0.AddHours(1).ToString("o")
        } | ConvertTo-Json -Compress),
        $Utf8NoBom
    )
    Assert-True (-not (Test-AiSopGuardEscapeEnabled)) (
        "Unexpired token must not globally disable the guard."
    )
    $tokenAllow = Assert-AllowDecision `
        -HookEvent $productionEvent `
        -Message "Feature-matching token must allow production edit."
    Assert-Equal $tokenAllow.ReasonCode "GUARD_DISABLED_FOR_FEATURE" (
        "Matching token used the wrong reason."
    )
    [System.IO.File]::WriteAllText(
        $guardTokenPath,
        (@{
            feature = "OtherFeature"
            reason = "test"
            operator = "test"
            expiresAt = $t0.AddHours(1).ToString("o")
        } | ConvertTo-Json -Compress),
        $Utf8NoBom
    )
    Assert-AllowDecision `
        -HookEvent $productionEvent `
        -Message "Mismatched token must fall through to exact Owner." |
        Out-Null
    Remove-Item -LiteralPath $guardTokenPath -Force

    $posixPolicyDir = Join-Path $Workspace ".ai-sop\config"
    [System.IO.Directory]::CreateDirectory($posixPolicyDir) | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $posixPolicyDir "project-policy.json"),
        '{"productionPatterns":["^src/.*"]}',
        $Utf8NoBom
    )
    Assert-True (
        Test-AiSopGuardProductionPath `
            -Path (Join-Path $Workspace "src\com\posix.java") `
            -WorkspaceRoot ([System.IO.Path]::GetFullPath($Workspace))
    ) "POSIX policy ^src/ must match a Windows src\\ path after slash normalize."
    Remove-Item -LiteralPath (Join-Path $posixPolicyDir "project-policy.json") -Force

    $script:AiSopForceUnixLockSemantics = $true
    $posixLockPath = Join-Path $TestRoot "posix.lock"
    [System.IO.File]::WriteAllText($posixLockPath, "", $Utf8NoBom)
    $posixStream = [System.IO.File]::Open(
        $posixLockPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    Exit-AiSopWorkflowLocks @(
        [pscustomobject]@{ Path = $posixLockPath; Stream = $posixStream }
    )
    Assert-True (Test-Path -LiteralPath $posixLockPath) (
        "POSIX lock semantics must leave the sentinel file in place."
    )
    $script:AiSopForceUnixLockSemantics = $false
    Remove-Item -LiteralPath $posixLockPath -Force -ErrorAction SilentlyContinue

    $savedOwnerReg = $env:SERVER_NEW_WORKFLOW_REGISTRY
    $savedAiSopOwner = $env:AI_SOP_OWNER_REGISTRY
    Remove-Item Env:SERVER_NEW_WORKFLOW_REGISTRY -ErrorAction SilentlyContinue
    Remove-Item Env:AI_SOP_OWNER_REGISTRY -ErrorAction SilentlyContinue
    try {
        $fromWorkspace = Get-AiSopWorkflowOwnerRegistryRoot -WorkspacePath $Workspace
        Push-Location (Join-Path $Workspace "docs")
        try {
            $fromCwd = Get-AiSopWorkflowOwnerRegistryRoot
        } finally {
            Pop-Location
        }
        Assert-True ($fromWorkspace -cne $fromCwd) (
            "Owner registry scope must not silently follow cwd when WorkspacePath is passed."
        )
        Assert-Equal (Get-AiSopWorkflowOwnerRegistryRoot -WorkspacePath $Workspace) $fromWorkspace (
            "Explicit WorkspacePath must be stable regardless of cwd."
        )
    } finally {
        $env:SERVER_NEW_WORKFLOW_REGISTRY = $savedOwnerReg
        if (-not [string]::IsNullOrWhiteSpace($savedAiSopOwner)) {
            $env:AI_SOP_OWNER_REGISTRY = $savedAiSopOwner
        }
    }

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
