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

# Check real Task examples against script parameter ASTs, including multiline
# calls. Do not execute documentation or infer its meaning from keyword counts.
function Get-TaskDocCommands {
    param([string]$Content, [ValidateSet('Task','Inputs','Preflight')][string]$Action='Task')
    $directScript=@{Task='workflow-task';Inputs='inspect-inputs';Preflight='preflight'}[$Action]
    $snippets=[Collections.Generic.List[string]]::new()
    $fences='(?ms)^[ \t]*```([^\r\n]*)\r?\n(.*?)^[ \t]*```[ \t]*$'
    foreach ($block in [regex]::Matches($Content,$fences)) {
        if ($block.Groups[1].Value.Trim() -eq 'powershell') { $snippets.Add($block.Groups[2].Value) }
    }
    # Remove fenced content before parsing inline spans: PowerShell continuation
    # backticks are syntax inside a fence, not Markdown inline delimiters.
    $inline=[regex]::Replace($Content,$fences,'')
    foreach ($span in [regex]::Matches($inline,'(?<!`)(`+)(?!`)([^\r\n]*?)(?<!`)\1(?!`)')) { $snippets.Add($span.Groups[2].Value) }
    foreach ($snippet in $snippets) {
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseInput($snippet,[ref]$tokens,[ref]$errors)
        foreach ($command in $ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true)) {
            $elements=@($command.CommandElements)
            $script=@($elements | Where-Object { $_ -is [Management.Automation.Language.StringConstantExpressionAst] -and $_.Value -match "(^|[/\\])(ai-sop|$directScript)\.ps1$" } | Select-Object -First 1)
            if (-not $script.Count) { continue }
            $isRoot=$script[0].Value -match '(^|[/\\])ai-sop\.ps1$'
            if ($isRoot -and -not @($elements | Where-Object { $_ -is [Management.Automation.Language.StringConstantExpressionAst] -and $_.Value -eq $Action }).Count) { continue }
            $parameters=@{}
            for ($i=0; $i -lt $elements.Count; $i++) {
                $element=$elements[$i]
                if ($element -isnot [Management.Automation.Language.CommandParameterAst]) { continue }
                if ($element.ParameterName -in @('File','NoProfile','Action')) { continue }
                $argument=if ($element.Argument) { $element.Argument } elseif ($i+1 -lt $elements.Count) { $elements[$i+1] } else { $null }
                $parameters[$element.ParameterName]=if ($argument -is [Management.Automation.Language.StringConstantExpressionAst]) { $argument.Value } else { $null }
            }
            @{isRoot=$isRoot;parameters=$parameters;raw=$command.Extent.Text}
        }
    }
}

function Get-TaskScriptContract {
    param([string]$Path)
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw "Script parse failed: $Path" }
    $contract=@{}
    foreach ($parameter in $ast.ParamBlock.Parameters) {
        $values=@($parameter.Attributes | Where-Object { $_.TypeName.FullName -eq 'ValidateSet' } | ForEach-Object { $_.PositionalArguments } | ForEach-Object { $_.SafeGetValue() })
        $contract[$parameter.Name.VariablePath.UserPath]=$values
    }
    return $contract
}

function Get-TaskDocProblems {
    param($Command, $TaskContract, $RootContract)
    foreach ($name in $Command.parameters.Keys) {
        if (-not $TaskContract.ContainsKey($name) -or ($Command.isRoot -and -not $RootContract.ContainsKey($name))) { "Unsupported Task parameter: $name"; continue }
        $value=$Command.parameters[$name]
        if ($null -ne $value -and $value -notmatch '<[^>]+>' -and $TaskContract[$name].Count -and $value -notin $TaskContract[$name]) { "Invalid Task ${name}: $value" }
    }
}

