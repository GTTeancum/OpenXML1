$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$path = (Resolve-Path (Join-Path $PSScriptRoot '../compare-vu-blocks.ps1')).Path
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw $errors[0] }
$gate = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
    $node.Clauses[0].Item1.Extent.Text.Contains('$AllowUncoveredBaseline')
}, $true)
if (!$gate) { throw 'Block coverage gate is missing.' }
$reject = [scriptblock]::Create($gate.Clauses[0].Item1.Extent.Text)
$pattern = 'attempted=(\d+) executed=(\d+) pairs=(\d+)'
$blocks = $true
$mode = 'baseline'
$AllowUncoveredBaseline = $false
$coverage = [regex]::Match('attempted=12 executed=0 pairs=0', $pattern)
if (!(& $reject)) { throw 'Default gate accepted an uncovered baseline.' }
$AllowUncoveredBaseline = $true
if (& $reject) { throw 'Explicit uncovered baseline was rejected.' }
$coverage = [regex]::Match('', $pattern)
if (!(& $reject)) { throw 'Missing coverage evidence was accepted.' }
$coverage = [regex]::Match('attempted=12 executed=0 pairs=0', $pattern)
$mode = 'candidate'
if (!(& $reject)) { throw 'Uncovered candidate was accepted.' }
$coverage = [regex]::Match('attempted=12 executed=1 pairs=8', $pattern)
if (& $reject) { throw 'Executed candidate was rejected.' }
$blocks = $false
$coverage = [regex]::Match('', $pattern)
if (& $reject) { throw 'Pair-only baseline incorrectly requires blocks.' }
'PASS block comparison: uncovered baseline is explicit; candidate execution remains required'
