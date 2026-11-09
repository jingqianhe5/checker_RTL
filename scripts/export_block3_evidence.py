"""Decode the actual block-3 stimulus and compare its captured final VCD packet."""
from pathlib import Path
import csv
import struct

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build' / 'system'


def lanes(word, count):
    value = int(word, 16)
    return [(value >> (16 * i)) & 65535 for i in range(count)]


def dec(value):
    return struct.unpack('>e', value.to_bytes(2, 'big'))[0]


def fmt(value):
    return f'{dec(value):g}'


tokens = iter((BUILD / 'system_vectors.txt').read_text().split())
cases = int(next(tokens))
for _ in range(cases):
    mode, block, corrected, recovered, due = [int(next(tokens), 16) for _ in range(5)]
    vector, banks, expected, refs, bad, bad_r = [next(tokens) for _ in range(6)]
    injection = next(tokens)
    tiles = []
    checksums = []
    for bank in range(4):
        checksums.append([lanes(next(tokens), 16) for _ in range(3)])
        tiles.append([lanes(next(tokens), 16) for _ in range(16)])
    if block == 3:
        break
else:
    raise RuntimeError('Block 3 missing')

# Read values from the simulator's VCD, rather than copying the expected packet.
names, values, captures, syndromes = {}, {}, [], []
time_ps = 0
lines = (BUILD / 'system_8_evidence.vcd').read_text().splitlines()


def capture():
    if values.get('block_id', '') in ('11', '00000011'):
        if values.get('ev_b0_delta_valid') == '1':
            syndromes.append(tuple(int(values[f'ev_b0_delta{i}'], 2) for i in (1, 2, 3)))
        if values.get('ev_result_match') == '1':
            captures.append((time_ps, dict(values)))


for line in lines:
    if line.startswith('$var '):
        fields = line.split()
        names[fields[3]] = fields[4]
    elif line.startswith('#'):
        capture()
        time_ps = int(line[1:])
    elif line.startswith('b'):
        bits, identifier = line[1:].split()
        values[names[identifier]] = bits
    elif line and line[0] in '01xXzZ':
        values[names[line[1:]]] = line[0]
capture()
if not captures:
    raise RuntimeError('No matching completed result in evidence VCD')
assert syndromes and set(syndromes) == {(0xc400, 0xcc00, 0xbc00)}, syndromes
completed_ps, observed = captures[0]
actual_word = int(observed['ev_actual_y'], 2)
assert actual_word == int(expected, 16)
assert int(observed['ev_reference_y'], 2) == int(expected, 16)
assert int(observed['corrected'], 2) == corrected == 1
assert int(observed['recovered'], 2) == recovered == 0
assert int(observed['due_mask'], 2) == due == 0
assert int(observed['ev_q_bank0'], 2) == int(vector, 16) & ((1 << 256) - 1)
assert int(observed['ev_k_row3'], 2) == sum(value << (16 * i) for i, value in enumerate(tiles[0][3]))
assert int(observed['ev_clean_y3'], 2) == 0x3800
assert int(observed['ev_forced_y3'], 2) == int(observed['ev_captured_y3'], 2) == 0x4480
inputs, theoretical = lanes(vector, 64), lanes(expected, 64)
actual = [(actual_word >> (16 * i)) & 65535 for i in range(64)]
for b in range(4):
    assert tiles[b] == [[int.from_bytes(struct.pack('>e', b + 1 if i == j else 0), 'big')
                         for j in range(16)] for i in range(16)]
    assert all(dec(theoretical[b * 16 + i]) == (b + 1) * (i + 1) / 8 for i in range(16))

with (BUILD / 'block3_inputs.csv').open('w', newline='', encoding='utf-8-sig') as f:
    writer = csv.writer(f)
    writer.writerow(['bank', 'row', *[f'K_col{j}' for j in range(16)],
                     'q_at_row', 'Ce_at_row', 'Cw_at_row', 'C_inv_w_at_row'])
    for b in range(4):
        for i in range(16):
            writer.writerow([b, i, *map(fmt, tiles[b][i]), fmt(inputs[b * 16 + i]),
                             fmt(checksums[b][0][i]), fmt(checksums[b][1][i]), fmt(checksums[b][2][i])])
with (BUILD / 'block3_outputs.csv').open('w', newline='', encoding='utf-8-sig') as f:
    writer = csv.writer(f)
    writer.writerow(['bank', 'index', 'bit_slice', 'expected_decimal', 'expected_fp16_hex',
                     'actual_decimal', 'actual_fp16_hex', 'match'])
    for b in range(4):
        for i in range(16):
            k = b * 16 + i
            writer.writerow([b, i, f'[{16*k+15}:{16*k}]', fmt(theoretical[k]),
                             f'{theoretical[k]:04x}', fmt(actual[k]), f'{actual[k]:04x}',
                             actual[k] == theoretical[k]])

