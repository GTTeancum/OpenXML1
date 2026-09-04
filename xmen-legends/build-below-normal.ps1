param(
    [ValidateSet('Debug', 'Release', 'RelWithDebInfo', 'MinSizeRel')]
    [string]$Config = 'Release',

    [string]$Target = 'ps2EntryRunner',

    [string]$BuildPath = '',

    [ValidateRange(1, 64)]
    [int]$Parallel = 1,

    [ValidateRange(128, 16384)]
    [int]$MaxCompilerMiB = 2048,

    [string]$SelectedSource = '',

    [switch]$DisableOptimization,

    [switch]$LinkOnly,

    [switch]$CompileOnly,

    [string]$OutputName = ''
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

if (($SelectedSource -and ($LinkOnly -or $CompileOnly)) -or ($LinkOnly -and $CompileOnly)) {
    throw 'SelectedSource, LinkOnly, and CompileOnly cannot be used together.'
}
if ($OutputName -and -not $LinkOnly) {
    throw 'OutputName requires LinkOnly.'
}
if ($OutputName -and $OutputName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
    throw "OutputName is not a valid file name: $OutputName"
}
if ($DisableOptimization -and -not $SelectedSource) {
    throw 'DisableOptimization requires SelectedSource.'
}

$buildExecutable = 'cmake.exe'
$workingDirectory = $repoRoot
$logStem = 'build-below-normal'
$archiveArguments = @()
if ($SelectedSource -or $LinkOnly -or $CompileOnly) {
    if ($SelectedSource) {
        $SelectedSource = [System.IO.Path]::GetFullPath($SelectedSource)
        if (-not (Test-Path -LiteralPath $SelectedSource -PathType Leaf)) {
            throw "Selected source does not exist: $SelectedSource"
        }

        $projectFiles = @(Get-ChildItem -LiteralPath $BuildPath -Recurse -File -Filter '*.vcxproj')
        $selectedBuildSources = @()
        $unityIncludeNeedle = '#include "' + $SelectedSource.Replace('\', '/') + '"'
        $unitySources = @(Get-ChildItem -LiteralPath $BuildPath -Recurse -File -Filter 'unity_*_cxx.cxx' |
            Where-Object {
                Select-String -LiteralPath $_.FullName -SimpleMatch $unityIncludeNeedle -Quiet
            })
        $unityOwners = @()
        foreach ($unitySource in $unitySources) {
            $unityProjectNeedle = '<ClCompile Include="' + $unitySource.FullName + '"'
            foreach ($projectFile in $projectFiles) {
                if (Select-String -LiteralPath $projectFile.FullName `
                        -SimpleMatch $unityProjectNeedle -Quiet) {
                    $unityOwners += [pscustomobject]@{
                        Project = $projectFile
                        Source = $unitySource
                    }
                }
            }
        }

        if ($unityOwners.Count -gt 0) {
            $owningProjects = @($unityOwners.Project | Sort-Object FullName -Unique)
            $selectedBuildSources = @($unityOwners.Source.FullName | Sort-Object -Unique)
        }
        else {
            $projectNeedle = '<ClCompile Include="' + $SelectedSource + '"'
            $owningProjects = @($projectFiles | Where-Object {
                Select-String -LiteralPath $_.FullName -SimpleMatch $projectNeedle -Quiet
            })
            $selectedBuildSources = @($SelectedSource)
        }

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
        [xml]$projectXml = Get-Content -LiteralPath $projectPath -Raw
        $configurationCondition = "'`$(Configuration)|`$(Platform)'=='$Config|x64'"
        $configurationGroups = @($projectXml.Project.PropertyGroup | Where-Object {
            $_.Label -eq 'Configuration' -and
            $_.Condition.Replace(' ', '') -eq $configurationCondition
        })
        if ($configurationGroups.Count -ne 1) {
            throw "Cannot identify the $Config configuration in $projectPath."
        }
        if ($configurationGroups[0].ConfigurationType -eq 'StaticLibrary') {
            # Re-evaluate without SelectedFiles so the archive retains every object.
            $archiveArguments = @($arguments | Where-Object { $_ -ne '/t:ClCompile' })
            $archiveArguments += '/t:_Lib'
            $archiveArguments += '/p:BuildProjectReferences=false'
        }
        $arguments += "/p:SelectedFiles=$($selectedBuildSources -join ';')"
        $arguments += '/p:SelectedFilesBuildPCH=false'
        $logStem = 'build-selected-below-normal'
        "SELECTED_SOURCE_MAP REQUEST=$SelectedSource EFFECTIVE=$($selectedBuildSources -join ';')"
    }
    elseif ($LinkOnly) {
        $arguments += '/p:Link_MinimalRebuildFromTracking=false'
        $arguments += '/p:BuildProjectReferences=false'
        if ($OutputName) {
            $arguments += "/p:TargetName=$OutputName"
        }
        $logStem = 'link-below-normal'
    }
    else {
        # Dependencies must already be built; do not link or replace the primary.
        $arguments += '/p:BuildProjectReferences=false'
        $arguments += '/p:ForceRebuild=true'
        $logStem = 'compile-below-normal'
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

if (-not ('OpenXml1BuildJob' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class OpenXml1BuildJob
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool TerminateJobObject(IntPtr job, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CloseHandle(IntPtr handle);
}
'@
}

$previousClAfterOptions = [Environment]::GetEnvironmentVariable('_CL_', 'Process')
$jobHandle = [IntPtr]::Zero
$startGate = $null
$process = $null
try {
    if ($DisableOptimization) {
        $clAfterOptions = @($previousClAfterOptions, '/Od') |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        [Environment]::SetEnvironmentVariable('_CL_', ($clAfterOptions -join ' '), 'Process')
    }

    $gateName = "Local\OpenXml1Build-$PID-$([Guid]::NewGuid().ToString('N'))"
    $startGate = [Threading.EventWaitHandle]::new(
        $false,
        [Threading.EventResetMode]::ManualReset,
        $gateName)
    $payload = @{
        EventName = $gateName
        Executable = $buildExecutable
        Arguments = @($arguments)
        ArchiveArguments = @($archiveArguments)
        WorkingDirectory = $workingDirectory
        StdoutPath = $stdoutPath
        StderrPath = $stderrPath
    } | ConvertTo-Json -Compress
    $payloadBase64 = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($payload))
    $wrapperSource = @'
$ErrorActionPreference = 'Stop'
$payloadJson = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String($env:OPENXML1_BUILD_PAYLOAD))
$payload = $payloadJson | ConvertFrom-Json
$gate = [Threading.EventWaitHandle]::OpenExisting($payload.EventName)
try {
    [void]$gate.WaitOne()
    Set-Location -LiteralPath $payload.WorkingDirectory
    & $payload.Executable @($payload.Arguments) `
        1> $payload.StdoutPath `
        2> $payload.StderrPath
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    if ($payload.ArchiveArguments.Count -gt 0) {
        & $payload.Executable @($payload.ArchiveArguments) `
            1>> $payload.StdoutPath `
            2>> $payload.StderrPath
    }
    exit $LASTEXITCODE
}
finally {
    $gate.Dispose()
}
'@
    $encodedWrapper = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($wrapperSource))
    $wrapperExecutable = (Get-Process -Id $PID).Path
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $wrapperExecutable
    $startInfo.WorkingDirectory = $workingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.Environment['OPENXML1_BUILD_PAYLOAD'] = $payloadBase64
    [void]$startInfo.ArgumentList.Add('-NoProfile')
    [void]$startInfo.ArgumentList.Add('-NonInteractive')
    [void]$startInfo.ArgumentList.Add('-EncodedCommand')
    [void]$startInfo.ArgumentList.Add($encodedWrapper)

    $jobHandle = [OpenXml1BuildJob]::CreateJobObject([IntPtr]::Zero, $null)
    if ($jobHandle -eq [IntPtr]::Zero) {
        throw [ComponentModel.Win32Exception]::new(
            [Runtime.InteropServices.Marshal]::GetLastWin32Error())
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Failed to start the gated build process.'
    }
    if (-not [OpenXml1BuildJob]::AssignProcessToJobObject(
            $jobHandle,
            $process.Handle)) {
        throw [ComponentModel.Win32Exception]::new(
            [Runtime.InteropServices.Marshal]::GetLastWin32Error())
    }
    $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
    $process.ProcessorAffinity = [IntPtr]0xF
    [void]$startGate.Set()
}
catch {
    if ($jobHandle -ne [IntPtr]::Zero) {
        [void][OpenXml1BuildJob]::TerminateJobObject($jobHandle, 1u)
        [void][OpenXml1BuildJob]::CloseHandle($jobHandle)
        $jobHandle = [IntPtr]::Zero
    }
    if ($null -ne $startGate) {
        $startGate.Dispose()
        $startGate = $null
    }
    if ($null -ne $process) {
        $process.Dispose()
        $process = $null
    }
    throw
}
finally {
    [Environment]::SetEnvironmentVariable('_CL_', $previousClAfterOptions, 'Process')
}
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
            $memoryViolation = $null
            try {
                $childProcess = Get-Process -Id $child.ProcessId -ErrorAction Stop
                $childProcess.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
                $childProcess.ProcessorAffinity = [IntPtr]0xF
                if ($child.Name -in @('cl.exe', 'c1xx.exe', 'c2.exe', 'link.exe') -and
                    $childProcess.PrivateMemorySize64 -gt [long]$MaxCompilerMiB * 1MB) {
                    $memoryViolation = "Compiler $($child.Name) PID $($child.ProcessId) exceeded $MaxCompilerMiB MiB of private memory."
                }
            }
            catch {
                # Short-lived compiler helpers may exit while the process tree is sampled.
            }
            if ($memoryViolation) {
                throw $memoryViolation
            }
        }
    }

}

$buildExitCode = 1
try {
    while (-not $process.HasExited) {
        Set-BuildTreePriority -RootProcessId $process.Id
        Start-Sleep -Milliseconds 100
        $process.Refresh()
    }
    $process.WaitForExit()
    $buildExitCode = $process.ExitCode
}
finally {
    if ($jobHandle -ne [IntPtr]::Zero) {
        [void][OpenXml1BuildJob]::TerminateJobObject($jobHandle, 1u)
        [void][OpenXml1BuildJob]::CloseHandle($jobHandle)
        $jobHandle = [IntPtr]::Zero
    }
    if ($null -ne $startGate) {
        $startGate.Dispose()
    }
    if ($null -ne $process) {
        $process.Dispose()
    }
}

Get-Content -LiteralPath $stdoutPath
if ((Get-Item -LiteralPath $stderrPath).Length -gt 0) {
    Get-Content -LiteralPath $stderrPath
}
exit $buildExitCode
