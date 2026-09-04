$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$fixture = [IO.Path]::GetFullPath((Join-Path $root ('.sampler-test-' + [guid]::NewGuid().ToString('N'))))
if (-not $fixture.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Fixture escaped the test directory.'
}
$null = New-Item -ItemType Directory -Path $fixture
$mapPath = Join-Path $fixture 'test.map'
$logPath = Join-Path $fixture 'test.log'
$reporter = Join-Path $PSScriptRoot '..\summarize-vu-sampler.ps1'
try {
    [IO.File]::WriteAllText($mapPath, @'
 Timestamp is 0000000a
 Preferred load address is 0000000140000000
 0001:00000000 ?First@@YAXXZ 0000000140001000 f test.obj
 0001:00000100 ?Second@@YAXXZ 0000000140001100 f test.obj
'@)
    $validLog = @'
[vu-sampler:image] timestamp=0x0000000a
[vu-sampler:ip] rva=0x1001 hits=2
[vu-sampler:ip] rva=0x1100 hits=3
'@
    [IO.File]::WriteAllText($logPath, $validLog)
    $rows = @(& $reporter -MapPath $mapPath -LogPath $logPath)
    if ($rows.Count -ne 2 -or $rows[0].Name -ne '?Second@@YAXXZ' -or
        $rows[0].Hits -ne 3 -or $rows[0].ModulePercent -ne 60 -or
        $rows[1].Name -ne '?First@@YAXXZ' -or $rows[1].ModulePercent -ne 40) {
        throw 'Sample address attribution or percentages are incorrect.'
    }
    foreach ($invalid in @(
        @{ Log = $validLog.Replace('timestamp=0x0000000a', 'timestamp=0x0000000b'); Error = 'different test executable' },
        @{ Log = '[vu-sampler:ip] rva=0x1001 hits=2'; Error = 'sampler image ID' },
        @{ Log = '[vu-sampler:image] timestamp=0x0000000a'; Error = 'No in-module samples' }
    )) {
        [IO.File]::WriteAllText($logPath, $invalid.Log)
        $rejected = $false
        try { $null = & $reporter -MapPath $mapPath -LogPath $logPath }
        catch {
            if ($_.Exception.Message -notlike "*$($invalid.Error)*") { throw }
            $rejected = $true
        }
        if (-not $rejected) { throw "Reporter did not reject: $($invalid.Error)" }
    }
    'PASS sampler attribution, build mismatch, missing identity, and empty sample checks'
}
finally {
    foreach ($file in @($mapPath, $logPath)) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
    Remove-Item -LiteralPath $fixture -Force
}
