#requires -Version 7.0
# 显式声明的交付材料只读检查：HEAD 原始字节与工作树、声明分别比较。
. (Join-Path $PSScriptRoot 'hidden-process.ps1')
. (Join-Path $PSScriptRoot 'review-delivery-batch.ps1')
function Invoke-AiSopDeliveryGit([string]$Repository,[string[]]$Arguments,[string]$InputText='') {
    $process=[Diagnostics.Process]::new();$memory=[IO.MemoryStream]::new();$started=$false
    $copy=$null;$errorRead=$null;$write=$null;$primary=$null;$cancellation=[Threading.CancellationTokenSource]::new()
    try {
        $process.StartInfo.FileName=(@(Get-Command git -CommandType Application -ErrorAction Stop)[0]).Source
        $process.StartInfo.UseShellExecute=$false;$process.StartInfo.CreateNoWindow=$true
        $process.StartInfo.RedirectStandardOutput=$true;$process.StartInfo.RedirectStandardError=$true;$process.StartInfo.RedirectStandardInput=$true
        foreach($key in @($process.StartInfo.Environment.Keys)){if($key.StartsWith('GIT_',[StringComparison]::OrdinalIgnoreCase)){[void]$process.StartInfo.Environment.Remove($key)}}
        $process.StartInfo.Environment['GIT_OPTIONAL_LOCKS']='0'
        $process.StartInfo.Environment['GIT_NO_LAZY_FETCH']='1'
        $process.StartInfo.Environment['GIT_NO_REPLACE_OBJECTS']='1'
        $process.StartInfo.Environment['GIT_TERMINAL_PROMPT']='0'
        foreach($arg in (@('--no-optional-locks','--literal-pathspecs','-c','core.fsmonitor=false','-C',$Repository)+$Arguments)){[void]$process.StartInfo.ArgumentList.Add($arg)}
        if(-not $process.Start()){throw 'DELIVERY_GIT_START_FAILED'}
        $started=$true;$clock=[Diagnostics.Stopwatch]::StartNew()
        $write=$null
        if($InputText){$write=$process.StandardInput.WriteAsync($InputText)}
        $copy=$process.StandardOutput.BaseStream.CopyToAsync($memory,$cancellation.Token);$errorRead=$process.StandardError.ReadToEndAsync()
        if($write -and -not $write.Wait(1000)){throw 'DELIVERY_GIT_INPUT_TIMEOUT'}
        $process.StandardInput.Close()
        if(-not $process.WaitForExit([Math]::Max(0,10000-[int]$clock.ElapsedMilliseconds))){throw 'DELIVERY_GIT_TIMEOUT'}
        if(-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($copy,$errorRead),2000)){throw 'DELIVERY_GIT_OUTPUT_INCOMPLETE'}
        if($process.ExitCode -ne 0){throw ('DELIVERY_GIT_EXIT_'+$process.ExitCode)}
        return @{bytes=$memory.ToArray()}
    } catch {$primary=$_;throw} finally {
        # 管道、取消和 Dispose 也可能阻塞，沿用有界后台清理，不再同步重复关闭。
        $copies=@();if($copy){$copies+=,$copy};if($errorRead){$copies+=,$errorRead};if($write){$copies+=,$write}
        try {
            $cleanup=Invoke-AiSopProcessCleanup -Process $process -Started $started -Terminate $true -Cancellation $cancellation -Copies $copies -Resources @($memory) -BudgetMilliseconds 2000
            if(-not $cleanup.confirmed){throw 'DELIVERY_GIT_CLEANUP_UNCONFIRMED'}
        } catch {if($primary){try{[Console]::Error.WriteLine('DELIVERY_GIT_CLEANUP_UNCONFIRMED')}catch{}}else{throw}}
    }
}
function Get-AiSopDeliveryText([string]$Repository,[string[]]$Arguments) {
    return [Text.Encoding]::UTF8.GetString((Invoke-AiSopDeliveryGit $Repository $Arguments).bytes)
}
function Get-AiSopReadOnlyWorkingChanges([string]$Repository) {
    # status 也可能调用 clean/process 过滤器；只读审查禁用这些外部命令。
    $keys=@()
    try{$keys=@((Get-AiSopDeliveryText $Repository @('config','--name-only','--get-regexp','^filter\..*\.(clean|smudge|process|required)$')) -split '\r?\n'|Where-Object {$_})}
    catch{if($_.Exception.Message -ne 'DELIVERY_GIT_EXIT_1'){throw}}
    $options=@()
    foreach($key in $keys){$value=if($key -match '\.required$'){'false'}else{''};$options+=@('-c',($key+'='+$value))}
    return @((Get-AiSopDeliveryText $Repository ($options+@('status','--porcelain=v1','--untracked-files=all','--ignore-submodules=dirty'))) -split '\r?\n'|Where-Object {$_})
}
function Get-AiSopDeliveryReview([string]$Workspace,[string]$Manifest) {
    $answer=[ordered]@{status='NOT_REQUESTED';blocking=$false;manifest=$null;coverage='NOT_REQUESTED';items=@();diagnostics=@();limits=@('Only explicitly declared materials are checked.','COMMITTED means matching bytes in the observed local commit; it does not prove push, remote availability, test semantics or completion.')}
    if(-not $Manifest){return $answer}
    $answer.status='UNAVAILABLE';$answer.coverage='INCOMPLETE'
    try {
        $manifestPath=Resolve-AiSopReviewChild $Workspace $Manifest
        $bytes=[IO.File]::ReadAllBytes($manifestPath)
        $raw=[Text.Encoding]::UTF8.GetString($bytes)
        if($raw.Length -and $raw[0] -eq [char]0xFEFF){$raw=$raw.Substring(1)}
        $answer.manifest=@{path=$Manifest;sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()}
        if(-not $raw.TrimStart().StartsWith('[')){throw 'DELIVERY_MANIFEST_ARRAY_REQUIRED'}
        $declared=ConvertFrom-Json -InputObject $raw -AsHashtable -NoEnumerate -ErrorAction Stop
        if($declared -isnot [array]){throw 'DELIVERY_MANIFEST_ARRAY_REQUIRED'}
    } catch {$answer.diagnostics=@('DELIVERY_MANIFEST_UNAVAILABLE');return $answer}
    $base=Split-Path -Parent $manifestPath
    $comparison=if([OperatingSystem]::IsWindows()){[StringComparer]::OrdinalIgnoreCase}else{[StringComparer]::Ordinal}
    $seen=[Collections.Generic.HashSet[string]]::new($comparison)
    $repositories=[Collections.Generic.Dictionary[string,object]]::new($comparison)
    $items=[Collections.Generic.List[object]]::new()
    $complete=$true
    foreach($declaration in $declared){
        $item=[ordered]@{path=$null;declaredSha256=$null;local=@{status='UNAVAILABLE';sha256=$null};git=@{status='UNAVAILABLE';repository=$null;commit=$null;blobOid=$null;sha256=$null};status='UNKNOWN';diagnostics=@()}
        try {
            if($declaration -isnot [Collections.IDictionary] -or $declaration.path -isnot [string] -or $declaration.sha256 -isnot [string] -or $declaration.sha256 -notmatch '^[0-9a-fA-F]{64}$'){throw 'DELIVERY_ITEM_INVALID'}
            $item.path=$declaration.path;$item.declaredSha256=$declaration.sha256.ToLowerInvariant()
            $child=ConvertTo-AiSopReviewScope $declaration.path
            $relative=[IO.Path]::GetRelativePath($Workspace,(Join-Path $base $child)).Replace('\','/')
            $path=Resolve-AiSopReviewChild $Workspace $relative
            if(-not $seen.Add($path)){throw 'DELIVERY_DUPLICATE_PATH'}
            $stream=$null
            try {
                $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                $item.local.sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()
                $item.local.status=if($item.local.sha256 -ceq $item.declaredSha256){'MATCH'}else{'CHANGED'}
            } catch {
                $cause=$_.Exception.GetBaseException()
                if($cause -is [IO.FileNotFoundException] -or $cause -is [IO.DirectoryNotFoundException]){$item.local.status='MISSING'}else{throw 'DELIVERY_LOCAL_UNAVAILABLE'}
            } finally {if($stream){$stream.Dispose()}}
            $cursor=Split-Path -Parent $path;$repository=$null
            while($cursor){
                if((Test-Path -LiteralPath (Join-Path $cursor '.git'))){$repository=$cursor;break}
                if($comparison.Equals($cursor,$Workspace)){break}
                $next=Split-Path -Parent $cursor;if($next -eq $cursor){break};$cursor=$next
            }
            if(-not $repository){throw 'DELIVERY_REPOSITORY_UNAVAILABLE'}
            if(-not $repositories.ContainsKey($repository)){
                $top=(Get-AiSopDeliveryText $repository @('rev-parse','--show-toplevel')).Trim()
                if(-not $comparison.Equals((Resolve-PhysicalPathIdentity $top),(Resolve-PhysicalPathIdentity $repository))){throw 'DELIVERY_REPOSITORY_MISMATCH'}
                $head=(Get-AiSopDeliveryText $repository @('rev-parse','--verify','HEAD^{commit}')).Trim()
                if($head -notmatch '^[0-9a-f]{40,64}$'){throw 'DELIVERY_HEAD_INVALID'}
                $repositories[$repository]=@{head=$head;requests=[Collections.Generic.List[object]]::new()}
            }
            $commit=$repositories[$repository].head
            $item.git.repository=[IO.Path]::GetRelativePath($Workspace,$repository).Replace('\','/');$item.git.commit=$commit
            $repoPath=[IO.Path]::GetRelativePath($repository,$path).Replace('\','/')
            $repositories[$repository].requests.Add(@{path=$repoPath;item=$item})
        } catch {$item.diagnostics+=,$_.Exception.Message;$complete=$false}
        $items.Add($item)
    }
    foreach($repository in $repositories.Keys){Set-AiSopDeliveryBatchFacts $repository $repositories[$repository].head $repositories[$repository].requests.ToArray()}
    foreach($item in $items){
        if($item.diagnostics.Count){$complete=$false}
        $item.status=if($item.local.status -eq 'MISSING'){'MISSING'}elseif($item.local.status -eq 'CHANGED'){'CHANGED'}elseif($item.local.status -eq 'MATCH' -and $item.git.status -eq 'MATCH'){'COMMITTED'}elseif($item.local.status -eq 'MATCH' -and $item.git.status -in @('DIFFERENT','NOT_IN_HEAD')){'LOCAL'}else{'UNKNOWN'}
    }
    # 仓库引用在导出期间漂移时，保留观察到的提交但不再给出已提交结论。
    foreach($repository in $repositories.Keys){
        try{$unchanged=(Get-AiSopDeliveryText $repository @('rev-parse','--verify','HEAD^{commit}')).Trim() -ceq $repositories[$repository].head}catch{$unchanged=$false}
        if(-not $unchanged){$complete=$false;foreach($item in $items){if($item.git.repository -eq [IO.Path]::GetRelativePath($Workspace,$repository).Replace('\','/')){$item.git.status='HEAD_UNSTABLE';$item.status='UNKNOWN';$item.diagnostics+=,'DELIVERY_HEAD_UNSTABLE'}}}
    }
    $answer.items=$items.ToArray();$answer.status='CHECKED';$answer.coverage=if($complete){'COMPLETE'}else{'INCOMPLETE'}
    return $answer
}
