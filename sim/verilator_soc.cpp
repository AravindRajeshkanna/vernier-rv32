// A Verilator harness for the whole SoC.
//
// ---- Why this exists ----
//
// Everything in sim/tb_*.v runs under Icarus, and Icarus runs this SoC at
// about 11.3 thousand cycles per second - measured: sim_sdramboot, 2,108,456
// cycles in 187 s. That is fine for every test in the suite; the longest is
// under four minutes.
//
// It stops being fine at the next milestone. Booting Linux is order 10^8
// cycles, which is seven hours or more per attempt under Icarus - one
// attempt per working day, on a bring-up whose characteristic failure is a
// silent hang with no output at all. The same design through this harness
// measures 4.44 M cycles/s, roughly 390x, which turns that attempt into
// about a minute. That ratio, not any RTL, is what decides whether the Linux
// bring-up takes weeks or months, so it is worth building first.
//
// ---- What it is not ----
//
// It is not a replacement for the Icarus testbenches, and specifically it is
// not the protocol authority for SDRAM. `make verify` still runs sim_sdram
// and sim_sdramboot against sim/sdram_model.v, and that file remains the
// definition of what the part will and will not accept. What is here is a
// port of that model, checked against it by running the same program and
// requiring the same cycle count, refresh count and output (see
// `make verilator_check`). If the two ever disagree, the Verilog one is
// right and this one has a bug.
//
// The reason for porting rather than reusing: sim/sdram_model.v is written in
// nanoseconds, with `#T_AC_NS` on the data path and real-valued timing
// comparisons. Verilator has no notion of either. So the model is
// re-expressed here as a cycle-accurate object that carries an explicit
// nanosecond clock, and the one genuinely sub-cycle thing it modelled - the
// access time from the part's clock edge - becomes a static margin check at
// startup rather than a delay (see SdramModel::check_ac_margin).
//
// ---- Usage ----
//
//   obj_dir_soc_inorder/Vsoc_top +sdram=sdramimage.hex +drain=8000
//
//   +sdram=FILE       $readmemh-format image, one 16-bit word per line
//   +rom=FILE         boot ROM image, one 32-bit word per line
//   +ram=FILE         block RAM image, one 32-bit word per line
//   +sdram_words=N    16-bit words of modelled SDRAM (default 2^21 = 4 MB)
//   +maxcycles=N      give up after this many cycles
//   +stopon=TEXT      stop once TEXT has come out of the UART, then drain.
//                     The verdict word in block RAM is how a bare-metal
//                     program here says it is finished, and software this
//                     project did not write does not write it: Linux ends a
//                     boot by printing something, not by storing a magic
//                     number. Without this a kernel run costs +maxcycles
//                     every time, whatever happens - and +maxcycles has to
//                     be set for the slowest plausible boot.
//                     TEXT cannot contain a space, because a plusarg is one
//                     shell word; the markers it is meant for are hyphenated
//                     for that reason.
//   +drain=N          cycles to keep running after the verdict word appears,
//                     so the last of the UART output gets out
//   +uart_clks=N      clock cycles per UART bit (default 4). Must match what
//                     the UART is actually running at - a driver that
//                     programs the ns16550 divisor changes it.
//   +watchskew=N      how many cycles after the watched PC retires to read
//                     the register file (default 3). Not a tuning knob: the
//                     register file is written in WB, so at the moment an
//                     instruction retires the one or two *before* it have
//                     not landed yet, and reading the array then reports
//                     their previous values. At a function entry that is
//                     exactly the argument registers - the two `mv`s that
//                     set them are still in flight - so the dump shows the
//                     previous call's arguments and looks like a hardware
//                     bug. It did, twice, in one afternoon. Zero reproduces
//                     the old behaviour.
//   +watchpc=ADDR     dump the integer registers the first time a *retired*
//                     instruction is at ADDR. `+watchlast` takes the last
//                     occurrence instead, which is what you want when the
//                     address is inside a loop and only the final pass
//                     failed. For firmware that gives up without a
//                     console: the error code it decided to hang on is still
//                     in a register at the point it branches to its hang
//                     loop, and there is no other way to read it.
//   +checkreads       compare every SDRAM read the interconnect completes
//                     against what the modelled part actually holds, and
//                     report the first few that disagree. This asks a
//                     different question from every other probe here: not
//                     "where did the machine go" but "was what it read
//                     real". A whole boot's worth of accesses is checked,
//                     which is why it is a flag - it costs a compare per
//                     acknowledged transfer.
//   +checkfetch       the same question for instructions. `+checkreads`
//                     cannot answer it: a fetch that hits in the I-cache
//                     never reaches the bus, so the only place to catch a
//                     cache handing back the wrong word is where the core
//                     takes it.
//   +checkmmu         walk the page tables in C++ and compare against what
//                     rtl/mmu.v resolved, on every translation both TLBs
//                     answer. Software cannot check this - not seeing the
//                     translation is the point of having one - so a wrong
//                     physical address is invisible from inside the machine
//                     and shows up only as whatever the program did next.
//   +writetrace=ADDR:LEN:FILE
//                     every write the interconnect completes inside
//                     [ADDR, ADDR+LEN), as "cycle address data sel master".
//                     The mirror of +readtrace, and it reads the *request*
//                     (s_dat_w/s_sel) rather than the response: a write's
//                     `fin_dat` is not a claim about memory, because the
//                     controller may acknowledge before the array has taken
//                     it. What the store put on the bus is the question when
//                     a value that should be in memory is not.
//
//                     This exists because the wide core's execve -EFAULT is a
//                     store page fault on a page whose PTE is zero, and "did
//                     anything ever write that word, and with what" is not
//                     answerable from a read trace, a trap trace or a memory
//                     dump at the end.
//   +readtrace=ADDR:LEN:FILE
//                     log every SDRAM read the interconnect completes inside
//                     [ADDR, ADDR+LEN) as "cycle address data master". For
//                     watching software walk a structure: the *sequence* of
//                     addresses is the thing, and it is not recoverable from
//                     a PC trace once the code is a loop over a pointer.
//   +checkdecode      check that the instruction the decoder is holding is
//                     the instruction at the PC it is attributed to,
//                     translating that PC through the page tables the same
//                     way the hardware would. This is the one check the
//                     others cannot make: +checkfetch proves the fetch unit
//                     returned the right word for the address it was *given*,
//                     and says nothing about whether that was the right
//                     address to have asked for. An ITLB walk that resolves
//                     after a mispredict redirect answers for the address it
//                     started with, and the IF/ID register then pairs a real
//                     instruction from the wrong path with the corrected PC.
//   +checkuart        check that every byte written to the UART's holding
//                     register comes out on the wire, in order. The console
//                     is the instrument the rest of this list reports
//                     through, so when it is the thing that is broken the
//                     evidence and the fault are the same signal: output
//                     arrives thinned and unreadable, and every reading of it
//                     is a guess about the decoder. This watches both ends
//                     independently - what software wrote, and what the line
//                     carried - so "the harness is decoding at the wrong
//                     rate" and "the hardware threw the byte away" stop
//                     looking alike.
//   +pipetrace=FROM:TO:FILE
//                     one line per cycle between FROM and TO: the fetch PC,
//                     the retiring PC, the register writeback, and the
//                     redirect and prediction state. For the case where an
//                     instruction retires and its register write does not
//                     appear - which no probe that samples the register file
//                     can distinguish from sampling it at the wrong moment.
//   +traptrace=FILE   every trap the core takes, as
//                     "cycle pc priv to scause sepc stval mcause mepc mtval
//                      satp". Traps are the one thing that can interrupt an
//                     instruction sequence without appearing in it, so when a
//                     register write goes missing between two adjacent
//                     instructions this is what says whether anything
//                     happened in between.
//
//                     `to` is S or M, taken from csr_file.v's own `trap_to_s`
//                     rather than worked out here. Both CSR sets are recorded
//                     beside it because only one of them is written by any
//                     given trap and the values do not say which. Two ways of
//                     deciding that from the trace alone were tried and are
//                     both wrong: reading `scause` unconditionally reports a
//                     store page fault for every timer interrupt that follows
//                     one, and "whichever set changed since the last trap"
//                     fails because software writes these registers too -
//                     OpenSBI sets mepc before every mret. `priv` is the mode
//                     the hart was in when the trap was taken, not the one it
//                     landed in.
//
//                     The CSRs are captured one cycle after `trap` pulses,
//                     because they are registered off it: sampling them in
//                     the same cycle returns the *previous* trap. A one-deep
//                     pending slot carries the record across, and is flushed
//                     before a new trap is captured so back-to-back traps
//                     cannot overwrite each other.
//   +savemem=ADDR:LEN:FILE
//                     write LEN bytes of SDRAM starting at ADDR to FILE when
//                     the run ends. +peek reads a word; this reads a
//                     structure. It exists because the useful question about
//                     a device tree, a page table or a kernel image in memory
//                     is not "what is that word" but "is this still the thing
//                     it is supposed to be" - and the tools that answer that
//                     (dtc, objdump, cmp) take a file.
//   +peek=ADDR        print the 32-bit word at ADDR when the run ends, up to
//                     four times. For reading a firmware's own globals - an
//                     allocator's high-water mark, a status flag - when it has
//                     no way to print them itself. Reads the SDRAM model, so
//                     the address must be in the SDRAM window.
//   +quiet            suppress the UART stream (keep the summary)
//   +dump[=FILE]      write a VCD. Only works if built with --trace; see the
//                     Makefile's VTRACE knob, and note that the reason it is
//                     opt-in is a 228 GB disk that a previous unconditional
//                     dump filled to 100%.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cinttypes>
#include <string>
#include <vector>
#include <deque>
#include <chrono>

#include "Vsoc_top.h"
#include "Vsoc_top___024root.h"
#include "verilated.h"
#if VM_TRACE
# include "verilated_vcd_c.h"
#endif

