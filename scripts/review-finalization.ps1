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
                        # 示例代码不是实际引用；只提示正文中的简单内联链接。
                        $lines=[Collections.Generic.List[string]]::new();$fence=''
                        foreach($line in ($text -split '\r?\n')){
                            if($line -match '^\s*(`{3,}|~{3,})'){
                                $mark=$Matches[1]
                                if(-not $fence){$fence=$mark}elseif($mark[0] -eq $fence[0] -and $mark.Length -ge $fence.Length){$fence=''}
                                continue
                            }
                            if(-not $fence){$lines.Add($line)}
                        }
                        $text=[regex]::Replace(($lines -join "`n"),'(?s)(?<!`)(`+)(?!`).*?(?<!`)\1(?!`)','')
                        $ref.links=@(foreach($match in [regex]::Matches($text,'\[[^\]\r\n]+\]\(([^()\s]+)\)')){
                            $link=$match.Groups[1].Value
                            if($link.StartsWith('#') -or $link -match '^[a-zA-Z][a-zA-Z0-9+.-]*:'){continue}
                            $target=($link -split '[#?]',2)[0]
                            $item=@{target=$link;status='UNAVAILABLE'}
                            try{
                                $target=[Uri]::UnescapeDataString($target)
                                $candidate=[IO.Path]::GetFullPath((Join-Path (Split-Path $file) $target))
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
