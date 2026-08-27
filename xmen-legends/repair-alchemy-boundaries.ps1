param(
    [string]$Disassembly = "$PSScriptRoot\SLUS_206.56.disasm.txt",
    [string]$Elf = "$PSScriptRoot\SLUS_206.56",
    [string]$FunctionMap = "$PSScriptRoot\xmen-legends.synthetic-ghidra.final3.csv",
    [string]$GeneratedDirectory = "$PSScriptRoot\output_mapped_final3",
    [string]$ObservedEntryPointsFile = "$PSScriptRoot\xmen-legends.resume-entry-points.observed.txt"
)

$ErrorActionPreference = 'Stop'

function Parse-HexAddress([string]$text) {
    return [Convert]::ToUInt32($text.Substring(2), 16)
}

function Set-RegisterValue($registers, [string]$name, [uint32]$value) {
    $registers[$name] = $value
}

$rows = @(Import-Csv $FunctionMap | ForEach-Object {
    [pscustomobject]@{
        Name = $_.Name
        Start = Parse-HexAddress $_.Start
        End = Parse-HexAddress $_.End
    }
})

function Find-OwnerRowIndex([uint32]$address) {
    $low = 0
    $high = $rows.Count - 1
    while ($low -le $high) {
        $middle = [int](($low + $high) / 2)
        $row = $rows[$middle]
        if ($address -lt $row.Start) {
            $high = $middle - 1
        }
        elseif ($address -ge $row.End) {
            $low = $middle + 1
        }
        else {
            return $middle
        }
    }
    return -1
}

$existingStarts = [System.Collections.Generic.HashSet[uint32]]::new()
foreach ($row in $rows) {
    [void]$existingStarts.Add($row.Start)
}

$lines = Get-Content $Disassembly
$delaySlots = [System.Collections.Generic.HashSet[uint32]]::new()
$instructionAddresses = [System.Collections.Generic.HashSet[uint32]]::new()
foreach ($line in $lines) {
    $instruction = [regex]::Match($line, '^\s*([0-9a-f]+):\s+[0-9a-f]+\s+([a-z0-9.]+)')
    if ($instruction.Success) {
        $instructionAddress = [Convert]::ToUInt32($instruction.Groups[1].Value, 16)
        [void]$instructionAddresses.Add($instructionAddress)
        if ($instruction.Groups[2].Value -match '^(b|bal|beq|beqz|bne|bnez|bgez|bgezal|bgtz|blez|bltz|bltzal|bc1f|bc1t|j|jal|jalr|jr)$') {
            [void]$delaySlots.Add($instructionAddress + 4u)
        }
    }
}
$candidates = [System.Collections.Generic.HashSet[uint32]]::new()
$observedEntryPoints = [System.Collections.Generic.HashSet[uint32]]::new()
foreach ($line in Get-Content -LiteralPath $ObservedEntryPointsFile) {
    if ($line.Trim() -match '^0x([0-9a-fA-F]+)$') {
        [void]$observedEntryPoints.Add([Convert]::ToUInt32($matches[1], 16))
    }
}

# Required indirect targets observed in runtime traces whose owning metadata is
# outside the Alchemy-only static scan below.
foreach ($address in @(0x00324FB0u, 0x004005A0u)) {
    [void]$candidates.Add($address)
}

