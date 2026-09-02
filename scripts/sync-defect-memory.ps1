#requires -Version 7.0

<#
.SYNOPSIS
    Syncs historical dual-agent review rejection patterns and bug fixes into structured context memory.
.DESCRIPTION
    Parses historical rejection records from review-mailbox.json and bug patterns from BUGS.md,
    extracting categorized anti-patterns into .ai-workspace/context/defect-patterns.md with token budget governance.
.AUTHOR
    shuyongqiang
#>

[CmdletBinding()]
param(
    [string]$WorkspaceRoot,
    [string]$MailboxPath,
    [string]$OutputMemoryFile,
    [int]$MaxPatterns = 20,
    [int]$MaxTokens = 1500,
    [string]$ModuleFilter = "",
    [switch]$PassThru,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-AiSopWorkspaceRoot {
    param([string]$StartPath)
    if ([string]::IsNullOrWhiteSpace($StartPath)) { return $null }
    $curDir = if (Test-Path -LiteralPath $StartPath -PathType Container) {
        [System.IO.Path]::GetFullPath($StartPath)
    } else {
        Split-Path -Parent ([System.IO.Path]::GetFullPath($StartPath))
    }
    while (-not [string]::IsNullOrWhiteSpace($curDir)) {
        if ((Test-Path -LiteralPath (Join-Path $curDir ".ai-workspace")) -or 
            (Test-Path -LiteralPath (Join-Path $curDir ".ai-sop")) -or 
            (Test-Path -LiteralPath (Join-Path $curDir ".git")) -or 
            (Test-Path -LiteralPath (Join-Path $curDir ".svn"))) {
            return $curDir
        }
        $parent = Split-Path -Parent $curDir
        if ($parent -eq $curDir) { break }
        $curDir = $parent
    }
    return $null
}

$wsRoot = if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    [System.IO.Path]::GetFullPath($WorkspaceRoot)
} else {
    $found = Resolve-AiSopWorkspaceRoot -StartPath $PWD
    if ($found) { $found } else { [System.IO.Path]::GetFullPath($PWD) }
}

$outputFile = if (-not [string]::IsNullOrWhiteSpace($OutputMemoryFile)) {
    if ([System.IO.Path]::IsPathRooted($OutputMemoryFile)) {
        [System.IO.Path]::GetFullPath($OutputMemoryFile)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $wsRoot $OutputMemoryFile))
    }
} else {
    Join-Path $wsRoot ".ai-workspace\context\defect-patterns.md"
}

function Get-SafeValue {
    param($Obj, [string]$PropName, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($PropName)) {
            $val = $Obj[$PropName]
            if ($null -ne $val) { return $val }
        }
        return $Default
    }
    if ($Obj.PSObject.Properties.Match($PropName).Count -gt 0) {
        $val = $Obj.$PropName
        if ($null -ne $val) { return $val }
    }
    return $Default
}

function Classify-DefectCategory {
    param([string]$Problem, [string]$FixSuggestion, [string]$File)
    $text = "$Problem $FixSuggestion $File".ToLowerInvariant()

    if ($text -match '(?:import\s+static|static\s+import)') {
        return "STATIC_IMPORT_DISALLOWED"
    }
    if ($text -match '(?:update\(player\)|mutation|persist|save\(|flush|dirty|cost\w+|add\w+)') {
        return "MUTATION_WITHOUT_PERSISTENCE"
    }
    if ($text -match '(?:cold\s*reload|coldreload|storage\s*reload|selectbyid|getbyid|fake\s*green|oracle)') {
        return "MISSING_COLD_RELOAD"
    }
    if ($text -match '(?:duplicate\s*(?:error|return|failure)|code\s*collision|same\s*method.*return\s*code)') {
        return "DUPLICATE_ERROR_CODE"
    }
    if ($text -match '(?:naked\s*map|raw\s*map|map<|protocol.*map)') {
        return "NAKED_MAP_IN_PROTOCOL"
    }
    if ($text -match '(?:lock|timeout|deadlock|concurrency|race\s*condition|synchronized|thread)') {
        return "CONCURRENCY_LOCK_SAFETY"
    }
    if ($text -match '(?:null\s*pointer|nullpointer|edge\s*case|boundary|unhandled|overflow)') {
        return "EDGE_CASE_BOUNDARY_SAFETY"
    }
    if ($text -match '(?:backward\s*compat|compatibility|protocol\s*break|schema\s*drift)') {
        return "BACKWARD_COMPATIBILITY_BREAK"
    }
    return "DOMAIN_LOGIC_DEFECT"
}

