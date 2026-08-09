# Builds dist/ClaudeUsage.icuewidget from the widget/ folder and stages the
# helper's copy of the dashboard page. Run from the repo root:
#   powershell -ExecutionPolicy Bypass -File build.ps1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repo = $PSScriptRoot
$dist = Join-Path $repo 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$out = Join-Path $dist 'ClaudeUsage.icuewidget'
if (Test-Path $out) { Remove-Item $out }

# iCUE expects index.html as the FIRST zip entry, so add files in explicit order.
$zip = [System.IO.Compression.ZipFile]::Open($out, 'Create')
try {
    foreach ($pair in @(
        @('widget\index.html',        'index.html'),
        @('widget\manifest.json',     'manifest.json'),
        @('widget\resources\icon.png','resources/icon.png')
    )) {
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, (Join-Path $repo $pair[0]), $pair[1]) | Out-Null
    }
} finally { $zip.Dispose() }

# The helper serves the same page at http://127.0.0.1:8787/
Copy-Item (Join-Path $repo 'widget\index.html') (Join-Path $repo 'helper\index.html') -Force

Write-Host "Built $out"
Write-Host "Staged helper\index.html"
