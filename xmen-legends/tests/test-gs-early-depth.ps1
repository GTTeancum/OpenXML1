param([string]$TestExecutable = '')
$ErrorActionPreference = 'Stop'
if (-not $TestExecutable) {
    $workspace = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $TestExecutable = Join-Path $workspace 'PS2Recomp\out\xmen-final3-build\ps2xTest\Release\ps2x_tests.exe'
}
$savedEnvironment = @{}
Get-ChildItem Env:PS2X_* | ForEach-Object { $savedEnvironment[$_.Name] = $_.Value }
$previousFilter = $env:MINITEST_FILTER
$process = Get-Process -Id $PID
$previousPriority = $process.PriorityClass
$previousAffinity = $process.ProcessorAffinity
try {
    Get-ChildItem Env:PS2X_* | Remove-Item
    $process.PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal
    $process.ProcessorAffinity = [IntPtr]0xF
    $env:MINITEST_FILTER = 'GS early depth'
    $digests = @()
    foreach ($enabled in @($false, $true)) {
        if ($enabled) { Remove-Item Env:PS2X_GS_DISABLE_EARLY_DEPTH -ErrorAction SilentlyContinue }
        else { $env:PS2X_GS_DISABLE_EARLY_DEPTH = '1' }
        $output = (& $TestExecutable 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { throw "Depth tests failed (enabled=$enabled): $output" }
        if ($output -notmatch '\[gs-depth-differential\] cases=128 hash=([0-9a-f]{16})') {
            throw "Missing differential workload output: $output"
        }
        $digests += $Matches[1]
        "EARLY_DEPTH=$enabled VRAM_DIGEST=$($digests[-1])"
    }
    if ($digests[0] -ne $digests[1]) { throw 'Early depth changed the graphics-memory result.' }
    'PASS early-depth comparisons and complete-VRAM differential workload'
}
finally {
    Get-ChildItem Env:PS2X_* | Remove-Item
    foreach ($entry in $savedEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
    $env:MINITEST_FILTER = $previousFilter
    $process.PriorityClass = $previousPriority
    $process.ProcessorAffinity = $previousAffinity
}
