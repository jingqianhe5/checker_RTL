param([string]$VivadoBin='C:\software\vivado\Vivado\2020.2\bin',[switch]$Elaborate,[switch]$Evidence=$true)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$build=Join-Path $root 'build\system'
New-Item -ItemType Directory -Force -Path $build | Out-Null
& python (Join-Path $PSScriptRoot 'generate_system_vectors.py')
if($LASTEXITCODE -ne 0){throw 'System oracle generation failed'}
& python (Join-Path $PSScriptRoot 'wave_signals.py')
if($LASTEXITCODE -ne 0){throw 'Waveform selection generation failed'}
function Run-Tool {
    param([string]$Tool,[string[]]$ToolArgs,[string]$Pass='')
    $output=& (Join-Path $VivadoBin ($Tool+'.bat')) @ToolArgs 2>&1
    $code=$LASTEXITCODE
    $output|Out-Host
    $all=$output -join "`n"
    if($code -ne 0 -or $all -match '(?m)^(FAIL:|ERROR:)'){throw "$Tool failed"}
    if($Pass -and $all -notmatch [regex]::Escape($Pass)){throw 'Missing expected PASS marker'}
}
Push-Location $build
try {
    $sources=@('-i','../../rtl') + @(Get-ChildItem (Join-Path $root 'rtl') -Filter '*.v' | ForEach-Object {$_.FullName}) + @('../../tb/tb_sys_top.v')
    Run-Tool xvlog $sources
    $depths=@(1,8)
    foreach($depth in $depths) {
        $snapshot='system_'+$depth
        Run-Tool xelab @('tb_sys_top','-generic_top',('"FIFO_DEPTH='+$depth+'"'),'-debug','typical','-s',$snapshot)
        if($Evidence -and $depth -eq 1){
            # A full-system depth-one run forces FIFO backpressure. The review
            # waveform remains the depth-eight run under its established name.
            Run-Tool xsim @($snapshot,'-testplusarg',('"SUMMARY_FILE=system_1_summary.csv"'),
                '-testplusarg',('"EVIDENCE_LOG=system_1_events.csv"'),'-runall') 'PASS: sys_top end-to-end'
            continue
        }
        $outputName=if($Evidence){'system_'+$depth+'_evidence'}else{'system_'+$depth}
        $traceScript=if($Evidence){'source ../../scripts/waves_evidence.tcl'}else{'source ../../scripts/waves_system.tcl'}
        $vcdName=if($Evidence){$outputName+'_raw.vcd'}else{$outputName+'.vcd'}
        $waveScript=$outputName+'_wave.tcl'
        @("set wave_file $vcdName", "set wave_config_file $outputName.wcfg", $traceScript) |
            Set-Content -LiteralPath $waveScript -Encoding ascii
        Run-Tool xsim @($snapshot,'-testplusarg',('"SUMMARY_FILE='+$outputName+'_summary.csv"'),
            '-testplusarg',('"EVIDENCE_LOG='+$outputName+'_events.csv"'),
            '-wdb',($outputName+'.wdb'),'-tclbatch',$waveScript) 'PASS: sys_top end-to-end'
    }
    if($Evidence){
        & python (Join-Path $PSScriptRoot 'audit_system_evidence.py')
        if($LASTEXITCODE -ne 0){throw 'Whole-system VCD audit failed'}
        & python (Join-Path $PSScriptRoot 'export_block3_evidence.py')
        if($LASTEXITCODE -ne 0){throw 'Block 3 evidence export failed'}
        & python (Join-Path $PSScriptRoot 'wave_signals.py') --publish
        if($LASTEXITCODE -ne 0){throw 'Key-signal waveform export failed'}
        Remove-Item -LiteralPath 'system_8_evidence_raw.vcd'
    }
    if($Elaborate){Run-Tool vivado @('-mode','batch','-source','../../scripts/check_system_rtl.tcl','-log','system_rtl.log','-journal','system_rtl.jou') 'PASS: sys_top RTL elaboration'}
    Write-Host 'PASS: all whole-system simulations'
} finally {Pop-Location}
