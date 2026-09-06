$ErrorActionPreference = 'Stop'
$reporter = Join-Path $PSScriptRoot '../summarize-vu-coverage.ps1'
$first = '[vu:coverage-window] begin=1100 end=1132 native=800 interpreted=200 block-pairs=600 attempted=90 executed=80'
$second = '[vu:coverage-window] begin=1132 end=1388 native=200 interpreted=800 block-pairs=100 attempted=60 executed=20'
$result = & $reporter -Lines @('unrelated log output', $first, $second) -RequireGameplaySpan
if ($result.NativePairs -ne 1000 -or $result.InterpretedPairs -ne 1000 -or
    $result.BlockPairs -ne 700 -or $result.NativePercent -ne 50 -or
    $result.BlockPercent -ne 35 -or $result.Windows.Count -ne 2 -or
    $result.Begin -ne 1100 -or $result.End -ne 1388) {
    throw 'Coverage sums or percentages are incorrect.'
}
foreach ($invalid in @(
    @{ Lines = @($first); Error = 'Incomplete gameplay' },
    @{ Lines = @('unrelated'); Error = 'No nonempty' },
    @{ Lines = @($first.Replace('native=800', 'native=bad')); Error = 'Malformed' },
    @{ Lines = @($first.Replace('block-pairs=600', 'block-pairs=801')); Error = 'Invalid' },
    @{ Lines = @($first.Replace('executed=80', 'executed=91')); Error = 'Invalid' },
    @{ Lines = @($first.Replace('end=1132', 'end=1101')); Error = 'Invalid' },
    @{ Lines = @($first, $second.Replace('begin=1132', 'begin=1133')); Error = 'Noncontiguous' },
    @{ Lines = @($first, $first); Error = 'Noncontiguous' },
    @{ Lines = @($first.Replace('native=800 interpreted=200 block-pairs=600', 'native=0 interpreted=0 block-pairs=0')); Error = 'No nonempty' }
)) {
    $rejected = $false
    try { $null = & $reporter -Lines $invalid.Lines -RequireGameplaySpan }
    catch {
        if ($_.Exception.Message -notlike "*$($invalid.Error)*") { throw }
        $rejected = $true
    }
    if (!$rejected) { throw "Accepted invalid coverage: $($invalid.Error)" }
}
'PASS VU coverage aggregation, span validation, and malformed/reset interval rejection'
