# Vernier-RV32 - build, simulation and verification entry point.
#
# macOS setup (one-time):
#   brew install icarus-verilog surfer
#   brew install verilator          # optional, for the verilator target
#   brew install riscv-software-src/riscv/riscv-tools   # for `make software`
#
# Usage:
#   make sim         -> run the hand-assembled self-checking testbench (Icarus)
#   make isa          -> build + run the official RISC-V architectural tests
#   make cosim        -> co-simulate every ISA test against Spike, instruction
#                        by instruction
#   make formal       -> bounded model checking of key modules (yosys + z3)
#   make coremark     -> build and run CoreMark on the SoC in simulation
#   make wave         -> run sim, then open the waveform (surfer)
#   make wave_soc     -> same for the SoC simulation
#   make verilator    -> build and run rtl/top.v with Verilator instead
#   make software     -> compile software/ with riscv64-unknown-elf-gcc
#   make sim_software -> build software/ and run it, showing real UART output
#   make clean
#
# The SoC in simulation, three ways. sim_soc is the finished boot path - off
# the card, 256 KB of RAM. The other two are the path a *board* takes, which
# is neither: the program preloaded into the bitstream, and 64 KB.
#
#   make sim_soc      -> boot off the SD card model, run the acceptance test
#   make sim_ramboot  -> same test, preloaded into 64 KB, as the board runs it
#   make sim_rerun    -> run it twice with a reset between, as a board does
#   make sim_probe    -> the newlib probe: which rung of libc actually fails
#   make trapcheck    -> provoke known faults, check the trap reports come out
#
# External memory (docs/roadmap.md Phase 2). Two layers, in the order they
# fail: the controller against an SDRAM model at the bus, then the whole SoC
# running a 96 KB program out of it with block RAM untouched.
#
#   make sim_sdram     -> rtl/soc/wb_sdram.v against sim/sdram_model.v
#   make sim_sdramboot -> the SoC executing from SDRAM, larger than block RAM
#   make sim_mmusdram  -> Sv32 page tables *in* SDRAM, walked from S-mode,
#                         with the mapped pages in the part's top 16 MB
#   make sim_plic      -> the PLIC's standard register map, and an external
#                         interrupt delivered to S-mode through context 1
#   make sim_uart16550 -> the ns16550 map: DLAB, the divisor latch, IIR, and
#                         the UART's interrupt arriving through PLIC source 1
#   make sim_uartirq   -> a driver that actually uses that interrupt to send,
#                         instead of polling THRE - docs/roadmap.md Phase 3
#   make sim_uartload  -> the boot ROM's UART loader: a host sends a program
#                         over the serial line and the SoC runs it from SDRAM
#   make uartload-host -> the host script against a fake board on a pty
#
# The same SoC under Verilator: 4.44 M cycles/s against Icarus's 11.3 k, a
# measured 390x. Built for the Linux bring-up, where a boot is order 10^8
# cycles and the Icarus path would be seven hours per attempt:
#
#   make verilator_soc       -> build the harness (sim/verilator_soc.cpp)
#   make verilator_sdramboot -> what sim_sdramboot runs, in about half a second
#   make verilator_check     -> run it under *both* and require the cycle
#                               counts, refresh counts and output to match

IVERILOG      = iverilog
# Which CPU to build the SoC around. `inorder` is rtl/cpu_core.v, the design
# that has run on hardware; `ooo` is rtl/ooo/core_ooo.v, Phase 1 of
# docs/roadmap.md. Both have the same port list and face the same suites:
#
#   make verify            the in-order core
#   make verify_ooo        the same suites against the wide core
#
# The knob exists so a regression in one cannot hide behind the other.
#
# `hetero` (Phase 15, Stage 1) is a third value, not a blend of the other
# two: rtl/soc/soc_top.v's own hart-0 instantiation and its NUM_HARTS
# generate loop each read a *different* one of CORE_HETERO/CORE_OOO, so
# hart 0 stays cpu_core.v while every hart from 1 upward becomes
# core_ooo.v instead of a second copy of hart 0's own type - see that
# file's own comments at both instantiation sites for the exact
# reasoning. It needs both cores' own source files present in the same
# build, which is already true of a plain CORE=ooo build today
# (SOC_RTL_BASE below already carries rtl/cpu_core.v unconditionally, for
# the same "iverilog has to resolve every module cpu_core.v references"
# reason rtl/pmp.v is unconditional too) - CORE_RTL/VERILATOR_LINT_FLAGS
# are identical to CORE=ooo's own values for exactly that reason, only
# CORE_DEFINES differs.
CORE         ?= inorder
ifeq ($(CORE),ooo)
# regfile_phys.v is only in this list, never the in-order one: rtl/regfile.v
# (2R/1W) still serves cpu_core.v, and building both cores against the same
# register file would remove the point of having two cores. Stage 1d
# replaced regfile_wide.v's dual-issue register file with a renamed
# physical one - see rtl/ooo/core_ooo.v's header.
CORE_RTL      = rtl/ooo/core_ooo.v rtl/ooo/regfile_phys.v
CORE_DEFINES  = -DCORE_OOO
# sim/verilator_soc.vlt already waives UNOPTFLAT by file for exactly the wide
# core's CDB-bypass structure (see its own "Waivers" section) - a real,
# reasoned suppression, not an oversight, confirmed harmless against every
# iverilog-run functional gate. That waiver suppresses the warning outright
# on this project's own development machine (verilator never even prints
# it), but does not on the Linux runner CI uses: same reported Verilator
# version (5.050 2026-07-01) and byte-identical command line, yet CI prints
# and fatally exits on the same 8 warnings the .vlt file names by file. That
# is a platform-specific difference in how `lint_off -file` matches, not a
# new defect - the RTL side is already reasoned about at length in the .vlt
# file, and this flag is the backstop that makes the suppression actually
# hold wherever `make` runs. Confirmed elsewhere in this SoC-level build
# (rtl/soc/soc_top.v:169's `dmem_rdata`, rtl/soc/cpu_wb.v:327's `load_hit`)
# rather than only inside core_ooo.v, because the wide core's bypass reaches
# through the shared bus adapter too. CORE=ooo only: cpu_core.v's build
# stays held to the stricter default, since none of this exists there.
VERILATOR_LINT_FLAGS = -Wno-UNOPTFLAT
else ifeq ($(CORE),hetero)
CORE_RTL      = rtl/ooo/core_ooo.v rtl/ooo/regfile_phys.v
CORE_DEFINES  = -DCORE_HETERO
# core_ooo.v instances 1..NUM_HARTS-1 carry the same CDB-bypass structure
# CORE=ooo's own waiver above exists for, regardless of what hart 0 is.
VERILATOR_LINT_FLAGS = -Wno-UNOPTFLAT
else
CORE_RTL      =
CORE_DEFINES  =
VERILATOR_LINT_FLAGS =
endif
IVFLAGS       = -g2012 $(CORE_DEFINES)
VVP           = vvp
VERILATOR     = verilator
# The $$readmemh image rules below list `Makefile` as a prerequisite on
# purpose: the word/byte layout of every image is decided by the bin2hex
# flags *in this file*, not by anything in software/. Without it, changing a
# memory's organization leaves a stale image that loads silently and wrong -
# which cost real debugging time when wb_ram.v went from byte- to
# word-organized.
# ?= so the environment can select a differently-prefixed toolchain without
# editing this file. CI does exactly that: the prebuilt it uses is xPack's
# riscv-none-elf-, because riscv-collab's riscv64-elf build ships only a
# 64-bit libc_nano.a and this firmware links -specs=nano.specs against the
# rv32im/ilp32 multilib.
RISCV_CC      ?= riscv64-unknown-elf-gcc
RISCV_OBJCOPY ?= riscv64-unknown-elf-objcopy
# Only software/opensbi/mkimage.py uses this: it reads OpenSBI's own
# symbols to check the load address before packing an image.
RISCV_NM      ?= riscv64-unknown-elf-nm

RTL = rtl/regfile.v rtl/imem.v rtl/dmem.v rtl/csr_file.v rtl/muldiv_div.v \
      rtl/clint.v rtl/plic.v rtl/uart.v rtl/btb.v rtl/mmu.v rtl/pmp.v rtl/cpu_core.v rtl/top.v $(CORE_RTL)
TB  = sim/tb_top.v

# The SoC build shares the core and peripherals but swaps rtl/top.v (flat,
# Harvard, zero-latency) for the Wishbone system in rtl/soc/.
#
# rtl/pmp.v is listed unconditionally, not inside $(CORE_RTL): cpu_core.v's
# own body instantiates it directly (not through an `ifdef CORE_OOO` arm),
# and iverilog has to resolve every module cpu_core.v references to
# elaborate the file at all - true in a CORE=ooo build too, since
# soc_top.v's own `ifdef` only selects *which* core gets instantiated as
# the active one, not which core source files get compiled.
# SOC_RTL_BASE is the same list with $(CORE_RTL) deliberately left off -
# i.e. always exactly what CORE=inorder would build, regardless of the
# ambient $(CORE) - kept as SOC_RTL's own building block below.
# sim_cpu_halt's recipe hardcodes rtl/cpu_core.v directly instead of going
# through either variable, for the same core-scoping reason: it is
# CORE=inorder only and always will be (docs/debug.md has the reasoning).
SOC_RTL_BASE = rtl/regfile.v rtl/csr_file.v rtl/muldiv_div.v rtl/clint.v rtl/plic.v \
          rtl/uart.v rtl/btb.v rtl/mmu.v rtl/pmp.v rtl/cpu_core.v \
          rtl/soc/wb_interconnect.v rtl/soc/cpu_wb.v rtl/soc/wb_ptw.v \
          rtl/soc/reservation_monitor.v \
          rtl/soc/wb_ram.v \
          rtl/soc/wb_rom.v rtl/soc/wb_periph_bridge.v rtl/soc/wb_gpio.v \
          rtl/soc/wb_spi.v rtl/soc/video_timing.v rtl/soc/wb_framebuffer.v \
          rtl/soc/wb_sdram.v rtl/soc/wb_timer.v rtl/soc/wb_npu.v \
          rtl/soc/wb_fir.v \
          rtl/debug/jtag_tap.v rtl/debug/dmi_cdc.v rtl/debug/dm.v \
          rtl/soc/soc_top.v
SOC_RTL = $(SOC_RTL_BASE) $(CORE_RTL)
SOC_TB  = sim/tb_soc.v sim/sd_card_model.v

SOFTWARE_SRCS = software/crt0.S software/syscalls.c software/uart.c software/main.c
SOFTWARE_CFLAGS = -march=rv32im -mabi=ilp32 -specs=nano.specs -ffreestanding \
                   -O2 -Wall -nostartfiles -T software/link.ld

# SoC firmware: two separate images. The boot ROM is freestanding (no libc,
# baked into the bitstream); the RAM program is a normal newlib-nano build
# that gets loaded off SD at boot.
# zicsr/zifencei are needed explicitly: this firmware reads CSRs and issues
# FENCE.I directly. They don't affect multilib selection (still rv32im/ilp32),
# they just tell the assembler those opcodes are legal.
SOC_CFLAGS_COMMON = -march=rv32im_zicsr_zifencei -mabi=ilp32 -ffreestanding -O2 -Wall \
                     -nostartfiles -Isoftware -Isoftware/soc
BOOTROM_SRCS = software/soc/crt0_rom.S software/soc/bootrom.c
# crt0_ram.S, console.c and trap.c are the RAM-program runtime: startup, the
# libc-free console, and the loud trap handler. Every program that runs out of
# RAM wants all three.
SOCRT_SRCS   = software/soc/crt0_ram.S software/soc/console.c software/soc/trap.c
SOCPROG_SRCS = $(SOCRT_SRCS) software/soc/main.c \
                software/syscalls.c software/uart.c
# The newlib probe: same runtime, but its whole purpose is to call into libc.
PROBE_SRCS   = $(SOCRT_SRCS) software/soc/newlibprobe.c \
                software/syscalls.c software/uart.c
# The handler's own calibration. No libc at all - it must not be able to fail
# for a reason the thing it is testing isn't responsible for.
TRAPCHK_SRCS = $(SOCRT_SRCS) software/soc/trapcheck.c
# Which deliberate fault trapcheck.c provokes. sim/trapcheck.sh sets this per
# case; on its own the default just gives you a runnable program.
TRAPCHECK   ?= 1
SOCPROG_CFLAGS = $(SOC_CFLAGS_COMMON) -specs=nano.specs
SOC_HDRS = software/soc/soc.h software/soc/console.h software/soc/trap.h

# Card size in 512-byte blocks; must match sim/tb_soc.v's CARD_BYTES (64 KB).
SD_BLOCKS = 128

.PHONY: all sim wave wave_soc verilator software sim_software soc card ramimage probeimage \
        verilator_soc verilator_sdramboot verilator_check \
        sim_soc sim_ramboot sim_probe sim_rerun trapcheck sim_video sim_blit sim_ulx3s sim_ecpix5 sim_cmd0 dtb \
        sim_sdram sim_sdramboot sdramimage sim_sdramprobe sim_sdramcheck sim_ddr3_init sim_ddr3_data sim_ddr3_top sim_ddr3_dqs_write sim_ddr3_write_seq sim_ddr3_read_seq sim_ddr3_read_burst_ext \
        sim_jtag \
        sim_mmusdram sim_plic sim_pmptest sim_uart16550 sim_uartirq \
        sim_uartload uartload-host sbiimage sim_opensbi \
        linuximage linuxpayload sim_linux \
        mmuimage plicimage uart16550image \
        check-program regen-program verify_ooo \
        isa isa-build isa-fetch cosim formal coremark coremark-fetch verify clean \
        linux_trapdiff linux-if-built \
        lint lint-markdown lint-vale bom sbom hbom \
        lint-rtl lint-rtl-flat lint-rtl-soc lint-c lint-py code-quality \
        verilator_coverage_build verilator_coverage verilator_coverage_report

all: sim

sim:
	$(IVERILOG) $(IVFLAGS) -o sim/sim.out $(TB) $(RTL)
	cd sim && $(VVP) sim.out $(VVP_DUMP)

# Waveform viewer. GTKWave was discontinued upstream and Homebrew disabled
# its cask on 2025-10-29, so `surfer` is the default here; VIEWER= overrides
# it if you still have gtkwave installed from elsewhere.
VIEWER = surfer

# Waveforms are opt-in. `make sim DUMP=1` (or any other target here) passes
# `+dump` to the simulation, which is what makes its testbench write a VCD.
#
# They used to be written unconditionally, and the size scales with how long
# the run is: sim_sdramboot wrote a 6.2 GB VCD and sim_uartload an 18 GB one,
# so a single `make verify` filled a 228 GB disk to 100%. The `wave` targets
# below set it for you; nothing else should need it unless you are actually
# looking at a waveform.
DUMP ?=
ifeq ($(DUMP),1)
VVP_DUMP = +dump
else
VVP_DUMP =
endif

wave:
	$(MAKE) sim DUMP=1
	$(VIEWER) sim/wave.vcd &

wave_soc:
	$(MAKE) sim_soc DUMP=1
	$(VIEWER) sim/wave_soc.vcd &

verilator:
	$(VERILATOR) --cc --exe --build --trace -j 4 --top-module top \
		$(RTL) sim/verilator_main.cpp \
		--Mdir obj_dir
	cd sim && ../obj_dir/Vtop

# =====================================================================
# The SoC under Verilator
# =====================================================================
#
# `verilator` above builds rtl/top.v - the flat, Harvard, zero-latency core
# on its own, for 100 cycles. That was the whole Verilator story until now,
# and it could not run the SoC at all, which meant every SoC-level simulation
# went through Icarus at about 11.3 thousand cycles a second.
#
# That rate is fine for the tests in this file - the longest is under four
# minutes. It is not fine for the next milestone: a Linux boot is order 10^8
# cycles, which is seven hours or more per attempt under Icarus, on a
# bring-up whose characteristic failure is a silent hang with no output at
# all. Measured here at 4.44 M cycles/s. See sim/verilator_soc.cpp.
#
# The Icarus path stays exactly as it is, and stays the authority: `verify`
# runs sim_sdram and sim_sdramboot against sim/sdram_model.v, whose timing is
# in nanoseconds and which is the definition of what the part accepts. The
# C++ model in the harness is a port of it, and `verilator_check` below is
# what keeps the two honest.
#
# Per-core output directory, for the reason `verify_ooo` deletes sim/*.out:
# a built simulation does not record which core it was built with, and
# running a stale one reports the in-order core's result under the other
# core's name.
VERILATOR_MDIR = obj_dir_soc_$(CORE)
VERILATOR_BIN  = $(VERILATOR_MDIR)/Vsoc_top

# Tracing is a build-time decision in Verilator, and it costs speed even when
# no VCD is being written - so it is off by default and `VTRACE=1` turns it
# on, at which point `+dump` works. The reason any of this is opt-in is a
# 228 GB disk that unconditional dumping filled to 100%; see DUMP above.
VTRACE ?=
ifeq ($(VTRACE),1)
VERILATOR_TRACE = --trace
else
VERILATOR_TRACE =
endif

# -O3 on the generated model, and the lint left at full strength for the
# in-order build: cpu_core.v's soc_top currently verilates with zero
# warnings and the point of a second front end is to keep finding things
# Icarus does not. The wide core's build additionally carries
# $(VERILATOR_LINT_FLAGS) - see CORE_DEFINES above for why.
#
# The parameters are set here rather than in a testbench because Verilator
# has no testbench to set them in. These match sim/tb_sdramboot.v: the
# board's 64 KB of block RAM, and a reset vector pointing straight at SDRAM
# so the first instruction fetch lands on a controller that is still 100 us
# into its power-up sequence and cannot answer.
VERILATOR_PARAMS = -GRAM_BYTES=65536 -GRESET_PC=0x90000000

# CORE_DEFINES is `-DCORE_OOO` or empty, and Verilator spells `define the
# same way Icarus does, so the same variable serves both front ends.
# `-CFLAGS` carries CORE_DEFINES too, not just the Verilog side. The harness
# has to compile differently for the wide core: `+checkdecode`'s second-slot
# check reads id_ex1_* signals that exist only in rtl/ooo/core_ooo.v, and
# referencing them in the in-order build is a compile error rather than a
# silent nothing.
VERILATOR_FLAGS = --cc --exe --build -j 4 -O3 -CFLAGS "-O2 $(CORE_DEFINES)" \
                   --top-module soc_top $(VERILATOR_TRACE) $(VERILATOR_LINT_FLAGS) \
                   $(CORE_DEFINES) $(VERILATOR_PARAMS) --Mdir $(VERILATOR_MDIR)

$(VERILATOR_BIN): $(SOC_RTL) sim/verilator_soc.cpp sim/verilator_soc.vlt Makefile
	$(VERILATOR) $(VERILATOR_FLAGS) $(SOC_RTL) \
	    sim/verilator_soc.vlt sim/verilator_soc.cpp

verilator_soc: $(VERILATOR_BIN)

# Extra plusargs for a one-off run: +quiet, +maxcycles=N, +sdram_words=N,
# +dump (which needs VTRACE=1). sim/verilator_soc.cpp lists them all.
VERILATOR_PLUSARGS ?=

# The same program sim_sdramboot runs, in the same configuration, out of the
# same image - and, being the same design, it must produce the same answer.
verilator_sdramboot: sim/sdramimage.hex $(VERILATOR_BIN)
	cd sim && ../$(VERILATOR_BIN) +sdram=sdramimage.hex $(VERILATOR_PLUSARGS)

# ---- the check that makes the fast path trustworthy ----
#
# A second simulator is only worth having if it agrees with the first. This
# compares sim_sdramboot's two runs on the cycle count, the refresh count and
# every byte the program printed - not merely that both say PASS, which two
# quite different machines could do.
#
# Matching cycle counts mean the C++ SDRAM model returns data on the same
# edges the Verilog one does and nothing is being simulated approximately. It
# is the only check here that can catch a port of a memory model being subtly
# early. The cycle count is allowed to differ by one, for a reason that lives
# in the testbenches rather than the design and that
# sim/verilator_compare.py sets out in full; everything else must match
# exactly.
#
# It reuses the Icarus run rather than repeating it - that run is three
# minutes and `verify` does it anyway.
# The self-checking probes ride along free: this run already happens, and
# each is a compare per event against an independent model of the answer.
# +checkdecode is the one that matters most - it is what caught a core
# executing an instruction from a mispredicted path under the corrected PC,
# and no other check here can see that. sim_sdramboot runs with paging off,
# so it exercises the untranslated half; the translated half is reached by
# `make sim_linux`, which is not in `verify` because it needs a kernel.
verilator_check: sim_sdramboot $(VERILATOR_BIN)
	@cd sim && ../$(VERILATOR_BIN) +sdram=sdramimage.hex \
	    +checkreads +checkfetch +checkdecode +checkmmu +checkuart \
	    | tee verilator_soc.log
	@python3 sim/verilator_compare.py sim/sdramboot.log sim/verilator_soc.log
	@grep -aq "were not the instruction at their own PC" sim/verilator_soc.log && \
	    { echo "FAILED: the core decoded an instruction that is not at its PC"; \
	      exit 1; } || true
	@grep -aq "returned the wrong word" sim/verilator_soc.log && \
	    { echo "FAILED: a read returned something the memory does not hold"; \
	      exit 1; } || true
# +checkfetch's failure line is "were the wrong word"; the read check above
# prints "returned the wrong word". Close enough to look covered and different
# enough not to be - for four PRs this target ran +checkfetch and then grepped
# for a string it cannot print. A fetch-path change made during the timing
# work produced exactly that output, mismatching fetches on every run, and
# `make verify` stayed green. practices.md section 26.
	@grep -aq "were the wrong word" sim/verilator_soc.log && \
	    { echo "FAILED: a fetch returned something the memory does not hold"; \
	      exit 1; } || true
	@grep -aq "disagreed with the page tables" sim/verilator_soc.log && \
	    { echo "FAILED: a translation disagreed with the page tables"; \
	      exit 1; } || true
	@grep -aq "dropped by the transmitter" sim/verilator_soc.log && \
	    { echo "FAILED: the UART did not send a byte software wrote to it"; \
	      exit 1; } || true

