#requires -Version 7.0
# These optional tools reject linked descendants instead of trusting lexical containment.
function Resolve-AiSopReviewChild([string]$Root,[string]$RelativePath) {
    if([IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '(^|[/\\])\.\.([/\\]|$)'){throw 'REVIEW_PATH_ESCAPE'}
    $cursor=[IO.Path]::GetFullPath($Root)
    foreach($part in ($RelativePath -split '[/\\]')){
        if(-not $part -or $part -eq '.'){continue}
        $cursor=Join-Path $cursor $part
        $item=Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'REVIEW_LINKED_DESCENDANT_UNSUPPORTED'}
    }
    return Resolve-AiSopWorkspaceChild $Root $RelativePath
}
function ConvertTo-AiSopReviewScope([string]$Path) {
    if(-not $Path -or [IO.Path]::IsPathRooted($Path) -or $Path -match '(^|[/\\])\.\.([/\\]|$)'){throw 'REVIEW_SCOPE_INVALID'}
    $parts=@($Path.Replace('\','/') -split '/'|Where-Object {$_ -and $_ -ne '.'})
    if(-not $parts.Count){return '.'}
    return $parts -join '/'
}
