"""Audit every completion and recovery path directly from the whole-system VCD."""
from collections import Counter, defaultdict
from pathlib import Path
import csv
import struct
import xml.etree.ElementTree as ET
from audit_module_evidence import ModuleAudit
from wave_signals import DISPLAY_NAMES

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
    'Bank0 第二轮仅 H3 出错，第三轮实算后提交', '正常 pV',
    'Bank0 qK 首项单错', 'Bank0 qK 末项单错', 'Bank0 pV 末项负向单错',
    'Bank0 pV 首项负向单错', 'Bank0 异号双错，delta1 抵消为零',
    'Bank0 pV 同号双错', 'Bank0 R3 NaN', 'Bank0 R3 +Inf', 'Bank0 R3 near-INF',
    'Bank0 第一轮 H3 NaN，后两轮有效匹配', 'Bank0 前两轮同样错误，空转后分流 Recovery',
    '负向量 qK', '全零 pV', '相对阈值下方', '恰好等于相对阈值',
    '相对阈值上方，单 R1 修复', '三分量故障满足乘积关系，但非整数位置被 Locator 拒绝',
    '最小正非正规数输入', '正常 pV；随后测试运行中复位和重载',
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
                            vector=vector, bank_y=banks, y=y, r=r, injection=injection,
                            checksums=checksums, matrix=matrix)
    assert count == len(DESCRIPTIONS)
    return cases