# =====================================================================
# RTL coverage (Verilator line + toggle), report-only
# =====================================================================
#
# Two separate binaries, not one --coverage build: verilator_coverage's
# own --filter-type flag - the documented way to split a single combined
# .dat by point type - does not exist on Verilator 5.020, the version
# CI's own apt package resolves to (docs/toolchain.md), only on newer
# ones (confirmed directly: `verilator_coverage --help` on 5.020 lists
# --annotate/--write-info/--rank/--unlink and nothing else). Building
# --coverage-line and --coverage-toggle separately instead means each
# resulting .dat is already type-pure - `verilator_coverage --write-info`
# needs no flag this project can't rely on to split it. This also
# surfaced a real, measured cost difference worth knowing before reading
# a "coverage takes N minutes" number: on the sdramboot image, the
# line-only build runs at roughly 1.2M cycles/s (barely slower than an
# uninstrumented build), while the toggle-only build runs at roughly 35K
# cycles/s - toggle instrumentation is where nearly all of this stage's
# own runtime actually goes.
#
# RTL coverage, not firmware coverage: nearly all C in software/ cross-
# compiles to RV32 and only runs inside this simulator, never natively -
# gcov does not apply here without a large new ported-runtime subsystem,
# out of scope, not attempted. What this measures is which lines/toggles
# of the *hardware* the one boot below reached, not which lines of C ran.
VERILATOR_COV_LINE_MDIR   = obj_dir_soc_cov_line_$(CORE)
VERILATOR_COV_LINE_BIN    = $(VERILATOR_COV_LINE_MDIR)/Vsoc_top
VERILATOR_COV_TOGGLE_MDIR = obj_dir_soc_cov_toggle_$(CORE)
VERILATOR_COV_TOGGLE_BIN  = $(VERILATOR_COV_TOGGLE_MDIR)/Vsoc_top

# Mostly the same flags as $(VERILATOR_BIN)'s own rule, with --coverage-
# line/--coverage-toggle in place of --coverage - keeping Verilator's own
# -O3 (model-generation optimization; dropping it broke
# sim/verilator_soc.vlt's public_flat_rd visibility into
# rtl/mmu.v's internal signals under --coverage-toggle specifically,
# confirmed by testing with and without it - this flag is not the one
# that costs memory) but deliberately not -CFLAGS -O2 (the g++
# optimization level, which is): that one exists on the real build
# because it has to run a whole boot fast, repeatedly, in CI. This one
# runs sdramboot exactly once per category and is never in anyone's
# inner loop, so paying g++ for aggressive optimization buys nothing
# here - and toggle instrumentation in particular generates large enough
# functions that -O2 genuinely ran the compiler out of memory (a real,
# measured OOM kill on cc1plus, not a theoretical concern), confirmed to
# go away at -O0 with nothing else changed. -O0 explicitly, not simply
# omitted: `-CFLAGS ""` on its own (empty string, CORE=inorder's
# $(CORE_DEFINES)) is a real Verilator argument-parsing bug on its own -
# it swallows the next command-line token instead of being treated as a
# no-op, which is exactly why $(VERILATOR_BIN)'s own rule never hit
# this: -O2 always kept that string non-empty. -O0 keeps it non-empty
# here too.
$(VERILATOR_COV_LINE_BIN): $(SOC_RTL) sim/verilator_soc.cpp sim/verilator_soc.vlt Makefile
	$(VERILATOR) --cc --exe --build -j 4 -O3 -CFLAGS "-O0 $(CORE_DEFINES)" \
	    --top-module soc_top --coverage-line $(VERILATOR_LINT_FLAGS) \
	    $(CORE_DEFINES) $(VERILATOR_PARAMS) --Mdir $(VERILATOR_COV_LINE_MDIR) \
	    $(SOC_RTL) sim/verilator_soc.vlt sim/verilator_soc.cpp

$(VERILATOR_COV_TOGGLE_BIN): $(SOC_RTL) sim/verilator_soc.cpp sim/verilator_soc.vlt Makefile
	$(VERILATOR) --cc --exe --build -j 4 -O3 -CFLAGS "-O0 $(CORE_DEFINES)" \
	    --top-module soc_top --coverage-toggle $(VERILATOR_LINT_FLAGS) \
	    $(CORE_DEFINES) $(VERILATOR_PARAMS) --Mdir $(VERILATOR_COV_TOGGLE_MDIR) \
	    $(SOC_RTL) sim/verilator_soc.vlt sim/verilator_soc.cpp

verilator_coverage_build: $(VERILATOR_COV_LINE_BIN) $(VERILATOR_COV_TOGGLE_BIN)

# The same firmware verilator_sdramboot already proves in CI on both
# cores, reused rather than a purpose-built coverage corpus. Does NOT
# cover riscv-tests, cosim, the MMU/PLIC/UART peripheral suites, OpenSBI
# or Linux - none of those run here, so "X% covered" answers only "how
# much RTL did this one boot path reach," not "how tested is this SoC."
# docs/toolchain.md and CONTRIBUTING.md say so explicitly.
#
# Per-CORE, per-category .dat, matching $(VERILATOR_MDIR)'s own per-core
# reasoning: neither cores' nor categories' data may overwrite each other
# when run back to back on one machine.
verilator_coverage: sim/sdramimage.hex verilator_coverage_build
	cd sim && ../$(VERILATOR_COV_LINE_BIN) +sdram=sdramimage.hex \
	    +coverage=../coverage_line_$(CORE).dat
	cd sim && ../$(VERILATOR_COV_TOGGLE_BIN) +sdram=sdramimage.hex \
	    +coverage=../coverage_toggle_$(CORE).dat

verilator_coverage_report: verilator_coverage
	verilator_coverage --write-info coverage_line_$(CORE).info coverage_line_$(CORE).dat
	verilator_coverage --write-info coverage_toggle_$(CORE).info coverage_toggle_$(CORE).dat
	python3 sim/coverage_summary.py \
	    coverage_line_$(CORE).info coverage_toggle_$(CORE).info \
	    | tee coverage_summary_$(CORE).txt

software: sim/firmware_imem.hex sim/firmware_dmem.hex

software/firmware.elf: $(SOFTWARE_SRCS) software/link.ld
	$(RISCV_CC) $(SOFTWARE_CFLAGS) -o $@ $(SOFTWARE_SRCS)

sim/firmware_imem.hex: software/firmware.elf software/bin2hex.py Makefile
	$(RISCV_OBJCOPY) -O binary --only-section=.text software/firmware.elf software/firmware_text.bin
	python3 software/bin2hex.py --word-size=4 software/firmware_text.bin > sim/firmware_imem.hex

sim/firmware_dmem.hex: software/firmware.elf software/bin2hex.py Makefile
	$(RISCV_OBJCOPY) -O binary --only-section=.data software/firmware.elf software/firmware_data.bin
	python3 software/bin2hex.py --word-size=1 software/firmware_data.bin > sim/firmware_dmem.hex

# ---- the hand-assembled core regression program ----
# sim/program.hex is committed, because `make sim` must run with no RISC-V
# toolchain at all - that is what makes it the fastest thing in the suite that
# can fail, and what lets CI run it on a bare runner.
#
# It used to be committed with no source: produced by a throwaway Python
# encoder that was never in the repository, which left 440 instructions that
# could be read but not changed. sim/program.S is that source, recovered by
# disassembly and verified by reassembling to the identical bytes.
#
# Neither target runs as part of a normal build; both need a toolchain.
#   make check-program   reassemble and fail if it differs from the committed hex
#   make regen-program   rewrite the hex from the source
PROGRAM_CFLAGS = -march=rv32ima_zicsr_zifencei -mabi=ilp32 -nostdlib \
                  -nostartfiles -Wl,-Ttext=0

sim/program.rebuilt.hex: sim/program.S software/bin2hex.py Makefile
	$(RISCV_CC) $(PROGRAM_CFLAGS) -o sim/program.rebuilt.elf sim/program.S
	$(RISCV_OBJCOPY) -O binary sim/program.rebuilt.elf sim/program.rebuilt.bin
	python3 software/bin2hex.py --word-size=4 sim/program.rebuilt.bin > $@

check-program: sim/program.rebuilt.hex
	@if diff -q sim/program.rebuilt.hex sim/program.hex >/dev/null; then \
	    echo "program.hex matches sim/program.S"; \
	else \
	    echo "program.hex does NOT match sim/program.S:"; \
	    diff sim/program.rebuilt.hex sim/program.hex | head -20; \
	    exit 1; \
	fi

regen-program: sim/program.rebuilt.hex
	cp sim/program.rebuilt.hex sim/program.hex

sim_software: software
	$(IVERILOG) $(IVFLAGS) -o sim/sim_software.out sim/tb_software.v $(RTL)
	cd sim && $(VVP) sim_software.out

# =====================================================================
# SoC build
# =====================================================================
soc: sim/bootrom_$(CORE).hex sim/card.hex

# Embeds this project's own real device tree into the boot ROM image - see
# the generator script's own header for why (the boot ROM hands its address
# onward as a1, the real RISC-V firmware entry convention).
#
# $(CORE)-suffixed, all the way down to sim/bootrom_$(CORE).hex below: the
# two cpu nodes' own `compatible` strings vary with $(CORE) now (dts/soc.dts's
# own header, Phase 15 Stage 3's second half), so a single shared
# dtb_blob.h/bootrom.elf/bootrom.hex would let Make's own mtime-based rebuild
# tracking miss a $(CORE) switch between two manual invocations - exactly how
# `make verify` then `make verify_ooo` runs in this same tree, back to back,
# every time. docs/roadmap.md's Phase 15 entry has the full account of why
# this was deferred rather than shipped as a two-line rename the first time
# it came up.
software/soc/dtb_blob_$(CORE).h: dts/soc_$(CORE).dtb software/soc/gen_dtb_blob.py
	python3 software/soc/gen_dtb_blob.py dts/soc_$(CORE).dtb > $@

software/soc/bootrom_$(CORE).elf: $(BOOTROM_SRCS) software/soc/link_rom.ld software/soc/soc.h \
                                   software/soc/dtb_blob_$(CORE).h
	$(RISCV_CC) $(SOC_CFLAGS_COMMON) -DDTB_BLOB_HEADER='"dtb_blob_$(CORE).h"' \
	    -T software/soc/link_rom.ld -o $@ $(BOOTROM_SRCS)

sim/bootrom_$(CORE).hex: software/soc/bootrom_$(CORE).elf software/bin2hex.py Makefile
	$(RISCV_OBJCOPY) -O binary software/soc/bootrom_$(CORE).elf software/soc/bootrom_$(CORE).bin
	python3 software/bin2hex.py --word-size=4 software/soc/bootrom_$(CORE).bin > $@

# Generated, not hand-edited - see the script's own header for why the
# specific values don't matter and what does (mixed sign, no collisions).
software/soc/npu_layer_data.h: software/soc/gen_npu_layer.py
	python3 software/soc/gen_npu_layer.py > $@

# Same reasoning - see the script's own header for the filter design and
# why the expected outputs are independently computed, not derived from
# the RTL or the C test that will exercise them.
software/soc/fir_workload_data.h: software/soc/gen_fir_workload.py
	python3 software/soc/gen_fir_workload.py > $@

# Same reasoning again - a real quantized dense layer at the scale
# rtl/soc/wb_npu.v's own DMA master port (not the MMIO path) exists to
# reach.
software/soc/npu_dma_workload_data.h: software/soc/gen_npu_dma_workload.py
	python3 software/soc/gen_npu_dma_workload.py > $@

# Same reasoning again, but the weights themselves are genuinely trained
# (gradient descent on a real loss), not drawn from random.Random - see
# the script's own header for exactly what that does and does not mean.
software/soc/npu_trained_layer_data.h: software/soc/gen_npu_trained_layer.py
	python3 software/soc/gen_npu_trained_layer.py > $@

software/soc/socprog.elf: $(SOCPROG_SRCS) software/soc/link_ram.ld $(SOC_HDRS) \
                          software/soc/npu_layer_data.h \
                          software/soc/fir_workload_data.h \
                          software/soc/npu_dma_workload_data.h \
                          software/soc/npu_trained_layer_data.h
	$(RISCV_CC) $(SOCPROG_CFLAGS) -T software/soc/link_ram.ld -o $@ $(SOCPROG_SRCS)

software/soc/newlibprobe.elf: $(PROBE_SRCS) software/soc/link_ram.ld $(SOC_HDRS)
	$(RISCV_CC) $(SOCPROG_CFLAGS) -T software/soc/link_ram.ld -o $@ $(PROBE_SRCS)

software/soc/trapcheck.elf: $(TRAPCHK_SRCS) software/soc/link_ram.ld $(SOC_HDRS)
	$(RISCV_CC) $(SOC_CFLAGS_COMMON) -DTRAPCHECK=$(TRAPCHECK) \
	    -T software/soc/link_ram.ld -o $@ $(TRAPCHK_SRCS)

sim/card.hex: software/soc/socprog.elf software/soc/mkcard.py Makefile
	$(RISCV_OBJCOPY) -O binary software/soc/socprog.elf software/soc/socprog.bin
	python3 software/soc/mkcard.py software/soc/socprog.bin $(SD_BLOCKS) > $@

# ---- SD card image for real hardware ----
# sim/card.hex is ASCII for $readmemh and cannot be written to a card. This is
# the raw form, unpadded, to go at the front of a real card:
#
#   make card
#   diskutil unmountDisk /dev/diskN        # macOS; umount on Linux
#   sudo dd if=sim/card.img of=/dev/rdiskN bs=1m
#
# It overwrites the card's first blocks, including any partition table. That
# is intended - the boot ROM reads raw blocks and knows nothing about
# filesystems - but it does mean the card stops looking like a normal one.
card: sim/card.img

sim/card.img: software/soc/socprog.elf software/soc/mkcard.py Makefile
	$(RISCV_OBJCOPY) -O binary software/soc/socprog.elf software/soc/socprog.bin
	python3 software/soc/mkcard.py --binary software/soc/socprog.bin $(SD_BLOCKS) $@

# ---- RAM preload image ----
# The acceptance-test program, positioned for wb_ram's $readmemh so it lands
# at PROGRAM_LOAD_ADDR. That is RAM_BASE + 0x1000, and $readmemh always
# starts at index 0, so the 0x1000-byte offset has to be 1024 zero words at
# the front of the file. Lets `BOARD=ulx3s85-ram` build a bitstream that
# boots without an SD card at all.
ramimage: sim/ramimage.hex

sim/ramimage.hex: software/soc/socprog.elf software/bin2hex.py Makefile
	$(RISCV_OBJCOPY) -O binary software/soc/socprog.elf software/soc/socprog.bin
	python3 software/bin2hex.py --word-size=4 --skip-words=1024 \
	    software/soc/socprog.bin > $@

# The newlib probe, positioned the same way. See software/soc/newlibprobe.c:
# it is the ladder that says *which* rung of libc fails, run under a trap
# handler that no longer swallows the evidence.
probeimage: sim/probeimage.hex

sim/probeimage.hex: software/soc/newlibprobe.elf software/bin2hex.py Makefile
	$(RISCV_OBJCOPY) -O binary software/soc/newlibprobe.elf software/soc/newlibprobe.bin
	python3 software/bin2hex.py --word-size=4 --skip-words=1024 \
	    software/soc/newlibprobe.bin > $@

sim_soc: soc
	$(IVERILOG) $(IVFLAGS) -DROM_IMAGE='"bootrom_$(CORE).hex"' -o sim/sim_soc.out $(SOC_TB) $(SOC_RTL)
	cd sim && $(VVP) sim_soc.out $(VVP_DUMP)

# ---- the preloaded-RAM boot path, in simulation ----
# sim_soc boots off the SD card model with 256 KB of RAM. The board that
# `BOARD=ulx3s85-ram` builds does neither: the program is baked into the
# bitstream and the RAM is 64 KB. Those are the two things that differed
# between "passes in simulation" and "dies on hardware", and until now nothing
# simulated them - so this testbench is that path, at that size.
sim/sim_ramboot.out: sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)
	$(IVERILOG) $(IVFLAGS) -DRAM_IMAGE='"ramimage.hex"' -DROM_IMAGE='"bootrom_$(CORE).hex"' \
	    -o $@ sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)

sim_ramboot: sim/bootrom_$(CORE).hex sim/ramimage.hex sim/sim_ramboot.out
	@cd sim && $(VVP) sim_ramboot.out $(VVP_DUMP) 2>&1 | tee ramboot.log
	@grep -q "RAMBOOT TEST PASSED" sim/ramboot.log || \
	    { echo "sim_ramboot FAILED"; exit 1; }

# ---- the preloaded-RAM boot path, with a second hart (Phase 13, Stage 12) ----
#
# Boots through the *real* software/soc/bootrom.c/crt0_rom.S path, not
# sim/tb_soc_2hart.v's RESET_PC-into-RAM shortcut or
# software/opensbi/sbi_stub.S's own hardcoded a0/a1 stand-in - both of those
# bypass the boot ROM entirely. See sim/tb_ramboot_2hart.v's own header for
# what this proves and the payload it runs. $(SOC_RTL), not
# $(SOC_RTL_BASE): bootrom.c/crt0_rom.S are plain C/asm with no
# CORE_OOO-specific behavior, so this runs under both `make verify` and
# `make verify_ooo` for full coverage, unlike the reservation-port tests
# (Stage 7/9) that genuinely needed CORE=inorder pinning.
sim/ramimage2hart.hex: Makefile
	@python3 -c "\
	import sys;\
	i_type = lambda imm, rs1, f3, rd, op: ((imm & 0xFFF) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 0x7) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F);\
	j_type = lambda imm, rd, op: (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F);\
	b_type = lambda imm, rs1, rs2, f3, op: (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 0x7) << 12) | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | (op & 0x7F);\
	u_type = lambda imm20, rd, op: ((imm20 & 0xFFFFF) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F);\
	s_type = lambda imm, rs1, rs2, f3, op: (((imm >> 5) & 0x7F) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 0x7) << 12) | ((imm & 0x1F) << 7) | (op & 0x7F);\
	prog = [\
	    b_type(48, 10, 0, 0x1, 0x63),\
	    u_type(0x80000, 1, 0x37),\
	    i_type(0x100, 1, 0x0, 2, 0x13),\
	    i_type(0x104, 1, 0x0, 3, 0x13),\
	    i_type(0xA0, 0, 0x0, 4, 0x13),\
	    s_type(0, 2, 4, 0x2, 0x23),\
	    i_type(0, 3, 0x2, 5, 0x03),\
	    b_type(-4, 5, 0, 0x0, 0x63),\
	    u_type(0x50415, 6, 0x37),\
	    i_type(0x353, 6, 0x0, 6, 0x13),\
	    s_type(0, 1, 6, 0x2, 0x23),\
	    j_type(0, 0, 0x6F),\
	    u_type(0x80000, 1, 0x37),\
	    i_type(0x104, 1, 0x0, 3, 0x13),\
	    i_type(0xA1, 0, 0x0, 4, 0x13),\
	    s_type(0, 3, 4, 0x2, 0x23),\
	    j_type(0, 0, 0x6F),\
	];\
	words = [0] * 1024 + prog;\
	[sys.stdout.write('%08X\n' % (w & 0xFFFFFFFF)) for w in words]" > $@

sim/sim_ramboot_2hart.out: sim/tb_ramboot_2hart.v sim/sdram_model.v $(SOC_RTL)
	$(IVERILOG) $(IVFLAGS) -DRAM_IMAGE='"ramimage2hart.hex"' -DROM_IMAGE='"bootrom_$(CORE).hex"' \
	    -o $@ sim/tb_ramboot_2hart.v sim/sdram_model.v $(SOC_RTL)

sim_ramboot_2hart: sim/bootrom_$(CORE).hex sim/ramimage2hart.hex sim/sim_ramboot_2hart.out
	@cd sim && $(VVP) sim_ramboot_2hart.out $(VVP_DUMP) 2>&1 | tee ramboot_2hart.log
	@grep -q "RAMBOOT-2HART TEST PASSED" sim/ramboot_2hart.log || \
	    { echo "sim_ramboot_2hart FAILED"; exit 1; }

sim/sim_probe.out: sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)
	$(IVERILOG) $(IVFLAGS) -DRAM_IMAGE='"probeimage.hex"' -DROM_IMAGE='"bootrom_$(CORE).hex"' \
	    -o $@ sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)

sim_probe: sim/bootrom_$(CORE).hex sim/probeimage.hex sim/sim_probe.out
	@cd sim && $(VVP) sim_probe.out $(VVP_DUMP) 2>&1 | tee probe.log
	@grep -q "RAMBOOT TEST PASSED" sim/probe.log || \
	    { echo "sim_probe FAILED"; exit 1; }

# ---- does the program survive a reset? ----
# Block RAM is initialised when the FPGA is *configured*, not when the CPU is
# reset, so tapping the reset button re-runs the program over memory the
# previous run already wrote. Every simulation before this one ran the program
# exactly once and so could not see it.
#
# What it missed: .data was loaded once and never restored, so run 2 inherited
# run 1's writes. newlib's __sinit found its own "already initialised" guard
# still set, skipped setting up stdout, and every printf for the rest of that
# run returned -1 and printed nothing - which is what "printf hangs on
# hardware" actually was, for months. crt0_ram.S now rebuilds .data on every
# startup; this is the test that says so.
#
# The probe rather than the acceptance test, deliberately: the acceptance test
# keeps its state in .bss, which _start has always zeroed, so it passes twice
# either way and would not have caught this.
sim/sim_rerun.out: sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)
	$(IVERILOG) $(IVFLAGS) -DRAM_IMAGE='"probeimage.hex"' -DROM_IMAGE='"bootrom_$(CORE).hex"' -DRERUN \
	    -o $@ sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)

sim_rerun: sim/bootrom_$(CORE).hex sim/probeimage.hex sim/sim_rerun.out
	@cd sim && $(VVP) sim_rerun.out $(VVP_DUMP) 2>&1 | tee rerun.log
	@grep -q "RERUN TEST PASSED" sim/rerun.log || \
	    { echo "sim_rerun FAILED: the program does not survive a reset"; exit 1; }

# ---- the trap handler's own calibration ----
# The handler is a measuring instrument: everything it is meant to find, it
# finds by halting and printing. So it gets provoked with faults whose reports
# are known in advance, and the run is scored on the text that comes out. See
# sim/trapcheck.sh - it drives all three cases through this one binary.
sim/trapimage.hex: software/soc/trapcheck.elf software/bin2hex.py Makefile
	$(RISCV_OBJCOPY) -O binary software/soc/trapcheck.elf software/soc/trapcheck.bin
	python3 software/bin2hex.py --word-size=4 --skip-words=1024 \
	    software/soc/trapcheck.bin > $@

sim/sim_trap.out: sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)
	$(IVERILOG) $(IVFLAGS) -DRAM_IMAGE='"trapimage.hex"' -DROM_IMAGE='"bootrom_$(CORE).hex"' \
	    -o $@ sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)

trapcheck: sim/bootrom_$(CORE).hex sim/sim_trap.out
	./sim/trapcheck.sh

# ---- video ----
# The framebuffer's only proof while no display is attached: draw a known
# pattern through the bus, capture a frame off the scan-out, and compare.
# Also drops sim/frame.ppm for a human to look at - but the verdict is the
# readback, not the image.
sim_video:
	$(IVERILOG) $(IVFLAGS) -o sim/sim_video.out sim/tb_video.v \
	    rtl/soc/video_timing.v rtl/soc/wb_framebuffer.v
	cd sim && $(VVP) sim_video.out

