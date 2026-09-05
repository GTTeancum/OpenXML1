param(
    [Parameter(Mandatory = $true)]
    [int]$Probe,

    [ValidateSet('Interpreted', 'Pairs', 'Blocks')]
    [string]$Mode = 'Blocks',

    [ValidateRange(60, 1800)]
    [int]$TimeoutSeconds = 480
)

$ErrorActionPreference = 'Stop'
function Assert-CompleteGameplayImage {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $pe = $null
    try {
        $pe = [Reflection.PortableExecutable.PEReader]::new($stream)
        if ($null -eq $pe.PEHeaders.PEHeader -or
            $pe.PEHeaders.PEHeader.AddressOfEntryPoint -eq 0 -or
            $pe.PEHeaders.SectionHeaders.Length -eq 0) {
            throw 'Missing executable headers or entry point.'
        }
        foreach ($section in $pe.PEHeaders.SectionHeaders) {
            if ($section.PointerToRawData -lt 0 -or $section.SizeOfRawData -lt 0 -or
                ([long]$section.PointerToRawData + $section.SizeOfRawData) -gt $stream.Length) {
                throw 'Truncated executable section.'
            }
        }
    }
    catch { throw "Candidate is not a complete PE executable: $($_.Exception.Message)" }
    finally {
        if ($null -ne $pe) { $pe.Dispose() }
        $stream.Dispose()
    }
}

$root = Split-Path -Parent $PSScriptRoot
$disc = Join-Path $PSScriptRoot 'disc'
$exe = Join-Path $root 'PS2Recomp\out\xmen-final3-build\ps2xRuntime\Release\ps2EntryRunner.candidate.exe'
Assert-CompleteGameplayImage -Path $exe
$identity = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
$running = @(Get-Process -Name 'ps2EntryRunner*' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) })
if ($running.Count) { throw 'Close the existing workspace runtime before timing another run.' }

