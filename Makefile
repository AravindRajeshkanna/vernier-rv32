# Simulation Makefile.
#
# macOS setup (one-time):
#   brew install icarus-verilog surfer
#   brew install verilator          # optional, for the verilator target
#   brew install riscv-software-src/riscv/riscv-tools   # for `make software`
#
# Usage:
#   make sim         -> run the hand-assembled self-checking testbench (Icarus)
#   make wave         -> run sim, then open the waveform (surfer)
#   make wave_soc     -> same for the SoC simulation
#   make verilator    -> build and run with Verilator instead
#   make software     -> compile software/ with riscv64-unknown-elf-gcc
#   make sim_software -> build software/ and run it, showing real UART output
#   make clean

IVERILOG      = iverilog
VVP           = vvp
VERILATOR     = verilator
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

.PHONY: all sim wave wave_soc verilator software sim_software soc sim_soc dtb clean

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

sim/firmware_imem.hex: software/firmware.elf software/bin2hex.py
	$(RISCV_OBJCOPY) -O binary --only-section=.text software/firmware.elf software/firmware_text.bin
	python3 software/bin2hex.py --word-size=4 software/firmware_text.bin > sim/firmware_imem.hex

sim/firmware_dmem.hex: software/firmware.elf software/bin2hex.py
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

sim/bootrom.hex: software/soc/bootrom.elf software/bin2hex.py
	$(RISCV_OBJCOPY) -O binary software/soc/bootrom.elf software/soc/bootrom.bin
	python3 software/bin2hex.py --word-size=4 software/soc/bootrom.bin > $@

software/soc/socprog.elf: $(SOCPROG_SRCS) software/soc/link_ram.ld software/soc/soc.h
	$(RISCV_CC) $(SOCPROG_CFLAGS) -T software/soc/link_ram.ld -o $@ $(SOCPROG_SRCS)

sim/card.hex: software/soc/socprog.elf software/soc/mkcard.py
	$(RISCV_OBJCOPY) -O binary software/soc/socprog.elf software/soc/socprog.bin
	python3 software/soc/mkcard.py software/soc/socprog.bin $(SD_BLOCKS) > $@

sim_soc: soc
	$(IVERILOG) -g2012 -o sim/sim_soc.out $(SOC_TB) $(SOC_RTL)
	cd sim && $(VVP) sim_soc.out

# =====================================================================
# Device tree
# =====================================================================
dtb: dts/soc.dtb

dts/soc.dtb: dts/soc.dts
	dtc -I dts -O dtb -o $@ $<
	@echo "--- round-tripping back to source as a sanity check ---"
	@dtc -I dtb -O dts $@ > /dev/null && echo "device tree OK"

clean:
	rm -rf sim/sim.out sim/wave.vcd sim/wave_verilator.vcd obj_dir \
	       sim/sim_software.out sim/firmware_imem.hex sim/firmware_dmem.hex \
	       software/firmware.elf software/firmware_text.bin software/firmware_data.bin \
	       sim/sim_soc.out sim/wave_soc.vcd sim/bootrom.hex sim/card.hex \
	       software/soc/bootrom.elf software/soc/bootrom.bin \
	       software/soc/socprog.elf software/soc/socprog.bin \
	       dts/soc.dtb
