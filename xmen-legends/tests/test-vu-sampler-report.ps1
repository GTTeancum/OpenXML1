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
        $rows[1].Name -ne '?First@@YAXXZ' -or $rows[1].ModulePercent -ne 40 -or
        $rows[0].Scope -ne 'whole-replay') {
        throw 'Sample address attribution or percentages are incorrect.'
    }
    $limited = @(& $reporter -MapPath $mapPath -LogPath $logPath -Top 1)
    $all = @(& $reporter -MapPath $mapPath -LogPath $logPath -Top 1 -All)
    if ($limited.Count -ne 1 -or $all.Count -ne 2 -or ($all | Measure-Object Hits -Sum).Sum -ne 5) {
        throw 'All-symbol reporting must preserve every sample instead of applying Top.'
    }
    [IO.File]::WriteAllText($logPath, $validLog + "`n[vu-sampler:summary] samples=5 execution-only=1 outside=7`n")
    $executionRows = @(& $reporter -MapPath $mapPath -LogPath $logPath)
    if ($executionRows[0].Scope -ne 'warm-execution' -or $executionRows[0].ModulePercent -ne 60) {
        throw 'Execution-only samples must be labelled without including excluded observations.'
    }
    foreach ($invalid in @(
        @{ Log = $validLog.Replace('timestamp=0x0000000a', 'timestamp=0x0000000b'); Error = 'different test executable' },
        @{ Log = $validLog + "`n[vu-sampler:image] timestamp=0x0000000b"; Error = 'different test executable' },
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
    $externalLog = @'
[vu-sampler:image] timestamp=0x0000000a
[vu-sampler:summary] samples=10 external=5 execution-only=1
[vu-sampler:external-summary] modules=1 unique=1 unresolved=0 dropped=0
[vu-sampler:module] id=0 timestamp=0x00000001 size=0x2000 path="C:\fixture.dll"
[vu-sampler:external-ip] module=0 rva=0x1000 hits=5
Running replay test: [vu-sampler:image] timestamp=0x0000000a
[vu-sampler:summary] samples=10 external=3 execution-only=1
[vu-sampler:external-summary] modules=1 unique=1 unresolved=0 dropped=0
[vu-sampler:module] id=0 timestamp=0x00000002 size=0x2000 path="C:\fixture.dll"
[vu-sampler:external-ip] module=0 rva=0x1000 hits=3
'@
    [IO.File]::WriteAllText($logPath, $externalLog)
    $externalRows = @(& $reporter -LogPath $logPath -External -All -Top 1)
    if ($externalRows.Count -ne 2 -or $externalRows[0].Hits -ne 5 -or
        $externalRows[0].ExternalPercent -ne 62.5 -or $externalRows[0].ExecutionPercent -ne 25 -or
        $externalRows[0].Timestamp -ne '0x00000001' -or $externalRows[1].Timestamp -ne '0x00000002') {
        throw 'External identities, module-ID reuse, percentages or All reporting are incorrect.'
    }
    foreach ($invalid in @(
        @{ Log = $externalLog.Replace('module=0 rva', 'module=1 rva'); Error = 'no module identity' },
        @{ Log = $externalLog.Replace('rva=0x1000', 'rva=0x2000'); Error = 'outside its recorded' },
        @{ Log = $externalLog.Replace('hits=3', 'hits=2'); Error = 'accounting' },
        @{ Log = $validLog; Error = 'accounting' }
    )) {
        [IO.File]::WriteAllText($logPath, $invalid.Log)
        $rejected = $false
        try { $null = & $reporter -LogPath $logPath -External }
        catch {
            if ($_.Exception.Message -notlike "*$($invalid.Error)*") { throw }
            $rejected = $true
        }
        if (-not $rejected) { throw "External reporter did not reject: $($invalid.Error)" }
    }
    [IO.File]::WriteAllText($logPath, $externalLog.Replace('unresolved=0 dropped=0', 'unresolved=1 dropped=1').Replace('hits=3', 'hits=1').Replace('hits=5', 'hits=3'))
    $partial = @(& $reporter -LogPath $logPath -External -All -WarningVariable diagnostics -WarningAction SilentlyContinue)
    if ($partial.Count -ne 2 -or $partial[0].ExternalPercent -ne 37.5 -or
        $diagnostics.Count -ne 1 -or $diagnostics[0].Message -notlike '*unresolved=2 dropped=2*') {
        throw 'Unresolved and dropped samples must remain in denominators and be reported explicitly.'
    }
    'PASS sampler attribution, module identities, bounded accounting, build mismatch, and missing data checks'
}
finally {
    foreach ($file in @($mapPath, $logPath)) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
    Remove-Item -LiteralPath $fixture -Force
}
