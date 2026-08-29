param(
    [ValidateSet("Bypass", "MovieOnly", "MovieWait", "TitleGameplayFirst", "GameplayDemo", "GameplayMap", "GameplayMapNoMovie", "GameplayFirst", "Restore")]
    [string]$Mode = "Bypass"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$zipPath = Join-Path $root "disc\Z\ASSETSFB.ZIP"
$sourceName = switch ($Mode) {
    "Bypass" { "intro_normal.skip-movies.py" }
    "MovieOnly" { "intro_normal.movie-only.py" }
    "MovieWait" { "intro_normal.movie-wait.py" }
    "TitleGameplayFirst" { "intro_normal.skip-movies.py" }
    "GameplayDemo" { "intro_normal.gameplay-demo.py" }
    "GameplayMap" { "intro_normal.gameplay-map.py" }
    "GameplayMapNoMovie" { "intro_normal.gameplay-map.py" }
    "GameplayFirst" { "intro_normal.gameplay-first.py" }
    "Restore" { "intro_normal.original.py" }
}
$missionSourceName = if ($Mode -in @("TitleGameplayFirst", "GameplayMapNoMovie", "GameplayFirst")) {
    "mission_alison.skip-movie.py"
} else {
    "mission_alison.original.py"
}
$startupReplacements = @(
    @{
        EntryName = "scripts/menus/intro_normal.py"
        RestoreSource = "intro_normal.original.py"
    },
    @{
        EntryName = "scripts/menus/intro_demo.py"
        RestoreSource = "intro_demo.original.py"
    },
    @{
        EntryName = "scripts/menus/intro_e3.py"
        RestoreSource = "intro_e3.original.py"
    }
) | ForEach-Object {
    @{
        EntryName = $_.EntryName
        SourcePath = Join-Path $PSScriptRoot $(
            if ($Mode -eq "Restore") { $_.RestoreSource } else { $sourceName }
        )
    }
}
$replacements = @(
    $startupReplacements
    @{
        EntryName = "scripts/missions/alison.py"
        SourcePath = Join-Path $PSScriptRoot $missionSourceName
    }
)

Add-Type -AssemblyName System.IO.Compression.FileSystem

$zipItem = Get-Item -LiteralPath $zipPath
$wasReadOnly = $zipItem.IsReadOnly
if ($wasReadOnly) {
    $zipItem.IsReadOnly = $false
}

try {
    $stream = $null
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            $stream = [System.IO.File]::Open(
                $zipPath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None)
            break
        } catch [System.IO.IOException] {
            if ($attempt -eq 20) {
                throw
            }
            Start-Sleep -Milliseconds 250
        }
    }
    try {
        $archive = [System.IO.Compression.ZipArchive]::new(
            $stream,
            [System.IO.Compression.ZipArchiveMode]::Update,
            $false)
        try {
            foreach ($item in $replacements) {
                $existing = $archive.GetEntry($item.EntryName)
                if ($null -eq $existing) {
                    throw "Archive entry not found: $($item.EntryName)"
                }
                $existing.Delete()

                $replacement = $archive.CreateEntry(
                    $item.EntryName,
                    [System.IO.Compression.CompressionLevel]::Optimal)
                $text = [System.IO.File]::ReadAllText($item.SourcePath)
                $text = [System.Text.RegularExpressions.Regex]::Replace(
                    $text,
                    "\r?\n",
                    "`r`n")
                $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($text)
                $output = $replacement.Open()
                try {
                    $output.Write($bytes, 0, $bytes.Length)
                } finally {
                    $output.Dispose()
                }
            }
        } finally {
            $archive.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
} finally {
    if ($wasReadOnly) {
        (Get-Item -LiteralPath $zipPath).IsReadOnly = $true
    }
}

Write-Output "Startup movie script mode: $Mode"
