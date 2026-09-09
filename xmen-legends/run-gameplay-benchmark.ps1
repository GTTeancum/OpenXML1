param(
    [ValidateSet('TitleGameplayFirst', 'GameplayMapNoMovie', 'GameplayMissionNoMovie')]
    [string]$StartupMovieMode = 'TitleGameplayFirst',
    [ValidateSet('Primary', 'Staged', 'Candidate', 'Profile')]
    [string]$RuntimeVariant = 'Candidate',
    [string]$RuntimePath = '',
    [switch]$PhaseProfile,
    [switch]$ProgressTrace,
    [switch]$RenderGateTrace,
    [switch]$Diagnostics,
    [switch]$TitleMenuConfirm,
    [switch]$CompatibilityBranchHooks,
    [ValidateRange(1, 1400)][int]$AutoCrossAtTick = 291,
    [ValidateRange(1, 60)][int]$AutoCrossTicks = 4,
    [uint32]$WatchRdramStart = 0,
    [ValidateRange(1, 4096)][uint32]$WatchRdramSize = 4,
    [switch]$BridgeProfile,
    [switch]$BudgetProfile,
    [switch]$CoverageProfile,
    [ValidateRange(0, 10000)][int]$SteadyCallTraceMinTick = 0,
    [switch]$CpuRasterProfile,
    [switch]$CaptureFrame,
    [switch]$CaptureVu,
    [ValidateRange(0, 1400)][int]$CaptureVuStartTick = 1100,
    [switch]$CompiledVu,
    [switch]$CompiledStream,
    [switch]$CompiledStreamBatch,
    [ValidateRange(0, 1400)][int]$CompiledStreamTraceMinTick = 0,
    [ValidateRange(0, 1400)][int]$Vu1ServiceTraceMinTick = 0,
    [ValidateRange(0, 4096)]
    [int]$CompiledStreamBlockBytes = 0,
    [switch]$CompiledEfu,
    [switch]$CompiledRetry,
    [switch]$RetainVuCache,
    [switch]$DisableNativeBlocks,
    [switch]$BestFitHeap,
    [switch]$InPlaceRealloc,
    [switch]$HeapDiagnostics,
    [switch]$HeapTrace,
    [switch]$ReservedHeap,
    [switch]$AuditCompiledVu,
    [switch]$AuditBilinear,
    [switch]$PreparedTexture,
    [switch]$AuditPreparedTexture,
    [switch]$VulkanGs,
    [ValidateRange(0, 10000)][int]$AutoMoveAtTick = 0,
    [ValidateRange(1, 10000)][int]$AutoMoveTicks = 60,
    [ValidateRange(0, 255)][int]$AutoMoveX = 255,
    [ValidateRange(0, 255)][int]$AutoMoveY = 128,
    [ValidateRange(0, 512)][int]$CaptureLatestInterval = 0,
    [ValidateRange(1, 286720)][int]$MinimumWorldNonblackPixels = 16384,
    [ValidateRange(1, 286720)][int]$MinimumWorldCentralPixels = 8192,
    [ValidateRange(1, 256)][int]$MinimumWorldOccupiedTiles = 48,
    [ValidateRange(600, 10000)][int]$RunVsyncLimit = 1400,
    [ValidateSet(0, 8, 16, 32, 64, 128, 256)]
    [int]$FastDispatchDepth = 0,
    [switch]$FullHostResources,
    [ValidateRange(30, 1800)]
    [int]$TimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'framebuffer-metrics.ps1')
