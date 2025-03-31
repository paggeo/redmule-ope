module ope_regbuffer #(
  parameter DATA_WIDTH = 8,
  parameter DEPTH = 16
) (
  input logic                      clk_i, 
  input logic                      rst_ni,
  input logic                      clear_i,
  input logic                      read_buff_i, 
  input logic                      store_buff_i,
  input  logic [$clog2(DEPTH)-1:0] addr_i
  input  logic [DATA_WIDTH-1:0]    data_i,
  output logic [DATA_WIDTH-1:0]    data_o 
);

  logic [DEPTH-1:0][DATA_WIDTH-1:0] buffer_d, buffer_q;

  always_comb begin
    buffer_d = buffer_q;
    data_o = 'b0;
    if (read_buff_i) begin
      data_o = buffer_q[addr_i];
    end else if (store_buff_i) begin
      for (int i = 0; i < DEPTH; i++) begin
        if (i == addr_i) buffer_d[i] = data_i;
        else buffer_d[i] = buffer_q[i];
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : x_cols_iters_register
    if (~rst_ni) buffer_q <= 'b0;
    else begin 
      if (clear_i) buffer_q <= 'b0;
      else buffer_q <= buffer_d;
    end
  end


endmodule: ope_regbuffer