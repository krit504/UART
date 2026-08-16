module piso(
    input logic clk,
    input logic rst_n,
    input logic load,
    input logic en,
    input logic [7:0] load_val,
    output logic tx_data,
    output logic done
);

logic [7:0] shift_reg;
logic [$clog2(8)-1:0] count;

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        count<=0;
        shift_reg<=0;
    end
    else if(load) begin
        shift_reg<=load_val;
        count<=0;
    end
    else if(en) begin
        shift_reg<={1'b1,shift_reg[7:1]};
        count<=count+1;
    end
end

assign tx_data=shift_reg[0];
assign done=(count==3'd7);
endmodule

