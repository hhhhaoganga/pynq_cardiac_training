@echo off
rem Run Vitis HLS (hls/run_hls.tcl) with a clean Windows environment, from the project root.
rem   hw\..\hls\run_hls.bat   or   cmd /c hls\run_hls.bat
rem Why: Windows make reads "/dev/null" as <drive>:\dev\null. Vivado keeps writing its Patcher
rem log there, and csim then dies with "/dev/null:1: *** missing separator". Only a file that
rem looks like that log is removed; anything else stops the run so a human can look at it.
setlocal
if "%VITIS_HLS_BIN%"=="" set "VITIS_HLS_BIN=D:\Xilinx\Vitis_HLS\2024.2\bin"
cd /d "%~dp0.."
set "STRAY=%~d0\dev\null"
if exist "%STRAY%" (
    findstr /b /c:"[Patcher]" "%STRAY%" >nul && (
        del "%STRAY%" && echo removed stray Vivado log %STRAY%
    ) || (
        echo %STRAY% exists and is not a Vivado Patcher log; inspect it, then rename it. & exit /b 2
    )
)
rem vitis_hls.bat pipes through tee.exe, shipped in Vitis' gnuwin\bin, not in Vitis_HLS\bin.
if "%XILINX_GNUWIN%"=="" set "XILINX_GNUWIN=%VITIS_HLS_BIN%\..\..\..\Vitis\2024.2\gnuwin\bin"
set "PATH=%SystemRoot%\System32;%SystemRoot%;%SystemRoot%\System32\WindowsPowerShell\v1.0;%XILINX_GNUWIN%"
set "HOME=%USERPROFILE%"
set "SHELL="
set "MAKEFLAGS="
call "%VITIS_HLS_BIN%\vitis_hls.bat" -f hls/run_hls.tcl
exit /b %ERRORLEVEL%