# The C++ array construction helper at 0x100450 receives constructor and
# destructor function pointers in a1/a2. Recover every statically resolved pair.
for ($i = 0; $i -lt $lines.Count; ++$i) {
    if ($lines[$i] -notmatch '\bjal\s+0x100450\b') {
        continue
    }

    $registers = @{}
    for ($j = [Math]::Max(0, $i - 24); $j -le [Math]::Min($i + 1, $lines.Count - 1); ++$j) {
        $line = $lines[$j]
        if ($line -match 'lui\s+(\w+),0x([0-9a-f]+)') {
            Set-RegisterValue $registers $matches[1] ([Convert]::ToUInt32($matches[2], 16) -shl 16)
        }
        elseif ($line -match 'addiu\s+(\w+),(\w+),(-?\d+)') {
            if ($registers.ContainsKey($matches[2])) {
                Set-RegisterValue $registers $matches[1] ([uint32](([int64]$registers[$matches[2]] + [int]$matches[3]) -band 0xffffffffL))
            }
            else {
                $registers.Remove($matches[1])
            }
        }
        elseif ($line -match 'ori\s+(\w+),(\w+),0x([0-9a-f]+)') {
            if ($registers.ContainsKey($matches[2])) {
                Set-RegisterValue $registers $matches[1] ([uint32]($registers[$matches[2]] -bor [Convert]::ToUInt32($matches[3], 16)))
            }
            else {
                $registers.Remove($matches[1])
            }
        }
        elseif ($line -match 'move\s+(\w+),(\w+)') {
            if ($matches[2] -eq 'zero') {
                Set-RegisterValue $registers $matches[1] 0u
            }
            elseif ($registers.ContainsKey($matches[2])) {
                Set-RegisterValue $registers $matches[1] $registers[$matches[2]]
            }
            else {
                $registers.Remove($matches[1])
            }
        }
    }

    foreach ($name in @('a1', 'a2')) {
        if (-not $registers.ContainsKey($name)) {
            continue
        }
        $address = [uint32]$registers[$name]
        if ($address -ge 0x00100000u -and $address -lt 0x00630000u -and
            ($address -band 3u) -eq 0u -and
            $instructionAddresses.Contains($address) -and
            -not $delaySlots.Contains($address)) {
            [void]$candidates.Add($address)
        }
    }
}

# Static initialization-list wrappers pass their producer callback in a0 to
# 0x212ba0, while 0x203b20 stores an a0 callback in the global allocation hook.
for ($i = 0; $i -lt $lines.Count; ++$i) {
    if ($lines[$i] -notmatch '\b(?:j|jal)\s+0x(?:212ba0|203b20)\b') {
        continue
    }

    $registers = @{}
    for ($j = [Math]::Max(0, $i - 24); $j -le [Math]::Min($i + 1, $lines.Count - 1); ++$j) {
        $line = $lines[$j]
        if ($line -match 'lui\s+(\w+),0x([0-9a-f]+)') {
            Set-RegisterValue $registers $matches[1] ([Convert]::ToUInt32($matches[2], 16) -shl 16)
        }
        elseif ($line -match 'addiu\s+(\w+),(\w+),(-?\d+)') {
            if ($registers.ContainsKey($matches[2])) {
                Set-RegisterValue $registers $matches[1] ([uint32](([int64]$registers[$matches[2]] + [int]$matches[3]) -band 0xffffffffL))
            }
            else {
                $registers.Remove($matches[1])
            }
        }
        elseif ($line -match 'ori\s+(\w+),(\w+),0x([0-9a-f]+)') {
            if ($registers.ContainsKey($matches[2])) {
                Set-RegisterValue $registers $matches[1] ([uint32]($registers[$matches[2]] -bor [Convert]::ToUInt32($matches[3], 16)))
            }
            else {
                $registers.Remove($matches[1])
            }
        }
        elseif ($line -match 'move\s+(\w+),(\w+)') {
            if ($matches[2] -eq 'zero') {
                Set-RegisterValue $registers $matches[1] 0u
            }
            elseif ($registers.ContainsKey($matches[2])) {
                Set-RegisterValue $registers $matches[1] $registers[$matches[2]]
            }
            else {
                $registers.Remove($matches[1])
            }
        }
    }

    if ($registers.ContainsKey('a0')) {
        $address = [uint32]$registers['a0']
        if ($address -ge 0x00100000u -and $address -lt 0x00630000u -and
            ($address -band 3u) -eq 0u -and
            $instructionAddresses.Contains($address) -and
            -not $delaySlots.Contains($address)) {
            [void]$candidates.Add($address)
        }
    }
}

