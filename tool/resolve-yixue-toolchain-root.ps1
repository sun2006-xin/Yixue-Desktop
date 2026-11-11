param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'
$resolvedProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)

if ($env:YIXUE_TOOLCHAIN_ROOT) {
    $toolchainRoot = [System.IO.Path]::GetFullPath($env:YIXUE_TOOLCHAIN_ROOT)
} else {
    $adjacentToolchainRoot = Join-Path (Split-Path -Parent $resolvedProjectRoot) 'YixueToolchains'
    if (Test-Path -LiteralPath $adjacentToolchainRoot -PathType Container) {
        $toolchainRoot = $adjacentToolchainRoot
    } else {
        $toolchainRoot = Join-Path $resolvedProjectRoot '.toolchains'
    }
}

[System.IO.Path]::GetFullPath($toolchainRoot)
