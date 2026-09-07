// Formal properties for rtl/soc/wb_interconnect.v.
//
// An interconnect's failure modes are the nastiest kind to debug from a
// waveform - two slaves strobed at once, or an ack delivered to the master
// that did not make the request - because they surface far away as corrupted
// data. That makes it worth proving rather than testing.
//
// Proven at NUM_HARTS=2, not 1: Phase 13 stage 3 generalized the DUT from a
// fixed 4-master shape (one fetch, one data, one walker, one debug) to
// NUM_HARTS-many (fetch, data, walker) triples plus one shared debug master,
// and the whole point of proving it here, before a second hart exists to
// wire in for real, is to prove the *general* case - the same "verify the
// hard piece in isolation" sequencing stage 1's AMO-atomicity fix and
// rtl/pmp.v itself both used. NUM_HARTS=1, the shape every real
// instantiation in this tree still builds, is covered instead by the full
// simulation regression (make verify/make verify_ooo) that already exercises
// rtl/soc/soc_top.v's real single-hart instantiation end to end - formally
// re-proving that exact case here would be strictly weaker than what those
// gates already establish, where NUM_HARTS=2 is not exercised by anything
// else in the tree yet.
//
// It became a *sequential* proof when the arbiter gained a lock. The
// memories are now synchronous block RAMs with a wait state, so a transfer
// spans several cycles, and a purely combinational grant would let a
// higher-priority master take the bus in the middle of another master's
// read - after which the RAM's ack, which belongs to that other master's
// address, is delivered along with that other master's data. Properties 8
// and 9 below are the ones that say that cannot happen.
module fv_interconnect #(
    parameter NUM_SLAVES = 9,
    parameter NUM_HARTS  = 2
)(
    input wire        clk,
    input wire        rst,

    input wire [NUM_HARTS-1:0]      f_cyc, f_stb,
    input wire [NUM_HARTS*32-1:0]   f_adr,

    input wire [NUM_HARTS-1:0]      d_cyc, d_stb, d_we,
    input wire [NUM_HARTS*32-1:0]   d_adr, d_dat_w,
    input wire [NUM_HARTS*4-1:0]    d_sel,

    input wire [NUM_HARTS-1:0]      w_cyc, w_stb,
    input wire [NUM_HARTS*32-1:0]   w_adr,

    // The debug module (rtl/debug/dm.v). Highest priority and the second
    // kind of master with a write path, which is why it is here rather than
    // assumed harmless: every property below has to hold with debug plus
    // 3*NUM_HARTS contenders, not just the per-hart ones, and "at most one
    // master is selected" is exactly the kind of thing that stays true by
    // luck when a case is added.
    input wire        dbg_cyc, dbg_stb, dbg_we,
    input wire [31:0] dbg_adr, dbg_dat_w,
    input wire [3:0]  dbg_sel,

    input wire [NUM_SLAVES*32-1:0] s_dat_r,
    input wire [NUM_SLAVES-1:0]    s_ack
);
    // The real map from soc_top.v, all nine slaves. Held constant rather than
    // left free because `s_base`/`s_mask` are wiring constants in the real
    // design; leaving them free would let the solver invent an aliased map
    // (two slaves answering the same address) and then report a "bug" no
    // instantiation can produce.
    //
    // The SDRAM's mask is 0xFE rather than 0xFF, so it answers to 0x90 and
    // 0x91 alike: 32 MB, the size of the part on the board. That asymmetry is
    // the point of proving with the real map rather than a tidy one - a
    // masked slave is exactly where a decode bug would put two slaves on the
    // same address, and property 1 is what would catch it.
    wire [NUM_SLAVES*8-1:0] s_base =
        {8'h90, 8'h80, 8'h07, 8'h06, 8'h05, 8'h04, 8'h03, 8'h02, 8'h00};
    wire [NUM_SLAVES*8-1:0] s_mask =
        {8'hFE, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF};

    wire [NUM_HARTS*32-1:0] f_dat_r, d_dat_r, w_dat_r;
    wire [NUM_HARTS-1:0]    f_ack, d_ack, w_ack;
    wire [31:0] dbg_dat_r;
    wire        dbg_ack;
    wire        s_cyc, s_we, s_data_master;
    wire [NUM_SLAVES-1:0] s_stb;
    wire [31:0] s_adr, s_dat_w;
    wire [3:0]  s_sel;

    wb_interconnect #(.NUM_SLAVES(NUM_SLAVES), .NUM_HARTS(NUM_HARTS)) DUT (
        .clk(clk), .rst(rst),
        .f_cyc(f_cyc), .f_stb(f_stb), .f_adr(f_adr),
        .f_dat_r(f_dat_r), .f_ack(f_ack),
        .d_cyc(d_cyc), .d_stb(d_stb), .d_we(d_we), .d_adr(d_adr),
        .d_dat_w(d_dat_w), .d_sel(d_sel),
        .d_dat_r(d_dat_r), .d_ack(d_ack),
        .w_cyc(w_cyc), .w_stb(w_stb), .w_adr(w_adr),
        .w_dat_r(w_dat_r), .w_ack(w_ack),
        .dbg_cyc(dbg_cyc), .dbg_stb(dbg_stb), .dbg_we(dbg_we), .dbg_adr(dbg_adr),
        .dbg_dat_w(dbg_dat_w), .dbg_sel(dbg_sel),
        .dbg_dat_r(dbg_dat_r), .dbg_ack(dbg_ack),
        .s_base(s_base), .s_mask(s_mask),
        .s_cyc(s_cyc), .s_stb(s_stb), .s_we(s_we),
        .s_adr(s_adr), .s_dat_w(s_dat_w), .s_sel(s_sel),
        .s_dat_r(s_dat_r), .s_ack(s_ack),
        .s_data_master(s_data_master)
    );

    // BMC starts from an unconstrained state, so require reset in the first
    // step - otherwise the solver invents a power-on state (a lock held for a
    // master that never requested anything) that no reset sequence reaches.
    reg f_initialized = 1'b0;
    always @(posedge clk) f_initialized <= 1'b1;
    always @(*) if (!f_initialized) assume (rst);

    // ---- environment assumption: masters are Wishbone-legal ----
    // A master that has asserted cyc+stb holds them until it is acked. This
    // is not wishful thinking about the environment; it is a property of
    // every master in this design, and cpu_wb.v's `f_busy` exists
    // specifically to guarantee it for the fetch master now that transfers
    // span cycles. Without it the solver can drop a request mid-transfer and
    // then legitimately complain that the ack went to a master that is no
    // longer asking - a "bug" that says nothing about the interconnect.
    // Every master ties stb to cyc: every core drives each pair from a
    // single expression. Wishbone does permit cyc without stb - a master
    // holding the bus between transfers - but this arbiter grants on cyc
    // alone, so such a master would take the bus and then never strobe,
    // blocking everyone else until it let go. No master in this SoC behaves
    // that way, and saying so is what keeps the grant-stability property
    // below about the arbiter rather than about a master that does not
    // exist here.
    integer k;
    always @(*) begin
        for (k = 0; k < NUM_HARTS; k = k + 1) begin
            assume (f_cyc[k] == f_stb[k]);
            assume (d_cyc[k] == d_stb[k]);
            assume (w_cyc[k] == w_stb[k]);
        end
        assume (dbg_cyc == dbg_stb);
    end

    reg [NUM_HARTS-1:0] p_f_pending, p_d_pending, p_w_pending;
    reg                 p_dbg_pending;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            p_f_pending   <= {NUM_HARTS{1'b0}};
            p_d_pending   <= {NUM_HARTS{1'b0}};
            p_w_pending   <= {NUM_HARTS{1'b0}};
            p_dbg_pending <= 1'b0;
        end else begin
            p_f_pending   <= f_cyc & f_stb & ~f_ack;
            p_d_pending   <= d_cyc & d_stb & ~d_ack;
            p_w_pending   <= w_cyc & w_stb & ~w_ack;
            p_dbg_pending <= dbg_cyc && dbg_stb && !dbg_ack;
        end
    end
    always @(*) begin
        for (k = 0; k < NUM_HARTS; k = k + 1) begin
            if (p_f_pending[k]) assume (f_cyc[k] && f_stb[k]);
            if (p_d_pending[k]) assume (d_cyc[k] && d_stb[k]);
            if (p_w_pending[k]) assume (w_cyc[k] && w_stb[k]);
        end
        if (p_dbg_pending) assume (dbg_cyc && dbg_stb);
    end

    // ---- everything below is expressed over ports only ----
    // No hierarchical references into the DUT. Partly because they survive a
    // refactor, but mainly because `prep -flatten` leaves several distinct
    // nets sharing a name, so a reference like `DUT.lock` can silently bind
    // to the wrong one and produce a counterexample that describes nothing.
    //
    // "A transfer is in progress" is therefore derived the way an observer on
    // the bus would derive it: somebody is asserting cyc+stb and nobody has
    // been acked yet.
    wire any_f_req = |(f_cyc & f_stb);
    wire any_d_req = |(d_cyc & d_stb);
    wire any_w_req = |(w_cyc & w_stb);
    wire any_req   = any_f_req || any_d_req || any_w_req || (dbg_cyc && dbg_stb);
    wire any_ack   = (|f_ack) || (|d_ack) || (|w_ack) || dbg_ack;

    reg                  p_any_req, p_any_ack, p_dm, p_rst;
    reg [NUM_HARTS-1:0]  p_d_ack;
    always @(posedge clk) begin
        p_any_req <= any_req;
        p_any_ack <= any_ack;
        p_dm      <= s_data_master;
        p_rst     <= rst;
        p_d_ack   <= d_ack;
    end

    // True exactly when a transfer started earlier and has not completed, so
    // arbitration must stay put.
    wire in_flight = p_any_req && !p_any_ack;

    integer j;
    reg [3:0] stb_count;
    always @(*) begin
        stb_count = 4'd0;
        for (j = 0; j < NUM_SLAVES; j = j + 1)
            stb_count = stb_count + {3'b0, s_stb[j]};
    end

    // Same manual popcount idiom as stb_count above, over every ack line
    // (every hart's fetch/data/walker plus debug), for property 5's "at
    // most one master ever acks" check - avoids depending on a SystemVerilog
    // builtin ($countbits) this formal flow's yosys frontend may not support.
    reg [3:0] ack_count;
    always @(*) begin
        ack_count = 4'd0;
        for (k = 0; k < NUM_HARTS; k = k + 1)
            ack_count = ack_count + {3'b0, f_ack[k]} + {3'b0, d_ack[k]} +
                        {3'b0, w_ack[k]};
        ack_count = ack_count + {3'b0, dbg_ack};
    end

    // A hart's own data master immediately re-asking the cycle right after
    // its own ack - the AMO-follow-up signature stage 1 introduced,
    // generalized per hart and derived from ports only, matching the DUT's
    // own internal `d_continuing` (which this file cannot reference
    // directly - see the header note above).
    wire [NUM_HARTS-1:0] p_d_continuing = p_d_ack & d_cyc;
    wire                 any_p_d_continuing = |p_d_continuing;

    always @(*) if (!rst) begin
        // 1. At most one slave is ever strobed. Two slaves answering in the
        //    same cycle drive the shared response mux against each other.
        assert (stb_count <= 4'd1);

        // 2. A strobed slave is the one the address actually decodes to,
        //    through that slave's own mask. A slave with a mask narrower than
        //    0xFF answers to more than one base byte, which is how the SDRAM
        //    covers 32 MB.
        for (j = 0; j < NUM_SLAVES; j = j + 1)
            if (s_stb[j])
                assert ((s_adr[31:24] & s_mask[8*j +: 8]) ==
                        (s_base[8*j +: 8] & s_mask[8*j +: 8]));

        // 3. The bus is only claimed as a data access when some hart's data
        //    master is actually asking for it.
        if (s_data_master) assert (any_d_req);

        // 3b. `s_data_master` is what gates read side effects - the PLIC's
        //     claim register, the UART's RBR. The debug module must never
        //     assert it: a host reading a peripheral through rtl/debug/dm.v
        //     has to get the value without consuming it. This is one line and
        //     it is the difference between a debug port and a second CPU.
        if (dbg_ack) assert (!s_data_master);

        // 4a. Data outranks the walker whenever arbitration is actually
        //     open, for any hart - the property that keeps atomics atomic.
        //     Every core holds `cyc` across both phases of an AMO's
        //     read-modify-write and relies on its *own* data master always
        //     winning against any walker (its own or another hart's) to
        //     keep anyone else out of the gap - and instruction fetch
        //     carries on translating while a MEM stage sits in an AMO, so a
        //     walker genuinely can ask during it. The `!in_flight` qualifier
        //     is the whole point of the lock: while a transfer is under way,
        //     priority does not get to preempt it.
        if (any_d_req && !in_flight) assert (!(|w_ack) && !(|f_ack));

        // 4z. Debug outranks everything, whenever arbitration is open -
        //     except any hart's own data master's immediate follow-up phase
        //     (`any_p_d_continuing`, derived here from ports rather than
        //     peeked at directly, matching this file's own "expressed over
        //     ports only" rule). That exception is deliberate and is what
        //     property 10 below exists to prove.
        if (dbg_cyc && !in_flight && !any_p_d_continuing) begin
            assert (!(|f_ack));
            assert (!(|d_ack));
            assert (!(|w_ack));
        end

        if (any_d_req && !dbg_cyc && !in_flight) begin
            assert (s_data_master);
            assert (!(|w_ack));
            assert (!(|f_ack));
        end

        // 4b. The walker outranks fetch, for any hart. Fetch is nearly
        //     continuous, so a walk that lost to it could be starved
        //     indefinitely; the reverse cannot happen, because a walk is two
        //     reads and then it is over.
        if (any_w_req && !any_d_req && !dbg_cyc && !in_flight)
            assert (!(|f_ack));

        // 5. Acks go to the master that made the request, and only to one -
        //    across every hart and every role, not just within one.
        for (k = 0; k < NUM_HARTS; k = k + 1) begin
            if (f_ack[k]) assert (f_cyc[k]);
            if (d_ack[k]) assert (d_cyc[k]);
            if (w_ack[k]) assert (w_cyc[k]);
        end
        if (dbg_ack) assert (dbg_cyc);
        assert (ack_count <= 4'd1);

        // 6. An access to an address matching no slave still acks. A bus
        //    that never acks wedges the issuing hart permanently - every
        //    core freezes its pipeline waiting for one - so a stray pointer
        //    would become an unrecoverable hang instead of garbage data the
        //    program survives.
        //
        //    It matters for the walker too, and more than it looks: a walker
        //    reads whatever physical address a PTE names, and a half-built
        //    page table names unmapped ones. wb_ptw.v's own handling of a
        //    same-cycle ack is what turns that into a page fault rather than
        //    a re-issued read forever.
        if (any_d_req && !dbg_cyc && !in_flight && (s_stb == {NUM_SLAVES{1'b0}}))
            assert (|d_ack);
        // The debug master needs it most: a host can ask for any address at
        // all, including ones that decode to nothing, and a debug read that
        // hangs the bus would take the machine down rather than report a
        // hole. Same exemption as property 4z, for the same reason: some
        // hart's data master's own immediate follow-up phase wins this cycle
        // instead.
        if (dbg_cyc && dbg_stb && !in_flight && (s_stb == {NUM_SLAVES{1'b0}}) &&
            !any_p_d_continuing)
            assert (dbg_ack);
        if (any_w_req && !any_d_req && !dbg_cyc && !in_flight &&
            (s_stb == {NUM_SLAVES{1'b0}}))
            assert (|w_ack);

        // 7. The broadcast address belongs to the granted master.
        for (k = 0; k < NUM_HARTS; k = k + 1) begin
            if (d_ack[k]) assert (s_adr == d_adr[32*k +: 32]);
            if (f_ack[k]) assert (s_adr == f_adr[32*k +: 32]);
            if (w_ack[k]) assert (s_adr == w_adr[32*k +: 32]);
        end
        if (dbg_ack) assert (s_adr == dbg_adr);

        // 8. Only a master that *has* a write path drives `s_we` - a data
        //    master and the debug module. Fetch and the walkers have none,
        //    so if this could fail either of them could corrupt memory.
        if (s_we) assert (s_data_master || dbg_cyc);
    end

    // ---- the property that makes a multi-cycle slave safe ----
    //
    // Compared between registered history and the current cycle, and asserted
    // combinationally. Asserting inside `always @(posedge clk)` looks
    // equivalent and is not: after yosys's async2sync pass, register outputs
    // sampled at the edge are not consistent with the combinational signals
    // derived from them, and the solver duly reports a "counterexample" that
    // is an artifact of the sampling rather than a behavior of the design.
    always @(*) if (!rst && !p_rst && f_initialized) begin
        // 9. A transfer that started and was not acked keeps the bus.
        //
        //    This is what the lock is for, and it is the property that fails
        //    without it: a higher-priority master would take the bus
        //    mid-transfer, and the slave's ack - which belongs to the
        //    address latched when the transfer began - would be delivered to
        //    the wrong master along with the wrong data. Silent corruption,
        //    not a hang, which is why it is worth proving rather than hoping
        //    a test trips over it.
        if (in_flight) assert (s_data_master == p_dm);

        // 10. A hart's own data master keeps the bus across its own
        //     multi-phase sequence, not just across one transfer - and,
        //     generalized from a single data master to NUM_HARTS of them,
        //     specifically *that hart's own* access, not merely "some data
        //     access." `in_flight` (property 9) goes false the instant an
        //     ack fires - by design, that is the one cycle arbitration is
        //     genuinely open - so this is a different claim: if hart k's own
        //     ack fired last cycle and hart k is *still asking* this cycle
        //     (an AMO's write phase immediately following its read phase,
        //     driven by the same instruction the whole way through), nobody
        //     else - not debug, and not another hart's own data, walker, or
        //     fetch master - may have won that gap cycle instead. Without
        //     the re-lock this proves, debug's absolute priority (property
        //     4z) could interpose here - rare enough in practice not to
        //     matter with one data master, not rare enough once a second one
        //     exists. This is what makes that eventually safe, proved here
        //     with two harts before either is actually wired in for real.
        //
        //     Checked the same way the original, single-master version of
        //     this property was: against `s_data_master` and the broadcast
        //     bus address, not against `d_ack[k]` - a slave's own ack can
        //     legitimately lag the grant by a wait state or more (block RAMs
        //     have one), so "hart k *acks* this cycle" is not what stage 1's
        //     re-lock actually guarantees. "Hart k's own address is what
        //     went out on the bus" is: it is combinational, derived from the
        //     same `sel_d` the grant itself is, and it is what would be
        //     wrong if a different master's address reached the slave
        //     instead.
        for (k = 0; k < NUM_HARTS; k = k + 1)
            if (p_d_continuing[k]) begin
                assert (s_data_master);
                assert (s_adr == d_adr[32*k +: 32]);
            end
    end
endmodule
