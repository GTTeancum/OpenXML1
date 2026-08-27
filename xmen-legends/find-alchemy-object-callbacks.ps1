param(
    [string]$Disassembly = "$PSScriptRoot\SLUS_206.56.disasm.txt",
    [string]$Manifest = "$PSScriptRoot\xmen-legends.resume-entry-points.txt",
    [int]$FieldOffset = 60
)

$ErrorActionPreference = 'Stop'
$lines = Get-Content -LiteralPath $Disassembly
$addressToLine = @{}
for ($i = 0; $i -lt $lines.Count; ++$i) {
    if ($lines[$i] -match '^\s*([0-9a-f]+):') {
        $addressToLine[[Convert]::ToUInt32($matches[1], 16)] = $i
    }
}

function Resolve-ConstantRegister(
    [string]$Register,
    [int]$BeforeLine,
    [int]$StartLine,
    [int]$Depth = 0
) {
    if ($Register -eq 'zero') {
        return [uint32]0
    }
    if ($Depth -gt 8) {
        return $null
    }

    for ($i = $BeforeLine; $i -ge $StartLine; --$i) {
        $instruction = [regex]::Match(
            $lines[$i],
            '^\s*[0-9a-f]+:\s+[0-9a-f]+\s+([a-z0-9.]+)\s*(.*)$')
        if (-not $instruction.Success) {
            continue
        }

        $opcode = $instruction.Groups[1].Value
        $arguments = $instruction.Groups[2].Value.Trim()
        $destination = [regex]::Match($arguments, '^([a-z0-9]+),')
        if (-not $destination.Success -or $destination.Groups[1].Value -ne $Register) {
            continue
        }

        if ($opcode -eq 'lui' -and $arguments -match '^\w+,0x([0-9a-f]+)$') {
            return [uint32]([Convert]::ToUInt32($matches[1], 16) -shl 16)
        }
        if ($opcode -in @('addiu', 'daddiu') -and
            $arguments -match '^\w+,(\w+),(-?\d+)$') {
            $source = Resolve-ConstantRegister $matches[1] ($i - 1) $StartLine ($Depth + 1)
            if ($null -eq $source) {
                return $null
            }
            return [uint32](([int64]$source + [int64]$matches[2]) -band 0xffffffffL)
        }
        if ($opcode -eq 'ori' -and $arguments -match '^\w+,(\w+),0x([0-9a-f]+)$') {
            $source = Resolve-ConstantRegister $matches[1] ($i - 1) $StartLine ($Depth + 1)
            if ($null -eq $source) {
                return $null
            }
            return [uint32]($source -bor [Convert]::ToUInt32($matches[2], 16))
        }
        if ($opcode -eq 'li' -and $arguments -match '^\w+,(-?\d+)$') {
            return [uint32](([int64]$matches[1]) -band 0xffffffffL)
        }
        if ($opcode -eq 'move' -and $arguments -match '^\w+,(\w+)$') {
            return Resolve-ConstantRegister $matches[1] ($i - 1) $StartLine ($Depth + 1)
        }
        return $null
    }
    return $null
}

$constructors = [System.Collections.Generic.HashSet[uint32]]::new()
$unresolvedConstructors = [System.Collections.Generic.List[string]]::new()
$registrationCalls = 0
for ($i = 0; $i -lt $lines.Count; ++$i) {
    if ($lines[$i] -notmatch '\bjal\s+0x212c20\b') {
        continue
    }

    ++$registrationCalls
    $startLine = $i
    while ($startLine -gt 0 -and $lines[$startLine - 1] -notmatch '^\s*\.\.\.') {
        --$startLine
    }

    $storeLine = -1
    $sourceRegister = $null
    for ($j = $i - 1; $j -ge $startLine; --$j) {
        if ($lines[$j] -match '\b(?:sd|sw)\s+(\w+),0\(sp\)') {
            $storeLine = $j
            $sourceRegister = $matches[1]
            break
        }
    }
    if ($storeLine -lt 0) {
        $unresolvedConstructors.Add(('disassembly line {0}: no stack-0 store' -f ($i + 1)))
        continue
    }

    $constructor = Resolve-ConstantRegister $sourceRegister ($storeLine - 1) $startLine
    if ($null -eq $constructor) {
        $unresolvedConstructors.Add(('disassembly line {0}: unresolved stack-0 store' -f `
            ($storeLine + 1)))
        continue
    }
    [void]$constructors.Add([uint32]$constructor)
}

$callbacks = [System.Collections.Generic.HashSet[uint32]]::new()
$unresolvedStores = [System.Collections.Generic.List[string]]::new()
$storeCount = 0
$storePattern = '\bsw\s+(\w+),' + $FieldOffset + '\((\w+)\)'
foreach ($constructor in $constructors) {
    if (-not $addressToLine.ContainsKey($constructor)) {
        $unresolvedStores.Add(('0x{0:x}: no instruction' -f $constructor))
        continue
    }

    $startLine = [int]$addressToLine[$constructor]
    for ($i = $startLine; $i -lt $lines.Count; ++$i) {
        if ($i -gt $startLine -and $lines[$i] -match '^\s*\.\.\.') {
            break
        }
        if ($lines[$i] -notmatch $storePattern) {
            continue
        }

        ++$storeCount
        $callback = Resolve-ConstantRegister $matches[1] ($i - 1) $startLine
        if ($null -eq $callback) {
            $unresolvedStores.Add(('0x{0:x}: store at disassembly line {1}' -f `
                $constructor, ($i + 1)))
            continue
        }
        if ($callback -ge 0x00100000 -and $callback -lt 0x00630000 -and
            ($callback -band 3) -eq 0) {
            [void]$callbacks.Add([uint32]$callback)
        }
    }
}

$manifestEntries = [System.Collections.Generic.HashSet[uint32]]::new()
foreach ($line in Get-Content -LiteralPath $Manifest) {
    if ($line -match '^0x([0-9a-f]+)$') {
        [void]$manifestEntries.Add([Convert]::ToUInt32($matches[1], 16))
    }
}
$missing = @($callbacks | Where-Object { -not $manifestEntries.Contains($_) } | Sort-Object)
$missingConstructors = @($constructors | Where-Object {
    $_ -ge 0x00100000 -and $_ -lt 0x00630000 -and
    ($_ -band 3) -eq 0 -and -not $manifestEntries.Contains($_)
} | Sort-Object)

Write-Host (('registration_calls={0} constructor_targets={1} unresolved_constructors={2} ' +
    'field_stores={3} code_callbacks={4} unresolved_stores={5} missing_callbacks={6} ' +
    'missing_constructors={7}') -f `
    $registrationCalls, $constructors.Count, $unresolvedConstructors.Count, $storeCount, $callbacks.Count,
    $unresolvedStores.Count, $missing.Count, $missingConstructors.Count)
Write-Host ('known_constructor_1ca0e0={0} known_callback_1ca1d0={1}' -f `
    $constructors.Contains(0x001ca0e0), $callbacks.Contains(0x001ca1d0))
if ($unresolvedConstructors.Count -gt 0) {
    Write-Host 'UNRESOLVED CONSTRUCTORS'
    $unresolvedConstructors
}
if ($unresolvedStores.Count -gt 0) {
    Write-Host 'UNRESOLVED'
    $unresolvedStores
}
Write-Host 'MISSING'
$missing | ForEach-Object { '0x{0:x}' -f $_ }
Write-Host 'MISSING CONSTRUCTORS'
$missingConstructors | ForEach-Object { '0x{0:x}' -f $_ }