for ($i = 0; $i -lt $lines.Count; ++$i) {
    if ($lines[$i] -notmatch 'jal\s+0x212c20') {
        continue
    }

    $windowStart = [Math]::Max(0, $i - 50)
    for ($j = $i - 1; $j -ge $windowStart; --$j) {
        if ($lines[$j] -match '\bjal\b') {
            $windowStart = $j + 1
            break
        }
    }

    $registers = @{}
    $stackArguments = @{}
    # Include the call's delay slot: several registrations complete t3 there.
    for ($j = $windowStart; $j -le [Math]::Min($i + 1, $lines.Count - 1); ++$j) {
        $line = $lines[$j]
        if ($line -match 'lui\s+(\w+),0x([0-9a-f]+)') {
            Set-RegisterValue $registers $matches[1] ([Convert]::ToUInt32($matches[2], 16) -shl 16)
        }
        elseif ($line -match 'addiu\s+(\w+),(\w+),(-?\d+)') {
            if ($registers.ContainsKey($matches[2])) {
                Set-RegisterValue $registers $matches[1] ([uint32](([int64]$registers[$matches[2]] + [int]$matches[3]) -band 0xffffffffL))
            }
            else {
                $registers.Remove($matches[1])
            }
        }
        elseif ($line -match 'ori\s+(\w+),(\w+),0x([0-9a-f]+)') {
            if ($registers.ContainsKey($matches[2])) {
                Set-RegisterValue $registers $matches[1] ([uint32]($registers[$matches[2]] -bor [Convert]::ToUInt32($matches[3], 16)))
            }
            else {
                $registers.Remove($matches[1])
            }
        }
        elseif ($line -match 'move\s+(\w+),(\w+)') {
            if ($matches[2] -eq 'zero') {
                Set-RegisterValue $registers $matches[1] 0
            }
            elseif ($registers.ContainsKey($matches[2])) {
                Set-RegisterValue $registers $matches[1] $registers[$matches[2]]
            }
            else {
                $registers.Remove($matches[1])
            }
        }
        elseif ($line -match 'li\s+(\w+),(-?\d+)') {
            Set-RegisterValue $registers $matches[1] ([uint32]([int]$matches[2]))
        }

        if ($line -match 'sd\s+(\w+),(\d+)\(sp\)') {
            if ($matches[1] -eq 'zero') {
                $stackArguments[[int]$matches[2]] = [uint32]0
            }
            elseif ($registers.ContainsKey($matches[1])) {
                $stackArguments[[int]$matches[2]] = $registers[$matches[1]]
            }
        }
    }

    $values = @()
    foreach ($name in @('a2', 'a3', 't0', 't1', 't3')) {
        if ($registers.ContainsKey($name)) {
            $values += [uint32]$registers[$name]
        }
    }
    foreach ($offset in @(0, 8, 16)) {
        if ($stackArguments.ContainsKey($offset)) {
            $values += [uint32]$stackArguments[$offset]
        }
    }
foreach ($value in $values) {
        if ($value -ge 0x00100000 -and $value -lt 0x00630000 -and ($value -band 3) -eq 0 -and
            -not $delaySlots.Contains($value)) {
            [void]$candidates.Add($value)
        }
    }
}

