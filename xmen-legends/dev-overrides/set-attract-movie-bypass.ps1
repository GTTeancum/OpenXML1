param(
    [ValidateSet("Bypass", "Restore")]
    [string]$Mode = "Bypass"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$sourcePath = [System.IO.Path]::GetFullPath(
    (Join-Path $root "SLUS_206.56"))
$targetPath = [System.IO.Path]::GetFullPath(
    (Join-Path $root "disc\SLUS_206.56"))
$expectedTarget = [System.IO.Path]::GetFullPath(
    (Join-Path $root "disc\SLUS_206.56"))
$stringOffset = 6125408
$enabledBytes = [System.Text.Encoding]::ASCII.GetBytes("startMovie('i107', '')")
$disabledBytes = [byte[]]::new($enabledBytes.Length)
$disabledBytes[0] = [byte][char]'#'

if (-not $targetPath.Equals(
        $expectedTarget,
        [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Unexpected executable path: $targetPath"
}
if ($enabledBytes.Length -ne $disabledBytes.Length) {
    throw "The replacement must preserve the executable layout"
}

function Read-BytesAtOffset {
    param(
        [string]$Path,
        [long]$Offset,
        [int]$Count
    )

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        if ($stream.Length -lt ($Offset + $Count)) {
            throw "Executable is too small for the CMenuMain command patch: $Path"
        }
        $stream.Position = $Offset
        $bytes = [byte[]]::new($Count)
        if ($stream.Read($bytes, 0, $Count) -ne $Count) {
            throw "Unable to read CMenuMain command bytes from $Path"
        }
        return $bytes
    } finally {
        $stream.Dispose()
    }
}

function Format-Bytes {
    param([byte[]]$Bytes)
    return [System.BitConverter]::ToString($Bytes)
}

$sourceBytes = Read-BytesAtOffset `
    -Path $sourcePath `
    -Offset $stringOffset `
    -Count $enabledBytes.Length
if ((Format-Bytes $sourceBytes) -ne (Format-Bytes $enabledBytes)) {
    throw "Reference executable does not contain the I107 command at offset $stringOffset"
}

$currentBytes = Read-BytesAtOffset `
    -Path $targetPath `
    -Offset $stringOffset `
    -Count $enabledBytes.Length
$replacementBytes = if ($Mode -eq "Bypass") {
    $disabledBytes
} else {
    $enabledBytes
}

if ((Format-Bytes $currentBytes) -eq (Format-Bytes $replacementBytes)) {
    Write-Output "Main-menu I107 command mode already set: $Mode"
    exit 0
}

$expectedCurrentBytes = if ($Mode -eq "Bypass") {
    $enabledBytes
} else {
    $disabledBytes
}
if ((Format-Bytes $currentBytes) -ne (Format-Bytes $expectedCurrentBytes)) {
    throw "Unexpected CMenuMain command bytes at offset $stringOffset"
}

$targetItem = Get-Item -LiteralPath $targetPath
$wasReadOnly = $targetItem.IsReadOnly
if ($wasReadOnly) {
    $targetItem.IsReadOnly = $false
}

try {
    $stream = [System.IO.File]::Open(
        $targetPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None)
    try {
        $stream.Position = $stringOffset
        $stream.Write($replacementBytes, 0, $replacementBytes.Length)
    } finally {
        $stream.Dispose()
    }
} finally {
    if ($wasReadOnly) {
        (Get-Item -LiteralPath $targetPath).IsReadOnly = $true
    }
}

Write-Output "Main-menu I107 command mode: $Mode"
