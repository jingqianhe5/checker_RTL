"""The review waveform. Full internal traces are used only for simulation audits."""
from pathlib import Path
import argparse
import csv
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build/system"
PREFIX = BUILD / "system_8_evidence"

# Each row is (existing testbench probe, displayed name). Preserve this order.
GROUPS = {
    "01_System": [
        ("clk", "clk"), ("rst_n", "rst_n"), ("wave_case", "test_id"),
        ("mode_tree", "mode_qk"), ("start_valid", "start_valid"),
        ("start_ready", "start_ready"), ("result_valid", "result_valid"),
        ("result_ready", "result_ready"), ("corrected", "corrected_mask"),
        ("recovered", "recovered_mask"), ("due_mask", "due_mask"),
        ("ev_result_match", "result_matches_reference"),
    ],
    "02_Inputs": [
        ("load_valid", "matrix_load_valid"), ("load_ready", "matrix_load_ready"),
        ("load_bank", "matrix_load_bank"), ("load_row", "matrix_load_row"),
        ("load_data", "matrix_load_row_fp16x16"),
        ("checksum_valid", "checksum_load_valid"), ("checksum_ready", "checksum_load_ready"),
        ("checksum_bank", "checksum_load_bank"), ("ce", "checksum_e_fp16x16"),
        ("cw", "checksum_w_fp16x16"), ("ci", "checksum_inv_w_fp16x16"),
        ("ev_q_bank0", "b0_x_fp16x16"), ("wave_watch_index", "b0_watch_index"),
        ("wave_input_x", "b0_x_watch_fp16"), ("wave_load_element", "matrix_load_watch_fp16"),
    ],
    "03_Bank0_GEMV": [
        ("ev_b0_phase", "b0_gemv_phase"), ("ev_b0_service", "b0_is_recovery"),
        ("ev_b0_core_mode_tree", "b0_gemv_tree_mode"),
        ("ev_b0_core_valid", "b0_gemv_valid"), ("ev_b0_core_ready", "b0_gemv_ready"),
        ("ev_b0_read_row", "b0_matrix_read_row"), ("wave_bank0_inject", "b0_fault_injection_active"),
        ("wave_fault_value", "b0_injected_value_fp16x16"),
    ],
    "04_Bank0_ZeroBound": [
        ("ev_b0_zb_capture", "b0_zb_capture"),
        ("ev_b0_zb_raw", "b0_zb_input_fp16x16"),
        ("ev_b0_zb_clean", "b0_zb_output_fp16x16"),
        ("ev_b0_zb_mask", "b0_zb_special_mask"),
        ("wave_zb_raw", "b0_zb_lane0_input_fp16"),
        ("wave_zb_clean", "b0_zb_lane0_output_fp16"),
    ],
    "05_Bank0_ResultBuffer": [
        ("ev_b0_buf_write_y", "b0_buffer_write_y"),
        ("ev_b0_buf_index", "b0_buffer_write_index"),
        ("ev_b0_buf_seal", "b0_buffer_seal"),
        ("ev_b0_buf_valid", "b0_buffer_valid"),
        ("ev_b0_buf_y", "b0_buffer_y_fp16x16"),
        ("wave_buffer_y", "b0_buffer_y_watch_fp16"),
        ("ev_b0_buf_y_mask", "b0_buffer_y_special_mask"),
        ("ev_b0_buf_r_mask", "b0_buffer_r_special_mask"),
        ("ev_b0_buf_r1", "b0_r1_fp16"), ("ev_b0_buf_r2", "b0_r2_fp16"),
        ("ev_b0_buf_r3", "b0_r3_fp16"),
    ],
    "06_Bank0_H_Vote": [
        ("ev_b0_h_start_valid", "b0_h_start"),
        ("wave_h_sample", "b0_h_slot_done"),
        ("ev_b0_h_attempts", "b0_h_completed_slots"),
        ("ev_b0_h_skip_round", "b0_h_idle_slot"),
        ("ev_b0_h_capture_h3", "b0_h_capture_third_channel"),
        ("ev_b0_h_candidate1", "b0_h_current1_fp16"),
        ("ev_b0_h_candidate2", "b0_h_current2_fp16"),
        ("ev_b0_h_candidate3", "b0_h_current3_fp16"),
        ("ev_b0_h_first1", "b0_h_first1_fp16"),
        ("ev_b0_h_first2", "b0_h_first2_fp16"),
        ("ev_b0_h_first3", "b0_h_first3_fp16"),
        ("ev_b0_h_previous1", "b0_h_previous1_fp16"),
        ("ev_b0_h_previous2", "b0_h_previous2_fp16"),
        ("ev_b0_h_previous3", "b0_h_previous3_fp16"),
        ("ev_b0_h_sample_finite", "b0_h_current_finite"),
        ("ev_b0_h_match_first", "b0_h_matches_first"),
        ("ev_b0_h_match_previous", "b0_h_matches_previous"),
        ("ev_b0_h_commit", "b0_h_commit"), ("ev_b0_h_fail", "b0_h_fail"),
    ],
    "07_Bank0_Syndrome": [
        ("wave_bank_result", "b0_packet_accepted"),
        ("ev_b0_h1", "b0_h1_fp16"), ("ev_b0_h2", "b0_h2_fp16"),
        ("ev_b0_h3", "b0_h3_fp16"),
        ("ev_b0_delta_valid", "b0_delta_valid"),
        ("ev_b0_delta1", "b0_delta1_fp16"), ("ev_b0_delta2", "b0_delta2_fp16"),
        ("ev_b0_delta3", "b0_delta3_fp16"),
        ("ev_b0_mismatch", "b0_mismatch_mask"),
        ("ev_b0_product_match", "b0_single_error_relation_matches"),
        ("ev_b0_fault_type", "b0_fault_type"),
        ("wave_fault_enqueue", "b0_fault_enqueued"),
    ],
    "08_Shared_BG_Locator": [
        ("ev_fault_mask", "bank_fault_valid_mask"),
        ("ev_fault_count", "bg_fifo_count"),
        ("wave_fifo_push", "bg_fifo_push"), ("wave_fifo_pop", "bg_fifo_pop"),
        ("ev_locator_low", "bg_search_low_weight"),
        ("ev_locator_high", "bg_search_high_weight"),
        ("wave_bg_dequeue", "bg_candidate_accepted"),
        ("ev_candidate_src", "bg_candidate_src"),
        ("wave_bg_bank", "bg_candidate_bank"),
        ("ev_candidate_type", "bg_fault_type"),
        ("ev_candidate_located", "bg_patch_possible"),
        ("ev_candidate_reason", "bg_locator_reason"),
        ("ev_candidate_steps", "bg_search_steps"),
        ("ev_candidate_pos", "bg_y_index"),
        ("wave_locator_source_y", "bg_buffer_y_fp16"),
        ("ev_candidate_value", "bg_patch_value_fp16"),
    ],
    "09_Recovery": [
        ("ev_recovery_request", "recovery_request_accepted"),
        ("ev_recovery_src", "recovery_src"),
        ("wave_recovery_bank", "recovery_bank"),
        ("ev_recovery_done", "recovery_result_accepted"),
        ("ev_recovery_good", "recovery_checks_pass"),
        ("wave_recovery_y", "recovery_y_watch_fp16"),
        ("ev_patch_applied", "patch_applied"), ("ev_patch_bank", "patch_bank"),
        ("ev_patch_full", "patch_is_full_bank"),
        ("wave_final_y", "b0_patched_y_watch_fp16"),
    ],
    "10_DUE_and_Output": [
        ("due_valid", "due_valid"), ("due_ready", "due_ready"),
        ("due_src", "due_src"), ("due_reason", "due_reason"),
        ("ev_reduce_skip", "reduce_skip_mask"),
        ("ev_actual_y", "output_y_fp16x64"), ("ev_reference_y", "reference_y_fp16x64"),
        ("ev_actual_r", "output_r_fp16x12"), ("ev_reference_r", "reference_r_fp16x12"),
        ("wave_expected_y", "b0_reference_y_watch_fp16"),
    ],
}

