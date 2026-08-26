#requires -Version 7.0

# End-to-End Smoke Test: T2 Fast-Track Flow (workflow-state chain)
#
# Tests what unit tests cannot: the full chain of workflow-state operations a
# real T2 session performs, verifying the *linkage* between steps (not just
# each step in isolation). Unit tests verify individual operations (Approve
# alone, Status alone); this test verifies they compose into a real session:
#
#   InitApproval -> Approve(requirement) -> Approve(design) -> Status ->
#   UpdateHash(cosmetic) -> Status(drift fixed) -> ValidateApproval ->
#   WriteCoverage -> ValidateTestCoverage -> ResetApproval -> re-Approve
#
# This catches issues like "UpdateHash leaves the state inconsistent for
# ValidateApproval" or "Status reports MATCH but ValidateApproval still throws"
# — linkage bugs that single-operation tests miss.
#
# Ownership is written directly (Write-Owner11 pattern) to focus on the
# workflow-state chain; grant/session mechanics are covered by workflow-owner.tests.

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$ScriptsRoot = Split-Path -Parent $PSScriptRoot
$StateScript = Join-Path $ScriptsRoot "workflow-state.ps1"
$OwnerScript = Join-Path $ScriptsRoot "workflow-owner.ps1"
$SessionScript = Join-Path $ScriptsRoot "workflow-session.ps1"
$GrantScript = Join-Path $ScriptsRoot "workflow-command-grant.ps1"
$ClaudeRoot = Split-Path -Parent $ScriptsRoot
$SchemaRoot = Join-Path $ClaudeRoot "schemas"
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "e2e-smoke-" + [guid]::NewGuid().ToString("N")
)
$env:SERVER_NEW_WORKFLOW_REGISTRY = Join-Path $TestRoot "owners"
$env:SERVER_NEW_WORKFLOW_SESSION_REGISTRY = Join-Path $TestRoot "sessions"
$env:SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY = Join-Path $TestRoot "grants"
$env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY = Join-Path $TestRoot "transactions"
$env:SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS = "30000"
$env:SERVER_NEW_WORKFLOW_TRANSACTION_DEADLINE_MS = "30000"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

. $SessionScript
. $GrantScript

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -cne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Get-TestArtifactHash {
    param([string]$Path)
    $ext = [System.IO.Path]::GetExtension($Path)
    if ($ext -ieq ".json") {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $raw = [System.IO.File]::ReadAllText($Path)
    $normalized = $raw -replace "`r`n", "`n"
    $normalized = $normalized -replace "`r", "`n"
    $normalized = $normalized -replace "[ \t]+`n", "`n"
    $normalized = $normalized.TrimEnd() + "`n"
    $enc = [System.Text.UTF8Encoding]::new($false)
    $bytes = $enc.GetBytes($normalized)
    return (Get-FileHash -InputStream ([System.IO.MemoryStream]::new($bytes)) -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-OwnerDirect {
    # Write a 1.1 SUPERPOWERS owner directly (bypasses grant mechanics).
    param([string]$Feature, [string]$SpecDir, [string]$OwnerId, [string]$SessionKey, [string]$SessionEpochId)
    [System.IO.Directory]::CreateDirectory($env:SERVER_NEW_WORKFLOW_REGISTRY) | Out-Null
    $owner = [ordered]@{
        schemaVersion = "1.1"
        feature = $Feature
        workflow = "SUPERPOWERS"
        agent = "CLAUDE_CODE"
        ownerId = $OwnerId
        specDirectory = [System.IO.Path]::GetFullPath($SpecDir)
        workspacePath = [System.IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $SpecDir)))))
        status = "ACTIVE"
        startedAt = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString("o")
        completedAt = ""
        sessionBinding = [ordered]@{
            sessionKey = $SessionKey
            sessionEpochId = $SessionEpochId
            boundAt = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString("o")
        }
        lastTransactionId = "e2e-direct"
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $env:SERVER_NEW_WORKFLOW_REGISTRY ($Feature.ToLowerInvariant() + ".json")),
        ($owner | ConvertTo-Json -Depth 30), $Utf8NoBom
    )
}

