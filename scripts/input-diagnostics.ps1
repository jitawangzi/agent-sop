#requires -Version 7.0
# Read-only explanations; all selection decisions come from the real scanner.
function Get-AiSopInputPathExplanation {
    param([string]$WorkspacePath, [string]$Path, $Trace)
    $physical=Resolve-AiSopWorkspaceChild $WorkspacePath $Path
    $relative=[IO.Path]::GetRelativePath($WorkspacePath,$physical).Replace('\','/')
    $match=@($Trace.entries | Where-Object { Test-AiSopInputPathWithin $relative $_.path } | Sort-Object { $_.path.Length } -Descending | Select-Object -First 1)
    $comparison=if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $exact=$match.Count -and ([string]$match[0].path).Equals($relative,$comparison)
    if ($match.Count -and ($exact -or $match[0].decision -eq 'EXCLUDED')) {
        return @{path=$Path;exists=(Test-Path -LiteralPath $physical);decision=$match[0].decision;rule=$match[0].rule;matchedRules=$match[0].matchedRules;evaluatedPath=$match[0].path;inherited=(-not $exact)}
    }
    return @{path=$Path;exists=(Test-Path -LiteralPath $physical);decision='NOT_FOUND';rule=$null;matchedRules=@();evaluatedPath=$null;inherited=$false}
}

function Get-AiSopInputInspection {
    param([string]$WorkspacePath, [string[]]$InputPath=@(), [string]$CandidatePolicy, [switch]$ExplainOnly)
    $WorkspacePath=Resolve-PhysicalPathIdentity $WorkspacePath
    foreach ($path in $InputPath) { Resolve-AiSopWorkspaceChild $WorkspacePath $path | Out-Null }
    # Fail before any input traversal, including the first full comparison scan.
    $candidatePolicyValue=if ($CandidatePolicy) { Get-AiSopInputPolicy $WorkspacePath $CandidatePolicy } else { $null }
    if ($ExplainOnly) {
        if (-not $InputPath.Count) { throw 'INPUT_EXPLANATION_PATH_REQUIRED: -ExplainOnly requires -InputPath' }
        $policy=Get-AiSopInputPolicy $WorkspacePath
        $paths=@($InputPath | ForEach-Object { [IO.Path]::GetRelativePath($WorkspacePath,[IO.Path]::GetFullPath((Join-Path $WorkspacePath $_))).Replace('\','/') })
        $trace=@{}
        Invoke-AiSopInputTraversal $WorkspacePath -Diagnostics $trace -ExplainOnly -ExplainPaths $paths
        $report=[ordered]@{
            schemaVersion='1.0'; readOnly=$true; mode='RULES_ONLY'; workspace=$WorkspacePath; algorithm=$null; inputDigest=$null; policyDigest=$policy.digest
            statistics=@{scannedEntries=$trace.scannedEntries;hashedFiles=0;readBytes=0;elapsedMilliseconds=$trace.elapsedMilliseconds}
            largestFiles=@(); paths=@(foreach ($path in $InputPath) { Get-AiSopInputPathExplanation $WorkspacePath $path $trace }); candidate=$null
            notes=@('Rules and path metadata only; no input contents were hashed. This report is not verification evidence or a complete input inventory.', 'include adds inputs; it is not a whitelist.')
        }
        if ($CandidatePolicy) {
            $candidateTrace=@{}
            Invoke-AiSopInputTraversal $WorkspacePath -Diagnostics $candidateTrace -PolicyPath $CandidatePolicy -ExplainOnly -ExplainPaths $paths
            $report.candidate=@{path=$CandidatePolicy;mode='RULES_ONLY';policyDigest=$candidatePolicyValue.digest;policyChanged=($policy.digest -cne $candidatePolicyValue.digest);paths=@(foreach ($path in $InputPath) { Get-AiSopInputPathExplanation $WorkspacePath $path $candidateTrace })}
        }
        return $report
    }
    $trace=@{}
    $snapshot=Get-AiSopInputSnapshot $WorkspacePath -Diagnostics $trace
    $report=[ordered]@{
        schemaVersion='1.0'; readOnly=$true; mode='FULL'; workspace=$WorkspacePath; algorithm=$snapshot.algorithm; inputDigest=$snapshot.digest
        policyDigest=[string]$snapshot.policyDigest
        statistics=@{scannedEntries=$trace.scannedEntries;hashedFiles=$trace.hashedFiles;readBytes=$trace.readBytes;elapsedMilliseconds=$trace.elapsedMilliseconds}
        largestFiles=@($trace.entries | Where-Object { -not $_.directory -and $_.decision -eq 'INCLUDED' } | Sort-Object @{Expression='bytes';Descending=$true},path | Select-Object -First 10 | ForEach-Object { @{path=$_.path;bytes=$_.bytes} })
        paths=@(foreach ($path in $InputPath) { Get-AiSopInputPathExplanation $WorkspacePath $path $trace })
        candidate=$null
        notes=@('This is a live read-only observation, not saved verification evidence. Excluded subtrees are pruned; their children are explained by the boundary rule.', 'include adds inputs; it is not a whitelist. Policy changes invalidate evidence even when the selected file set stays the same.')
    }
    if ($CandidatePolicy) {
        $candidateTrace=@{}
        $candidate=Get-AiSopInputSnapshot $WorkspacePath -Diagnostics $candidateTrace -PolicyPath $CandidatePolicy
        $added=@($candidate.files.Keys | Where-Object { -not $snapshot.files.ContainsKey($_) } | Sort-Object -CaseSensitive)
        $removed=@($snapshot.files.Keys | Where-Object { -not $candidate.files.ContainsKey($_) } | Sort-Object -CaseSensitive)
        $changed=@($candidate.files.Keys | Where-Object { $snapshot.files.ContainsKey($_) -and $snapshot.files[$_] -cne $candidate.files[$_] } | Sort-Object -CaseSensitive)
        $report.candidate=@{
            path=$CandidatePolicy;algorithm=$candidate.algorithm;policyDigest=[string]$candidate.policyDigest
            policyChanged=([string]$snapshot.policyDigest -cne [string]$candidate.policyDigest); added=$added;removed=$removed
            contentChangedDuringComparison=$changed
            statistics=@{scannedEntries=$candidateTrace.scannedEntries;hashedFiles=$candidateTrace.hashedFiles;readBytes=$candidateTrace.readBytes;elapsedMilliseconds=$candidateTrace.elapsedMilliseconds}
            paths=@(foreach ($path in $InputPath) { Get-AiSopInputPathExplanation $WorkspacePath $path $candidateTrace })
        }
    }
    return $report
}

function Write-AiSopInputInspection {
    param($Report, [switch]$Json)
    if ($Json) { $Report | ConvertTo-Json -Depth 20; return }
    function Write-PathExplanation($Path, [string]$Indent) {
        $decision=if ($Path.decision -eq 'TRAVERSE_ONLY') { 'traversed only to reach explicitly included descendants' } else { $Path.decision }
        $rule=''
        if ($Path.rule) {
            $label=[string]$Path.rule.kind
            if ($Path.rule.path) { $label+=':' + $Path.rule.path }
            $rule=" [$label]"
            if ($Path.rule.reason) { $rule+=' ' + $Path.rule.reason }
        }
        Write-Output "$Indent$($Path.path): $decision$rule"
        if ($Path.inherited) { Write-Output "${Indent}  ancestor pruned at $($Path.evaluatedPath); no child contents read" }
    }
    Write-Output "Inputs (read-only) — $($Report.workspace)"
    if ($Report.mode -eq 'RULES_ONLY') { Write-Output '  rules only: no content scan, input digest or full inventory' }
    else { Write-Output "  algorithm=$($Report.algorithm) files=$($Report.statistics.hashedFiles) readBytes=$($Report.statistics.readBytes) elapsedMs=$($Report.statistics.elapsedMilliseconds) scannedEntries=$($Report.statistics.scannedEntries)" }
    foreach ($path in $Report.paths) {
        Write-PathExplanation $path '  '
    }
    foreach ($file in $Report.largestFiles) { Write-Output "  large input: $($file.bytes) bytes $($file.path)" }
    if ($Report.candidate) {
        $candidate=$Report.candidate
        if ($Report.mode -eq 'RULES_ONLY') { Write-Output "  candidate=$($candidate.path) policyChanged=$($candidate.policyChanged); requested paths only" }
        else { Write-Output "  candidate=$($candidate.path) policyChanged=$($candidate.policyChanged) files=$($candidate.statistics.hashedFiles) readBytes=$($candidate.statistics.readBytes) elapsedMs=$($candidate.statistics.elapsedMilliseconds)" }
        foreach ($path in $candidate.added) { Write-Output "    + $path" }
        foreach ($path in $candidate.removed) { Write-Output "    - $path" }
        foreach ($path in $candidate.contentChangedDuringComparison) { Write-Output "    ! content changed between scans: $path; repeat while files are stable" }
        foreach ($path in $candidate.paths) { Write-PathExplanation $path '    ' }
    }
    foreach ($note in $Report.notes) { Write-Output "  $note" }
}
