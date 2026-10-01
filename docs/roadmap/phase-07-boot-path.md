# Phase 7 — Close the boot path

Moved to last, and not because it got harder. This file orders phases by what
each one unblocks, and nothing above is blocked by the SD card: every hardware
run preloads the program into the bitstream, and that works. It is the only
phase whose absence costs convenience rather than capability.

**The SD card is the only part of the boot chain that has never worked on
hardware**, and it is by a wide margin the cheapest open question in the
project — which is the argument for doing it out of order, below.

A 64 GB SDXC card never answers CMD0. That is permitted — SPI mode is optional
above 32 GB — but it has not been distinguished from a wiring fault, because no
smaller card has been tried. `BOARD=ulx3s-cmd0` builds a 60-flip-flop probe,
proven against the card model by `make sim_cmd0`, that answers it in seconds.

Until this closes, every hardware run depends on preloading the program into
the bitstream, which is a bring-up crutch rather than a boot path. That is the
argument for doing it early despite its position: a crutch that works is still
a crutch, and the phases above are all easier to test on hardware without
one.

**Done when:** a card ≤32 GB answers CMD0, and `BOARD=ulx3s85` boots the
acceptance test off the card rather than out of block RAM.

## Known defects

None recorded against this phase. The common, cross-cutting entries are in the [index](index.md#common-known-defects).

## Hardware

*Physical board testing: what has and has not run on a real board.*

Open, and it is the only part of the boot chain that has never worked on hardware. A 64 GB SDXC card never answers CMD0, and that has not been told apart from a wiring fault because no card of 32 GB or less has been tried. `BOARD=ulx3s-cmd0` is the probe that answers it in seconds; it needs the physical card.

## Software

*Simulation and formal checking: what has and has not been shown without a board.*

`make sim_cmd0` proves the probe against the SD card model. The boot-off-the-card half of the "Done when" has no simulation result recorded in this phase.
