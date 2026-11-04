@echo off
rem Run hw/build_overlay.tcl with a clean Windows env. git-bash/MSYS leaks break Vivado:
rem   PATH with mingw tcl86.dll -> "Could not create slave interpreter"; SHELL=/bin/bash.exe -> make fails.
rem Set VIVADO_BIN to your install, e.g. D:\Xilinx\Vivado\2024.2\bin
if "%VIVADO_BIN%"=="" set "VIVADO_BIN=D:\Xilinx\Vivado\2024.2\bin"
set "PATH=C:\Windows\System32;C:\Windows;C:\Windows\System32\WindowsPowerShell\v1.0"
set "HOME=%USERPROFILE%"
set SHELL=
set MAKEFLAGS=
cd /d "%~dp0.."
call "%VIVADO_BIN%\vivado.bat" -mode batch -nojournal -log build_vivado.log -source hw/build_overlay.tcl
