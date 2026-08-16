`timescale 1ns/1ps

module tb_uart_top;

  localparam CLK_FREQ    = 50_000_000;
  localparam BAUD_RATE   = 115200;
  localparam OVERSAMPLE  = 16;
  localparam DIVISOR     = CLK_FREQ/(OVERSAMPLE*BAUD_RATE);
  localparam CLK_PERIOD  = 20; // 50 MHz
  localparam TICKS_PER_FRAME = 10*OVERSAMPLE; // start + 8 data + stop, 16 ticks each

  logic clk, rst_n;
  logic tx_start;
  logic [7:0] tx_data;
  logic tx, tx_busy;
  logic rx_loop;
  logic [7:0] rx_data;
  logic rx_done;

  int byte_errors = 0;
  int timing_errors = 0;
  int frames = 0;

  uart_top dut (
    .clk(clk), .rst_n(rst_n),
    .tx_start(tx_start), .tx_data(tx_data),
    .tx(tx), .tx_busy(tx_busy),
    .rx(rx_loop),
    .rx_data(rx_data), .rx_done(rx_done)
  );

  // loopback: tx line straight into rx
  assign rx_loop = tx;

  always #(CLK_PERIOD/2) clk = ~clk;

  // free-running, single-writer tick counter -- never reset mid-test, so
  // frame duration is measured as a difference and can't race a self-clear
  longint total_ticks;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) total_ticks <= 0;
    else if (dut.baud_tick) total_ticks <= total_ticks + 1;
  end

  task automatic send_and_check(logic [7:0] data);
    longint ticks_before, ticks_used;
    begin
      tx_data = data;
      tx_start <= 1'b1;
      @(posedge clk);
      tx_start <= 1'b0;

      // wait for tx to actually start driving the start bit, snapshot tick count there
      @(negedge tx);
      ticks_before = total_ticks;

      @(posedge rx_done);
      frames++;
      if (rx_data !== data) begin
        byte_errors++;
        $display("[FAIL] frame %0d: sent 8'h%02x, received 8'h%02x", frames, data, rx_data);
      end else begin
        $display("[PASS] frame %0d: sent 8'h%02x, received 8'h%02x", frames, data, rx_data);
      end

      @(negedge tx_busy);
      ticks_used = total_ticks - ticks_before;
      if (ticks_used !== TICKS_PER_FRAME) begin
        timing_errors++;
        $display("[FAIL] frame %0d: frame spanned %0d baud ticks, expected %0d (10 bit periods x 16 ticks)",
                  frames, ticks_used, TICKS_PER_FRAME);
      end

      // idle gap so rx sees a clean IDLE before next frame
      repeat (2*OVERSAMPLE*DIVISOR) @(posedge clk);
    end
  endtask

  initial begin
    $dumpfile("uart_top.vcd");
    $dumpvars(0, tb_uart_top);

    clk = 0;
    rst_n = 0;
    tx_start = 0;
    tx_data = 0;

    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    send_and_check(8'h55); // 0101_0101 - alternating
    send_and_check(8'hA5); // 1010_0101
    send_and_check(8'h00); // all zeros
    send_and_check(8'hFF); // all ones
    send_and_check(8'h01); // LSB-first sanity: single bit set at bit0
    send_and_check(8'h80); // single bit set at bit7

    $display("--------------------------------------------------");
    $display("%0d frames sent, %0d byte mismatches, %0d timing violations",
              frames, byte_errors, timing_errors);
    if (byte_errors == 0 && timing_errors == 0)
      $display("ALL FRAMES PASSED");
    else
      $display("FRAMES FAILED");

    $finish;
  end

  // watchdog
  initial begin
    #(200_000_000);
    $display("[TIMEOUT] simulation did not finish in time");
    $finish;
  end

endmodule
