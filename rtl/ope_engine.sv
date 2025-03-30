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
  input  logic                    [H-1:0][BITW-1:0] a_i          , // Column of inputs
  input  logic                    [W-1:0][BITW-1:0] b_i          , // Row of weights
  input  logic                    [W-1:0][BITW-1:0] c_i           , // Row of biases
  // Output Result
  output logic                    [W-1:0]       [BITW-1:0] z_o  , // Row of outputs

  // fpnew_fma Input Signals
  input  logic                    [2:0]                    fma_is_boxed_i     , //3'b111
  input  fpnew_pkg::roundmode_e                            stage1_rnd_i       , //fpnew_pkg::RNE
  input  fpnew_pkg::operation_e                            op1_i              , //fpnew_pkg::FMADD
  input  logic                                             op_mod_i           , //0
  input  TagType                                           tag_i              , //0
  input  AuxType                                           aux_i              , //0
  // fpnew_fma Input Handshake
  input  logic                                             in_valid_i         ,
  output logic                    [W-1:0][H-1:0]           in_ready_o         ,
  input  logic                                             reg_enable_i       ,
  input  logic                                             flush_i            ,
  // fpnew_fma Output signals
  output fpnew_pkg::status_t      [W-1:0][H-1:0]           status_o           ,
  output logic                    [W-1:0][H-1:0]           extension_bit_o    , // always 1
  output TagType                  [W-1:0][H-1:0]           tag_o              , // always 0
  output AuxType                  [W-1:0][H-1:0]           aux_o              , // always 0
  // fpnew_fma Output handshake
  output logic                    [W-1:0][H-1:0]           out_valid_o        ,
  input  logic                                             out_ready_i        ,
  // fpnew_fma Indication of valid data in flight
  output logic                    [W-1:0][H-1:0]           busy_o             ,
  // control bus from FSM
  input  cntrl_engine_t                                    ctrl_engine_i
);


logic [H-1:0][W-1:0][BITW-1:0] internal_z_q, internal_z_d;
logic [H-1:0][W-1:0][BITW-1:0] fma_ouput;

always_comb begin 
  internal_z_d = internal_z_q;
  out_valid_o = 1'b0;
  z_o = 'b0;
  case (cntrl_engine_i.mac_mode)
    ope_pkg::Z_LOAD: begin 
      for(int row_index = 0; row_index < H; row_index++) begin
        if (row_index == cntrl_engine_i.row_index) internal_z_d[row_index] = b_i;
        else internal_z_d[row_index] = internal_z_q[row_index];
      end
    end
    ope_pkg::Z_COMPUTE: begin 
      for (int row_index = 0; row_index < H; row_index++) begin
        for (int col_index = 0; col_index < W; col_index++) begin 
          internal_z_d[row_index][col_index] = fma_ouput[row_index][col_index];
        end
      end
    end
    ope_pkg::Z_READ: begin 
      z_o = internal_z_q[cntrl_engine_i.row_index];
      out_valid_o = 1'b1;
    end
    ope_pkg::IDLE: begin 
      internal_z_d = internal_z_q;
    end
    default: internal_z_d = internal_z_q;
  endcase
end

always_ff @(posedge clk_i or negedge rst_ni) begin
  if (~rst_ni) begin
    internal_z_q <= 0;
  end else begin
    if (flush_i) internal_z_q <= 0;
    else internal_z_q <= internal_z_d;
  end
end

logic [H-1:0][W-1:0][2:0][BITW-1:0] ce_operands;
always_comb begin 
  for (int row_index = 0; row_index < H; row_index++) begin 
    for (int col_index = 0; col_index < W; col_index++) begin 
      ce_operands[row_index][col_index][0] = a_i[row_index];
      ce_operands[row_index][col_index][1] = b_i[col_index];
      ce_operands[row_index][col_index][2] = internal_z_q[row_index][col_index];
    end
  end
end

assign extension_bit_o = 'b1;
assign tag_o = 'b0;
assign aux_o = 'b0;
// the valid and ready signals need to be extended to include the new register that is added.


// Valid and ready handshake signals
logic

logic [H-1:0][W-1:0] fma_in_ready;
logic [H-1:0][W-1:0] fma_in_valid_q, fma_in_valid_d;
logic fma_single_ready;
logic fma_fire;

always_ff @(posedge clk_i or negedge rst_ni) begin 
  if (~rst_ni) begin
    fma_in_valid_q <= '0;
  end else begin
    if (flush_i) fma_in_valid_q <= '0;
    else fma_in_valid_q <= fma_in_valid_d;
  end
end

always_comb begin 
  fma_in_valid_d = '0;
  in_ready_o = '0;

  fma_single_ready = &fma_in_ready;
  fma_fire = fma_single_ready & (|valid_in_q);



end

  generate
    for(genvar row_index = 0; row_index < H; row_index++) begin: gen_mac_row
      for (genvar col_index = 0; col_index < W; col_index++) begin: gen_mac_col
      redmule_ce   #(
        .FpFormat    ( FpFormat    ),
        .NumPipeRegs ( NumPipeRegs ),
        .PipeConfig  ( PipeConfig  ),
        .Stallable   ( Stallable   )
      ) ce_i (
        .clk_i              ( clk_i              ),
        .rst_ni             ( rst_ni             ),
        .x_input_i        ( ce_operands[row_index][col_index][0] ),
        .y_input_i        ( ce_operands[row_index][col_index][1] ),
        .z_input_i        ( ce_operands[row_index][col_index][2] ),
        .fma_is_boxed_i     ( fma_is_boxed_i     ),
        .noncomp_is_boxed_i ( 3'b111            ),
        .stage1_rnd_i       ( stage1_rnd_i       ),
        .stage2_rnd_i       ( stage1_rnd_i       ),
        .op1_i              ( op1_i              ),
        .op2_i              ( op2_i              ),
        .memory_fmt_i      ( memory_fmt_i      ),
        .op_mod_i           ( op_mod_i           ),
      );
      end
    end
  endgenerate

endmodule: ope_engine