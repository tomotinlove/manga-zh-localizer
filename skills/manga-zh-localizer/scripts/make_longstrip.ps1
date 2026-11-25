param(
    [Parameter(Mandatory=$true)][string[]]$Images,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [int]$TargetWidth = 1518,
    [int]$Padding = 20,
    [int]$Gap = 28,
    [int]$MaxHeight = 24000,
    [int]$JpegQuality = 93,
    [switch]$ShowPageNumbers,
    [string]$OrderedOutDir = "",
    [string]$JobPrefix = "",
    [switch]$MoveOriginals
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

# Parse pipe-delimited or array image list in exact reading order
$rawImgs = @()
foreach ($it in $Images) { $rawImgs += ($it -split '\|') }
$valid = @($rawImgs | ForEach-Object { $_.Trim() } | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
if ($valid.Count -eq 0) { throw "No valid images passed to make_longstrip.ps1" }

$totalPages = $valid.Count
$padDigits = [Math]::Max(2, ([string]$totalPages).Length)

# Optional: package individual lossless pages into an ordered job folder with 01..NN prefix & monotonic timestamps
$orderedPaths = New-Object System.Collections.Generic.List[string]
if ($OrderedOutDir) {
    New-Item -ItemType Directory -Force -Path $OrderedOutDir | Out-Null
    $baseTime = (Get-Date).AddSeconds(-($totalPages * 4 + 10))
    for ($i = 0; $i -lt $totalPages; $i++) {
        $src = (Resolve-Path -LiteralPath $valid[$i]).Path
        $leaf = Split-Path -Leaf $src
        # Strip any existing leading 01_ / 02_ prefix so re-runs stay idempotent
        $cleanLeaf = $leaf -replace '^\d{2,3}_', ''
        $numStr = ($i + 1).ToString("D$padDigits")
        $destName = if ($JobPrefix -and ($cleanLeaf -notlike "${JobPrefix}*")) {
            "${numStr}_${JobPrefix}_${cleanLeaf}"
        } else {
            "${numStr}_${cleanLeaf}"
        }
        $destPath = Join-Path $OrderedOutDir $destName
        if ($src -ne $destPath) {
            if ($MoveOriginals.IsPresent) {
                Move-Item -LiteralPath $src -Destination $destPath -Force
            } else {
                Copy-Item -LiteralPath $src -Destination $destPath -Force
            }
        }
        $ts = $baseTime.AddSeconds(($i + 1) * 4)
        $item = Get-Item -LiteralPath $destPath
        $item.CreationTime = $ts
        $item.LastWriteTime = $ts
        $orderedPaths.Add($destPath)
    }
    Write-Host "PackagedOrderedPages: $OrderedOutDir ($totalPages files, monotonic timestamps set)"
} else {
    foreach ($p in $valid) { $orderedPaths.Add((Resolve-Path -LiteralPath $p).Path) }
}

# Measure scaled dimensions for vertical long strip(s)
$headerH = if ($ShowPageNumbers.IsPresent) { 36 } else { 0 }
$pageInfos = New-Object System.Collections.Generic.List[hashtable]
for ($i = 0; $i -lt $orderedPaths.Count; $i++) {
    $bmp = [System.Drawing.Bitmap]::FromFile($orderedPaths[$i])
    $w = $bmp.Width
    $h = $bmp.Height
    $bmp.Dispose()
    $sh = [int][Math]::Round($h * ($TargetWidth / [double]$w))
    $pageInfos.Add(@{ Index = ($i + 1); Path = $orderedPaths[$i]; OrigW = $w; OrigH = $h; ScaledH = $sh })
}

# Partition into chunks if total height exceeds MaxHeight (protects mobile/browser GPU texture limits)
$chunks = New-Object System.Collections.Generic.List[object]
$curr = New-Object System.Collections.Generic.List[hashtable]
$currH = $Padding * 2
foreach ($pi in $pageInfos) {
    $need = $pi.ScaledH + $headerH + $(if ($curr.Count -gt 0) { $Gap } else { 0 })
    if ($curr.Count -gt 0 -and ($currH + $need) -gt $MaxHeight) {
        $chunks.Add($curr)
        $curr = New-Object System.Collections.Generic.List[hashtable]
        $currH = $Padding * 2
        $need = $pi.ScaledH + $headerH
    }
    $curr.Add($pi)
    $currH += $need
}
if ($curr.Count -gt 0) { $chunks.Add($curr) }

$outParent = Split-Path -Parent $OutputPath
if ($outParent) { New-Item -ItemType Directory -Force -Path $outParent | Out-Null }
$outDir = Split-Path -Parent $OutputPath
$outBase = [System.IO.Path]::GetFileNameWithoutExtension($OutputPath)
$outExt = [System.IO.Path]::GetExtension($OutputPath)
if (-not $outExt) { $outExt = ".png" }

$canvasW = $TargetWidth + 2 * $Padding
$bgColor = [System.Drawing.Color]::FromArgb(30, 31, 36)
$barTextColor = [System.Drawing.Color]::FromArgb(205, 210, 220)
$borderColor = [System.Drawing.Color]::FromArgb(62, 65, 74)

$savedOutputs = New-Object System.Collections.Generic.List[string]
for ($ci = 0; $ci -lt $chunks.Count; $ci++) {
    $chunk = $chunks[$ci]
    $canvasH = $Padding * 2
    for ($k = 0; $k -lt $chunk.Count; $k++) {
        $canvasH += $headerH + $chunk[$k].ScaledH
        if ($k -gt 0) { $canvasH += $Gap }
    }

    $strip = New-Object System.Drawing.Bitmap($canvasW, $canvasH, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [System.Drawing.Graphics]::FromImage($strip)
    $g.Clear($bgColor)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

    $font = New-Object System.Drawing.Font("Microsoft YaHei", 15, [System.Drawing.FontStyle]::Bold)
    $txtBrush = New-Object System.Drawing.SolidBrush($barTextColor)
    $framePen = New-Object System.Drawing.Pen($borderColor, 1)

    $y = $Padding
    for ($k = 0; $k -lt $chunk.Count; $k++) {
        $pi = $chunk[$k]
        if ($k -gt 0) { $y += $Gap }
        if ($headerH -gt 0) {
            $lbl = ("P{0} / {1}" -f $pi.Index.ToString("D$padDigits"), $totalPages.ToString("D$padDigits"))
            $g.DrawString($lbl, $font, $txtBrush, $Padding + 4, $y + 5)
            $y += $headerH
        }
        $srcBmp = [System.Drawing.Bitmap]::FromFile($pi.Path)
        $g.DrawImage($srcBmp, (New-Object System.Drawing.Rectangle($Padding, $y, $TargetWidth, $pi.ScaledH)))
        $srcBmp.Dispose()
        $g.DrawRectangle($framePen, $Padding, $y, $TargetWidth - 1, $pi.ScaledH - 1)
        $y += $pi.ScaledH
    }

    $font.Dispose(); $txtBrush.Dispose(); $framePen.Dispose(); $g.Dispose()

    $chunkPath = if ($chunks.Count -eq 1) {
        $OutputPath
    } else {
        Join-Path $outDir ("{0}_part{1}{2}" -f $outBase, ($ci + 1), $outExt)
    }

    if ($chunkPath -match '\.jpe?g$') {
        $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
        $encParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
        $encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]$JpegQuality)
        $strip.Save($chunkPath, $codec, $encParams)
    } else {
        $strip.Save($chunkPath, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    $strip.Dispose()

    # Keep long-strip timestamp right before page 01 when stored inside OrderedOutDir
    if ($OrderedOutDir -and ((Split-Path -Parent (Resolve-Path -LiteralPath $chunkPath).Path) -eq (Resolve-Path -LiteralPath $OrderedOutDir).Path)) {
        $firstItem = Get-Item -LiteralPath $orderedPaths[0]
        $stripItem = Get-Item -LiteralPath $chunkPath
        $ts0 = $firstItem.LastWriteTime.AddSeconds(-4 + $ci)
        $stripItem.CreationTime = $ts0
        $stripItem.LastWriteTime = $ts0
    }

    $szMB = [Math]::Round((Get-Item -LiteralPath $chunkPath).Length / 1MB, 2)
    $savedOutputs.Add($chunkPath)
    Write-Host "SavedLongStrip: $chunkPath (${canvasW}x${canvasH}, $($chunk.Count) pages, ${szMB}MB)"
}
