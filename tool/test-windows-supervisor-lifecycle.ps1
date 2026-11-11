param(
    [switch]$KeepArtifactsOnFailure
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$testSource = Join-Path $projectRoot 'app\yixue_app\windows\runner\tests\supervised_process_lifecycle_test.cpp'
if (-not (Test-Path -LiteralPath $testSource -PathType Leaf)) {
    throw "Supervisor lifecycle test source was not found: $testSource"
}

$programFilesX86 = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
$programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
$vswhere = @(
    (Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'),
    (Join-Path $programFiles 'Microsoft Visual Studio\Installer\vswhere.exe')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $vswhere) {
    throw 'Visual Studio vswhere.exe was not found; the native lifecycle test requires the C++ desktop workload.'
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

$systemTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
$testDirectory = Join-Path $systemTempRoot "yixue-supervisor-lifecycle-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testDirectory | Out-Null
$testSucceeded = $false
try {
    & $vsDevShell -Arch amd64 -HostArch amd64
    if ($LASTEXITCODE -ne 0) {
        throw "Visual Studio developer shell failed with exit code $LASTEXITCODE"
    }

    $testExecutable = Join-Path $testDirectory 'supervised_process_lifecycle_test.exe'
    & cl.exe /nologo /EHsc /std:c++17 "/Fo$testDirectory\" "/Fd$testDirectory\compiler.pdb" `
        $testSource "/Fe$testExecutable"
    if ($LASTEXITCODE -ne 0) {
        throw "The supervisor lifecycle test failed to compile with exit code $LASTEXITCODE"
    }
    & $testExecutable
    if ($LASTEXITCODE -ne 0) {
        throw "The supervisor lifecycle test failed with exit code $LASTEXITCODE"
    }

    $testSucceeded = $true
    Write-Output 'Windows supervisor lifecycle tests passed.'
} finally {
    $resolvedTestDirectory = [System.IO.Path]::GetFullPath($testDirectory)
    if ([System.IO.Path]::GetDirectoryName($resolvedTestDirectory) -ne $systemTempRoot) {
        throw "Refusing to remove a test directory outside $systemTempRoot"
    }
    if ($KeepArtifactsOnFailure -and -not $testSucceeded) {
        Write-Warning "Preserving failed native test artifacts for diagnosis: $resolvedTestDirectory"
    } elseif (Test-Path -LiteralPath $resolvedTestDirectory -PathType Container) {
        $directoryItem = Get-Item -LiteralPath $resolvedTestDirectory -Force
        if ($directoryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Refusing to remove a reparse point used as a test directory: $resolvedTestDirectory"
        }
        Remove-Item -LiteralPath $resolvedTestDirectory -Recurse -Force
    }
}
