param([switch]$Unity)
$ErrorActionPreference = 'Stop'
$helper = Join-Path (Split-Path -Parent $PSScriptRoot) 'build-below-normal.ps1'
$source = Join-Path $PSScriptRoot 'selected-build'
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$build = Join-Path $tempRoot "OpenXML1-selected-build-$([Guid]::NewGuid().ToString('N'))"
$process = Get-Process -Id $PID
$previousPriority = $process.PriorityClass
$previousAffinity = $process.ProcessorAffinity
$previousCl = $env:_CL_
try {
    $process.PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal
    $process.ProcessorAffinity = [IntPtr]0xF
    $env:_CL_ = ''
    & cmake -S $source -B $build -G 'Visual Studio 17 2022' -A x64 `
        "-DCMAKE_UNITY_BUILD=$(if ($Unity) { 'ON' } else { 'OFF' })"
    if ($LASTEXITCODE -ne 0) { throw 'Fixture configuration failed.' }
    & $helper -BuildPath $build -Target selected_runner
    if ($LASTEXITCODE -ne 0) { throw 'Fixture build failed.' }
    $exe = Join-Path $build 'ps2xRuntime\Release\selected_runner.exe'
    if ((& $exe) -ne '18') { throw 'Incorrect initial library contents.' }
    $originalHash = (Get-FileHash -LiteralPath $exe).Hash
    & $helper -BuildPath $build -ConfigureCache 'CMAKE_VERBOSE_MAKEFILE:BOOL=ON'
    if ($LASTEXITCODE -ne 0 -or -not (Select-String -LiteralPath (Join-Path $build 'CMakeCache.txt') `
            -Pattern '^CMAKE_VERBOSE_MAKEFILE:BOOL=ON$' -Quiet)) {
        throw 'Resource-limited cache reconfiguration failed.'
    }
    if ((Get-FileHash -LiteralPath $exe).Hash -ne $originalHash) {
        throw 'Reconfiguration modified the saved executable.'
    }
    $rejected = $false
    try { & $helper -BuildPath $build -ConfigureCache '-G=invalid' }
    catch {
        if ($_.Exception.Message -notlike '*Invalid CMake cache definition*') { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw 'Invalid cache definition was accepted.' }
    $retainedObject = Join-Path $build 'ps2xRuntime\selected_fixture.dir\Release\retained.obj'
    if (-not $Unity) { $retainedTime = (Get-Item -LiteralPath $retainedObject).LastWriteTimeUtc }
    $env:_CL_ = '/DSELECTED_BUILD_VALUE=29'
    & $helper -BuildPath $build -SelectedSource (Join-Path $source 'ps2xRuntime\selected.cpp')
    if ($LASTEXITCODE -ne 0) { throw 'Selected compilation/archive failed.' }
    $env:_CL_ = ''
    if (-not $Unity -and (Get-Item -LiteralPath $retainedObject).LastWriteTimeUtc -ne $retainedTime) {
        throw 'Unselected source was recompiled.'
    }
    & $helper -BuildPath $build -Target selected_runner -LinkOnly -OutputName selected_candidate
    if ($LASTEXITCODE -ne 0) { throw 'Candidate relink failed.' }
    $candidate = Join-Path $build 'ps2xRuntime\Release\selected_candidate.exe'
    if ((& $candidate) -ne '36') { throw 'Candidate did not link the updated complete archive.' }
    if ((Get-FileHash -LiteralPath $exe).Hash -ne $originalHash) { throw 'Primary executable was modified.' }
    $candidateHash = (Get-FileHash -LiteralPath $candidate).Hash
    $env:_CL_ = '/DRUNNER_BUILD_BONUS=5'
    & $helper -BuildPath $build -Target selected_runner -CompileOnly
    if ($LASTEXITCODE -ne 0) { throw 'Compile-only runner build failed.' }
    $compileSteps = @(Select-String -LiteralPath (Join-Path $build 'compile-below-normal.out.log') `
        -Pattern '^COMPILE_SOURCE ')
    if ($compileSteps.Count -ne 3 -or $compileSteps[0].Line -notmatch 'cmake_pch.cxx') {
        throw 'Compile-only must build the PCH first, then each of the two sources separately.'
    }
    $env:_CL_ = ''
    if ((Get-FileHash -LiteralPath $exe).Hash -ne $originalHash -or
        (Get-FileHash -LiteralPath $candidate).Hash -ne $candidateHash) {
        throw 'Compile-only replaced an executable.'
    }
    & $helper -BuildPath $build -Target selected_runner -LinkOnly -OutputName selected_candidate
    if ($LASTEXITCODE -ne 0 -or (& $candidate) -ne '51') {
        throw 'Candidate did not use the compile-only runner and retained library.'
    }
    $candidateHash = (Get-FileHash -LiteralPath $candidate).Hash
    $env:_CL_ = '/DRUNNER_BUILD_BONUS=intentionally_invalid_identifier'
    & $helper -BuildPath $build -Target selected_runner -CompileOnly | Out-Null
    if ($LASTEXITCODE -eq 0) { throw 'Invalid runner source unexpectedly compiled.' }
    if ((Get-FileHash -LiteralPath $exe).Hash -ne $originalHash -or
        (Get-FileHash -LiteralPath $candidate).Hash -ne $candidateHash) {
        throw 'Failed compile-only changed a saved executable.'
    }
    $library = Join-Path $build 'ps2xRuntime\Release\selected_fixture.lib'
    $libraryHash = (Get-FileHash -LiteralPath $library).Hash
    $libraryTime = (Get-Item -LiteralPath $library).LastWriteTimeUtc
    $env:_CL_ = '/DSELECTED_BUILD_VALUE=intentionally_invalid_identifier'
    & $helper -BuildPath $build -SelectedSource (Join-Path $source 'ps2xRuntime\selected.cpp') | Out-Null
    if ($LASTEXITCODE -eq 0) { throw 'Invalid source unexpectedly compiled.' }
    if ((Get-FileHash -LiteralPath $library).Hash -ne $libraryHash -or
        (Get-Item -LiteralPath $library).LastWriteTimeUtc -ne $libraryTime) {
        throw 'A failed compilation modified the library.'
    }
    "PASS reconfiguration, selected archive, retained object, compile-only runner, candidate relink, primary preservation, compile failure (unity=$Unity)"
}
finally {
    $env:_CL_ = $previousCl
    $process.PriorityClass = $previousPriority
    $process.ProcessorAffinity = $previousAffinity
    $resolvedBuild = [IO.Path]::GetFullPath($build)
    if (-not $resolvedBuild.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedBuild) -notlike 'OpenXML1-selected-build-*') {
        throw "Refusing cleanup outside the test temporary directory: $resolvedBuild"
    }
    if (Test-Path -LiteralPath $resolvedBuild) { Remove-Item -LiteralPath $resolvedBuild -Recurse -Force }
}
exit 0
