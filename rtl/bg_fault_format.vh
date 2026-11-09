`ifndef BG_FAULT_FORMAT_VH
`define BG_FAULT_FORMAT_VH
// V3 record: {src[15:0], type[2:0], payload[31:0]}.
// SINGLE_Y payload = {delta2, delta1}; SINGLE_R payload[15:0] = replacement.
// Recovery types only use src. Y and R live in the writeback store.
`define BG_RECORD_WIDTH 51
`define BG_DELTA1_LSB 0
`define BG_DELTA2_LSB 16
`define BG_TYPE_LSB 32
`define BG_SRC_LSB 35
`define BG_CLEAN 3'd0
`define BG_SINGLE_Y 3'd1
`define BG_SINGLE_R1 3'd2
`define BG_SINGLE_R2 3'd3
`define BG_SINGLE_R3 3'd4
`define BG_MULTI_OR_UNKNOWN 3'd5
`define BG_INVALID 3'd6
`endif
