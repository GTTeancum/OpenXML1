$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '../run-interactive.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path $path), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }

# Execute the real environment configuration without starting a process or
# changing the startup package. This also exercises inherited probe settings.
$body = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.TryStatementAst] -and
    $node.Body.Extent.Text.Contains('$startInfo =')
}, $true).Body.Statements
$configuration = @()
$collect = $false
foreach ($statement in $body) {
    if ($statement -is [System.Management.Automation.Language.AssignmentStatementAst]) {
        if ($statement.Left.Extent.Text -eq '$startInfo') { $collect = $true }
        if ($statement.Left.Extent.Text -eq '$process') { break }
    }
    if ($collect) { $configuration += $statement.Extent.Text }
}
if (!$configuration.Count) { throw 'Missing interactive process configuration.' }
$configure = [scriptblock]::Create($configuration -join "`n")
$exe = 'unused-test-runner.exe'
$disc = $PSScriptRoot
$RuntimeVariant = 'Candidate'
$StartupMovieMode = 'TitleGameplayFirst'
$FastBranchHooks = $false
$CompatibilityBranchHooks = $false
$Diagnostics = $false
$WhiteWireframe = $false
$SuppressLateSprites = $false
$optimizedRuntime = $true
$CompiledVu = $false
$CompiledStreamBlockBytes = 32
$CompiledStreamBatch = $true
$Vu1ServiceTraceMinTick = 0
$names = @('PS2X_DISABLE_HOST_INPUT', 'PS2X_RUN_VSYNC_LIMIT', 'PS2X_VU_COMPILED_AUDIT',
    'PS2X_GS_VERIFY_BILINEAR', 'PS2X_AUTOMOVE_LEFT_STICK_AT_TICK')
$saved = @{}
try {
    foreach ($name in $names) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, '1')
    }
    . $configure
    foreach ($name in $names) {
        if ($startInfo.Environment.ContainsKey($name)) { throw "Inherited probe setting survived: $name" }
    }
    foreach ($name in @('PS2X_VU_NATIVE_PAIRS', 'PS2X_VU_NATIVE_BLOCKS', 'PS2X_VU_COMPILED',
        'PS2X_VU_COMPILED_STREAM', 'PS2X_VU_COMPILED_STREAM_BATCH',
        'PS2X_GS_PLAY_VULKAN', 'PS2X_XMEN_START_FIRST_LEVEL')) {
        if ($startInfo.Environment[$name] -ne '1') { throw "Missing candidate gameplay option: $name" }
    }
    if ($startInfo.Environment['PS2X_VU_COMPILED_STREAM_BLOCK_BYTES'] -ne '32') {
        throw 'Interactive stream block limit is not the verified value.'
    }
    if (!$startInfo.CreateNoWindow -or $startInfo.UseShellExecute) { throw 'Launcher must hide its console.' }
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
}

$function = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Update-InteractiveStatus'
}, $true)
. ([scriptblock]::Create($function.Extent.Text))
$status = @{ Running = $true; HostInput = $true; CompiledVu = $true
    DirectMapStart = $false; NewGameHandler = $false; LevelPackage = $false; LastPresent = 0L
    CompiledCallsLowerBound = 0L; CompiledStreamCompletedLowerBound = 0L
    GuestFaultLines = 0; FirstGuestFault = $null; ReadyForInput = $false }
foreach ($line in @('[xmen-newgame-handler] invoked',
    '[open] path="maps/nyc/alison/nyc1_1_1.igb"', '[gs:present] index=1152 tick=1300 has=0')) {
    Update-InteractiveStatus $status $line
    if ($status.ReadyForInput) { throw 'Ready without compiled execution evidence.' }
}
Update-InteractiveStatus $status '[vu:compiled] accepted=4097'
if ($status.ReadyForInput) { throw 'Missing presentation marked ready.' }
Update-InteractiveStatus $status '[gs:present] index=1152 tick=1300 has=1'
if (!$status.ReadyForInput) { throw 'Healthy interactive workload not ready.' }
$status.HostInput = $false
Update-InteractiveStatus $status 'unrelated output'
if ($status.ReadyForInput) { throw 'Disabled input marked ready.' }
$status.HostInput = $true
$status.Running = $false
Update-InteractiveStatus $status 'unrelated output'
if ($status.ReadyForInput) { throw 'Exited runtime marked ready.' }
$status.Running = $true
Update-InteractiveStatus $status 'Error during program execution: sample fault'
if ($status.ReadyForInput -or $status.GuestFaultLines -ne 1) { throw 'Faulting runtime marked ready.' }
$directMapStatus = @{ Running = $true; HostInput = $true; CompiledVu = $false
    DirectMapStart = $true; NewGameHandler = $false; LevelPackage = $true; LastPresent = 512L
    CompiledCallsLowerBound = 0L; CompiledStreamCompletedLowerBound = 0L
    GuestFaultLines = 0; FirstGuestFault = $null; ReadyForInput = $false }
Update-InteractiveStatus $directMapStatus '[gs:present] index=512 tick=700 has=1'
if ($directMapStatus.ReadyForInput) { throw 'Direct-map diagnostic route was accepted as playable.' }
'PASS interactive launcher: inherited probes removed, compiled VU retained, readiness gates verified; no processes launched.'
