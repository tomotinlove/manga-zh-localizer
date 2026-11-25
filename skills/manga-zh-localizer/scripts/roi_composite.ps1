param(
    [Parameter(Mandatory=$true)][string]$BasePath,
    [Parameter(Mandatory=$true)][string]$AiPath,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [Parameter(Mandatory=$true)][string]$CropRect,   # "x,y,w,h" in BasePath coordinates
    [Parameter(Mandatory=$true)][string]$RoisJson,   # Path to JSON array: [{"box":[x0,y0,x1,y1],"mode":"glyph_diff"|"full_roi","dilate":5,"feather":4}]
    [int]$SearchRange = 8,
    [switch]$AutoTrimAiMargins,
    [int]$MarginWhiteThresh = 240
)

$ErrorActionPreference = "Stop"

$csCode = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;

public static class MangaRoiCompositor {
    public static Rectangle FindContentBounds(Bitmap bmp, int whiteThresh) {
        int thr = whiteThresh * 3;
        int minX = bmp.Width, minY = bmp.Height, maxX = -1, maxY = -1;
        for (int y = 0; y < bmp.Height; y++) {
            for (int x = 0; x < bmp.Width; x++) {
                Color c = bmp.GetPixel(x, y);
                if (c.R + c.G + c.B < thr) {
                    if (x < minX) minX = x;
                    if (x > maxX) maxX = x;
                    if (y < minY) minY = y;
                    if (y > maxY) maxY = y;
                }
            }
        }
        if (maxX < minX || maxY < minY) return new Rectangle(0, 0, bmp.Width, bmp.Height);
        return new Rectangle(minX, minY, maxX - minX + 1, maxY - minY + 1);
    }

    public static Bitmap ResizeHQ(Bitmap src, int w, int h) {
        var dst = new Bitmap(w, h, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(dst)) {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.SmoothingMode = SmoothingMode.HighQuality;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.DrawImage(src, 0, 0, w, h);
        }
        return dst;
    }

    // Find optimal integer alignment shift (dx, dy) over non-ROI pixels inside cropRect
    public static Point FindShift(Bitmap orig, Bitmap aiResized, Rectangle crop, Rectangle[] rois, int searchRange) {
        int bestDx = 0, bestDy = 0;
        long bestErr = long.MaxValue;
        int stepX = Math.Max(4, crop.Width / 90);
        int stepY = Math.Max(4, crop.Height / 60);

        for (int dy = -searchRange; dy <= searchRange; dy++) {
            for (int dx = -searchRange; dx <= searchRange; dx++) {
                long err = 0;
                int count = 0;
                for (int y = crop.Top; y < crop.Bottom; y += stepY) {
                    int ay = y - crop.Top + dy;
                    if (ay < 0 || ay >= aiResized.Height) continue;
                    for (int x = crop.Left; x < crop.Right; x += stepX) {
                        int ax = x - crop.Left + dx;
                        if (ax < 0 || ax >= aiResized.Width) continue;
                        bool inRoi = false;
                        foreach (var r in rois) if (r.Contains(x, y)) { inRoi = true; break; }
                        if (inRoi) continue;
                        Color c1 = orig.GetPixel(x, y);
                        Color c2 = aiResized.GetPixel(ax, ay);
                        err += Math.Abs(c1.R - c2.R) + Math.Abs(c1.G - c2.G) + Math.Abs(c1.B - c2.B);
                        count++;
                    }
                }
                if (count > 0) {
                    long normErr = err * 1000 / count;
                    if (normErr < bestErr) { bestErr = normErr; bestDx = dx; bestDy = dy; }
                }
            }
        }
        return new Point(bestDx, bestDy);
    }

