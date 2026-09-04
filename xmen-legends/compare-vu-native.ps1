param(
    [ValidateRange(3, 21)][int]$Pairs = 9,
    [ValidateRange(1, 2048)][int]$Repeats = 1024
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$checkout = Join-Path $root 'PS2Recomp'
$exe = Join-Path $checkout 'out\xmen-final3-build\ps2xTest\Release\ps2x_tests.exe'
$capture = Join-Path $PSScriptRoot 'disc\vu-replay.bin'
$module = Join-Path $checkout 'out\xmen-final3-build\ps2xRuntime\Release\ps2_vu_native_upper.dll'
$identities = @{}
foreach ($path in @($exe, $capture, $module)) {
    $identities[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}
$results = [System.Collections.Generic.List[object]]::new()
for ($pair = 0; $pair -lt $Pairs; $pair++) {
    $modes = if ($pair % 2 -eq 0) { @('interpreted', 'native') } else { @('native', 'interpreted') }
    foreach ($mode in $modes) {
        $start = [System.Diagnostics.ProcessStartInfo]::new($exe)
        $start.WorkingDirectory = $checkout
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($key in @($start.Environment.Keys)) {
            if ($key.StartsWith('PS2X_', [StringComparison]::OrdinalIgnoreCase)) {
                $start.Environment.Remove($key) | Out-Null
            }
        }
        $start.Environment['MINITEST_FILTER'] = 'recorded VU slices'
        $start.Environment['PS2X_VU_REPLAY_FILE'] = $capture
        $start.Environment['PS2X_VU_REPLAY_REPEATS'] = [string]$Repeats
        if ($mode -eq 'native') { $start.Environment['PS2X_VU_REPLAY_NATIVE'] = '1' }
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $start
        $started = $false
        try {
            if (-not $process.Start()) { throw 'Replay process did not start.' }
            $started = $true
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            $process.PriorityClass = 'Normal'
            $process.ProcessorAffinity = [IntPtr]0xF
            if (-not $process.WaitForExit(180000)) { throw 'Replay exceeded its three-minute limit.' }
            $output = $stdout.GetAwaiter().GetResult()
            $errors = $stderr.GetAwaiter().GetResult()
            if ($process.ExitCode -ne 0) { throw "Replay failed: $output`n$errors" }
            $timing = [regex]::Match($output, '\[vu-replay:result\] cases=(\d+) iterations=(\d+) cycles=(\d+) execute-ms=([0-9.]+) digest=([0-9a-f]+) error=\r?\n')
            $coverage = [regex]::Match($output, '\[vu-replay:upper-coverage\] native=(\d+) interpreted=(\d+)')
            if (-not $timing.Success -or -not $coverage.Success) { throw "Missing replay result: $output" }
            if ($timing.Groups[1].Value -ne '32' -or $timing.Groups[5].Value -ne '75d4ff1e67bbbc4c' -or
                [uint64]$timing.Groups[2].Value -ne 32 * $Repeats) { throw 'Unexpected capture identity or repetition count.' }
            $native = [uint64]$coverage.Groups[1].Value
            if (($mode -eq 'native' -and $native -eq 0) -or ($mode -eq 'interpreted' -and $native -ne 0)) {
                throw 'Replay did not use the requested execution path.'
            }
            $entry = [pscustomobject]@{
                Pair = $pair + 1
                Mode = $mode
                ExecuteMs = [double]::Parse($timing.Groups[4].Value, [System.Globalization.CultureInfo]::InvariantCulture)
                NativeUpper = $native
                InterpretedUpper = [uint64]$coverage.Groups[2].Value
                Digest = $timing.Groups[5].Value
            }
            $results.Add($entry)
            $entry | Format-Table -HideTableHeaders
        }
        finally {
            if ($started -and -not $process.HasExited) {
                $process.Kill($true)
                $process.WaitForExit()
            }
            $process.Dispose()
        }
    }
}
foreach ($path in $identities.Keys) {
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $identities[$path]) {
        throw "Benchmark input changed during comparison: $path"
    }
}
$medians = @{}
foreach ($mode in @('interpreted', 'native')) {
    $times = @($results | Where-Object Mode -eq $mode | Sort-Object ExecuteMs | ForEach-Object ExecuteMs)
    $medians[$mode] = ($times[[int][Math]::Floor(($times.Count - 1) / 2)] + $times[[int][Math]::Floor($times.Count / 2)]) / 2
}
$report = [pscustomobject]@{
    Pairs = $Pairs
    Repeats = $Repeats
    Identities = $identities
    Medians = $medians
    ExecutionTimeReductionPercent = 100 * (1 - $medians.native / $medians.interpreted)
    Results = $results
}
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'disc\vu-native-comparison.json')
$report | Select-Object Pairs, Repeats, Medians, ExecutionTimeReductionPercent | Format-List