try {
    $featureName = "E2ET2Smoke"
    $specDir = Join-Path $TestRoot ".ai-workspace\specs\features\$featureName"
    $approvalPath = Join-Path $specDir "00_workflow_state.json"
    $requirementPath = Join-Path $specDir "01_server_rules.md"
    $designPath = Join-Path $specDir "06_design_contract.md"
    $coveragePath = Join-Path $specDir "05_test_coverage.json"
    [System.IO.Directory]::CreateDirectory($specDir) | Out-Null
    # Create the workspace structure the scripts expect (.ai-sop/scripts under workspace).
    $workspaceDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $specDir)))
    [System.IO.Directory]::CreateDirectory((Join-Path $workspaceDir ".ai-sop\scripts")) | Out-Null
    $ownerId = "e2e-smoke-owner"

    Write-Host "Step 1: Write owner (direct, bypass grant)" -ForegroundColor Cyan
    # Register a real session so workflow-state can read it.
    $session = Invoke-AiSopWorkflowSession -Operation Register -Agent CLAUDE_CODE `
        -NativeSessionId "e2e-native" -WorkspacePath $workspaceDir `
        -LifecycleProof CONFIRMED -AcceptedAt ([DateTimeOffset]::UtcNow)
    $sessionKey = $session.Record.sessionKey
    $sessionEpochId = $session.Record.sessionEpochId
    # Bind the session to this feature/owner (normally done by Claim).
    $sessionRecord = Get-Content -LiteralPath $session.SessionPath -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    $sessionRecord.boundFeature = $featureName
    $sessionRecord.boundWorkflow = "SUPERPOWERS"
    $sessionRecord.boundOwnerId = $ownerId
    $sessionRecord.boundSessionEpochId = $sessionEpochId
    $sessionRecord.status = "ACTIVE"
    $sessionRecord.lifecycleProof = "CONFIRMED"
    [System.IO.File]::WriteAllText($session.SessionPath, ($sessionRecord | ConvertTo-Json -Depth 30), $Utf8NoBom)
    Write-OwnerDirect -Feature $featureName -SpecDir $specDir -OwnerId $ownerId -SessionKey $sessionKey -SessionEpochId $sessionEpochId
    Write-Host "  session record:"
    $sr = Get-Content -LiteralPath $session.SessionPath -Raw | ConvertFrom-Json
    Write-Host "    status=$($sr.status) agent=$($sr.agent) lifecycleProof=$($sr.lifecycleProof)"
    Write-Host "    boundFeature=$($sr.boundFeature) boundWorkflow=$($sr.boundWorkflow) boundOwnerId=$($sr.boundOwnerId) boundSessionEpochId=$($sr.boundSessionEpochId)"
    Write-Host "    sessionEpochId=$($sr.sessionEpochId) workspacePath=$($sr.workspacePath)"
    Write-Host "    expiresAt=$($sr.expiresAt) now=$([DateTimeOffset]::UtcNow.ToString('o'))"
    Assert-True (Test-Path -LiteralPath (Join-Path $env:SERVER_NEW_WORKFLOW_REGISTRY "$($featureName.ToLowerInvariant()).json")) `
        "Owner file should exist."

    Write-Host "Step 2: InitApproval" -ForegroundColor Cyan
    & $StateScript -Operation InitApproval -Path $approvalPath -Feature $featureName `
        -OwnerWorkflow SUPERPOWERS -OwnerAgent CLAUDE_CODE -OwnerId $ownerId | Out-Null
    $state = Get-Content -LiteralPath $approvalPath -Raw | ConvertFrom-Json
    Assert-Equal $state.requirement.status "DRAFT" "Requirement should start DRAFT."
    Assert-Equal $state.design.status "DRAFT" "Design should start DRAFT."

    Write-Host "Step 3: Write requirement + Approve(requirement)" -ForegroundColor Cyan
    [System.IO.File]::WriteAllText($requirementPath, "# Rules`n- BR-1 T2 smoke requirement", $Utf8NoBom)
    & $StateScript -Operation Approve -Path $approvalPath -Gate requirement `
        -ApprovedBy "human:e2e" -OwnerWorkflow SUPERPOWERS -OwnerAgent CLAUDE_CODE -OwnerId $ownerId | Out-Null
    $state = Get-Content -LiteralPath $approvalPath -Raw | ConvertFrom-Json
    Assert-Equal $state.requirement.status "APPROVED" "Requirement should be APPROVED."

    Write-Host "Step 4: Write design + Approve(design) — T2 skips design-reviewer" -ForegroundColor Cyan
    [System.IO.File]::WriteAllText($designPath, "# Design`n- DC-1 T2 smoke design", $Utf8NoBom)
    & $StateScript -Operation Approve -Path $approvalPath -Gate design `
        -ApprovedBy "human:e2e" -OwnerWorkflow SUPERPOWERS -OwnerAgent CLAUDE_CODE -OwnerId $ownerId | Out-Null
    $state = Get-Content -LiteralPath $approvalPath -Raw | ConvertFrom-Json
    Assert-Equal $state.design.status "APPROVED" "Design should be APPROVED."

    Write-Host "Step 5: Status (linkage: both APPROVED, hashes MATCH)" -ForegroundColor Cyan
    $status = & $StateScript -Operation Status -Path $approvalPath 2>&1 | Out-String
    Assert-True ($status -match "gate=requirement status=APPROVED") "Status req APPROVED: $status"
    Assert-True ($status -match "gate=design status=APPROVED") "Status design APPROVED: $status"
    Assert-True ($status -match "hashMatch=MATCH") "Status should show MATCH: $status"

    Write-Host "Step 6: Drift artifact + ValidateApproval should FAIL (linkage)" -ForegroundColor Cyan
    [System.IO.File]::AppendAllText($requirementPath, "`n- BR-2 added", $Utf8NoBom)
    $driftStatus = & $StateScript -Operation Status -Path $approvalPath 2>&1 | Out-String
    Assert-True ($driftStatus -match "hashMatch=DRIFT") "After artifact change, Status should show DRIFT: $driftStatus"
    $validateFailed = $false
    try {
        & $StateScript -Operation ValidateApproval -Path $approvalPath 2>&1 | Out-Null
    } catch {
        $validateFailed = $true
    }
    Assert-True $validateFailed "ValidateApproval must fail when artifact drifted (hashMatch=DRIFT)."

    Write-Host "Step 7: UpdateHash (cosmetic) restores MATCH, approval preserved" -ForegroundColor Cyan
    & $StateScript -Operation UpdateHash -Path $approvalPath -Gate requirement `
        -OwnerWorkflow SUPERPOWERS -OwnerAgent CLAUDE_CODE -OwnerId $ownerId | Out-Null
    $afterUpdate = & $StateScript -Operation Status -Path $approvalPath 2>&1 | Out-String
    Assert-True ($afterUpdate -match "gate=requirement status=APPROVED") "UpdateHash must keep APPROVED: $afterUpdate"
    Assert-True ($afterUpdate -match "hashMatch=MATCH") "UpdateHash must restore MATCH: $afterUpdate"
    & $StateScript -Operation ValidateApproval -Path $approvalPath | Out-Null

    Write-Host "Step 8: ValidateTestCoverage (coverage linkage)" -ForegroundColor Cyan
    # Test plan artifact must exist for coverage validation.
    [System.IO.File]::WriteAllText((Join-Path $specDir "05_test_plan.md"), "# Test Plan`n- TC-E2E-1`n- TC-E2E-2", $Utf8NoBom)
    $reqSha = (Get-TestArtifactHash -Path $requirementPath)
    $desSha = (Get-TestArtifactHash -Path $designPath)
    $tpSha = (Get-TestArtifactHash -Path (Join-Path $specDir "05_test_plan.md"))
    $coverage = [ordered]@{
        schemaVersion = "1.0"
        feature = $featureName
        requirementArtifact = "01_server_rules.md"
        requirementSha256 = $reqSha
        designArtifact = "06_design_contract.md"
        designSha256 = $desSha
        testPlanArtifact = "05_test_plan.md"
        testPlanSha256 = $tpSha
        cases = @(
            [ordered]@{
                id = "TC-E2E-1"; title = "E2E smoke TC1"; priority = "P1"; status = "PLANNED"
                testTypes = @("FUNCTIONAL")
                requirementIds = @("BR-1"); designIds = @("DC-1")
                setup = @("none"); trigger = @("run"); cleanup = @("none")
                automationCarrier = "JUnit"
                assertions = [ordered]@{ protocol = @(@{ target = "resp"; operator = "EQ"; expected = "ok" }); serverState = @(@{ target = "state"; operator = "EQ"; expected = "ok" }); sideEffects = @(@{ target = "none"; operator = "EMPTY"; expected = "" }); regression = @(@{ target = "none"; operator = "EMPTY"; expected = "" }) }
            }
            [ordered]@{
                id = "TC-E2E-2"; title = "E2E smoke TC2"; priority = "P1"; status = "PLANNED"
                testTypes = @("FUNCTIONAL")
                requirementIds = @("BR-2"); designIds = @("DC-1")
                setup = @("none"); trigger = @("run"); cleanup = @("none")
                automationCarrier = "JUnit"
                assertions = [ordered]@{ protocol = @(@{ target = "resp"; operator = "EQ"; expected = "ok" }); serverState = @(@{ target = "state"; operator = "EQ"; expected = "ok" }); sideEffects = @(@{ target = "none"; operator = "EMPTY"; expected = "" }); regression = @(@{ target = "none"; operator = "EMPTY"; expected = "" }) }
            }
        )
        riskExemptions = @()
    }
    [System.IO.File]::WriteAllText($coveragePath, ($coverage | ConvertTo-Json -Depth 10), $Utf8NoBom)
    & $StateScript -Operation ValidateTestCoverage -Path $coveragePath | Out-Null

    Write-Host "Step 9: ResetApproval(requirement) cascades to design (linkage)" -ForegroundColor Cyan
    & $StateScript -Operation ResetApproval -Path $approvalPath -Gate requirement `
        -OwnerWorkflow SUPERPOWERS -OwnerAgent CLAUDE_CODE -OwnerId $ownerId | Out-Null
    $afterReset = Get-Content -LiteralPath $approvalPath -Raw | ConvertFrom-Json
    Assert-Equal $afterReset.requirement.status "DRAFT" "Reset(requirement) should make requirement DRAFT."
    Assert-Equal $afterReset.design.status "DRAFT" "Reset(requirement) should cascade to design DRAFT."

    Write-Host "Step 10: Re-approve both (full cycle)" -ForegroundColor Cyan
    & $StateScript -Operation Approve -Path $approvalPath -Gate requirement `
        -ApprovedBy "human:e2e-re" -OwnerWorkflow SUPERPOWERS -OwnerAgent CLAUDE_CODE -OwnerId $ownerId | Out-Null
    & $StateScript -Operation Approve -Path $approvalPath -Gate design `
        -ApprovedBy "human:e2e-re" -OwnerWorkflow SUPERPOWERS -OwnerAgent CLAUDE_CODE -OwnerId $ownerId | Out-Null
    & $StateScript -Operation ValidateApproval -Path $approvalPath | Out-Null
    $finalStatus = & $StateScript -Operation Status -Path $approvalPath 2>&1 | Out-String
    Assert-True ($finalStatus -match "gate=requirement status=APPROVED") "Final req APPROVED: $finalStatus"
    Assert-True ($finalStatus -match "gate=design status=APPROVED") "Final design APPROVED: $finalStatus"
    Assert-True ($finalStatus -match "hashMatch=MATCH") "Final should be MATCH: $finalStatus"

    Write-Host "All E2E T2 smoke tests passed (10 steps, full workflow-state chain verified)." -ForegroundColor Green
} catch {
    Write-Host "E2E SMOKE FAILURE: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    exit 1
} finally {
    foreach ($name in @(
        "SERVER_NEW_WORKFLOW_REGISTRY", "SERVER_NEW_WORKFLOW_SESSION_REGISTRY",
        "SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY",
        "SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY",
        "SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS",
        "SERVER_NEW_WORKFLOW_TRANSACTION_DEADLINE_MS"
    )) {
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $TestRoot) {
        [System.IO.Directory]::Delete($TestRoot, $true)
    }
}
