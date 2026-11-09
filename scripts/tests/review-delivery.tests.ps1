#requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path -Parent $PSScriptRoot
. (Join-Path $scripts task-context.ps1)
. (Join-Path $scripts review-paths.ps1)
. (Join-Path $scripts review-delivery.ps1)
$root=Join-Path ([IO.Path]::GetTempPath()) ('delivery-review-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
function Assert($condition,[string]$message){if(-not $condition){throw $message}}
function FixtureGit([string]$where,[string[]]$arguments){$output=& git -C $where @arguments 2>&1;if($LASTEXITCODE -ne 0){throw ($output|Out-String)}}
function Put([string]$path,[byte[]]$bytes){[IO.Directory]::CreateDirectory((Split-Path -Parent $path))|Out-Null;[IO.File]::WriteAllBytes($path,$bytes)}
function Hash([string]$path){return (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()}
function Declare([string]$path){return @{path=$path;sha256=(Hash (Join-Path $root $path))}}
function Review($entries){ConvertTo-Json -InputObject @($entries) -Depth 10|Set-Content (Join-Path $root manifest.json);return Get-AiSopDeliveryReview $root manifest.json}
function Item($report,[string]$path){return @($report.items|Where-Object path -CEQ $path)[0]}
try{
 FixtureGit $root @('init','-q','-b','main');FixtureGit $root @('config','user.name','Fixture');FixtureGit $root @('config','user.email','fixture@example.invalid');FixtureGit $root @('config','core.autocrlf','false')
 Put (Join-Path $root '.gitattributes') ([Text.Encoding]::UTF8.GetBytes("* -text`ncrlf.txt text`n"))
 foreach($name in @('stable.bin','missing.bin','changed.bin','staged-change.bin')){Put (Join-Path $root $name) ([byte[]]@(0,255,13,10,42,0))}
 Put (Join-Path $root crlf.txt) ([Text.Encoding]::UTF8.GetBytes("one`r`ntwo`r`n"))
 $expected=@(Declare stable.bin;Declare missing.bin;Declare changed.bin;Declare staged-change.bin;Declare crlf.txt)
 FixtureGit $root @('add','.');FixtureGit $root @('commit','-q','-m','fixture baseline')
 Put (Join-Path $root local.bin) ([byte[]]@(7,8));Put (Join-Path $root staged.bin) ([byte[]]@(9,10));FixtureGit $root @('add','--','staged.bin')
 Put (Join-Path $root changed.bin) ([byte[]]@(4,5));Put (Join-Path $root staged-change.bin) ([byte[]]@(2,3));FixtureGit $root @('add','--','staged-change.bin')
 Remove-Item -LiteralPath (Join-Path $root missing.bin)
 $expected=@($expected|Where-Object path -ne 'staged-change.bin')+@(Declare staged-change.bin;Declare local.bin;Declare staged.bin)
 $nested=Join-Path $root nested;[IO.Directory]::CreateDirectory($nested)|Out-Null
 FixtureGit $nested @('init','-q','-b','main');FixtureGit $nested @('config','user.name','Fixture');FixtureGit $nested @('config','user.email','fixture@example.invalid')
 Put (Join-Path $nested inner.bin) ([byte[]]@(1,2,3));FixtureGit $nested @('add','.');FixtureGit $nested @('commit','-q','-m','nested fixture')
 $expected+=Declare nested/inner.bin
 Put (Join-Path $root .gitignore) ([Text.Encoding]::UTF8.GetBytes("nested/`nlocal.bin`n"))
 Add-Content (Join-Path $root .gitattributes) 'stable.bin filter=tripwire'
 FixtureGit $root @('config','filter.tripwire.smudge','delivery-filter-must-not-execute');FixtureGit $root @('config','filter.tripwire.clean','delivery-filter-must-not-execute');FixtureGit $root @('config','filter.tripwire.required','true')
 $report=Review $expected
 Assert ((Item $report stable.bin).status -eq 'COMMITTED') 'Binary HEAD bytes or no-filter boundary failed'
 Assert ((Item $report missing.bin).status -eq 'MISSING' -and (Item $report missing.bin).git.status -eq 'MATCH') 'Missing local conflated with committed copy'
 Assert ((Item $report changed.bin).status -eq 'CHANGED') 'Changed local not detected'
 foreach($name in @('local.bin','staged.bin','staged-change.bin','crlf.txt')){Assert ((Item $report $name).status -eq 'LOCAL') "Index/untracked/normalized bytes treated as committed:$name"}
 Assert ((Item $report nested/inner.bin).status -eq 'COMMITTED' -and (Item $report nested/inner.bin).git.repository -eq 'nested') 'Nearest nested repository not used'
 Assert ((Get-AiSopDeliveryReview $root '').status -eq 'NOT_REQUESTED') 'Implicit delivery obligation'
 Assert ((Review @()).items.Count -eq 0) 'Empty array unsupported'
 Assert ((Review @((Declare stable.bin))).items.Count -eq 1) 'Single item array collapsed'
 $manifestPath=Join-Path $root manifest.json
 [IO.File]::WriteAllBytes($manifestPath,([byte[]](@(239,187,191)+[IO.File]::ReadAllBytes($manifestPath))))
 $bom=Get-AiSopDeliveryReview $root manifest.json
 Assert ($bom.items[0].status -eq 'COMMITTED' -and $bom.manifest.sha256 -eq (Hash $manifestPath)) 'BOM parsing changed raw manifest binding'
 $hadDir=Test-Path Env:git_dir;$hadTree=Test-Path Env:git_work_tree
 $oldDir=[Environment]::GetEnvironmentVariable('git_dir');$oldTree=[Environment]::GetEnvironmentVariable('git_work_tree')
 try{
  [Environment]::SetEnvironmentVariable('git_dir',(Join-Path $nested .git));[Environment]::SetEnvironmentVariable('git_work_tree',$nested)
  Assert ((Review @((Declare stable.bin))).items[0].status -eq 'COMMITTED') 'Inherited lowercase Git environment redirected repository'
 }finally{
  if($hadDir){[Environment]::SetEnvironmentVariable('git_dir',$oldDir)}else{Remove-Item Env:git_dir -ErrorAction SilentlyContinue}
  if($hadTree){[Environment]::SetEnvironmentVariable('git_work_tree',$oldTree)}else{Remove-Item Env:git_work_tree -ErrorAction SilentlyContinue}
 }
 foreach($invalid in @('null','{}','"text"','{broken')){[IO.File]::WriteAllText((Join-Path $root manifest.json),$invalid);Assert ((Get-AiSopDeliveryReview $root manifest.json).status -eq 'UNAVAILABLE') 'Bad manifest crashed or passed'}
 $mixed=Review @((Declare stable.bin),@{path='../escape';sha256=('0'*64)},'invalid',@{path='stable.bin';sha256=('1'*64)})
 Assert ($mixed.coverage -eq 'INCOMPLETE' -and $mixed.items[0].status -eq 'COMMITTED' -and @($mixed.items|Where-Object status -eq 'UNKNOWN').Count -eq 3) 'Invalid items lost valid facts'
 Put (Join-Path $root broken/.git) ([Text.Encoding]::UTF8.GetBytes('gitdir: nonexistent'))
 Put (Join-Path $root broken/file.bin) ([byte[]]@(8,8))
 Assert ((Review @((Declare broken/file.bin))).items[0].status -eq 'UNKNOWN') 'Broken nested repository fell back to parent'
 # 真实链接入口不可穿越；Git 中链接/子模块也不能当普通交付字节。
 $target=Join-Path $root link-target;[IO.Directory]::CreateDirectory($target)|Out-Null
 Put (Join-Path $target file.bin) ([byte[]]@(3,4))
 $link=Join-Path $root linked
 if([OperatingSystem]::IsWindows()){New-Item -ItemType Junction -Path $link -Target $target|Out-Null}else{New-Item -ItemType SymbolicLink -Path $link -Target $target|Out-Null}
 try{Assert ((Review @(@{path='linked/file.bin';sha256=(Hash (Join-Path $target file.bin))})).items[0].status -eq 'UNKNOWN') 'Linked descendant accepted'}finally{Remove-Item -LiteralPath $link -Force}
 $head=(& git -C $nested rev-parse HEAD).Trim()
 $blob=(& git -C $nested rev-parse 'HEAD:inner.bin').Trim()
 Put (Join-Path $nested head-link) ([byte[]]@(1,2,3));Put (Join-Path $nested head-submodule) ([byte[]]@(1,2,3))
 FixtureGit $nested @('update-index','--add','--cacheinfo',"120000,$blob,head-link")
 FixtureGit $nested @('update-index','--add','--cacheinfo',"160000,$head,head-submodule")
 FixtureGit $nested @('commit','-q','-m','non-blob modes fixture')
 $modes=Review @((Declare nested/head-link),(Declare nested/head-submodule))
 Assert (@($modes.items|Where-Object status -eq 'UNKNOWN').Count -eq 2) 'HEAD symlink/gitlink treated as normal blob'
 $worktree=Join-Path $root linked-worktree
 FixtureGit $nested @('worktree','add','--detach',$worktree,$head)
 Assert ((Review @((Declare linked-worktree/inner.bin))).items[0].status -eq 'COMMITTED') 'Linked Git worktree unsupported'
 $manifest=Join-Path $root manifest.json
 $taskDir=Join-Path $root '.ai-workspace/specs/features/Example/tasks/delivery'
 [IO.Directory]::CreateDirectory($taskDir)|Out-Null
 @{schemaVersion='1.0';taskId='delivery';feature='Example';ownerId='fixture';tier='T2';objective='Delivery fixture';status='DONE';nextAction='';notes='';createdAt='2026-01-01T00:00:00Z';updatedAt='2026-01-01T00:00:00Z';requiredCaseIds=@();verifications=@()}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $taskDir task.json)
 $null=Review @((Declare stable.bin));$before=Hash $manifest;$gitBefore=(Get-AiSopReadOnlyWorkingChanges $root|Out-String)
 $export=& (Join-Path $scripts export-review.ps1) -WorkspacePath $root -Feature Example -TaskId delivery -RepositoryPaths @('.') -DeliveryManifest manifest.json|ConvertFrom-Json
 Assert ($export.taskStatus -eq 'DONE' -and $export.delivery.items[0].status -eq 'COMMITTED' -and $export.repositories[0].status -eq 'AVAILABLE') 'Exporter integration or no-filter status failed'
 Assert ((Hash $manifest) -eq $before -and (Get-AiSopReadOnlyWorkingChanges $root|Out-String) -ceq $gitBefore) 'Read-only delivery changed inputs or Git state'
 $expectedHead=(& git -C $root rev-parse HEAD).Trim()
 $savedGitDir=[Environment]::GetEnvironmentVariable('GIT_DIR');$savedWorkTree=[Environment]::GetEnvironmentVariable('GIT_WORK_TREE')
 $hadGitDir=Test-Path Env:GIT_DIR;$hadWorkTree=Test-Path Env:GIT_WORK_TREE
 try{
  [Environment]::SetEnvironmentVariable('GIT_DIR',(Join-Path $nested .git));[Environment]::SetEnvironmentVariable('GIT_WORK_TREE',$root)
  $polluted=& (Join-Path $scripts export-review.ps1) -WorkspacePath $root -Feature Example -TaskId delivery -RepositoryPaths @('.') -DeliveryManifest manifest.json|ConvertFrom-Json
  Assert ($polluted.repositories[0].revision -ceq $expectedHead -and $polluted.delivery.items[0].git.commit -ceq $expectedHead) 'Exporter mixed repository identities under inherited Git environment'
 }finally{
  if($hadGitDir){[Environment]::SetEnvironmentVariable('GIT_DIR',$savedGitDir)}else{Remove-Item Env:GIT_DIR -ErrorAction SilentlyContinue}
  if($hadWorkTree){[Environment]::SetEnvironmentVariable('GIT_WORK_TREE',$savedWorkTree)}else{Remove-Item Env:GIT_WORK_TREE -ErrorAction SilentlyContinue}
 }
 # 独立命令行缺 Git 时，stdout 必须仍是单个 JSON；不能只测同进程成功流。
 $child=[Diagnostics.Process]::new()
 try{
  $child.StartInfo.FileName=(Get-Process -Id $PID).Path;$child.StartInfo.UseShellExecute=$false;$child.StartInfo.CreateNoWindow=$true
  $child.StartInfo.RedirectStandardOutput=$true;$child.StartInfo.RedirectStandardError=$true;$child.StartInfo.Environment['PATH']=''
  foreach($arg in @('-NoProfile','-File',(Join-Path $scripts export-review.ps1),'-WorkspacePath',$root,'-Feature','Example','-TaskId','delivery','-DeliveryManifest','manifest.json')){[void]$child.StartInfo.ArgumentList.Add($arg)}
  Assert ($child.Start()) 'No-Git CLI failed to start'
  $out=$child.StandardOutput.ReadToEndAsync();$err=$child.StandardError.ReadToEndAsync()
  Assert ($child.WaitForExit(20000)) 'No-Git CLI timeout'
  Assert ([Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($out,$err),5000)) 'No-Git output incomplete'
  $noGit=$out.GetAwaiter().GetResult()|ConvertFrom-Json
  Assert ($child.ExitCode -eq 0 -and $noGit.taskStatus -eq 'DONE' -and $noGit.delivery.items[0].status -eq 'UNKNOWN') 'Missing Git broke CLI JSON or lost task facts'
 }finally{if(-not $child.HasExited){$child.Kill($true);[void]$child.WaitForExit(5000)};$child.Dispose()}
 $realText=(Get-Command Get-AiSopDeliveryText).ScriptBlock;$script:deliveryHeadCalls=0
 try{
  function Get-AiSopDeliveryText([string]$Repository,[string[]]$Arguments){
   if($Arguments[0] -eq 'rev-parse' -and $Arguments[1] -eq '--verify'){$script:deliveryHeadCalls++;if($script:deliveryHeadCalls -gt 1){return ('0'*40)}}
   & $realText $Repository $Arguments
  }
  $moved=Review @((Declare stable.bin))
  Assert ($moved.coverage -eq 'INCOMPLETE' -and $moved.items[0].status -eq 'UNKNOWN' -and $moved.items[0].git.status -eq 'HEAD_UNSTABLE') 'HEAD movement retained committed claim'
 }finally{Set-Item Function:Get-AiSopDeliveryText $realText}
 # 父仓存在真实 gitlink 时，不能通过子模块 status 间接执行其私有过滤器。
 FixtureGit $root @('config','filter.tripwire.required','false');FixtureGit $root @('config','filter.tripwire.clean','')
 FixtureGit $root @('add','-f','--','nested');FixtureGit $root @('commit','-q','-m','embedded repository gitlink')
 $marker=Join-Path $root filter-executed.marker;$filterScript=Join-Path $root filter-tripwire.ps1
 [IO.File]::WriteAllText($filterScript,"[IO.File]::WriteAllText('"+$marker.Replace("'","''")+"','executed'); [Console]::OpenStandardInput().CopyTo([Console]::OpenStandardOutput())")
 $filterCommand='"'+(Get-Process -Id $PID).Path.Replace('\','/')+'" -NoProfile -File "'+$filterScript.Replace('\','/')+'"'
 FixtureGit $nested @('config','filter.childtripwire.clean',$filterCommand);FixtureGit $nested @('config','filter.childtripwire.required','true')
 Put (Join-Path $nested .gitattributes) ([Text.Encoding]::UTF8.GetBytes("inner.bin filter=childtripwire`n"));Put (Join-Path $nested inner.bin) ([byte[]]@(4,5,6))
 FixtureGit $nested @('status','--porcelain=v1','--ignore-submodules=dirty')
 Assert (Test-Path -LiteralPath $marker) 'Submodule filter tripwire not active'
 Remove-Item -LiteralPath $marker
 $safeExport=& (Join-Path $scripts export-review.ps1) -WorkspacePath $root -Feature Example -TaskId delivery -RepositoryPaths @('.') -DeliveryManifest manifest.json|ConvertFrom-Json
 Assert ($safeExport.repositories[0].status -eq 'AVAILABLE' -and -not (Test-Path -LiteralPath $marker)) 'Parent review executed child repository filter'
 # 真实 Git 子进程超时与退出后后代持管道；夹具使用有界 sleep，不调用业务资源。
 $failure='';$watch=[Diagnostics.Stopwatch]::StartNew()
 try{$null=Invoke-AiSopDeliveryGit $root @('-c','alias.delivery-timeout=!sleep 30','delivery-timeout')}catch{$failure=$_.Exception.Message}
 Assert ($failure -eq 'DELIVERY_GIT_TIMEOUT' -and $watch.Elapsed.TotalSeconds -lt 30) 'Git execution timeout was unbounded or misclassified'
 $failure='';$watch.Restart()
 try{$null=Invoke-AiSopDeliveryGit $root @('-c','alias.delivery-pipe=!sleep 8 &','delivery-pipe')}catch{$failure=$_.Exception.Message}
 Assert ($failure -eq 'DELIVERY_GIT_OUTPUT_INCOMPLETE' -and $watch.Elapsed.TotalSeconds -lt 20) 'Inherited pipe was not bounded or classified'
 Start-Sleep -Seconds 9 # 等待这个专用有界后代自然退出，避免留下运行资源。
 Write-Output 'PASS: explicit delivery manifest, raw committed bytes, local/index distinction, nested roots, normalization, no filters, partial errors, read-only export'
}finally{
 $resolved=[IO.Path]::GetFullPath($root);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
 if(-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'delivery-review-*'){throw 'Unsafe fixture cleanup'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
