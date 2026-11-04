# Write the .img inside a PYNQ zip to a removable disk, then read it back and
# compare SHA-256. Must run elevated. Refuses to touch any disk that does not
# match the expected number, size and removable media type.
param(
    [Parameter(Mandatory = $true)][string]$ZipPath,
    [Parameter(Mandatory = $true)][int]$DiskNumber,
    [Parameter(Mandatory = $true)][long]$ExpectedSize,
    [Parameter(Mandatory = $true)][string]$Log
)
$ErrorActionPreference = 'Stop'
function Say($m) { $line = "[{0:HH:mm:ss}] {1}" -f (Get-Date), $m; Add-Content -Path $Log -Value $line; Write-Host $line }

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -TypeDefinition @'
using System; using System.IO; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class RawDisk {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string n, uint a, uint s, IntPtr sa, uint d, uint f, IntPtr t);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint c, IntPtr i, uint il, IntPtr o, uint ol, out uint r, IntPtr ov);
    public static SafeFileHandle Open(string path, bool write) {
        uint access = write ? 0xC0000000u : 0x80000000u;
        var h = CreateFile(path, access, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h.IsInvalid) throw new IOException("CreateFile " + path + " failed, error " + Marshal.GetLastWin32Error());
        return h;
    }
    // Returns the open handle; keep it alive so the volume stays locked/dismounted.
    public static SafeFileHandle LockDismount(string volume, out bool locked) {
        var h = Open(volume, true); uint r;
        locked = false;
        for (int i = 0; i < 10 && !locked; i++) {
            locked = DeviceIoControl(h, 0x00090018, IntPtr.Zero, 0, IntPtr.Zero, 0, out r, IntPtr.Zero);
            if (!locked) System.Threading.Thread.Sleep(300);
        }
        if (!DeviceIoControl(h, 0x00090020, IntPtr.Zero, 0, IntPtr.Zero, 0, out r, IntPtr.Zero))
            throw new IOException("dismount " + volume + " failed, error " + Marshal.GetLastWin32Error());
        return h;
    }
}
'@

Set-Content -Path $Log -Value ''
try {
    # ---- guard: exact target disk ---------------------------------------------
    $disk = Get-CimInstance Win32_DiskDrive | Where-Object Index -eq $DiskNumber
    if (-not $disk) { throw "disk $DiskNumber not found" }
    Say "target disk $DiskNumber model='$($disk.Model)' media='$($disk.MediaType)' size=$($disk.Size)"
    if ($disk.MediaType -notmatch 'Removable') { throw "disk $DiskNumber is not removable media; refusing" }
    if ([long]$disk.Size -ne $ExpectedSize) { throw "disk $DiskNumber size $($disk.Size) != expected $ExpectedSize; refusing" }
    $sys = (Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':'))).DiskNumber
    if ($sys -eq $DiskNumber) { throw "disk $DiskNumber is the system disk; refusing" }

    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    $entry = $zip.Entries | Where-Object { $_.Name -like '*.img' } | Select-Object -First 1
    if (-not $entry) { throw "no .img inside $ZipPath" }
    $len = $entry.Length
    Say "image $($entry.Name) bytes=$len"
    if ($len -gt [long]$disk.Size) { throw "image larger than disk" }
    if ($len % 512) { throw "image length not a multiple of 512" }

    # ---- lock and dismount every volume on the target disk ---------------------
    $locks = @()
    $letters = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue | Where-Object DriveLetter | ForEach-Object DriveLetter
    foreach ($l in $letters) {
        $locked = $false
        $locks += [RawDisk]::LockDismount("\\.\$($l):", [ref]$locked)
        Say "volume $($l): dismounted (locked=$locked)"
    }

    # ---- write ------------------------------------------------------------------
    # [long] so [Math]::Min(chunk, remaining) picks the Int64 overload (image > 2 GiB).
    [long]$chunk = 4MB
    $buf = New-Object byte[] $chunk
    $sha = [Security.Cryptography.SHA256]::Create()
    $h = [RawDisk]::Open("\\.\PhysicalDrive$DiskNumber", $true)
    $out = New-Object IO.FileStream($h, [IO.FileAccess]::ReadWrite, 1)
    $in = $entry.Open()
    $done = 0L; $next = 512MB; $t0 = Get-Date
    while ($done -lt $len) {
        $want = [int][Math]::Min($chunk, $len - $done)
        $got = 0
        while ($got -lt $want) {
            $n = $in.Read($buf, $got, $want - $got)
            if ($n -le 0) { throw "zip stream ended early at $($done + $got)" }
            $got += $n
        }
        $out.Write($buf, 0, $want)
        [void]$sha.TransformBlock($buf, 0, $want, $null, 0)
        $done += $want
        if ($done -ge $next) {
            $mbps = $done / 1MB / ((Get-Date) - $t0).TotalSeconds
            Say ("write {0:N0} / {1:N0} MB  ({2:N1} MB/s)" -f ($done / 1MB), ($len / 1MB), $mbps)
            $next += 512MB
        }
    }
    [void]$sha.TransformFinalBlock($buf, 0, 0)
    $imgHash = ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToLower()
    $out.Flush(); $out.Dispose(); $in.Dispose(); $zip.Dispose()
    Say "write done, image sha256=$imgHash"

    # ---- read back and verify ---------------------------------------------------
    $sha2 = [Security.Cryptography.SHA256]::Create()
    $h2 = [RawDisk]::Open("\\.\PhysicalDrive$DiskNumber", $false)
    $rd = New-Object IO.FileStream($h2, [IO.FileAccess]::Read, 1)
    $done = 0L; $next = 1GB
    while ($done -lt $len) {
        $want = [int][Math]::Min($chunk, $len - $done)
        $got = 0
        while ($got -lt $want) {
            $n = $rd.Read($buf, $got, $want - $got)
            if ($n -le 0) { throw "disk read ended early at $($done + $got)" }
            $got += $n
        }
        [void]$sha2.TransformBlock($buf, 0, $want, $null, 0)
        $done += $want
        if ($done -ge $next) { Say ("verify {0:N0} / {1:N0} MB" -f ($done / 1MB), ($len / 1MB)); $next += 1GB }
    }
    [void]$sha2.TransformFinalBlock($buf, 0, 0)
    $rd.Dispose()
    $diskHash = ([BitConverter]::ToString($sha2.Hash) -replace '-', '').ToLower()
    Say "readback sha256=$diskHash"
    foreach ($k in $locks) { $k.Dispose() }
    if ($diskHash -ne $imgHash) { throw "VERIFY MISMATCH" }
    Say "FLASH_OK"
}
catch {
    Say "FLASH_FAILED: $($_.Exception.Message)"
    exit 1
}
