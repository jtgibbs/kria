// Clock-domain-crossing experiments between a slow clock (clk_s, 100 MHz)
// and a fast clock (clk_f, ~4x). Each test has an improper ("bad_") and a
// proper (XPM-based) version side by side, with counters to compare them.
//
// Naming: registers that capture a signal from the *other* domain without a
// proper CDC structure are named bad_s2f_* (captured in clk_f) or bad_f2s_*
// (captured in clk_s). constraints/async/bad_paths.xdc keys off these names.
//
//   T1  1-bit level, slow -> fast. One async signal captured by two flops with
//       different routing delay. Bad: raw signal into both flops; they
//       disagree whenever the edge lands between their arrival times.
//       Good: xpm_cdc_single first, then fan out. Counts disagreements.
//   T2  1-cycle pulse, fast -> slow. Bad: a textbook 2-flop synchronizer,
//       which misses pulses shorter than the slow period. Good: xpm_cdc_pulse.
//       Compare received counts with t2_sent.
//   T3  16-bit counter, fast -> slow. Bad: each bit through its own 2-flop
//       synchronizer (binary). Good: xpm_cdc_gray. Bad errors = samples more
//       than 2 counts away from the gray-crossed value; good errors = gray
//       samples that step by more than 6 per slow cycle.
//   T4  32-bit word {~x, x}, slow -> fast. Bad: per-bit 2-flop capture of the
//       bus. Good: xpm_cdc_handshake. Errors = words where hi != ~lo.
//
// Fast-domain counters are carried to clk_s with xpm_cdc_gray. They step by
// at most one per clk_f cycle, except when cleared; clear only while stopped.

