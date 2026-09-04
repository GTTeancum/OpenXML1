[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$LogPath,
    [string]$MapPath = (Join-Path $PSScriptRoot '..\PS2Recomp\out\xmen-final3-build\ps2xTest\Release\ps2x_tests.exe.map'),
    [ValidateRange(1, 100)]
    [int]$Top = 20
)

$ErrorActionPreference = 'Stop'
$map = Get-Content -LiteralPath $MapPath
$log = Get-Content -LiteralPath $LogPath
$baseMatch = $map | Select-String 'Preferred load address is ([0-9A-Fa-f]+)'
$stampMatch = $map | Select-String 'Timestamp is ([0-9A-Fa-f]+)'
$imageMatch = $log | Select-String '\[vu-sampler:image\] timestamp=0x([0-9A-Fa-f]+)'
if ($null -eq $baseMatch -or $null -eq $stampMatch -or $null -eq $imageMatch) {
    throw 'A sampler image ID and a matching MSVC linker map are required.'
}
$mapStamp = [Convert]::ToUInt32($stampMatch.Matches[0].Groups[1].Value, 16)
$imageStamp = [Convert]::ToUInt32($imageMatch.Matches[0].Groups[1].Value, 16)
if ($mapStamp -ne $imageStamp) {
    throw 'The linker map belongs to a different test executable. Do not attribute these samples.'
}
$base = [Convert]::ToInt64($baseMatch.Matches[0].Groups[1].Value, 16)
$symbols = @($map | ForEach-Object {
    if ($_ -match '^\s+0001:[0-9a-fA-F]+\s+(\S+)\s+([0-9a-fA-F]{16})\s+f\s+(.+)$') {
        [pscustomobject]@{
            Rva = [Convert]::ToInt64($Matches[2], 16) - $base
            Name = $Matches[1]
            SourceObject = $Matches[3]
        }
    }
} | Sort-Object Rva -Unique)
if ($symbols.Count -eq 0) { throw 'No code symbols found in the linker map.' }

$rows = @($log | ForEach-Object {
    if ($_ -match '\[vu-sampler:ip\] rva=0x([0-9a-f]+) hits=(\d+)') {
        $rva = [Convert]::ToInt64($Matches[1], 16)
        $hits = [int]$Matches[2]
        $lo = 0
        $hi = $symbols.Count - 1
        while ($lo -le $hi) {
            $mid = ($lo + $hi) -shr 1
            if ($symbols[$mid].Rva -le $rva) { $lo = $mid + 1 }
            else { $hi = $mid - 1 }
        }
        [pscustomobject]@{
            Name = if ($hi -ge 0) { $symbols[$hi].Name } else { '<unmapped>' }
            SourceObject = if ($hi -ge 0) { $symbols[$hi].SourceObject } else { '' }
            Hits = $hits
        }
    }
})
$total = ($rows | Measure-Object Hits -Sum).Sum
if ($total -le 0) { throw 'No in-module samples were recorded.' }
# Percentages include replay setup/comparison, not just timed VU execution.
$rows | Group-Object Name | ForEach-Object {
    $hits = ($_.Group | Measure-Object Hits -Sum).Sum
    [pscustomobject]@{
        Hits = $hits
        ModulePercent = [Math]::Round(100 * $hits / $total, 2)
        Name = $_.Name
        SourceObject = $_.Group[0].SourceObject
    }
} | Sort-Object Hits -Descending | Select-Object -First $Top
