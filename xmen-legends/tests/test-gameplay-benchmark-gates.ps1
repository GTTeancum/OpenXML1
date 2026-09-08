$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '../run-gameplay-benchmark.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path -LiteralPath $path), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw $errors[0] }
$assignment = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -eq '$verified'
}, $true)
if (!$assignment) { throw 'Benchmark verification gate is missing.' }
$completion = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -eq '$completed'
}, $true)
if (!$completion) { throw 'Workload completion gate is missing.' }
$completeCheck = [scriptblock]::Create($completion.Right.Extent.Text)
$check = [scriptblock]::Create('$completed = ' + $completion.Right.Extent.Text + "`n" + $assignment.Right.Extent.Text)
$process = [pscustomobject]@{ ExitCode = 0 }
$reachedLimit = $true
$blockPairs = 1
$newGameHandler = $true
$levelPackage = $true
$startupReached = $true
$markers = @{ '1152' = 1; '1280' = 2 }
$guestFaultLines = 0
$CompiledVu = $false
$CompiledRetry = $false
$RetainVuCache = $false
$cacheHits = 0L
$BridgeProfile = $false
$bridgeStages = @{}
$BudgetProfile = $false
$budgetStages = @{}
$compiledRetryCalls = 0L
$BestFitHeap = $false
$InPlaceRealloc = $false
$reallocCalls = 0L
$HeapDiagnostics = $false
$HeapTrace = $false
$CaptureVu = $false
$bestFitActive = $false
$heapFailures = 0L
$renderSlotAllocationFailures = 0L
$AuditCompiledVu = $false
$AuditBilinear = $false
$PreparedTexture = $false
$AuditPreparedTexture = $false
$preparedTextureActive = $false
$preparedTextureSamples = 0L
$bilinearSamples = 0L
$compiledCalls = 0L
$VulkanGs = $false
$vulkanActive = $false
$vulkanPresents = 0L
$vulkanSubmits = 0L
$vulkanNonblack = 0L
$AutoMoveAtTick = 0
$autoMoveSeen = $false
$CaptureLatestInterval = 0
$presentationHashes = [Collections.Generic.List[object]]::new()
$movementFresh = $true
$worldCoverageRequired = $false
$worldCoverageVerified = $true
$nativeBlockEvidence = $true
$timingEvidence = $true
$SteadyCallTraceMinTick = 0
if (!(& $check)) { throw 'Healthy workload rejected.' }
$SteadyCallTraceMinTick = 500
if (& $check) { throw 'Call tracing was accepted as an FPS measurement.' }
$SteadyCallTraceMinTick = 0
$AutoMoveAtTick = 1235
$worldCoverageRequired = $true
$worldCoverageVerified = $false
if (& $completeCheck) { throw 'Movement workload accepted without injected input evidence.' }
$autoMoveSeen = $true
$movementFresh = $false
if (& $completeCheck) { throw 'Movement workload accepted with a stale framebuffer.' }
$movementFresh = $true
if (& $completeCheck) { throw 'Movement workload accepted without world framebuffer coverage.' }
$worldCoverageVerified = $true
if (!(& $completeCheck)) { throw 'Fresh movement workload with world coverage rejected.' }
$AutoMoveAtTick = 0
$worldCoverageRequired = $false
$worldCoverageVerified = $true
$autoMoveSeen = $false
$CaptureLatestInterval = 32
if (& $completeCheck) { throw 'Frame-hash workload accepted without multiple captures.' }
$presentationHashes.Add(@{ Index = 1152; Sha256 = 'a' })
$presentationHashes.Add(@{ Index = 1184; Sha256 = 'b' })
if (!(& $completeCheck)) { throw 'Frame-hash workload with multiple captures rejected.' }
$CaptureLatestInterval = 0
$presentationHashes.Clear()
$BridgeProfile = $true
if (& $completeCheck) { throw 'Missing bridge profile accepted.' }
foreach ($stage in @('capture','copy','import','scalar-import','execute','export','commit')) {
    $bridgeStages[$stage] = @{ Calls=1L; Nanoseconds=1L }
}
if (!(& $completeCheck)) { throw 'Complete bridge profile rejected.' }
if (& $check) { throw 'Bridge profile accepted as FPS.' }
$bridgeStages['execute'].Calls = 0L
if (& $completeCheck) { throw 'Unexecuted bridge stage accepted.' }
$BridgeProfile = $false
$BudgetProfile = $true
if (& $completeCheck) { throw 'Missing budget profile accepted.' }
foreach ($stage in @('short','long-reference','long-compiled')) {
    $budgetStages[$stage] = @{ Calls=1L; Nanoseconds=1L }
}
if (!(& $completeCheck)) { throw 'Complete budget profile rejected.' }
if (& $check) { throw 'Budget profile accepted as FPS.' }
$BudgetProfile = $false
$CaptureVu = $true
if (& $check) { throw 'VU recording accepted as FPS.' }
$CaptureVu = $false
$HeapTrace = $true
if (& $check) { throw 'Heap trace accepted as FPS.' }
$HeapTrace = $false
$InPlaceRealloc = $true
if (& $check) { throw 'In-place realloc accepted without execution evidence.' }
$reallocCalls = 1L
if (!(& $check)) { throw 'Executed in-place realloc rejected.' }
$InPlaceRealloc = $false
$BestFitHeap = $true
if (& $check) { throw 'Best-fit mode accepted without execution evidence.' }
$bestFitActive = $true
if (!(& $check)) { throw 'Executed best-fit mode rejected.' }
$HeapDiagnostics = $true
if (& $check) { throw 'Heap diagnostics accepted as FPS.' }
if (!(& $completeCheck)) { throw 'Healthy heap diagnostic workload rejected.' }
$heapFailures = 1L
if (& $completeCheck) { throw 'Allocation failure accepted as healthy workload.' }
$heapFailures = 0L
$renderSlotAllocationFailures = 1L
if (& $completeCheck) { throw 'Failed render-slot growth accepted as healthy workload.' }
$renderSlotAllocationFailures = 0L
$HeapDiagnostics = $false
$BestFitHeap = $false
$VulkanGs = $true
if (& $check) { throw 'GPU mode accepted without execution evidence.' }
$vulkanActive = $true
if (& $check) { throw 'GPU mode accepted without gameplay presentations.' }
$vulkanPresents = 1280L
$vulkanSubmits = 1L
$vulkanNonblack = 1L
if (!(& $check)) { throw 'Executed GPU workload rejected.' }
$vulkanNonblack = 0L
if (& $check) { throw 'Black GPU workload accepted.' }
$vulkanNonblack = 1L
$VulkanGs = $false
$CompiledVu = $true
if (& $check) { throw 'Requested compiled engine was accepted without execution evidence.' }
$compiledCalls = 1L
if (!(& $check)) { throw 'Verified compiled workload rejected.' }
$RetainVuCache = $true
if (& $check) { throw 'Retained VU cache accepted without reuse evidence.' }
$cacheHits = 1L
if (!(& $check)) { throw 'Executed retained VU cache rejected.' }
$RetainVuCache = $false
$CompiledRetry = $true
if (& $check) { throw 'Compiled retry accepted without execution evidence.' }
$compiledRetryCalls = 1L
if (!(& $check)) { throw 'Executed compiled retry rejected.' }
$CompiledVu = $false
if (& $check) { throw 'Compiled retry accepted without compiled mode.' }
$CompiledVu = $true
$CompiledRetry = $false
$AuditCompiledVu = $true
if (& $check) { throw 'Diagnostic double-execution was accepted as an FPS measurement.' }
if (!(& $completeCheck)) { throw 'Successful VU audit did not complete its workload.' }
$AuditBilinear = $true
if (& $completeCheck) { throw 'Filter audit accepted without executed sample evidence.' }
$bilinearSamples = 1L
if (!(& $completeCheck)) { throw 'Successful combined audit did not complete its workload.' }
if (& $check) { throw 'Combined audit was accepted as an FPS measurement.' }
$AuditCompiledVu = $false
if (& $check) { throw 'Filter-only audit was accepted as an FPS measurement.' }
$AuditBilinear = $false
$bilinearSamples = 0L
$PreparedTexture = $true
if (& $completeCheck) { throw 'Prepared sampler accepted without execution evidence.' }
$preparedTextureActive = $true
if (!(& $check)) { throw 'Executed prepared sampler was rejected.' }
$AuditPreparedTexture = $true
if (& $completeCheck) { throw 'Prepared sampler audit accepted without compared sample evidence.' }
$preparedTextureSamples = 1L
if (!(& $completeCheck)) { throw 'Successful sampler audit rejected.' }
if (& $check) { throw 'Sampler double-execution was accepted as FPS.' }
$PreparedTexture = $false
if (& $completeCheck) { throw 'Sampler audit accepted without enabled sampler.' }
$AuditPreparedTexture = $false
$preparedTextureActive = $false
$preparedTextureSamples = 0L
$CompiledVu = $false
$compiledCalls = 0L
$guestFaultLines = 1
if (& $check) { throw 'A guest fault with process exit zero was accepted.' }
$guestFaultLines = 0
$process.ExitCode = 1
if (& $check) { throw 'A process failure was accepted.' }
$process.ExitCode = 0
$markers.Remove('1280')
$timingEvidence = $false
if (& $check) { throw 'An incomplete frame span was accepted.' }
$markers['1280'] = 2
$timingEvidence = $true
foreach ($name in @('reachedLimit', 'startupReached')) {
    Set-Variable -Name $name -Value $false
    if (& $check) { throw "Missing $name was accepted." }
    Set-Variable -Name $name -Value $true
}
$blockPairs = 0
$nativeBlockEvidence = $false
if (& $check) { throw 'Missing native block execution was accepted.' }

