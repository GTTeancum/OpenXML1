param(
    [Parameter(Mandatory = $true)][string]$BaselineExecutable,
    [string]$CandidateExecutable = '',
    [ValidateRange(3, 15)][int]$Rounds = 7,
    [ValidateRange(1, 2048)][int]$Repeats = 1024,
    [switch]$BaselinePairsOnly
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$checkout = Join-Path $root 'PS2Recomp'
if (-not $CandidateExecutable) {
    $CandidateExecutable = Join-Path $checkout 'out\xmen-final3-build\ps2xTest\Release\ps2x_tests.exe'
}
$executables = @{
    baseline = (Resolve-Path -LiteralPath $BaselineExecutable).Path
    candidate = (Resolve-Path -LiteralPath $CandidateExecutable).Path
}
$capture = Join-Path $PSScriptRoot 'disc\vu-replay.bin'
$identities = @{}
foreach ($path in @($executables.baseline, $executables.candidate, $capture)) {
    $identities[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}
$results = [Collections.Generic.List[object]]::new()
for ($round = 0; $round -lt $Rounds; ++$round) {
    $order = if ($round % 2 -eq 0) { @('baseline', 'candidate') } else { @('candidate', 'baseline') }
    foreach ($mode in $order) {
        $blocks = $mode -eq 'candidate' -or -not $BaselinePairsOnly
        $start = [Diagnostics.ProcessStartInfo]::new($executables[$mode])
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
        $start.Environment['PS2X_VU_REPLAY_PAIRS'] = '1'
        if ($blocks) { $start.Environment['PS2X_VU_REPLAY_BLOCKS'] = '1' }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        $started = $false
        try {
            $started = $process.Start()
            if (-not $started) { throw 'Replay did not start.' }
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            $process.PriorityClass = 'Normal'
            $process.ProcessorAffinity = [IntPtr]0xF
            if (-not $process.WaitForExit(180000)) { throw 'Replay exceeded three minutes.' }
            $output = $stdout.GetAwaiter().GetResult()
            $errors = $stderr.GetAwaiter().GetResult()
            if ($process.ExitCode -ne 0) { throw "Replay failed: $output`n$errors" }
            $match = [regex]::Match($output,
                '\[vu-replay:result\] cases=(\d+) iterations=(\d+) cycles=(\d+) execute-ms=([0-9.]+) digest=([0-9a-f]+) error=\r?\n')
            if (-not $match.Success -or $match.Groups[1].Value -ne '32' -or
                [uint64]$match.Groups[2].Value -ne 32 * $Repeats -or
                [uint64]$match.Groups[3].Value -ne 40803 * $Repeats -or
                $match.Groups[5].Value -ne '75d4ff1e67bbbc4c') {
                throw "Replay identity, cycle count, or exact result changed: $output`n$errors"
            }
            $coverage = [regex]::Match($errors,
                '\[vu-replay:block-coverage\] attempted=(\d+) executed=(\d+) pairs=(\d+)')
            if ($blocks -and (-not $coverage.Success -or [uint64]$coverage.Groups[3].Value -eq 0)) {
                throw 'Requested native blocks did not execute.'
            }
            if (-not $blocks -and $coverage.Success) { throw 'Unexpected native block execution.' }
            $entry = [pscustomobject]@{
                Round = $round + 1
                Mode = $mode
                ExecuteMs = [double]::Parse($match.Groups[4].Value, [Globalization.CultureInfo]::InvariantCulture)
                BlockPairs = $(if ($blocks) { [uint64]$coverage.Groups[3].Value } else { 0 })
                Digest = $match.Groups[5].Value
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
        throw "Benchmark input changed: $path"
    }
}
$medians = @{}
foreach ($mode in @('baseline', 'candidate')) {
    $times = @($results | Where-Object Mode -eq $mode | Sort-Object ExecuteMs | ForEach-Object ExecuteMs)
    $medians[$mode] = ($times[[int][Math]::Floor(($times.Count - 1) / 2)] +
        $times[[int][Math]::Floor($times.Count / 2)]) / 2
}
$wins = @($results | Group-Object Round | Where-Object {
    ($_.Group | Where-Object Mode -eq 'candidate').ExecuteMs -lt
        ($_.Group | Where-Object Mode -eq 'baseline').ExecuteMs
}).Count
$report = [pscustomobject]@{
    RecordedAtUtc = [DateTime]::UtcNow.ToString('o')
    Rounds = $Rounds
    Repeats = $Repeats
    BaselinePairsOnly = [bool]$BaselinePairsOnly
    Identities = $identities
    BaselineMedianMs = $medians.baseline
    CandidateMedianMs = $medians.candidate
    ReductionPercent = 100 * (1 - $medians.candidate / $medians.baseline)
    CandidateWins = $wins
    Results = $results
}
$report | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath (Join-Path $PSScriptRoot 'disc\vu-block-comparison.json')
$report | Select-Object Rounds, Repeats, BaselineMedianMs, CandidateMedianMs,
    ReductionPercent, CandidateWins | Format-List