PAIRS = [pair for entries in GROUPS.values() for pair in entries]
DISPLAY_NAMES = dict(PAIRS)
assert len(DISPLAY_NAMES) == len(PAIRS)
assert len(set(DISPLAY_NAMES.values())) == len(PAIRS)


def write_tcl():
    rows = ["set display_signals {"]
    for group, entries in GROUPS.items():
        for source, label in entries:
            # Indices and metadata are integers. FP16 encodings stay hexadecimal.
            radix = "hex" if label.endswith(("_fp16", "_fp16x16", "_fp16x64", "_fp16x12", "_mask", "_src")) else "unsigned"
            if label == "bg_y_index":
                radix = "dec"
            rows.append(f"    {source} {label} {group} {radix}")
    rows.append("}")
    (BUILD / "wave_selection.tcl").write_text("\n".join(rows) + "\n", encoding="ascii")


def publish():
    """Stream the audited trace into the compact VCD, then replace it atomically."""
    source = BUILD / "system_8_evidence_raw.vcd"
    published = PREFIX.with_suffix(".vcd")
    temporary = published.with_suffix(".vcd.tmp")
    identifiers = {}
    present = set()
    with source.open() as stream, temporary.open("w", newline="\n") as out:
        in_header = True
        for line in stream:
            if line.startswith("$var "):
                fields = line.split()
                name = fields[4]
                if name in DISPLAY_NAMES:
                    fields[4] = DISPLAY_NAMES[name]
                    identifiers[fields[3]] = name
                    present.add(name)
                    out.write(" ".join(fields) + "\n")
            elif in_header:
                out.write(line)
                if line.startswith("$enddefinitions"):
                    in_header = False
            elif line.startswith("b"):
                if line.split()[1] in identifiers:
                    out.write(line)
            elif line and line[0] in "01xXzZ":
                if line[1:].strip() in identifiers:
                    out.write(line)
            else:
                out.write(line)
    assert present == set(DISPLAY_NAMES), set(DISPLAY_NAMES) - present
    wave_objects = ET.parse(PREFIX.with_suffix(".wcfg")).findall(".//wvobject")
    wave_names = {obj.attrib["fp_name"].rsplit("/", 1)[-1] for obj in wave_objects
                  if obj.attrib["type"] != "group"}
    assert wave_names == present, (wave_names - present, present - wave_names)
    for obj in wave_objects:
        if obj.attrib["type"] != "group":
            source_name = obj.attrib["fp_name"].rsplit("/", 1)[-1]
            labels = [p.text for p in obj.findall("obj_property") if p.attrib["name"] == "label"]
            assert DISPLAY_NAMES[source_name] in labels, (source_name, labels)
    temporary.replace(published)
    with (BUILD / "system_8_evidence_signals.csv").open("w", newline="", encoding="utf-8-sig") as stream:
        writer = csv.writer(stream)
        writer.writerow(["group", "wave_name", "testbench_probe"])
        for group, entries in GROUPS.items():
            writer.writerows((group, label, original) for original, label in entries)
    # Refresh the signal references in the existing detailed guides.
    pattern = re.compile(r"\b(" + "|".join(sorted(DISPLAY_NAMES, key=len, reverse=True)) + r")\b")
    for guide in (ROOT / "资料").glob("*.md"):
        content = guide.read_text(encoding="utf-8")
        content = pattern.sub(lambda m: DISPLAY_NAMES[m[0]], content)
        content = content.replace("详细模块信号已导出全部四个 Bank", "详细模块信号仅展示 Bank0")
        guide.write_text(content, encoding="utf-8")
    write_guide()
    print(f"PASS: compact VCD and WCFG, {len(PAIRS)} key signals in {len(GROUPS)} groups")


