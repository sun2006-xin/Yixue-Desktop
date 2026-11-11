param(
    [ValidateSet('Debug', 'Release')]
    [string]$Mode = 'Debug'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$toolchainRoot = & (Join-Path $PSScriptRoot 'resolve-yixue-toolchain-root.ps1') -ProjectRoot $projectRoot
$cargoHome = if ($env:YIXUE_CARGO_HOME) {
    [System.IO.Path]::GetFullPath($env:YIXUE_CARGO_HOME)
} else {
    Join-Path $toolchainRoot 'cargo'
}
$rustupHome = if ($env:YIXUE_RUSTUP_HOME) {
    [System.IO.Path]::GetFullPath($env:YIXUE_RUSTUP_HOME)
} else {
    Join-Path $toolchainRoot 'rustup'
}
$cargo = if ($env:YIXUE_CARGO_EXE) {
    [System.IO.Path]::GetFullPath($env:YIXUE_CARGO_EXE)
} elseif (Test-Path -LiteralPath (Join-Path $cargoHome 'bin\cargo.exe') -PathType Leaf) {
    Join-Path $cargoHome 'bin\cargo.exe'
} else {
    $cargoCommand = Get-Command 'cargo.exe' -ErrorAction SilentlyContinue
    if ($cargoCommand) { $cargoCommand.Source } else { $null }
}
$releaseAssetRoot = if ($env:YIXUE_RELEASE_ASSET_ROOT) {
    [System.IO.Path]::GetFullPath($env:YIXUE_RELEASE_ASSET_ROOT)
} else {
    $projectRoot
}
$pubspec = Join-Path $projectRoot 'app\yixue_app\pubspec.yaml'
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
if (-not $vsDevShell -or -not (Test-Path -LiteralPath $vsDevShell -PathType Leaf)) {
    throw 'Visual Studio C++ Build Tools were not found. Install the C++ desktop workload or set YIXUE_VS_DEV_SHELL to Launch-VsDevShell.ps1.'
}
$vsDevShell = (Resolve-Path -LiteralPath $vsDevShell).Path
if (-not $cargo -or -not (Test-Path -LiteralPath $cargo -PathType Leaf)) {
    throw 'Cargo was not found. Set YIXUE_CARGO_EXE and YIXUE_CARGO_HOME to the installed Rust toolchain.'
}
if (-not (Test-Path -LiteralPath $releaseAssetRoot -PathType Container)) {
    throw "Release asset root was not found: $releaseAssetRoot"
}

$env:CARGO_HOME = $cargoHome
$env:RUSTUP_HOME = $rustupHome

# A Windows build starts Rust first and Flutter second. Guard the whole
# operation before either compiler is launched so low virtual memory cannot
# reproduce the Dart heap/thread failure seen during development.
$minimumPhysicalFreeKb = 2 * 1024 * 1024
$minimumVirtualFreeKb = 3 * 1024 * 1024
$operatingSystem = Get-CimInstance Win32_OperatingSystem
if ($operatingSystem.FreePhysicalMemory -lt $minimumPhysicalFreeKb -or
    $operatingSystem.FreeVirtualMemory -lt $minimumVirtualFreeKb) {
    $physicalFreeGb = '{0:N2}' -f ($operatingSystem.FreePhysicalMemory / 1MB)
    $virtualFreeGb = '{0:N2}' -f ($operatingSystem.FreeVirtualMemory / 1MB)
    throw "Windows build refused for safety: free memory is $physicalFreeGb GB physical / $virtualFreeGb GB virtual; at least 2.00 GB physical and 3.00 GB virtual are required. Close other applications and retry."
}

$compilerProcessNames = @('cargo', 'rustc', 'dart', 'dartaotruntime', 'flutter', 'flutter_tester', 'msbuild')
$activeCompilerProcesses = @(Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $compilerProcessNames -contains $_.ProcessName.ToLowerInvariant() })
if ($activeCompilerProcesses.Count -gt 0) {
    $processList = $activeCompilerProcesses |
        ForEach-Object { '{0} (PID {1})' -f $_.ProcessName, $_.Id } |
        Sort-Object
    throw "Windows build refused: another compiler operation is already running: $($processList -join ', ')"
}

& $vsDevShell -Arch amd64 -HostArch amd64
Set-Location $projectRoot

$cargoArgs = @('build', '-p', 'yixue-ffi')
$flutterArgs = @('build', 'windows')
$cargoProfile = 'debug'
if ($Mode -eq 'Release') {
    $cargoArgs += '--release'
    $flutterArgs += '--release'
    $cargoProfile = 'release'
} else {
    $flutterArgs += '--debug'
}

$versionMatch = Select-String -LiteralPath $pubspec -Pattern '^version:\s*(.+)$'
if (-not $versionMatch) {
    throw 'Version is missing from pubspec.yaml'
}
$appVersion = $versionMatch.Matches[0].Groups[1].Value.Trim()
$gitCommit = (& git -C $projectRoot rev-parse --short=8 HEAD).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Git commit could not be resolved'
}
$isDirty = [bool](& git -C $projectRoot status --porcelain)
$dirtySuffix = if ($isDirty) { '-dirty' } else { '' }
$flutterArgs += "--dart-define=YIXUE_BUILD_LABEL=$appVersion@$gitCommit$dirtySuffix"