cases = read_cases()
names, values, previous = {}, {}, {}
widths = {}
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
module_audits = [ModuleAudit(bank) for bank in range(4)]
accepted_deltas = {}
accepted_payloads = {}
fifo_accepted_sources = Counter()
syndrome_checks = Counter()
third_channel_cases = set()
syndrome_rows = []
main_facts = {}
candidate_facts = defaultdict(list)


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
        for bank in range(4):
            prefix = f'ev_b{bank}_'
            if p.get(prefix + 'packet_valid') == p.get(prefix + 'packet_ready') == '1':
                row = [time_ps / 1000, block, bank, number(p, prefix + 'service'),
                       number(p, prefix + 'delta_valid')]
                for channel in (1, 2, 3):
                    for suffix in (f'buf_r{channel}', f'h{channel}', f'delta{channel}'):
                        bits = number(p, prefix + suffix)
                        row.extend((f'{bits:04x}', decode(bits)))
                row.extend(number(p, prefix + suffix) for suffix in
                           ('mismatch', 'fault_type', 'good', 'clean_inputs', 'same_sign', 'product_match'))
                syndrome_rows.append(row)
                if not number(p, prefix + 'service'):
                    main_facts[block, bank] = {
                        'delta': tuple(number(p, prefix + f'delta{i}') for i in (1,2,3)),
                        'mismatch': number(p, prefix + 'mismatch'),
                        'type': number(p, prefix + 'fault_type'),
                        'relation_matches': number(p, prefix + 'product_match'),
                    }
        if p.get('start_valid') == p.get('start_ready') == '1':
            start_times[block].append(time_ps)
            event(time_ps, block, '', 'start')
        if block:
            fault_seen[block] |= number(p, 'ev_fault_mask')
            pending = number(p, 'ev_fault_mask') & number(p, 'ev_fault_ready')
            # Four producers share ONE arbiter/FIFO/Locator, accepting at most
            # one bank per edge. Record fields must preserve that bank's source.
            assert pending & (pending - 1) == 0, (time_ps, 'multiple BG enqueues')
            push = number(p, 'ev_fifo_push_valid') and number(p, 'ev_fifo_push_ready')
            pop = number(p, 'ev_fifo_valid') and number(p, 'ev_fifo_ready')
            assert bool(push) == bool(pending)
            assert number(values, 'ev_fault_count') == number(p, 'ev_fault_count') + push - pop
            types = number(p, 'ev_fault_type')
            for bank in range(4):
                if pending & (1 << bank):
                    src = (block << 8) | bank
                    payload = number(p, 'ev_b%d_fault_payload' % bank)
                    fault_type = (types >> (3 * bank)) & 7
                    assert number(p, 'ev_arbiter_bank') == bank
                    assert number(p, 'ev_fifo_push_record') == (src << 35) | (fault_type << 32) | payload
                    assert (number(p, 'ev_fault_src') >> (16 * bank)) & 65535 == src
                    assert (number(p, 'ev_fault_payload') >> (32 * bank)) & 0xffffffff == payload
                    accepted_payloads[block, bank] = payload
                    accepted_types[block, bank] = (types >> (3 * bank)) & 7
                    accepted_deltas[block, bank] = (
                        tuple(number(p, f'ev_b{bank}_delta{i}') for i in (1, 2, 3)),
                        number(p, f'ev_b{bank}_delta_valid'))
            if pop:
                record = number(p, 'ev_fifo_record')
                src, fault_type, payload = record >> 35, (record >> 32) & 7, record & 0xffffffff
                key = (src >> 8, src & 255)
                assert fault_type == accepted_types[key] and payload == accepted_payloads[key]
                fifo_accepted_sources[key] += 1
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
            expected_delta, trusted = accepted_deltas[src >> 8, bank]
            assert tuple(number(p, f'ev_delta{i}') for i in (1, 2, 3)) == expected_delta
            assert number(p, 'ev_delta_valid') == trusted
            payload = number(p, 'ev_candidate_payload')
            assert payload == accepted_payloads[src >> 8, bank]
            assert fifo_accepted_sources[src >> 8, bank] == 1
            if fault_type == 1:
                assert payload == expected_delta[0] | (expected_delta[1] << 16)
            if fault_type == 4:
                assert expected_delta[:2] == (0, 0) and expected_delta[2] != 0
                third_channel_cases.add(src >> 8)
            candidates[src >> 8].append((bank, fault_type, located))
            candidate_facts[src >> 8].append({
                'pos': number(p, 'ev_candidate_pos'), 'reason': number(p, 'ev_candidate_reason'),
                'value': number(p, 'ev_candidate_value'),
            })
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
    for audit in module_audits:
        audit.observe(time_ps, values, previous)
    if values.get('rst_n') == '1':
        for bank in range(4):
            prefix = f'ev_b{bank}_'
            if values.get(prefix + 'delta_valid') == '1':
                for channel in (1, 2, 3):
                    r = decode(number(values, prefix + f'buf_r{channel}'))
                    h = decode(number(values, prefix + f'h{channel}'))
                    try:
                        expected = int.from_bytes(struct.pack('>e', r - h), 'big')
                    except OverflowError:
                        expected = 0xfc00 if r < h else 0x7c00
                    actual = number(values, prefix + f'delta{channel}')
                    assert actual == expected, (time_ps, bank, channel, r, h, actual, expected)
                    assert (number(values, prefix + 'delta_nonfinite') >> (channel-1)) & 1 == ((actual >> 10) & 31 == 31)
                    syndrome_checks[bank, channel] += 1
    previous = dict(values)


for line in (BUILD / 'system_8_evidence_raw.vcd').read_text().splitlines():
    if line.startswith('$var '):
        parts = line.split()
        names[parts[3]] = parts[4]
        widths[parts[4]] = int(parts[2])
    elif line.startswith('#'):
        inspect()
        time_ps = int(line[1:])
    elif line.startswith('b'):
        bits, identifier = line[1:].split()
        values[names[identifier]] = bits
    elif line and line[0] in '01xXzZ':
        values[names[line[1:]]] = line[0]
inspect()
# A fresh VCD alone is insufficient: the saved Vivado view must expose the
# same signals, with three-bit masks and untruncated third-channel values.
wave_objects = ET.parse(PREFIX.with_suffix('.wcfg')).findall('.//wvobject')
wave_names = [obj.attrib['fp_name'].rsplit('/', 1)[-1] for obj in wave_objects
              if obj.attrib['type'] != 'group']
