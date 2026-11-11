param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$FlutterArgs
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = [System.IO.Path]::GetFullPath($projectRoot)
$toolchainRoot = & (Join-Path $PSScriptRoot 'resolve-yixue-toolchain-root.ps1') -ProjectRoot $projectRoot
$asciiRoot = if ($env:YIXUE_FLUTTER_PROJECT_ALIAS) {
    $env:YIXUE_FLUTTER_PROJECT_ALIAS
} elseif ($projectRoot -match '[^\x00-\x7F]') {
    Join-Path (Split-Path -Parent $projectRoot) 'YixueDev'
} else {
    $projectRoot
}
$asciiRoot = [System.IO.Path]::GetFullPath($asciiRoot)
$localFlutterRoot = Join-Path $toolchainRoot 'flutter'
$flutterRoot = if ($env:YIXUE_FLUTTER_SDK) {
    $env:YIXUE_FLUTTER_SDK
} elseif (Test-Path -LiteralPath (Join-Path $localFlutterRoot 'bin\flutter.bat') -PathType Leaf) {
    $localFlutterRoot
} else {
    $flutterCommand = Get-Command 'flutter.bat' -ErrorAction SilentlyContinue
    if ($flutterCommand) {
        Split-Path -Parent (Split-Path -Parent $flutterCommand.Source)
    } else {
        throw 'Flutter SDK was not found in the project toolchain or PATH. Set YIXUE_FLUTTER_SDK to its installation directory.'
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $flutterRoot 'bin\flutter.bat') -PathType Leaf)) {
    throw "Flutter SDK is missing: $(Join-Path $flutterRoot 'bin\flutter.bat')"
}

# Flutter's analysis/test/build processes can reserve a large Dart heap. Keep
# the project wrapper fail-closed when the machine is already under pressure,
# and serialize wrapper calls so two expensive operations cannot overlap.
$minimumPhysicalFreeKb = 2 * 1024 * 1024
$minimumVirtualFreeKb = 3 * 1024 * 1024
$operatingSystem = Get-CimInstance Win32_OperatingSystem
if ($operatingSystem.FreePhysicalMemory -lt $minimumPhysicalFreeKb -or
    $operatingSystem.FreeVirtualMemory -lt $minimumVirtualFreeKb) {
    $physicalFreeGb = '{0:N2}' -f ($operatingSystem.FreePhysicalMemory / 1MB)
    $virtualFreeGb = '{0:N2}' -f ($operatingSystem.FreeVirtualMemory / 1MB)
    throw "Flutter operation refused for safety: free memory is $physicalFreeGb GB physical / $virtualFreeGb GB virtual; at least 2.00 GB physical and 3.00 GB virtual are required. Close other applications and retry."
}

$activeProcessNames = @('dart', 'dartaotruntime', 'flutter', 'flutter_tester')
$activeProcesses = @(Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $activeProcessNames -contains $_.ProcessName.ToLowerInvariant() })
if ($activeProcesses.Count -gt 0) {
    $processList = $activeProcesses |
        ForEach-Object { '{0} (PID {1})' -f $_.ProcessName, $_.Id } |
        Sort-Object
    throw "Flutter operation refused: another Dart/Flutter operation is already running: $($processList -join ', ')"
}

$operationLockPath = Join-Path $toolchainRoot 'flutter-operation.lock'
$toolchainDirectory = Split-Path -Parent $operationLockPath
if (-not (Test-Path -LiteralPath $toolchainDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $toolchainDirectory -Force | Out-Null
}
$operationLock = $null
$flutterExitCode = 1
try {
    try {
        $operationLock = [System.IO.File]::Open(
            $operationLockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    } catch [System.IO.IOException] {
        throw 'Flutter operation refused: another project Flutter operation is already running.'
    }

    if ($asciiRoot -ne $projectRoot) {
        if (-not (Test-Path -LiteralPath $asciiRoot)) {
            New-Item -ItemType Junction -Path $asciiRoot -Target $projectRoot | Out-Null
        } else {
            $existingLink = Get-Item -LiteralPath $asciiRoot -Force
            $existingTarget = [System.IO.Path]::GetFullPath([string]$existingLink.Target)
            if ($existingLink.LinkType -ne 'Junction' -or $existingTarget -ne $projectRoot) {
                throw "$asciiRoot exists but does not point to $projectRoot"
            }
        }
    }

    $env:PUB_CACHE = if ($env:YIXUE_PUB_CACHE) {
        $env:YIXUE_PUB_CACHE
    } else {
        Join-Path $toolchainRoot 'pub-cache'
    }
    Push-Location (Join-Path $asciiRoot 'app\yixue_app')
    try {
        # Flutter's batch launcher prefers PowerShell 7 when `pwsh.exe` is on
        # PATH. On this machine, the Visual Studio developer environment can
        # put a broken/interactive pwsh shim ahead of Windows PowerShell; the
        # engine-version probe then hangs before Flutter starts. Keep this
        # workaround process-local: hide only PATH entries that contain
        # pwsh.exe while the Flutter child runs, then restore the caller PATH.
        $originalChildPath = $env:PATH
        $flutterChildPath = foreach ($pathEntry in ($env:PATH -split ';')) {
            if ([string]::IsNullOrWhiteSpace($pathEntry)) {
                $pathEntry
                continue
            }
            $candidatePowerShell7 = Join-Path $pathEntry.Trim('"') 'pwsh.exe'
            if (-not (Test-Path -LiteralPath $candidatePowerShell7 -PathType Leaf)) {
                $pathEntry
            }
        }
        try {
            $env:PATH = $flutterChildPath -join ';'
            & (Join-Path $flutterRoot 'bin\flutter.bat') @FlutterArgs
            $flutterExitCode = $LASTEXITCODE
        } finally {
            $env:PATH = $originalChildPath
        }
    } finally {
        Pop-Location
    }
} finally {
    if ($null -ne $operationLock) {
        $operationLock.Dispose()
    }
}
exit $flutterExitCode
