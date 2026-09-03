#requires -Version 7.0

# Feature State (cross-tool handoff) manager.
# Stores lightweight runtime progress so a feature can resume in a different
# AI tool without chat history. Complements 00_workflow_state.json (gate
# approval state) with execution progress: tier/phase/completed/next/verify.
#
# Usage:
#   pwsh -NoProfile -File ./.ai-sop/scripts/feature-state.ps1 -Operation Get -Feature <Name> -SpecDirectory <dir>
#   pwsh -NoProfile -File ./.ai-sop/scripts/feature-state.ps1 -Operation Set -Feature <Name> -SpecDirectory <dir> -Phase IMPLEMENTING -Tier T2 -NextAction "run tests" -AppendStep "compiled"

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet("Get", "Set", "Clear")] [string]$Operation,
    [Parameter(Mandatory)] [string]$Feature,
    [Parameter(Mandatory)] [string]$SpecDirectory,
    [ValidateSet("T1", "T2", "T3", "FAST_TRACK")] [string]$Tier = "",
    [ValidateSet("DUAL", "DESIGN_ONLY", "")] [string]$GateMode = "",
    [ValidateSet(
        "INTENT",
        "CLAIMED",
        "REQUIREMENT_DRAFT",
        "REQUIREMENT_APPROVED",
        "DESIGN_DRAFT",
        "DESIGN_REVIEWED",
        "DESIGN_APPROVED",
        "PLANNING",
        "IMPLEMENTING",
        "IMPLEMENTATION_DONE",
        "AUDITED",
        "QA_VERIFIED",
        "READY_TO_DELIVER",
        "DELIVERED",
        "DONE",
        "COMPLETED",
        "BLOCKED",
        ""
    )]
    [string]$Phase = "",
    [string]$NextAction = "",
    [string]$AppendStep = "",
    [ValidateSet("PASS", "FAIL", "SKIPPED", "")] [string]$VerifyResult = "",
    [string]$VerifyCommand = "",
    [string]$Agent = "",
    [string]$OwnerId = "",
    [string]$Notes = ""
)

$ErrorActionPreference = "Stop"
$SchemaRoot = Join-Path (Split-Path -Parent $PSScriptRoot) "schemas"
$SchemaPath = Join-Path $SchemaRoot "feature-state.schema.json"
$StatePath = Join-Path $SpecDirectory "feature-state.json"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Read-State {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return $null }
    return Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -AsHashtable
}

function Write-State {
    param([hashtable]$State)
    $json = $State | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($StatePath, $json, $Utf8NoBom)
}

switch ($Operation) {
    "Get" {
        $s = Read-State
        if ($null -eq $s) {
            Write-Output "NO_STATE: feature-state.json does not exist at $StatePath"
        } else {
            $tierDisplay = if ($s.gateMode -eq "DESIGN_ONLY") { "$($s.tier) (DESIGN_ONLY)" } else { [string]$s.tier }
            Write-Output "feature=$($s.feature) tier=$tierDisplay phase=$($s.phase)"
            Write-Output "updatedAt=$($s.updatedAt)"
            if ($s.ownerSession) { Write-Output "owner=$($s.ownerSession.agent)/$($s.ownerSession.ownerId)" }
            if ($s.completedSteps) { Write-Output "completed=$($s.completedSteps -join ', ')" }
            if ($s.nextAction) { Write-Output "nextAction=$($s.nextAction)" }
            if ($s.lastVerification -and $s.lastVerification.result) { Write-Output "lastVerify=$($s.lastVerification.result)" }
            Write-Output "DIAGNOSTIC: use this to resume work in any AI tool without chat history."
        }
    }
    "Set" {
        $s = Read-State
        if ($null -eq $s) {
            $inheritedGateMode = $GateMode
            if (-not $inheritedGateMode) {
                $approvalPath = Join-Path $SpecDirectory "00_workflow_state.json"
                if (Test-Path -LiteralPath $approvalPath -PathType Leaf) {
                    try {
                        $st = Get-Content -LiteralPath $approvalPath -Raw | ConvertFrom-Json
                        if ($st.gateMode) { $inheritedGateMode = [string]$st.gateMode }
                    } catch {}
                }
            }
            $s = [ordered]@{
                schemaVersion = "1.0"
                feature = $Feature
                tier = if ($Tier) { $Tier } else { "T2" }
                phase = if ($Phase) { $Phase } else { "INTENT" }
                ownerSession = @{}
                completedSteps = @()
                nextAction = ""
                lastVerification = @{}
                updatedAt = [DateTimeOffset]::UtcNow.ToString("o")
                notes = ""
            }
            if ($inheritedGateMode) { $s["gateMode"] = $inheritedGateMode }
        } else {
            if ($Tier) { $s.tier = $Tier }
            if ($Phase) { $s.phase = $Phase }
            if ($GateMode) {
                $s["gateMode"] = $GateMode
            } elseif (-not $s.ContainsKey("gateMode") -or [string]::IsNullOrWhiteSpace($s.gateMode)) {
                $approvalPath = Join-Path $SpecDirectory "00_workflow_state.json"
                if (Test-Path -LiteralPath $approvalPath -PathType Leaf) {
                    try {
                        $st = Get-Content -LiteralPath $approvalPath -Raw | ConvertFrom-Json
                        if ($st.gateMode) { $s["gateMode"] = [string]$st.gateMode }
                    } catch {}
                }
            }
            if ($Agent -or $OwnerId) {
                if (-not $s.ContainsKey("ownerSession")) { $s["ownerSession"] = @{} }
                if ($Agent) { $s.ownerSession.agent = $Agent }
                if ($OwnerId) { $s.ownerSession.ownerId = $OwnerId }
            }
            if ($AppendStep) {
                if (-not $s.ContainsKey("completedSteps")) { $s["completedSteps"] = @() }
                $s.completedSteps = @($s.completedSteps) + $AppendStep
            }
            if ($NextAction) { $s.nextAction = $NextAction }
            if ($VerifyResult) {
                if (-not $s.ContainsKey("lastVerification")) { $s["lastVerification"] = @{} }
                $s.lastVerification = @{ result = $VerifyResult; command = $VerifyCommand; at = [DateTimeOffset]::UtcNow.ToString("o") }
            }
            if ($Notes) { $s.notes = $Notes }
            $s.updatedAt = [DateTimeOffset]::UtcNow.ToString("o")
        }
        Write-State $s
        Write-Output "feature-state.json updated at $StatePath"
    }
    "Clear" {
        if (Test-Path -LiteralPath $StatePath) { Remove-Item -LiteralPath $StatePath -Force; Write-Output "cleared $StatePath" }
        else { Write-Output "nothing to clear" }
    }
}
