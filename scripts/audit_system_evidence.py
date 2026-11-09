"""Audit every completion and recovery path directly from the whole-system VCD."""
from collections import Counter, defaultdict
from pathlib import Path
import csv
import struct
from audit_module_evidence import ModuleAudit

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build/system'
PREFIX = BUILD / 'system_8_evidence'
DESCRIPTIONS = [
    '正常 qK', '正常 pV', 'Bank0 单点错误，直接修复', 'Bank1 单点错误，直接修复',
    'Bank2 多分量错误，Recovery 成功', 'Bank0 同号双分量错误，Recovery 成功',
    'Bank3 持久矩阵双输出错误，Recovery 失败并报告 DUE', 'Bank1 持久双校验向量错误，DUE',
    'Bank2 H 计算错误，Recovery 成功', '四个 Bank 同时单点错误，全部修复',
    'Bank0 R1 计算错误，直接修复', '混合：直接修复、Recovery 成功与 DUE',
    'Bank0 主计算及重算均有双分量错误，DUE', '正常 pV',
    '非对角矩阵，正常 qK', '非对角矩阵，正常 pV',
    '非对角矩阵，Bank2 单点注错因 FP16 残差不确定转 Recovery', '非对角矩阵，Bank3 多分量 Recovery 成功',
    '正常 pV', '四个 Bank 使用不同 p，正常 pV',
    '四个 Bank 全部 DUE，报告队列反压', '正常 pV',
    'FP16 顺序求和舍入检查，结果为 -1', '正常 pV',
    'Bank0 Y[3] 注入 NaN，置零/标记后 Recovery',
    'Bank0 Y[3] 注入 +Inf，置零/标记后 Recovery',
    'Bank0 Y[3] 注入 -Inf，置零/标记后 Recovery',
    'Bank0 Y[3] 达到 +65504 上界，置零/标记后 Recovery',
    'Bank0 Y[3] 达到 -65504 上界，置零/标记后 Recovery',
    'Bank0 pV 混合特殊值与上界内有限值，Recovery 成功',
    'Bank0 R1 注入 NaN，置零/标记后 Recovery',
    'Bank0 R1 注入 +Inf，置零/标记后 Recovery',
    'Bank0 R2 注入 -Inf，置零/标记后 Recovery',
    'Bank0 R2 达到上界，置零/标记后 Recovery',
    'Bank0 R1=65472，阈值内不置零，R1 直接修复',
    'Bank0 三组有限 H 连续不同，两次比较失败后 Recovery',
    'Bank0 第一组 H 错误，第二组不一致，第三组比较通过',
    'Bank0 H 连续不一致且 Recovery 再失败，DUE',
    'Bank0 Y 持续 +Inf，Recovery 后 mask 仍异常，DUE',
    '正常 pV',
    'Bank0 H 三取二 A/B/A，第三组匹配第一组提交',
    'Bank0 H 分量各有多数但整组无匹配，拒绝拼接后 Recovery',
    '正常 pV',
    'Bank0 R2 计算错误，直接修复', 'Bank0 R3 计算错误，直接修复',
    'Bank0 第二轮仅 H3 出错，第三轮实算后提交', '正常 pV；随后测试运行中复位和重载',
]


def decode(bits):
    return struct.unpack('>e', bits.to_bytes(2, 'big'))[0]


def lanes(value, count=64):
    return [(value >> (16 * i)) & 65535 for i in range(count)]


def read_cases():
    tokens = iter((BUILD / 'system_vectors.txt').read_text().split())
    count = int(next(tokens))
    cases = {}
    for _ in range(count):
        mode, block, corrected, recovered, due = [int(next(tokens), 16) for _ in range(5)]
        vector, banks, y, r, bad, bad_r = [int(next(tokens), 16) for _ in range(6)]
        injection = int(next(tokens), 16)
        checksums, matrix = [], []
        for bank in range(4):
            checksums.append([int(next(tokens), 16) for _ in range(3)])
            matrix.append([int(next(tokens), 16) for _ in range(16)])
        cases[block] = dict(mode=mode, corrected=corrected, recovered=recovered, due=due,
                            vector=vector, y=y, r=r, injection=injection,
                            checksums=checksums, matrix=matrix)
    assert count == len(DESCRIPTIONS)
    return cases


