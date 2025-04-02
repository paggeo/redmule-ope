// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// George Pagonis
//


module ope_engine
  import fpnew_pkg::*;
  import redmule_pkg::*;
#(
 parameter  fp_format_e   FpFormat    = fpnew_pkg::FP32              ,
 parameter  int unsigned  Height      = 4                            , // Number of PEs per row
 parameter  int unsigned  Width       = 8                            , // Number of parallel index
 parameter  int unsigned  NumPipeRegs = 3                            ,
 parameter  pipe_config_t PipeConfig  = DISTRIBUTED                  ,
 parameter  type          TagType     = logic                        ,
 parameter  type          AuxType     = logic                        ,
 localparam int unsigned  BITW        = fpnew_pkg::fp_width(FpFormat), // Number of bits for the given format
 localparam int unsigned  H           = Height                       ,
 localparam int unsigned  W           = Width                        ,
 parameter logic          Stallable   = 1'b0                         ,
 localparam int unsigned  DELAY       = NumPipeRegs+1
)(
  input  logic                                             clk_i              ,
  input  logic                                             rst_ni             ,
  // Input Elements
  input  logic                    [H-1:0][BITW-1:0] x_input_i          , // Column of inputs
  input  logic                    [W-1:0][BITW-1:0] w_input_i          , // Row of weights
  input  logic                    [W-1:0][BITW-1:0] y_bias_i           , // Row of biases
  // Output Result
  output logic                    [W-1:0]       [BITW-1:0] z_output_o  , // Row of outputs

  // fpnew_fma Input Signals
  input  logic                    [2:0]                    fma_is_boxed_i     , //3'b111
  input  logic                    [1:0]                    noncomp_is_boxed_i ,
  input  fpnew_pkg::roundmode_e                            stage1_rnd_i       , //fpnew_pkg::RNE
  input  fpnew_pkg::roundmode_e                            stage2_rnd_i       ,
  input  fpnew_pkg::operation_e                            op1_i              ,
  input  fpnew_pkg::operation_e                            op2_i              ,
  input  fpu_fmt_e                                         memory_fmt_i       ,
  input  fpu_fmt_e                                         computing_fmt_i    ,
  input  logic                                             same_fmt_i         , 
  input  logic                                             op_mod_i           , //0
  input  TagType                                           tag_i              , //0
  input  AuxType                                           aux_i              , //0
  // fpnew_fma Input Handshake
  input  logic                                             in_valid_i         ,
  input  logic                                             y_in_valid_i       ,
  output logic                    [W-1:0][H-1:0]           in_ready_o         ,
  input  logic                                             reg_enable_i       ,
  input  logic                                             flush_i            ,
  // fpnew_fma Output signals
  output fpnew_pkg::status_t      [W-1:0][H-1:0]           status_o           ,
  output logic                    [W-1:0][H-1:0]           extension_bit_o    , // always 1
  output fpnew_pkg::classmask_e   [W-1:0][H-1:0]           class_mask_o       ,
  output logic                    [W-1:0][H-1:0]           is_class_o         ,
  output TagType                  [W-1:0][H-1:0]           tag_o              , // always 0
  output AuxType                  [W-1:0][H-1:0]           aux_o              , // always 0
  // fpnew_fma Output handshake
  output logic                    [W-1:0][H-1:0]           out_valid_o        ,
  input  logic                                             out_ready_i        ,
  // fpnew_fma Indication of valid data in flight
  output logic                    [W-1:0][H-1:0]           busy_o             ,
  // control bus from FSM
  input  cntrl_engine_t                                    cntrl_engine_i  // This include the mode (idle, load, compute, read) and the row_index
);

  // ******** OPE Registers ********
  // They store the intermediate results
  // They should be loaded first the internal registers then move to the next row

  logic [Height-1:0][Width-1:0][BITW-1:0] engine_reg_output;
  logic [Height-1:0][Width-1:0]           engine_reg_out_valid;
  logic [Height-1:0][Width-1:0]           engine_in_valid;

  logic [$clog2(REG_PER_CE)-1:0] internal_write_index_q, internal_write_index_d;
  logic [$clog2(Height) - 1: 0] y_row_index_q, y_row_index_d;

  always_comb begin
    for (int row_index = 0; row_index < Height; row_index++) begin
      for (int col_index = 0; col_index < Width; col_index++) begin
        engine_in_valid[row_index][col_index] = y_in_valid_i && (row_index == y_row_index_q);
      end
    end
  end

  generate
    for (genvar row_index = 0; row_index < Height; row_index++) begin: gen_row
      for (genvar col_index = 0; col_index < Width; col_index++) begin: gen_col
        ope_engine_reg #(
          .DATA_WIDTH ( BITW          ),
          .D          ( REG_PER_CE    )
        ) reg_i (
          .clk_i      ( clk_i                                                               ),
          .rst_ni     ( rst_ni                                                              ),
          .flush_i    ( flush_i                                                             ),
          .input_i    ( y_bias_i[col_index]                                                 ),         
          .in_valid_i ( engine_in_valid[row_index][col_index]                               ),
          .read_i     ( cntrl_engine_i.mode == cntrl_engine_mode_e'(Y_LOAD) || y_in_valid_i ),
          .output_o   ( engine_reg_output[row_index][col_index]                             ),
          .out_valid_o( engine_reg_out_valid[row_index][col_index]                          )      
        );
      end
    end
  endgenerate


  always_comb begin 
    internal_write_index_d = internal_write_index_q;
    y_row_index_d = y_row_index_q;
    if (cntrl_engine_i.mode == cntrl_engine_mode_e'(Y_LOAD)) begin
      if (y_in_valid_i) begin
        if (internal_write_index_q == REG_PER_CE - 1) begin
          internal_write_index_d = 'b0;
          y_row_index_d = y_row_index_q + 1;
        end else begin
          internal_write_index_d = internal_write_index_q + 1;
          y_row_index_d = y_row_index_q;
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      y_row_index_q <= 'b0;
      internal_write_index_q <= 'b0;
    end else begin
      if (flush_i) begin
        y_row_index_q <= 'b0;
        internal_write_index_q <= 'b0;
      end else begin 
        y_row_index_q <= y_row_index_d;
        internal_write_index_q <= internal_write_index_d;
      end
    end
  end

/*
logic [H-1:0][W-1:0][BITW-1:0] ce_output;
logic [H-1:0][W-1:0]           ce_in_ready;
logic [H-1:0][W-1:0]           ce_out_valid;

logic ce_valid;
assign ce_valid = in_valid_i & (cntrl_ope_engine_i.mode == redmule_pkg::OPE_COMPUTE);

always_comb begin 
  internal_reg_d = internal_reg_q;
  out_valid_o = 1'b0;
  z_output_o = 'b0;
  case (cntrl_engine_i.mode)
    ope_pkg::Z_LOAD: begin 
      for(int row_index = 0; row_index < Height; row_index++) begin
        if (row_index == cntrl_engine_i.row_index) internal_reg_d[row_index] = w_input_i;
        else internal_reg_d[row_index] = internal_reg_q[row_index];
      end
    end
    ope_pkg::Z_COMPUTE: begin 
      for (int row_index = 0; row_index < Height; row_index++) begin
        for (int col_index = 0; col_index < Width; col_index++) begin 
          internal_reg_d[row_index][col_index] = ce_output[row_index][col_index];
        end
      end
    end
    ope_pkg::Z_READ: begin // This should wait for the output to be ready
      z_output_o = internal_reg_q[cntrl_engine_i.row_index];
      out_valid_o = 1'b1;
    end
    ope_pkg::IDLE: begin 
      internal_reg_d = internal_reg_q;
    end
    default: internal_reg_d = internal_reg_q;
  endcase
end


logic [H-1:0][W-1:0][2:0][BITW-1:0] ce_operands;
always_comb begin 
  for (int row_index = 0; row_index < Height; row_index++) begin 
    for (int col_index = 0; col_index < Width; col_index++) begin 
      ce_operands[row_index][col_index][0] = x_input_i[row_index];
      ce_operands[row_index][col_index][1] = w_input_i[col_index];
      ce_operands[row_index][col_index][2] = internal_reg_q[row_index][col_index];
    end
  end
end

// ******** Output signals ********
// The output signals are not used in the current implementation.
assign extension_bit_o = 'b0;
assign tag_o           = 'b0;
assign aux_o           = 'b0;
assign status_o        = 'b0;
assign busy_o          = 'b0;
assign class_mask_o    = 'b0;
assign is_class_o      = 'b0;

  generate
    for(genvar row_index = 0; row_index < Height; row_index++) begin: gen_mac_row
      for (genvar col_index = 0; col_index < Width; col_index++) begin: gen_mac_col
      redmule_ce   #(
        .FpFormat    ( FpFormat    ),
        .NumPipeRegs ( NumPipeRegs ),
        .PipeConfig  ( PipeConfig  ),
        .Stallable   ( Stallable   )
      ) ce_i (
        .clk_i              ( clk_i                                ),
        .rst_ni             ( rst_ni                               ),
        .x_input_i          ( ce_operands[row_index][col_index][0] ),
        .y_input_i          ( ce_operands[row_index][col_index][1] ),
        .z_input_i          ( ce_operands[row_index][col_index][2] ),
        .fma_is_boxed_i     ( fma_is_boxed_i                       ),
        .noncomp_is_boxed_i ( 3'b111                               ),
        .stage1_rnd_i       ( stage1_rnd_i                         ),
        .stage2_rnd_i       ( stage2_rnd_i                         ),
        .op1_i              ( op1_i                                ),
        .op2_i              ( op2_i                                ),
        .memory_fmt_i       ( memory_fmt_i                         ),
        .computing_fmt_i    ( computing_fmt_i                      ),
        .same_fmt_i         ( same_fmt_i                           ),
        .op_mod_i           ( op_mod_i                             ),
        .tag_i              ( tag_i                                ),
        .aux_i              ( aux_i                                ),
        .in_valid_i         ( in_valid_i                           ), 
        .in_ready_o         ( ce_in_ready[row_index][col_index]    ),
        .reg_enable_i       ( reg_enable_i                         ),
        .flush_i            ( flush_i                              ),
        .z_output_o         ( ce_output[row_index][col_index]      ),
        .status_o           (                                      ), // Not used 
        .extension_bit_o    (                                      ), // Not used
        .is_class_o         (                                      ), // Not used
        .tag_o              (                                      ), // Not used
        .aux_o              (                                      ), // Not used
        .out_valid_o        ( ce_out_valid[row_index][col_index]   ),
        .out_ready_i        ( out_ready_i                          ), 
        .busy_o             (                                      )  // Not used
      );
      end
    end
  endgenerate
  */
endmodule: ope_engine