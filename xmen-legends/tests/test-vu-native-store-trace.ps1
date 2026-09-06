param([string]$Executable = '', [string]$CapturePath = '')

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../../PS2Recomp')).Path
if (!$Executable) { $Executable = Join-Path $root 'out/xmen-final3-build/ps2xTest/Release/ps2x_tests.exe' }
if (!$CapturePath) { $CapturePath = Join-Path $PSScriptRoot '../disc/vu-replay.bin' }
$Executable = (Resolve-Path -LiteralPath $Executable).Path
$CapturePath = (Resolve-Path -LiteralPath $CapturePath).Path
$word = $null
foreach ($mode in @('address', 'word')) {
    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.WorkingDirectory = $root
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($key in @($start.Environment.Keys)) {
        if ($key.StartsWith('PS2X_', [StringComparison]::OrdinalIgnoreCase)) {
            [void]$start.Environment.Remove($key)
        }
    }
    $start.Environment['MINITEST_FILTER'] = 'recorded VU slices'
    $start.Environment['PS2X_VU_REPLAY_FILE'] = $CapturePath
    $start.Environment['PS2X_VU_REPLAY_REPEATS'] = '1'
    $start.Environment['PS2X_VU_REPLAY_PAIRS'] = '1'
    $start.Environment['PS2X_VU_REPLAY_BLOCKS'] = '1'
    $start.Environment['PS2X_TRACE_VU_STORE_MAX_TRACES'] = '8'
    if ($mode -eq 'address') {
        $start.Environment['PS2X_TRACE_VU_STORE_ADDRESS_FIRST'] = '0'
        $start.Environment['PS2X_TRACE_VU_STORE_ADDRESS_LAST'] = '16383'
    } else {
        $start.Environment['PS2X_TRACE_VU_STORE_WORD0'] = "0x$word"
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $started = $false
    try {
        $started = $process.Start()
        if (!$started) { throw 'Store trace replay did not start.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.PriorityClass = 'Normal'
        $process.ProcessorAffinity = [IntPtr]0xF
        if (!$process.WaitForExit(180000)) { throw 'Store trace replay timed out.' }
        $output = $stdout.GetAwaiter().GetResult()
        $errors = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or $output -notmatch 'Total Tests: 1\b' -or
            $output -notmatch 'Passed: 1\b' -or $output -notmatch '\[vu-replay:result\].* error=\r?\n') {
            throw "Store trace replay failed in $mode mode (exit $($process.ExitCode))."
        }
        $traces = [regex]::Matches($errors,
            '\[xmen-vu1:target-store\][^\r\n]*words=([0-9a-f]{8}),([0-9a-f]{8}),([0-9a-f]{8}),([0-9a-f]{8})')
        if ($traces.Count -eq 0 -or $traces.Count -gt 8) { throw "Missing or unbounded $mode store trace." }
        if (($output + $errors) -notmatch '\[vu-replay:block-coverage\] attempted=0 executed=0 pairs=0\b') {
            throw "Direct native blocks must yield to $mode store tracing."
        }
        if ($mode -eq 'address') { $word = $traces[0].Groups[1].Value }
        else {
            foreach ($trace in $traces) {
                if ($trace.Groups[1].Value -cne $word) { throw 'Store word filter was not respected.' }
            }
        }
        "PASS native-store tracing mode=$mode entries=$($traces.Count) blocks=0 replay=exact"
    } finally {
        if ($started -and !$process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
}
