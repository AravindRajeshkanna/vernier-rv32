# Simulation Makefile.
#
# macOS setup (one-time):
#   brew install icarus-verilog gtkwave
#   brew install verilator          # optional, for the verilator target
#   brew install riscv-software-src/riscv/riscv-tools   # for `make software`
#
# Usage:
#   make sim         -> run the hand-assembled self-checking testbench (Icarus)
#   make wave         -> run sim, then open the waveform in GTKWave
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

SOFTWARE_SRCS = software/crt0.S software/syscalls.c software/uart.c software/main.c
SOFTWARE_CFLAGS = -march=rv32im -mabi=ilp32 -specs=nano.specs -ffreestanding \
                   -O2 -Wall -nostartfiles -T software/link.ld

.PHONY: all sim wave verilator software sim_software clean

all: sim

sim:
	$(IVERILOG) -g2012 -o sim/sim.out $(TB) $(RTL)
	cd sim && $(VVP) sim.out

wave: sim
	gtkwave sim/wave.vcd &

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

clean:
	rm -rf sim/sim.out sim/wave.vcd sim/wave_verilator.vcd obj_dir \
	       sim/sim_software.out sim/firmware_imem.hex sim/firmware_dmem.hex \
	       software/firmware.elf software/firmware_text.bin software/firmware_data.bin
