// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// George Pagonis  <gpagonis@student.ethz.ch>


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
 parameter logic          Stallable   = 1'b1                         
)(
  input  logic                                             clk_i              ,
  input  logic                                             rst_ni             ,
  input  logic                    [H-1:0][BITW-1:0]        x_input_i          , // Column of inputs
  input  logic                    [W-1:0][BITW-1:0]        w_input_i          , // Row of weights
  input  logic                    [W-1:0][BITW-1:0]        y_bias_i           , // Row of biases
  output logic                    [W-1:0][BITW-1:0]        z_output_o         , // Row of outputs

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

  input  logic                                             in_valid_i         ,
  input  logic                                             y_in_valid_i       ,
  output logic                    [W-1:0][H-1:0]           in_ready_o         ,
  input  logic                                             reg_enable_i       ,
  input  logic                                             flush_i            ,
  input  logic                                             iteration_change_i , // This signal is used to flush the registers

  output fpnew_pkg::status_t      [W-1:0][H-1:0]           status_o           ,
  output logic                    [W-1:0][H-1:0]           extension_bit_o    , // always 1
  output fpnew_pkg::classmask_e   [W-1:0][H-1:0]           class_mask_o       ,
  output logic                    [W-1:0][H-1:0]           is_class_o         ,
  output TagType                  [W-1:0][H-1:0]           tag_o              , // always 0
  output AuxType                  [W-1:0][H-1:0]           aux_o              , // always 0

  output logic                                             out_valid_o        ,
  input  logic                                             out_ready_i        ,

  output logic                                             busy_o             ,
  input  cntrl_engine_t                                    cntrl_engine_i  // This include the mode (idle, load, compute, read) and the row_index
);

  /*---------------------------------------------------------------*/
  /* |                      ACCUMULATION_REGISTERS               | */
  /*---------------------------------------------------------------*/
  logic [Height-1:0][Width-1:0][BITW-1:0] engine_to_reg_output;
  logic [Height-1:0][Width-1:0]           engine_to_reg_out_valid;
  logic [Height-1:0][Width-1:0]           engine_in_valid;


  // **** Align the writing of the y_bias to the internal registers ****
  // Load first all the register (all 4) of a row and then move to the next row

  logic [$clog2(REG_PER_CE)-1:0] internal_write_index_q, internal_write_index_d;
  logic [$clog2(Height) - 1: 0] y_row_index_q, y_row_index_d;

  always_comb begin 
    internal_write_index_d  = internal_write_index_q;
    y_row_index_d           = y_row_index_q;
    if (cntrl_engine_i.mode == cntrl_engine_mode_e'(Y_LOAD)) begin
      if (y_in_valid_i) begin
        if (internal_write_index_q == REG_PER_CE - 1) begin
          internal_write_index_d = 'b0;
          y_row_index_d          = y_row_index_q + 1;
        end else begin
          internal_write_index_d = internal_write_index_q + 1;
          y_row_index_d          = y_row_index_q;
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      y_row_index_q            <= 'b0;
      internal_write_index_q   <= 'b0;
    end else begin
      if (flush_i || iteration_change_i) begin
        y_row_index_q          <= 'b0;
        internal_write_index_q <= 'b0;
      end else begin 
        y_row_index_q           <= y_row_index_d;
        internal_write_index_q  <= internal_write_index_d;
      end
    end
  end

  // **** Multiplexer for the input of the registers ****
  logic [Height-1:0][Width-1:0]           reg_in_valid;
  logic [Height-1:0][Width-1:0][BITW-1:0] reg_in_data;

  logic [Height-1:0][Width-1:0]           reg_out_valid;
  logic [Height-1:0][Width-1:0][BITW-1:0] reg_out_data;

  always_comb begin
    reg_in_data   = 'b0;
    reg_in_valid  = 'b0;
    for (int row_index = 0; row_index < Height; row_index++) begin
      for (int col_index = 0; col_index < Width; col_index++) begin
        if (cntrl_engine_i.mode == cntrl_engine_mode_e'(Y_LOAD)) begin
          reg_in_data[row_index][col_index]  = y_bias_i[col_index];
          reg_in_valid[row_index][col_index] = y_in_valid_i && (row_index == y_row_index_q); 
        end else if (cntrl_engine_i.mode == cntrl_engine_mode_e'(COMPUTE)) begin
          reg_in_data[row_index][col_index]  = engine_to_reg_output[row_index][col_index];
          reg_in_valid[row_index][col_index] = engine_to_reg_out_valid[row_index][col_index];
        end
      end
    end
  end


  logic register_reading_compute, register_reading_output; 
  always_comb begin
    register_reading_output     = 1'b0;
    register_reading_compute    = 1'b0;
    if (cntrl_engine_i.mode == cntrl_engine_mode_e'(COMPUTE) && in_valid_i) begin
      register_reading_compute  = 1'b1;
    end else if (cntrl_engine_i.mode == cntrl_engine_mode_e'(Z_READ) && out_ready_i) begin // Note: Reset the registers, good for padding values
      register_reading_output   = 1'b1;
    end
  end

  generate
    for (genvar row_index = 0; row_index < Height; row_index++) begin: accumulation_reg_row
      for (genvar col_index = 0; col_index < Width; col_index++) begin: accumulation_reg_col
        accumulation_reg #(
          .DATA_WIDTH ( BITW          ),
          .DEPTH      ( REG_PER_CE    )
        ) i_acc_reg (
          .clk_i              ( clk_i                                                ),
          .rst_ni             ( rst_ni                                               ),
          .flush_i            ( flush_i                                              ),
          .input_i            ( reg_in_data[row_index][col_index]                    ),         
          .in_valid_i         ( reg_in_valid[row_index][col_index]                   ),
          .iteration_change_i ( iteration_change_i                                   ),     
          .read_i             ( register_reading_compute  || register_reading_output ), 
          .output_o           ( reg_out_data[row_index][col_index]                   ),  
          .out_valid_o        ( reg_out_valid[row_index][col_index]                  )         
        );
      end
    end
  endgenerate

  // Register reading to the output
  logic [$clog2(REG_PER_CE)-1:0] internal_read_index_q, internal_read_index_d;
  logic [$clog2(Height) - 1: 0] z_row_index_q, z_row_index_d;

  always_comb begin 
    z_output_o              = 'b0;
    out_valid_o             = 'b0;
    internal_read_index_d   = internal_read_index_q;
    z_row_index_d           = z_row_index_q;
    if (register_reading_output) begin 
      z_output_o            = reg_out_data[z_row_index_q];
      out_valid_o           = &reg_out_valid[z_row_index_q];
      internal_read_index_d = (internal_read_index_q == REG_PER_CE - 1) ? 'b0 : internal_read_index_q + 1;
      z_row_index_d         = (internal_read_index_q == REG_PER_CE - 1) ? z_row_index_q + 1 : z_row_index_q;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      internal_read_index_q   <= 'b0;
      z_row_index_q           <= 'b0;
    end else begin
      if (flush_i || iteration_change_i) begin
        internal_read_index_q <= 'b0;
        z_row_index_q         <= 'b0;
      end else begin 
        internal_read_index_q <= internal_read_index_d;
        z_row_index_q         <= z_row_index_d;
      end
    end
  end

  /*---------------------------------------------------------------*/
  /* |                      Computing Elements                   | */
  /*---------------------------------------------------------------*/


  logic [H-1:0][W-1:0][2:0][BITW-1:0] ce_operands;
  logic [H-1:0][W-1:0]                ce_in_ready;
  always_comb begin 
    for (int row_index = 0; row_index < Height; row_index++) begin 
      for (int col_index = 0; col_index < Width; col_index++) begin 
        ce_operands[row_index][col_index][0] = x_input_i[row_index];
        ce_operands[row_index][col_index][1] = w_input_i[col_index];
        ce_operands[row_index][col_index][2] = reg_out_data[row_index][col_index];
      end
    end
  end

  // ******** Output signals ********
  // The output signals are not used in the current implementation.
  logic [Height-1:0][Width-1:0]           busy;

  assign extension_bit_o = 'b0;
  assign tag_o           = 'b0;
  assign aux_o           = 'b0;
  assign status_o        = 'b0;
  assign busy_o          = &busy;
  assign class_mask_o    = 'b0;
  assign is_class_o      = 'b0;

  // ******** Compute Engine 2D array ********

  logic ce_clk_en;
  logic ce_clk;
  always_comb begin : clock_gating_selector
    ce_clk_en            = 1'b0;
    if (cntrl_engine_i.mode == cntrl_engine_mode_e'(COMPUTE)) ce_clk_en = 1'b1;
  end : clock_gating_selector

  tc_clk_gating ce_clock_gating (
    .clk_i      ( clk_i     ),
    .en_i       ( ce_clk_en ),
    .test_en_i  ( '0        ),
    .clk_o      ( ce_clk    )    
  );

  generate
    for(genvar row_index = 0; row_index < Height; row_index++) begin: ce_row
      for (genvar col_index = 0; col_index < Width; col_index++) begin: ce_col
      redmule_ce   #(
        .FpFormat    ( FpFormat    ),
        .NumPipeRegs ( NumPipeRegs ),
        .PipeConfig  ( PipeConfig  ),
        .Stallable   ( Stallable   )
      ) i_ce (
        .clk_i              ( ce_clk                                          ),
        .rst_ni             ( rst_ni                                          ),
        .x_input_i          ( ce_operands[row_index][col_index][0]            ),
        .w_input_i          ( ce_operands[row_index][col_index][1]            ),
        .y_bias_i           ( ce_operands[row_index][col_index][2]            ),
        .fma_is_boxed_i     ( fma_is_boxed_i                                  ),
        .noncomp_is_boxed_i ( 2'b11                                           ),
        .stage1_rnd_i       ( stage1_rnd_i                                    ),
        .stage2_rnd_i       ( stage2_rnd_i                                    ),
        .op1_i              ( op1_i                                           ),
        .op2_i              ( op2_i                                           ),
        .memory_fmt_i       ( memory_fmt_i                                    ),
        .computing_fmt_i    ( computing_fmt_i                                 ),
        .same_fmt_i         ( same_fmt_i                                      ),
        .op_mod_i           ( op_mod_i                                        ),
        .tag_i              ( tag_i                                           ),
        .aux_i              ( aux_i                                           ),
        .in_valid_i         ( in_valid_i                                      ), 
        .in_ready_o         ( ce_in_ready[row_index][col_index]               ),
        .reg_enable_i       ( reg_enable_i                                    ),
        .flush_i            ( flush_i                                         ),
        .z_output_o         ( engine_to_reg_output[row_index][col_index]      ),
        .status_o           (                                                 ), // Not used 
        .extension_bit_o    (                                                 ), // Not used
        .class_mask_o       (                                                 ), // Not used
        .is_class_o         (                                                 ), // Not used
        .tag_o              (                                                 ), // Not used
        .aux_o              (                                                 ), // Not used
        .out_valid_o        ( engine_to_reg_out_valid[row_index][col_index]   ),
        .out_ready_i        ( 1'b1                                            ),
        .busy_o             ( busy[row_index][col_index]                      )  // Not used
      );
      end
    end
  endgenerate
endmodule: ope_engine