// ---------------------------------------------------------------------------
// Clock
// ---------------------------------------------------------------------------
// 40 ns, matching soc_top's CLK_HZ default of 25 MHz and sim/tb_sdramboot.v's
// CLK_PERIOD. This is load-bearing rather than cosmetic: the SDRAM model
// checks tRCD, tRP, tRFC and the refresh interval in nanoseconds, and
// wb_sdram.v derives its cycle counts from CLK_HZ. Running the clock faster
// here than CLK_HZ claims would violate real timing while the controller
// believed it was compliant.
static const double CLK_PERIOD_NS = 40.0;
static const double CLK_HALF_NS   = CLK_PERIOD_NS / 2.0;

// Must match the rate the UART is actually running at. soc_top's
// UART_CLKS_PER_BIT is 4, which every testbench here uses to keep simulations
// short - but rtl/uart.v is an ns16550 now, and a driver that programs the
// baud divisor changes the rate out from under that default. OpenSBI does
// exactly this: it reads `clock-frequency` from the device tree and writes
// 25e6/(16*115200) = 13, for 208 clocks per bit.
//
// So it is a runtime setting (`+uart_clks=N`) rather than a constant. Note
// what makes that affordable: at 208 clocks per bit a character costs 2080
// cycles and a banner costs a million, which is a quarter of a second here
// and a minute and a half under Icarus.
static int uart_clks_per_bit = 4;

// `+stopon=TEXT`: the text to watch the console for, and whether it has been
// seen. A rolling suffix compare rather than a line-based one, so a marker
// still matches when it shares a line with something else - kernel output is
// interleaved with whatever else is printing.
static std::string uart_stop_on;
static bool        uart_stop_hit = false;

// ---------------------------------------------------------------------------
// `+checkuart`: what the program handed the transmitter, against what the
// wire carried.
//
// The console is the one part of this machine whose output *is* the
// instrument, so a fault in it disguises itself as a fault in everything
// upstream. rtl/uart.v holds one byte and its TX_IDLE arm takes a write only
// when the transmitter is free; a write that lands mid-character is
// discarded, and there is no status bit that says so. What comes out is a
// thinned version of what went in, which reads as a console decoding at the
// wrong rate - a hypothesis about the harness rather than about the machine.
//
// Two counts and one queue. The counts say how many bytes software wrote and
// how many the hardware threw away, which is the *cause*. The queue holds
// the accepted bytes and the receiver pops one per completed frame, which
// checks the stronger property - that the wire carries the bytes the
// transmitter took, in order - on every run that prints anything.
//
// Neither needs calibrating against a known-good baseline: a dropped write is
// a defect on its own terms, and so is a byte on the line that nothing wrote.
// docs/practices.md section 30.
// ---------------------------------------------------------------------------
static bool uart_check       = false;
static long uart_thr_writes  = 0;
static long uart_thr_dropped = 0;
static long uart_wire_bytes  = 0;
static long uart_wire_bad    = 0;
static std::deque<uint8_t> uart_accepted;

static char uart_glyph(uint8_t b) {
    return (b >= 0x20 && b < 0x7f) ? (char)b : '.';
}

// Called on the cycle a THR write is on the bus, with the transmitter's state
// as the RTL will see it at the edge that takes the write.
static void uart_thr_write(uint8_t b, bool busy, long cycle) {
    uart_thr_writes++;
    if (busy) {
        uart_thr_dropped++;
        if (uart_thr_dropped <= 12)
            printf("\n** UART dropped a byte at cycle %ld: 0x%02x '%c' was "
                   "written to THR while the transmitter was still shifting "
                   "the previous character out\n",
                   cycle, b, uart_glyph(b));
    } else {
        uart_accepted.push_back(b);
    }
}

// Called by the receiver below as each frame completes on the line.
static void uart_wire_byte(uint8_t b) {
    uart_wire_bytes++;
    if (uart_accepted.empty()) {
        uart_wire_bad++;
        if (uart_wire_bad <= 12)
            printf("\n** UART sent 0x%02x '%c', which nothing wrote to THR\n",
                   b, uart_glyph(b));
        return;
    }
    const uint8_t want = uart_accepted.front();
    uart_accepted.pop_front();
    if (want != b) {
        uart_wire_bad++;
        if (uart_wire_bad <= 12)
            printf("\n** UART sent 0x%02x '%c' where THR was given 0x%02x "
                   "'%c'\n", b, uart_glyph(b), want, uart_glyph(want));
    }
}

// ---------------------------------------------------------------------------
// A 16-bit SDR SDRAM, ported from sim/sdram_model.v
// ---------------------------------------------------------------------------
// The header of that file explains at length why a *strict* model is the
// point: every interesting SDRAM bug is a protocol bug, and none of them
// corrupt data in simulation in a way a write-then-read test would notice.
// They corrupt data on a board, at temperature, weeks later. So this refuses
// the same eleven things the Verilog one refuses, with the same messages.
class SdramModel {
public:
    // Timing, nanoseconds. Winbond W9825G6KH-6 / equivalent -6 speed grade.
    //
    // The same numbers as sim/sdram_model.v's defaults, and unavoidably a
    // second copy of them - Verilog and C++ cannot share a constant, so
    // practices.md section 11 applies. If one moves, both must. The direction
    // of safe error is *long*: too long makes the model stricter than the
    // part, so a controller that passes still works on silicon; too short
    // makes it permissive, which is how a protocol violation reaches a board.
    // `make verilator_check` fails if the two copies stop agreeing.
    static constexpr double T_RCD_NS  = 18.0;
    static constexpr double T_RP_NS   = 18.0;
    static constexpr double T_RC_NS   = 60.0;
    static constexpr double T_RFC_NS  = 60.0;
    static constexpr double T_MRD_NS  = 12.0;
    static constexpr double T_RAS_NS  = 42.0;
    static constexpr double T_WR_NS   = 15.0;
    static constexpr double T_INIT_NS = 100000.0;
    static constexpr double T_REFI_NS = 7812.5;
    static constexpr double T_AC_NS   = 5.4;

    static const int PIPE    = 8;
    // sim/sdram_model.v parameterises the bank count; this does not, because
    // every part this SoC has ever addressed has four banks and a parameter
    // nothing varies is a parameter nothing tests. BA_BITS is the width the
    // address mapping needs, and the two must stay consistent.
    static const int BA_BITS = 2;
    static const int NBANKS  = 1 << BA_BITS;

    SdramModel(int row_bits, int col_bits, size_t mem_words)
        : row_bits_(row_bits), col_bits_(col_bits),
          ncols_(1u << col_bits), mem_(mem_words, 0) {
        reset_state(0.0);
        // Outside reset_state() because the Verilog keeps it cumulative: it
        // is a statistic the testbenches print, not part of the protocol.
        refresh_count_ = 0;
    }

    // ---- the sub-cycle thing this model can no longer represent ----
    //
    // sim/sdram_model.v drives read data `#T_AC_NS` after its own clock edge,
    // and that delay is not decoration: it is what made the model able to
    // represent the 180-degree-shifted clock that fpga/sdram_clk_out.v
    // actually ships, after an aligned clock failed on the bench (one word in
    // a thousand - see fpga/README.md). A cycle-based model has nowhere to
    // put 5.4 ns.
    //
    // What it can do is check that the delay stays invisible. The part's
    // clock edge is half a period before the controller's sampling edge, so
    // the data is valid (half - T_AC) before it is sampled. If that ever goes
    // negative, this harness is quietly simulating a machine that would not
    // work, and it says so instead.
    void check_ac_margin() const {
        const double setup = CLK_HALF_NS - T_AC_NS;
        if (setup <= 0.0) {
            fprintf(stderr,
                    "\nSDRAM: read data arrives %.1f ns after the part's clock "
                    "edge but is sampled %.1f ns after it.\n"
                    "  There is no setup margin, and a cycle-based model cannot "
                    "represent that. Use the Icarus\n"
                    "  path (make sim_sdramboot), whose model carries the delay "
                    "properly.\n", T_AC_NS, CLK_HALF_NS);
            exit(1);
        }
    }
    double ac_setup_ns() const { return CLK_HALF_NS - T_AC_NS; }

    // sim/sdram_model.v also has a `rst` input, because the system's reset is
    // the only way it can be told the 100 us power-up is about to happen
    // again - which is what `make sim_rerun` does on purpose. There is no
    // equivalent here, deliberately: this harness asserts reset once and
    // never again, so a re-initialisation path would be code nothing builds,
    // and section 14 of docs/practices.md is about what happens to that.
    // Adding a rerun means calling reset_state() on the rising edge of rst.

    size_t words() const { return mem_.size(); }
    long   refreshes() const { return refresh_count_; }
    uint16_t *storage() { return mem_.data(); }