table = ['| 下标 i | q[i] | Bank 0 | Bank 1 | Bank 2 | Bank 3 |',
         '|---:|---:|---:|---:|---:|---:|']
for i in range(16):
    table.append('| ' + ' | '.join([str(i), fmt(inputs[i]),
                 *[fmt(theoretical[b * 16 + i]) for b in range(4)]]) + ' |')

with (BUILD / 'system_8_evidence_events.csv').open(newline='') as f:
    event_ns = {row['event']: int(row['time_ps']) / 1000 for row in csv.DictReader(f)}

report = f'''# blockID=3：输入、理论运算与实际波形

本文件从本次仿真的 system_vectors.txt 读取实际加载的数据，并从
system_8_evidence.vcd 读取完成时的真实输出。64 个 FP16 结果逐位相等；
第一个匹配的完成包出现在 {completed_ps / 1000:g} ns。
这验证了本测试案例，不能代替对所有输入或硬件故障的证明。

## 1024 bit 如何分配

默认 N=16，每个 FP16 数占 16 bit。qK 模式拼接四个 Bank，
共 4×16×16=1024 bit，即 64 个 FP16 数，不是 1024 个数。

| 输出切片 | 内容 |
|---|---|
| result_y[255:0] | Bank 0，16 个结果 |
| result_y[511:256] | Bank 1，16 个结果 |
| result_y[767:512] | Bank 2，16 个结果 |
| result_y[1023:768] | Bank 3，16 个结果 |

Bank b 的第 i 项在 result_y[(b*16+i)*16 +: 16]。
例如 Bank 0 的 y[3] 在 [63:48]。波形十六进制字符串最右侧四位是 Bank 0 的 y[0]。
有效结果在 result_valid=1 时读取；接收发生在时钟上升沿 valid 与 ready 同时为 1 时。
pV 模式保留同一总线宽度，但四个 Bank 相加后只有低 256 bit 有效，高 768 bit 为零。

## 实际输入矩阵与 GEMV

这个案例 mode_tree=1，是 qK 模式。每个 Bank 都加载一个 16×16 矩阵：

K0=I16，K1=2I16，K2=3I16，K3=4I16。

即 Kb[i,j] 在 i=j 时为 b+1，其余全部为 0。
完整 64 行实际输入在 block3_inputs.csv，每行包含矩阵的 16 列、q、Ce、Cw 和 C_inv_w。
四个 Bank 的 q 相同：

q=[0.125,0.25,0.375,0.5,0.625,0.75,0.875,1,1.125,1.25,1.375,1.5,1.625,1.75,1.875,2]。

按 RTL 的存储方向，GEMV 计算 yb=Kb×q（q 看成列向量）：

yb[i]=sum(j=0..15, Kb[i,j]×q[j])=(b+1)×q[i]。

如果按 attention 的行向量记法写，则是 q×Kb^T。
每次乘法、加法都按 FP16 舍入，加法树两两规约。
本案例 Y 的乘积和加法都可精确表示，下面的实数理论值也就是 FP16 理论值。
例如 Bank 0 第 4 行乘 q：0×0.125+0×0.25+0×0.375+1×0.5+其余零项=0.5。

{chr(10).join(table)}

block3_outputs.csv 给出以上 64 项的实际 VCD 输出、理论值、FP16 十六进制编码和切片位置。
该案例使用对角矩阵，便于手算；其他系统测试还包含非对角矩阵和不同 Bank 的不同输入向量。

## 从正确计算到注错、定位、修复

位置权重 w[i]=i+1。外界加载 Ce[j]=sum(i,K[i,j])，
Cw[j]=sum(i,w[i]×K[i,j])，C_inv_w[j]=sum(i,K[i,j]/w[i])。Bank 0 的 Ce 全部为 1，Cw=[1,2,...,16]，C_inv_w=[1,1/2,...,1/16] 按 FP16 存放。
共享 GEMV 先算 R1=Ce·q=17，R2=Cw·q=187，R3=C_inv_w·q=2，再算 Y。
Zero-bound 检查非有限/near-INF 值，本案例的正常值与注错值都不会被置零。
Result Buffer 保存得到的 Y；同一个 GEMV 再算 H1=sum(Y)，H2=sum(w[i]×Y[i])，H3=sum(Y[i]/w[i])。
H 控制器按完整 (H1,H2,H3) 组做三取二。前两组一致且有限时，第三轮空转后再提交。
若前两组不一致，则计算第三组，匹配任一已有有限组时提交，三组无有效匹配则失败。

本案例只在 Bank 0 的 y[3] 返回时注入一次计算故障：0.5 改为 4.5。
不是修改输入 q 或矩阵，不是测试平台手动拉高 corrected。
于是 H1=21，H2=203，H3=3；参考 R 不受这次故障影响：

Δ1=R1−H1=17−21=−4；Δ2=R2−H2=187−203=−16，Δ3=R3−H3=2−3=−1。

Bank 检查 Δ2×Δ3=16 与 Δ1²=16，分类为单 Y 错。

定位的理论关系为 Δ2/Δ1=4，对应权重 4，即下标 3（第 4 项）。
RTL 用二分比较搜索位置，不用浮点除法器。
候选修正值=错误 Y[3]+Δ1=4.5−4=0.5。
共享 FIFO 将记录交给 Locator，位置权重校验通过后直接提交补丁。
多错、不确定和定位失败才会进入 Recovery，重算后仍未通过校验则报告 DUE。
这个案例 corrected=0001，recovered=0000，due_mask=0000。
最终 Reduce/Concat 按上述四个切片拼接输出。

| 时间 ns | 波形/事件 | 应观察到的值 |
|---:|---|---|
| {event_ns['start_q3']:g} | 启动握手，ev_q3 | 3800 = 0.5；K[3,3]=3c00 = 1 |
| {event_ns['force_value']:g} | ev_clean_y3 / ev_forced_y3，ev_inject_pulse | 3800 / 4480，即 0.5 / 4.5 |
| {event_ns['DUT_captured_faulty_Y3']:g} | ev_captured_y3，随后 ev_buffer_y3 | 4480，证明错误值确实进入 DUT |
| {event_ns['Delta1']:g} | 候选握手，ev_delta1 / ev_delta2 / ev_delta3 | c400 / cc00 / bc00，即 −4 / −16 / −1 |
| {event_ns['candidate_pos']:g} | ev_candidate_pos / ev_candidate_value | 0003 / 3800，即下标 3 / 0.5 |
| {event_ns['patch_applied']:g} | 采样 ev_patch_applied | 沿前为 1，事件 CSV 中该行的 0 是 Bank 编号 |
| {completed_ps / 1000:g} | result_valid，ev_final_y3，ev_result_match | 1，3800，1 |

时间来自实际事件日志 system_8_evidence_events.csv。
该日志最后一行是 TB 在 {event_ns['final_Y3']:g} ns 采样记录的值。波形中的 valid 拉高时间以 VCD 为准。
ev_b0_buf_r1/r2/r3 在主计算结束时应为 17/187/2，ev_b0_h1/h2/h3 应为 21/203/3。
FP16 十六进制需按 binary16 解码，不能直接切换为整数十进制后当成浮点数。

## 打开与重新运行

build/system/system_8_evidence.vcd 从 0 ns 记录到仿真结束，包含全部 {cases} 个案例、运行中复位和重载。
时钟初值为 0，5 ns 首次翻转，周期为 10 ns，全程持续运行。
观察 blockID=3 的修复过程时，可放大 {event_ns['start_q3']:g}–{event_ns['final_Y3']:g} ns；
ev_actual_y 是实际全部输出，ev_reference_y 是独立参考输出。
ev_result_match 只有完成包有效且 Y、R、三个状态 mask 全部逐位匹配时才为 1。
输入矩阵加载早于启动，ev_k_row3 直接观察 Bank 0 内实际存储的第 4 行；
ev_q_bank0 是锁存后的完整输入向量，不是理论常量。

重新生成：

```powershell
.\\scripts\\run_system_simulation.ps1 -Evidence
python .\\scripts\\export_block3_evidence.py
```

仿真使用 Vivado 2020.2 的 xvlog/xelab/xsim；本次完整执行 {cases} 个事务和复位重载，全部通过。
完整场景的时间索引和 Recovery/DUE 观察说明见 SYSTEM_WAVE_GUIDE.md。
'''
report_dir = ROOT / '资料'
report_dir.mkdir(exist_ok=True)
(report_dir / 'WAVE_EVIDENCE.md').write_text(report, encoding='utf-8')
print(f'PASS: block 3 captured inputs/fault and actual VCD vs oracle: 64/64 FP16 values, complete at {completed_ps / 1000:g} ns')
