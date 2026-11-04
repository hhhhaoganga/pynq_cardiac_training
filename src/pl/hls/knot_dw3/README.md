# 256×320 knot DW3/E3, 64 PW MACs

Independent evaluation candidate. User accepted the reduced-resolution float
accuracy tradeoff on 2026-10-07. QAT uses the existing 256×320 float checkpoint.

The engine is copied from memory_candidate: original multiply/accumulate structure,
outh/bias_d/mult_d in BRAM. Generated config sets CNN_TILE_IN=4 (16×4 PW MACs),
DW taps=3, and buffer capacities calculated from this network. DSP16 experiments
are not used. Packed PW weights are regenerated for 4-input tiles.

Validation: full validation-set integer metrics, C simulation, complete-inference
RTL cosimulation comparing every block, actual Vivado OOC synthesis and region
capacity audit against the existing frozen shell. No physical implementation is
launched by these scripts. RTL cycles at 100 MHz exclude real PS/DDR overhead;
20 fps end-to-end requires board measurement.
