# Knot DW3/E3 SystemVerilog candidate

Independent implementation of the accepted 256x320 integer model. This directory
is a development candidate, not a deployable bitstream. Preserve the HLS baseline.

Contract: identical exported integer weights, activation signedness, rounding,
24-bit accumulator semantics, residual scaling, and padded output layout. The
existing 22-block golden fixture is the first end-to-end oracle. Additional
randomized arithmetic and memory-backpressure checks are required.

Architecture: offline row-level microprogram, shared 16-output x 4-input PW array,
16-channel x 3-tap DW array, synchronous explicitly banked RAM. Channel parameters
are packed as bias24/mult32/shift6 in a 64-bit word and prefetched into registers.
PW and DW retain local parameter RAMs to avoid a wide cross-region bus. Head and
ordinary output share a 64-bit output RAM, removing the 512-bit shallow head RAM.
No HLS-generated arithmetic or controller is used in the new core.

Acceptance order: compiler contract checks; arithmetic/RAM simulation; all 22
blocks bit-exact under memory stalls; complete-call cycles with DDR budget;
Vivado OOC resource/timing and fixed-shell capacity review; only then one physical
implementation. No static-shell changes or board programming are authorized here.
Simulation performance is not proof of 20fps on the board.

## Data path and software integration

The compiler preserves original DDR tensor locations. It appends channel-packed
parameters and 4062 row instructions to the reviewed fixture. The image buffer is
RGBX unsigned input codes; the head is 32x40x16 padded signed int32, with 7 valid
channels. Use the existing model's quantized preprocessing and head scales/decode.
`program.json` supplies input/output offsets and the program's 64-bit beat address.
Initialize DDR from `memory.bin` once, overwrite input codes per frame, flush the
buffer, issue SVK1 start, wait, invalidate the output buffer, then decode/NMS on PS.

`board_driver.py` accepts an already mapped MMIO object. It neither flashes the
board nor assumes the old HLS register ABI. SVK1 registers: control/status 0x00,
IRQ enable 0x04, pending W1C 0x0c, DDR base byte address 0x10, program beat offset
0x18, cycle counter 0x20/0x24, signature 0x3c. Bitstream and live-board acceptance
are separate gates; the helper alone is not proof of deployment.

## Reproduce

1. `python compile_program.py <reviewed HLS fixture directory> fixture`
2. `python tests/make_arithmetic_vectors.py`
3. On the configured server: `python3 validate.py <new-revision-name>`.
   This creates an immutable source/input snapshot and runs arithmetic edges,
   22-block RTL checks, whole-model AXI tests with stalls, and Vivado OOC synthesis.
4. Inspect the exact revision's resources and timing before `audit.tcl` or physical
   implementation. Never route a different source tree than the one verified.

The PW arithmetic array has an operand capture stage, multiply stage, two adder
tree stages, and accumulator stage (II=1). DW has multiply, sum and partial-sum
accumulation stages. RAM/window alignment and the shared seven-stage requantizer
are additional stages. PW and DW execute sequentially under the row scheduler;
their 64 and 48 multipliers are not 112 sustained parallel MACs for the model.
