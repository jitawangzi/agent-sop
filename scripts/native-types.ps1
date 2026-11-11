# 两段不变的 Win32 辅助代码在同一进程中一次编译；不缓存跨进程制品或权限状态。
function Initialize-AiSopNativeTypes {
    if(-not [OperatingSystem]::IsWindows()){return}
    $sources=@(foreach($name in @('PhysicalPath','AtomicFile')){
        # 兼容同进程中已加载其中一个类型的入口，不能重复定义旧类型。
        $typeName=if($name -eq 'PhysicalPath'){'AiSop.PhysicalPathV2'}else{'AiSop.AtomicFile'}
        if(-not ($typeName -as [type])){Join-Path $PSScriptRoot ('native/'+$name+'.cs')}
    })
    if($sources.Count){Add-Type -LiteralPath $sources}
}
