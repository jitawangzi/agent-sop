#requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path $PSScriptRoot
. (Join-Path $scripts task-context.ps1)
. (Join-Path $scripts review-paths.ps1)
. (Join-Path $scripts review-finalization.ps1)
. (Join-Path $PSScriptRoot fixtures/retained-fixture.ps1)
. (Join-Path $PSScriptRoot fixtures/boundary-cases.ps1)
function Assert($ok,$message){if(-not $ok){throw $message}}
$root=Join-Path ([IO.Path]::GetTempPath()) ('finalization-review-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$ok=$false;$failure=''
try{
    $latest=@(@{kind='test';outcome='PASSED';inputsStable=$true;currentInputs='MATCH'})
    Assert ((Get-AiSopFinalizationReview $root '' @() @{}).tests -eq 'NOT_RECORDED') 'Empty test history became PASS'
    Assert ((Get-AiSopFinalizationReview $root '' @(@{kind='compile';outcome='PASSED';inputsStable=$true}) @{}).tests -eq 'NOT_RECORDED') 'Compile-only history became test evidence'
    $doc=@'
[required](final-review.md)
[external](https://example.invalid)
`[inline example](not-required.md)`
``[double-backtick example](not-required.md)``
``
[multiline example](not-required.md)
``
```md
[fenced example](not-required.md)
```
'@
    $doc|Set-Content (Join-Path $root validation.md)
    '["validation.md","final-review.md"]'|Set-Content (Join-Path $root attachments.json)
    $r=Get-AiSopFinalizationReview $root attachments.json $latest @{}
    Assert ($r.documents -eq 'NEEDS_ATTENTION' -and $r.references[0].links.Count -eq 1 -and $r.references[0].links[0].status -eq 'MISSING') 'Missing actual review lost or code examples treated as references'
    Assert ($r.tests -eq 'RECORDED_PASSES' -and $r.remote -eq 'NOT_CHECKED' -and $r.package -eq 'NOT_CHECKED' -and $r.committedBytes -eq 'NOT_CONFIRMED' -and -not $r.blocking) 'Invented delivery facts or gate'
    'reviewed'|Set-Content (Join-Path $root final-review.md)
    $r=Get-AiSopFinalizationReview $root attachments.json $latest @{coverage='COMPLETE';items=@(@{status='COMMITTED'})}
    Assert ($r.documents -eq 'DECLARED_REFERENCES_PRESENT' -and $r.committedBytes -eq 'OBSERVED_MATCH') 'Actual facts not exposed'
    $latest[0].currentInputs='STALE';$latest[0].outcome='FAILED'
    $r=Get-AiSopFinalizationReview $root attachments.json $latest @{coverage='COMPLETE';items=@()}
    Assert ($r.currentInputs -eq 'NOT_CONFIRMED' -and $r.tests -eq 'NEEDS_REVIEW' -and $r.committedBytes -eq 'NOT_CONFIRMED') 'Stale/failed/empty evidence exaggerated'
    foreach($case in @(Get-AiSopJsonBoundaryCases Object|Where-Object {$_.kind -ne 'Array'})){
        $case.json|Set-Content (Join-Path $root attachments.json)
        Assert ((Get-AiSopFinalizationReview $root attachments.json @() @{}).documents -eq 'UNAVAILABLE') 'Bad manifest disrupted optional summary'
    }
    '["../escape","final-review.md"]'|Set-Content (Join-Path $root attachments.json)
    $r=Get-AiSopFinalizationReview $root attachments.json @() @{}
    Assert ($r.references[0].status -eq 'UNAVAILABLE' -and $r.references[1].status -eq 'PRESENT') 'One bad reference erased valid facts'
    $ok=$true
}catch{$failure=$_.ToString();throw}finally{Complete-AiSopTestFixture -Root $root -Prefix finalization-review- -Succeeded $ok -Failure $failure}
Write-Output 'PASS: optional finalization facts, missing references, example exclusion and honest incomplete delivery'
