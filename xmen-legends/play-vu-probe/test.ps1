param([string]$ReplayPath, [ValidateRange(0, 63)][Nullable[int]]$MemoryTraceCase)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$build = Join-Path $root '.tools/Play-VU/out/vu-probe'
$exe = (Resolve-Path -LiteralPath (Join-Path $build 'Release/play_vu_probe.exe')).Path
$start = [Diagnostics.ProcessStartInfo]::new($exe)
$start.WorkingDirectory = $build
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
if ($ReplayPath) { $start.ArgumentList.Add((Resolve-Path -LiteralPath $ReplayPath).Path) }
if ($null -ne $MemoryTraceCase) {
    if (!$ReplayPath) { throw 'Memory tracing requires a replay path.' }
    $start.Environment['PS2X_VU_REPLAY_MEMORY_TRACE_CASE'] = [string]$MemoryTraceCase
} else { [void]$start.Environment.Remove('PS2X_VU_REPLAY_MEMORY_TRACE_CASE') }
$process = [Diagnostics.Process]::new()
$process.StartInfo = $start
$started = $false
try {
    $started = $process.Start()
    if (!$started) { throw 'VU probe did not start.' }
    $process.PriorityClass = 'Normal'
    $process.ProcessorAffinity = [IntPtr]0xF
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (!$process.WaitForExit(120000)) { throw 'VU probe exceeded its two-minute limit.' }
    $output = $stdout.GetAwaiter().GetResult()
    $errors = $stderr.GetAwaiter().GetResult()
    $output -split '\r?\n'
    $errors
    'SHA256=' + (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    if ($process.ExitCode -ne 0) { throw "VU probe failed: exit $($process.ExitCode)" }
    if (!$output.Contains('[play-vu:synthetic-abi] xmm-corrupt-mask=0x0 output-errors=0')) {
        throw 'Public synthetic Windows register-preservation regression did not pass.'
    }
    if (([regex]::Matches($output, '\[play-vu:transfer-test\] mode=\d+ passed=1')).Count -ne 8) {
        throw 'Compiled transfer-timing regressions did not pass.'
    }
    if (!$output.Contains('[play-vu:pending-import-test] passed=1 delayed-read-cycles=6')) {
        throw 'Pending VU-state import regression did not pass.'
    }
    if (!$output.Contains('[play-vu:scalar-import-test] passed=1 vf=3f000000 q=3f000000 p=3e800000')) {
        throw 'Idle scalar pipeline import regression did not pass.'
    }
    if (!$output.Contains('[play-vu:drain-test] passed=1 cycle=19 status=0e2 known-mask=0e3')) {
        throw 'Completed control-state drain regression did not pass.'
    }
    if (!$output.Contains('[play-vu:session-test] passed=1 detached=1 fp-restored=1 cache-replaced=1 rejection-recovered=1')) {
        throw 'Detached compiled session regressions did not pass.'
    }
    if (!$output.Contains('[play-vu:typed-bridge-test] passed=1 pending-import=1 staged-export=1 partial-flags=1 runtime-accepted=0')) {
        throw 'Typed runtime bridge regressions did not pass.'
    }
    if (([regex]::Matches($output, '\[play-vu:scalar-flags\] case=\d+ passed=1')).Count -ne 13 -or
        !$output.Contains('[play-vu:scalar-flag-contracts] passed=1 same-cycle-order=1 pending-tail=1 late-budget-rejection=1')) {
        throw 'Timed scalar flag regressions did not pass.'
    }
    if (([regex]::Matches($output, '\[play-vu:sticky-reset\] reset=[0-9a-f]+ later=[01] passed=1')).Count -ne 8) {
        throw 'Arithmetic sticky-reset ordering regressions did not pass.'
    }
    if (([regex]::Matches($output, '\[play-vu:wait-test\] mode=\d+ passed=1')).Count -ne 7) {
        throw 'Compiled XGKICK wait regressions did not pass.'
    }
    if ($ReplayPath) {
        if (!$output.Contains('[play-vu:replay-summary]') -or
            !$output.Contains('repeatable=1 compatibility-accepted=0')) {
            throw 'Replay diagnostic did not complete. This is not a compatibility pass.'
        }
    } elseif (!$output.Contains('[play-vu] 21 unmodified upstream tests passed') -or
        ([regex]::Matches($output, '\[play-vu:budget\]')).Count -ne 4 -or
        !$output.Contains('[play-vu:xgkick] callbacks=1')) {
        throw 'Probe did not complete the expected test and contract checks.'
    }
} finally {
    if ($started -and !$process.HasExited) { $process.Kill(); $process.WaitForExit() }
    $process.Dispose()
}
