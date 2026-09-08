param(
    [ValidateSet('GameplayFirst', 'TitleGameplayFirst', 'GameplayMap', 'GameplayMapNoMovie', 'GameplayMissionNoMovie')]
    [string]$StartupMovieMode = 'GameplayFirst',

    [ValidateSet('Debug', 'Release', 'RelWithDebInfo', 'MinSizeRel')]
    [string]$Config = 'Release',

    [ValidateSet('Auto', 'Primary', 'Staged', 'Candidate')]
    [string]$RuntimeVariant = 'Auto',

    [string]$RuntimePath,

    [ValidateRange(8, 4096)]
    [int]$CompiledStreamBlockBytes = 32,

    [switch]$CompiledStreamBatch = $true,

    [ValidateRange(0, [long]::MaxValue)]
    [long]$Vu1ServiceTraceMinTick = 0,

    # Retained for compatibility with existing launch commands. Fast dispatch is
    # now the default; use -CompatibilityBranchHooks to disable it.
    [switch]$FastBranchHooks,

    [switch]$CompatibilityBranchHooks,

    [switch]$CompiledVu,

    [switch]$Diagnostics,

    [switch]$WhiteWireframe,

    [switch]$SuppressLateSprites
)

$ErrorActionPreference = 'Stop'

function Update-InteractiveStatus {
    param([System.Collections.IDictionary]$Status, [string]$Line, [string]$Stream)
    if ($Stream -eq 'err') { $Status.LastErrorLine = $Line.Substring(0, [Math]::Min(1024, $Line.Length)) }
    else { $Status.LastOutputLine = $Line.Substring(0, [Math]::Min(1024, $Line.Length)) }
    if ($Line -match '^\[xmen-new-?game-handler\]') { $Status.NewGameHandler = $true }
    if ($Line.Contains('path="maps/nyc/alison/nyc1_1_1.igb"')) { $Status.LevelPackage = $true }
    if ($Line -match '^\[gs:present\] index=(\d+)\b.*\bhas=1\b') { $Status.LastPresent = [long]$Matches[1] }
    if ($Line -match '^\[vu:compiled\] accepted=(\d+)') { $Status.CompiledCallsLowerBound = [long]$Matches[1] }
    if ($Line -match '^\[vu:compiled-stream\] started=(\d+) completed=(\d+)') {
        $Status.CompiledStreamCompletedLowerBound = [Math]::Max(
            [long]$Status.CompiledStreamCompletedLowerBound, [long]$Matches[2])
    }
    if ($Line -match '^\[(?:ee-thread:missing-pc|guest-branch:missing-target|vu:compiled-audit-failed|gs:bilinear-audit-failed)\]|^Error during program execution:') {
        ++$Status.GuestFaultLines
        if (!$Status.FirstGuestFault) { $Status.FirstGuestFault = $Line.Substring(0, [Math]::Min(1024, $Line.Length)) }
    }
    $Status.ReadyForInput = $Status.Running -and $Status.HostInput -and
        $Status.NewGameHandler -and
        $Status.LevelPackage -and $Status.LastPresent -ge 512 -and
        (!$Status.CompiledVu -or $Status.CompiledCallsLowerBound -gt 0 -or
            $Status.CompiledStreamCompletedLowerBound -gt 0) -and
        $Status.GuestFaultLines -eq 0
}

function Limit-LogFile {
    param([string]$Path, [long]$MaximumBytes = 8MB)
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $file = Get-Item -LiteralPath $Path
    if ($file.Length -le $MaximumBytes) { return }

    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        [void]$stream.Seek(-$MaximumBytes, [IO.SeekOrigin]::End)
        $bytes = [byte[]]::new($MaximumBytes)
        $count = $stream.Read($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
    [IO.File]::WriteAllBytes($Path, $bytes[0..($count - 1)])
}

$root = Split-Path -Parent $PSScriptRoot
$disc = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'disc'))
$expectedDisc = [System.IO.Path]::GetFullPath((Join-Path $root 'xmen-legends\disc'))
if (-not $disc.Equals($expectedDisc, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Unexpected disc path: $disc"
}

$runtimeDirectory = Join-Path $root "PS2Recomp\out\xmen-final3-build\ps2xRuntime\$Config"
$primaryExe = Join-Path $runtimeDirectory 'ps2EntryRunner.exe'
$stagedExe = Join-Path $runtimeDirectory 'ps2EntryRunner.next.exe'
$exe = if ($RuntimePath) {
    [System.IO.Path]::GetFullPath($RuntimePath)
} else {
    switch ($RuntimeVariant) {
        'Primary' { $primaryExe }
        'Staged' { $stagedExe }
        'Candidate' { Join-Path $runtimeDirectory 'ps2EntryRunner.candidate.exe' }
        default {
            if (Test-Path -LiteralPath $stagedExe -PathType Leaf) {
                $stagedExe
            } else {
                $primaryExe
            }
        }
    }
}
$optimizedRuntime = [bool]$RuntimePath -or $RuntimeVariant -ne 'Primary'
$startupScript = Join-Path $PSScriptRoot 'dev-overrides\set-startup-movie-bypass.ps1'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw "Runtime executable does not exist: $exe"
}

