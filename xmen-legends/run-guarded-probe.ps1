param(
    [Parameter(Mandatory = $true)]
    [int]$Probe,

    [int]$TimeoutSeconds = 220,

    [switch]$ContinueAfterNonBlack,

    [switch]$ContinueAfterMissing,

    [switch]$CleanupOnly,

    [ValidateRange(1, 100)]
    [int]$RetainProbeCount = 8,

    [ValidateRange(16, 4096)]
    [int]$MaxCombinedLogMiB = 128
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

function Remove-StaleProbeArtifacts {
    param([int]$CurrentProbe)

    $pinnedProbeIds = [System.Collections.Generic.HashSet[int]]::new()
    $retentionPath = Join-Path $PSScriptRoot 'probe-retain.txt'
    if (Test-Path -LiteralPath $retentionPath) {
        foreach ($line in Get-Content -LiteralPath $retentionPath) {
            $value = $line.Trim()
            if (-not $value -or $value.StartsWith('#')) {
                continue
            }

            $probeId = 0
            if (-not [int]::TryParse($value, [ref]$probeId)) {
                throw "Invalid probe ID in ${retentionPath}: $value"
            }

            [void]$pinnedProbeIds.Add($probeId)
        }
    }

    $trackedNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($trackedPath in git -C $root ls-files -- 'xmen-legends/probe*') {
        [void]$trackedNames.Add([System.IO.Path]::GetFileName($trackedPath))
    }

    $artifacts = @(
        Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter 'probe*' |
            Where-Object { $_.Name -match '^probe(?<id>\d+).*\.(?:log|zip|ppm|png)$' } |
            ForEach-Object {
                [pscustomobject]@{
                    File = $_
                    ProbeId = [int]$Matches.id
                }
            }
    )

    $keepProbeIds = [System.Collections.Generic.HashSet[int]]::new()
    [void]$keepProbeIds.Add($CurrentProbe)
    foreach ($probeId in $pinnedProbeIds) {
        [void]$keepProbeIds.Add($probeId)
    }
    foreach ($probeId in $artifacts.ProbeId | Sort-Object -Descending -Unique |
        Select-Object -First $RetainProbeCount) {
        [void]$keepProbeIds.Add($probeId)
    }

    $removedCount = 0
    [long]$removedBytes = 0
    foreach ($artifact in $artifacts) {
        if ($keepProbeIds.Contains($artifact.ProbeId) -or
            $trackedNames.Contains($artifact.File.Name)) {
            continue
        }

        $parent = [System.IO.Path]::GetDirectoryName($artifact.File.FullName).TrimEnd('\')
        if (-not $parent.Equals($PSScriptRoot.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove unexpected path: $($artifact.File.FullName)"
        }

        $removedBytes += $artifact.File.Length
        Remove-Item -LiteralPath $artifact.File.FullName -Force
        $removedCount++
    }

    if ($removedCount -gt 0) {
        "CLEANUP FILES=$removedCount MIB=$([math]::Round($removedBytes / 1MB, 1))"
    }
}

Remove-StaleProbeArtifacts -CurrentProbe $Probe

if ($CleanupOnly) {
    exit 0
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
    $process.ProcessorAffinity = [IntPtr]0xF
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
$maxCombinedLogBytes = [long]$MaxCombinedLogMiB * 1MB

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

    [long]$combinedLogBytes = 0
    foreach ($log in @($outLog, $errLog)) {
        if (Test-Path -LiteralPath $log) {
            $combinedLogBytes += (Get-Item -LiteralPath $log).Length
        }
    }
    if ($combinedLogBytes -gt $maxCombinedLogBytes) {
        "LOG_LIMIT PID=$($process.Id) MIB=$([math]::Round($combinedLogBytes / 1MB, 1))"
        Stop-ProbeProcess
        exit 44
    }

    if ($process.HasExited) {
        "EXITED CODE=$($process.ExitCode) PPM_COUNT=$($seen.Count)"
        exit 0
    }

    Start-Sleep -Milliseconds 500
}

Stop-ProbeProcess

"TIMEOUT PPM_COUNT=$($seen.Count)"
