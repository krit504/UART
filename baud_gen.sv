module baud_gen #(parameter baud_rate=115200,
parameter clk_freq=50_000_000,
parameter sampling_rate=16)(
    input logic clk,
    input logic rst_n,
    output logic tick
);
localparam DIVISOR = clk_freq/(sampling_rate * baud_rate);
logic [$clog2(DIVISOR)-1:0] count;

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        count<=0;
        tick<=0;
    end
    else if(count==DIVISOR-1) begin
        tick<=1;
        count<=0;
    end
    else begin
        count<= count+1;
        tick<=0;
    end
end
endmodule