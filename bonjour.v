// ============================================================
// Bonjour FPGA
//
// Board  : Lattice iCEstick
// FPGA   : iCE40HX1K
// Clock  : 12 MHz
// UART   : 115200 baud, 8N1
//
// Features:
//   - Character echo
//   - Reliable backspace
//   - RX FIFO (16 characters)
//   - TX FIFO (64 characters)
//   - Command interpreter
//   - Individual LED control
//   - All LEDs ON/OFF
//   - Bonjour command
//   - Help, status, version
//   - CR/LF support
//
// Existing modules required:
//   uart_rx.v
//   uart_tx.v
// ============================================================

`timescale 1ns/1ps

module bonjour (
    input  wire pclk,
    input  wire RXD,
    output wire TXD,
    output wire led1,
    output wire led2,
    output wire led3,
    output wire led4,
    output wire led5
);

    localparam CLK_HZ = 12000000;
    localparam BAUD   = 115200;

    // ========================================================
    // INTERNAL RESET
    // ========================================================

    reg [3:0] reset_cnt = 0;
    reg rst = 1'b1;

    always @(posedge pclk) begin
        if (reset_cnt != 15) begin
            reset_cnt <= reset_cnt + 1'b1;
            rst <= 1'b1;
        end
        else begin
            rst <= 1'b0;
        end
    end

    // ========================================================
    // UART RECEIVER
    // ========================================================

    wire[7:0] rx_data;
    wire rx_valid;
    wire rx_err;

    uart_rx #(
        .CLK_HZ(CLK_HZ),
        .BAUD(BAUD)
    ) receiver (
        .clk(pclk),
        .rst(rst),
        .rx(RXD),
        .data(rx_data),
        .valid(rx_valid),
        .err(rx_err)
    );

    // ========================================================
    // UART TRANSMITTER
    // ========================================================

    reg[7:0] tx_data;

    reg tx_start;
    wire tx_busy;
    wire tx_done;

    uart_tx #(
        .CLK_HZ(CLK_HZ),
        .BAUD(BAUD)
    ) transmitter (
        .clk(pclk),
        .rst(rst),
        .start(tx_start),
        .data(tx_data),
        .tx(TXD),
        .busy(tx_busy),
        .done(tx_done)
    );

    // ========================================================
    // LED OUTPUTS
    // ========================================================

    reg[4:0] led_reg = 0;

    assign led1 = led_reg[0];
    assign led2 = led_reg[1];
    assign led3 = led_reg[2];
    assign led4 = led_reg[3];
    assign led5 = led_reg[4];

    // ========================================================
    // RX FIFO
    //
    // 16 characters
    // Decouples UART reception from command processing.
    // ========================================================

    reg[7:0] rx_fifo [0:15];

    reg[3:0] rx_wr_ptr = 0;
    reg[3:0] rx_rd_ptr = 0;

    reg[4:0] rx_count = 0;

    reg rx_overflow = 0;

    wire rx_pop;
    wire rx_fifo_full = (rx_count == 16);
    wire rx_push = rx_valid && !rx_fifo_full;

    wire[7:0] rx_head = rx_fifo[rx_rd_ptr];

    always @(posedge pclk) begin
        if (rst) begin
            rx_wr_ptr <= 0;
            rx_rd_ptr <= 0;
            rx_count <= 0;
            rx_overflow <= 0;

        end
        else begin
            if (rx_push) begin
                rx_fifo[rx_wr_ptr] <= rx_data;
                rx_wr_ptr <= rx_wr_ptr + 1'b1;
            end
            if (rx_pop)
                rx_rd_ptr <= rx_rd_ptr + 1'b1;

            case ({rx_push, rx_pop})
                2'b10:
                    rx_count <= rx_count + 1'b1;
                2'b01:
                    rx_count <= rx_count - 1'b1;
                default:
                    rx_count <= rx_count;
            endcase

            if (rx_valid && rx_fifo_full && !rx_pop)
                rx_overflow <= 1'b1;
        end
    end

    // ========================================================
    // TX FIFO
    //
    // 64 characters
    // Buffers outgoing terminal data.
    // ========================================================

    reg[7:0] tx_fifo [0:63];

    reg[5:0] tx_wr_ptr = 0;
    reg[5:0] tx_rd_ptr = 0;

    reg[6:0] tx_count = 0;

    wire tx_pop;
    wire tx_push;

    wire tx_fifo_full = (tx_count == 64);
    wire tx_fifo_space = !tx_fifo_full || tx_pop;

    // UART reads the FIFO head.
    always @(*) begin
        tx_data = tx_fifo[tx_rd_ptr];
        tx_start = (tx_count != 0) && !tx_busy;
    end

    assign tx_pop = tx_start;

    always @(posedge pclk) begin
        if (rst) begin
            tx_wr_ptr <= 0;
            tx_rd_ptr <= 0;
            tx_count <= 0;
        end
        else begin
            if (tx_push) begin
                tx_fifo[tx_wr_ptr] <= tx_push_data;
                tx_wr_ptr <= tx_wr_ptr + 1'b1;
            end

            if (tx_pop)
                tx_rd_ptr <= tx_rd_ptr + 1'b1;

            case ({tx_push, tx_pop})
                2'b10:
                    tx_count <= tx_count + 1'b1;
                2'b01:
                    tx_count <= tx_count - 1'b1;
                default:
                    tx_count <= tx_count;
            endcase
        end
    end

    // ========================================================
    // COMMAND BUFFER
    // ========================================================

    reg[7:0] line_buf[0:15];
    reg[4:0] line_len = 0;

    reg ignore_lf = 0;

    // ========================================================
    // BACKSPACE CONTROL
    //
    // BS SPACE BS
    //
    // 3 = first BS
    // 2 = SPACE
    // 1 = second BS
    // 0 = finished
    // ========================================================

    reg[1:0] bs_pending = 0;

    // ========================================================
    // MESSAGE GENERATOR
    //
    // 0  = Startup
    // 1  = Help
    // 2  = All LEDs ON
    // 3  = All LEDs OFF
    // 4  = Status
    // 5  = Version
    // 6  = Unknown command
    // 7  = Individual LED ON
    // 8  = Individual LED OFF
    // 9  = Bonjour
    // 10 = Empty command
    // ========================================================

    reg[3:0] msg_id = 0;
    reg[3:0] msg_led = 0;

    reg[7:0] msg_idx = 0;

    reg msg_active = 0;

    // ========================================================
    // MESSAGE ROM
    // ========================================================

    function[7:0] message_char;

        input[3:0] id;
        input[7:0] idx;
        input[3:0] led_num;

        begin
            message_char = 0;

            case (id)
                // --------------------------------------------
                // STARTUP
                // --------------------------------------------

                0: case (idx)
                    0: message_char = "B";
                    1: message_char = "o";
                    2: message_char = "n";
                    3: message_char = "j";
                    4: message_char = "o";
                    5: message_char = "u";
                    6: message_char = "r";
                    7: message_char = " ";
                    8: message_char = "F";
                    9: message_char = "P";
                    10: message_char = "G";
                    11: message_char = "A";
                    12: message_char = " ";
                    13: message_char = "v";
                    14: message_char = "1";
                    15: message_char = ".";
                    16: message_char = "4";
                    17: message_char = 13;
                    18: message_char = 10;
                    19: message_char = "i";
                    20: message_char = "C";
                    21: message_char = "E";
                    22: message_char = "s";
                    23: message_char = "t";
                    24: message_char = "i";
                    25: message_char = "c";
                    26: message_char = "k";
                    27: message_char = " ";
                    28: message_char = "-";
                    29: message_char = " ";
                    30: message_char = "1";
                    31: message_char = "2";
                    32: message_char = " ";
                    33: message_char = "M";
                    34: message_char = "H";
                    35: message_char = "z";
                    36: message_char = 13;
                    37: message_char = 10;
                    38: message_char = "U";
                    39: message_char = "A";
                    40: message_char = "R";
                    41: message_char = "T";
                    42: message_char = " ";
                    43: message_char = "1";
                    44: message_char = "1";
                    45: message_char = "5";
                    46: message_char = "2";
                    47: message_char = "0";
                    48: message_char = "0";
                    49: message_char = " ";
                    50: message_char = "8";
                    51: message_char = "N";
                    52: message_char = "1";
                    53: message_char = 13;
                    54: message_char = 10;
                    55: message_char = 13;
                    56: message_char = 10;
                    57: message_char = ">";
                    58: message_char = " ";
                endcase

                // --------------------------------------------
                // HELP
                // --------------------------------------------

                1: case (idx)
                    0: message_char = 13;
                    1: message_char = 10;
                    2: message_char = "C";
                    3: message_char = "o";
                    4: message_char = "m";
                    5: message_char = "m";
                    6: message_char = "a";
                    7: message_char = "n";
                    8: message_char = "d";
                    9: message_char = "s";
                    10: message_char = ":";
                    11: message_char = 13;
                    12: message_char = 10;
                    13: message_char = " ";
                    14: message_char = " ";
                    15: message_char = "h";
                    16: message_char = "e";
                    17: message_char = "l";
                    18: message_char = "p";
                    19: message_char = 13;
                    20: message_char = 10;
                    21: message_char = " ";
                    22: message_char = " ";
                    23: message_char = "b";
                    24: message_char = "o";
                    25: message_char = "n";
                    26: message_char = "j";
                    27: message_char = "o";
                    28: message_char = "u";
                    29: message_char = "r";
                    30: message_char = 13;
                    31: message_char = 10;
                    32: message_char = " ";
                    33: message_char = " ";
                    34: message_char = "l";
                    35: message_char = "e";
                    36: message_char = "d";
                    37: message_char = " ";
                    38: message_char = "o";
                    39: message_char = "n";
                    40: message_char = "/";
                    41: message_char = "o";
                    42: message_char = "f";
                    43: message_char = "f";
                    44: message_char = 13;
                    45: message_char = 10;
                    46: message_char = " ";
                    47: message_char = " ";
                    48: message_char = "l";
                    49: message_char = "e";
                    50: message_char = "d";
                    51: message_char = " ";
                    52: message_char = "N";
                    53: message_char = " ";
                    54: message_char = "o";
                    55: message_char = "n";
                    56: message_char = "/";
                    57: message_char = "o";
                    58: message_char = "f";
                    59: message_char = "f";
                    60: message_char = 13;
                    61: message_char = 10;
                    62: message_char = " ";
                    63: message_char = " ";
                    64: message_char = "s";
                    65: message_char = "t";
                    66: message_char = "a";
                    67: message_char = "t";
                    68: message_char = "u";
                    69: message_char = "s";
                    70: message_char = 13;
                    71: message_char = 10;
                    72: message_char = " ";
                    73: message_char = " ";
                    74: message_char = "v";
                    75: message_char = "e";
                    76: message_char = "r";
                    77: message_char = "s";
                    78: message_char = "i";
                    79: message_char = "o";
                    80: message_char = "n";
                    81: message_char = 13;
                    82: message_char = 10;
                    83: message_char = 13;
                    84: message_char = 10;
                    85: message_char = ">";
                    86: message_char = " ";
                endcase

                // --------------------------------------------
                // ALL LEDS ON
                // --------------------------------------------

                2: case (idx)
                    0: message_char = 13;
                    1: message_char = 10;
                    2: message_char = "L";
                    3: message_char = "E";
                    4: message_char = "D";
                    5: message_char = "s";
                    6: message_char = " ";
                    7: message_char = "O";
                    8: message_char = "N";
                    9: message_char = 13;
                    10: message_char = 10;
                    11: message_char = ">";
                    12: message_char = " ";
                endcase

                // --------------------------------------------
                // ALL LEDS OFF
                // --------------------------------------------

                3: case (idx)
                    0: message_char = 13;
                    1: message_char = 10;
                    2: message_char = "L";
                    3: message_char = "E";
                    4: message_char = "D";
                    5: message_char = "s";
                    6: message_char = " ";
                    7: message_char = "O";
                    8: message_char = "F";
                    9: message_char = "F";
                    10: message_char = 13;
                    11: message_char = 10;
                    12: message_char = ">";
                    13: message_char = " ";
                endcase

                // --------------------------------------------
                // STATUS
                // --------------------------------------------

                4: case (idx)
                    0: message_char = 13;
                    1: message_char = 10;
                    2: message_char = "F";
                    3: message_char = "P";
                    4: message_char = "G";
                    5: message_char = "A";
                    6: message_char = ":";
                    7: message_char = " ";
                    8: message_char = "i";
                    9: message_char = "C";
                    10: message_char = "E";
                    11: message_char = "4";
                    12: message_char = "0";
                    13: message_char = "H";
                    14: message_char = "X";
                    15: message_char = "1";
                    16: message_char = "K";
                    17: message_char = 13;
                    18: message_char = 10;
                    19: message_char = "C";
                    20: message_char = "l";
                    21: message_char = "o";
                    22: message_char = "c";
                    23: message_char = "k";
                    24: message_char = ":";
                    25: message_char = " ";
                    26: message_char = "1";
                    27: message_char = "2";
                    28: message_char = " ";
                    29: message_char = "M";
                    30: message_char = "H";
                    31: message_char = "z";
                    32: message_char = 13;
                    33: message_char = 10;
                    34: message_char = "U";
                    35: message_char = "A";
                    36: message_char = "R";
                    37: message_char = "T";
                    38: message_char = ":";
                    39: message_char = " ";
                    40: message_char = "1";
                    41: message_char = "1";
                    42: message_char = "5";
                    43: message_char = "2";
                    44: message_char = "0";
                    45: message_char = "0";
                    46: message_char = 13;
                    47: message_char = 10;
                    48: message_char = ">";
                    49: message_char = " ";
                endcase

                // --------------------------------------------
                // VERSION
                // --------------------------------------------

                5: case (idx)
                    0: message_char = 13;
                    1: message_char = 10;
                    2: message_char = "B";
                    3: message_char = "o";
                    4: message_char = "n";
                    5: message_char = "j";
                    6: message_char = "o";
                    7: message_char = "u";
                    8: message_char = "r";
                    9: message_char = " ";
                    10: message_char = "F";
                    11: message_char = "P";
                    12: message_char = "G";
                    13: message_char = "A";
                    14: message_char = " ";
                    15: message_char = "v";
                    16: message_char = "1";
                    17: message_char = ".";
                    18: message_char = "4";
                    19: message_char = 13;
                    20: message_char = 10;
                    21: message_char = ">";
                    22: message_char = " ";
                endcase

                // --------------------------------------------
                // UNKNOWN COMMAND
                // --------------------------------------------

                6: case (idx)
                    0: message_char = 13;
                    1: message_char = 10;
                    2: message_char = "U";
                    3: message_char = "n";
                    4: message_char = "k";
                    5: message_char = "n";
                    6: message_char = "o";
                    7: message_char = "w";
                    8: message_char = "n";
                    9: message_char = " ";
                    10: message_char = "c";
                    11: message_char = "o";
                    12: message_char = "m";
                    13: message_char = "m";
                    14: message_char = "a";
                    15: message_char = "n";
                    16: message_char = "d";
                    17: message_char = ".";
                    18: message_char = 13;
                    19: message_char = 10;
                    20: message_char = ">";
                    21: message_char = " ";
                endcase

                // --------------------------------------------
                // INDIVIDUAL LED ON
                // --------------------------------------------

                7: case (idx)
                    0: message_char = 13;
                    1: message_char = 10;
                    2: message_char = "L";
                    3: message_char = "E";
                    4: message_char = "D";
                    5: message_char = led_num + 8'h30;
                    6: message_char = " ";
                    7: message_char = "O";
                    8: message_char = "N";
                    9: message_char = 13;
                    10: message_char = 10;
                    11: message_char = ">";
                    12: message_char = " ";
                endcase

                // --------------------------------------------
                // INDIVIDUAL LED OFF
                // --------------------------------------------

                8: case (idx)
                    0: message_char = 13;
                    1: message_char = 10;
                    2: message_char = "L";
                    3: message_char = "E";
                    4: message_char = "D";
                    5: message_char = led_num + 8'h30;
                    6: message_char = " ";
                    7: message_char = "O";
                    8: message_char = "F";
                    9: message_char = "F";
                    10: message_char = 13;
                    11: message_char = 10;
                    12: message_char = ">";
                    13: message_char = " ";
                endcase

                // --------------------------------------------
                // BONJOUR
                // --------------------------------------------

                9: case (idx)
                    0: message_char = 13;
                    1: message_char = 10;
                    2: message_char = "B";
                    3: message_char = "o";
                    4: message_char = "n";
                    5: message_char = "j";
                    6: message_char = "o";
                    7: message_char = "u";
                    8: message_char = "r";
                    9: message_char = "!";
                    10: message_char = 13;
                    11: message_char = 10;
                    12: message_char = "W";
                    13: message_char = "e";
                    14: message_char = "l";
                    15: message_char = "c";
                    16: message_char = "o";
                    17: message_char = "m";
                    18: message_char = "e";
                    19: message_char = " ";
                    20: message_char = "t";
                    21: message_char = "o";
                    22: message_char = " ";
                    23: message_char = "B";
                    24: message_char = "o";
                    25: message_char = "n";
                    26: message_char = "j";
                    27: message_char = "o";
                    28: message_char = "u";
                    29: message_char = "r";
                    30: message_char = " ";
                    31: message_char = "F";
                    32: message_char = "P";
                    33: message_char = "G";
                    34: message_char = "A";
                    35: message_char = ".";
                    36: message_char = 13;
                    37: message_char = 10;
                    38: message_char = "T";
                    39: message_char = "y";
                    40: message_char = "p";
                    41: message_char = "e";
                    42: message_char = " ";
                    43: message_char = "'";
                    44: message_char = "h";
                    45: message_char = "e";
                    46: message_char = "l";
                    47: message_char = "p";
                    48: message_char = "'";
                    49: message_char = " ";
                    50: message_char = "f";
                    51: message_char = "o";
                    52: message_char = "r";
                    53: message_char = " ";
                    54: message_char = "c";
                    55: message_char = "o";
                    56: message_char = "m";
                    57: message_char = "m";
                    58: message_char = "a";
                    59: message_char = "n";
                    60: message_char = "d";
                    61: message_char = "s";
                    62: message_char = ".";
                    63: message_char = 13;
                    64: message_char = 10;
                    65: message_char = 13;
                    66: message_char = 10;
                    67: message_char = ">";
                    68: message_char = " ";
                endcase

                // --------------------------------------------
                // EMPTY COMMAND
                // --------------------------------------------

                10: case (idx)
                    0: message_char = 13;
                    1: message_char = 10;
                    2: message_char = ">";
                    3: message_char = " ";
                endcase
            endcase
        end
    endfunction // message_char

    wire[7:0] msg_char =
        message_char(msg_id, msg_idx, msg_led);

    // ========================================================
    // TX FIFO INPUT ARBITER
    //
    // Priority:
    //   1. Command response
    //   2. Backspace sequence
    //   3. Character echo
    // ========================================================

    reg[7:0] tx_push_data;

    reg tx_push;
    reg push_bs;
    reg push_msg;

    always @(*) begin
        tx_push = 0;
        tx_push_data = 0;
        push_bs = 0;
        push_msg = 0;

        if (tx_fifo_space) begin
            if (msg_active && msg_char != 0) begin
                tx_push = 1;
                tx_push_data = msg_char;
                push_msg = 1;

            end
            else if (bs_pending != 0) begin
                tx_push = 1;
                push_bs = 1;

                case (bs_pending)
                    3: tx_push_data = 8'h08;
                    2: tx_push_data = 8'h20;
                    1: tx_push_data = 8'h08;
                    default: tx_push_data = 0;
                endcase

            end
            else if (rx_pop &&
                     rx_head >= 8'h20 &&
                     rx_head <= 8'h7E) begin

                tx_push = 1;
                tx_push_data = rx_head;
            end
        end
    end

    // ========================================================
    // RX FIFO POP CONTROL
    //
    // Do not consume received characters while:
    //   - A response is being generated.
    //   - Backspace is being transmitted.
    //   - TX FIFO has no available space.
    // ========================================================

    assign rx_pop =
        (rx_count != 0) &&
        !msg_active &&
        (bs_pending == 0) &&
        tx_fifo_space;

    // ========================================================
    // COMMAND PROCESSOR
    // ========================================================

    always @(posedge pclk) begin
        if (rst) begin
            line_len <= 0;
            ignore_lf <= 0;

            led_reg <= 0;

            msg_id <= 0;
            msg_led <= 0;
            msg_idx <= 0;

            msg_active <= 1;

            bs_pending <= 0;
        end
        else begin

            // -----------------------------------------------
            // MESSAGE GENERATOR
            // -----------------------------------------------

            if (push_msg)
                msg_idx <= msg_idx + 1'b1;

            if (msg_active && msg_char == 0) begin
                msg_active <= 0;
                msg_idx <= 0;
            end

            // -----------------------------------------------
            // BACKSPACE TRANSMISSION
            // -----------------------------------------------

            if (push_bs)
                bs_pending <= bs_pending - 1'b1;

            // -----------------------------------------------
            // RECEIVE CHARACTER
            // -----------------------------------------------

            if (rx_pop) begin

                // -------------------------------------------
                // CR/LF HANDLING
                // -------------------------------------------

                if (ignore_lf && rx_head == 8'h0A) begin
                    ignore_lf <= 0;
                end

                else begin
                    ignore_lf <= 0;

                    // ---------------------------------------
                    // ENTER
                    // ---------------------------------------

                    if (rx_head == 8'h0D ||
                        rx_head == 8'h0A) begin

                        if (rx_head == 8'h0D)
                            ignore_lf <= 1;

                        line_len <= 0;

                        msg_idx <= 0;
                        msg_led <= 0;
                        msg_active <= 1;

                        if (line_len == 0) begin
                            msg_id <= 10;
                        end

                        // -----------------------------------
                        // HELP
                        // -----------------------------------

                        else if (line_len == 4 &&
                            line_buf[0] == "h" &&
                            line_buf[1] == "e" &&
                            line_buf[2] == "l" &&
                            line_buf[3] == "p") begin

                            msg_id <= 1;
                        end

                        // -----------------------------------
                        // BONJOUR
                        // -----------------------------------

                        else if (line_len == 7 &&
                            line_buf[0] == "b" &&
                            line_buf[1] == "o" &&
                            line_buf[2] == "n" &&
                            line_buf[3] == "j" &&
                            line_buf[4] == "o" &&
                            line_buf[5] == "u" &&
                            line_buf[6] == "r") begin

                            msg_id <= 9;
                        end

                        // -----------------------------------
                        // ALL LEDS ON
                        // -----------------------------------

                        else if (line_len == 6 &&
                            line_buf[0] == "l" &&
                            line_buf[1] == "e" &&
                            line_buf[2] == "d" &&
                            line_buf[3] == " " &&
                            line_buf[4] == "o" &&
                            line_buf[5] == "n") begin

                            led_reg <= 5'b11111;
                            msg_id <= 2;

                        end

                        // -----------------------------------
                        // ALL LEDS OFF
                        // -----------------------------------

                        else if (line_len == 7 &&
                            line_buf[0] == "l" &&
                            line_buf[1] == "e" &&
                            line_buf[2] == "d" &&
                            line_buf[3] == " " &&
                            line_buf[4] == "o" &&
                            line_buf[5] == "f" &&
                            line_buf[6] == "f") begin

                            led_reg <= 5'b00000;
                            msg_id <= 3;
                        end

                        // -----------------------------------
                        // INDIVIDUAL LED ON
                        // led N on
                        // -----------------------------------

                        else if (line_len == 8 &&
                            line_buf[0] == "l" &&
                            line_buf[1] == "e" &&
                            line_buf[2] == "d" &&
                            line_buf[3] == " " &&
                            line_buf[5] == " " &&
                            line_buf[6] == "o" &&
                            line_buf[7] == "n") begin

                            case (line_buf[4])

                                "1": begin
                                    led_reg[0] <= 1'b1;
                                    msg_led <= 1;
                                    msg_id <= 7;
                                end

                                "2": begin
                                    led_reg[1] <= 1'b1;
                                    msg_led <= 2;
                                    msg_id <= 7;
                                end

                                "3": begin
                                    led_reg[2] <= 1'b1;
                                    msg_led <= 3;
                                    msg_id <= 7;
                                end

                                "4": begin
                                    led_reg[3] <= 1'b1;
                                    msg_led <= 4;
                                    msg_id <= 7;
                                end

                                "5": begin
                                    led_reg[4] <= 1'b1;
                                    msg_led <= 5;
                                    msg_id <= 7;
                                end

                                default: msg_id <= 6;
                            endcase
                        end

                        // -----------------------------------
                        // INDIVIDUAL LED OFF
                        // led N off
                        // -----------------------------------

                        else if (line_len == 9 &&
                            line_buf[0] == "l" &&
                            line_buf[1] == "e" &&
                            line_buf[2] == "d" &&
                            line_buf[3] == " " &&
                            line_buf[5] == " " &&
                            line_buf[6] == "o" &&
                            line_buf[7] == "f" &&
                            line_buf[8] == "f") begin

                            case (line_buf[4])

                                "1": begin
                                    led_reg[0] <= 1'b0;
                                    msg_led <= 1;
                                    msg_id <= 8;
                                end

                                "2": begin
                                    led_reg[1] <= 1'b0;
                                    msg_led <= 2;
                                    msg_id <= 8;
                                end

                                "3": begin
                                    led_reg[2] <= 1'b0;
                                    msg_led <= 3;
                                    msg_id <= 8;
                                end

                                "4": begin
                                    led_reg[3] <= 1'b0;
                                    msg_led <= 4;
                                    msg_id <= 8;
                                end

                                "5": begin
                                    led_reg[4] <= 1'b0;
                                    msg_led <= 5;
                                    msg_id <= 8;
                                end

                                default: msg_id <= 6;
                            endcase
                        end

                        // -----------------------------------
                        // STATUS
                        // -----------------------------------

                        else if (line_len == 6 &&
                            line_buf[0] == "s" &&
                            line_buf[1] == "t" &&
                            line_buf[2] == "a" &&
                            line_buf[3] == "t" &&
                            line_buf[4] == "u" &&
                            line_buf[5] == "s") begin

                            msg_id <= 4;
                        end

                        // -----------------------------------
                        // VERSION
                        // -----------------------------------

                        else if (line_len == 7 &&
                            line_buf[0] == "v" &&
                            line_buf[1] == "e" &&
                            line_buf[2] == "r" &&
                            line_buf[3] == "s" &&
                            line_buf[4] == "i" &&
                            line_buf[5] == "o" &&
                            line_buf[6] == "n") begin

                            msg_id <= 5;
                        end

                        // -----------------------------------
                        // UNKNOWN COMMAND
                        // -----------------------------------

                        else begin
                            msg_id <= 6;
                        end
                    end

                    // ---------------------------------------
                    // BACKSPACE / DELETE
                    // ---------------------------------------

                    else if (rx_head == 8'h08 ||
                             rx_head == 8'h7F) begin
                        if (line_len != 0) begin
                            line_len <= line_len - 1'b1;
                            bs_pending <= 3;
                        end
                    end

                    // ---------------------------------------
                    // PRINTABLE CHARACTER
                    // ---------------------------------------

                    else if (rx_head >= 8'h20 &&
                             rx_head <= 8'h7E) begin
                        if (line_len < 16) begin
                            line_buf[line_len[3:0]] <= rx_head;
                            line_len <= line_len + 1'b1;
                        end
                    end
                end
            end
        end
    end

endmodule // bonjour
