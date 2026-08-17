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
#   make verilator    -> build and run with Verilator instead
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

IVERILOG      = iverilog
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

RTL = rtl/regfile.v rtl/imem.v rtl/dmem.v rtl/csr_file.v rtl/muldiv_div.v \
      rtl/clint.v rtl/plic.v rtl/uart.v rtl/btb.v rtl/mmu.v rtl/cpu_core.v rtl/top.v
TB  = sim/tb_top.v

# The SoC build shares the core and peripherals but swaps rtl/top.v (flat,
# Harvard, zero-latency) for the Wishbone system in rtl/soc/.
SOC_RTL = rtl/regfile.v rtl/csr_file.v rtl/muldiv_div.v rtl/clint.v rtl/plic.v \
          rtl/uart.v rtl/btb.v rtl/mmu.v rtl/cpu_core.v \
          rtl/soc/wb_interconnect.v rtl/soc/cpu_wb.v rtl/soc/wb_ram.v \
          rtl/soc/wb_rom.v rtl/soc/wb_periph_bridge.v rtl/soc/wb_gpio.v \
          rtl/soc/wb_spi.v rtl/soc/video_timing.v rtl/soc/wb_framebuffer.v \
          rtl/soc/soc_top.v
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
        sim_soc sim_ramboot sim_probe sim_rerun trapcheck sim_video sim_ulx3s sim_cmd0 dtb \
        check-program regen-program \
        isa isa-build isa-fetch cosim formal coremark coremark-fetch verify clean

all: sim

sim:
	$(IVERILOG) -g2012 -o sim/sim.out $(TB) $(RTL)
	cd sim && $(VVP) sim.out

# Waveform viewer. GTKWave was discontinued upstream and Homebrew disabled
# its cask on 2025-10-29, so `surfer` is the default here; VIEWER= overrides
# it if you still have gtkwave installed from elsewhere.
VIEWER = surfer

wave: sim
	$(VIEWER) sim/wave.vcd &

wave_soc: sim_soc
	$(VIEWER) sim/wave_soc.vcd &

verilator:
	$(VERILATOR) --cc --exe --build --trace -j 4 --top-module top \
		$(RTL) sim/verilator_main.cpp \
		--Mdir obj_dir
	cd sim && ../obj_dir/Vtop

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
	$(IVERILOG) -g2012 -o sim/sim_software.out sim/tb_software.v $(RTL)
	cd sim && $(VVP) sim_software.out

# =====================================================================
# SoC build
# =====================================================================
soc: sim/bootrom.hex sim/card.hex

software/soc/bootrom.elf: $(BOOTROM_SRCS) software/soc/link_rom.ld software/soc/soc.h
	$(RISCV_CC) $(SOC_CFLAGS_COMMON) -T software/soc/link_rom.ld -o $@ $(BOOTROM_SRCS)

sim/bootrom.hex: software/soc/bootrom.elf software/bin2hex.py Makefile
	$(RISCV_OBJCOPY) -O binary software/soc/bootrom.elf software/soc/bootrom.bin
	python3 software/bin2hex.py --word-size=4 software/soc/bootrom.bin > $@

software/soc/socprog.elf: $(SOCPROG_SRCS) software/soc/link_ram.ld $(SOC_HDRS)
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
	$(IVERILOG) -g2012 -o sim/sim_soc.out $(SOC_TB) $(SOC_RTL)
	cd sim && $(VVP) sim_soc.out

# ---- the preloaded-RAM boot path, in simulation ----
# sim_soc boots off the SD card model with 256 KB of RAM. The board that
# `BOARD=ulx3s85-ram` builds does neither: the program is baked into the
# bitstream and the RAM is 64 KB. Those are the two things that differed
# between "passes in simulation" and "dies on hardware", and until now nothing
# simulated them - so this testbench is that path, at that size.
sim/sim_ramboot.out: sim/tb_ramboot.v $(SOC_RTL)
	$(IVERILOG) -g2012 -DRAM_IMAGE='"ramimage.hex"' -o $@ sim/tb_ramboot.v $(SOC_RTL)

sim_ramboot: sim/bootrom.hex sim/ramimage.hex sim/sim_ramboot.out
	cd sim && $(VVP) sim_ramboot.out

sim/sim_probe.out: sim/tb_ramboot.v $(SOC_RTL)
	$(IVERILOG) -g2012 -DRAM_IMAGE='"probeimage.hex"' -o $@ sim/tb_ramboot.v $(SOC_RTL)

sim_probe: sim/bootrom.hex sim/probeimage.hex sim/sim_probe.out
	cd sim && $(VVP) sim_probe.out

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
sim/sim_rerun.out: sim/tb_ramboot.v $(SOC_RTL)
	$(IVERILOG) -g2012 -DRAM_IMAGE='"probeimage.hex"' -DRERUN \
	    -o $@ sim/tb_ramboot.v $(SOC_RTL)