    // One rising edge of the part's clock - which is the *falling* edge of
    // the controller's, because the board clocks it 180 degrees out.
    void edge(double now, bool cke, bool cs_n, bool ras_n, bool cas_n,
              bool we_n, uint32_t a, uint32_t ba, uint32_t dqm,
              uint16_t dq_in, bool dq_driven) {
        now_ = now;

        // A row that is never refreshed keeps its contents forever in a model
        // and loses them on a board, so the gap is checked here instead.
        if (mr_programmed_ && (now_ - t_last_refresh_) > 2.0 * T_REFI_NS)
            fail("no AUTO REFRESH within 2x tREFI - rows are losing data");

        // ---- read pipeline shifts every cycle ----
        // The Verilog does this with non-blocking assignments and then lets
        // the command below overwrite the same indices, so the command wins.
        // Reproduced here by shifting into a scratch copy first.
        uint16_t nd[PIPE];
        bool     nv[PIPE];
        for (int i = 0; i < PIPE - 1; i++) { nv[i] = pipe_v_[i+1]; nd[i] = pipe_d_[i+1]; }
        nv[PIPE-1] = false; nd[PIPE-1] = 0;

        // ---- a write burst already under way takes the bus data ----
        int      next_wr_left = wr_left_;
        uint32_t next_wr_col  = wr_col_;
        if (wr_left_ > 0) {
            if (!dq_driven)
                fail("write burst continued with the data bus not driven");
            uint32_t widx = flat_addr(wr_bank_, bank_row_[wr_bank_], wr_col_);
            if (widx >= mem_.size())
                fail("write beyond the modelled storage - raise +sdram_words");
            store(widx, dq_in, dqm);
            next_wr_left = wr_left_ - 1;
            t_write_end_[wr_bank_] = now_;
            if (wr_col_ == (ncols_ - 1) && wr_left_ > 1)
                fail("write burst crossed a row boundary");
            next_wr_col = (wr_col_ + 1) & (ncols_ - 1);
        }

        const int cmd = (cs_n ? 8 : 0) | (ras_n ? 4 : 0) | (cas_n ? 2 : 0) | (we_n ? 1 : 0);
        const bool selected = !cs_n;

        if (cke && selected && cmd != C_NOP) {
            if (now_ < T_INIT_NS)
                fail("command issued before the 100 us power-up interval");

            switch (cmd) {
            case C_MRS: {
                if (any_bank_active())
                    fail("LOAD MODE REGISTER with a bank still active");
                const uint32_t burst_code = a & 0x7;
                const bool     burst_type = (a >> 3) & 1;
                const uint32_t mr_cas     = (a >> 4) & 0x7;
                if (((a >> 10) & 1) || ((a >> 9) & 1))
                    fail("LOAD MODE REGISTER with reserved bits set");
                switch (burst_code) {
                    case 0: bl_ = 1; break;
                    case 1: bl_ = 2; break;
                    case 2: bl_ = 4; break;
                    case 3: bl_ = 8; break;
                    default: fail("mode register: reserved burst length");
                }
                if (mr_cas != 2 && mr_cas != 3)
                    fail("mode register: CAS latency must be 2 or 3");
                cl_ = (int)mr_cas;
                mr_programmed_ = true;
                t_mrs_done_ = now_ + T_MRD_NS;
                printf("SDRAM: mode register programmed - CL=%d BL=%d %s\n",
                       cl_, bl_, burst_type ? "interleaved" : "sequential");
                fflush(stdout);
                break;
            }
            case C_ACT: {
                if (!mr_programmed_) fail("ACTIVE before the mode register was set");
                if (now_ < t_mrs_done_)     fail("ACTIVE within tMRD of LOAD MODE REGISTER");
                if (now_ < t_refresh_done_) fail("ACTIVE within tRFC of AUTO REFRESH");
                if (bank_active_[ba])       fail("ACTIVE to a bank that already has a row open");
                if (now_ < t_precharge_[ba] + T_RP_NS)
                    fail("ACTIVE within tRP of the PRECHARGE that closed this bank");
                if (now_ < t_active_[ba] + T_RC_NS)
                    fail("ACTIVE within tRC of the previous ACTIVE on this bank");
                bank_active_[ba] = true;
                bank_row_[ba]    = a & ((1u << row_bits_) - 1);
                t_active_[ba]    = now_;
                break;
            }
            case C_RD: {
                if (!bank_active_[ba]) fail("READ to a bank with no row open");
                if (now_ < t_active_[ba] + T_RCD_NS) fail("READ within tRCD of ACTIVE");
                if ((a >> 10) & 1)
                    fail("READ with A[10] set: that is read auto-precharge, and this "
                         "controller believes the row stays open");
                const uint32_t col  = a & (ncols_ - 1);
                const uint32_t bidx = flat_addr(ba, bank_row_[ba], col);
                if (bidx + (uint32_t)bl_ > mem_.size())
                    fail("read beyond the modelled storage - raise +sdram_words");
                if (col + (uint32_t)bl_ > ncols_)
                    fail("read burst would cross a row boundary");
                for (int i = 0; i < bl_; i++) {
                    // cl-1, not cl. That indexing was changed to cl while
                    // chasing the hardware failure in fpga/README.md, on the
                    // reasoning that CAS latency means the data is *launched*
                    // cl edges after the command. It made the configuration
                    // the board actually ran fail catastrophically in
                    // simulation, and the board did not fail catastrophically
                    // - it failed one word in a thousand. The bench is the
                    // ground truth and the change was reverted, there and
                    // therefore here.
                    const int slot = cl_ - 1 + i;
                    nv[slot] = true;
                    nd[slot] = mem_[bidx + i];
                }
                break;
            }
            case C_WR: {
                if (!bank_active_[ba]) fail("WRITE to a bank with no row open");
                if (now_ < t_active_[ba] + T_RCD_NS) fail("WRITE within tRCD of ACTIVE");
                if ((a >> 10) & 1)
                    fail("WRITE with A[10] set - that is write auto-precharge");
                if (!dq_driven)
                    fail("WRITE issued with the data bus not driven");
                const uint32_t col  = a & (ncols_ - 1);
                const uint32_t cidx = flat_addr(ba, bank_row_[ba], col);
                if (cidx + (uint32_t)bl_ > mem_.size())
                    fail("write beyond the modelled storage - raise +sdram_words");
                if (col + (uint32_t)bl_ > ncols_)
                    fail("write burst would cross a row boundary");
                // The first word of a write burst is on the bus in the same
                // cycle as the command, which is what makes writes and reads
                // asymmetric and is a classic off-by-one in a controller.
                store(cidx, dq_in, dqm);
                t_write_end_[ba] = now_;
                wr_bank_     = ba;
                next_wr_col  = (col + 1) & (ncols_ - 1);
                next_wr_left = bl_ - 1;
                break;
            }
            case C_PRE: {
                // tRAS and tWR are the two intervals a controller gets wrong
                // by closing a row as soon as it has what it wanted. Neither
                // shows up as bad data in simulation.
                if ((a >> 10) & 1) {
                    for (int i = 0; i < NBANKS; i++) {
                        if (bank_active_[i]) {
                            if (now_ < t_active_[i] + T_RAS_NS)
                                fail("PRECHARGE ALL within tRAS of an ACTIVE");
                            if (now_ < t_write_end_[i] + T_WR_NS)
                                fail("PRECHARGE ALL within tWR of a write");
                            t_precharge_[i] = now_;
                        }
                        bank_active_[i] = false;
                    }
                } else {
                    if (bank_active_[ba]) {
                        if (now_ < t_active_[ba] + T_RAS_NS)
                            fail("PRECHARGE within tRAS of the ACTIVE on this bank");
                        if (now_ < t_write_end_[ba] + T_WR_NS)
                            fail("PRECHARGE within tWR of a write to this bank");
                        t_precharge_[ba] = now_;
                    }
                    bank_active_[ba] = false;
                }
                break;
            }
            case C_REF: {
                if (any_bank_active()) fail("AUTO REFRESH with a bank still active");
                if (now_ < t_refresh_done_)
                    fail("AUTO REFRESH within tRFC of the previous one");
                refresh_count_++;
                t_last_refresh_ = now_;
                t_refresh_done_ = now_ + T_RFC_NS;
                break;
            }
            case C_BST:
                break;   // burst terminate: legal, and this controller never uses it
            default:
                fail("unrecognised command on the SDRAM bus");
            }
        }

        memcpy(pipe_d_, nd, sizeof(pipe_d_));
        memcpy(pipe_v_, nv, sizeof(pipe_v_));
        wr_left_ = next_wr_left;
        wr_col_  = next_wr_col;
    }

    // What the part is driving after the edge above. Valid T_AC_NS later on a
    // board; check_ac_margin() is what makes ignoring that legitimate here.
    bool     driving() const { return pipe_v_[0]; }
    uint16_t data()     const { return pipe_d_[0]; }

private:
    enum { C_NOP = 0x7, C_ACT = 0x3, C_RD = 0x5, C_WR = 0x4,
           C_PRE = 0x2, C_REF = 0x1, C_MRS = 0x0, C_BST = 0x6 };

    void reset_state(double now) {
        for (int i = 0; i < NBANKS; i++) {
            bank_active_[i] = false;
            bank_row_[i]    = 0;
            t_active_[i]    = 0.0;
            t_precharge_[i] = now;
            t_write_end_[i] = 0.0;
        }
        for (int i = 0; i < PIPE; i++) { pipe_v_[i] = false; pipe_d_[i] = 0; }
        mr_programmed_  = false;
        cl_ = 0; bl_ = 0;
        t_last_refresh_ = now;
        t_refresh_done_ = 0.0;
        t_mrs_done_     = 0.0;
        wr_left_ = 0; wr_bank_ = 0; wr_col_ = 0;
        now_ = now;
    }

    bool any_bank_active() const {
        for (int i = 0; i < NBANKS; i++) if (bank_active_[i]) return true;
        return false;
    }

    void store(uint32_t idx, uint16_t d, uint32_t dqm) {
        if (!(dqm & 1)) mem_[idx] = (uint16_t)((mem_[idx] & 0xFF00) | (d & 0x00FF));
        if (!(dqm & 2)) mem_[idx] = (uint16_t)((mem_[idx] & 0x00FF) | (d & 0xFF00));
    }

    // Must be the inverse of the mapping in rtl/soc/wb_sdram.v. Written out
    // rather than shared, so that a change on one side shows up as a failing
    // test instead of following the other side silently.
    uint32_t flat_addr(uint32_t b, uint32_t r, uint32_t c) const {
        return (r << (col_bits_ + BA_BITS)) | (b << col_bits_) | c;
    }

    [[noreturn]] void fail(const char *why) const {
        printf("\n");
        printf("SDRAM PROTOCOL ERROR at %.0f ns: %s\n", now_, why);
        printf("  bank states: %d %d %d %d  refreshes so far: %ld\n",
               bank_active_[0], bank_active_[1], bank_active_[2],
               bank_active_[3], refresh_count_);
        fflush(stdout);
        exit(1);
    }

