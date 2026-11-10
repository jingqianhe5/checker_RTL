"""Observe H rounds and buffer seals in the captured per-bank module signals."""
from collections import Counter
import csv
from pathlib import Path
import re

SPECIALS = {
    25:{0x7e00},26:{0x7c00},27:{0xfc00},28:{0x7bff},29:{0xfbff},
    30:{0x7e00,0x7c00,0xfc00,0x7bff,0xfbff,0x7bfe,0xfbfe,0x8000,0xc000},
    31:{0x7e00},32:{0x7c00},33:{0xfc00},34:{0x7bff},35:{0x7bfe},39:{0x7c00},54:{0x7e00},55:{0x7c00},56:{0x7bff},
}
REJECTED = {0x7e00,0x7c00,0xfc00,0x7bff,0xfbff}


class ModuleAudit:
    def __init__(self, bank=0):
        self.bank = bank
        self.sessions = {}
        self.h_start_times = {}
        self.h_captures = []
        self.events = []
        self.counts = Counter()
        self.special_seen = {}
        self.special_rows = []
        self.outcomes = {}
        self.mismatches = Counter()

    @staticmethod
    def number(state, name):
        value = state[name]
        assert not any(c in value.lower() for c in 'xz'), (name, value)
        return int(value, 2)

    def observe(self, time_ps, current, previous):
        if current.get('rst_n') != '1':
            self.sessions.clear()
            return
        for suffix in ('match','match_first','match_previous'):
            if current.get(f'ev_b{self.bank}_h_'+suffix) == '1':
                assert current.get(f'ev_b{self.bank}_h_sample_valid') == current.get(f'ev_b{self.bank}_h_sample_ready') == '1', (time_ps, suffix, 'outside sample window')
        rising = current.get('clk') == '1' and previous.get('clk') == '0'
        if not rising or previous.get('rst_n') != '1':
            return
        for bank in (self.bank,):
            prefix = f'ev_b{bank}_'
            old = lambda suffix: self.number(previous, prefix + suffix)
            new = lambda suffix: self.number(current, prefix + suffix)
            block = self.number(previous, 'ev_result_block')
            service = old('service')

            def log(kind, details):
                self.events.append([time_ps / 1000, block, bank, service, kind, details])
                self.counts[kind] += 1

            if bank == 0 and old('zb_capture') and block in SPECIALS:
                raw, clean, mask = old('zb_raw'), old('zb_clean'), old('zb_mask')
                for lane in range(16):
                    value = raw >> (16*lane) & 65535
                    if value in SPECIALS[block]:
                        rejected = value in REJECTED
                        assert (mask >> lane & 1) == rejected, (time_ps, block, value, mask)
                        observed = clean >> (16*lane) & 65535
                        assert observed == (0 if rejected else value), (time_ps, block, value, observed)
                        self.special_seen.setdefault(block, set()).add(value)
                        self.special_rows.append([time_ps/1000,block,service,old('phase'),lane,
                                                  f'{value:04x}',int(rejected),f'{observed:04x}'])
            if old('buf_seal'):
                if bank == 0 and not service:
                    expected_y_mask = 0x1f if block == 30 else 8 if block in (25,26,27,28,29,39) else 0
                    expected_r_mask = 1 if block in (31,32) else 2 if block in (33,34) else 4 if block in (54,55,56) else 0
                    assert old('buf_y_mask') == expected_y_mask, (time_ps, block, 'saved Y mask')
                    assert old('buf_r_mask') == expected_r_mask, (time_ps, block, 'saved R mask')
                    if block in (25,26,27,28,29,39):
                        assert old('buf_y') >> 48 & 65535 == 0
                    if block in (31,32): assert old('buf_r1') == 0
                    if block in (33,34): assert old('buf_r2') == 0
                    if block == 35: assert old('buf_r1') == 0x7bfe
                log('buffer_seal', f'Y3={old("buf_y") >> 48 & 65535:04x},'
                    f'R1={old("buf_r1"):04x},R2={old("buf_r2"):04x},R3={old("buf_r3"):04x},'
                    f'Y_mask={old("buf_y_mask"):04x},R_mask={old("buf_r_mask"):x}')
            if old('h_start_valid') and old('h_start_ready'):
                self.sessions[bank] = []
                self.h_start_times[bank] = time_ps
                self.h_captures = []
                log('H_start', '')
            for channel in ('h_capture_h1', 'h_capture_h2', 'h_capture_h3'):
                if old(channel):
                    assert not old('h_skip_round'), (time_ps, block, 'capture during idle slot')
                    self.h_captures.append(channel)
            if old('h_sample_valid') and old('h_sample_ready'):
                assert bank in self.sessions, (time_ps, bank, 'sample without start')
                samples = self.sessions[bank]
                round_number = new('h_attempts')
                assert old('h_attempts') == len(samples) and round_number == len(samples) + 1
                assert time_ps - self.h_start_times[bank] == 110_000 * round_number
                agreed = len(samples) == 2 and samples[0] == samples[1] and samples[0][1]
                assert bool(old('h_skip_round')) == agreed
                if agreed:
                    assert not self.h_captures and not old('h_match')
                    log('H_skip', 'round=3,no GEMV capture')
                else:
                    assert self.h_captures == ['h_capture_h1', 'h_capture_h2', 'h_capture_h3']
                    pair = (old('h_candidate1'), old('h_candidate2'), old('h_candidate3'))
                    finite = all((value >> 10) & 31 != 31 for value in pair)
                    assert old('h_sample_finite') == finite
                    expected_vote = finite and any(valid and prior == pair for prior, valid in samples)
                    assert bool(old('h_match')) == expected_vote, (time_ps, block, 'two-of-three vote')
                    if samples and not old('h_match'):
                        self.mismatches[block,service] += 1
                        log('H_mismatch', f'comparison={len(samples)},finite={int(finite)}')
                    samples.append((pair, finite))
                    log('H_sample', f'round={round_number},H1={pair[0]:04x},H2={pair[1]:04x},H3={pair[2]:04x},'
                        f'finite={int(finite)},match={old("h_match")},'
                        f'match_first={old("h_match_first")},match_previous={old("h_match_previous")}')
                self.h_captures = []
            if new('h_attempts') < 3:
                assert not new('h_commit') and not new('h_fail') and not new('h_done_valid')
            if new('packet_valid') and not old('packet_valid'):
                assert new('h_attempts') == 3 and time_ps - self.h_start_times[bank] == 340_000
            if new('h_commit') and not old('h_commit'):
                samples = self.sessions[bank]
                assert new('h_attempts') == 3 and time_ps - self.h_start_times[bank] == 330_000
                assert 2 <= len(samples) <= 3
                assert samples[-1][1] and any(valid and pair == samples[-1][0] for pair, valid in samples[:-1])
                assert (new('h1'), new('h2'), new('h3')) == samples[-1][0]
                self.outcomes[block,service] = ('commit', list(samples))
                log('H_commit', f'rounds=3,computed={len(samples)},H1={new("h1"):04x},H2={new("h2"):04x},H3={new("h3"):04x}')
            if new('h_fail') and not old('h_fail'):
                samples = self.sessions[bank]
                assert len(samples) == 3 and new('h_attempts') == 3 and time_ps - self.h_start_times[bank] == 330_000
                assert not any(a[1] and b[1] and a[0] == b[0]
                               for i, a in enumerate(samples) for b in samples[i+1:])
                assert not new('h_valid') and not new('delta_valid')
                self.outcomes[block,service] = ('fail', list(samples))
                log('H_fail', 'rounds=3')
            if new('h_valid'):
                assert new('h_commit') and not new('h_fail') and new('packet_valid')
                assert new('delta_valid')

    def finish(self, root, names, other_banks=()):
        source = (root / 'scripts/waves_evidence.tcl').read_text(encoding='utf-8')
        suffixes = re.search(r'set module_signals \{([^}]+)\}', source).group(1).split()
        required = {f'ev_b{bank}_{suffix}' for bank in range(4) for suffix in suffixes}
        assert required <= set(names.values()), required - set(names.values())
        for audit in other_banks:
            assert audit.counts['H_commit'] > 0 and audit.counts['buffer_seal'] > 0, audit.bank
        all_events = sorted(self.events + [row for audit in other_banks for row in audit.events], key=lambda row: (row[0], row[2]))
        assert self.counts['H_commit'] > 0
        assert self.counts['H_skip'] > 0
        assert any(row[1:5] == [3, 0, 0, 'H_commit'] for row in self.events)
        assert not any(row[1:5] == [3, 0, 1, 'H_commit'] for row in self.events)
        for block, values in SPECIALS.items():
            assert values <= self.special_seen.get(block, set()), (block, 'missing captured special values')
        different = [((0x4c80,0x59e0,0x4000),True),((0x4cc0,0x59e8,0x4000),True),((0x4d00,0x59f0,0x4000),True)]
        for key in ((36,0),(38,0),(38,1)):
            assert self.outcomes[key] == ('fail',different), (key,self.outcomes.get(key))
            assert self.mismatches[key] == 2
        assert self.outcomes[37,0] == ('commit', [different[0],((0x4c40,0x59d8,0x4000),True),((0x4c40,0x59d8,0x4000),True)])
        assert self.mismatches[37,0] == 1
        normal = ((0x4c40,0x59d8,0x4000),True)
        assert self.outcomes[41,0] == ('commit',[normal,different[0],normal])
        assert self.mismatches[41,0] == 1
        mixed_pairs = [((0x4c40,0x59e0,0x4000),True),((0x4c80,0x59d8,0x4000),True),normal]
        assert self.outcomes[42,0] == ('fail',mixed_pairs)
        assert self.mismatches[42,0] == 2
        assert self.outcomes[46,0] == ('commit', [normal, ((0x4c40,0x59d8,0x4200),True), normal])
        assert self.mismatches[46,0] == 1
        assert self.outcomes[57,0] == ('commit', [((0x4c40,0x59d8,0x7e00),False), normal, normal])
        assert self.outcomes[58,0] == ('commit', [different[0],different[0]])
        assert self.counts['H_skip'] > 0
        with (root/'build/system/system_8_evidence_special_values.csv').open('w',newline='',encoding='utf-8-sig') as stream:
            writer=csv.writer(stream)
            writer.writerow(['time_ns','block_id_decimal','service','phase_0R1_1R2_2Y','raw_lane','raw_fp16_hex','mask','clean_fp16_hex'])
            writer.writerows(self.special_rows)
        special_table = ['| blockID 十进制（十六进制） | 时间 ns | service | 阶段 | 原始项 hex | mask | 清理后 hex |',
                         '|---|---:|---:|---|---|---:|---|']
        for time,block,service,phase,lane,raw,mask,clean in self.special_rows:
            special_table.append(f'| {block}（{block:02x}） | {time:g} | {service} | { {0:"R1",1:"R2",2:"Y",5:"R3"}[phase]} | {raw} | {mask} | {clean} |')
        h_table = ['| blockID 十进制（十六进制） | 时间 ns | service | 事件 | 实际记录 |',
                   '|---|---:|---:|---|---|']
        for time,block,bank,service,kind,details in self.events:
            if block in (1,36,37,38,41,42,46) and kind in ('H_sample','H_skip','H_mismatch','H_commit','H_fail'):
                h_table.append(f'| {block}（{block:02x}） | {time:g} | {service} | {kind} | {details} |')
        report = '''# Bank0 特殊值与 H 连续出错的波形证据

仍打开同一个 build/system/system_8_evidence.vcd，四 Bank 系统仍完整仿真，详细模块信号仅展示 Bank0，四个 Bank 的结果均参与自动审计。
以下时间全部从这次 VCD 的真实采样值提取，未强制设置 mask、h_match、h_fail、h_commit 或最终修复状态。
service=0 是主计算，1 是 Recovery；各案例时间范围与最终状态见 SYSTEM_WAVE_GUIDE.md。

## 特殊值

观察 ev_b0_zb_raw、zb_mask、zb_clean、zb_capture；在 capture=1 的上升沿采样。
7e00=NaN，7c00=+Inf，fc00=-Inf，7bff=65504，fbff=-65504。
这些值被置为正零，mask=1。7bfe=65472、fbfe=-65472 处于默认上界内，保持原值且 mask=0。
8000=-0，c000=-2，均正常保留。只有有限且绝对值小于上界的值通过。

qK 模式返回标量放在原始总线最低一项，所以 Y[3] 的特殊值先使 zb_mask[0]=1；
写入缓冲时按 buf_index=3 保存到 buf_y_mask[3]。pV 一次返回整个向量，mask 按元素位置对应。
case30 混合向量清理后 buf_y_mask=001f，前五项置零，阈值内两项和 -0/-2 保留。
case31/32 的 buf_r_mask=1，case33/34 为 2；case35 的 R1=65472 保留且 mask=0，
但这个 R1 与真实校验不符，会由单校验错分支修复。通过特殊值检查仅代表该值处于有效范围。

''' + '\n'.join(special_table) + '''

## H 三取二校验

控制器固定走满三个 110 ns 时隙。前两组完整 (H1,H2,H3) 有限且一致时，第三轮保留同样的时序但不发起 GEMV，结束后才提交第一组。
前两组不一致则实际计算第三组，同时比较第一组和第二组，任意两组有限且逐位相同就采用该组。
三个校验量整组表决。任一分量为 NaN 或 Inf 时该组无效。
case36（三组 18/188、19/189、20/190）两次比较均不一致，h_attempts=3、h_fail=1；之后 Recovery 恢复为 17/187。
case37（三组 18/188、17/187、17/187）第二组不一致，第三组比较通过，h_commit=1，不进入 Recovery。
case38 与 case36 的主计算相同，但 Recovery 也注入三组不同 H，最终 due_mask=1，并发出 Bank0 DUE。
case39 则持续向 Y[3] 注入 +Inf，Recovery 后 mask 仍异常，最终 DUE。
case41 为 A/B/A：17/187、18/188、17/187；第三组匹配第一组，提交 17/187，无需 Recovery。
case42 为 17/188、18/187、17/187；虽然各分量单独有多数，但没有完整组匹配，必须失败后 Recovery。

case46 只扰动第二轮 H3，第一轮和第三轮整组匹配，验证第三路也参与投票。

观察 ev_b0_h_candidate1/2/3、h_first1/2/3、h_previous1/2/3、h_match_first、h_match_previous、h_sample_valid/ready、h_sample_finite、h_match、h_attempts、h_commit、h_fail、h_valid。
在 sample_valid && sample_ready 的上升沿前读比较输入。ev_b0_h_skip_round 为 1 时，该握手只结束空轮，未接收新的候选值。attempts 统计已完成的时隙，commit/fail 在第三个时隙结束时更新。
波形中的 h_match、h_match_first、h_match_previous 已限定在 sample_valid && sample_ready 窗口内，其余时刻输出 0；没有修改 RTL 内部比较电路。
第一组的 match=0 只是没有上一组，不能计为一次比较失败。
本次有限 H 故障候选的 sample_finite 全为 1，失败来自不一致，不是 NaN/Inf。
4c80/59e0=18/188，4cc0/59e8=19/189，4d00/59f0=20/190，4c40/59d8=17/187。

''' + '\n'.join(h_table) + '\n'
        report_dir = root / '资料'
        report_dir.mkdir(exist_ok=True)
        (report_dir / 'SPECIAL_VALUE_H_GUIDE.md').write_text(report, encoding='utf-8')
        path = root / 'build/system/system_8_evidence_module_events.csv'
        with path.open('w', newline='', encoding='utf-8-sig') as stream:
            writer = csv.writer(stream)
            writer.writerow(['time_ns', 'block_id_decimal', 'bank', 'service_0main_1recompute', 'event', 'details'])
            writer.writerows(all_events)
        print(f'PASS: {len(required)} module observer signals, '
              f'{self.counts["H_sample"]} H samples, {self.counts["H_skip"]} idle rounds, {self.counts["H_commit"]} commits, '
              f'{self.counts["H_fail"]} failures in Bank 0; all four banks audited')
