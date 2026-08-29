param()

$ErrorActionPreference = 'Stop'

$workspace = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
$xmenRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$disc = [IO.Path]::GetFullPath((Join-Path $xmenRoot 'disc')).TrimEnd('\')
$recomp = [IO.Path]::GetFullPath((Join-Path $workspace 'PS2Recomp')).TrimEnd('\')

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
    (Join-Path $xmenRoot 'logs')
)

$removedDirectoryCount = 0
foreach ($candidate in $obsoleteDirectories) {
    $target = Assert-WorkspacePath $candidate
    if (Test-Path -LiteralPath $target -PathType Container) {
        Remove-Item -LiteralPath $target -Recurse -Force
        ++$removedDirectoryCount
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
$obsoleteFiles += Get-ChildItem -LiteralPath (Join-Path $recomp 'out') -File -Force |
    Where-Object { $_.Extension -eq '.log' }
$obsoleteFiles += Get-ChildItem -LiteralPath $recomp -File -Force |
    Where-Object { $_.Name -match '^probe.*\.log$' }
$obsoleteFiles = @($obsoleteFiles | Sort-Object FullName -Unique)

$removedFileBytes = [int64]0
foreach ($file in $obsoleteFiles) {
    $target = Assert-WorkspacePath $file.FullName
    $removedFileBytes += $file.Length
    Remove-Item -LiteralPath $target -Force
}

[pscustomobject]@{
    RemovedDirectories = $removedDirectoryCount
    RemovedFiles = $obsoleteFiles.Count
    RemovedFileGB = [math]::Round($removedFileBytes / 1GB, 3)
}
