param(
    [ValidateSet('Primary', 'Staged', 'Candidate')]
    [string]$RuntimeVariant = 'Candidate',
    [switch]$PhaseProfile,
    [switch]$CoverageProfile,
    [switch]$CpuRasterProfile,
    [switch]$CaptureFrame,
    [switch]$CompiledVu,
    [switch]$CompiledRetry,
    [switch]$BestFitHeap,
    [switch]$InPlaceRealloc,
    [switch]$HeapDiagnostics,
    [switch]$HeapTrace,
    [switch]$AuditCompiledVu,
    [switch]$AuditBilinear,
    [switch]$PreparedTexture,
    [switch]$AuditPreparedTexture,
    [switch]$VulkanGs,
    [ValidateRange(30, 1800)]
    [int]$TimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
if ($HeapTrace -and !$HeapDiagnostics) { throw 'HeapTrace requires HeapDiagnostics; trace runs are never FPS measurements.' }
$root = Split-Path -Parent $PSScriptRoot
$disc = Join-Path $PSScriptRoot 'disc'
$build = Join-Path $root 'PS2Recomp/out/xmen-final3-build'
$name = switch ($RuntimeVariant) {
    'Primary' { 'ps2EntryRunner.exe' }
    'Staged' { 'ps2EntryRunner.next.exe' }
    'Candidate' { 'ps2EntryRunner.candidate.exe' }
}
$exe = (Resolve-Path -LiteralPath (Join-Path $build "ps2xRuntime/Release/$name")).Path
if (Get-Process -Name 'ps2EntryRunner*' -ErrorAction SilentlyContinue) {
    throw 'A PS2 runtime is already running; leave it under user control.'
}

# Restore only known retail entries, never silently replace unknown user edits.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead((Join-Path $disc 'Z/ASSETSFB.ZIP'))
try {
    foreach ($item in @(
        @('scripts/menus/intro_normal.py', 'intro_normal.original.py'),
        @('scripts/menus/intro_demo.py', 'intro_demo.original.py'),
        @('scripts/menus/intro_e3.py', 'intro_e3.original.py'),
        @('scripts/missions/alison.py', 'mission_alison.original.py')
    )) {
        $entry = $archive.GetEntry($item[0])
        if (!$entry) { throw "Missing startup entry: $($item[0])" }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { $actual = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $expected = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot "dev-overrides/$($item[1])")
        if (($actual -replace "`r`n", "`n") -cne ($expected -replace "`r`n", "`n")) {
            throw "Startup entry has unknown edits: $($item[0])"
        }
    }
} finally { $archive.Dispose() }

$stem = if ($AuditPreparedTexture) { 'gameplay-texture-audit' } elseif ($AuditCompiledVu) { 'gameplay-compiled-audit' } elseif ($AuditBilinear) { 'gameplay-filter-audit' } elseif ($PhaseProfile -or $CoverageProfile -or $CpuRasterProfile) { 'gameplay-phase' } elseif ($PreparedTexture) { 'gameplay-texture-rate' } elseif ($CompiledVu) { 'gameplay-compiled-rate' } else { 'gameplay-rate' }
if ($VulkanGs) {
    if ($PreparedTexture -or $AuditPreparedTexture -or $AuditBilinear -or $CpuRasterProfile) {
        throw 'VulkanGs cannot be combined with CPU raster/sampler diagnostics.'
    }
    $stem = if ($AuditCompiledVu) { 'gameplay-vulkan-audit' } elseif ($PhaseProfile -or $CoverageProfile) { 'gameplay-vulkan-phase' } else { 'gameplay-vulkan-rate' }
}
if ($CompiledRetry) {
    if (!$CompiledVu) { throw 'CompiledRetry requires CompiledVu.' }
    $stem += '-retry'
}
if ($BestFitHeap) { $stem += '-best-fit' }
if ($InPlaceRealloc) { $stem += '-realloc' }
if ($HeapDiagnostics) { $stem += '-heap-audit' }
$outLog = Join-Path $build "$stem.out.log"
$errLog = Join-Path $build "$stem.err.log"
$start = [Diagnostics.ProcessStartInfo]::new($exe)
$start.WorkingDirectory = $disc
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.ArgumentList.Add('.\SLUS_206.56')
foreach ($key in @($start.Environment.Keys)) {
    if ($key.StartsWith('PS2X_', [StringComparison]::OrdinalIgnoreCase)) {
        [void]$start.Environment.Remove($key)
    }
}
foreach ($key in @('PS2X_DISABLE_HOST_INPUT', 'PS2X_XMEN_HOST_CLOCK',
    'PS2X_FAST_FORWARD_XMEN_LEGAL', 'PS2X_BYPASS_XMEN_BRANCH_HOOKS',
    'PS2X_XMEN_START_FIRST_LEVEL', 'PS2X_VU_NATIVE_PAIRS', 'PS2X_VU_NATIVE_BLOCKS')) {
    $start.Environment[$key] = '1'
}
$start.Environment['PS2X_RUN_VSYNC_LIMIT'] = '1400'
if ($VulkanGs) { $start.Environment['PS2X_GS_PLAY_VULKAN'] = '1' }
if ($CompiledRetry) { $start.Environment['PS2X_VU_COMPILED_RETRY'] = '1' }
if ($BestFitHeap) { $start.Environment['PS2X_GUEST_BUMP_BEST_FIT'] = '1' }
if ($InPlaceRealloc) { $start.Environment['PS2X_GUEST_BUMP_REALLOC'] = '1' }
if ($HeapDiagnostics) { $start.Environment['PS2X_GUEST_BUMP_DIAGNOSTICS'] = '1' }
if ($HeapTrace) { $start.Environment['PS2X_GUEST_HEAP_TRACE'] = Join-Path $build 'gameplay-heap-trace.bin' }
if ($AuditCompiledVu -and !$CompiledVu) { throw 'AuditCompiledVu requires CompiledVu' }
if ($AuditPreparedTexture -and !$PreparedTexture) { throw 'AuditPreparedTexture requires PreparedTexture' }
if ($PreparedTexture) { $start.Environment['PS2X_GS_PREPARED_TEXTURE'] = '1' }
if ($AuditPreparedTexture) { $start.Environment['PS2X_GS_VERIFY_TEXTURE'] = '1' }
if ($CompiledVu) {
    $start.Environment['PS2X_VU_COMPILED'] = '1'
    $start.Environment['PS2X_VU_COMPILED_STATS'] = '1'
    if ($AuditCompiledVu) {
        $start.Environment['PS2X_VU_COMPILED_AUDIT'] = Join-Path $PSScriptRoot 'disc/vu-compiled-failure.bin'
    }
}
if ($PhaseProfile) { $start.Environment['PS2X_RUNTIME_PHASE_PROFILE'] = '1' }
if ($CpuRasterProfile) { $start.Environment['PS2X_GS_CPU_PROFILE'] = '1' }
if ($AuditBilinear) { $start.Environment['PS2X_GS_VERIFY_BILINEAR'] = '1' }
if ($CoverageProfile) { $start.Environment['PS2X_VU_COVERAGE_PROFILE'] = '1' }
if ($CaptureFrame) { $start.Environment['PS2X_DUMP_PRESENT_RANGE'] = '1280-1280' }

$identity = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
$startup = Join-Path $PSScriptRoot 'dev-overrides/set-startup-movie-bypass.ps1'
$process = [Diagnostics.Process]::new()
$process.StartInfo = $start
$writers = @{}
$tasks = @{}
$markers = @{}
$blockPairs = 0L
$compiledCalls = 0L
$compiledRetryCalls = 0L
$bestFitActive = $false
$reallocCalls = 0L
$publicFreeCalls = 0L
$publicFreeBytes = 0L
$heapFailures = 0L
$bilinearSamples = 0L
$preparedTextureActive = $false
$preparedTextureSamples = 0L
$vulkanActive = $false
$vulkanPresents = 0L
$vulkanSubmits = 0L
$vulkanNonblack = 0L
$reachedLimit = $false
$newGameHandler = $false
$levelPackage = $false
$guestFaultLines = 0
$firstGuestFault = $null
$started = $false
$bytes = 0L
try {
    & $startup -Mode TitleGameplayFirst
    $writers.out = [IO.StreamWriter]::new($outLog, $false)
    $writers.err = [IO.StreamWriter]::new($errLog, $false)
    $writers.out.AutoFlush = $true
    $writers.err.AutoFlush = $true
    $started = $process.Start()
    if (!$started) { throw 'Runtime did not start.' }
    $process.PriorityClass = 'Normal'
    $process.ProcessorAffinity = [IntPtr]0xF
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $streams = @{out = $process.StandardOutput; err = $process.StandardError}
    foreach ($key in $streams.Keys) { $tasks[$key] = $streams[$key].ReadLineAsync() }
    $nextReport = 30
    "GAME_PID=$($process.Id) SHA256=$identity PHASE_PROFILE=$([bool]$PhaseProfile) COVERAGE_PROFILE=$([bool]$CoverageProfile)"
    while ($tasks.Count -gt 0 -or !$process.HasExited) {
        $readAny = $false
        foreach ($key in @($tasks.Keys)) {
            while ($tasks.ContainsKey($key) -and $tasks[$key].IsCompleted) {
                $line = $tasks[$key].GetAwaiter().GetResult()
                if ($null -eq $line) { $tasks.Remove($key); break }
                $readAny = $true
                $bytes += [Text.Encoding]::UTF8.GetByteCount($line) + 2
                if ($bytes -gt 128MB) { throw 'Runtime exceeded the combined log limit.' }
                $writers[$key].WriteLine($line)
                if ($line -match '^\[gs:present\] index=(1152|1280)\b') {
                    $index = $Matches[1]
                    if (!$markers.ContainsKey($index)) {
                        $markers[$index] = $watch.Elapsed.TotalSeconds
                        "PRESENT=$index SECONDS=$($markers[$index])"
                    }
                }
                if ($line -match '^\[run:probe-limit\] vsync=1400\b') { $reachedLimit = $true }
                if ($line -match '^\[vu:blocks\] stopped .* pairs=(\d+)') { $blockPairs = [long]$Matches[1] }
                if ($line -match '^\[vu:compiled\] accepted=(\d+)') { $compiledCalls = [long]$Matches[1] }
                if ($line -match '^\[vu:compiled-retry\] accepted=(\d+)') { $compiledRetryCalls = [long]$Matches[1] }
                if ($line -eq '[heap:best-fit] active=1') { $bestFitActive = $true }
                if ($line -match '^\[heap:realloc-in-place\] accepted=(\d+)') { $reallocCalls = [long]$Matches[1] }
                if ($line -match '^\[heap:public-free\] accepted=(\d+) bytes=(\d+)') {
                    $publicFreeCalls = [long]$Matches[1]
                    $publicFreeBytes = [long]$Matches[2]
                }
                if ($line.StartsWith('[heap:allocation-failed]')) {
                    ++$heapFailures
                    if ($HeapDiagnostics -and !$process.HasExited) {
                        try { $process.Kill() }
                        catch [InvalidOperationException] { if (!$process.HasExited) { throw } }
                    }
                }
                if ($line -match '^\[gs:bilinear-audit\] samples=(\d+) mismatches=0') { $bilinearSamples = [long]$Matches[1] }
                if ($line -eq '[gs:prepared-texture] active=1') { $preparedTextureActive = $true }
                if ($line -eq '[gs:play-vulkan] active=1') { $vulkanActive = $true }
                if ($line -match '^\[gs:play-vulkan-present\] presents=(\d+) submits=(\d+) nonblack=(\d+)') {
                    $vulkanPresents = [long]$Matches[1]
                    $vulkanSubmits = [long]$Matches[2]
                    $vulkanNonblack = [long]$Matches[3]
                }
                if ($line -match '^\[gs:prepared-texture-audit\] samples=(\d+) mismatches=0') { $preparedTextureSamples = [long]$Matches[1] }
                if ($line -match '^\[xmen-new-?game-handler\]') { $newGameHandler = $true }
                if ($line.Contains('path="maps/nyc/alison/nyc1_1_1.igb"')) { $levelPackage = $true }
                if ($line -match '^\[(?:ee-thread:missing-pc|guest-branch:missing-target|vu:compiled-audit-failed|gs:bilinear-audit-failed|gs:prepared-texture-audit-failed)\]|^Error during program execution:') {
                    ++$guestFaultLines
                    if ($null -eq $firstGuestFault) {
                        $firstGuestFault = $line.Substring(0, [Math]::Min(1024, $line.Length))
                    }
                    if ((($AuditCompiledVu -and $line.StartsWith('[vu:compiled-audit-failed]')) -or
                        ($AuditPreparedTexture -and $line.StartsWith('[gs:prepared-texture-audit-failed]')) -or
                        ($AuditBilinear -and $line.StartsWith('[gs:bilinear-audit-failed]'))) -and !$process.HasExited) {
                        try { $process.Kill() }
                        catch [InvalidOperationException] { if (!$process.HasExited) { throw } }
                    }
                }
                $tasks[$key] = $streams[$key].ReadLineAsync()
                if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw 'Runtime timed out.' }
            }
        }
        if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw 'Runtime timed out.' }
        if ($watch.Elapsed.TotalSeconds -ge $nextReport) {
            "ELAPSED_SECONDS=$([Math]::Round($watch.Elapsed.TotalSeconds))"
            $nextReport += 30
        }
        if (!$readAny) { Start-Sleep -Milliseconds 5 }
    }
    $process.WaitForExit()
    foreach ($writer in $writers.Values) { $writer.Dispose() }
    $writers.Clear()
    $coverage = if ($CoverageProfile) {
        & (Join-Path $PSScriptRoot 'summarize-vu-coverage.ps1') -LogPath $errLog -RequireGameplaySpan
    } else { $null }
    $completed = $process.ExitCode -eq 0 -and $guestFaultLines -eq 0 -and
        $heapFailures -eq 0 -and (!$BestFitHeap -or $bestFitActive) -and
        (!$InPlaceRealloc -or $reallocCalls -gt 0) -and
        (!$VulkanGs -or ($vulkanActive -and $vulkanPresents -ge 1152 -and $vulkanSubmits -gt 0 -and $vulkanNonblack -gt 0)) -and
        (!$CompiledVu -or $compiledCalls -gt 0) -and
        (!$CompiledRetry -or ($CompiledVu -and $compiledRetryCalls -gt 0)) -and
        (!$AuditBilinear -or $bilinearSamples -gt 0) -and
        (!$PreparedTexture -or $preparedTextureActive) -and
        (!$AuditPreparedTexture -or ($PreparedTexture -and $preparedTextureSamples -gt 0)) -and
        $reachedLimit -and $blockPairs -gt 0 -and
        $newGameHandler -and $levelPackage -and
        $markers.ContainsKey('1152') -and $markers.ContainsKey('1280')
    $verified = $completed -and !$AuditCompiledVu -and !$AuditBilinear -and !$AuditPreparedTexture -and !$HeapDiagnostics -and !$HeapTrace
    $report = [ordered]@{
        RecordedAtUtc = [DateTime]::UtcNow.ToString('o')
        Executable = $exe; Sha256 = $identity; PhaseProfile = [bool]$PhaseProfile
        CoverageProfile = [bool]$CoverageProfile
        CpuRasterProfile = [bool]$CpuRasterProfile
        CompiledVu = [bool]$CompiledVu; CompiledCallsLowerBound = $compiledCalls
        CompiledRetry = [bool]$CompiledRetry; CompiledRetryCallsLowerBound = $compiledRetryCalls
        BestFitHeap = [bool]$BestFitHeap; BestFitActive = $bestFitActive
        InPlaceRealloc = [bool]$InPlaceRealloc; InPlaceReallocCallsLowerBound = $reallocCalls
        PublicFreeCallsLowerBound = $publicFreeCalls; PublicFreeBytesLowerBound = $publicFreeBytes
        HeapDiagnostics = [bool]$HeapDiagnostics; HeapFailureLines = $heapFailures
        HeapTrace = [bool]$HeapTrace
        VulkanGs = [bool]$VulkanGs; VulkanActive = $vulkanActive
        VulkanPresents = $vulkanPresents; VulkanSubmits = $vulkanSubmits; VulkanNonblack = $vulkanNonblack
        AuditCompiledVu = [bool]$AuditCompiledVu
        AuditBilinear = [bool]$AuditBilinear; BilinearSamplesLowerBound = $bilinearSamples
        PreparedTexture = [bool]$PreparedTexture; PreparedTextureActive = $preparedTextureActive
        AuditPreparedTexture = [bool]$AuditPreparedTexture; PreparedTextureSamplesLowerBound = $preparedTextureSamples
        AuditVerified = [bool]($completed -and ($AuditCompiledVu -or $AuditBilinear -or $AuditPreparedTexture))
        Coverage = $coverage
        StartupMode = 'TitleGameplayFirst'; HostInput = $false
        ExitCode = $process.ExitCode; ReachedLimit = $reachedLimit; BlockPairs = $blockPairs
        GuestFaultLines = $guestFaultLines; FirstGuestFault = $firstGuestFault
        NewGameHandler = $newGameHandler; LevelPackage = $levelPackage; WorkloadVerified = $verified
        ElapsedSeconds = $watch.Elapsed.TotalSeconds; Presents = $markers
        Frames = 128; FrameSeconds = $null; Fps = $null
        TimingMethod = 'External stderr line observation; shared-host approximate timing'
    }
    if (!$PhaseProfile -and !$CoverageProfile -and !$CpuRasterProfile -and $verified) {
        $report.FrameSeconds = $markers['1280'] - $markers['1152']
        if ($report.FrameSeconds -gt 0) { $report.Fps = 128 / $report.FrameSeconds }
    }
    if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $identity) {
        throw 'Runtime executable changed during the run.'
    }
    $report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $build "$stem.json")
    [pscustomobject]$report | Format-List
    if (!$completed) {
        throw 'Run did not complete the native-block workload; do not use it as a gameplay benchmark.'
    }
} finally {
    if ($started -and !$process.HasExited) { $process.Kill(); $process.WaitForExit() }
    $process.Dispose()
    foreach ($writer in $writers.Values) { $writer.Dispose() }
    & $startup -Mode Restore
}
