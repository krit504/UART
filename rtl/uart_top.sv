module uart_top (
  input  logic clk, rst_n,
  input  logic tx_start,
  input  logic [7:0] tx_data,
  output logic tx, tx_busy,
  input  logic rx,
  output logic [7:0] rx_data,
  output logic rx_done
);
  logic baud_tick;   

  baud_gen u_baud (
    .clk(clk), .rst_n(rst_n),
    .tick(baud_tick)
  );

  tx_top u_tx (
    .clk(clk), .rst_n(rst_n),
    .baud_tick(baud_tick),        
    .tx_start(tx_start), .tx_data(tx_data),
    .tx(tx), .tx_busy(tx_busy)
  );

  rx_top u_rx (
    .clk(clk), .rst_n(rst_n),
    .baud_tick(baud_tick),        
    .rx(rx),
    .rx_data(rx_data), .rx_done(rx_done)
  );
endmodule