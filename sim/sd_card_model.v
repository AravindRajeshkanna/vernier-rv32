// Simulation-only model of an SD card in SPI mode - enough of the protocol
// for a first-stage bootloader to initialize it and read blocks.
//
// Commands implemented (the standard minimal init-then-read sequence):
//   CMD0  GO_IDLE_STATE        -> R1 = 0x01 (idle)
//   CMD8  SEND_IF_COND         -> R7 = 0x01, 00 00 01 AA (voltage accepted)
//   CMD55 APP_CMD              -> R1 = 0x01
//   ACMD41 SD_SEND_OP_COND     -> R1 = 0x00 (initialization complete)
//   CMD58 READ_OCR             -> R3 = 0x00, 40 FF 80 00 (CCS=1, so SDHC:
//                                 CMD17's argument is a *block* number, not
//                                 a byte offset)
//   CMD17 READ_SINGLE_BLOCK    -> R1 = 0x00, then the 0xFE data token,
//                                 512 data bytes, then two (dummy) CRC bytes
//
// Anything else answers 0x04 (illegal command). CRCs on incoming commands are
// accepted without checking, which is what a real card does once CRC mode is
// off - the host still has to *send* a valid CRC for CMD0, and the model
// tolerates whatever it sends.
//
// SPI mode 0: the host drives MOSI on the falling edge and samples MISO on
// the rising edge, so this model does the mirror image - samples MOSI on the
// rising edge and advances MISO on the falling edge.
//
// Card contents come from a $readmemh image (one byte per line). See
// software/soc/mkcard.py, which builds it.
module sd_card_model #(
    parameter CARD_BYTES = 262144,
    parameter INIT_FILE  = ""
)(
    input  wire sck,
    input  wire mosi,
    output wire miso,
    input  wire cs_n
);
    reg [7:0] card [0:CARD_BYTES-1];
    integer i;

    initial begin
        for (i = 0; i < CARD_BYTES; i = i + 1)
            card[i] = 8'h00;
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, card);
    end

    // ---- bit-level shift ----
    reg [7:0]  rx_sh;
    reg [7:0]  tx_sh = 8'hFF;
    reg [3:0]  bitcnt = 0;

    assign miso = cs_n ? 1'b1 : tx_sh[7];

    // ---- response queue ----
    // Sized for the largest single response: R1 + filler + data token +
    // 512 data bytes + 2 CRC bytes.
    localparam QSIZE = 1024;
    reg [7:0]   q [0:QSIZE-1];
    integer     qhead = 0;
    integer     qtail = 0;

    task push(input [7:0] b);
        begin
            q[qtail] = b;
            qtail = (qtail + 1) % QSIZE;
        end
    endtask

    // ---- command assembly ----
    reg [7:0]  cmdbuf [0:5];
    integer    cmdidx = 0;
    reg        in_cmd = 0;
    reg        app_cmd = 0;   // set by CMD55, so the next command is an ACMD

    task process_command;
        reg [5:0]  cmd;
        reg [31:0] arg;
        integer    base;
        integer    k;
        begin
            cmd = cmdbuf[0][5:0];
            arg = {cmdbuf[1], cmdbuf[2], cmdbuf[3], cmdbuf[4]};

            if (app_cmd && cmd == 6'd41) begin
                // ACMD41: report initialization complete immediately. A real
                // card usually needs to be polled a few times; a bootloader
                // that polls correctly works fine against an instant answer.
                push(8'h00);
                app_cmd = 0;
            end else begin
                case (cmd)
                    6'd0: begin push(8'h01); app_cmd = 0; end
                    6'd8: begin
                        push(8'h01); push(8'h00); push(8'h00); push(8'h01); push(8'hAA);
                        app_cmd = 0;
                    end
                    6'd55: begin push(8'h01); app_cmd = 1; end
                    6'd58: begin
                        push(8'h00); push(8'h40); push(8'hFF); push(8'h80); push(8'h00);
                        app_cmd = 0;
                    end
                    6'd17: begin
                        push(8'h00);   // R1: accepted
                        push(8'hFF);   // a little latency before the data token
                        push(8'hFE);   // start-of-block token
                        base = arg * 512;   // CCS=1 -> block addressing
                        for (k = 0; k < 512; k = k + 1) begin
                            if (base + k < CARD_BYTES) push(card[base + k]);
                            else                        push(8'h00);
                        end
                        push(8'hFF); push(8'hFF);  // CRC16 (not checked by the host)
                        app_cmd = 0;
                    end
                    default: begin push(8'h04); app_cmd = 0; end  // illegal command
                endcase
            end
        end
    endtask

    task byte_received(input [7:0] b);
        begin
            if (!in_cmd) begin
                // Command frames start with 01xxxxxx; everything else on the
                // wire is 0xFF filler the host sends to clock responses out.
                if (b[7:6] == 2'b01) begin
                    cmdbuf[0] = b;
                    cmdidx    = 1;
                    in_cmd    = 1;
                end
            end else begin
                cmdbuf[cmdidx] = b;
                if (cmdidx == 5) begin
                    in_cmd = 0;
                    process_command;
                end else begin
                    cmdidx = cmdidx + 1;
                end
            end
        end
    endtask

    // Sample MOSI on the rising edge (mode 0).
    always @(posedge sck) begin
        if (!cs_n) begin
            rx_sh = {rx_sh[6:0], mosi};
            if (bitcnt == 4'd7) begin
                bitcnt = 0;
                byte_received(rx_sh);
            end else begin
                bitcnt = bitcnt + 1;
            end
        end
    end

    // Advance MISO on the falling edge, reloading at each byte boundary.
    always @(negedge sck) begin
        if (!cs_n) begin
            if (bitcnt == 0) begin
                if (qhead != qtail) begin
                    tx_sh = q[qhead];
                    qhead = (qhead + 1) % QSIZE;
                end else begin
                    tx_sh = 8'hFF;   // idle / busy filler
                end
            end else begin
                tx_sh = {tx_sh[6:0], 1'b1};
            end
        end
    end

    // Deselecting the card resets the framing but not the queue contents,
    // matching a real card's behavior of abandoning a partial command.
    always @(posedge cs_n) begin
        bitcnt = 0;
        in_cmd = 0;
        cmdidx = 0;
    end
endmodule
