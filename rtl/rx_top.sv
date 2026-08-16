module rx_top
(
    input logic clk,
    input logic rst_n,
    input logic baud_tick,
    input logic rx,
    output logic [7:0] rx_data,
    output logic rx_done
);

state_t state;

state_t next_state;
logic sr_shift_en;
logic [3:0] tick_cnt;
logic [2:0] bit_cnt;

sipo SIPO(
    .clk(clk),
    .rst_n(rst_n),
    .shift_en(sr_shift_en),
    .serial_in(rx),
    .parallel_out(rx_data)
);

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        bit_cnt<=0;
        tick_cnt<=0;
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
        if (state==IDLE) begin
            bit_cnt <=0;
            end
        else if(state==DATA && baud_tick && tick_cnt==15 && bit_cnt<7) begin
            bit_cnt<=bit_cnt+1;
        end
    end
end

always_comb begin
    next_state=state;
    rx_done=0;
    sr_shift_en=0;

    case(state) 
        IDLE: begin
            sr_shift_en=0;
            if(!rx) begin
                next_state=START;
            end
            else next_state=IDLE;
        end

        START: begin
            sr_shift_en=0;
            if(baud_tick && tick_cnt==7) begin
                if(rx==1) begin
                    next_state=IDLE;
                end
            end
            else if(baud_tick && tick_cnt==15) begin
                next_state=DATA;
            end
        end

        DATA: begin
            if(tick_cnt==7) begin
                sr_shift_en= baud_tick;
            end
            else if(baud_tick && tick_cnt==15) begin
                if(bit_cnt<7) begin
                    next_state=DATA;
                end
                else if(bit_cnt==7) begin
                    next_state=STOP;
                end
            end
        end

        STOP: begin
            sr_shift_en=0;
            if(baud_tick && tick_cnt==15) begin
                rx_done=1;
                next_state=IDLE;
            end
        end
        default:
        next_state=IDLE;

    endcase
end
endmodule

             

