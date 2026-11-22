// UART Receiver — 8N1 // Target: iCE40HX1K (iCEstick) // Clock: 12 MHz // Baud: 115200 // Fractional half-bit timing using a phase accumulator

`timescale 1ns/1ps

module uart_rx #( 
  parameter CLK_HZ = 12000000, 
  parameter BAUD = 115200) ( 
  input wire clk, 
  input wire rst, 
  input wire rx, 
  output reg[7:0] data, 
  output reg valid, 
  output reg err 
);

localparam IDLE  = 2'd0;
localparam START = 2'd1;
localparam DATA  = 2'd2;
localparam STOP  = 2'd3;

// Generate one timing event every half UART bit.
// Average interval = CLK_HZ / (2 * BAUD).

localparam [31:0] HALF_BIT_INC = ((64'd2 * BAUD * 64'd4294967296) + (CLK_HZ/2)) / CLK_HZ;

reg[31:0] phase_acc;
wire[32:0] phase_sum;

assign phase_sum = {1'b0, phase_acc} + {1'b0, HALF_BIT_INC};

wire half_tick = phase_sum[32];

// UART input synchronizer

reg rx_s1;
reg rx_s2;

always @(posedge clk) begin
    if (rst) begin
        rx_s1 <= 1'b1;
        rx_s2 <= 1'b1;
    end
    else begin
        rx_s1 <= rx;
        rx_s2 <= rx_s1;
    end
end

// Receiver state

reg [1:0] state = IDLE;

reg half_count;
reg [2:0] bit_idx;
reg [7:0] shift_reg;

always @(posedge clk) begin

    if (rst) begin
        state      <= IDLE;
        phase_acc  <= 0;
        half_count <= 0;
        bit_idx    <= 0;
        shift_reg  <= 0;
        data       <= 0;
        valid      <= 0;
        err        <= 0;
    end
    else begin
        valid <= 0;
        err   <= 0;

        case (state)
            // -------------------------
            // IDLE
            // -------------------------

            IDLE: begin
                phase_acc  <= 0;
                half_count <= 0;

                if (!rx_s2) begin
                    state     <= START;
                    phase_acc <= 0;
                end
            end

            // -------------------------
            // START BIT
            // Sample at half-bit centre
            // -------------------------

            START: begin
                phase_acc <= phase_sum[31:0];

                if (half_tick) begin

                    if (!rx_s2) begin
                        state      <= DATA;
                        bit_idx    <= 0;
                        half_count <= 0;
                    end
                    else begin
                        state <= IDLE;
                    end
                end
            end

            // -------------------------
            // DATA BITS
            // LSB first
            // -------------------------

            DATA: begin
                phase_acc <= phase_sum[31:0];

                if (half_tick) begin
                    if (half_count) begin
                        half_count <= 0;

                        shift_reg <= {
                            rx_s2,
                            shift_reg[7:1]
                        };

                        if (bit_idx == 3'd7) begin
                            state <= STOP;
                        end
                        else begin
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end
                    else begin
                        half_count <= 1;
                    end
                end
            end

            // -------------------------
            // STOP BIT
            // -------------------------

            STOP: begin
                phase_acc <= phase_sum[31:0];

                if (half_tick) begin
                    if (half_count) begin
                        half_count <= 0;
                        state <= IDLE;

                        if (rx_s2) begin
                            data  <= shift_reg;
                            valid <= 1'b1;
                        end
                        else begin
                            err <= 1'b1;
                        end
                    end
                    else begin
                        half_count <= 1;
                    end
                end
            end

            default: begin
                state <= IDLE;
                phase_acc <= 0;
            end
        endcase
    end
end

endmodule // uart_rx