    // Mode 1: glyph_diff -- polarity: "dark" (default, dark text on bright bg), "light" (white text on dark bg), or "both"
    public static void ApplyGlyphDiff(Bitmap target, Bitmap aiResized, Rectangle crop, int dx, int dy, Rectangle roi, int dilateR, float innerR, string polarity) {
        int x0 = Math.Max(crop.Left, roi.Left);
        int y0 = Math.Max(crop.Top, roi.Top);
        int x1 = Math.Min(crop.Right - 1, roi.Right);
        int y1 = Math.Min(crop.Bottom - 1, roi.Bottom);
        int w = x1 - x0 + 1, h = y1 - y0 + 1;
        if (w <= 0 || h <= 0) return;

        bool checkDark = (polarity != "light");
        bool checkLight = (polarity == "light" || polarity == "both");

        bool[,] raw = new bool[w, h];
        for (int y = y0; y <= y1; y++) {
            int ay = y - crop.Top + dy;
            if (ay < 0 || ay >= aiResized.Height) continue;
            for (int x = x0; x <= x1; x++) {
                int ax = x - crop.Left + dx;
                if (ax < 0 || ax >= aiResized.Width) continue;
                Color o = target.GetPixel(x, y);
                Color a = aiResized.GetPixel(ax, ay);
                int oLum = (o.R + o.G + o.B) / 3;
                int aLum = (a.R + a.G + a.B) / 3;
                int diff = Math.Abs(o.R - a.R) + Math.Abs(o.G - a.G) + Math.Abs(o.B - a.B);
                bool darkTextRemoved = checkDark && ((oLum < 165 && aLum > oLum + 35) || (oLum < 120 && diff > 90));
                bool lightTextRemoved = checkLight && ((oLum > 205 && aLum < oLum - 40) || (oLum > 225 && diff > 100));
                if (darkTextRemoved || lightTextRemoved) {
                    raw[x - x0, y - y0] = true;
                }
            }
        }

        float[,] alpha = new float[w, h];
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                if (!raw[x, y]) continue;
                for (int ky = -dilateR; ky <= dilateR; ky++) {
                    int ny = y + ky;
                    if (ny < 0 || ny >= h) continue;
                    for (int kx = -dilateR; kx <= dilateR; kx++) {
                        int nx = x + kx;
                        if (nx < 0 || nx >= w) continue;
                        double d = Math.Sqrt(kx * kx + ky * ky);
                        if (d <= innerR) alpha[nx, ny] = 1.0f;
                        else if (d <= dilateR) {
                            float v = (float)((dilateR - d) / Math.Max(0.5, dilateR - innerR));
                            if (v > alpha[nx, ny]) alpha[nx, ny] = v;
                        }
                    }
                }
            }
        }

        for (int y = 0; y < h; y++) {
            int gy = y0 + y;
            int ay = gy - crop.Top + dy;
            if (ay < 0 || ay >= aiResized.Height) continue;
            for (int x = 0; x < w; x++) {
                float al = alpha[x, y];
                if (al <= 0.001f) continue;
                int gx = x0 + x;
                int ax = gx - crop.Left + dx;
                if (ax < 0 || ax >= aiResized.Width) continue;
                Color o = target.GetPixel(gx, gy);
                Color a = aiResized.GetPixel(ax, ay);
                int rC = (int)Math.Round(o.R * (1 - al) + a.R * al);
                int gC = (int)Math.Round(o.G * (1 - al) + a.G * al);
                int bC = (int)Math.Round(o.B * (1 - al) + a.B * al);
                target.SetPixel(gx, gy, Color.FromArgb(rC, gC, bC));
            }
        }
    }

    // Mode 2: full_roi -- smoothly feathers entire ROI rectangle (ideal for AI-redrawn art titles/SFX in illustrations)
    public static void ApplyFullRoi(Bitmap target, Bitmap aiResized, Rectangle crop, int dx, int dy, Rectangle roi, int featherPx) {
        int x0 = Math.Max(crop.Left, roi.Left);
        int y0 = Math.Max(crop.Top, roi.Top);
        int x1 = Math.Min(crop.Right - 1, roi.Right);
        int y1 = Math.Min(crop.Bottom - 1, roi.Bottom);
        if (x1 < x0 || y1 < y0) return;

        for (int gy = y0; gy <= y1; gy++) {
            int ay = gy - crop.Top + dy;
            if (ay < 0 || ay >= aiResized.Height) continue;
            int distY = Math.Min(gy - y0, y1 - gy);
            float fy = featherPx > 0 ? Math.Min(1.0f, (distY + 0.5f) / featherPx) : 1.0f;
            for (int gx = x0; gx <= x1; gx++) {
                int ax = gx - crop.Left + dx;
                if (ax < 0 || ax >= aiResized.Width) continue;
                int distX = Math.Min(gx - x0, x1 - gx);
                float fx = featherPx > 0 ? Math.Min(1.0f, (distX + 0.5f) / featherPx) : 1.0f;
                float al = fx * fy;
                Color o = target.GetPixel(gx, gy);
                Color a = aiResized.GetPixel(ax, ay);
                int rC = (int)Math.Round(o.R * (1 - al) + a.R * al);
                int gC = (int)Math.Round(o.G * (1 - al) + a.G * al);
                int bC = (int)Math.Round(o.B * (1 - al) + a.B * al);
                target.SetPixel(gx, gy, Color.FromArgb(rC, gC, bC));
            }
        }
    }
}
'@

