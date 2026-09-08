function Get-PpmFrameMetrics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1, 255)][byte]$BlackThreshold = 4,
        [ValidateRange(1, 256)][int]$TileWidth = 40,
        [ValidateRange(1, 256)][int]$TileHeight = 28
    )

    $bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path))
    $cursor = 0
    $readPpmToken = {
        while ($cursor -lt $bytes.Length) {
            $value = $bytes[$cursor]
            if ($value -eq 35) {
                while ($cursor -lt $bytes.Length -and $bytes[$cursor] -notin @(10, 13)) {
                    ++$cursor
                }
            } elseif ($value -in @(9, 10, 13, 32)) {
                ++$cursor
            } else {
                break
            }
        }
        $start = $cursor
        while ($cursor -lt $bytes.Length -and $bytes[$cursor] -notin @(9, 10, 13, 32, 35)) {
            ++$cursor
        }
        if ($start -eq $cursor) { throw "Malformed PPM header: $Path" }
        [Text.Encoding]::ASCII.GetString($bytes, $start, $cursor - $start)
    }

    if ((. $readPpmToken) -cne 'P6') { throw "Unsupported PPM encoding: $Path" }
    $width = [int](. $readPpmToken)
    $height = [int](. $readPpmToken)
    $maximum = [int](. $readPpmToken)
    if ($width -le 0 -or $height -le 0 -or $maximum -ne 255) {
        throw "Unsupported PPM dimensions or channel range: $Path"
    }
    if ($cursor -ge $bytes.Length -or $bytes[$cursor] -notin @(9, 10, 13, 32)) {
        throw "Malformed PPM pixel boundary: $Path"
    }
    if ($bytes[$cursor] -eq 13 -and $cursor + 1 -lt $bytes.Length -and $bytes[$cursor + 1] -eq 10) {
        $cursor += 2
    } else {
        ++$cursor
    }
    $expectedBytes = [long]$width * $height * 3
    if ($bytes.Length - $cursor -lt $expectedBytes) { throw "Truncated PPM pixel data: $Path" }

    $nonblack = 0L
    $centralNonblack = 0L
    $minimumX = $width
    $minimumY = $height
    $maximumX = -1
    $maximumY = -1
    $tiles = [Collections.Generic.HashSet[int]]::new()
    $centralLeft = [int][Math]::Floor($width * 0.20)
    $centralRight = [int][Math]::Ceiling($width * 0.90)
    $centralTop = [int][Math]::Floor($height * 0.08)
    $centralBottom = [int][Math]::Ceiling($height * 0.92)
    $tileColumns = [int][Math]::Ceiling($width / [double]$TileWidth)
    for ($y = 0; $y -lt $height; ++$y) {
        for ($x = 0; $x -lt $width; ++$x) {
            $offset = $cursor + 3 * ($y * $width + $x)
            if ($bytes[$offset] -le $BlackThreshold -and
                $bytes[$offset + 1] -le $BlackThreshold -and
                $bytes[$offset + 2] -le $BlackThreshold) { continue }
            ++$nonblack
            if ($x -ge $centralLeft -and $x -lt $centralRight -and
                $y -ge $centralTop -and $y -lt $centralBottom) { ++$centralNonblack }
            $minimumX = [Math]::Min($minimumX, $x)
            $minimumY = [Math]::Min($minimumY, $y)
            $maximumX = [Math]::Max($maximumX, $x)
            $maximumY = [Math]::Max($maximumY, $y)
            $tileY = [int][Math]::Floor($y / [double]$TileHeight)
            $tileX = [int][Math]::Floor($x / [double]$TileWidth)
            [void]$tiles.Add(($tileY * $tileColumns) + $tileX)
        }
    }

    $pixelCount = [long]$width * $height
    $centralPixelCount = [long]($centralRight - $centralLeft) * ($centralBottom - $centralTop)
    [ordered]@{
        Width = $width
        Height = $height
        NonblackPixels = $nonblack
        NonblackPercent = if ($pixelCount) { 100.0 * $nonblack / $pixelCount } else { 0.0 }
        CentralNonblackPixels = $centralNonblack
        CentralNonblackPercent = if ($centralPixelCount) { 100.0 * $centralNonblack / $centralPixelCount } else { 0.0 }
        OccupiedTiles = $tiles.Count
        Bounds = if ($nonblack) {
            [ordered]@{ Left=$minimumX; Top=$minimumY; Right=$maximumX; Bottom=$maximumY }
        } else { $null }
    }
}

function Test-WorldFrameMetrics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Metrics,
        [ValidateRange(1, 286720)][int]$MinimumNonblackPixels = 16384,
        [ValidateRange(1, 286720)][int]$MinimumCentralPixels = 8192,
        [ValidateRange(1, 256)][int]$MinimumOccupiedTiles = 48
    )

    [long]$Metrics.NonblackPixels -ge $MinimumNonblackPixels -and
        [long]$Metrics.CentralNonblackPixels -ge $MinimumCentralPixels -and
        [int]$Metrics.OccupiedTiles -ge $MinimumOccupiedTiles
}
