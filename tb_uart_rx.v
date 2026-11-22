// tb_uart_rx.v — self-checking testbench for uart_rx
`timescale 1ns/1ps

module tb_uart_rx;

// ---- Parameters matching DUT ----
parameter CLK_PERIOD  = 10;       // 100 MHz
parameter CLKS_PER_BIT = 868;     // 115200 baud at 100 MHz
parameter BIT_PERIOD   = CLK_PERIOD * CLKS_PER_BIT; // ns per bit

// ---- DUT signals ----
reg        clk = 0;
reg        rst = 1;
reg        rx  = 1;   // idle high
wire [7:0] data;
wire       valid;
wire       err;

// ---- Instantiate DUT ----
uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) dut (
    .clk(clk), .rst(rst), .rx(rx),
    .data(data), .valid(valid), .err(err)
);

// ---- Clock ----
always #(CLK_PERIOD/2) clk = ~clk;

// ---- Task: send one byte over serial line ----
task send_byte;
    input [7:0] byte_in;
    integer i;
    begin
        // Start bit (low)
        rx = 1'b0;
        #(BIT_PERIOD);
        // 8 data bits, LSB first
        for (i = 0; i < 8; i = i + 1) begin
            rx = byte_in[i];
            #(BIT_PERIOD);
        end
        // Stop bit (high)
        rx = 1'b1;
        #(BIT_PERIOD);
    end
endtask

// ---- Check helper ----
integer pass_cnt = 0;
integer fail_cnt = 0;

task check_byte;
    input [7:0] expected;
    begin
        // Wait for valid pulse
        @(posedge valid);
        @(posedge clk);
        if (data === expected) begin
            $display("PASS: received 0x%02X (expected 0x%02X)", data, expected);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: received 0x%02X expected 0x%02X", data, expected);
            fail_cnt = fail_cnt + 1;
        end
        if (err) begin
            $display("FAIL: unexpected framing error");
            fail_cnt = fail_cnt + 1;
        end
    end
endtask

// ---- Stimulus ----
initial begin
    $dumpfile("tb_uart_rx.vcd");
    $dumpvars(0, tb_uart_rx);

    // Reset
    @(posedge clk);
    rst = 1;
    repeat(10) @(posedge clk);
    rst = 0;
    #(BIT_PERIOD);   // idle gap

    // Test 1: send 0x55 (alternating bits 01010101)
    fork
        send_byte(8'h55);
        check_byte(8'h55);
    join

    #(BIT_PERIOD * 2);  // inter-byte gap

    // Test 2: send 0xA3 (10100011)
    fork
        send_byte(8'hA3);
        check_byte(8'hA3);
    join

    #(BIT_PERIOD * 2);

    // Test 3: send 0x00
    fork
        send_byte(8'h00);
        check_byte(8'h00);
    join

    #(BIT_PERIOD * 2);

    // Test 4: send 0xFF
    fork
        send_byte(8'hFF);
        check_byte(8'hFF);
    join

    #(BIT_PERIOD * 2);

    // Summary
    if (fail_cnt == 0)
        $display("\nALL TESTS PASSED (%0d/%0d)", pass_cnt, pass_cnt+fail_cnt);
    else
        $display("\nFAILED: %0d/%0d tests passed", pass_cnt, pass_cnt+fail_cnt);

    $finish;
end

// ---- Timeout watchdog ----
initial begin
    #(BIT_PERIOD * 100);
    $display("TIMEOUT");
    $finish;
end

endmodule