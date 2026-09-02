#requires -Version 7.0

[CmdletBinding()]
param(
    [string[]]$Files,

    [string]$WorkspaceRoot,

    [switch]$Strict,

    [switch]$Fix,

    [switch]$Json,

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-EffectiveWorkspaceRoot {
    param([string]$ExplicitRoot)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitRoot)) {
        if (Test-Path -LiteralPath $ExplicitRoot) {
            $full = [System.IO.Path]::GetFullPath($ExplicitRoot)
            try {
                return (Get-Item -LiteralPath $full).FullName
            } catch {
                return $full
            }
        }
    }

    $cur = [System.IO.Path]::GetFullPath($PWD)
    while (-not [string]::IsNullOrWhiteSpace($cur)) {
        if ((Test-Path -LiteralPath (Join-Path $cur ".ai-workspace")) -or 
            (Test-Path -LiteralPath (Join-Path $cur ".ai-sop")) -or 
            (Test-Path -LiteralPath (Join-Path $cur ".git")) -or 
            (Test-Path -LiteralPath (Join-Path $cur ".svn"))) {
            try {
                return (Get-Item -LiteralPath $cur).FullName
            } catch {
                return $cur
            }
        }
        $parent = Split-Path -Parent $cur
        if ($parent -eq $cur) { break }
        $cur = $parent
    }
    return [System.IO.Path]::GetFullPath($PWD)
}

function Test-IsTestFile {
    param(
        [string]$FilePath,
        [string]$Workspace
    )

    $fileName = [System.IO.Path]::GetFileName($FilePath)
    $wsCanonical = if (-not [string]::IsNullOrWhiteSpace($Workspace) -and (Test-Path -LiteralPath $Workspace)) {
        try { (Get-Item -LiteralPath $Workspace).FullName } catch { [System.IO.Path]::GetFullPath($Workspace) }
    } else {
        $null
    }
    $fileCanonical = if (Test-Path -LiteralPath $FilePath) {
        try { (Get-Item -LiteralPath $FilePath).FullName } catch { [System.IO.Path]::GetFullPath($FilePath) }
    } else {
        [System.IO.Path]::GetFullPath($FilePath)
    }

    $relPath = if (-not [string]::IsNullOrWhiteSpace($wsCanonical)) {
        try {
            [System.IO.Path]::GetRelativePath($wsCanonical, $fileCanonical)
        } catch { $FilePath }
    } else {
        $FilePath
    }
    $normRel = ($relPath -replace "\\", "/").TrimStart('/')

    if ($normRel -notmatch '^\.\.' -and -not [System.IO.Path]::IsPathRooted($normRel)) {
        if ($normRel -match '(?i)^src/test/' -or 
            $normRel -match '(?i)^test/' -or 
            $normRel -match '(?i)^tests/' -or 
            $normRel -match '(?i)/(?:test|tests)/') {
            return $true
        }
    }

    if ($fileName -match '(?i)Test(?:s|Case)?\.[a-zA-Z0-9]+$' -or 
        $fileName -match '(?i)_test\.[a-zA-Z0-9]+$' -or 
        $fileName -match '(?i)\.tests\.ps1$') {
        return $true
    }

    return $false
}