cases = read_cases()
names, values, previous = {}, {}, {}
time_ps = 0
completions, timeline = [], []
events = defaultdict(Counter)
start_times = defaultdict(list)
fault_seen = defaultdict(int)
accepted_types = {}
due_seen = defaultdict(int)
candidates = defaultdict(list)
output_hold_checks = 0
reset_times = []
module_audit = ModuleAudit()


def number(state, name):
    bits = state.get(name, 'x')
    assert not any(c in bits.lower() for c in 'xz'), (time_ps, name, bits)
    return int(bits, 2)


def event(time, block, bank, kind, detail=''):
    timeline.append([time / 1000, block, bank, kind, detail])
    events[block][kind] += 1


def inspect():
    global previous, output_hold_checks
    if not values:
        return
    if values.get('rst_n') == '0' and previous.get('rst_n') == '1':
        reset_times.append(time_ps)
    if values.get('result_valid') == '1':
        block = number(values, 'ev_result_block')
        expected = cases[block]
        assert number(values, 'block_id') == block
        for signal, key in [('ev_actual_y', 'y'), ('ev_reference_y', 'y'),
                            ('ev_actual_r', 'r'), ('ev_reference_r', 'r'),
                            ('corrected', 'corrected'), ('recovered', 'recovered'),
                            ('due_mask', 'due'), ('ev_input_vector', 'vector')]:
            assert number(values, signal) == expected[key], (time_ps, block, signal)
        assert number(values, 'ev_result_match') == 1, (time_ps, block, 'result_match')
        output_hold_checks += 1
        if previous.get('result_valid') != '1':
            completions.append((time_ps, block, dict(values)))
            event(time_ps, block, '', 'complete')
    # Protocol events are accepted at the rising edge using the pre-edge values.
    if (values.get('clk') == '1' and previous.get('clk') == '0'
            and previous.get('rst_n') == '1' and values.get('rst_n') == '1'):
        p = previous
        block = number(p, 'block_id')
        if p.get('start_valid') == p.get('start_ready') == '1':
            start_times[block].append(time_ps)
            event(time_ps, block, '', 'start')
        if block:
            fault_seen[block] |= number(p, 'ev_fault_mask')
            pending = number(p, 'ev_fault_mask') & number(p, 'ev_fault_ready')
            types = number(p, 'ev_fault_type')
            for bank in range(4):
                if pending & (1 << bank):
                    accepted_types[block, bank] = (types >> (3 * bank)) & 7
        for signal, src_name, kind in [
            ('ev_recovery_request', 'ev_recovery_src', 'recovery_request'),
            ('ev_recovery_done', 'ev_recovery_src', 'recovery_done')]:
            if p.get(signal) == '1':
                src = number(p, src_name)
                detail = ''
                if kind.endswith('done'):
                    good = number(p, 'ev_recovery_good')
                    detail = f'ABFT_good={good}'
                event(time_ps, src >> 8, src & 255, kind, detail)
        if p.get('ev_candidate_valid') == p.get('ev_candidate_ready') == '1':
            src = number(p, 'ev_candidate_src')
            fault_type = number(p, 'ev_candidate_type')
            bank = src & 255
            located = number(p, 'ev_candidate_located')
            assert fault_type == accepted_types[src >> 8, bank]
            candidates[src >> 8].append((bank, fault_type, located))
            event(time_ps, src >> 8, bank, 'candidate',
                  f'type={fault_type},located={located},pos={number(p, "ev_candidate_pos")}')
        if p.get('ev_patch_applied') == '1':
            event(time_ps, block, number(p, 'ev_patch_bank'),
                  'recovery_patch' if number(p, 'ev_patch_full') else 'single_patch')
        if p.get('due_valid') == p.get('due_ready') == '1':
            src = number(p, 'due_src')
            assert src >> 8 == block and (src & 255) < 4
            assert number(p, 'due_reason') == 1
            bit = 1 << (src & 255)
            assert not due_seen[block] & bit, (block, 'duplicate DUE')
            due_seen[block] |= bit
            event(time_ps, block, src & 255, 'DUE_accepted', 'reason=01')
    module_audit.observe(time_ps, values, previous)
    previous = dict(values)


