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
    $latest=@(@{kind='test';outcome='PASSED';exitCode=0;inputsStable=$true;currentInputs='MATCH'})
    Assert ((Get-AiSopFinalizationReview $root '' @() @{}).tests -eq 'NOT_RECORDED') 'Empty test history became PASS'
    Assert ((Get-AiSopFinalizationReview $root '' @(@{kind='compile';outcome='PASSED';exitCode=0;inputsStable=$true}) @{}).tests -eq 'NOT_RECORDED') 'Compile-only history became test evidence'
    foreach($case in Get-AiSopVerificationRecordCases){
        $record=$case.Clone();$record.kind='test'
        $expected=if($case.expectedPass){'RECORDED_PASSES'}else{'NEEDS_REVIEW'}
        Assert ((Get-AiSopFinalizationReview $root '' @($record) @{}).tests -eq $expected) "Record case lost: $($case.id)"
    }
    foreach($override in @(@{exitCode=$null},@{exitCode=$false},@{exitCode='0'},@{exitCode=0.5},@{exitCode=[char]0},@{exitCode=[double]::NaN},@{exitCode=[double]::PositiveInfinity},@{inputsStable='true'},@{inputsStable=1},@{outcome='passed'})){
        $record=$latest[0].Clone();foreach($key in $override.Keys){$record[$key]=$override[$key]}
        Assert ((Get-AiSopFinalizationReview $root '' @($record) @{}).tests -eq 'NEEDS_REVIEW') 'Malformed fields became recorded pass'
    }
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
    $coverage=$r.references[0].linkCoverage
    Assert ($coverage.checkedLinks -eq 1 -and $coverage.skippedLinks -eq 5 -and $coverage.recognizedCandidates -eq 6) 'Candidate counts do not describe the checked subset'
    Assert ($coverage.skippedByReason.EXTERNAL_SCHEME -eq 1 -and $coverage.skippedByReason.INLINE_CODE -eq 3 -and $coverage.skippedByReason.FENCED_CODE -eq 1) 'Skip reasons lost'
    Assert ($r.references[0].links[0].line -eq 1 -and ($r.references[0].skippedLinks.line -join ',') -eq '2,3,4,6,9') 'Code masking changed original line positions'
    Assert ($r.tests -eq 'RECORDED_PASSES' -and $r.remote -eq 'NOT_CHECKED' -and $r.package -eq 'NOT_CHECKED' -and $r.committedBytes -eq 'NOT_CONFIRMED' -and -not $r.blocking) 'Invented delivery facts or gate'
    'reviewed'|Set-Content (Join-Path $root final-review.md)
    $r=Get-AiSopFinalizationReview $root attachments.json $latest @{coverage='COMPLETE';items=@(@{status='COMMITTED'})}
    Assert ($r.documents -eq 'DECLARED_REFERENCES_PRESENT' -and $r.committedBytes -eq 'OBSERVED_MATCH') 'Actual facts not exposed'
    # 使用本机真实绝对路径，防止盘符被当成协议，也防止绝对目标被拼到文档目录下。
    [IO.Directory]::CreateDirectory((Join-Path $root docs))|Out-Null
    '["docs/absolute-links.md"]'|Set-Content (Join-Path $root attachments.json)
    $present=Join-Path $root 'final review.md'
    'reviewed'|Set-Content -LiteralPath $present
    $missing=Join-Path $root 'missing review.md'
    $outside=Join-Path (Split-Path $root) ('outside-'+[guid]::NewGuid().ToString('N')+'.md')
    $cases=@(
        @{target=$present.Replace('\','/');status='PRESENT'},
        @{target=$missing.Replace('\','/');status='MISSING'},
        @{target=$outside.Replace('\','/');status='UNAVAILABLE'},
        @{target=([Uri]::new($present,[UriKind]::Absolute)).AbsoluteUri;status='PRESENT'},
        @{target=([Uri]::new($missing,[UriKind]::Absolute)).AbsoluteUri;status='MISSING'},
        @{target=([Uri]::new($outside,[UriKind]::Absolute)).AbsoluteUri;status='UNAVAILABLE'},
        @{target='file://unreachable.invalid/share/review.md';status='UNAVAILABLE'},
        @{target='file://localhost/share/review.md';status='UNAVAILABLE'},
        @{target='\\unreachable.invalid\share\review.md';status='UNAVAILABLE'}
    )
    if([OperatingSystem]::IsWindows()){
        $cases+=@(
            @{target=$present;status='PRESENT'},
            @{target=$missing;status='MISSING'},
            @{target=('/'+$present.Replace('\','/'));status='PRESENT'},
            @{target=('/'+$missing.Replace('\','/'));status='MISSING'}
        )
    }else{
        $cases+=@{target='C:/foreign-platform/review.md';status='UNAVAILABLE'}
    }
    foreach($case in $cases){
        # 裸路径先编码 Markdown 分隔字符；file URI 已由 Uri 编码，不能重复转义。
        $target=$case.target
        if($target -notmatch '^file:'){$target=$target.Replace('%','%25').Replace(' ','%20').Replace('#','%23').Replace('?','%3F')}
        ('[local]('+ $target +')')|Set-Content (Join-Path $root docs/absolute-links.md)
        $r=Get-AiSopFinalizationReview $root attachments.json $latest @{}
        Assert ($r.references[0].links.Count -eq 1) ('Local absolute link was skipped: '+$case.target)
        Assert ($r.references[0].links[0].status -eq $case.status) ('Wrong local absolute link status: '+$case.target)
        Assert ($r.documents -eq $(if($case.status -eq 'PRESENT'){'DECLARED_REFERENCES_PRESENT'}else{'NEEDS_ATTENTION'}) -and -not $r.blocking) 'Local link changed aggregate facts or added gate'
    }
    '[web](https://example.invalid) [mail](mailto:test@example.invalid) [custom](vscode://file/example) [anchor](#section)'|Set-Content (Join-Path $root docs/absolute-links.md)
    $r=Get-AiSopFinalizationReview $root attachments.json $latest @{}
    Assert ($r.references[0].links.Count -eq 0 -and $r.documents -eq 'DECLARED_REFERENCES_PRESENT') 'External links or anchors became local checks'
    Assert ($r.references[0].linkCoverage.status -eq 'NO_SUPPORTED_LOCAL_LINKS' -and $r.references[0].linkCoverage.skippedLinks -eq 4) 'Skipped-only document implied local link verification'
    foreach($newline in @("`n","`r`n")){
        @('prose','[title](missing.md "title")','[reference][id]','[bad](path(nested).md)','   [actual](missing.md)') -join $newline|Set-Content (Join-Path $root docs/absolute-links.md)
        $r=Get-AiSopFinalizationReview $root attachments.json $latest @{}
        Assert ($r.references[0].linkCoverage.checkedLinks -eq 1 -and $r.references[0].linkCoverage.skippedByReason.UNSUPPORTED_SYNTAX -eq 3) 'Unsupported syntax hidden or treated as a checked target'
        Assert ($r.references[0].links[0].line -eq 5 -and $r.references[0].links[0].column -eq 4 -and $r.references[0].links[0].status -eq 'MISSING') 'Diagnostic position does not point to original source'
    }
    'plain prose'|Set-Content (Join-Path $root docs/absolute-links.md)
    $r=Get-AiSopFinalizationReview $root attachments.json $latest @{}
    Assert ($r.references[0].linkCoverage.status -eq 'NO_SUPPORTED_LOCAL_LINKS' -and $r.references[0].linkCoverage.recognizedCandidates -eq 0 -and -not $r.blocking) 'Empty recognized scope inflated coverage or added gate'
    '["validation.md","final-review.md"]'|Set-Content (Join-Path $root attachments.json)
    # 同一目标经历缺失、创建、删除，各种写法必须保持相同事实；旧单点反例继续保留。
    $familyTarget=Join-Path $root 'same file % # (节点).md'
    $documentDirectory=Join-Path $root docs
    '["docs/absolute-links.md"]'|Set-Content (Join-Path $root attachments.json)
    $family=@(Get-AiSopEquivalentLocalLinkCases -DocumentDirectory $documentDirectory -TargetPath $familyTarget)
    foreach($state in @('MISSING','PRESENT','MISSING')){
        if($state -eq 'PRESENT'){'created'|Set-Content -LiteralPath $familyTarget}
        elseif(Test-Path -LiteralPath $familyTarget){Remove-Item -LiteralPath $familyTarget}
        foreach($case in $family){
            ('[same]('+ $case.target +')')|Set-Content (Join-Path $documentDirectory absolute-links.md)
            $r=Get-AiSopFinalizationReview $root attachments.json $latest @{}
            Assert ($r.references[0].links.Count -eq 1 -and $r.references[0].links[0].status -eq $state) ("Equivalent link mismatch: $($case.id) $state")
        }
    }
    foreach($case in @(Get-AiSopEquivalentLocalLinkCases -DocumentDirectory $documentDirectory -TargetPath $outside)){
        ('[outside]('+ $case.target +')')|Set-Content (Join-Path $documentDirectory absolute-links.md)
        $r=Get-AiSopFinalizationReview $root attachments.json $latest @{}
        Assert ($r.references[0].links.Count -eq 1 -and $r.references[0].links[0].status -eq 'UNAVAILABLE') ('Equivalent outside link escaped: '+$case.id)
    }
    '["validation.md","final-review.md"]'|Set-Content (Join-Path $root attachments.json)
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
