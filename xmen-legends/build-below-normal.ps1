param(
    [ValidateSet('Debug', 'Release', 'RelWithDebInfo', 'MinSizeRel')]
    [string]$Config = 'Release',

    [string]$Target = 'ps2EntryRunner',

    [string]$BuildPath = '',

    [ValidateRange(1, 64)]
    [int]$Parallel = 1
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $BuildPath) {
    $BuildPath = Join-Path $repoRoot 'PS2Recomp\out\xmen-final3-build'
}
$BuildPath = [System.IO.Path]::GetFullPath($BuildPath)
if (-not (Test-Path -LiteralPath $BuildPath -PathType Container)) {
    throw "Build directory does not exist: $BuildPath"
}

$stdoutPath = Join-Path $BuildPath 'build-below-normal.out.log'
$stderrPath = Join-Path $BuildPath 'build-below-normal.err.log'
$arguments = @(
    '--build', $BuildPath,
    '--config', $Config,
    '--target', $Target,
    '--parallel', $Parallel
)

$process = Start-Process -FilePath 'cmake.exe' `
    -ArgumentList $arguments `
    -WorkingDirectory $repoRoot `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -PassThru
$process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
$process.ProcessorAffinity = [IntPtr]0xF

function Set-BuildTreePriority {
    param([int]$RootProcessId)

    $pending = [System.Collections.Generic.Queue[int]]::new()
    $pending.Enqueue($RootProcessId)
    while ($pending.Count -gt 0) {
        $parentId = $pending.Dequeue()
        foreach ($child in Get-CimInstance Win32_Process -Filter "ParentProcessId = $parentId") {
            $pending.Enqueue([int]$child.ProcessId)
            try {
                $childProcess = Get-Process -Id $child.ProcessId -ErrorAction Stop
                $childProcess.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
                $childProcess.ProcessorAffinity = [IntPtr]0xF
            }
            catch {
                # Short-lived compiler helpers may exit while the process tree is sampled.
            }
        }
    }
}

try {
    while (-not $process.HasExited) {
        Set-BuildTreePriority -RootProcessId $process.Id
        Start-Sleep -Milliseconds 100
        $process.Refresh()
    }
}
finally {
    if (-not $process.HasExited) {
        $process.WaitForExit()
    }
}

$process.WaitForExit()
Get-Content -LiteralPath $stdoutPath
if ((Get-Item -LiteralPath $stderrPath).Length -gt 0) {
    Get-Content -LiteralPath $stderrPath
}
exit $process.ExitCode