for line in PREFIX.with_suffix('.vcd').read_text().splitlines():
    if line.startswith('$var '):
        parts = line.split()
        names[parts[3]] = parts[4]
    elif line.startswith('#'):
        inspect()
        time_ps = int(line[1:])
    elif line.startswith('b'):
        bits, identifier = line[1:].split()
        values[names[identifier]] = bits
    elif line and line[0] in '01xXzZ':
        values[names[line[1:]]] = line[0]
inspect()
assert len(completions) == len(cases) + 1, len(completions)
assert [block for _, block, _ in completions] == list(cases) + [max(cases)]
assert reset_times and time_ps >= completions[-1][0]
for block, case in cases.items():
    assert events[block]['single_patch'] == bin(case['corrected'] & ~case['recovered']).count('1'), (block, events[block])
    assert events[block]['recovery_patch'] == bin(case['recovered']).count('1'), (block, events[block])
    assert events[block]['recovery_request'] == bin(case['recovered'] | case['due']).count('1'), (block, events[block])
    assert due_seen[block] == case['due'], (block, due_seen[block], case['due'])
    assert fault_seen[block] & (case['corrected'] | case['due']) == case['corrected'] | case['due']
for block, expected in {3: (0, 1, 1), 5: (2, 5, 0), 6: (0, 5, 0),
                        11: (0, 2, 1), 44: (0, 3, 1), 45: (0, 4, 1)}.items():
    assert candidates[block] == [expected], (block, candidates[block])
module_audit.finish(ROOT, names)

with Path(str(PREFIX) + '_timeline.csv').open('w', newline='', encoding='utf-8-sig') as f:
    writer = csv.writer(f)
    writer.writerow(['time_ns', 'block_id_decimal', 'bank', 'event', 'detail'])
    writer.writerows(sorted(timeline, key=lambda row: row[0]))

rows, result_rows = [], []
for run, (done, block, state) in enumerate(completions, 1):
    case = cases[block]
    start = max(t for t in start_times[block] if t <= done)
    rows.append([run, block, f'{block:02x}', DESCRIPTIONS[block-1] if run <= len(cases) else '运行中复位后重载，正常完成',
                 start / 1000, done / 1000, f'{case["corrected"]:x}', f'{case["recovered"]:x}',
                 f'{case["due"]:x}', 'PASS'])
    actual = lanes(number(state, 'ev_actual_y'))
    for i, (expected, observed) in enumerate(zip(lanes(case['y']), actual)):
        result_rows.append([run, block, i // 16 if case['mode'] else 'reduced' if i < 16 else 'padding',
                            i % 16, f'[{i*16+15}:{i*16}]', decode(expected), f'{expected:04x}',
                            decode(observed), f'{observed:04x}', expected == observed])
with Path(str(PREFIX) + '_coverage.csv').open('w', newline='', encoding='utf-8-sig') as f:
    writer = csv.writer(f)
    writer.writerow(['run', 'block_id_decimal', 'block_id_hex', 'scenario', 'start_ns', 'complete_ns',
                     'corrected_hex', 'recovered_hex', 'due_hex', 'comparison'])
    writer.writerows(rows)
with Path(str(PREFIX) + '_results.csv').open('w', newline='', encoding='utf-8-sig') as f:
    writer = csv.writer(f)
    writer.writerow(['run', 'block_id_decimal', 'bank_or_reduction', 'index', 'bit_slice',
                     'expected_decimal', 'expected_fp16_hex', 'actual_decimal', 'actual_fp16_hex', 'match'])
    writer.writerows(result_rows)