# wb_framebuffer.v's fill engine (Phase 10 stage 1): drives the blit-control
# block directly, no CPU or video_timing.v needed - this is a bus-and-FSM
# test, not a scan-out test, which sim_video already covers.
sim_blit:
	$(IVERILOG) $(IVFLAGS) -o sim/sim_blit.out sim/tb_blit.v \
	    rtl/soc/wb_framebuffer.v
	cd sim && $(VVP) sim_blit.out

# ---- hardware CMD0 probe ----
# fpga/ulx3s_cmd0.v goes on a board to answer "does the card reply to CMD0",
# so a bug in it would send someone hunting for hardware faults that are not
# there. This proves it against the card model first: 0xFF with no card, 0x01
# when one is inserted mid-run, 0xFF again when removed.
sim_cmd0:
	$(IVERILOG) $(IVFLAGS) -o sim/sim_cmd0.out sim/tb_cmd0.v \
	    sim/sd_card_model.v fpga/ulx3s_cmd0.v
	cd sim && $(VVP) sim_cmd0.out

# ---- board wrapper ----
# fpga/ulx3s_top.v is the one piece of RTL no simulation would otherwise
# touch, and fpga/top_fpga.v is the cautionary tale: it sat in the tree for
# months with unconnected page-table-walker ports because nothing built it.
# This target checks the wiring the wrapper is responsible for - pin
# direction, polarity, tie-offs - and is part of `make verify` so the file
# cannot rot the same way. It does not re-test the SoC; sim_soc does that.
sim_ulx3s: soc
	$(IVERILOG) $(IVFLAGS) -o sim/sim_ulx3s.out sim/tb_ulx3s.v \
	    $(SOC_RTL) fpga/soc_fpga.v fpga/ulx3s_top.v fpga/sdram_clk_out.v
	cd sim && $(VVP) sim_ulx3s.out

# Same reasoning as sim_ulx3s above, for docs/roadmap.md's Phase 9
# entry's own Stage 0 board wrapper - fpga/ecpix5_top.v is real RTL no
# other target would otherwise build.
sim_ecpix5: soc
	$(IVERILOG) $(IVFLAGS) -o sim/sim_ecpix5.out sim/tb_ecpix5.v \
	    $(SOC_RTL) fpga/soc_fpga.v fpga/ecpix5_top.v fpga/ecpix5_clk_pll.v
	cd sim && $(VVP) sim_ecpix5.out

# `WITH_VIDEO` is opt-in (fpga/ulx3s_top.v, BOARD=ulx3s85-video in
# fpga/synth/synth_ecp5.sh) - the primary board target above builds and
# simulates without it, matching what actually ships by default. This
# target is the only place `-DWITH_VIDEO` is exercised in `make verify`:
# without it, video_out.v is compiled but never instantiated, so
# sim_ulx3s above would silently stop testing the integration it added.
sim_ulx3s_video: soc
	$(IVERILOG) $(IVFLAGS) -DWITH_VIDEO -o sim/sim_ulx3s_video.out sim/tb_ulx3s.v \
	    $(SOC_RTL) fpga/soc_fpga.v fpga/ulx3s_top.v fpga/sdram_clk_out.v \
	    fpga/video_out.v fpga/video_pll.v fpga/tmds_serialize.v \
	    rtl/soc/tmds_encode.v
	cd sim && $(VVP) sim_ulx3s_video.out

# =====================================================================
# Device tree
# =====================================================================
dtb: dts/soc_$(CORE).dtb

# $(CORE)-suffixed - see dts/soc.dts's own header comment for why the two cpu
# nodes' `compatible` strings, and so the compiled .dtb itself, vary with
# $(CORE) now. Preprocessed with the C preprocessor first, the same
# `-x assembler-with-cpp` mode the Linux kernel's own arch/riscv/boot/dts
# tree relies on for exactly this reason: it passes a `#foo = <...>;`
# device-tree property through unrecognized while still treating
# `#ifdef`/`#else`/`#endif` as real conditionals. `-P` drops the `# <line> "file"`
# markers cpp would otherwise emit, which dtc's own parser does not expect.
dts/soc_$(CORE).dtb: dts/soc.dts
	cc -E -x assembler-with-cpp -P $(CORE_DEFINES) dts/soc.dts | dtc -I dts -O dtb -o $@
	@echo "--- round-tripping back to source as a sanity check ---"
	@dtc -I dtb -O dts $@ > /dev/null && echo "device tree OK"

# =====================================================================
# Verification
# =====================================================================
# The RTL list for anything built on the SoC. Same files as SOC_RTL, but the
# ISA/benchmark testbenches bring their own top-level rather than tb_soc.v.
ISA_TB   = sim/tb_isa.v sim/tracer.v
BENCH_TB = sim/tb_bench.v

# ---- RISC-V architectural tests (riscv-tests) ----
# Not vendored; tests/fetch.sh clones them at a pinned commit. See
# tests/README.md for what passes, what doesn't, and why.
isa-fetch:
	./tests/fetch.sh

tests/build/manifest.txt:
	@test -d tests/riscv-tests/env/p || \
	    { echo "riscv-tests not fetched - run 'make isa-fetch'"; exit 1; }
	./tests/build.sh

isa-build: tests/build/manifest.txt

sim/sim_isa.out: $(ISA_TB) $(SOC_RTL)
	$(IVERILOG) $(IVFLAGS) -o $@ $(ISA_TB) $(SOC_RTL)

# CORE is exported rather than inferred, for the same reason cosim gets
# --core: run.sh has to tell "the wide core issued nothing in slot 1" from
# "this is the in-order core, which has no slot 1", and only this file knows
# which one it just built. See tests/dual-issue-floor.txt.
isa: sim/sim_isa.out isa-build
	CORE=$(CORE) ./tests/run.sh

# ---- co-simulation against Spike ----
# Stricter than the tests: compares every retired instruction, not just the
# final verdict. Needs `spike` on PATH.
#
# --core is passed rather than detected: sim/sim_isa.out does not record which
# core it was built from, and cosim.py's dual-issue floor has to be able to
# tell "the wide core issued nothing in slot 1" (a failure) from "this is the
# in-order core" (correct). Only this file knows which one it just built.
cosim: sim/sim_isa.out isa-build
	python3 tests/cosim.py --all --core=$(CORE)

# ---- formal (yosys + yosys-smtbmc + z3) ----
formal:
	./formal/run.sh

# ---- documentation lint (markdownlint + Vale) ----
#
# `git ls-files` rather than a glob: this repo's own markdown sits next to
# fetched-not-vendored third-party trees that carry their own docs
# (tests/riscv-tests/, software/bench/coremark/, both .gitignore'd) - a
# glob would happily lint those too on a machine that has run
# isa-fetch/coremark-fetch, and nowhere else in this project's tooling
# reaches into a fetched tree's own files. `git ls-files` is exactly this
# project's own tracked markdown, identically in CI (nothing fetched, so a
# glob would have matched the same set) and on a contributor's machine
# (something fetched, where it would not have).
#
# Versions pinned in both targets (matching docs/toolchain.md's own
# practice for the RTL toolchain): 0.23.2 for markdownlint-cli2, whatever
# `vale` resolves to on PATH (installed at a pinned version by CI's own
# setup step - see .github/workflows/ci.yml). An unpinned `npx ...@latest`
# means a future upstream release can add a new rule and turn this red
# with no change in this repo at all.
lint-markdown:
	npx --yes markdownlint-cli2@0.23.2 $$(git ls-files '*.md')

lint-vale:
	vale $$(git ls-files '*.md')

lint: lint-markdown lint-vale

# ---- RTL/C/Python static analysis (Verilator lint-only + cppcheck + ruff) ----
#
# One job in CI (`Code Quality`), three ecosystems, each its own step and
# its own Makefile target - the same "one job, several tools, so a failure
# names which one" shape `lint` above already uses for markdownlint + Vale.
#
# `--lint-only` does exactly what the flag says: full elaboration and every
# warning Verilator would otherwise report as a side effect of `--cc --exe
# --build`, with no C++ compile and no testbench needed. `-Wall`
# additionally turns on Verilator's *style* category (DECLFILENAME,
# UNUSEDSIGNAL, VARHIDDEN, PINCONNECTEMPTY, and friends), off by default
# and never enabled by any real build target here - it had only ever been
# run ad hoc, by hand, against individual files during specific stages
# (docs/roadmap.md's work on cpu_core.v and plic.v, both resolved by fixing
# the RTL, not waiving). This was the first time it ran against the whole
# $(RTL)/$(SOC_RTL) file lists in one pass, and it found something real:
# rtl/top.v had a genuinely unconnected `itlb_wait_stall` output (harmless
# here - only rtl/soc/cpu_wb.v's bus adapter reads it - but previously
# implicit rather than the explicit, commented tie-off every sibling port
# already got) and rtl/mmu.v's `perm_ok` had a function-local `pa` (the
# PTE's Accessed bit) shadowing the module's own `pa` output (the resolved
# physical address) - safe by Verilog's own scoping rules, but a real
# legibility hazard, so renamed rather than waived. Both fixed at the root.
#
# `-Wno-UNUSEDSIGNAL` is a real, measured, blanket exception to that "fix
# or waive individually" rule - not an oversight. A single build already
# produced 39 UNUSEDSIGNAL findings, and every one was the same shape: a
# bus/register field this project deliberately keeps at a round width
# (32-bit address/data buses even where a specific peripheral only decodes
# a narrow window, WARL-reserved CSR bits) for uniformity across the whole
# interconnect, not a signal nothing uses. Waiving 39+ individually, per
# build, per core, would bury the rare real finding in noise rather than
# surface it - the opposite of what `-Wall` is for here. Every other
# category `-Wall` adds stays on.
#
# Remaining PINCONNECTEMPTY findings (11, both cores) were all already
# intentional, commented tie-offs (rtl/top.v's own resv_*/dbg_* ports, the
# same class of "explicit rather than omitted" decision docs/roadmap.md's
# Phase 13 stages document at length) - each now has its own scoped
# `lint_off`/`lint_on PINCONNECTEMPTY` bracket right at the site, matching
# WIDTHTRUNC/BLKSEQ's own precedent, rather than a second blanket flag.
#
# CORE-aware for the same reason every build target is: core_ooo.v's own
# structural UNOPTFLAT cycle is reachable from both top-level files, so
# $(VERILATOR_LINT_FLAGS) rides along here exactly as the real builds do -
# including on the flat rtl/top.v side, which had never been built under
# CORE=ooo in CI before.
lint-rtl-flat:
	$(VERILATOR) --lint-only -Wall -Wno-UNUSEDSIGNAL $(CORE_DEFINES) $(VERILATOR_LINT_FLAGS) \
	    --top-module top $(RTL)

# sim/verilator_soc.vlt included for the same reason the real SoC build
# includes it (its file-scoped UNOPTFLAT waivers), and $(VERILATOR_PARAMS)
# so this lints the exact RAM_BYTES/RESET_PC the real build elaborates
# against, not Verilator's own defaults.
#
# -Wno-SYNCASYNCNET is a second real, measured, blanket exception, this one
# SoC-specific: cpu_core.v resets every pipeline register asynchronously
# (`posedge clk or posedge rst`, for fast recovery regardless of clock
# activity) while several bus-adapter/peripheral registers - e.g.
# rtl/soc/wb_periph_bridge.v's own ack_r - reset synchronously
# (`posedge clk` only, simpler timing, no need for the async guarantee on
# a plain handshake register). Both styles share the same `rst`/`rst_soc`
# net by construction, which is exactly what SYNCASYNCNET is built to
# flag - correctly, but as a description of a deliberate, project-wide
# split by register role, not a defect. Confirmed by checking multiple
# independent sites (cpu_core.v, cpu_wb.v, wb_periph_bridge.v) rather than
# assumed from the one pair Verilator happened to name first.
lint-rtl-soc:
	$(VERILATOR) --lint-only -Wall -Wno-UNUSEDSIGNAL -Wno-SYNCASYNCNET \
	    $(CORE_DEFINES) $(VERILATOR_LINT_FLAGS) \
	    --top-module soc_top $(VERILATOR_PARAMS) \
	    $(SOC_RTL) sim/verilator_soc.vlt

lint-rtl: lint-rtl-flat lint-rtl-soc

# git ls-files rather than a glob, for the identical reason lint-markdown
# gives: software/bench/coremark/ is a fetched, .gitignore'd tree with its
# own C sources, and nowhere else in this project's tooling reaches into a
# fetched tree's own files.
#
# --error-exitcode=1 is load-bearing: cppcheck's own default is to exit 0
# regardless of findings, which is exactly the "test that cannot fail"
# CONTRIBUTING.md's own "what gets pushed back on" section names first.
# --enable is deliberately not "all"/"style" on a corpus that's never seen
# this tool before - the same reasoning .vale.ini gives for not using
# Vale's third-party style packs against different prose. Version: apt on
# a pinned runner OS (ubuntu-24.04), not a source build - see the Code
# Quality job's own "Install cppcheck" step for why, and how CI still
# catches an unnoticed version drift despite not pinning the package
# itself.
#
# -D'__asm__(x)=' -D'asm(x)=' are load-bearing, not decoration: cppcheck's
# own C parser cannot handle GCC's named-register-variable extension
# (`register long a7 __asm__("a7") = n;`, used throughout
# software/linux/initramfs/init.c's syscall wrappers and
# software/soc/pmptest.c's own register-poison check) and gives up on the
# whole file at the first one, silently skipping everything after it -
# confirmed by running with and without these defines and seeing
# real (non-parse-error) findings only appear once the file parses past
# that point. Defining the macro away for cppcheck's own preprocessing
# pass turns `register long a7 __asm__("a7") = n;` into the plain
# `register long a7 = n;` it can already parse - it does not touch a real
# inline-asm block (`__asm__ volatile (...)`, with a keyword between the
# name and the parenthesis), only the exact register-binding form that
# was breaking the parse.
lint-c:
	cppcheck --enable=warning,performance,portability --inline-suppr \
	    --error-exitcode=1 --suppress=missingIncludeSystem \
	    -Isoftware -Isoftware/soc \
	    -D'__asm__(x)=' -D'asm(x)=' \
	    $$(git ls-files '*.c' '*.h')

# Pinned by version (docs/toolchain.md) AND by rule selection, in
# ruff.toml: Ruff 0.16.0 (2026-07-23) expanded its own *default* enabled
# rule set from 59 rules to 413 overnight - the unpinned-tool risk this
# project's own lint job header warns about generically has already
# happened to this exact tool. Pinning only the version isn't enough on
# its own for a tool whose defaults themselves aren't stable.
lint-py:
	ruff check $$(git ls-files '*.py')

# Mirrors `bom: sbom hbom` above. Recursive $(MAKE) for CORE, the same
# shape verify_ooo already uses to re-run verify under CORE=ooo - lint-rtl
# needs it said explicitly here since nothing else drives both cores in
# one target.
code-quality: lint-c lint-py
	$(MAKE) lint-rtl CORE=inorder
	$(MAKE) lint-rtl CORE=ooo

# ---- Bill of materials (SBOM + HBOM), CycloneDX 1.5 JSON ----
#
# No RTL toolchain needed - bom/gen_sbom.py and bom/gen_hbom.py are plain
# Python 3, reading this project's own pinned-version files and RTL
# directly. See bom/gen_sbom.py's and bom/gen_hbom.py's own header
# comments for why each is generated rather than hand-maintained, and
# bom/test_bom.py for what actually gates them - unlike lint above, the
# generators themselves cannot "fail" in a way `make` would notice (bad
# JSON would still be JSON), so the check is a separate step, matching
# this project's own "run" then "check the verdict" pattern elsewhere.
bom/sbom.json: bom/gen_sbom.py .github/actions/riscv-toolchain/action.yml \
               .github/actions/oss-cad-suite/action.yml \
               .github/workflows/ci.yml Makefile tests/fetch.sh \
               software/bench/fetch-coremark.sh \
               software/opensbi/build-opensbi.sh software/linux/build-linux.sh
	python3 bom/gen_sbom.py -o $@

bom/hbom.json: bom/gen_hbom.py $(shell find rtl fpga -name '*.v') fpga/README.md
	python3 bom/gen_hbom.py -o $@

sbom: bom/sbom.json
hbom: bom/hbom.json
bom: sbom hbom
	python3 bom/test_bom.py

# ---- CoreMark ----
COREMARK_DIR   = software/bench/coremark
COREMARK_ITERS ?= 1
COREMARK_SRCS  = $(COREMARK_DIR)/core_main.c $(COREMARK_DIR)/core_list_join.c \
                  $(COREMARK_DIR)/core_matrix.c $(COREMARK_DIR)/core_state.c \
                  $(COREMARK_DIR)/core_util.c
COREMARK_PORT  = software/bench/crt0_bench.S software/bench/core_portme.c \
                  software/syscalls.c software/uart.c
# -march must match the rest of software/: rv32im is what has a multilib, and
# zicsr is needed because core_portme.c reads the `cycle` CSR directly.
#
# Split into _COMMON (everything but the linker script) so the dual-hart
# harness below (Phase 15 Stage 5) can reuse the identical flags with its own
# -T and -DCOREMARK_DUAL_HART, without duplicating this list a second time
# and risking the two builds drift apart on anything but the two flags that
# are supposed to differ.
COREMARK_CFLAGS_COMMON = -march=rv32im_zicsr_zifencei -mabi=ilp32 \
                          -specs=nano.specs -ffreestanding -O2 -nostartfiles \
                          -DITERATIONS=$(COREMARK_ITERS) -DPERFORMANCE_RUN=1 \
                          -DFLAGS_STR='"-O2 -march=rv32im"' \
                          -I$(COREMARK_DIR) -Isoftware/bench -Isoftware
COREMARK_CFLAGS = $(COREMARK_CFLAGS_COMMON) -T software/bench/link_bench.ld

coremark-fetch:
	./software/bench/fetch-coremark.sh

software/bench/coremark.elf: $(COREMARK_PORT) software/bench/link_bench.ld \
                              software/bench/core_portme.h
	@test -f $(COREMARK_DIR)/core_main.c || \
	    { echo "coremark not fetched - run 'make coremark-fetch'"; exit 1; }
	$(RISCV_CC) $(COREMARK_CFLAGS) -o $@ $(COREMARK_PORT) $(COREMARK_SRCS)

sim/coremark.hex: software/bench/coremark.elf software/bin2hex.py Makefile
	$(RISCV_OBJCOPY) -O binary software/bench/coremark.elf software/bench/coremark.bin
	python3 software/bin2hex.py --word-size=4 software/bench/coremark.bin > $@

sim/sim_bench.out: $(BENCH_TB) $(SOC_RTL)
	$(IVERILOG) $(IVFLAGS) -o $@ $(BENCH_TB) $(SOC_RTL)

coremark: sim/sim_bench.out sim/coremark.hex
	cd sim && $(VVP) sim_bench.out +hex=coremark.hex

# ---- CoreMark, both harts running it concurrently (Phase 15 Stage 5) ----
#
# Two completely independent links of the identical port layer above (see
# software/bench/link_bench_hart0.ld/link_bench_hart1.ld's own headers for
# why one shared binary can't work here), plus a tiny shared dispatcher at
# the common RESET_PC that sends each hart to its own copy by mhartid. See
# sim/tb_soc_2hart_coremark.v's own header for the full picture and
# software/bench/core_portme.c's own COREMARK_DUAL_HART block for the
# console-serialization lock this needs and why.
#
# -DCOREMARK_DUAL_HART only ever reaches these three builds, never
# software/bench/coremark.elf above - the existing single-hart baseline this
# project has published numbers against (docs/roadmap.md, every phase since
# Phase 1) stays byte-for-byte unaffected by this stage's own new code.
MC_CFLAGS = $(COREMARK_CFLAGS_COMMON) -DCOREMARK_DUAL_HART

software/bench/coremark_hart0.elf: $(COREMARK_PORT) software/bench/link_bench_hart0.ld \
                                    software/bench/core_portme.h
	@test -f $(COREMARK_DIR)/core_main.c || \
	    { echo "coremark not fetched - run 'make coremark-fetch'"; exit 1; }
	$(RISCV_CC) $(MC_CFLAGS) -T software/bench/link_bench_hart0.ld \
	    -o $@ $(COREMARK_PORT) $(COREMARK_SRCS)

software/bench/coremark_hart1.elf: $(COREMARK_PORT) software/bench/link_bench_hart1.ld \
                                    software/bench/core_portme.h
	@test -f $(COREMARK_DIR)/core_main.c || \
	    { echo "coremark not fetched - run 'make coremark-fetch'"; exit 1; }
	$(RISCV_CC) $(MC_CFLAGS) -T software/bench/link_bench_hart1.ld \
	    -o $@ $(COREMARK_PORT) $(COREMARK_SRCS)

software/bench/coremark_dispatch.elf: software/bench/coremark_dispatch.S \
                                       software/bench/link_coremark_dispatch.ld
	$(RISCV_CC) -march=rv32im_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles \
	    -T software/bench/link_coremark_dispatch.ld \
	    -o $@ software/bench/coremark_dispatch.S

sim/coremark_hart0.hex: software/bench/coremark_hart0.elf software/bin2hex.py Makefile
	$(RISCV_OBJCOPY) -O binary software/bench/coremark_hart0.elf software/bench/coremark_hart0.bin
	python3 software/bin2hex.py --word-size=4 software/bench/coremark_hart0.bin > $@

sim/coremark_hart1.hex: software/bench/coremark_hart1.elf software/bin2hex.py Makefile
	$(RISCV_OBJCOPY) -O binary software/bench/coremark_hart1.elf software/bench/coremark_hart1.bin
	python3 software/bin2hex.py --word-size=4 software/bench/coremark_hart1.bin > $@

sim/coremark_dispatch.hex: software/bench/coremark_dispatch.elf software/bin2hex.py Makefile
	$(RISCV_OBJCOPY) -O binary software/bench/coremark_dispatch.elf software/bench/coremark_dispatch.bin
	python3 software/bin2hex.py --word-size=4 software/bench/coremark_dispatch.bin > $@

sim/sim_soc_2hart_coremark.out: sim/tb_soc_2hart_coremark.v $(SOC_RTL)
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_soc_2hart_coremark.v $(SOC_RTL)

sim_soc_2hart_coremark: sim/coremark_dispatch.hex sim/coremark_hart0.hex sim/coremark_hart1.hex \
                         sim/sim_soc_2hart_coremark.out
	cd sim && $(VVP) sim_soc_2hart_coremark.out $(VVP_DUMP) | tee soc_2hart_coremark.log
	@grep -aq "SOC-2HART-COREMARK: PASS" sim/soc_2hart_coremark.log && echo "DUAL-HART COREMARK OK" || \
	    { echo "FAILED: concurrent CoreMark on both harts (CORE=$(CORE))"; exit 1; }