# 1. Collect candidate review-mailbox files
$mailboxFiles = [System.Collections.Generic.List[string]]::new()
if (-not [string]::IsNullOrWhiteSpace($MailboxPath)) {
    $fullMbPath = if ([System.IO.Path]::IsPathRooted($MailboxPath)) { $MailboxPath } else { Join-Path $wsRoot $MailboxPath }
    if (Test-Path -LiteralPath $fullMbPath -PathType Leaf) {
        $mailboxFiles.Add($fullMbPath)
    }
} else {
    $specsDir = Join-Path $wsRoot ".ai-workspace\specs\features"
    if (Test-Path -LiteralPath $specsDir -PathType Container) {
        $foundMbs = Get-ChildItem -LiteralPath $specsDir -Filter "review-mailbox.json" -Recurse -File -ErrorAction SilentlyContinue
        foreach ($f in $foundMbs) {
            $mailboxFiles.Add($f.FullName)
        }
    }
}

# 2. Extract issues
$extractedPatterns = [System.Collections.Generic.List[object]]::new()

foreach ($mbFile in $mailboxFiles) {
    try {
        $raw = [System.IO.File]::ReadAllText($mbFile, [System.Text.Encoding]::UTF8)
        $data = ConvertFrom-Json $raw -Depth 100
        $feature = [string](Get-SafeValue $data 'feature' 'Unknown')
        
        if (-not [string]::IsNullOrWhiteSpace($ModuleFilter) -and $feature -notmatch $ModuleFilter) {
            continue
        }

        $history = Get-SafeValue $data 'history'
        if ($null -ne $history) {
            foreach ($h in $history) {
                $verdict = Get-SafeValue $h 'reviewVerdict'
                if ($null -ne $verdict) {
                    $verdictKind = [string](Get-SafeValue $verdict 'verdict' '')
                    if ($verdictKind -eq "REJECTED") {
                        $issues = Get-SafeValue $verdict 'issues'
                        if ($null -ne $issues) {
                            foreach ($iss in $issues) {
                                $prob = [string](Get-SafeValue $iss 'problem' '')
                                $fix = [string](Get-SafeValue $iss 'fixSuggestion' '')
                                $file = [string](Get-SafeValue $iss 'file' '')
                                $sev = [string](Get-SafeValue $iss 'severity' 'MEDIUM')
                                $category = Classify-DefectCategory -Problem $prob -FixSuggestion $fix -File $file

                                $extractedPatterns.Add([ordered]@{
                                    category = $category
                                    problem = $prob
                                    fixSuggestion = $fix
                                    file = $file
                                    severity = $sev
                                    feature = $feature
                                    source = "REVIEW_MAILBOX"
                                })
                            }
                        }
                    }
                }
            }
        }
    } catch {
        Write-Warning "Failed to parse mailbox file '$mbFile': $_"
    }
}

# 3. Also scan BUGS.md if available
$bugsFiles = [System.Collections.Generic.List[string]]::new()
$rootBugs = Join-Path $wsRoot "BUGS.md"
if (Test-Path -LiteralPath $rootBugs -PathType Leaf) { $bugsFiles.Add($rootBugs) }
$specsBugs = Join-Path $wsRoot ".ai-workspace\specs\features"
if (Test-Path -LiteralPath $specsBugs -PathType Container) {
    $foundBugs = Get-ChildItem -LiteralPath $specsBugs -Filter "*BUG*.md" -Recurse -File -ErrorAction SilentlyContinue
    foreach ($fb in $foundBugs) { $bugsFiles.Add($fb.FullName) }
}

foreach ($bFile in $bugsFiles) {
    try {
        $lines = [System.IO.File]::ReadAllLines($bFile)
        foreach ($l in $lines) {
            if ($l -match '^\s*[-*]\s*\[(.*?)\]\s*(.*)$') {
                $sev = $Matches[1]
                $desc = $Matches[2]
                $cat = Classify-DefectCategory -Problem $desc -FixSuggestion "" -File ""
                $extractedPatterns.Add([ordered]@{
                    category = $cat
                    problem = $desc
                    fixSuggestion = "Follow standard architecture constraints"
                    file = (Split-Path -Leaf $bFile)
                    severity = if ($sev -match 'HIGH|CRITICAL') { "HIGH" } else { "MEDIUM" }
                    feature = "Global"
                    source = "BUGS_DOC"
                })
            }
        }
    } catch {}
}

# 4. Group & Aggregate Patterns
$grouped = $extractedPatterns | Group-Object -Property { (Get-SafeValue $_ 'category') }

$severityWeight = @{
    "CRITICAL" = 4
    "HIGH" = 3
    "MEDIUM" = 2
    "LOW" = 1
    "NONE" = 0
}