function Get-TaskForwardingProblems {
    param([string]$Entry, [hashtable]$Arguments)
    # The isolated engine only echoes received parameters; no task is started.
    $received=& $Entry Task @Arguments | ConvertFrom-Json -AsHashtable
    if ($LASTEXITCODE -ne 0) { throw "Root forwarding probe failed: $LASTEXITCODE" }
    $expected=@{WorkspacePath=(Split-Path -Parent $Entry)}
    foreach ($key in $Arguments.Keys) { $expected[$key]=$Arguments[$key] }
    foreach ($key in $expected.Keys) {
        if (-not $received.ContainsKey($key) -or (ConvertTo-Json -InputObject $received[$key] -Compress) -cne (ConvertTo-Json -InputObject $expected[$key] -Compress)) { "Forwarding mismatch: $key" }
    }
    foreach ($key in $received.Keys) { if (-not $expected.ContainsKey($key)) { "Unexpected forwarded parameter: $key" } }
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

    $taskContract=Get-TaskScriptContract (Join-Path $SopRoot 'scripts/workflow-task.ps1')
    $rootContract=Get-TaskScriptContract (Join-Path $SopRoot 'distribution/templates/root/ai-sop.ps1')
    $taskExampleCount=0
    foreach ($relative in @('distribution/templates/root/AGENTS.md','SUPERPOWERS_MANUAL.md','workflows/superpowers-adapter.md','skills/quality-assurance/SKILL.md','skills/workflow-orchestrator/SKILL.md')) {
        $examples=@(Get-TaskDocCommands ([IO.File]::ReadAllText((Join-Path $SopRoot $relative))))
        if ($relative -in @('skills/quality-assurance/SKILL.md','skills/workflow-orchestrator/SKILL.md')) { Assert-Contract "$relative must provide a Task command example" ($examples.Count -gt 0) }
        foreach ($example in $examples) {
            $taskExampleCount++
            $problems=@(Get-TaskDocProblems $example $taskContract $rootContract)
            Assert-Contract "Task example in $relative must match both entrypoints" ($problems.Count -eq 0) "$($problems -join '; '): $($example.raw)"
        }
    }
    # A negative fixture proves multiline parameters and invalid operations are
    # actually inspected instead of silently finding zero examples.
    $badExamples=@(Get-TaskDocCommands @'
```powershell
& ./ai-sop.ps1 Task -Operation Imaginary `
  -MissingSwitch value
```
'@)
    Assert-Contract 'Task example parser must find multiline calls' ($badExamples.Count -eq 1)
    $badProblems=@(Get-TaskDocProblems $badExamples[0] $taskContract $rootContract)
    Assert-Contract 'Task example validation must reject invalid operation and trailing parameter' ($badProblems.Count -eq 2)
    $inlineExamples=@(Get-TaskDocCommands @'
Use `./ai-sop.ps1 Task -Operation Imaginary -MissingSwitch value` or ``./.ai-sop/scripts/workflow-task.ps1 -Operation RetryEvidence -RunId run-1``.
'@)
    Assert-Contract 'Inline parser finds root and direct commands' ($inlineExamples.Count -eq 2)
    Assert-Contract 'Inline invalid operation and parameter are rejected' (@(Get-TaskDocProblems $inlineExamples[0] $taskContract $rootContract).Count -eq 2)
    Assert-Contract 'Inline valid command is accepted' (@(Get-TaskDocProblems $inlineExamples[1] $taskContract $rootContract).Count -eq 0)

    $fixture=Join-Path ([IO.Path]::GetTempPath()) ('sop-contract-forwarding-' + [guid]::NewGuid().ToString('N'))
    try {
        $stubDirectory=Join-Path $fixture '.ai-sop/scripts'
        [IO.Directory]::CreateDirectory($stubDirectory) | Out-Null
        $rootSource=Join-Path $SopRoot 'distribution/templates/root/ai-sop.ps1'
        $fixtureEntry=Join-Path $fixture 'ai-sop.ps1'
        Copy-Item -LiteralPath $rootSource -Destination $fixtureEntry
        $tokens=$null; $errors=$null
        $rootAst=[Management.Automation.Language.Parser]::ParseFile($rootSource,[ref]$tokens,[ref]$errors)
        $arguments=@{}; $declarations=@('[string]$WorkspacePath')
        foreach ($parameter in $rootAst.ParamBlock.Parameters) {
            $name=$parameter.Name.VariablePath.UserPath
            if (-not $taskContract.ContainsKey($name)) { continue }
            $declarations+='[{0}]${1}' -f $parameter.StaticType.FullName,$name
            $arguments[$name]=if ($parameter.StaticType -eq [switch]) { $true }
                elseif ($parameter.StaticType -eq [string[]]) { @('first value','quote";literal$token') }
                elseif ($parameter.StaticType -eq [int]) { 37 }
                elseif ($name -eq 'Operation') { 'RetryEvidence' }
                elseif ($rootContract[$name].Count) { $rootContract[$name][0] }
                else { 'value-' + $name }
        }
        $stub='param(' + ($declarations -join ',') + ')' + [Environment]::NewLine + @'
$captured=@{}
foreach ($key in $PSBoundParameters.Keys) {
    $value=$PSBoundParameters[$key]
    $captured[$key]=if ($value -is [switch]) { $value.IsPresent } else { $value }
}
$captured | ConvertTo-Json -Depth 5
exit 0
'@
        [IO.File]::WriteAllText((Join-Path $stubDirectory 'workflow-task.ps1'),$stub)
        $forwardingProblems=@(Get-TaskForwardingProblems $fixtureEntry $arguments)
        Assert-Contract 'Root forwards every shared Task parameter with its actual value' ($forwardingProblems.Count -eq 0) ($forwardingProblems -join '; ')
        $mutated=[IO.File]::ReadAllText($fixtureEntry).Replace("'ConfirmTakeover','RunId','Reason'","'ConfirmTakeover','Reason'")
        [IO.File]::WriteAllText($fixtureEntry,$mutated)
        $negative=@(Get-TaskForwardingProblems $fixtureEntry $arguments)
        Assert-Contract 'Forwarding probe detects a missing RunId even with intact ParamBlocks' ($negative.Count -eq 1 -and $negative[0] -eq 'Forwarding mismatch: RunId')
    } finally {
        $resolved=[IO.Path]::GetFullPath($fixture)
        $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if ($resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'sop-contract-forwarding-*') { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
    }

    foreach ($action in @('Inputs','Preflight')) {
        $scriptName=if ($action -eq 'Inputs') { 'inspect-inputs.ps1' } else { 'preflight.ps1' }
        $contract=Get-TaskScriptContract (Join-Path $SopRoot "scripts/$scriptName")
        $examples=@(Get-TaskDocCommands ([IO.File]::ReadAllText((Join-Path $SopRoot 'SUPERPOWERS_MANUAL.md'))) -Action $action)
        Assert-Contract "$action has a real manual example and root action" ($examples.Count -gt 0 -and $action -in $rootContract.Action)
        foreach ($example in $examples) {
            $problems=@(Get-TaskDocProblems $example $contract $rootContract)
            Assert-Contract "$action manual example matches both entrypoints" ($problems.Count -eq 0) ($problems -join '; ')
        }
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
    Assert-Contract "AGENTS.md must not treat 2-5 minute steps as Task splits" `
        ($agentsText -notmatch '拆分为 2-5 分钟可完成的小任务')
    Assert-Contract "AGENTS.md must distinguish Task vs Step for writing-plans" `
        ($agentsText -match '默认 1 个 Task' -and $agentsText -match 'Step')
    Assert-Contract "adapter must define writing-plans Task granularity overlay" `
        ($adapterText -match 'writing-plans Task 粒度')
    Assert-Contract "Task policy must default to T2 and respect human selection" `
        ($agentsText -match '默认 T2' -and $agentsText -match '人工显式选择优先' -and $agentsText -match '不自行升降档')
    Assert-Contract "T2 must synchronize affected artifacts without independent review" `
        ($agentsText -match 'RecordSync' -and $agentsText -match 'T1/T2 无独立代码审核环节')
    Assert-Contract "Deferred work must remain visible without becoming a gate" `
        ($agentsText -match 'AddFollowUp' -and $agentsText -match 'CloseFollowUp' -and $agentsText -match '不因待办升档或阻止完成')

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
        '默认 T3'             = "default is T2; human selection takes priority"
        '默认T3'              = "default is T2; human selection takes priority"
        '不管需求多简单'      = "removed; no blanket T3 requirement"
        '自动降级为 T2'       = "tier changes require the human request; capability failures do not change tier"
        '必须强制走 T3'       = "risk assessment advises scope and validation; it does not override the task tier"
        '自动走快通道'        = "new tasks have three tiers; use applicability for pure documentation"
        'ai-sop$1'            = "leftover `$1 path artifact; use '.ai-sop\scripts\' instead"
        '拆分为 2-5 分钟可完成的小任务' = "2-5 minutes are Steps inside a Task, not Task count; see adapter writing-plans Task 粒度"
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
    Write-Output "All doc-script contract tests passed ($($docCommands.Count) legacy and $taskExampleCount Task commands verified)."
} catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    exit 1
}
