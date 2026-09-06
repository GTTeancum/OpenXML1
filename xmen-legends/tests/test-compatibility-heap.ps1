param([switch]$Diagnostics, [switch]$Trace)

$ErrorActionPreference = 'Stop'
if ($Trace -and !$Diagnostics) { throw 'Trace requires Diagnostics.' }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$recomp = Join-Path $root 'PS2Recomp'
$build = Join-Path $recomp 'out/xmen-final3-build'
$exe = (Resolve-Path -LiteralPath (Join-Path $build 'ps2xTest/Release/ps2x_tests.exe')).Path
$log = Join-Path $build 'heap-ownership-checks.log'
$identity = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
"SHA256=$identity" | Set-Content -LiteralPath $log
$cases = @(
    foreach ($fast in @($false, $true)) {
        foreach ($bestFit in @($false, $true)) {
            foreach ($inPlace in @($false, $true)) {
                foreach ($filter in @('public allocator dispatch',
                    'reallocation preserves ownership', 'best fit preserves a large',
                    'free frontier joins untouched tail', 'reuse free frontier before exhaustion',
                    'split free extent retains address order', 'bump alignment gap remains reusable')) {
                    [pscustomobject]@{ Fast = $fast; BestFit = $bestFit; InPlace = $inPlace; Filter = $filter }
                }
            }
        }
    }
    foreach ($filter in @('setup heap and allocator primitives',
        'allocator compatibility stubs', 'memalign stubs')) {
        [pscustomobject]@{ Fast = $false; BestFit = $false; InPlace = $false; Filter = $filter }
    }
)
foreach ($case in $cases) {
    $start = [Diagnostics.ProcessStartInfo]::new($exe)
    $start.WorkingDirectory = $recomp
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($key in @($start.Environment.Keys)) {
        if ($key.StartsWith('PS2X_', [StringComparison]::OrdinalIgnoreCase)) {
            [void]$start.Environment.Remove($key)
        }
    }
    $start.Environment['MINITEST_FILTER'] = $case.Filter
    if ($case.Fast) { $start.Environment['PS2X_BYPASS_XMEN_BRANCH_HOOKS'] = '1' }
    if ($case.BestFit) { $start.Environment['PS2X_GUEST_BUMP_BEST_FIT'] = '1' }
    if ($case.InPlace) { $start.Environment['PS2X_GUEST_BUMP_REALLOC'] = '1' }
    if ($Diagnostics) { $start.Environment['PS2X_GUEST_BUMP_DIAGNOSTICS'] = '1' }
    $traceCase = $Trace -and $case.Filter -eq 'public allocator dispatch'
    if ($traceCase) { $start.Environment['PS2X_GUEST_HEAP_TRACE'] = Join-Path $build 'heap-ownership-trace.bin' }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $started = $false
    try {
        $started = $process.Start()
        if (!$started) { throw 'Test process did not start.' }
        $process.PriorityClass = 'Normal'
        $process.ProcessorAffinity = [IntPtr]0xF
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(60000)) { throw "Heap test timed out: $($case.Filter)" }
        $label = "DIAGNOSTICS=$([bool]$Diagnostics) FAST=$($case.Fast) BEST_FIT=$($case.BestFit) IN_PLACE=$($case.InPlace) FILTER=$($case.Filter)"
        "$label EXIT=$($process.ExitCode)`n$($stdout.Result)`n$($stderr.Result)" |
            Add-Content -LiteralPath $log
        if ($process.ExitCode -ne 0 -or $stdout.Result -notmatch 'Total Tests: 1\b' -or
            $stdout.Result -notmatch 'Passed: 1\b' -or $stdout.Result -notmatch 'Failed: 0\b') {
            throw "Heap test failed or did not execute: $label; see $log"
        }
        if ($Diagnostics -and $case.Filter -eq 'public allocator dispatch' -and
            $stderr.Result -notmatch '\[heap:failed-call\] source=0x800000 target=0x200e10\b') {
            throw "Heap failure attribution missing: $label"
        }
        if ($Diagnostics -and $case.Filter -eq 'public allocator dispatch' -and
            $stderr.Result -notmatch '\[heap:call-chain\] depth=1 source=0x800200 target=0x800100\b') {
            throw 'Missing nested allocation caller attribution'
        }
        if (!$Diagnostics -and $stderr.Result -match '\[heap:(failed-call|live-size|call-chain)\]') {
            throw 'Disabled failure attribution emitted diagnostic records.'
        }
        if ([regex]::Matches($stderr.Result, '\[heap:live-size\]').Count -gt 16 -or
            [regex]::Matches($stderr.Result, '\[heap:failed-call\]').Count -gt 1 -or
            [regex]::Matches($stderr.Result, '\[heap:call-chain\]').Count -gt 12) {
            throw 'Heap failure attribution exceeded its output bound.'
        }
        "PASS $label"
        if ($traceCase) {
            $traceReport = & python (Join-Path $root 'xmen-legends/replay-heap-trace.py') (Join-Path $build 'heap-ownership-trace.bin')
            if ($LASTEXITCODE -ne 0) { throw "Heap event trace failed validation: $label" }
            $traceReport | Add-Content -LiteralPath $log
            "PASS trace ownership replay: $label"
        }
    } finally {
        if ($started -and !$process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
}
if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $identity) {
    throw 'Test image changed during validation.'
}
"PASS $($cases.Count) fresh-process heap checks; SHA256=$identity"