def write_guide():
    with Path(str(PREFIX) + "_coverage.csv").open(encoding="utf-8-sig") as stream:
        coverage = list(csv.DictReader(stream))
    with Path(str(PREFIX) + "_requirements.csv").open(encoding="utf-8-sig") as stream:
        requirements = list(csv.DictReader(stream))
    lines = [
        "# 系统仿真与精简波形",
        "",
        f"本次有 {len(coverage)-1} 个测试事务，以及一次 Recovery 中复位、重载后完成的事务，共 {len(coverage)} 个完成包。",
        f"系统先在 FIFO 深度 1 下验证队满反压，再以深度 8 生成同名 system_8_evidence 波形。",
        f"所有 Bank 的 Y、三路 R、三路残差、H 表决和共享 FIFO 记录均参与自动审计。供查看的 VCD 和 Vivado 波形配置只保留 {len(PAIRS)} 个关键信号，分为 {len(GROUPS)} 组。",
        "详细过程仅展示 Bank0。共享 BG、Recovery 和 DUE 的 src 高 8 位是任务编号，低 8 位是 Bank 编号。",
        "",
        "打开 build/system/system_8_evidence.vcd，或在 Vivado 中打开同名 .wdb 和 .wcfg。",
        "VCD 使用下表的新名称，WCFG 对对应的真实测试平台信号设置相同显示名称。",
        "test_id、下标、次数、类型和搜索权重按整数读。带 fp16 的数值按 binary16 读，十六进制 3c00 表示 1，7c00 表示 +Inf。",
        "这些测试覆盖下列功能场景，覆盖统计来自实际握手和数据核对。",
        "",
        "## 按顺序查看",
        "",
        "| 分组 | 主要信号与读取方法 |",
        "|---|---|",
        "| 01 System | test_id 按十进制显示。mode_qk=1 为 qK，0 为 pV。result_valid 时读取完整结果和状态 mask |",
        "| 02 Inputs | matrix_load_valid/ready 同时为 1 时，matrix_load_bank/row 指定当前加载的 16 项矩阵行。b0_x_fp16x16 是 Bank0 锁存的 q 或 p |",
        "| 03 Bank0 GEMV | b0_gemv_phase 指定正在算 R、Y 或 H。b0_is_recovery 区分主计算与重算。b0_fault_injection_active=1 时观察 b0_injected_value_fp16x16 |",
        "| 04 ZeroBound | b0_zb_capture 时读取输入、输出和 b0_zb_special_mask。mask 每一位为 1 表示对应项被置零 |",
        "| 05 ResultBuffer | b0_buffer_write_y/index 显示写入位置。b0_buffer_seal 表示 Y 和 R 已收齐。b0_r1/2/3_fp16 为首次 GEMV 的参考校验结果 |",
        "| 06 H Vote | b0_h_slot_done 的上升沿采样整组 current1/2/3。b0_h_completed_slots 统计完成的时隙，提交始终在第三时隙结束 |",
        "| 07 Syndrome | b0_delta_valid 时残差有效。在 b0_packet_accepted 时读取 mismatch_mask 和 fault_type。b0_h1/2/3_fp16 是最终选出的 H |",
        "| 08 Shared BG | bg_candidate_accepted 时读取 src、fault_type、patch_possible、y_index、patch_value 和 locator_reason |",
        "| 09 Recovery | recovery_result_accepted 时读取 recovery_checks_pass。patch_applied 时读取 patch_bank 和 patch_is_full_bank |",
        "| 10 DUE and Output | due_valid/ready 完成 DUE 握手。reduce_skip_mask 显示屏蔽哪些 Bank，result_matches_reference 显示整个完成包的核对结果 |",
        "",
        "GEMV phase 为 0=R1、1=R2、2=Y、3=H1、4=H2、5=R3、6=H3。",
        "H current 是当前候选，first 保存第一组，previous 保存最近一次实际采样的完整组。previous 会在采样沿后更新，因此要在 b0_h_slot_done 的沿前比较输入。",
        "b0_h_matches_first/previous 只在采样握手窗口有效。前两组匹配时 b0_h_idle_slot=1，第三轮不捕获 H，结束后才提交。",
        "每轮 110 ns，H 启动被接受到 commit 或 fail 为 330 ns。H3 非有限时整组无效。",
        "",
        "| fault_type | 分流 |",
        "|---|---|",
        "| 0 | 三路检查通过 |",
        "| 1 | 符合单 Y 错特征，交 Locator 继续确认位置 |",
        "| 2 / 3 / 4 | 单 R1 / R2 / R3 错，直接修复对应校验值 |",
        "| 5 | 多错或不确定，进入 Recovery |",
        "| 6 | 特殊值、无有效 H 或非有限残差，进入 Recovery |",
        "",
        "type=1 时 bg_y_index 是从 0 开始的 Y 下标，搜索权重则从 1 开始。",
        "type=2/3/4 的补丁针对 R，bg_y_index=−1。此时 bg_patch_possible=1 表示对应 R 可以修复。",
        "bg_locator_reason=4 表示位置超范围或与合法整数权重不符。多错/非法记录会直接分流，reason 可以为 0，要结合 fault_type 和 patch_possible 判断。",
        "test_id=61/62 的 R1 被故意改到相对阈值以内或恰好等于阈值，设计会接受这两个偏差，参考完成包也保留相同的 R1。test_id=63 越过阈值后才修复 R1。",
        "",
        "b0_watch_index 在首末项测试中选 0 或 15，其余选 3。带 watch 的输入、缓冲、写回、参考和重算信号都对应这个下标。",
        "qK 返回标量在 Zero-bound 原始总线的 lane0，写缓冲时再按 write_index 放入 Y。pV 返回整个 16 项向量。",
        "因此 qK 的特殊值可以先令 special_mask[0]=1，最后在缓冲 mask 中标记 Y 的实际下标。",
        "",
        "qK 的 output_y_fp16x64 拼接四个 Bank 的 16 项结果。pV 逐步相加，低 16 项有效，其余填零。",
        "output_r_fp16x12 每 Bank 占三项，低位到高位依次为 R1、R2、R3。pV 归约后低三项有效。",
        "DUE 的 Bank 按设计屏蔽，参考输出也按相同规则计算。",
        "",
        "## 功能覆盖",
        "",
        "| 场景 | test_id（十进制） | 核对 |",
        "|---|---|---|",
    ]
    for row in requirements:
        ids = row["test_ids_decimal"]
        if len(ids.split()) > 20:
            ids = "全部事务"
        lines.append(f'| {row["requirement"]} | {ids} | {row["result"]} |')
    lines += [
        "",
        "## 实际时间索引",
        "",
        "| test_id | 场景 | 启动→完成 ns | corrected / recovered / DUE |",
        "|---|---|---|---|",
    ]
    for row in coverage:
        state = " / ".join(row[name] for name in ("corrected_hex","recovered_hex","due_hex"))
        lines.append(f'| {row["block_id_decimal"]} | {row["scenario"]} | {row["start_ns"]}→{row["complete_ns"]} | {state} |')
    lines += [
        "",
        "system_8_evidence_signals.csv 给出全部新名称与测试平台探针的对应关系。",
        "requirements.csv 给出功能覆盖，coverage.csv 给出每个事务，timeline.csv 给出实际握手时刻。",
        "results.csv 和 syndromes.csv 保留四个 Bank 的数值核对。完整输入矩阵和 q/p 在 inputs.csv 中。",
        "",
        "在工程目录运行 .\\scripts\\run_system_simulation.ps1 -Evidence 可重新生成全部结果。",
        "自动审计先读取完整内部追踪，通过后将 VCD 精简为供查看的信号，WDB 从开始就只记录这些关键信号。",
        "",
    ]
    (ROOT / "资料" / "SYSTEM_WAVE_GUIDE.md").write_text("\n".join(lines), encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--publish", action="store_true")
    args = parser.parse_args()
    publish() if args.publish else write_tcl()
