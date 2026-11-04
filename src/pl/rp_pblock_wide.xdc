# Reconfigurable partition floorplan, wide variant (xc7z020, DFX build only).
# Same as rp_pblock.xdc plus the seven rightmost slice columns of the static
# strip (SLICE_X43-X49, clock regions X0Y1+X0Y2, full height): 11,300 slices,
# 120 RAMB36, 180 DSP48. Possible because the fixed vtg_720p replaced v_tc
# (~750 static slices). The strip's RAMB36/DSP column (X2, between slice
# columns 31 and 38) stays static for the VDMA line buffer and vid_out FIFO.
create_pblock pblock_rp_accel
resize_pblock pblock_rp_accel -add {SLICE_X50Y0:SLICE_X113Y149 RAMB18_X3Y0:RAMB18_X5Y59 RAMB36_X3Y0:RAMB36_X5Y29 DSP48_X3Y0:DSP48_X4Y59}
resize_pblock pblock_rp_accel -add {SLICE_X0Y0:SLICE_X49Y49 RAMB18_X0Y0:RAMB18_X2Y19 RAMB36_X0Y0:RAMB36_X2Y9 DSP48_X0Y0:DSP48_X2Y19}
resize_pblock pblock_rp_accel -add {SLICE_X43Y50:SLICE_X49Y149}
add_cells_to_pblock pblock_rp_accel [get_cells shell_i/rp_accel]
set_property SNAPPING_MODE ON [get_pblocks pblock_rp_accel]
set_property RESET_AFTER_RECONFIG true [get_pblocks pblock_rp_accel]
