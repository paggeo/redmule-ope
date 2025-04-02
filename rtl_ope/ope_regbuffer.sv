// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// George Pagonis
//

module ope_regbuffer #(
  parameter PINGPONG = redmule_pkg::WAIT_LOAD_FIRST,
  parameter DATA_WIDTH = 8,
  parameter DEPTH = 2
) (
  input  logic                     clk_i, 
  input  logic                     rst_ni,
  input  logic                     clear_i,
  input  logic                     iteration_change_i,
  input  logic                     read_buff_i, 
  input  logic                     store_buff_i,
  input  logic [$clog2(DEPTH)-1:0] addr_i,
  input  logic [DATA_WIDTH-1:0]    data_i,
  input  logic                     valid_i,
  output logic                     ready_o,
  output logic [DATA_WIDTH-1:0]    data_o, 
  output logic                     valid_o
);

  logic [DEPTH-1:0][DATA_WIDTH-1:0] buffer_d, buffer_q;

  // FIXME: Not sure if the counter is sufficient to do it inside, or manage by controller
  // I think this is the easiest approach
  logic [$clog2(DEPTH)-1 : 0] counter_d, counter_q;
  logic [$clog2(DEPTH)-1 : 0] prev_counter_d, prev_counter_q;


  always_comb begin 
    ready_o = 1'b1;
    if (PINGPONG == redmule_pkg::WAIT_LOAD_FIRST) begin
      if (counter_d == 1) ready_o = 1'b0;
    end else if (PINGPONG == redmule_pkg::WAIT_LOAD_LAST) begin
      if (counter_d == 0 && prev_counter_q == DEPTH-1 ) ready_o = 1'b0;
    end
  end

  always_comb begin
    buffer_d = buffer_q;
    counter_d = counter_q;
    prev_counter_d = counter_q;
    data_o = 'b0;
    valid_o = 1'b0;
    if (read_buff_i) begin
      data_o = buffer_q[addr_i];
      valid_o = 1'b1;
    end else if (store_buff_i) begin
      if (valid_i) begin
        buffer_d[counter_q] = data_i;
        counter_d = counter_q +1;
        prev_counter_d = counter_q;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin 
    if (~rst_ni) begin
      buffer_q <= 'b0;
      counter_q <= 'b0;
      prev_counter_q <= 'b0;
    end else begin 
      if (clear_i || iteration_change_i) begin
        buffer_q <= 'b0;
        counter_q <= 'b0;
        prev_counter_q <= 'b0;
      end else begin 
        buffer_q <= buffer_d;
        counter_q <= counter_d;
        prev_counter_q <= prev_counter_d;
      end
    end
  end


endmodule: ope_regbuffer