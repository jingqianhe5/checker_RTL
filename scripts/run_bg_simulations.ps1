param([string]$VivadoBin='C:\software\vivado\Vivado\2020.2\bin')
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$buildDir=Join-Path $projectRoot 'build\bg_corrector'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
& python (Join-Path $PSScriptRoot 'generate_bg_vectors.py')
if($LASTEXITCODE -ne 0){throw 'BG reference generation failed'}
function Invoke-Tool {
    param([string]$Name,[string[]]$ToolArgs,[string]$Pass='')
    $output=& (Join-Path $VivadoBin ($Name+'.bat')) @ToolArgs 2>&1
    $code=$LASTEXITCODE
    $output | Out-Host
    $all=$output -join "`n"
    if($code -ne 0 -or $all -match '(?m)^FAIL:'){throw "$Name failed"}
    if($Pass -and $all -notmatch [regex]::Escape($Pass)){throw 'Missing PASS marker'}
}
Push-Location $buildDir
try {
    Invoke-Tool xvlog @('-i','../../rtl','../../rtl/fp16_add.v','../../rtl/sync_fifo.v',
        '../../rtl/bg_fault_fifo.v','../../rtl/bg_locator.v','../../rtl/BG_corrector.v',
        '../../tb/tb_bg_locator.v','../../tb/tb_BG_corrector.v')
    foreach($n in @(16,3,1)){
        $snapshot='locator_'+$n
        Invoke-Tool xelab @('tb_bg_locator','-generic_top',('"NUM_LANES='+$n+'"'),'-s',$snapshot)
        Invoke-Tool xsim @($snapshot,'-testplusarg',('"CASE_FILE=locator_'+$n+'.txt"'),'-runall') 'PASS: bg_locator'
    }
    foreach($depth in @(1,3,16)){
        $snapshot='bg_'+$depth
        Invoke-Tool xelab @('tb_BG_corrector','-generic_top',('"FIFO_DEPTH='+$depth+'"'),'-s',$snapshot)
        Invoke-Tool xsim @($snapshot,'-runall') 'PASS: BG_corrector'
    }
    Write-Host 'PASS: all BG regressions'
} finally {Pop-Location}
