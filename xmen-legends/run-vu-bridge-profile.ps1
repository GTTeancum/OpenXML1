param(
    [ValidateSet('Original', 'Spread')][string]$Capture = 'Original',
    [ValidateRange(1, 2048)][int]$Repeats = 512,
    [switch]$Profile,
    [switch]$Sample,
    [switch]$Retry,
    [switch]$Reference
)
$ErrorActionPreference = 'Stop'
if ($Reference -and $Profile) { throw 'Bridge profiling requires compiled replay.' }
if ($Reference -and $Retry) { throw 'Compiled retry requires compiled replay.' }
$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root 'PS2Recomp/out/xmen-final3-build'
$exe = (Resolve-Path (Join-Path $build 'ps2xTest/Release/ps2x_tests.exe')).Path
$file = if ($Capture -eq 'Original') { 'vu-replay.bin' } else { 'vu-replay-spread.bin' }
$digest = if ($Capture -eq 'Original') { '75d4ff1e67bbbc4c' } else { '6c13c7a10069aeef' }
$record = (Resolve-Path (Join-Path $PSScriptRoot "disc/$file")).Path
$mode = if ($Profile) { 'profile' } elseif ($Sample) { 'sample' } elseif ($Reference) { 'reference' } else { 'hybrid' }
if ($Retry) { $mode = "retry-$mode" }
$logPath = Join-Path $build "vu-bridge-$($Capture.ToLowerInvariant())-$mode.log"
$si = [Diagnostics.ProcessStartInfo]::new($exe)
$si.WorkingDirectory = Join-Path $root 'PS2Recomp'
$si.UseShellExecute = $false
$si.CreateNoWindow = $true
$si.RedirectStandardOutput = $true
$si.RedirectStandardError = $true
foreach ($name in @($si.Environment.Keys)) {
    if ($name.StartsWith('PS2X_', [StringComparison]::OrdinalIgnoreCase)) { [void]$si.Environment.Remove($name) }
}
$si.Environment['MINITEST_FILTER'] = 'recorded VU slices reproduce state memory and graphics packets'
$si.Environment['PS2X_VU_REPLAY_FILE'] = $record
$si.Environment['PS2X_VU_REPLAY_REPEATS'] = "$Repeats"
$si.Environment['PS2X_VU_REPLAY_PAIRS'] = '1'
$si.Environment['PS2X_VU_REPLAY_BLOCKS'] = '1'
if (!$Reference) { $si.Environment['PS2X_VU_REPLAY_COMPILED'] = '1' }
if ($Profile) { $si.Environment['PS2X_VU_BRIDGE_PROFILE'] = '1' }
if ($Sample) { $si.Environment['PS2X_VU_REPLAY_PROFILE'] = '1' }
if ($Retry) { $si.Environment['PS2X_VU_COMPILED_RETRY'] = '1' }
$process = [Diagnostics.Process]::new()
$process.StartInfo = $si
$started = $false
$identity = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
try {
    $started = $process.Start()
    if (!$started) { throw 'Replay test did not start.' }
    $process.PriorityClass = 'Normal'
    $process.ProcessorAffinity = [IntPtr]0xF
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (!$process.WaitForExit(120000)) { throw 'Replay test timed out.' }
    $output = $stdout.GetAwaiter().GetResult()
    $errors = $stderr.GetAwaiter().GetResult()
    "SHA=$identity CAPTURE=$Capture REPEATS=$Repeats PROFILE=$Profile SAMPLE=$Sample RETRY=$Retry REFERENCE=$Reference`n$output`n$errors" |
        Set-Content -LiteralPath $logPath
    $resultPattern = "(?m)^\[vu-replay:result\] cases=32 iterations=\d+ cycles=\d+ execute-ms=([\d.]+) digest=$digest error=\r?$"
    if ($process.ExitCode -ne 0 -or $output -notmatch $resultPattern) {
        throw "Replay validation failed; see $logPath"
    }
    $executionMs = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
    $stages = @([regex]::Matches($errors, '(?m)^\[vu:bridge-profile\] stage=([a-z-]+) calls=(\d+) ns=(\d+)\r?$') |
        ForEach-Object { [pscustomobject]@{Stage=$_.Groups[1].Value; Calls=[long]$_.Groups[2].Value; Milliseconds=[double]$_.Groups[3].Value / 1e6} })
    if ($Profile -and (@($stages.Stage | Sort-Object -Unique).Count -ne 7 -or @($stages | Where-Object Calls -eq 0).Count)) {
        throw 'Bridge profile did not execute every measured stage.'
    }
    if (!$Profile -and $stages.Count) { throw 'Disabled bridge profiling produced diagnostics.' }
    if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $identity) { throw 'Test executable changed during replay.' }
    [pscustomobject]@{Capture=$Capture; Sha256=$identity; Profile=[bool]$Profile; Sample=[bool]$Sample;
        Reference=[bool]$Reference; Retry=[bool]$Retry; Verified=$true; WarmReplayMs=$executionMs; Stages=$stages; Log=$logPath} | ConvertTo-Json -Depth 4
} finally {
    if ($started -and !$process.HasExited) { $process.Kill(); $process.WaitForExit() }
    $process.Dispose()
}
