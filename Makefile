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

IVERILOG      = iverilog
VVP           = vvp
VERILATOR     = verilator
# The $$readmemh image rules below list `Makefile` as a prerequisite on
# purpose: the word/byte layout of every image is decided by the bin2hex
# flags *in this file*, not by anything in software/. Without it, changing a
# memory's organization leaves a stale image that loads silently and wrong -
# which cost real debugging time when wb_ram.v went from byte- to
# word-organized.
RISCV_CC      = riscv64-unknown-elf-gcc
RISCV_OBJCOPY = riscv64-unknown-elf-objcopy

RTL = rtl/regfile.v rtl/imem.v rtl/dmem.v rtl/csr_file.v rtl/muldiv_div.v \
      rtl/clint.v rtl/plic.v rtl/uart.v rtl/btb.v rtl/mmu.v rtl/cpu_core.v rtl/top.v
TB  = sim/tb_top.v

# The SoC build shares the core and peripherals but swaps rtl/top.v (flat,
# Harvard, zero-latency) for the Wishbone system in rtl/soc/.
SOC_RTL = rtl/regfile.v rtl/csr_file.v rtl/muldiv_div.v rtl/clint.v rtl/plic.v \
          rtl/uart.v rtl/btb.v rtl/mmu.v rtl/cpu_core.v \
          rtl/soc/wb_interconnect.v rtl/soc/cpu_wb.v rtl/soc/wb_ram.v \
          rtl/soc/wb_rom.v rtl/soc/wb_periph_bridge.v rtl/soc/wb_gpio.v \
          rtl/soc/wb_spi.v rtl/soc/soc_top.v
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
SOCPROG_SRCS = software/soc/crt0_ram.S software/soc/main.c \
                software/syscalls.c software/uart.c
SOCPROG_CFLAGS = $(SOC_CFLAGS_COMMON) -specs=nano.specs

# Card size in 512-byte blocks; must match sim/tb_soc.v's CARD_BYTES (64 KB).
SD_BLOCKS = 128

.PHONY: all sim wave wave_soc verilator software sim_software soc sim_soc sim_ulx3s dtb \
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

software/soc/socprog.elf: $(SOCPROG_SRCS) software/soc/link_ram.ld software/soc/soc.h
	$(RISCV_CC) $(SOCPROG_CFLAGS) -T software/soc/link_ram.ld -o $@ $(SOCPROG_SRCS)

sim/card.hex: software/soc/socprog.elf software/soc/mkcard.py Makefile
	$(RISCV_OBJCOPY) -O binary software/soc/socprog.elf software/soc/socprog.bin
	python3 software/soc/mkcard.py software/soc/socprog.bin $(SD_BLOCKS) > $@

sim_soc: soc
	$(IVERILOG) -g2012 -o sim/sim_soc.out $(SOC_TB) $(SOC_RTL)
	cd sim && $(VVP) sim_soc.out

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
verify: sim sim_software sim_soc sim_ulx3s isa cosim formal

clean:
	rm -rf sim/sim.out sim/wave.vcd sim/wave_verilator.vcd obj_dir \
	       sim/sim_software.out sim/firmware_imem.hex sim/firmware_dmem.hex \
	       software/firmware.elf software/firmware_text.bin software/firmware_data.bin \
	       sim/sim_soc.out sim/wave_soc.vcd sim/bootrom.hex sim/card.hex \
	       software/soc/bootrom.elf software/soc/bootrom.bin \
	       software/soc/socprog.elf software/soc/socprog.bin \
	       dts/soc.dtb \
	       sim/sim_isa.out sim/sim_bench.out sim/coremark.hex \
	       software/bench/coremark.elf software/bench/coremark.bin \
	       tests/build formal/build
