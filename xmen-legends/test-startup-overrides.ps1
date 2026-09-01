param()

$ErrorActionPreference = 'Stop'

$archivePath = Join-Path $PSScriptRoot '.startup-override-test.zip'
$overrideRoot = Join-Path $PSScriptRoot 'dev-overrides'
$overrideScript = Join-Path $overrideRoot 'set-startup-movie-bypass.ps1'
$entryNames = @(
    'scripts/menus/intro_normal.py',
    'scripts/menus/intro_demo.py',
    'scripts/menus/intro_e3.py',
    'scripts/missions/alison.py'
)

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-NormalizedSourceText {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [Text.RegularExpressions.Regex]::Replace(
        [IO.File]::ReadAllText($Path),
        "\r?\n",
        "`r`n"
    )
}

function Read-ArchiveEntry {
    param([Parameter(Mandatory = $true)][string]$Name)

    $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $entry = $archive.GetEntry($Name)
        if ($null -eq $entry) {
            throw "Archive entry not found: $Name"
        }

        $reader = [IO.StreamReader]::new($entry.Open())
        try {
            return $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Assert-EntryText {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Expected
    )

    $actual = Read-ArchiveEntry -Name $Name
    if ($actual -cne $Expected) {
        throw "Unexpected text for archive entry: $Name"
    }
}

try {
    if (Test-Path -LiteralPath $archivePath) {
        Remove-Item -LiteralPath $archivePath -Force
    }

    $stream = [IO.File]::Open(
        $archivePath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None
    )
    try {
        $archive = [IO.Compression.ZipArchive]::new(
            $stream,
            [IO.Compression.ZipArchiveMode]::Create,
            $false
        )
        try {
            foreach ($name in $entryNames) {
                $entry = $archive.CreateEntry($name)
                $writer = [IO.StreamWriter]::new($entry.Open())
                try {
                    $writer.Write('placeholder')
                }
                finally {
                    $writer.Dispose()
                }
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }

    & $overrideScript -Mode GameplayMissionNoMovie -ArchivePath $archivePath | Out-Null
    $newGameText = Get-NormalizedSourceText (
        Join-Path $overrideRoot 'intro_normal.gameplay-first.py'
    )
    foreach ($name in $entryNames[0..2]) {
        Assert-EntryText -Name $name -Expected $newGameText
    }
    Assert-EntryText -Name $entryNames[3] -Expected (
        Get-NormalizedSourceText (Join-Path $overrideRoot 'mission_alison.skip-movie.py')
    )

    & $overrideScript -Mode Restore -ArchivePath $archivePath | Out-Null
    $restoreSources = @(
        'intro_normal.original.py',
        'intro_demo.original.py',
        'intro_e3.original.py',
        'mission_alison.original.py'
    )
    for ($i = 0; $i -lt $entryNames.Count; ++$i) {
        Assert-EntryText -Name $entryNames[$i] -Expected (
            Get-NormalizedSourceText (Join-Path $overrideRoot $restoreSources[$i])
        )
    }

    'Startup override tests passed.'
}
finally {
    if (Test-Path -LiteralPath $archivePath) {
        Remove-Item -LiteralPath $archivePath -Force
    }
}
