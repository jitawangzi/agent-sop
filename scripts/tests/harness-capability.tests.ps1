#requires -Version 7.0
# Harness capability probe + admission tests (DC-006).

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$ScriptsRoot = Split-Path -Parent $PSScriptRoot
$CapabilityScript = Join-Path $ScriptsRoot "harness-capability.ps1"
$SchemaPath = Join-Path (Split-Path -Parent $ScriptsRoot) "schemas\harness-capability.schema.json"

foreach ($required in @($CapabilityScript, $SchemaPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required HarnessCapability artifact missing: $required"
    }
}

. $CapabilityScript

$PassCount = 0
$FailCount = 0
function Assert-Equal {
    param($E, $A, [string]$M)
    if (-not ($E -ceq $A)) { throw "ASSERT: $M`nExpected:$E`nActual:$A" }
}
function Assert-True {
    param([bool]$C, [string]$M)
    if (-not $C) { throw "ASSERT: $M" }
}
function Invoke-Test {
    param([string]$N, [scriptblock]$B)
    try {
        & $B
        $script:PassCount++
        Write-Host "  PASS  $N" -ForegroundColor Green
    } catch {
        $script:FailCount++
        Write-Host "  FAIL  $N" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
    }
}

Invoke-Test "Claude Code CLI -> STRICT" {
    $r = New-AiSopHarnessCapabilityRecord -A "CLAUDE_CODE" -R "CLI" -Ver "2.1" -OsVal "Windows" -Pwsh "7.4"
    Assert-Equal "STRICT" $r.decision "decision"
    Assert-True ($r.decisionReason -match "all critical") "reason"
}

Invoke-Test "Pi CLI -> BLOCKED (no subagent/evidence)" {
    $r = New-AiSopHarnessCapabilityRecord -A "PI" -R "CLI" -Ver "1.0" -OsVal "Windows" -Pwsh "7.4"
    Assert-Equal "BLOCKED" $r.decision "decision"
    Assert-True ($r.decisionReason -match "evidence") "reason must mention evidence"
    Assert-True ($r.capabilities.subagent -eq $false) "subagent false"
}

Invoke-Test "Cursor CLI -> STRICT" {
    $r = New-AiSopHarnessCapabilityRecord -A "CURSOR" -R "CLI" -Ver "0.42" -OsVal "Windows" -Pwsh "7.4"
    Assert-Equal "STRICT" $r.decision "decision"
}

Invoke-Test "Copilot CLI -> STRICT (subagent+evidence confirmed for T3 review)" {
    $r = New-AiSopHarnessCapabilityRecord -A "COPILOT" -R "CLI" -Ver "1.0.80" -OsVal "Windows" -Pwsh "7.4"
    Assert-Equal "STRICT" $r.decision "decision"
    Assert-True ($r.decisionReason -match "subagent|evidence|all critical") "reason"
}

Invoke-Test "Unknown agent -> BLOCKED + reason" {
    $r = New-AiSopHarnessCapabilityRecord -A "UNKNOWN_TOOL" -R "CLI" -Ver "" -OsVal "" -Pwsh ""
    Assert-Equal "BLOCKED" $r.decision "decision"
    Assert-True ($r.decisionReason -match "unknown") "reason unknown"
}

Invoke-Test "Unknown runtime (CLAUDE_CODE/CLOUD) -> BLOCKED" {
    $r = New-AiSopHarnessCapabilityRecord -A "CLAUDE_CODE" -R "CLOUD" -Ver "" -OsVal "" -Pwsh ""
    Assert-Equal "BLOCKED" $r.decision "decision"
    Assert-True ($r.decisionReason -match "unknown") "reason unknown runtime"
}

Invoke-Test "Test-AiSopHarnessCapability STRICT when all critical true" {
    $caps = [ordered]@{ skillDiscovery=$true; subagent=$true; blockingHook=$true; workspace=$true; pauseResume=$false; evidence=$true }
    $d = Test-AiSopHarnessCapability -Capabilities $caps
    Assert-Equal "STRICT" $d.Decision "decision (subagent+evidence critical; pauseResume non-critical)"
}

Invoke-Test "Test-AiSopHarnessCapability BLOCKED when subagent false" {
    $caps = [ordered]@{ skillDiscovery=$true; subagent=$false; blockingHook=$true; workspace=$true; pauseResume=$true; evidence=$true }
    $d = Test-AiSopHarnessCapability -Capabilities $caps
    Assert-Equal "BLOCKED" $d.Decision "decision"
    Assert-True ($d.Reason -match "subagent") "reason lists subagent"
}