sim_rerun: sim/bootrom.hex sim/probeimage.hex sim/sim_rerun.out
	@cd sim && $(VVP) sim_rerun.out 2>&1 | tee rerun.log
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

sim/sim_trap.out: sim/tb_ramboot.v $(SOC_RTL)
	$(IVERILOG) -g2012 -DRAM_IMAGE='"trapimage.hex"' -o $@ sim/tb_ramboot.v $(SOC_RTL)

trapcheck: sim/bootrom.hex sim/sim_trap.out
	./sim/trapcheck.sh

# ---- video ----
# The framebuffer's only proof while no display is attached: draw a known
# pattern through the bus, capture a frame off the scan-out, and compare.
# Also drops sim/frame.ppm for a human to look at - but the verdict is the
# readback, not the image.
sim_video:
	$(IVERILOG) -g2012 -o sim/sim_video.out sim/tb_video.v \
	    rtl/soc/video_timing.v rtl/soc/wb_framebuffer.v
	cd sim && $(VVP) sim_video.out

# ---- hardware CMD0 probe ----
# fpga/ulx3s_cmd0.v goes on a board to answer "does the card reply to CMD0",
# so a bug in it would send someone hunting for hardware faults that are not
# there. This proves it against the card model first: 0xFF with no card, 0x01
# when one is inserted mid-run, 0xFF again when removed.
sim_cmd0:
	$(IVERILOG) -g2012 -o sim/sim_cmd0.out sim/tb_cmd0.v \
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
	$(IVERILOG) -g2012 -o sim/sim_ulx3s.out sim/tb_ulx3s.v \
	    $(SOC_RTL) fpga/soc_fpga.v fpga/ulx3s_top.v
	cd sim && $(VVP) sim_ulx3s.out

# =====================================================================
# Device tree
# =====================================================================
dtb: dts/soc.dtb

dts/soc.dtb: dts/soc.dts
	dtc -I dts -O dtb -o $@ $<
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
	$(IVERILOG) -g2012 -o $@ $(ISA_TB) $(SOC_RTL)

isa: sim/sim_isa.out isa-build
	./tests/run.sh

# ---- co-simulation against Spike ----
# Stricter than the tests: compares every retired instruction, not just the
# final verdict. Needs `spike` on PATH.
cosim: sim/sim_isa.out isa-build
	python3 tests/cosim.py --all

# ---- formal (yosys + yosys-smtbmc + z3) ----
formal:
	./formal/run.sh

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
COREMARK_CFLAGS = -march=rv32im_zicsr_zifencei -mabi=ilp32 -specs=nano.specs \
                   -ffreestanding -O2 -nostartfiles \
                   -DITERATIONS=$(COREMARK_ITERS) -DPERFORMANCE_RUN=1 \
                   -DFLAGS_STR='"-O2 -march=rv32im"' \
                   -I$(COREMARK_DIR) -Isoftware/bench -Isoftware \
                   -T software/bench/link_bench.ld

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
	$(IVERILOG) -g2012 -o $@ $(BENCH_TB) $(SOC_RTL)

coremark: sim/sim_bench.out sim/coremark.hex
	cd sim && $(VVP) sim_bench.out +hex=coremark.hex

# Everything that can gate a change, in rough order of how fast it fails.
verify: sim sim_software sim_soc sim_ramboot sim_rerun trapcheck sim_video sim_ulx3s sim_cmd0 \
        check-program isa cosim formal

clean:
	rm -rf sim/sim.out sim/wave.vcd sim/wave_verilator.vcd obj_dir \
	       sim/sim_software.out sim/firmware_imem.hex sim/firmware_dmem.hex \
	       software/firmware.elf software/firmware_text.bin software/firmware_data.bin \
	       sim/sim_soc.out sim/wave_soc.vcd sim/bootrom.hex sim/card.hex \
	       sim/sim_ramboot.out sim/sim_probe.out sim/sim_rerun.out \
	       sim/program.rebuilt.hex sim/program.rebuilt.elf sim/program.rebuilt.bin \
	       sim/wave_ramboot.vcd sim/rerun.log \
	       sim/ramimage.hex sim/probeimage.hex \
	       software/soc/bootrom.elf software/soc/bootrom.bin \
	       software/soc/socprog.elf software/soc/socprog.bin \
	       software/soc/newlibprobe.elf software/soc/newlibprobe.bin \
	       dts/soc.dtb \
	       sim/sim_isa.out sim/sim_bench.out sim/coremark.hex \
	       software/bench/coremark.elf software/bench/coremark.bin \
	       tests/build formal/build
