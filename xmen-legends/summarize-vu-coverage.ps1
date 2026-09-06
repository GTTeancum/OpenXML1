[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'File')][string]$LogPath,
    [Parameter(Mandatory = $true, ParameterSetName = 'Lines')][AllowEmptyCollection()][string[]]$Lines,
    [switch]$RequireGameplaySpan
)

$ErrorActionPreference = 'Stop'
$windows = [Collections.Generic.List[object]]::new()
[decimal]$native = 0
[decimal]$interpreted = 0
[decimal]$blocks = 0
[decimal]$attempted = 0
[decimal]$executed = 0
$pattern = '^\[vu:coverage-window\] begin=(\d+) end=(\d+) native=(\d+) interpreted=(\d+) block-pairs=(\d+) attempted=(\d+) executed=(\d+)$'
$reader = if ($PSCmdlet.ParameterSetName -eq 'Lines') {
    [IO.StringReader]::new(($Lines -join "`n"))
} else { [IO.File]::OpenText((Resolve-Path -LiteralPath $LogPath).Path) }
try {
    while ($null -ne ($line = $reader.ReadLine())) {
        if (!$line.StartsWith('[vu:coverage-window]')) { continue }
        if ($line -notmatch $pattern) { throw 'Malformed VU coverage window.' }
        $values = @(1..7 | ForEach-Object { [uint64]::Parse($Matches[$_]) })
        if ($values[0] -lt 1100 -or $values[1] -gt 1400 -or
            $values[1] -lt $values[0] -or $values[1] - $values[0] -lt 32 -or
            $values[4] -gt $values[2] -or $values[6] -gt $values[5]) {
            throw 'Invalid VU coverage interval or counters.'
        }
        if ($windows.Count -gt 0 -and $values[0] -ne $windows[$windows.Count - 1].End) {
            throw 'Noncontiguous VU coverage windows; do not combine reset or missing intervals.'
        }
        $windows.Add([pscustomobject]@{
            Begin = $values[0]; End = $values[1]
            NativePairs = $values[2]; InterpretedPairs = $values[3]; BlockPairs = $values[4]
            Attempts = $values[5]; Executions = $values[6]
        })
        $native += $values[2]; $interpreted += $values[3]; $blocks += $values[4]
        $attempted += $values[5]; $executed += $values[6]
    }
} finally { $reader.Dispose() }
if ($windows.Count -eq 0 -or $native + $interpreted -eq 0) {
    throw 'No nonempty VU coverage windows.'
}
if ($RequireGameplaySpan -and ($windows[0].Begin -gt 1132 -or $windows[$windows.Count - 1].End -lt 1356)) {
    throw 'Incomplete gameplay coverage span.'
}
[pscustomobject]@{
    Begin = $windows[0].Begin; End = $windows[$windows.Count - 1].End
    NativePairs = $native; InterpretedPairs = $interpreted; BlockPairs = $blocks
    Attempts = $attempted; Executions = $executed
    NativePercent = 100 * $native / ($native + $interpreted)
    BlockPercent = 100 * $blocks / ($native + $interpreted)
    Windows = $windows.ToArray()
}