# Alchemy also supplies class-wide setup callbacks to these traversal helpers.
# Their function pointer is commonly completed in the call's delay slot.
for ($i = 0; $i -lt $lines.Count; ++$i) {
    if ($lines[$i] -notmatch '\b(?:j|jal)\s+0x2126(?:40|50)\b') {
        continue
    }

    $registers = @{}
    $windowStart = [Math]::Max(0, $i - 20)
    for ($j = $windowStart; $j -le [Math]::Min($i + 1, $lines.Count - 1); ++$j) {
        $line = $lines[$j]
        if ($line -match 'lui\s+(\w+),0x([0-9a-f]+)') {
            Set-RegisterValue $registers $matches[1] ([Convert]::ToUInt32($matches[2], 16) -shl 16)
        }
        elseif ($line -match 'addiu\s+(\w+),(\w+),(-?\d+)') {
            if ($registers.ContainsKey($matches[2])) {
                Set-RegisterValue $registers $matches[1] ([uint32](([int64]$registers[$matches[2]] + [int]$matches[3]) -band 0xffffffffL))
            }
            else {
                $registers.Remove($matches[1])
            }
        }
        elseif ($line -match 'ori\s+(\w+),(\w+),0x([0-9a-f]+)') {
            if ($registers.ContainsKey($matches[2])) {
                Set-RegisterValue $registers $matches[1] ([uint32]($registers[$matches[2]] -bor [Convert]::ToUInt32($matches[3], 16)))
            }
            else {
                $registers.Remove($matches[1])
            }
        }
        elseif ($line -match 'move\s+(\w+),(\w+)') {
            if ($matches[2] -eq 'zero') {
                Set-RegisterValue $registers $matches[1] 0
            }
            elseif ($registers.ContainsKey($matches[2])) {
                Set-RegisterValue $registers $matches[1] $registers[$matches[2]]
            }
            else {
                $registers.Remove($matches[1])
            }
        }
    }

    if ($registers.ContainsKey('a0')) {
        $value = [uint32]$registers['a0']
        if ($value -ge 0x00100000 -and $value -lt 0x00630000 -and ($value -band 3) -eq 0 -and
            -not $delaySlots.Contains($value)) {
            [void]$candidates.Add($value)
        }
    }
}

# 0x567278 installs a callback from a1 into the stream-service table. Recover
# each non-null callback assembled at its call sites.
for ($i = 0; $i -lt $lines.Count; ++$i) {
    if ($lines[$i] -notmatch '\bjal\s+0x567278\b') {
        continue
    }

    $registers = @{}
    for ($j = [Math]::Max(0, $i - 12); $j -le [Math]::Min($i + 1, $lines.Count - 1); ++$j) {
        $line = $lines[$j]
        if ($line -match 'lui\s+(\w+),0x([0-9a-f]+)') {
            Set-RegisterValue $registers $matches[1] ([Convert]::ToUInt32($matches[2], 16) -shl 16)
        }
        elseif ($line -match 'addiu\s+(\w+),(\w+),(-?\d+)') {
            if ($registers.ContainsKey($matches[2])) {
                Set-RegisterValue $registers $matches[1] ([uint32](([int64]$registers[$matches[2]] + [int]$matches[3]) -band 0xffffffffL))
            }
            else {
                $registers.Remove($matches[1])
            }
        }
        elseif ($line -match 'move\s+(\w+),(\w+)') {
            if ($matches[2] -eq 'zero') {
                Set-RegisterValue $registers $matches[1] 0u
            }
            elseif ($registers.ContainsKey($matches[2])) {
                Set-RegisterValue $registers $matches[1] $registers[$matches[2]]
            }
            else {
                $registers.Remove($matches[1])
            }
        }
    }

    if ($registers.ContainsKey('a1')) {
        $callbackAddress = [uint32]$registers['a1']
        if ($callbackAddress -ge 0x00100000u -and $callbackAddress -lt 0x00630000u -and
            ($callbackAddress -band 3u) -eq 0u -and
            $instructionAddresses.Contains($callbackAddress) -and
            -not $delaySlots.Contains($callbackAddress)) {
            [void]$candidates.Add($callbackAddress)
        }
    }
}

# The game registers its Python commands through a contiguous static table. These
# function pointers are only reached indirectly, so ordinary disassembly misses
# them as function starts (including startMovie and openmenu).
$elfBytes = [IO.File]::ReadAllBytes($Elf)

