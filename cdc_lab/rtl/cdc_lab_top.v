// cdc_lab top level: AXI4-Lite register block in the slow clock domain, a
// free-running 64-bit counter in each clock domain, the user LEDs, the CDC
// experiments (step 2) and the fast-counter readout methods (step 3).
//
// Register map (32-bit registers, byte offsets):
//   0x00  ID            RO  0xCDC0_0002
//   0x04  CTRL          RW  bit0 = clear 64-bit counter (self-clearing, reads 0)
//                           bit1 = run CDC tests
//                           bit2 = hold CDC test counters at zero
//   0x08  COUNT_LO      RO  counter[31:0]; reading it latches counter[63:32] into COUNT_HI
//   0x0C  COUNT_HI      RO  counter[63:32] as of the last COUNT_LO read
//   0x10  SCRATCH       RW  read/write test register
//   0x14  LED           RW  bit0 = force UF2 on (UF1 = slow heartbeat, UF2 = fast heartbeat)
//   0x18  FAST_COUNT    RO  free-running clk_fast cycle count (gray-crossed)
//   0x1C  CONFIG        RO  bit0 = ASYNC_MODE build parameter
//   0x20  T1_ERR_BAD    RO  \
//   0x24  T1_ERR_GOOD   RO   |
//   0x28  T2_SENT       RO   |
//   0x2C  T2_RECV_BAD   RO   |
//   0x30  T2_RECV_GOOD  RO   |  see cdc_tests.v
//   0x34  T3_ERR_BAD    RO   |
//   0x38  T3_ERR_GOOD   RO   |
//   0x3C  T4_ERR_BAD    RO   |
//   0x40  T4_ERR_GOOD   RO   |
//   0x44  T4_RECV_GOOD  RO  /
//   0x48  SNAP          WO  write 1: capture the slow counter and every readout
//                           method's view of the fast counter in one clk_s cycle
//   0x50  SNAP_SLOW     RO  64-bit slow counter            (lo at +0, hi at +4)
//   0x58  SNAP_M0       RO  64-bit fast count, raw sample   \
//   0x60  SNAP_M1       RO  64-bit fast count, 2FF per bit   |
//   0x68  SNAP_M2       RO  64-bit fast count, gray code     |  see fast_readout.v
//   0x70  SNAP_M3       RO  64-bit fast count, handshake     |
//   0x78  SNAP_M4       RO  64-bit fast count, async FIFO   /
//   0x80  M0_ERR .. 0x90 M4_ERR   RO  readout check failures, one per method
//   0x94  M3_UPDATES    RO  handshake updates received
//   0x98  M4_POPS       RO  FIFO entries received
//
// Read COUNT_LO then COUNT_HI to get a consistent 64-bit value.

