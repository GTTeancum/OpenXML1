param(
    [int]$Probe = 1556,
    [int]$TimeoutSeconds = 180,
    [string]$WatchStart = '',
    [string]$WatchSize = '',
    [switch]$CaptureStderr
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$disc = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'disc')).Path
$exe = (Resolve-Path -LiteralPath (
    Join-Path $root 'PS2Recomp\out\xmen-final3-build\ps2xRuntime\Release\ps2EntryRunner.exe'
)).Path
$outLog = Join-Path $PSScriptRoot "probe$Probe.out.log"
$errLog = Join-Path $PSScriptRoot "probe$Probe.err.log"

foreach ($log in @($outLog, $errLog)) {
    if (Test-Path -LiteralPath $log) {
        Remove-Item -LiteralPath $log -Force
    }
}

if ($WatchStart) {
    $env:PS2X_WATCH_START_K = $WatchStart
}
if ($WatchSize) {
    $env:PS2X_WATCH_SIZE_K = $WatchSize
}

$stderrTarget = if ($CaptureStderr) { $errLog } else { 'NUL' }

$process = Start-Process `
    -FilePath $exe `
    -WorkingDirectory $disc `
    -ArgumentList '.\SLUS_206.56' `
    -RedirectStandardOutput $outLog `
    -RedirectStandardError $stderrTarget `
    -WindowStyle Hidden `
    -PassThru

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
    Stop-Process -Id $process.Id -Force
    Wait-Process -Id $process.Id -ErrorAction SilentlyContinue
}

'TIMEOUT'
