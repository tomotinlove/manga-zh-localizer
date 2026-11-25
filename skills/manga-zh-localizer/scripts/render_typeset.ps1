param(
    [Parameter(Mandatory=$true)][string]$CleanImage,
    [Parameter(Mandatory=$true)][string]$LayoutPath,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [string]$TextLayerOut = "",
    [string]$HtmlOut = "",
    [string]$AuditOverlay = "",
    [string]$AuditJsonOut = "",
    [switch]$AutoOpticalCenter,
    [int]$SuperSample = 2,
    [string]$TmpDir = "",
    [string]$BrowserPath = "",
    [string]$ConfigPath = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot "_common.ps1")
$mlConfig = Get-MangaLocalizerConfig -ScriptDir $PSScriptRoot -ConfigPath $ConfigPath -TmpDir $TmpDir -BrowserPath $BrowserPath

$auditorCs = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class BlockSpec {
    public string Id;
    public int X, Y, W, H;
    public double FontSize;
    public bool OpticalCenter;
    public bool SnapToBubble;
    public bool HasStroke;
    public bool IsDarkBg;
}

public class BlockAudit {
    public string Id;
    public int TargetCx, TargetCy;
    public bool HasCavity;
    public int CavCx, CavCy;
    public int OffCenterX, OffCenterY;
    public int InkX0, InkY0, InkX1, InkY1;
    public int ShiftX, ShiftY;
    public int MarginL, MarginR, MarginT, MarginB;
    public int BorderHits;
    public string HitSides;
    public int AvoidedFromHits;
    public int MinClearancePx;
    public bool FoundInk;
}