$guardLog = Join-Path $disc 'gameplay-guard.out.log'
$guardError = Join-Path $disc 'gameplay-guard.err.log'
$runtimeLog = Join-Path $PSScriptRoot "probe$Probe.err.log"
if (Test-Path -LiteralPath $runtimeLog) { throw "Probe $Probe already has a log; choose an unused number." }
$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = (Get-Process -Id $PID).Path
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
$startInfo.WorkingDirectory = $root
foreach ($name in @($startInfo.Environment.Keys)) {
    if ($name -like 'PS2X_*') { [void]$startInfo.Environment.Remove($name) }
}
$startInfo.Environment['PS2X_XMEN_START_FIRST_LEVEL'] = '1'
$startInfo.Environment['PS2X_DISABLE_HOST_INPUT'] = '1'
$startInfo.Environment['PS2X_RUN_VSYNC_LIMIT'] = '1400'
if ($Mode -ne 'Interpreted') { $startInfo.Environment['PS2X_VU_NATIVE_PAIRS'] = '1' }
if ($Mode -eq 'Blocks') { $startInfo.Environment['PS2X_VU_NATIVE_BLOCKS'] = '1' }
foreach ($argument in @(
    '-NoProfile', '-NonInteractive', '-File',
    (Join-Path $PSScriptRoot 'run-guarded-probe.ps1'),
    '-Probe', "$Probe", '-RuntimeVariant', 'Candidate',
    '-TimeoutSeconds', "$TimeoutSeconds", '-ContinueAfterNonBlack', '-ContinueAfterMissing',
    '-StartupMovieMode', 'TitleGameplayFirst', '-FastForwardLegal', '-UseHostClock',
    '-BypassXmenBranchHooks', '-DumpPresentRange', '1280-1280'
)) { [void]$startInfo.ArgumentList.Add($argument) }
$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
$started = $false
$reader = $null
$pending = ''
$samples = @{}
$clock = [Diagnostics.Stopwatch]::StartNew()
try {
    if (-not $process.Start()) { throw 'Unable to start the guarded gameplay run.' }
    $started = $true
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.PriorityClass = [Diagnostics.ProcessPriorityClass]::Normal
    $process.ProcessorAffinity = [IntPtr]0xF
    "GAMEPLAY_START PROBE=$Probe MODE=$Mode GUARD_PID=$($process.Id) SHA256=$identity"
    do {
        if ($null -eq $reader -and (Test-Path -LiteralPath $runtimeLog)) {
            $stream = [IO.File]::Open($runtimeLog, [IO.FileMode]::Open,
                [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            $reader = [IO.StreamReader]::new($stream)
        }
        if ($null -ne $reader) {
            $pending += $reader.ReadToEnd()
            $observed = $clock.Elapsed.TotalSeconds
            $lastNewline = $pending.LastIndexOf("`n")
            if ($lastNewline -ge 0) {
                $complete = $pending.Substring(0, $lastNewline + 1)
                $pending = $pending.Substring($lastNewline + 1)
                foreach ($match in [regex]::Matches($complete, '\[gs:present\] index=(\d+) tick=(\d+) has=(\d+)')) {
                    $index = [int]$match.Groups[1].Value
                    if ($index -in 1152, 1280 -and -not $samples.ContainsKey($index)) {
                        if ($match.Groups[3].Value -ne '1') { throw "Present $index has no framebuffer." }
                        $samples[$index] = $observed
                        "GAMEPLAY_SAMPLE PRESENT=$index SECONDS=$observed"
                    }
                }
            }
        }
        $process.Refresh()
        if (-not $process.HasExited) { Start-Sleep -Milliseconds 20 }
    } while (-not $process.HasExited)
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "Guard failed with exit code $($process.ExitCode)." }
}
finally {
    if ($null -ne $reader) { $reader.Dispose() }
    # Let the bounded guard close its own runtime and restore the startup archive.
    if ($started) {
        if (-not $process.HasExited) { $process.WaitForExit() }
        [IO.File]::WriteAllText($guardLog, $stdoutTask.GetAwaiter().GetResult())
        [IO.File]::WriteAllText($guardError, $stderrTask.GetAwaiter().GetResult())
    }
    $process.Dispose()
}

$guardText = Get-Content -LiteralPath $guardLog -Raw
if ($guardText -notmatch 'EXITED CODE=0\b') { throw 'Runtime did not exit normally; inspect the guard log.' }
$runtimeText = Get-Content -LiteralPath $runtimeLog -Raw
$blocks = [regex]::Match($runtimeText, '\[vu:blocks\] stopped vu1=(\d+)/(\d+) \(executed/attempted\) pairs=(\d+)')
$pairs = [regex]::Match($runtimeText, '\[vu:pairs\] stopped vu1=(\d+)/(\d+) \(native/interpreted\)')
if (-not $blocks.Success -or -not $pairs.Success) { throw 'Missing post-join VU counters.' }
if ($Mode -eq 'Blocks' -and [long]$blocks.Groups[3].Value -eq 0) { throw 'Compiled blocks did not execute.' }
if ($Mode -ne 'Blocks' -and [long]$blocks.Groups[3].Value -ne 0) { throw 'Unexpected compiled blocks in the baseline.' }
if ($Mode -eq 'Pairs' -and [long]$pairs.Groups[1].Value -eq 0) { throw 'Compiled pairs did not execute.' }
if ($Mode -eq 'Interpreted' -and [long]$pairs.Groups[1].Value -ne 0) { throw 'Unexpected compiled pairs in the baseline.' }
if (-not $samples.ContainsKey(1152) -or -not $samples.ContainsKey(1280) -or $samples[1280] -le $samples[1152]) {
    throw 'Missing or coalesced timing endpoints; no frame-rate result is valid.'
}
if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $identity) { throw 'Runtime changed during measurement.' }
$seconds = $samples[1280] - $samples[1152]
$report = [ordered]@{
    Probe = $Probe
    Mode = $Mode
    StartPresent = 1152
    EndPresent = 1280
    Frames = 128
    ElapsedSeconds = $seconds
    FramesPerSecond = 128 / $seconds
    ObservedUtc = [DateTime]::UtcNow.ToString('o')
    Executable = $exe
    Sha256 = $identity
    NativeBlockPairs = [long]$blocks.Groups[3].Value
    NativePairs = [long]$pairs.Groups[1].Value
    InterpretedPairs = [long]$pairs.Groups[2].Value
}
$reportPath = Join-Path $disc "gameplay-$($Mode.ToLowerInvariant())-rate.json"
$report | ConvertTo-Json | Set-Content -LiteralPath $reportPath -Encoding utf8
$report | ConvertTo-Json