# The movie-record vtable is below the broad Alchemy metadata range and would
# otherwise be filtered as ordinary static data. Its non-null entries are all
# record callbacks reached through record->vtable.
foreach ($entryAddress in 0x00666BD4u..0x00666C08u | Where-Object { (($_ - 0x00666BD4u) % 4u) -eq 0u }) {
    $fileOffset = [int]($entryAddress - 0x000FFF80u)
    $callbackAddress = [BitConverter]::ToUInt32($elfBytes, $fileOffset)
    if ($callbackAddress -ge 0x00100000u -and $callbackAddress -lt 0x00630000u -and
        ($callbackAddress -band 3u) -eq 0u -and
        $instructionAddresses.Contains($callbackAddress) -and
        -not $delaySlots.Contains($callbackAddress)) {
        [void]$candidates.Add($callbackAddress)
    }
}

# 0x212100 walks a caller-supplied constructor table in a1, with its entry
# count in a2. These tables live below the broad Alchemy metadata range, so
# recover only arrays that are explicitly passed to this traversal helper.
for ($i = 0; $i -lt $lines.Count; ++$i) {
    if ($lines[$i] -notmatch '\bjal\s+0x212100\b') {
        continue
    }

    $registers = @{}
    $windowStart = [Math]::Max(0, $i - 24)
    for ($j = $windowStart; $j -le [Math]::Min($i + 1, $lines.Count - 1); ++$j) {
        $line = $lines[$j]
        if ($line -match 'lui\s+(\w+),0x([0-9a-f]+)') {
            Set-RegisterValue $registers $matches[1] ([Convert]::ToUInt32($matches[2], 16) -shl 16)
        }
        elseif ($line -match 'addiu\s+(\w+),(\w+),(-?\d+)') {
            if ($registers.ContainsKey($matches[2])) {
                Set-RegisterValue $registers $matches[1] ([uint32](([int64]$registers[$matches[2]] + [int]$matches[3]) -band 0xffffffffL))
            }
            else {
                $registers.Remove($matches[1])
            }
        }
        elseif ($line -match 'ori\s+(\w+),(\w+),0x([0-9a-f]+)') {
            if ($registers.ContainsKey($matches[2])) {
                Set-RegisterValue $registers $matches[1] ([uint32]($registers[$matches[2]] -bor [Convert]::ToUInt32($matches[3], 16)))
            }
            else {
                $registers.Remove($matches[1])
            }
        }
        elseif ($line -match 'li\s+(\w+),(-?\d+)') {
            Set-RegisterValue $registers $matches[1] ([uint32]([int]$matches[2]))
        }
        elseif ($line -match 'move\s+(\w+),(\w+)') {
            if ($matches[2] -eq 'zero') {
                Set-RegisterValue $registers $matches[1] 0u
            }
            elseif ($registers.ContainsKey($matches[2])) {
                Set-RegisterValue $registers $matches[1] $registers[$matches[2]]
            }
            else {
                $registers.Remove($matches[1])
            }
        }
    }

    if (-not $registers.ContainsKey('a1') -or -not $registers.ContainsKey('a2')) {
        continue
    }
    $tableAddress = [uint32]$registers['a1']
    $entryCount = [uint32]$registers['a2']
    if ($tableAddress -lt 0x00630000u -or $tableAddress -ge 0x006A0000u -or
        $entryCount -eq 0u -or $entryCount -gt 1024u) {
        continue
    }

    for ($entry = 0u; $entry -lt $entryCount; ++$entry) {
        $fileOffset = [int]($tableAddress + ($entry * 4u) - 0x000FFF80u)
        if ($fileOffset -lt 0 -or $fileOffset + 3 -ge $elfBytes.Length) {
            break
        }
        $callbackAddress = [BitConverter]::ToUInt32($elfBytes, $fileOffset)
        if ($callbackAddress -ge 0x00100000u -and $callbackAddress -lt 0x00630000u -and
            ($callbackAddress -band 3u) -eq 0u -and
            $instructionAddresses.Contains($callbackAddress) -and
            -not $delaySlots.Contains($callbackAddress)) {
            [void]$candidates.Add($callbackAddress)
        }
    }
}