    int      row_bits_, col_bits_;
    uint32_t ncols_;
    std::vector<uint16_t> mem_;

    bool     bank_active_[NBANKS];
    uint32_t bank_row_[NBANKS];
    double   t_active_[NBANKS], t_precharge_[NBANKS], t_write_end_[NBANKS];

    bool   mr_programmed_;
    int    cl_, bl_;
    double t_last_refresh_, t_refresh_done_, t_mrs_done_;
    long   refresh_count_;

    uint16_t pipe_d_[PIPE];
    bool     pipe_v_[PIPE];

    int      wr_left_;
    uint32_t wr_bank_, wr_col_;

    double now_;
};

// ---------------------------------------------------------------------------
// An Sv32 walk in C++, for checking the one in rtl/mmu.v
// ---------------------------------------------------------------------------
// Deliberately written from the spec rather than from mmu.v: a re-implementation
// that copies the design's structure agrees with its bugs. Two levels, leaf at
// either, and no permission checking - this is here to answer "is that the
// right address", and the hardware has already said it did not fault.
//
// Returns false when the walk cannot be completed from the modelled part -
// a table outside the SDRAM window, which is not a disagreement.
struct Sv32 {
    static bool walk(SdramModel &mem, uint32_t satp_ppn, uint32_t va,
                     uint32_t *pa_out)
    {
        uint32_t pte1;
        if (!read32(mem, (satp_ppn << 12) + ((va >> 22) << 2), &pte1))
            return false;
        if (!(pte1 & 1))                       return false;   // invalid
        if (pte1 & 0x2 || pte1 & 0x8) {                        // R or X: leaf
            *pa_out = ((pte1 >> 20) << 22) | (va & 0x3FFFFF);
            return true;
        }
        uint32_t pte2;
        if (!read32(mem, ((pte1 >> 10) << 12) + (((va >> 12) & 0x3FF) << 2),
                    &pte2))
            return false;
        if (!(pte2 & 1))                       return false;
        *pa_out = ((pte2 >> 10) << 12) | (va & 0xFFF);
        return true;
    }

private:
    static bool read32(SdramModel &mem, uint32_t addr, uint32_t *out)
    {
        if ((addr >> 24) != 0x90 && (addr >> 24) != 0x91) return false;
        const uint32_t w = (addr - 0x90000000u) >> 1;
        if (w + 1 >= mem.words()) return false;
        *out = mem.storage()[w] | ((uint32_t)mem.storage()[w + 1] << 16);
        return true;
    }
};

// ---------------------------------------------------------------------------
// UART receiver, same shape as the SoC testbenches: hunt for the start bit,
// then sample each of the eight data bits in the middle of its window.
// ---------------------------------------------------------------------------
class UartRx {
public:
    explicit UartRx(bool quiet) : quiet_(quiet) {}

    // Mid-bit sample points, from the same arithmetic the fixed-rate version
    // used: the start bit spans one period from the falling edge, so the
    // middle of data bit b is at 1.5 + b periods.
    int sample_at(int bit) const {
        return (3 * uart_clks_per_bit) / 2 + bit * uart_clks_per_bit;
    }

    void sample(bool tx) {
        if (idle_) {
            if (prev_ && !tx) { idle_ = false; cnt_ = 0; bit_ = 0; byte_ = 0; }
        } else {
            cnt_++;
            // The middle of data bit b; see sample_at(). At the default rate
            // this is 6+4b, which is what the Verilog testbenches reach by
            // waiting half a bit and then one bit per sample.
            if (cnt_ == sample_at(bit_)) {
                if (tx) byte_ |= (uint8_t)(1u << bit_);
                if (++bit_ == 8) {
                    idle_ = true;
                    if (uart_check) uart_wire_byte(byte_);
                    if (!quiet_) { putchar((int)byte_); fflush(stdout); }
                    if (!uart_stop_on.empty() && !uart_stop_hit) {
                        tail_ += (char)byte_;
                        if (tail_.size() > uart_stop_on.size())
                            tail_.erase(0, tail_.size() - uart_stop_on.size());
                        if (tail_ == uart_stop_on) uart_stop_hit = true;
                    }
                }
            }
        }
        prev_ = tx;
    }

private:
    bool    quiet_;
    bool    idle_ = true;
    bool    prev_ = true;
    int     cnt_  = 0;
    int     bit_  = 0;
    uint8_t byte_ = 0;
    std::string tail_;      // the last uart_stop_on.size() bytes received
};

// ---------------------------------------------------------------------------
// $readmemh, enough of it for the images software/bin2hex.py writes: one
// hexadecimal word per line, no addresses, no comments.
// ---------------------------------------------------------------------------
template <typename T>
static size_t load_hex(const char *path, T *dst, size_t capacity) {
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "cannot open image '%s'\n", path); exit(1); }
    char line[256];
    size_t n = 0;
    while (fgets(line, sizeof(line), f)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '\n' || *p == '\r' || *p == '\0' || *p == '/') continue;
        if (n >= capacity) {
            fprintf(stderr, "image '%s' is larger than the %zu words it loads into\n",
                    path, capacity);
            exit(1);
        }
        dst[n++] = (T)strtoull(p, nullptr, 16);
    }
    fclose(f);
    return n;
}

// Every occurrence of a repeated plusarg, in order. `+peek` is the only user:
// one address is rarely enough when the question is "which of these grew".
static std::vector<std::string> plusargs_all(int argc, char **argv,
                                             const char *name) {
    std::vector<std::string> out;
    const size_t len = strlen(name);
    for (int i = 1; i < argc; i++) {
        if (argv[i][0] != '+') continue;
        const char *s = argv[i] + 1;
        if (strncmp(s, name, len) == 0 && s[len] == '=')
            out.push_back(s + len + 1);
    }
    return out;
}

static const char *plusarg(int argc, char **argv, const char *name) {
    const size_t len = strlen(name);
    for (int i = 1; i < argc; i++) {
        if (argv[i][0] != '+') continue;
        const char *s = argv[i] + 1;
        if (strncmp(s, name, len) != 0) continue;
        if (s[len] == '=') return s + len + 1;
        if (s[len] == '\0') return "";
    }
    return nullptr;
}

static long plusarg_long(int argc, char **argv, const char *name, long dflt) {
    const char *v = plusarg(argc, argv, name);
    return (v && *v) ? strtol(v, nullptr, 0) : dflt;
}

// ---------------------------------------------------------------------------
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    const char *sdram_img = plusarg(argc, argv, "sdram");
    const char *rom_img   = plusarg(argc, argv, "rom");
    const char *ram_img   = plusarg(argc, argv, "ram");
    const char *dump      = plusarg(argc, argv, "dump");
    const bool  quiet     = plusarg(argc, argv, "quiet") != nullptr;

    // 4 MB of modelled storage by default, matching sim/tb_sdramboot.v: the
    // program's LOAD and RUN regions occupy the first megabyte and
    // sdramtest.c's sweep runs from 0x9010_0000 for 256 KB.
    const size_t sdram_words = (size_t)plusarg_long(argc, argv, "sdram_words", 1L << 21);
    const long   max_cycles  = plusarg_long(argc, argv, "maxcycles", 40000000L);
    // Long enough for the last line of output to clear a 4-clocks-per-bit
    // UART, which is what the Verilog testbenches wait too.
    uart_clks_per_bit = (int)plusarg_long(argc, argv, "uart_clks", 4);
    if (const char *v = plusarg(argc, argv, "stopon")) uart_stop_on = v;
    const long   drain       = plusarg_long(argc, argv, "drain",
                                            200L * uart_clks_per_bit * 10);

    // The verdict lives in block RAM, not in the memory under test, exactly
    // as sim/tb_sdramboot.v arranges it: a broken SDRAM then shows up as a
    // timeout with whatever output got out, not as a corrupt magic word that
    // might read "PASS" by luck.
    const uint32_t RESULT_PASS = 0x50415353;   // "PASS"
    const uint32_t RESULT_FAIL = 0x4641494C;   // "FAIL"

    Vsoc_top *top = new Vsoc_top;
    auto     *root = top->rootp;

    SdramModel sdram(13, 9, sdram_words);
    sdram.check_ac_margin();
    UartRx uart(quiet);

#if VM_TRACE
    VerilatedVcdC *tfp = nullptr;
    if (dump) {
        Verilated::traceEverOn(true);
        tfp = new VerilatedVcdC;
        top->trace(tfp, 99);
        tfp->open(*dump ? dump : "wave_verilator_soc.vcd");
    }
#else
    if (dump) {
        fprintf(stderr, "+dump needs a build with tracing: make verilator_soc VTRACE=1\n");
        exit(1);
    }