if ($HeapTrace -and !$HeapDiagnostics) { throw 'HeapTrace requires HeapDiagnostics; trace runs are never FPS measurements.' }
if ($CaptureLatestInterval -gt 0 -and $CaptureFrame) { throw 'CaptureLatestInterval cannot be combined with CaptureFrame.' }
if ($CompiledEfu -and !$CompiledVu) { throw 'CompiledEfu requires CompiledVu.' }
if ($CompiledStream -and !$CompiledVu) { throw 'CompiledStream requires CompiledVu.' }
if ($CompiledStreamBatch -and !$CompiledStream) { throw 'CompiledStreamBatch requires CompiledStream.' }
if ($CompiledStreamTraceMinTick -gt 0 -and !$CompiledStream) { throw 'CompiledStreamTraceMinTick requires CompiledStream.' }
if ($Vu1ServiceTraceMinTick -gt 0 -and !$CompiledVu) { throw 'Vu1ServiceTraceMinTick requires CompiledVu.' }
if ($CompiledStreamBlockBytes -gt 0 -and !$CompiledStream) { throw 'CompiledStreamBlockBytes requires CompiledStream.' }
if ($CompiledStreamBlockBytes -gt 0 -and
    ($CompiledStreamBlockBytes -lt 8 -or ($CompiledStreamBlockBytes % 8) -ne 0)) {
    throw 'CompiledStreamBlockBytes must be a multiple of 8 between 8 and 4096.'
}
if ($TitleMenuConfirm -and $StartupMovieMode -ne 'TitleGameplayFirst') {
    throw 'TitleMenuConfirm requires StartupMovieMode TitleGameplayFirst.'
}
$root = Split-Path -Parent $PSScriptRoot
$disc = Join-Path $PSScriptRoot 'disc'
$build = Join-Path $root 'PS2Recomp/out/xmen-final3-build'
Get-ChildItem -LiteralPath $disc -Filter 'gs-present-latest*.ppm' -File -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
$name = switch ($RuntimeVariant) {
    'Primary' { 'ps2EntryRunner.exe' }
    'Staged' { 'ps2EntryRunner.next.exe' }
    'Candidate' { 'ps2EntryRunner.candidate.exe' }
    'Profile' { 'ps2EntryRunner.profile.exe' }
}
$requestedExe = if ($RuntimePath) { $RuntimePath } else { Join-Path $build "ps2xRuntime/Release/$name" }
$exe = (Resolve-Path -LiteralPath $requestedExe).Path
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
if ($CompiledEfu) { $stem += '-efu' }
if ($CompiledStream) { $stem += '-stream' }
if ($CompiledStreamBatch) { $stem += '-batch' }
if ($CompiledStreamTraceMinTick -gt 0) { $stem += "-stream-trace-$CompiledStreamTraceMinTick" }
if ($Vu1ServiceTraceMinTick -gt 0) { $stem += "-service-trace-$Vu1ServiceTraceMinTick" }
if ($CompiledStreamBlockBytes -gt 0) { $stem += "-stream-block-$CompiledStreamBlockBytes" }
if ($RetainVuCache) {
    if (!$CompiledVu) { throw 'RetainVuCache requires CompiledVu.' }
    $stem += '-cache'
}
if ($DisableNativeBlocks) { $stem += '-no-native-blocks' }
if ($BridgeProfile) {
    if (!$CompiledVu) { throw 'BridgeProfile requires CompiledVu.' }
    $stem += '-bridge-profile'
}
if ($BudgetProfile) { $stem += '-budget-profile' }
if ($BestFitHeap) { $stem += '-best-fit' }
if ($InPlaceRealloc) { $stem += '-realloc' }
if ($HeapDiagnostics) { $stem += '-heap-audit' }
if ($ReservedHeap) { $stem += '-reserved-heap' }
if ($CaptureVu) { $stem += '-vu-capture' }
if ($AutoMoveAtTick -gt 0) { $stem += '-move' }
if ($CaptureLatestInterval -gt 0) { $stem += '-frame-hashes' }
if ($ProgressTrace) { $stem += '-progress' }
if ($RenderGateTrace) { $stem += '-gate-trace' }
if ($WatchRdramStart -ne 0) { $stem += '-rdram-watch' }
if ($StartupMovieMode -eq 'GameplayMissionNoMovie') { $stem += '-mission-start' }
if ($StartupMovieMode -eq 'GameplayMapNoMovie') { $stem += '-map-start' }
if ($TitleMenuConfirm) { $stem += '-title-confirm' }
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
    'PS2X_FAST_FORWARD_XMEN_LEGAL', 'PS2X_VU_NATIVE_PAIRS')) {
    $start.Environment[$key] = '1'
}
if (!$CompatibilityBranchHooks) {
    $start.Environment['PS2X_BYPASS_XMEN_BRANCH_HOOKS'] = '1'
}
if (!$DisableNativeBlocks) { $start.Environment['PS2X_VU_NATIVE_BLOCKS'] = '1' }
if ($StartupMovieMode -eq 'TitleGameplayFirst' -and !$TitleMenuConfirm) {
    $start.Environment['PS2X_XMEN_START_FIRST_LEVEL'] = '1'
}
if ($TitleMenuConfirm) {
    $start.Environment['PS2X_AUTOPRESS_CROSS_AT_TICK'] = "$AutoCrossAtTick"
    $start.Environment['PS2X_AUTOPRESS_CROSS_TICKS'] = "$AutoCrossTicks"
}
$start.Environment['PS2X_RUN_VSYNC_LIMIT'] = "$RunVsyncLimit"
if ($VulkanGs) { $start.Environment['PS2X_GS_PLAY_VULKAN'] = '1' }
if ($FastDispatchDepth -gt 0) {
    $start.Environment['PS2X_XMEN_FAST_DISPATCH_DEPTH'] = "$FastDispatchDepth"
}
if ($CompiledRetry) { $start.Environment['PS2X_VU_COMPILED_RETRY'] = '1' }
if ($RetainVuCache) { $start.Environment['PS2X_VU_RETAIN_BLOCK_CACHE'] = '1' }
if ($BridgeProfile) { $start.Environment['PS2X_VU_BRIDGE_PROFILE'] = '1' }
if ($BudgetProfile) { $start.Environment['PS2X_VU_BUDGET_PROFILE'] = '1' }
if ($BestFitHeap) { $start.Environment['PS2X_GUEST_BUMP_BEST_FIT'] = '1' }
if ($InPlaceRealloc) { $start.Environment['PS2X_GUEST_BUMP_REALLOC'] = '1' }
if ($HeapDiagnostics) { $start.Environment['PS2X_GUEST_BUMP_DIAGNOSTICS'] = '1' }
if ($ReservedHeap) { $start.Environment['PS2X_XMEN_RESERVED_HEAP'] = '1' }
if ($HeapTrace) {
    $start.Environment['PS2X_GUEST_HEAP_TRACE'] = Join-Path $build 'gameplay-heap-trace.bin'
    $start.Environment['PS2X_GUEST_HEAP_FAILURE_SNAPSHOT'] = Join-Path $build 'gameplay-heap-failure.rdram'
    Remove-Item -LiteralPath $start.Environment['PS2X_GUEST_HEAP_FAILURE_SNAPSHOT'] -ErrorAction SilentlyContinue
}
if ($AuditCompiledVu -and !$CompiledVu) { throw 'AuditCompiledVu requires CompiledVu' }
if ($AuditPreparedTexture -and !$PreparedTexture) { throw 'AuditPreparedTexture requires PreparedTexture' }
if ($PreparedTexture) { $start.Environment['PS2X_GS_PREPARED_TEXTURE'] = '1' }
if ($AuditPreparedTexture) { $start.Environment['PS2X_GS_VERIFY_TEXTURE'] = '1' }
if ($CompiledVu) {
    $start.Environment['PS2X_VU_COMPILED'] = '1'
    $start.Environment['PS2X_VU_COMPILED_STATS'] = '1'
    if ($CompiledEfu) { $start.Environment['PS2X_VU_COMPILED_EFU'] = '1' }
    if ($CompiledStream) { $start.Environment['PS2X_VU_COMPILED_STREAM'] = '1' }
    if ($CompiledStreamBatch) { $start.Environment['PS2X_VU_COMPILED_STREAM_BATCH'] = '1' }
    if ($CompiledStreamTraceMinTick -gt 0) {
        $start.Environment['PS2X_VU_COMPILED_STREAM_TRACE_MIN_TICK'] = "$CompiledStreamTraceMinTick"
    }
    if ($Vu1ServiceTraceMinTick -gt 0) {
        $start.Environment['PS2X_VU1_SERVICE_TRACE_MIN_TICK'] = "$Vu1ServiceTraceMinTick"
    }
    if ($CompiledStreamBlockBytes -gt 0) {
        $start.Environment['PS2X_VU_COMPILED_STREAM_BLOCK_BYTES'] = "$CompiledStreamBlockBytes"
    }
    if ($AuditCompiledVu) {
        $start.Environment['PS2X_VU_COMPILED_AUDIT'] = Join-Path $PSScriptRoot 'disc/vu-compiled-failure.bin'
    }
}
if ($PhaseProfile) { $start.Environment['PS2X_RUNTIME_PHASE_PROFILE'] = '1' }
if ($ProgressTrace) { $start.Environment['PS2X_XMEN_PROGRESS_TRACE'] = '1' }
if ($RenderGateTrace) { $start.Environment['PS2X_XMEN_RENDER_GATE_TRACE'] = '1' }
if ($Diagnostics) { $start.Environment['PS2X_XMEN_DIAGNOSTICS'] = '1' }
if ($WatchRdramStart -ne 0) {
    $start.Environment['PS2X_XMEN_MEMORY_WATCHES'] = '1'
    $start.Environment['PS2X_WATCH_START_K'] = "0x$($WatchRdramStart.ToString('x'))"
    $start.Environment['PS2X_WATCH_SIZE_K'] = "$WatchRdramSize"
}
if ($CpuRasterProfile) { $start.Environment['PS2X_GS_CPU_PROFILE'] = '1' }
if ($AuditBilinear) { $start.Environment['PS2X_GS_VERIFY_BILINEAR'] = '1' }
if ($CoverageProfile) { $start.Environment['PS2X_VU_COVERAGE_PROFILE'] = '1' }
if ($SteadyCallTraceMinTick -gt 0) {
    $start.Environment['PS2X_XMEN_STEADY_COVERAGE'] = '1'
    $start.Environment['PS2X_XMEN_STEADY_COVERAGE_MIN_TICK'] = "$SteadyCallTraceMinTick"
}
if ($CaptureFrame) { $start.Environment['PS2X_DUMP_PRESENT_RANGE'] = '1280-1280' }
if ($CaptureLatestInterval -gt 0) {
    $start.Environment['PS2X_CAPTURE_LATEST_PRESENT_INTERVAL'] = "$CaptureLatestInterval"
}
if ($AutoMoveAtTick -gt 0) {
    $start.Environment['PS2X_AUTOMOVE_LEFT_STICK_AT_TICK'] = "$AutoMoveAtTick"
    $start.Environment['PS2X_AUTOMOVE_LEFT_STICK_TICKS'] = "$AutoMoveTicks"
    $start.Environment['PS2X_AUTOMOVE_LEFT_STICK_X'] = "$AutoMoveX"
    $start.Environment['PS2X_AUTOMOVE_LEFT_STICK_Y'] = "$AutoMoveY"
}
if ($CaptureVu) {
    $start.Environment['PS2X_VU_REPLAY_CAPTURE'] = Join-Path $disc 'vu-gameplay-current.bin'
    $start.Environment['PS2X_VU_REPLAY_CAPTURE_START_TICK'] = "$CaptureVuStartTick"
}

