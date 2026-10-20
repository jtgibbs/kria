// Five ways to read a free-running 64-bit counter in the fast clock domain
// from the slow (AXI) domain. Every method produces a 64-bit value in clk_s,
// and checks in clk_s count values that can't be right.
//
//   M0  raw sample    BAD   the bus is registered straight into clk_s.
//   M1  2FF per bit   BAD   each bit gets its own 2-flop synchronizer. Looks
//                           proper, but the bits resolve independently.
//   M2  gray code     good  hand-built 64-bit gray synchronizer (xpm_cdc_gray
//                           stops at 32 bits). Needs its own constraints:
//                           constraints/cdc_gray64.xdc.
//   M3  handshake     good  xpm_cdc_handshake carries a held 64-bit snapshot.
//                           Updates every few tens of fast cycles.
//   M4  async FIFO    good  xpm_fifo_async; the fast side pushes the count
//                           every 64 cycles, so consecutive pops differ by
//                           exactly 64.
//
// Checks (counted only while en_s, cleared by clr_s):
//   M0, M1  value more than 32 counts away from M2
//   M2      steps by more than 8 in one slow cycle (fast/slow ratio is ~4)
//   M3      an update that doesn't move forward by 1..512
//   M4      a pop that isn't exactly 64 past the previous one