# Alchemy's class metadata contains direct method pointers in the ELF data segment.
# Recovering these as interior entry points avoids discovering vtable methods one
# missing indirect call at a time while preserving their original owner ranges.
$elfLoadBias = 0x000FFF80u
$dataStartAddress = 0x00630000u
$alchemyMetadataStartAddress = 0x006A0000u
$discardedStaticDataCandidates = [System.Collections.Generic.HashSet[uint32]]::new()
$dataStartOffset = [int]($dataStartAddress - $elfLoadBias)
for ($fileOffset = $dataStartOffset; $fileOffset + 3 -lt $elfBytes.Length; $fileOffset += 4) {
    $callbackAddress = [BitConverter]::ToUInt32($elfBytes, $fileOffset)
    if ($callbackAddress -ge 0x00100000u -and $callbackAddress -lt $dataStartAddress -and
        ($callbackAddress -band 3u) -eq 0u -and
        $instructionAddresses.Contains($callbackAddress) -and
        -not $delaySlots.Contains($callbackAddress)) {
        $storageAddress = [uint32]($fileOffset + $elfLoadBias)
        if ($storageAddress -ge $alchemyMetadataStartAddress) {
            [void]$candidates.Add($callbackAddress)
        }
        else {
            [void]$discardedStaticDataCandidates.Add($callbackAddress)
        }
    }
}

for ($entryAddress = 0x006B3560u; $entryAddress -le 0x006B41A0u; $entryAddress += 0x10u) {
    $fileOffset = [int]($entryAddress - 0x000FFF80u)
    $callbackAddress = [BitConverter]::ToUInt32($elfBytes, $fileOffset)
    if ($callbackAddress -ge 0x00100000u -and $callbackAddress -lt 0x00630000u -and
        ($callbackAddress -band 3u) -eq 0u -and -not $delaySlots.Contains($callbackAddress)) {
        [void]$candidates.Add($callbackAddress)
    }
}

# Console commands are registered by name through the global command manager.
# Recover the code pointer passed in a2 to its registration slot (+0x14).
for ($i = 0; $i -lt $lines.Count - 1; ++$i) {
    if ($lines[$i] -notmatch '\bjalr\s+t9\b' -or
        $lines[$i + 1] -notmatch 'addiu\s+a2,a2,(-?\d+)') {
        continue
    }

    $lowOffset = [int]$matches[1]
    $highHalf = $null
    $hasManagerAccessor = $false
    $hasRegistrationSlot = $false
    for ($j = [Math]::Max(0, $i - 16); $j -lt $i; ++$j) {
        if ($lines[$j] -match '\bjal\s+0x345040\b') {
            $hasManagerAccessor = $true
        }
        if ($lines[$j] -match '\blw\s+t9,20\(t9\)') {
            $hasRegistrationSlot = $true
        }
        if ($lines[$j] -match '\blui\s+a2,0x([0-9a-f]+)') {
            $highHalf = [Convert]::ToUInt32($matches[1], 16)
        }
    }

    if ($hasManagerAccessor -and $hasRegistrationSlot -and $null -ne $highHalf) {
        $callbackAddress = [uint32](([int64]($highHalf -shl 16) + $lowOffset) -band 0xffffffffL)
        if ($callbackAddress -ge 0x00100000u -and $callbackAddress -lt 0x00630000u -and
            ($callbackAddress -band 3u) -eq 0u -and -not $delaySlots.Contains($callbackAddress)) {
            [void]$candidates.Add($callbackAddress)
        }
    }
}

