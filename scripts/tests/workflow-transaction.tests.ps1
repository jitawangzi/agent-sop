#requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$ScriptsRoot = Split-Path -Parent $PSScriptRoot
$TransactionScript = Join-Path $ScriptsRoot "workflow-transaction.ps1"
$OwnerScript = Join-Path $ScriptsRoot "workflow-owner.ps1"
$SessionScript = Join-Path $ScriptsRoot "workflow-session.ps1"
$GrantScript = Join-Path $ScriptsRoot "workflow-command-grant.ps1"
$ClaudeRoot = Split-Path -Parent $ScriptsRoot
$TransactionSchema = Join-Path $ClaudeRoot "schemas\workflow-transaction.schema.json"
$OwnerSchema = Join-Path $ClaudeRoot "schemas\workflow-owner.schema.json"
$SessionSchema = Join-Path $ClaudeRoot "schemas\workflow-session.schema.json"
$GrantSchema = Join-Path $ClaudeRoot "schemas\workflow-command-grant.schema.json"
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "workflow-transaction-tests-" + [guid]::NewGuid().ToString("N")
)
$env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY = Join-Path $TestRoot "transactions"
$env:SERVER_NEW_WORKFLOW_SESSION_REGISTRY = Join-Path $TestRoot "sessions"
$env:SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY = Join-Path $TestRoot "grants"
$env:SERVER_NEW_WORKFLOW_REGISTRY = Join-Path $TestRoot "owners"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$t0 = [DateTimeOffset]::Parse("2026-08-17T12:00:00.0000000Z")

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)

    if ($Actual -cne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-ThrowsCode {
    param([scriptblock]$Action, [string]$Code, [string]$Message)

    $actual = ""
    try {
        & $Action | Out-Null
    } catch {
        $actual = $_.Exception.Message
    }
    if ($actual -cne $Code) {
        throw "$Message Expected error '$Code', got '$actual'."
    }
}

function Write-State {
    param([string]$Path, [object]$Value)

    [System.IO.Directory]::CreateDirectory(
        [System.IO.Path]::GetDirectoryName($Path)
    ) | Out-Null
    [System.IO.File]::WriteAllText(
        $Path,
        ($Value | ConvertTo-Json -Depth 30),
        $Utf8NoBom
    )
}

function Read-State {
    param([string]$Path, [string]$SchemaPath)

    $raw = [System.IO.File]::ReadAllText($Path)
    Assert-True ($raw | Test-Json -SchemaFile $SchemaPath) (
        "State does not satisfy schema: $Path"
    )
    return ConvertFrom-AiSopWorkflowJson -Json $raw
}

function New-BeforeStateSet {
    param(
        [string]$CaseRoot,
        [string]$TransactionId,
        [string]$SessionKey
    )

    $workspace = Join-Path $CaseRoot "workspace"
    $spec = Join-Path $workspace ".ai-workspace\specs\features\TxFeature"
    $ownerPath = Join-Path $env:SERVER_NEW_WORKFLOW_REGISTRY "txfeature.json"
    $sessionPath = Join-Path (
        $env:SERVER_NEW_WORKFLOW_SESSION_REGISTRY
    ) "$SessionKey.json"
    $grantId = Get-AiSopWorkflowSha256 "grant-$TransactionId"
    $grantPath = Join-Path (
        $env:SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY
    ) "$grantId.json"
    [System.IO.Directory]::CreateDirectory($spec) | Out-Null

    $epoch = "epoch-$TransactionId"
    $sessionBefore = [ordered]@{
        schemaVersion = "1.0"
        sessionKey = $SessionKey
        sessionEpochId = $epoch
        agent = "CURSOR"
        nativeSessionIdSha256 = Get-AiSopWorkflowSha256 "native-$TransactionId"
        workspacePath = [System.IO.Path]::GetFullPath($workspace)
        lifecycleProof = "CONFIRMED"
        lifecycleNativeSessionIdSha256 = Get-AiSopWorkflowSha256 "native-$TransactionId"
        status = "ACTIVE"
        firstSeenAt = $t0.ToString("o")
        lastSeenAt = $t0.ToString("o")
        stateChangedAt = $t0.ToString("o")
        expiresAt = $t0.AddMinutes(30).ToString("o")
        endedAt = ""
        lastGrantId = $grantId
        lastGrantIntentSha256 = Get-AiSopWorkflowSha256 "intent-$TransactionId"
        boundFeature = ""
        boundWorkflow = ""
        boundOwnerId = ""
        boundSessionEpochId = ""
        lastTransactionId = ""
    }
    $ownerBefore = [ordered]@{
        schemaVersion = "1.1"
        feature = "TxFeature"
        workflow = "SUPERPOWERS"
        agent = "CURSOR"
        ownerId = "tx-owner"
        specDirectory = [System.IO.Path]::GetFullPath($spec)
        workspacePath = [System.IO.Path]::GetFullPath($workspace)
        status = "ACTIVE"
        startedAt = $t0.ToString("o")
        completedAt = ""
        sessionBinding = [ordered]@{
            sessionKey = $SessionKey
            sessionEpochId = $epoch
            boundAt = $t0.ToString("o")
        }
        lastTransactionId = "previous-$TransactionId"
    }
    $grantBefore = [ordered]@{
        schemaVersion = "1.0"
        grantId = $grantId
        status = "ISSUED"
        sessionKey = $SessionKey
        sessionEpochId = $epoch
        agent = "CURSOR"
        workspacePath = [System.IO.Path]::GetFullPath($workspace)
        operation = "Claim"
        feature = "TxFeature"
        specDirectory = [System.IO.Path]::GetFullPath($spec)
        workflow = "SUPERPOWERS"
        ownerId = "tx-owner"
        intentSha256 = Get-AiSopWorkflowSha256 "intent-$TransactionId"
        dedupKey = Get-AiSopWorkflowSha256 "dedup-$TransactionId"
        issuedAt = $t0.ToString("o")
        expiresAt = $t0.AddSeconds(10).ToString("o")
        consumedAt = ""
        transactionId = "issue-$TransactionId"
    }

    $sessionAfter = $sessionBefore |
        ConvertTo-Json -Depth 30 |
        ForEach-Object {
            ConvertFrom-AiSopWorkflowJson -Json $_ -AsHashtable
        }
    $sessionAfter.boundFeature = "TxFeature"
    $sessionAfter.boundWorkflow = "SUPERPOWERS"
    $sessionAfter.boundOwnerId = "tx-owner"
    $sessionAfter.boundSessionEpochId = $epoch
    $sessionAfter.lastTransactionId = $TransactionId
    $ownerAfter = $ownerBefore |
        ConvertTo-Json -Depth 30 |
        ForEach-Object {
            ConvertFrom-AiSopWorkflowJson -Json $_ -AsHashtable
        }
    $ownerAfter.lastTransactionId = $TransactionId
    $grantAfter = $grantBefore |
        ConvertTo-Json -Depth 30 |
        ForEach-Object {
            ConvertFrom-AiSopWorkflowJson -Json $_ -AsHashtable
        }
    $grantAfter.status = "CONSUMED"
    $grantAfter.consumedAt = $t0.AddSeconds(1).ToString("o")
    $grantAfter.transactionId = $TransactionId

    Write-State $sessionPath $sessionBefore
    Write-State $ownerPath $ownerBefore
    Write-State $grantPath $grantBefore

    return [pscustomobject]@{
        Workspace = $workspace
        OwnerPath = $ownerPath
        SessionPath = $sessionPath
        GrantPath = $grantPath
        SessionKey = $SessionKey
        GrantId = $grantId
        Before = [ordered]@{
            Session = $sessionBefore
            Owner = $ownerBefore
            Grant = $grantBefore
        }
        After = [ordered]@{
            Session = $sessionAfter
            Owner = $ownerAfter
            Grant = $grantAfter
        }
        Targets = @(
            [pscustomobject][ordered]@{
                path = $sessionPath
                kind = "SESSION"
                schemaId = "SESSION"
                afterJson = ConvertTo-AiSopWorkflowCanonicalJson $sessionAfter
            },
            [pscustomobject][ordered]@{
                path = $ownerPath
                kind = "OWNER"
                schemaId = "OWNER"
                afterJson = ConvertTo-AiSopWorkflowCanonicalJson $ownerAfter
            },
            [pscustomobject][ordered]@{
                path = $grantPath
                kind = "COMMAND_GRANT"
                schemaId = "COMMAND_GRANT"
                afterJson = ConvertTo-AiSopWorkflowCanonicalJson $grantAfter
            }
        )
    }
}

function Assert-StateSet {
    param(
        [object]$StateSet,
        [ValidateSet("BEFORE", "AFTER")]
        [string]$Expected
    )

    $expectedSet = if ($Expected -eq "BEFORE") {
        $StateSet.Before
    } else {
        $StateSet.After
    }
    $actualSession = Read-State $StateSet.SessionPath $SessionSchema
    $actualOwner = Read-State $StateSet.OwnerPath $OwnerSchema
    $actualGrant = Read-State $StateSet.GrantPath $GrantSchema
    Assert-Equal (
        ConvertTo-AiSopWorkflowCanonicalJson $actualSession
    ) (
        ConvertTo-AiSopWorkflowCanonicalJson $expectedSet.Session
    ) "$Expected session state mismatch."
    Assert-Equal (
        ConvertTo-AiSopWorkflowCanonicalJson $actualOwner
    ) (
        ConvertTo-AiSopWorkflowCanonicalJson $expectedSet.Owner
    ) "$Expected owner state mismatch."
    Assert-Equal (
        ConvertTo-AiSopWorkflowCanonicalJson $actualGrant
    ) (
        ConvertTo-AiSopWorkflowCanonicalJson $expectedSet.Grant
    ) "$Expected grant state mismatch."
}

function New-RealOwnerCommand {
    param(
        [string]$Operation,
        [string]$Feature,
        [string]$OwnerId
    )

    return (
        "pwsh -NoProfile -File '.\.ai-sop\scripts\workflow-owner.ps1' " +
        "-Operation '$Operation' " +
        "-SpecDirectory '.ai-workspace\specs\features\$Feature' " +
        "-Feature '$Feature' -Workflow 'SUPERPOWERS' " +
        "-Agent 'CURSOR' -OwnerId '$OwnerId'"
    )
}

function New-RealOperationState {
    param(
        [string]$Operation,
        [string]$CaseName
    )

    $feature = "Real$CaseName"
    $ownerId = "real-$($CaseName.ToLowerInvariant())"
    $workspace = Join-Path $TestRoot "real-$CaseName"
    $spec = Join-Path $workspace ".ai-workspace\specs\features\$feature"
    [System.IO.Directory]::CreateDirectory($spec) | Out-Null
    [System.IO.Directory]::CreateDirectory(
        (Join-Path $workspace ".ai-sop\scripts")
    ) | Out-Null
    $featStatePath = Join-Path $spec "feature-state.json"
    Write-State $featStatePath ([ordered]@{
        schemaVersion = "1.0"
        feature = $feature
        tier = "T2"
        phase = "IMPLEMENTING"
        ownerSession = [ordered]@{
            agent = "CURSOR"
            ownerId = $ownerId
        }
        updatedAt = [DateTimeOffset]::UtcNow.ToString("o")
    })
    $now = [DateTimeOffset]::UtcNow
    $newSession = Invoke-AiSopWorkflowSession `
        -Operation Register `
        -Agent CURSOR `
        -NativeSessionId "real-new-$CaseName" `
        -WorkspacePath $workspace `
        -LifecycleProof CONFIRMED `
        -AcceptedAt $now
    $ownerPath = Join-Path $env:SERVER_NEW_WORKFLOW_REGISTRY (
        $feature.ToLowerInvariant() + ".json"
    )
    $sessionKeys = @([string]$newSession.Record.sessionKey)
    if ($Operation -eq "BindSession") {
        Write-State $ownerPath ([ordered]@{
            schemaVersion = "1.0"
            feature = $feature
            workflow = "SUPERPOWERS"
            agent = "CURSOR"
            ownerId = $ownerId
            specDirectory = [System.IO.Path]::GetFullPath($spec)
            status = "ACTIVE"
            startedAt = $now.AddMinutes(-1).ToString("o")
            completedAt = ""
        })
    } elseif ($Operation -in @("Validate", "Complete")) {
        $bound = Get-Content -LiteralPath $newSession.SessionPath -Raw |
            ConvertFrom-Json -AsHashtable -DateKind String
        $bound.boundFeature = $feature
        $bound.boundWorkflow = "SUPERPOWERS"
        $bound.boundOwnerId = $ownerId
        $bound.boundSessionEpochId = $bound.sessionEpochId
        Write-State $newSession.SessionPath $bound
        Write-State $ownerPath ([ordered]@{
            schemaVersion = "1.1"
            feature = $feature
            workflow = "SUPERPOWERS"
            agent = "CURSOR"
            ownerId = $ownerId
            specDirectory = [System.IO.Path]::GetFullPath($spec)
            workspacePath = [System.IO.Path]::GetFullPath($workspace)
            status = "ACTIVE"
            startedAt = $now.AddMinutes(-1).ToString("o")
            completedAt = ""
            sessionBinding = [ordered]@{
                sessionKey = $bound.sessionKey
                sessionEpochId = $bound.sessionEpochId
                boundAt = $now.AddMinutes(-1).ToString("o")
            }
            lastTransactionId = "real-before-$CaseName"
        })
        $newSession = Get-AiSopWorkflowSession -SessionKey $bound.sessionKey
    } elseif ($Operation -eq "RebindSession") {
        $oldSession = Invoke-AiSopWorkflowSession `
            -Operation Register `
            -Agent CURSOR `
            -NativeSessionId "real-old-$CaseName" `
            -WorkspacePath $workspace `
            -LifecycleProof CONFIRMED `
            -AcceptedAt $now
        $old = Get-Content -LiteralPath $oldSession.SessionPath -Raw |
            ConvertFrom-Json -AsHashtable -DateKind String
        $old.boundFeature = $feature
        $old.boundWorkflow = "SUPERPOWERS"
        $old.boundOwnerId = $ownerId
        $old.boundSessionEpochId = $old.sessionEpochId
        $old.status = "ENDED"
        $old.endedAt = $now.AddMilliseconds(-1).ToString("o")
        Write-State $oldSession.SessionPath $old
        Write-State $ownerPath ([ordered]@{
            schemaVersion = "1.1"
            feature = $feature
            workflow = "SUPERPOWERS"
            agent = "CURSOR"
            ownerId = $ownerId
            specDirectory = [System.IO.Path]::GetFullPath($spec)
            workspacePath = [System.IO.Path]::GetFullPath($workspace)
            status = "ACTIVE"
            startedAt = $now.AddMinutes(-1).ToString("o")
            completedAt = ""
            sessionBinding = [ordered]@{
                sessionKey = $old.sessionKey
                sessionEpochId = $old.sessionEpochId
                boundAt = $now.AddMinutes(-1).ToString("o")
            }
            lastTransactionId = "real-before-$CaseName"
        })
        $sessionKeys += [string]$old.sessionKey
    }
    $grant = Invoke-AiSopWorkflowCommandGrant `
        -Operation Issue `
        -CommandText (New-RealOwnerCommand `
            -Operation $Operation `
            -Feature $feature `
            -OwnerId $ownerId) `
        -SessionKey $newSession.Record.sessionKey `
        -SessionEpochId $newSession.Record.sessionEpochId `
        -DedupKey (Get-AiSopWorkflowSha256 "real-dedup-$CaseName") `
        -AcceptedAt ([DateTimeOffset]::UtcNow) `
        -TransactionId "real-issue-$CaseName"
    return [pscustomobject]@{
        Feature = $feature
        OwnerId = $ownerId
        Workspace = $workspace
        Spec = $spec
        OwnerPath = $ownerPath
        Grant = $grant
        SessionKeys = @($sessionKeys | Sort-Object -Unique)
    }
}

function Assert-RealRecoveredJournalState {
    param(
        [object]$Journal,
        [ValidateSet("BEFORE", "AFTER")]
        [string]$Expected
    )

    foreach ($target in @($Journal.targets)) {
        $expectedSnapshot = if ($Expected -eq "BEFORE") {
            $target.before
        } else {
            $target.after
        }
        $actual = Get-AiSopWorkflowTargetSnapshot `
            -Path ([string]$target.path) `
            -SchemaId ([string]$target.schemaId)
        Assert-Equal ([bool]$actual.exists) ([bool]$expectedSnapshot.exists) (
            "$Expected existence mismatch for $($target.path)."
        )
        if ([bool]$expectedSnapshot.exists) {
            Assert-Equal ([string]$actual.sha256) ([string]$expectedSnapshot.sha256) (
                "$Expected snapshot mismatch for $($target.path)."
            )
        }
    }
}

try {
    foreach ($requiredPath in @(
        $TransactionScript,
        $TransactionSchema,
        $OwnerSchema,
        $SessionSchema,
        $GrantSchema
    )) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Required Task 3 artifact does not exist: $requiredPath"
        }
    }
    . $TransactionScript
    . $SessionScript
    . $GrantScript
    $transactionFixtureRoot = Join-Path (
        $PSScriptRoot
    ) "fixtures\workflow-transactions"
    foreach ($fixtureName in @(
        "claim-prepared.json",
        "rebind-prepared.json",
        "rebind-committed.json"
    )) {
        $fixturePath = Join-Path $transactionFixtureRoot $fixtureName
        if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
            throw "Required Task 3 fixture does not exist: $fixturePath"
        }
        Assert-True (
            [System.IO.File]::ReadAllText($fixturePath) |
                Test-Json -SchemaFile $TransactionSchema
        ) "Workflow transaction fixture is schema-invalid: $fixtureName"
        $fixture = ConvertFrom-AiSopWorkflowJson `
            -Json ([System.IO.File]::ReadAllText($fixturePath))
        foreach ($target in @($fixture.targets)) {
            $targetSchema = switch ([string]$target.schemaId) {
                "OWNER" { $OwnerSchema }
                "SESSION" { $SessionSchema }
                "COMMAND_GRANT" { $GrantSchema }
            }
            foreach ($snapshot in @($target.before, $target.after)) {
                if (-not [bool]$snapshot.exists) {
                    continue
                }
                $snapshotJson = [System.Text.Encoding]::UTF8.GetString(
                    [Convert]::FromBase64String(
                        [string]$snapshot.canonicalJsonBase64
                    )
                )
                Assert-Equal (
                    Get-AiSopWorkflowSha256 $snapshotJson
                ) ([string]$snapshot.sha256) (
                    "Fixture snapshot hash mismatch: $fixtureName"
                )
                Assert-True (
                    $snapshotJson | Test-Json -SchemaFile $targetSchema
                ) "Fixture target snapshot is schema-invalid: $fixtureName"
            }
        }
    }
    foreach ($functionName in @(
        "ConvertTo-AiSopWorkflowCanonicalJson",
        "Get-AiSopWorkflowSha256",
        "Invoke-AiSopWorkflowTransaction",
        "Invoke-AiSopWorkflowTransactionRecovery",
        "Get-AiSopWorkflowTransactionProof"
    )) {
        Assert-True ($null -ne (Get-Command $functionName -ErrorAction SilentlyContinue)) (
            "Transaction API is missing $functionName."
        )
    }

    [System.IO.Directory]::CreateDirectory($TestRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory(
        $env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY
    ) | Out-Null
    $kindMismatchPath = Join-Path (
        $env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY
    ) "fixture-kind-mismatch.json"
    $kindMismatch = ConvertFrom-AiSopWorkflowJson `
        -Json ([System.IO.File]::ReadAllText(
            (Join-Path $transactionFixtureRoot "claim-prepared.json")
        )) `
        -AsHashtable
    $kindMismatch.transactionId = "fixture-kind-mismatch"
    $kindMismatch.targets[0].schemaId = "SESSION"
    [System.IO.File]::WriteAllText(
        $kindMismatchPath,
        ($kindMismatch | ConvertTo-Json -Depth 50),
        $Utf8NoBom
    )
    Assert-ThrowsCode -Code "WORKFLOW_TRANSACTION_CORRUPT" `
        -Message "Journal kind/schema mismatch was trusted." `
        -Action {
            Read-AiSopWorkflowTransactionJournal $kindMismatchPath
        }
    [System.IO.File]::Delete($kindMismatchPath)

    $workerPath = Join-Path $TestRoot "transaction-worker.ps1"
    $workerSource = @'
param(
    [string]$TransactionScript,
    [string]$PayloadPath,
    [string]$PausePoint,
    [string]$MarkerPath
)
$ErrorActionPreference = "Stop"
. $TransactionScript
$payload = Get-Content -LiteralPath $PayloadPath -Raw |
    ConvertFrom-Json -Depth 50
$env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY = $payload.transactionRegistry
$env:SERVER_NEW_WORKFLOW_SESSION_REGISTRY = $payload.sessionRegistry
$env:SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY = $payload.grantRegistry
$env:SERVER_NEW_WORKFLOW_REGISTRY = $payload.ownerRegistry
$env:SERVER_NEW_WORKFLOW_TRANSACTION_PAUSE_POINT = $PausePoint
$env:SERVER_NEW_WORKFLOW_TRANSACTION_PAUSE_MARKER = $MarkerPath
Invoke-AiSopWorkflowTransaction `
    -Operation $payload.operation `
    -Feature $payload.feature `
    -OwnerPath $payload.ownerPath `
    -SessionKeys @($payload.sessionKeys) `
    -Targets @($payload.targets) `
    -TransactionId $payload.transactionId | Out-Null
'@
    [System.IO.File]::WriteAllText($workerPath, $workerSource, $Utf8NoBom)

    $pauseCases = @(
        foreach ($transactionOperation in @(
            "CLAIM",
            "BIND_SESSION",
            "REBIND_SESSION",
            "COMPLETE"
        )) {
            foreach ($pauseDefinition in @(
                [pscustomobject]@{
                    Point = "AFTER_PREPARED"
                    Expected = "BEFORE"
                },
                [pscustomobject]@{
                    Point = "AFTER_TARGET_1"
                    Expected = "BEFORE"
                },
                [pscustomobject]@{
                    Point = "AFTER_TARGET_2"
                    Expected = "BEFORE"
                },
                [pscustomobject]@{
                    Point = "AFTER_TARGET_3"
                    Expected = "AFTER"
                },
                [pscustomobject]@{
                    Point = "BEFORE_COMMITTED"
                    Expected = "AFTER"
                },
                [pscustomobject]@{
                    Point = "AFTER_COMMITTED"
                    Expected = "AFTER"
                }
            )) {
                [pscustomobject]@{
                    Operation = $transactionOperation
                    Point = $pauseDefinition.Point
                    Expected = $pauseDefinition.Expected
                }
            }
        }
    )
    foreach ($case in $pauseCases) {
        foreach ($registryPath in @(
            $env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY,
            $env:SERVER_NEW_WORKFLOW_SESSION_REGISTRY,
            $env:SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY,
            $env:SERVER_NEW_WORKFLOW_REGISTRY
        )) {
            if (Test-Path -LiteralPath $registryPath) {
                [System.IO.Directory]::Delete($registryPath, $true)
            }
        }
        $transactionId = (
            "kill-$($case.Operation.ToLowerInvariant().Replace('_', '-'))-" +
            "$($case.Point.ToLowerInvariant().Replace('_', '-'))"
        )
        $sessionKey = Get-AiSopWorkflowSha256 "session-$transactionId"
        $stateSet = New-BeforeStateSet `
            -CaseRoot (Join-Path $TestRoot $transactionId) `
            -TransactionId $transactionId `
            -SessionKey $sessionKey
        $payloadPath = Join-Path $TestRoot "$transactionId-payload.json"
        $markerPath = Join-Path $TestRoot "$transactionId.marker"
        $payload = [ordered]@{
            transactionRegistry = $env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY
            sessionRegistry = $env:SERVER_NEW_WORKFLOW_SESSION_REGISTRY
            grantRegistry = $env:SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY
            ownerRegistry = $env:SERVER_NEW_WORKFLOW_REGISTRY
            operation = $case.Operation
            feature = "TxFeature"
            ownerPath = $stateSet.OwnerPath
            sessionKeys = @($sessionKey)
            targets = @($stateSet.Targets)
            transactionId = $transactionId
        }
        [System.IO.File]::WriteAllText(
            $payloadPath,
            ($payload | ConvertTo-Json -Depth 50),
            $Utf8NoBom
        )
        $stdoutPath = Join-Path $TestRoot "$transactionId.out"
        $stderrPath = Join-Path $TestRoot "$transactionId.err"
        # Cold-started transaction worker under load needs a wider deadline to
        # reach its pause point; only recovery semantics are under test.
        $env:SERVER_NEW_WORKFLOW_TRANSACTION_DEADLINE_MS = '10000'
        $process = Start-Process `
            -FilePath (Get-Process -Id $PID).Path `
            -WindowStyle Hidden `
            -ArgumentList @(
                "-NoProfile",
                "-File",
                $workerPath,
                "-TransactionScript",
                $TransactionScript,
                "-PayloadPath",
                $payloadPath,
                "-PausePoint",
                $case.Point,
                "-MarkerPath",
                $markerPath
            ) `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -PassThru
        $limit = [DateTimeOffset]::UtcNow.AddSeconds(10)
        while (
            -not (Test-Path -LiteralPath $markerPath) -and
            -not $process.HasExited -and
            [DateTimeOffset]::UtcNow -lt $limit
        ) {
            Start-Sleep -Milliseconds 20
            $process.Refresh()
        }
        if (
            -not (Test-Path -LiteralPath $markerPath) -and
            -not $process.HasExited
        ) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            $process.WaitForExit()
        }
        $workerFailure = ""
        if (
            -not (Test-Path -LiteralPath $markerPath) -and
            (Test-Path -LiteralPath $stderrPath)
        ) {
            $workerFailure = [System.IO.File]::ReadAllText($stderrPath)
        }
        Assert-True (Test-Path -LiteralPath $markerPath) (
            "Strong-kill worker did not reach $($case.Point). $workerFailure"
        )
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit()

        $journalPath = Join-Path (
            $env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY
        ) "$transactionId.json"
        Assert-True (Test-Path -LiteralPath $journalPath -PathType Leaf) (
            "Strong kill at $($case.Point) did not leave a journal."
        )
        $journalRaw = [System.IO.File]::ReadAllText($journalPath)
        Assert-True ($journalRaw | Test-Json -SchemaFile $TransactionSchema) (
            "Strong-kill journal is schema-invalid at $($case.Point)."
        )
        if (
            $case.Operation -eq "CLAIM" -and
            $case.Point -eq "AFTER_COMMITTED"
        ) {
            $committedUnknown = Read-State $stateSet.OwnerPath $OwnerSchema
            $committedUnknown.ownerId = "committed-unknown-content"
            Write-State $stateSet.OwnerPath $committedUnknown
        }

        Invoke-AiSopWorkflowTransactionRecovery | Out-Null
        Assert-StateSet -StateSet $stateSet -Expected $case.Expected
        Assert-True (-not (Test-Path -LiteralPath $journalPath)) (
            "Recovery did not remove resolved journal at $($case.Point)."
        )
        Invoke-AiSopWorkflowTransactionRecovery | Out-Null
        Assert-StateSet -StateSet $stateSet -Expected $case.Expected
    }

    # Exercise the actual Owner CLI target assembly, not transaction labels.
    # Cross-session Rebind has four replacements and is killed after each one.
    foreach ($realOperation in @(
        "Claim",
        "BindSession",
        "RebindSession",
        "Validate",
        "Complete"
    )) {
        $targetCount = if ($realOperation -eq "RebindSession") { 6 } else { 5 }
        $realPoints = @("AFTER_PREPARED")
        for ($targetIndex = 1; $targetIndex -le $targetCount; $targetIndex++) {
            $realPoints += "AFTER_TARGET_$targetIndex"
        }
        $realPoints += @("BEFORE_COMMITTED", "AFTER_COMMITTED")
        foreach ($point in $realPoints) {
            foreach ($registryPath in @(
                $env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY,
                $env:SERVER_NEW_WORKFLOW_SESSION_REGISTRY,
                $env:SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY,
                $env:SERVER_NEW_WORKFLOW_REGISTRY
            )) {
                if (Test-Path -LiteralPath $registryPath) {
                    [System.IO.Directory]::Delete($registryPath, $true)
                }
            }
            $caseName = (
                "$realOperation-$point-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
            )
            $state = New-RealOperationState `
                -Operation $realOperation `
                -CaseName $caseName
            $marker = Join-Path $TestRoot "$caseName.marker"
            $stdout = Join-Path $TestRoot "$caseName.out"
            $stderr = Join-Path $TestRoot "$caseName.err"
            $env:SERVER_NEW_WORKFLOW_TRANSACTION_PAUSE_POINT = $point
            $env:SERVER_NEW_WORKFLOW_TRANSACTION_PAUSE_MARKER = $marker
            # This subprocess is cold-started under CPU contention and must only
            # reach the pause point; the 750ms production deadline is unrelated to
            # recovery semantics under test, so widen it for this launch only.
            $env:SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS = '10000'
            try {
                $process = Start-Process -FilePath (Get-Process -Id $PID).Path `
                    -WindowStyle Hidden `
                    -ArgumentList @(
                        "-NoProfile",
                        "-File",
                        $OwnerScript,
                        "-Operation",
                        $realOperation,
                        "-SpecDirectory",
                        $state.Spec,
                        "-Feature",
                        $state.Feature,
                        "-Workflow",
                        "SUPERPOWERS",
                        "-Agent",
                        "CURSOR",
                        "-OwnerId",
                        $state.OwnerId
                    ) `
                    -RedirectStandardOutput $stdout `
                    -RedirectStandardError $stderr `
                    -PassThru
            } finally {
                Remove-Item Env:SERVER_NEW_WORKFLOW_TRANSACTION_PAUSE_POINT `
                    -ErrorAction SilentlyContinue
                Remove-Item Env:SERVER_NEW_WORKFLOW_TRANSACTION_PAUSE_MARKER `
                    -ErrorAction SilentlyContinue
                Remove-Item Env:SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS `
                    -ErrorAction SilentlyContinue
                Remove-Item Env:SERVER_NEW_WORKFLOW_TRANSACTION_DEADLINE_MS `
                    -ErrorAction SilentlyContinue
            }
            $limit = [DateTimeOffset]::UtcNow.AddSeconds(10)
            while (
                -not (Test-Path -LiteralPath $marker) -and
                -not $process.HasExited -and
                [DateTimeOffset]::UtcNow -lt $limit
            ) {
                Start-Sleep -Milliseconds 10
                $process.Refresh()
            }
            if (-not (Test-Path -LiteralPath $marker)) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                $process.WaitForExit()
                $process.Dispose()
                $failure = if (Test-Path -LiteralPath $stderr) {
                    [System.IO.File]::ReadAllText($stderr)
                } else {
                    ""
                }
                throw "Real $realOperation did not reach $point. $failure"
            }
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            $process.WaitForExit()
            $process.Dispose()
            $journalPaths = @(
                Get-ChildItem -LiteralPath (
                    $env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY
                ) -Filter *.json -File
            )
            Assert-Equal $journalPaths.Count 1 (
                "Real $realOperation at $point left an unexpected journal count."
            )
            $journal = Read-AiSopWorkflowTransactionJournal $journalPaths[0].FullName
            Assert-Equal @($journal.targets).Count $targetCount (
                "Real $realOperation did not assemble $targetCount targets."
            )
            $expected = if (
                $point -in @(
                    "AFTER_TARGET_$targetCount",
                    "BEFORE_COMMITTED",
                    "AFTER_COMMITTED"
                )
            ) {
                "AFTER"
            } else {
                "BEFORE"
            }
            Invoke-AiSopWorkflowTransactionRecovery | Out-Null
            Assert-RealRecoveredJournalState `
                -Journal $journal `
                -Expected $expected
            $findAction = {
                Invoke-AiSopWorkflowCommandGrant `
                    -Operation Find `
                    -GrantOperation $realOperation `
                    -SpecDirectory $state.Spec `
                    -Feature $state.Feature `
                    -Workflow SUPERPOWERS `
                    -Agent CURSOR `
                    -OwnerId $state.OwnerId `
                    -AcceptedAt ([DateTimeOffset]::UtcNow)
            }
            if ($expected -eq "BEFORE") {
                $foundGrant = & $findAction
                Assert-Equal $foundGrant.Record.grantId $state.Grant.Record.grantId (
                    "Real $realOperation $point recovery lost before Find visibility."
                )
            } else {
                Assert-ThrowsCode `
                    -Code "COMMAND_GRANT_NOT_FOUND" `
                    -Message (
                        "Real $realOperation $point recovery retained after Find visibility."
                    ) `
                    -Action $findAction
            }
            Invoke-AiSopWorkflowTransactionRecovery | Out-Null
            Assert-RealRecoveredJournalState `
                -Journal $journal `
                -Expected $expected
        }
    }

    # Unknown content is neither before nor after: retain evidence and fail closed.
    foreach ($registryPath in @(
        $env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY,
        $env:SERVER_NEW_WORKFLOW_SESSION_REGISTRY,
        $env:SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY,
        $env:SERVER_NEW_WORKFLOW_REGISTRY
    )) {
        if (Test-Path -LiteralPath $registryPath) {
            [System.IO.Directory]::Delete($registryPath, $true)
        }
    }
    $unknownTx = "kill-unknown-half-state"
    $unknownSessionKey = Get-AiSopWorkflowSha256 "session-$unknownTx"
    $unknownSet = New-BeforeStateSet `
        -CaseRoot (Join-Path $TestRoot $unknownTx) `
        -TransactionId $unknownTx `
        -SessionKey $unknownSessionKey
    $unknownPayloadPath = Join-Path $TestRoot "$unknownTx-payload.json"
    $unknownMarker = Join-Path $TestRoot "$unknownTx.marker"
    [System.IO.File]::WriteAllText(
        $unknownPayloadPath,
        ([ordered]@{
            transactionRegistry = $env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY
            sessionRegistry = $env:SERVER_NEW_WORKFLOW_SESSION_REGISTRY
            grantRegistry = $env:SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY
            ownerRegistry = $env:SERVER_NEW_WORKFLOW_REGISTRY
            operation = "CLAIM"
            feature = "TxFeature"
            ownerPath = $unknownSet.OwnerPath
            sessionKeys = @($unknownSessionKey)
            targets = @($unknownSet.Targets)
            transactionId = $unknownTx
        } | ConvertTo-Json -Depth 50),
        $Utf8NoBom
    )
    $env:SERVER_NEW_WORKFLOW_TRANSACTION_DEADLINE_MS = '10000'
    $unknownProcess = Start-Process `
        -FilePath (Get-Process -Id $PID).Path `
        -WindowStyle Hidden `
        -ArgumentList @(
            "-NoProfile",
            "-File",
            $workerPath,
            "-TransactionScript",
            $TransactionScript,
            "-PayloadPath",
            $unknownPayloadPath,
            "-PausePoint",
            "AFTER_TARGET_1",
            "-MarkerPath",
            $unknownMarker
        ) `
        -PassThru
    $unknownLimit = [DateTimeOffset]::UtcNow.AddSeconds(10)
    while (
        -not (Test-Path -LiteralPath $unknownMarker) -and
        -not $unknownProcess.HasExited -and
        [DateTimeOffset]::UtcNow -lt $unknownLimit
    ) {
        Start-Sleep -Milliseconds 20
        $unknownProcess.Refresh()
    }
    Assert-True (Test-Path -LiteralPath $unknownMarker) (
        "Unknown-state worker did not reach target replacement."
    )
    Stop-Process -Id $unknownProcess.Id -Force -ErrorAction SilentlyContinue
    $unknownProcess.WaitForExit()
    Remove-Item Env:SERVER_NEW_WORKFLOW_TRANSACTION_DEADLINE_MS `
        -ErrorAction SilentlyContinue
    $unknownOwner = Read-State $unknownSet.OwnerPath $OwnerSchema
    $unknownOwner.ownerId = "externally-corrupted"
    Write-State $unknownSet.OwnerPath $unknownOwner
    Assert-ThrowsCode -Code "WORKFLOW_TRANSACTION_INDETERMINATE" `
        -Message "Unknown half-state did not fail closed." `
        -Action { Invoke-AiSopWorkflowTransactionRecovery }
    Assert-True (
        Test-Path -LiteralPath (
            Join-Path $env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY "$unknownTx.json"
        )
    ) "Unknown half-state journal evidence was deleted."

    # A fresh transaction exposes deterministic sorted session lock order.
    [System.IO.Directory]::Delete(
        $env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY,
        $true
    )
    [System.IO.Directory]::Delete($env:SERVER_NEW_WORKFLOW_SESSION_REGISTRY, $true)
    [System.IO.Directory]::Delete(
        $env:SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY,
        $true
    )
    [System.IO.Directory]::Delete($env:SERVER_NEW_WORKFLOW_REGISTRY, $true)
    $sortedTx = "sorted-lock-order"
    $keyA = Get-AiSopWorkflowSha256 "A-session"
    $keyB = Get-AiSopWorkflowSha256 "B-session"
    $sortedSet = New-BeforeStateSet `
        -CaseRoot (Join-Path $TestRoot $sortedTx) `
        -TransactionId $sortedTx `
        -SessionKey $keyA
    $result = Invoke-AiSopWorkflowTransaction `
        -Operation CLAIM `
        -Feature TxFeature `
        -OwnerPath $sortedSet.OwnerPath `
        -SessionKeys @($keyB, $keyA, $keyB) `
        -Targets $sortedSet.Targets `
        -TransactionId $sortedTx
    Assert-Equal $result.SessionLockOrder.Count 2 (
        "Session lock order did not de-duplicate keys."
    )
    Assert-Equal $result.SessionLockOrder[0] (
        @($keyA, $keyB | Sort-Object)[0]
    ) "Session locks were not acquired in ordinal order."
    Assert-StateSet -StateSet $sortedSet -Expected AFTER
    Assert-Equal (
        Get-AiSopWorkflowTransactionProof -TransactionId $sortedTx
    ) "APPLIED" "Committed transaction proof was not discoverable."

    Write-Output "All workflow transaction tests passed."
} finally {
    foreach ($name in @(
        "SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY",
        "SERVER_NEW_WORKFLOW_SESSION_REGISTRY",
        "SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY",
        "SERVER_NEW_WORKFLOW_REGISTRY",
        "SERVER_NEW_WORKFLOW_TRANSACTION_PAUSE_POINT",
        "SERVER_NEW_WORKFLOW_TRANSACTION_PAUSE_MARKER"
    )) {
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $TestRoot) {
        [System.IO.Directory]::Delete($TestRoot, $true)
    }
}