function Get-InlineExemptions {
    param([string[]]$Lines)

    $fileExemptions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $lineExemptions = [System.Collections.Generic.Dictionary[int, [System.Collections.Generic.HashSet[string]]]]::new()

    # Supported comment patterns:
    # // ai-sop-lint-disable: RULE_ID [reason]
    # # ai-sop-lint-disable: RULE_ID [reason]
    # <!-- ai-sop-lint-disable: RULE_ID [reason] -->
    # -- ai-sop-lint-disable: RULE_ID [reason]
    $disablePattern = '(?i)(?://|#|<!--|--)\s*ai-sop-lint-disable(?:-line|-next-line)?:\s*([A-Za-z0-9_-]+)'
    $fileDisablePattern = '(?i)(?://|#|<!--|--)\s*ai-sop-lint-disable-file:\s*([A-Za-z0-9_-]+)'

    for ($i = 0; $i -lt $Lines.Length; $i++) {
        $lineNum = $i + 1
        $line = $Lines[$i]

        foreach ($m in [regex]::Matches($line, $fileDisablePattern)) {
            $rule = $m.Groups[1].Value.Trim()
            $fileExemptions.Add($rule) | Out-Null
            $fileExemptions.Add("RULE_" + ($rule -replace '^RULE[-_]?', '')) | Out-Null
        }

        foreach ($m in [regex]::Matches($line, $disablePattern)) {
            $rule = $m.Groups[1].Value.Trim()
            $canonRule = "RULE_" + ($rule -replace '^RULE[-_]?', '')
            if (-not $lineExemptions.ContainsKey($lineNum)) {
                $lineExemptions[$lineNum] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            }
            $lineExemptions[$lineNum].Add($rule) | Out-Null
            $lineExemptions[$lineNum].Add($canonRule) | Out-Null

            # Also cover next line if disable-next-line
            if ($line -match '(?i)ai-sop-lint-disable-next-line') {
                $next = $lineNum + 1
                if (-not $lineExemptions.ContainsKey($next)) {
                    $lineExemptions[$next] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                }
                $lineExemptions[$next].Add($rule) | Out-Null
                $lineExemptions[$next].Add($canonRule) | Out-Null
            }
        }
    }

    return [pscustomobject]@{
        FileExemptions = $fileExemptions
        LineExemptions = $lineExemptions
    }
}

function Test-IsRuleExempted {
    param(
        [object]$Exemptions,
        [int]$LineNumber,
        [string]$RuleId
    )

    $canonRule = "RULE_" + ($RuleId -replace '^RULE[-_]?', '')
    if ($Exemptions.FileExemptions.Contains("ALL") -or 
        $Exemptions.FileExemptions.Contains($RuleId) -or 
        $Exemptions.FileExemptions.Contains($canonRule)) {
        return $true
    }

    if ($Exemptions.LineExemptions.ContainsKey($LineNumber)) {
        $set = $Exemptions.LineExemptions[$LineNumber]
        if ($set.Contains("ALL") -or $set.Contains($RuleId) -or $set.Contains($canonRule)) {
            return $true
        }
    }
    return $false
}

function Remove-CodeComments {
    param([string]$Code)
    if ([string]::IsNullOrEmpty($Code)) { return "" }
    $noBlock = [regex]::Replace($Code, '(?s)/\*.*?\*/', '')
    $noComments = [regex]::Replace($noBlock, '(?m)//.*$', '')
    return $noComments
}

