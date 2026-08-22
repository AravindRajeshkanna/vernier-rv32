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
CORE         ?= inorder
ifeq ($(CORE),ooo)
# regfile_wide.v is only in this list, never the in-order one: rtl/regfile.v
# (2R/1W) still serves cpu_core.v, and building both cores against the same
# register file would remove the point of having two cores.
CORE_RTL      = rtl/ooo/core_ooo.v rtl/ooo/regfile_wide.v
CORE_DEFINES  = -DCORE_OOO
else
CORE_RTL      =
CORE_DEFINES  =
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
      rtl/clint.v rtl/plic.v rtl/uart.v rtl/btb.v rtl/mmu.v rtl/cpu_core.v rtl/top.v $(CORE_RTL)
TB  = sim/tb_top.v

# The SoC build shares the core and peripherals but swaps rtl/top.v (flat,
# Harvard, zero-latency) for the Wishbone system in rtl/soc/.
SOC_RTL = rtl/regfile.v rtl/csr_file.v rtl/muldiv_div.v rtl/clint.v rtl/plic.v \
          rtl/uart.v rtl/btb.v rtl/mmu.v rtl/cpu_core.v \
          rtl/soc/wb_interconnect.v rtl/soc/cpu_wb.v rtl/soc/wb_ptw.v \
          rtl/soc/wb_ram.v \
          rtl/soc/wb_rom.v rtl/soc/wb_periph_bridge.v rtl/soc/wb_gpio.v \
          rtl/soc/wb_spi.v rtl/soc/video_timing.v rtl/soc/wb_framebuffer.v \
          rtl/soc/wb_sdram.v rtl/soc/soc_top.v $(CORE_RTL)
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
        sim_soc sim_ramboot sim_probe sim_rerun trapcheck sim_video sim_ulx3s sim_cmd0 dtb \
        sim_sdram sim_sdramboot sdramimage sim_sdramprobe sim_sdramcheck \
        sim_mmusdram sim_plic sim_uart16550 \
        sim_uartload uartload-host sbiimage sim_opensbi \
        linuximage linuxpayload sim_linux \
        check-program regen-program verify_ooo \
        isa isa-build isa-fetch cosim formal coremark coremark-fetch verify clean

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

# -O3 on the generated model, and the lint left at full strength: soc_top
# currently verilates with zero warnings and the point of a second front end
# is to keep finding things Icarus does not.
#
# The parameters are set here rather than in a testbench because Verilator
# has no testbench to set them in. These match sim/tb_sdramboot.v: the
# board's 64 KB of block RAM, and a reset vector pointing straight at SDRAM
# so the first instruction fetch lands on a controller that is still 100 us
# into its power-up sequence and cannot answer.
VERILATOR_PARAMS = -GRAM_BYTES=65536 -GRESET_PC=0x90000000

# CORE_DEFINES is `-DCORE_OOO` or empty, and Verilator spells `define the
# same way Icarus does, so the same variable serves both front ends.
VERILATOR_FLAGS = --cc --exe --build -j 4 -O3 -CFLAGS "-O2" \
                   --top-module soc_top $(VERILATOR_TRACE) \
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
	@grep -aq "disagreed with the page tables" sim/verilator_soc.log && \
	    { echo "FAILED: a translation disagreed with the page tables"; \
	      exit 1; } || true
	@grep -aq "dropped by the transmitter" sim/verilator_soc.log && \
	    { echo "FAILED: the UART did not send a byte software wrote to it"; \
	      exit 1; } || true

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
	$(IVERILOG) $(IVFLAGS) -o sim/sim_soc.out $(SOC_TB) $(SOC_RTL)
	cd sim && $(VVP) sim_soc.out $(VVP_DUMP)

# ---- the preloaded-RAM boot path, in simulation ----
# sim_soc boots off the SD card model with 256 KB of RAM. The board that
# `BOARD=ulx3s85-ram` builds does neither: the program is baked into the
# bitstream and the RAM is 64 KB. Those are the two things that differed
# between "passes in simulation" and "dies on hardware", and until now nothing
# simulated them - so this testbench is that path, at that size.
sim/sim_ramboot.out: sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)
	$(IVERILOG) $(IVFLAGS) -DRAM_IMAGE='"ramimage.hex"' -o $@ sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)

sim_ramboot: sim/bootrom.hex sim/ramimage.hex sim/sim_ramboot.out
	cd sim && $(VVP) sim_ramboot.out $(VVP_DUMP)

sim/sim_probe.out: sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)
	$(IVERILOG) $(IVFLAGS) -DRAM_IMAGE='"probeimage.hex"' -o $@ sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)

