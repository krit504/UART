module sipo(
    input logic clk,
    input logic rst_n,
    input logic shift_en,
    input logic serial_in,
    output logic [7:0] parallel_out
);

logic [7:0] shift_reg;
// logic [$clog2(8)-1:0] count;

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        shift_reg<=0;
    end
    else if(shift_en) begin
        shift_reg<={serial_in,shift_reg[7:1]};
    end
end

assign parallel_out=shift_reg;
endmodule