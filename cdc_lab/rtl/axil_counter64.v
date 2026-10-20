// AXI4-Lite slave exposing a free-running 64-bit counter.
//
// Register map (32-bit registers, byte offsets):
//   0x00  ID        RO  0xCDC0_0001
//   0x04  CTRL      WO  bit0 = clear counter (self-clearing)
//   0x08  COUNT_LO  RO  counter[31:0]; reading it latches counter[63:32] into COUNT_HI
//   0x0C  COUNT_HI  RO  counter[63:32] as of the last COUNT_LO read
//   0x10  SCRATCH   RW  read/write test register
//   0x14  LED       RW  bit0 = UF2 (UF1 blinks from counter bit 26)
//
// Read COUNT_LO then COUNT_HI to get a consistent 64-bit value.

`timescale 1ns / 1ps

module axil_counter64 (
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

    output wire [1:0]  led
);

    localparam [31:0] ID_VALUE = 32'hCDC0_0001;

    localparam [11:0] REG_ID       = 12'h000;
    localparam [11:0] REG_CTRL     = 12'h004;
    localparam [11:0] REG_COUNT_LO = 12'h008;
    localparam [11:0] REG_COUNT_HI = 12'h00C;
    localparam [11:0] REG_SCRATCH  = 12'h010;
    localparam [11:0] REG_LED      = 12'h014;

    wire clk = s_axi_aclk;
    wire rst = ~s_axi_aresetn;

    reg [63:0] count;
    reg [31:0] count_hi_snap;
    reg [31:0] scratch;
    reg        clear;
    reg        led_sw;

    // UF1: ~0.75 Hz heartbeat at 100 MHz. UF2: software controlled.
    assign led = {led_sw, count[26]};

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
        end else begin
            clear <= 1'b0;

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
                        if (w_strb[0]) clear <= w_data[0];
                    REG_SCRATCH:
                        for (i = 0; i < 4; i = i + 1)
                            if (w_strb[i]) scratch[8*i +: 8] <= w_data[8*i +: 8];
                    REG_LED:
                        if (w_strb[0]) led_sw <= w_data[0];
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
                REG_ID:       s_axi_rdata <= ID_VALUE;
                REG_COUNT_LO: begin
                    s_axi_rdata   <= count[31:0];
                    count_hi_snap <= count[63:32];
                end
                REG_COUNT_HI: s_axi_rdata <= count_hi_snap;
                REG_SCRATCH:  s_axi_rdata <= scratch;
                REG_LED:      s_axi_rdata <= {31'd0, led_sw};
                default:      s_axi_rdata <= 32'd0;
            endcase
        end else if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end

endmodule
