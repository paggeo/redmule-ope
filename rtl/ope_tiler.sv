// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Yvan Tortorella <yvan.tortorella@unibo.it>
// Francesco Conti <f.conti@unibo.it>

module ope_tiler
  import ope_pkg::*;
  import hwpe_ctrl_package::*;
(
  input  logic              clk_i      ,
  input  logic              rst_ni     ,
  input  logic              clear_i    ,
  input  logic              setback_i  ,
  input  logic              start_cfg_i,
  input  ctrl_regfile_t     reg_file_i ,
  output logic              valid_o    ,
  output ctrl_regfile_t     reg_file_o
);

logic clk_en;
logic clk_int;

redmule_config_t config_d, config_q;

always_ff @(posedge clk_i, negedge rst_ni) begin: clock_gate_enabler
  if (~rst_ni) begin
    clk_en <= 1'b0;
  end else begin
    if (clear_i || setback_i) begin
      clk_en <= 1'b0;
    end else if (start_cfg_i) begin
      clk_en <= 1'b1;
    end
  end
end

tc_clk_gating i_tiler_clockg (
  .clk_i      ( clk_i   ),
  .en_i       ( clk_en  ),
  .test_en_i  ( '0      ),
  .clk_o      ( clk_int )
);

assign config_d.x_addr          = reg_file_i.hwpe_params[X_ADDR];
assign config_d.w_addr          = reg_file_i.hwpe_params[W_ADDR];
assign config_d.z_addr          = reg_file_i.hwpe_params[Z_ADDR];
assign config_d.m_size          = reg_file_i.hwpe_params[MCFIG0][15: 0];
assign config_d.k_size          = reg_file_i.hwpe_params[MCFIG0][31:16];
assign config_d.n_size          = reg_file_i.hwpe_params[MCFIG1][15: 0];
// assign config_d.gemm_ops        = gemm_op_e' (reg_file_i.hwpe_params[MACFG][12:10]);
assign config_d.gemm_ops        = gemm_op_e' (reg_file_i.hwpe_params[MACFG][12:10]);
assign config_d.gemm_memory_fmt     = gemm_fmt_e'(reg_file_i.hwpe_params[MACFG][ 9: 7]);    // Memory Format
assign config_d.gemm_computing_fmt  = gemm_fmt_e'(reg_file_i.hwpe_params[MACFG][ 19: 17]);  // Computing Format

logic [$clog2(2)-1:0] cnt;
logic valid_q, ready_q;

always_ff @(posedge clk_i or negedge rst_ni)
begin : counter
  if(~rst_ni) begin
    cnt <= '0;
    valid_q <= '0;
    ready_q <= 1'b1;
  end
  else if(clear_i | setback_i ) begin
    cnt <= '0;
    valid_q <= '0;
    ready_q <= 1'b1;
  end
  else if(cnt == 2 - 1) begin
    cnt <= 0;
    valid_q <= 1'b1;
    ready_q <= 1'b1;
  end
  else if((start_cfg_i==1'b1) || (cnt>0)) begin
    cnt <= cnt + 1;
    valid_q <= 1'b0;
    ready_q <= 1'b0;
  end
end
logic valid_tmp, ready_tmp;
assign valid_tmp = valid_q;
assign ready_tmp = ready_q;

assign config_d.stage_1_rnd_mode = config_d.gemm_ops == MATMUL ? RNE :
                                   config_d.gemm_ops == GEMM   ? RNE :
                                   config_d.gemm_ops == ADDMAX ? RNE :
                                   config_d.gemm_ops == ADDMIN ? RNE :
                                   config_d.gemm_ops == MULMAX ? RNE :
                                   config_d.gemm_ops == MULMIN ? RNE :
                                   config_d.gemm_ops == MAXMIN ? RTZ :
                                                                 RNE ;
assign config_d.stage_2_rnd_mode = config_d.gemm_ops == MATMUL ? RNE :
                                   config_d.gemm_ops == GEMM   ? RNE :
                                   config_d.gemm_ops == ADDMAX ? RTZ :
                                   config_d.gemm_ops == ADDMIN ? RNE :
                                   config_d.gemm_ops == MULMAX ? RTZ :
                                   config_d.gemm_ops == MULMIN ? RNE :
                                   config_d.gemm_ops == MAXMIN ? RNE :
                                                                 RTZ;
assign config_d.stage_1_op       = config_d.gemm_ops == MATMUL ? FPU_FMADD :
                                   config_d.gemm_ops == GEMM   ? FPU_FMADD :
                                   config_d.gemm_ops == ADDMAX ? FPU_ADD :
                                   config_d.gemm_ops == ADDMIN ? FPU_ADD :
                                   config_d.gemm_ops == MULMAX ? FPU_MUL :
                                   config_d.gemm_ops == MULMIN ? FPU_MUL :
                                   config_d.gemm_ops == MAXMIN ? FPU_MINMAX :
                                                                 FPU_MINMAX;
assign config_d.stage_2_op       = FPU_MINMAX;
assign config_d.memory_format     = config_d.gemm_memory_fmt == Float16    ? FPU_FP16 :
                                   config_d.gemm_memory_fmt == Float8     ? FPU_FP8 :
                                   config_d.gemm_memory_fmt == Float16Alt ? FPU_FP16ALT :
                                   config_d.gemm_memory_fmt == Float32    ? FPU_FP32 :
                                                                           FPU_FP8ALT;
assign config_d.computing_format = config_d.gemm_computing_fmt == Float16    ? FPU_FP16 :
                                   config_d.gemm_computing_fmt == Float8     ? FPU_FP8 :
                                   config_d.gemm_computing_fmt == Float16Alt ? FPU_FP16ALT :
                                   config_d.gemm_computing_fmt == Float32    ? FPU_FP32 :
                                                                            FPU_FP8ALT;

assign config_d.gemm_selection   = 1'b1;


// register configuration to avoid critical paths (maybe removable!)
always_ff @(posedge clk_int or negedge rst_ni) begin
  if(~rst_ni)
    config_q <= '0;
  else if (clear_i)
    config_q <= '0;
  else if(valid_tmp & ready_tmp)
    config_q <= config_d;
end

// generate output valid
always_ff @(posedge clk_int or negedge rst_ni) begin
  if(~rst_ni)
    valid_o <= '0;
  else if (clear_i | setback_i)
    valid_o <= '0;
  else if(ready_tmp)
    valid_o <= valid_tmp;
end

// re-encode in older RedMulE regfile map
assign reg_file_o.generic_params = '0;
assign reg_file_o.ext_data = '0;
assign reg_file_o.hwpe_params[REGFILE_N_MAX_IO_REGS-1:REDMULE_REGS] = '0;
assign reg_file_o.hwpe_params[      X_ADDR]        = config_d.x_addr; // do not register (these are straight from regfile)
assign reg_file_o.hwpe_params[      W_ADDR]        = config_d.w_addr; // do not register (these are straight from regfile)
assign reg_file_o.hwpe_params[      Z_ADDR]        = config_d.z_addr; // do not register (these are straight from regfile)
assign reg_file_o.hwpe_params[OP_SELECTION][31:29] = config_q.stage_1_rnd_mode;
assign reg_file_o.hwpe_params[OP_SELECTION][28:26] = config_q.stage_2_rnd_mode;
assign reg_file_o.hwpe_params[OP_SELECTION][25:21] = (config_q.memory_format != config_q.computing_format)? fpnew_pkg::operation_e'(fpnew_pkg::SDOTP) : FPU_FMADD;
// assign reg_file_o.hwpe_params[OP_SELECTION][25:21] = config_q.stage_1_op;
assign reg_file_o.hwpe_params[OP_SELECTION][20:16] = config_q.stage_2_op;
assign reg_file_o.hwpe_params[OP_SELECTION][15:13] = config_q.memory_format;
assign reg_file_o.hwpe_params[OP_SELECTION][12:10] = config_q.computing_format;
assign reg_file_o.hwpe_params[OP_SELECTION][ 9: 1] = '0;
assign reg_file_o.hwpe_params[OP_SELECTION][0]     = config_q.gemm_selection;

assign reg_file_o.hwpe_params[M_SIZE][15:0]        = config_q.m_size;
assign reg_file_o.hwpe_params[N_SIZE][15:0]        = config_q.n_size;
assign reg_file_o.hwpe_params[K_SIZE][15:0]        = config_q.k_size;
assign reg_file_o.hwpe_params[M_SIZE][31:16]       = 'b0;
assign reg_file_o.hwpe_params[N_SIZE][31:16]       = 'b0;
assign reg_file_o.hwpe_params[K_SIZE][31:16]       = 'b0;

endmodule: ope_tiler
