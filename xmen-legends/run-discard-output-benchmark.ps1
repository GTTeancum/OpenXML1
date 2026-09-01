param(
    [ValidateRange(1, 3600)]
    [int]$TimeoutSeconds = 180,

    [ValidateRange(0, [int]::MaxValue)]
    [int]$TargetPresent = 24,

    [ValidateRange(-1, [int]::MaxValue)]
    [int]$SkipCpuRasterBeforePresent = 925,

    [switch]$BypassBranchHooks,

    [ValidateSet('GameplayMap', 'GameplayMapNoMovie', 'GameplayMissionNoMovie')]
    [string]$StartupMovieMode = 'GameplayMissionNoMovie'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$disc = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'disc'))
$expectedDisc = [System.IO.Path]::GetFullPath((Join-Path $root 'xmen-legends\disc'))
if (-not $disc.Equals($expectedDisc, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Unexpected disc path: $disc"
}

$exe = Join-Path $root 'PS2Recomp\out\xmen-final3-build\ps2xRuntime\Release\ps2EntryRunner.exe'
$startupScript = Join-Path $PSScriptRoot 'dev-overrides\set-startup-movie-bypass.ps1'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw "Runtime executable does not exist: $exe"
}

Get-ChildItem -LiteralPath $disc -File -Filter 'gs-present-*.ppm' |
    ForEach-Object {
        $parent = [System.IO.Path]::GetDirectoryName($_.FullName)
        if (-not $parent.Equals($disc, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove unexpected path: $($_.FullName)"
        }
        Remove-Item -LiteralPath $_.FullName -Force
    }

& $startupScript -Mode $StartupMovieMode

$process = $null
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$result = 0
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
    if ($StartupMovieMode -ne 'GameplayMissionNoMovie') {
        $startInfo.Environment['PS2X_XMEN_START_FIRST_LEVEL'] = '1'
    }
    $startInfo.Environment['PS2X_XMEN_HOST_CLOCK'] = '1'
    $startInfo.Environment['PS2X_FAST_FORWARD_XMEN_LEGAL'] = '1'
    $startInfo.Environment['PS2X_DUMP_PRESENT_RANGE'] = "$TargetPresent-$TargetPresent"
    if ($BypassBranchHooks) {
        $startInfo.Environment['PS2X_BYPASS_XMEN_BRANCH_HOOKS'] = '1'
    }
    if ($SkipCpuRasterBeforePresent -ge 0) {
        $startInfo.Environment['PS2X_SKIP_CPU_RASTER_BEFORE_PRESENT'] =
            $SkipCpuRasterBeforePresent.ToString()
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Failed to start ps2EntryRunner.'
    }
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()
    $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal
    $process.ProcessorAffinity = [IntPtr]0xF
    "PID=$($process.Id)"

    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    while (-not $process.HasExited -and $stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        foreach ($file in Get-ChildItem -LiteralPath $disc -File -Filter 'gs-present-*.ppm' |
            Sort-Object LastWriteTimeUtc) {
            if (-not $seen.Add($file.Name)) {
                continue
            }

            "FRAME=$($file.Name) ELAPSED_MS=$($stopwatch.ElapsedMilliseconds)"
            if ($file.Name -eq "gs-present-$TargetPresent.ppm") {
                $result = 42
                break
            }
        }

        if ($result -eq 42) {
            break
        }
        Start-Sleep -Milliseconds 100
        $process.Refresh()
    }

    if ($result -ne 42) {
        "END EXITED=$($process.HasExited) ELAPSED_MS=$($stopwatch.ElapsedMilliseconds)"
    }
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

exit $result