#endif

    if (sdram_img) {
        size_t n = load_hex(sdram_img, sdram.storage(), sdram.words());
        printf("SDRAM image: %zu 16-bit words from %s\n", n, sdram_img);
    }

    top->rst      = 1;
    top->uart_rx  = 1;
    top->spi_miso = 1;      // no card; MISO idles high
    top->gpio_in  = 0;
    top->sdram_dq_i = 0;

    // Settle at time 0 with the clock low and reset asserted, before the
    // first rising edge - which is what `reg clk = 0; reg rst = 1;` gives the
    // Verilog testbenches for free, and what an eval-free start does not.
    // Without this the design's asynchronous resets have not reached the
    // output pins on the first rising edge, and uart_tx spends that one cycle
    // low: a falling edge on an idle-high line, which the receiver below
    // dutifully decodes as a start bit and reports as a 0xFF byte that no
    // program sent.
    top->clk = 0;
    top->eval();

    // ---- the *Verilog* arrays, and why they are loaded here and not above ----
    //
    // rtl/soc/wb_ram.v and wb_rom.v both open with an `initial` block that
    // zero-fills the array (Verilog leaves an unwritten one X, and several
    // testbenches load an image smaller than the memory and expect the rest
    // to read zero). Verilator runs `initial` blocks on the *first* eval(),
    // which is the line above - so anything written into those arrays before
    // it is erased before the first instruction is fetched.
    //
    // That is not a hypothetical. `+ram=` and `+rom=` were documented at the
    // top of this file and had never worked: loading a block-RAM program
    // produced a machine that fetched zeros from its reset vector and trapped
    // on cycle 7 with mcause=2, mtval=0, forever. It printed nothing, which
    // reads as "the program hung" rather than "the program is not there".
    // Nothing had noticed because every run until now started from SDRAM,
    // which is a C++ model this does not apply to.
    //
    // The SDRAM image above is loaded before eval() and stays loaded for
    // exactly that reason: it goes into SdramModel, not into an array the
    // design's own initial block owns.
    if (rom_img) {
        size_t n = load_hex(rom_img, &root->soc_top__DOT__ROM__DOT__mem[0],
                            sizeof(root->soc_top__DOT__ROM__DOT__mem) / sizeof(uint32_t));
        printf("ROM image: %zu words from %s\n", n, rom_img);
    }
    if (ram_img) {
        size_t n = load_hex(ram_img, &root->soc_top__DOT__RAM__DOT__mem[0],
                            sizeof(root->soc_top__DOT__RAM__DOT__mem) / sizeof(uint32_t));
        printf("RAM image: %zu words from %s\n", n, ram_img);
    }

    printf("=== SoC running from external SDRAM (Verilator) ===\n");
    fflush(stdout);

    const auto   wall_start = std::chrono::steady_clock::now();
    long         cycles     = 0;
    // soc_top exports `trap` for exactly this: a program that produces no
    // output has either not started or is trapping, and those want different
    // fixes. Counting is cheap and the first number worth having when a
    // firmware image prints nothing at all.
    long         traps      = 0;
    long         first_trap = -1;
    uint32_t     first_trap_pc = 0, first_trap_cause = 0;
    uint32_t     first_trap_epc = 0, first_trap_tval = 0;
    bool         capture_trap_next = false;
    const uint32_t watch_pc = (uint32_t)plusarg_long(argc, argv, "watchpc", 0);
    bool         watch_hit = false;
    const bool   watch_last = plusarg(argc, argv, "watchlast") != nullptr;
    const long   watch_skew = plusarg_long(argc, argv, "watchskew", 3);
    long         watch_arm  = -1;   // cycles left before sampling the regfile
    long         watch_cycle = -1;  // when the sample was taken
    long         watch_count = 0;
    uint32_t     watch_regs[32] = {0};
    // Capacity is cheap - two uint32_t per entry - and was 16 for years,
    // which is enough to see a tight spin but not enough to see who called
    // into a function a dozen calls deep before wedging. `+branch_hist=N`
    // (below) controls how many of these get printed; the default there is
    // still 16, so nothing about a plain run's output changes.
    static const int BRANCH_RING = 200000;
    uint32_t     branch_from[BRANCH_RING] = {0}, branch_to[BRANCH_RING] = {0};
    const long   branch_print_n = plusarg_long(argc, argv, "branch_hist", 16);
    long         branch_n = 0;
    uint32_t     prev_pc = 0;
    uint32_t     pc_lo = 0xFFFFFFFFu, pc_hi = 0;
    // Only the tail of the run: early PCs are startup and say nothing about
    // where it ended up.
    const long   pc_window_from = plusarg_long(argc, argv, "pcwindow",
                                               max_cycles > 2000 ? max_cycles - 2000 : 0);
    long         verdict_at = -1;
    long         stop_at    = -1;   // cycle +stopon's text completed
    const bool   check_reads = plusarg(argc, argv, "checkreads") != nullptr;
    long         reads_checked = 0;
    long         reads_bad     = 0;
    const bool   check_fetch = plusarg(argc, argv, "checkfetch") != nullptr;
    long         fetch_checked = 0;
    long         fetch_bad     = 0;
    const bool   check_dec = plusarg(argc, argv, "checkdecode") != nullptr;
    long         dec_checked = 0;
    long         dec_bad     = 0;
    const bool   check_mmu  = plusarg(argc, argv, "checkmmu") != nullptr;
    long         xlat_checked = 0;
    long         xlat_bad     = 0;
    // What the check skipped, counted rather than left silent. See the two
    // `continue`s in the loop below: a translation the hardware *faulted* is
    // not compared, and neither is one the C++ walk cannot map. Both are
    // reasonable - this model resolves addresses and does not model
    // permissions, so it has nothing to say about a fault - but "355,033,084
    // translations checked, all agreed" reads as coverage of the whole MMU,
    // and it is coverage of the successful half. On the wide core's failing
    // Linux boot the skipped set is *four* translations, and one of them is
    // the store page fault that ends the boot.
    long         xlat_faulted = 0;
    long         xlat_unmapped = 0;
    uart_check = plusarg(argc, argv, "checkuart") != nullptr;

    // +pipetrace=FROM:TO:FILE
    long  pt_from = 0, pt_to = -1;
    FILE *pt_fp = nullptr;
    if (const char *spec = plusarg(argc, argv, "pipetrace")) {
        const std::string sp(spec);
        const size_t c1 = sp.find(':');
        const size_t c2 = (c1 == std::string::npos) ? c1 : sp.find(':', c1 + 1);
        if (c2 == std::string::npos) {
            printf("pipetrace \"%s\": expected FROM:TO:FILE\n", spec);
        } else {
            pt_from = strtol(sp.substr(0, c1).c_str(), nullptr, 0);
            pt_to   = strtol(sp.substr(c1 + 1, c2 - c1 - 1).c_str(), nullptr, 0);
            pt_fp   = fopen(sp.substr(c2 + 1).c_str(), "w");
            if (!pt_fp) printf("pipetrace: cannot write %s\n",
                               sp.substr(c2 + 1).c_str());
            else fprintf(pt_fp, "%-10s %-8s %-8s %-8s %-3s %-3s %-14s %-3s %-3s %s\n",
                         "cycle", "fetchpc", "ifidpc", "ifidins", "we",
                         "ret", "wb", "rdr", "mis", "pred|imemaddr imemdata iwait");
        }
    }

    FILE *tt_fp = nullptr;
    if (const char *f = plusarg(argc, argv, "traptrace")) {
        tt_fp = fopen(f, "w");
        if (!tt_fp) printf("traptrace: cannot write %s\n", f);
        else fprintf(tt_fp, "# cycle pc priv to scause sepc stval "
                            "mcause mepc mtval satp\n");
    }
    // One-deep pending slot for the trap whose CSRs are not written yet.
    bool     tt_pending    = false;
    long     tt_cycle      = 0;
    uint32_t tt_pc         = 0;
    uint32_t tt_priv       = 0;
    uint32_t tt_to_s       = 0;

    // +writetrace=ADDR:LEN:FILE, parsed exactly like +readtrace below.
    uint32_t  wt_lo = 0, wt_hi = 0;
    FILE     *wt_fp = nullptr;
    if (const char *spec = plusarg(argc, argv, "writetrace")) {
        const std::string sp(spec);
        const size_t c1 = sp.find(':');
        const size_t c2 = sp.find(':', c1 + 1);
        if (c1 == std::string::npos || c2 == std::string::npos) {
            printf("writetrace \"%s\": expected ADDR:LEN:FILE\n", spec);
        } else {
            wt_lo = (uint32_t)strtoul(sp.substr(0, c1).c_str(), nullptr, 0);
            wt_hi = wt_lo + (uint32_t)strtoul(
                        sp.substr(c1 + 1, c2 - c1 - 1).c_str(), nullptr, 0);
            wt_fp = fopen(sp.substr(c2 + 1).c_str(), "w");
            if (!wt_fp) printf("writetrace: cannot write %s\n",
                               sp.substr(c2 + 1).c_str());
            else fprintf(wt_fp, "# cycle address data sel master\n");
        }
    }

    // +readtrace=ADDR:LEN:FILE
    uint32_t  rt_lo = 0, rt_hi = 0;
    FILE     *rt_fp = nullptr;
    if (const char *spec = plusarg(argc, argv, "readtrace")) {
        const std::string sp(spec);
        const size_t c1 = sp.find(':');
        const size_t c2 = (c1 == std::string::npos) ? c1 : sp.find(':', c1 + 1);
        if (c2 == std::string::npos) {
            printf("readtrace \"%s\": expected ADDR:LEN:FILE\n", spec);
        } else {
            rt_lo = (uint32_t)strtoul(sp.substr(0, c1).c_str(), nullptr, 0);
            rt_hi = rt_lo + (uint32_t)strtoul(
                        sp.substr(c1 + 1, c2 - c1 - 1).c_str(), nullptr, 0);
            rt_fp = fopen(sp.substr(c2 + 1).c_str(), "w");
            if (!rt_fp) printf("readtrace: cannot write %s\n",
                               sp.substr(c2 + 1).c_str());
        }
    }
    uint32_t     result     = 0;
    double       now_ns     = 0.0;

    for (;;) {
        // ---- the controller's rising edge ----
        now_ns = CLK_HALF_NS + CLK_PERIOD_NS * (double)cycles;
        top->clk = 1;
        top->eval();
        cycles++;
#if VM_TRACE
        if (tfp) tfp->dump((uint64_t)now_ns);
#endif

        // sim/tb_sdramboot.v releases reset after four posedges.
        if (cycles == 4) top->rst = 0;

        uart.sample(top->uart_tx != 0);

        // ---- and the other end of the same wire ----
        //
        // `write_thr` is combinational off the bus, so after this eval() it is
        // the write the *next* edge will take - and `tx_state` is what that
        // edge will see, because nothing but a THR write moves the
        // transmitter out of TX_IDLE. So the two read here are consistent:
        // busy now means this write is about to be discarded.
        if (uart_check && root->soc_top__DOT__UART__DOT__write_thr)
            uart_thr_write((uint8_t)root->soc_top__DOT__UART__DOT__wdata,
                           root->soc_top__DOT__UART__DOT__tx_state != 0,
                           cycles);

        // `trap` is a combinational pulse in EX; mcause/mepc/mtval are
        // written by the same edge, so reading them on the pulse cycle
        // returns the *previous* trap's values - which for the first trap is
        // three zeros, and looks exactly like "cause 0, misaligned fetch at
        // address 0". Sample one cycle later instead.
        if (capture_trap_next) {
            capture_trap_next = false;
            first_trap_cause  = root->soc_top__DOT__CPU__DOT__CSR__DOT__mcause_r;
            first_trap_epc    = root->soc_top__DOT__CPU__DOT__CSR__DOT__mepc_r;
            first_trap_tval   = root->soc_top__DOT__CPU__DOT__CSR__DOT__mtval_r;
        }
        // ---- every read, against what the part holds ----
        //
        // The interconnect's `fin_ack` is the acknowledgement it hands the
        // owning master, and `fin_dat` the word it hands over with it, so
        // this is the last point where the data is still the bus's rather
        // than a cache's. Comparing it with the model's storage catches a
        // controller, an arbiter or a decode returning the wrong word -
        // which is invisible from software, because software has nothing to
        // compare against.
        //
        // Writes are skipped rather than checked: the controller may
        // acknowledge one before the array has taken it, so a write's
        // `fin_dat` is not a claim about memory.
        if (wt_fp &&
            root->soc_top__DOT__BUS__DOT__fin_ack &&
            root->soc_top__DOT__BUS__DOT__s_we) {
            const uint32_t a = root->soc_top__DOT__BUS__DOT__s_adr;
            if (a >= wt_lo && a < wt_hi)
                fprintf(wt_fp, "%ld %08x %08x %x %s\n", cycles, a,
                        root->soc_top__DOT__BUS__DOT__s_dat_w,
                        root->soc_top__DOT__BUS__DOT__s_sel,
                        root->soc_top__DOT__BUS__DOT__sel_m1 ? "data" :
                        root->soc_top__DOT__BUS__DOT__sel_m2 ? "walker"
                                                             : "fetch");
        }

        if (rt_fp &&
            root->soc_top__DOT__BUS__DOT__fin_ack &&
            !root->soc_top__DOT__BUS__DOT__s_we) {
            const uint32_t a = root->soc_top__DOT__BUS__DOT__s_adr;
            if (a >= rt_lo && a < rt_hi)
                fprintf(rt_fp, "%ld %08x %08x %s\n", cycles, a,
                        root->soc_top__DOT__BUS__DOT__fin_dat,
                        root->soc_top__DOT__BUS__DOT__sel_m1 ? "data" :
                        root->soc_top__DOT__BUS__DOT__sel_m2 ? "walker"
                                                             : "fetch");
        }

        if (check_reads &&
            root->soc_top__DOT__BUS__DOT__fin_ack &&
            !root->soc_top__DOT__BUS__DOT__s_we) {
            const uint32_t a = root->soc_top__DOT__BUS__DOT__s_adr;
            if ((a >> 24) == 0x90 || (a >> 24) == 0x91) {
                const uint32_t w = (a - 0x90000000u) >> 1;
                if (w + 1 < sdram.words()) {
                    const uint32_t want = sdram.storage()[w] |
                                          ((uint32_t)sdram.storage()[w + 1] << 16);
                    const uint32_t got = root->soc_top__DOT__BUS__DOT__fin_dat;
                    reads_checked++;
                    if (got != want) {
                        reads_bad++;
                        if (reads_bad <= 12) {
                            const char *who =
                                root->soc_top__DOT__BUS__DOT__sel_m1 ? "data" :
                                root->soc_top__DOT__BUS__DOT__sel_m2 ? "walker"
                                                                     : "fetch";
                            printf("\n** bad read at cycle %ld: [0x%08x] = "
                                   "0x%08x, bus returned 0x%08x (%s master)\n",
                                   cycles, a, want, got, who);
                        }
                    }
                }
            }
        }

        // ---- and every instruction the core takes ----
        //
        // `ibus_wait` low means the word on `imem_rdata` is the one the core
        // is about to execute, whether it came from the cache or the bus.
        if (check_fetch && !root->soc_top__DOT__BUSADAPT__DOT__ibus_wait) {
            const uint32_t a = root->soc_top__DOT__BUSADAPT__DOT__imem_addr & ~3u;
            if ((a >> 24) == 0x90 || (a >> 24) == 0x91) {
                const uint32_t w = (a - 0x90000000u) >> 1;
                if (w + 1 < sdram.words()) {
                    const uint32_t want = sdram.storage()[w] |
                                          ((uint32_t)sdram.storage()[w + 1] << 16);
                    const uint32_t got = root->soc_top__DOT__BUSADAPT__DOT__imem_rdata;
                    fetch_checked++;
                    if (got != want) {
                        fetch_bad++;
                        if (fetch_bad <= 12)
                            printf("\n** bad fetch at cycle %ld: [0x%08x] = "
                                   "0x%08x, core got 0x%08x\n",
                                   cycles, a, want, got);
                    }
                }
            }
        }

        // ---- is the decoder looking at the instruction at its own PC? ----
        //
        // Factored into a lambda because the wide core has *two* issue slots
        // and both need it. Slot 0 is checked at IF/ID, where both cores have
        // the signal; the wide core's slot 1 is formed later, at issue, so it
        // is checked at ID/EX. Same question either way: is the instruction
        // this stage is holding the one that lives at the PC it is attributed
        // to.
        auto check_one_decode = [&](uint32_t va, uint32_t got) {
            const uint32_t satp = root->soc_top__DOT__CPU__DOT__IMMU__DOT__satp_ppn;
            uint32_t pa = va;
            bool have = true;
            if (satp)                       // paging on: translate as the hart would
                have = Sv32::walk(sdram, satp, va, &pa);
            if (!have) return;
            if ((pa >> 24) != 0x90 && (pa >> 24) != 0x91) return;
            const uint32_t w = (pa - 0x90000000u) >> 1;
            if (w + 1 >= sdram.words()) return;
            const uint32_t want = sdram.storage()[w] |
                                  ((uint32_t)sdram.storage()[w + 1] << 16);
            dec_checked++;
            if (got != want) {
                dec_bad++;
                if (dec_bad <= 12)
                    printf("\n** decoding the wrong instruction at cycle "
                           "%ld: pc 0x%08x (pa 0x%08x) holds 0x%08x, "
                           "decoder has 0x%08x\n",
                           cycles, va, pa, want, got);
            }
        };

        if (check_dec && root->soc_top__DOT__CPU__DOT__if_id_valid)
            check_one_decode(root->soc_top__DOT__CPU__DOT__if_id_pc,
                             root->soc_top__DOT__CPU__DOT__if_id_instr);

#ifdef CORE_OOO
        // The second issue slot, which nothing checked until now.
        //
        // The wide core dual-issues, so "52.8 million decoded instructions all
        // matched their PC" was a statement about slot 0 alone. Adding this
        // takes the same boot to 56.6 million - 7% more, not the half it was
        // assumed to be, because the second slot only issues one class of
        // single-cycle ALU op. Small, and exactly the part that exists only
        // on the core with a failing Linux boot. docs/practices.md §31.
        if (check_dec && root->soc_top__DOT__CPU__DOT__id_ex1_valid)
            check_one_decode(root->soc_top__DOT__CPU__DOT__id_ex1_pc,
                             root->soc_top__DOT__CPU__DOT__id_ex1_instr);
#endif

        // ---- and every translation, against the tables it came from ----
        if (check_mmu) {
            // The address the hardware actually translated: the live `va` on
            // a TLB hit (state S_IDLE), the latched `va_r` on a concluded
            // walk. Getting this wrong is not a subtle inaccuracy - it
            // manufactures disagreements on every walk, because the live one
            // has moved on. See sim/verilator_soc.vlt.
            struct { const char *name; uint32_t req, resolved, fault, va, satp, pa; } t[2] = {
                {"itlb",
                 root->soc_top__DOT__CPU__DOT__IMMU__DOT__req,
                 root->soc_top__DOT__CPU__DOT__IMMU__DOT__resolved,
                 root->soc_top__DOT__CPU__DOT__IMMU__DOT__fault,
                 root->soc_top__DOT__CPU__DOT__IMMU__DOT__state == 0
                     ? root->soc_top__DOT__CPU__DOT__IMMU__DOT__va
                     : root->soc_top__DOT__CPU__DOT__IMMU__DOT__va_r,
                 root->soc_top__DOT__CPU__DOT__IMMU__DOT__satp_ppn,
                 root->soc_top__DOT__CPU__DOT__IMMU__DOT__pa},
                {"dtlb",
                 root->soc_top__DOT__CPU__DOT__MMU__DOT__req,
                 root->soc_top__DOT__CPU__DOT__MMU__DOT__resolved,
                 root->soc_top__DOT__CPU__DOT__MMU__DOT__fault,
                 root->soc_top__DOT__CPU__DOT__MMU__DOT__state == 0
                     ? root->soc_top__DOT__CPU__DOT__MMU__DOT__va
                     : root->soc_top__DOT__CPU__DOT__MMU__DOT__va_r,
                 root->soc_top__DOT__CPU__DOT__MMU__DOT__satp_ppn,
                 root->soc_top__DOT__CPU__DOT__MMU__DOT__pa},
            };
            for (int k = 0; k < 2; k++) {
                if (!t[k].resolved) continue;
                if (t[k].fault) { xlat_faulted++; continue; }
                uint32_t want;
                if (!Sv32::walk(sdram, t[k].satp, t[k].va, &want)) {
                    xlat_unmapped++;
                    continue;
                }
                xlat_checked++;
                if (want != t[k].pa) {
                    xlat_bad++;
                    if (xlat_bad <= 12)
                        printf("\n** bad %s translation at cycle %ld: "
                               "va 0x%08x -> 0x%08x, tables say 0x%08x "
                               "(satp ppn 0x%05x)\n",
                               t[k].name, cycles, t[k].va, t[k].pa, want,
                               t[k].satp);
                }
            }
        }

        if (pt_fp && cycles >= pt_from && cycles <= pt_to) {
            const bool we = root->soc_top__DOT__CPU__DOT__mem_wb_reg_we;
            const int  rd = root->soc_top__DOT__CPU__DOT__mem_wb_rd;
            char wb[16];
            if (we && rd) snprintf(wb, sizeof(wb), "x%-2d=%08x", rd,
                                   root->soc_top__DOT__CPU__DOT__mem_wb_wb_data);
            else          snprintf(wb, sizeof(wb), "%-14s", "-");
            fprintf(pt_fp, "%-10ld %08x %08x %08x %-3s %-3s %-14s %-3s %-3s %d/%08x\n",
                    cycles,
                    root->soc_top__DOT__CPU__DOT__pc,
                    root->soc_top__DOT__CPU__DOT__if_id_pc,
                    root->soc_top__DOT__CPU__DOT__if_id_instr,
                    root->soc_top__DOT__CPU__DOT__id_ex_reg_we ? "yes" : "-",
                    root->soc_top__DOT__CPU__DOT__instret_retire ? "yes" : "-",
                    wb,
                    root->soc_top__DOT__CPU__DOT__redirect_valid ? "yes" : "-",
                    root->soc_top__DOT__CPU__DOT__mispredict ? "yes" : "-",
                    root->soc_top__DOT__CPU__DOT__id_ex_pred_taken,
                    root->soc_top__DOT__CPU__DOT__id_ex_pred_target);
            fseek(pt_fp, -1, SEEK_CUR);
            fprintf(pt_fp, "|%08x %08x %s\n",
                    root->soc_top__DOT__BUSADAPT__DOT__imem_addr,
                    root->soc_top__DOT__BUSADAPT__DOT__imem_rdata,
                    root->soc_top__DOT__BUSADAPT__DOT__ibus_wait ? "wait" : "-");
        }

        // Flush the previous cycle's trap first: its CSRs are written now.
        // Doing this before capturing a new one is what makes back-to-back
        // traps come out as two records rather than one.
        if (tt_pending && tt_fp) {
            tt_pending = false;
            fprintf(tt_fp,
                    "%ld %08x %u %c %08x %08x %08x %08x %08x %08x %08x\n",
                    tt_cycle, tt_pc, tt_priv, tt_to_s ? 'S' : 'M',
                    root->soc_top__DOT__CPU__DOT__CSR__DOT__scause_r,
                    root->soc_top__DOT__CPU__DOT__CSR__DOT__sepc_r,
                    root->soc_top__DOT__CPU__DOT__CSR__DOT__stval_r,
                    root->soc_top__DOT__CPU__DOT__CSR__DOT__mcause_r,
                    root->soc_top__DOT__CPU__DOT__CSR__DOT__mepc_r,
                    root->soc_top__DOT__CPU__DOT__CSR__DOT__mtval_r,
                    root->soc_top__DOT__CPU__DOT__CSR__DOT__satp_r);
        }
        if (top->trap && tt_fp) {
            tt_pending = true;
            tt_cycle   = cycles;
            tt_pc      = root->soc_top__DOT__CPU__DOT__id_ex_pc;
            // Sampled with the trap, not after it: `current_priv` is updated
            // by the same edge that writes the cause registers, so a cycle
            // later this would read the mode the trap landed in.
            tt_priv    = root->soc_top__DOT__CPU__DOT__CSR__DOT__current_priv;
            // Which set this trap will write, read out of the delegation
            // logic itself. It is combinational off the cause, so it is only
            // valid in the cycle `trap` pulses.
            tt_to_s    = root->soc_top__DOT__CPU__DOT__CSR__DOT__trap_to_s;
        }

        if (top->trap) {
            traps++;
            if (first_trap < 0) {
                first_trap        = cycles;
                first_trap_pc     = root->soc_top__DOT__CPU__DOT__id_ex_pc;
                capture_trap_next = true;
            }
        }

        // The *retired* PC, not the fetch PC. See sim/verilator_soc.vlt: a
        // probe on the fetch PC fires on speculative addresses the pipeline
        // later squashes, and reports register values from a context that
        // never ran.
        const bool     retired = root->soc_top__DOT__CPU__DOT__instret_retire;
        const uint32_t ret_pc  = root->soc_top__DOT__CPU__DOT__id_ex_pc;

        // Arm on the match, sample `watch_skew` cycles later. See the note on
        // +watchskew: reading the register file in the retire cycle catches
        // the two preceding instructions mid-flight and reports what their
        // destinations held *before* the call being watched.
        if (watch_pc && (watch_last || !watch_hit) && retired &&
            ret_pc == watch_pc) {
            watch_count++;
            watch_arm = watch_skew;
        }
        if (watch_arm >= 0 && watch_arm-- == 0) {
            watch_hit = true;
            watch_cycle = cycles;
            for (int r = 0; r < 32; r++)
                watch_regs[r] = root->soc_top__DOT__CPU__DOT__RF__DOT__regs[r];
        }

        // ---- a ring of the last control transfers ----
        //
        // "It stopped and will not say why" is the characteristic failure of
        // bringing up firmware that owns the console, and a PC alone answers
        // only half of it: `sbi_hart_hang()` tells you OpenSBI gave up, not
        // which check gave up. The jump *into* it does.
        //
        // So: remember every non-sequential PC change, keep the last few, and
        // print them at the end. Two addresses per entry, straight into
        // addr2line. Cheap - one compare per cycle - and it is the difference
        // between a guess and a name.
        if (retired) {
            const uint32_t pc_now = ret_pc;
            if (pc_now != prev_pc + 4 && pc_now != prev_pc) {
                // Collapse a repeat of the immediately previous transfer.
                // Without this a two-instruction `wfi` spin overwrites the
                // whole ring within a microsecond and the trace shows only
                // the hang - which is the one thing already known.
                const long last = branch_n ? (branch_n - 1) % BRANCH_RING : -1;
                if (last < 0 || branch_from[last] != prev_pc ||
                    branch_to[last] != pc_now) {
                    branch_from[branch_n % BRANCH_RING] = prev_pc;
                    branch_to  [branch_n % BRANCH_RING] = pc_now;
                    branch_n++;
                }
            }
            prev_pc = pc_now;
        }

        // A rolling low/high water mark of the PC over the last stretch of the
        // run. A firmware that has wedged is almost always in a tight loop,
        // and the *range* it is looping over identifies the loop far better
        // than any single sample: a two-instruction `wfi` spin and a
        // thousand-instruction search look nothing alike.
        if (retired) {
            const uint32_t pc_now = ret_pc;
            if (cycles >= pc_window_from) {
                if (pc_now < pc_lo) pc_lo = pc_now;
                if (pc_now > pc_hi) pc_hi = pc_now;
            }
        }

        // Loopback on the pins the SoC is driving, which is what the board's
        // GPIO header does when nothing is plugged into it.
        top->gpio_in = top->gpio_out & top->gpio_dir;

        // ---- the verdict ----
        //
        // Read straight after eval(), which is the natural thing for a
        // cycle-based harness: the non-blocking write has already landed.
        //
        // sim/tb_sdramboot.v cannot see it at quite the same moment. It
        // watches the word from an `initial` block sitting on
        // `@(posedge clk)`, which resumes in the active region - before this
        // edge's non-blocking assignments - and counts cycles in a *second*
        // process on the same edge, whose ordering against the first is not
        // something Verilog defines. So the two simulators' totals can differ
        // by one cycle, in either direction.
        //
        // An earlier version of this file "corrected" for that with a
        // constant offset, fitted to the in-order core, where it produced an
        // exact match. Running the same check against the wide core showed
        // the offset there was zero, not one, and the correction turned a
        // clean run into a false failure. It is not a constant, and it is not
        // worth modelling: see verilator_compare.py, which allows the one
        // cycle explicitly and requires everything else to match exactly.
        result = root->soc_top__DOT__RAM__DOT__mem[0];
        if (verdict_at < 0 && (result == RESULT_PASS || result == RESULT_FAIL))
            verdict_at = cycles;

        // A console marker ends the run the same way the verdict word does,
        // drain included - the marker is usually not the last thing printed.
        if (uart_stop_hit && stop_at < 0) stop_at = cycles;

        if (verdict_at >= 0 && cycles >= verdict_at + drain) break;
        if (stop_at    >= 0 && cycles >= stop_at    + drain) break;
        if (cycles >= max_cycles) break;

        // ---- the part's rising edge, half a period later ----
        //
        // fpga/sdram_clk_out.v drives the SDRAM's clock from an ODDRX1F so
        // its rising edge lands on the internal clock's falling edge. Clocking
        // the model from the controller's own edge here would simulate a
        // machine no board is - and would be the *aligned* configuration that
        // hardware rejected.
        now_ns += CLK_HALF_NS;
        top->clk = 0;
        top->eval();
#if VM_TRACE
        if (tfp) tfp->dump((uint64_t)now_ns);
#endif

        sdram.edge(now_ns,
                   top->sdram_cke != 0, top->sdram_cs_n != 0,
                   top->sdram_ras_n != 0, top->sdram_cas_n != 0,
                   top->sdram_we_n != 0,
                   top->sdram_a, top->sdram_ba, top->sdram_dqm,
                   (uint16_t)top->sdram_dq_o, top->sdram_dq_oe != 0);

        top->sdram_dq_i = sdram.driving() ? sdram.data() : 0;
        top->eval();     // let the captured word settle before the next edge
    }

    const auto   wall_end = std::chrono::steady_clock::now();
    const double secs = std::chrono::duration<double>(wall_end - wall_start).count();

    if (wt_fp) fclose(wt_fp);
    if (rt_fp) fclose(rt_fp);
    if (tt_fp) {
        // A trap in the very last cycle leaves its record pending with its
        // CSRs unread. Writing it anyway, flagged, beats dropping it: the
        // last trap before a run ends is the one most likely to be the
        // interesting one.
        if (tt_pending)
            fprintf(tt_fp,
                    "%ld %08x %u %c - - - - - - -  # csrs unread: run ended\n",
                    tt_cycle, tt_pc, tt_priv, tt_to_s ? 'S' : 'M');
        fclose(tt_fp);
    }
    if (pt_fp) fclose(pt_fp);

