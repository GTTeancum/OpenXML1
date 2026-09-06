param([string]$ReplayPath = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$disc = (Resolve-Path (Join-Path $PSScriptRoot 'disc')).Path
if (!$ReplayPath) { $ReplayPath = Join-Path $disc 'vu-gameplay-current.bin' }
$source = (Resolve-Path -LiteralPath $ReplayPath).Path
$shortPath = Join-Path $disc 'vu-short-current.bin'
$recipePath = Join-Path $disc 'vu-native-pairs-short.inc'
if ($source -eq $shortPath) { throw 'The source recording must not be the generated short recording.' }
if ((Get-Item -LiteralPath $source).Length -gt 4MB) { throw 'Recording exceeds 4 MiB.' }
$inputStream = [IO.BinaryReader]::new([IO.File]::OpenRead($source))
$buffer = [IO.MemoryStream]::new()
$output = [IO.BinaryWriter]::new($buffer)
$records = 0
$selected = 0
try {
    while ($inputStream.BaseStream.Position -lt $inputStream.BaseStream.Length) {
        if (++$records -gt 64) { throw 'Recording exceeds 64 cases.' }
        $magic = $inputStream.ReadUInt32()
        $size = $inputStream.ReadUInt32()
        if ($magic -ne 0x31525556 -or $size -lt 4 -or $size -gt 4MB) { throw 'Invalid VUR1 record header.' }
        $body = $inputStream.ReadBytes([int]$size)
        if ($body.Length -ne $size) { throw 'Truncated VUR1 record.' }
        $budget = [BitConverter]::ToUInt32($body, 0)
        if (!$budget -or $budget -gt 1048576) { throw 'Invalid VU cycle budget.' }
        if ($budget -le 64) {
            $output.Write($magic)
            $output.Write($size)
            $output.Write($body)
            ++$selected
        }
    }
    if (!$selected) { throw 'Recording contains no short slices.' }
    $output.Flush()
    [IO.File]::WriteAllBytes($shortPath, $buffer.ToArray())
} finally {
    $output.Dispose()
    $buffer.Dispose()
    $inputStream.Dispose()
}

$build = Join-Path $root 'PS2Recomp/out/xmen-final3-build'
$exe = (Resolve-Path (Join-Path $build 'ps2xTest/Release/ps2x_tests.exe')).Path
$start = [Diagnostics.ProcessStartInfo]::new($exe)
$start.WorkingDirectory = Join-Path $root 'PS2Recomp'
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
foreach ($name in @($start.Environment.Keys)) {
    if ($name.StartsWith('PS2X_', [StringComparison]::OrdinalIgnoreCase)) { [void]$start.Environment.Remove($name) }
}
$start.Environment['MINITEST_FILTER'] = 'recorded VU slices reproduce'
$start.Environment['PS2X_VU_REPLAY_FILE'] = $shortPath
$start.Environment['PS2X_VU_REPLAY_REPEATS'] = '1'
$start.Environment['PS2X_VU_REPLAY_PAIR_EXPORT'] = $recipePath
$process = [Diagnostics.Process]::new()
$process.StartInfo = $start
$started = $false
try {
    $started = $process.Start()
    if (!$started) { throw 'Short-slice replay did not start.' }
    $process.PriorityClass = 'Normal'
    $process.ProcessorAffinity = [IntPtr]0xF
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (!$process.WaitForExit(120000)) { throw 'Short-slice export exceeded two minutes.' }
    $text = $stdout.GetAwaiter().GetResult()
    $errors = $stderr.GetAwaiter().GetResult()
    "$text`n$errors" | Set-Content -LiteralPath (Join-Path $build 'vu-short-export.log')
    if ($process.ExitCode -ne 0 -or $text -notmatch "\[vu-replay:result\] cases=$selected iterations=$selected cycles=\d+ execute-ms=[\d.]+ digest=([0-9a-f]+) error=\r?\n") {
        throw 'Short-slice validation/export failed; do not use the generated recipe.'
    }
    $digest = $Matches[1]
    if ((Get-Item -LiteralPath $recipePath).Length -gt 256KB) { throw 'Recipe exceeds the native compiler limit.' }
    [pscustomobject]@{
        PrivateArtifacts = $true; Records = $records; ShortRecords = $selected; Digest = $digest
        SourceSha256 = (Get-FileHash -LiteralPath $source).Hash
        ShortSha256 = (Get-FileHash -LiteralPath $shortPath).Hash
        RecipeSha256 = (Get-FileHash -LiteralPath $recipePath).Hash
        TestSha256 = (Get-FileHash -LiteralPath $exe).Hash
        Recipe = $recipePath
    } | ConvertTo-Json
} finally {
    if ($started -and !$process.HasExited) { $process.Kill(); $process.WaitForExit() }
    $process.Dispose()
}
