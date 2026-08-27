param(
    [ValidateSet("Bypass", "Restore")]
    [string]$Mode = "Bypass"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$movieDirectory = [System.IO.Path]::GetFullPath(
    (Join-Path $root "disc\MOVIES\NTSC\I\1"))
$enabledPath = [System.IO.Path]::GetFullPath(
    (Join-Path $movieDirectory "I107.SFD"))
$disabledPath = [System.IO.Path]::GetFullPath(
    (Join-Path $movieDirectory "I107.SFD.dev-disabled"))
$directoryPrefix = $movieDirectory.TrimEnd('\') + '\'

foreach ($path in @($enabledPath, $disabledPath)) {
    if (-not $path.StartsWith(
            $directoryPrefix,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to move a path outside $movieDirectory`: $path"
    }
}

$sourcePath = if ($Mode -eq "Bypass") { $enabledPath } else { $disabledPath }
$destinationPath = if ($Mode -eq "Bypass") { $disabledPath } else { $enabledPath }

if ((Test-Path -LiteralPath $destinationPath) -and
    -not (Test-Path -LiteralPath $sourcePath)) {
    Write-Output "Attract movie mode already set: $Mode"
    exit 0
}
if (Test-Path -LiteralPath $destinationPath) {
    throw "Both attract movie paths exist; refusing to overwrite $destinationPath"
}
if (-not (Test-Path -LiteralPath $sourcePath)) {
    throw "Attract movie source not found: $sourcePath"
}

$sourceItem = Get-Item -LiteralPath $sourcePath
$wasReadOnly = $sourceItem.IsReadOnly
if ($wasReadOnly) {
    $sourceItem.IsReadOnly = $false
}

try {
    Move-Item -LiteralPath $sourcePath -Destination $destinationPath
} finally {
    if ($wasReadOnly -and (Test-Path -LiteralPath $destinationPath)) {
        (Get-Item -LiteralPath $destinationPath).IsReadOnly = $true
    }
}

Write-Output "Attract movie mode: $Mode"