if (-not ("MangaRoiCompositor" -as [type])) {
    Add-Type -TypeDefinition $csCode -ReferencedAssemblies System.Drawing
} else {
    Add-Type -AssemblyName System.Drawing
}

$parts = $CropRect -split ',' | ForEach-Object { [int]$_.Trim() }
$crop = New-Object System.Drawing.Rectangle($parts[0], $parts[1], $parts[2], $parts[3])

$origBase = [System.Drawing.Bitmap]::FromFile($BasePath)
$target = New-Object System.Drawing.Bitmap($origBase)
$origBase.Dispose()

$aiRaw = [System.Drawing.Bitmap]::FromFile($AiPath)
if ($AutoTrimAiMargins) {
    $trimRect = [MangaRoiCompositor]::FindContentBounds($aiRaw, $MarginWhiteThresh)
    if ($trimRect.Width -lt $aiRaw.Width -or $trimRect.Height -lt $aiRaw.Height) {
        Write-Host "AutoTrimAiMargins: $($aiRaw.Width)x$($aiRaw.Height) -> [$($trimRect.X),$($trimRect.Y),$($trimRect.Width),$($trimRect.Height)]"
        $trimmed = $aiRaw.Clone($trimRect, $aiRaw.PixelFormat)
        $aiRaw.Dispose()
        $aiRaw = $trimmed
    }
}
Write-Host "AiRawSize: $($aiRaw.Width)x$($aiRaw.Height) -> CropSize: $($crop.Width)x$($crop.Height)"
$aiResized = [MangaRoiCompositor]::ResizeHQ($aiRaw, $crop.Width, $crop.Height)
$aiRaw.Dispose()

$roiCfg = ([System.IO.File]::ReadAllText($RoisJson, [System.Text.Encoding]::UTF8)) | ConvertFrom-Json
$roiItems = if ($roiCfg.rois) { $roiCfg.rois } else { $roiCfg }

$rectList = New-Object System.Collections.Generic.List[System.Drawing.Rectangle]
foreach ($item in $roiItems) {
    $b = $item.box # [x0, y0, x1, y1]
    $rectList.Add((New-Object System.Drawing.Rectangle([int]$b[0], [int]$b[1], ([int]$b[2] - [int]$b[0]), ([int]$b[3] - [int]$b[1]))))
}

$shift = [MangaRoiCompositor]::FindShift($target, $aiResized, $crop, $rectList.ToArray(), $SearchRange)
Write-Host "AutoShift: dx=$($shift.X), dy=$($shift.Y)"

for ($i = 0; $i -lt $roiItems.Count; $i++) {
    $item = $roiItems[$i]
    $rect = $rectList[$i]
    $mode = if ($item.mode) { [string]$item.mode } else { "glyph_diff" }
    if ($mode -eq "full_roi") {
        $feather = if ($item.feather) { [int]$item.feather } else { 10 }
        [MangaRoiCompositor]::ApplyFullRoi($target, $aiResized, $crop, $shift.X, $shift.Y, $rect, $feather)
    } else {
        $dilate = if ($item.dilate) { [int]$item.dilate } else { 5 }
        $inner = if ($item.inner) { [float]$item.inner } else { [float]([Math]::Max(1.5, $dilate - 1.8)) }
        $polarity = if ($item.polarity) { [string]$item.polarity } else { "dark" }
        [MangaRoiCompositor]::ApplyGlyphDiff($target, $aiResized, $crop, $shift.X, $shift.Y, $rect, $dilate, $inner, $polarity)
    }
}

$outParent = Split-Path -Parent $OutputPath
if ($outParent) { New-Item -ItemType Directory -Force -Path $outParent | Out-Null }
$target.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
$target.Dispose(); $aiResized.Dispose()
Write-Host "RoiCompositeSaved: $OutputPath"
