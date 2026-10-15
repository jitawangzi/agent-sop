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
    param([string]$WorkspacePath)
    $path = Resolve-AiSopWorkspaceChild $WorkspacePath '.ai-workspace/context/verification-inputs.json'
    if (-not [IO.File]::Exists($path)) { return @{ include=@(); exclude=@(); digest='' } }
    try {
        $raw = [IO.File]::ReadAllText($path)
        if (-not (Test-Json -Json $raw -SchemaFile (Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/verification-inputs.schema.json') -ErrorAction Stop)) { throw 'schema mismatch' }
        $policy = ConvertFrom-AiSopWorkflowJson $raw -AsHashtable
        foreach ($relative in @($policy.include) + @($policy.exclude | ForEach-Object { $_.path })) {
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
        return @{ include=@($policy.include); exclude=@($policy.exclude); digest=(Get-AiSopWorkflowSha256 (ConvertTo-AiSopWorkflowCanonicalJson $policy)) }
    } catch { throw "INPUT_POLICY_INVALID: $path; $($_.Exception.Message)" }
}

function Get-AiSopInputDigest {
    param($Snapshot)
    $files = [Collections.Generic.SortedDictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($key in $Snapshot.files.Keys) { $files[$key] = $Snapshot.files[$key] }
    $lines = @($files.GetEnumerator() | ForEach-Object { "$($_.Key.Length):$($_.Key):$($_.Value)" })
    $header = $Snapshot.algorithm + "`n"
    if ($Snapshot.algorithm -eq 'inputs-v3') { $header += $Snapshot.policyDigest + "`n" }
    return Get-AiSopWorkflowSha256 ($header + ($lines -join "`n"))
}

function Get-AiSopInputSnapshot {
    param([string]$WorkspacePath)
    $root = Resolve-PhysicalPathIdentity $WorkspacePath
    $policy = Get-AiSopInputPolicy $root
    $excludedDirectories = @('.git', '.svn', '.ai-sop', '.ai-workspace', '.claude', '.agents', '.agent', '.gemini', '.cursor', '.idea', '.vscode', '.superpowers', 'node_modules', '.gradle', '__pycache__')
    $outputDirectories = @('build', 'target', 'bin', 'obj', 'out', 'classes')
    $excludedFiles = @('.git', 'AGENTS.md', 'CLAUDE.md', 'ANTIGRAVITY.md', 'GEMINI.md', 'compile-evidence.json', 'test-evidence.json', '.guard-token.json')
    $files = [Collections.Generic.SortedDictionary[string,string]]::new([StringComparer]::Ordinal)
    $pending = [Collections.Generic.Stack[object]]::new(); $pending.Push(@{path=$root; excluded=$false})
    while ($pending.Count) {
        $frame = $pending.Pop(); $dir = $frame.path
        $projectRoot = $dir -ceq $root
        if (-not $projectRoot) { $projectRoot = @('pom.xml','build.gradle','build.gradle.kts') | Where-Object { [IO.File]::Exists((Join-Path $dir $_)) } | Select-Object -First 1 }
        $webOutputRoot = (Split-Path -Leaf $dir) -ceq 'WEB-INF' -and [IO.File]::Exists((Join-Path $dir 'web.xml'))
        foreach ($item in Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop) {
            $rel = [IO.Path]::GetRelativePath($root, $item.FullName).Replace('\', '/')
            # Never descend into VCS stores or evidence even if an ancestor was
            # explicitly included (e.g. a vendored dependency containing .git).
            if ($item.Name -in @('.git','.svn') -or $rel -match '^\.ai-sop(/|$)|^\.ai-workspace/(specs|\.runtime)(/|$)') { continue }
            $include = $false; $descend = $false
            foreach ($entry in $policy.include) {
                if (Test-AiSopInputPathWithin $rel $entry) { $include=$true }
                if ($item.PSIsContainer -and (Test-AiSopInputPathWithin $entry $rel)) { $descend=$true }
            }
            $exclude = $false
            foreach ($rule in $policy.exclude) { if (Test-AiSopInputPathWithin $rel $rule.path) { $exclude=$true; break } }
            $defaultExcluded = $frame.excluded -or ($item.PSIsContainer -and ($item.Name -in $excludedDirectories -or ($projectRoot -and $item.Name -in $outputDirectories) -or ($webOutputRoot -and $item.Name -ceq 'classes'))) -or
                ($dir -ceq $root -and $item.Name -eq '.ai-sop-staging') -or
                (-not $item.PSIsContainer -and ($item.Name -in $excludedFiles -or $item.Extension -eq '.tmp' -or $item.Name -match '\.log(?:\.\d+)*(?:\.(?:zip|gz|bz2|xz))?$'))
            if (($exclude -or $defaultExcluded) -and -not $include -and -not $descend) { continue }
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "INPUT_LINK_UNSUPPORTED: $($item.FullName)" }
            if ($item.PSIsContainer) { $pending.Push(@{path=$item.FullName; excluded=($defaultExcluded -and -not $include)}); continue }
            $physical = Resolve-AiSopWorkspaceChild $root $rel
            $files[$rel] = (Get-FileHash -LiteralPath $physical -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    # Preserve existing v2 evidence when no policy has been configured.
    $snapshot = @{ algorithm='inputs-v2'; files=$files }
    if ($policy.digest) { $snapshot.algorithm='inputs-v3'; $snapshot.policyDigest=$policy.digest }
    $snapshot.digest = Get-AiSopInputDigest $snapshot
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

function Read-AiSopVerificationInputs {
    param($Record, [string]$WorkspacePath, $ValidationContext)
    if (-not $Record.inputsRef) { return @{ files=$Record.inputs } } # Legacy inline records.
    $ref = [string]$Record.inputsRef
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
