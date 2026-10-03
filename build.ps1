$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = $PSScriptRoot
$info = Get-Content (Join-Path $root "info.json") -Raw | ConvertFrom-Json
$folder = "$($info.name)_$($info.version)"
$distDir = Join-Path $root "dist"
$zipPath = Join-Path $distDir "$folder.zip"

$files = @("info.json", "changelog.txt", "thumbnail.png", "settings.lua", "data.lua", "control.lua", "LICENSE")
$dirs = @("scripts", "graphics", "locale")
$forbidden = @(".exe", ".bat", ".ps1", ".sh", ".py")

$entries = @()
foreach ($f in $files) {
    $p = Join-Path $root $f
    if (Test-Path $p) { $entries += Get-Item $p }
    elseif ($f -eq "thumbnail.png") { Write-Warning "thumbnail.png is missing" }
    elseif ($f -ne "LICENSE") { throw "Required file missing: $f" }
}
foreach ($d in $dirs) {
    $p = Join-Path $root $d
    if (-not (Test-Path $p)) { throw "Required folder missing: $d" }
    $entries += Get-ChildItem $p -Recurse -File
}

$bad = $entries | Where-Object { $forbidden -contains $_.Extension.ToLower() }
if ($bad) { throw "Forbidden executable files: $($bad.FullName -join ', ')" }

New-Item -ItemType Directory -Force $distDir | Out-Null
if (Test-Path $zipPath) { Remove-Item $zipPath }

$zip = [System.IO.Compression.ZipFile]::Open($zipPath, "Create")
try {
    foreach ($e in $entries) {
        $rel = $e.FullName.Substring($root.Length).TrimStart("\", "/").Replace("\", "/")
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $e.FullName, "$folder/$rel", "Optimal") | Out-Null
    }
}
finally {
    $zip.Dispose()
}

Write-Host "Built $zipPath ($($entries.Count) files)"