`timescale 1ns / 1ps

module cdc_tests #(
    // LUT buffers between the two T1 capture flops. The failure window is
    // their delay difference; in async mode the false-pathed route can pack
    // two LUTs to within ~50 ps, so use more there. In sync mode the path is
    // timed at 2.5 ns and longer chains fail timing.
    parameter integer T1_DELAY_LUTS = 2
) (
    input  wire        clk_s,
    input  wire        rst_s,
    input  wire        clk_f,
    input  wire        rst_f,

    input  wire        en_s,       // run the tests
    input  wire        clr_s,      // hold test counters at zero

    output wire [31:0] fast_count, // free-running clk_f cycle count
    output wire [31:0] t1_err_bad,
    output wire [31:0] t1_err_good,
    output wire [31:0] t2_sent,
    output reg  [31:0] t2_recv_bad,
    output reg  [31:0] t2_recv_good,
    output reg  [31:0] t3_err_bad,
    output reg  [31:0] t3_err_good,
    output wire [31:0] t4_err_bad,
    output wire [31:0] t4_err_good,
    output wire [31:0] t4_recv_good,

    output wire        heartbeat_f
);

    // ---------------- controls into clk_f ----------------
    wire en_f, clr_f;

    xpm_cdc_single #(.DEST_SYNC_FF(2), .INIT_SYNC_FF(0), .SIM_ASSERT_CHK(0), .SRC_INPUT_REG(1))
    u_en_sync (.src_clk(clk_s), .src_in(en_s), .dest_clk(clk_f), .dest_out(en_f));

    xpm_cdc_single #(.DEST_SYNC_FF(2), .INIT_SYNC_FF(0), .SIM_ASSERT_CHK(0), .SRC_INPUT_REG(1))
    u_clr_sync (.src_clk(clk_s), .src_in(clr_s), .dest_clk(clk_f), .dest_out(clr_f));

    // ---------------- free-running fast counter ----------------
    reg [31:0] fcount;
    always @(posedge clk_f) begin
        if (rst_f) fcount <= 32'd0;
        else       fcount <= fcount + 32'd1;
    end
    assign heartbeat_f = fcount[28];  // ~0.75 Hz at 400 MHz

    gray_count_xfer u_fcount_x (.src_clk(clk_f), .src_cnt(fcount), .dest_clk(clk_s), .dest_cnt(fast_count));

    // ================= T1: 1-bit level, slow -> fast =================
    reg t1_src;
    always @(posedge clk_s) begin
        if (rst_s)     t1_src <= 1'b0;
        else if (en_s) t1_src <= ~t1_src;
    end

    // Bad: raw async input fans out to two flops, one behind extra LUT delay.
    wire t1_src_dly;
    lut_delay #(.N(T1_DELAY_LUTS)) u_t1_bad_dly (.i(t1_src), .o(t1_src_dly));

    reg bad_s2f_t1_a, bad_s2f_t1_b;
    reg t1_bad_hit;
    reg [31:0] t1_bad_cnt;
    always @(posedge clk_f) begin
        bad_s2f_t1_a <= t1_src;
        bad_s2f_t1_b <= t1_src_dly;
        t1_bad_hit   <= bad_s2f_t1_a ^ bad_s2f_t1_b;
        if (rst_f || clr_f)  t1_bad_cnt <= 32'd0;
        else if (t1_bad_hit) t1_bad_cnt <= t1_bad_cnt + 32'd1;
    end

    // Good: synchronize once, then fan out through the same delay structure.
    wire t1_sync, t1_sync_dly;
    xpm_cdc_single #(.DEST_SYNC_FF(2), .INIT_SYNC_FF(0), .SIM_ASSERT_CHK(0), .SRC_INPUT_REG(0))
    u_t1_sync (.src_clk(clk_s), .src_in(t1_src), .dest_clk(clk_f), .dest_out(t1_sync));
    lut_delay #(.N(T1_DELAY_LUTS)) u_t1_good_dly (.i(t1_sync), .o(t1_sync_dly));

    reg t1_good_a, t1_good_b;
    reg t1_good_hit;
    reg [31:0] t1_good_cnt;
    always @(posedge clk_f) begin
        t1_good_a   <= t1_sync;
        t1_good_b   <= t1_sync_dly;
        t1_good_hit <= t1_good_a ^ t1_good_b;
        if (rst_f || clr_f)   t1_good_cnt <= 32'd0;
        else if (t1_good_hit) t1_good_cnt <= t1_good_cnt + 32'd1;
    end

    gray_count_xfer u_t1_bad_x  (.src_clk(clk_f), .src_cnt(t1_bad_cnt),  .dest_clk(clk_s), .dest_cnt(t1_err_bad));
    gray_count_xfer u_t1_good_x (.src_clk(clk_f), .src_cnt(t1_good_cnt), .dest_clk(clk_s), .dest_cnt(t1_err_good));

    // ================= T2: 1-cycle pulse, fast -> slow =================
    // One pulse every 37 clk_f cycles; 37 is not a multiple of 4, so in sync
    // mode the pulse walks through every phase of the slow clock.
    reg [5:0]  t2_gap;
    reg        t2_pulse;
    reg [31:0] t2_sent_cnt;
    always @(posedge clk_f) begin
        if (rst_f || clr_f) begin
            t2_gap      <= 6'd0;
            t2_pulse    <= 1'b0;
            t2_sent_cnt <= 32'd0;
        end else begin
            t2_pulse <= 1'b0;
            if (en_f) begin
                if (t2_gap == 6'd36) begin
                    t2_gap      <= 6'd0;
                    t2_pulse    <= 1'b1;
                    t2_sent_cnt <= t2_sent_cnt + 32'd1;
                end else begin
                    t2_gap <= t2_gap + 6'd1;
                end
            end
        end
    end
    gray_count_xfer u_t2_sent_x (.src_clk(clk_f), .src_cnt(t2_sent_cnt), .dest_clk(clk_s), .dest_cnt(t2_sent));

    // Bad: a correct-looking 2-flop synchronizer on a too-short pulse.
    (* ASYNC_REG = "TRUE" *) reg bad_f2s_t2_s1, bad_f2s_t2_s2;
    reg t2_bad_s3;
    always @(posedge clk_s) begin
        bad_f2s_t2_s1 <= t2_pulse;
        bad_f2s_t2_s2 <= bad_f2s_t2_s1;
        t2_bad_s3     <= bad_f2s_t2_s2;
        if (rst_s || clr_s)                    t2_recv_bad <= 32'd0;
        else if (bad_f2s_t2_s2 && !t2_bad_s3)  t2_recv_bad <= t2_recv_bad + 32'd1;
    end

    // Good: toggle-based pulse synchronizer.
    wire t2_good_pulse;
    xpm_cdc_pulse #(.DEST_SYNC_FF(2), .INIT_SYNC_FF(0), .REG_OUTPUT(1), .RST_USED(0), .SIM_ASSERT_CHK(0))
    u_t2_pulse (.src_clk(clk_f), .src_pulse(t2_pulse), .src_rst(1'b0),
                .dest_clk(clk_s), .dest_rst(1'b0), .dest_pulse(t2_good_pulse));
    always @(posedge clk_s) begin
        if (rst_s || clr_s)     t2_recv_good <= 32'd0;
        else if (t2_good_pulse) t2_recv_good <= t2_recv_good + 32'd1;
    end

    // ================= T3: 16-bit counter, fast -> slow =================
    reg [15:0] t3_cnt;
    always @(posedge clk_f) begin
        if (rst_f)     t3_cnt <= 16'd0;
        else if (en_f) t3_cnt <= t3_cnt + 16'd1;
    end

    // Bad: binary bus, each bit synchronized on its own.
    (* ASYNC_REG = "TRUE" *) reg [15:0] bad_f2s_t3_s1, bad_f2s_t3_s2;
    always @(posedge clk_s) begin
        bad_f2s_t3_s1 <= t3_cnt;
        bad_f2s_t3_s2 <= bad_f2s_t3_s1;
    end

    // Good: gray-coded crossing.
    wire [15:0] t3_good;
    xpm_cdc_gray #(.DEST_SYNC_FF(2), .INIT_SYNC_FF(0), .REG_OUTPUT(0), .SIM_ASSERT_CHK(0),
                   .SIM_LOSSLESS_GRAY_CHK(0), .WIDTH(16))
    u_t3_gray (.src_clk(clk_f), .src_in_bin(t3_cnt), .dest_clk(clk_s), .dest_out_bin(t3_good));

    reg  [15:0] t3_good_prev;
    reg  [15:0] t3_diff, t3_step;
    reg         t3_diff_ok_d, t3_step_ok_d, t3_check;
    always @(posedge clk_s) begin
        t3_good_prev <= t3_good;
        t3_diff      <= bad_f2s_t3_s2 - t3_good;
        t3_step      <= t3_good - t3_good_prev;
        // |bad - good| <= 2 and 0 <= step <= 6, both mod 2^16
        t3_diff_ok_d <= (t3_diff <= 16'd2) || (t3_diff >= 16'hFFFE);
        t3_step_ok_d <= (t3_step <= 16'd6);
        if (rst_s || clr_s) begin
            t3_check    <= 1'b0;
            t3_err_bad  <= 32'd0;
            t3_err_good <= 32'd0;
        end else begin
            t3_check <= 1'b1;  // skip the cycle where the pipeline is refilling
            if (t3_check && !t3_diff_ok_d) t3_err_bad  <= t3_err_bad  + 32'd1;
            if (t3_check && !t3_step_ok_d) t3_err_good <= t3_err_good + 32'd1;
        end
    end

    // ================= T4: 32-bit word, slow -> fast =================
    // Bad source: a new word every 7 slow cycles. 0x1357 flips many bits.
    // In async mode the clock phase pattern repeats every 24 slow cycles
    // (395.833/100 = 95/24); 7 is coprime to 24, so updates hit every phase.
    // With 8 they would only hit 3 phases, and whether any of those tear
    // would depend on when the test started.
    reg [2:0]  t4_div;
    reg [15:0] t4_x;
    reg [31:0] t4_bus;
    wire [15:0] t4_x_next = t4_x + 16'h1357;
    always @(posedge clk_s) begin
        if (rst_s) begin
            t4_div <= 3'd0;
            t4_x   <= 16'd0;
            t4_bus <= {16'hFFFF, 16'h0000};
        end else if (en_s) begin
            t4_div <= (t4_div == 3'd6) ? 3'd0 : t4_div + 3'd1;
            if (t4_div == 3'd6) begin
                t4_x   <= t4_x_next;
                t4_bus <= {~t4_x_next, t4_x_next};
            end
        end
    end

    (* ASYNC_REG = "TRUE" *) reg [31:0] bad_s2f_t4_s1, bad_s2f_t4_s2;
    reg        t4_bad_hit;
    reg [31:0] t4_bad_cnt;
    always @(posedge clk_f) begin
        bad_s2f_t4_s1 <= t4_bus;
        bad_s2f_t4_s2 <= bad_s2f_t4_s1;
        t4_bad_hit    <= bad_s2f_t4_s2[31:16] != ~bad_s2f_t4_s2[15:0];
        if (rst_f || clr_f)  t4_bad_cnt <= 32'd0;
        else if (t4_bad_hit) t4_bad_cnt <= t4_bad_cnt + 32'd1;
    end

    // Good: handshake. Send the next word as soon as the previous one is acked.
    reg  [15:0] t4_gx;
    reg  [31:0] t4_gdata;
    reg         t4_send;
    wire        t4_rcv;
    wire [15:0] t4_gx_next = t4_gx + 16'h1357;
    always @(posedge clk_s) begin
        if (rst_s) begin
            t4_gx    <= 16'd0;
            t4_gdata <= {16'hFFFF, 16'h0000};
            t4_send  <= 1'b0;
        end else if (!t4_send && !t4_rcv && en_s) begin
            t4_gx    <= t4_gx_next;
            t4_gdata <= {~t4_gx_next, t4_gx_next};
            t4_send  <= 1'b1;
        end else if (t4_send && t4_rcv) begin
            t4_send  <= 1'b0;
        end
    end

    wire        t4_req;
    wire [31:0] t4_dout;
    xpm_cdc_handshake #(.DEST_EXT_HSK(0), .DEST_SYNC_FF(2), .INIT_SYNC_FF(0), .SIM_ASSERT_CHK(0),
                        .SRC_SYNC_FF(2), .WIDTH(32))
    u_t4_hsk (.src_clk(clk_s), .src_in(t4_gdata), .src_send(t4_send), .src_rcv(t4_rcv),
              .dest_clk(clk_f), .dest_req(t4_req), .dest_ack(1'b0), .dest_out(t4_dout));

    reg        t4_good_hit, t4_good_got;
    reg [31:0] t4_good_cnt, t4_recv_cnt;
    always @(posedge clk_f) begin
        t4_good_got <= t4_req;
        t4_good_hit <= t4_req && (t4_dout[31:16] != ~t4_dout[15:0]);
        if (rst_f || clr_f) begin
            t4_good_cnt <= 32'd0;
            t4_recv_cnt <= 32'd0;
        end else begin
            if (t4_good_hit) t4_good_cnt <= t4_good_cnt + 32'd1;
            if (t4_good_got) t4_recv_cnt <= t4_recv_cnt + 32'd1;
        end
    end

    gray_count_xfer u_t4_bad_x  (.src_clk(clk_f), .src_cnt(t4_bad_cnt),  .dest_clk(clk_s), .dest_cnt(t4_err_bad));
    gray_count_xfer u_t4_good_x (.src_clk(clk_f), .src_cnt(t4_good_cnt), .dest_clk(clk_s), .dest_cnt(t4_err_good));
    gray_count_xfer u_t4_recv_x (.src_clk(clk_f), .src_cnt(t4_recv_cnt), .dest_clk(clk_s), .dest_cnt(t4_recv_good));

endmodule


// Carry a counter that steps by at most one per src_clk cycle into dest_clk.
module gray_count_xfer (
    input  wire        src_clk,
    input  wire [31:0] src_cnt,
    input  wire        dest_clk,
    output wire [31:0] dest_cnt
);
    xpm_cdc_gray #(.DEST_SYNC_FF(2), .INIT_SYNC_FF(0), .REG_OUTPUT(1), .SIM_ASSERT_CHK(0),
                   .SIM_LOSSLESS_GRAY_CHK(0), .WIDTH(32))
    u_gray (.src_clk(src_clk), .src_in_bin(src_cnt), .dest_clk(dest_clk), .dest_out_bin(dest_cnt));
endmodule


// Chain of N LUT1 buffers kept through optimization, to add routing delay.
module lut_delay #(parameter integer N = 2) (
    input  wire i,
    output wire o
);
    wire [N:0] c;
    assign c[0] = i;
    genvar k;
    generate
        for (k = 0; k < N; k = k + 1) begin : g_lut
            (* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'b10)) u_buf (.I0(c[k]), .O(c[k+1]));
        end
    endgenerate
    assign o = c[N];
endmodule
