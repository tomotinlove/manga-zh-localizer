param(
    [Parameter(Mandatory=$true)][string]$ImagePath,
    [Parameter(Mandatory=$true)][string]$OutDir,
    [int]$GridStep = 0,
    [int]$MajorStep = 0,
    [string]$CropsJson = "",
    [string]$PreviewOut = "",
    [int]$PreviewWidth = 950,
    [string]$AutoBubblesOut = "",
    [switch]$FastPreview,
    [switch]$PrintSummary
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$inspectCs = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class AutoBubbleCandidateV4 {
    public int id;
    public int[] box;
    public int[] seed;
    public int[] optical_center;
    public int[] safe_rect;
    public int[] dark_bbox;
    public bool has_text;
    public string bg_type;
    public int[] bg_rgb;
    public int area;
}

public static class GridInspectFastV4 {
    public static void Analyze(Bitmap bmp, out List<int> blackRows, out List<int> whiteRows, bool detectBubbles, out List<AutoBubbleCandidateV4> bubbles) {
        int W = bmp.Width, H = bmp.Height;
        blackRows = new List<int>();
        whiteRows = new List<int>();
        bubbles = new List<AutoBubbleCandidateV4>();

        var bd = bmp.LockBits(new Rectangle(0, 0, W, H), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        int stride = bd.Stride;
        byte[] buf = new byte[stride * H];
        Marshal.Copy(bd.Scan0, buf, 0, buf.Length);
        bmp.UnlockBits(bd);

        int sampleStep = Math.Max(2, W / 140);
        int marginX = Math.Min(20, (int)(W * 0.03));
        int totalCols = 0;
        for (int x = marginX; x < W - marginX; x += sampleStep) totalCols++;

        for (int y = 0; y < H; y++) {
            int row = y * stride;
            int dark = 0, bright = 0;
            for (int x = marginX; x < W - marginX; x += sampleStep) {
                int p = row + (x << 2);
                byte b = buf[p], g = buf[p + 1], r = buf[p + 2];
                if (r < 32 && g < 32 && b < 32) dark++;
                else if (r > 245 && g > 245 && b > 245) bright++;
            }
            if (dark >= (int)(totalCols * 0.90)) blackRows.Add(y);
            else if (bright >= (int)(totalCols * 0.96)) whiteRows.Add(y);
        }

        if (!detectBubbles) return;

        // Downsampled ~440px-wide connected-component scan catching both regular and tiny speech bubbles
        int step = Math.Max(2, W / 440);
        int sw = (W + step - 1) / step;
        int sh = (H + step - 1) / step;
        bool[] isW = new bool[sw * sh];
        for (int sy = 0; sy < sh; sy++) {
            int py = Math.Min(H - 1, sy * step);
            int row = py * stride;
            for (int sx = 0; sx < sw; sx++) {
                int px = Math.Min(W - 1, sx * step);
                int p = row + (px << 2);
                if (buf[p] >= 240 && buf[p + 1] >= 240 && buf[p + 2] >= 240) isW[sy * sw + sx] = true;
            }
        }
        bool[] vis = new bool[sw * sh];
        var q = new Queue<int>();
        var comp = new List<int>(1024);
        int[] dx = {1,-1,0,0}, dy = {0,0,1,-1};
        int minCells = Math.Max(14, (sw * sh) / 2400);
        int maxCells = (sw * sh) / 7;

        for (int i = 0; i < sw * sh; i++) {
            if (!isW[i] || vis[i]) continue;
            vis[i] = true;
            q.Enqueue(i);
            comp.Clear();
            int minX = sw, minY = sh, maxX = -1, maxY = -1;
            bool touchesBorder = false;
            while (q.Count > 0) {
                int cur = q.Dequeue();
                comp.Add(cur);
                int cx = cur % sw, cy = cur / sw;
                if (cx < minX) minX = cx; if (cx > maxX) maxX = cx;
                if (cy < minY) minY = cy; if (cy > maxY) maxY = cy;
                if (cx == 0 || cy == 0 || cx == sw - 1 || cy == sh - 1) touchesBorder = true;
                for (int k = 0; k < 4; k++) {
                    int nx = cx + dx[k], ny = cy + dy[k];
                    if (nx < 0 || nx >= sw || ny < 0 || ny >= sh) continue;
                    int ni = ny * sw + nx;
                    if (isW[ni] && !vis[ni]) { vis[ni] = true; q.Enqueue(ni); }
                }
            }
            int cnt = comp.Count;
            if (cnt < minCells || cnt > maxCells) continue;
            int bw = (maxX - minX + 1) * step;
            int bh = (maxY - minY + 1) * step;
            double fillRatio = (double)cnt / ((maxX - minX + 1) * (maxY - minY + 1));
            if (fillRatio < 0.30 || (touchesBorder && fillRatio < 0.55)) continue;
            if (bw < W * 0.025 || bh < H * 0.025 || bw > W * 0.55 || bh > H * 0.45) continue;

            // 2-pass Chamfer 3-4 DT on component bbox (also fills interior text holes before DT!)
            int cbw = (maxX - minX + 1) + 2;
            int cbh = (maxY - minY + 1) + 2;
            bool[] inComp = new bool[cbw * cbh];
            for (int k = 0; k < cnt; k++) {
                int lx = (comp[k] % sw) - minX + 1;
                int ly = (comp[k] / sw) - minY + 1;
                inComp[ly * cbw + lx] = true;
            }
            // Flood exterior on padded local grid to find true filled interior (including text strokes inside bubble)
            bool[] ext = new bool[cbw * cbh];
            var eq = new Queue<int>();
            ext[0] = true; eq.Enqueue(0);
            while (eq.Count > 0) {
                int cur = eq.Dequeue();
                int lx = cur % cbw, ly = cur / cbw;
                for (int k = 0; k < 4; k++) {
                    int nx = lx + dx[k], ny = ly + dy[k];
                    if (nx < 0 || nx >= cbw || ny < 0 || ny >= cbh) continue;
                    int ni = ny * cbw + nx;
                    if (!ext[ni] && !inComp[ni]) { ext[ni] = true; eq.Enqueue(ni); }
                }
            }
            const int INF = 1000000;
            int[] dist = new int[cbw * cbh];
            for (int k = 0; k < cbw * cbh; k++) dist[k] = ext[k] ? 0 : INF;
            for (int y = 1; y < cbh - 1; y++) {
                int row = y * cbw, up = (y - 1) * cbw;
                for (int x = 1; x < cbw - 1; x++) {
                    int idx = row + x;
                    if (dist[idx] == 0) continue;
                    int d = dist[idx];
                    int c1 = dist[idx - 1] + 3; if (c1 < d) d = c1;
                    int c2 = dist[up + x] + 3; if (c2 < d) d = c2;
                    int c3 = dist[up + x - 1] + 4; if (c3 < d) d = c3;
                    int c4 = dist[up + x + 1] + 4; if (c4 < d) d = c4;
                    dist[idx] = d;
                }
            }
            int maxD = 0, bestSeedX = -1, bestSeedY = -1, bestSeedD = -1;
            for (int y = cbh - 2; y >= 1; y--) {
                int row = y * cbw, dn = (y + 1) * cbw;
                for (int x = cbw - 2; x >= 1; x--) {
                    int idx = row + x;
                    if (dist[idx] == 0) continue;
                    int d = dist[idx];
                    int c1 = dist[idx + 1] + 3; if (c1 < d) d = c1;
                    int c2 = dist[dn + x] + 3; if (c2 < d) d = c2;
                    int c3 = dist[dn + x - 1] + 4; if (c3 < d) d = c3;
                    int c4 = dist[dn + x + 1] + 4; if (c4 < d) d = c4;
                    dist[idx] = d;
                    if (d > maxD) maxD = d;
                    if (inComp[idx] && d > bestSeedD) {
                        bestSeedD = d; bestSeedX = x; bestSeedY = y;
                    }
                }
            }
            if (maxD <= 3 || bestSeedX < 0) continue;

            int coreThresh = (int)Math.Round(maxD * 0.72);
            double sumX = 0, sumY = 0, sumW = 0;
            int holeCells = 0;
            int dMinX = W, dMinY = H, dMaxX = -1, dMaxY = -1;
            for (int y = 1; y < cbh - 1; y++) {
                int row = y * cbw;
                for (int x = 1; x < cbw - 1; x++) {
                    int idx = row + x;
                    int d = dist[idx];
                    if (d >= coreThresh) {
                        double wt = (double)d * d;
                        sumX += (minX + x - 1) * wt;
                        sumY += (minY + y - 1) * wt;
                        sumW += wt;
                    }
                    // Interior non-white hole cell (likely text stroke!) with margin >= 4 from rim
                    if (!ext[idx] && !inComp[idx] && d >= 4) {
                        int px = Math.Min(W - 1, (minX + x - 1) * step);
                        int py = Math.Min(H - 1, (minY + y - 1) * step);
                        int p = py * stride + (px << 2);
                        int lum = (buf[p] + buf[p + 1] + buf[p + 2]) / 3;
                        if (lum < 130) {
                            holeCells++;
                            if (px < dMinX) dMinX = px; if (px > dMaxX) dMaxX = px;
                            if (py < dMinY) dMinY = py; if (py > dMaxY) dMaxY = py;
                        }
                    }
                }
            }
            if (sumW <= 0) continue;

            int cxImg = (int)Math.Round((sumX / sumW) * step);
            int cyImg = (int)Math.Round((sumY / sumW) * step);
            int sxImg = Math.Min(W - 1, (minX + bestSeedX - 1) * step);
            int syImg = Math.Min(H - 1, (minY + bestSeedY - 1) * step);

            // Refine seed on full-res bitmap to guarantee pure bright pixel away from strokes
            int sp0 = syImg * stride + (sxImg << 2);
            if (buf[sp0] < 240 || buf[sp0 + 1] < 240 || buf[sp0 + 2] < 240) {
                bool found = false;
                for (int r = 2; r <= step * 3 && !found; r += 2) {
                    for (int oy = -r; oy <= r && !found; oy += r) {
                        for (int ox = -r; ox <= r && !found; ox += r) {
                            int nx = sxImg + ox, ny = syImg + oy;
                            if (nx < 0 || nx >= W || ny < 0 || ny >= H) continue;
                            int np = ny * stride + (nx << 2);
                            if (buf[np] >= 244 && buf[np + 1] >= 244 && buf[np + 2] >= 244) {
                                sxImg = nx; syImg = ny; found = true;
                            }
                        }
                    }
                }
            }
            int spFinal = syImg * stride + (sxImg << 2);
            int bgR = buf[spFinal + 2], bgG = buf[spFinal + 1], bgB = buf[spFinal];
            int bgLum = (bgR + bgG + bgB) / 3;
            string bgType = (bgLum >= 244) ? "white" : "grey";

            // Also verify interior text at finer 2px resolution if downsampled scan saw few holes (small thin glyphs)
            if (holeCells < 2) {
                int ix0 = Math.Max(0, minX * step + step * 2);
                int iy0 = Math.Max(0, minY * step + step * 2);
                int ix1 = Math.Min(W - 1, maxX * step - step * 2);
                int iy1 = Math.Min(H - 1, maxY * step - step * 2);
                int fineDark = 0;
                for (int py = iy0; py <= iy1; py += 3) {
                    int row = py * stride;
                    int ly = (py / step) - minY + 1;
                    if (ly <= 1 || ly >= cbh - 1) continue;
                    for (int px = ix0; px <= ix1; px += 3) {
                        int lx = (px / step) - minX + 1;
                        if (lx <= 1 || lx >= cbw - 1) continue;
                        if (dist[ly * cbw + lx] < 6) continue;
                        int p = row + (px << 2);
                        if ((buf[p] + buf[p + 1] + buf[p + 2]) < 330) {
                            fineDark++;
                            if (px < dMinX) dMinX = px; if (px > dMaxX) dMaxX = px;
                            if (py < dMinY) dMinY = py; if (py > dMaxY) dMaxY = py;
                        }
                    }
                }
                if (fineDark >= 8) holeCells = Math.Max(holeCells, fineDark / 4);
            }

            int x0 = Math.Max(0, minX * step - step * 2);
            int y0 = Math.Max(0, minY * step - step * 2);
            int x1 = Math.Min(W - 1, (maxX + 1) * step + step * 2);
            int y1 = Math.Min(H - 1, (maxY + 1) * step + step * 2);
            int safeW = (int)Math.Round(bw * 0.76);
            int safeH = (int)Math.Round(bh * 0.74);

            var c = new AutoBubbleCandidateV4();
            c.box = new int[] { x0, y0, x1, y1 };
            c.seed = new int[] { sxImg, syImg };
            c.optical_center = new int[] { cxImg, cyImg };
            c.safe_rect = new int[] { cxImg - safeW / 2, cyImg - safeH / 2, safeW, safeH };
            c.has_text = (holeCells >= 2 && dMaxX >= dMinX);
            c.dark_bbox = c.has_text ? new int[] { dMinX, dMinY, dMaxX, dMaxY } : null;
            c.bg_type = bgType;
            c.bg_rgb = new int[] { bgR, bgG, bgB };
            c.area = cnt * step * step;
            bubbles.Add(c);
        }

        // Sort in manga reading order (top-to-bottom bands, right-to-left)
        bubbles.Sort((a, b) => {
            int bandA = a.optical_center[1] / Math.Max(1, H / 4);
            int bandB = b.optical_center[1] / Math.Max(1, H / 4);
            if (bandA != bandB) return bandA.CompareTo(bandB);
            return b.optical_center[0].CompareTo(a.optical_center[0]);
        });
        for (int idx = 0; idx < bubbles.Count; idx++) bubbles[idx].id = idx + 1;
    }
}
'@

if (-not ("GridInspectFastV4" -as [type])) {
    Add-Type -TypeDefinition $inspectCs -ReferencedAssemblies System.Drawing
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$bmp = [System.Drawing.Bitmap]::FromFile((Resolve-Path -LiteralPath $ImagePath).Path)
$W = $bmp.Width
$H = $bmp.Height
if ($GridStep -le 0)  { $GridStep  = if ($W -ge 1600) { 100 } else { 50 } }
if ($MajorStep -le 0) { $MajorStep = if ($W -ge 1600) { 500 } else { 200 } }

Write-Host "ImageSize: ${W}x${H}"
if ($ImagePath -match '\.user_uploaded' -or ([Math]::Max($W, $H) -le 1024)) {
    Write-Host "WARNING_LOW_RES: Input appears to be chat-uploaded or <=1024px (${W}x${H})."
}

$blackRows = $null; $whiteRows = $null; $bubbles = $null
[GridInspectFastV4]::Analyze($bmp, [ref]$blackRows, [ref]$whiteRows, [bool]($AutoBubblesOut -ne "" -or $PrintSummary.IsPresent), [ref]$bubbles)

function Format-Ranges([System.Collections.Generic.List[int]]$nums) {
    if ($nums.Count -eq 0) { return "none" }
    $ranges = @()
    $start = $nums[0]; $prev = $nums[0]
    for ($i = 1; $i -lt $nums.Count; $i++) {
        if ($nums[$i] -eq $prev + 1) { $prev = $nums[$i] }
        else {
            if (($prev - $start) -ge 2) { $ranges += "${start}..${prev}" }
            $start = $nums[$i]; $prev = $nums[$i]
        }
    }
    if (($prev - $start) -ge 2) { $ranges += "${start}..${prev}" }
    if ($ranges.Count -eq 0) { return "none" }
    return ($ranges -join ", ")
}

Write-Host "HorizontalBlackBars: $(Format-Ranges $blackRows)"
Write-Host "HorizontalWhiteGaps: $(Format-Ranges $whiteRows)"

if ($AutoBubblesOut) {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($AutoBubblesOut, ($bubbles | ConvertTo-Json -Depth 4), $utf8)
    $textCnt = @($bubbles | Where-Object { $_.has_text }).Count
    Write-Host "SavedAutoBubbles: $AutoBubblesOut ($($bubbles.Count) candidates, $textCnt with text)"
}

if ($PrintSummary.IsPresent -and $bubbles) {
    foreach ($b in $bubbles) {
        if (-not $b.has_text) { continue }
        $dbStr = if ($b.dark_bbox) { "ink=[$($b.dark_bbox -join ',')]" } else { "ink=none" }
        Write-Host ("  [B{0,-2}] box=[{1}] seed=[{2}] ctr=[{3}] {4} bg={5}" -f $b.id, ($b.box -join ','), ($b.seed -join ','), ($b.optical_center -join ','), $dbStr, $b.bg_type)
    }
}

$needGrid = (-not $FastPreview.IsPresent) -or ($PreviewOut -ne "")
if ($needGrid) {
    $grid = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($grid)
    $g.DrawImage($bmp, 0, 0, $W, $H)

    $penMaj = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(145, 255, 0, 0), [Math]::Max(1, [int]($W / 1200)))
    $penMin = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(65, 0, 120, 255), 1)
    $fontSize = [Math]::Max(10, [Math]::Min(26, [int]($W / 75)))
    $font = New-Object System.Drawing.Font("Arial", $fontSize, [System.Drawing.FontStyle]::Bold)
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(235, 210, 0, 0))
    $bgBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(190, 255, 255, 255))

    $labelYs = @(2)
    if ($H -gt 600) { $labelYs += [int]($H * 0.42) }
    if ($H -gt 900) { $labelYs += [int]($H * 0.81) }

    for ($x = 0; $x -lt $W; $x += $GridStep) {
        $isMaj = ($x % $MajorStep -eq 0)
        $p = if ($isMaj) { $penMaj } else { $penMin }
        $g.DrawLine($p, $x, 0, $x, $H)
        if ($isMaj -and $x -gt 0) {
            $lbl = "$x"
            $sz = $g.MeasureString($lbl, $font)
            foreach ($ly in $labelYs) {
                $g.FillRectangle($bgBrush, $x + 2, $ly, $sz.Width, $sz.Height)
                $g.DrawString($lbl, $font, $brush, $x + 2, $ly)
            }
        }
    }
    for ($y = 0; $y -lt $H; $y += $GridStep) {
        $isMaj = ($y % $MajorStep -eq 0)
        $p = if ($isMaj) { $penMaj } else { $penMin }
        $g.DrawLine($p, 0, $y, $W, $y)
        if ($isMaj) {
            $lbl = "$y"
            $sz = $g.MeasureString($lbl, $font)
            $g.FillRectangle($bgBrush, 2, $y + 2, $sz.Width, $sz.Height)
            $g.DrawString($lbl, $font, $brush, 2, $y + 2)
        }
    }

    if (-not $FastPreview.IsPresent) {
        $gridOut = Join-Path $OutDir "grid_debug.png"
        $grid.Save($gridOut, [System.Drawing.Imaging.ImageFormat]::Png)
        Write-Host "SavedGrid: $gridOut"
    }

    if ($PreviewOut) {
        $pw = [Math]::Min($W, $PreviewWidth)
        $ph = [int][Math]::Round($H * ($pw / [double]$W))
        $prev = New-Object System.Drawing.Bitmap($pw, $ph, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $gp = [System.Drawing.Graphics]::FromImage($prev)
        $gp.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $gp.DrawImage($grid, 0, 0, $pw, $ph)
        $gp.Dispose()
        $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
        $encParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
        $encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]88)
        $prev.Save($PreviewOut, $codec, $encParams)
        $prev.Dispose()
        Write-Host "SavedPreview: $PreviewOut (${pw}x${ph})"
    }

    $penMaj.Dispose(); $penMin.Dispose(); $font.Dispose(); $brush.Dispose(); $bgBrush.Dispose()
    $g.Dispose(); $grid.Dispose()
}

if ($CropsJson -and (Test-Path $CropsJson)) {
    $raw = [System.IO.File]::ReadAllText($CropsJson, [System.Text.Encoding]::UTF8)
    $crops = $raw | ConvertFrom-Json
    foreach ($c in $crops) {
        $cx = [Math]::Max(0, [int]$c.x)
        $cy = [Math]::Max(0, [int]$c.y)
        $cw = [Math]::Min($W - $cx, [int]$c.w)
        $ch = [Math]::Min($H - $cy, [int]$c.h)
        $rect = New-Object System.Drawing.Rectangle($cx, $cy, $cw, $ch)
        $sub = $bmp.Clone($rect, $bmp.PixelFormat)
        $outCrop = Join-Path $OutDir $c.name
        $sub.Save($outCrop, [System.Drawing.Imaging.ImageFormat]::Png)
        $sub.Dispose()
        Write-Host "SavedCrop: $outCrop (${cw}x${ch} at $cx,$cy)"
    }
}

$bmp.Dispose()
