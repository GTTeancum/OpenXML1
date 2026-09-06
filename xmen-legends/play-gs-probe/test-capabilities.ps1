param([switch]$Offscreen, [switch]$Adapter, [switch]$Benchmark)
$ErrorActionPreference = 'Stop'
if ($Offscreen -and $Adapter) { throw 'Choose Offscreen or Adapter, not both.' }
if ($Benchmark -and !$Adapter) { throw 'Benchmark requires Adapter.' }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$build = Join-Path $root '.tools/Play-VU/out/vu-probe/play-gs-probe'
$target = if ($Offscreen) { 'play_gs_offscreen' } else { 'play_gs_capabilities' }
$logName = if ($Offscreen) { 'offscreen.log' } else { 'capabilities.log' }
$marker = if ($Offscreen) { '\[gs-gpu:offscreen\] matched=20480 cases=5 rendering-tested=1 windows=0' } else { '\[gs-gpu:capabilities\].*rendering-tested=0 windows=0' }
if ($Adapter) {
    $target = 'play_gs_adapter_test'
    $logName = 'adapter.log'
    $marker = '\[gs-adapter:passed\] cases=12 windows=0'
}
$exe = (Resolve-Path -LiteralPath (Join-Path $build "Release/$target.exe")).Path
$si = [Diagnostics.ProcessStartInfo]::new($exe)
foreach ($name in @($si.Environment.Keys)) {
    if ($name.StartsWith('PS2X_', [StringComparison]::OrdinalIgnoreCase)) { [void]$si.Environment.Remove($name) }
}
if ($Adapter) { $si.Environment['PS2X_GS_PREPARED_TEXTURE'] = '1' }
if ($Benchmark) { $si.ArgumentList.Add('--benchmark'); $logName = 'adapter-benchmark.log' }
$si.WorkingDirectory = $build
$si.UseShellExecute = $false
$si.CreateNoWindow = $true
$si.RedirectStandardOutput = $true
$si.RedirectStandardError = $true
$process = [Diagnostics.Process]::new()
$process.StartInfo = $si
$started = $false
try {
    $started = $process.Start()
    if (!$started) { throw 'GPU capability check did not start.' }
    $process.PriorityClass = 'Normal'
    $process.ProcessorAffinity = [IntPtr]0xF
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (!$process.WaitForExit(60000)) { throw 'GPU capability check timed out.' }
    $output = $stdout.GetAwaiter().GetResult()
    $errors = $stderr.GetAwaiter().GetResult()
    $identity = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    $log = "SHA=$identity`n$output`n$errors"
    $log | Set-Content -LiteralPath (Join-Path $build $logName)
    $log
    if ($process.ExitCode -ne 0 -or $output -notmatch $marker) {
        throw "GPU check $target failed; exit=$($process.ExitCode)."
    }
    if ($Benchmark -and $output -notmatch '\[gs-adapter:benchmark-passed\] pairs=6 gameplay-fps=unmeasured') {
        throw 'GPU benchmark did not complete every comparison.'
    }
} finally {
    if ($started -and !$process.HasExited) { $process.Kill(); $process.WaitForExit() }
    $process.Dispose()
}