# ---- hardware bring-up (docs/roadmap.md Phase 2, on a board) ----
#
# Two steps, in the order they narrow the problem. Both have a simulation
# here, because a diagnostic that arrives at a board untested turns "the
# memory does not work" into a hunt through the memory, the pinout and the
# clock when the fault is in the instrument.
#
#   make sim_sdramprobe -> fpga/ulx3s_sdram.v, the no-CPU LED probe
#   make sim_sdramcheck -> software/soc/sdramcheck.c, from block RAM
#
# and the bitstreams they become:
#
#   BOARD=ulx3s-sdram        ./fpga/synth/synth_ecp5.sh
#   BOARD=ulx3s85-sdramcheck ./fpga/synth/synth_ecp5.sh
sim/sim_sdramprobe.out: sim/tb_ulx3s_sdram.v sim/sdram_model.v \
                        fpga/ulx3s_sdram.v fpga/sdram_clk_out.v rtl/soc/wb_sdram.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_ulx3s_sdram.v sim/sdram_model.v \
	    fpga/ulx3s_sdram.v fpga/sdram_clk_out.v rtl/soc/wb_sdram.v

sim_sdramprobe: sim/sim_sdramprobe.out
	cd sim && $(VVP) sim_sdramprobe.out $(VVP_DUMP)

# Same testbench and the same 64 KB block RAM as sim_ramboot - only the
# preloaded program differs, which is exactly the difference between the two
# bitstreams as well.
software/soc/sdramcheck.elf: $(SOCRT_SRCS) software/soc/sdramcheck.c \
                              software/soc/link_ram.ld $(SOC_HDRS)
	$(RISCV_CC) $(SOCPROG_CFLAGS) -T software/soc/link_ram.ld \
	    -o $@ $(SOCRT_SRCS) software/soc/sdramcheck.c

sim/sdramcheckimage.hex: software/soc/sdramcheck.elf software/bin2hex.py Makefile
	$(RISCV_OBJCOPY) -O binary software/soc/sdramcheck.elf software/soc/sdramcheck.bin
	python3 software/bin2hex.py --word-size=4 --skip-words=1024 \
	    software/soc/sdramcheck.bin > $@

# ---- the same program over the whole part ----
#
# 256 KB is what silicon has ever been asked to hold, and rtl/soc/wb_sdram.v
# maps wb_adr[24:12] to the row - so that is 64 of 8192 rows, with seven of
# the thirteen row address bits never driven high. A kernel needs about 28 MB.
# `sdramcheck.c` prints those ranges at startup now, so the short run says how
# short it is.
#
# This build sweeps all 32 MB. It is a different .elf rather than a runtime
# flag because it has to be *the image a bitstream bakes in*, and a knob a
# board build could get wrong is not worth the flexibility.
#
# Icarus cannot run it - `make sim_sdramcheck` is minutes at 256 KB and this
# is 128 times the work. Verilator can: `make verilator_sdramfull` does the
# whole part in well under a minute, which is what keeps this from being a
# bitstream nobody has ever executed. practices section 4.
software/soc/sdramfull.elf: $(SOCRT_SRCS) software/soc/sdramcheck.c \
                              software/soc/link_ram.ld $(SOC_HDRS)
	$(RISCV_CC) $(SOCPROG_CFLAGS) -DSWEEP_BYTES=0x02000000u \
	    -T software/soc/link_ram.ld \
	    -o $@ $(SOCRT_SRCS) software/soc/sdramcheck.c

sim/sdramfullimage.hex: software/soc/sdramfull.elf software/bin2hex.py Makefile
	$(RISCV_OBJCOPY) -O binary software/soc/sdramfull.elf software/soc/sdramfull.bin
	python3 software/bin2hex.py --word-size=4 --skip-words=1024 \
	    software/soc/sdramfull.bin > $@

sdramfullimage: sim/sdramfullimage.hex

# The whole 32 MB, swept densely, under Verilator.
#
# This needs a *second* Verilator binary and that is the whole difficulty.
# VERILATOR_PARAMS builds soc_top with RESET_PC=0x9000_0000 because the
# harness models sim/tb_sdramboot.v, where execution starts in SDRAM. A
# program that runs from block RAM never starts under it - it sat there
# printing nothing, which is what sent this down a wrong path once already.
#
# So: same RTL, same harness, RESET_PC at the block-RAM program instead. That
# skips the boot ROM, which on a board would only have jumped here anyway
# (PROGRAM_LOAD_ADDR in software/soc/soc.h, and bin2hex's --skip-words=1024 is
# the same 0x1000).
#
# What it buys: the bitstream BOARD=ulx3s85-sdramfull bakes in has been
# executed before it is flashed - 8 million words written and read back, and
# the retention interval that produces measured rather than assumed. Icarus
# cannot do this run; it is hours at 256 KB's rate.
VERILATOR_RAMBOOT_MDIR = obj_dir_soc_ramboot
VERILATOR_RAMBOOT_BIN  = $(VERILATOR_RAMBOOT_MDIR)/Vsoc_top

$(VERILATOR_RAMBOOT_BIN): $(SOC_RTL) sim/verilator_soc.cpp sim/verilator_soc.vlt Makefile
	$(VERILATOR) --cc --exe --build -j 4 -O3 -CFLAGS "-O2 $(CORE_DEFINES)" \
	    --top-module soc_top $(CORE_DEFINES) $(VERILATOR_LINT_FLAGS) \
	    -GRAM_BYTES=65536 -GRESET_PC=0x80001000 \
	    --Mdir $(VERILATOR_RAMBOOT_MDIR) \
	    $(SOC_RTL) sim/verilator_soc.vlt sim/verilator_soc.cpp

# `+sdram_words` is 16,777,216 sixteen-bit words - the whole part. The
# harness's default models 4 MB and the sweep would run off the end of it,
# which the model reports rather than quietly wrapping.
verilator_sdramfull: sim/sdramfullimage.hex $(VERILATOR_RAMBOOT_BIN)
	@cd sim && ../$(VERILATOR_RAMBOOT_BIN) +ram=sdramfullimage.hex \
	    +sdram_words=16777216 +maxcycles=2000000000 \
	    +stopon="SDRAM-CHECK:" | tee sdramfull.log
	@grep -aq "SDRAM-CHECK: PASS" sim/sdramfull.log && \
	    echo "SDRAM FULL-PART CHECK PASSED" || \
	    { echo "SDRAM FULL-PART CHECK FAILED"; exit 1; }
	@grep -aq "rows 0..8191 of 8192" sim/sdramfull.log || \
	    { echo "FAILED: the full-part build did not sweep the full part"; \
	      exit 1; }

# ---- OpenSBI, packed into an SDRAM image ----
#
# Not part of `verify`: it needs OpenSBI's source tree, which
# software/opensbi/build-opensbi.sh clones, and a network is not a build
# dependency this project is willing to have. Run it by hand:
#
#   ./software/opensbi/build-opensbi.sh          # once, clones and builds
#   make sbiimage      -> pack stub + device tree + OpenSBI into an SDRAM image
#   make sim_opensbi   -> boot it, and check the banner and platform detection
#   cd sim && ../obj_dir_soc_inorder/Vsoc_top \
#            +sdram=sbiimage_inorder.hex +uart_clks=208 +maxcycles=8000000
#
# `+uart_clks=208` is not arbitrary: OpenSBI reads `clock-frequency` from
# dts/soc.dts and programs the ns16550 divisor to 25e6/(16*115200) = 13, so
# the line runs at 208 clocks per bit rather than the testbenches' 4. See
# software/opensbi/README.md for how far this currently gets.
OPENSBI_DIR = software/opensbi/build/opensbi/build/platform/generic/firmware
OPENSBI_FW  = $(OPENSBI_DIR)/fw_jump.bin
OPENSBI_ELF = $(OPENSBI_DIR)/fw_jump.elf

software/opensbi/build/sbi_stub.bin: software/opensbi/sbi_stub.S
	$(RISCV_CC) -march=rv32im_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
	    -Wl,-Ttext=0x90000000 -o software/opensbi/build/sbi_stub.elf $<
	$(RISCV_OBJCOPY) -O binary software/opensbi/build/sbi_stub.elf $@

# dts/soc_$(CORE).dtb, not a fixed dts/soc.dtb - the two cpu nodes'
# `compatible` strings vary with $(CORE) now (dts/soc.dts's own header).
#
# $(CORE)-suffixed too, all the way to sim/sbiimage_$(CORE).hex below - a
# first attempt at this fix left this one (and linuximage.hex below) as a
# single shared filename, reasoning that neither OpenSBI nor Linux keys real
# *behavior* off the vendor-specific half of the compatible string, so a
# stale one would be cosmetic rather than functional. That reasoning missed
# that "cosmetic" is not "harmless": a real `make verify` (CORE=inorder) then
# `make verify_ooo` in one tree left a Linux boot's own `/proc/cpuinfo`
# printing `uarch : riscv-fpga-cpu,cpu-inorder` while running on a genuinely
# `core_ooo.v`-built hart 0 - Make's own mtime tracking correctly saw this
# fixed-name file newer than its own dts/soc_ooo.dtb prerequisite (built
# minutes earlier, by hand, before either gate ran) and skipped rebuilding
# it, exactly the staleness class this whole stage exists to close, just
# found in the two files this account first argued were exempt from it.
sim/sbiimage_$(CORE).hex: software/opensbi/build/sbi_stub.bin dts/soc_$(CORE).dtb \
                   software/opensbi/mkimage.py Makefile
	@test -f $(OPENSBI_FW) || { \
	    echo "$(OPENSBI_FW) is missing - run ./software/opensbi/build-opensbi.sh first"; \
	    exit 1; }
	python3 software/opensbi/mkimage.py --nm=$(RISCV_NM) \
	    software/opensbi/build/sbi_stub.bin dts/soc_$(CORE).dtb \
	    $(OPENSBI_FW) $(OPENSBI_ELF) > $@

sbiimage: sim/sbiimage_$(CORE).hex

# Boot it. Not part of `verify` for the same reason `sbiimage` is not: it
# needs OpenSBI's cloned source tree.
#
# `+uart_clks=224` is not a guess. OpenSBI reads `clock-frequency` from
# dts/soc.dts and programs the ns16550 divisor, rounding rather than
# truncating: (25e6 + 8*115200) / (16*115200) = 14, so 224 clocks per bit and
# not the 208 that 25e6/(16*115200) suggests. The harness prints the divisor
# the UART is actually running at and says so when it disagrees, because a
# mismatch prints convincing garbage rather than nothing - which reads as a
# firmware fault instead of a decoding one, and did for one round.
#
# 16 M words is the whole 32 MB part. It used to be 8 MB, which was enough
# while FW_JUMP_FDT_ADDR was 0x9020_0000; that address is 0x91E0_0000 now,
# because arch/riscv drops every memory range below the kernel and a device
# tree underneath it is in memory Linux has decided does not exist. See
# software/opensbi/build-opensbi.sh.
sim_opensbi: sim/sbiimage_$(CORE).hex $(VERILATOR_BIN)
	@cd sim && ../$(VERILATOR_BIN) +sdram=sbiimage_$(CORE).hex +uart_clks=224 \
	    +maxcycles=40000000 +sdram_words=16777216 | tee opensbi.log
	@grep -q "Boot HART Base ISA          : rv32ima" sim/opensbi.log && \
	    grep -q "Platform Console Device     : uart8250" sim/opensbi.log && \
	    echo "OPENSBI BOOT PASSED" || \
	    { echo "OPENSBI BOOT FAILED - no banner, or the platform was not detected"; \
	      exit 1; }

# ---- OpenSBI, with a second hart (Phase 13, Stage 10) ----
#
# Same sbiimage_$(CORE).hex, same OpenSBI binary, same dts/soc_$(CORE).dtb
# (now with a cpu@1 node) - the only difference is the soc_top build underneath it,
# at NUM_HARTS=2 instead of the default 1. Not part of `verify`, for the
# same reason `sim_opensbi` is not (needs OpenSBI's cloned source tree);
# run it by hand the same way. $(VERILATOR_2HART_BIN) (below) is CORE-aware
# since Stage 17 - both cores build here now.
#
# 150M cycles, not sim_opensbi's own 40M: measured, not guessed - a 40M-cycle
# run here times out having printed only the ASCII banner, nothing else, which
# first looked like a hang (traced to a real, if slow, libfdt device-tree walk
# taking noticeably longer with two /cpus subnodes to enumerate instead of
# one). A 100M-cycle run reaches "Platform HART Count : 2" and the rest of the
# banner cleanly; 150M leaves real margin rather than pinning to the
# measurement exactly.
VERILATOR_2HART_MDIR = obj_dir_soc_2hart_$(CORE)
VERILATOR_2HART_BIN  = $(VERILATOR_2HART_MDIR)/Vsoc_top

# CORE-aware since Phase 13 stage 17, the same fix stage 16 already made to
# sim_soc_2hart_lrsc's own build rule: $(SOC_RTL_BASE) (never $(CORE_RTL))
# and no $(CORE_DEFINES) meant this always built and booted the in-order
# core regardless of ambient CORE=ooo, exactly the false-pass hazard that
# fix eliminated elsewhere - rtl/ooo/core_ooo.v has had real cross-hart
# LR/SC coherence since that stage, so there is now something for a
# CORE=ooo build here to prove. $(VERILATOR_2HART_MDIR) is CORE-suffixed
# for the same reason $(VERILATOR_MDIR) already is: a built simulation does
# not record which core it was built with, so an in-order and an ooo
# 2-hart build must not share one output directory.
$(VERILATOR_2HART_BIN): $(SOC_RTL) sim/verilator_soc.cpp sim/verilator_soc.vlt Makefile
	$(VERILATOR) --cc --exe --build -j 4 -O3 -CFLAGS "-O2 $(CORE_DEFINES)" \
	    --top-module soc_top $(CORE_DEFINES) $(VERILATOR_LINT_FLAGS) \
	    -GRAM_BYTES=65536 -GRESET_PC=0x90000000 -GNUM_HARTS=2 \
	    --Mdir $(VERILATOR_2HART_MDIR) \
	    $(SOC_RTL) sim/verilator_soc.vlt sim/verilator_soc.cpp

sim_opensbi_2hart: sim/sbiimage_$(CORE).hex $(VERILATOR_2HART_BIN)
	@cd sim && ../$(VERILATOR_2HART_BIN) +sdram=sbiimage_$(CORE).hex +uart_clks=224 \
	    +maxcycles=150000000 +sdram_words=16777216 | tee opensbi_2hart.log
	@grep -q "Platform HART Count         : 2" sim/opensbi_2hart.log && \
	    grep -q "Boot HART Base ISA          : rv32ima" sim/opensbi_2hart.log && \
	    echo "OPENSBI 2-HART BOOT PASSED" || \
	    { echo "OPENSBI 2-HART BOOT FAILED - hart count not 2, or no banner"; \
	      exit 1; }

# ---- Linux, packed into the same SDRAM image ----
#
# Not part of `verify`, for the same reason OpenSBI is not: building it needs
# a 150 MB kernel tarball off the network. Run it by hand:
#
#   ./software/opensbi/build-opensbi.sh    # once
#   ./software/linux/build-linux.sh        # once, fetches and builds Linux
#   make linuximage                        # pack stub + dtb + OpenSBI + Image
#   make sim_linux                         # boot it under Verilator
#
# `make linuxpayload` writes the same bytes as a flat binary, which is what
# software/soc/uartload.py sends to a board. One script emits both so the
# simulated image and the hardware image cannot drift apart.
LINUX_IMAGE = software/linux/build/Image

#
# $(wildcard) rather than a plain prerequisite: it expands to nothing when the
# kernel has not been built, so the `test -f` below gets to say which script to
# run instead of make saying "no rule to make target" - and to the path once it
# exists, so rebuilding the kernel repacks the image.
# dts/soc_$(CORE).dtb, not a fixed dts/soc.dtb - and $(CORE)-suffixed all the
# way to sim/linuximage_$(CORE).hex below, the same correction sbiimage's own
# rule above explains in full (a real staleness bug, not a hypothetical one,
# found by testing this stage's own first attempt).
#
# software/linux/build/sdram.bin (the flat-binary twin `linuxpayload` below
# reports) stays a fixed name, deliberately not $(CORE)-suffixed like the
# .hex above it: it is a real-hardware flashing artifact, and no board build
# has ever asked for anything but CORE=inorder (rtl/ooo/core_ooo.v has no
# measurable Fmax on real hardware at all, Phase 1's own still-open
# finding), so there is no second $(CORE) value it could ever silently go
# stale against in practice, unlike the simulation-only .hex this rule also
# produces.
sim/linuximage_$(CORE).hex: software/opensbi/build/sbi_stub.bin dts/soc_$(CORE).dtb \
                     software/opensbi/mkimage.py Makefile \
                     $(wildcard $(LINUX_IMAGE))
	@test -f $(OPENSBI_FW) || { \
	    echo "$(OPENSBI_FW) is missing - run ./software/opensbi/build-opensbi.sh first"; \
	    exit 1; }
	@test -f $(LINUX_IMAGE) || { \
	    echo "$(LINUX_IMAGE) is missing - run ./software/linux/build-linux.sh first"; \
	    exit 1; }
	python3 software/opensbi/mkimage.py --nm=$(RISCV_NM) \
	    --kernel=$(LINUX_IMAGE) --bin=software/linux/build/sdram.bin \
	    software/opensbi/build/sbi_stub.bin dts/soc_$(CORE).dtb \
	    $(OPENSBI_FW) $(OPENSBI_ELF) > $@

linuximage: sim/linuximage_$(CORE).hex

linuxpayload: sim/linuximage_$(CORE).hex
	@ls -la software/linux/build/sdram.bin | \
	    awk '{printf "  %s  %.1f KB\n", $$9, $$5/1024}'
	@echo "  send with: ./software/soc/uartload.py /dev/cu.usbserial-XXXX \\"
	@echo "                 software/linux/build/sdram.bin"

# The whole 32 MB is modelled because the kernel runs from 0x9040_0000 and
# OpenSBI puts its device tree at 0x91E0_0000.
#
# `+stopon` is what makes this affordable. A bare-metal program here ends by
# storing a magic word in block RAM; Linux ends a boot by *printing*, so
# without a console trigger every run - passing or failing - costs the full
# +maxcycles. The marker is the last line software/linux/initramfs/init.c
# prints, so seeing it means everything before it also ran.
LINUX_MARKER = VERNIER-RV32-LINUX-BOOT-OK

# ---- the same boot on both cores, compared by the traps it took ----
#
# The wide core boots the whole kernel and then fails execve with -EFAULT.
# Everything that could be checked against an independent model was already
# passing on it - translations, bus reads, both decode slots, riscv-tests and
# CoreMark - so the next instrument had to look at the boot rather than at a
# test, and the cheapest thing a failing boot produces that a passing one does
# not is a trap.
#
# Interrupts are what makes this non-trivial: the two cores take different
# numbers of cycles for the same instructions, so a timer lands at a different
# instruction in each and the raw traces diverge within a hundred traps for
# reasons that are not defects. tests/traptrace.py drops interrupts and
# compares exceptions by (privilege, target, cause, epc, tval).
#
# Both runs are allowed to exit non-zero. The wide core's boot *is* the
# failing one - it never reaches the marker and stops on +maxcycles - so a
# rule that required success here could only ever run when there was nothing
# to diagnose.
#
# Not in `verify` for the same reason `sim_linux` is not: it needs a kernel
# off the network.
#
# Always the CORE=inorder-flavored image specifically, regardless of ambient
# $(CORE) - the same reasoning `sim_ramboot_2hart_hetero` above already has
# for its own recursive `$(MAKE) ... CORE=hetero` sub-build: sim/
# linuximage_$(CORE).hex is a static rule keyed off whatever $(CORE) means
# for the whole outer invocation, not a real per-target parameter. Which
# $(CORE) built the one shared image is an arbitrary, deterministic choice
# here specifically because it does not matter to what this tool checks: the
# two Vsoc_top binaries below are what differs (one inorder, one ooo), and
# the whole point is comparing trap behavior of the *same* compiled kernel
# image against both - the embedded compatible string plays no role in
# that comparison either way.
linux_trapdiff: sim/linuximage_inorder.hex
	@$(MAKE) -s obj_dir_soc_inorder/Vsoc_top CORE=inorder
	@$(MAKE) -s obj_dir_soc_ooo/Vsoc_top CORE=ooo
	@cd sim && ../obj_dir_soc_inorder/Vsoc_top +sdram=linuximage_inorder.hex \
	    +uart_clks=224 +sdram_words=16777216 +maxcycles=400000000 +quiet \
	    +stopon=$(LINUX_MARKER) +traptrace=trap_inorder.txt > /dev/null || true
	@cd sim && ../obj_dir_soc_ooo/Vsoc_top +sdram=linuximage_inorder.hex \
	    +uart_clks=224 +sdram_words=16777216 +maxcycles=400000000 +quiet \
	    +stopon=$(LINUX_MARKER) +traptrace=trap_ooo.txt > /dev/null || true
	python3 tests/traptrace.py sim/trap_inorder.txt sim/trap_ooo.txt \
	    --map software/linux/build/System.map

sim_linux: sim/linuximage_$(CORE).hex $(VERILATOR_BIN)
	@cd sim && ../$(VERILATOR_BIN) +sdram=linuximage_$(CORE).hex +uart_clks=224 \
	    +sdram_words=16777216 +maxcycles=400000000 +checkuart \
	    +stopon=$(LINUX_MARKER) | tee linux.log
# The `===` are load-bearing and this gate was wrong without them. The
# harness reports what +stopon was looking for - `stopon "MARKER": never seen
# in 400000000 cycles` - so a grep for the bare marker matches the harness
# telling you it never appeared, and a failing boot reports success. It did,
# on the first run of this target. docs/practices.md section 26: a suite that
# passes is not a suite that ran the code. Only
# software/linux/initramfs/init.c prints the delimited form.
# Two gates, because they fail differently. The marker says the boot reached
# `/init`; `+checkuart` says the console carried every byte software wrote to
# it. A boot can reach the marker with output that is unreadable either side of
# it - that is exactly what a device tree claiming a sixteen-byte FIFO on a
# one-byte holding register produced - and a log nobody can read is not a
# passing boot.
#
# `-a` on both, and it is load-bearing rather than tidiness. A console failure
# puts bytes above 0x7f in this log, grep then calls the file binary, and
# `grep -q` on a binary file exits *non-zero even when the pattern is there* -
# checked on this machine, not assumed. So the gate that exists to report a
# garbled boot was the gate a garbled boot disabled, and it would have called a
# boot that reached userspace a failure. Same lesson as the `===` note above:
# the failing case is the one the gate has to survive.
	@grep -aq "dropped by the transmitter" sim/linux.log && \
	    { echo "LINUX BOOT FAILED - the console did not send every byte"; \
	      exit 1; } || true
	@grep -aq "=== $(LINUX_MARKER) ===" sim/linux.log && \
	    echo "LINUX BOOT PASSED - reached userspace" || \
	    { echo "LINUX BOOT FAILED - never reached /init"; exit 1; }

