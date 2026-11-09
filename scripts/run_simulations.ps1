param(
    [string]$VivadoBin = 'C:\software\vivado\Vivado\2020.2\bin',
    [switch]$Elaborate
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$simulationDir = Join-Path $projectRoot 'build\bank_checker'
New-Item -ItemType Directory -Force -Path $simulationDir | Out-Null

function Invoke-VivadoTool {
    param([string]$Tool, [string[]]$ToolArgs, [string]$PassPattern = '')
    $toolPath = Join-Path $VivadoBin ($Tool + '.bat')
    if (!(Test-Path -LiteralPath $toolPath)) { throw "Tool not found: $toolPath" }
    $toolOutput = & $toolPath @ToolArgs 2>&1
    $toolExitCode = $LASTEXITCODE
    $toolOutput | Out-Host
    $toolText = $toolOutput -join "`n"
    if ($toolExitCode -ne 0 -or $toolText -match '(?m)^FAIL:') {
        throw "$Tool failed (exit $toolExitCode)"
    }
    if ($PassPattern -and $toolText -notmatch [regex]::Escape($PassPattern)) {
        throw "$Tool did not report the expected PASS marker"
    }
}

& python (Join-Path $PSScriptRoot 'generate_gemv_vectors.py')
if ($LASTEXITCODE -ne 0) { throw 'Reference vector generation failed' }
Push-Location $simulationDir
try {
    Invoke-VivadoTool -Tool xvlog -ToolArgs @(
        '-i', '../../rtl', '../../rtl/input_mode_mux.v',
        '../../rtl/fp16_add.v', '../../rtl/fp16_mul.v',
        '../../rtl/bank_gemv.v', '../../rtl/Bank_checker.v',
        '../../rtl/zero_bound.v', '../../rtl/result_buffer.v',
        '../../rtl/h_calculator_control.v', '../../rtl/bank_checker_fsm.v',
        '../../rtl/syndrome_checker.v', '../../tb/tb_syndrome_checker.v',
        '../../tb/tb_fp16.v', '../../tb/tb_bank_gemv.v',
        '../../tb/tb_Bank_checker.v', '../../tb/tb_input_mode_mux.v',
        '../../tb/tb_zero_bound.v', '../../tb/tb_result_buffer.v',
        '../../tb/tb_h_calculator_control.v', '../../tb/tb_Bank_checker_faults.v'
    )
    foreach ($testName in @('fp16', 'bank_gemv', 'input_mode_mux', 'zero_bound', 'result_buffer', 'h_calculator_control', 'Bank_checker_faults', 'syndrome_checker')) {
        $snapshotName = $testName + '_regression'
        Invoke-VivadoTool -Tool xelab -ToolArgs @(('tb_' + $testName), '-s', $snapshotName)
        Invoke-VivadoTool -Tool xsim -ToolArgs @($snapshotName, '-runall') -PassPattern ('PASS: ' + $(if ($testName -eq 'fp16') { 'FP16' } else { $testName }))
    }
    Invoke-VivadoTool -Tool xelab -ToolArgs @('tb_Bank_checker', '-generic_top', '"NEAR_INF_THRESHOLD=20480"', '-s', 'checker_bound_regression')
    Invoke-VivadoTool -Tool xsim -ToolArgs @('checker_bound_regression', '-testplusarg', '"CASE_FILE=blocks_16_5000.txt"', '-runall') -PassPattern 'PASS: Bank_checker, 32 blocks, lanes=16'
    foreach ($laneCount in @(16, 3, 1)) {
        $snapshotName = 'checker_' + $laneCount + '_regression'
        # Literal quotes preserve '=' through Vivado's Windows batch wrappers.
        $genericArgument = '"NUM_LANES=' + $laneCount + '"'
        $fileArgument = '"CASE_FILE=blocks_' + $laneCount + '.txt"'
        Invoke-VivadoTool -Tool xelab -ToolArgs @('tb_Bank_checker', '-generic_top', $genericArgument, '-s', $snapshotName)
        Invoke-VivadoTool -Tool xsim -ToolArgs @($snapshotName, '-testplusarg', $fileArgument, '-runall') -PassPattern "PASS: Bank_checker, 32 blocks, lanes=$laneCount"
    }
    if ($Elaborate) {
        Invoke-VivadoTool -Tool vivado -ToolArgs @('-mode', 'batch', '-source', '../../scripts/check_rtl.tcl', '-log', 'rtl_elaboration.log', '-journal', 'rtl_elaboration.jou') -PassPattern 'PASS: Bank_checker Vivado RTL elaboration'
    }
    Write-Host 'PASS: all simulation regressions'
} finally {
    Pop-Location
}
