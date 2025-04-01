// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Andrea Belano <andrea.belano2@unibo.it>
//

module redmule_memory_scheduler
  import redmule_pkg::*;
  import hwpe_ctrl_package::*;
#(
  parameter int unsigned   DW   = DATAW,
  parameter int unsigned   W    = ARRAY_WIDTH,
  parameter int unsigned   H    = ARRAY_HEIGHT,
  parameter int unsigned   ELW  = BITW,
  localparam int unsigned  D    = TOT_DEPTH
) (
  input  logic                  clk_i            ,
  input  logic                  rst_ni           ,
  input  logic                  clear_i          ,
  input  ctrl_regfile_t         reg_file_i       ,
  input  flgs_streamer_t        flgs_streamer_i  ,
  input  cntrl_scheduler_t      cntrl_scheduler_i,
  output cntrl_streamer_t       cntrl_streamer_o
);

  logic [31:0] i_counter_d, i_counter_q;
  logic [31:0] j_counter_d, j_counter_q;

  always_comb begin 
    i_counter_d = 'b0;
    j_counter_d = 'b0;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : x_cols_iters_register
    if (~rst_ni) begin
      i_counter_q <= 'b0;
      j_counter_q <= 'b0;
    end else begin
      if (clear_i) begin
        i_counter_q <= 'b0;
        j_counter_q <= 'b0;
      end else begin // change that
        i_counter_q <= i_counter_d;
        j_counter_q <= j_counter_d;
      end
    end

  end
  always_comb begin : address_gen_signals
    // Here we initialize the streamer source signals
    // for the X stream source
    // X: M*N | W: N*K | Y: N*K | Z: N*K
    cntrl_streamer_o.x_stream_source_ctrl.addressgen_ctrl.base_addr     = reg_file_i.hwpe_params[X_ADDR] + i_counter_q * BITW/8;
    cntrl_streamer_o.x_stream_source_ctrl.addressgen_ctrl.tot_len       = reg_file_i.hwpe_params[M_SIZE];
    cntrl_streamer_o.x_stream_source_ctrl.addressgen_ctrl.d0_len        = reg_file_i.hwpe_params[M_SIZE];
    cntrl_streamer_o.x_stream_source_ctrl.addressgen_ctrl.d0_stride     = reg_file_i.hwpe_params[N_SIZE] * BITW/8;
    cntrl_streamer_o.x_stream_source_ctrl.addressgen_ctrl.dim_enable_1h = 2'b11;

    // Here we initialize the streamer source signals
    // for the W stream source
    cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.base_addr     = reg_file_i.hwpe_params[W_ADDR] + j_counter_q * BITW/8;
    cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.tot_len       = reg_file_i.hwpe_params[N_SIZE];
    cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.d0_len        = reg_file_i.hwpe_params[N_SIZE];
    cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.d0_stride     = reg_file_i.hwpe_params[K_SIZE] * BITW/8;
    cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.dim_enable_1h = 2'b11;

    // Here we initialize the streamer source signals
    // for the Y stream source
    cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.base_addr     = reg_file_i.hwpe_params[Z_ADDR] + i_counter_q * BITW/8 * reg_file_i.hwpe_params[K_SIZE] + j_counter_q * BITW/8;
    cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.tot_len       = ARRAY_HEIGHT;
    cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.d0_len        = ARRAY_HEIGHT;
    cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.d0_stride     = reg_file_i.hwpe_params[K_SIZE] * BITW/8;
    cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.dim_enable_1h = 2'b11;

    // Here we initialize the streamer sink signals for
    // the Z stream sink
    cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.base_addr       = reg_file_i.hwpe_params[Z_ADDR] + i_counter_q * BITW/8 * reg_file_i.hwpe_params[K_SIZE] + j_counter_q * BITW/8;
    cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.tot_len         = ARRAY_HEIGHT;
    cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.d0_len          = ARRAY_HEIGHT;
    cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.d0_stride       = reg_file_i.hwpe_params[K_SIZE] * BITW/8;
    cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.dim_enable_1h   = 2'b11;
  end

  always_comb begin : req_start_assignment
    cntrl_streamer_o.x_stream_source_ctrl.req_start    = cntrl_scheduler_i.start_load_x && flgs_streamer_i.x_stream_source_flags.ready_start;
    cntrl_streamer_o.w_stream_source_ctrl.req_start    = cntrl_scheduler_i.start_load_w && flgs_streamer_i.w_stream_source_flags.ready_start;
    cntrl_streamer_o.y_stream_source_ctrl.req_start    = cntrl_scheduler_i.start_load_y && flgs_streamer_i.y_stream_source_flags.ready_start;
    cntrl_streamer_o.z_stream_sink_ctrl.req_start      = cntrl_scheduler_i.start_store_z && flgs_streamer_i.z_stream_sink_flags.ready_start;
  end

  // NOTE: these are used for the casting, don't care for now
  assign cntrl_streamer_o.input_cast_src_fmt  = fpnew_pkg::fp_format_e'(reg_file_i.hwpe_params[OP_SELECTION][15:13]);
  assign cntrl_streamer_o.input_cast_dst_fmt  = fpnew_pkg::fp_format_e'(reg_file_i.hwpe_params[OP_SELECTION][12:10]);
  assign cntrl_streamer_o.output_cast_src_fmt = fpnew_pkg::fp_format_e'(reg_file_i.hwpe_params[OP_SELECTION][12:10]);
  assign cntrl_streamer_o.output_cast_dst_fmt = fpnew_pkg::fp_format_e'(reg_file_i.hwpe_params[OP_SELECTION][15:13]);

endmodule : redmule_memory_scheduler
