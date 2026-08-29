param(
    [string]$OutputDirectory = "output_mapped_final3"
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$outputPath = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot $OutputDirectory)
).TrimEnd('\')
$expectedParent = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
if (-not $outputPath.StartsWith(
        "$expectedParent\",
        [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Generated output must remain under $expectedParent"
}

$requiredFiles = @(
    (Join-Path $outputPath "xmen_fn_00274970_0x274970.cpp"),
    (Join-Path $outputPath "register_functions.cpp")
)
foreach ($requiredFile in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Generated file not found: $requiredFile"
    }
}

$patchPath = Join-Path $PSScriptRoot "dev-overrides\generated-first-level-probe.patch"
& git -C $root apply --reverse --check -- $patchPath 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Output "Generated first-level probe is already applied."
    exit 0
}

& git -C $root apply --check -- $patchPath
if ($LASTEXITCODE -ne 0) {
    throw "Generated output no longer matches the first-level probe patch."
}

& git -C $root apply -- $patchPath
if ($LASTEXITCODE -ne 0) {
    throw "Unable to apply the generated first-level probe patch."
}

Write-Output "Applied generated first-level probe to $outputPath"
