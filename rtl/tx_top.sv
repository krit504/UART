module tx_top
    import typedefs::*;
(
    input logic clk,
    input logic rst_n,
    input logic baud_tick,
    input logic tx_start,
    input logic [7:0]tx_data,
    output logic tx,
    output logic tx_busy
);

state_t state;

piso PISO (
    .clk(clk),
    .rst_n(rst_n),
    .load(sr_load),
    .load_val(tx_data),
    .en(sr_en),
    .tx_data(sr_bit)
);

logic sr_load;
logic sr_en;
logic sr_bit;
logic [4:0] tick_cnt;
logic [2:0] bit_cnt;
state_t next_state;

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state<=IDLE;
    end
    else begin
        state<=next_state;

        if(state==IDLE) begin
                tick_cnt<=0;
            end

        else if(baud_tick) begin
            if(tick_cnt==15) begin
                tick_cnt<=0;
            end 

            else begin
                tick_cnt<=tick_cnt+1;
            end
        end
        if(state==IDLE) begin 
                bit_cnt <=0;
            end
        else if(sr_en) begin 
            bit_cnt<=bit_cnt+1;
        end
    end
end

always_comb begin
    sr_load=0;
    sr_en=0;
    next_state=state;
    

    case(state)
        IDLE: begin
            if(tx_start) begin
            tx=1;
            tx_busy=0;
            sr_load=1;
            next_state=START;
            end
            else begin
                tx=1;
                tx_busy=0;
                next_state=IDLE;
            end
        end
        START: begin
            tx=1'b0;
            tx_busy=1;
            if(baud_tick && tick_cnt==15) begin
                next_state=DATA;
            end
            else begin
                next_state=START;
            end
        end
        DATA: begin
            tx=sr_bit;
            tx_busy=1;
            sr_load=0;
            if(baud_tick && tick_cnt==15) begin
                if(bit_cnt<7) begin
                    sr_en=1;
                    next_state=DATA;
                end
                else if(bit_cnt==7) begin
                    sr_en=0;
                    next_state=STOP;
                end
            end
        end
        STOP: begin
            tx=1;
            tx_busy=1;
            sr_load=0;
            sr_en=0;
            if(baud_tick && tick_cnt==15) begin
                next_state=IDLE;
            end
        end
        default: 
            next_state=IDLE;
    endcase
end
endmodule









    