assert len(wave_names) == len(set(wave_names)) == len(DISPLAY_NAMES)
assert set(wave_names) == set(DISPLAY_NAMES)
assert set(DISPLAY_NAMES) <= set(widths)
for bank in range(4):
    for suffix in ('delta1', 'delta2', 'delta3', 'buf_r3', 'h3', 'h_candidate3', 'h_first3', 'h_previous3', 'final_r3'):
        assert widths[f'ev_b{bank}_{suffix}'] == 16
    for suffix in ('buf_r_mask', 'delta_nonfinite', 'mismatch'):
        assert widths[f'ev_b{bank}_{suffix}'] == 3
assert widths['ev_actual_r'] == widths['ev_reference_r'] == 192
assert widths['ev_delta3'] == 16
print(f'PASS: full VCD audited; grouped WCFG selects {len(DISPLAY_NAMES)} key signals; third-channel widths verified')
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
                        11: (0, 2, 1), 44: (0, 3, 1), 45: (0, 4, 1),
                        48: (0, 1, 1), 49: (0, 1, 1), 50: (0, 1, 1), 51: (0, 1, 1),
                        52: (0, 5, 0), 53: (0, 5, 0),
                        54: (0, 6, 0), 55: (0, 6, 0), 56: (0, 6, 0),
                        58: (0, 5, 0), 63: (0, 2, 1), 64: (0, 1, 0)}.items():
    assert candidates[block] == [expected], (block, candidates[block])
for block in (57,59,60,61,62,65):
    assert not candidates[block], (block, candidates[block])
for block,pos in ((48,0),(49,15),(50,15),(51,0)):
    fact=candidate_facts[block][0]
    expected_value=(cases[block]['bank_y'] >> (16*pos)) & 65535
    assert fact == dict(pos=pos,reason=0,value=expected_value), (block,fact)
assert main_facts[52,0]['delta'][0] == 0
for block, delta, mask in ((61, -0.0546875, 0), (62, -0.0625, 0), (63, -0.0703125, 1)):
    assert decode(main_facts[block,0]['delta'][0]) == delta
    assert main_facts[block,0]['mismatch'] == mask
assert main_facts[64,0]['relation_matches'] == 1
assert candidate_facts[64][0]['reason'] == 4
assert events[64]['single_patch'] == 0 and events[64]['recovery_patch'] == 1
assert third_channel_cases == {45}, third_channel_cases
assert sorted(candidates[10]) == [(bank, 1, 1) for bank in range(4)]
assert all(count == 1 for count in fifo_accepted_sources.values())
print(f'PASS: four banks share one BG; {len(fifo_accepted_sources)} fault records retain source/type/payload through arbitration and FIFO')
assert all(syndrome_checks[b, c] > 0 for b in range(4) for c in (1, 2, 3))
module_audits[0].finish(ROOT, names, module_audits[1:])
print(f'PASS: all four banks x three FP16 residuals, {sum(syndrome_checks.values())} samples; candidate snapshots and R3 repair verified')