Invoke-Test "Full probe output is schema-valid (All)" {
    $out = & $CapabilityScript -All -ProductVersion "test" -Os "Windows" -PwshVersion "7.4"
    $json = ($out -join "`n")
    $json | Test-Json -SchemaFile $SchemaPath | Out-Null
    $obj = $json | ConvertFrom-Json
    Assert-Equal 5 @($obj.harnesses).Count "5 harness records"
}

Invoke-Test "releaseDecision MIXED when some STRICT some BLOCKED" {
    $out = & $CapabilityScript -All -ProductVersion "test" -Os "Windows" -PwshVersion "7.4" | ConvertFrom-Json
    Assert-True (@($out.harnesses | Where-Object {$_.decision -eq "STRICT"}).Count -gt 0) "has STRICT"
    Assert-True (@($out.harnesses | Where-Object {$_.decision -eq "BLOCKED"}).Count -gt 0) "has BLOCKED"
    Assert-Equal "MIXED" $out.releaseDecision "releaseDecision"
}

Invoke-Test "Local override downgrades CLAUDE_CODE subagent -> BLOCKED" {
    # Redirect $ClaudeRoot to a temp dir so the override file does not pollute the
    # real .ai-sop source. The override mechanism merges per-machine capability
    # downgrades onto the static table (gitignored, never shared).
    $origClaudeRoot = $ClaudeRoot
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cap-override-" + [guid]::NewGuid().ToString("N"))
    [System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    try {
        $script:ClaudeRoot = $tempRoot
        $overridePath = Join-Path $tempRoot ".harness-capability-override.json"
        $overrideJson = '{"CLAUDE_CODE":{"subagent":false,"_reason":"this build subagent broken"}}'
        [System.IO.File]::WriteAllText($overridePath, $overrideJson, [System.Text.UTF8Encoding]::new($false))
        $r = New-AiSopHarnessCapabilityRecord -A "CLAUDE_CODE" -R "CLI" -Ver "2.1" -OsVal "Windows" -Pwsh "7.4"
        Assert-Equal "BLOCKED" $r.decision "override must downgrade CLAUDE_CODE to BLOCKED"
        Assert-True ($r.capabilities.subagent -eq $false) "subagent overridden to false"
        Assert-True ($r.evidence.note -match "LOCAL OVERRIDE") "evidence.note must flag the override"
        Assert-True ($r.evidence.note -match "subagent=False") "note must list the changed capability"
    } finally {
        $script:ClaudeRoot = $origClaudeRoot
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "Local override absent -> static table unchanged" {
    $origClaudeRoot = $ClaudeRoot
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cap-nooverride-" + [guid]::NewGuid().ToString("N"))
    [System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    try {
        $script:ClaudeRoot = $tempRoot  # no override file present
        $r = New-AiSopHarnessCapabilityRecord -A "CLAUDE_CODE" -R "CLI" -Ver "2.1" -OsVal "Windows" -Pwsh "7.4"
        Assert-Equal "STRICT" $r.decision "no override -> static STRICT preserved"
        Assert-True (-not ($r.evidence.note -match "OVERRIDE")) "no override note when file absent"
    } finally {
        $script:ClaudeRoot = $origClaudeRoot
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "Local override cannot upgrade PI subagent -> stays BLOCKED" {
    $origClaudeRoot = $ClaudeRoot
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cap-upgrade-" + [guid]::NewGuid().ToString("N"))
    [System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    try {
        $script:ClaudeRoot = $tempRoot
        $overridePath = Join-Path $tempRoot ".harness-capability-override.json"
        $overrideJson = '{"PI":{"subagent":true,"_reason":"attempted upgrade"}}'
        [System.IO.File]::WriteAllText($overridePath, $overrideJson, [System.Text.UTF8Encoding]::new($false))
        $r = New-AiSopHarnessCapabilityRecord -A "PI" -R "CLI" -Ver "1.0" -OsVal "Windows" -Pwsh "7.4"
        Assert-Equal "BLOCKED" $r.decision "override must not upgrade PI to STRICT"
        Assert-True ($r.capabilities.subagent -eq $false) "PI subagent stays false"
        Assert-True (-not ($r.evidence.note -match "LOCAL OVERRIDE applied")) "upgrade-only override must not apply"
    } finally {
        $script:ClaudeRoot = $origClaudeRoot
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host ("{0} capability tests passed, {1} failed" -f $script:PassCount, $script:FailCount) -ForegroundColor Cyan
if ($script:FailCount -gt 0) { exit 1 } else { exit 0 }