# ---- Linux, with a second hart (Phase 13, Stage 11) ----
#
# The same sim/linuximage_$(CORE).hex sim_linux already builds - same
# OpenSBI, same stub, same dts/soc_$(CORE).dtb (both cpu@0 and cpu@1), same kernel Image, built
# with CONFIG_SMP=y (software/linux/vernier_rv32.config) - only the soc_top
# build parameter differs, exactly like sim_opensbi_2hart. Not part of
# `verify`, for the same reason `sim_linux` itself is not: it needs a kernel
# off the network. Same 400M-cycle budget as `sim_linux` - measured at
# 286,259,012 cycles to reach the marker here, comfortably inside it, so no
# separate number was needed.
#
# This is the roadmap's own last "Done when" clause for Phase 13: not just
# that OpenSBI can count two harts (Stage 10), but that a real kernel brings
# up a second one and both reach userspace. `smp: Brought up 1 node, 2 CPUs`
# is Linux's own accounting, not this harness's; `/proc/cpuinfo` printing
# both `processor 0` and `processor 1` is what `grep`s below actually check.
# It is also, incidentally, the first real stress test cross-hart LR/SC
# coherence (Stage 9) has seen outside its own directed test - spinlocks and
# RCU lean on working atomics constantly during SMP bring-up, and a broken
# reservation_monitor.v connection would much more plausibly hang or corrupt
# state here than pass quietly.
sim_linux_2hart: sim/linuximage_$(CORE).hex $(VERILATOR_2HART_BIN)
	@cd sim && ../$(VERILATOR_2HART_BIN) +sdram=linuximage_$(CORE).hex +uart_clks=224 \
	    +sdram_words=16777216 +maxcycles=400000000 +checkuart \
	    +stopon=$(LINUX_MARKER) | tee linux_2hart.log
	@grep -aq "dropped by the transmitter" sim/linux_2hart.log && \
	    { echo "LINUX 2-HART BOOT FAILED - the console did not send every byte"; \
	      exit 1; } || true
	@grep -aq "=== $(LINUX_MARKER) ===" sim/linux_2hart.log && \
	    grep -aq "processor	: 0" sim/linux_2hart.log && \
	    grep -aq "processor	: 1" sim/linux_2hart.log && \
	    echo "LINUX 2-HART BOOT PASSED - both harts reached userspace" || \
	    { echo "LINUX 2-HART BOOT FAILED - never reached /init, or only one hart did"; \
	      exit 1; }

# ---- the ns16550 register map, and the UART's interrupt ----
#
# The surface a *driver* touches that no program here did: DLAB, the divisor
# latch, IIR, MSR, and an interrupt reaching mip through PLIC source 1.
UARTTEST_SRCS = $(SOCRT_SRCS) software/soc/uarttest.c

software/soc/uarttest.elf: $(UARTTEST_SRCS) software/soc/link_ram.ld $(SOC_HDRS)
	$(RISCV_CC) $(SOC_CFLAGS_COMMON) -T software/soc/link_ram.ld \
	    -o $@ $(UARTTEST_SRCS)

sim/uart16550image.hex: software/soc/uarttest.elf software/bin2hex.py Makefile
	$(RISCV_OBJCOPY) -O binary software/soc/uarttest.elf software/soc/uarttest.bin
	python3 software/bin2hex.py --word-size=4 --skip-words=1024 \
	    software/soc/uarttest.bin > $@

sim/sim_uart16550.out: sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)
	$(IVERILOG) $(IVFLAGS) -DRAM_IMAGE='"uart16550image.hex"' -DROM_IMAGE='"bootrom_$(CORE).hex"' \
	    -o $@ sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)

sim_uart16550: sim/bootrom_$(CORE).hex sim/uart16550image.hex sim/sim_uart16550.out
	@cd sim && $(VVP) sim_uart16550.out $(VVP_DUMP) 2>&1 | tee uart16550.log
	@grep -q "RAMBOOT TEST PASSED" sim/uart16550.log || \
	    { echo "sim_uart16550 FAILED"; exit 1; }

# ---- the PLIC: standard layout, two contexts, S-mode delivery ----
#
# The first program here that ever takes an external interrupt. sim/program.S
# pokes the PLIC's registers and the formal properties prove its claim
# encoder, but nothing had ever checked that a hart sees the line - in either
# privilege mode. software/soc/plictest.c explains what that missed.
PLICTEST_SRCS = $(SOCRT_SRCS) software/soc/plictest.c

software/soc/plictest.elf: $(PLICTEST_SRCS) software/soc/link_ram.ld $(SOC_HDRS)
	$(RISCV_CC) $(SOC_CFLAGS_COMMON) -T software/soc/link_ram.ld \
	    -o $@ $(PLICTEST_SRCS)

sim/plicimage.hex: software/soc/plictest.elf software/bin2hex.py Makefile
	$(RISCV_OBJCOPY) -O binary software/soc/plictest.elf software/soc/plictest.bin
	python3 software/bin2hex.py --word-size=4 --skip-words=1024 \
	    software/soc/plictest.bin > $@

sim/sim_plic.out: sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)
	$(IVERILOG) $(IVFLAGS) -DRAM_IMAGE='"plicimage.hex"' -DROM_IMAGE='"bootrom_$(CORE).hex"' \
	    -o $@ sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)

sim_plic: sim/bootrom_$(CORE).hex sim/plicimage.hex sim/sim_plic.out
	@cd sim && $(VVP) sim_plic.out $(VVP_DUMP) 2>&1 | tee plic.log
	@grep -q "RAMBOOT TEST PASSED" sim/plic.log || \
	    { echo "sim_plic FAILED"; exit 1; }

# ---- Phase 13: PLIC NUM_CONTEXTS default bumped to 4 ----
#
# Board-independent, like sim_pmp/sim_clint_multihart above: proves the two
# new contexts (a second hart's own M-mode/S-mode) land at the exact byte
# offsets software/soc/soc.h's own macros expect and are independently
# addressable, complementing formal/run.sh's "plic" target (which proves the
# logical properties generically but does not independently check the
# strided address arithmetic) - see docs/roadmap.md's Phase 13 entry.
sim/sim_plic_4ctx.out: sim/tb_plic_4ctx.v rtl/plic.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_plic_4ctx.v rtl/plic.v

sim_plic_4ctx: sim/sim_plic_4ctx.out
	cd sim && $(VVP) sim_plic_4ctx.out $(VVP_DUMP) | tee plic_4ctx.log
	@grep -aq "PLIC-4CTX-TEST: PASS" sim/plic_4ctx.log && echo "PLIC 4CTX OK" || \
	    { echo "FAILED: plic.v NUM_CONTEXTS default"; exit 1; }

# ---- PMP: real S-mode enforcement, wired to the data access path ----
#
# rtl/pmp.v's own matching logic and rv32mi-p-pmpaddr's CSR-storage check
# both predate this - neither one drives a real load or store through the
# module. software/soc/pmptest.c's header explains what's configured and why.
#
# $(SOC_RTL) and $(IVFLAGS), like every other core-sensitive test (sim_plic,
# sim_mmusdram) - NOT $(SOC_RTL_BASE), which this recipe hardcoded to
# cpu_core.v when PMP enforcement was CORE=inorder only. Now that both
# rtl/ooo/core_ooo.v and rtl/cpu_core.v enforce PMP on their data path *and*
# instruction fetch (see docs/roadmap.md's PMP entry), this test should
# exercise whichever core is active, the same way every other directed test
# does - a `make verify_ooo` run that never touched core_ooo.v's own
# enforcement logic would leave exactly the same "verify_ooo passes" false
# confidence docs/roadmap.md warned against, just for a different core.
PMPTEST_SRCS = $(SOCRT_SRCS) software/soc/pmptest.c

software/soc/pmptest.elf: $(PMPTEST_SRCS) software/soc/link_ram.ld $(SOC_HDRS)
	$(RISCV_CC) $(SOC_CFLAGS_COMMON) -T software/soc/link_ram.ld \
	    -o $@ $(PMPTEST_SRCS)

sim/pmptestimage.hex: software/soc/pmptest.elf software/bin2hex.py Makefile
	$(RISCV_OBJCOPY) -O binary software/soc/pmptest.elf software/soc/pmptest.bin
	python3 software/bin2hex.py --word-size=4 --skip-words=1024 \
	    software/soc/pmptest.bin > $@

sim/sim_pmptest.out: sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)
	$(IVERILOG) $(IVFLAGS) -DRAM_IMAGE='"pmptestimage.hex"' -DROM_IMAGE='"bootrom_$(CORE).hex"' \
	    -o $@ sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)

sim_pmptest: sim/bootrom_$(CORE).hex sim/pmptestimage.hex sim/sim_pmptest.out
	@cd sim && $(VVP) sim_pmptest.out $(VVP_DUMP) 2>&1 | tee pmptest.log
	@grep -q "RAMBOOT TEST PASSED" sim/pmptest.log || \
	    { echo "sim_pmptest FAILED"; exit 1; }

# ---- interrupt-driven UART TX: using the interrupt, not just proving it ----
#
# plictest.c proves the PLIC delivers the UART's interrupt to S-mode, and
# disarms it the moment it has. software/soc/uartirq.c is the driver that was
# still missing: a ring buffer fed one byte per interrupt, and a demonstration
# that the hart does unrelated work while the transfer is in flight instead of
# blocking on LSR.THRE the way every put_char in this repository still does.
UARTIRQTEST_SRCS = $(SOCRT_SRCS) software/soc/uartirq.c

software/soc/uartirq.elf: $(UARTIRQTEST_SRCS) software/soc/link_ram.ld $(SOC_HDRS)
	$(RISCV_CC) $(SOC_CFLAGS_COMMON) -T software/soc/link_ram.ld \
	    -o $@ $(UARTIRQTEST_SRCS)

sim/uartirqimage.hex: software/soc/uartirq.elf software/bin2hex.py Makefile
	$(RISCV_OBJCOPY) -O binary software/soc/uartirq.elf software/soc/uartirq.bin
	python3 software/bin2hex.py --word-size=4 --skip-words=1024 \
	    software/soc/uartirq.bin > $@

sim/sim_uartirq.out: sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)
	$(IVERILOG) $(IVFLAGS) -DRAM_IMAGE='"uartirqimage.hex"' -DROM_IMAGE='"bootrom_$(CORE).hex"' \
	    -o $@ sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)

sim_uartirq: sim/bootrom_$(CORE).hex sim/uartirqimage.hex sim/sim_uartirq.out
	@cd sim && $(VVP) sim_uartirq.out $(VVP_DUMP) 2>&1 | tee uartirq.log
	@grep -q "RAMBOOT TEST PASSED" sim/uartirq.log || \
	    { echo "sim_uartirq FAILED"; exit 1; }

# ---- __div64_32, isolated ----
#
# docs/roadmap.md's "Stage 1d was built anyway" section ("Update 3") has why:
# sim_linux CORE=ooo was found permanently stuck inside this exact kernel
# routine. software/soc/div64test.c is the same function, copied verbatim,
# called with a spread of operands and checked against host-computed
# answers - a fast, deterministic way to ask whether CORE=ooo gets it wrong
# without a 90-million-cycle Linux boot in the way.
DIV64TEST_SRCS = $(SOCRT_SRCS) software/soc/div64test.c

software/soc/div64test.elf: $(DIV64TEST_SRCS) software/soc/link_ram.ld $(SOC_HDRS)
	$(RISCV_CC) $(SOC_CFLAGS_COMMON) -T software/soc/link_ram.ld \
	    -o $@ $(DIV64TEST_SRCS)

sim/div64testimage.hex: software/soc/div64test.elf software/bin2hex.py Makefile
	$(RISCV_OBJCOPY) -O binary software/soc/div64test.elf software/soc/div64test.bin
	python3 software/bin2hex.py --word-size=4 --skip-words=1024 \
	    software/soc/div64test.bin > $@

sim/sim_div64test.out: sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)
	$(IVERILOG) $(IVFLAGS) -DRAM_IMAGE='"div64testimage.hex"' -DROM_IMAGE='"bootrom_$(CORE).hex"' \
	    -o $@ sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)

sim_div64test: sim/bootrom_$(CORE).hex sim/div64testimage.hex sim/sim_div64test.out
	@cd sim && $(VVP) sim_div64test.out $(VVP_DUMP) 2>&1 | tee div64test.log
	@grep -q "RAMBOOT TEST PASSED" sim/div64test.log || \
	    { echo "sim_div64test FAILED"; exit 1; }

# ---- Sv32 with the page tables in external SDRAM ----
#
# The test for the two changes that let a page table live in DRAM at all:
# rtl/soc/wb_ptw.v (the walkers became a bus master, so a PTE can come from
# any slave) and wb_interconnect.v's masked decode (so the top half of a
# 32 MB part is addressable). software/soc/mmutest.c explains how each of
# them fails loudly rather than quietly if reverted.
#
# The SDRAM model is 16 MB here rather than the usual 2, because the page
# table deliberately maps addresses above 0x9100_0000 - which is the half of
# the part that did not exist before the decode was masked. That costs about
# 140 MB of simulator memory and two seconds to clear.
MMUTEST_SRCS = $(SOCRT_SRCS) software/soc/mmutest.c

software/soc/mmutest.elf: $(MMUTEST_SRCS) software/soc/link_ram.ld $(SOC_HDRS)
	$(RISCV_CC) $(SOC_CFLAGS_COMMON) -T software/soc/link_ram.ld \
	    -o $@ $(MMUTEST_SRCS)

# --skip-words=1024, like every other preloaded image: link_ram.ld puts the
# program at PROGRAM_LOAD_ADDR (RAM_BASE + 0x1000) and the first 4 KB is the
# verdict word and the boot stack. Without it the image lands at offset 0, the
# boot ROM does not recognise a preloaded program, and the run goes looking
# for an SD card that is not there.
sim/mmuimage.hex: software/soc/mmutest.elf software/bin2hex.py Makefile
	$(RISCV_OBJCOPY) -O binary software/soc/mmutest.elf software/soc/mmutest.bin
	python3 software/bin2hex.py --word-size=4 --skip-words=1024 \
	    software/soc/mmutest.bin > $@

sim/sim_mmusdram.out: sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)
	$(IVERILOG) $(IVFLAGS) -DRAM_IMAGE='"mmuimage.hex"' -DROM_IMAGE='"bootrom_$(CORE).hex"' \
	    -DSDRAM_WORDS='((1<<23)+(1<<16))' \
	    -o $@ sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)

sim_mmusdram: sim/bootrom_$(CORE).hex sim/mmuimage.hex sim/sim_mmusdram.out
	@cd sim && $(VVP) sim_mmusdram.out $(VVP_DUMP) 2>&1 | tee mmusdram.log
	@grep -q "RAMBOOT TEST PASSED" sim/mmusdram.log || \
	    { echo "sim_mmusdram FAILED"; exit 1; }

# SDRAM_WORDS is the whole 32 MB part here, and it has to be: the row test in
# sdramcheck.c touches one word in each of 8192 rows, and the top of the part
# is 0x91FF_FFFF. tb_ramboot.v defaults to 2 MB, and sim/sdram_model.v *errors*
# on an access past MEM_WORDS instead of aliasing - so a model left too small
# fails loudly rather than passing a row test it never performed. It costs
# memory in the simulator and nothing in time, because the sparse test does
# 16,384 accesses however big the array is.
sim/sim_sdramcheck.out: sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)
	$(IVERILOG) $(IVFLAGS) -DRAM_IMAGE='"sdramcheckimage.hex"' -DROM_IMAGE='"bootrom_$(CORE).hex"' \
	    -DSDRAM_WORDS=16777216 \
	    -o $@ sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)

sim_sdramcheck: sim/bootrom_$(CORE).hex sim/sdramcheckimage.hex sim/sim_sdramcheck.out
	@cd sim && $(VVP) sim_sdramcheck.out $(VVP_DUMP) 2>&1 | tee sdramcheck.log
	@grep -q "RAMBOOT TEST PASSED" sim/sdramcheck.log || \
	    { echo "sim_sdramcheck FAILED"; exit 1; }

# ---- the JTAG debug path ----
#
# rtl/debug/jtag_tap.v + dmi_cdc.v + dm.v, driven the way a host drives them:
# the testbench bit-bangs TCK/TMS/TDI and checks only values a real debugger
# reads. It needs no toolchain - the block RAM image is a generated pattern,
# not a compiled program - so it runs on a bare runner like `make sim`.
# Word 1024 (byte 0x8000_1000) is sim/tb_jtag.v's RESET_PC: everywhere else
# keeps the 0xDEAD_00nn pattern the SBA checks in that testbench depend on,
# but the hart-control checks need a real program to observe, not the
# illegal-instruction-trap-forever it fetches everywhere else - an
# increment loop (addi x5,x5,1 / jal x0,-4) that halt can genuinely freeze
# and a debug write to x5 can genuinely be seen advancing past. Encoded via
# the same field-packing a RISC-V assembler uses, not hand-typed hex - see
# sim/tb_cpu_halt.v's header for why hand-derived encodings in this project
# get checked against the real toolchain before being trusted, and this is
# the same pair of instructions, independently re-derived here.
sim/jtagram.hex: Makefile
	@python3 -c "\
	import sys;\
	i_type = lambda imm, rs1, f3, rd, op: ((imm & 0xFFF) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 0x7) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F);\
	j_type = lambda imm, rd, op: (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F);\
	words = [0xDEAD0000 + (n & 0xFFFF) for n in range(16384)];\
	words[1024] = i_type(1, 5, 0x0, 5, 0x13);\
	words[1025] = j_type(-4, 0, 0x6F);\
	[sys.stdout.write('%08X\n' % w) for w in words]" > $@

sim/sim_jtag.out: sim/tb_jtag.v $(SOC_RTL)
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_jtag.v $(SOC_RTL)

# Friendly names for the three images that become BOARD= bitstreams, so the
# documented flash sequence in fpga/README.md is a command rather than a path.
mmuimage:       sim/mmuimage.hex
plicimage:      sim/plicimage.hex
uart16550image: sim/uart16550image.hex

sim_jtag: sim/jtagram.hex sim/sim_jtag.out
	cd sim && $(VVP) sim_jtag.out $(VVP_DUMP) | tee jtag.log
	@grep -aq "JTAG TEST PASSED" sim/jtag.log && echo "JTAG PATH OK" || \
	    { echo "FAILED: the JTAG debug path"; exit 1; }

# ---- hart control (rtl/cpu_core.v's dbg_haltreq/dbg_resumereq/dbg_reg_*) ----
#
# Driven directly, no DMI/JTAG layer - see sim/tb_cpu_halt.v's own header for
# why that split. CORE=inorder only: rtl/ooo/core_ooo.v has no hart-control
# ports (docs/roadmap.md Phase 6), so this is a plain rtl/cpu_core.v build,
# independent of $(CORE_RTL)/$(SOC_RTL).
sim/sim_cpu_halt.out: sim/tb_cpu_halt.v rtl/regfile.v rtl/imem.v rtl/dmem.v \
                       rtl/csr_file.v rtl/muldiv_div.v rtl/mmu.v rtl/btb.v rtl/pmp.v rtl/cpu_core.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_cpu_halt.v rtl/regfile.v rtl/imem.v rtl/dmem.v \
	    rtl/csr_file.v rtl/muldiv_div.v rtl/mmu.v rtl/btb.v rtl/pmp.v rtl/cpu_core.v

sim_cpu_halt: sim/sim_cpu_halt.out
	cd sim && $(VVP) sim_cpu_halt.out $(VVP_DUMP) | tee cpu_halt.log
	@grep -aq "CPU-HALT-TEST: PASS" sim/cpu_halt.log && echo "CPU HALT/RESUME OK" || \
	    { echo "FAILED: hart control (halt/resume/register access)"; exit 1; }

# ---- Phase 13's reservation-exposure ports (rtl/cpu_core.v's resv_valid/
# resv_addr/store_fire/store_addr/resv_invalidate_ext) ----
#
# CORE=inorder only, same reasoning as sim_cpu_halt above: rtl/ooo/core_ooo.v
# has not been given these ports yet (docs/roadmap.md Phase 13, stage 7 -
# "inorder first" precedent from the hart-control/PMP stages), so this is a
# plain rtl/cpu_core.v build, independent of $(CORE_RTL)/$(SOC_RTL). See
# sim/tb_cpu_resv_ports.v's own header for what this proves and why.
sim/sim_cpu_resv_ports.out: sim/tb_cpu_resv_ports.v rtl/regfile.v rtl/imem.v rtl/dmem.v \
                       rtl/csr_file.v rtl/muldiv_div.v rtl/mmu.v rtl/btb.v rtl/pmp.v rtl/cpu_core.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_cpu_resv_ports.v rtl/regfile.v rtl/imem.v rtl/dmem.v \
	    rtl/csr_file.v rtl/muldiv_div.v rtl/mmu.v rtl/btb.v rtl/pmp.v rtl/cpu_core.v

sim_cpu_resv_ports: sim/sim_cpu_resv_ports.out
	cd sim && $(VVP) sim_cpu_resv_ports.out $(VVP_DUMP) | tee cpu_resv_ports.log
	@grep -aq "CPU-RESV-PORTS-TEST: PASS" sim/cpu_resv_ports.log && echo "CPU RESERVATION PORTS OK" || \
	    { echo "FAILED: cpu_core.v's reservation-exposure ports"; exit 1; }

# The out-of-order analog, always against rtl/ooo/core_ooo.v directly -
# independent of $(CORE_RTL)/ambient CORE=, the opposite reason
# sim_cpu_resv_ports above is always cpu_core.v: this one exists
# specifically to prove core_ooo.v's own identically-shaped ports, so it
# runs the same regardless of which core the rest of the ambient build is
# testing. See sim/tb_ooo_resv_ports.v's own header for what this proves
# and why - in particular the store-buffer-drain address case
# sim/tb_cpu_resv_ports.v has no equivalent of at all.
sim/sim_ooo_resv_ports.out: sim/tb_ooo_resv_ports.v rtl/ooo/core_ooo.v rtl/ooo/regfile_phys.v \
                       rtl/csr_file.v rtl/muldiv_div.v rtl/mmu.v rtl/btb.v rtl/pmp.v rtl/imem.v rtl/dmem.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_ooo_resv_ports.v rtl/ooo/core_ooo.v rtl/ooo/regfile_phys.v \
	    rtl/csr_file.v rtl/muldiv_div.v rtl/mmu.v rtl/btb.v rtl/pmp.v rtl/imem.v rtl/dmem.v

