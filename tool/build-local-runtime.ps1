param(
    [ValidateSet('Release', 'Debug')]
    [string]$Mode = 'Release'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$toolchainRoot = & (Join-Path $PSScriptRoot 'resolve-yixue-toolchain-root.ps1') -ProjectRoot $projectRoot
$runtimeRoot = Join-Path $projectRoot 'runtime'
$vendorRoot = Join-Path $runtimeRoot 'vendor'
$buildRoot = Join-Path $runtimeRoot 'build'
$installRoot = Join-Path $runtimeRoot 'install'
$cmake = Join-Path $toolchainRoot 'cmake\3.30.2\bin\cmake.exe'
$ninja = Join-Path $toolchainRoot 'ninja\1.12.1\ninja.exe'
$vsDevShell = $env:YIXUE_VS_DEV_SHELL
if (-not $vsDevShell) {
    $programFilesX86 = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::ProgramFilesX86
    )
    $programFiles = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::ProgramFiles
    )
    $vswhereCandidates = @(
        (Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'),
        (Join-Path $programFiles 'Microsoft Visual Studio\Installer\vswhere.exe')
    )
    $vswhere = $vswhereCandidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
    if ($vswhere) {
        $vsInstallPath = & $vswhere -latest -products '*' `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath
        if ($LASTEXITCODE -eq 0 -and $vsInstallPath) {
            $vsDevShell = Join-Path $vsInstallPath 'Common7\Tools\Launch-VsDevShell.ps1'
        }
    }
}

$dependencies = @(
    @{
        Name = 'CTranslate2'
        Url = 'https://github.com/OpenNMT/CTranslate2.git'
        Tag = 'v4.8.2'
        Commit = 'd44d2d069eb88c7b7804da864c10c201501cb4a9'
    },
    @{
        Name = 'sentencepiece'
        Url = 'https://github.com/google/sentencepiece.git'
        Tag = 'v0.2.2'
        Commit = 'e0cce7d37b065b5140349dbe12c6bcf6192fdd78'
    }
)

if (-not $vsDevShell -or -not (Test-Path -LiteralPath $vsDevShell -PathType Leaf)) {
    throw 'Visual Studio C++ Build Tools were not found. Install the C++ desktop workload or set YIXUE_VS_DEV_SHELL to Launch-VsDevShell.ps1.'
}

foreach ($path in @($cmake, $ninja)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required build tool is missing: $path"
    }
}

New-Item -ItemType Directory -Path $vendorRoot, $buildRoot, $installRoot -Force | Out-Null

foreach ($dependency in $dependencies) {
    $destination = Join-Path $vendorRoot $dependency.Name
    if (-not (Test-Path -LiteralPath (Join-Path $destination '.git') -PathType Container)) {
        & git clone --recursive --depth 1 --branch $dependency.Tag $dependency.Url $destination
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    $actualCommit = (& git -C $destination rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $dependency.Commit) {
        throw "$($dependency.Name) source is not the pinned commit"
    }
}

$ctranslate2Patch = Join-Path $runtimeRoot 'patches\ctranslate2-4.8.2-windows-ruy-shutdown.patch'
$ctranslate2Source = Join-Path $vendorRoot 'CTranslate2'
& git -C $ctranslate2Source apply --reverse --check $ctranslate2Patch 2>$null
if ($LASTEXITCODE -ne 0) {
    & git -C $ctranslate2Source apply --check $ctranslate2Patch
    if ($LASTEXITCODE -ne 0) {
        throw 'Pinned CTranslate2 source does not accept the Windows Ruy shutdown patch'
    }
    & git -C $ctranslate2Source apply $ctranslate2Patch
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to apply the Windows Ruy shutdown patch'
    }
}

$env:VSLANG = '1033'
& $vsDevShell -Arch amd64 -HostArch amd64
Set-Location -LiteralPath $projectRoot

$sentencePieceSource = Join-Path $vendorRoot 'sentencepiece'
$sentencePieceBuild = Join-Path $buildRoot 'sentencepiece'
$sentencePieceInstall = Join-Path $installRoot 'sentencepiece'
& $cmake -S $sentencePieceSource -B $sentencePieceBuild -G Ninja `
    "-DCMAKE_MAKE_PROGRAM=$ninja" `
    "-DCMAKE_BUILD_TYPE=$Mode" `
    "-DCMAKE_INSTALL_PREFIX=$sentencePieceInstall" `
    '-DSPM_ENABLE_SHARED=OFF' `
    '-DSPM_ENABLE_TCMALLOC=OFF' `
    '-DSPM_BUILD_TEST=OFF' `
    '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $cmake --build $sentencePieceBuild --config $Mode --target install --parallel 2
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$ctranslate2Build = Join-Path $buildRoot 'ctranslate2'
$ctranslate2Install = Join-Path $installRoot 'ctranslate2'
& $cmake -S $ctranslate2Source -B $ctranslate2Build -G Ninja `
    "-DCMAKE_MAKE_PROGRAM=$ninja" `
    "-DCMAKE_BUILD_TYPE=$Mode" `
    "-DCMAKE_INSTALL_PREFIX=$ctranslate2Install" `
    '-DBUILD_SHARED_LIBS=ON' `
    '-DBUILD_CLI=OFF' `
    '-DBUILD_TESTS=OFF' `
    '-DWITH_MKL=OFF' `
    '-DWITH_DNNL=OFF' `
    '-DWITH_OPENBLAS=OFF' `
    '-DWITH_RUY=ON' `
    '-DWITH_CUDA=OFF' `
    '-DOPENMP_RUNTIME=NONE' `
    '-DENABLE_CPU_DISPATCH=ON'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $cmake --build $ctranslate2Build --config $Mode --target install --parallel 2
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$availableDrive = @('Y', 'X', 'W', 'V') |
    Where-Object { -not (Test-Path -LiteralPath "${_}:\") } |
    Select-Object -First 1
if (-not $availableDrive) {
    throw 'No temporary ASCII drive letter is available for the Windows native build'
}

$mappedRoot = "${availableDrive}:"
& subst.exe $mappedRoot $projectRoot
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to create the temporary native-build drive mapping'
}

try {
    $mappedRuntimeRoot = Join-Path $mappedRoot 'runtime'
    $wrapperSource = Join-Path $mappedRuntimeRoot 'yixue-ct2-runtime'
    $wrapperBuild = Join-Path $mappedRuntimeRoot 'build\yixue-ct2-runtime'
    $wrapperInstall = Join-Path $mappedRuntimeRoot 'install\yixue-ct2-runtime'
    $mappedCTranslate2 = Join-Path $mappedRuntimeRoot 'install\ctranslate2'
    $mappedSentencePieceSource = Join-Path $mappedRuntimeRoot 'vendor\sentencepiece'
    & $cmake -S $wrapperSource -B $wrapperBuild -G Ninja `
        "-DCMAKE_MAKE_PROGRAM=$ninja" `
        "-DCMAKE_BUILD_TYPE=$Mode" `
        "-DCMAKE_INSTALL_PREFIX=$wrapperInstall" `
        "-DCTranslate2_DIR=$(Join-Path $mappedCTranslate2 'lib\cmake\ctranslate2')" `
        "-DSENTENCEPIECE_SOURCE=$mappedSentencePieceSource" `
        '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL'
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to configure the Yixue runtime wrapper'
    }
    & $cmake --build $wrapperBuild --config $Mode --target install --parallel 2
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to build the Yixue runtime wrapper'
    }
} finally {
    & subst.exe $mappedRoot /d
}

$wrapperInstall = Join-Path $installRoot 'yixue-ct2-runtime'

Write-Output "CTRANSLATE2_ROOT=$ctranslate2Install"
Write-Output "SENTENCEPIECE_ROOT=$sentencePieceInstall"
Write-Output "YIXUE_CT2_RUNTIME_ROOT=$wrapperInstall"