$identity = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
$startup = Join-Path $PSScriptRoot 'dev-overrides/set-startup-movie-bypass.ps1'
$process = [Diagnostics.Process]::new()
$process.StartInfo = $start
$writers = @{}
$tasks = @{}
$markers = @{}
$presentTicks = @{}
$blockPairs = 0L
$compiledCalls = 0L
$compiledStreamStarted = 0L
$compiledStreamCompleted = 0L
$compiledRetryCalls = 0L
$captureComplete = $false
$autoMoveSeen = $false
$autoCrossSeen = $false
$presentationHashes = [Collections.Generic.List[object]]::new()
$cacheHits = 0L
$bridgeStages = @{}
$budgetStages = @{}
$bestFitActive = $false
$reallocCalls = 0L
$publicFreeCalls = 0L
$publicFreeBytes = 0L
$heapFailures = 0L
$renderSlotAllocationFailures = 0L
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
$reportPath = Join-Path $build "$stem.json"
$reportWritten = $false
$watch = [Diagnostics.Stopwatch]::new()
try {
    [ordered]@{RecordedAtUtc=[DateTime]::UtcNow.ToString('o'); Sha256=$identity;
        Status='Running'; WorkloadVerified=$false; AuditVerified=$false; Fps=$null} |
        ConvertTo-Json | Set-Content -LiteralPath $reportPath
    & $startup -Mode $StartupMovieMode
    $writers.out = [IO.StreamWriter]::new($outLog, $false)
    $writers.err = [IO.StreamWriter]::new($errLog, $false)
    $writers.out.AutoFlush = $true
    $writers.err.AutoFlush = $true
    $started = $process.Start()
    if (!$started) { throw 'Runtime did not start.' }
    $process.PriorityClass = if ($FullHostResources) { 'Normal' } else { 'BelowNormal' }
    $process.ProcessorAffinity = if ($FullHostResources) { [IntPtr]0xFFFF } else { [IntPtr]0xF }
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
                if ($line -match '^\[gs:present\] index=(\d+) tick=(\d+)\b') {
                    $presentTicks[[long]$Matches[1]] = [long]$Matches[2]
                }
                if ($line -match '^\[gs:present\] index=(1152|1280)\b') {
                    $index = $Matches[1]
                    if (!$markers.ContainsKey($index)) {
                        $markers[$index] = $watch.Elapsed.TotalSeconds
                        "PRESENT=$index SECONDS=$($markers[$index])"
                    }
                }
                if ($line -match '^\[run:probe-limit\] vsync=(\d+)\b' -and
                    [long]$Matches[1] -eq $RunVsyncLimit) { $reachedLimit = $true }
                if ($line -match '^\[vu:blocks\] stopped .* pairs=(\d+)') { $blockPairs = [long]$Matches[1] }
                if ($line -match '^\[vu:compiled\] accepted=(\d+)') { $compiledCalls = [long]$Matches[1] }
                if ($line -match '^\[vu:compiled-stream\] started=(\d+) completed=(\d+)') {
                    $compiledStreamStarted = [Math]::Max($compiledStreamStarted, [long]$Matches[1])
                    $compiledStreamCompleted = [Math]::Max($compiledStreamCompleted, [long]$Matches[2])
                }
                if ($line -match '^\[pad:auto-left-stick\].*\btick=(\d+)\b') {
                    $autoMoveSeen = $true
                }
                if ($line -match '^\[pad:auto-cross\].*\btick=(\d+)\b') {
                    $autoCrossSeen = $true
                }
                if ($CaptureLatestInterval -gt 0 -and
                    $line -match '^\[gs:present-latest\] index=(?<index>\d+)(?: tick=(?<tick>\d+))? path=(?<path>[^ ]+) wrote=1(?: nonblack=(?<nonblack>\d+) central=(?<central>\d+) tiles=(?<tiles>\d+) bounds=(?<bounds>[\d,]+))?$') {
                    $capturePath = Join-Path $disc $Matches['path']
                    if (Test-Path -LiteralPath $capturePath -PathType Leaf) {
                        $captureIndex = [long]$Matches['index']
                        try {
                            $frameMetrics = if ($Matches['nonblack']) {
                                $bounds = @($Matches['bounds'].Split(',') | ForEach-Object { [uint32]$_ })
                                [ordered]@{
                                    Width = 640; Height = 448
                                    NonblackPixels = [long]$Matches['nonblack']
                                    CentralNonblackPixels = [long]$Matches['central']
                                    OccupiedTiles = [int]$Matches['tiles']
                                    Bounds = [ordered]@{ Left=$bounds[0]; Top=$bounds[1]; Right=$bounds[2]; Bottom=$bounds[3] }
                                }
                            } else {
                                Get-PpmFrameMetrics -Path $capturePath
                            }
                            $presentationHashes.Add([ordered]@{
                                Index = $captureIndex
                                Tick = if ($Matches['tick']) { [long]$Matches['tick'] } elseif ($presentTicks.ContainsKey($captureIndex)) { [long]$presentTicks[$captureIndex] } else { $null }
                                Seconds = $watch.Elapsed.TotalSeconds
                                Sha256 = (Get-FileHash -LiteralPath $capturePath -Algorithm SHA256).Hash
                                FrameMetrics = $frameMetrics
                            })
                        } finally {
                            Remove-Item -LiteralPath $capturePath -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
                if ($line -match '^\[vu:compiled-cache\] compiled=\d+ hits=(\d+)') { $cacheHits = [long]$Matches[1] }
                if ($line -match '^\[vu:bridge-profile\] stage=([a-z-]+) calls=(\d+) ns=(\d+)$') {
                    $stage = $Matches[1]
                    if (!$bridgeStages.ContainsKey($stage)) { $bridgeStages[$stage] = @{ Calls=0L; Nanoseconds=0L } }
                    $bridgeStages[$stage].Calls += [long]$Matches[2]
                    $bridgeStages[$stage].Nanoseconds += [long]$Matches[3]
                }
                if ($line -match '^\[vu:budget-profile\] kind=([a-z-]+) calls=(\d+) ns=(\d+)$') {
                    $stage = $Matches[1]
                    if (!$budgetStages.ContainsKey($stage)) { $budgetStages[$stage] = @{ Calls=0L; Nanoseconds=0L } }
                    $budgetStages[$stage].Calls += [long]$Matches[2]
                    $budgetStages[$stage].Nanoseconds += [long]$Matches[3]
                }
                if ($CaptureVu -and $line -match '^\[vu-replay:capture\] short=16 long=16 .* saved=1 ') {
                    $captureComplete = $true
                    if (!$process.HasExited) {
                        try { $process.Kill() }
                        catch [InvalidOperationException] { if (!$process.HasExited) { throw } }
                    }
                }
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
                if ($line -match '^\[xmen-render-slot-grow-return\].*\ballocationResult=0x0\b') {
                    ++$renderSlotAllocationFailures
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
    # The runtime emits present-latest immediately before the matching present
    # record, so resolve capture ticks after both streams have drained.
    foreach ($capture in $presentationHashes) {
        if ($null -eq $capture.Tick -and $presentTicks.ContainsKey([long]$capture.Index)) {
            $capture.Tick = [long]$presentTicks[[long]$capture.Index]
        }
    }
    $coverage = if ($CoverageProfile) {
        & (Join-Path $PSScriptRoot 'summarize-vu-coverage.ps1') -LogPath $errLog -RequireGameplaySpan
    } else { $null }
    $sampleFrames = 128L
    $sampleSeconds = $null
    $sampleFps = $null
    if ($presentationHashes.Count -ge 2) {
        $sampleFirst = $presentationHashes[$presentationHashes.Count - 2]
        $sampleLast = $presentationHashes[$presentationHashes.Count - 1]
        $sampleFrames = [long]$sampleLast.Index - [long]$sampleFirst.Index
        $sampleSeconds = [double]$sampleLast.Seconds - [double]$sampleFirst.Seconds
        if ($sampleFrames -gt 0 -and $sampleSeconds -gt 0) {
            $sampleFps = $sampleFrames / $sampleSeconds
        }
    }
    $movementSamples = @()
    $movementFresh = $AutoMoveAtTick -eq 0
    $worldCoverageRequired = $AutoMoveAtTick -gt 0
    $worldCoverageVerified = !$worldCoverageRequired
    $worldCoverageSamples = @()
    $movementFrames = $null
    $movementSeconds = $null
    $movementFps = $null
    if ($AutoMoveAtTick -gt 0) {
        $moveEndTick = [long]$AutoMoveAtTick + [long]$AutoMoveTicks
        $movementSamples = @($presentationHashes | Where-Object {
            $null -ne $_.Tick -and [long]$_.Tick -ge $AutoMoveAtTick -and [long]$_.Tick -lt $moveEndTick
        })
        if ($movementSamples.Count -ge 2) {
            $moveFirst = $movementSamples[$movementSamples.Count - 2]
            $moveLast = $movementSamples[$movementSamples.Count - 1]
            $movementFrames = [long]$moveLast.Index - [long]$moveFirst.Index
            $movementSeconds = [double]$moveLast.Seconds - [double]$moveFirst.Seconds
            $movementFresh = $moveFirst.Sha256 -ne $moveLast.Sha256
            if ($movementFresh -and $movementFrames -gt 0 -and $movementSeconds -gt 0) {
                $movementFps = $movementFrames / $movementSeconds
            }
            $worldCoverageSamples = @($movementSamples | Where-Object {
                $_.FrameMetrics -and (Test-WorldFrameMetrics -Metrics $_.FrameMetrics `
                    -MinimumNonblackPixels $MinimumWorldNonblackPixels `
                    -MinimumCentralPixels $MinimumWorldCentralPixels `
                    -MinimumOccupiedTiles $MinimumWorldOccupiedTiles)
            })
            $worldCoverageVerified = $worldCoverageSamples.Count -ge 2
        }
    }
    $vulkanPresentationThreshold = if ($CompiledStream) { 512L } else { 1152L }
    $nativeBlockEvidence = $CompiledStream -or $blockPairs -gt 0
    $timingEvidence = ($markers.ContainsKey('1152') -and $markers.ContainsKey('1280')) -or
        ($presentationHashes.Count -ge 2 -and $sampleFps -gt 0)
    $startupReached = $levelPackage -and
        ($StartupMovieMode -eq 'GameplayMapNoMovie' -or $newGameHandler)
    $completed = $process.ExitCode -eq 0 -and $guestFaultLines -eq 0 -and
        $heapFailures -eq 0 -and $renderSlotAllocationFailures -eq 0 -and
        (!$BestFitHeap -or $bestFitActive) -and
        (!$InPlaceRealloc -or $reallocCalls -gt 0) -and
        (!$VulkanGs -or ($vulkanActive -and $vulkanPresents -ge $vulkanPresentationThreshold -and $vulkanSubmits -gt 0 -and $vulkanNonblack -gt 0)) -and
        (!$CompiledVu -or $compiledCalls -gt 0 -or
            ($CompiledStream -and $compiledStreamCompleted -gt 0)) -and
        (!$CompiledStream -or ($compiledStreamStarted -gt 0 -and $compiledStreamCompleted -gt 0)) -and
        (!$CompiledRetry -or ($CompiledVu -and $compiledRetryCalls -gt 0)) -and
        (!$RetainVuCache -or ($CompiledVu -and
            ($cacheHits -gt 0 -or ($CompiledStream -and $compiledStreamCompleted -gt 0)))) -and
        (!$BridgeProfile -or ($bridgeStages.Count -eq 7 -and @($bridgeStages.Values | Where-Object { $_.Calls -le 0 }).Count -eq 0)) -and
        (!$BudgetProfile -or ($budgetStages.Count -eq 3 -and $budgetStages['short'].Calls -gt 0)) -and
        (!$AuditBilinear -or $bilinearSamples -gt 0) -and
        (!$PreparedTexture -or $preparedTextureActive) -and
        (!$AuditPreparedTexture -or ($PreparedTexture -and $preparedTextureSamples -gt 0)) -and
        (!$TitleMenuConfirm -or $autoCrossSeen) -and
        ($AutoMoveAtTick -eq 0 -or ($autoMoveSeen -and $movementFresh)) -and
        (!$worldCoverageRequired -or $worldCoverageVerified) -and
        ($CaptureLatestInterval -eq 0 -or $presentationHashes.Count -gt 1) -and
        $reachedLimit -and $nativeBlockEvidence -and
        $startupReached -and
        $timingEvidence
    $verified = $completed -and !$AuditCompiledVu -and !$AuditBilinear -and !$AuditPreparedTexture -and !$HeapDiagnostics -and !$HeapTrace -and !$CaptureVu -and !$BridgeProfile -and !$BudgetProfile -and $SteadyCallTraceMinTick -eq 0
    $report = [ordered]@{
        RecordedAtUtc = [DateTime]::UtcNow.ToString('o')
        Executable = $exe; Sha256 = $identity; PhaseProfile = [bool]$PhaseProfile
        ProgressTrace = [bool]$ProgressTrace
        RenderGateTrace = [bool]$RenderGateTrace
        CoverageProfile = [bool]$CoverageProfile
        SteadyCallTraceMinTick = $SteadyCallTraceMinTick
        CpuRasterProfile = [bool]$CpuRasterProfile
        CompiledVu = [bool]$CompiledVu; CompiledEfu = [bool]$CompiledEfu
        CompiledCallsLowerBound = $compiledCalls
        CompiledStream = [bool]$CompiledStream
        CompiledStreamBatch = [bool]$CompiledStreamBatch
        CompiledStreamTraceMinTick = $CompiledStreamTraceMinTick
        CompiledStreamBlockBytes = $CompiledStreamBlockBytes
        CompiledStreamStartedLowerBound = $compiledStreamStarted
        CompiledStreamCompletedLowerBound = $compiledStreamCompleted
        CompiledRetry = [bool]$CompiledRetry; CompiledRetryCallsLowerBound = $compiledRetryCalls
        RetainVuCache = [bool]$RetainVuCache; CacheHitsLowerBound = $cacheHits
        BridgeProfile = [bool]$BridgeProfile; BridgeStages = $bridgeStages
        BudgetProfile = [bool]$BudgetProfile; BudgetStages = $budgetStages
        CaptureVu = [bool]$CaptureVu; CaptureVuStartTick = $CaptureVuStartTick; CaptureComplete = $captureComplete
        AutoMoveAtTick = $AutoMoveAtTick; AutoMoveTicks = $AutoMoveTicks
        AutoMoveX = $AutoMoveX; AutoMoveY = $AutoMoveY; AutoMoveSeen = $autoMoveSeen
        GameplayMovementVerified = $movementFresh
        WorldCoverageRequired = $worldCoverageRequired
        WorldCoverageVerified = $worldCoverageVerified
        WorldCoverageSampleCount = $worldCoverageSamples.Count
        MinimumWorldNonblackPixels = $MinimumWorldNonblackPixels
        MinimumWorldCentralPixels = $MinimumWorldCentralPixels
        MinimumWorldOccupiedTiles = $MinimumWorldOccupiedTiles
        MovementPresentationSamples = $movementSamples
        MovementFrames = $movementFrames; MovementSeconds = $movementSeconds
        TitleMenuConfirm = [bool]$TitleMenuConfirm; AutoCrossAtTick = $AutoCrossAtTick
        AutoCrossTicks = $AutoCrossTicks; AutoCrossSeen = $autoCrossSeen
        CaptureLatestInterval = $CaptureLatestInterval; PresentationHashes = $presentationHashes
        RunVsyncLimit = $RunVsyncLimit
        BestFitHeap = [bool]$BestFitHeap; BestFitActive = $bestFitActive
        InPlaceRealloc = [bool]$InPlaceRealloc; InPlaceReallocCallsLowerBound = $reallocCalls
        PublicFreeCallsLowerBound = $publicFreeCalls; PublicFreeBytesLowerBound = $publicFreeBytes
        HeapDiagnostics = [bool]$HeapDiagnostics; HeapFailureLines = $heapFailures
        RenderSlotAllocationFailures = $renderSlotAllocationFailures
        HeapTrace = [bool]$HeapTrace
        ReservedHeap = [bool]$ReservedHeap
        VulkanGs = [bool]$VulkanGs; VulkanActive = $vulkanActive
        VulkanPresents = $vulkanPresents; VulkanSubmits = $vulkanSubmits; VulkanNonblack = $vulkanNonblack
        AuditCompiledVu = [bool]$AuditCompiledVu
        AuditBilinear = [bool]$AuditBilinear; BilinearSamplesLowerBound = $bilinearSamples
        PreparedTexture = [bool]$PreparedTexture; PreparedTextureActive = $preparedTextureActive
        AuditPreparedTexture = [bool]$AuditPreparedTexture; PreparedTextureSamplesLowerBound = $preparedTextureSamples
        AuditVerified = [bool]($completed -and ($AuditCompiledVu -or $AuditBilinear -or $AuditPreparedTexture))
        Coverage = $coverage
        StartupMode = $StartupMovieMode; HostInput = $false
        CompatibilityBranchHooks = [bool]$CompatibilityBranchHooks
        ExitCode = $process.ExitCode; ReachedLimit = $reachedLimit; BlockPairs = $blockPairs
        GuestFaultLines = $guestFaultLines; FirstGuestFault = $firstGuestFault
        NewGameHandler = $newGameHandler; LevelPackage = $levelPackage; WorkloadVerified = $verified
        ElapsedSeconds = $watch.Elapsed.TotalSeconds; Presents = $markers
        Frames = if ($AutoMoveAtTick -gt 0) { $movementFrames } else { $sampleFrames }
        FrameSeconds = if ($AutoMoveAtTick -gt 0) { $movementSeconds } else { $sampleSeconds }
        Fps = if ($verified) {
            if ($AutoMoveAtTick -gt 0) { $movementFps } else { $sampleFps }
        } else { $null }
        TimingMethod = 'External stderr line observation; shared-host approximate timing'
    }
    if ($AutoMoveAtTick -eq 0 -and !$PhaseProfile -and !$CoverageProfile -and !$CpuRasterProfile -and $verified -and
        $markers.ContainsKey('1152') -and $markers.ContainsKey('1280')) {
        $report.FrameSeconds = $markers['1280'] - $markers['1152']
        $report.Frames = 128
        if ($report.FrameSeconds -gt 0) { $report.Fps = 128 / $report.FrameSeconds }
    }
    if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $identity) {
        throw 'Runtime executable changed during the run.'
    }
    $report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $reportPath
    $reportWritten = $true
    [pscustomobject]$report | Format-List
    if (!$completed -and !($CaptureVu -and $captureComplete -and $guestFaultLines -eq 0 -and
            $heapFailures -eq 0 -and $renderSlotAllocationFailures -eq 0)) {
        throw 'Run did not complete the native-block workload; do not use it as a gameplay benchmark.'
    }
} catch {
    if (!$reportWritten) {
        [ordered]@{
            RecordedAtUtc=[DateTime]::UtcNow.ToString('o'); Executable=$exe; Sha256=$identity
            Status='Incomplete'; Error=$_.Exception.Message; ElapsedSeconds=$watch.Elapsed.TotalSeconds
            ProgressTrace=[bool]$ProgressTrace
            CompiledVu=[bool]$CompiledVu; CompiledEfu=[bool]$CompiledEfu
            CompiledCallsLowerBound=$compiledCalls; CompiledRetryCallsLowerBound=$compiledRetryCalls
            CompiledStream=[bool]$CompiledStream
            CompiledStreamBatch=[bool]$CompiledStreamBatch
            CompiledStreamTraceMinTick=$CompiledStreamTraceMinTick
            CompiledStreamBlockBytes=$CompiledStreamBlockBytes
            CompiledStreamStartedLowerBound=$compiledStreamStarted
            CompiledStreamCompletedLowerBound=$compiledStreamCompleted
            RetainVuCache=[bool]$RetainVuCache; CacheHitsLowerBound=$cacheHits
            BridgeProfile=[bool]$BridgeProfile; BridgeStages=$bridgeStages
            BudgetProfile=[bool]$BudgetProfile; BudgetStages=$budgetStages
            CaptureVu=[bool]$CaptureVu; CaptureVuStartTick=$CaptureVuStartTick; CaptureComplete=$captureComplete
            AutoMoveAtTick=$AutoMoveAtTick; AutoMoveTicks=$AutoMoveTicks; AutoMoveSeen=$autoMoveSeen
            TitleMenuConfirm=[bool]$TitleMenuConfirm; AutoCrossAtTick=$AutoCrossAtTick
            AutoCrossTicks=$AutoCrossTicks; AutoCrossSeen=$autoCrossSeen
            CaptureLatestInterval=$CaptureLatestInterval; PresentationHashes=$presentationHashes
            RunVsyncLimit=$RunVsyncLimit
            HeapFailureLines=$heapFailures; RenderSlotAllocationFailures=$renderSlotAllocationFailures
            GuestFaultLines=$guestFaultLines; FirstGuestFault=$firstGuestFault
            NewGameHandler=$newGameHandler; LevelPackage=$levelPackage; Presents=$markers
            WorkloadVerified=$false; AuditVerified=$false; Fps=$null; HostInput=$false
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $reportPath
    }
    throw
} finally {
    if ($started -and !$process.HasExited) { $process.Kill(); $process.WaitForExit() }
    $process.Dispose()
    foreach ($writer in $writers.Values) { $writer.Dispose() }
    & $startup -Mode Restore
}
