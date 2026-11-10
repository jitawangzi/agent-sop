# 按显式路径分批读取固定提交；只复用本次调用的对象摘要，不缓存工作树字节。
function Read-AiSopDeliveryBlobBatch([string]$Repository,$Objects) {
    $inputText=(@($Objects.oid) -join "`n")+"`n"
    $bytes=(Invoke-AiSopDeliveryGit $Repository @('cat-file','--batch') $inputText).bytes
    $offset=0;$hashes=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach($obj in $Objects){
        $end=[Array]::IndexOf($bytes,[byte]10,$offset)
        if($end -lt $offset -or $end-$offset -gt 160){throw 'DELIVERY_BATCH_HEADER_INVALID'}
        $header=[Text.Encoding]::ASCII.GetString($bytes,$offset,$end-$offset)
        if($header -cne "$($obj.oid) blob $($obj.size)"){throw 'DELIVERY_BATCH_OBJECT_MISMATCH'}
        $offset=$end+1
        if($obj.size -gt 67108864 -or $offset+$obj.size -ge $bytes.Length -or $bytes[$offset+$obj.size] -ne 10){throw 'DELIVERY_BLOB_SIZE_MISMATCH'}
        $content=[byte[]]::new([int]$obj.size)
        [Array]::Copy($bytes,$offset,$content,0,$content.Length)
        $hashes[$obj.oid]=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($content)).ToLowerInvariant()
        $offset+=$content.Length+1
    }
    if($offset -ne $bytes.Length){throw 'DELIVERY_BATCH_TRAILING_BYTES'}
    return ,$hashes
}

# Requests中的item来自原始条目；批失败仅影响本批，不把其他有效条目吞掉。
function Set-AiSopDeliveryBatchFacts([string]$Repository,[string]$Commit,$Requests) {
    for($start=0;$start -lt $Requests.Count;){
        $selected=[Collections.Generic.List[object]]::new();$argumentChars=0
        do{
            $request=$Requests[$start];$selected.Add($request);$argumentChars+=$request.path.Length+3;$start++
        }while($start -lt $Requests.Count -and $selected.Count -lt 16 -and $argumentChars+$Requests[$start].path.Length+3 -le 16000)
        $group=$selected.ToArray()
        try{
            $raw=Get-AiSopDeliveryText $Repository (@('ls-tree','-t','-l','-z',$Commit,'--')+@($group.path))
            $entries=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
            foreach($line in ($raw -split "`0"|Where-Object {$_})){
                if($line -notmatch '(?s)^(\d{6}) (\w+) ([0-9a-f]{40,64})\s+(-|\d+)\t(.*)$'){throw 'DELIVERY_TREE_INVALID'}
                $entries.Add($Matches[5],@{mode=$Matches[1];type=$Matches[2];oid=$Matches[3];size=$Matches[4]})
            }
            $eligible=[Collections.Generic.List[object]]::new()
            foreach($request in $group){
                if(-not $entries.ContainsKey($request.path)){$request.item.git.status='NOT_IN_HEAD';continue}
                $obj=$entries[$request.path]
                if($obj.mode -notin @('100644','100755') -or $obj.type -ne 'blob'){$request.item.diagnostics+=,'DELIVERY_UNSUPPORTED_GIT_OBJECT';continue}
                $request.item.git.blobOid=$obj.oid
                if([long]$obj.size -gt 67108864){$request.item.diagnostics+=,'DELIVERY_BLOB_SIZE_LIMIT';continue}
                $eligible.Add(@{item=$request.item;oid=$obj.oid;size=[long]$obj.size})
            }
            # 每个输出批的内容总量不超过单对象上限，避免批量优化放大内存占用。
            while($eligible.Count){
                $chunk=[Collections.Generic.List[object]]::new();$total=0L
                while($eligible.Count -and $total+$eligible[0].size -le 67108864){$obj=$eligible[0];$eligible.RemoveAt(0);$chunk.Add($obj);$total+=$obj.size}
                try{
                    $hashes=Read-AiSopDeliveryBlobBatch $Repository $chunk.ToArray()
                    foreach($obj in $chunk){$obj.item.git.sha256=$hashes[$obj.oid];$obj.item.git.status=if($hashes[$obj.oid] -ceq $obj.item.declaredSha256){'MATCH'}else{'DIFFERENT'}}
                }catch{foreach($obj in $chunk){$obj.item.diagnostics+=,$_.Exception.Message}}
            }
        }catch{foreach($request in $group){$request.item.diagnostics+=,$_.Exception.Message}}
    }
}
