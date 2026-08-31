param(
    [ValidateSet('Debug', 'Release', 'RelWithDebInfo', 'MinSizeRel')]
    [string]$Config = 'Release',

    [string]$Target = 'ps2EntryRunner',

    [string]$BuildPath = '',

    [ValidateRange(1, 64)]
    [int]$Parallel = 1,

    [string]$SelectedSource = '',

    [switch]$DisableOptimization,

    [switch]$LinkOnly
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

if ($SelectedSource -and $LinkOnly) {
    throw 'SelectedSource and LinkOnly cannot be used together.'
}
if ($DisableOptimization -and -not $SelectedSource) {
    throw 'DisableOptimization requires SelectedSource.'
}

$buildExecutable = 'cmake.exe'
$workingDirectory = $repoRoot
$logStem = 'build-below-normal'
if ($SelectedSource -or $LinkOnly) {
    if ($SelectedSource) {
        $SelectedSource = [System.IO.Path]::GetFullPath($SelectedSource)
        if (-not (Test-Path -LiteralPath $SelectedSource -PathType Leaf)) {
            throw "Selected source does not exist: $SelectedSource"
        }

        $projectNeedle = '<ClCompile Include="' + $SelectedSource + '"'
        $owningProjects = @(Get-ChildItem -LiteralPath $BuildPath -Recurse -File -Filter '*.vcxproj' |
            Where-Object {
                Select-String -LiteralPath $_.FullName -SimpleMatch $projectNeedle -Quiet
            })
        if ($owningProjects.Count -ne 1) {
            throw "Expected one generated project to own $SelectedSource; found $($owningProjects.Count)."
        }
        $projectPath = $owningProjects[0].FullName
    }
    else {
        $projectPath = Join-Path $BuildPath "ps2xRuntime\$Target.vcxproj"
    }
    if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
        throw "MSBuild project does not exist: $projectPath"
    }

    $cachePath = Join-Path $BuildPath 'CMakeCache.txt'
    $makeProgramLine = Select-String -LiteralPath $cachePath `
        -Pattern '^CMAKE_MAKE_PROGRAM:FILEPATH=(.+)$' | Select-Object -First 1
    if ($makeProgramLine) {
        $buildExecutable = $makeProgramLine.Matches[0].Groups[1].Value
    }
    else {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} `
            'Microsoft Visual Studio\Installer\vswhere.exe'
        if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
            throw "CMAKE_MAKE_PROGRAM is missing from $cachePath and vswhere is unavailable."
        }
        $buildExecutable = & $vswhere -latest -requires Microsoft.Component.MSBuild `
            -find 'MSBuild\**\Bin\amd64\MSBuild.exe' | Select-Object -First 1
        if (-not $buildExecutable) {
            throw 'Unable to locate the 64-bit MSBuild executable.'
        }
    }
    $workingDirectory = Split-Path -Parent $projectPath
    $arguments = @(
        $projectPath,
        $(if ($LinkOnly) { '/t:_Link' } else { '/t:ClCompile' }),
        "/p:Configuration=$Config",
        '/p:Platform=x64',
        '/m:1',
        '/v:m',
        '/nodeReuse:false',
        '/p:UseSharedCompilation=false'
    )

    if ($SelectedSource) {
        $arguments += "/p:SelectedFiles=$SelectedSource"
        $arguments += '/p:SelectedFilesBuildPCH=false'
        $logStem = 'build-selected-below-normal'
    }
    else {
        $arguments += '/p:Link_MinimalRebuildFromTracking=false'
        $logStem = 'link-below-normal'
    }
}
else {
    $arguments = @(
        '--build', $BuildPath,
        '--config', $Config,
        '--target', $Target,
        '--parallel', $Parallel,
        '--',
        '/nodeReuse:false',
        '/p:UseSharedCompilation=false'
    )
}

$stdoutPath = Join-Path $BuildPath "$logStem.out.log"
$stderrPath = Join-Path $BuildPath "$logStem.err.log"
$env:MSBUILDDISABLENODEREUSE = '1'
$buildProcessIds = [System.Collections.Generic.HashSet[int]]::new()
$preexistingMsBuildIds = [System.Collections.Generic.HashSet[int]]::new()
foreach ($existingMsBuild in Get-Process -Name 'MSBuild' -ErrorAction SilentlyContinue) {
    [void]$preexistingMsBuildIds.Add($existingMsBuild.Id)
}

$previousClAfterOptions = [Environment]::GetEnvironmentVariable('_CL_', 'Process')
try {
    if ($DisableOptimization) {
        $clAfterOptions = @($previousClAfterOptions, '/Od') |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        [Environment]::SetEnvironmentVariable('_CL_', ($clAfterOptions -join ' '), 'Process')
    }

    $process = Start-Process -FilePath $buildExecutable `
        -ArgumentList $arguments `
        -WorkingDirectory $workingDirectory `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru
}
finally {
    [Environment]::SetEnvironmentVariable('_CL_', $previousClAfterOptions, 'Process')
}
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