# Each requirement links to completed transactions whose data, routing and
# handshake checks above must all pass. This records functional scenarios.
requirements = {
    'qK 正常拼接 / pV 正常求和': [1,2],
    '非对角矩阵与每 Bank 不同输入': [15,16,20],
    'Y 单错首项 / 末项': [48,49],
    'Y 单错负向误差与 pV 模式': [50,51],
    'R1 / R2 / R3 单错直接修复': [11,44,45],
    '同号双错 / 异号双错抵消 delta1': [6,52,53],
    'FP16 残差不确定后 Recovery': [17],
    'Y 的 NaN / 正负 Inf / near-INF': [25,26,27,28,29],
    '特殊值混合、上界内值与负零': [30,35],
    'R1 / R2 特殊值': [31,32,33,34],
    'R3 NaN / Inf / near-INF': [54,55,56],
    'H 前两轮匹配、第三轮空转': [1],
    'H 第三轮匹配第一轮': [41],
    'H 第三轮匹配第二轮': [37],
    'H 三组均不同': [36],
    'H 分量多数但整组无匹配': [42],
    '仅 H3 参与分歧': [46],
    'H3 非有限、后两轮匹配': [57],
    'H 前两轮同样错误后仍由 Syndrome 检出': [58],
    '相对阈值小于 / 等于 / 大于边界': [61,62,63],
    '满足乘积关系但位置不合法': [64],
    'Recovery 成功 / 失败转 DUE': [6,13],
    '持续矩阵 / 校验向量 / H / 特殊值故障': [7,8,38,39],
    '四 Bank 同时单错，共享 FIFO 保序': [10],
    '四 Bank 同时 DUE，报告反压': [21],
    'Reduce 前屏蔽 NaN / Inf': [12,21],
    '负输入 / 全零输入 / 最小正非正规数': [59,60,65],
    'FP16 顺序归约舍入': [23],
    '输出反压时完整结果保持': list(cases),
    'Recovery 中复位、重新配置并完成': [66],
}
completed_blocks = {block for _,block,_ in completions}
with Path(str(PREFIX) + '_requirements.csv').open('w', newline='', encoding='utf-8-sig') as stream:
    writer = csv.writer(stream)
    writer.writerow(['requirement', 'test_ids_decimal', 'result'])
    for requirement, blocks in requirements.items():
        assert set(blocks) <= completed_blocks
        writer.writerow([requirement, ' '.join(map(str,blocks)), 'PASS'])
print(f'PASS: {len(requirements)} required functional scenarios')

with Path(str(PREFIX) + '_syndromes.csv').open('w', newline='', encoding='utf-8-sig') as f:
    writer = csv.writer(f)
    header = ['time_ns', 'block_id_decimal', 'bank', 'service_0main_1recompute', 'delta_valid']
    for channel in (1, 2, 3):
        for signal in ('R', 'H', 'delta'):
            header.extend((f'{signal}{channel}_hex', f'{signal}{channel}_fp16'))
    writer.writerow(header + ['mismatch', 'fault_type', 'good', 'clean_inputs', 'same_sign', 'product_match'])
    writer.writerows(syndrome_rows)

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
ev_b0_delta1/2/3 是 Bank0 的实际残差；ev_b1_、ev_b2_、ev_b3_ 对应其他 Bank。
共享 ev_delta1/2/3 是故障入队时保存的三路实际残差，按 ev_candidate_src 选择；在 candidate_valid && ev_delta_valid 时读取。
ev_candidate_payload 是真实的 32-bit 队列载荷：单 Y 错为 {{delta2,delta1}}，单 R 错低 16 bit 为替换 H 值。delta3 在 Bank 分类时使用，不在当前 51-bit 队列记录中。
H 校验失败时 ev_delta_valid=0，三路残差不能解释为正常零残差。

## 数值对照文件

Zero-bound、Result Buffer、H Calculator/Control 和三路残差分类信号覆盖全部四个 Bank，前缀为 ev_b0_ 至 ev_b3_。module_events.csv 按 bank 列记录四个 Bank 的 H 各轮检查与缓冲封存事件。完整分组、位宽、有效窗口见 WAVE_SIGNALS.md。
新增加的特殊值/H 连续出错案例及实际采样时刻见 SPECIAL_VALUE_H_GUIDE.md。

- system_8_evidence_coverage.csv：全部场景的实际启动/完成时间及状态。
- system_8_evidence_timeline.csv：实际握手接受的候选、Recovery、修复与 DUE 事件。
- system_8_evidence_syndromes.csv：四个 Bank 每个主计算/Recovery 完整包的 R1/2/3、H1/2/3、delta1/2/3，含 FP16 编码、解码值、有效位与分类。
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