sim_ooo_resv_ports: sim/sim_ooo_resv_ports.out
	cd sim && $(VVP) sim_ooo_resv_ports.out $(VVP_DUMP) | tee ooo_resv_ports.log
	@grep -aq "OOO-RESV-PORTS-TEST: PASS" sim/ooo_resv_ports.log && echo "OOO RESERVATION PORTS OK" || \
	    { echo "FAILED: rtl/ooo/core_ooo.v's reservation-exposure ports"; exit 1; }

# Hart control for rtl/ooo/core_ooo.v (Phase 13, stage 18) - the same
# out-of-order analog rtl/ooo/regfile_phys.v's own reservation-ports target
# above is, always against core_ooo.v directly regardless of ambient CORE=.
# See sim/tb_ooo_halt.v's own header for what this proves and why - in
# particular the store-buffer-drain quiescence case (check 0) neither
# sim/tb_cpu_halt.v nor its own harder-earned test design has an equivalent
# of at all.
sim/sim_ooo_halt.out: sim/tb_ooo_halt.v rtl/ooo/core_ooo.v rtl/ooo/regfile_phys.v \
                       rtl/csr_file.v rtl/muldiv_div.v rtl/mmu.v rtl/btb.v rtl/pmp.v rtl/imem.v rtl/dmem.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_ooo_halt.v rtl/ooo/core_ooo.v rtl/ooo/regfile_phys.v \
	    rtl/csr_file.v rtl/muldiv_div.v rtl/mmu.v rtl/btb.v rtl/pmp.v rtl/imem.v rtl/dmem.v

sim_ooo_halt: sim/sim_ooo_halt.out
	cd sim && $(VVP) sim_ooo_halt.out $(VVP_DUMP) | tee ooo_halt.log
	@grep -aq "OOO-HALT-TEST: PASS" sim/ooo_halt.log && echo "OOO HALT/RESUME OK" || \
	    { echo "FAILED: rtl/ooo/core_ooo.v's hart control (halt/resume/register access)"; exit 1; }

# ---- Phase 13 stage 8: rtl/soc/soc_top.v's NUM_HARTS=2, a real second
# hart's hardware ----
#
# RESET_PC points straight into RAM: software/soc/bootrom.c does not know a
# second hart exists yet, so this cannot boot through the real boot ROM the
# way `make sim_soc` does. Encoded via the same field-packing helpers
# sim/jtagram.hex's own generator uses, not hand-typed hex - see
# sim/tb_soc_2hart.v's own header for the program and what it proves.
sim/soc2hart.hex: Makefile
	@python3 -c "\
	import sys;\
	i_type = lambda imm, rs1, f3, rd, op: ((imm & 0xFFF) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 0x7) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F);\
	j_type = lambda imm, rd, op: (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F);\
	b_type = lambda imm, rs1, rs2, f3, op: (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 0x7) << 12) | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | (op & 0x7F);\
	u_type = lambda imm20, rd, op: ((imm20 & 0xFFFFF) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F);\
	s_type = lambda imm, rs1, rs2, f3, op: (((imm >> 5) & 0x7F) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 0x7) << 12) | ((imm & 0x1F) << 7) | (op & 0x7F);\
	words = [\
	    i_type(0xF14, 0, 0x2, 1, 0x73),\
	    u_type(0x80000, 2, 0x37),\
	    b_type(20, 1, 0, 0x1, 0x63),\
	    i_type(0x100, 2, 0x0, 2, 0x13),\
	    u_type(0xAAAA0, 3, 0x37),\
	    s_type(0, 2, 3, 0x2, 0x23),\
	    j_type(0, 0, 0x6F),\
	    i_type(0x104, 2, 0x0, 2, 0x13),\
	    u_type(0xBBBB0, 3, 0x37),\
	    s_type(0, 2, 3, 0x2, 0x23),\
	    j_type(0, 0, 0x6F),\
	];\
	[sys.stdout.write('%08X\n' % (w & 0xFFFFFFFF)) for w in words]" > $@

sim/sim_soc_2hart.out: sim/tb_soc_2hart.v $(SOC_RTL)
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_soc_2hart.v $(SOC_RTL)

sim_soc_2hart: sim/soc2hart.hex sim/sim_soc_2hart.out
	cd sim && $(VVP) sim_soc_2hart.out $(VVP_DUMP) | tee soc_2hart.log
	@grep -aq "SOC-2HART-TEST: PASS" sim/soc_2hart.log && echo "SOC 2-HART HARDWARE OK" || \
	    { echo "FAILED: rtl/soc/soc_top.v's NUM_HARTS=2"; exit 1; }

# ---- Phase 15 stage 1: hart 0 = cpu_core.v, hart 1 = core_ooo.v, at once -
# a real heterogeneous elaboration, not just two of the same core ----
#
# Reuses sim/tb_soc_2hart.v and sim/soc2hart.hex completely unchanged: that
# testbench only ever reads mhartid, branches on it, and writes a hart-
# specific sentinel - nothing about it assumes both harts share a module,
# so the exact same program and the exact same checks already prove what
# this stage needs once soc_top.v's own CORE_HETERO branch (see that
# file's generate-loop comment) picks a different module per hart. This
# target hardcodes its own file list and `-DCORE_HETERO` rather than
# going through $(SOC_RTL)/$(CORE_DEFINES), so it builds correctly - and
# unconditionally - regardless of whether the surrounding `make verify`/
# `make verify_ooo` invocation has $(CORE) set to `inorder` or `ooo`.
sim/sim_soc_2hart_hetero.out: sim/tb_soc_2hart.v $(SOC_RTL_BASE) rtl/ooo/core_ooo.v rtl/ooo/regfile_phys.v
	$(IVERILOG) -g2012 -DCORE_HETERO -o $@ sim/tb_soc_2hart.v $(SOC_RTL_BASE) rtl/ooo/core_ooo.v rtl/ooo/regfile_phys.v

sim_soc_2hart_hetero: sim/soc2hart.hex sim/sim_soc_2hart_hetero.out
	cd sim && $(VVP) sim_soc_2hart_hetero.out $(VVP_DUMP) | tee soc_2hart_hetero.log
	@grep -aq "SOC-2HART-TEST: PASS" sim/soc_2hart_hetero.log && echo "SOC HETEROGENEOUS 2-HART HARDWARE OK" || \
	    { echo "FAILED: rtl/soc/soc_top.v's CORE=hetero (hart 0 cpu_core.v, hart 1 core_ooo.v)"; exit 1; }

# ---- Phase 15 stage 2: cross-hart LR/SC coherence between the two
# different hart types, both directions ----
#
# Direction 1 reuses sim/tb_soc_2hart_lrsc.v and sim/soc2hart_lrsc.hex
# completely unchanged (only the testbench's own CORE_HETERO-guarded
# identity check is new, added directly to that file): hart 0 (always
# cpu_core.v under CORE=hetero) holds the reservation, hart 1 (always
# core_ooo.v) makes the foreign write. Hardcoded file list and
# -DCORE_HETERO for the same reason sim_soc_2hart_hetero above is - this
# has to build correctly regardless of the ambient $(CORE).
sim/sim_soc_2hart_lrsc_hetero.out: sim/tb_soc_2hart_lrsc.v $(SOC_RTL_BASE) rtl/ooo/core_ooo.v rtl/ooo/regfile_phys.v
	$(IVERILOG) -g2012 -DCORE_HETERO -o $@ sim/tb_soc_2hart_lrsc.v $(SOC_RTL_BASE) rtl/ooo/core_ooo.v rtl/ooo/regfile_phys.v

sim_soc_2hart_lrsc_hetero: sim/soc2hart_lrsc.hex sim/sim_soc_2hart_lrsc_hetero.out
	cd sim && $(VVP) sim_soc_2hart_lrsc_hetero.out $(VVP_DUMP) | tee soc_2hart_lrsc_hetero.log
	@grep -aq "SOC-2HART-LRSC-TEST: PASS" sim/soc_2hart_lrsc_hetero.log && echo "CROSS-HART LR/SC OK (in-order holds, ooo writes)" || \
	    { echo "FAILED: rtl/soc/reservation_monitor.v under CORE=hetero (in-order LR/SC vs ooo write)"; exit 1; }

# Direction 2 is the mirror image - hart 1 (core_ooo.v) holds the
# reservation, hart 0 (cpu_core.v) makes the foreign write - genuinely
# new coverage, not a symmetric re-run: see sim/tb_soc_2hart_lrsc_swap.v's
# own header for why this direction was never exercised before and what
# specifically differs from direction 1. soc2hart_lrsc_swap.hex is
# sim/soc2hart_lrsc.hex's own generator with exactly one word changed -
# the branch that assigns roles by mhartid is BEQ here, BNE there -
# everything else, including every address and expected value, is
# identical, because the addresses involved don't care which hart reaches
# them, only which role each hart plays.
sim/soc2hart_lrsc_swap.hex: Makefile
	@python3 -c "\
	import sys;\
	i_type = lambda imm, rs1, f3, rd, op: ((imm & 0xFFF) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 0x7) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F);\
	j_type = lambda imm, rd, op: (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F);\
	b_type = lambda imm, rs1, rs2, f3, op: (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 0x7) << 12) | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | (op & 0x7F);\
	u_type = lambda imm20, rd, op: ((imm20 & 0xFFFFF) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F);\
	s_type = lambda imm, rs1, rs2, f3, op: (((imm >> 5) & 0x7F) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 0x7) << 12) | ((imm & 0x1F) << 7) | (op & 0x7F);\
	r_type = lambda f5, aq, rl, rs2, rs1, f3, rd, op: ((f5 & 0x1F) << 27) | ((aq & 1) << 26) | ((rl & 1) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 0x7) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F);\
	words = [\
	    i_type(0xF14, 0, 0x2, 10, 0x73),\
	    u_type(0x80000, 1, 0x37),\
	    b_type(44, 10, 0, 0x0, 0x63),\
	    i_type(0x200, 1, 0x0, 2, 0x13),\
	    i_type(0x304, 1, 0x0, 4, 0x13),\
	    i_type(0x308, 1, 0x0, 5, 0x13),\
	    r_type(0x02, 0, 0, 0, 2, 0x2, 6, 0x2F),\
	    i_type(0, 4, 0x2, 8, 0x03),\
	    b_type(-4, 8, 0, 0x0, 0x63),\
	    i_type(0xAB, 0, 0x0, 9, 0x13),\
	    r_type(0x03, 0, 0, 9, 2, 0x2, 11, 0x2F),\
	    s_type(0, 5, 11, 0x2, 0x23),\
	    j_type(0, 0, 0x6F),\
	    i_type(0x200, 1, 0x0, 2, 0x13),\
	    i_type(0x304, 1, 0x0, 4, 0x13),\
	    i_type(200, 0, 0x0, 12, 0x13),\
	    i_type(-1, 12, 0x0, 12, 0x13),\
	    b_type(-4, 12, 0, 0x1, 0x63),\
	    i_type(0xCD, 0, 0x0, 9, 0x13),\
	    s_type(0, 2, 9, 0x2, 0x23),\
	    i_type(1, 0, 0x0, 7, 0x13),\
	    s_type(0, 4, 7, 0x2, 0x23),\
	    j_type(0, 0, 0x6F),\
	];\
	[sys.stdout.write('%08X\n' % (w & 0xFFFFFFFF)) for w in words]" > $@

sim/sim_soc_2hart_lrsc_swap_hetero.out: sim/tb_soc_2hart_lrsc_swap.v $(SOC_RTL_BASE) rtl/ooo/core_ooo.v rtl/ooo/regfile_phys.v
	$(IVERILOG) -g2012 -DCORE_HETERO -o $@ sim/tb_soc_2hart_lrsc_swap.v $(SOC_RTL_BASE) rtl/ooo/core_ooo.v rtl/ooo/regfile_phys.v

sim_soc_2hart_lrsc_swap_hetero: sim/soc2hart_lrsc_swap.hex sim/sim_soc_2hart_lrsc_swap_hetero.out
	cd sim && $(VVP) sim_soc_2hart_lrsc_swap_hetero.out $(VVP_DUMP) | tee soc_2hart_lrsc_swap_hetero.log
	@grep -aq "SOC-2HART-LRSC-SWAP-TEST: PASS" sim/soc_2hart_lrsc_swap_hetero.log && echo "CROSS-HART LR/SC OK (ooo holds, in-order writes)" || \
	    { echo "FAILED: rtl/soc/reservation_monitor.v under CORE=hetero (ooo LR/SC vs in-order write)"; exit 1; }

# ---- Phase 15 stage 2, closing the gap that stage's own account named:
# ordinary (non-atomic) cross-hart loads/stores, stressed with the same
# directed-hazard rigor as the LR/SC tests above, not just exercised
# incidentally as a byproduct of them ----
#
# Both directions in one program, unlike the LR/SC pair above: ordinary
# loads/stores have no core-type-specific internal mechanism the way LR/SC's
# own reservation-invalidation logic does (that asymmetry is why the LR/SC
# swap test needed a second file), so one hart writing then the other
# reading, in both directions, within a single directed program, is real,
# sufficient coverage rather than an arbitrarily narrower scope.
#
#   hart 0                          hart 1
#   ------                          ------
#   (tight delay loop)              WORD_A_WAIT: poll FLAG_A
#   WORD_A = 0x11
#   FLAG_A = 1
#   WORD_B_WAIT: poll FLAG_B        (sees FLAG_A) read WORD_A -> R1
#   (sees FLAG_B) read WORD_B -> R2 (tight delay loop)
#   halt                            WORD_B = 0x22
#                                   FLAG_B = 1
#                                   halt
#
# The delay loops are short (20 iterations) - a real, tuned, tight window
# rather than a generous one, so the flag-setting write and the other
# hart's own concurrent pipeline state are genuinely close in real time,
# matching the LR/SC test's own already-proven "tuned, not generous delay"
# technique for provoking a real hazard rather than an eventually-consistent
# non-event. Hand-encoded the same field-packing way sim/soc2hart_lrsc.hex
# is - independently verified against a real disassembler
# (riscv64-unknown-elf-objdump -m riscv:rv32) before being trusted, not
# just hand-traced.
sim/soc2hart_ordinary.hex: Makefile
	@python3 -c "\
	import sys;\
	i_type = lambda imm, rs1, f3, rd, op: ((imm & 0xFFF) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 0x7) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F);\
	j_type = lambda imm, rd, op: (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F);\
	b_type = lambda imm, rs1, rs2, f3, op: (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 0x7) << 12) | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | (op & 0x7F);\
	u_type = lambda imm20, rd, op: ((imm20 & 0xFFFFF) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F);\
	s_type = lambda imm, rs1, rs2, f3, op: (((imm >> 5) & 0x7F) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 0x7) << 12) | ((imm & 0x1F) << 7) | (op & 0x7F);\
	words = [\
	    i_type(0xF14, 0, 0x2, 10, 0x73),\
	    u_type(0x80000, 1, 0x37),\
	    b_type(72, 10, 0, 0x1, 0x63),\
	    i_type(0x100, 1, 0x0, 2, 0x13),\
	    i_type(0x104, 1, 0x0, 3, 0x13),\
	    i_type(0x108, 1, 0x0, 4, 0x13),\
	    i_type(0x10C, 1, 0x0, 5, 0x13),\
	    i_type(0x114, 1, 0x0, 6, 0x13),\
	    i_type(20, 0, 0x0, 12, 0x13),\
	    i_type(-1, 12, 0x0, 12, 0x13),\
	    b_type(-4, 12, 0, 0x1, 0x63),\
	    i_type(0x11, 0, 0x0, 7, 0x13),\
	    s_type(0, 2, 7, 0x2, 0x23),\
	    i_type(1, 0, 0x0, 8, 0x13),\
	    s_type(0, 3, 8, 0x2, 0x23),\
	    i_type(0, 5, 0x2, 9, 0x03),\
	    b_type(-4, 9, 0, 0x0, 0x63),\
	    i_type(0, 4, 0x2, 10, 0x03),\
	    s_type(0, 6, 10, 0x2, 0x23),\
	    j_type(0, 0, 0x6F),\
	    i_type(0x100, 1, 0x0, 2, 0x13),\
	    i_type(0x104, 1, 0x0, 3, 0x13),\
	    i_type(0x108, 1, 0x0, 4, 0x13),\
	    i_type(0x10C, 1, 0x0, 5, 0x13),\
	    i_type(0x110, 1, 0x0, 6, 0x13),\
	    i_type(0, 3, 0x2, 9, 0x03),\
	    b_type(-4, 9, 0, 0x0, 0x63),\
	    i_type(0, 2, 0x2, 10, 0x03),\
	    s_type(0, 6, 10, 0x2, 0x23),\
	    i_type(20, 0, 0x0, 12, 0x13),\
	    i_type(-1, 12, 0x0, 12, 0x13),\
	    b_type(-4, 12, 0, 0x1, 0x63),\
	    i_type(0x22, 0, 0x0, 7, 0x13),\
	    s_type(0, 4, 7, 0x2, 0x23),\
	    i_type(1, 0, 0x0, 8, 0x13),\
	    s_type(0, 5, 8, 0x2, 0x23),\
	    j_type(0, 0, 0x6F),\
	];\
	[sys.stdout.write('%08X\n' % (w & 0xFFFFFFFF)) for w in words]" > $@

# CORE-aware the same way sim_soc_2hart_lrsc is - real, general coverage,
# not a hetero-only patch, since this specific directed hazard has never
# existed for any pairing before now, homogeneous or not.
sim/sim_soc_2hart_ordinary.out: sim/tb_soc_2hart_ordinary.v $(SOC_RTL)
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_soc_2hart_ordinary.v $(SOC_RTL)

sim_soc_2hart_ordinary: sim/soc2hart_ordinary.hex sim/sim_soc_2hart_ordinary.out
	cd sim && $(VVP) sim_soc_2hart_ordinary.out $(VVP_DUMP) | tee soc_2hart_ordinary.log
	@grep -aq "SOC-2HART-ORDINARY-TEST: PASS" sim/soc_2hart_ordinary.log && echo "CROSS-HART ORDINARY LOAD/STORE OK" || \
	    { echo "FAILED: rtl/soc/wb_interconnect.v ordinary cross-hart load/store visibility"; exit 1; }

sim/sim_soc_2hart_ordinary_hetero.out: sim/tb_soc_2hart_ordinary.v $(SOC_RTL_BASE) rtl/ooo/core_ooo.v rtl/ooo/regfile_phys.v
	$(IVERILOG) -g2012 -DCORE_HETERO -o $@ sim/tb_soc_2hart_ordinary.v $(SOC_RTL_BASE) rtl/ooo/core_ooo.v rtl/ooo/regfile_phys.v

sim_soc_2hart_ordinary_hetero: sim/soc2hart_ordinary.hex sim/sim_soc_2hart_ordinary_hetero.out
	cd sim && $(VVP) sim_soc_2hart_ordinary_hetero.out $(VVP_DUMP) | tee soc_2hart_ordinary_hetero.log
	@grep -aq "SOC-2HART-ORDINARY-TEST: PASS" sim/soc_2hart_ordinary_hetero.log && echo "CROSS-HART ORDINARY LOAD/STORE OK (hetero)" || \
	    { echo "FAILED: rtl/soc/wb_interconnect.v ordinary cross-hart load/store visibility under CORE=hetero"; exit 1; }

# ---- Phase 15 stage 3: the real boot-ROM mailbox, not the RESET_PC-into-
# RAM shortcut every other Phase 15 test above uses ----
#
# Reuses sim/tb_ramboot_2hart.v and sim/ramimage2hart.hex completely
# unchanged (only the testbench's own CORE_HETERO-guarded identity check is
# new, added directly to that file, mirroring every other Phase 15 stage):
# software/soc/crt0_rom.S's park_hart and software/soc/bootrom.c's
# hart_release_addr are plain C/asm with no per-hart-type behavior, so the
# same payload already proves the real mailbox handoff the moment it is
# built against CORE=hetero - hart 0 (cpu_core.v) runs the actual boot ROM
# and releases hart 1 (core_ooo.v) to the preloaded payload, rather than
# either hart resetting straight into RAM. Hardcoded file list and
# -DCORE_HETERO for the same reason every other _hetero target above is -
# this has to build correctly regardless of the ambient $(CORE).
#
# The boot ROM it loads must be the hetero-flavored one specifically
# (sim/bootrom_hetero.hex, with cpu1's own device-tree `compatible` string
# actually saying core_ooo.v), never whatever sim/bootrom_$(CORE).hex the
# ambient $(CORE) happens to mean here - the same reason -DCORE_HETERO above
# is hardcoded rather than $(CORE_DEFINES). Unlike every other file in this
# target's own dependency chain, sim/bootrom_hetero.hex is a *static* pattern
# parameterized by whatever $(CORE) equals for this whole `make` invocation,
# not a real per-target parameter - so a plain prerequisite would silently
# resolve to sim/bootrom_$(CORE).hex's own build rule, never actually
# producing a file named "bootrom_hetero.hex" unless the ambient $(CORE)
# already happened to equal hetero. A recursive sub-make with CORE=hetero
# bound just for this one file, the same "$(MAKE) ... CORE=..." pattern
# `verify_ooo` above already uses for its own reason, sidesteps that: Make's
# own normal dependency-freshness logic still applies inside the sub-make, so
# this only rebuilds what is actually stale.
sim/sim_ramboot_2hart_hetero.out: sim/tb_ramboot_2hart.v sim/sdram_model.v $(SOC_RTL_BASE) rtl/ooo/core_ooo.v rtl/ooo/regfile_phys.v
	$(IVERILOG) -g2012 -DCORE_HETERO -DRAM_IMAGE='"ramimage2hart.hex"' -DROM_IMAGE='"bootrom_hetero.hex"' \
	    -o $@ sim/tb_ramboot_2hart.v sim/sdram_model.v $(SOC_RTL_BASE) rtl/ooo/core_ooo.v rtl/ooo/regfile_phys.v

sim_ramboot_2hart_hetero: sim/ramimage2hart.hex sim/sim_ramboot_2hart_hetero.out
	$(MAKE) sim/bootrom_hetero.hex CORE=hetero
	@cd sim && $(VVP) sim_ramboot_2hart_hetero.out $(VVP_DUMP) 2>&1 | tee ramboot_2hart_hetero.log
	@grep -q "RAMBOOT-2HART TEST PASSED" sim/ramboot_2hart_hetero.log || \
	    { echo "FAILED: the real boot-ROM mailbox under CORE=hetero (hart 0 cpu_core.v releases hart 1 core_ooo.v)"; exit 1; }

