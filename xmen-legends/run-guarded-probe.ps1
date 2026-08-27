param(
    [Parameter(Mandatory = $true)]
    [int]$Probe,

    [int]$TimeoutSeconds = 220,

    [switch]$ContinueAfterNonBlack,

    [switch]$ContinueAfterMissing
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$disc = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'disc')).Path.TrimEnd('\')
$expectedDisc = [System.IO.Path]::GetFullPath(
    (Join-Path $root 'xmen-legends\disc')
).TrimEnd('\')

if (-not $disc.Equals($expectedDisc, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Unexpected disc path: $disc"
}

Get-ChildItem -LiteralPath $disc -Filter 'gs-present-*.ppm' -File | ForEach-Object {
    $parent = [System.IO.Path]::GetDirectoryName($_.FullName).TrimEnd('\')
    if (-not $parent.Equals($disc, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove unexpected path: $($_.FullName)"
    }

    Remove-Item -LiteralPath $_.FullName -Force
}

$outLog = Join-Path $PSScriptRoot "probe$Probe.out.log"
$errLog = Join-Path $PSScriptRoot "probe$Probe.err.log"
foreach ($log in @($outLog, $errLog)) {
    if (Test-Path -LiteralPath $log) {
        Remove-Item -LiteralPath $log -Force
    }
}

$exe = Join-Path $root 'PS2Recomp\out\xmen-final3-build\ps2xRuntime\Release\ps2EntryRunner.exe'
$process = Start-Process `
    -FilePath $exe `
    -WorkingDirectory $disc `
    -ArgumentList '.\SLUS_206.56' `
    -RedirectStandardOutput $outLog `
    -RedirectStandardError $errLog `
    -WindowStyle Hidden `
    -PassThru

try {
    $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
}
catch {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    throw "Unable to lower probe process priority: $($_.Exception.Message)"
}

function Stop-ProbeProcess {
    $process.Refresh()
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        Wait-Process -Id $process.Id -ErrorAction SilentlyContinue
    }
}

"PID=$($process.Id)"

$knownBlack = '00C470B9619BB218650748690CD9DE4A6D885656DEAF8D573A1468B394F3DB4A'
$seen = @{}
$seenMissing = @{}
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

while ([DateTime]::UtcNow -lt $deadline) {
    $process.Refresh()

    foreach ($file in Get-ChildItem -LiteralPath $disc -Filter 'gs-present-*.ppm' -File |
        Sort-Object LastWriteTimeUtc) {
        if ($seen.ContainsKey($file.FullName)) {
            continue
        }

        try {
            $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        }
        catch [System.IO.IOException] {
            # The runtime may still be writing a newly-created framebuffer dump.
            continue
        }

        $seen[$file.FullName] = $hash
        "PPM=$($file.Name) SHA256=$hash"

        if ($hash -ne $knownBlack) {
            "NONBLACK PID=$($process.Id) FILE=$($file.FullName) SHA256=$hash"
            if (-not $ContinueAfterNonBlack) {
                Stop-ProbeProcess
                exit 42
            }
        }
    }

    if (Test-Path -LiteralPath $errLog) {
        $missing = Select-String -LiteralPath $errLog -Pattern 'guest-branch:missing-target' |
            Select-Object -Last 1
        if ($missing -and -not $seenMissing.ContainsKey($missing.Line)) {
            $seenMissing[$missing.Line] = $true
            "MISSING PID=$($process.Id) LINE=$($missing.Line)"
            if (-not $ContinueAfterMissing) {
                Stop-ProbeProcess
                exit 43
            }
        }
    }

    if ($process.HasExited) {
        "EXITED CODE=$($process.ExitCode) PPM_COUNT=$($seen.Count)"
        exit 0
    }

    Start-Sleep -Milliseconds 500
}

Stop-ProbeProcess

"TIMEOUT PPM_COUNT=$($seen.Count)"
