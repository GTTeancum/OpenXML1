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
    $output
    $errors
    'SHA256=' + (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    if ($process.ExitCode -ne 0) { throw "VU probe failed: exit $($process.ExitCode)" }
    if (!$output.Contains('[play-vu] 21 unmodified upstream tests passed') -or
        ([regex]::Matches($output, '\[play-vu:budget\]')).Count -ne 4 -or
        !$output.Contains('[play-vu:xgkick] callbacks=1')) {
        throw 'Probe did not complete the expected test and contract checks.'
    }
} finally {
    if ($started -and !$process.HasExited) { $process.Kill(); $process.WaitForExit() }
    $process.Dispose()
}
