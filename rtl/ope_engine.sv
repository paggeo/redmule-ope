// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// George Pagonis  <gpagonis@student.ethz.ch>


module ope_engine
  import fpnew_pkg::*;
  import ope_pkg::*;
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


  input logic                                              single_iteration_i, 
  output logic                                             accumulation_reg_y_ready_o,
  output logic                                             accumulation_reg_z_valid_o,    
  output logic                                              accumuluation_reg_full_first_o, 

  output logic                                             busy_o             ,
  input  cntrl_engine_t                                    cntrl_engine_i  // This include the mode (idle, load, compute, read) and the row_index
);


  typedef enum logic {
    CE_RELOAD = 1'b0,
    CE_RUNNING = 1'b1
  } ce_state_e;

  ce_state_e ce_state_current, ce_state_next;


  logic [31:0] inner_loop_counter_q, inner_loop_counter_d;

  logic [$clog2(REG_PER_CE)-1:0] y_write_reg_index_q, y_write_reg_index_d;
  logic [$clog2(Height)-1:0] y_write_row_index_q, y_write_row_index_d;

  logic [$clog2(REG_PER_CE)-1:0] z_read_reg_index_q, z_read_reg_index_d;
  logic [$clog2(Height)-1:0] z_read_row_index_q, z_read_row_index_d;

  logic [$clog2(REG_PER_CE)-1:0] reg_read_to_engine_q, reg_read_to_engine_d;
  logic acc_reg_write_valid;


  logic [Height-1:0][Width-1:0][BITW-1:0] reg_out_data;
  logic [Height-1:0][Width-1:0]           reg_out_valid;

  logic [Height-1:0][Width-1:0][BITW-1:0] engine_to_reg_output;
  logic [Height-1:0][Width-1:0]           engine_to_reg_out_valid;
  logic [Height-1:0][Width-1:0]           engine_in_valid;

  /*---------------------------------------------------------------*/

  typedef enum logic [1:0] {
    ACC_EMPTY = 2'b00,
    ACC_Y_FULL = 2'b01,
    ACC_Z_FULL = 2'b10
  } acc_state_e;

  acc_state_e acc_state_current, acc_state_next;

  assign accumulation_reg_z_valid_o     = (acc_state_current == ACC_Z_FULL) ? 1'b1 : 1'b0;
  assign accumulation_reg_y_ready_o     = (acc_state_current == ACC_EMPTY)  ? 1'b1 : 1'b0;
  assign accumuluation_reg_full_first_o = (acc_state_current == ACC_Y_FULL) ? 1'b1 : 1'b0;

  logic not_first_d, not_first_q;

  always_comb begin
    not_first_d = not_first_q;
    if (acc_state_current == ACC_Y_FULL && acc_state_next == ACC_EMPTY) not_first_d = 1'b1;
  end

  always_comb begin 
    acc_state_next = acc_state_current;
    y_write_reg_index_d = y_write_reg_index_q;
    y_write_row_index_d = y_write_row_index_q;
    reg_read_to_engine_d = reg_read_to_engine_q;
    z_read_reg_index_d = z_read_reg_index_q;
    z_read_row_index_d = z_read_row_index_q;
    
    case (acc_state_current)
      ACC_EMPTY: begin
        if (y_in_valid_i) begin
          y_write_reg_index_d = (y_write_reg_index_q == REG_PER_CE - 1) ? 'b0 : y_write_reg_index_q + 1;
          y_write_row_index_d = (y_write_reg_index_q == REG_PER_CE - 1) ? (y_write_row_index_q == Height-1) ? 'b0: y_write_row_index_q + 1 : y_write_row_index_q;
          acc_state_next      = (y_write_row_index_q == Height - 1 && y_write_reg_index_q == REG_PER_CE - 1)  ? ACC_Y_FULL : ACC_EMPTY;
        end
      end

      ACC_Y_FULL: begin // NOTE:  All the y-bias values are loaded , Not correct Fix it
        if (in_valid_i) begin
          reg_read_to_engine_d = (reg_read_to_engine_q == REG_PER_CE - 1) ? 'b0: reg_read_to_engine_q + 1; // This can be used both ways
          acc_state_next = (reg_read_to_engine_q == REG_PER_CE - 1) ? (not_first_q || single_iteration_i) ? ACC_Z_FULL : ACC_EMPTY : ACC_Y_FULL;
        end
      end

      ACC_Z_FULL: begin 
        if (out_ready_i) begin 
          z_read_reg_index_d = (z_read_reg_index_q == REG_PER_CE - 1) ? 'b0: z_read_reg_index_q + 1;
          z_read_row_index_d = (z_read_reg_index_q == REG_PER_CE - 1) ? (z_read_row_index_q == Height - 1) ? 'b0: z_read_row_index_q + 1: z_read_row_index_q;
          acc_state_next     = (z_read_row_index_q == Height - 1) ? ACC_EMPTY : ACC_Z_FULL;
        end
      end
    endcase
  end
  
  always_comb begin
    out_valid_o = 1'b0;
    z_output_o = 'b0;
    if (acc_state_current == ACC_Z_FULL && out_ready_i) begin
      out_valid_o = 1'b1;
      for (int row_index = 0; row_index < Height; row_index++) begin
        if (z_read_row_index_q == row_index) begin
          z_output_o = reg_out_data[row_index];
        end
      end
    end
  end

  
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      acc_state_current <= ACC_EMPTY;
      y_write_reg_index_q <= 'b0;
      y_write_row_index_q <= 'b0;
      reg_read_to_engine_q <= 'b0;
      z_read_reg_index_q <= 'b0;
      z_read_row_index_q <= 'b0;
      not_first_q <= 'b0;
    end else begin
      if (flush_i) begin
        acc_state_current <= ACC_EMPTY;
        y_write_reg_index_q <= 'b0;
        y_write_row_index_q <= 'b0;
        reg_read_to_engine_q <= 'b0;
        z_read_reg_index_q <= 'b0;
        z_read_row_index_q <= 'b0;
        not_first_q <= 'b0;
      end else begin 
        acc_state_current <= acc_state_next;
        y_write_reg_index_q <= y_write_reg_index_d;
        y_write_row_index_q <= y_write_row_index_d;
        reg_read_to_engine_q <= reg_read_to_engine_d;
        z_read_reg_index_q <= z_read_reg_index_d;
        z_read_row_index_q <= z_read_row_index_d;
        not_first_q <= not_first_d;
      end
    end
  end

  /*---------------------------------------------------------------*/
  /* |                      Writing Mutliplexer                  | */
  /*---------------------------------------------------------------*/

  
  logic [Height-1:0][Width-1:0]           reg_in_valid;
  logic [Height-1:0][Width-1:0][BITW-1:0] reg_in_data;
  logic [$clog2(REG_PER_CE)-1:0]          write_index;

  always_comb begin
    reg_in_data   = 'b0;
    reg_in_valid  = 'b0;
    write_index   = 'b0;
    for (int row_index = 0; row_index < Height; row_index++) begin
      for (int col_index = 0; col_index < Width; col_index++) begin
        if (acc_state_current == ACC_EMPTY) begin // Load from external
          reg_in_data[row_index][col_index]  = y_bias_i[col_index];
          reg_in_valid[row_index][col_index] = y_in_valid_i && (row_index == y_write_row_index_q); 
          write_index                        = y_write_reg_index_q;
        end else if (acc_state_current == ACC_Y_FULL) begin // Load from the engine - the output
          reg_in_data[row_index][col_index]  = engine_to_reg_output[row_index][col_index];
          reg_in_valid[row_index][col_index] = engine_to_reg_out_valid[row_index][col_index];
          write_index                        = reg_read_to_engine_q;
        end
      end
    end
  end
  
  /*---------------------------------------------------------------*/
  /* |                      Reading Mutliplexer                  | */
  /*---------------------------------------------------------------*/

  logic [Height-1:0][Width-1:0]  reading_enable;
  logic [$clog2(REG_PER_CE)-1:0] read_index;

  always_comb begin
    reading_enable = 'b0;
    read_index     = 'b0;
    for (int row_index = 0; row_index < Height; row_index++) begin
      for (int col_index = 0; col_index < Width; col_index++) begin
        if (acc_state_current == ACC_Z_FULL && out_ready_i) begin // Read row by row
          read_index = z_read_reg_index_q;
          reading_enable = (row_index == z_read_reg_index_q);
        end else if (acc_state_current == ACC_Y_FULL && in_valid_i) begin
          read_index = reg_read_to_engine_q; // Same as write index | they happen in parallel
          reading_enable = 1'b1;
        end
      end 
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
          .iteration_change_i ( iteration_change_i                                   ),     
          .input_i            ( reg_in_data[row_index][col_index]                    ),         
          .write_en_i         ( reg_in_valid[row_index][col_index]                   ),
          .write_index_i      ( write_index                                          ),
          .read_en_i          ( reading_enable[row_index][col_index]                 ),
          .read_index_i       ( read_index                                           ),
          .output_o           ( reg_out_data[row_index][col_index]                   ),  
          .out_valid_o        ( reg_out_valid[row_index][col_index]                  )         
        );
      end
    end
  endgenerate

  /*---------------------------------------------------------------*/
  /* |                      Computing Elements                   | */
  /*---------------------------------------------------------------*/


  logic [H-1:0][W-1:0][2:0][BITW-1:0] ce_operands;
  logic [H-1:0][W-1:0]                ce_in_ready;

  always_comb begin
    inner_loop_counter_d = inner_loop_counter_q;
    ce_state_next = ce_state_current;
    case (ce_state_current) 
      CE_RELOAD: begin
        ce_state_next = (reg_read_to_engine_q == REG_PER_CE - 1) ? CE_RUNNING : CE_RELOAD;
      end
      CE_RUNNING: begin
        inner_loop_counter_d = (inner_loop_counter_q == (cntrl_engine_i.inner_loop_count - 1) && in_valid_i) ? 'b0 : inner_loop_counter_q + 1;
        ce_state_next = (inner_loop_counter_q == (cntrl_engine_i.inner_loop_count -1 ) && in_valid_i ) ? CE_RELOAD : CE_RUNNING;
      end
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      ce_state_current <= CE_RELOAD;
      inner_loop_counter_q <= 'b0;
    end else begin
      ce_state_current <= ce_state_next;
      inner_loop_counter_q <= inner_loop_counter_d;
    end
  end

  always_comb begin 
    for (int row_index = 0; row_index < Height; row_index++) begin 
      for (int col_index = 0; col_index < Width; col_index++) begin 
        ce_operands[row_index][col_index][0] = x_input_i[row_index];
        ce_operands[row_index][col_index][1] = w_input_i[col_index];
        ce_operands[row_index][col_index][2] = (ce_state_current == CE_RUNNING) ? engine_to_reg_output[row_index][col_index] : reg_out_data[row_index][col_index];
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
    if (in_valid_i) ce_clk_en = 1'b1;
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
      ope_ce   #(
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
endmodule 