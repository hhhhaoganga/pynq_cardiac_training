# PYNQ-Z2 HDMI OUT TMDS. Cross-checked against Xilinx/PYNQ v3.1:
# boards/Pynq-Z2/base/vivado/constraints/base.xdc
# blob fb77db7aee82cc9ad8614c8b77ba953d7c28a8f4
# DDC uses PS MIO50/51; no PL pin constraints for DDC.
set_property -dict {PACKAGE_PIN L16 IOSTANDARD TMDS_33} [get_ports TMDS_0_tmds_clk_p]
set_property -dict {PACKAGE_PIN L17 IOSTANDARD TMDS_33} [get_ports TMDS_0_tmds_clk_n]
set_property -dict {PACKAGE_PIN K17 IOSTANDARD TMDS_33} [get_ports {TMDS_0_tmds_data_p[0]}]
set_property -dict {PACKAGE_PIN K18 IOSTANDARD TMDS_33} [get_ports {TMDS_0_tmds_data_n[0]}]
set_property -dict {PACKAGE_PIN K19 IOSTANDARD TMDS_33} [get_ports {TMDS_0_tmds_data_p[1]}]
set_property -dict {PACKAGE_PIN J19 IOSTANDARD TMDS_33} [get_ports {TMDS_0_tmds_data_n[1]}]
set_property -dict {PACKAGE_PIN J18 IOSTANDARD TMDS_33} [get_ports {TMDS_0_tmds_data_p[2]}]
set_property -dict {PACKAGE_PIN H18 IOSTANDARD TMDS_33} [get_ports {TMDS_0_tmds_data_n[2]}]

# JY62 IMU on PS UART1 (EMIO), Pmod JB pin1 (W14) <- JY62 TX, pin2 (Y14) -> JY62 RX.
set_property -dict {PACKAGE_PIN W14 IOSTANDARD LVCMOS33 PULLUP true} [get_ports UART_1_rxd]
set_property -dict {PACKAGE_PIN Y14 IOSTANDARD LVCMOS33} [get_ports UART_1_txd]
