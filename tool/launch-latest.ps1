param(
    [string]$PreviewRoot,
    [switch]$PrintPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($PreviewRoot)) {
    $PreviewRoot = Join-Path $projectRoot 'releases\preview'
}

if (-not (Test-Path -LiteralPath $PreviewRoot -PathType Container)) {
    throw "Preview directory is missing: $PreviewRoot"
}

$release = Get-ChildItem -LiteralPath $PreviewRoot -Directory |
    Where-Object { $_.Name -like 'v*-preview.*' } |
    Sort-Object LastWriteTimeUtc -Descending |
    Where-Object {
        (Test-Path -LiteralPath (Join-Path $_.FullName 'preview-manifest.json') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $_.FullName 'yixue_app.exe') -PathType Leaf)
    } |
    Select-Object -First 1

if (-not $release) {
    throw "No complete preview release was found in: $PreviewRoot"
}

$executable = Join-Path $release.FullName 'yixue_app.exe'
if ($PrintPath) {
    Write-Output $executable
    exit 0
}

Start-Process -FilePath $executable -WorkingDirectory $release.FullName
