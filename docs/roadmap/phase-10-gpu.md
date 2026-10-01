# Phase 10 — GPU

**Not blocked on a board, blocked on a decision, and that decision is the
whole phase.** "Renders images, video, and user interfaces" spans a range
too wide to plan against as one item - a solid-fill/blit engine that
offloads `wb_framebuffer.v`'s current software rasterizer is a peripheral
roughly the size of `rtl/soc/wb_spi.v`; a programmable 3D pipeline with vertex/fragment
shaders is closer in scope to Phase 1's out-of-order core, and shares
none of its design. Naming this "the GPU phase" without picking a point
on that range would be exactly the kind of estimate `docs/practices.md`
exists to catch - a number quoted, not measured. Nothing below is a spec;
it names what already exists to build from and what the real open
question is once a target is picked.

**What existed when this phase began, precisely:** `rtl/soc/wb_framebuffer.v` -
320×240, 8bpp RRRGGGBB, one Wishbone slave, one wait state - and
`rtl/soc/video_timing.v`, scanning it out at 640×480@60 over the
block RAM's own second port (no bus master added for scan-out). Every
pixel in it was written by the CPU executing an ordinary `sb`, in a
software loop - there was no acceleration hardware of any kind, and
`make sim_video` proved only that the timing generator and scan-out
path are correct, not that anything draws faster than a store
instruction can. (The stages below changed this - see the running
account.) Phase 4 built the path from framebuffer to a real
monitor - `fpga/video_pll.v`, `fpga/tmds_serialize.v`, real GPDI pins on
`fpga/ulx3s_top.v`, gated behind `` `ifdef WITH_VIDEO `` after it cost the
default board target its timing margin (`docs/soc.md` has the current
state) - so a GPU phase inherits a real, silicon-verified place to send
pixels; it does not need to build one.

**The first open item, matching how Phase 8 treats board selection:**
what "renders" is actually asking for. In roughly increasing order of how
much of this codebase it touches:

- **2D acceleration** - a blit/fill/line-draw engine, commanded by MMIO
  registers or a small command queue the CPU writes and the engine
  drains. Closest in shape to every peripheral this project already has.
- **A display compositor** - fixed-size sprites or layers blended by
  hardware during scan-out, extending `video_timing.v`'s read path rather
  than the CPU-write path. Different problem from 2D acceleration:
  faster *drawing* than faster *composing what's already drawn*.
- **A programmable pipeline** - vertex/fragment shader cores, texture
  sampling, a framebuffer far larger than 320×240×8bpp allows. This is
  not "add a peripheral"; it is a second, parallel processor with its own
  instruction set and memory model, and belongs in the same conversation
  as Phase 1's superscalar/OoO work, not a small register-mapped
  peripheral's.

**Done when:** whichever target is chosen, the same bar Phase 0 set for
the pipeline itself - simulated first, then a real, measured result on
the ULX3S over the GPDI output Phase 4 already proved works, not a
claim from simulation alone.

**Stage 1 (shipped): solid rectangle fill.** 2D acceleration was the
target picked; the first increment is a fill engine only - no copy, no
line-draw, both deferred to later stages.

**Extends `wb_framebuffer.v`'s own Wishbone slave rather than adding a
new one** - a deliberate departure from the bullet above's original "as
a new Wishbone slave" framing, made once the module's own header comment
turned out to already anticipate exactly this ("no drawing engine, no
blitter... deliberate for a first version... adds no bus master").
Extending in place instead of adding a fourth slave costs zero
interconnect wiring: no `NUM_SLAVES` bump, no new `s_base`/`s_mask`
entry, no new `soc_top.v` instantiation, none of the five-places-to-edit
risk `docs/soc.md`'s own peripheral checklist warns about for a genuinely
new slave. The new register block lives at a previously-unused address
bit (bit 17 of the offset, `FB_BASE + 0x20000`) well clear of the
76,800-byte pixel array, so pixel addressing is untouched.

Register map (`docs/soc.md` has the full table): `BLIT_X`/`Y`/`W`/`H`/
`COLOR` set the rectangle, `BLIT_CTRL` starts it, `BLIT_STATUS` reports
busy - the same CTRL/STATUS naming `wb_spi.v` already established,
reused rather than inventing a new shape. Unlike SPI's blocking DATA
register, starting a fill is **non-blocking**: the whole value of a fill
engine is that software can go do something else while it runs, so the
CTRL write acks immediately and a separate STATUS poll (mirroring
`SPI_STATUS`'s busy bit) is how a caller learns it's done. A CPU access
to pixel data, or to any other blit register, stalls - not acked - for
the duration of a fill, reusing the same "withhold ack" mechanism SPI's
own multi-cycle transfers already exercise, rather than adding a new
kind of wait state to the interconnect.

**Out-of-range rectangles are clamped, not rejected**, matching this
project's "ack with zeros rather than wedge the bus" treatment of a
stray pointer elsewhere in the address map: a width/height that would
run past the buffer edge is silently truncated; an origin already off
the buffer, or a zero width/height, draws nothing and still completes
normally. Verified directly - `sim/tb_blit.v` drives the register block
with no CPU involved and checks every pixel in the buffer against an
independently-tracked expected image after each case (exact fit, an
interior overlay, a rectangle clamped at the edge, an off-buffer origin,
zero width, zero height), plus that `BLIT_STATUS.busy` genuinely reads 1
partway through a large fill rather than clearing immediately, plus that
a pixel write issued mid-fill really stalls (measured in cycles, not
just "eventually returns") and lands correctly once the fill completes.
Made the test fail first: temporarily disabling the clamp produced 570
real pixel mismatches at the buffer's bottom-right edge before the fix
was restored, rather than trusting a test that had never been observed
to catch anything. `software/soc/main.c`'s acceptance test gained a
`test_blit()` case exercising the same path a real caller would, through
`soc.h`'s `fb_fill_rect()` wrapper rather than the raw registers.

**Stage 2 (shipped): rectangle copy, with overlap.** The engine gained a
second operation - `BLIT_CTRL` bit 1 selects it - that copies one
rectangle to another rather than filling with a constant. `BLIT_X`/`Y`
are reused as the destination (the same concept a fill's rectangle
already is); two new registers, `BLIT_SRC_X`/`SRC_Y`, name the source.

**Copying is honestly two cycles per pixel, not one - measured, not
assumed.** A fill writes a constant into `mem[]` every cycle, needing
only the one write reference the destination address already uses. A
copy needs a *read* of the source pixel and a *write* of the destination
pixel, and `mem[]` has exactly two ports: the one this engine shares
with the CPU, and the scan-out port, which is permanently committed to
the live raster and cannot be borrowed even for a single cycle without
corrupting the picture on screen. With only one read+write port
available, and one port unable to read one address and write a
different one in the same cycle, a copy is a read cycle followed by a
write cycle - `sim/tb_blit.v` confirms this directly: a 100x80 fill took
2,000 status polls, the identical-area copy took 4,000.

**The real design problem was overlap**, not the two-phase pipeline. A
copy's source and destination are allowed to overlap - the ordinary
case is scrolling part of the screen - and a naive forward copy
corrupts itself the moment the destination writes over a source pixel
that a later step still needs to read. The fix is the standard
technique behind `memmove` and every BitBLT-style engine that allows
overlap: choose each axis's iteration direction independently, backward
whenever the destination sits on the higher-address side of the source
on that axis. That is provably correct for *any* relative offset, not
just a pure horizontal or vertical shift, because a row or column is
only ever written after everything still needed from it has already
been read. `sim/tb_blit.v` draws a per-pixel pattern (a solid fill can't
reveal a scrambled copy - every pixel looks the same either way) and
checks all four shift directions plus two diagonals, a copy clamped by
running the source off the buffer edge, and the degenerate off-buffer
and zero-width cases - all against an independently-tracked expected
image that models the copy as its own atomic snapshot-then-write, so
the test's own model can't share a bug with the RTL it's checking.

Made the test fail first here too: forcing both axes to always iterate
forward - the version without the overlap fix - produced 6,892 pixel
mismatches concentrated exactly where the overlapping-copy cases
predicted, before the real direction logic was restored.
`software/soc/main.c` gained `test_copy()`, exercised through `soc.h`'s
new `fb_copy_rect()` wrapper: two colours placed side by side, shifted
right by an offset smaller than their combined width so the copy must
overlap its own source, then checked that the boundary between them
landed exactly where a correct shift puts it.

**Stage 3 (shipped): line drawing.** `BLIT_CTRL` gained a third op
value; `BLIT_X`/`Y` and `BLIT_SRC_X`/`Y` are reused as the line's two
endpoints, the same "point 0, point 1" shape a copy's destination and
source already are. The rasterization is standard integer Bresenham -
the "dy stored negative" formulation, chosen because it's what makes
this hardware-friendly in the first place: no floating point, no
division, one comparison and one or two additions per pixel, and every
octant plus the degenerate single-point case falls out with no
special-casing.

**Deliberately not clamped the way a fill or copy rectangle is.**
Clipping a line segment to a viewport is a genuinely different, more
involved problem (Cohen-Sutherland and its relatives) than clamping an
axis-aligned rectangle, and this stage doesn't take it on. Instead,
every step checks whether the pixel it's about to plot actually lands
inside the buffer and skips the write if not, while still advancing the
algorithm - so a line is safe to draw with any endpoints, including ones
entirely off the buffer, and always completes in a bounded number of
cycles (at most `max(|X1-X0|,|Y1-Y0|)+1`, the same order of magnitude a
fill or copy already costs for a comparable span). This was a deliberate
scope cut, not an oversight - real line-clipping is its own problem and
a plausible future stage on its own.

**Verified by structural invariant, not by re-deriving Bresenham a
second time in the testbench.** A second implementation of the same
algorithm risks sharing a bug (or landing on a different, still-valid
tie-breaking convention) with the RTL it's meant to check, so
`sim/tb_blit.v` instead confirms properties that hold for *any* correct
rasterization of a fully-visible line: exactly `max(|dx|,|dy|)+1` pixels
drawn, both endpoints present, every pixel inside the line's own
bounding box, and - the strongest of the four - exactly one pixel per
column for a shallow line or one per row for a steep one, which rules
out both gaps and double-backs regardless of tie-breaking. Covers
horizontal, vertical, an exact 45-degree diagonal, a shallow slope, a
steep slope, a line drawn backward (both endpoints decreasing), a
degenerate single point, a line clipped at the buffer edge, and a line
entirely off the buffer.

Made the test fail first twice over, for two different properties.
Bypassing the per-pixel in-buffer check entirely made the "line
entirely off the buffer" case show 42 stray visible pixels - a real
out-of-bounds write aliasing back onto the visible screen instead of
being skipped. Separately, swapping which register held the x and y
step magnitudes at kickoff - a classic transposition bug - didn't
produce a wrong picture; it hung. The very first line test never
completed, exceeding the testbench's own 2-second simulated-time
watchdog, because the swap broke the invariant the whole design leans
on: a line always reaches its own endpoint in a bounded number of
steps. Both faults were restored and the suite re-verified clean before
shipping. `software/soc/main.c` gained `test_line()`, through `soc.h`'s
new `fb_line()` wrapper, checking a horizontal and a 45-degree line by
exact pixel set - unlike the general case, both have an unambiguous
rasterization, so this doesn't need `tb_blit.v`'s structural checks.

## Known defects

None recorded against this phase. The common, cross-cutting entries are in the [index](index.md#common-known-defects).

## Hardware

*Physical board testing: what has and has not run on a real board.*

No stage of the blitter has been run on a board. The phase is not blocked on one; its stages are proven in simulation.

## Software

*Simulation and formal checking: what has and has not been shown without a board.*

Stages 1 to 3 shipped and are checked in simulation: rectangle fill, rectangle copy with overlap, and line drawing. The stage accounts above carry how each was verified and what each cost.