# Keep runtime-observed interior entries that the recompiler validated and
# emitted. Some of these also appear as ordinary pointers below the Alchemy
# metadata region, so the static-data cleanup must not discard them.
$observedSourceCache = @{}
foreach ($address in $observedEntryPoints) {
    if ($existingStarts.Contains($address)) {
        continue
    }

    $rowIndex = Find-OwnerRowIndex $address
    if ($rowIndex -lt 0) {
        continue
    }

    $row = $rows[$rowIndex]
    $sourcePath = Join-Path $GeneratedDirectory ($row.Name + '_0x' + ('{0:x}' -f $row.Start) + '.cpp')
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        continue
    }
    if (-not $observedSourceCache.ContainsKey($sourcePath)) {
        $observedSourceCache[$sourcePath] = [IO.File]::ReadAllText($sourcePath)
    }

    $hex = '{0:x}' -f $address
    if ($observedSourceCache[$sourcePath] -match ('(?i)case\s+0x0*' + $hex + 'u:') -or
        ($instructionAddresses.Contains($address) -and -not $delaySlots.Contains($address))) {
        [void]$candidates.Add($address)
    }
}

$missing = @($candidates | Where-Object { -not $existingStarts.Contains($_) } | Sort-Object)

# Persist validated interior entries so the next recompiler run emits their
# resume cases directly instead of requiring another broad source repair.
$observedEntryPointsChanged = $false
foreach ($address in $missing) {
    if ($observedEntryPoints.Add($address)) {
        $observedEntryPointsChanged = $true
    }
}
if ($observedEntryPointsChanged) {
    $observedLines = @($observedEntryPoints | Sort-Object | ForEach-Object {
        '0x{0:X8}' -f $_
    })
    [IO.File]::WriteAllLines($ObservedEntryPointsFile, $observedLines)
}

$byRow = @{}
foreach ($address in $missing) {
    $rowIndex = Find-OwnerRowIndex $address
    if ($rowIndex -lt 0) {
        continue
    }
    if (-not $byRow.ContainsKey($rowIndex)) {
        $byRow[$rowIndex] = [System.Collections.Generic.List[uint32]]::new()
    }
    $byRow[$rowIndex].Add($address)
}

$registrationLines = [System.Collections.Generic.List[string]]::new()
$registerPath = Join-Path $GeneratedDirectory 'register_functions.cpp'
$registerSource = [IO.File]::ReadAllText($registerPath)
$originalRegisterSource = $registerSource
$registerNewline = if ($registerSource.Contains("`r`n")) { "`r`n" } else { "`n" }
$registrationPattern = [regex]::new(
    '(?m)^\s*g_ps2RecompiledFunctionTable\[\d+\]\s*=\s*\w+;\s*// 0x(?<address>[0-9a-f]+)\r?\n')
$registeredAddresses = [System.Collections.Generic.HashSet[uint32]]::new()
foreach ($match in $registrationPattern.Matches($registerSource)) {
    [void]$registeredAddresses.Add([Convert]::ToUInt32($match.Groups['address'].Value, 16))
}
$pendingRegistrationAddresses = [System.Collections.Generic.HashSet[uint32]]::new()
foreach ($rowIndex in @($byRow.Keys | Sort-Object)) {
    $row = $rows[$rowIndex]
    $startSuffix = '{0:x}' -f $row.Start
    $sourcePath = Join-Path $GeneratedDirectory ($row.Name + '_0x' + $startSuffix + '.cpp')
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        $probeAddress = @($byRow[$rowIndex] | Sort-Object)[0]
        $probeComment = '// 0x{0:x}:' -f $probeAddress
        $owner = Get-ChildItem -LiteralPath $GeneratedDirectory -Filter '*.cpp' |
            Select-String -SimpleMatch $probeComment -List |
            Select-Object -First 1
        if ($null -eq $owner) {
            throw "Generated source not found for instruction $probeComment"
        }
        $sourcePath = $owner.Path
    }

    $source = [IO.File]::ReadAllText($sourcePath)
    $newline = if ($source.Contains("`r`n")) { "`r`n" } else { "`n" }
    if ($source -notmatch 'void\s+(xmen_fn_\w+)\s*\(') {
        throw "Could not identify generated function in $sourcePath"
    }
    $functionName = $matches[1]
    $caseLines = [System.Collections.Generic.List[string]]::new()

    foreach ($address in @($byRow[$rowIndex] | Sort-Object)) {
        $hex = '{0:x}' -f $address
        if ($source -notmatch ('(?i)case\s+0x0*' + $hex + 'u:')) {
            $caseLines.Add(('        case 0x{0:X8}u: goto label_{1};' -f $address, $hex))
        }
        if ($source -notmatch ('(?m)^\s*label_' + $hex + ':')) {
            $commentPattern = '(?m)^(\s*)// 0x' + $hex + ':'
            if ($source -notmatch $commentPattern) {
                throw ('Instruction 0x{0:X8} not found in {1}' -f $address, $sourcePath)
            }
            $source = [regex]::Replace(
                $source,
                $commentPattern,
                ('$1label_' + $hex + ':' + $newline + '$1// 0x' + $hex + ':'),
                1)
        }

        if (-not $registeredAddresses.Contains($address) -and
            $pendingRegistrationAddresses.Add($address)) {
            $slot = [uint32](($address - 0x00100008) / 4)
            $registrationLines.Add(('        g_ps2RecompiledFunctionTable[{0}] = {1}; // 0x{2:x}' -f $slot, $functionName, $address))
        }
    }

    if ($caseLines.Count -gt 0) {
        $switchPattern = 'switch \(ctx->pc\) \{' + [regex]::Escape($newline)
        $caseBlock = ($caseLines -join $newline) + $newline
        $source = [regex]::Replace($source, $switchPattern, ('$0' + $caseBlock), 1)
    }
    if ($source -ne [IO.File]::ReadAllText($sourcePath)) {
        [IO.File]::WriteAllText($sourcePath, $source)
    }
}

