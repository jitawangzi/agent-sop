function Get-AiSopIncrementalReview {
    param([string]$Workspace,[string]$PreviousReport,$Repositories,$Latest)
    $answer=@{status='NOT_REQUESTED';blocking=$false;repositories=@();previousReport=$null;latestRunIds=@($Latest.runId);limits=@('Selected report is a comparison reference, not proof of approval.','Commit differences do not capture prior dirty or untracked bytes.','Changed paths do not automatically determine test coverage or invalidate review conclusions.')}
    if(-not $PreviousReport){return $answer}
    try{
        $path=Resolve-AiSopReviewChild $Workspace $PreviousReport
        $bytes=[IO.File]::ReadAllBytes($path)
        $prior=[Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xfeff)|ConvertFrom-Json -AsHashtable -NoEnumerate
        if($prior -isnot [System.Collections.IDictionary] -or $prior.derived -isnot [bool] -or -not $prior.derived -or $prior.repositories -isnot [System.Collections.IList]){throw 'INVALID_PREVIOUS_REVIEW'}
        $answer.previousReport=@{path=$PreviousReport;sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()}
        $answer.omittedPreviousRepositories=@($prior.repositories|Where-Object {$_.path -cnotin @($Repositories.path)}|ForEach-Object {@{path=$_.path;status='NOT_SELECTED'}})
        $answer.repositories=@(foreach($repo in $Repositories){
            $item=@{path=$repo.path;status='UNAVAILABLE';previousRevision=$null;revision=$repo.revision;committedDifference=@();previousWorkingChanges=@();workingChanges=$repo.workingChanges}
            try{
                $old=@($prior.repositories|Where-Object {$_.path -ceq $repo.path})
                if($old.Count -ne 1 -or $repo.status -ne 'AVAILABLE' -or $old[0].status -ne 'AVAILABLE' -or $old[0].revision -isnot [string] -or $old[0].revision -notmatch '^[0-9a-f]{40,64}$' -or $old[0].workingChanges -isnot [System.Collections.IList]){throw 'REVIEW_REFERENCE_UNAVAILABLE'}
                $root=if($repo.path -eq '.'){$Workspace}else{Resolve-AiSopReviewChild $Workspace $repo.path}
                $base=$old[0].revision
                $null=Get-AiSopDeliveryText $root @('rev-parse','--verify',($base+'^{commit}'))
                $item.previousRevision=$base;$item.previousWorkingChanges=@($old[0].workingChanges)
                $item.committedDifference=@((Get-AiSopDeliveryText $root @('diff','--no-ext-diff','--no-textconv','--name-status',$base,$repo.revision,'--')) -split '\r?\n'|Where-Object {$_})
                if((Get-AiSopDeliveryText $root @('rev-parse','HEAD')).Trim() -cne $repo.revision){throw 'REVIEW_HEAD_CHANGED'}
                $item.status=if($item.previousWorkingChanges.Count -or @($repo.workingChanges).Count){'COMMIT_DIFF_WITH_WORKTREE_LIMITS'}else{'COMMIT_DIFF'}
            }catch{$item.diagnostic=$_.Exception.Message}
            $item
        })
        $answer.status=if(-not $answer.repositories.Count -or $answer.omittedPreviousRepositories.Count -or @($answer.repositories|Where-Object status -eq UNAVAILABLE).Count){'PARTIAL'}else{'AVAILABLE'}
    }catch{$answer.status='UNAVAILABLE';$answer.diagnostic='PREVIOUS_REVIEW_UNAVAILABLE: '+$_.Exception.Message}
    return $answer
}
