param(
    [string]$Output = '',
    [string]$Preview = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$master = Join-Path $projectRoot 'assets\brand\yixue-logo-master-v3.png'
if (-not $Output) {
    $Output = Join-Path $projectRoot 'app\yixue_app\windows\runner\resources\app_icon.ico'
}
if (-not $Preview) {
    $Preview = Join-Path $projectRoot 'assets\brand\yixue-mark-256.png'
}
if (-not (Test-Path -LiteralPath $master -PathType Leaf)) {
    throw "Brand master is missing: $master"
}

Add-Type -AssemblyName System.Drawing

function New-YixuePngBytes([int]$size) {
    $source = [System.Drawing.Image]::FromFile($master)
    $bitmap = [System.Drawing.Bitmap]::new(
        $size,
        $size,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    )
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
    $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $graphics.DrawImage($source, 0, 0, $size, $size)

    $stream = [System.IO.MemoryStream]::new()
    $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $bytes = $stream.ToArray()
    $stream.Dispose()
    $graphics.Dispose()
    $bitmap.Dispose()
    $source.Dispose()
    Write-Output -NoEnumerate $bytes
}

$sizes = @(16, 24, 32, 48, 64, 128, 256)
$images = [System.Collections.Generic.List[byte[]]]::new()
foreach ($size in $sizes) {
    $images.Add((New-YixuePngBytes $size))
}

[System.IO.Directory]::CreateDirectory((Split-Path -Parent $Output)) | Out-Null
$stream = [System.IO.File]::Create($Output)
$writer = [System.IO.BinaryWriter]::new($stream)
$writer.Write([uint16]0)
$writer.Write([uint16]1)
$writer.Write([uint16]$images.Count)
$offset = 6 + 16 * $images.Count
for ($i = 0; $i -lt $images.Count; $i++) {
    $size = $sizes[$i]
    $writer.Write([byte]($(if ($size -eq 256) { 0 } else { $size })))
    $writer.Write([byte]($(if ($size -eq 256) { 0 } else { $size })))
    $writer.Write([byte]0)
    $writer.Write([byte]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]32)
    $writer.Write([uint32]$images[$i].Length)
    $writer.Write([uint32]$offset)
    $offset += $images[$i].Length
}
foreach ($image in $images) {
    $writer.Write($image)
}
$writer.Dispose()
$stream.Dispose()

[System.IO.Directory]::CreateDirectory((Split-Path -Parent $Preview)) | Out-Null
[System.IO.File]::WriteAllBytes($Preview, $images[$images.Count - 1])
$shortcutIcon = Join-Path $projectRoot 'assets\brand\yixue-app-icon-v3.ico'
Copy-Item -LiteralPath $Output -Destination $shortcutIcon -Force

Write-Output "MASTER=$master"
Write-Output "ICON=$Output"
Write-Output "PREVIEW=$Preview"
Write-Output "SHORTCUT_ICON=$shortcutIcon"
