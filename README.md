# Checker 仿真工程

本工程包含 Checker 和 Corrector 的 Verilog RTL、测试平台，以及用 Vivado XSim 运行仿真和生成波形的脚本。系统级 RTL 顶层是 `sys_top`，对应的测试平台是 `tb_sys_top`。

## 目录说明

| 目录 | 用途 |
| --- | --- |
| [`rtl/`](rtl/) | 硬件设计源码，包括系统顶层 `sys_top.v`、`Bank_checker.v`、`BG_corrector.v` 和 FP16 运算等子模块。 |
| [`tb/`](tb/) | 系统级和模块级测试平台。Testbench 提供时钟、复位和测试激励，并检查仿真结果。系统波形由 [`tb_sys_top.v`](tb/tb_sys_top.v) 的仿真生成。 |
| [`scripts/`](scripts/) | PowerShell 脚本启动仿真，Python 脚本生成测试向量并核对结果，Tcl 脚本选择要记录的信号或执行 RTL 展开检查。 |
| [`build/`](build/) | 仿真输出目录。仓库保留 `build/system/` 中的系统级波形和显示配置。测试向量、日志和编译产物在本地运行时生成。 |


## 在 Windows 上开始仿真

准备 Windows PowerShell、Vivado 2020.2（含 XSim）和 Python 3.9。确认在终端执行 `python --version` 能找到 Python。

在工程根目录打开 PowerShell，把 `$vivadoBin` 改成你电脑上包含 `xvlog.bat`、`xelab.bat` 和 `xsim.bat` 的 Vivado `bin` 路径，然后运行系统级仿真。

```powershell
$vivadoBin = 'C:\software\vivado\Vivado\2020.2\bin'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_system_simulation.ps1 -VivadoBin $vivadoBin
```

脚本会生成测试向量、编译 RTL 和 testbench、运行 XSim，再核对波形中的结果。看到 `PASS: all whole-system simulations` 表示整套系统仿真通过。重新运行会更新 `build/system/` 中的同名波形文件。

如果只需要运行模块级回归，在同一个终端执行对应命令。

```powershell
# Bank Checker 及相关模块
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_simulations.ps1 -VivadoBin $vivadoBin

# BG Corrector 及故障定位模块
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_bg_simulations.ps1 -VivadoBin $vivadoBin
```

## 最新系统波形

仓库里最新的一组是 `system_8_evidence`，对应 `FIFO_DEPTH=8` 的系统仿真，包含正常运行、故障修复、Recovery、DUE 和复位重载场景。

最新波形按**三个校验值、四个 Bank 共享一个 BG**组织，保留 119 个关键信号，分成 10 组。详细内部过程展示 Bank0，共享 BG、Recovery 和 DUE 通过来源编号区分四个 Bank。全系统测试包含 66 个事务和复位重载后的一个完成包。

优先结合 `b0_delta_valid` 读取 `b0_delta1_fp16`、`b0_delta2_fp16`、`b0_delta3_fp16`，并在 `b0_packet_accepted` 时查看 `b0_fault_type`。逐步流程、全部信号含义、有效时机、三取二规则、阈值公式与案例时间见 [`WAVE_SIGNALS.md`](WAVE_SIGNALS.md)。仿真还生成 `build/system/system_8_evidence_syndromes.csv`，按包列出四 Bank 的三路 R/H/delta 及 FP16 解码值。

| 文件 | 如何使用 |
| --- | --- |
| [`system_8_evidence.vcd`](build/system/system_8_evidence.vcd) | 通用波形文件，用支持 VCD 的波形查看器打开。 |
| [`system_8_evidence.wdb`](build/system/system_8_evidence.wdb) | Vivado XSim 的原生波形数据库。 |
| [`system_8_evidence.wcfg`](build/system/system_8_evidence.wcfg) | Vivado 的波形显示配置，搭配同名 `.wdb` 使用。 |
