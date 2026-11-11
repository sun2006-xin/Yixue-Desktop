param(
    [ValidateSet('Debug', 'Release')]
    [string]$Mode = 'Debug',
    [switch]$KeepArtifactsOnFailure
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$runnerDirectory = Join-Path $projectRoot "app\yixue_app\build\windows\x64\runner\$Mode"
$mediaKitDirectory = if ($env:YIXUE_MEDIAKIT_NATIVE_DIR) {
    [System.IO.Path]::GetFullPath($env:YIXUE_MEDIAKIT_NATIVE_DIR)
} else {
    $runnerDirectory
}
foreach ($requiredFile in @('libmpv-2.dll', 'media_kit_video_plugin.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $mediaKitDirectory $requiredFile) -PathType Leaf)) {
        throw "The Windows MediaKit runtime is missing: $(Join-Path $mediaKitDirectory $requiredFile)"
    }
}

$programFilesX86 = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
$programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
$vswhereCandidates = @(
    (Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'),
    (Join-Path $programFiles 'Microsoft Visual Studio\Installer\vswhere.exe')
)
$vswhere = $vswhereCandidates |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
if (-not $vswhere) {
    throw 'Visual Studio vswhere.exe was not found; the fixture generator requires the C++ desktop workload.'
}
$vsInstallPath = & $vswhere -latest -products '*' `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $vsInstallPath) {
    throw 'Visual Studio C++ Build Tools were not found.'
}
$vsDevShell = Join-Path $vsInstallPath 'Common7\Tools\Launch-VsDevShell.ps1'
if (-not (Test-Path -LiteralPath $vsDevShell -PathType Leaf)) {
    throw "Visual Studio developer shell was not found: $vsDevShell"
}

$systemTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$qaDirectory = Join-Path $systemTempRoot "yixue-media-smoke-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $qaDirectory | Out-Null
$originalPath = $env:PATH
$originalMediaKitDirectory = $env:YIXUE_MEDIAKIT_NATIVE_DIR
$originalMp4Fixture = $env:YIXUE_TEST_MP4_FILE
$originalIntegrationTestMode = $env:YIXUE_WINDOWS_INTEGRATION_TEST
$testSucceeded = $false
try {
    & $vsDevShell -Arch amd64 -HostArch amd64
    if ($LASTEXITCODE -ne 0) {
        throw "Visual Studio developer shell failed with exit code $LASTEXITCODE"
    }

    $generator = Join-Path $qaDirectory 'windows_mp4_fixture_generator.exe'
    $source = Join-Path $PSScriptRoot 'tests\windows_mp4_fixture_generator.cpp'
    & cl.exe /nologo /EHsc /std:c++17 /MD "/Fo$qaDirectory\" "/Fd$qaDirectory\compiler.pdb" $source "/Fe$generator" /link mfplat.lib mfreadwrite.lib mfuuid.lib ole32.lib
    if ($LASTEXITCODE -ne 0) {
        throw "The synthetic MP4 fixture generator failed to compile with exit code $LASTEXITCODE"
    }

    $fixture = Join-Path $qaDirectory 'synthetic-screen-recording.mp4'
    & $generator $fixture
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $fixture -PathType Leaf)) {
        throw 'Windows Media Foundation could not create the synthetic H.264 MP4 fixture.'
    }
    $fixtureMarker = Join-Path $qaDirectory '.yixue-media-smoke-fixture'
    [System.IO.File]::WriteAllText(
        $fixtureMarker,
        'YIXUE_SYNTHETIC_MEDIA_FIXTURE_V1',
        [System.Text.UTF8Encoding]::new($false)
    )
    $fixtureLength = (Get-Item -LiteralPath $fixture).Length
    if ($fixtureLength -le 4096) {
        throw "The generated synthetic MP4 is unexpectedly small ($fixtureLength bytes)."
    }
    Write-Host "Generated synthetic MP4 ($fixtureLength bytes): $fixture"

    $env:YIXUE_MEDIAKIT_NATIVE_DIR = $mediaKitDirectory
    $env:YIXUE_TEST_MP4_FILE = $fixture
    $env:PATH = "$mediaKitDirectory;$env:PATH"
    & (Join-Path $PSScriptRoot 'flutter.ps1') test --no-pub --reporter compact `
        'test\recording_media_player_native_smoke_test.dart'
    if ($LASTEXITCODE -ne 0) {
        throw "The native MediaKit MP4 smoke test failed with exit code $LASTEXITCODE"
    }

    $env:YIXUE_WINDOWS_INTEGRATION_TEST = '1'
    $integrationOutput = & (Join-Path $PSScriptRoot 'flutter.ps1') test `
        --no-pub --reporter expanded `
        --device-id windows `
        'integration_test\recording_media_player_texture_test.dart' 2>&1
    $integrationExitCode = $LASTEXITCODE
    $integrationLog = $integrationOutput | ForEach-Object { $_.ToString() }
    $integrationLog | ForEach-Object { Write-Host $_ }
    [System.IO.File]::WriteAllLines(
        (Join-Path $qaDirectory 'windows-texture-integration-test.log'),
        [string[]]$integrationLog,
        [System.Text.UTF8Encoding]::new($false)
    )
    $integrationText = $integrationLog -join "`n"
    if ($integrationExitCode -ne 0) {
        throw "The Windows Flutter video texture integration test failed with exit code $integrationExitCode"
    }
    if ($integrationText -notmatch 'production recording dialog renders a synthetic MP4 texture and disposes it' -or
        $integrationText -notmatch 'All tests passed!') {
        throw 'The Windows texture test exited without reporting the expected test case and a passing result.'
    }
    $testSucceeded = $true
} finally {
    $env:PATH = $originalPath
    $env:YIXUE_MEDIAKIT_NATIVE_DIR = $originalMediaKitDirectory
    $env:YIXUE_TEST_MP4_FILE = $originalMp4Fixture
    $env:YIXUE_WINDOWS_INTEGRATION_TEST = $originalIntegrationTestMode

    $resolvedQaDirectory = [System.IO.Path]::GetFullPath($qaDirectory)
    if ([System.IO.Path]::GetDirectoryName($resolvedQaDirectory) -ne $systemTempRoot.TrimEnd('\')) {
        throw "Refusing to remove a temporary test path outside $systemTempRoot"
    }
    if ($KeepArtifactsOnFailure -and -not $testSucceeded) {
        Write-Warning "Preserving failed-test fixture and compiler outputs for diagnosis: $resolvedQaDirectory"
    } elseif (Test-Path -LiteralPath $resolvedQaDirectory -PathType Container) {
        $qaItem = Get-Item -LiteralPath $resolvedQaDirectory -Force
        if ($qaItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Refusing to remove a reparse point used as a temporary test path: $resolvedQaDirectory"
        }
        Remove-Item -LiteralPath $resolvedQaDirectory -Recurse -Force
    }
}
