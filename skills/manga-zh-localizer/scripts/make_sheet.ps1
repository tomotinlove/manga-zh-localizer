param(
    [Parameter(Mandatory=$true)][string[]]$Images,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [int]$ColWidth = 950,
    [int]$Gap = 16,
    [int]$JpegQuality = 88,
    [string[]]$Labels = @()
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$rawImgs = @()
foreach ($it in $Images) { $rawImgs += ($it -split '\|') }
$valid = @($rawImgs | ForEach-Object { $_.Trim() } | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
if ($valid.Count -eq 0) { throw "No valid images passed to make_sheet.ps1" }

$labelList = @()
foreach ($lb in $Labels) { $labelList += ($lb -split '\|') }

$bmps = New-Object System.Collections.Generic.List[System.Drawing.Bitmap]
$scaledHeights = New-Object System.Collections.Generic.List[int]
$maxH = 0
$labelH = if ($labelList.Count -gt 0) { 30 } else { 0 }

foreach ($p in $valid) {
    $b = [System.Drawing.Bitmap]::FromFile((Resolve-Path -LiteralPath $p).Path)
    $bmps.Add($b)
    $sh = [int][Math]::Round($b.Height * ($ColWidth / [double]$b.Width))
    $scaledHeights.Add($sh)
    if ($sh -gt $maxH) { $maxH = $sh }
}

$totalW = $valid.Count * $ColWidth + ($valid.Count + 1) * $Gap
$totalH = $maxH + $labelH + 2 * $Gap

$sheet = New-Object System.Drawing.Bitmap($totalW, $totalH, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$g = [System.Drawing.Graphics]::FromImage($sheet)
$g.Clear([System.Drawing.Color]::FromArgb(30, 30, 34))
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

$font = New-Object System.Drawing.Font("Arial", 14, [System.Drawing.FontStyle]::Bold)
$txtBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)

for ($i = 0; $i -lt $bmps.Count; $i++) {
    $x = $Gap + $i * ($ColWidth + $Gap)
    $y = $Gap + $labelH
    $sh = $scaledHeights[$i]
    if ($labelH -gt 0 -and $i -lt $labelList.Count) {
        $g.DrawString($labelList[$i], $font, $txtBrush, $x + 4, $Gap + 2)
    }
    $g.DrawImage($bmps[$i], (New-Object System.Drawing.Rectangle($x, $y, $ColWidth, $sh)))
    $bmps[$i].Dispose()
}

$font.Dispose(); $txtBrush.Dispose(); $g.Dispose()

$outParent = Split-Path -Parent $OutputPath
if ($outParent) { New-Item -ItemType Directory -Force -Path $outParent | Out-Null }

if ($OutputPath -match '\.jpe?g$') {
    $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
    $encParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
    $encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]$JpegQuality)
    $sheet.Save($OutputPath, $codec, $encParams)
} else {
    $sheet.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
}
$sheet.Dispose()
Write-Host "SavedSheet: $OutputPath (${totalW}x${totalH}, $($valid.Count) tiles)"
