# Reconfigurable partition floorplan (xc7z020, DFX build only).
# RP = all of fabric column 1 (clock regions X1Y0-X1Y2, full height) plus
# clock region X0Y0: 10,900 slices, 120 RAMB36, 180 DSP48.
# Static keeps X0Y1+X0Y2 (the strip beside the PS7: 2,400 slices, 20 RAMB36,
# 40 DSP48) where the PS-side AXI/VDMA/VTC logic already sits, plus the IO and
# clocking columns (MMCM, BUFG, OSERDES for HDMI), which DFX never reconfigures.
# Both rectangles are full clock-region height, as RESET_AFTER_RECONFIG needs.
create_pblock pblock_rp_accel
resize_pblock pblock_rp_accel -add {SLICE_X50Y0:SLICE_X113Y149 RAMB18_X3Y0:RAMB18_X5Y59 RAMB36_X3Y0:RAMB36_X5Y29 DSP48_X3Y0:DSP48_X4Y59}
resize_pblock pblock_rp_accel -add {SLICE_X0Y0:SLICE_X49Y49 RAMB18_X0Y0:RAMB18_X2Y19 RAMB36_X0Y0:RAMB36_X2Y9 DSP48_X0Y0:DSP48_X2Y19}
add_cells_to_pblock pblock_rp_accel [get_cells shell_i/rp_accel]
set_property SNAPPING_MODE ON [get_pblocks pblock_rp_accel]
set_property RESET_AFTER_RECONFIG true [get_pblocks pblock_rp_accel]
