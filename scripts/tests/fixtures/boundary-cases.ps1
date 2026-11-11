# 可复用的输入反例；调用者仍执行真实入口并断言领域语义。
function Get-AiSopJsonBoundaryCases {
    param([ValidateSet('Object','NonnegativeNumber')][string]$Kind)
    $cases=@(
        @{id='null';json='null';kind='Null'},
        @{id='empty-object';json='{}';kind='Object'},
        @{id='empty-array';json='[]';kind='Array'},
        @{id='boolean-true';json='true';kind='Boolean'},
        @{id='boolean-false';json='false';kind='Boolean'},
        @{id='numeric-string';json='"1"';kind='String'},
        @{id='zero';json='0';kind='Number'},
        @{id='integer';json='12';kind='Number'},
        @{id='fraction';json='1.5';kind='Number'},
        @{id='negative';json='-1';kind='Negative'}
    )
    foreach($case in $cases){
        $case.accepted=if($Kind -eq 'Object'){$case.kind -eq 'Object'}else{$case.kind -eq 'Number'}
        [pscustomobject]$case
    }
}
function Get-AiSopInvalidPathDeclarations {
    param([Parameter(Mandatory)][string]$Root)
    $absolute=[IO.Path]::GetFullPath((Join-Path $Root escape))
    if(-not [IO.Path]::IsPathRooted($absolute)){throw 'BOUNDARY_NATIVE_PATH_NOT_ROOTED'}
    foreach($path in @('../escape',$absolute)){
        [pscustomobject]@{path=$path;json=(ConvertTo-Json -InputObject @($path) -Compress)}
    }
}

# 同一个目标的链接写法；是否允许越界由真实消费者决定，夹具不预设权限结论。
function Get-AiSopEquivalentLocalLinkCases {
    param([Parameter(Mandatory)][string]$DocumentDirectory,[Parameter(Mandatory)][string]$TargetPath)
    $target=[IO.Path]::GetFullPath($TargetPath)
    $relative=[IO.Path]::GetRelativePath([IO.Path]::GetFullPath($DocumentDirectory),$target).Replace('\','/')
    $cases=@(
        @{id='relative';target=$relative},
        @{id='absolute';target=$target.Replace('\','/')}
    )
    if(-not [IO.Path]::IsPathRooted($relative)){$cases+=@{id='relative-dot';target='./'+$relative}}
    if([OperatingSystem]::IsWindows()){
        $cases+=@{id='windows-separator';target=$target}
        if($target -match '^[a-zA-Z]:'){$cases+=@{id='windows-leading-slash';target='/'+$target.Replace('\','/')}}
    }
    foreach($case in $cases){
        $case.target=$case.target.Replace('%','%25').Replace(' ','%20').Replace('#','%23').Replace('?','%3F').Replace('(','%28').Replace(')','%29')
        [pscustomobject]$case
    }
    [pscustomobject]@{id='file-uri';target=([Uri]::new($target,[UriKind]::Absolute)).AbsoluteUri.Replace('(','%28').Replace(')','%29')}
}

# 声明预期，不调用生产解释器；所有消费者复用同一组记录反例。
function Get-AiSopVerificationRecordCases {
    @(
        @{id='passed';outcome='PASSED';exitCode=0;inputsStable=$true;expectedPass=$true},
        @{id='failed';outcome='FAILED';exitCode=1;inputsStable=$true;expectedPass=$false},
        @{id='timeout';outcome='TIMED_OUT';exitCode=124;inputsStable=$true;expectedPass=$false},
        @{id='interrupted';outcome='INTERRUPTED';exitCode=130;inputsStable=$true;expectedPass=$false},
        @{id='running';outcome='RUNNING';exitCode=-2;inputsStable=$false;expectedPass=$false},
        @{id='unstable';outcome='PASSED';exitCode=0;inputsStable=$false;expectedPass=$false},
        @{id='nonzero';outcome='PASSED';exitCode=1;inputsStable=$true;expectedPass=$false}
    )
}

# Expectations are declared independently of the production fact reader.
function Get-AiSopProcessContractCases {
    @(
        @{id='zero';code=0;diagnostic='';completed=$true;disposed=$true;confirmed=$true;pending=$false;expected=$true},
        @{id='nonzero';code=23;diagnostic='';completed=$true;disposed=$true;confirmed=$true;pending=$false;expected=$true},
        @{id='running';code=0;diagnostic='';completed=$false;disposed=$false;confirmed=$false;pending=$false;expected=$false},
        @{id='not-disposed';code=0;diagnostic='';completed=$true;disposed=$false;confirmed=$true;pending=$false;expected=$false},
        @{id='drain';code=125;diagnostic='OUTPUT_DRAIN_TIMED_OUT';completed=$true;disposed=$true;confirmed=$true;pending=$false;expected=$false},
        @{id='cleanup';code=125;diagnostic='PROCESS_CLEANUP_FAILED';completed=$true;disposed=$true;confirmed=$false;pending=$false;expected=$false},
        @{id='pending';code=0;diagnostic='';completed=$true;disposed=$true;confirmed=$true;pending=$true;expected=$false}
    )
}
