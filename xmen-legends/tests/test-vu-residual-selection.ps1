$ErrorActionPreference = 'Stop'
$selector = Join-Path $PSScriptRoot '../select-vu-residual-pairs.ps1'
$recipe = @'
// Synthetic recipe; no game code.
VU_NATIVE_ENTRY(0x0000u)
VU_NATIVE_BLOCK(0x0000u, 2u)
VU_NATIVE_PAIR(0x0000u, 0x00000000u, 0x00000001u)
VU_NATIVE_PC_HITS(0x0000u, 9u)
VU_NATIVE_PAIR_WORDS(0x00000000u, 0x00000001u, 9u)
VU_NATIVE_EDGE(0x0000u, 0x0008u)
'@
$first = @'
pc,lower,upper,native,interpreted
0,0,1,90,0
8,0,2,0,10
'@
$second = @'
pc,lower,upper,native,interpreted
0,0,1,0,1
8,0,2,0,5
16,0,2,0,5
'@
$result = & $selector -ProfileCsv @($first, $second) -RecipeText $recipe -Limit 1
if ($result.Selected[0].Upper -ne 2 -or $result.Selected[0].Executions -ne 20 -or
    $result.Coverage[0].Covered -ne 10 -or $result.Coverage[1].Covered -ne 10) {
    throw 'Selection must normalize each capture, merge matching words across PCs, and retain raw counts.'
}
$preserved = @($recipe -split '\r?\n' | Where-Object { !($_.StartsWith('VU_NATIVE_PAIR_WORDS')) }) -join "`n"
$actual = @($result.RecipeLines | Where-Object {
    !($_.StartsWith('VU_NATIVE_PAIR_WORDS')) -and !($_.StartsWith('// Residual dispatch'))
}) -join "`n"
if ($actual -cne $preserved) { throw 'Block provenance, order, weights, and edges must remain unchanged.' }
$tie = & $selector -ProfileCsv @($first.Replace('90,0', '10,0')) -RecipeText $recipe -Limit 1
if ($tie.Selected[0].Upper -ne 1) { throw 'Equal scores must use deterministic word ordering.' }
foreach ($invalid in @(
    @{ Csv = $first.Replace('pc,lower', 'address,lower'); Error = 'header' },
    @{ Csv = $first.Replace('90,0', '90,0,1'); Error = 'columns' },
    @{ Csv = $first.Replace('90,0', '90'); Error = 'columns' },
    @{ Csv = $first.Replace('90,0', 'bad,0'); Error = 'integer' },
    @{ Csv = $first.Replace('8,0,2', '7,0,2'); Error = 'bounds' },
    @{ Csv = $first.Replace('8,0,2', '16384,0,2'); Error = 'bounds' },
    @{ Csv = $first.Replace('8,0,2', '8,4294967296,2'); Error = 'bounds' },
    @{ Csv = $first.Replace('90,0', '100000001,0'); Error = 'bounds' },
    @{ Csv = $first.Replace('90,0', '18446744073709551616,0'); Error = 'integer' },
    @{ Csv = $first.Replace('8,0,2', '0,0,1'); Error = 'Duplicate' },
    @{ Csv = $first.Replace('90,0', '0,0'); Error = 'Empty' },
    @{ Csv = $first.Replace('90,0', '100000000,0'); Error = 'execution limit' },
    @{ Csv = "pc,lower,upper,native,interpreted`n"; Error = 'row count' }
)) {
    $rejected = $false
    try { $null = & $selector -ProfileCsv @($invalid.Csv) -RecipeText $recipe }
    catch {
        if ($_.Exception.Message -notlike "*$($invalid.Error)*") { throw }
        $rejected = $true
    }
    if (!$rejected) { throw "Accepted invalid input: $($invalid.Error)" }
}
$rejected = $false
try { $null = & $selector -ProfileCsv @($first) -RecipeText $recipe.Replace('9u)', '0u)') }
catch { $rejected = $_.Exception.Message -like '*pair-word recipe*' }
if (!$rejected) { throw 'Malformed word lines must not be silently replaced.' }
'PASS residual selection weighting, deterministic ties, metadata preservation, and malformed input rejection'