# ---- Phase 13 stage 9: rtl/soc/reservation_monitor.v wired to both harts
# - cross-hart LR/SC coherence, not just hardware that runs ----
#
# Same RESET_PC-into-RAM approach as sim/soc2hart.hex, for the same reason
# (bootrom.c doesn't know a second hart exists). See sim/tb_soc_2hart_lrsc.v's
# own header for the two-hart handshake this program runs and what it proves.
sim/soc2hart_lrsc.hex: Makefile
	@python3 -c "\
	import sys;\
	i_type = lambda imm, rs1, f3, rd, op: ((imm & 0xFFF) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 0x7) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F);\
	j_type = lambda imm, rd, op: (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F);\
	b_type = lambda imm, rs1, rs2, f3, op: (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 0x7) << 12) | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | (op & 0x7F);\
	u_type = lambda imm20, rd, op: ((imm20 & 0xFFFFF) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F);\
	s_type = lambda imm, rs1, rs2, f3, op: (((imm >> 5) & 0x7F) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 0x7) << 12) | ((imm & 0x1F) << 7) | (op & 0x7F);\
	r_type = lambda f5, aq, rl, rs2, rs1, f3, rd, op: ((f5 & 0x1F) << 27) | ((aq & 1) << 26) | ((rl & 1) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 0x7) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F);\
	words = [\
	    i_type(0xF14, 0, 0x2, 10, 0x73),\
	    u_type(0x80000, 1, 0x37),\
	    b_type(44, 10, 0, 0x1, 0x63),\
	    i_type(0x200, 1, 0x0, 2, 0x13),\
	    i_type(0x304, 1, 0x0, 4, 0x13),\
	    i_type(0x308, 1, 0x0, 5, 0x13),\
	    r_type(0x02, 0, 0, 0, 2, 0x2, 6, 0x2F),\
	    i_type(0, 4, 0x2, 8, 0x03),\
	    b_type(-4, 8, 0, 0x0, 0x63),\
	    i_type(0xAB, 0, 0x0, 9, 0x13),\
	    r_type(0x03, 0, 0, 9, 2, 0x2, 11, 0x2F),\
	    s_type(0, 5, 11, 0x2, 0x23),\
	    j_type(0, 0, 0x6F),\
	    i_type(0x200, 1, 0x0, 2, 0x13),\
	    i_type(0x304, 1, 0x0, 4, 0x13),\
	    i_type(200, 0, 0x0, 12, 0x13),\
	    i_type(-1, 12, 0x0, 12, 0x13),\
	    b_type(-4, 12, 0, 0x1, 0x63),\
	    i_type(0xCD, 0, 0x0, 9, 0x13),\
	    s_type(0, 2, 9, 0x2, 0x23),\
	    i_type(1, 0, 0x0, 7, 0x13),\
	    s_type(0, 4, 7, 0x2, 0x23),\
	    j_type(0, 0, 0x6F),\
	];\
	[sys.stdout.write('%08X\n' % (w & 0xFFFFFFFF)) for w in words]" > $@

# CORE-aware since Phase 13 stage 16: rtl/ooo/core_ooo.v gained the same
# reservation ports rtl/cpu_core.v has (stage 15) and rtl/soc/soc_top.v now
# wires either core's own ports into the monitor unconditionally, so this
# target follows the ambient $(CORE) like every other sim target - under
# the default CORE=inorder this is $(SOC_RTL)==$(SOC_RTL_BASE) and
# $(IVFLAGS)=="-g2012" bit-for-bit (both $(CORE_RTL)/$(CORE_DEFINES) are
# empty there), so this is a strict no-op for the in-order build; under
# `make verify_ooo`'s own ambient CORE=ooo, this now genuinely tests
# core_ooo.v's own cross-hart coherence instead of silently re-testing
# the in-order core redundantly, as it did before stage 16.
sim/sim_soc_2hart_lrsc.out: sim/tb_soc_2hart_lrsc.v $(SOC_RTL)
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_soc_2hart_lrsc.v $(SOC_RTL)

sim_soc_2hart_lrsc: sim/soc2hart_lrsc.hex sim/sim_soc_2hart_lrsc.out
	cd sim && $(VVP) sim_soc_2hart_lrsc.out $(VVP_DUMP) | tee soc_2hart_lrsc.log
	@grep -aq "SOC-2HART-LRSC-TEST: PASS" sim/soc_2hart_lrsc.log && echo "CROSS-HART LR/SC OK" || \
	    { echo "FAILED: rtl/soc/reservation_monitor.v wired to soc_top.v"; exit 1; }

# ---- rtl/soc/wb_interconnect.v's own plain-AMO cross-hart atomicity fix ----
#
# LR/SC gets cross-hart coherence from rtl/soc/reservation_monitor.v; plain
# AMOs (amoswap.w, amoadd.w, ...) never go through it at all - their own
# atomicity depends entirely on rtl/soc/wb_interconnect.v holding the data
# bus exclusively across an AMO's read and write phases, a claim that
# stood, formally proved, for a whole phase before anything actually put two
# harts in real contention on one to check it. sim/tb_soc_2hart_amoswap.v's
# own header has the full account of what that check found and what closes
# it. Both harts run the identical program (sim/soc2hart_amoswap.hex, same
# field-packing generator style as sim/soc2hart_lrsc.hex).
sim/soc2hart_amoswap.hex: Makefile
	@python3 -c "\
	import sys;\
	i_type = lambda imm, rs1, f3, rd, op: ((imm & 0xFFF) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 0x7) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F);\
	j_type = lambda imm, rd, op: (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F);\
	b_type = lambda imm, rs1, rs2, f3, op: (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 0x7) << 12) | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | (op & 0x7F);\
	u_type = lambda imm20, rd, op: ((imm20 & 0xFFFFF) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F);\
	s_type = lambda imm, rs1, rs2, f3, op: (((imm >> 5) & 0x7F) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 0x7) << 12) | ((imm & 0x1F) << 7) | (op & 0x7F);\
	r_type = lambda f5, aq, rl, rs2, rs1, f3, rd, op: ((f5 & 0x1F) << 27) | ((aq & 1) << 26) | ((rl & 1) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 0x7) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F);\
	words = [\
	    i_type(0xF14, 0, 0x2, 1, 0x73),\
	    u_type(0x80000, 2, 0x37),\
	    i_type(0x200, 2, 0x0, 2, 0x13),\
	    i_type(100, 0, 0x0, 7, 0x13),\
	    i_type(0, 0, 0x0, 5, 0x13),\
	    b_type(40, 5, 7, 0x0, 0x63),\
	    i_type(1, 0, 0x0, 8, 0x13),\
	    r_type(0x01, 0, 0, 8, 2, 0x2, 6, 0x2F),\
	    b_type(-8, 6, 0, 0x1, 0x63),\
	    i_type(4, 2, 0x2, 9, 0x03),\
	    i_type(1, 9, 0x0, 9, 0x13),\
	    s_type(4, 2, 9, 0x2, 0x23),\
	    s_type(0, 2, 0, 0x2, 0x23),\
	    i_type(1, 5, 0x0, 5, 0x13),\
	    j_type(-36, 0, 0x6F),\
	    i_type(1, 0, 0x0, 11, 0x13),\
	    b_type(12, 1, 0, 0x1, 0x63),\
	    s_type(8, 2, 11, 0x2, 0x23),\
	    j_type(8, 0, 0x6F),\
	    s_type(12, 2, 11, 0x2, 0x23),\
	    j_type(0, 0, 0x6F),\
	];\
	[sys.stdout.write('%08X\n' % (w & 0xFFFFFFFF)) for w in words]" > $@

# CORE-aware the same way sim_soc_2hart_lrsc is (Phase 13 stage 16's own
# unification of both cores' reservation ports doesn't matter here at all -
# plain AMOs never touch reservation_monitor.v - but both cores' AMO
# read-modify-write shape is identical enough that this needs no
# core-specific handling either): a strict no-op under the default
# CORE=inorder, and under `make verify_ooo`'s own ambient CORE=ooo this
# tests core_ooo.v's own AMO retirement against real cross-hart contention
# for the first time.
sim/sim_soc_2hart_amoswap.out: sim/tb_soc_2hart_amoswap.v $(SOC_RTL)
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_soc_2hart_amoswap.v $(SOC_RTL)

sim_soc_2hart_amoswap: sim/soc2hart_amoswap.hex sim/sim_soc_2hart_amoswap.out
	cd sim && $(VVP) sim_soc_2hart_amoswap.out $(VVP_DUMP) | tee soc_2hart_amoswap.log
	@grep -aq "SOC-2HART-AMOSWAP-TEST: PASS" sim/soc_2hart_amoswap.log && echo "CROSS-HART AMO ATOMICITY OK" || \
	    { echo "FAILED: rtl/soc/wb_interconnect.v's own cross-hart AMO atomicity"; exit 1; }

# The mixed pair specifically - hardcoded file list and -DCORE_HETERO, the
# same pattern every other Phase 15 _hetero target uses, since this is
# gated in verify's own dependency list unconditionally and has to build
# correctly regardless of the ambient $(CORE).
sim/sim_soc_2hart_amoswap_hetero.out: sim/tb_soc_2hart_amoswap.v $(SOC_RTL_BASE) rtl/ooo/core_ooo.v rtl/ooo/regfile_phys.v
	$(IVERILOG) -g2012 -DCORE_HETERO -o $@ sim/tb_soc_2hart_amoswap.v $(SOC_RTL_BASE) rtl/ooo/core_ooo.v rtl/ooo/regfile_phys.v

sim_soc_2hart_amoswap_hetero: sim/soc2hart_amoswap.hex sim/sim_soc_2hart_amoswap_hetero.out
	cd sim && $(VVP) sim_soc_2hart_amoswap_hetero.out $(VVP_DUMP) | tee soc_2hart_amoswap_hetero.log
	@grep -aq "SOC-2HART-AMOSWAP-TEST: PASS" sim/soc_2hart_amoswap_hetero.log && echo "CROSS-HART AMO ATOMICITY OK (hetero)" || \
	    { echo "FAILED: rtl/soc/wb_interconnect.v's own cross-hart AMO atomicity under CORE=hetero"; exit 1; }

# ---- OOO CSR-write-timing hazard ----
#
# CORE_OOO hardcoded, not $(CORE_DEFINES)/$(CORE_RTL): this is specifically
# about rtl/ooo/core_ooo.v's own retirement timing (docs/roadmap.md's
# "CORE=ooo has no Fmax" entry), not a general dual-core regression, so it
# always builds the wide core regardless of what CORE= is set to. Driven
# through rtl/top.v (the same zero-latency flat harness `make sim CORE=ooo`
# already uses), not sim/tb_isa.v/tests/, because the check is on an
# internal timing signal (csr_file's `we` port), not an architectural
# result - see sim/tb_ooo_csr_hazard.v's own header for why it reaches into
# the design, unlike most testbenches here.
sim/sim_ooo_csr_hazard.out: sim/tb_ooo_csr_hazard.v rtl/regfile.v rtl/imem.v rtl/dmem.v \
                       rtl/csr_file.v rtl/muldiv_div.v rtl/clint.v rtl/plic.v rtl/uart.v \
                       rtl/btb.v rtl/mmu.v rtl/pmp.v rtl/cpu_core.v rtl/top.v \
                       rtl/ooo/core_ooo.v rtl/ooo/regfile_phys.v
	$(IVERILOG) $(IVFLAGS) -DCORE_OOO -o $@ sim/tb_ooo_csr_hazard.v rtl/regfile.v rtl/imem.v \
	    rtl/dmem.v rtl/csr_file.v rtl/muldiv_div.v rtl/clint.v rtl/plic.v rtl/uart.v \
	    rtl/btb.v rtl/mmu.v rtl/pmp.v rtl/cpu_core.v rtl/top.v rtl/ooo/core_ooo.v rtl/ooo/regfile_phys.v

sim_ooo_csr_hazard: sim/sim_ooo_csr_hazard.out
	cd sim && $(VVP) sim_ooo_csr_hazard.out $(VVP_DUMP) | tee ooo_csr_hazard.log
	@grep -aq "OOO-CSR-HAZARD-TEST: PASS" sim/ooo_csr_hazard.log && echo "OOO CSR HAZARD OK" || \
	    { echo "FAILED: OOO CSR-write-timing hazard"; exit 1; }

# ---- PMP (Physical Memory Protection): CSR storage + matching, stage 1 ----
#
# Storage/WARL/lock semantics (csr_file.v) and the address-matching module
# (rtl/pmp.v) only - see rtl/pmp.v's header and docs/roadmap.md for why
# nothing wires enforcement into a real access path yet. Board-independent,
# like sim_tmds_encode: rtl/pmp.v takes no core, no bus, nothing but its own
# inputs, so it is checked here before any pipeline integration exists to
# risk breaking.
sim/sim_pmp.out: sim/tb_pmp.v rtl/pmp.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_pmp.v rtl/pmp.v

sim_pmp: sim/sim_pmp.out
	cd sim && $(VVP) sim_pmp.out $(VVP_DUMP) | tee pmp.log
	@grep -aq "PMP-TEST: PASS" sim/pmp.log && echo "PMP OK" || \
	    { echo "FAILED: PMP address matching"; exit 1; }

sim/sim_pmp_csr.out: sim/tb_pmp_csr.v rtl/csr_file.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_pmp_csr.v rtl/csr_file.v

sim_pmp_csr: sim/sim_pmp_csr.out
	cd sim && $(VVP) sim_pmp_csr.out $(VVP_DUMP) | tee pmp_csr.log
	@grep -aq "PMP-CSR-TEST: PASS" sim/pmp_csr.log && echo "PMP CSR OK" || \
	    { echo "FAILED: PMP CSR WARL/lock semantics"; exit 1; }

# ---- Phase 13 stage 2: hart-ID plumbing (mhartid, CLINT per-hart arrays) ----
#
# Both board-independent, like sim_pmp/sim_pmp_csr above: proves the new
# HARTID/NUM_HARTS parameters actually reach independent storage per hart,
# in isolation, before any second hart exists to wire them to for real - see
# docs/roadmap.md's Phase 13 entry.
sim/sim_mhartid.out: sim/tb_mhartid.v rtl/csr_file.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_mhartid.v rtl/csr_file.v

sim_mhartid: sim/sim_mhartid.out
	cd sim && $(VVP) sim_mhartid.out $(VVP_DUMP) | tee mhartid.log
	@grep -aq "MHARTID-TEST: PASS" sim/mhartid.log && echo "MHARTID OK" || \
	    { echo "FAILED: csr_file.v HARTID parameter"; exit 1; }

sim/sim_clint_multihart.out: sim/tb_clint_multihart.v rtl/clint.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_clint_multihart.v rtl/clint.v

sim_clint_multihart: sim/sim_clint_multihart.out
	cd sim && $(VVP) sim_clint_multihart.out $(VVP_DUMP) | tee clint_multihart.log
	@grep -aq "CLINT-MULTIHART-TEST: PASS" sim/clint_multihart.log && echo "CLINT MULTIHART OK" || \
	    { echo "FAILED: clint.v NUM_HARTS parameter"; exit 1; }

# ---- Phase 13 stage 3: interconnect NUM_HARTS generalization ----
#
# Board-independent, like sim_pmp/sim_clint_multihart above: proves two of
# the arbitration behaviors formal/fv_interconnect.v proves in the abstract
# (cross-hart tier priority, per-hart AMO continuation) actually play out
# over a real cycle-by-cycle trace against a real, multi-wait-state slave,
# before any second hart exists to wire the new ports to for real - see
# docs/roadmap.md's Phase 13 entry.
sim/sim_interconnect_multihart.out: sim/tb_interconnect_multihart.v rtl/soc/wb_interconnect.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_interconnect_multihart.v rtl/soc/wb_interconnect.v

sim_interconnect_multihart: sim/sim_interconnect_multihart.out
	cd sim && $(VVP) sim_interconnect_multihart.out $(VVP_DUMP) | tee interconnect_multihart.log
	@grep -aq "INTERCONNECT-MULTIHART-TEST: PASS" sim/interconnect_multihart.log && echo "INTERCONNECT MULTIHART OK" || \
	    { echo "FAILED: wb_interconnect.v NUM_HARTS parameter"; exit 1; }

# ---- Phase 13: cpu_wb.v D-cache bypass (DCACHE_ENABLE) ----
#
# Board-independent, like sim_interconnect_multihart above: proves the
# actual coherence scenario DCACHE_ENABLE=0 exists to close - a foreign
# write to the backing memory, standing in for a second hart's own store
# reaching the same physical address through a different bus master
# entirely - is served stale with caching on and correctly fresh with it
# off, before any second hart exists to need the escape hatch for real -
# see docs/roadmap.md's Phase 13 entry.
sim/sim_cpu_wb_dcache_bypass.out: sim/tb_cpu_wb_dcache_bypass.v rtl/soc/cpu_wb.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_cpu_wb_dcache_bypass.v rtl/soc/cpu_wb.v

sim_cpu_wb_dcache_bypass: sim/sim_cpu_wb_dcache_bypass.out
	cd sim && $(VVP) sim_cpu_wb_dcache_bypass.out $(VVP_DUMP) | tee cpu_wb_dcache_bypass.log
	@grep -aq "CPU-WB-DCACHE-BYPASS-TEST: PASS" sim/cpu_wb_dcache_bypass.log && echo "CPU_WB DCACHE BYPASS OK" || \
	    { echo "FAILED: cpu_wb.v DCACHE_ENABLE parameter"; exit 1; }

# ---- Phase 13: cross-hart LR/SC reservation monitor ----
#
# Board-independent, like sim_cpu_wb_dcache_bypass above: a brand new,
# standalone module nothing else in this tree instantiates yet - proven on
# its own before either core is wired to it, matching every earlier Phase
# 13 stage's own "verify the hard piece in isolation" sequencing. See
# docs/roadmap.md's Phase 13 entry.
sim/sim_reservation_monitor.out: sim/tb_reservation_monitor.v rtl/soc/reservation_monitor.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_reservation_monitor.v rtl/soc/reservation_monitor.v

sim_reservation_monitor: sim/sim_reservation_monitor.out
	cd sim && $(VVP) sim_reservation_monitor.out $(VVP_DUMP) | tee reservation_monitor.log
	@grep -aq "RESERVATION-MONITOR-TEST: PASS" sim/reservation_monitor.log && echo "RESERVATION MONITOR OK" || \
	    { echo "FAILED: rtl/soc/reservation_monitor.v"; exit 1; }

# ---- Phase 14: quantized-inference MAC engine ----
#
# Standalone module test first, matching Phase 13's own "verify the hard
# piece in isolation" sequencing (sim_reservation_monitor above being the
# most recent precedent) - proves rtl/soc/wb_npu.v's own register interface
# and MAC arithmetic against an independently-computed reference, without
# going through the interconnect at all. `make sim_ramboot`'s own
# acceptance test (software/soc/main.c's test_npu()) separately proves the
# same peripheral is reachable at 0x0900_0000 through the real CPU load/
# store path and the real address decode - the two together are what
# actually closes the loop; this alone does not.
sim/sim_wb_npu.out: sim/tb_wb_npu.v rtl/soc/wb_npu.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_wb_npu.v rtl/soc/wb_npu.v

sim_wb_npu: sim/sim_wb_npu.out
	cd sim && $(VVP) sim_wb_npu.out $(VVP_DUMP) | tee wb_npu.log
	@grep -aq "WB-NPU-TEST: PASS" sim/wb_npu.log && echo "NPU MAC ENGINE OK" || \
	    { echo "FAILED: rtl/soc/wb_npu.v"; exit 1; }

# ---- Phase 11: streaming FIR filter coprocessor ----
#
# Same "verify the hard piece in isolation" sequencing as sim_wb_npu above:
# proves rtl/soc/wb_fir.v's own register interface, sliding-window shift,
# and saturating accumulation against a reference tracked independently in
# sim/tb_wb_fir.v, without going through the interconnect at all. `make
# sim_ramboot`'s own acceptance test separately proves the same peripheral
# is reachable through the real CPU load/store path and the real address
# decode - the two together are what actually closes the loop.
sim/sim_wb_fir.out: sim/tb_wb_fir.v rtl/soc/wb_fir.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_wb_fir.v rtl/soc/wb_fir.v

sim_wb_fir: sim/sim_wb_fir.out
	cd sim && $(VVP) sim_wb_fir.out $(VVP_DUMP) | tee wb_fir.log
	@grep -aq "WB-FIR-TEST: PASS" sim/wb_fir.log && echo "FIR FILTER OK" || \
	    { echo "FAILED: rtl/soc/wb_fir.v"; exit 1; }

# ---- TMDS encoder (Phase 4, stage 1) ----
#
# Board-independent on purpose: no PLL, no serializer, no LPF entry exists
# yet (docs/roadmap.md Phase 4) - this checks only rtl/soc/tmds_encode.v's
# bit-level correctness against hand-derived vectors from the DVI 1.0 spec,
# so it can be trusted before any of the board-facing pieces exist.
sim/sim_tmds_encode.out: sim/tb_tmds_encode.v rtl/soc/tmds_encode.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_tmds_encode.v rtl/soc/tmds_encode.v

sim_tmds_encode: sim/sim_tmds_encode.out
	cd sim && $(VVP) sim_tmds_encode.out $(VVP_DUMP) | tee tmds_encode.log
	@grep -aq "TMDS-ENCODE-TEST: PASS" sim/tmds_encode.log && echo "TMDS ENCODE OK" || \
	    { echo "FAILED: TMDS encoder"; exit 1; }

# ---- video PLL (Phase 4, stage 2) ----
#
# fpga/video_pll.v's EHXPLLL body has no Icarus model (like
# fpga/sdram_clk_out.v's ODDRX1F) and is not what this checks - that is a
# nextpnr-ecp5 question, recorded by hand in fpga/README.md, not something
# `make verify` can gate. This checks the simulation-mode fallback's own
# divider logic gives the 5:1 clk_bit:clk_pixel ratio the eventual TMDS
# serializer needs, and that `locked` behaves like a real PLL's rather than
# being tied high.
sim/sim_video_pll.out: sim/tb_video_pll.v fpga/video_pll.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_video_pll.v fpga/video_pll.v

sim_video_pll: sim/sim_video_pll.out
	cd sim && $(VVP) sim_video_pll.out $(VVP_DUMP) | tee video_pll.log
	@grep -aq "VIDEO-PLL-TEST: PASS" sim/video_pll.log && echo "VIDEO PLL OK" || \
	    { echo "FAILED: video PLL"; exit 1; }

# ---- underclock PLL (real ULX3S hardware test for CORE=ooo) ----
#
# fpga/underclock_pll.v's EHXPLLL body has no Icarus model, the same
# situation as fpga/video_pll.v/fpga/sdram_clk_out.v above - a real
# nextpnr-ecp5 run is what actually confirms it, recorded in
# docs/roadmap.md's "CORE=ooo has no Fmax" entry, not something
# `make verify` can gate. This checks the simulation-mode fallback's own
# divider logic gives the real 5:1 clk_25mhz:clk_soc ratio, and that
# `locked` behaves like a real PLL's rather than being tied high.
sim/sim_underclock_pll.out: sim/tb_underclock_pll.v fpga/underclock_pll.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_underclock_pll.v fpga/underclock_pll.v