#if VM_TRACE
    if (tfp) { tfp->close(); delete tfp; }
#endif

    printf("\n---------------------------------------------\n");
    printf("cycles: %ld\n", cycles);
    if (!uart_stop_on.empty()) {
        if (stop_at >= 0)
            printf("stopon \"%s\": seen at cycle %ld\n",
                   uart_stop_on.c_str(), stop_at);
        else
            printf("stopon \"%s\": never seen in %ld cycles\n",
                   uart_stop_on.c_str(), cycles);
    }
    if (check_reads) {
        if (reads_bad)
            printf("SDRAM reads checked: %ld, **%ld returned the wrong word**\n",
                   reads_checked, reads_bad);
        else
            printf("SDRAM reads checked: %ld, all matched the part\n",
                   reads_checked);
    }
    if (check_fetch) {
        if (fetch_bad)
            printf("instruction fetches checked: %ld, **%ld were the wrong "
                   "word**\n", fetch_checked, fetch_bad);
        else
            printf("instruction fetches checked: %ld, all matched memory\n",
                   fetch_checked);
    }
    if (check_dec) {
        if (dec_bad)
            printf("decoded instructions checked: %ld, **%ld were not the "
                   "instruction at their own PC**\n", dec_checked, dec_bad);
        else
            printf("decoded instructions checked: %ld, all matched their PC\n",
                   dec_checked);
    }
    if (check_mmu) {
        if (xlat_bad)
            printf("translations checked: %ld, **%ld disagreed with the page "
                   "tables**\n", xlat_checked, xlat_bad);
        else
            printf("translations checked: %ld, all agreed with the page "
                   "tables\n", xlat_checked);
        // Printed every time, including when the count is zero, so the line
        // above is never read as a statement about the whole MMU. This model
        // resolves addresses; it does not model permissions, so it has
        // nothing to say about whether a fault was *warranted* - and a fault
        // the hardware raised wrongly is invisible here by construction.
        printf("  not compared: %ld faulted in hardware, "
               "%ld the model could not map\n",
               xlat_faulted, xlat_unmapped);
    }
    if (uart_check) {
        // One byte may legitimately still be in the shift register when the
        // run ends - a timeout does not drain the console the way `+stopon`
        // does - and reporting that as lost would be the probe inventing a
        // fault on every run that times out. Anything beyond it is real.
        size_t stranded = uart_accepted.size();
        if (stranded && root->soc_top__DOT__UART__DOT__tx_state != 0) stranded--;
        if (uart_thr_dropped || uart_wire_bad || stranded)
            printf("UART bytes written to THR: %ld, **%ld dropped by the "
                   "transmitter**, %ld sent, %ld wrong on the wire, %zu never "
                   "sent\n",
                   uart_thr_writes, uart_thr_dropped, uart_wire_bytes,
                   uart_wire_bad, stranded);
        else
            printf("UART bytes written to THR: %ld, all %ld sent, in order\n",
                   uart_thr_writes, uart_wire_bytes);
    }
    if (traps) {
        printf("traps taken: %ld (first at cycle %ld)\n", traps, first_trap);
        printf("  first trap: pc=0x%08x mcause=0x%08x mepc=0x%08x mtval=0x%08x\n",
               first_trap_pc, first_trap_cause, first_trap_epc, first_trap_tval);
    } else {
        printf("traps taken: none\n");
    }
    if (pc_hi >= pc_lo)
        printf("pc over the last %ld cycles: 0x%08x .. 0x%08x\n",
               cycles - pc_window_from, pc_lo, pc_hi);
    if (watch_pc) {
        if (!watch_hit) {
            printf("watchpc 0x%08x: never reached\n", watch_pc);
        } else {
            static const char *abi[32] = {
                "zero","ra","sp","gp","tp","t0","t1","t2","s0","s1","a0","a1",
                "a2","a3","a4","a5","a6","a7","s2","s3","s4","s5","s6","s7",
                "s8","s9","s10","s11","t3","t4","t5","t6"};
            printf("registers at pc 0x%08x (%s of %ld visits, cycle %ld):\n",
                   watch_pc, watch_last ? "last" : "first", watch_count,
                   watch_cycle);
            for (int r = 0; r < 32; r += 4) {
                printf("  ");
                for (int c = 0; c < 4; c++)
                    printf("%-4s 0x%08x  ", abi[r + c], watch_regs[r + c]);
                printf("\n");
            }
        }
    }
    for (const std::string &spec : plusargs_all(argc, argv, "savemem")) {
        // ADDR:LEN:FILE
        const size_t c1 = spec.find(':');
        const size_t c2 = (c1 == std::string::npos) ? c1 : spec.find(':', c1 + 1);
        if (c2 == std::string::npos) {
            printf("savemem \"%s\": expected ADDR:LEN:FILE\n", spec.c_str());
            continue;
        }
        const uint32_t addr = (uint32_t)strtoul(spec.substr(0, c1).c_str(), nullptr, 0);
        const uint32_t len  = (uint32_t)strtoul(spec.substr(c1 + 1, c2 - c1 - 1).c_str(),
                                                nullptr, 0);
        const std::string path = spec.substr(c2 + 1);

        if ((addr >> 24) != 0x90 && (addr >> 24) != 0x91) {
            printf("savemem 0x%08x: not in the SDRAM window\n", addr);
            continue;
        }
        const uint32_t w0 = (addr - 0x90000000u) >> 1;
        if (w0 + (len + 1) / 2 > sdram.words()) {
            printf("savemem 0x%08x+%u: past the modelled storage\n", addr, len);
            continue;
        }
        FILE *f = fopen(path.c_str(), "wb");
        if (!f) { printf("savemem: cannot write %s\n", path.c_str()); continue; }
        for (uint32_t i = 0; i < len; i++) {
            const uint16_t word = sdram.storage()[w0 + i / 2];
            fputc((i & 1) ? (word >> 8) : (word & 0xFF), f);
        }
        fclose(f);
        printf("savemem 0x%08x+%u -> %s\n", addr, len, path.c_str());
    }
    {
        const std::vector<std::string> peeks = plusargs_all(argc, argv, "peek");
        for (size_t i = 0; i < peeks.size() && i < 4; i++) {
            const uint32_t addr = (uint32_t)strtoul(peeks[i].c_str(), nullptr, 0);
            if ((addr >> 24) != 0x90 && (addr >> 24) != 0x91) {
                printf("peek 0x%08x: not in the SDRAM window\n", addr);
                continue;
            }
            const uint32_t w = (addr - 0x90000000u) >> 1;   // 16-bit words
            if (w + 1 >= sdram.words()) {
                printf("peek 0x%08x: past the modelled storage\n", addr);
                continue;
            }
            const uint32_t v = sdram.storage()[w] |
                               ((uint32_t)sdram.storage()[w + 1] << 16);
            printf("peek 0x%08x = 0x%08x (%u)\n", addr, v, v);
        }
    }
    if (branch_n) {
        printf("last control transfers (oldest first):\n");
        const long cap = branch_print_n < BRANCH_RING ? branch_print_n : BRANCH_RING;
        const long first = branch_n > cap ? branch_n - cap : 0;
        for (long i = first; i < branch_n; i++)
            printf("  0x%08x -> 0x%08x\n",
                   branch_from[i % BRANCH_RING], branch_to[i % BRANCH_RING]);
    }
    {
        const uint32_t div = root->soc_top__DOT__UART__DOT__divisor_r;
        const long actual = div ? 16L * div : uart_clks_per_bit;
        printf("UART divisor: %u -> %ld clocks/bit", div, actual);
        if (actual != uart_clks_per_bit)
            printf("  ** decoding at %d, output will be garbage: "
                   "re-run with +uart_clks=%ld **", uart_clks_per_bit, actual);
        printf("\n");
    }
    printf("SDRAM refreshes issued: %ld\n", sdram.refreshes());
    printf("SDRAM read setup margin: %.1f ns\n", sdram.ac_setup_ns());
    printf("result word (expect \"PASS\"): 0x%08x\n", result);
    printf("wall clock: %.2f s  (%.0f cycles/s)\n", secs, secs > 0 ? cycles / secs : 0.0);
    // A program that ends by *printing* never writes the verdict word, so
    // "no verdict" and "timed out" are not the same outcome and this used to
    // call both of them a failure - printing "VERILATOR SOC TEST FAILED
    // (timed out)" directly above `make sim_linux`'s "LINUX BOOT PASSED" on a
    // boot that reached userspace and stopped on its own marker. Two verdicts
    // that disagree teach you to read neither. The word is still the verdict
    // when there is one; when the run ended on `+stopon` instead, that is
    // what it says.
    if (result == RESULT_PASS)      printf("VERILATOR SOC TEST PASSED\n");
    else if (result == RESULT_FAIL) printf("VERILATOR SOC TEST FAILED\n");
    else if (uart_stop_hit)
        printf("VERILATOR SOC RUN ENDED ON +stopon (no verdict word; the "
               "caller's gate decides)\n");
    else printf("VERILATOR SOC TEST FAILED (timed out after %ld cycles)\n", cycles);
    printf("---------------------------------------------\n");

    delete top;
    return (result == RESULT_PASS) ? 0 : 1;
}
