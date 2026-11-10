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