. (Join-Path $PSScriptRoot '../framebuffer-metrics.ps1')
$ppmPath = [IO.Path]::GetTempFileName()
try {
    $width = 80
    $height = 56
    $header = [Text.Encoding]::ASCII.GetBytes("P6`n# benchmark fixture`n$width $height`n255`n")
    $pixels = [byte[]]::new($width * $height * 3)
    for ($y = 8; $y -lt 48; ++$y) {
        for ($x = 16; $x -lt 72; ++$x) {
            $offset = 3 * ($y * $width + $x)
            $pixels[$offset] = 32
            $pixels[$offset + 1] = 64
            $pixels[$offset + 2] = 96
        }
    }
    $stream = [IO.File]::Open($ppmPath, [IO.FileMode]::Create, [IO.FileAccess]::Write)
    try { $stream.Write($header); $stream.Write($pixels) } finally { $stream.Dispose() }
    $metrics = Get-PpmFrameMetrics -Path $ppmPath -TileWidth 10 -TileHeight 7
    if ($metrics.Width -ne 80 -or $metrics.Height -ne 56 -or
        $metrics.NonblackPixels -ne 2240 -or $metrics.CentralNonblackPixels -ne 2240 -or
        $metrics.OccupiedTiles -ne 42 -or $metrics.Bounds.Left -ne 16 -or
        $metrics.Bounds.Top -ne 8 -or $metrics.Bounds.Right -ne 71 -or $metrics.Bounds.Bottom -ne 47) {
        throw "Unexpected PPM metrics: $($metrics | ConvertTo-Json -Compress)"
    }
    if (!(Test-WorldFrameMetrics -Metrics $metrics -MinimumNonblackPixels 2000 `
        -MinimumCentralPixels 2000 -MinimumOccupiedTiles 40)) {
        throw 'Broad synthetic framebuffer failed its world-coverage gate.'
    }
    if (Test-WorldFrameMetrics -Metrics $metrics -MinimumNonblackPixels 3000 `
        -MinimumCentralPixels 2000 -MinimumOccupiedTiles 40) {
        throw 'Sparse synthetic framebuffer passed its world-coverage gate.'
    }

    [Array]::Fill($pixels, [byte]32)
    $stream = [IO.File]::Open($ppmPath, [IO.FileMode]::Create, [IO.FileAccess]::Write)
    try { $stream.Write($header); $stream.Write($pixels) } finally { $stream.Dispose() }
    $fullMetrics = Get-PpmFrameMetrics -Path $ppmPath -TileWidth 10 -TileHeight 7
    if ($fullMetrics.NonblackPixels -ne 4480 -or $fullMetrics.OccupiedTiles -ne 64) {
        throw "Full framebuffer tile metrics used non-floor coordinates: $($fullMetrics | ConvertTo-Json -Compress)"
    }
} finally { Remove-Item -LiteralPath $ppmPath -Force -ErrorAction SilentlyContinue }

$faultExpression = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.BinaryExpressionAst] -and
    $node.Left.Extent.Text -eq '$line' -and
    $node.Right.Extent.Text.Contains('ee-thread:missing-pc')
}, $true)
if (!$faultExpression) { throw 'Guest-fault recognition is missing.' }
$recognize = [scriptblock]::Create($faultExpression.Extent.Text)
foreach ($line in @(
    '[ee-thread:missing-pc] id=1 pc=0xa3a4f0',
    '[guest-branch:missing-target] kind=DirectJump',
    '[vu:compiled-audit-failed] accepted=100 reason=state differs',
    '[gs:bilinear-audit-failed] actual=00000001 expected=00000000',
    '[gs:prepared-texture-audit-failed] actual=00000001 expected=00000000 psm=19',
    'Error during program execution: test failure'
)) {
    if (!(& $recognize)) { throw "Guest fault not recognized: $line" }
}
foreach ($line in @(
    '[gs:present] index=1280 tick=1360 has=1',
    '[run:probe-limit] vsync=1400',
    'ordinary diagnostic containing guest-branch:missing-target'
)) {
    if (& $recognize) { throw "Ordinary output misclassified: $line" }
}
$failureCatch = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.CatchClauseAst] -and
    $node.Body.Extent.Text.Contains("Status='Incomplete'")
}, $true)
if (!$failureCatch) { throw 'Incomplete-run reporting is missing.' }
$failureHandler = [scriptblock]::Create($failureCatch.Body.Statements[0].Extent.Text)
$reportPath = [IO.Path]::GetTempFileName()
$reportWritten = $false
$identity = 'synthetic-current-image'
$exe = 'synthetic.exe'
$watch = [Diagnostics.Stopwatch]::StartNew()
try {
    '{"WorkloadVerified":true,"Fps":999}' | Set-Content -LiteralPath $reportPath
    try { throw 'Synthetic runtime timeout' } catch { & $failureHandler }
    $failed = Get-Content -Raw -LiteralPath $reportPath | ConvertFrom-Json
    if ($failed.Status -ne 'Incomplete' -or $failed.Sha256 -ne $identity -or
        $failed.WorkloadVerified -or $failed.AuditVerified -or $null -ne $failed.Fps -or
        $failed.Error -ne 'Synthetic runtime timeout') { throw 'A timeout retained a stale or verified result.' }
    $reportWritten = $true
    'preserve-completed-report' | Set-Content -LiteralPath $reportPath
    try { throw 'Synthetic gate failure' } catch { & $failureHandler }
    if ((Get-Content -Raw -LiteralPath $reportPath).Trim() -ne 'preserve-completed-report') {
        throw 'Detailed completed-run failure was overwritten.'
    }
} finally { Remove-Item -LiteralPath $reportPath -Force }
'PASS gameplay benchmark: workload gates, guest-fault recognition and incomplete-run reporting'
