param()

$ErrorActionPreference = 'Stop'
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
                    'reallocation preserves ownership', 'best fit preserves a large')) {
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
        $label = "FAST=$($case.Fast) BEST_FIT=$($case.BestFit) IN_PLACE=$($case.InPlace) FILTER=$($case.Filter)"
        "$label EXIT=$($process.ExitCode)`n$($stdout.Result)`n$($stderr.Result)" |
            Add-Content -LiteralPath $log
        if ($process.ExitCode -ne 0 -or $stdout.Result -notmatch 'Total Tests: 1\b' -or
            $stdout.Result -notmatch 'Passed: 1\b' -or $stdout.Result -notmatch 'Failed: 0\b') {
            throw "Heap test failed or did not execute: $label; see $log"
        }
        "PASS $label"
    } finally {
        if ($started -and !$process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
}
if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $identity) {
    throw 'Test image changed during validation.'
}
"PASS $($cases.Count) fresh-process heap checks; SHA256=$identity"
