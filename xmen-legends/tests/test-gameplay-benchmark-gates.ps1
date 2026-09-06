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
$markers = @{ '1152' = 1; '1280' = 2 }
$guestFaultLines = 0
$CompiledVu = $false
$AuditCompiledVu = $false
$AuditBilinear = $false
$bilinearSamples = 0L
$compiledCalls = 0L
if (!(& $check)) { throw 'Healthy workload rejected.' }
$CompiledVu = $true
if (& $check) { throw 'Requested compiled engine was accepted without execution evidence.' }
$compiledCalls = 1L
if (!(& $check)) { throw 'Verified compiled workload rejected.' }
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
$CompiledVu = $false
$compiledCalls = 0L
$guestFaultLines = 1
if (& $check) { throw 'A guest fault with process exit zero was accepted.' }
$guestFaultLines = 0
$process.ExitCode = 1
if (& $check) { throw 'A process failure was accepted.' }
$process.ExitCode = 0
$markers.Remove('1280')
if (& $check) { throw 'An incomplete frame span was accepted.' }
$markers['1280'] = 2
foreach ($name in @('reachedLimit', 'newGameHandler', 'levelPackage')) {
    Set-Variable -Name $name -Value $false
    if (& $check) { throw "Missing $name was accepted." }
    Set-Variable -Name $name -Value $true
}
$blockPairs = 0
if (& $check) { throw 'Missing native block execution was accepted.' }

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
'PASS gameplay benchmark: workload gates and guest-fault recognition'