function Split-JavaMethodBlocks {
    param([string]$Content)

    $blocks = [System.Collections.Generic.List[pscustomobject]]::new()
    $lines = $Content -split "\r?\n"
    
    $methodHeaderPattern = '(?m)^\s*(?:public|protected|private|static|\s)+[\w\<\>\[\],\s]+\s+(\w+)\s*\([^\)]*\)\s*(?:throws\s+[\w\<\>,\s]+)?\s*\{'
    $matches = [regex]::Matches($Content, $methodHeaderPattern)

    foreach ($m in $matches) {
        $methodName = $m.Groups[1].Value
        $startIndex = $m.Index
        $startLine = ($Content.Substring(0, $startIndex) -split "\r?\n").Length

        # Find matching closing brace
        $braceCount = 0
        $endIndex = -1
        $chars = $Content.ToCharArray()
        $inString = $false
        $inChar = $false
        $inLineComment = $false
        $inBlockComment = $false

        for ($idx = $startIndex; $idx -lt $chars.Length; $idx++) {
            $c = $chars[$idx]
            $next = if ($idx + 1 -lt $chars.Length) { $chars[$idx + 1] } else { [char]0 }

            if ($inLineComment) {
                if ($c -eq "`n") { $inLineComment = $false }
                continue
            }
            if ($inBlockComment) {
                if ($c -eq "*" -and $next -eq "/") { $inBlockComment = $false; $idx++ }
                continue
            }
            if ($inString) {
                if ($c -eq "\" -and $next -eq '"') { $idx++; continue }
                if ($c -eq '"') { $inString = $false }
                continue
            }
            if ($inChar) {
                if ($c -eq "\" -and $next -eq "'") { $idx++; continue }
                if ($c -eq "'") { $inChar = $false }
                continue
            }

            if ($c -eq "/" -and $next -eq "/") { $inLineComment = $true; $idx++; continue }
            if ($c -eq "/" -and $next -eq "*") { $inBlockComment = $true; $idx++; continue }
            if ($c -eq '"') { $inString = $true; continue }
            if ($c -eq "'") { $inChar = $true; continue }

            if ($c -eq "{") {
                $braceCount++
            } elseif ($c -eq "}") {
                $braceCount--
                if ($braceCount -eq 0) {
                    $endIndex = $idx
                    break
                }
            }
        }

        if ($endIndex -gt $startIndex) {
            $methodBody = $Content.Substring($startIndex, $endIndex - $startIndex + 1)
            $endLine = ($Content.Substring(0, $endIndex) -split "\r?\n").Length
            $blocks.Add([pscustomobject]@{
                MethodName = $methodName
                StartLine  = $startLine
                EndLine    = $endLine
                Body       = $methodBody
            })
        }
    }
    return $blocks
}

function Get-CustomProjectRules {
    param([string]$WorkspaceRoot)

    $customRules = [System.Collections.Generic.List[pscustomobject]]::new()
    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { return $customRules }

    $candidateDirs = @(
        (Join-Path $WorkspaceRoot ".ai-sop/config"),
        (Join-Path $WorkspaceRoot ".ai-sop/rules"),
        (Join-Path $WorkspaceRoot ".ai-workspace/rules"),
        (Join-Path $WorkspaceRoot ".ai-workspace/config")
    )

    foreach ($dir in $candidateDirs) {
        if (Test-Path -LiteralPath $dir -PathType Container) {
            $files = Get-ChildItem -LiteralPath $dir -Filter "*quality*.json" -File -ErrorAction SilentlyContinue
            foreach ($f in $files) {
                try {
                    $json = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
                    if ($json.rules) {
                        foreach ($r in $json.rules) {
                            $customRules.Add($r)
                        }
                    } elseif ($json -is [System.Collections.IEnumerable] -and $json -isnot [string]) {
                        foreach ($r in $json) { $customRules.Add($r) }
                    }
                } catch {}
            }
        }
    }
    return $customRules
}

function Invoke-ScanFile {
    param(
        [string]$FilePath,
        [string]$WorkspaceRoot
    )

    $violations = [System.Collections.Generic.List[pscustomobject]]::new()
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        return $violations
    }

    $rawContent = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
    $lines = $rawContent -split "\r?\n"
    $exemptions = Get-InlineExemptions -Lines $lines
    $isTest = Test-IsTestFile -FilePath $FilePath -Workspace $WorkspaceRoot
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()

    # Rule 101: Disallow static import in Java (unless in test assertions or explicitly exempted)
    if ($ext -eq ".java") {
        for ($i = 0; $i -lt $lines.Length; $i++) {
            $lineNum = $i + 1
            $line = $lines[$i]
            if ($line -match '^\s*import\s+static\s+([^;]+);') {
                $imported = $Matches[1].Trim()
                # Test files may import standard assertions like org.junit.* or org.mockito.*
                if ($isTest) {
                    if ($imported -match '^(?:org\.junit|org\.mockito|org\.assertj|org\.hamcrest|static\s+org\.)') {
                        continue
                    }
                }
                if (-not (Test-IsRuleExempted -Exemptions $exemptions -LineNumber $lineNum -RuleId "RULE_101")) {
                    $violations.Add([pscustomobject]@{
                        RuleId     = "RULE_101"
                        RuleName   = "JAVA_NO_STATIC_IMPORT"
                        File       = $FilePath
                        LineNumber = $lineNum
                        Message    = "Explicit reference required: static import '$imported' is forbidden. Call constants/methods with class qualification."
                        Severity   = "ERROR"
                        Snippet    = $line.Trim()
                    })
                }
            }
        }

        # Method-level analysis for Java files
        if (-not $isTest) {
            $methodBlocks = Split-JavaMethodBlocks -Content $rawContent
            foreach ($block in $methodBlocks) {
                $methodBody = $block.Body
                $methodLines = $methodBody -split "\r?\n"
                $cleanMethodBody = Remove-CodeComments -Code $methodBody

                # Rule 102: Entity Mutation without Persistence
                $mutationPattern = '(?i)\b(?:player|roleData|user|account|playerData|hero|bag|item|order|entity)\.(?:cost[A-Za-z0-9_]*|add[A-Za-z0-9_]*|deduct[A-Za-z0-9_]*|set[A-Z][A-Za-z0-9_]*|increase[A-Za-z0-9_]*|decrease[A-Za-z0-9_]*|consume[A-Za-z0-9_]*)\b|\b(?:costOneBaseRes|costOnePiece|costRes|addReward|costBaseRes|addBaseRes)\b'
                $persistPattern = '(?i)\b(?:update|updateAirData|save|flush|persist|saveOrUpdate|savePlayer|saveEntity|playerDao\.\w+|playerMapper\.\w+|dao\.\w+|mapper\.\w+|repo\.\w+|repository\.\w+)\s*\(|\.update\s*\('

                $hasMutation = ($cleanMethodBody -match $mutationPattern)
                $hasPersist = ($cleanMethodBody -match $persistPattern)

                if ($hasMutation -and -not $hasPersist) {
                    # Find line of first mutation
                    for ($mIdx = 0; $mIdx -lt $methodLines.Length; $mIdx++) {
                        $mLine = $methodLines[$mIdx]
                        $cleanLine = ($mLine -replace '//.*$', '').Trim()
                        $absLineNum = $block.StartLine + $mIdx
                        if ($cleanLine -match $mutationPattern) {
                            if (-not (Test-IsRuleExempted -Exemptions $exemptions -LineNumber $absLineNum -RuleId "RULE_102")) {
                                $violations.Add([pscustomobject]@{
                                    RuleId     = "RULE_102"
                                    RuleName   = "MUTATION_WITHOUT_PERSISTENCE"
                                    File       = $FilePath
                                    LineNumber = $absLineNum
                                    Message    = "Entity state mutation in method '$($block.MethodName)' must be followed by explicit persistence call (e.g. update(player), updateAirData, or DAO/Mapper update)."
                                    Severity   = "ERROR"
                                    Snippet    = $mLine.Trim()
                                })
                                break
                            }
                        }
                    }
                }

                # Rule 103: Duplicate Failure Error Codes within the same method
                $failReturnPattern = '(?i)return\s+(?:Response|Result|ActionResult|ServiceResult|ApiResult|CommonResult)\.(?:fail|error|failure)\s*\(\s*([^,;\)]+)'
                $failReturnMatches = [regex]::Matches($cleanMethodBody, $failReturnPattern)
                $seenCodes = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::OrdinalIgnoreCase)

                foreach ($m in $failReturnMatches) {
                    $codeToken = $m.Groups[1].Value.Trim()
                    $matchIndex = $m.Index
                    $matchLineOffset = ($cleanMethodBody.Substring(0, $matchIndex) -split "\r?\n").Length - 1
                    $absLine = $block.StartLine + $matchLineOffset

                    if ($seenCodes.ContainsKey($codeToken)) {
                        if (-not (Test-IsRuleExempted -Exemptions $exemptions -LineNumber $absLine -RuleId "RULE_103")) {
                            $violations.Add([pscustomobject]@{
                                RuleId     = "RULE_103"
                                RuleName   = "DUPLICATE_FAILURE_ERROR_CODES"
                                File       = $FilePath
                                LineNumber = $absLine
                                Message    = "Duplicate failure error code '$codeToken' in method '$($block.MethodName)'. Each distinct failure branch must return a unique error code."
                                Severity   = "ERROR"
                                Snippet    = if ($absLine -le $lines.Length) { $lines[$absLine - 1].Trim() } else { $codeToken }
                            })
                        }
                    } else {
                        $seenCodes[$codeToken] = $absLine
                    }
                }

                # Rule 104: Invalid Protocol Response Structure (Raw Naked Map in protocol handlers)
                if ($block.MethodName -match '(?i)(?:handle|process|onMessage|doHttp|action|protocol)' -or 
                    $FilePath -match '(?i)(?:handler|action|protocol|controller|service)') {
                    $nakedMapPattern = '(?i)\b(?:Map<String,\s*Object>|HashMap<String,\s*Object>)\s+\w+\s*=\s*new\s+HashMap|return\s+new\s+HashMap'
                    for ($mIdx = 0; $mIdx -lt $methodLines.Length; $mIdx++) {
                        $mLine = $methodLines[$mIdx]
                        $cleanLine = ($mLine -replace '//.*$', '').Trim()
                        $absLineNum = $block.StartLine + $mIdx
                        if ($cleanLine -match $nakedMapPattern) {
                            if (-not (Test-IsRuleExempted -Exemptions $exemptions -LineNumber $absLineNum -RuleId "RULE_104")) {
                                $violations.Add([pscustomobject]@{
                                    RuleId     = "RULE_104"
                                    RuleName   = "INVALID_PROTOCOL_RESPONSE_STRUCTURE"
                                    File       = $FilePath
                                    LineNumber = $absLineNum
                                    Message    = "Raw naked Map detected in protocol handler '$($block.MethodName)'. Use structured typed VO / Response protocol model."
                                    Severity   = "ERROR"
                                    Snippet    = $mLine.Trim()
                                })
                            }
                        }
                    }
                }
            }
        }
    }

    # Custom extensible project rules
    $customRules = Get-CustomProjectRules -WorkspaceRoot $WorkspaceRoot
    foreach ($cr in $customRules) {
        $ruleId = if ($cr.id) { [string]$cr.id } else { "CUSTOM_RULE" }
        $ruleName = if ($cr.name) { [string]$cr.name } else { "CUSTOM_RULE" }
        $filePat = if ($cr.filePattern) { [string]$cr.filePattern } else { ".*" }
        if ($FilePath -notmatch $filePat) { continue }

        $pat = if ($cr.pattern) { [string]$cr.pattern } else { $cr.forbiddenPattern }
        if (-not [string]::IsNullOrWhiteSpace($pat)) {
            for ($i = 0; $i -lt $lines.Length; $i++) {
                $lineNum = $i + 1
                $line = $lines[$i]
                if ($line -match $pat) {
                    if (-not (Test-IsRuleExempted -Exemptions $exemptions -LineNumber $lineNum -RuleId $ruleId)) {
                        $violations.Add([pscustomobject]@{
                            RuleId     = $ruleId
                            RuleName   = $ruleName
                            File       = $FilePath
                            LineNumber = $lineNum
                            Message    = if ($cr.message) { [string]$cr.message } else { "Custom rule violation ($ruleName)" }
                            Severity   = if ($cr.severity) { [string]$cr.severity } else { "ERROR" }
                            Snippet    = $line.Trim()
                        })
                    }
                }
            }
        }
    }

    return $violations
}

