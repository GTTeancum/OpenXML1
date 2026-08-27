param(
    [int]$Probe,
    [int]$TimeoutSeconds = 120,
    [string]$WatchStart,
    [string]$WatchSize = '0x80',
    [string]$Filter = 'dynamic-k'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$disc = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'disc')).Path
$exe = (Resolve-Path -LiteralPath (
    Join-Path $root 'PS2Recomp\out\xmen-final3-build\ps2xRuntime\Release\ps2EntryRunner.exe'
)).Path
$outLog = Join-Path $PSScriptRoot "probe$Probe.out.log"
$errLog = Join-Path $PSScriptRoot "probe$Probe.filtered.err.log"

foreach ($log in @($outLog, $errLog)) {
    if (Test-Path -LiteralPath $log) {
        Remove-Item -LiteralPath $log -Force
    }
}

$env:PS2X_WATCH_START_K = $WatchStart
$env:PS2X_WATCH_SIZE_K = $WatchSize

$command = ('""{0}" ".\SLUS_206.56" 2>&1 1>"{1}" | "{2}\System32\findstr.exe" /L /C:"{3}" >"{4}""' -f
    $exe, $outLog, $env:SystemRoot, $Filter, $errLog)
$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $env:ComSpec
$startInfo.WorkingDirectory = $disc
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.Arguments = "/d /s /c $command"

$process = [System.Diagnostics.Process]::Start($startInfo)
$process.PriorityClass = 'BelowNormal'
"PID=$($process.Id)"

$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
while ([DateTime]::UtcNow -lt $deadline) {
    $process.Refresh()
    if ($process.HasExited) {
        "EXITED CODE=$($process.ExitCode)"
        exit 0
    }
    Start-Sleep -Seconds 1
}

$process.Refresh()
if (-not $process.HasExited) {
    & "$env:SystemRoot\System32\taskkill.exe" /PID $process.Id /T /F | Out-Null
    $process.WaitForExit()
}

'TIMEOUT'
