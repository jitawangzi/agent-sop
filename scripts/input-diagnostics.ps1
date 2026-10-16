#requires -Version 7.0
# Read-only explanations; all selection decisions come from the real scanner.
function Get-AiSopInputPathExplanation {
    param([string]$WorkspacePath, [string]$Path, $Trace)
    $physical=Resolve-AiSopWorkspaceChild $WorkspacePath $Path
    $relative=[IO.Path]::GetRelativePath($WorkspacePath,$physical).Replace('\','/')
    $match=@($Trace.entries | Where-Object { Test-AiSopInputPathWithin $relative $_.path } | Sort-Object { $_.path.Length } -Descending | Select-Object -First 1)
    if ($match.Count -and ($match[0].path -ceq $relative -or $match[0].decision -eq 'EXCLUDED')) {
        return @{path=$Path;exists=(Test-Path -LiteralPath $physical);decision=$match[0].decision;rule=$match[0].rule;matchedRules=$match[0].matchedRules;evaluatedPath=$match[0].path;inherited=($match[0].path -cne $relative)}
    }
    return @{path=$Path;exists=(Test-Path -LiteralPath $physical);decision='NOT_FOUND';rule=$null;matchedRules=@();evaluatedPath=$null;inherited=$false}
}

function Get-AiSopInputInspection {
    param([string]$WorkspacePath, [string[]]$InputPath=@(), [string]$CandidatePolicy)
    $WorkspacePath=Resolve-PhysicalPathIdentity $WorkspacePath
    foreach ($path in $InputPath) { Resolve-AiSopWorkspaceChild $WorkspacePath $path | Out-Null }
    $trace=@{}
    $snapshot=Get-AiSopInputSnapshot $WorkspacePath -Diagnostics $trace
    $report=[ordered]@{
        schemaVersion='1.0'; readOnly=$true; workspace=$WorkspacePath; algorithm=$snapshot.algorithm; inputDigest=$snapshot.digest
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
    Write-Output "Inputs (read-only) — $($Report.workspace)"
    Write-Output "  algorithm=$($Report.algorithm) files=$($Report.statistics.hashedFiles) readBytes=$($Report.statistics.readBytes) elapsedMs=$($Report.statistics.elapsedMilliseconds) scannedEntries=$($Report.statistics.scannedEntries)"
    foreach ($path in $Report.paths) {
        Write-Output "  $($path.path): $($path.decision) [$($path.rule.kind):$($path.rule.path)] $($path.rule.reason)"
        if ($path.inherited) { Write-Output "    ancestor pruned at $($path.evaluatedPath); no child contents read" }
    }
    foreach ($file in $Report.largestFiles) { Write-Output "  large input: $($file.bytes) bytes $($file.path)" }
    if ($Report.candidate) {
        $candidate=$Report.candidate
        Write-Output "  candidate=$($candidate.path) policyChanged=$($candidate.policyChanged) files=$($candidate.statistics.hashedFiles) readBytes=$($candidate.statistics.readBytes) elapsedMs=$($candidate.statistics.elapsedMilliseconds)"
        foreach ($path in $candidate.added) { Write-Output "    + $path" }
        foreach ($path in $candidate.removed) { Write-Output "    - $path" }
        foreach ($path in $candidate.contentChangedDuringComparison) { Write-Output "    ! content changed between scans: $path; repeat while files are stable" }
        foreach ($path in $candidate.paths) { Write-Output "    $($path.path): $($path.decision) [$($path.rule.kind):$($path.rule.path)] $($path.rule.reason)" }
    }
    foreach ($note in $Report.notes) { Write-Output "  $note" }
}