sim_underclock_pll: sim/sim_underclock_pll.out
	cd sim && $(VVP) sim_underclock_pll.out $(VVP_DUMP) | tee underclock_pll.log
	@grep -aq "UNDERCLOCK-PLL-TEST: PASS" sim/underclock_pll.log && echo "UNDERCLOCK PLL OK" || \
	    { echo "FAILED: underclock PLL"; exit 1; }

# ---- TMDS serializer (Phase 4, stage 3) ----
#
# fpga/tmds_serialize.v's ODDRX1F body has no Icarus model, same situation
# as fpga/video_pll.v's EHXPLLL and fpga/sdram_clk_out.v's own ODDRX1F
# before it - this exercises the simulation-mode fallback, driven by
# fpga/video_pll.v's own simulation clocks (the real 5:1 ratio the
# serializer assumes, not a hand-rolled one), and checks the reconstructed
# serial bit stream against the words that were actually fed in.
sim/sim_tmds_serialize.out: sim/tb_tmds_serialize.v fpga/tmds_serialize.v fpga/video_pll.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_tmds_serialize.v fpga/tmds_serialize.v fpga/video_pll.v

sim_tmds_serialize: sim/sim_tmds_serialize.out
	cd sim && $(VVP) sim_tmds_serialize.out $(VVP_DUMP) | tee tmds_serialize.log
	@grep -aq "TMDS-SERIALIZE-TEST: PASS" sim/tmds_serialize.log && echo "TMDS SERIALIZE OK" || \
	    { echo "FAILED: TMDS serializer"; exit 1; }

# ---- the boot ROM's UART loader ----
#
# The only way a program gets into external SDRAM on a board: a bitstream
# initialises block RAM at FPGA configuration time and SDRAM comes up empty.
# software/soc/uartload.py is the host half.
#
# The simulated transfer sends software/soc/uartprog.c rather than the 99 KB
# sdramtest image - at four clocks per bit the big one costs four million
# cycles before anything is checked, and sim_sdramcheck and sim_sdramboot
# already cover the size and the memory. On hardware, send the big one.
UARTPROG_SRCS = $(SOCRT_SRCS) software/soc/uartprog.c

software/soc/uartprog.elf: $(UARTPROG_SRCS) software/soc/link_sdram.ld $(SOC_HDRS)
	$(RISCV_CC) $(SOC_CFLAGS_COMMON) -T software/soc/link_sdram.ld \
	    -o $@ $(UARTPROG_SRCS)

# --word-size=1: this image travels as bytes over a serial line, not as words
# into a memory model.
sim/uartimage.hex: software/soc/uartprog.elf software/bin2hex.py Makefile
	$(RISCV_OBJCOPY) -O binary software/soc/uartprog.elf software/soc/uartprog.bin
	python3 software/bin2hex.py --word-size=1 software/soc/uartprog.bin > $@

sim/sim_uartload.out: sim/tb_uartload.v sim/sdram_model.v $(SOC_RTL)
	$(IVERILOG) $(IVFLAGS) -DROM_IMAGE='"bootrom_$(CORE).hex"' -o $@ sim/tb_uartload.v sim/sdram_model.v $(SOC_RTL)

# The *host* half of the same protocol, against a fake board on a pty. No
# board, no toolchain, no simulator - the fastest thing here that can catch a
# loader bug, and the only thing that tests software/soc/uartload.py at all.
# It found two on its first run.
uartload-host:
	python3 tests/uartload_host.py

sim_uartload: sim/bootrom_$(CORE).hex sim/uartimage.hex sim/sim_uartload.out
	@cd sim && $(VVP) sim_uartload.out $(VVP_DUMP) 2>&1 | tee uartload.log
	@grep -q "UARTLOAD TEST PASSED" sim/uartload.log || \
	    { echo "sim_uartload FAILED"; exit 1; }

# ---- external SDRAM (Phase 2) ----
#
# Two layers. sim_sdram drives rtl/soc/wb_sdram.v directly and is where a
# protocol bug is named; sim_sdramboot runs the SoC out of SDRAM and is where
# "larger than 64 KB" is actually demonstrated. The unit test needs no RISC-V
# toolchain at all, which is why CI can run it in the `rtl` job.
sim/sim_sdram.out: sim/tb_sdram.v sim/sdram_model.v rtl/soc/wb_sdram.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_sdram.v sim/sdram_model.v rtl/soc/wb_sdram.v

sim_sdram: sim/sim_sdram.out
	@cd sim && $(VVP) sim_sdram.out $(VVP_DUMP) 2>&1 | tee sdram.log
	@grep -q "SDRAM TEST PASSED" sim/sdram.log || \
	    { echo "sim_sdram FAILED"; exit 1; }

# ---- DDR3 init sequence (Phase 9 Stage 1, Part 1, docs/roadmap.md) ----
#
# Command sequence and timing only - no read/write/refresh data path
# exists yet, so this is not "sim_sdram for DDR3," it is the narrower
# thing that exists before that: proving the real JEDEC power-up/mode-
# register order and the real inter-command waits are honored, against
# sim/ddr3_model.v's own real protocol checker.
sim/sim_ddr3_init.out: sim/tb_ddr3_init.v rtl/soc/ddr3_init_seq.v rtl/soc/ddr3_phy_ecp5.v sim/ddr3_model.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_ddr3_init.v rtl/soc/ddr3_init_seq.v \
	    rtl/soc/ddr3_phy_ecp5.v sim/ddr3_model.v

sim_ddr3_init: sim/sim_ddr3_init.out
	@cd sim && $(VVP) sim_ddr3_init.out $(VVP_DUMP) 2>&1 | tee ddr3_init.log
	@grep -q "DDR3 INIT SEQUENCE TEST PASSED" sim/ddr3_init.log || \
	    { echo "sim_ddr3_init FAILED"; exit 1; }

# ---- DDR3 DQ/DQS data path (Phase 9 Stage 1, Part 2, docs/roadmap.md) ----
#
# One byte lane's own DQSBUFM-based read calibration and write-then-
# readback round trip, against sim/ddr3_dq_model.v's own real
# behavioral DQ/DQS memory. Distinct from sim_ddr3_init above: that one
# proves the command/mode-register sequence, this one proves the
# genuinely double-data-rate data path none of Part 1's own files touch.
sim/sim_ddr3_data.out: sim/tb_ddr3_data.v rtl/soc/ddr3_eclk_pll.v rtl/soc/ddr3_dqs_ecp5.v \
    rtl/soc/ddr3_dq_serdes_ecp5.v rtl/soc/ddr3_read_calib.v sim/ddr3_dq_model.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_ddr3_data.v rtl/soc/ddr3_eclk_pll.v \
	    rtl/soc/ddr3_dqs_ecp5.v rtl/soc/ddr3_dq_serdes_ecp5.v \
	    rtl/soc/ddr3_read_calib.v sim/ddr3_dq_model.v

sim_ddr3_data: sim/sim_ddr3_data.out
	@cd sim && $(VVP) sim_ddr3_data.out $(VVP_DUMP) 2>&1 | tee ddr3_data.log
	@grep -q "DDR3 DATA PATH TEST PASSED" sim/ddr3_data.log || \
	    { echo "sim_ddr3_data FAILED"; exit 1; }

# ---- DDR3 PHY integration (Phase 9 Stage 1, Part 3, docs/roadmap.md) ----
#
# rtl/soc/ddr3_ecp5_top.v wires Part 1 (init sequence + command/address)
# and Part 2 (DQ/DQS data path) onto one real, shared, PLL-derived clock
# tree for the first time - distinct from sim_ddr3_init/sim_ddr3_data
# above, which each proved their own half in isolation, against their
# own independently free-running testbench clock.
sim/sim_ddr3_top.out: sim/tb_ddr3_top.v rtl/soc/ddr3_ecp5_top.v rtl/soc/ddr3_eclk_pll.v \
    rtl/soc/ddr3_init_seq.v rtl/soc/ddr3_phy_ecp5.v rtl/soc/ddr3_dqs_ecp5.v \
    rtl/soc/ddr3_dq_serdes_ecp5.v rtl/soc/ddr3_dqs_write_ecp5.v rtl/soc/ddr3_read_calib.v \
    sim/ddr3_model.v sim/ddr3_dq_model.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_ddr3_top.v rtl/soc/ddr3_ecp5_top.v \
	    rtl/soc/ddr3_eclk_pll.v rtl/soc/ddr3_init_seq.v rtl/soc/ddr3_phy_ecp5.v \
	    rtl/soc/ddr3_dqs_ecp5.v rtl/soc/ddr3_dq_serdes_ecp5.v \
	    rtl/soc/ddr3_dqs_write_ecp5.v rtl/soc/ddr3_read_calib.v \
	    sim/ddr3_model.v sim/ddr3_dq_model.v

sim_ddr3_top: sim/sim_ddr3_top.out
	@cd sim && $(VVP) sim_ddr3_top.out $(VVP_DUMP) 2>&1 | tee ddr3_top.log
	@grep -q "DDR3 PHY INTEGRATION TEST PASSED" sim/ddr3_top.log || \
	    { echo "sim_ddr3_top FAILED"; exit 1; }

# ---- DDR3 DQS write-drive (Phase 9 Stage 1, Part 4, docs/roadmap.md) ----
#
# rtl/soc/ddr3_dqs_write_ecp5.v's own real preamble/active/postamble
# state sequencing, proven standalone - the same "narrow proof first"
# discipline Part 2's own byte-lane read-calibration test used before
# Part 3 integrated it. Not yet wired into ddr3_ecp5_top.v or exercised
# against a real memory model that samples on DQS edges - later work.
sim/sim_ddr3_dqs_write.out: sim/tb_ddr3_dqs_write.v rtl/soc/ddr3_dqs_write_ecp5.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_ddr3_dqs_write.v rtl/soc/ddr3_dqs_write_ecp5.v

sim_ddr3_dqs_write: sim/sim_ddr3_dqs_write.out
	@cd sim && $(VVP) sim_ddr3_dqs_write.out $(VVP_DUMP) 2>&1 | tee ddr3_dqs_write.log
	@grep -q "DDR3 DQS WRITE-DRIVE TEST PASSED" sim/ddr3_dqs_write.log || \
	    { echo "sim_ddr3_dqs_write FAILED"; exit 1; }

# ---- DDR3 write command sequencer (Phase 9 Stage 1, Part 6, docs/roadmap.md) ----
#
# rtl/soc/ddr3_write_seq.v's own real ACT->WR->write_start command
# sequencing with real (measured, not assumed) tRCD/CWL timing, proven
# standalone - the same "narrow proof first" discipline Part 4's own
# DQS write-drive test used before Part 5 integrated it. Not yet wired
# into rtl/soc/ddr3_ecp5_top.v.
sim/sim_ddr3_write_seq.out: sim/tb_ddr3_write_seq.v rtl/soc/ddr3_write_seq.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_ddr3_write_seq.v rtl/soc/ddr3_write_seq.v

sim_ddr3_write_seq: sim/sim_ddr3_write_seq.out
	@cd sim && $(VVP) sim_ddr3_write_seq.out $(VVP_DUMP) 2>&1 | tee ddr3_write_seq.log
	@grep -q "DDR3 WRITE SEQUENCER TEST PASSED" sim/ddr3_write_seq.log || \
	    { echo "sim_ddr3_write_seq FAILED"; exit 1; }

# ---- DDR3 read command sequencer (Phase 9 Stage 1, Part 7, docs/roadmap.md) ----
#
# rtl/soc/ddr3_read_seq.v's own real ACT->RD->read_start command
# sequencing - the read-side twin of sim_ddr3_write_seq above. Proven
# standalone; not yet wired into rtl/soc/ddr3_ecp5_top.v.
sim/sim_ddr3_read_seq.out: sim/tb_ddr3_read_seq.v rtl/soc/ddr3_read_seq.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_ddr3_read_seq.v rtl/soc/ddr3_read_seq.v

sim_ddr3_read_seq: sim/sim_ddr3_read_seq.out
	@cd sim && $(VVP) sim_ddr3_read_seq.out $(VVP_DUMP) 2>&1 | tee ddr3_read_seq.log
	@grep -q "DDR3 READ SEQUENCER TEST PASSED" sim/ddr3_read_seq.log || \
	    { echo "sim_ddr3_read_seq FAILED"; exit 1; }

# ---- DDR3 read-burst active-window extender (Phase 9 Stage 1, Part 8,
# docs/roadmap.md) ----
#
# rtl/soc/ddr3_read_burst_ext.v's own real read_active window, closing
# the shape mismatch Part 7 named: ddr3_read_seq.v's own read_start
# pulses once, but rtl/soc/ddr3_dqs_ecp5.v's own read_active input needs
# to stay high for the whole real capture window. Proven standalone;
# not yet wired into rtl/soc/ddr3_ecp5_top.v.
sim/sim_ddr3_read_burst_ext.out: sim/tb_ddr3_read_burst_ext.v rtl/soc/ddr3_read_burst_ext.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_ddr3_read_burst_ext.v rtl/soc/ddr3_read_burst_ext.v

sim_ddr3_read_burst_ext: sim/sim_ddr3_read_burst_ext.out
	@cd sim && $(VVP) sim_ddr3_read_burst_ext.out $(VVP_DUMP) 2>&1 | tee ddr3_read_burst_ext.log
	@grep -q "DDR3 READ BURST EXT TEST PASSED" sim/ddr3_read_burst_ext.log || \
	    { echo "sim_ddr3_read_burst_ext FAILED"; exit 1; }

SDRAMTEST_SRCS = $(SOCRT_SRCS) software/soc/sdramtest.c software/soc/sdramtable.S

software/soc/sdramtest.elf: $(SDRAMTEST_SRCS) software/soc/link_sdram.ld $(SOC_HDRS)
	$(RISCV_CC) $(SOC_CFLAGS_COMMON) -T software/soc/link_sdram.ld \
	    -o $@ $(SDRAMTEST_SRCS)

# --word-size=2 because sim/sdram_model.v is a 16-bit part: one entry per
# SDRAM word, little-endian. The default 4 would load every 32-bit word into
# one 16-bit column and put the rest of the image half an address space away,
# so the CPU would execute garbage from its first instruction.
sim/sdramimage.hex: software/soc/sdramtest.elf software/bin2hex.py Makefile
	$(RISCV_OBJCOPY) -O binary software/soc/sdramtest.elf software/soc/sdramtest.bin
	python3 software/bin2hex.py --word-size=2 software/soc/sdramtest.bin > $@

sdramimage: sim/sdramimage.hex

sim/sim_sdramboot.out: sim/tb_sdramboot.v sim/sdram_model.v $(SOC_RTL)
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_sdramboot.v sim/sdram_model.v $(SOC_RTL)

# The log is kept because `verilator_check` compares against it rather than
# running Icarus a second time - this test is three minutes and `verify` runs
# both targets. sim/*.log is gitignored.
sim_sdramboot: sim/sdramimage.hex sim/sim_sdramboot.out
	@cd sim && $(VVP) sim_sdramboot.out $(VVP_DUMP) 2>&1 | tee sdramboot.log
	@grep -q "SDRAMBOOT TEST PASSED" sim/sdramboot.log || \
	    { echo "sim_sdramboot FAILED"; exit 1; }

# Everything that can gate a change, in rough order of how fast it fails.
# Rebuilds from scratch on purpose: the simulation binaries do not encode
# which core they were built with, and running a stale one would report the
# in-order core's result under the other core's name.
verify_ooo:
	rm -f sim/*.out
	$(MAKE) verify CORE=ooo
	rm -f sim/*.out

verify: sim sim_software sim_soc sim_ramboot sim_ramboot_2hart sim_rerun trapcheck sim_video sim_blit sim_ulx3s sim_ulx3s_video sim_ecpix5 sim_cmd0 \
        sim_sdram sim_sdramboot verilator_check sim_sdramprobe sim_sdramcheck sim_ddr3_init sim_ddr3_data sim_ddr3_top sim_ddr3_dqs_write sim_ddr3_write_seq sim_ddr3_read_seq sim_ddr3_read_burst_ext \
        verilator_sdramfull \
        sim_mmusdram sim_plic sim_pmptest sim_uart16550 sim_uartirq sim_uartload sim_jtag \
        sim_cpu_halt \
        sim_cpu_resv_ports \
        sim_ooo_resv_ports \
        sim_ooo_halt \
        sim_soc_2hart \
        sim_soc_2hart_hetero \
        sim_soc_2hart_lrsc \
        sim_soc_2hart_lrsc_hetero \
        sim_soc_2hart_lrsc_swap_hetero \
        sim_soc_2hart_ordinary \
        sim_soc_2hart_ordinary_hetero \
        sim_ramboot_2hart_hetero \
        sim_soc_2hart_amoswap \
        sim_soc_2hart_amoswap_hetero \
        sim_ooo_csr_hazard \
        sim_pmp \
        sim_pmp_csr \
        sim_mhartid \
        sim_clint_multihart \
        sim_interconnect_multihart \
        sim_plic_4ctx \
        sim_cpu_wb_dcache_bypass \
        sim_reservation_monitor \
        sim_wb_npu \
        sim_wb_fir \
        sim_tmds_encode \
        sim_video_pll \
        sim_tmds_serialize \
        sim_div64test \
        uartload-host check-program isa cosim linux-if-built formal

# ---- the Linux boot, when there is a kernel to boot ----
#
# `sim_linux` cannot be a plain prerequisite of `verify`: it needs a kernel
# tarball off the network, and a gate that fails on a machine that has not run
# build-linux.sh is a gate people delete. So it runs when the image is there
# and says so loudly when it is not.
#
# It is here because of a specific incident. PR #49 registered the peripheral
# bridge's ack, recovered the timing margin, and **broke the Linux boot**: the
# supervisor-external interrupt count went from 50 to 87,339 and userspace
# never finished starting. It passed `make verify` on both cores and all eight
# CI jobs, because the longest thing this project runs was in none of them.
#
# Every peripheral test still passed too - sim_plic claims and completes one
# interrupt correctly. What broke needs a driver claiming and completing
# thousands, which only Linux does here. docs/practices.md section 44.
linux-if-built:
	@if [ -f $(LINUX_IMAGE) ]; then \
	    $(MAKE) --no-print-directory sim_linux; \
	else \
	    echo "==================================================="; \
	    echo "sim_linux SKIPPED - $(LINUX_IMAGE) is not built."; \
	    echo "This is the gate that would have caught PR #49."; \
	    echo "  ./software/linux/build-linux.sh   (needs the network)"; \
	    echo "==================================================="; \
	fi

clean:
	rm -rf sim/sim.out sim/wave.vcd sim/wave_verilator.vcd obj_dir \
	       obj_dir_soc_inorder obj_dir_soc_ooo sim/wave_verilator_soc.vcd \
	       sim/sdramboot.log sim/verilator_soc.log \
	       sim/sim_software.out sim/firmware_imem.hex sim/firmware_dmem.hex \
	       software/firmware.elf software/firmware_text.bin software/firmware_data.bin \
	       sim/sim_soc.out sim/wave_soc.vcd sim/card.hex \
	       sim/bootrom_inorder.hex sim/bootrom_ooo.hex sim/bootrom_hetero.hex \
	       sim/sim_ramboot.out sim/sim_probe.out sim/sim_rerun.out \
	       sim/program.rebuilt.hex sim/program.rebuilt.elf sim/program.rebuilt.bin \
	       sim/wave_ramboot.vcd sim/rerun.log \
	       sim/ramimage.hex sim/probeimage.hex \
	       sim/sim_sdram.out sim/sim_sdramboot.out sim/sdramimage.hex \
	       sim/sim_sdramprobe.out sim/sim_sdramcheck.out sim/sdramcheckimage.hex \
	       sim/sdramfullimage.hex sim/sdramfull.log \
	       obj_dir_soc_ramboot \
	       software/soc/sdramfull.elf software/soc/sdramfull.bin \
	       sim/sim_mmusdram.out sim/mmuimage.hex \
	       sim/sim_plic.out sim/plicimage.hex \
	       sim/sim_uart16550.out sim/uart16550image.hex \
	       sim/sim_uartirq.out sim/uartirqimage.hex \
	       sim/sim_jtag.out sim/jtagram.hex sim/jtag.log \
	       sim/sbiimage_inorder.hex sim/sbiimage_ooo.hex sim/sbiimage_hetero.hex \
	       sim/opensbi.log \
	       sim/linuximage_inorder.hex sim/linuximage_ooo.hex sim/linuximage_hetero.hex \
	       sim/linux.log \
	       software/linux/build/sdram.bin \
	       software/opensbi/build/sbi_stub.elf \
	       software/opensbi/build/sbi_stub.bin \
	       software/soc/uarttest.elf software/soc/uarttest.bin \
	       software/soc/uartirq.elf software/soc/uartirq.bin \
	       software/soc/plictest.elf software/soc/plictest.bin \
	       software/soc/mmutest.elf software/soc/mmutest.bin \
	       sim/sim_uartload.out sim/uartimage.hex sim/wave_uartload.vcd \
	       tests/build/uartload_case.bin \
	       software/soc/uartprog.elf software/soc/uartprog.bin \
	       sim/wave_ulx3s_sdram.vcd software/soc/sdramcheck.elf software/soc/sdramcheck.bin \
	       sim/wave_sdram.vcd sim/wave_sdramboot.vcd \
	       software/soc/sdramtest.elf software/soc/sdramtest.bin \
	       software/soc/bootrom_inorder.elf software/soc/bootrom_inorder.bin \
	       software/soc/bootrom_ooo.elf software/soc/bootrom_ooo.bin \
	       software/soc/bootrom_hetero.elf software/soc/bootrom_hetero.bin \
	       software/soc/socprog.elf software/soc/socprog.bin \
	       software/soc/npu_layer_data.h \
	       software/soc/fir_workload_data.h \
	       software/soc/npu_dma_workload_data.h \
	       software/soc/npu_trained_layer_data.h \
	       software/soc/dtb_blob_inorder.h software/soc/dtb_blob_ooo.h \
	       software/soc/dtb_blob_hetero.h \
	       software/soc/newlibprobe.elf software/soc/newlibprobe.bin \
	       dts/soc_inorder.dtb dts/soc_ooo.dtb dts/soc_hetero.dtb \
	       sim/sim_isa.out sim/sim_bench.out sim/coremark.hex \
	       software/bench/coremark.elf software/bench/coremark.bin \
	       sim/sim_soc_2hart_coremark.out sim/coremark_dispatch.hex \
	       sim/coremark_hart0.hex sim/coremark_hart1.hex \
	       software/bench/coremark_hart0.elf software/bench/coremark_hart0.bin \
	       software/bench/coremark_hart1.elf software/bench/coremark_hart1.bin \
	       software/bench/coremark_dispatch.elf software/bench/coremark_dispatch.bin \
	       tests/build formal/build
