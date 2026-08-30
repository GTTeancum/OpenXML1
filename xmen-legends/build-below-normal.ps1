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
    '--parallel', $Parallel,
    '--',
    '/nodeReuse:false',
    '/p:UseSharedCompilation=false'
)
$env:MSBUILDDISABLENODEREUSE = '1'
$buildProcessIds = [System.Collections.Generic.HashSet[int]]::new()
$preexistingMsBuildIds = [System.Collections.Generic.HashSet[int]]::new()
foreach ($existingMsBuild in Get-Process -Name 'MSBuild' -ErrorAction SilentlyContinue) {
    [void]$preexistingMsBuildIds.Add($existingMsBuild.Id)
}

$process = Start-Process -FilePath 'cmake.exe' `
    -ArgumentList $arguments `
    -WorkingDirectory $repoRoot `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -PassThru
$process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
$process.ProcessorAffinity = [IntPtr]0xF
[void]$buildProcessIds.Add($process.Id)

function Set-BuildTreePriority {
    param([int]$RootProcessId)

    $pending = [System.Collections.Generic.Queue[int]]::new()
    $pending.Enqueue($RootProcessId)
    while ($pending.Count -gt 0) {
        $parentId = $pending.Dequeue()
        foreach ($child in Get-CimInstance Win32_Process -Filter "ParentProcessId = $parentId") {
            [void]$buildProcessIds.Add([int]$child.ProcessId)
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

    foreach ($name in @('cmake', 'MSBuild', 'cl', 'link')) {
        foreach ($compilerProcess in Get-Process -Name $name -ErrorAction SilentlyContinue) {
            try {
                $compilerProcess.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
                $compilerProcess.ProcessorAffinity = [IntPtr]0xF
            }
            catch {
                # A process can exit between enumeration and the priority update.
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
function Remove-DetachedBuildWorkers {
    foreach ($processId in $buildProcessIds) {
        $trackedProcess = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($trackedProcess -and
            $trackedProcess.ProcessName -in @('cmake', 'MSBuild', 'cl', 'link')) {
            try {
                $trackedProcess.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
                Stop-Process -Id $processId -Force -ErrorAction Stop
            }
            catch {
                # A tracked build process can exit while cleanup is running.
            }
        }
    }

    foreach ($worker in Get-CimInstance Win32_Process -Filter "Name='MSBuild.exe'") {
        if ($preexistingMsBuildIds.Contains([int]$worker.ProcessId) -or
            (Get-Process -Id $worker.ParentProcessId -ErrorAction SilentlyContinue)) {
            continue
        }

        try {
            $workerProcess = Get-Process -Id $worker.ProcessId -ErrorAction Stop
            $workerProcess.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
            Stop-Process -Id $worker.ProcessId -Force -ErrorAction Stop
        }
        catch {
            # A detached worker can exit while cleanup is running.
        }
    }
}

Remove-DetachedBuildWorkers
foreach ($cleanupPass in 1..5) {
    Start-Sleep -Milliseconds 400
    Remove-DetachedBuildWorkers
}
Get-Content -LiteralPath $stdoutPath
if ((Get-Item -LiteralPath $stderrPath).Length -gt 0) {
    Get-Content -LiteralPath $stderrPath
}
exit $process.ExitCode