& $cargo @cargoArgs
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& (Join-Path $PSScriptRoot 'flutter.ps1') @flutterArgs
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$sourceDll = Join-Path $projectRoot "target\$cargoProfile\yixue_ffi.dll"
$runnerDirectory = Join-Path $projectRoot "app\yixue_app\build\windows\x64\runner\$Mode"
$destinationDll = Join-Path $runnerDirectory 'yixue_ffi.dll'
Copy-Item -LiteralPath $sourceDll -Destination $destinationDll -Force

$runtimeSource = Join-Path $releaseAssetRoot 'runtime\install\yixue-ct2-runtime\bin'
$runtimeDestination = Join-Path $runnerDirectory 'runtime'
$runtimeFiles = @('yixue_ct2_worker.exe', 'yixue_ct2_runtime.dll', 'ctranslate2.dll')
New-Item -ItemType Directory -Path $runtimeDestination -Force | Out-Null
foreach ($runtimeFile in $runtimeFiles) {
    $runtimeSourceFile = Join-Path $runtimeSource $runtimeFile
    if (-not (Test-Path -LiteralPath $runtimeSourceFile -PathType Leaf)) {
        throw "Local translation runtime is missing: $runtimeSourceFile"
    }
    Copy-Item -LiteralPath $runtimeSourceFile -Destination $runtimeDestination -Force
}

$modelDestinationRoot = Join-Path $runnerDirectory 'models'
New-Item -ItemType Directory -Path $modelDestinationRoot -Force | Out-Null
foreach ($modelName in @('yixue.opus-en-zh.int8', 'yixue.opus-zh-en.int8')) {
    $modelSource = Join-Path $releaseAssetRoot "models\packages\$modelName"
    if (-not (Test-Path -LiteralPath (Join-Path $modelSource 'yixue-model.json') -PathType Leaf)) {
        throw "Bundled translation model is missing: $modelSource"
    }
    Copy-Item -LiteralPath $modelSource -Destination $modelDestinationRoot -Recurse -Force
}

$licenseDestination = Join-Path $runnerDirectory 'licenses'
New-Item -ItemType Directory -Path $licenseDestination -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'LICENSE') -Destination (Join-Path $licenseDestination 'Yixue-Apache-2.0.txt') -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'NOTICE') -Destination (Join-Path $licenseDestination 'Yixue-NOTICE.txt') -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'THIRD_PARTY_NOTICES.md') -Destination (Join-Path $licenseDestination 'THIRD_PARTY_NOTICES.md') -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'assets\licenses\CTranslate2-LICENSE.txt') -Destination (Join-Path $licenseDestination 'CTranslate2-LICENSE.txt') -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'assets\licenses\SentencePiece-LICENSE.txt') -Destination (Join-Path $licenseDestination 'SentencePiece-LICENSE.txt') -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'LICENSE') -Destination (Join-Path $licenseDestination 'OPUS-MT-en-zh-APACHE-2.0.txt') -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'assets\licenses\CC-BY-4.0.txt') -Destination (Join-Path $licenseDestination 'OPUS-MT-zh-en-CC-BY-4.0.txt') -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'assets\licenses\OPUS-MT-NOTICES.txt') -Destination (Join-Path $licenseDestination 'OPUS-MT-NOTICES.txt') -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'assets\licenses\WHISPER-MULTILINGUAL-ASR-NOTICE.md') -Destination (Join-Path $licenseDestination 'WHISPER-MULTILINGUAL-ASR-NOTICE.md') -Force

# Open dictionary data is compiled into the runtime Dart libraries. Keep the
# source license notices beside the Windows package so the runtime data is
# accompanied by its attribution and redistribution terms.
$dictionarySourceNotices = @(
    'ECDICT-LICENSE.txt',
    'TATOEBA-NOTICE.md',
    'CC-BY-2.0-FR-legalcode.html',
    'KAIKKI-WIKTIONARY-NOTICE.md',
    'CC-BY-SA-4.0-legalcode.html',
    'GNU-FDL-1.2.txt',
    'WordNet-3.0-LICENSE.txt'
)
$dictionaryNoticeRoot = Join-Path $projectRoot 'third_party\dictionary_sources'
foreach ($noticeName in $dictionarySourceNotices) {
    $sourceNotice = Join-Path $dictionaryNoticeRoot $noticeName
    if (-not (Test-Path -LiteralPath $sourceNotice -PathType Leaf)) {
        throw "Dictionary source notice is missing: $sourceNotice"
    }
    Copy-Item -LiteralPath $sourceNotice `
        -Destination (Join-Path $licenseDestination $noticeName) -Force
}
foreach ($noticeName in $dictionarySourceNotices) {
    $packagedNotice = Join-Path $licenseDestination $noticeName
    if (-not (Test-Path -LiteralPath $packagedNotice -PathType Leaf)) {
        throw "Dictionary source notice was not packaged: $packagedNotice"
    }
}

$buildMetadata = [ordered]@{
    schemaVersion = 1
    product = '译学'
    version = $appVersion
    mode = $Mode
    gitCommit = $gitCommit
    dirty = $isDirty
    builtAt = (Get-Date).ToString('o')
}
$buildMetadata |
    ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $runnerDirectory 'build-source.json') -Encoding utf8

Write-Output "Windows app ready: $runnerDirectory"