public static class MangaTypesetAuditorV5 {
    static bool DetectBubbleCavityCenter(byte[] cBuf, int cStride, int W, int H, BlockSpec[] specs, int selfIdx, out int cavCx, out int cavCy) {
        cavCx = 0; cavCy = 0;
        var s = specs[selfIdx];
        int seedX = Math.Max(0, Math.Min(W - 1, s.X + s.W / 2));
        int seedY = Math.Max(0, Math.Min(H - 1, s.Y + s.H / 2));
        int sp = seedY * cStride + (seedX << 2);
        int sb = cBuf[sp], sg = cBuf[sp + 1], sr = cBuf[sp + 2];
        int seedLum = (sr + sg + sb) / 3;
        if (!s.IsDarkBg && seedLum < 165) return false;
        if (s.IsDarkBg && seedLum > 95) return false;

        int padX = Math.Max(s.W, (int)Math.Round(W * 0.18));
        int padY = Math.Max(s.H, (int)Math.Round(H * 0.18));
        int wx0 = Math.Max(0, seedX - padX);
        int wy0 = Math.Max(0, seedY - padY);
        int wx1 = Math.Min(W - 1, seedX + padX);
        int wy1 = Math.Min(H - 1, seedY + padY);
        int ww = wx1 - wx0 + 1, wh = wy1 - wy0 + 1;
        if (ww < 16 || wh < 16) return false;

        bool[] reach = new bool[ww * wh];
        var q = new Queue<int>(ww * 4);
        int lSx = seedX - wx0, lSy = seedY - wy0;
        reach[lSy * ww + lSx] = true;
        q.Enqueue(lSy * ww + lSx);

        int tol2 = 24 * 24;
        int maxArea = (int)(W * H * 0.13);
        int area = 0;
        int minX = ww, minY = wh, maxX = -1, maxY = -1;
        bool leakL = false, leakR = false, leakT = false, leakB = false;
        int[] dxs = { 1, -1, 0, 0 };
        int[] dys = { 0, 0, 1, -1 };

        while (q.Count > 0) {
            int p = q.Dequeue();
            int px = p % ww, py = p / ww;
            area++;
            if (area > maxArea) return false;
            if (px < minX) minX = px; if (px > maxX) maxX = px;
            if (py < minY) minY = py; if (py > maxY) maxY = py;
            if (px == 0 && wx0 > 0) leakL = true;
            if (px == ww - 1 && wx1 < W - 1) leakR = true;
            if (py == 0 && wy0 > 0) leakT = true;
            if (py == wh - 1 && wy1 < H - 1) leakB = true;

            for (int k = 0; k < 4; k++) {
                int nx = px + dxs[k], ny = py + dys[k];
                if (nx < 0 || nx >= ww || ny < 0 || ny >= wh) continue;
                int ni = ny * ww + nx;
                if (reach[ni]) continue;
                int cp = (wy0 + ny) * cStride + ((wx0 + nx) << 2);
                int dr = cBuf[cp + 2] - sr, dg = cBuf[cp + 1] - sg, db = cBuf[cp] - sb;
                if (dr * dr + dg * dg + db * db <= tol2) {
                    reach[ni] = true;
                    q.Enqueue(ni);
                }
            }
        }

        // Open background leak check: if cavity escapes out >= 2 interior window borders, it is not an enclosed bubble
        int leaks = (leakL ? 1 : 0) + (leakR ? 1 : 0) + (leakT ? 1 : 0) + (leakB ? 1 : 0);
        if (leaks >= 2) return false;
        int cavW = maxX - minX + 1, cavH = maxY - minY + 1;
        if (cavW > Math.Max(s.W * 2.6, W * 0.42) || cavH > Math.Max(s.H * 2.6, H * 0.42)) return false;

        // Check if another optical-centered bubble block shares this exact connected cavity (double-lobed snowman bubble)
        for (int j = 0; j < specs.Length; j++) {
            if (j == selfIdx) continue;
            var o = specs[j];
            if (!o.OpticalCenter || o.HasStroke) continue;
            int ocx = o.X + o.W / 2, ocy = o.Y + o.H / 2;
            if (ocx >= wx0 && ocx <= wx1 && ocy >= wy0 && ocy <= wy1) {
                if (reach[(ocy - wy0) * ww + (ocx - wx0)]) return false;
            }
        }

        // Crop to tight bbox of reach for fast 2-pass Chamfer 3-4 Distance Transform
        int bx0 = Math.Max(0, minX - 1), by0 = Math.Max(0, minY - 1);
        int bx1 = Math.Min(ww - 1, maxX + 1), by1 = Math.Min(wh - 1, maxY + 1);
        int bw = bx1 - bx0 + 1, bh = by1 - by0 + 1;
        const int INF = 1000000;
        int[] dist = new int[bw * bh];
        for (int y = 0; y < bh; y++) {
            int row = y * bw;
            int rRow = (by0 + y) * ww + bx0;
            for (int x = 0; x < bw; x++) {
                bool inside = reach[rRow + x];
                bool atEdge = (x == 0 || y == 0 || x == bw - 1 || y == bh - 1);
                dist[row + x] = (!inside || atEdge) ? 0 : INF;
            }
        }
        for (int y = 1; y < bh - 1; y++) {
            int row = y * bw, up = (y - 1) * bw;
            for (int x = 1; x < bw - 1; x++) {
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
        int maxD = 0;
        for (int y = bh - 2; y >= 1; y--) {
            int row = y * bw, dn = (y + 1) * bw;
            for (int x = bw - 2; x >= 1; x--) {
                int idx = row + x;
                if (dist[idx] == 0) continue;
                int d = dist[idx];
                int c1 = dist[idx + 1] + 3; if (c1 < d) d = c1;
                int c2 = dist[dn + x] + 3; if (c2 < d) d = c2;
                int c3 = dist[dn + x - 1] + 4; if (c3 < d) d = c3;
                int c4 = dist[dn + x + 1] + 4; if (c4 < d) d = c4;
                dist[idx] = d;
                if (d > maxD) maxD = d;
            }
        }
        if (maxD <= 6) return false;
        int coreThresh = (int)Math.Round(maxD * 0.72);
        double sumX = 0, sumY = 0, sumW = 0;
        for (int y = 1; y < bh - 1; y++) {
            int row = y * bw;
            for (int x = 1; x < bw - 1; x++) {
                int d = dist[row + x];
                if (d >= coreThresh) {
                    double wt = (double)d * d;
                    sumX += (wx0 + bx0 + x) * wt;
                    sumY += (wy0 + by0 + y) * wt;
                    sumW += wt;
                }
            }
        }
        if (sumW <= 0) return false;
        cavCx = (int)Math.Round(sumX / sumW);
        cavCy = (int)Math.Round(sumY / sumW);
        return true;
    }

    static int CountHitsAtShift(byte[] cBuf, int cStride, byte[] tBuf, int tStride, int W, int H,
        int ix0, int iy0, int ix1, int iy1, int shiftX, int shiftY, Func<int, int, bool> inOther, int padCheck) {
        int hits = 0;
        for (int y = iy0; y <= iy1; y += 2) {
            int ny = y + shiftY; if (ny < 0 || ny >= H) continue;
            int tRow = y * tStride;
            for (int x = ix0; x <= ix1; x += 2) {
                if (inOther(x, y)) continue;
                if (tBuf[tRow + (x << 2) + 3] < 90) continue;
                int nx = x + shiftX; if (nx < 0 || nx >= W) continue;
                bool nearDark = false;
                for (int oy = -padCheck; oy <= padCheck && !nearDark; oy += padCheck) {
                    int cy = ny + oy; if (cy < 0 || cy >= H) continue;
                    int cRow = cy * cStride;
                    for (int ox = -padCheck; ox <= padCheck && !nearDark; ox += padCheck) {
                        int cx = nx + ox; if (cx < 0 || cx >= W) continue;
                        int cp = cRow + (cx << 2);
                        int lum = (cBuf[cp] + cBuf[cp + 1] + cBuf[cp + 2]) / 3;
                        if (lum <= 95) nearDark = true;
                    }
                }
                if (nearDark) hits++;
            }
        }
        return hits;
    }

    public static BlockAudit[] ProcessAndAudit(Bitmap cleanBmp, Bitmap textBmp, BlockSpec[] specs, Bitmap outTextBmp, string auditOverlayPath) {
        int W = textBmp.Width, H = textBmp.Height;
        var rectFull = new Rectangle(0, 0, W, H);

        var bdText = textBmp.LockBits(rectFull, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        int tStride = bdText.Stride;
        byte[] tBuf = new byte[tStride * H];
        Marshal.Copy(bdText.Scan0, tBuf, 0, tBuf.Length);
        textBmp.UnlockBits(bdText);

        var bdClean = cleanBmp.LockBits(rectFull, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        int cStride = bdClean.Stride;
        byte[] cBuf = new byte[cStride * H];
        Marshal.Copy(bdClean.Scan0, cBuf, 0, cBuf.Length);
        cleanBmp.UnlockBits(bdClean);

        byte[] outBuf = (byte[])tBuf.Clone();
        var results = new BlockAudit[specs.Length];

        // Precompute non-overlapping ownership rectangles for safe optical shifting
        var searchRects = new Rectangle[specs.Length];
        for (int i = 0; i < specs.Length; i++) {
            var s = specs[i];
            int pad = Math.Max(14, (int)Math.Round(W * 0.012));
            int sx0 = Math.Max(0, s.X - pad);
            int sy0 = Math.Max(0, s.Y - pad);
            int sx1 = Math.Min(W - 1, s.X + s.W - 1 + pad);
            int sy1 = Math.Min(H - 1, s.Y + s.H - 1 + pad);
            for (int j = 0; j < specs.Length; j++) {
                if (i == j) continue;
                var o = specs[j];
                int ox0 = o.X, oy0 = o.Y, ox1 = o.X + o.W - 1, oy1 = o.Y + o.H - 1;
                if (sx1 < ox0 || sx0 > ox1 || sy1 < oy0 || sy0 > oy1) continue;
                int midX = (s.X + s.W / 2);
                int oMidX = (o.X + o.W / 2);
                int midY = (s.Y + s.H / 2);
                int oMidY = (o.Y + o.H / 2);
                int sepX = Math.Abs(midX - oMidX);
                int sepY = Math.Abs(midY - oMidY);
                if (sepX >= sepY) {
                    if (oMidX > midX) sx1 = Math.Min(sx1, Math.Max(s.X + s.W - 1, ox0 - 1));
                    else sx0 = Math.Max(sx0, Math.Min(s.X, ox1 + 1));
                } else {
                    if (oMidY > midY) sy1 = Math.Min(sy1, Math.Max(s.Y + s.H - 1, oy0 - 1));
                    else sy0 = Math.Max(sy0, Math.Min(s.Y, oy1 + 1));
                }
            }
            searchRects[i] = Rectangle.FromLTRB(sx0, sy0, Math.Max(sx0, sx1), Math.Max(sy0, sy1));
        }

        Func<int, int, int, bool> inOtherBlock = (px, py, selfIdx) => {
            for (int j = 0; j < specs.Length; j++) {
                if (j == selfIdx) continue;
                var o = specs[j];
                if (px >= o.X && px < o.X + o.W && py >= o.Y && py < o.Y + o.H) return true;
            }
            return false;
        };

        int padCheck = Math.Max(2, (int)Math.Round(W * 0.002));

        for (int i = 0; i < specs.Length; i++) {
            var s = specs[i];
            var sr = searchRects[i];
            int boxCx = s.X + s.W / 2;
            int boxCy = s.Y + s.H / 2;
            int tCx = boxCx, tCy = boxCy;
            int ix0 = W, iy0 = H, ix1 = -1, iy1 = -1;

            for (int y = sr.Top; y <= sr.Bottom; y++) {
                int row = y * tStride;
                for (int x = sr.Left; x <= sr.Right; x++) {
                    if (inOtherBlock(x, y, i)) continue;
                    byte a = tBuf[row + (x << 2) + 3];
                    if (a >= 28) {
                        if (x < ix0) ix0 = x; if (x > ix1) ix1 = x;
                        if (y < iy0) iy0 = y; if (y > iy1) iy1 = y;
                    }
                }
            }

            var au = new BlockAudit();
            au.Id = s.Id;
            au.TargetCx = tCx;
            au.TargetCy = tCy;

            if (ix1 < ix0 || iy1 < iy0) {
                au.FoundInk = false;
                results[i] = au;
                continue;
            }
            au.FoundInk = true;
            int inkCx = (ix0 + ix1) / 2;
            int inkCy = (iy0 + iy1) / 2;

            // Detect true enclosed bubble cavity optical center from cleanBmp
            int cavCx = 0, cavCy = 0;
            bool hasCav = false;
            if (s.OpticalCenter && !s.HasStroke) {
                hasCav = DetectBubbleCavityCenter(cBuf, cStride, W, H, specs, i, out cavCx, out cavCy);
                if (hasCav) {
                    au.HasCavity = true;
                    au.CavCx = cavCx;
                    au.CavCy = cavCy;
                    if (s.SnapToBubble) {
                        int maxSnapX = Math.Max(32, (int)Math.Round(s.W * 0.55));
                        int maxSnapY = Math.Max(32, (int)Math.Round(s.H * 0.55));
                        if (Math.Abs(cavCx - boxCx) <= maxSnapX && Math.Abs(cavCy - boxCy) <= maxSnapY) {
                            tCx = cavCx;
                            tCy = cavCy;
                            au.TargetCx = tCx;
                            au.TargetCy = tCy;
                        }
                    }
                }
            }

            int dx = tCx - inkCx;
            int dy = tCy - inkCy;
            int maxShiftX = Math.Max(28, (int)Math.Round(s.W * 0.55));
            int maxShiftY = Math.Max(28, (int)Math.Round(s.H * 0.55));
            int avoidedFrom = 0;

            if (s.OpticalCenter && Math.Abs(dx) <= maxShiftX && Math.Abs(dy) <= maxShiftY) {
                // Collision-safe refinement: if target position touches dark border/rays, search minimal nudge to 0 hits
                Func<int, int, bool> inOtherSelf = (px, py) => inOtherBlock(px, py, i);
                if (!s.HasStroke && !s.IsDarkBg) {
                    int baseHits = CountHitsAtShift(cBuf, cStride, tBuf, tStride, W, H, ix0, iy0, ix1, iy1, dx, dy, inOtherSelf, padCheck);
                    if (baseHits > 0) {
                        int bestDx = dx, bestDy = dy, bestHits = baseHits;
                        int maxRad = Math.Max(22, Math.Min(96, (int)Math.Round(s.FontSize * 1.15)));
                        int radStep = Math.Max(2, maxRad / 18);
                        int[,] dirs = { {0,1}, {0,-1}, {1,0}, {-1,0}, {1,1}, {1,-1}, {-1,1}, {-1,-1} };
                        for (int rad = radStep; rad <= maxRad && bestHits > 0; rad += radStep) {
                            for (int dIdx = 0; dIdx < 8; dIdx++) {
                                int cdx = dx + dirs[dIdx, 0] * rad;
                                int cdy = dy + dirs[dIdx, 1] * rad;
                                if (Math.Abs(cdx) > maxShiftX + maxRad || Math.Abs(cdy) > maxShiftY + maxRad) continue;
                                int h2 = CountHitsAtShift(cBuf, cStride, tBuf, tStride, W, H, ix0, iy0, ix1, iy1, cdx, cdy, inOtherSelf, padCheck);
                                if (h2 < bestHits) { bestHits = h2; bestDx = cdx; bestDy = cdy; if (h2 == 0) break; }
                            }
                        }
                        if (bestHits < baseHits) {
                            // Fine binary/step polish back toward target along winning vector
                            int stepBackX = Math.Sign(dx - bestDx), stepBackY = Math.Sign(dy - bestDy);
                            if (bestHits == 0 && radStep > 2) {
                                for (int pStep = 0; pStep < radStep; pStep++) {
                                    int ndx = bestDx + stepBackX * 2;
                                    int ndy = bestDy + stepBackY * 2;
                                    if ((ndx == dx && ndy == dy) || (Math.Abs(ndx - dx) > Math.Abs(bestDx - dx)) || (Math.Abs(ndy - dy) > Math.Abs(bestDy - dy))) break;
                                    if (CountHitsAtShift(cBuf, cStride, tBuf, tStride, W, H, ix0, iy0, ix1, iy1, ndx, ndy, inOtherSelf, padCheck) == 0) {
                                        bestDx = ndx; bestDy = ndy;
                                    } else break;
                                }
                            }
                            avoidedFrom = baseHits;
                            dx = bestDx; dy = bestDy;
                        }
                    }
                }

                if (dx != 0 || dy != 0) {
                    int bx0 = Math.Max(sr.Left, ix0 - 2);
                    int by0 = Math.Max(sr.Top, iy0 - 2);
                    int bx1 = Math.Min(sr.Right, ix1 + 2);
                    int by1 = Math.Min(sr.Bottom, iy1 + 2);
                    for (int y = by0; y <= by1; y++) {
                        int row = y * tStride;
                        for (int x = bx0; x <= bx1; x++) {
                            if (inOtherBlock(x, y, i)) continue;
                            int p = row + (x << 2);
                            outBuf[p] = 0; outBuf[p + 1] = 0; outBuf[p + 2] = 0; outBuf[p + 3] = 0;
                        }
                    }
                    for (int y = by0; y <= by1; y++) {
                        int ny = y + dy;
                        if (ny < 0 || ny >= H) continue;
                        int sRow = y * tStride;
                        int dRow = ny * tStride;
                        for (int x = bx0; x <= bx1; x++) {
                            if (inOtherBlock(x, y, i)) continue;
                            int nx = x + dx;
                            if (nx < 0 || nx >= W) continue;
                            int sp = sRow + (x << 2);
                            byte sa = tBuf[sp + 3];
                            if (sa == 0) continue;
                            int dp = dRow + (nx << 2);
                            if (sa >= outBuf[dp + 3]) {
                                outBuf[dp] = tBuf[sp];
                                outBuf[dp + 1] = tBuf[sp + 1];
                                outBuf[dp + 2] = tBuf[sp + 2];
                                outBuf[dp + 3] = sa;
                            }
                        }
                    }
                    ix0 += dx; ix1 += dx; iy0 += dy; iy1 += dy;
                    au.ShiftX = dx;
                    au.ShiftY = dy;
                }
            }
            au.AvoidedFromHits = avoidedFrom;

            au.InkX0 = ix0; au.InkY0 = iy0; au.InkX1 = ix1; au.InkY1 = iy1;
            au.MarginL = ix0 - s.X;
            au.MarginR = (s.X + s.W - 1) - ix1;
            au.MarginT = iy0 - s.Y;
            au.MarginB = (s.Y + s.H - 1) - iy1;
            if (hasCav) {
                au.OffCenterX = ((ix0 + ix1) / 2) - cavCx;
                au.OffCenterY = ((iy0 + iy1) / 2) - cavCy;
            }

            // Border-collision & breathing-clearance audit for non-stroked regular bubble text on light/grey backgrounds
            int hits = 0;
            int hitT = 0, hitB = 0, hitL = 0, hitR = 0;
            int minClear = -1;
            if (!s.HasStroke && !s.IsDarkBg) {
                int cxSample = Math.Max(0, Math.Min(W - 1, (ix0 + ix1) / 2));
                int cySample = Math.Max(0, Math.Min(H - 1, (iy0 + iy1) / 2));
                int ci = cySample * cStride + (cxSample << 2);
                int bgLum = (cBuf[ci] + cBuf[ci + 1] + cBuf[ci + 2]) / 3;
                if (bgLum >= 165) {
                    int ay0 = Math.Max(0, iy0), ay1 = Math.Min(H - 1, iy1);
                    int ax0 = Math.Max(0, ix0), ax1 = Math.Min(W - 1, ix1);
                    int inkW = Math.Max(1, ax1 - ax0 + 1);
                    int inkH = Math.Max(1, ay1 - ay0 + 1);
                    int maxProbe = hasCav ? Math.Max(8, (int)Math.Round(s.FontSize * 0.40)) : 0;
                    int[,] rays = { {1,0}, {-1,0}, {0,1}, {0,-1}, {1,1}, {-1,1}, {1,-1}, {-1,-1} };
                    for (int y = ay0; y <= ay1; y += 2) {
                        int tRow = y * tStride;
                        for (int x = ax0; x <= ax1; x += 2) {
                            if (outBuf[tRow + (x << 2) + 3] < 90) continue;
                            bool nearDark = false;
                            for (int oy = -padCheck; oy <= padCheck && !nearDark; oy += padCheck) {
                                int ny = y + oy; if (ny < 0 || ny >= H) continue;
                                int cRow = ny * cStride;
                                for (int ox = -padCheck; ox <= padCheck && !nearDark; ox += padCheck) {
                                    int nx = x + ox; if (nx < 0 || nx >= W) continue;
                                    int cp = cRow + (nx << 2);
                                    int lum = (cBuf[cp] + cBuf[cp + 1] + cBuf[cp + 2]) / 3;
                                    if (lum <= 95) nearDark = true;
                                }
                            }
                            if (nearDark) {
                                hits++;
                                double ry = (y - ay0) / (double)inkH;
                                double rx = (x - ax0) / (double)inkW;
                                if (ry < 0.35) hitT++;
                                else if (ry > 0.65) hitB++;
                                if (rx < 0.35) hitL++;
                                else if (rx > 0.65) hitR++;
                            } else if (maxProbe > 0 && hits == 0) {
                                // Only probe perimeter ink pixels to measure clearance to bubble wall fast
                                bool isEdge = (x <= ax0 + 1 || x >= ax1 - 1 || y <= ay0 + 1 || y >= ay1 - 1) ||
                                    (x >= 2 && outBuf[tRow + ((x - 2) << 2) + 3] < 40) ||
                                    (x + 2 < W && outBuf[tRow + ((x + 2) << 2) + 3] < 40) ||
                                    (y >= 2 && outBuf[(y - 2) * tStride + (x << 2) + 3] < 40) ||
                                    (y + 2 < H && outBuf[(y + 2) * tStride + (x << 2) + 3] < 40);
                                if (isEdge) {
                                    int lim = (minClear >= 0) ? Math.Min(maxProbe, minClear) : maxProbe;
                                    for (int rIdx = 0; rIdx < 8; rIdx++) {
                                        int rx = rays[rIdx, 0], ry = rays[rIdx, 1];
                                        double stepScale = (rx != 0 && ry != 0) ? 1.4142 : 1.0;
                                        for (int d = padCheck + 1; d * stepScale <= lim; d++) {
                                            int nx = x + rx * d, ny = y + ry * d;
                                            if (nx < 0 || nx >= W || ny < 0 || ny >= H) break;
                                            int cp = ny * cStride + (nx << 2);
                                            int lum = (cBuf[cp] + cBuf[cp + 1] + cBuf[cp + 2]) / 3;
                                            if (lum <= 95) {
                                                int distPx = (int)Math.Round(d * stepScale);
                                                if (minClear < 0 || distPx < minClear) {
                                                    minClear = distPx;
                                                    lim = Math.Min(lim, minClear);
                                                }
                                                break;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            au.BorderHits = hits;
            if (hits > 0) {
                var sideParts = new List<string>();
                if (hitT > 0) sideParts.Add("T:" + hitT);
                if (hitB > 0) sideParts.Add("B:" + hitB);
                if (hitL > 0) sideParts.Add("L:" + hitL);
                if (hitR > 0) sideParts.Add("R:" + hitR);
                au.HitSides = (sideParts.Count > 0) ? string.Join(",", sideParts.ToArray()) : "C";
            } else {
                au.HitSides = "";
            }
            au.MinClearancePx = (hits > 0) ? 0 : minClear;
            results[i] = au;
        }

        var bdOut = outTextBmp.LockBits(rectFull, ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        Marshal.Copy(outBuf, 0, bdOut.Scan0, outBuf.Length);
        outTextBmp.UnlockBits(bdOut);

        if (!string.IsNullOrEmpty(auditOverlayPath)) {
            int ovW = Math.Min(W, 1000);
            int ovH = (int)Math.Round(H * (ovW / (double)W));
            double sc = ovW / (double)W;
            using (var ov = new Bitmap(ovW, ovH, PixelFormat.Format24bppRgb))
            using (var g = Graphics.FromImage(ov)) {
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.DrawImage(cleanBmp, 0, 0, ovW, ovH);
                g.DrawImage(outTextBmp, 0, 0, ovW, ovH);
                using (var penTarget = new Pen(Color.FromArgb(180, 0, 190, 90), 1.5f))
                using (var penInk = new Pen(Color.FromArgb(220, 235, 30, 30), 1.5f))
                using (var penCross = new Pen(Color.FromArgb(230, 0, 140, 255), 1.5f))
                using (var penCav = new Pen(Color.FromArgb(240, 210, 0, 210), 2.0f))
                using (var font = new Font("Arial", 9, FontStyle.Bold))
                using (var br = new SolidBrush(Color.FromArgb(220, 255, 255, 255)))
                using (var brTxt = new SolidBrush(Color.FromArgb(230, 200, 0, 0))) {
                    penTarget.DashStyle = DashStyle.Dash;
                    for (int i = 0; i < specs.Length; i++) {
                        var s = specs[i]; var au = results[i];
                        g.DrawRectangle(penTarget, (float)(s.X * sc), (float)(s.Y * sc), (float)(s.W * sc), (float)(s.H * sc));
                        float cx = (float)(au.TargetCx * sc), cy = (float)(au.TargetCy * sc);
                        g.DrawLine(penCross, cx - 5, cy, cx + 5, cy);
                        g.DrawLine(penCross, cx, cy - 5, cx, cy + 5);
                        if (au.HasCavity) {
                            float vx = (float)(au.CavCx * sc), vy = (float)(au.CavCy * sc);
                            g.DrawPolygon(penCav, new PointF[] { new PointF(vx, vy - 6), new PointF(vx + 6, vy), new PointF(vx, vy + 6), new PointF(vx - 6, vy) });
                        }
                        if (au.FoundInk) {
                            g.DrawRectangle(penInk, (float)(au.InkX0 * sc), (float)(au.InkY0 * sc), (float)((au.InkX1 - au.InkX0) * sc), (float)((au.InkY1 - au.InkY0) * sc));
                        }
                        bool offWarn = au.HasCavity && (Math.Abs(au.OffCenterX) > 6 || Math.Abs(au.OffCenterY) > 6);
                        string lbl = s.Id + (au.BorderHits > 0 ? "!" : "") + (offWarn ? "*" : "");
                        g.FillRectangle(br, (float)(s.X * sc), Math.Max(0, (float)(s.Y * sc) - 13), 38, 13);
                        g.DrawString(lbl, font, brTxt, (float)(s.X * sc) + 1, Math.Max(0, (float)(s.Y * sc) - 13));
                    }
                }
                ov.Save(auditOverlayPath, ImageFormat.Jpeg);
            }
        }
        return results;
    }
}
'@

if (-not ("MangaTypesetAuditorV5" -as [type])) {
    Add-Type -TypeDefinition $auditorCs -ReferencedAssemblies System.Drawing
}

# Locate headless Edge, Chrome, Brave, or Chromium via shared config resolver
$browser = $mlConfig.BrowserBin
if (-not $browser) { throw "No Edge, Chrome, Brave, or Chromium executable found for headless HTML/CSS rendering. Set MANGA_BROWSER_BIN or browser_bin in ~/.manga-zh-localizer/config.json." }

$imgAbs = (Resolve-Path -LiteralPath $CleanImage).Path
$baseBmp = [System.Drawing.Bitmap]::FromFile($imgAbs)
$W = $baseBmp.Width
$H = $baseBmp.Height

$layout = ([System.IO.File]::ReadAllText($LayoutPath, [System.Text.Encoding]::UTF8)) | ConvertFrom-Json

$fontPresets = @{
    "dialogue"    = @{ family = '"Source Han Sans SC", "Microsoft YaHei", "Microsoft JhengHei", sans-serif'; weight = 700 }
    "narration"   = @{ family = '"Source Han Sans SC", "Microsoft YaHei", "SimHei", sans-serif'; weight = 700 }
    "scream"      = @{ family = '"Source Han Sans SC Heavy", "SimHei", "Microsoft YaHei", sans-serif'; weight = 700 }
    "serif"       = @{ family = '"Source Han Serif SC", "STZhongsong", "STSong", "SimSun", serif'; weight = 400 }
    "handwritten" = @{ family = '"LXGW WenKai", "STKaiti", "KaiTi", "YouYuan", serif'; weight = 400 }
    "round"       = @{ family = '"Source Han Rounded SC", "YouYuan", "Microsoft YaHei", sans-serif'; weight = 400 }
    "brush"       = @{ family = '"STXingkai", "FZShuTi", "STKaiti", serif'; weight = 400 }
    "note"        = @{ family = '"Microsoft YaHei", sans-serif'; weight = 400 }
}

# Pure ASCII Unicode escape regexes for vertical punctuation & tate-chu-yoko
$cInterrobang = [string][char]0x2049
$cDoubleExcl  = [string][char]0x203C
$cFwExcl      = [string][char]0xFF01
$cFwQuest     = [string][char]0xFF1F
$tcyPattern = '(' + [regex]::Escape($cInterrobang) + '|' + [regex]::Escape($cDoubleExcl) + '|' + [regex]::Escape($cFwExcl + $cFwQuest) + '|' + [regex]::Escape($cFwQuest + $cFwExcl) + '|!\?|!!|\?!)'

$cEllip = [string][char]0x2026
$cVertEllip = [string][char]0xFE19
$cEmDash = [string][char]0x2014
$cVertDash = [string][char]0xFE31
$cWaveFw = [string][char]0xFF5E
$cWaveJp = [string][char]0x301C
$wavePattern = '(' + [regex]::Escape($cWaveFw) + '|' + [regex]::Escape($cWaveJp) + '|~)'
$rotChars = -join @(
    [char]0x300C, [char]0x300D, [char]0x300E, [char]0x300F,
    [char]0xFF08, [char]0xFF09, [char]0x3010, [char]0x3011,
    [char]0x300A, [char]0x300B, [char]0x3008, [char]0x3009
)
$rotPattern = '([' + [regex]::Escape($rotChars) + ']+)'
$latinPattern = "[A-Za-z]{2,}(?:[ \-'\.][A-Za-z0-9]+)*"
$vertTokenPattern = "(?<ellip>" + [regex]::Escape($cEllip) + ")|(?<dash>" + [regex]::Escape($cEmDash) + ")|(?<wave>" + $wavePattern + ")|(?<tcy>" + $tcyPattern + ")|(?<latin>" + $latinPattern + ")|(?<rot>" + $rotPattern + ")"

function Escape-Html([string]$s) {
    return $s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('"', "&quot;")
}

function Format-VerticalText([string]$text) {
    $sb = New-Object System.Text.StringBuilder
    $pos = 0
    foreach ($m in [regex]::Matches($text, $vertTokenPattern)) {
        if ($m.Index -gt $pos) {
            [void]$sb.Append((Escape-Html $text.Substring($pos, $m.Index - $pos)))
        }
        if ($m.Groups['ellip'].Success) {
            [void]$sb.Append('<span class="vellip">' + $cVertEllip + '</span>')
        } elseif ($m.Groups['dash'].Success) {
            [void]$sb.Append('<span class="vdash">' + $cVertDash + '</span>')
        } elseif ($m.Groups['wave'].Success) {
            [void]$sb.Append('<span class="vwave">' + $cWaveFw + '</span>')
        } elseif ($m.Groups['tcy'].Success) {
            [void]$sb.Append('<span class="tcy">' + (Escape-Html $m.Value) + '</span>')
        } elseif ($m.Groups['latin'].Success) {
            [void]$sb.Append('<span class="latin">' + (Escape-Html $m.Value) + '</span>')
        } elseif ($m.Groups['rot'].Success) {
            [void]$sb.Append('<span class="rot">' + (Escape-Html $m.Value) + '</span>')
        }
        $pos = $m.Index + $m.Length
    }
    if ($pos -lt $text.Length) {
        [void]$sb.Append((Escape-Html $text.Substring($pos)))
    }
    return $sb.ToString()
}

function Build-RoundStrokeCss([double]$r, [string]$color, [string]$extraShadow = "") {
    $parts = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt 24; $i++) {
        $ang = 2.0 * [Math]::PI * $i / 24.0
        $ox = [Math]::Round([Math]::Cos($ang) * $r, 2)
        $oy = [Math]::Round([Math]::Sin($ang) * $r, 2)
        $parts.Add("${ox}px ${oy}px 0 $color")
    }
    if ($r -ge 1.8) {
        $rMid = [Math]::Round($r * 0.55, 2)
        for ($i = 0; $i -lt 12; $i++) {
            $ang = 2.0 * [Math]::PI * $i / 12.0
            $ox = [Math]::Round([Math]::Cos($ang) * $rMid, 2)
            $oy = [Math]::Round([Math]::Sin($ang) * $rMid, 2)
            $parts.Add("${ox}px ${oy}px 0 $color")
        }
    }
    if ($r -ge 4.0) {
        $rIn = [Math]::Round($r * 0.28, 2)
        for ($i = 0; $i -lt 8; $i++) {
            $ang = 2.0 * [Math]::PI * $i / 8.0
            $ox = [Math]::Round([Math]::Cos($ang) * $rIn, 2)
            $oy = [Math]::Round([Math]::Sin($ang) * $rIn, 2)
            $parts.Add("${ox}px ${oy}px 0 $color")
        }
    }
    if ($extraShadow) { $parts.Add($extraShadow) }
    return "text-shadow: " + ($parts -join ", ") + ";"
}

$outDir = Split-Path -Parent $OutputPath
if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$tmpDir = Join-Path $mlConfig.TmpDir "_render_tmp"
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
$runTag = [guid]::NewGuid().ToString("N").Substring(0,8)
$ephemeralHtml = $false
if (-not $HtmlOut) {
    $HtmlOut = Join-Path $tmpDir ("typeset_layer_" + $runTag + ".html")
    $ephemeralHtml = $true
}

$scale = [Math]::Max(1, [Math]::Min(3, $SuperSample))
$winW = $W + 180
$winH = $H + 200

$cssBlocks = New-Object System.Text.StringBuilder
$htmlBlocks = New-Object System.Text.StringBuilder
$specList = New-Object System.Collections.Generic.List[BlockSpec]

$idx = 0
foreach ($blk in $layout.blocks) {
    $idx++
    if ($blk.skip -eq $true) { continue }
    $id = if ($blk.id) { "b_$($blk.id)" } else { "b_$idx" }
    $dir = if ($blk.direction) { [string]$blk.direction } else { "vertical" }
    $isVert = ($dir -ne "horizontal")

    $x = [int]$blk.rect[0]; $y = [int]$blk.rect[1]; $bw = [int]$blk.rect[2]; $bh = [int]$blk.rect[3]
    $presetKey = if ($blk.preset -and $fontPresets.ContainsKey([string]$blk.preset)) { [string]$blk.preset } else { "dialogue" }
    $presetDef = $fontPresets[$presetKey]
    $fontFamily = if ($blk.font_family) { [string]$blk.font_family } else { $presetDef.family }
    $fontSize = if ($blk.font_size) { [double]$blk.font_size } else { [Math]::Round($W * 0.024, 1) }
    $fontWeight = if ($null -ne $blk.font_weight) { [int]$blk.font_weight } else { $presetDef.weight }
    $lineHeight = if ($blk.line_height) { [double]$blk.line_height } else { 1.30 }
    $letterSpacing = if ($null -ne $blk.letter_spacing) { [double]$blk.letter_spacing } else { 0 }
    $color = if ($blk.color) { [string]$blk.color } else { "#111111" }
    $valign = if ($blk.align -eq "top") { "top" } else { "center" }
    $halign = if ($blk.halign) { [string]$blk.halign } else { "center" }
    $autoFit = if ($null -ne $blk.auto_fit) { [bool]$blk.auto_fit } else { $true }
    $minFont = if ($blk.min_font_size) { [double]$blk.min_font_size } else { [Math]::Max(13.0, [Math]::Round($fontSize * 0.85, 1)) }

    $optCenter = $false
    if ($null -ne $blk.optical_center) {
        $optCenter = [bool]$blk.optical_center
    } elseif ($AutoOpticalCenter.IsPresent -and $valign -ne "top") {
        $optCenter = $true
    }

    $snapToBubble = $optCenter
    if ($null -ne $blk.snap_to_bubble) {
        $snapToBubble = [bool]$blk.snap_to_bubble
    }

    $sp = New-Object BlockSpec
    $sp.Id = $id; $sp.X = $x; $sp.Y = $y; $sp.W = $bw; $sp.H = $bh
    $sp.FontSize = $fontSize
    $sp.OpticalCenter = $optCenter
    $sp.SnapToBubble = $snapToBubble
    $sp.HasStroke = ($null -ne $blk.stroke -or $null -ne $blk.halo)
    $sp.IsDarkBg = ($color -match '^#f|^#e|white')
    $specList.Add($sp)

    $justifyCss = switch ($halign) {
        "left"  { "flex-start" }
        "right" { "flex-end" }
        default { "center" }
    }
    $alignCss = if ($valign -eq "top") { "flex-start" } else { "center" }

    $strokeCss = ""
    if ($blk.stroke) {
        $sc = if ($blk.stroke.color) { [string]$blk.stroke.color } else { "#ffffff" }
        $sw = if ($blk.stroke.width) { [double]$blk.stroke.width } else { 2.0 }
        $style = if ($blk.stroke.style) { [string]$blk.stroke.style } else { "round" }
        if ($style -eq "miter") {
            $sw2 = [Math]::Round($sw * 2.0, 2)
            $strokeCss = "-webkit-text-stroke: ${sw2}px $sc; paint-order: stroke fill;"
        } else {
            $strokeCss = Build-RoundStrokeCss $sw $sc
        }
    } elseif ($blk.halo) {
        $hc = if ($blk.halo -is [string]) { $blk.halo } else { "rgba(255, 255, 255, 0.92)" }
        $hr = [Math]::Max(1.8, [Math]::Round($W * 0.0022, 2))
        $glow = [Math]::Max(3.0, [Math]::Round($hr * 1.6, 1))
        $strokeCss = Build-RoundStrokeCss $hr $hc "0 0 ${glow}px $hc"
    }

    $rotCss = if ($blk.rotate) { "transform: rotate($($blk.rotate)deg);" } else { "" }
    $modeClass = if ($isVert) { "vinner" } else { "hinner" }

    [void]$cssBlocks.AppendLine("  #$id { left: ${x}px; top: ${y}px; width: ${bw}px; height: ${bh}px; align-items: $alignCss; justify-content: $justifyCss; }")
    [void]$cssBlocks.AppendLine("  #$id .$modeClass { font-family: $fontFamily; font-size: ${fontSize}px; font-weight: $fontWeight; line-height: $lineHeight; letter-spacing: ${letterSpacing}px; color: $color; $strokeCss $rotCss }")

    if ($blk.col_offsets) {
        for ($ci = 0; $ci -lt $blk.col_offsets.Count; $ci++) {
            $off = [double]$blk.col_offsets[$ci]
            if ($off -ne 0) {
                $prop = if ($isVert) { "padding-top" } else { "padding-left" }
                [void]$cssBlocks.AppendLine("  #$id .col:nth-child($($ci + 1)) { ${prop}: ${off}px; }")
            }
        }
    }

    $innerHtml = New-Object System.Text.StringBuilder
    if ($blk.lines) {
        $arr = @($blk.lines)
        if ($arr.Count -eq 1) {
            $fmt = if ($isVert) { Format-VerticalText ([string]$arr[0]) } else { Escape-Html ([string]$arr[0]) }
            [void]$innerHtml.Append($fmt)
        } else {
            foreach ($ln in $arr) {
                $fmt = if ($isVert) { Format-VerticalText ([string]$ln) } else { Escape-Html ([string]$ln) }
                [void]$innerHtml.Append("<span class=`"col`">$fmt</span>")
            }
        }
    } elseif ($blk.text) {
        $arr = ([string]$blk.text) -split "`r?`n"
        if ($arr.Count -eq 1) {
            $fmt = if ($isVert) { Format-VerticalText ([string]$arr[0]) } else { Escape-Html ([string]$arr[0]) }
            [void]$innerHtml.Append($fmt)
        } else {
            foreach ($ln in $arr) {
                $fmt = if ($isVert) { Format-VerticalText ([string]$ln) } else { Escape-Html ([string]$ln) }
                [void]$innerHtml.Append("<span class=`"col`">$fmt</span>")
            }
        }
    }

    $afAttr = if ($autoFit -and (-not $blk.rotate)) { " data-autofit=`"1`" data-minfs=`"$minFont`"" } else { "" }
    [void]$htmlBlocks.AppendLine("  <div id=`"$id`" class=`"box`"$afAttr><div class=`"$modeClass`">$($innerHtml.ToString())</div></div>")
}

$html = @"
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  html, body { width: ${winW}px; height: ${winH}px; overflow: hidden; background: transparent; }
  .page {
    position: relative;
    width: ${W}px;
    height: ${H}px;
    background: transparent;
    font-synthesis: none;
    text-rendering: optimizeLegibility;
    -webkit-font-smoothing: antialiased;
  }
  .box {
    position: absolute;
    display: flex;
    user-select: none;
  }
  .vinner {
    writing-mode: vertical-rl;
    text-orientation: upright;
    font-feature-settings: "vert" 1, "vrt2" 1;
    white-space: nowrap;
  }
  .hinner {
    writing-mode: horizontal-tb;
    text-align: center;
    white-space: nowrap;
  }
  .col { display: block; }
  .tcy { text-combine-upright: all; letter-spacing: -1px; }
  .rot { text-orientation: mixed; }
  .vwave { text-orientation: mixed; font-family: "Microsoft YaHei", "SimSun", sans-serif; }
  .latin { text-orientation: sideways; letter-spacing: 0; margin-inline: 0.08em; }
  .vellip { text-orientation: upright; font-family: "Microsoft YaHei", "SimSun", sans-serif; }
  .vdash { text-orientation: upright; font-family: "Microsoft YaHei", "SimSun", sans-serif; letter-spacing: -0.08em; }
$($cssBlocks.ToString())
</style>
</head>
<body>
<div class="page">
$($htmlBlocks.ToString())
</div>
<script>
document.querySelectorAll('.box[data-autofit="1"]').forEach(box => {
  const inner = box.firstElementChild;
  if (!inner) return;
  const minFs = parseFloat(box.dataset.minfs || '14');
  let fs = parseFloat(getComputedStyle(inner).fontSize);
  const bw = box.clientWidth;
  const bh = box.clientHeight;
  let guard = 0;
  while (guard < 24 && fs > minFs) {
    const r = inner.getBoundingClientRect();
    if (r.width <= bw + 1 && r.height <= bh + 1) break;
    fs = Math.max(minFs, +(fs - 0.5).toFixed(2));
    inner.style.fontSize = fs + 'px';
    guard++;
  }
});
</script>
</body>
</html>
"@

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($HtmlOut, $html, $utf8NoBom)

$rawShot = Join-Path $tmpDir ("_edge_text_layer_" + $runTag + ".png")
$profileDir = Join-Path $tmpDir ("_edge_prof_" + $runTag)
$htmlUri = "file:///" + (((Resolve-Path -LiteralPath $HtmlOut).Path) -replace '\\', '/')

$argsList = @(
    "--headless=new",
    "--disable-gpu",
    "--no-first-run",
    "--no-default-browser-check",
    "--hide-scrollbars",
    "--force-device-scale-factor=$scale",
    "--default-background-color=00000000",
    "--window-size=$winW,$winH",
    "--user-data-dir=`"$profileDir`"",
    "--screenshot=`"$rawShot`"",
    "`"$htmlUri`""
)
try {
    Start-Process -FilePath $browser -ArgumentList $argsList -Wait -NoNewWindow
} finally {
    Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($ephemeralHtml) { Remove-Item -LiteralPath $HtmlOut -Force -ErrorAction SilentlyContinue }
}

if (-not (Test-Path $rawShot)) {
    $baseBmp.Dispose()
    throw "Headless browser failed to render transparent text layer at $rawShot"
}

$rawLayer = [System.Drawing.Bitmap]::FromFile($rawShot)
$srcW = [Math]::Min($rawLayer.Width, $W * $scale)
$srcH = [Math]::Min($rawLayer.Height, $H * $scale)
$cropRect = New-Object System.Drawing.Rectangle(0, 0, $srcW, $srcH)
$hiResLayer = $rawLayer.Clone($cropRect, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$rawLayer.Dispose()
Remove-Item $rawShot -Force -ErrorAction SilentlyContinue

$textLayerRaw = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$gt = [System.Drawing.Graphics]::FromImage($textLayerRaw)
$gt.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
$gt.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$gt.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$gt.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
$gt.DrawImage($hiResLayer, (New-Object System.Drawing.Rectangle(0, 0, $W, $H)), (New-Object System.Drawing.Rectangle(0, 0, $srcW, $srcH)), [System.Drawing.GraphicsUnit]::Pixel)
$gt.Dispose()
$hiResLayer.Dispose()

# LockBits Optical Ink Auto-Centering + Bubble Cavity Snap + Auto-Clearance & Border-Collision Audit
$textLayer = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$audits = [MangaTypesetAuditorV5]::ProcessAndAudit($baseBmp, $textLayerRaw, $specList.ToArray(), $textLayer, $AuditOverlay)
$textLayerRaw.Dispose()

$warnCount = 0
for ($auditIdx = 0; $auditIdx -lt $audits.Length; $auditIdx++) {
    $au = $audits[$auditIdx]
    if (-not $au.FoundInk) {
        Write-Host "[Audit] $($au.Id): NO_INK_FOUND"
        $warnCount++
        continue
    }
    $flag = "OK"
    $specObj = $specList[$auditIdx]
    $tightThresh = [Math]::Max(5, [int][Math]::Round($specObj.FontSize * 0.22))
    if ($au.BorderHits -gt 0) {
        $sideTag = if ($au.HitSides) { "[$($au.HitSides)]" } else { "" }
        $flag = "WARN_BORDER_HITS=$($au.BorderHits)$sideTag"
        $warnCount++
    }
    elseif ($au.HasCavity -and $specObj.SnapToBubble -and ([Math]::Abs($au.OffCenterX) -gt 6 -or [Math]::Abs($au.OffCenterY) -gt 6)) {
        $flag = "WARN_OFFCENTER($($au.OffCenterX),$($au.OffCenterY))"; $warnCount++
    }
    elseif ($au.HasCavity -and $au.MinClearancePx -ge 0 -and $au.MinClearancePx -lt $tightThresh) {
        $flag = "WARN_TIGHT_MARGIN($($au.MinClearancePx)px<$($tightThresh)px)"; $warnCount++
    }
    elseif (-not $au.HasCavity -and $au.AvoidedFromHits -eq 0 -and ($au.MarginL -lt -6 -or $au.MarginR -lt -6 -or $au.MarginT -lt -6 -or $au.MarginB -lt -6)) {
        $flag = "WARN_OVERFLOW"; $warnCount++
    }
    if ($au.AvoidedFromHits -gt 0 -and $au.BorderHits -eq 0) {
        $flag = "$flag (auto-avoided $($au.AvoidedFromHits)->0)"
    }
    $cavStr = if ($au.HasCavity) { "cav=($($au.CavCx),$($au.CavCy)) off=($($au.OffCenterX),$($au.OffCenterY))" } else { "cav=none" }
    $clrStr = if ($au.MinClearancePx -ge 0) { "clear=$($au.MinClearancePx)px" } else { "clear=ok" }
    Write-Host ("[Audit] {0,-6} shift=({1,3},{2,3}) {3,-26} {4,-10} ink=[{5},{6},{7},{8}] {9}" -f $au.Id, $au.ShiftX, $au.ShiftY, $cavStr, $clrStr, $au.InkX0, $au.InkY0, ($au.InkX1-$au.InkX0+1), ($au.InkY1-$au.InkY0+1), $flag)
}

for ($ai = 0; $ai -lt $specList.Count; $ai++) {
    $a = $specList[$ai]
    for ($bi = $ai + 1; $bi -lt $specList.Count; $bi++) {
        $b = $specList[$bi]
        $gapX = [Math]::Max($a.X - ($b.X + $b.W), $b.X - ($a.X + $a.W))
        $gapY = [Math]::Max($a.Y - ($b.Y + $b.H), $b.Y - ($a.Y + $a.H))
        if ($gapX -lt 12 -and $gapY -lt 12) {
            Write-Host "[Audit] $($a.Id) & $($b.Id) WARN_RECT_OVERLAP (gapX=$gapX, gapY=$gapY; keep >=12px apart to prevent extraction-pad ghost clipping)"
            $warnCount++
        }
    }
}

if ($AuditJsonOut) {
    $aJson = $audits | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($AuditJsonOut, $aJson, $utf8NoBom)
}

if ($TextLayerOut) {
    $tlDir = Split-Path -Parent $TextLayerOut
    if ($tlDir) { New-Item -ItemType Directory -Force -Path $tlDir | Out-Null }
    $textLayer.Save($TextLayerOut, [System.Drawing.Imaging.ImageFormat]::Png)
}

$finalBmp = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($finalBmp)
$g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
$g.DrawImage($baseBmp, 0, 0, $W, $H)
$g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
$g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
$g.DrawImage($textLayer, 0, 0, $W, $H)
$g.Dispose()

$finalBmp.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
$finalBmp.Dispose()
$textLayer.Dispose()
$baseBmp.Dispose()

Write-Host "RenderedFinalLosslessV3: $OutputPath (${W}x${H}, ${scale}xSS, warnings=$warnCount)"