function Invoke-AutoFixFile {
    param(
        [string]$FilePath,
        [string]$WorkspaceRoot
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return $false }
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    $modified = $false

    if ($ext -eq ".java") {
        $rawContent = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
        $lines = $rawContent -split "\r?\n"
        $newLines = [System.Collections.Generic.List[string]]::new()
        $isTest = Test-IsTestFile -FilePath $FilePath -Workspace $WorkspaceRoot

        foreach ($line in $lines) {
            if ($line -match '^\s*import\s+static\s+([a-zA-Z0-9_.]+)\.([a-zA-Z0-9_*]+)\s*;') {
                $pkg = $Matches[1]
                $member = $Matches[2]
                if ($isTest -and $pkg -match '^(?:org\.junit|org\.mockito|org\.assertj|org\.hamcrest)') {
                    $newLines.Add($line)
                } else {
                    $newLines.Add("import $pkg; // ai-sop auto-fixed static import ($member)")
                    $modified = $true
                }
            } else {
                $newLines.Add($line)
            }
        }

        if ($modified) {
            $newContent = $newLines -join [System.Environment]::NewLine
            [System.IO.File]::WriteAllText($FilePath, $newContent, [System.Text.UTF8Encoding]::new($false))
        }
    }

    return $modified
}

$effectiveWs = Resolve-EffectiveWorkspaceRoot -ExplicitRoot $WorkspaceRoot