`timescale 1ns / 1ps

module cdc_lab_top #(
    parameter integer ASYNC_MODE = 0
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn" *)
    input  wire        s_axi_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire        s_axi_aresetn,

    input  wire [11:0] s_axi_awaddr,
    input  wire [2:0]  s_axi_awprot,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,

    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,

    output wire [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,

    input  wire [11:0] s_axi_araddr,
    input  wire [2:0]  s_axi_arprot,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,

    output reg  [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_fast CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_RESET fast_resetn" *)
    input  wire        clk_fast,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 fast_resetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire        fast_resetn,

    output wire [1:0]  led
);

    localparam [31:0] ID_VALUE = 32'hCDC0_0002;

    localparam [11:0] REG_ID           = 12'h000;
    localparam [11:0] REG_CTRL         = 12'h004;
    localparam [11:0] REG_COUNT_LO     = 12'h008;
    localparam [11:0] REG_COUNT_HI     = 12'h00C;
    localparam [11:0] REG_SCRATCH      = 12'h010;
    localparam [11:0] REG_LED          = 12'h014;
    localparam [11:0] REG_FAST_COUNT   = 12'h018;
    localparam [11:0] REG_CONFIG       = 12'h01C;
    localparam [11:0] REG_T1_ERR_BAD   = 12'h020;
    localparam [11:0] REG_T1_ERR_GOOD  = 12'h024;
    localparam [11:0] REG_T2_SENT      = 12'h028;
    localparam [11:0] REG_T2_RECV_BAD  = 12'h02C;
    localparam [11:0] REG_T2_RECV_GOOD = 12'h030;
    localparam [11:0] REG_T3_ERR_BAD   = 12'h034;
    localparam [11:0] REG_T3_ERR_GOOD  = 12'h038;
    localparam [11:0] REG_T4_ERR_BAD   = 12'h03C;
    localparam [11:0] REG_T4_ERR_GOOD  = 12'h040;
    localparam [11:0] REG_T4_RECV_GOOD = 12'h044;
    localparam [11:0] REG_SNAP         = 12'h048;
    localparam [11:0] REG_SNAP_BASE    = 12'h050;  // 6 x 64-bit, 0x50..0x7C
    localparam [11:0] REG_M0_ERR       = 12'h080;
    localparam [11:0] REG_M1_ERR       = 12'h084;
    localparam [11:0] REG_M2_ERR       = 12'h088;
    localparam [11:0] REG_M3_ERR       = 12'h08C;
    localparam [11:0] REG_M4_ERR       = 12'h090;
    localparam [11:0] REG_M3_UPDATES   = 12'h094;
    localparam [11:0] REG_M4_POPS      = 12'h098;

    wire clk = s_axi_aclk;
    wire rst = ~s_axi_aresetn;

    reg [63:0] count;
    reg [31:0] count_hi_snap;
    reg [31:0] scratch;
    reg        clear;
    reg        led_sw;
    reg        test_en, test_clr;
    reg        snap;

    // ---------------- fast-domain free-running counter ----------------
    wire rst_fast = ~fast_resetn;
    reg [63:0] fcount;
    always @(posedge clk_fast) begin
        if (rst_fast) fcount <= 64'd0;
        else          fcount <= fcount + 64'd1;
    end

    // ---------------- CDC experiments ----------------
    wire [31:0] fast_count;
    wire [31:0] t1_err_bad, t1_err_good;
    wire [31:0] t2_sent, t2_recv_bad, t2_recv_good;
    wire [31:0] t3_err_bad, t3_err_good;
    wire [31:0] t4_err_bad, t4_err_good, t4_recv_good;
    wire        heartbeat_fast;

    cdc_tests #(.T1_DELAY_LUTS(ASYNC_MODE ? 8 : 2)) u_tests (
        .clk_s(clk), .rst_s(rst), .clk_f(clk_fast), .rst_f(rst_fast), .fcount(fcount),
        .en_s(test_en), .clr_s(test_clr),
        .fast_count(fast_count),
        .t1_err_bad(t1_err_bad), .t1_err_good(t1_err_good),
        .t2_sent(t2_sent), .t2_recv_bad(t2_recv_bad), .t2_recv_good(t2_recv_good),
        .t3_err_bad(t3_err_bad), .t3_err_good(t3_err_good),
        .t4_err_bad(t4_err_bad), .t4_err_good(t4_err_good), .t4_recv_good(t4_recv_good),
        .heartbeat_f(heartbeat_fast)
    );

    // ---------------- fast counter readout methods ----------------
    wire [63:0] m0_val, m1_val, m2_val, m3_val, m4_val;
    wire [31:0] m0_err, m1_err, m2_err, m3_err, m4_err, m3_updates, m4_pops;

    fast_readout u_readout (
        .clk_s(clk), .rst_s(rst), .clk_f(clk_fast), .rst_f(rst_fast), .fcount(fcount),
        .en_s(test_en), .clr_s(test_clr),
        .m0_val(m0_val), .m1_val(m1_val), .m2_val(m2_val), .m3_val(m3_val), .m4_val(m4_val),
        .m0_err(m0_err), .m1_err(m1_err), .m2_err(m2_err), .m3_err(m3_err), .m4_err(m4_err),
        .m3_updates(m3_updates), .m4_pops(m4_pops)
    );

    // Snapshot: index 0 = slow counter, 1..5 = M0..M4.
    reg [63:0] snap_val [0:5];
    always @(posedge clk) begin
        if (snap) begin
            snap_val[0] <= count;
            snap_val[1] <= m0_val;
            snap_val[2] <= m1_val;
            snap_val[3] <= m2_val;
            snap_val[4] <= m3_val;
            snap_val[5] <= m4_val;
        end
    end

    // UF1: ~0.75 Hz slow-domain heartbeat. UF2: fast-domain heartbeat, or on.
    // Both drive pins directly; the LED ports are false-pathed.
    assign led = {led_sw | heartbeat_fast, count[26]};

    // ---------------- counter ----------------
    always @(posedge clk) begin
        if (rst || clear)
            count <= 64'd0;
        else
            count <= count + 64'd1;
    end

    // ---------------- write channel ----------------
    reg        aw_held, w_held;
    reg [11:0] aw_addr;
    reg [31:0] w_data;
    reg [3:0]  w_strb;

    assign s_axi_awready = ~aw_held;
    assign s_axi_wready  = ~w_held;
    assign s_axi_bresp   = 2'b00;

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            aw_held      <= 1'b0;
            w_held       <= 1'b0;
            s_axi_bvalid <= 1'b0;
            scratch      <= 32'd0;
            clear        <= 1'b0;
            led_sw       <= 1'b0;
            test_en      <= 1'b0;
            test_clr     <= 1'b0;
            snap         <= 1'b0;
        end else begin
            clear <= 1'b0;
            snap  <= 1'b0;

            if (s_axi_awvalid && s_axi_awready) begin
                aw_held <= 1'b1;
                aw_addr <= s_axi_awaddr;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                w_held <= 1'b1;
                w_data <= s_axi_wdata;
                w_strb <= s_axi_wstrb;
            end

            if (aw_held && w_held && !s_axi_bvalid) begin
                case ({aw_addr[11:2], 2'b00})
                    REG_CTRL:
                        if (w_strb[0]) begin
                            clear    <= w_data[0];
                            test_en  <= w_data[1];
                            test_clr <= w_data[2];
                        end
                    REG_SCRATCH:
                        for (i = 0; i < 4; i = i + 1)
                            if (w_strb[i]) scratch[8*i +: 8] <= w_data[8*i +: 8];
                    REG_LED:
                        if (w_strb[0]) led_sw <= w_data[0];
                    REG_SNAP:
                        if (w_strb[0]) snap <= w_data[0];
                    default: ;
                endcase
                aw_held      <= 1'b0;
                w_held       <= 1'b0;
                s_axi_bvalid <= 1'b1;
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    // ---------------- read channel ----------------
    assign s_axi_arready = ~s_axi_rvalid;
    assign s_axi_rresp   = 2'b00;

    always @(posedge clk) begin
        if (rst) begin
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= 32'd0;
            count_hi_snap <= 32'd0;
        end else if (s_axi_arvalid && s_axi_arready) begin
            s_axi_rvalid <= 1'b1;
            case ({s_axi_araddr[11:2], 2'b00})
                REG_ID:           s_axi_rdata <= ID_VALUE;
                REG_CTRL:         s_axi_rdata <= {29'd0, test_clr, test_en, 1'b0};
                REG_COUNT_LO: begin
                    s_axi_rdata   <= count[31:0];
                    count_hi_snap <= count[63:32];
                end
                REG_COUNT_HI:     s_axi_rdata <= count_hi_snap;
                REG_SCRATCH:      s_axi_rdata <= scratch;
                REG_LED:          s_axi_rdata <= {31'd0, led_sw};
                REG_FAST_COUNT:   s_axi_rdata <= fast_count;
                REG_CONFIG:       s_axi_rdata <= {31'd0, ASYNC_MODE != 0};
                REG_T1_ERR_BAD:   s_axi_rdata <= t1_err_bad;
                REG_T1_ERR_GOOD:  s_axi_rdata <= t1_err_good;
                REG_T2_SENT:      s_axi_rdata <= t2_sent;
                REG_T2_RECV_BAD:  s_axi_rdata <= t2_recv_bad;
                REG_T2_RECV_GOOD: s_axi_rdata <= t2_recv_good;
                REG_T3_ERR_BAD:   s_axi_rdata <= t3_err_bad;
                REG_T3_ERR_GOOD:  s_axi_rdata <= t3_err_good;
                REG_T4_ERR_BAD:   s_axi_rdata <= t4_err_bad;
                REG_T4_ERR_GOOD:  s_axi_rdata <= t4_err_good;
                REG_T4_RECV_GOOD: s_axi_rdata <= t4_recv_good;
                REG_M0_ERR:       s_axi_rdata <= m0_err;
                REG_M1_ERR:       s_axi_rdata <= m1_err;
                REG_M2_ERR:       s_axi_rdata <= m2_err;
                REG_M3_ERR:       s_axi_rdata <= m3_err;
                REG_M4_ERR:       s_axi_rdata <= m4_err;
                REG_M3_UPDATES:   s_axi_rdata <= m3_updates;
                REG_M4_POPS:      s_axi_rdata <= m4_pops;
                default:
                    if (s_axi_araddr >= REG_SNAP_BASE && s_axi_araddr < REG_SNAP_BASE + 12'd48)
                        s_axi_rdata <= s_axi_araddr[2]
                            ? snap_val[(s_axi_araddr - REG_SNAP_BASE) >> 3][63:32]
                            : snap_val[(s_axi_araddr - REG_SNAP_BASE) >> 3][31:0];
                    else
                        s_axi_rdata <= 32'd0;
            endcase
        end else if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end

endmodule
