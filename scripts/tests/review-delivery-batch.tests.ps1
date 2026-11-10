#requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path $PSScriptRoot
. (Join-Path $scripts task-context.ps1)
. (Join-Path $scripts review-paths.ps1)
. (Join-Path $scripts review-delivery.ps1)
. (Join-Path $PSScriptRoot fixtures/retained-fixture.ps1)
function Assert($ok,$message){if(-not $ok){throw $message}}
$root=Join-Path ([IO.Path]::GetTempPath()) ('delivery-batch-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$ok=$false;$failure='';$realInvoke=${function:Invoke-AiSopDeliveryGit}
try{
    & git -C $root init -q
    & git -C $root config user.name fixture
    & git -C $root config user.email fixture@example.invalid
    & git -C $root config core.autocrlf false
    $entries=@(foreach($i in 0..16){
        $name="file $i [中文].bin"
        $bytes=[byte[]]@();if($i -ne 0){$bytes=[byte[]]@(0,255,10,13,9,7)}
        [IO.File]::WriteAllBytes((Join-Path $root $name),$bytes)
        @{path=$name;sha256=(Get-FileHash -LiteralPath (Join-Path $root $name)).Hash.ToLowerInvariant()}
    })
    & git -C $root add .
    & git -C $root commit -qm fixture
    Assert ($LASTEXITCODE -eq 0) 'Fixture commit failed'
    function Invoke-AiSopDeliveryGit([string]$Repository,[string[]]$Arguments,[string]$InputText=''){
        $script:calls++
        $value=& $realInvoke $Repository $Arguments $InputText
        if($script:corrupt -and $Arguments[0] -eq 'cat-file'){
            $script:corrupt=$false
            return @{bytes=[byte[]]$value.bytes[0..($value.bytes.Length-2)]}
        }
        return $value
    }
    foreach($count in @(0,1,16,17)){
        $script:calls=0;$script:corrupt=$false
        ConvertTo-Json -InputObject @($entries|Select-Object -First $count)|Set-Content (Join-Path $root manifest.json)
        $r=Get-AiSopDeliveryReview $root manifest.json
        Assert ($r.items.Count -eq $count -and $r.coverage -eq 'COMPLETE' -and -not @($r.items|Where-Object status -ne COMMITTED).Count) "Batch boundary failed: $count"
        if($count){Assert ($script:calls -le 3+2*[Math]::Ceiling($count/16)) "Git process count did not decrease: $script:calls"}
    }
    # 首批截断不发布任何成功；第17项仍正常读，全部local事实保留。
    $script:corrupt=$true
    $r=Get-AiSopDeliveryReview $root manifest.json
    Assert ($r.coverage -eq 'INCOMPLETE' -and @($r.items|Where-Object status -eq UNKNOWN).Count -eq 16 -and $r.items[16].status -eq 'COMMITTED') 'Truncated batch erased other batch or published partial success'
    Assert (-not @($r.items|Where-Object {$_.local.status -ne 'MATCH'}).Count) 'Batch failure erased local evidence'
    Set-Item Function:Invoke-AiSopDeliveryGit $realInvoke
    $oid='a'*40
    foreach($wire in @("$oid blob 0`n`nJUNK","$oid blob 1`n`n","$oid tree 0`n`n",'broken')){
        $script:wireBytes=[Text.Encoding]::ASCII.GetBytes($wire)
        function Invoke-AiSopDeliveryGit {return @{bytes=$script:wireBytes}}
        $rejected=$false
        try{$null=Read-AiSopDeliveryBlobBatch $root @(@{oid=$oid;size=0L})}catch{$rejected=$true}
        Assert $rejected 'Invalid raw batch protocol accepted'
    }
    Set-Item Function:Invoke-AiSopDeliveryGit $realInvoke
    # 实际对象验证64MiB边界；超限对象只影响自身，正常同批对象仍可核对。
    $large=@(foreach($length in @(67108864,67108865)){
        $path=Join-Path $root "size-$length.bin"
        $stream=[IO.File]::Create($path);try{$stream.SetLength($length)}finally{$stream.Dispose()}
        @{path=[IO.Path]::GetFileName($path);sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()}
    })
    & git -C $root add -- 'size-67108864.bin' 'size-67108865.bin'
    & git -C $root commit -qm size-boundary
    Assert ($LASTEXITCODE -eq 0) 'Size fixture commit failed'
    ConvertTo-Json -InputObject @($large+$entries[1])|Set-Content (Join-Path $root manifest.json)
    $r=Get-AiSopDeliveryReview $root manifest.json
    Assert ($r.items[0].status -eq 'COMMITTED' -and $r.items[1].status -eq 'UNKNOWN' -and $r.items[1].diagnostics -contains 'DELIVERY_BLOB_SIZE_LIMIT' -and $r.items[2].status -eq 'COMMITTED') 'Size cap or split-batch isolation changed'
    # 同时查询目录及后代时仍须报告目录为不支持的对象，不能误记为提交中不存在。
    $folder=Join-Path $root overlap
    [IO.Directory]::CreateDirectory($folder)|Out-Null
    [IO.File]::WriteAllBytes((Join-Path $folder child.bin),[byte[]]@(1,2,3))
    $childHash=(Get-FileHash -LiteralPath (Join-Path $folder child.bin)).Hash.ToLowerInvariant()
    & git -C $root add -- overlap/child.bin
    & git -C $root commit -qm overlap
    Assert ($LASTEXITCODE -eq 0) 'Overlap fixture commit failed'
    if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($folder)) -cne [IO.Path]::GetFullPath($root)){throw 'Unsafe overlap fixture cleanup'}
    Remove-Item -LiteralPath $folder -Recurse -Force
    ConvertTo-Json -InputObject @(@{path='overlap';sha256=('0'*64)},@{path='overlap/child.bin';sha256=$childHash})|Set-Content (Join-Path $root manifest.json)
    $r=Get-AiSopDeliveryReview $root manifest.json
    Assert ($r.coverage -eq 'INCOMPLETE' -and $r.items[0].diagnostics -contains 'DELIVERY_UNSUPPORTED_GIT_OBJECT' -and $r.items[0].git.status -ne 'NOT_IN_HEAD' -and $r.items[1].git.status -eq 'MATCH') 'Overlapping tree/file requests hid unsupported tree or lost descendant'
    $ok=$true
}catch{$failure=$_.ToString();throw}finally{
    Set-Item Function:Invoke-AiSopDeliveryGit $realInvoke
    Complete-AiSopTestFixture -Root $root -Prefix delivery-batch- -Succeeded $ok -Failure $failure
}
Write-Output 'PASS: 0/1/16/17 batch sizes, binary/empty/duplicate objects, bounded process count, truncated batch isolation and strict wire parsing'