sim_probe: sim/bootrom.hex sim/probeimage.hex sim/sim_probe.out
	cd sim && $(VVP) sim_probe.out $(VVP_DUMP)

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
	$(IVERILOG) $(IVFLAGS) -DRAM_IMAGE='"probeimage.hex"' -DRERUN \
	    -o $@ sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)

sim_rerun: sim/bootrom.hex sim/probeimage.hex sim/sim_rerun.out
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
	$(IVERILOG) $(IVFLAGS) -DRAM_IMAGE='"trapimage.hex"' -o $@ sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)

trapcheck: sim/bootrom.hex sim/sim_trap.out
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
	$(IVERILOG) $(IVFLAGS) -o $@ $(ISA_TB) $(SOC_RTL)

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
	$(IVERILOG) $(IVFLAGS) -o $@ $(BENCH_TB) $(SOC_RTL)

coremark: sim/sim_bench.out sim/coremark.hex
	cd sim && $(VVP) sim_bench.out +hex=coremark.hex

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
#            +sdram=sbiimage.hex +uart_clks=208 +maxcycles=8000000
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

sim/sbiimage.hex: software/opensbi/build/sbi_stub.bin dts/soc.dtb \
                   software/opensbi/mkimage.py Makefile
	@test -f $(OPENSBI_FW) || { \
	    echo "$(OPENSBI_FW) is missing - run ./software/opensbi/build-opensbi.sh first"; \
	    exit 1; }
	python3 software/opensbi/mkimage.py --nm=$(RISCV_NM) \
	    software/opensbi/build/sbi_stub.bin dts/soc.dtb \
	    $(OPENSBI_FW) $(OPENSBI_ELF) > $@

sbiimage: sim/sbiimage.hex

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
sim_opensbi: sim/sbiimage.hex $(VERILATOR_BIN)
	@cd sim && ../$(VERILATOR_BIN) +sdram=sbiimage.hex +uart_clks=224 \
	    +maxcycles=40000000 +sdram_words=16777216 | tee opensbi.log
	@grep -q "Boot HART Base ISA          : rv32ima" sim/opensbi.log && \
	    grep -q "Platform Console Device     : uart8250" sim/opensbi.log && \
	    echo "OPENSBI BOOT PASSED" || \
	    { echo "OPENSBI BOOT FAILED - no banner, or the platform was not detected"; \
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
sim/linuximage.hex: software/opensbi/build/sbi_stub.bin dts/soc.dtb \
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
	    software/opensbi/build/sbi_stub.bin dts/soc.dtb \
	    $(OPENSBI_FW) $(OPENSBI_ELF) > $@

linuximage: sim/linuximage.hex

linuxpayload: sim/linuximage.hex
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

sim_linux: sim/linuximage.hex $(VERILATOR_BIN)
	@cd sim && ../$(VERILATOR_BIN) +sdram=linuximage.hex +uart_clks=224 \
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
	$(IVERILOG) $(IVFLAGS) -DRAM_IMAGE='"uart16550image.hex"' \
	    -o $@ sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)

sim_uart16550: sim/bootrom.hex sim/uart16550image.hex sim/sim_uart16550.out
	cd sim && $(VVP) sim_uart16550.out $(VVP_DUMP)

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
	$(IVERILOG) $(IVFLAGS) -DRAM_IMAGE='"plicimage.hex"' \
	    -o $@ sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)

sim_plic: sim/bootrom.hex sim/plicimage.hex sim/sim_plic.out
	cd sim && $(VVP) sim_plic.out $(VVP_DUMP)

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
	$(IVERILOG) $(IVFLAGS) -DRAM_IMAGE='"mmuimage.hex"' \
	    -DSDRAM_WORDS='((1<<23)+(1<<16))' \
	    -o $@ sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)

sim_mmusdram: sim/bootrom.hex sim/mmuimage.hex sim/sim_mmusdram.out
	cd sim && $(VVP) sim_mmusdram.out $(VVP_DUMP)

sim/sim_sdramcheck.out: sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)
	$(IVERILOG) $(IVFLAGS) -DRAM_IMAGE='"sdramcheckimage.hex"' \
	    -o $@ sim/tb_ramboot.v sim/sdram_model.v $(SOC_RTL)

sim_sdramcheck: sim/bootrom.hex sim/sdramcheckimage.hex sim/sim_sdramcheck.out
	cd sim && $(VVP) sim_sdramcheck.out $(VVP_DUMP)

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
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_uartload.v sim/sdram_model.v $(SOC_RTL)

