module ope_engine_reg
  import redmule_pkg::*;
#(
  parameter int unsigned   DATA_WIDTH   = BITW,
  parameter int unsigned   D            = REG_PER_CE
)(
  input  logic                  clk_i           ,
  input  logic                  rst_ni          ,
  input  logic                  flush_i         ,
  input  logic                  iteration_change_i         ,
  input  logic [DATA_WIDTH-1:0] input_i         ,
  input  logic                  in_valid_i      ,
  input  logic                  read_i          ,

  output logic [DATA_WIDTH-1:0] output_o        ,
  output logic                  out_valid_o     
);

  logic [D-1:0][DATA_WIDTH-1:0] internal_reg_d, internal_reg_q;
  logic [$clog2(D)-1:0] read_index_d, read_index_q;
  logic [$clog2(D)-1:0] write_index_d, write_index_q;

  always_comb begin
    internal_reg_d = internal_reg_q;
    read_index_d = read_index_q;
    write_index_d = write_index_q;
    output_o = 'b0;
    out_valid_o = 1'b0;

    if (in_valid_i) begin
      internal_reg_d[write_index_q] = input_i;
      write_index_d = (D > 1) ? ((write_index_q == D-1) ? '0 : write_index_q + 1) : '0;
    end

    if (read_i) begin
      output_o = internal_reg_q[read_index_q];
      out_valid_o = 1'b1;
      read_index_d = (D > 1) ? ((read_index_q == D-1) ? '0 : read_index_q + 1) : '0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      internal_reg_q <= 'b0;
      read_index_q <= 'b0;
      write_index_q <= 'b0;
    end else begin
      if (flush_i || iteration_change_i) begin
        internal_reg_q <= 'b0;
        read_index_q <= 'b0;
        write_index_q <= 'b0;
      end else begin
        internal_reg_q <= internal_reg_d;
        read_index_q <= read_index_d;
        write_index_q <= write_index_d;
      end
    end
  end

endmodule : ope_engine_reg