$targetFiles = [System.Collections.Generic.List[string]]::new()
if ($Files -and $Files.Count -gt 0) {
    foreach ($f in $Files) {
        if (-not [string]::IsNullOrWhiteSpace($f)) {
            $p = if ([System.IO.Path]::IsPathRooted($f)) {
                [System.IO.Path]::GetFullPath($f)
            } else {
                [System.IO.Path]::GetFullPath((Join-Path $effectiveWs $f))
            }
            if (Test-Path -LiteralPath $p) {
                $targetFiles.Add($p)
            }
        }
    }
} else {
    # Auto-detect changed files via git status if available
    try {
        $gitStatus = git -C $effectiveWs status --porcelain 2>$null
        if ($gitStatus) {
            foreach ($line in $gitStatus) {
                $rel = ($line -split '\s+', 2)[-1].Trim()
                $full = [System.IO.Path]::GetFullPath((Join-Path $effectiveWs $rel))
                if (Test-Path -LiteralPath $full -PathType Leaf) {
                    $targetFiles.Add($full)
                }
            }
        }
    } catch {}
}

$fixedCount = 0
if ($Fix) {
    foreach ($tf in $targetFiles) {
        if (Invoke-AutoFixFile -FilePath $tf -WorkspaceRoot $effectiveWs) {
            $fixedCount++
        }
    }
}

