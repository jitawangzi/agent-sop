#requires -Version 7.0

# Document-Script Contract Tests
#
# Parses command examples from AGENTS.md (the single source of truth that AI
# tools load) and verifies they match the actual PowerShell script parameters.
# Catches drift like: doc says `-NewAgent` but script param is `-Agent`.
# Catches: doc references an Operation the script doesn't support (or vice
# versa for documented operations).

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$SopRoot = Split-Path -Parent $PSScriptRoot
$SopRoot = Split-Path -Parent $SopRoot  # scripts/ -> .ai-sop/
$AgentsMd = Join-Path $SopRoot "distribution/templates/root/AGENTS.md"
$WorkflowStateScript = Join-Path $SopRoot "scripts/workflow-state.ps1"
$WorkflowOwnerScript = Join-Path $SopRoot "scripts/workflow-owner.ps1"

function Get-ScriptOperations {
    param([string]$ScriptPath, [string]$ParamName)
    # Extract ValidateSet values for the $Operation parameter.
    $content = Get-Content -LiteralPath $ScriptPath -Raw
    # Find the ValidateSet block following $Operation param.
    $pattern = '(?s)\[ValidateSet\(\s*((?:"[^"]+",?\s*)+)\s*\)\]\s*\[string\]\$Operation'
    $match = [regex]::Match($content, $pattern)
    if (-not $match.Success) {
        throw "Could not find Operation ValidateSet in $ScriptPath"
    }
    $ops = [regex]::Matches($match.Groups[1].Value, '"([^"]+)"') |
        ForEach-Object { $_.Groups[1].Value }
    return [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$ops,
        [System.StringComparer]::OrdinalIgnoreCase
    )
}

function Get-ScriptParams {
    param([string]$ScriptPath)
    # Extract all parameter names the script accepts.
    $content = Get-Content -LiteralPath $ScriptPath -Raw
    $params = [regex]::Matches($content, '\[\w+(?:\(\))?\]\s*\$([A-Za-z]+)') |
        ForEach-Object { $_.Groups[1].Value }
    return [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$params,
        [System.StringComparer]::OrdinalIgnoreCase
    )
}

function Get-DocCommands {
    param([string]$DocPath)
    # Parse AGENTS.md for workflow-state.ps1 / workflow-owner.ps1 command examples.
    # Captures: script name, -Operation value, and any -ParamName tokens.
    $content = Get-Content -LiteralPath $DocPath -Raw
    $commands = [System.Collections.Generic.List[pscustomobject]]::new()
    $pattern = '(?m)(workflow-(?:state|owner)\.ps1)\s+(?:-NoProfile\s+)?-Operation\s+(\w+)([^`\n]*?)(?:`|$)'
    foreach ($m in [regex]::Matches($content, $pattern)) {
        $script = $m.Groups[1].Value
        $op = $m.Groups[2].Value
        $rest = $m.Groups[3].Value
        $params = [regex]::Matches($rest, '(?<=\s)-([A-Za-z]+)') |
            ForEach-Object { $_.Groups[1].Value } |
            Where-Object { $_ -ne "NoProfile" -and $_ -ne "File" -and $_ -ne "Operation" }
        $commands.Add([pscustomobject]@{
            Script = $script
            Operation = $op
            Params = [string[]]$params
            Raw = $m.Value
        })
    }
    return $commands
}

$failures = [System.Collections.Generic.List[string]]::new()
function Assert-Contract {
    param([string]$Description, [bool]$Condition, [string]$Detail = "")
    if (-not $Condition) {
        $failures.Add("FAIL: $Description" + $(if ($Detail) { " — $Detail" } else { "" }))
    }
}

