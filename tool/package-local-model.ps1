param(
    [Parameter(Mandatory)]
    [string]$SourceDirectory,
    [Parameter(Mandatory)]
    [string]$DestinationDirectory,
    [Parameter(Mandatory)]
    [string]$PackageId,
    [Parameter(Mandatory)]
    [string]$DisplayName,
    [Parameter(Mandatory)]
    [ValidateSet('english', 'chinese')]
    [string]$SourceLanguage,
    [Parameter(Mandatory)]
    [ValidateSet('english', 'chinese')]
    [string]$TargetLanguage,
    [Parameter(Mandatory)]
    [string]$BaseModel,
    [Parameter(Mandatory)]
    [string]$License
)

$ErrorActionPreference = 'Stop'
$source = (Resolve-Path -LiteralPath $SourceDirectory).Path
if (Test-Path -LiteralPath $DestinationDirectory) {
    $entries = @(Get-ChildItem -LiteralPath $DestinationDirectory -Force)
    if ($entries.Count -gt 0) {
        throw 'Destination model package directory must be empty'
    }
}
New-Item -ItemType Directory -Force -Path $DestinationDirectory | Out-Null
$destination = (Resolve-Path -LiteralPath $DestinationDirectory).Path

$required = @('config.json', 'model.bin', 'source.spm', 'target.spm')
$sharedVocabulary = Join-Path $source 'shared_vocabulary.json'
$splitVocabulary = @(
    (Join-Path $source 'source_vocabulary.json'),
    (Join-Path $source 'target_vocabulary.json')
)
if (Test-Path -LiteralPath $sharedVocabulary -PathType Leaf) {
    $required += 'shared_vocabulary.json'
} elseif (($splitVocabulary | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count -eq 2) {
    $required += 'source_vocabulary.json', 'target_vocabulary.json'
} else {
    throw 'Source model does not contain a complete CTranslate2 vocabulary layout'
}

$hashes = [ordered]@{}
foreach ($name in $required) {
    $sourceFile = Join-Path $source $name
    if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
        throw "Required model file is missing: $name"
    }
    $destinationFile = Join-Path $destination $name
    Copy-Item -LiteralPath $sourceFile -Destination $destinationFile
    $hashes[$name] = (Get-FileHash -LiteralPath $destinationFile -Algorithm SHA256).Hash.ToLowerInvariant()
}

$manifest = [ordered]@{
    schema_version = 1
    package_id = $PackageId
    display_name = $DisplayName
    engine = 'ctranslate2'
    source_language = $SourceLanguage
    target_language = $TargetLanguage
    base_model = $BaseModel
    license = $License
    files = $hashes
}
$manifestPath = Join-Path $destination 'yixue-model.json'
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM
Write-Output $destination
