#requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path $PSScriptRoot
. (Join-Path $scripts task-context.ps1)
. (Join-Path $scripts review-paths.ps1)
. (Join-Path $scripts review-delivery.ps1)
. (Join-Path $scripts review-incremental.ps1)
. (Join-Path $PSScriptRoot fixtures/retained-fixture.ps1)
. (Join-Path $PSScriptRoot fixtures/boundary-cases.ps1)
function Assert($ok,$message){if(-not $ok){throw $message}}
$root=Join-Path ([IO.Path]::GetTempPath()) ('incremental-review-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$success=$false;$failure=''
try{
    & git -C $root init -q
    & git -C $root config user.name fixture
    & git -C $root config user.email fixture@example.invalid
    [IO.File]::WriteAllText((Join-Path $root input.txt),'before')
    & git -C $root add input.txt
    & git -C $root commit -qm before
    Assert ($LASTEXITCODE -eq 0) 'Initial commit failed'
    $base=(& git -C $root rev-parse HEAD).Trim()
    $prior=@{derived=$true;repositories=@(@{path='.';status='AVAILABLE';revision=$base;workingChanges=@()})}
    $prior|ConvertTo-Json -Depth 8|Set-Content (Join-Path $root prior.json)
    [IO.File]::WriteAllText((Join-Path $root input.txt),'after')
    & git -C $root add input.txt
    & git -C $root commit -qm after
    Assert ($LASTEXITCODE -eq 0) 'Second commit failed'
    $head=(& git -C $root rev-parse HEAD).Trim()
    $repos=@(@{path='.';status='AVAILABLE';revision=$head;workingChanges=@('?? prior.json')})
    $hash=(Get-FileHash (Join-Path $root prior.json)).Hash
    $taskDir=Join-Path $root '.ai-workspace/specs/features/Example/tasks/change'
    [IO.Directory]::CreateDirectory($taskDir)|Out-Null
    @{schemaVersion='1.0';feature='Example';taskId='change';ownerId='fixture';tier='T2';status='ACTIVE';objective='incremental fixture';nextAction='';notes='';createdAt='2026-01-01T00:00:00Z';updatedAt='2026-01-01T00:00:00Z';requiredCaseIds=@();verifications=@()}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $taskDir task.json)
    $exported=& (Join-Path $scripts export-review.ps1) -WorkspacePath $root -Feature Example -TaskId change -RepositoryPaths @('.') -PreviousReview prior.json|ConvertFrom-Json
    Assert ($exported.incremental.status -eq 'AVAILABLE' -and ($exported.incremental.repositories[0].committedDifference -join '') -match 'input.txt' -and $exported.history.Count -eq 0) 'Actual exporter lost incremental comparison or complete history'
    $r=Get-AiSopIncrementalReview $root prior.json $repos @(@{runId='current'})
    Assert ($r.status -eq 'AVAILABLE' -and $r.repositories[0].status -eq 'COMMIT_DIFF_WITH_WORKTREE_LIMITS') 'Dirty state was hidden'
    Assert (($r.repositories[0].committedDifference -join '') -match 'input.txt' -and $r.latestRunIds[0] -eq 'current') 'Delta or current run reference missing'
    Assert ((Get-FileHash (Join-Path $root prior.json)).Hash -eq $hash) 'Prior report mutated'
    $prior.repositories+=@{path='omitted-repo';status='AVAILABLE';revision=$base;workingChanges=@()}
    $prior|ConvertTo-Json -Depth 8|Set-Content (Join-Path $root prior.json)
    $r=Get-AiSopIncrementalReview $root prior.json $repos @()
    Assert ($r.status -eq 'PARTIAL' -and $r.omittedPreviousRepositories[0].path -eq 'omitted-repo' -and $r.omittedPreviousRepositories[0].status -eq 'NOT_SELECTED') 'Unselected previous repository silently disappeared'
    $prior.repositories=@($prior.repositories[0])
    $prior.repositories[0].workingChanges=@(' M previous-dirty.txt')
    $repos[0].workingChanges=@()
    $prior|ConvertTo-Json -Depth 8|Set-Content (Join-Path $root prior.json)
    Assert ((Get-AiSopIncrementalReview $root prior.json $repos @()).repositories[0].status -eq 'COMMIT_DIFF_WITH_WORKTREE_LIMITS') 'Previous dirty state hidden'
    $prior.repositories[0].workingChanges=@()
    $prior.repositories[0].revision=$head
    $prior|ConvertTo-Json -Depth 8|Set-Content (Join-Path $root prior.json)
    $r=Get-AiSopIncrementalReview $root prior.json $repos @()
    Assert ($r.repositories[0].status -eq 'COMMIT_DIFF' -and $r.repositories[0].committedDifference.Count -eq 0) 'Identical clean commits invented changes'
    Assert ((Get-AiSopIncrementalReview $root prior.json @() @()).status -eq 'PARTIAL') 'Empty selection claimed complete comparison'
    $repos[0].revision=$base
    Assert ((Get-AiSopIncrementalReview $root prior.json $repos @()).repositories[0].diagnostic -eq 'REVIEW_HEAD_CHANGED') 'HEAD drift hidden'
    $repos[0].revision=$head
    $prior.repositories[0].revision='0'*40
    $prior|ConvertTo-Json -Depth 8|Set-Content (Join-Path $root prior.json)
    Assert ((Get-AiSopIncrementalReview $root prior.json $repos @()).status -eq 'PARTIAL') 'Unavailable commit hidden'
    foreach($case in @(Get-AiSopJsonBoundaryCases Object|Where-Object {-not $_.accepted})){
        $case.json|Set-Content (Join-Path $root prior.json)
        Assert ((Get-AiSopIncrementalReview $root prior.json $repos @()).status -eq 'UNAVAILABLE') 'Invalid previous report accepted'
    }
    Assert ((Get-AiSopIncrementalReview $root '../escape' $repos @()).status -eq 'UNAVAILABLE') 'Previous report escaped workspace'
    Assert ((Get-AiSopIncrementalReview $root '' $repos @()).status -eq 'NOT_REQUESTED') 'Optional comparison became mandatory'
    $success=$true
}catch{$failure=$_.ToString();throw}finally{Complete-AiSopTestFixture -Root $root -Prefix incremental-review- -Succeeded $success -Failure $failure}
Write-Output 'PASS: read-only incremental commit comparison, worktree limits, invalid/missing references and optional use'
