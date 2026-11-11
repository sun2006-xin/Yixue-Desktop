param(
    [ValidateSet('Debug', 'Release')]
    [string]$Mode = 'Debug',
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'build-windows.ps1') -Mode $Mode
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

$pubspec = Join-Path $projectRoot 'app\yixue_app\pubspec.yaml'
$versionMatch = Select-String -LiteralPath $pubspec -Pattern '^version:\s*(.+)$'
if (-not $versionMatch) {
    throw 'Version is missing from pubspec.yaml'
}

$versionText = $versionMatch.Matches[0].Groups[1].Value.Trim()
$version = $versionText.Replace('+', '-')
$commit = (& git -C $projectRoot rev-parse --short=8 HEAD).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Git commit could not be resolved'
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$source = Join-Path $projectRoot "app\yixue_app\build\windows\x64\runner\$Mode"
$executable = Join-Path $source 'yixue_app.exe'
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    throw "Built application is missing: $executable"
}
$buildMetadataPath = Join-Path $source 'build-source.json'
if (-not (Test-Path -LiteralPath $buildMetadataPath -PathType Leaf)) {
    throw 'Built application metadata is missing; run the guarded Windows build before packaging.'
}
try {
    $buildMetadata = Get-Content -LiteralPath $buildMetadataPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
} catch {
    throw "Built application metadata is invalid: $buildMetadataPath"
}
if ($buildMetadata.schemaVersion -ne 1 -or
    $buildMetadata.gitCommit -ne $commit -or
    $buildMetadata.version -ne $versionText -or
    $buildMetadata.mode -ne $Mode -or
    $buildMetadata.dirty -eq $true) {
    throw "Built application is stale or dirty; expected commit $commit, version $version, mode $Mode. Run the guarded Windows build again."
}

$previewRoot = Join-Path $projectRoot 'releases\preview'
$target = Join-Path $previewRoot "v$version-preview.$stamp-$commit"
New-Item -ItemType Directory -Path $target | Out-Null
Copy-Item -Path (Join-Path $source '*') -Destination $target -Recurse

# User state must never be inherited from a developer run or shipped in a preview.
$packagedUserData = Join-Path $target 'user-data'
if (Test-Path -LiteralPath $packagedUserData) {
    Remove-Item -LiteralPath $packagedUserData -Recurse -Force
}
$legacyRuntimeData = Join-Path $target 'data'
foreach ($privateName in @('.yixue-launched', 'yixue.db', 'yixue.db-shm', 'yixue.db-wal')) {
    $privatePath = Join-Path $legacyRuntimeData $privateName
    if (Test-Path -LiteralPath $privatePath -PathType Leaf) {
        Remove-Item -LiteralPath $privatePath -Force
    }
}

$manifest = [ordered]@{
    product = '译学'
    version = $version
    channel = 'preview'
    mode = $Mode
    gitCommit = $commit
    builtAt = (Get-Date).ToString('o')
    executable = 'yixue_app.exe'
}
$manifest |
    ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $target 'preview-manifest.json') -Encoding utf8

Write-Output "PREVIEW_DIR=$target"
Write-Output "PREVIEW_EXE=$(Join-Path $target 'yixue_app.exe')"
