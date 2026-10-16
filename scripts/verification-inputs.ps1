#requires -Version 7.0
# Content inputs and portable, deduplicated manifests. State records referencing
# these immutable artifacts are still committed by the workflow transaction.

function Resolve-AiSopWorkspaceChild {
    param([string]$WorkspacePath, [string]$RelativePath)
    if ([IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '(^|[/\\])\.\.([/\\]|$)') { throw 'WORKSPACE_PATH_ESCAPE' }
    $root = (Resolve-PhysicalPathIdentity $WorkspacePath).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $path = Resolve-PhysicalPathIdentity (Join-Path $root $RelativePath)
    $comparison = if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $path.StartsWith($root, $comparison)) { throw "WORKSPACE_PATH_ESCAPE: $RelativePath" }
    return $path
}

function Test-AiSopInputPathWithin {
    param([string]$Path, [string]$Parent)
    $comparison = if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return $Path.Equals($Parent, $comparison) -or $Path.StartsWith($Parent + '/', $comparison)
}

function Get-AiSopInputPolicy {
    param([string]$WorkspacePath, [string]$PolicyPath)
    $path = Resolve-AiSopWorkspaceChild $WorkspacePath $(if ($PolicyPath) { $PolicyPath } else { '.ai-workspace/context/verification-inputs.json' })
    if (-not [IO.File]::Exists($path)) {
        if ($PolicyPath) { throw "INPUT_POLICY_MISSING: $path" }
        return @{ include=@(); exclude=@(); nonExecutable=@(); digest='' }
    }
    try {
        $raw = [IO.File]::ReadAllText($path)
        if (-not (Test-Json -Json $raw -SchemaFile (Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/verification-inputs.schema.json') -ErrorAction Stop)) { throw 'schema mismatch' }
        $policy = ConvertFrom-AiSopWorkflowJson $raw -AsHashtable
        foreach ($relative in @($policy.include) + @($policy.exclude | ForEach-Object { $_.path }) + @($policy.nonExecutable | Where-Object { $_ } | ForEach-Object { $_.path })) {
            # Literal workspace-relative files or subtrees, not globs. Avoid
            # accidental broad exclusions or platform-dependent path syntax.
            if ($relative -match '(^|/)\.{1,2}(/|$)|[\\:*?\[\]]|^/|/$|//') { throw "invalid relative path: $relative" }
            Resolve-AiSopWorkspaceChild $WorkspacePath $relative | Out-Null
        }
        foreach ($relative in $policy.include) {
            if ($relative -match '(^|/)\.(git|svn)(/|$)|^\.ai-sop(/|$)|^\.ai-workspace/(specs|\.runtime)(/|$)' -or $relative -eq '.ai-workspace') {
                throw "governance/VCS data cannot be an input: $relative"
            }
            if (-not (Test-Path -LiteralPath (Join-Path $WorkspacePath $relative))) { throw "included path missing: $relative" }
        }
        foreach ($rule in $policy.exclude) { if ([string]::IsNullOrWhiteSpace($rule.reason)) { throw 'exclusion reason required' } }
        foreach ($rule in @($policy.nonExecutable | Where-Object { $_ })) { if ([string]::IsNullOrWhiteSpace($rule.reason)) { throw 'non-executable input reason required' } }
        $comparison = if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        foreach ($entry in $policy.include) {
            foreach ($rule in $policy.exclude) {
                if ($entry.Equals($rule.path, $comparison)) { throw "conflicting include/exclude path: $entry" }
            }
        }
        return @{ include=@($policy.include); exclude=@($policy.exclude); nonExecutable=@($policy.nonExecutable | Where-Object { $_ }); digest=(Get-AiSopWorkflowSha256 (ConvertTo-AiSopWorkflowCanonicalJson $policy)) }
    } catch { throw "INPUT_POLICY_INVALID: $path; $($_.Exception.Message)" }
}

function Get-AiSopInputDigest {
    param($Snapshot)
    $files = [Collections.Generic.SortedDictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($key in $Snapshot.files.Keys) { $files[$key] = $Snapshot.files[$key] }
    $lines = @($files.GetEnumerator() | ForEach-Object { "$($_.Key.Length):$($_.Key):$($_.Value)" })
    $header = $Snapshot.algorithm + "`n"
    if ($Snapshot.algorithm -in @('inputs-v3','inputs-v4')) { $header += $Snapshot.policyDigest + "`n" }
    return Get-AiSopWorkflowSha256 ($header + ($lines -join "`n"))
}

function Assert-AiSopInputCaptureBudget {
    param($Budget)
    if ($Budget -and $Budget.timer.ElapsedMilliseconds -ge $Budget.milliseconds) { throw 'INPUT_CAPTURE_BUDGET_EXCEEDED: time' }
}

function Get-AiSopBudgetedFileHash {
    param([string]$Path, $Budget, $Diagnostics)
    Assert-AiSopInputCaptureBudget $Budget
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $hash=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        if ($Budget -and $stream.Length -gt $Budget.remainingBytes) { throw 'INPUT_CAPTURE_BUDGET_EXCEEDED: bytes' }
        $buffer=[byte[]]::new(65536)
        while ($true) {
            Assert-AiSopInputCaptureBudget $Budget
            $count=$stream.Read($buffer,0,$buffer.Length)
            if (-not $count) { break }
            if ($Budget) {
                $Budget.remainingBytes-=$count
                if ($Budget.remainingBytes -lt 0) { throw 'INPUT_CAPTURE_BUDGET_EXCEEDED: bytes' }
            }
            if ($Diagnostics) { $Diagnostics.readBytes += $count }
            $hash.AppendData($buffer,0,$count)
        }
        return [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
    } finally { $stream.Dispose(); $hash.Dispose() }
}

function Get-AiSopInputSnapshot {
    param([string]$WorkspacePath, [ValidateRange(0,60000)][int]$BudgetMilliseconds=0, [ValidateRange(1,[long]::MaxValue)][long]$MaxBytes=8MB,
        [hashtable]$Diagnostics, [string]$PolicyPath)
    Invoke-AiSopInputTraversal @PSBoundParameters
}

function Invoke-AiSopInputTraversal {
    param([string]$WorkspacePath, [ValidateRange(0,60000)][int]$BudgetMilliseconds=0, [ValidateRange(1,[long]::MaxValue)][long]$MaxBytes=8MB,
        [hashtable]$Diagnostics, [string]$PolicyPath, [switch]$ExplainOnly, [string[]]$ExplainPaths=@())
    if ($ExplainOnly -and (-not $ExplainPaths.Count -or $null -eq $Diagnostics)) { throw 'INPUT_EXPLANATION_PATH_REQUIRED' }
    # Optional diagnostics use the real traversal and hash rules. Normal task
    # operations allocate no trace and retain their existing capture budget.
    $tracing = $null -ne $Diagnostics
    if ($tracing) {
        $timer=[Diagnostics.Stopwatch]::StartNew()
        $Diagnostics.entries=[Collections.Generic.List[object]]::new()
        $Diagnostics.readBytes=[long]0; $Diagnostics.scannedEntries=0; $Diagnostics.hashedFiles=0
    }
    $budget=if ($BudgetMilliseconds) { @{timer=[Diagnostics.Stopwatch]::StartNew();milliseconds=$BudgetMilliseconds;remainingBytes=$MaxBytes} } else { $null }
    $root = Resolve-PhysicalPathIdentity $WorkspacePath
    $policy = Get-AiSopInputPolicy $root -PolicyPath $PolicyPath
    $excludedDirectories = @('.git', '.svn', '.ai-sop', '.ai-workspace', '.claude', '.agents', '.agent', '.gemini', '.cursor', '.idea', '.vscode', '.superpowers', 'node_modules', '.gradle', '__pycache__')
    $outputDirectories = @('build', 'target', 'bin', 'obj', 'out', 'classes')
    $excludedFiles = @('.git', 'AGENTS.md', 'CLAUDE.md', 'ANTIGRAVITY.md', 'GEMINI.md', 'compile-evidence.json', 'test-evidence.json', '.guard-token.json')
    $files = [Collections.Generic.SortedDictionary[string,string]]::new([StringComparer]::Ordinal)
    $pending = [Collections.Generic.Stack[object]]::new(); $pending.Push(@{path=$root; defaultExcludeLength=-1; defaultRule=$null})
    while ($pending.Count) {
        Assert-AiSopInputCaptureBudget $budget
        $frame = $pending.Pop(); $dir = $frame.path
        $projectRoot = $dir -ceq $root
        if (-not $projectRoot) { $projectRoot = @('pom.xml','build.gradle','build.gradle.kts') | Where-Object { [IO.File]::Exists((Join-Path $dir $_)) } | Select-Object -First 1 }
        $webOutputRoot = (Split-Path -Leaf $dir) -ceq 'WEB-INF' -and [IO.File]::Exists((Join-Path $dir 'web.xml'))
        # Enumerate lazily so a large directory does not defeat light Start's
        # budget before the first file. Native IO itself has no hard time limit.
        if ($ExplainOnly) {
            # Visit only the requested branches, without enumerating siblings or
            # reading input contents. Selection below is shared with full scans.
            $dirRel=[IO.Path]::GetRelativePath($root,$dir).Replace('\','/')
            $children=@(foreach ($requested in $ExplainPaths) {
                if ($dirRel -eq '.') { $requested.Split('/')[0] }
                elseif ((Test-AiSopInputPathWithin $requested $dirRel) -and $requested.Length -gt $dirRel.Length) { $requested.Substring($dirRel.Length+1).Split('/')[0] }
            }) | Sort-Object -Unique
            $entries=@(foreach ($name in $children) {
                $child=Join-Path $dir $name
                if (Test-Path -LiteralPath $child) { Get-Item -LiteralPath $child -Force -ErrorAction Stop }
            })
            $iterator=([Collections.Generic.List[IO.FileSystemInfo]]$entries).GetEnumerator()
        } else { $iterator=[IO.DirectoryInfo]::new($dir).EnumerateFileSystemInfos().GetEnumerator() }
        try { while ($iterator.MoveNext()) {
            Assert-AiSopInputCaptureBudget $budget
            $item=$iterator.Current
            $isDirectory=($item.Attributes -band [IO.FileAttributes]::Directory) -ne 0
            $rel = [IO.Path]::GetRelativePath($root, $item.FullName).Replace('\', '/')
            if ($tracing) { $Diagnostics.scannedEntries++ }
            # Never descend into VCS stores or evidence even if an ancestor was
            # explicitly included (e.g. a vendored dependency containing .git).
            if ($item.Name -in @('.git','.svn') -or $rel -match '^\.ai-sop(/|$)|^\.ai-workspace/(specs|\.runtime)(/|$)') {
                if ($tracing) { $Diagnostics.entries.Add(@{path=$rel;directory=$isDirectory;decision='EXCLUDED';rule=@{kind='PROTECTED';path=$rel};matchedRules=@();bytes=0}) }
                continue
            }
            $includeLength = -1; $excludeLength = -1; $descend = $false
            if ($tracing) { $matched=[Collections.Generic.List[object]]::new(); $includeRule=$null; $excludeRule=$null }
            foreach ($entry in $policy.include) {
                if (Test-AiSopInputPathWithin $rel $entry) {
                    if ($tracing) { $rule=@{kind='INCLUDE';path=$entry}; $matched.Add($rule); if ($entry.Length -gt $includeLength) { $includeRule=$rule } }
                    $includeLength=[Math]::Max($includeLength,$entry.Length)
                }
                if ($isDirectory -and (Test-AiSopInputPathWithin $entry $rel)) { $descend=$true }
            }
            foreach ($rule in $policy.exclude) {
                if (Test-AiSopInputPathWithin $rel $rule.path) {
                    if ($tracing) { $match=@{kind='EXCLUDE';path=$rule.path;reason=$rule.reason}; $matched.Add($match); if ($rule.path.Length -gt $excludeLength) { $excludeRule=$match } }
                    $excludeLength=[Math]::Max($excludeLength,$rule.path.Length)
                }
            }
            $defaultExcluded = ($isDirectory -and ($item.Name -in $excludedDirectories -or ($projectRoot -and $item.Name -in $outputDirectories) -or ($webOutputRoot -and $item.Name -ceq 'classes'))) -or
                ($dir -ceq $root -and $item.Name -eq '.ai-sop-staging') -or
                (-not $isDirectory -and ($item.Name -in $excludedFiles -or $item.Extension -eq '.tmp' -or $item.Name -match '\.log(?:\.\d+(?:[.-]\d+)*)*(?:\.(?:zip|gz|bz2|xz))?$'))
            # The most specific path wins. An explicit include can override a
            # default at the same path, but not a deeper output/log exclusion.
            # Retain the ancestor default when traversing to a reincluded leaf.
            $defaultExcludeLength = if ($defaultExcluded) { $rel.Length } else { $frame.defaultExcludeLength }
            $excluded = ($excludeLength -ge 0 -and $excludeLength -gt $includeLength) -or $defaultExcludeLength -gt $includeLength
            $defaultRule=$null
            if ($tracing) {
                $defaultRule=if ($defaultExcluded) {
                    $reason=if ($isDirectory -and $item.Name -in $excludedDirectories) { 'Tool, dependency or workspace metadata directory' }
                        elseif ($isDirectory -and (($projectRoot -and $item.Name -in $outputDirectories) -or ($webOutputRoot -and $item.Name -ceq 'classes'))) { 'Build output at a detected project/output root' }
                        elseif ($dir -ceq $root -and $item.Name -eq '.ai-sop-staging') { 'Installer staging at workspace root' }
                        elseif ($item.Name -in $excludedFiles) { 'Agent instruction or generated evidence file' }
                        elseif ($item.Extension -eq '.tmp') { 'Temporary file' } else { 'Log or rotated/compressed log' }
                    @{kind='DEFAULT_EXCLUDE';path=$rel;reason=$reason}
                } else { $frame.defaultRule }
                if ($defaultRule) { $matched.Add($defaultRule) }
                $winner=if ($excluded) { if ($excludeLength -ge $defaultExcludeLength) { $excludeRule } else { $defaultRule } }
                    elseif ($includeRule) { $includeRule } else { @{kind='DEFAULT_INCLUDE';path=''} }
                $decision=if ($excluded) { if ($descend) { 'TRAVERSE_ONLY' } else { 'EXCLUDED' } } else { 'INCLUDED' }
                $trace=@{path=$rel;directory=$isDirectory;decision=$decision;rule=$winner;matchedRules=$matched.ToArray();bytes=0}
                $Diagnostics.entries.Add($trace)
            }
            if ($excluded -and -not $descend) { continue }
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "INPUT_LINK_UNSUPPORTED: $($item.FullName)" }
            if ($isDirectory) {
                if (-not $ExplainOnly -or @($ExplainPaths | Where-Object { $_.Length -gt $rel.Length -and (Test-AiSopInputPathWithin $_ $rel) }).Count) {
                    $pending.Push(@{path=$item.FullName; defaultExcludeLength=$defaultExcludeLength; defaultRule=$defaultRule})
                }
                continue
            }
            if ($ExplainOnly) { continue }
            $physical = Resolve-AiSopWorkspaceChild $root $rel
            $readBefore=if ($tracing) { $Diagnostics.readBytes } else { 0 }
            $files[$rel] = if ($budget -or $tracing) { Get-AiSopBudgetedFileHash $physical $budget $Diagnostics } else { (Get-FileHash -LiteralPath $physical -Algorithm SHA256).Hash.ToLowerInvariant() }
            if ($tracing) { $trace.bytes=$Diagnostics.readBytes-$readBefore; $Diagnostics.hashedFiles++ }
        } } finally { $iterator.Dispose() }
    }
    if ($ExplainOnly) { $Diagnostics.elapsedMilliseconds=$timer.ElapsedMilliseconds; return }
    # Preserve existing v2 evidence when no policy has been configured.
    $snapshot = @{ algorithm='inputs-v2'; files=$files }
    if ($policy.digest) { $snapshot.algorithm='inputs-v4'; $snapshot.policyDigest=$policy.digest }
    $snapshot.digest = Get-AiSopInputDigest $snapshot
    Assert-AiSopInputCaptureBudget $budget
    if ($tracing) { $Diagnostics.elapsedMilliseconds=$timer.ElapsedMilliseconds }
    return $snapshot
}

function Get-AiSopInputManifestPath {
    param([string]$WorkspacePath, [string]$Reference)
    if ($Reference -cnotmatch '^[0-9a-f]{64}$') { throw 'INPUT_MANIFEST_REFERENCE_INVALID' }
    return Resolve-AiSopWorkspaceChild $WorkspacePath ".ai-workspace/specs/.artifacts/inputs/$Reference.json"
}

function Save-AiSopInputManifest {
    param($Snapshot, [string]$WorkspacePath)
    $raw = ConvertTo-AiSopWorkflowCanonicalJson $Snapshot
    $reference = Get-AiSopWorkflowSha256 $raw
    $path = Get-AiSopInputManifestPath $WorkspacePath $reference
    if ([IO.File]::Exists($path)) {
        if ((Get-AiSopWorkflowSha256 ([IO.File]::ReadAllText($path))) -cne $reference) { throw "INPUT_MANIFEST_CORRUPT: $path" }
    } else { Write-AiSopWorkflowTextAtomic -Path $path -Text $raw }
    return $reference
}

function Read-AiSopInputManifest {
    param([string]$Reference, [string]$WorkspacePath, $ValidationContext)
    $ref = $Reference
    $cacheKey = (Resolve-PhysicalPathIdentity $WorkspacePath) + "|" + $ref
    if ($ValidationContext -and $ValidationContext.manifests.ContainsKey($cacheKey)) { $snapshot = $ValidationContext.manifests[$cacheKey] }
    else {
        $path = Get-AiSopInputManifestPath $WorkspacePath $ref
        if (-not [IO.File]::Exists($path)) { throw "INPUT_MANIFEST_MISSING: $path; sync specs/.artifacts/inputs from the source workspace or rerun verification" }
        try {
            $raw = [IO.File]::ReadAllText($path)
            if ((Get-AiSopWorkflowSha256 $raw) -cne $ref) { throw 'content hash mismatch' }
            if (-not (Test-Json -Json $raw -SchemaFile (Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/input-manifest.schema.json') -ErrorAction Stop)) { throw 'schema mismatch' }
            $snapshot = ConvertFrom-AiSopWorkflowJson $raw -AsHashtable
            if ((Get-AiSopInputDigest $snapshot) -cne $snapshot.digest) { throw 'input digest mismatch' }
        } catch { throw "INPUT_MANIFEST_CORRUPT: $path; $($_.Exception.Message)" }
        if ($ValidationContext) { $ValidationContext.manifests[$cacheKey]=$snapshot }
    }
    return $snapshot
}

function Read-AiSopVerificationInputs {
    param($Record, [string]$WorkspacePath, $ValidationContext)
    if (-not $Record.inputsRef) { return @{ files=$Record.inputs } } # Legacy inline records.
    $snapshot=Read-AiSopInputManifest ([string]$Record.inputsRef) $WorkspacePath $ValidationContext
    if ($snapshot.digest -cne $Record.inputDigest) { throw 'INPUT_MANIFEST_DIGEST_MISMATCH' }
    return $snapshot
}

function New-AiSopValidationContext {
    # Explicitly passed, invocation-local cache. Never shared across commands or
    # between the before/after snapshots of Run.
    return @{ snapshots=@{}; specDigests=@{}; manifests=@{} }
}

function Get-AiSopValidationSnapshot {
    param([string]$WorkspacePath, $ValidationContext)
    if (-not $ValidationContext) { return Get-AiSopInputSnapshot $WorkspacePath }
    $root = Resolve-PhysicalPathIdentity $WorkspacePath
    if (-not $ValidationContext.snapshots.ContainsKey($root)) {
        try { $ValidationContext.snapshots[$root]=@{ value=(Get-AiSopInputSnapshot $root) } }
        catch { $ValidationContext.snapshots[$root]=@{ error=$_.Exception.Message } }
    }
    $entry = $ValidationContext.snapshots[$root]
    if ($entry.error) { throw $entry.error }
    return $entry.value
}

function Get-AiSopRunLogPath {
    param($Record, [string]$WorkspacePath, [string]$SpecDirectory, [string]$TaskId)
    if ($Record.context.logPath) { return Resolve-AiSopWorkspaceChild $WorkspacePath $Record.context.logPath }
    if ($Record.context.logFile -notmatch '^[0-9a-f]{32}\.log$') { return $null }
    return Resolve-AiSopWorkspaceChild $WorkspacePath ([IO.Path]::GetRelativePath($WorkspacePath, (Join-Path (Split-Path -Parent (Get-AiSopTaskPath $SpecDirectory $TaskId)) $Record.context.logFile)))
}