try {
    if (-not (Test-Path -LiteralPath $AgentsMd)) {
        throw "AGENTS.md template not found: $AgentsMd"
    }

    $docCommands = Get-DocCommands -DocPath $AgentsMd
    Assert-Contract "AGENTS.md should contain at least one workflow command example" `
        ($docCommands.Count -gt 0) "found $($docCommands.Count) commands"

    $stateOps = Get-ScriptOperations -ScriptPath $WorkflowStateScript
    $stateParams = Get-ScriptParams -ScriptPath $WorkflowStateScript
    $ownerOps = Get-ScriptOperations -ScriptPath $WorkflowOwnerScript
    $ownerParams = Get-ScriptParams -ScriptPath $WorkflowOwnerScript

    foreach ($cmd in $docCommands) {
        $scriptOps = if ($cmd.Script -match "state") { $stateOps } else { $ownerOps }
        $scriptParams = if ($cmd.Script -match "state") { $stateParams } else { $ownerParams }

        # The Operation value might be wrapped in <> (placeholder like <requirement|design>).
        # For contract we check concrete Operation names; skip placeholders.
        if ($cmd.Operation -match "^[A-Za-z]+$" -and -not $cmd.Operation.StartsWith("<")) {
            Assert-Contract `
                "Doc Operation '$($cmd.Operation)' should exist in $($cmd.Script) ValidateSet" `
                ($scriptOps.Contains($cmd.Operation)) `
                "script supports: $($scriptOps -join ', ')"
        }

        # Check each parameter name in the doc example exists in the script.
        foreach ($p in $cmd.Params) {
            # Skip placeholder values and <...> tokens.
            if ($p -match "^[A-Za-z]+$") {
                Assert-Contract `
                    "Doc param '-$p' (in '$($cmd.Operation)' example) should exist in $($cmd.Script)" `
                    ($scriptParams.Contains($p)) `
                    "script params: $($scriptParams -join ', ')"
            }
        }
    }

    # Verify every Operation in the script ValidateSet is documented in AGENTS.md.
    # (Operations can be undocumented if internal-only, but documented ones must exist.)
    $docStateOps = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]($docCommands | Where-Object { $_.Script -match "state" } |
            ForEach-Object { $_.Operation }),
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $docOwnerOps = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]($docCommands | Where-Object { $_.Script -match "owner" } |
            ForEach-Object { $_.Operation }),
        [System.StringComparer]::OrdinalIgnoreCase
    )

    # Key user-facing operations must be documented.
    $keyStateOps = @("Approve", "ResetApproval", "UpdateHash", "Status", "ValidateTestCoverage")
    foreach ($op in $keyStateOps) {
        Assert-Contract "Key Operation '$op' (workflow-state) should be documented in AGENTS.md" `
            ($docStateOps.Contains($op)) "doc has: $($docStateOps -join ', ')"
    }
    $keyOwnerOps = @("Claim", "Validate", "Complete", "Transfer", "ForceRelease")
    foreach ($op in $keyOwnerOps) {
        Assert-Contract "Key Operation '$op' (workflow-owner) should be documented in AGENTS.md" `
            ($docOwnerOps.Contains($op)) "doc has: $($docOwnerOps -join ', ')"
    }

    # --- Compile-before-audit (SDD): prevent racing auditor before javac ---
    $agentsText = Get-Content -LiteralPath $AgentsMd -Raw
    $adapterPath = Join-Path $SopRoot "workflows/superpowers-adapter.md"
    $engineSkill = Join-Path $SopRoot "skills/implementation-engine/SKILL.md"
    $auditorSkill = Join-Path $SopRoot "skills/implementation-auditor/SKILL.md"
    $logicSkill = Join-Path $SopRoot "skills/logic-auditor/SKILL.md"
    $antigravityMd = Join-Path $SopRoot "distribution/templates/root/ANTIGRAVITY.md"
    $adapterText = Get-Content -LiteralPath $adapterPath -Raw
    $engineText = Get-Content -LiteralPath $engineSkill -Raw
    $auditorText = Get-Content -LiteralPath $auditorSkill -Raw
    $logicText = Get-Content -LiteralPath $logicSkill -Raw
    $antigravityText = Get-Content -LiteralPath $antigravityMd -Raw
    Assert-Contract "AGENTS.md must require compile-before-audit" `
        ($agentsText -match '先编译通过再内审')
    Assert-Contract "adapter must define 编译准入再审查" `
        ($adapterText -match '编译准入再审查')
    Assert-Contract "adapter must forbid dispatching auditor without compile evidence" `
        ($adapterText -match '【编译证据】' -and $adapterText -match '禁止' -and $adapterText -match 'implementation-auditor')
    Assert-Contract "implementation-engine must require 【编译证据】 handoff" `
        ($engineText -match '【编译证据】')
    Assert-Contract "implementation-auditor must refuse PASS without compile evidence" `
        ($auditorText -match 'INDETERMINATE' -and $auditorText -match 'COMPILE_REQUIRED')
    Assert-Contract "logic-auditor must refuse PASS without compile evidence" `
        ($logicText -match 'INDETERMINATE' -and $logicText -match 'COMPILE_REQUIRED')
    Assert-Contract "ANTIGRAVITY.md must warn against racing auditor with engine" `
        ($antigravityText -match '编译准入')

    # --- Semantic drift guards: prevent known contradiction phrases from recurring ---
    # These were real drift bugs (single-point fix not propagated). Lock them out so the
    # same contradiction cannot silently return. Scan SOP doc surfaces only (templates +
    # .ai-sop workflows/skills/docs + root AGENTS md projections), NOT feature specs
    # (which may carry historical content unrelated to SOP doc hygiene).
    $driftScanDirs = @(
        (Join-Path $SopRoot "distribution/templates"),
        (Join-Path $SopRoot "workflows"),
        (Join-Path $SopRoot "skills"),
        (Join-Path $SopRoot "docs")
    )
    # Root-level SOP md projections. When this repo is the workspace itself,
    # parent of SopRoot can be empty on some Linux hosts.
    $workspaceRoot = Split-Path -Parent $SopRoot
    if ([string]::IsNullOrWhiteSpace($workspaceRoot)) {
        $workspaceRoot = $SopRoot
    }
    $rootSopMds = @(
        (Join-Path $workspaceRoot "AGENTS.md"),
        (Join-Path $workspaceRoot "AI_SOP_使用指南.md")
    )
    $bannedPhrases = [ordered]@{
        '自动走 T2'           = "fast-track is an independent tier (not T2); use '自动走快通道' instead"
        '默认 T3'             = "default follows change-class (缺陷/单点=T2); use '变更类默认' instead"
        '默认T3'              = "default follows change-class; use '变更类默认' instead"
        '不管需求多简单'      = "removed; tier follows change-class default, not blanket T3"
        'ai-sop$1'            = "leftover `$1 path artifact; use '.ai-sop\scripts\' instead"
        '.ai-sop/workflows/parallel-development' = "wrong path; parallel-development is at .ai-workspace/workflows/"
    }
    $driftFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($d in $driftScanDirs) {
        if (Test-Path -LiteralPath $d) {
            $found = [string[]]@(Get-ChildItem -LiteralPath $d -Recurse -Filter "*.md" -File | ForEach-Object { $_.FullName })
            foreach ($fp in $found) { $driftFiles.Add($fp) }
        }
    }
    foreach ($f in $rootSopMds) {
        if (Test-Path -LiteralPath $f) { $driftFiles.Add($f) }
    }
    foreach ($f in $driftFiles) {
        $text = Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue
        if ($null -eq $text) { continue }
        foreach ($phrase in $bannedPhrases.Keys) {
            if ($text -match [regex]::Escape($phrase)) {
                $rel = $f.Replace("$workspaceRoot\", "")
                Assert-Contract "Drift guard: '$phrase' must not appear in $rel" $false $bannedPhrases[$phrase]
            }
        }
    }

    if ($failures.Count -gt 0) {
        foreach ($f in $failures) { Write-Host $f -ForegroundColor Red }
        throw "$($failures.Count) doc-script contract failure(s)."
    }
    Write-Output "All doc-script contract tests passed ($($docCommands.Count) commands verified)."
} catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    exit 1
}
