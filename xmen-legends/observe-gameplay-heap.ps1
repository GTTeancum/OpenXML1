param(
    [Parameter(Mandatory)][int]$ProcessId,
    [ValidateRange(1, 600)][int]$TimeoutSeconds = 300,
    [switch]$AllocationSnapshot
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$expectedPath = [IO.Path]::GetFullPath((Join-Path $root 'PS2Recomp/out/xmen-final3-build/ps2xRuntime/Release/ps2EntryRunner.candidate.exe'))
# RVAs verified against this executable's allocator disassembly, not the stale PDB.
$expectedHash = '7F5AE058415EFEB2812512F708DE7B2E85F8801E9556BB06E360E6F5AA298408'
$process = Get-Process -Id $ProcessId
if ($process.Path -ine $expectedPath -or (Get-FileHash -LiteralPath $process.Path).Hash -ne $expectedHash) {
    throw 'Heap observer only supports the explicitly verified candidate image.'
}
$base = $process.MainModule.BaseAddress.ToInt64()
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class XmenHeapReader {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, int id);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool ReadProcessMemory(IntPtr process, IntPtr address, byte[] data, UIntPtr length, out UIntPtr read);
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr handle);
}
'@
$handle = [XmenHeapReader]::OpenProcess(0x410, $false, $ProcessId)
if ($handle -eq [IntPtr]::Zero) { throw 'Read-only process access failed.' }
function Read-Bytes([long]$Address, [int]$Size) {
    $bytes = [byte[]]::new($Size)
    $read = [UIntPtr]::Zero
    if (![XmenHeapReader]::ReadProcessMemory($handle, [IntPtr]$Address, $bytes, [UIntPtr]$Size, [ref]$read) -or $read.ToUInt64() -ne $Size) {
        throw 'Process memory read failed.'
    }
    return ,$bytes
}
$samples = [Collections.Generic.List[object]]::new()
$allocations = @()
$skipped = 0
$watch = [Diagnostics.Stopwatch]::StartNew()
try {
    $instruction = Read-Bytes ($base + 0x25d11) 7
    if ([Convert]::ToHexString($instruction) -ne '448B0D18DBCC09') { throw 'Allocator instruction signature mismatch.' }
    if ($AllocationSnapshot) {
        # MSVC's list-backed map, verified by allocator insertion code. Read only.
        $map = Read-Bytes ($base + 0xb0ff220) 24
        $head = [BitConverter]::ToInt64($map, 8)
        $count = [BitConverter]::ToInt64($map, 16)
        if ($count -lt 1 -or $count -gt 65536 -or !$head) { throw 'Unexpected allocation map layout.' }
        $node = [BitConverter]::ToInt64((Read-Bytes $head 16), 0)
        $entries = [Collections.Generic.List[object]]::new()
        for ($n = 0; $n -lt $count; ++$n) {
            if ($n % 256 -eq 0 -and $watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw 'Allocation snapshot timed out.' }
            if (!$node -or $node -eq $head) { throw 'Allocation list changed during snapshot.' }
            $entry = Read-Bytes $node 24
            $address = [BitConverter]::ToUInt32($entry, 16)
            $bytes = [BitConverter]::ToUInt32($entry, 20)
            if ($address -lt 0x900000 -or [long]$address + $bytes -gt 0x1800000) { throw 'Unexpected allocation entry.' }
            $entries.Add([pscustomobject]@{Address=$address; Bytes=$bytes})
            $node = [BitConverter]::ToInt64($entry, 0)
        }
        if ($node -ne $head -or [Convert]::ToHexString($map) -ne [Convert]::ToHexString((Read-Bytes ($base + 0xb0ff220) 24))) {
            throw 'Allocation map changed during snapshot.'
        }
        $allocations = @($entries.ToArray() | Sort-Object Bytes -Descending)
        $allocations | Select-Object -First 20 | Format-Table
        "ALLOCATION_COUNT=$count TOTAL_BYTES=$(($allocations | Measure-Object Bytes -Sum).Sum)"
    }
    while (!$process.HasExited -and $watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        try {
            $bump = [BitConverter]::ToUInt32((Read-Bytes ($base + 0x9cf3830) 4), 0)
            $vector = Read-Bytes ($base + 0xb100c20) 24
            $first = [BitConverter]::ToInt64($vector, 0)
            $last = [BitConverter]::ToInt64($vector, 8)
            $capacity = [BitConverter]::ToInt64($vector, 16)
            $size = $last - $first
            if ($bump -lt 0x900000 -or $bump -ge 0x1800000 -or $size -lt 0 -or $size -gt 65536 -or $size % 8 -ne 0 -or $last -gt $capacity) {
                throw 'Changing or unexpected allocator layout.'
            }
            $blocks = if ($size) { Read-Bytes $first $size } else { [byte[]]::new(0) }
            $again = Read-Bytes ($base + 0xb100c20) 24
            if ([Convert]::ToHexString($vector) -ne [Convert]::ToHexString($again)) { throw 'Free-list changed during sampling.' }
            $free = 0L
            $largest = 0L
            for ($i = 0; $i -lt $size; $i += 8) {
                $address = [BitConverter]::ToUInt32($blocks, $i)
                $bytes = [BitConverter]::ToUInt32($blocks, $i + 4)
                if ($address -lt 0x900000 -or [long]$address + $bytes -gt $bump) { throw 'Free-list changed during sampling.' }
                $free += $bytes
                $largest = [Math]::Max($largest, $bytes)
            }
            $sample = [pscustomobject]@{
                Seconds = [Math]::Round($watch.Elapsed.TotalSeconds, 3)
                Bump = $bump; TailBytes = 0x1800000 - $bump
                FreeBlocks = $size / 8; FreeBytes = $free; LargestFreeBlock = $largest
            }
            $samples.Add($sample)
            if ($samples.Count % 10 -eq 1) { $sample | ConvertTo-Json -Compress }
            if ($AllocationSnapshot) { break }
        } catch {
            if (!$process.HasExited) { ++$skipped }
        }
        Start-Sleep -Seconds 1
        $process.Refresh()
    }
} finally {
    [void][XmenHeapReader]::CloseHandle($handle)
    $report = [ordered]@{
        Sha256 = $expectedHash; ProcessId = $ProcessId; ReadOnly = $true
        Method = 'Unsuspended read-only sampling; concurrent changes can invalidate individual samples. Not an allocation trace or FPS benchmark.'
        SkippedSamples = $skipped; Samples = @($samples.ToArray()); Allocations = $allocations
    }
    $name = if ($AllocationSnapshot) { 'gameplay-heap-allocations.json' } else { 'gameplay-heap-observation.json' }
    $report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $root "PS2Recomp/out/xmen-final3-build/$name")
    $process.Dispose()
}
if (!$samples.Count -and !$allocations.Count) { throw 'No valid heap sample or allocation snapshot was collected.' }