`timescale 1ns / 1ps

module fast_readout (
    input  wire        clk_s,
    input  wire        rst_s,
    input  wire        clk_f,
    input  wire        rst_f,
    input  wire [63:0] fcount,       // clk_f domain

    input  wire        en_s,
    input  wire        clr_s,

    output wire [63:0] m0_val,
    output wire [63:0] m1_val,
    output reg  [63:0] m2_val,
    output reg  [63:0] m3_val,
    output reg  [63:0] m4_val,

    output reg  [31:0] m0_err,
    output reg  [31:0] m1_err,
    output reg  [31:0] m2_err,
    output reg  [31:0] m3_err,
    output reg  [31:0] m4_err,
    output reg  [31:0] m3_updates,
    output reg  [31:0] m4_pops
);

    localparam integer FIFO_INTERVAL = 64;

    // ================= M0: raw sample =================
    reg [63:0] bad_f2s_m0;
    always @(posedge clk_s) bad_f2s_m0 <= fcount;
    assign m0_val = bad_f2s_m0;

    // ================= M1: 2-flop synchronizer per bit =================
    (* ASYNC_REG = "TRUE" *) reg [63:0] bad_f2s_m1_s1, bad_f2s_m1_s2;
    always @(posedge clk_s) begin
        bad_f2s_m1_s1 <= fcount;
        bad_f2s_m1_s2 <= bad_f2s_m1_s1;
    end
    assign m1_val = bad_f2s_m1_s2;

    // ================= M2: gray code =================
    // Source must be a register: gray of a counter changes one bit per step.
    reg [63:0] m2_gray_src;
    always @(posedge clk_f) m2_gray_src <= fcount ^ (fcount >> 1);

    (* ASYNC_REG = "TRUE" *) reg [63:0] m2_gray_s1, m2_gray_s2;
    reg [63:0] m2_bin;
    integer i;
    always @(*) begin
        m2_bin[63] = m2_gray_s2[63];
        for (i = 62; i >= 0; i = i - 1)
            m2_bin[i] = m2_bin[i+1] ^ m2_gray_s2[i];
    end
    always @(posedge clk_s) begin
        m2_gray_s1 <= m2_gray_src;
        m2_gray_s2 <= m2_gray_s1;
        m2_val     <= m2_bin;
    end

    // ================= M3: handshake =================
    // Hold a snapshot, send it, and take the next one as soon as it's acked.
    reg  [63:0] m3_hold;
    reg         m3_send;
    wire        m3_rcv;
    always @(posedge clk_f) begin
        if (rst_f) begin
            m3_hold <= 64'd0;
            m3_send <= 1'b0;
        end else if (!m3_send && !m3_rcv) begin
            m3_hold <= fcount;
            m3_send <= 1'b1;
        end else if (m3_send && m3_rcv) begin
            m3_send <= 1'b0;
        end
    end

    wire        m3_req;
    wire [63:0] m3_dout;
    xpm_cdc_handshake #(.DEST_EXT_HSK(0), .DEST_SYNC_FF(2), .INIT_SYNC_FF(0), .SIM_ASSERT_CHK(0),
                        .SRC_SYNC_FF(2), .WIDTH(64))
    u_m3_hsk (.src_clk(clk_f), .src_in(m3_hold), .src_send(m3_send), .src_rcv(m3_rcv),
              .dest_clk(clk_s), .dest_req(m3_req), .dest_ack(1'b0), .dest_out(m3_dout));

    // ================= M4: async FIFO =================
    reg  [5:0]  m4_div;
    wire        m4_full, m4_empty, m4_wr_busy, m4_rd_busy;
    wire [63:0] m4_dout;
    wire        m4_wr_en = (m4_div == FIFO_INTERVAL - 1) && !m4_full && !m4_wr_busy;
    wire        m4_rd_en = !m4_empty && !m4_rd_busy;
    always @(posedge clk_f) begin
        if (rst_f) m4_div <= 6'd0;
        else       m4_div <= m4_div + 6'd1;
    end

    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(16), .WRITE_DATA_WIDTH(64),
        .READ_DATA_WIDTH(64), .READ_MODE("fwft"), .FIFO_READ_LATENCY(0),
        .CDC_SYNC_STAGES(2), .RELATED_CLOCKS(0), .ECC_MODE("no_ecc"),
        .USE_ADV_FEATURES("0000"), .FULL_RESET_VALUE(0), .DOUT_RESET_VALUE("0"),
        .PROG_EMPTY_THRESH(10), .PROG_FULL_THRESH(10),
        .RD_DATA_COUNT_WIDTH(1), .WR_DATA_COUNT_WIDTH(1),
        .WAKEUP_TIME(0), .SIM_ASSERT_CHK(0)
    ) u_m4_fifo (
        .rst(rst_f), .wr_clk(clk_f), .wr_en(m4_wr_en), .din(fcount),
        .full(m4_full), .wr_rst_busy(m4_wr_busy),
        .rd_clk(clk_s), .rd_en(m4_rd_en), .dout(m4_dout),
        .empty(m4_empty), .rd_rst_busy(m4_rd_busy),
        .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
        .almost_empty(), .almost_full(), .data_valid(), .dbiterr(), .overflow(),
        .prog_empty(), .prog_full(), .rd_data_count(), .sbiterr(), .underflow(),
        .wr_ack(), .wr_data_count()
    );

    // ================= checks (clk_s) =================
    // A check only counts once its "previous value" is valid.
    reg        chk;
    reg [63:0] m2_prev;
    reg [63:0] m0_diff, m1_diff, m2_step;
    reg        m3_seen, m4_seen;
    reg        m3_upd_d, m4_pop_d;
    reg [63:0] m3_step, m4_step;

    function within32(input [63:0] d);
        within32 = (d <= 64'd32) || (d >= 64'hFFFF_FFFF_FFFF_FFE0);
    endfunction

    always @(posedge clk_s) begin
        m2_prev  <= m2_val;
        m0_diff  <= m0_val - m2_val;
        m1_diff  <= m1_val - m2_val;
        m2_step  <= m2_val - m2_prev;

        m3_upd_d <= m3_req;
        m4_pop_d <= m4_rd_en;
        if (m3_req) begin
            m3_step <= m3_dout - m3_val;
            m3_val  <= m3_dout;
        end
        if (m4_rd_en) begin
            m4_step <= m4_dout - m4_val;
            m4_val  <= m4_dout;
        end

        if (rst_s || clr_s || !en_s) begin
            chk     <= 1'b0;
            m3_seen <= 1'b0;
            m4_seen <= 1'b0;
        end else begin
            chk <= 1'b1;
            if (m3_upd_d) m3_seen <= 1'b1;
            if (m4_pop_d) m4_seen <= 1'b1;
        end

        if (rst_s || clr_s) begin
            m0_err     <= 32'd0;
            m1_err     <= 32'd0;
            m2_err     <= 32'd0;
            m3_err     <= 32'd0;
            m4_err     <= 32'd0;
            m3_updates <= 32'd0;
            m4_pops    <= 32'd0;
        end else if (en_s) begin
            if (chk && !within32(m0_diff)) m0_err <= m0_err + 32'd1;
            if (chk && !within32(m1_diff)) m1_err <= m1_err + 32'd1;
            if (chk && m2_step > 64'd8)    m2_err <= m2_err + 32'd1;
            if (m3_upd_d) begin
                m3_updates <= m3_updates + 32'd1;
                if (m3_seen && (m3_step == 64'd0 || m3_step > 64'd512)) m3_err <= m3_err + 32'd1;
            end
            if (m4_pop_d) begin
                m4_pops <= m4_pops + 32'd1;
                if (m4_seen && m4_step != FIFO_INTERVAL) m4_err <= m4_err + 32'd1;
            end
        end
    end

endmodule
