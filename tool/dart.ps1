param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$DartArgs
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$toolchainRoot = & (Join-Path $PSScriptRoot 'resolve-yixue-toolchain-root.ps1') -ProjectRoot $projectRoot
$localFlutterRoot = Join-Path $toolchainRoot 'flutter'
$flutterRoot = if ($env:YIXUE_FLUTTER_SDK) {
    $env:YIXUE_FLUTTER_SDK
} elseif (Test-Path -LiteralPath (Join-Path $localFlutterRoot 'bin\dart.bat') -PathType Leaf) {
    $localFlutterRoot
} else {
    $dartCommand = Get-Command 'dart.bat' -ErrorAction SilentlyContinue
    if ($dartCommand) {
        Split-Path -Parent (Split-Path -Parent $dartCommand.Source)
    } else {
        throw 'Dart SDK was not found in the project toolchain or PATH. Set YIXUE_FLUTTER_SDK to its Flutter SDK directory.'
    }
}

$dart = Join-Path $flutterRoot 'bin\dart.bat'
if (-not (Test-Path -LiteralPath $dart -PathType Leaf)) {
    throw "Dart SDK is missing: $dart"
}

& $dart @DartArgs
exit $LASTEXITCODE