# Every generated resume case must have a table entry. Removing registrations
# merely because the same numeric value appears in static data breaks valid
# returns and indirect callbacks whose continuations collide with data words.
foreach ($row in $rows) {
    $sourcePath = Join-Path $GeneratedDirectory ($row.Name + '_0x' + ('{0:x}' -f $row.Start) + '.cpp')
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        continue
    }

    $source = [IO.File]::ReadAllText($sourcePath)
    if ($source -notmatch 'void\s+(xmen_fn_\w+)\s*\(') {
        continue
    }
    $functionName = $matches[1]

    foreach ($caseMatch in [regex]::Matches($source, '(?i)case\s+0x(?<address>[0-9a-f]+)u:\s*goto\s+label_')) {
        $address = [Convert]::ToUInt32($caseMatch.Groups['address'].Value, 16)
        if ($registeredAddresses.Contains($address) -or
            -not $pendingRegistrationAddresses.Add($address)) {
            continue
        }

        $slot = [uint32](($address - 0x00100008) / 4)
        $registrationLines.Add(('        g_ps2RecompiledFunctionTable[{0}] = {1}; // 0x{2:x}' -f $slot, $functionName, $address))
    }
}

$terminators = [regex]::Matches($registerSource, '(?m)^    }\r?\n};')
if ($terminators.Count -eq 0) {
    throw "Could not find function-table initializer terminator"
}
$insertAt = $terminators[$terminators.Count - 1].Index
if ($registrationLines.Count -gt 0) {
    $registrationBlock = $registerNewline + ($registrationLines -join $registerNewline) + $registerNewline
    $registerSource = $registerSource.Insert($insertAt, $registrationBlock)
}
if ($registerSource -ne $originalRegisterSource) {
    [IO.File]::WriteAllText($registerPath, $registerSource)
}

foreach ($sourceFile in Get-ChildItem -LiteralPath $GeneratedDirectory -Filter '*.cpp') {
    $source = [IO.File]::ReadAllText($sourceFile.FullName)
    $deduplicated = [regex]::Replace(
        $source,
        '(?m)^(\s*label_([0-9a-f]+):\r?\n)\s*label_\2:\r?\n',
        '$1')
    if ($deduplicated -ne $source) {
        [IO.File]::WriteAllText($sourceFile.FullName, $deduplicated)
    }
}

Write-Host ("Recovered {0} missing Alchemy code boundaries across {1} generated functions." -f $missing.Count, $byRow.Count)
