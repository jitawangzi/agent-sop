. (Join-Path $PSScriptRoot 'review-links.ps1')
# 收尾仅派生观察事实；清单复用打包附件清单，不形成第二份任务状态。
function Get-AiSopFinalizationReview([string]$Workspace,[string]$AttachmentsManifest,$Latest,$Delivery) {
    $tests=@($Latest|Where-Object kind -eq 'test')
    $result=@{derived=$true;blocking=$false;references=@();diagnostics=@();documents='NOT_REQUESTED';
        tests=if(-not $tests.Count){'NOT_RECORDED'}elseif(@($tests|Where-Object {$_.outcome -ne 'PASSED' -or -not $_.inputsStable}).Count){'NEEDS_REVIEW'}else{'RECORDED_PASSES'};
        currentInputs=if(@($Latest).Count -and -not @($Latest|Where-Object currentInputs -ne MATCH).Count){'MATCH'}else{'NOT_CONFIRMED'};
        committedBytes=if($Delivery.coverage -eq 'COMPLETE' -and @($Delivery.items).Count -and -not @($Delivery.items|Where-Object status -ne COMMITTED).Count){'OBSERVED_MATCH'}else{'NOT_CONFIRMED'};
        package='NOT_CHECKED';remote='NOT_CHECKED';
        sequence=@('Finalize documentation and review records.','Inspect explicit attachments and local links, then pack once.','After actual commit, check committed bytes; verify remote separately.');
        limits=@('Hints only; no task changes or extra completion gate.','Declared files and simple inline local Markdown links only; not a full Markdown parser.','Existing documents are not proof of review approval; recorded passes are not proof of test semantics.','This export neither creates/verifies a package nor contacts remotes.')}
    if(-not $AttachmentsManifest){return $result}
    try{
        $path=Resolve-AiSopReviewChild $Workspace $AttachmentsManifest
        $bytes=[IO.File]::ReadAllBytes($path)
        $list=[Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xfeff)|ConvertFrom-Json -AsHashtable -NoEnumerate
        if($list -isnot [Collections.IList]){throw 'ATTACHMENTS_MANIFEST_INVALID'}
        $result.manifest=@{path=$AttachmentsManifest;sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()}
        $refs=[Collections.Generic.List[object]]::new()
        foreach($entry in $list){
            $ref=@{path=$entry;status='UNAVAILABLE';links=@()}
            try{
                if($entry -isnot [string] -or [string]::IsNullOrWhiteSpace($entry)){throw 'ATTACHMENT_PATH_INVALID'}
                $file=Resolve-AiSopReviewChild $Workspace $entry
                if(-not [IO.File]::Exists($file)){$ref.status='MISSING'}else{
                    $ref.status='PRESENT'
                    if([IO.Path]::GetExtension($file) -ieq '.md'){
                        if((Get-Item -LiteralPath $file).Length -gt 1048576){throw 'DOCUMENT_SCAN_SIZE_LIMIT'}
                        $text=[IO.File]::ReadAllText($file)
                        $scan=Get-AiSopMarkdownLinkScan $text
                        $ref.linkCoverage=$scan.coverage
                        $ref.skippedLinks=$scan.skipped
                        $ref.links=@(foreach($candidate in $scan.links){
                            $link=$candidate.target
                            $target=($link -split '[#?]',2)[0]
                            $item=@{target=$link;line=$candidate.line;column=$candidate.column;status='UNAVAILABLE'}
                            try{
                                if($target -match '^file:'){
                                    $uri=[Uri]::new($target,[UriKind]::Absolute)
                                    if(-not $uri.IsFile -or $uri.IsUnc -or $uri.Host){throw 'REVIEW_NETWORK_PATH_UNSUPPORTED'}
                                    $target=$uri.LocalPath
                                }else{$target=[Uri]::UnescapeDataString($target)}
                                if($target -match '^[/\\]{2}'){throw 'REVIEW_NETWORK_PATH_UNSUPPORTED'}
                                if($target -match '^/?[a-zA-Z]:[/\\]'){
                                    if(-not [OperatingSystem]::IsWindows()){throw 'REVIEW_FOREIGN_ABSOLUTE_PATH_UNSUPPORTED'}
                                    $target=$target.TrimStart('/')
                                }
                                # 本机绝对目标直接解析；相对目标绑定文档目录，随后仍验证工作区边界。
                                $candidate=[IO.Path]::GetFullPath($target,(Split-Path $file))
                                $relative=[IO.Path]::GetRelativePath($Workspace,$candidate).Replace('\','/')
                                $resolved=Resolve-AiSopReviewChild $Workspace $relative
                                $item.status=if(Test-Path -LiteralPath $resolved){'PRESENT'}else{'MISSING'}
                            }catch{$item.diagnostic=$_.Exception.Message}
                            $item
                        })
                    }
                }
            }catch{$ref.status='UNAVAILABLE';$ref.diagnostic=$_.Exception.Message}
            $refs.Add($ref)
        }
        $result.references=$refs.ToArray()
        $result.documents=if(@($refs|Where-Object {$_.status -ne 'PRESENT' -or @($_.links|Where-Object status -ne PRESENT).Count}).Count){'NEEDS_ATTENTION'}else{'DECLARED_REFERENCES_PRESENT'}
    }catch{$result.documents='UNAVAILABLE';$result.diagnostics+=,$_.Exception.Message}
    return $result
}

# 从本次导出的原字段派生，区分已知问题与未核对项；不产生整体 PASS。
function Get-AiSopReviewAttention($Report) {
    $items=[Collections.Generic.List[object]]::new()
    function AddAttention([string]$Category,[string]$Code,[string]$Source,[string]$Observation){
        $items.Add(@{category=$Category;code=$Code;source=$Source;observation=$Observation})
    }
    if($Report.findingCoverage -eq 'INCOMPLETE'){AddAttention 'ATTENTION' 'FINDING_COVERAGE_INCOMPLETE' 'findingCoverage' $Report.findingCoverage}
    for($i=0;$i -lt @($Report.diagnostics).Count;$i++){
        $code=([string]$Report.diagnostics[$i] -split ':',2)[0]
        # 自由文本只保留原字段引用，不复制未知内容。
        AddAttention 'ATTENTION' $code "diagnostics[$i]" 'CONSULT_SOURCE'
    }
    $open=@($Report.findings|Where-Object declaredStatus -in @('OPEN','IN_REVIEW'))
    if($open.Count){AddAttention 'ATTENTION' 'RELATED_FINDINGS_UNRESOLVED' 'findings' ([string]$open.Count)}
    $cleanup=$Report.cleanup.value.outcome
    if($cleanup -eq 'FAILED'){AddAttention 'ATTENTION' 'CLEANUP_FAILED' 'cleanup' 'FAILED'}
    elseif($cleanup -ne 'PASSED'){AddAttention 'UNVERIFIED' 'CLEANUP_UNCONFIRMED' 'cleanup' 'NOT_CONFIRMED'}
    if($Report.cleanup.source.status -ne 'PRESENT_UNBOUND'){AddAttention 'UNVERIFIED' 'SUPPLEMENTAL_EVIDENCE_UNAVAILABLE' 'cleanup.source' 'NOT_CONFIRMED'}
    if($Report.unverifiedScope.status -eq 'NOT_RECORDED'){AddAttention 'UNVERIFIED' 'LIMITATIONS_NOT_RECORDED' 'unverifiedScope' 'NOT_RECORDED'}
    if($Report.finalization.tests -ne 'RECORDED_PASSES'){AddAttention 'ATTENTION' 'TEST_RECORDS_NEED_REVIEW' 'finalization.tests' $Report.finalization.tests}
    # tests 字段只概括测试；逐一引用所有最新批次，避免编译失败被测试 PASS 掩盖。
    for($i=0;$i -lt @($Report.latest).Count;$i++){
        $run=$Report.latest[$i]
        if($run.outcome -ne 'PASSED' -or $run.exitCode -ne 0 -or $run.inputsStable -ne $true){
            AddAttention 'ATTENTION' 'LATEST_VERIFICATION_NEEDS_REVIEW' "latest[$i]" 'CONSULT_SOURCE'
        }
    }
    if($Report.currentInputCheck -eq 'NOT_REQUESTED'){AddAttention 'UNVERIFIED' 'CURRENT_INPUTS_NOT_CHECKED' 'currentInputCheck' 'NOT_REQUESTED'}
    elseif($Report.finalization.currentInputs -ne 'MATCH'){AddAttention 'ATTENTION' 'CURRENT_INPUTS_NOT_CONFIRMED' 'latest' 'NOT_CONFIRMED'}
    if(@($Report.latest|Where-Object inputIntegrity -eq 'UNAVAILABLE').Count){AddAttention 'ATTENTION' 'INPUT_EVIDENCE_UNAVAILABLE' 'latest' 'UNAVAILABLE'}
    $missingEvidence=@(foreach($run in $Report.latest){
        foreach($ref in @($run.log)+@($run.reports)){if($ref -and $ref.status -in @('MISSING','UNAVAILABLE','CHANGED')){$ref}}
    })
    if(@($Report.latest|Where-Object {-not $_.log -and -not @($_.reports).Count}).Count){AddAttention 'UNVERIFIED' 'RUN_EVIDENCE_NOT_RECORDED' 'latest' 'NOT_RECORDED'}
    if($missingEvidence.Count){AddAttention 'ATTENTION' 'RUN_EVIDENCE_UNAVAILABLE' 'latest' ([string]$missingEvidence.Count)}
    if(@($Report.repositories|Where-Object status -ne AVAILABLE).Count){AddAttention 'UNVERIFIED' 'REPOSITORY_INVENTORY_INCOMPLETE' 'repositories' 'NOT_CONFIRMED'}
    foreach($name in @('documents','committedBytes','package','remote')){
        $value=[string]$Report.finalization[$name]
        if($value -in @('NEEDS_ATTENTION','UNAVAILABLE')){AddAttention 'ATTENTION' ($name.ToUpperInvariant()+'_NEEDS_REVIEW') ("finalization.$name") $value}
        elseif($value -in @('NOT_REQUESTED','NOT_CHECKED','NOT_CONFIRMED')){AddAttention 'UNVERIFIED' ($name.ToUpperInvariant()+'_NOT_CONFIRMED') ("finalization.$name") $value}
    }
    if($Report.delivery.status -ne 'NOT_REQUESTED' -and ($Report.delivery.coverage -ne 'COMPLETE' -or @($Report.delivery.items|Where-Object status -ne COMMITTED).Count)){
        AddAttention 'ATTENTION' 'DELIVERY_NEEDS_REVIEW' 'delivery' 'CONSULT_SOURCE'
    }
    return @{derived=$true;blocking=$false;items=$items.ToArray();attentionCount=@($items|Where-Object category -eq ATTENTION).Count;unverifiedCount=@($items|Where-Object category -eq UNVERIFIED).Count;
        limits=@('Counts summarize this export only; zero does not mean acceptance or approval.','Unresolved findings are selected by declared path scope; unknown coverage remains explicit.','Unavailable or unrequested checks do not create completion requirements.','Inspect referenced original records; this section is not a new authority.')}
}
