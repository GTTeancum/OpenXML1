[CmdletBinding(DefaultParameterSetName = 'Files')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Files')][string[]]$ProfilePath,
    [Parameter(Mandatory, ParameterSetName = 'Files')][string]$RecipePath,
    [Parameter(Mandatory, ParameterSetName = 'Text')][string[]]$ProfileCsv,
    [Parameter(Mandatory, ParameterSetName = 'Text')][string]$RecipeText,
    [ValidateRange(1, 512)][int]$Limit = 64,
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
$sourcePaths = @()
if ($PSCmdlet.ParameterSetName -eq 'Files') {
    $sourcePaths = @(@($ProfilePath) + @($RecipePath) | ForEach-Object {
        (Resolve-Path -LiteralPath $_).Path
    })
    if (@($sourcePaths | Select-Object -Unique).Count -ne $sourcePaths.Count) {
        throw 'Profile and recipe inputs must be distinct files.'
    }
    $ProfileCsv = @($ProfilePath | ForEach-Object { Get-Content -Raw -LiteralPath $_ })
    $RecipeText = Get-Content -Raw -LiteralPath $RecipePath
}
if ($ProfileCsv.Count -lt 1 -or $ProfileCsv.Count -gt 16) {
    throw 'Expected between one and sixteen residual profiles.'
}

$words = @{}
$profiles = @()
for ($index = 0; $index -lt $ProfileCsv.Count; ++$index) {
    $csv = $ProfileCsv[$index]
    if ($csv.Length -gt 1048576) { throw 'Residual CSV exceeds its size limit.' }
    $rows = [Collections.Generic.List[object]]::new()
    $reader = [IO.StringReader]::new($csv)
    $parser = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new($reader)
    try {
        $parser.SetDelimiters(',')
        $parser.TrimWhiteSpace = $false
        if (($parser.ReadFields() -join ',') -cne 'pc,lower,upper,native,interpreted') {
            throw 'Invalid residual CSV header.'
        }
        while (!$parser.EndOfData) {
            $fields = $parser.ReadFields()
            if ($fields.Count -ne 5) { throw 'Invalid residual CSV columns.' }
            $rows.Add([pscustomobject]@{
                pc = $fields[0]; lower = $fields[1]; upper = $fields[2]
                native = $fields[3]; interpreted = $fields[4]
            })
            if ($rows.Count -gt 4096) { throw 'Invalid residual profile row count.' }
        }
    } finally {
        $parser.Dispose()
        $reader.Dispose()
    }
    if ($rows.Count -eq 0 -or $rows.Count -gt 4096) {
        throw 'Invalid residual profile row count.'
    }
    $keys = [Collections.Generic.HashSet[string]]::new()
    $counts = @{}
    [decimal]$total = 0
    foreach ($row in $rows) {
        $values = @{}
        foreach ($field in @('pc', 'lower', 'upper', 'native', 'interpreted')) {
            [uint64]$value = 0
            if ($row.$field -notmatch '\A[0-9]+\z' -or ![uint64]::TryParse($row.$field, [ref]$value)) {
                throw "Invalid residual integer: $field"
            }
            $values[$field] = $value
        }
        if ($values.pc -ge 16384 -or $values.pc % 8 -ne 0 -or
            $values.lower -gt [uint32]::MaxValue -or $values.upper -gt [uint32]::MaxValue -or
            $values.native -gt 100000000 -or $values.interpreted -gt 100000000) {
            throw 'Residual value exceeds its bounds.'
        }
        if (!$keys.Add("$($values.pc),$($values.lower),$($values.upper)")) {
            throw 'Duplicate residual PC/word key.'
        }
        [decimal]$count = [decimal]$values.native + [decimal]$values.interpreted
        if ($count -eq 0) { throw 'Empty residual counter.' }
        $key = '{0:x8}{1:x8}' -f $values.lower, $values.upper
        if (!$words.ContainsKey($key)) {
            $words[$key] = [pscustomobject]@{
                Key = $key; Lower = $values.lower; Upper = $values.upper
                Score = [decimal]0; Executions = [uint64]0
            }
        }
        $counts[$key] = [decimal]$counts[$key] + $count
        $total += $count
    }
    if ($total -gt 100000000) { throw 'Residual profile exceeds the replay execution limit.' }
    foreach ($key in $counts.Keys) {
        $words[$key].Score += $counts[$key] / $total
        $words[$key].Executions += [uint64]$counts[$key]
    }
    $profiles += [pscustomobject]@{ Index = $index; Total = $total; Counts = $counts }
}

$ranked = @($words.Values | Sort-Object @{Expression = 'Score'; Descending = $true}, Lower, Upper)
$selected = @($ranked | Select-Object -First $Limit)
$lines = [Collections.Generic.List[string]]::new()
$replaced = 0
foreach ($line in ($RecipeText -replace "`r`n", "`n").TrimEnd("`n").Split("`n")) {
    if ($line.StartsWith('VU_NATIVE_PAIR_WORDS')) {
        if ($line -notmatch '^VU_NATIVE_PAIR_WORDS\(0x[0-9a-fA-F]{8}u, 0x[0-9a-fA-F]{8}u, [1-9][0-9]{0,19}u\)$') {
            throw 'Invalid pair-word recipe line.'
        }
        ++$replaced
    } else {
        $lines.Add($line)
    }
}
if ($replaced -eq 0) { throw 'Recipe contains no pair-word selection to replace.' }
$lines.Add('// Residual dispatch ranked by equal normalized capture weight; counts are raw sums.')
foreach ($word in $ranked) {
    $lines.Add(('VU_NATIVE_PAIR_WORDS(0x{0:x8}u, 0x{1:x8}u, {2}u)' -f
        $word.Lower, $word.Upper, $word.Executions))
}
$coverage = foreach ($profile in $profiles) {
    [decimal]$covered = 0
    foreach ($word in $selected) { $covered += [decimal]$profile.Counts[$word.Key] }
    [pscustomobject]@{ Index = $profile.Index; Total = $profile.Total; Covered = $covered }
}
if ($OutputPath) {
    $output = [IO.Path]::GetFullPath($OutputPath)
    if ($sourcePaths -contains $output) { throw 'Output must not overwrite an input.' }
    [IO.File]::WriteAllLines($output, $lines, [Text.UTF8Encoding]::new($false))
}
[pscustomobject]@{
    Limit = $Limit; Selected = $selected; Ranked = $ranked
    Coverage = @($coverage); RecipeLines = $lines.ToArray()
}
