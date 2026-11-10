# 只识别有限的正文内联链接；保留位置和跳过原因，不把识别范围当作完整 Markdown 验证。
function Get-AiSopMarkdownLinkScan([string]$Text) {
    $excluded=[Collections.Generic.List[object]]::new()
    $masked=[Text.StringBuilder]::new()
    $fence=''
    foreach($line in [regex]::Matches($Text,'[^\r\n]*(?:\r\n|\n|\r|$)')){
        if(-not $line.Length){continue}
        $skip=[bool]$fence
        if($line.Value -match '^\s*(`{3,}|~{3,})'){
            $mark=$Matches[1];$skip=$true
            if(-not $fence){$fence=$mark}elseif($mark[0] -eq $fence[0] -and $mark.Length -ge $fence.Length){$fence=''}
        }
        if($skip){
            $excluded.Add(@{start=$line.Index;end=$line.Index+$line.Length;reason='FENCED_CODE'})
            [void]$masked.Append([regex]::Replace($line.Value,'[^\r\n]',' '))
        }else{[void]$masked.Append($line.Value)}
    }
    foreach($span in [regex]::Matches($masked.ToString(),'(?s)(?<!`)(`+)(?!`).*?(?<!`)\1(?!`)')){
        $excluded.Add(@{start=$span.Index;end=$span.Index+$span.Length;reason='INLINE_CODE'})
    }
    $ranges=@($excluded|Sort-Object start)
    $rangeIndex=0;$lineNumber=1;$previousIndex=0;$lineStart=0
    $links=[Collections.Generic.List[object]]::new()
    $skipped=[Collections.Generic.List[object]]::new()
    $inline=[regex]::new('\G\[[^\]\r\n]+\]\(([^()\s]+)\)')
    # 标记未支持的内联写法及引用式写法，不尝试猜测其目标或访问文件。
    foreach($marker in [regex]::Matches($Text,'\[[^\]\r\n]+\](?:\(|\[[^\]\r\n]*\])')){
        $between=$Text.Substring($previousIndex,$marker.Index-$previousIndex)
        $newlines=[regex]::Matches($between,'\r\n|\n|\r')
        $lineNumber+=$newlines.Count
        if($newlines.Count){$last=$newlines[$newlines.Count-1];$lineStart=$previousIndex+$last.Index+$last.Length}
        $previousIndex=$marker.Index
        while($rangeIndex -lt $ranges.Count -and $ranges[$rangeIndex].end -le $marker.Index){$rangeIndex++}
        $reason='';$match=$inline.Match($Text,$marker.Index)
        if($rangeIndex -lt $ranges.Count -and $ranges[$rangeIndex].start -le $marker.Index){$reason=$ranges[$rangeIndex].reason}
        elseif(-not $match.Success){$reason='UNSUPPORTED_SYNTAX'}
        else{
            $target=$match.Groups[1].Value
            if($target.StartsWith('#')){$reason='ANCHOR'}
            elseif($target -match '^[a-zA-Z][a-zA-Z0-9+.-]*:' -and $target -notmatch '^[a-zA-Z]:[/\\]' -and $target -notmatch '^file:'){$reason='EXTERNAL_SCHEME'}
        }
        $position=@{line=$lineNumber;column=$marker.Index-$lineStart+1}
        if($reason){$position.reason=$reason;$skipped.Add($position)}
        else{$position.target=$target;$links.Add($position)}
    }
    $counts=@{}
    foreach($item in $skipped){if(-not $counts.ContainsKey($item.reason)){$counts[$item.reason]=0};$counts[$item.reason]++}
    return @{links=$links.ToArray();skipped=$skipped.ToArray();coverage=@{
        status=if($links.Count){'SUPPORTED_LOCAL_LINKS_CHECKED'}else{'NO_SUPPORTED_LOCAL_LINKS'}
        recognizedCandidates=$links.Count+$skipped.Count;checkedLinks=$links.Count;skippedLinks=$skipped.Count;skippedByReason=$counts
        limits=@('Counts cover recognized candidates only, not all Markdown syntax.','No supported local links means link contents were not checked.','File presence and skipped candidates do not prove all references are valid.')
    }}
}