$patternList = [System.Collections.Generic.List[object]]::new()
foreach ($g in $grouped) {
    $count = $g.Count
    $items = @($g.Group)
    $maxSev = "MEDIUM"
    $maxWeight = 0
    foreach ($it in $items) {
        $itSev = [string](Get-SafeValue $it 'severity' 'MEDIUM')
        $w = if ($severityWeight.ContainsKey($itSev)) { $severityWeight[$itSev] } else { 1 }
        if ($w -gt $maxWeight) {
            $maxWeight = $w
            $maxSev = $itSev
        }
    }
    
    $sampleProblems = @($items | ForEach-Object { [string](Get-SafeValue $_ 'problem') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique | Select-Object -First 3)
    $sampleFixes = @($items | ForEach-Object { [string](Get-SafeValue $_ 'fixSuggestion') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique | Select-Object -First 2)
    $affectedFiles = @($items | ForEach-Object { [string](Get-SafeValue $_ 'file') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique | Select-Object -First 3)

    $patternList.Add([pscustomobject]@{
        Category = [string]$g.Name
        Occurrences = $count
        MaxSeverity = $maxSev
        Weight = ($maxWeight * 100) + $count
        Problems = $sampleProblems
        FixSuggestions = $sampleFixes
        AffectedFiles = $affectedFiles
    })
}

# Sort by weighted score descending
$sortedPatterns = @($patternList | Sort-Object -Property Weight -Descending | Select-Object -First $MaxPatterns)

# 5. Render Markdown Document within Token Budget
$headerMeta = "<!-- context-meta owner:shuyongqiang reviewedAt:$([DateTime]::UtcNow.ToString('yyyy-MM')) expiresAt:$([DateTime]::UtcNow.AddMonths(3).ToString('yyyy-MM')) -->"

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine($headerMeta)
[void]$sb.AppendLine("# 历史缺陷模式与防范基线 (Defect Memory & Prevention Guidance)")
[void]$sb.AppendLine()
[void]$sb.AppendLine("> 本文档由 ``scripts/sync-defect-memory.ps1`` 自动聚合自历史 Dual-Agent Review 驳回记录与缺陷日志。")
[void]$sb.AppendLine("> 所有实现者 (``implementation-engine``) 与审查者 (``logic-auditor``) 必须将此作为防范单一真源。")
[void]$sb.AppendLine()
[void]$sb.AppendLine("## 一、 缺陷模式频次与高危分布")
[void]$sb.AppendLine()
[void]$sb.AppendLine("| 缺陷分类 (Category) | 历史频次 (Count) | 最高危害 (Severity) | 典型症状 (Key Signature) |")
[void]$sb.AppendLine("|---|:---:|:---:|---|")

if ($sortedPatterns.Count -eq 0) {
    [void]$sb.AppendLine("| NONE_RECORDED | 0 | LOW | 暂无历史驳回缺陷记录 |")
} else {
    foreach ($p in $sortedPatterns) {
        $sig = if ($p.Problems.Count -gt 0) { $p.Problems[0] -replace '\|', '/' } else { "Generic defect" }
        if ($sig.Length -gt 60) { $sig = $sig.Substring(0, 57) + "..." }
        [void]$sb.AppendLine("| **$($p.Category)** | $($p.Occurrences) | $($p.MaxSeverity) | $sig |")
    }
}

[void]$sb.AppendLine()
[void]$sb.AppendLine("## 二、 核心反模式规避法则 (Rule Guidelines)")
[void]$sb.AppendLine()

$categoryDescriptions = @{
    "STATIC_IMPORT_DISALLOWED" = @{
        Title = "禁止 Java 静态导入 (Disallow Static Imports)"
        Rule = "所有 Java 代码禁止使用 ``import static``，必须使用全类名限定（如 ``Math.max``、``DateUtil.now()``）以保持命名空间清晰。"
        Prevention = "使用 ``guard-code-quality.ps1`` (Rule 101) 自动拦截，或通过 IDE 配置禁用 static import 自动补全。"
    }
    "MUTATION_WITHOUT_PERSISTENCE" = @{
        Title = "内存状态修改缺失持久化 (State Mutation Without Persistence)"
        Rule = "凡对 Player/Entity 执行状态修改（如 ``costGold``, ``addExp``, ``setVipLevel``），必须紧随 ``player.update()`` 或持久化落库。"
        Prevention = "遵循状态变异 5 步曲：前置断言 -> 内存修改 -> 持久化调用 -> 后置断言 -> 冷重载检验。"
    }
    "MISSING_COLD_RELOAD" = @{
        Title = "单元测试虚假绿灯与缺失冷重载 (Missing Cold-Reload Oracle)"
        Rule = "测试持久化数据时，严禁仅做内存比对；必须重新从 DAO/Mapper/Redis/DB 重新加载对象再断言。"
        Prevention = "在 ``05_test_coverage.json`` 声明 ``PERSISTENCE_COLD_RELOAD`` 断言及 ``coldReloadEntity``。"
    }
    "DUPLICATE_ERROR_CODE" = @{
        Title = "同方法重复失败错误码 (Duplicate Failure Return Codes)"
        Rule = "同一方法内不同失败分支禁止复用相同错误码，以保证排查时能够根据错误码精准唯一定位失败路径。"
        Prevention = "每条错误校验分支分配独立错误码，或复用领域通用错误码时带清晰上下文日志。"
    }
    "NAKED_MAP_IN_PROTOCOL" = @{
        Title = "协议层裸用原生 Map (Naked Map in Protocol Handlers)"
        Rule = "对外通信与协议处理层禁止直接裸传无类型校验的 ``Map<String, Object>``，必须使用强类型 DTO/PB 对象。"
        Prevention = "使用强类型 Protocol Buffers 或 JavaBean 包装通信负载。"
    }
    "CONCURRENCY_LOCK_SAFETY" = @{
        Title = "并发锁与超时保护缺失 (Missing Concurrency Lock / Timeout)"
        Rule = "跨线程/分布式状态修改必须配置明确的锁获取超时（如 5s fail-safe），禁止无超时的阻塞等待。"
        Prevention = "统一使用 ``tryLock(5, TimeUnit.SECONDS)`` 并在 ``finally`` 块释放锁。"
    }
    "EDGE_CASE_BOUNDARY_SAFETY" = @{
        Title = "边界与空指针防护 (Edge Cases & Null Safety)"
        Rule = "集合取下标、数值溢出运算、非空状态解引用必须具备防御式前置判定。"
        Prevention = "入参强制校验，数值溢出使用 ``Math.addExact`` 或边界 clamp。"
    }
    "BACKWARD_COMPATIBILITY_BREAK" = @{
        Title = "协议与存储兼容性断裂 (Backward Compatibility Break)"
        Rule = "已上线协议字段与持久化反序列化结构禁止删除或修改既有类型，仅允许增量兼容扩展。"
        Prevention = "设计阶段强制执行 ``Mode D`` 拓扑穿透审计与滚更兼容演练。"
    }
}

foreach ($p in $sortedPatterns) {
    $info = if ($categoryDescriptions.ContainsKey($p.Category)) {
        $categoryDescriptions[$p.Category]
    } else {
        @{
            Title = "$($p.Category) 缺陷防范"
            Rule = "严格遵守业务设计契约与架构分层规范。"
            Prevention = "增强测试覆盖与 Dual-Agent Review 质量门禁。"
        }
    }

    [void]$sb.AppendLine("### 2.$($sortedPatterns.IndexOf($p) + 1) $($info.Title)")
    [void]$sb.AppendLine("- **核心规则**：$($info.Rule)")
    [void]$sb.AppendLine("- **防范措施**：$($info.Prevention)")
    if ($p.Problems.Count -gt 0) {
        [void]$sb.AppendLine("- **典型案例**：")
        foreach ($pr in $p.Problems) {
            [void]$sb.AppendLine("  - ``$pr``")
        }
    }
    if ($p.FixSuggestions.Count -gt 0) {
        [void]$sb.AppendLine("- **修复指引**：")
        foreach ($fx in $p.FixSuggestions) {
            [void]$sb.AppendLine("  - $fx")
        }
    }
    [void]$sb.AppendLine()
}

$markdownContent = $sb.ToString()

# 6. Ensure token / byte budget
$maxChars = $MaxTokens * 6  # ~1500 tokens ≈ 9000 chars
if ($markdownContent.Length -gt $maxChars) {
    $markdownContent = $markdownContent.Substring(0, $maxChars) + "`n`n<!-- Truncated by token budget limit -->`n"
}

# 7. Write output
$outDir = Split-Path -Parent $outputFile
if (-not (Test-Path -LiteralPath $outDir)) {
    [System.IO.Directory]::CreateDirectory($outDir) | Out-Null
}
[System.IO.File]::WriteAllText($outputFile, $markdownContent, [System.Text.Encoding]::UTF8)

if (-not $Json) {
    Write-Host "✅ Synced $($sortedPatterns.Count) defect patterns to: $outputFile" -ForegroundColor Green
}

$resultObj = [pscustomobject]@{
    WorkspaceRoot = $wsRoot
    OutputFile = $outputFile
    TotalPatternsFound = $extractedPatterns.Count
    UniqueCategories = $sortedPatterns.Count
    Categories = @($sortedPatterns | ForEach-Object { $_.Category })
    FileSizeBytes = (Get-Item -LiteralPath $outputFile).Length
    SyncedAt = [DateTime]::UtcNow.ToString("o")
}

if ($Json) {
    return ($resultObj | ConvertTo-Json -Depth 5)
}
if ($PassThru) {
    return $resultObj
}
