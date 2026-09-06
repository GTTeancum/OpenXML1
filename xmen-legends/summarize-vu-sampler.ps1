[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$LogPath,
    [string]$MapPath = (Join-Path $PSScriptRoot '..\PS2Recomp\out\xmen-final3-build\ps2xTest\Release\ps2x_tests.exe.map'),
    [ValidateRange(1, 100)]
    [int]$Top = 20,
    [switch]$All,
    [switch]$External
)

$ErrorActionPreference = 'Stop'
$log = Get-Content -LiteralPath $LogPath
$scope = if ($log | Select-String '\[vu-sampler:summary\].*execution-only=1(?:\s|$)') {
    'warm-execution'
} else { 'whole-replay' }
if ($External) {
    $modules = @{}
    $rows = @()
    $samples = 0L
    $externalCount = 0L
    $unresolved = 0L
    $dropped = 0L
    $summaries = 0
    $externalSummaries = 0
    foreach ($line in $log) {
        if ($line -match '\[vu-sampler:image\]') { $modules.Clear() }
        elseif ($line -match '^\[vu-sampler:summary\] samples=(\d+) external=(\d+)') {
            $samples += [long]$Matches[1]
            $externalCount += [long]$Matches[2]
            ++$summaries
        }
        elseif ($line -match '^\[vu-sampler:external-summary\] modules=\d+ unique=\d+ unresolved=(\d+) dropped=(\d+)$') {
            $unresolved += [long]$Matches[1]
            $dropped += [long]$Matches[2]
            ++$externalSummaries
        }
        elseif ($line -match '^\[vu-sampler:module\] id=(\d+) timestamp=(0x[0-9a-f]+) size=(0x[0-9a-f]+) path="([^"]+)"$') {
            $modules[$Matches[1]] = [pscustomobject]@{
                Timestamp = $Matches[2]; ImageSize = $Matches[3]; Path = $Matches[4]
            }
        }
        elseif ($line -match '^\[vu-sampler:external-ip\] module=(\d+) rva=(0x[0-9a-f]+) hits=(\d+)$') {
            $module = $modules[$Matches[1]]
            if ($null -eq $module) { throw 'An external sample has no module identity in its run.' }
            if ([Convert]::ToInt64($Matches[2], 16) -ge [Convert]::ToInt64($module.ImageSize, 16)) {
                throw 'An external sample is outside its recorded module image.'
            }
            $rows += [pscustomobject]@{
                Path = $module.Path; Timestamp = $module.Timestamp; ImageSize = $module.ImageSize
                Rva = $Matches[2]; Hits = [long]$Matches[3]
            }
        }
    }
    $resolved = ($rows | Measure-Object Hits -Sum).Sum
    if ($externalSummaries -eq 0 -or $externalSummaries -ne $summaries -or
        $externalCount -ne ($resolved + $unresolved + $dropped) -or $samples -lt $externalCount) {
        throw 'External sample accounting is missing or inconsistent.'
    }
    if ($unresolved -gt 0 -or $dropped -gt 0) {
        Write-Warning "External samples not attributed: unresolved=$unresolved dropped=$dropped"
    }
    $report = $rows | Group-Object Path,Timestamp,ImageSize,Rva | ForEach-Object {
        $row = $_.Group[0]
        $hits = ($_.Group | Measure-Object Hits -Sum).Sum
        [pscustomobject]@{
            Hits = $hits
            ExternalPercent = [Math]::Round(100 * $hits / $externalCount, 2)
            ExecutionPercent = [Math]::Round(100 * $hits / $samples, 2)
            Scope = $scope
            Path = $row.Path; Timestamp = $row.Timestamp; ImageSize = $row.ImageSize; Rva = $row.Rva
        }
    } | Sort-Object Hits -Descending
    if ($All) { $report } else { $report | Select-Object -First $Top }
    return
}
$map = Get-Content -LiteralPath $MapPath
$baseMatch = $map | Select-String 'Preferred load address is ([0-9A-Fa-f]+)'
$stampMatch = $map | Select-String 'Timestamp is ([0-9A-Fa-f]+)'
$imageMatch = $log | Select-String '\[vu-sampler:image\] timestamp=0x([0-9A-Fa-f]+)'
if ($null -eq $baseMatch -or $null -eq $stampMatch -or $null -eq $imageMatch) {
    throw 'A sampler image ID and a matching MSVC linker map are required.'
}
$mapStamp = [Convert]::ToUInt32($stampMatch.Matches[0].Groups[1].Value, 16)
$imageStamps = @($imageMatch | ForEach-Object {
    [Convert]::ToUInt32($_.Matches[0].Groups[1].Value, 16)
} | Sort-Object -Unique)
if ($imageStamps.Count -ne 1 -or $mapStamp -ne $imageStamps[0]) {
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
# New execution-only logs exclude snapshot setup/comparison; legacy logs do not.
$report = $rows | Group-Object Name | ForEach-Object {
    $hits = ($_.Group | Measure-Object Hits -Sum).Sum
    [pscustomobject]@{
        Hits = $hits
        ModulePercent = [Math]::Round(100 * $hits / $total, 2)
        Scope = $scope
        Name = $_.Name
        SourceObject = $_.Group[0].SourceObject
    }
} | Sort-Object Hits -Descending
if ($All) { $report }
else { $report | Select-Object -First $Top }
