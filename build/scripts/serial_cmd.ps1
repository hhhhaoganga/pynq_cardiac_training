# Run one shell command on the PYNQ serial console (COM6) and print its output.
# Answers a sudo password prompt with the default PYNQ password.
param(
    [Parameter(Mandatory = $true)][string]$Cmd,
    [string]$Port = 'COM6',
    [int]$TimeoutSec = 30,
    [string]$Password = 'xilinx'
)
$p = New-Object System.IO.Ports.SerialPort $Port, 115200, 'None', 8, 'One'
$p.DtrEnable = $false
$p.RtsEnable = $false
$p.Open()
try {
    Start-Sleep -Milliseconds 200
    [void]$p.ReadExisting()
    $marker = "__END_$([guid]::NewGuid().ToString('N').Substring(0, 8))__"
    $p.Write("$Cmd; echo $marker`r")
    $sb = New-Object Text.StringBuilder
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $answered = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        [void]$sb.Append($p.ReadExisting())
        $s = $sb.ToString()
        if (-not $answered -and $s -match '\[sudo\] password for') {
            $p.Write("$Password`r")
            $answered = $true
        }
        # The marker appears once in the echoed command line and once when printed.
        if (([regex]::Matches($s, [regex]::Escape($marker))).Count -ge 2) { break }
    }
    $out = $sb.ToString() -replace "`r", ''
    $lines = $out -split "`n" | Where-Object { $_ -notmatch [regex]::Escape($marker) -and $_ -notmatch '^\[sudo\] password' }
    ($lines -join "`n").Trim()
    if (([regex]::Matches($sb.ToString(), [regex]::Escape($marker))).Count -lt 2) { "SERIAL_TIMEOUT" }
}
finally {
    $p.Close()
}