$allViolations = [System.Collections.Generic.List[pscustomobject]]::new()
foreach ($tf in $targetFiles) {
    $v = Invoke-ScanFile -FilePath $tf -WorkspaceRoot $effectiveWs
    foreach ($item in $v) {
        $allViolations.Add($item)
    }
}

$isValid = ($allViolations.Count -eq 0)

$resultObj = [pscustomobject]@{
    IsValid           = $isValid
    ScannedFilesCount = $targetFiles.Count
    FixedFilesCount   = $fixedCount
    Violations        = @($allViolations)
    Files             = @($targetFiles)
}

if ($PassThru) {
    return $resultObj
}

if ($Json) {
    $resultObj | ConvertTo-Json -Depth 10
} else {
    if ($isValid) {
        Write-Host "✅ Code Quality Guard: Scanned $($targetFiles.Count) file(s), 0 violations found." -ForegroundColor Green
    } else {
        Write-Host "❌ Code Quality Guard: Found $($allViolations.Count) violation(s) across $($targetFiles.Count) file(s):" -ForegroundColor Red
        foreach ($v in $allViolations) {
            Write-Host ("  [{0}] {1}:{2} - {3}" -f $v.RuleId, $v.File, $v.LineNumber, $v.Message) -ForegroundColor Yellow
            if ($v.Snippet) {
                Write-Host ("    > {0}" -f $v.Snippet) -ForegroundColor DarkGray
            }
        }
    }
}

if ($isValid) {
    exit 0
} else {
    exit 1
}
