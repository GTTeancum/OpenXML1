param(
    [Parameter(Mandatory = $true)]
    [int]$Probe,

    [ValidateSet('Debug', 'Release', 'RelWithDebInfo', 'MinSizeRel')]
    [string]$Config = 'Release',

    [int]$TimeoutSeconds = 220,

    [switch]$ContinueAfterNonBlack,

    [ValidateRange(-1, [int]::MaxValue)]
    [int]$StopAfterPresent = -1,

    [switch]$ContinueAfterMissing,

    [switch]$CleanupOnly,

    [ValidateSet('Restore', 'Bypass', 'MovieOnly', 'MovieWait', 'TitleGameplayFirst', 'GameplayDemo', 'GameplayMap', 'GameplayMapNoMovie', 'GameplayFirst')]
    [string]$StartupMovieMode = 'Restore',

    [ValidateRange(1, 100)]
    [int]$RetainProbeCount = 8,

    [ValidateRange(1, 100)]
    [int]$RetainBuildCount = 8,

    [ValidateRange(1, 720)]
    [int]$MaxGeneratedImageAgeHours = 12,

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

    $artifactRoots = @($PSScriptRoot, $disc)
    $allowedParents = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($artifactRoot in $artifactRoots) {
        [void]$allowedParents.Add(
            [System.IO.Path]::GetFullPath($artifactRoot).TrimEnd('\')
        )
    }

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
        foreach ($artifactRoot in $artifactRoots) {
            Get-ChildItem -LiteralPath $artifactRoot -File -Filter 'probe*' |
                Where-Object { $_.Name -match '^probe(?<id>\d+).*\.(?:log|zip|ppm|png)$' } |
                ForEach-Object {
                    [pscustomobject]@{
                        File = $_
                        ProbeId = [int]$Matches.id
                    }
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
        if (-not $allowedParents.Contains($parent)) {
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

function Remove-StaleBuildArtifacts {
    $artifactRoots = @($PSScriptRoot, $disc)
    $allowedParents = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($artifactRoot in $artifactRoots) {
        [void]$allowedParents.Add(
            [System.IO.Path]::GetFullPath($artifactRoot).TrimEnd('\')
        )
    }

    $trackedNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($trackedPath in git -C $root ls-files -- 'xmen-legends/*') {
        [void]$trackedNames.Add([System.IO.Path]::GetFileName($trackedPath))
    }

    $artifacts = @(
        foreach ($artifactRoot in $artifactRoots) {
            Get-ChildItem -LiteralPath $artifactRoot -File |
                Where-Object {
                    $_.Name -match '^(?:build|configure|recomp|tests).*?(?<id>\d{3,}).*\.(?:log|err|exit)$'
                } |
                ForEach-Object {
                    [pscustomobject]@{
                        File = $_
                        BuildId = [int]$Matches.id
                    }
                }
        }
    )

    $keepBuildIds = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($buildId in $artifacts.BuildId | Sort-Object -Descending -Unique |
        Select-Object -First $RetainBuildCount) {
        [void]$keepBuildIds.Add($buildId)
    }

    $recentCutoff = [DateTime]::UtcNow.AddMinutes(-10)
    foreach ($artifact in $artifacts) {
        if ($keepBuildIds.Contains($artifact.BuildId) -or
            $trackedNames.Contains($artifact.File.Name) -or
            $artifact.File.LastWriteTimeUtc -ge $recentCutoff) {
            continue
        }

        $parent = [System.IO.Path]::GetDirectoryName($artifact.File.FullName).TrimEnd('\')
        if (-not $allowedParents.Contains($parent)) {
            throw "Refusing to remove unexpected path: $($artifact.File.FullName)"
        }
        Remove-Item -LiteralPath $artifact.File.FullName -Force
    }

    $releaseDirectory = Join-Path $root 'PS2Recomp\out\xmen-final3-build\ps2xRuntime\Release'
    if (Test-Path -LiteralPath $releaseDirectory -PathType Container) {
        Get-ChildItem -LiteralPath $releaseDirectory -File -Filter 'ps2EntryRunner.exe.*' |
            Where-Object { $_.Name -ne 'ps2EntryRunner.exe' } |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -Skip 1 |
            ForEach-Object {
                $parent = [System.IO.Path]::GetDirectoryName($_.FullName).TrimEnd('\')
                if (-not $parent.Equals($releaseDirectory.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "Refusing to remove unexpected path: $($_.FullName)"
                }
                Remove-Item -LiteralPath $_.FullName -Force
            }
    }
}

function Remove-StaleGeneratedImages {
    $captureRoot = Join-Path $PSScriptRoot 'asset-inspect'
    $cutoffUtc = [DateTime]::UtcNow.AddHours(-$MaxGeneratedImageAgeHours)
    $trackedPaths = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($trackedPath in git -C $root ls-files -- '*.png' '*.ppm') {
        [void]$trackedPaths.Add(
            [System.IO.Path]::GetFullPath((Join-Path $root $trackedPath))
        )
    }

    $scopes = @(
        [pscustomobject]@{
            Root = $captureRoot
            Recurse = $false
            NamePattern = '^probe\d+.*\.(?:ppm|png)$'
        }
        [pscustomobject]@{
            Root = $root
            Recurse = $false
            NamePattern = '^gs-present-.*\.(?:ppm|png)$'
        }
        [pscustomobject]@{
            Root = Join-Path $root 'PS2Recomp\out'
            Recurse = $true
            NamePattern = '^gs-present-.*\.(?:ppm|png)$'
        }
    )

    $removedCount = 0
    [long]$removedBytes = 0
    foreach ($scope in $scopes) {
        if (-not (Test-Path -LiteralPath $scope.Root -PathType Container)) {
            continue
        }

        $resolvedScopeRoot = [System.IO.Path]::GetFullPath($scope.Root).TrimEnd('\')
        $childArgs = @{
            LiteralPath = $resolvedScopeRoot
            File = $true
        }
        if ($scope.Recurse) {
            $childArgs.Recurse = $true
        }

        Get-ChildItem @childArgs |
            Where-Object {
                $_.Name -match $scope.NamePattern -and
                $_.LastWriteTimeUtc -lt $cutoffUtc
            } |
            ForEach-Object {
                $target = [System.IO.Path]::GetFullPath($_.FullName)
                if (-not ($target.StartsWith(
                        $resolvedScopeRoot + [System.IO.Path]::DirectorySeparatorChar,
                        [System.StringComparison]::OrdinalIgnoreCase) -or
                    $target.Equals(
                        $resolvedScopeRoot,
                        [System.StringComparison]::OrdinalIgnoreCase))) {
                    throw "Refusing to remove unexpected image path: $target"
                }
                if (-not $trackedPaths.Contains($target)) {
                    $removedBytes += $_.Length
                    Remove-Item -LiteralPath $target -Force
                    $removedCount++
                }
            }
    }

    if ($removedCount -gt 0) {
        "IMAGE_CLEANUP FILES=$removedCount MIB=$([math]::Round($removedBytes / 1MB, 1)) MAX_AGE_HOURS=$MaxGeneratedImageAgeHours"
    }
}

Remove-StaleProbeArtifacts -CurrentProbe $Probe
Remove-StaleBuildArtifacts
Remove-StaleGeneratedImages

foreach ($framebufferRoot in @($disc, (Join-Path $root 'PS2Recomp'))) {
    $resolvedFramebufferRoot = [System.IO.Path]::GetFullPath($framebufferRoot).TrimEnd('\')
    Get-ChildItem -LiteralPath $resolvedFramebufferRoot -File |
        Where-Object {
            $_.Name -like 'gs-present-*.ppm' -or
            $_.Name -like 'gs-present-*.png'
        } |
        ForEach-Object {
            $parent = [System.IO.Path]::GetDirectoryName($_.FullName).TrimEnd('\')
            if (-not $parent.Equals(
                    $resolvedFramebufferRoot,
                    [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to remove unexpected path: $($_.FullName)"
            }

            Remove-Item -LiteralPath $_.FullName -Force
        }
}

if ($CleanupOnly) {
    exit 0
}

$startupMovieScript = Join-Path $PSScriptRoot 'dev-overrides\set-startup-movie-bypass.ps1'
if ($StartupMovieMode -ne 'Restore') {
    & $startupMovieScript -Mode $StartupMovieMode
}

try {

$outLog = Join-Path $PSScriptRoot "probe$Probe.out.log"
$errLog = Join-Path $PSScriptRoot "probe$Probe.err.log"
foreach ($log in @($outLog, $errLog)) {
    if (Test-Path -LiteralPath $log) {
        Remove-Item -LiteralPath $log -Force
    }
}

if ($StopAfterPresent -ge 0) {
    $env:PS2X_DUMP_PRESENT_RANGE = "$StopAfterPresent-$StopAfterPresent"
}

$exe = Join-Path $root "PS2Recomp\out\xmen-final3-build\ps2xRuntime\$Config\ps2EntryRunner.exe"
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
            $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
        }
        catch {
            if ($_.Exception.Message -match 'being used by another process|cannot access the file') {
                # The runtime may still be writing a newly-created framebuffer dump.
                continue
            }

            throw
        }

        $seen[$file.FullName] = $hash
        "PPM=$($file.Name) SHA256=$hash"

        if ($StopAfterPresent -ge 0 -and
            $file.Name -eq "gs-present-$StopAfterPresent.ppm") {
            "TARGET_PRESENT PID=$($process.Id) INDEX=$StopAfterPresent FILE=$($file.FullName) SHA256=$hash"
            Stop-ProbeProcess
            exit 45
        }

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
}
finally {
    if ($StartupMovieMode -ne 'Restore') {
        & $startupMovieScript -Mode Restore
    }
}