with Path(str(PREFIX) + '_inputs.csv').open('w', newline='', encoding='utf-8-sig') as f:
    writer = csv.writer(f)
    writer.writerow(['block_id_decimal', 'bank', 'stored_row', *[f'col{i}' for i in range(16)],
                     'input_vector_at_row', 'Ce_at_row', 'Cw_at_row', 'C_inv_w_at_row'])
    for block, case in cases.items():
        vector = lanes(case['vector'])
        for bank in range(4):
            ce, cw, ci = [lanes(word, 16) for word in case['checksums'][bank]]
            for i, word in enumerate(case['matrix'][bank]):
                writer.writerow([block, bank, i, *map(decode, lanes(word, 16)),
                                 decode(vector[bank*16+i]), decode(ce[i]), decode(cw[i]), decode(ci[i])])

table = ['| blockID 十进制（十六进制） | 场景 | 启动→完成 ns | corrected / recovered / DUE |',
         '|---|---|---|---|']
for row in rows:
    _, block, hex_id, scenario, start, done, corrected, recovered, due, _ = row
    table.append(f'| {block}（{hex_id}） | {scenario} | {start:g}→{done:g} | {corrected} / {recovered} / {due} |')
guide = f'''# 完整系统波形：所有测试场景

只需打开 build/system/system_8_evidence.vcd；Vivado 原生文件为同名 .wdb/.wcfg。
记录从 0 ns 到 {time_ps / 1000:g} ns，覆盖 {len(cases)} 个测试事务、运行中复位及重载后的第 {len(completions)} 个完成包。
表中 mask 使用十六进制，1/2/4/8 对应 Bank0/1/2/3；波形 block_id 若使用十六进制，10 表示十进制 16。
所有完成包的完整 Y、R、输入向量和状态均从实际 VCD 逐位核对，{len(completions)}/{len(completions)} 通过；
共核对 {len(result_rows)} 个 FP16 输出槽位（包括 pV 的零填充），并检查 {output_hold_checks} 个有效输出时间点。
DUE 案例的参考输出按设计屏蔽失败 Bank，不表示恢复了失败 Bank 的原始正确值。
这些是有限测试覆盖，不是对全部可能输入与故障的形式证明。

{chr(10).join(table)}

## 用哪些信号区分路径

- 正常：result_valid=1 时，corrected=recovered=due_mask=0。
- 单点修复：ev_candidate_valid/ready 握手且 ev_candidate_located=1 后 ev_patch_applied=1，ev_patch_full=0；最终 corrected 对应位置 1、recovered 对应位 0。
- Recovery 成功：Bank 判为多错或不确定、输入非法，或 Locator 未找到可信位置时发出 ev_recovery_request/done；ev_recovery_good=1，之后 ev_patch_applied=1 且 ev_patch_full=1；最终 corrected/recovered 对应位置 1。
- 无法修复：ev_recovery_done 时 ev_recovery_good=0，之后 due_valid=1；due_src 给出来源，due_reason=01；due_mask 对应位置 1。due_ready=0 时报告等待接收，不代表报告丢失。
- ev_result_match 在最终结果有效且 Y/R/三个状态 mask 全部匹配参考时为 1；DUE 案例也必须匹配其规定的屏蔽输出。

## 新增的共用路径观察信号

| 信号 | 含义和读取时机 |
|---|---|
| ev_fault_mask[3:0] / ev_fault_ready[3:0] | 每个 Bank 故障记录的 valid/ready；上升沿对应位都为 1 时入队 |
| ev_candidate_src[15:0] | 定位结果来源，高 8 位 blockID、低 8 位 Bank；candidate_valid 与 candidate_ready 同为 1 时读取 |
| ev_candidate_located | 可直接提交补丁。单 Y 错的 pos 是 0 起算的下标；单 R 错由类型选通，无 Y 下标 |
| ev_fault_type[11:0] / ev_candidate_type[2:0] | Bank 分类与 BG 出队类型。0 正常、1 单 Y、2/3/4 单 R1/R2/R3、5 多错或不确定、6 非法输入 |
| ev_recovery_request | Recovery 重算请求握手事件 |
| ev_recovery_src[15:0] | Recovery 来源，高 8 位 blockID、低 8 位 Bank |
| ev_recovery_done | Recovery 重算响应握手事件 |
| ev_recovery_good | 重算响应的 ABFT 检查结果，仅在 recovery_done 时读取 |
| ev_recovery_y3 | Recovery 响应的第 4 项，FP16，仅在 recovery_done 时读取 |
| ev_patch_bank[1:0] | 应用修复的 Bank 编号，在 patch_applied 时读取 |
| ev_patch_full | 0=替换单个元素；1=Recovery 替换整个 Bank 向量；patch_applied 时读取 |
| ev_input_vector[1023:0] | 四个 Bank 锁存的 q/p，每个 Bank 占 256 bit |
| ev_actual_r / ev_reference_r | 实际/理论最终参考校验结果，各 192 bit。qK 每 Bank 48 bit，pV 归约值在低 48 bit。每组低到高是 R1、R2、R3 |
| ev_result_block | 最终输出包的 blockID，result_valid 时读取 |
| ev_inject_mask[3:0] | 哪些 Bank 当前 GEMV 返回值正被测试平台 force；被 force 的拍不一定每一项都被改变 |
| ev_injection_kind[15:0] | 每个 Bank 占 4 bit；0无注错，1单Y，2异号双Y，3同号双Y，4H非有限，5单R，6持续双Y；7特殊Y，8混合Y，9R1注错，aR2注错，b三组H不同，c首组H错，d持续H不同，e持续特殊Y，f仅第二组H错；矩阵/校验存储错误由加载数据注入 |
| due_valid / due_ready | DUE 报告握手；上升沿两者为 1 时接收 |
| due_src / due_reason | DUE 来源及原因；src 高 8 位 blockID、低 8 位 Bank；本设计 reason=01 表示 Recovery 检查失败 |
| load_valid / load_ready / load_bank / load_row / load_data | 实际矩阵行加载握手、Bank、行号及 16 个 FP16 数据 |
| checksum_valid / checksum_ready / checksum_bank / ce / cw / ci | 实际校验向量加载握手、Bank 和三组 16 项 FP16 向量 |

旧的 ev_clean_y3/ev_forced_y3/ev_captured_y3/ev_inject_pulse 仍专门保存 blockID=3、Bank0 的详细注错证据；
之后保持旧值，不代表其他案例没有注错。其余所有 Bank 使用 ev_inject_mask、来源编号、Recovery 和 DUE 信号观察。
ev_bank0_*、ev_k_row3、ev_q_bank0、ev_buffer_y3 只观察 Bank0。
ev_b0_delta1/2/3 是 Bank0 的实际残差。共享 ev_delta1/2 只在 ev_candidate_type=1 且候选握手时是两路定位残差。

## 数值对照文件

Zero-bound、Result Buffer、H Calculator/Control 的详细信号仅导出 Bank0，前缀分别为 ev_b0_zb_、ev_b0_buf_、ev_b0_h_。module_events.csv 记录 Bank0 的 H 各轮检查与缓冲封存事件。
新增加的特殊值/H 连续出错案例及实际采样时刻见 SPECIAL_VALUE_H_GUIDE.md。

- system_8_evidence_coverage.csv：全部场景的实际启动/完成时间及状态。
- system_8_evidence_timeline.csv：实际握手接受的候选、Recovery、修复与 DUE 事件。
- system_8_evidence_results.csv：{len(completions)} 个完成包每个输出槽位的理论/实际十进制与 FP16 编码。
- system_8_evidence_inputs.csv：{len(cases)} 个案例实际加载的完整矩阵、输入向量和 Ce/Cw/C_inv_w，包括故意加载的存储故障。
- WAVE_EVIDENCE.md：blockID=3 的矩阵、公式和详细手算例子。

重新生成与核对：

```powershell
.\\scripts\\run_system_simulation.ps1 -Evidence
```

脚本会在 Vivado 全系统仿真后自动审核 VCD 并更新上述表格。
'''
report_dir = ROOT / '资料'
report_dir.mkdir(exist_ok=True)
(report_dir / 'SYSTEM_WAVE_GUIDE.md').write_text(guide, encoding='utf-8')
print(f'PASS: complete VCD 0..{time_ps / 1000:g} ns; {len(completions)} packets, '
      f'{len(result_rows)} FP16 slots; normal/single/Recovery/DUE/reset verified')