$existingRuntime = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -like 'ps2EntryRunner*' }
if ($existingRuntime) {
    throw "A PS2 runtime is already running (PID $($existingRuntime.Id -join ', '))."
}

$process = $null
$started = $false
$statusPath = Join-Path $runtimeDirectory 'interactive-session.json'
$stdoutPath = Join-Path $runtimeDirectory 'interactive-session.out.log'
$stderrPath = Join-Path $runtimeDirectory 'interactive-session.err.log'
$logWriters = @{}
$status = [ordered]@{
    RecordedAtUtc = [DateTime]::UtcNow.ToString('o'); Running = $false; ProcessId = 0
    Executable = $exe; Sha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    HostInput = $true; CompiledVu = ($optimizedRuntime -or [bool]$CompiledVu); CompiledCallsLowerBound = 0L
    CompiledStreamCompletedLowerBound = 0L
    DirectMapStart = ($StartupMovieMode -eq 'GameplayMapNoMovie')
    NewGameHandler = $false; LevelPackage = $false; LastPresent = 0L
    GuestFaultLines = 0; FirstGuestFault = $null; ReadyForInput = $false; ExitCode = $null
    StdoutLog = $stdoutPath; StderrLog = $stderrPath; LastOutputLine = $null; LastErrorLine = $null
}
try {
    & $startupScript -Mode $StartupMovieMode
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $exe
    $startInfo.WorkingDirectory = $disc
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    [void]$startInfo.ArgumentList.Add('.\SLUS_206.56')

    foreach ($name in @($startInfo.Environment.Keys)) {
        if ($name.StartsWith('PS2X_', [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$startInfo.Environment.Remove($name)
        }
    }
    if ($FastBranchHooks -and $CompatibilityBranchHooks) {
        throw '-FastBranchHooks and -CompatibilityBranchHooks cannot be combined.'
    }
    if (-not $CompatibilityBranchHooks) {
        $startInfo.Environment['PS2X_BYPASS_XMEN_BRANCH_HOOKS'] = '1'
    }
    $startInfo.Environment['PS2X_XMEN_HOST_CLOCK'] = '1'
    $startInfo.Environment['PS2X_FAST_FORWARD_XMEN_LEGAL'] = '1'
    if ($optimizedRuntime) {
        $startInfo.Environment['PS2X_VU_NATIVE_PAIRS'] = '1'
        $startInfo.Environment['PS2X_VU_NATIVE_BLOCKS'] = '1'
        $startInfo.Environment['PS2X_VU_COMPILED'] = '1'
        $startInfo.Environment['PS2X_VU_COMPILED_STATS'] = '1'
        $startInfo.Environment['PS2X_VU_COMPILED_EFU'] = '1'
        $startInfo.Environment['PS2X_VU_COMPILED_STREAM'] = '1'
        if ($CompiledStreamBatch) {
            $startInfo.Environment['PS2X_VU_COMPILED_STREAM_BATCH'] = '1'
        }
        $startInfo.Environment['PS2X_VU_COMPILED_STREAM_BLOCK_BYTES'] = $CompiledStreamBlockBytes.ToString()
        $startInfo.Environment['PS2X_VU_RETAIN_BLOCK_CACHE'] = '1'
        $startInfo.Environment['PS2X_GUEST_BUMP_REALLOC'] = '1'
        $startInfo.Environment['PS2X_GS_PLAY_VULKAN'] = '1'
    }
    elseif ($CompiledVu) {
        $startInfo.Environment['PS2X_VU_COMPILED'] = '1'
        $startInfo.Environment['PS2X_VU_COMPILED_STATS'] = '1'
    }
    if ($Diagnostics) {
        $startInfo.Environment['PS2X_XMEN_DIAGNOSTICS'] = '1'
        $startInfo.Environment['PS2X_XMEN_PROGRESS_TRACE'] = '1'
        $startInfo.Environment['PS2X_CAPTURE_LATEST_PRESENT_INTERVAL'] = '128'
    }
    if ($Vu1ServiceTraceMinTick -gt 0) {
        $startInfo.Environment['PS2X_VU1_SERVICE_TRACE_MIN_TICK'] = $Vu1ServiceTraceMinTick.ToString()
    }
    if ($StartupMovieMode -eq 'TitleGameplayFirst') {
        $startInfo.Environment['PS2X_XMEN_START_FIRST_LEVEL'] = '1'
    }
    if ($WhiteWireframe) {
        $startInfo.Environment['PS2X_DEBUG_WHITE_WIREFRAME'] = '1'
    }
    if ($SuppressLateSprites) {
        if (-not $WhiteWireframe) {
            throw '-SuppressLateSprites requires -WhiteWireframe.'
        }
        $startInfo.Environment['PS2X_DEBUG_WHITE_WIREFRAME_NO_LATE_SPRITES'] = '1'
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $process.Start()
    if (-not $started) {
        throw 'Failed to start ps2EntryRunner.'
    }

    # Retain only a small status record, not the unbounded diagnostic stream.
    $streams = @{ out = $process.StandardOutput; err = $process.StandardError }
    $logWriters = @{
        out = [IO.StreamWriter]::new($stdoutPath, $false, [Text.UTF8Encoding]::new($false))
        err = [IO.StreamWriter]::new($stderrPath, $false, [Text.UTF8Encoding]::new($false))
    }
    $tasks = @{}
    foreach ($key in $streams.Keys) { $tasks[$key] = $streams[$key].ReadLineAsync() }
    $status.Running = $true
    $status.ProcessId = $process.Id
    $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal
    $process.ProcessorAffinity = [IntPtr]0xF

    "Interactive X-Men Legends runtime started (PID $($process.Id), binary $([IO.Path]::GetFileName($exe)))."
    'Close the game window normally to end the session and restore the retail startup package.'
    'Keyboard: WASD move, IJKL camera, arrows D-pad, Z/X/C/V face buttons, Enter Start.'

    $nextStatus = [DateTime]::MinValue
    while ($tasks.Count -gt 0 -or !$process.HasExited) {
        $readAny = $false
        foreach ($key in @($tasks.Keys)) {
            for ($count = 0; $count -lt 256 -and $tasks.ContainsKey($key) -and $tasks[$key].IsCompleted; ++$count) {
                $line = $tasks[$key].GetAwaiter().GetResult()
                if ($null -eq $line) { $tasks.Remove($key); break }
                $readAny = $true
                $logWriters[$key].WriteLine($line)
                Update-InteractiveStatus $status $line $key
                $tasks[$key] = $streams[$key].ReadLineAsync()
            }
        }
        if ([DateTime]::UtcNow -ge $nextStatus) {
            foreach ($writer in $logWriters.Values) { $writer.Flush() }
            $status.RecordedAtUtc = [DateTime]::UtcNow.ToString('o')
            $status | ConvertTo-Json | Set-Content -LiteralPath $statusPath
            $nextStatus = [DateTime]::UtcNow.AddSeconds(2)
        }
        if (!$readAny) { Start-Sleep -Milliseconds 5 }
    }
    $process.WaitForExit()
    $status.ExitCode = $process.ExitCode
    "Runtime exited with code $($process.ExitCode)."
}
finally {
    foreach ($writer in $logWriters.Values) {
        try { $writer.Flush(); $writer.Dispose() } catch {}
    }
    Limit-LogFile $stdoutPath
    Limit-LogFile $stderrPath
    if ($null -ne $process) {
        if ($started) {
            $process.Refresh()
            if (-not $process.HasExited) {
                $process.Kill()
                $process.WaitForExit()
            }
        }
        $process.Dispose()
    }

    $status.Running = $false
    $status.ReadyForInput = $false
    $status.RecordedAtUtc = [DateTime]::UtcNow.ToString('o')
    try { $status | ConvertTo-Json | Set-Content -LiteralPath $statusPath }
    finally { & $startupScript -Mode Restore }
}
