param(
    [ValidateSet('GameplayMap', 'GameplayMapNoMovie', 'GameplayMissionNoMovie')]
    [string]$StartupMovieMode = 'GameplayMissionNoMovie',

    [ValidateSet('Debug', 'Release', 'RelWithDebInfo', 'MinSizeRel')]
    [string]$Config = 'Release',

    [ValidateSet('Auto', 'Primary', 'Staged')]
    [string]$RuntimeVariant = 'Auto',

    [switch]$FastBranchHooks
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$disc = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'disc'))
$expectedDisc = [System.IO.Path]::GetFullPath((Join-Path $root 'xmen-legends\disc'))
if (-not $disc.Equals($expectedDisc, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Unexpected disc path: $disc"
}

$runtimeDirectory = Join-Path $root "PS2Recomp\out\xmen-final3-build\ps2xRuntime\$Config"
$primaryExe = Join-Path $runtimeDirectory 'ps2EntryRunner.exe'
$stagedExe = Join-Path $runtimeDirectory 'ps2EntryRunner.next.exe'
$exe = switch ($RuntimeVariant) {
    'Primary' { $primaryExe }
    'Staged' { $stagedExe }
    default {
        if (Test-Path -LiteralPath $stagedExe -PathType Leaf) {
            $stagedExe
        } else {
            $primaryExe
        }
    }
}
$startupScript = Join-Path $PSScriptRoot 'dev-overrides\set-startup-movie-bypass.ps1'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw "Runtime executable does not exist: $exe"
}

$existingRuntime = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -like 'ps2EntryRunner*' }
if ($existingRuntime) {
    throw "A PS2 runtime is already running (PID $($existingRuntime.Id -join ', '))."
}

& $startupScript -Mode $StartupMovieMode

$process = $null
try {
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
    if ($FastBranchHooks) {
        $startInfo.Environment['PS2X_BYPASS_XMEN_BRANCH_HOOKS'] = '1'
    }
    $startInfo.Environment['PS2X_XMEN_HOST_CLOCK'] = '1'
    $startInfo.Environment['PS2X_FAST_FORWARD_XMEN_LEGAL'] = '1'
    $startInfo.Environment['PS2X_XMEN_PROGRESS_TRACE'] = '1'

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Failed to start ps2EntryRunner.'
    }

    # Drain diagnostic streams without retaining multi-gigabyte probe logs.
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()
    $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal
    $process.ProcessorAffinity = [IntPtr]0xF

    "Interactive X-Men Legends runtime started (PID $($process.Id), binary $([IO.Path]::GetFileName($exe)))."
    'Close the game window normally to end the session and restore the retail startup package.'
    'Keyboard: WASD move, IJKL camera, arrows D-pad, Z/X/C/V face buttons, Enter Start.'

    while (-not $process.WaitForExit(500)) {
        # Keep the wrapper alive so its finally block restores the disc package.
    }
    "Runtime exited with code $($process.ExitCode)."
}
finally {
    if ($null -ne $process) {
        $process.Refresh()
        if (-not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        $process.Dispose()
    }

    & $startupScript -Mode Restore
}
