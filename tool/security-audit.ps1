$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$toolchainRoot = & (Join-Path $PSScriptRoot 'resolve-yixue-toolchain-root.ps1') -ProjectRoot $projectRoot
$cargoHome = Join-Path $toolchainRoot 'cargo'
$rustupHome = Join-Path $toolchainRoot 'rustup'
$cargoAudit = Join-Path $cargoHome 'bin\cargo-audit.exe'
$advisoryDb = Join-Path $toolchainRoot 'rustsec-advisory-db'
$lockFile = Join-Path $projectRoot 'Cargo.lock'

if (-not (Test-Path -LiteralPath $cargoAudit -PathType Leaf)) {
    throw 'cargo-audit is not installed. Install it with the project-local Cargo toolchain first.'
}
if (-not (Test-Path -LiteralPath $lockFile -PathType Leaf)) {
    throw 'The workspace Cargo.lock file is missing.'
}

$env:CARGO_HOME = $cargoHome
$env:RUSTUP_HOME = $rustupHome

& $cargoAudit audit --db $advisoryDb --file $lockFile
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Output 'Rust dependency audit passed.'
