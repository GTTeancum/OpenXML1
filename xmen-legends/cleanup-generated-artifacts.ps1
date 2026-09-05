param()

$ErrorActionPreference = 'Stop'

$workspace = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
$xmenRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$disc = [IO.Path]::GetFullPath((Join-Path $xmenRoot 'disc')).TrimEnd('\')
$recomp = [IO.Path]::GetFullPath((Join-Path $workspace 'PS2Recomp')).TrimEnd('\')
$activeBuild = [IO.Path]::GetFullPath(
    (Join-Path $recomp 'out\xmen-final3-build')
).TrimEnd('\')

function Assert-WorkspacePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not $full.StartsWith($workspace + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing path outside workspace: $full"
    }
    return $full
}

$obsoleteDirectories = @(
    (Join-Path $recomp 'out\xmen-build'),
    (Join-Path $recomp 'out\xmen-final2-build'),
    (Join-Path $recomp 'out\build'),
    (Join-Path $xmenRoot 'output'),
    (Join-Path $xmenRoot 'output_probe_315c20_v2'),
    (Join-Path $xmenRoot 'output_probe_315c20'),
    (Join-Path $xmenRoot 'output_mapped_final'),
    (Join-Path $xmenRoot 'output_mapped_final2'),
    (Join-Path $xmenRoot 'output_boot'),
    (Join-Path $xmenRoot 'output_mapped'),
    (Join-Path $xmenRoot 'output_mapped_clean'),
    (Join-Path $xmenRoot 'logs'),
    (Join-Path $xmenRoot '__pycache__')
)

$removedDirectoryCount = 0
foreach ($candidate in $obsoleteDirectories) {
    $target = Assert-WorkspacePath $candidate
    if (Test-Path -LiteralPath $target -PathType Container) {
        Remove-Item -LiteralPath $target -Recurse -Force
        ++$removedDirectoryCount
    }
}

$nativeBlockLimit = $null
$cachePath = Join-Path $activeBuild 'CMakeCache.txt'
if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
    $limitLine = Select-String -LiteralPath $cachePath `
        -Pattern '^PS2X_VU_NATIVE_BLOCK_LIMIT:STRING=([0-9]+)$' |
        Select-Object -First 1
    if ($limitLine) {
        $nativeBlockLimit = [int]$limitLine.Matches[0].Groups[1].Value
    }
}
if ($null -ne $nativeBlockLimit) {
    $runtimeBuild = Join-Path $activeBuild 'ps2xRuntime'
    $orphanedBlockDirectories = @(
        Get-ChildItem -LiteralPath $runtimeBuild -Directory -Force |
            Where-Object {
                $_.Name -match '^ps2_vu_native_direct_block_([0-9]+)\.dir$' -and
                [int]$Matches[1] -gt $nativeBlockLimit
            }
    )
    foreach ($directory in $orphanedBlockDirectories) {
        $target = Assert-WorkspacePath $directory.FullName
        Remove-Item -LiteralPath $target -Recurse -Force
        ++$removedDirectoryCount
    }
}

$activeRuntimePaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
foreach ($runtimeProcess in Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -like 'ps2EntryRunner*' }) {
    try {
        [void]$activeRuntimePaths.Add([IO.Path]::GetFullPath($runtimeProcess.Path))
    }
    catch {
        # A runtime can exit between enumeration and reading its executable path.
    }
}

$removedDebugDirectoryCount = 0
[int64]$removedDebugDirectoryBytes = 0
if (Test-Path -LiteralPath $activeBuild -PathType Container) {
    $debugDirectories = @(
        Get-ChildItem -LiteralPath $activeBuild -Recurse -Directory -Filter 'Debug' -Force |
            Sort-Object { $_.FullName.Length } -Descending
    )

    foreach ($directory in $debugDirectories) {
        $target = [IO.Path]::GetFullPath($directory.FullName).TrimEnd('\')
        if (-not $target.StartsWith(
                $activeBuild + '\',
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing inactive-config path outside active build: $target"
        }

        if (-not (Test-Path -LiteralPath $target -PathType Container)) {
            continue
        }

        $removedDebugDirectoryBytes += (
            Get-ChildItem -LiteralPath $target -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object Length -Sum
        ).Sum
        Remove-Item -LiteralPath $target -Recurse -Force
        ++$removedDebugDirectoryCount
    }
}

$retainManifest = Join-Path $xmenRoot 'probe-retain.txt'
$preservedProbeNumbers = @(
    if (Test-Path -LiteralPath $retainManifest -PathType Leaf) {
        Get-Content -LiteralPath $retainManifest |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '^\d+$' } |
            Sort-Object -Unique |
            ForEach-Object { [Regex]::Escape($_) }
    }
) -join '|'
$preservedProbePattern = if ($preservedProbeNumbers) {
    "^probe($preservedProbeNumbers)\."
} else {
    '(?!)'
}
$preservedFrames = '^gs-present-(1420|1450|1500)\.(ppm|png)$|^gs-present-vsync-'
$staleMediaCutoff = [DateTime]::UtcNow.AddHours(-12)
$generatedMediaExtensions = @('.bmp', '.jpeg', '.jpg', '.mp4', '.png', '.ppm', '.raw', '.wav')
$obsoleteFiles = @()
$obsoleteFiles += Get-ChildItem -LiteralPath $xmenRoot -File -Force |
    Where-Object {
        $_.Extension -eq '.log' -and
        $_.Name -notmatch $preservedProbePattern
    }
$obsoleteFiles += Get-ChildItem -LiteralPath $disc -File -Force |
    Where-Object { $_.Name -match '^(runner-)?probe.*\.log$' }
$obsoleteFiles += Get-ChildItem -LiteralPath $disc -File -Force |
    Where-Object {
        $_.Name -match '^(gs-|frame|probe).*(\.ppm|\.png|\.raw|\.wav|\.mp4)$' -and
        $_.Name -notmatch $preservedFrames
    }
$obsoleteFiles += Get-ChildItem -LiteralPath $xmenRoot -File -Force |
    Where-Object { $_.Name -match '^(frame|probe|gs-|runner).*(\.ppm|\.png|\.raw|\.wav|\.mp4)$' }
$assetInspect = Join-Path $xmenRoot 'asset-inspect'
if (Test-Path -LiteralPath $assetInspect -PathType Container) {
    $obsoleteFiles += Get-ChildItem -LiteralPath $assetInspect -Recurse -File -Force |
        Where-Object {
            $generatedMediaExtensions -contains $_.Extension.ToLowerInvariant() -and
            ($_.Name -match '^current-' -or
                ($_.LastWriteTimeUtc -lt $staleMediaCutoff -and
                    $_.Name -match '^(frame|probe|gs-)' -and
                    $_.Name -notmatch $preservedProbePattern))
        }
}
$analysisExtract = Join-Path $disc '.analysis-extract'
if (Test-Path -LiteralPath $analysisExtract -PathType Container) {
    $obsoleteFiles += Get-ChildItem -LiteralPath $analysisExtract -Recurse -File -Force |
        Where-Object {
            $_.LastWriteTimeUtc -lt $staleMediaCutoff -and
            $generatedMediaExtensions -contains $_.Extension.ToLowerInvariant()
        }
}
$obsoleteFiles += Get-ChildItem -LiteralPath $disc -File -Force |
    Where-Object {
        $_.LastWriteTimeUtc -lt $staleMediaCutoff -and
        $generatedMediaExtensions -contains $_.Extension.ToLowerInvariant() -and
        $_.Name -match '^xmen-'
    }
$obsoleteFiles += Get-ChildItem -LiteralPath (Join-Path $recomp 'out') -File -Force |
    Where-Object { $_.Extension -eq '.log' }
$obsoleteFiles += Get-ChildItem -LiteralPath $recomp -File -Force |
    Where-Object { $_.Name -match '^probe.*\.log$' }
$obsoleteFiles += Get-ChildItem -LiteralPath $recomp -File -Force |
    Where-Object {
        $generatedMediaExtensions -contains $_.Extension.ToLowerInvariant() -and
        $_.Name -match '^(frame|probe|gs-)'
    }
$obsoleteFiles += Get-ChildItem -LiteralPath $activeBuild -Recurse -File -Force |
    Where-Object {
        $_.Extension -eq '.log' -and
        $_.LastWriteTimeUtc -lt $staleMediaCutoff
    }
$testRelease = Join-Path $activeBuild 'ps2xTest\Release'
if (Test-Path -LiteralPath $testRelease -PathType Container) {
    $obsoleteFiles += Get-ChildItem -LiteralPath $testRelease -File -Force |
        Where-Object {
            $_.Name -match '^ps2x_tests\.(block[0-9]+|flags-base|ready-base|flagretire-base|blockexit-base)\.exe$'
        }
}
if ($null -ne $nativeBlockLimit) {
    $runtimeBuild = Join-Path $activeBuild 'ps2xRuntime'
    $obsoleteFiles += Get-ChildItem -LiteralPath $runtimeBuild -File -Force |
        Where-Object {
            $_.Name -match '^vu_native_direct_block_([0-9]+)\.cpp$' -and
            [int]$Matches[1] -gt $nativeBlockLimit
        }
}
$activeRelease = Join-Path $activeBuild 'ps2xRuntime\Release'
if (Test-Path -LiteralPath $activeRelease -PathType Container) {
    $obsoleteFiles += Get-ChildItem -LiteralPath $activeRelease -File -Force |
        Where-Object {
            $_.Name -match '^ps2EntryRunner\.(pre|old|bak|probe).*\.exe$' -or
            ($_.Name -eq 'ps2EntryRunner.next.exe' -and
                $_.LastWriteTimeUtc -lt $staleMediaCutoff -and
                -not $activeRuntimePaths.Contains([IO.Path]::GetFullPath($_.FullName)))
        }
}
if (Test-Path -LiteralPath $activeBuild -PathType Container) {
    $obsoleteFiles += Get-ChildItem -LiteralPath $activeBuild -Recurse -File -Force |
        Where-Object {
            ($_.Name -like 'ps2EntryRunner.next.*' -or
                $_.Name -like 'ps2EntryRunner.candidate.*') -and
            $_.Extension -ne '.exe'
        }
}
$protectedGeneratedNames = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
foreach ($name in @(
    'ps2EntryRunner.next.exe.exe',
    'ps2x_tests.vu-baseline.exe',
    'ps2x_tests.vu-retire.exe',
    'vu_native_words.inc',
    'vu_native_batch_152.obj',
    'gs-present-first-nonblack-0.ppm'
)) {
    [void]$protectedGeneratedNames.Add($name)
}
$obsoleteFiles = @(
    $obsoleteFiles |
        Where-Object { -not $protectedGeneratedNames.Contains($_.Name) } |
        Sort-Object FullName -Unique
)

$removedFileBytes = [int64]0
foreach ($file in $obsoleteFiles) {
    $target = Assert-WorkspacePath $file.FullName
    $removedFileBytes += $file.Length
    Remove-Item -LiteralPath $target -Force
}

[pscustomobject]@{
    RemovedDirectories = $removedDirectoryCount
    RemovedDebugDirectories = $removedDebugDirectoryCount
    RemovedDebugGB = [math]::Round($removedDebugDirectoryBytes / 1GB, 3)
    RemovedFiles = $obsoleteFiles.Count
    RemovedFileGB = [math]::Round($removedFileBytes / 1GB, 3)
}
