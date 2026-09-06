param([string]$Executable = '')

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../../PS2Recomp')).Path
if (!$Executable) { $Executable = Join-Path $root 'out/xmen-final3-build/ps2xTest/Release/ps2x_tests.exe' }
$Executable = (Resolve-Path -LiteralPath $Executable).Path
foreach ($budget in @(3, 40)) {
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
    $start.Environment['MINITEST_FILTER'] = 'VU budget trace records only issued instruction snapshots'
    $start.Environment['PS2X_XMEN_DIAGNOSTICS'] = '1'
    $start.Environment['PS2X_VU_TEST_TRACE_BUDGET'] = [string]$budget
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $started = $false
    try {
        $started = $process.Start()
        if (!$started) { throw 'Trace test did not start.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.PriorityClass = 'Normal'
        $process.ProcessorAffinity = [IntPtr]0xF
        if (!$process.WaitForExit(30000)) { throw 'Trace test exceeded 30 seconds.' }
        $output = $stdout.GetAwaiter().GetResult()
        $errors = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or $output -notmatch 'Total Tests: 1\b' -or
            $output -notmatch 'Passed: 1\b') { throw "Trace fixture failed: $output $errors" }
        $count = [Math]::Min($budget, 32)
        $headers = [regex]::Matches($errors, '\[vu1:budget-trace\] entries=(\d+)')
        $pairs = [regex]::Matches($errors,
            '\[vu1:budget-pair\] pc=0x([0-9a-f]+) lower=([0-9a-f]+) upper=([0-9a-f]+) vi=([^\r\n]+)')
        if ($headers.Count -ne 1 -or [int]$headers[0].Groups[1].Value -ne $count -or $pairs.Count -ne $count) {
            throw "Unexpected trace length for budget ${budget}: $errors"
        }
        $expectedVi = (@('123') + (@('0') * 13) + @('-17')) -join ','
        for ($index = 0; $index -lt $count; ++$index) {
            $pair = $pairs[$index]
            $pc = [Convert]::ToUInt32($pair.Groups[1].Value, 16)
            if ($pc -ne ($budget - $count + $index) * 8 -or
                $pair.Groups[2].Value -ne '8000033c' -or $pair.Groups[3].Value -ne '000002ff' -or
                $pair.Groups[4].Value -cne $expectedVi) {
                throw "Incorrect or uninitialized trace entry: $($pair.Value)"
            }
        }
        "PASS VU budget trace budget=$budget retained=$count PCs/opcodes/signed-registers exact"
    } finally {
        if ($started -and !$process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
}
