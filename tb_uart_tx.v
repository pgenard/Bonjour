`timescale 1ns/1ps

module tb_uart_tx;
    reg clk = 0, rst = 1, start = 0; 
    reg[7:0] data;
    wire tx, busy, done;

    // Use CLK_HZ=10, BAUD=1 -> 10 cycles per bit for fast simulation
    uart_tx #(.CLK_HZ(10), .BAUD(1)) dut(.clk(clk), .rst(rst), .start(start), .data(data), .tx(tx), .busy(busy), .done(done));
   
    always #5 clk=~clk;
   
    integer errors = 0;
   
    task sample_bit(input exp);
        repeat(10) @(posedge clk); // wait one bit period
        #1;

        if (tx != exp) begin 
          $display("FAIL tx=%b exp=%b", tx, exp);
          errors = errors + 1;
        end
        else begin 
          $display("ok   tx=%b", tx);
	end
    endtask // sample_bit

    initial begin
        repeat(2) @(negedge clk);

        rst = 0;

        @(negedge clk);
        data = 8'h41; // 'A' = 0100_0001
        start = 1;
       
        @(negedge clk);
        start = 0;

        // Check: START(0), b0=1,b1=0,b2=0,b3=0,b4=0,b5=0,b6=1,b7=0, STOP(1)
        sample_bit(0); // START
        sample_bit(1); // bit0
        sample_bit(0); // bit1
        sample_bit(0); // bit2
        sample_bit(0); // bit3
        sample_bit(0); // bit4
        sample_bit(0); // bit5
        sample_bit(1); // bit6
        sample_bit(0); // bit7
        sample_bit(1); // STOP

        // Wait for completion
        wait(done == 1);
        #1;

        if (done != 1) begin 
          $display("FAIL done not asserted");
          errors = errors + 1;
        end
        else begin 
          $display("ok   done=1");
	end
        
        if(errors == 0) begin 
          $display("ALL TESTS PASSED"); 
        end
        else begin 
          $display("%0d FAILED", errors);
	end
       
        $finish;
    end
endmodule // tb_uart_tx
