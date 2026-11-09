`timescale 1ns / 1ps
`default_nettype none
`include "bg_fault_format.vh"
// Faulty base vectors are retained privately for single-component replacement;
// Their contribution stays zero until the single-field or Recovery patch lands.
module apply_patch #(parameter integer NUM_LANES=16)(
    input wire clk_i,rst_ni,clear_i,active_i,input wire [7:0] block_id_i,
    input wire [3:0] base_valid_i,base_good_i,
    input wire [4*NUM_LANES*16-1:0] base_y_i,input wire [191:0] base_r_i,
    input wire [1:0] lookup_bank_i, input wire [3:0] lookup_pos_i,
    output wire [15:0] lookup_y_o,
    input wire [15:0] patch_src_i, input wire [2:0] patch_type_i,
    input wire [15:0] patch_pos_i, patch_value_i,
    input wire [NUM_LANES*16-1:0] recovery_y_i, input wire [47:0] recovery_r_i,
    input wire patch_full_i, patch_valid_i, output wire patch_ready_o,
    output reg applied_o,rejected_o,output reg [1:0] applied_bank_o,output reg applied_full_o,
    output wire [4*NUM_LANES*16-1:0] bank_y_o,output wire [191:0] bank_r_o
);
    localparam integer V=NUM_LANES*16;
    reg [4*V-1:0] stored_y;
    reg [191:0] stored_r;
    reg [3:0] enabled;
    wire [1:0] patch_bank = patch_src_i[1:0];
    wire [V-1:0] lookup_vector = stored_y[lookup_bank_i*V+:V];
    assign lookup_y_o = lookup_vector[lookup_pos_i*16+:16];
    wire valid_field = (patch_type_i == `BG_SINGLE_Y && patch_pos_i < NUM_LANES) ||
                       (patch_type_i >= `BG_SINGLE_R1 && patch_type_i <= `BG_SINGLE_R3);
    assign patch_ready_o=rst_ni&&active_i;
    genvar g;
    generate for(g=0;g<4;g=g+1) begin: visible
        assign bank_y_o[g*V+:V]=enabled[g]?stored_y[g*V+:V]:{V{1'b0}};
        assign bank_r_o[g*48+:48]=enabled[g]?stored_r[g*48+:48]:48'b0;
    end endgenerate
    integer b;
    always @(posedge clk_i or negedge rst_ni) begin
        if(!rst_ni) begin stored_y<=0;stored_r<=0;enabled<=0;applied_o<=0;rejected_o<=0;applied_bank_o<=0;applied_full_o<=0;end
        else begin
            applied_o<=0;rejected_o<=0;
            if(clear_i) begin stored_y<=0;stored_r<=0;enabled<=0;end
            else begin
                for(b=0;b<4;b=b+1) if(base_valid_i[b]) begin
                    stored_y[b*V+:V]<=base_y_i[b*V+:V];stored_r[b*48+:48]<=base_r_i[b*48+:48];enabled[b]<=base_good_i[b];
                end
                if(patch_valid_i&&patch_ready_o) begin
                    if (patch_src_i[15:8] != block_id_i || patch_src_i[7:0] > 3 ||
                        (!patch_full_i && !valid_field)) rejected_o <= 1;
                    else begin
                        if (patch_full_i) begin
                            stored_y[patch_bank*V+:V] <= recovery_y_i;
                            stored_r[patch_bank*48+:48] <= recovery_r_i;
                        end else begin
                            case (patch_type_i)
                                `BG_SINGLE_Y: stored_y[patch_bank*V+patch_pos_i*16+:16] <= patch_value_i;
                                `BG_SINGLE_R1: stored_r[patch_bank*48+:16] <= patch_value_i;
                                `BG_SINGLE_R2: stored_r[patch_bank*48+16+:16] <= patch_value_i;
                                `BG_SINGLE_R3: stored_r[patch_bank*48+32+:16] <= patch_value_i;
                                default: begin end
                            endcase
                        end
                        enabled[patch_bank] <= 1;
                        applied_o <= 1;
                        applied_bank_o <= patch_bank;
                        applied_full_o <= patch_full_i;
                    end
                end
            end
        end
    end
endmodule
`default_nettype wire