# The *host* half of the same protocol, against a fake board on a pty. No
# board, no toolchain, no simulator - the fastest thing here that can catch a
# loader bug, and the only thing that tests software/soc/uartload.py at all.
# It found two on its first run.
uartload-host:
	python3 tests/uartload_host.py

sim_uartload: sim/bootrom.hex sim/uartimage.hex sim/sim_uartload.out
	cd sim && $(VVP) sim_uartload.out $(VVP_DUMP)

# ---- external SDRAM (Phase 2) ----
#
# Two layers. sim_sdram drives rtl/soc/wb_sdram.v directly and is where a
# protocol bug is named; sim_sdramboot runs the SoC out of SDRAM and is where
# "larger than 64 KB" is actually demonstrated. The unit test needs no RISC-V
# toolchain at all, which is why CI can run it in the `rtl` job.
sim/sim_sdram.out: sim/tb_sdram.v sim/sdram_model.v rtl/soc/wb_sdram.v
	$(IVERILOG) $(IVFLAGS) -o $@ sim/tb_sdram.v sim/sdram_model.v rtl/soc/wb_sdram.v

sim_sdram: sim/sim_sdram.out
	cd sim && $(VVP) sim_sdram.out $(VVP_DUMP)

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
	cd sim && $(VVP) sim_sdramboot.out $(VVP_DUMP) | tee sdramboot.log

# Everything that can gate a change, in rough order of how fast it fails.
# Rebuilds from scratch on purpose: the simulation binaries do not encode
# which core they were built with, and running a stale one would report the
# in-order core's result under the other core's name.
verify_ooo:
	rm -f sim/*.out
	$(MAKE) verify CORE=ooo
	rm -f sim/*.out

verify: sim sim_software sim_soc sim_ramboot sim_rerun trapcheck sim_video sim_ulx3s sim_cmd0 \
        sim_sdram sim_sdramboot verilator_check sim_sdramprobe sim_sdramcheck \
        sim_mmusdram sim_plic sim_uart16550 sim_uartload \
        uartload-host check-program isa cosim formal

clean:
	rm -rf sim/sim.out sim/wave.vcd sim/wave_verilator.vcd obj_dir \
	       obj_dir_soc_inorder obj_dir_soc_ooo sim/wave_verilator_soc.vcd \
	       sim/sdramboot.log sim/verilator_soc.log \
	       sim/sim_software.out sim/firmware_imem.hex sim/firmware_dmem.hex \
	       software/firmware.elf software/firmware_text.bin software/firmware_data.bin \
	       sim/sim_soc.out sim/wave_soc.vcd sim/bootrom.hex sim/card.hex \
	       sim/sim_ramboot.out sim/sim_probe.out sim/sim_rerun.out \
	       sim/program.rebuilt.hex sim/program.rebuilt.elf sim/program.rebuilt.bin \
	       sim/wave_ramboot.vcd sim/rerun.log \
	       sim/ramimage.hex sim/probeimage.hex \
	       sim/sim_sdram.out sim/sim_sdramboot.out sim/sdramimage.hex \
	       sim/sim_sdramprobe.out sim/sim_sdramcheck.out sim/sdramcheckimage.hex \
	       sim/sim_mmusdram.out sim/mmuimage.hex \
	       sim/sim_plic.out sim/plicimage.hex \
	       sim/sim_uart16550.out sim/uart16550image.hex \
	       sim/sbiimage.hex sim/opensbi.log sim/linuximage.hex sim/linux.log \
	       software/linux/build/sdram.bin \
	       software/opensbi/build/sbi_stub.elf \
	       software/opensbi/build/sbi_stub.bin \
	       software/soc/uarttest.elf software/soc/uarttest.bin \
	       software/soc/plictest.elf software/soc/plictest.bin \
	       software/soc/mmutest.elf software/soc/mmutest.bin \
	       sim/sim_uartload.out sim/uartimage.hex sim/wave_uartload.vcd \
	       tests/build/uartload_case.bin \
	       software/soc/uartprog.elf software/soc/uartprog.bin \
	       sim/wave_ulx3s_sdram.vcd software/soc/sdramcheck.elf software/soc/sdramcheck.bin \
	       sim/wave_sdram.vcd sim/wave_sdramboot.vcd \
	       software/soc/sdramtest.elf software/soc/sdramtest.bin \
	       software/soc/bootrom.elf software/soc/bootrom.bin \
	       software/soc/socprog.elf software/soc/socprog.bin \
	       software/soc/newlibprobe.elf software/soc/newlibprobe.bin \
	       dts/soc.dtb \
	       sim/sim_isa.out sim/sim_bench.out sim/coremark.hex \
	       software/bench/coremark.elf software/bench/coremark.bin \
	       tests/build formal/build
