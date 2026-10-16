#requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path -Parent $PSScriptRoot
. (Join-Path $scripts 'task-context.ps1')
. (Join-Path $scripts 'input-diagnostics.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('sop-input-diagnostics-'+[guid]::NewGuid().ToString('N'))
function Assert($condition,[string]$message) { if (-not $condition) { throw $message } }
function Put([string]$path,[string]$text) {
    $full=Join-Path $root $path
    [IO.Directory]::CreateDirectory((Split-Path -Parent $full)) | Out-Null
    [IO.File]::WriteAllText($full,$text)
}
function TreeHash {
    return (@(Get-ChildItem -LiteralPath $root -File -Recurse -Force | Sort-Object FullName | ForEach-Object { $_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName).Hash }) -join "`n")
}
try {
    Put 'src/build/Main.txt' 'real source'; Put 'shared/base.txt' 'shared'
    Put 'module/build.gradle' 'build script'; Put 'module/build/cache.bin' ('a'*32)
    Put 'module/build/fixture.txt' 'fixture'; Put 'module/src/main.txt' 'module input'
    Put 'build/noise.txt' 'output'; Put 'logs/app.log.2026-10-15.gz' 'log'
    Put 'generated/noise.txt' 'generated'; Put '.git/HEAD' 'metadata'
    Put '.ai-workspace/specs/features/Example/notes.md' 'not executable'
    $policy=@{schemaVersion='1.0';include=@('module','module/build/fixture.txt');exclude=@(@{path='generated';reason='Generated artifacts'})}
    Put '.ai-workspace/context/verification-inputs.json' ($policy | ConvertTo-Json -Depth 8)
    $paths=@('module/build/cache.bin','module/build/fixture.txt','src/build/Main.txt','logs/app.log.2026-10-15.gz','generated/noise.txt','.git/HEAD','absent.txt')
    $before=TreeHash
    $snapshot=Get-AiSopInputSnapshot $root
    $report=Get-AiSopInputInspection $root $paths
    Assert ($report.inputDigest -ceq $snapshot.digest -and $report.statistics.hashedFiles -eq $snapshot.files.Count) 'Diagnostic scan differs from the real fingerprint'
    $expectedBytes=0L
    foreach ($path in $snapshot.files.Keys) { $expectedBytes+=(Get-Item -LiteralPath (Join-Path $root $path)).Length }
    Assert ($report.statistics.readBytes -eq $expectedBytes) 'Read-byte statistics include skipped files or omit input bytes'
    $cache=$report.paths | Where-Object path -eq 'module/build/cache.bin'
    Assert ($cache.decision -eq 'EXCLUDED' -and $cache.rule.path -eq 'module/build' -and @($cache.matchedRules | Where-Object kind -eq 'INCLUDE').Count) 'Module include explanation hid a more specific build exclusion'
    $fixture=$report.paths | Where-Object path -eq 'module/build/fixture.txt'
    Assert ($fixture.decision -eq 'INCLUDED' -and $fixture.rule.kind -eq 'INCLUDE') 'Explicit fixture include was not explained'
    Assert (($report.paths | Where-Object path -eq 'src/build/Main.txt').decision -eq 'INCLUDED') 'A source package named build was incorrectly excluded'
    Assert (($report.paths | Where-Object path -like 'logs/*').rule.reason -match 'Log') 'Dated log exclusion not explained'
    Assert (($report.paths | Where-Object path -eq 'generated/noise.txt').inherited) 'Pruned subtree explanation missing'
    Assert (($report.paths | Where-Object path -eq '.git/HEAD').rule.kind -eq 'PROTECTED') 'VCS exclusion missing'
    Assert (($report.paths | Where-Object path -eq 'absent.txt').decision -eq 'NOT_FOUND') 'Absent input not reported'
    $human=Write-AiSopInputInspection $report | Out-String
    Assert ($human -match 'absent.txt: NOT_FOUND' -and $human -notmatch '\[:\]') 'Missing rule printed empty diagnostic brackets'
    Assert ($human -match 'src/build/Main.txt: INCLUDED \[DEFAULT_INCLUDE\]' -and $human -notmatch '(?m)[ \t]+\r?$') 'Default rule printed an empty path or trailing whitespace'
    $caseTrace=@{entries=@(@{path='src/build/main.txt';decision='INCLUDED';rule=@{kind='DEFAULT';path='';reason='Input'};matchedRules=@()})}
    $caseProbe=Get-AiSopInputPathExplanation $root 'src/build/Main.txt' $caseTrace
    if ([OperatingSystem]::IsWindows()) { Assert ($caseProbe.decision -eq 'INCLUDED' -and -not $caseProbe.inherited) 'Windows case-only difference lost exact-path match' }
    else { Assert ($caseProbe.decision -eq 'NOT_FOUND') 'POSIX case distinction lost' }
    Assert ($before -ceq (TreeHash)) 'Inspection wrote workspace files'
    $light=Get-AiSopInputInspection $root $paths -ExplainOnly
    Assert ($light.mode -eq 'RULES_ONLY' -and $null -eq $light.inputDigest -and $null -eq $light.algorithm -and $light.statistics.readBytes -eq 0 -and $light.statistics.hashedFiles -eq 0) 'Rules-only explanation claimed a content scan/digest'
    foreach ($path in $paths) {
        $fullDecision=$report.paths | Where-Object path -eq $path
        $lightDecision=$light.paths | Where-Object path -eq $path
        Assert ((ConvertTo-AiSopWorkflowCanonicalJson $fullDecision) -ceq (ConvertTo-AiSopWorkflowCanonicalJson $lightDecision)) "Rule explanation disagrees with full scanner: $path"
    }
    # Refuse accidental hashing even when included files are unreadable; do not
    # visit unrelated branches containing unsupported links or huge inputs.
    $originalHash=(Get-Command Get-AiSopBudgetedFileHash).ScriptBlock
    try {
        function Get-AiSopBudgetedFileHash { throw 'UNEXPECTED_INPUT_READ' }
        $single=Get-AiSopInputInspection $root @('src/build/Main.txt') -ExplainOnly
        Assert ($single.statistics.scannedEntries -eq 3 -and $single.paths[0].decision -eq 'INCLUDED') 'Single-path diagnosis scanned unrelated branches'
        Put '.ai-workspace/context/bad-inputs.json' '{broken'
        foreach ($candidate in @('missing.json','.ai-workspace/context/bad-inputs.json','../escape.json')) {
            $failure=''; try { Get-AiSopInputInspection $root @() $candidate | Out-Null } catch { $failure=$_.Exception.Message }
            Assert ($failure -match 'INPUT_POLICY_MISSING|INPUT_POLICY_INVALID|WORKSPACE_PATH_ESCAPE' -and $failure -notmatch 'UNEXPECTED_INPUT_READ') 'Invalid candidate triggered a content scan before validation'
        }
        [IO.File]::Delete((Join-Path $root '.ai-workspace/context/bad-inputs.json'))
    } finally { Set-Item Function:\Get-AiSopBudgetedFileHash -Value $originalHash }
    $policy.exclude+=@{path='shared';reason='Candidate-only exclusion'}
    $policy.include+=@('build/noise.txt')
    Put '.ai-workspace/context/candidate-inputs.json' ($policy | ConvertTo-Json -Depth 8)
    $before=TreeHash
    $preview=Get-AiSopInputInspection $root @('shared/base.txt','build/noise.txt','build') '.ai-workspace/context/candidate-inputs.json'
    Assert ($preview.candidate.added.Count -eq 1 -and $preview.candidate.added[0] -eq 'build/noise.txt') 'Candidate added input mismatch'
    Assert ($preview.candidate.removed.Count -eq 1 -and $preview.candidate.removed[0] -eq 'shared/base.txt') 'Candidate removed input mismatch'
    Assert ($preview.candidate.policyChanged -and -not $preview.candidate.contentChangedDuringComparison.Count) 'Candidate comparison was not stable'
    Assert (($preview.candidate.paths | Where-Object path -eq 'build').decision -eq 'TRAVERSE_ONLY') 'Candidate no longer explains traversed output directory'
    $lightPreview=Get-AiSopInputInspection $root @('shared/base.txt','build/noise.txt','build') '.ai-workspace/context/candidate-inputs.json' -ExplainOnly
    Assert ($lightPreview.candidate.policyChanged -and $null -eq $lightPreview.candidate.added -and $null -eq $lightPreview.candidate.removed) 'Light candidate preview claimed a full inventory comparison'
    Assert ((ConvertTo-AiSopWorkflowCanonicalJson $lightPreview.candidate.paths) -ceq (ConvertTo-AiSopWorkflowCanonicalJson $preview.candidate.paths)) 'Candidate rules differ between light/full modes'
    $human=Write-AiSopInputInspection $preview | Out-String
    Assert ($human -match 'ancestor pruned at shared' -and $human -match 'traversed only to reach explicitly included descendants' -and $human -notmatch 'TRAVERSE_ONLY') 'Candidate human output hid pruning or exposed internal traversal enum'
    Assert ($before -ceq (TreeHash) -and (Get-AiSopInputSnapshot $root).digest -ceq $snapshot.digest) 'Candidate policy was installed or evidence persisted'
    $same=Get-AiSopInputInspection $root @() '.ai-workspace/context/verification-inputs.json'
    Assert (-not $same.candidate.policyChanged -and -not $same.candidate.added.Count -and -not $same.candidate.removed.Count) 'Identical policy reported a change'
    foreach ($bad in @('../escape.json','missing.json')) {
        $errorText=''; try { Get-AiSopInputInspection $root @() $bad | Out-Null } catch { $errorText=$_.Exception.Message }
        Assert ($errorText -match 'WORKSPACE_PATH_ESCAPE|INPUT_POLICY_MISSING') 'Unsafe/missing candidate not rejected'
    }
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $scripts) 'distribution/templates/root/ai-sop.ps1') -Destination (Join-Path $root 'ai-sop.ps1')
    [IO.Directory]::CreateDirectory((Join-Path $root '.ai-sop')) | Out-Null
    foreach ($dir in @('scripts','schemas')) { Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $scripts) $dir) -Destination (Join-Path $root '.ai-sop') -Recurse }
    $json=& (Join-Path $root 'ai-sop.ps1') Inputs -InputPath 'src/build/Main.txt' -Json | ConvertFrom-Json -AsHashtable
    Assert ($LASTEXITCODE -eq 0 -and $json.readOnly -and $json.paths[0].decision -eq 'INCLUDED') 'Root Inputs JSON dispatch failed'
    $json=& (Join-Path $root 'ai-sop.ps1') Inputs -InputPath 'src/build/Main.txt' -ExplainOnly -Json | ConvertFrom-Json -AsHashtable
    Assert ($LASTEXITCODE -eq 0 -and $json.mode -eq 'RULES_ONLY' -and $null -eq $json.inputDigest -and $json.paths[0].decision -eq 'INCLUDED') 'Root ExplainOnly dispatch failed'
    $human=& (Join-Path $root 'ai-sop.ps1') Inputs -InputPath 'module/build/cache.bin' | Out-String
    Assert ($LASTEXITCODE -eq 0 -and $human -match 'read-only' -and $human -match 'EXCLUDED') 'Human input explanation missing'
    Write-Output 'input-diagnostics.tests PASS'
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'sop-input-diagnostics-*') { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
}
