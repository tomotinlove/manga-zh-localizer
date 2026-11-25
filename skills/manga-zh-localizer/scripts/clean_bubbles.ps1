param(
    [Parameter(Mandatory=$true)][string]$ImagePath,
    [Parameter(Mandatory=$true)][string]$PlanPath,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [string]$BoxesOut = "",
    [string]$DiffOut = ""
)

$ErrorActionPreference = "Stop"

$csCode = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class BubbleMetrics {
    public int[] bubble_bbox;
    public int[] optical_center;
    public int[] safe_rect;
    public int[] orig_text_bbox;
    public int[] orig_text_center;
    public string warning;
}

public class FastImg {
    public int W, H, Stride;
    public byte[] Buf;

    public FastImg(Bitmap bmp) {
        W = bmp.Width; H = bmp.Height;
        var rect = new Rectangle(0, 0, W, H);
        var bd = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        Stride = bd.Stride;
        Buf = new byte[Stride * H];
        Marshal.Copy(bd.Scan0, Buf, 0, Buf.Length);
        bmp.UnlockBits(bd);
    }

    public FastImg CloneBuf() {
        var c = (FastImg)MemberwiseClone();
        c.Buf = (byte[])Buf.Clone();
        return c;
    }

    public void GetRgb(int x, int y, out byte r, out byte g, out byte b) {
        int i = y * Stride + (x << 2);
        b = Buf[i]; g = Buf[i + 1]; r = Buf[i + 2];
    }

    public void SetRgb(int x, int y, byte r, byte g, byte b) {
        int i = y * Stride + (x << 2);
        Buf[i] = b; Buf[i + 1] = g; Buf[i + 2] = r; Buf[i + 3] = 255;
    }

    public void SavePng(string path) {
        using (var bmp = new Bitmap(W, H, PixelFormat.Format32bppArgb)) {
            var bd = bmp.LockBits(new Rectangle(0, 0, W, H), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
            Marshal.Copy(Buf, 0, bd.Scan0, Buf.Length);
            bmp.UnlockBits(bd);
            bmp.Save(path, ImageFormat.Png);
        }
    }
}

public static class MangaBubbleCleanerV3 {
    static bool IsWhite(byte r, byte g, byte b, int thresh) {
        return r >= thresh && g >= thresh && b >= thresh;
    }
    static bool IsBlack(byte r, byte g, byte b, int thresh) {
        return r <= thresh && g <= thresh && b <= thresh;
    }
    static bool IsNearColor(byte r, byte g, byte b, byte tr, byte tg, byte tb, int tol2) {
        int dr = r - tr, dg = g - tg, db = b - tb;
        return (dr * dr + dg * dg + db * db) <= tol2;
    }

    static BubbleMetrics ComputeDiffTextMetrics(FastImg before, FastImg after, int x0, int y0, int x1, int y1) {
        int tx0 = before.W, ty0 = before.H, tx1 = -1, ty1 = -1;
        long sumX = 0, sumY = 0, cnt = 0;
        for (int y = y0; y <= y1; y++) {
            for (int x = x0; x <= x1; x++) {
                byte r0, g0, b0, r1, g1, b1;
                before.GetRgb(x, y, out r0, out g0, out b0);
                after.GetRgb(x, y, out r1, out g1, out b1);
                int diff = Math.Abs(r0 - r1) + Math.Abs(g0 - g1) + Math.Abs(b0 - b1);
                if (diff >= 55) {
                    if (x < tx0) tx0 = x; if (x > tx1) tx1 = x;
                    if (y < ty0) ty0 = y; if (y > ty1) ty1 = y;
                    sumX += x; sumY += y; cnt++;
                }
            }
        }
        if (cnt < 6 || tx1 < tx0) return null;
        var m = new BubbleMetrics();
        m.orig_text_bbox = new int[] { tx0, ty0, tx1 - tx0 + 1, ty1 - ty0 + 1 };
        m.orig_text_center = new int[] { (int)Math.Round((tx0 + tx1) * 0.5), (int)Math.Round((ty0 + ty1) * 0.5) };
        m.optical_center = new int[] { (int)Math.Round((double)sumX / cnt), (int)Math.Round((double)sumY / cnt) };
        return m;
    }

    static BubbleMetrics FloodCleanCore(FastImg img, int x0, int y0, int x1, int y1, int seedX, int seedY,
        Func<byte, byte, byte, bool> matchFn, byte fr, byte fg, byte fb, Rectangle[] keepRects, string openSide) {
        int W = img.W, H = img.H;
        x0 = Math.Max(0, x0); y0 = Math.Max(0, y0);
        x1 = Math.Min(W - 1, x1); y1 = Math.Min(H - 1, y1);
        int w = x1 - x0 + 1, h = y1 - y0 + 1;
        int sx = seedX - x0, sy = seedY - y0;
        if (w <= 0 || h <= 0 || sx < 0 || sy < 0 || sx >= w || sy >= h) return null;

        byte sr, sg, sb;
        img.GetRgb(x0 + sx, y0 + sy, out sr, out sg, out sb);
        if (!matchFn(sr, sg, sb)) {
            bool found = false;
            for (int rad = 1; rad <= 28 && !found; rad++) {
                for (int dyS = -rad; dyS <= rad && !found; dyS++) {
                    for (int dxS = -rad; dxS <= rad && !found; dxS++) {
                        if (Math.Abs(dxS) != rad && Math.Abs(dyS) != rad) continue;
                        int cx = sx + dxS, cy = sy + dyS;
                        if (cx >= 0 && cy >= 0 && cx < w && cy < h) {
                            img.GetRgb(x0 + cx, y0 + cy, out sr, out sg, out sb);
                            if (matchFn(sr, sg, sb)) { sx = cx; sy = cy; found = true; }
                        }
                    }
                }
            }
            if (!found) return null;
        }

        bool[] reach = new bool[w * h];
        var q = new Queue<int>(w * 4);
        reach[sy * w + sx] = true;
        q.Enqueue(sy * w + sx);
        int[] dx = { 1, -1, 0, 0 };
        int[] dy = { 0, 0, 1, -1 };

        while (q.Count > 0) {
            int p = q.Dequeue();
            int px = p % w, py = p / w;
            for (int i = 0; i < 4; i++) {
                int nx = px + dx[i], ny = py + dy[i];
                if (nx >= 0 && ny >= 0 && nx < w && ny < h) {
                    int ni = ny * w + nx;
                    if (!reach[ni]) {
                        img.GetRgb(x0 + nx, y0 + ny, out sr, out sg, out sb);
                        if (matchFn(sr, sg, sb)) {
                            reach[ni] = true;
                            q.Enqueue(ni);
                        }
                    }
                }
            }
        }

        string[] openSides = string.IsNullOrEmpty(openSide) ? new string[0] : openSide.ToLowerInvariant().Split(',');
        bool openTop = Array.IndexOf(openSides, "top") >= 0;
        bool openBot = Array.IndexOf(openSides, "bottom") >= 0;
        bool openLeft = Array.IndexOf(openSides, "left") >= 0;
        bool openRight = Array.IndexOf(openSides, "right") >= 0;

        bool[] outside = new bool[w * h];
        for (int x = 0; x < w; x++) {
            if (!openTop && !reach[x]) { outside[x] = true; q.Enqueue(x); }
            int bi = (h - 1) * w + x;
            if (!openBot && !reach[bi] && !outside[bi]) { outside[bi] = true; q.Enqueue(bi); }
        }
        for (int y = 0; y < h; y++) {
            int li = y * w;
            if (!openLeft && !reach[li] && !outside[li]) { outside[li] = true; q.Enqueue(li); }
            int ri = y * w + (w - 1);
            if (!openRight && !reach[ri] && !outside[ri]) { outside[ri] = true; q.Enqueue(ri); }
        }
        while (q.Count > 0) {
            int p = q.Dequeue();
            int px = p % w, py = p / w;
            for (int i = 0; i < 4; i++) {
                int nx = px + dx[i], ny = py + dy[i];
                if (nx >= 0 && ny >= 0 && nx < w && ny < h) {
                    int ni = ny * w + nx;
                    if (!outside[ni] && !reach[ni]) {
                        outside[ni] = true;
                        q.Enqueue(ni);
                    }
                }
            }
        }

        int minX = W, minY = H, maxX = -1, maxY = -1;
        int tx0 = W, ty0 = H, tx1 = -1, ty1 = -1;
        int[] rowLeft = new int[h];
        int[] rowRight = new int[h];
        int[] rowCount = new int[h];
        for (int y = 0; y < h; y++) { rowLeft[y] = W; rowRight[y] = -1; }

        for (int y = 0; y < h; y++) {
            int gy = y0 + y;
            for (int x = 0; x < w; x++) {
                int idx = y * w + x;
                if (outside[idx]) continue;
                int gx = x0 + x;
                if (gx < minX) minX = gx; if (gx > maxX) maxX = gx;
                if (gy < minY) minY = gy; if (gy > maxY) maxY = gy;
                if (gx < rowLeft[y]) rowLeft[y] = gx;
                if (gx > rowRight[y]) rowRight[y] = gx;
                rowCount[y]++;

                bool keep = false;
                if (keepRects != null) {
                    foreach (var r in keepRects) if (r.Contains(gx, gy)) { keep = true; break; }
                }
                if (keep) continue;

                bool adjOut = false;
                for (int i = 0; i < 4; i++) {
                    int nx = x + dx[i], ny = y + dy[i];
                    if (nx >= 0 && ny >= 0 && nx < w && ny < h && outside[ny * w + nx]) { adjOut = true; break; }
                }
                if (!adjOut || !reach[idx]) {
                    if (!reach[idx] && !adjOut) {
                        // Original glyph pixel strictly inside bubble interior
                        img.GetRgb(gx, gy, out sr, out sg, out sb);
                        int diff = Math.Abs(sr - fr) + Math.Abs(sg - fg) + Math.Abs(sb - fb);
                        if (diff >= 120) {
                            if (gx < tx0) tx0 = gx; if (gx > tx1) tx1 = gx;
                            if (gy < ty0) ty0 = gy; if (gy > ty1) ty1 = gy;
                        }
                    }
                    img.SetRgb(gx, gy, fr, fg, fb);
                }
            }
        }
        if (maxX < minX || maxY < minY) return null;

        // Compute tail-immune optical center & inscribed safe_rect via 2-pass Chamfer 3-4 Distance Transform:
        // Thin speech tails & sharp spikes have small distance-to-wall and are automatically excluded from the core!
        const int INF = 1000000;
        int[] dist = new int[w * h];
        for (int y = 0; y < h; y++) {
            int row = y * w;
            for (int x = 0; x < w; x++) {
                int idx = row + x;
                if (outside[idx] || x == 0 || y == 0 || x == w - 1 || y == h - 1) {
                    dist[idx] = 0;
                } else {
                    dist[idx] = INF;
                }
            }
        }
        // Forward pass
        for (int y = 1; y < h - 1; y++) {
            int row = y * w;
            int up = (y - 1) * w;
            for (int x = 1; x < w - 1; x++) {
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
        // Backward pass
        int maxD = 0;
        for (int y = h - 2; y >= 1; y--) {
            int row = y * w;
            int dn = (y + 1) * w;
            for (int x = w - 2; x >= 1; x--) {
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

        int optCx = (minX + maxX) / 2;
        int optCy = (minY + maxY) / 2;
        if (maxD > 0) {
            int coreThresh = (int)Math.Round(maxD * 0.72);
            double sumX = 0, sumY = 0, sumW = 0;
            for (int y = 1; y < h - 1; y++) {
                int row = y * w;
                for (int x = 1; x < w - 1; x++) {
                    int d = dist[row + x];
                    if (d >= coreThresh) {
                        double wt = (double)d * d;
                        sumX += (x0 + x) * wt;
                        sumY += (y0 + y) * wt;
                        sumW += wt;
                    }
                }
            }
            if (sumW > 0) {
                optCx = (int)Math.Round(sumX / sumW);
                optCy = (int)Math.Round(sumY / sumW);
            }
        }

        // Measure symmetric clear span around (optCx, optCy) inside the bubble cavity
        int cxLoc = Math.Max(0, Math.Min(w - 1, optCx - x0));
        int cyLoc = Math.Max(0, Math.Min(h - 1, optCy - y0));
        int spanL = 0; while (cxLoc - spanL - 1 >= 0 && !outside[cyLoc * w + (cxLoc - spanL - 1)]) spanL++;
        int spanR = 0; while (cxLoc + spanR + 1 < w && !outside[cyLoc * w + (cxLoc + spanR + 1)]) spanR++;
        int spanT = 0; while (cyLoc - spanT - 1 >= 0 && !outside[(cyLoc - spanT - 1) * w + cxLoc]) spanT++;
        int spanB = 0; while (cyLoc + spanB + 1 < h && !outside[(cyLoc + spanB + 1) * w + cxLoc]) spanB++;

        int bodyHalfW = Math.Max(8, Math.Min(spanL, spanR));
        int bodyHalfH = Math.Max(10, Math.Min(spanT, spanB));
        int safeW = Math.Max(16, (int)Math.Round(bodyHalfW * 2.0 * 0.78));
        int safeH = Math.Max(20, (int)Math.Round(bodyHalfH * 2.0 * 0.76));
        int safeX = optCx - safeW / 2;
        int safeY = optCy - safeH / 2;

        var m = new BubbleMetrics();
        m.bubble_bbox = new int[] { minX, minY, maxX - minX + 1, maxY - minY + 1 };
        m.optical_center = new int[] { optCx, optCy };
        m.safe_rect = new int[] { safeX, safeY, safeW, safeH };
        if (tx1 >= tx0 && ty1 >= ty0) {
            m.orig_text_bbox = new int[] { tx0, ty0, tx1 - tx0 + 1, ty1 - ty0 + 1 };
            m.orig_text_center = new int[] { (tx0 + tx1) / 2, (ty0 + ty1) / 2 };
        }
        return m;
    }

    public static BubbleMetrics CleanWhiteBubble(FastImg img, int x0, int y0, int x1, int y1, int seedX, int seedY, int thresh, string openSide, Rectangle[] keepRects) {
        byte sr = 255, sg = 255, sb = 255;
        if (seedX >= 0 && seedX < img.W && seedY >= 0 && seedY < img.H) {
            img.GetRgb(seedX, seedY, out sr, out sg, out sb);
        }
        var m = FloodCleanCore(img, x0, y0, x1, y1, seedX, seedY, (r, g, b) => IsWhite(r, g, b, thresh), 255, 255, 255, keepRects, openSide);
        if (m != null && Math.Min(sr, Math.Min(sg, sb)) <= 242 && Math.Min(sr, Math.Min(sg, sb)) >= thresh) {
            m.warning = string.Format("WARN_GREY_BUBBLE_SEED: seed rgb=({0},{1},{2}) was bleached to white! Use color_flood instead.", sr, sg, sb);
        }
        return m;
    }

    public static BubbleMetrics CleanBlackBubble(FastImg img, int x0, int y0, int x1, int y1, int seedX, int seedY, int thresh, string openSide, Rectangle[] keepRects, byte fr, byte fg, byte fb) {
        return FloodCleanCore(img, x0, y0, x1, y1, seedX, seedY, (r, g, b) => IsBlack(r, g, b, thresh), fr, fg, fb, keepRects, openSide);
    }

    public static BubbleMetrics CleanColorFlood(FastImg img, int x0, int y0, int x1, int y1, int seedX, int seedY, int tol, string openSide, Rectangle[] keepRects) {
        byte tr, tg, tb;
        img.GetRgb(seedX, seedY, out tr, out tg, out tb);
        int tol2 = tol * tol;
        return FloodCleanCore(img, x0, y0, x1, y1, seedX, seedY, (r, g, b) => IsNearColor(r, g, b, tr, tg, tb, tol2), tr, tg, tb, keepRects, openSide);
    }

    public static BubbleMetrics FillRect(FastImg img, int x0, int y0, int x1, int y1, byte r, byte g, byte b) {
        x0 = Math.Max(0, x0); y0 = Math.Max(0, y0);
        x1 = Math.Min(img.W - 1, x1); y1 = Math.Min(img.H - 1, y1);
        var before = img.CloneBuf();
        for (int y = y0; y <= y1; y++)
            for (int x = x0; x <= x1; x++)
                img.SetRgb(x, y, r, g, b);
        return ComputeDiffTextMetrics(before, img, x0, y0, x1, y1);
    }

    public static BubbleMetrics FillPolygon(FastImg img, Point[] pts, byte r, byte g, byte b) {
        if (pts == null || pts.Length < 3) return null;
        int minX = img.W, minY = img.H, maxX = 0, maxY = 0;
        foreach (var pt in pts) {
            if (pt.X < minX) minX = pt.X; if (pt.X > maxX) maxX = pt.X;
            if (pt.Y < minY) minY = pt.Y; if (pt.Y > maxY) maxY = pt.Y;
        }
        minX = Math.Max(0, minX); minY = Math.Max(0, minY);
        maxX = Math.Min(img.W - 1, maxX); maxY = Math.Min(img.H - 1, maxY);
        var before = img.CloneBuf();
        // Scanline polygon fill in LockBits buffer
        int n = pts.Length;
        var xs = new List<double>();
        for (int y = minY; y <= maxY; y++) {
            xs.Clear();
            double fy = y + 0.5;
            for (int i = 0, j = n - 1; i < n; j = i++) {
                double y1 = pts[i].Y, y2 = pts[j].Y;
                if ((y1 <= fy && y2 > fy) || (y2 <= fy && y1 > fy)) {
                    double xInt = pts[i].X + (fy - y1) * (pts[j].X - pts[i].X) / (y2 - y1);
                    xs.Add(xInt);
                }
            }
            xs.Sort();
            for (int k = 0; k + 1 < xs.Count; k += 2) {
                int lx = Math.Max(0, (int)Math.Ceiling(xs[k]));
                int rx = Math.Min(img.W - 1, (int)Math.Floor(xs[k + 1]));
                for (int x = lx; x <= rx; x++) img.SetRgb(x, y, r, g, b);
            }
        }
        return ComputeDiffTextMetrics(before, img, minX, minY, maxX, maxY);
    }

    public static string InterpV(FastImg img, int x0, int y0, int x1, int y1, int pad) {
        x0 = Math.Max(0, x0); y0 = Math.Max(pad, y0);
        x1 = Math.Min(img.W - 1, x1); y1 = Math.Min(img.H - 1 - pad, y1);
        int darkEdge = 0, totalEdge = Math.Max(1, (x1 - x0 + 1) * 2);
        for (int x = x0; x <= x1; x++) {
            byte rt, gt, bt, rb, gb, bb;
            img.GetRgb(x, y0 - pad, out rt, out gt, out bt);
            img.GetRgb(x, y1 + pad, out rb, out gb, out bb);
            if ((rt + gt + bt) / 3 < 130) darkEdge++;
            if ((rb + gb + bb) / 3 < 130) darkEdge++;
            for (int y = y0; y <= y1; y++) {
                double t = (double)(y - y0) / Math.Max(1, y1 - y0);
                img.SetRgb(x, y,
                    (byte)Math.Round(rt * (1 - t) + rb * t),
                    (byte)Math.Round(gt * (1 - t) + gb * t),
                    (byte)Math.Round(bt * (1 - t) + bb * t));
            }
        }
        if (darkEdge * 100 / totalEdge >= 6) {
            return string.Format("WARN_INTERP_DARK_EDGE: interp_v sampled {0}/{1} dark pixels on top/bottom edge (risk of vertical streak smear!)", darkEdge, totalEdge);
        }
        return null;
    }

    public static string InterpH(FastImg img, int x0, int y0, int x1, int y1, int pad) {
        x0 = Math.Max(pad, x0); y0 = Math.Max(0, y0);
        x1 = Math.Min(img.W - 1 - pad, x1); y1 = Math.Min(img.H - 1, y1);
        int darkEdge = 0, totalEdge = Math.Max(1, (y1 - y0 + 1) * 2);
        for (int y = y0; y <= y1; y++) {
            byte rl, gl, bl, rr, gr, br;
            img.GetRgb(x0 - pad, y, out rl, out gl, out bl);
            img.GetRgb(x1 + pad, y, out rr, out gr, out br);
            if ((rl + gl + bl) / 3 < 130) darkEdge++;
            if ((rr + gr + br) / 3 < 130) darkEdge++;
            for (int x = x0; x <= x1; x++) {
                double t = (double)(x - x0) / Math.Max(1, x1 - x0);
                img.SetRgb(x, y,
                    (byte)Math.Round(rl * (1 - t) + rr * t),
                    (byte)Math.Round(gl * (1 - t) + gr * t),
                    (byte)Math.Round(bl * (1 - t) + br * t));
            }
        }
        if (darkEdge * 100 / totalEdge >= 6) {
            return string.Format("WARN_INTERP_DARK_EDGE: interp_h sampled {0}/{1} dark pixels on left/right edge (risk of horizontal streak smear!)", darkEdge, totalEdge);
        }
        return null;
    }

    public static void CopyColRect(FastImg img, int x0, int y0, int x1, int y1, int srcX) {
        x0 = Math.Max(0, x0); y0 = Math.Max(0, y0);
        x1 = Math.Min(img.W - 1, x1); y1 = Math.Min(img.H - 1, y1);
        srcX = Math.Max(0, Math.Min(img.W - 1, srcX));
        for (int y = y0; y <= y1; y++) {
            byte r, g, b;
            img.GetRgb(srcX, y, out r, out g, out b);
            for (int x = x0; x <= x1; x++) img.SetRgb(x, y, r, g, b);
        }
    }

    public static void CopyColPolygon(FastImg img, Point[] pts, int srcX) {
        if (pts == null || pts.Length < 3) return;
        srcX = Math.Max(0, Math.Min(img.W - 1, srcX));
        int minY = img.H, maxY = 0;
        foreach (var pt in pts) {
            if (pt.Y < minY) minY = pt.Y;
            if (pt.Y > maxY) maxY = pt.Y;
        }
        minY = Math.Max(0, minY); maxY = Math.Min(img.H - 1, maxY);
        int n = pts.Length;
        var xs = new List<double>();
        for (int y = minY; y <= maxY; y++) {
            xs.Clear();
            double fy = y + 0.5;
            for (int i = 0, j = n - 1; i < n; j = i++) {
                double y1 = pts[i].Y, y2 = pts[j].Y;
                if ((y1 <= fy && y2 > fy) || (y2 <= fy && y1 > fy)) {
                    xs.Add(pts[i].X + (fy - y1) * (pts[j].X - pts[i].X) / (y2 - y1));
                }
            }
            xs.Sort();
            byte r, g, b;
            img.GetRgb(srcX, y, out r, out g, out b);
            for (int k = 0; k + 1 < xs.Count; k += 2) {
                int lx = Math.Max(0, (int)Math.Ceiling(xs[k]));
                int rx = Math.Min(img.W - 1, (int)Math.Floor(xs[k + 1]));
                for (int x = lx; x <= rx; x++) img.SetRgb(x, y, r, g, b);
            }
        }
    }

    public static void CopyRowRect(FastImg img, int x0, int y0, int x1, int y1, int srcY) {
        x0 = Math.Max(0, x0); y0 = Math.Max(0, y0);
        x1 = Math.Min(img.W - 1, x1); y1 = Math.Min(img.H - 1, y1);
        srcY = Math.Max(0, Math.Min(img.H - 1, srcY));
        for (int x = x0; x <= x1; x++) {
            byte r, g, b;
            img.GetRgb(x, srcY, out r, out g, out b);
            for (int y = y0; y <= y1; y++) img.SetRgb(x, y, r, g, b);
        }
    }

    public static void CopyRowPolygon(FastImg img, Point[] pts, int srcY) {
        if (pts == null || pts.Length < 3) return;
        srcY = Math.Max(0, Math.Min(img.H - 1, srcY));
        int minY = img.H, maxY = 0;
        foreach (var pt in pts) {
            if (pt.Y < minY) minY = pt.Y;
            if (pt.Y > maxY) maxY = pt.Y;
        }
        minY = Math.Max(0, minY); maxY = Math.Min(img.H - 1, maxY);
        int n = pts.Length;
        var xs = new List<double>();
        for (int y = minY; y <= maxY; y++) {
            xs.Clear();
            double fy = y + 0.5;
            for (int i = 0, j = n - 1; i < n; j = i++) {
                double y1 = pts[i].Y, y2 = pts[j].Y;
                if ((y1 <= fy && y2 > fy) || (y2 <= fy && y1 > fy)) {
                    xs.Add(pts[i].X + (fy - y1) * (pts[j].X - pts[i].X) / (y2 - y1));
                }
            }
            xs.Sort();
            for (int k = 0; k + 1 < xs.Count; k += 2) {
                int lx = Math.Max(0, (int)Math.Ceiling(xs[k]));
                int rx = Math.Min(img.W - 1, (int)Math.Floor(xs[k + 1]));
                for (int x = lx; x <= rx; x++) {
                    byte r, g, b;
                    img.GetRgb(x, srcY, out r, out g, out b);
                    img.SetRgb(x, y, r, g, b);
                }
            }
        }
    }

    static void SampleBilinear(FastImg src, double fx, double fy, out double r, out double g, out double b) {
        if (fx < 0) fx = 0; if (fx > src.W - 1.001) fx = src.W - 1.001;
        if (fy < 0) fy = 0; if (fy > src.H - 1.001) fy = src.H - 1.001;
        int x0 = (int)Math.Floor(fx), y0 = (int)Math.Floor(fy);
        int x1 = Math.Min(src.W - 1, x0 + 1), y1 = Math.Min(src.H - 1, y0 + 1);
        double tx = fx - x0, ty = fy - y0;
        byte r00, g00, b00, r10, g10, b10, r01, g01, b01, r11, g11, b11;
        src.GetRgb(x0, y0, out r00, out g00, out b00);
        src.GetRgb(x1, y0, out r10, out g10, out b10);
        src.GetRgb(x0, y1, out r01, out g01, out b01);
        src.GetRgb(x1, y1, out r11, out g11, out b11);
        double w00 = (1 - tx) * (1 - ty), w10 = tx * (1 - ty), w01 = (1 - tx) * ty, w11 = tx * ty;
        r = r00 * w00 + r10 * w10 + r01 * w01 + r11 * w11;
        g = g00 * w00 + g10 * w10 + g01 * w01 + g11 * w11;
        b = b00 * w00 + b10 * w10 + b01 * w01 + b11 * w11;
    }

    public static BubbleMetrics CopyAlongDir(FastImg img, int x0, int y0, int x1, int y1, Point[] pts, double dirDx, double dirDy, string side, bool onlyDark, int darkThresh, int dilateR, int maxSteps) {
        double len = Math.Sqrt(dirDx * dirDx + dirDy * dirDy);
        if (len < 1e-6) { dirDx = 1.0; dirDy = 0.0; } else { dirDx /= len; dirDy /= len; }
        if (pts != null && pts.Length >= 3) {
            x0 = img.W; y0 = img.H; x1 = 0; y1 = 0;
            foreach (var pt in pts) {
                if (pt.X < x0) x0 = pt.X; if (pt.X > x1) x1 = pt.X;
                if (pt.Y < y0) y0 = pt.Y; if (pt.Y > y1) y1 = pt.Y;
            }
        }
        x0 = Math.Max(0, x0); y0 = Math.Max(0, y0);
        x1 = Math.Min(img.W - 1, x1); y1 = Math.Min(img.H - 1, y1);
        int w = x1 - x0 + 1, h = y1 - y0 + 1;
        if (w <= 0 || h <= 0) return null;

        bool[] polyMask = new bool[w * h];
        if (pts != null && pts.Length >= 3) {
            int n = pts.Length;
            var xs = new List<double>();
            for (int y = y0; y <= y1; y++) {
                xs.Clear();
                double fy = y + 0.5;
                for (int i = 0, j = n - 1; i < n; j = i++) {
                    double py1 = pts[i].Y, py2 = pts[j].Y;
                    if ((py1 <= fy && py2 > fy) || (py2 <= fy && py1 > fy)) {
                        xs.Add(pts[i].X + (fy - py1) * (pts[j].X - pts[i].X) / (py2 - py1));
                    }
                }
                xs.Sort();
                for (int k = 0; k + 1 < xs.Count; k += 2) {
                    int lx = Math.Max(x0, (int)Math.Ceiling(xs[k]));
                    int rx = Math.Min(x1, (int)Math.Floor(xs[k + 1]));
                    for (int x = lx; x <= rx; x++) polyMask[(y - y0) * w + (x - x0)] = true;
                }
            }
        } else {
            for (int i = 0; i < w * h; i++) polyMask[i] = true;
        }

        bool[] mask = polyMask;
        if (onlyDark) {
            bool[] dm = new bool[w * h];
            int r2 = dilateR * dilateR + 1;
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    if (!polyMask[y * w + x]) continue;
                    byte r, g, b; img.GetRgb(x0 + x, y0 + y, out r, out g, out b);
                    if ((r + g + b) / 3 <= darkThresh) {
                        for (int oy = -dilateR; oy <= dilateR; oy++) {
                            for (int ox = -dilateR; ox <= dilateR; ox++) {
                                if (ox * ox + oy * oy > r2) continue;
                                int nx = x + ox, ny = y + oy;
                                if (nx >= 0 && nx < w && ny >= 0 && ny < h && polyMask[ny * w + nx]) dm[ny * w + nx] = true;
                            }
                        }
                    }
                }
            }
            mask = dm;
        }

        var src = img.CloneBuf();
        bool usePos = (side != "neg");
        bool useNeg = (side != "pos");
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                if (!mask[y * w + x]) continue;
                int gx = x0 + x, gy = y0 + y;
                bool hasP = false, hasN = false;
                double dP = 0, dN = 0, rP = 255, gP = 255, bP = 255, rN = 255, gN = 255, bN = 255;

                if (usePos) {
                    for (int s = 1; s <= maxSteps; s++) {
                        double fx = gx + dirDx * s, fy = gy + dirDy * s;
                        int ix = (int)Math.Round(fx), iy = (int)Math.Round(fy);
                        if (ix < 0 || ix >= src.W || iy < 0 || iy >= src.H) break;
                        bool inM = (ix >= x0 && ix <= x1 && iy >= y0 && iy <= y1 && mask[(iy - y0) * w + (ix - x0)]);
                        if (!inM) {
                            // Step 1 extra pixel outside mask edge for clean anti-aliased sample
                            double sx = gx + dirDx * (s + 1.0), sy = gy + dirDy * (s + 1.0);
                            SampleBilinear(src, sx, sy, out rP, out gP, out bP);
                            dP = s; hasP = true; break;
                        }
                    }
                }
                if (useNeg) {
                    for (int s = 1; s <= maxSteps; s++) {
                        double fx = gx - dirDx * s, fy = gy - dirDy * s;
                        int ix = (int)Math.Round(fx), iy = (int)Math.Round(fy);
                        if (ix < 0 || ix >= src.W || iy < 0 || iy >= src.H) break;
                        bool inM = (ix >= x0 && ix <= x1 && iy >= y0 && iy <= y1 && mask[(iy - y0) * w + (ix - x0)]);
                        if (!inM) {
                            double sx = gx - dirDx * (s + 1.0), sy = gy - dirDy * (s + 1.0);
                            SampleBilinear(src, sx, sy, out rN, out gN, out bN);
                            dN = s; hasN = true; break;
                        }
                    }
                }

                if (hasP && hasN) {
                    double t = dN / (dP + dN);
                    img.SetRgb(gx, gy,
                        (byte)Math.Max(0, Math.Min(255, (int)Math.Round(rN * (1 - t) + rP * t))),
                        (byte)Math.Max(0, Math.Min(255, (int)Math.Round(gN * (1 - t) + gP * t))),
                        (byte)Math.Max(0, Math.Min(255, (int)Math.Round(bN * (1 - t) + bP * t))));
                } else if (hasP) {
                    img.SetRgb(gx, gy, (byte)Math.Round(rP), (byte)Math.Round(gP), (byte)Math.Round(bP));
                } else if (hasN) {
                    img.SetRgb(gx, gy, (byte)Math.Round(rN), (byte)Math.Round(gN), (byte)Math.Round(bN));
                }
            }
        }
        return ComputeDiffTextMetrics(src, img, x0, y0, x1, y1);
    }

    public static BubbleMetrics PatchCopy(FastImg img, int x0, int y0, int x1, int y1, Point[] pts, int offX, int offY, bool autoAlign, int searchRadius, bool onlyDark, int darkThresh, int dilateR) {
        if (pts != null && pts.Length >= 3) {
            x0 = img.W; y0 = img.H; x1 = 0; y1 = 0;
            foreach (var pt in pts) {
                if (pt.X < x0) x0 = pt.X; if (pt.X > x1) x1 = pt.X;
                if (pt.Y < y0) y0 = pt.Y; if (pt.Y > y1) y1 = pt.Y;
            }
        }
        x0 = Math.Max(0, x0); y0 = Math.Max(0, y0);
        x1 = Math.Min(img.W - 1, x1); y1 = Math.Min(img.H - 1, y1);
        int w = x1 - x0 + 1, h = y1 - y0 + 1;
        if (w <= 0 || h <= 0) return null;

        bool[] polyMask = new bool[w * h];
        if (pts != null && pts.Length >= 3) {
            int n = pts.Length;
            var xs = new List<double>();
            for (int y = y0; y <= y1; y++) {
                xs.Clear();
                double fy = y + 0.5;
                for (int i = 0, j = n - 1; i < n; j = i++) {
                    double py1 = pts[i].Y, py2 = pts[j].Y;
                    if ((py1 <= fy && py2 > fy) || (py2 <= fy && py1 > fy)) {
                        xs.Add(pts[i].X + (fy - py1) * (pts[j].X - pts[i].X) / (py2 - py1));
                    }
                }
                xs.Sort();
                for (int k = 0; k + 1 < xs.Count; k += 2) {
                    int lx = Math.Max(x0, (int)Math.Ceiling(xs[k]));
                    int rx = Math.Min(x1, (int)Math.Floor(xs[k + 1]));
                    for (int x = lx; x <= rx; x++) polyMask[(y - y0) * w + (x - x0)] = true;
                }
            }
        } else {
            for (int i = 0; i < w * h; i++) polyMask[i] = true;
        }

        bool[] mask = polyMask;
        if (onlyDark) {
            bool[] dm = new bool[w * h];
            int r2 = dilateR * dilateR + 1;
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    if (!polyMask[y * w + x]) continue;
                    byte r, g, b; img.GetRgb(x0 + x, y0 + y, out r, out g, out b);
                    if ((r + g + b) / 3 <= darkThresh) {
                        for (int oy = -dilateR; oy <= dilateR; oy++) {
                            for (int ox = -dilateR; ox <= dilateR; ox++) {
                                if (ox * ox + oy * oy > r2) continue;
                                int nx = x + ox, ny = y + oy;
                                if (nx >= 0 && nx < w && ny >= 0 && ny < h && polyMask[ny * w + nx]) dm[ny * w + nx] = true;
                            }
                        }
                    }
                }
            }
            mask = dm;
        }

        var src = img.CloneBuf();
        int bestDx = offX, bestDy = offY;

        if (autoAlign && searchRadius > 0) {
            var ring = new List<Point>();
            int rx0 = Math.Max(0, x0 - 3), ry0 = Math.Max(0, y0 - 3);
            int rx1 = Math.Min(src.W - 1, x1 + 3), ry1 = Math.Min(src.H - 1, y1 + 3);
            for (int gy = ry0; gy <= ry1; gy++) {
                for (int gx = rx0; gx <= rx1; gx++) {
                    bool inPoly = (gx >= x0 && gx <= x1 && gy >= y0 && gy <= y1 && polyMask[(gy - y0) * w + (gx - x0)]);
                    if (inPoly) continue;
                    bool adj = false;
                    for (int oy = -3; oy <= 3 && !adj; oy++) {
                        int ny = gy + oy; if (ny < y0 || ny > y1) continue;
                        for (int ox = -3; ox <= 3 && !adj; ox++) {
                            int nx = gx + ox; if (nx < x0 || nx > x1) continue;
                            if (polyMask[(ny - y0) * w + (nx - x0)]) adj = true;
                        }
                    }
                    if (adj) ring.Add(new Point(gx, gy));
                }
            }
            if (ring.Count >= 8) {
                int step = Math.Max(1, ring.Count / 360);
                double bestScore = double.MaxValue;
                for (int cdy = offY - searchRadius; cdy <= offY + searchRadius; cdy++) {
                    for (int cdx = offX - searchRadius; cdx <= offX + searchRadius; cdx++) {
                        long err = 0; int cnt = 0;
                        for (int k = 0; k < ring.Count; k += step) {
                            int gx = ring[k].X, gy = ring[k].Y;
                            int sx = gx + cdx, sy = gy + cdy;
                            if (sx < 0 || sx >= src.W || sy < 0 || sy >= src.H) continue;
                            if (sx >= x0 && sx <= x1 && sy >= y0 && sy <= y1 && polyMask[(sy - y0) * w + (sx - x0)]) continue;
                            byte r0, g0, b0, r1, g1, b1;
                            src.GetRgb(gx, gy, out r0, out g0, out b0);
                            src.GetRgb(sx, sy, out r1, out g1, out b1);
                            err += Math.Abs(r0 - r1) + Math.Abs(g0 - g1) + Math.Abs(b0 - b1);
                            cnt++;
                        }
                        if (cnt >= 8) {
                            double score = (double)err / cnt;
                            if (score < bestScore) { bestScore = score; bestDx = cdx; bestDy = cdy; }
                        }
                    }
                }
            }
        }

        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                if (!mask[y * w + x]) continue;
                int sx = Math.Max(0, Math.Min(src.W - 1, x0 + x + bestDx));
                int sy = Math.Max(0, Math.Min(src.H - 1, y0 + y + bestDy));
                byte r, g, b;
                src.GetRgb(sx, sy, out r, out g, out b);
                img.SetRgb(x0 + x, y0 + y, r, g, b);
            }
        }
        return ComputeDiffTextMetrics(src, img, x0, y0, x1, y1);
    }

    public static void DrawLinesOnImg(FastImg img, PointF[][] polylines, float[] widths, Color[] colors, bool[] smooth) {
        if (polylines == null || polylines.Length == 0) return;
        using (var bmp = new Bitmap(img.W, img.H, PixelFormat.Format32bppArgb)) {
            var rect = new Rectangle(0, 0, img.W, img.H);
            var bd = bmp.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
            Marshal.Copy(img.Buf, 0, bd.Scan0, img.Buf.Length);
            bmp.UnlockBits(bd);
            using (var g = Graphics.FromImage(bmp)) {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                for (int i = 0; i < polylines.Length; i++) {
                    var pts = polylines[i];
                    if (pts == null || pts.Length < 2) continue;
                    using (var pen = new Pen(colors[i], widths[i])) {
                        pen.StartCap = LineCap.Round;
                        pen.EndCap = LineCap.Round;
                        pen.LineJoin = LineJoin.Round;
                        if (smooth[i] && pts.Length >= 3) g.DrawCurve(pen, pts, 0.5f);
                        else g.DrawLines(pen, pts);
                    }
                }
            }
            var bd2 = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            Marshal.Copy(bd2.Scan0, img.Buf, 0, img.Buf.Length);
            bmp.UnlockBits(bd2);
        }
    }

    static void HarmonicInpaint(FastImg img, bool[] mask, int x0, int y0, int x1, int y1, int iters, double dirDx, double dirDy) {
        int W = img.W, H = img.H;
        int w = x1 - x0 + 1;
        int bx0 = Math.Max(0, x0 - 24), by0 = Math.Max(0, y0 - 24);
        int bx1 = Math.Min(W - 1, x1 + 24), by1 = Math.Min(H - 1, y1 + 24);
        int rw = bx1 - bx0 + 1, rh = by1 - by0 + 1;
        double[] R = new double[rw * rh], G = new double[rw * rh], B = new double[rw * rh];
        for (int y = by0; y <= by1; y++) {
            int rowOff = (y - by0) * rw;
            for (int x = bx0; x <= bx1; x++) {
                byte cr, cg, cb;
                img.GetRgb(x, y, out cr, out cg, out cb);
                int idx = rowOff + (x - bx0);
                R[idx] = cr; G[idx] = cg; B[idx] = cb;
            }
        }
        bool useDir = (dirDx != 0 || dirDy != 0);
        double[] dxs = useDir ? new double[]{ dirDx, -dirDx } : new double[]{ 1, -1, 0, 0 };
        double[] dys = useDir ? new double[]{ dirDy, -dirDy } : new double[]{ 0, 0, 1, -1 };

        var active = new List<int>();
        for (int y = y0; y <= y1; y++) {
            for (int x = x0; x <= x1; x++) {
                if (!mask[(y - y0) * w + (x - x0)]) continue;
                active.Add((y - by0) * rw + (x - bx0));
                double wSum = 0, rSum = 0, gSum = 0, bSum = 0;
                for (int k = 0; k < dxs.Length; k++) {
                    for (int step = 1; step <= 80; step++) {
                        int nx = (int)Math.Round(x + dxs[k] * step);
                        int ny = (int)Math.Round(y + dys[k] * step);
                        if (nx < bx0 || nx > bx1 || ny < by0 || ny > by1) break;
                        bool inMask = (nx >= x0 && nx <= x1 && ny >= y0 && ny <= y1 && mask[(ny - y0) * w + (nx - x0)]);
                        if (!inMask) {
                            double wt = 1.0 / step;
                            int nidx = (ny - by0) * rw + (nx - bx0);
                            rSum += R[nidx] * wt; gSum += G[nidx] * wt; bSum += B[nidx] * wt; wSum += wt;
                            break;
                        }
                    }
                }
                if (wSum > 0) {
                    int cidx = (y - by0) * rw + (x - bx0);
                    R[cidx] = rSum / wSum; G[cidx] = gSum / wSum; B[cidx] = bSum / wSum;
                }
            }
        }
        int[] actArr = active.ToArray();
        double omega = 1.65;
        int dOffA = 0, dOffB = 0;
        if (useDir) {
            int adx = (int)Math.Round(dirDx), ady = (int)Math.Round(dirDy);
            dOffA = ady * rw + adx;
            dOffB = -ady * rw - adx;
        }
        int maxIdx = rw * rh - 1;
        for (int it = 0; it < iters; it++) {
            for (int k = 0; k < actArr.Length; k++) {
                int ci = actArr[k];
                double nr, ng, nb;
                if (useDir) {
                    int ia = ci + dOffA; if (ia < 0) ia = 0; else if (ia > maxIdx) ia = maxIdx;
                    int ib = ci + dOffB; if (ib < 0) ib = 0; else if (ib > maxIdx) ib = maxIdx;
                    nr = (R[ia] * 3 + R[ib] * 3 + R[ci - 1] + R[ci + 1] + R[ci - rw] + R[ci + rw]) * 0.1;
                    ng = (G[ia] * 3 + G[ib] * 3 + G[ci - 1] + G[ci + 1] + G[ci - rw] + G[ci + rw]) * 0.1;
                    nb = (B[ia] * 3 + B[ib] * 3 + B[ci - 1] + B[ci + 1] + B[ci - rw] + B[ci + rw]) * 0.1;
                } else {
                    nr = 0.25 * (R[ci - 1] + R[ci + 1] + R[ci - rw] + R[ci + rw]);
                    ng = 0.25 * (G[ci - 1] + G[ci + 1] + G[ci - rw] + G[ci + rw]);
                    nb = 0.25 * (B[ci - 1] + B[ci + 1] + B[ci - rw] + B[ci + rw]);
                }
                R[ci] += omega * (nr - R[ci]);
                G[ci] += omega * (ng - G[ci]);
                B[ci] += omega * (nb - B[ci]);
            }
        }
        for (int k = 0; k < actArr.Length; k++) {
            int ci = actArr[k];
            int gx = bx0 + (ci % rw);
            int gy = by0 + (ci / rw);
            img.SetRgb(gx, gy,
                (byte)Math.Max(0, Math.Min(255, (int)Math.Round(R[ci]))),
                (byte)Math.Max(0, Math.Min(255, (int)Math.Round(G[ci]))),
                (byte)Math.Max(0, Math.Min(255, (int)Math.Round(B[ci]))));
        }
    }

    static string AuditHarmonicSmear(FastImg before, bool[] mask, int x0, int y0, int x1, int y1) {
        int w = x1 - x0 + 1, h = y1 - y0 + 1;
        int maskCount = 0;
        int minLum = 255, maxLum = 0;
        int[] dx = { 1, -1, 0, 0 }, dy = { 0, 0, 1, -1 };
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                if (!mask[y * w + x]) continue;
                maskCount++;
                for (int k = 0; k < 4; k++) {
                    int nx = x + dx[k], ny = y + dy[k];
                    bool outsideMask = (nx < 0 || nx >= w || ny < 0 || ny >= h || !mask[ny * w + nx]);
                    if (!outsideMask) continue;
                    int gx = Math.Max(0, Math.Min(before.W - 1, x0 + nx));
                    int gy = Math.Max(0, Math.Min(before.H - 1, y0 + ny));
                    byte r, g, b; before.GetRgb(gx, gy, out r, out g, out b);
                    int lum = (r + g + b) / 3;
                    if (lum < minLum) minLum = lum;
                    if (lum > maxLum) maxLum = lum;
                }
            }
        }
        int span = maxLum - minLum;
        double cov = (double)maskCount / Math.Max(1, w * h);
        if (span >= 150 && (maskCount >= 1800 || (cov >= 0.40 && Math.Min(w, h) >= 36))) {
            return "WARN_HARMONIC_SMEAR: high-contrast boundary (lum " + minLum + ".." + maxLum + ") over " + maskCount + "px (" + (int)Math.Round(cov * 100) + "% of box) creates blurry grey block; use AI inpainting + roi_composite or crisp poly_fill+draw_lines instead";
        }
        return null;
    }

    public static BubbleMetrics CleanTranslucentHalo(FastImg img, int x0, int y0, int x1, int y1, int whiteThresh, int dilateR, int iters, double dirDx, double dirDy) {
        x0 = Math.Max(1, x0); y0 = Math.Max(1, y0);
        x1 = Math.Min(img.W - 2, x1); y1 = Math.Min(img.H - 2, y1);
        int w = x1 - x0 + 1, h = y1 - y0 + 1;
        var before = img.CloneBuf();
        bool[] raw = new bool[w * h];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                byte r, g, b; img.GetRgb(x0 + x, y0 + y, out r, out g, out b);
                if (Math.Min(r, Math.Min(g, b)) >= whiteThresh) raw[y * w + x] = true;
            }
        bool[] ext = new bool[w * h];
        var q = new Queue<int>();
        for (int x = 0; x < w; x++) {
            if (!raw[x]) { ext[x] = true; q.Enqueue(x); }
            int bi = (h - 1) * w + x;
            if (!raw[bi]) { ext[bi] = true; q.Enqueue(bi); }
        }
        for (int y = 0; y < h; y++) {
            int li = y * w; if (!raw[li] && !ext[li]) { ext[li] = true; q.Enqueue(li); }
            int ri = y * w + (w - 1); if (!raw[ri] && !ext[ri]) { ext[ri] = true; q.Enqueue(ri); }
        }
        int[] dx = {1,-1,0,0}, dy = {0,0,1,-1};
        while (q.Count > 0) {
            int p = q.Dequeue(); int cx = p % w, cy = p / w;
            for (int k = 0; k < 4; k++) {
                int nx = cx + dx[k], ny = cy + dy[k];
                if (nx < 0 || nx >= w || ny < 0 || ny >= h) continue;
                int ni = ny * w + nx;
                if (!ext[ni] && !raw[ni]) { ext[ni] = true; q.Enqueue(ni); }
            }
        }
        bool[] mask = new bool[w * h];
        int r2 = dilateR * dilateR + 1;
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                if (ext[y * w + x]) continue;
                for (int oy = -dilateR; oy <= dilateR; oy++)
                    for (int ox = -dilateR; ox <= dilateR; ox++) {
                        if (ox * ox + oy * oy > r2) continue;
                        int nx = x + ox, ny = y + oy;
                        if (nx >= 0 && nx < w && ny >= 0 && ny < h) mask[ny * w + nx] = true;
                    }
            }
        string smearWarn = AuditHarmonicSmear(before, mask, x0, y0, x1, y1);
        HarmonicInpaint(img, mask, x0, y0, x1, y1, iters, dirDx, dirDy);
        var m = ComputeDiffTextMetrics(before, img, x0, y0, x1, y1);
        if (m == null && smearWarn != null) m = new BubbleMetrics();
        if (m != null && smearWarn != null) m.warning = smearWarn;
        return m;
    }

    public static BubbleMetrics CleanTranslucentAnchored(FastImg img, int x0, int y0, int x1, int y1, int blackMax, int haloR, int whiteCheckThresh, int iters, double dirDx, double dirDy) {
        x0 = Math.Max(1, x0); y0 = Math.Max(1, y0);
        x1 = Math.Min(img.W - 2, x1); y1 = Math.Min(img.H - 2, y1);
        int w = x1 - x0 + 1, h = y1 - y0 + 1;
        var before = img.CloneBuf();
        bool[] core = new bool[w * h];
        int tx0 = img.W, ty0 = img.H, tx1 = -1, ty1 = -1;
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                byte r, g, b; img.GetRgb(x0 + x, y0 + y, out r, out g, out b);
                if (Math.Max(r, Math.Max(g, b)) <= blackMax) core[y * w + x] = true;
            }
        if (whiteCheckThresh > 0) {
            bool[] hasW = new bool[w * h];
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++) {
                    byte r, g, b; img.GetRgb(x0 + x, y0 + y, out r, out g, out b);
                    if (Math.Min(r, Math.Min(g, b)) >= whiteCheckThresh) hasW[y * w + x] = true;
                }
            bool[] filt = new bool[w * h];
            int chkR = Math.Max(4, haloR);
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++) {
                    if (!core[y * w + x]) continue;
                    bool ok = false;
                    for (int oy = -chkR; oy <= chkR && !ok; oy += 2)
                        for (int ox = -chkR; ox <= chkR && !ok; ox += 2) {
                            int nx = x + ox, ny = y + oy;
                            if (nx >= 0 && nx < w && ny >= 0 && ny < h && hasW[ny * w + nx]) ok = true;
                        }
                    if (ok) filt[y * w + x] = true;
                }
            core = filt;
        }
        bool[] mask = new bool[w * h];
        int r2 = haloR * haloR + 2;
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                if (!core[y * w + x]) continue;
                int gx = x0 + x, gy = y0 + y;
                if (gx < tx0) tx0 = gx; if (gx > tx1) tx1 = gx;
                if (gy < ty0) ty0 = gy; if (gy > ty1) ty1 = gy;
                for (int oy = -haloR; oy <= haloR; oy++)
                    for (int ox = -haloR; ox <= haloR; ox++) {
                        if (ox * ox + oy * oy > r2) continue;
                        int nx = x + ox, ny = y + oy;
                        if (nx >= 0 && nx < w && ny >= 0 && ny < h) mask[ny * w + nx] = true;
                    }
            }
        string smearWarn = AuditHarmonicSmear(before, mask, x0, y0, x1, y1);
        HarmonicInpaint(img, mask, x0, y0, x1, y1, iters, dirDx, dirDy);
        if (tx1 < tx0 && smearWarn == null) return null;
        var m = new BubbleMetrics();
        if (tx1 >= tx0) {
            m.orig_text_bbox = new int[] { tx0, ty0, tx1 - tx0 + 1, ty1 - ty0 + 1 };
            m.orig_text_center = new int[] { (tx0 + tx1) / 2, (ty0 + ty1) / 2 };
            m.optical_center = m.orig_text_center;
        }
        if (smearWarn != null) m.warning = smearWarn;
        return m;
    }

    public static BubbleMetrics CleanTranslucentDark(FastImg img, int x0, int y0, int x1, int y1, int darkThresh, int dilateR, int iters, double dirDx, double dirDy) {
        x0 = Math.Max(1, x0); y0 = Math.Max(1, y0);
        x1 = Math.Min(img.W - 2, x1); y1 = Math.Min(img.H - 2, y1);
        int w = x1 - x0 + 1, h = y1 - y0 + 1;
        var before = img.CloneBuf();
        bool[] mask = new bool[w * h];
        int tx0 = img.W, ty0 = img.H, tx1 = -1, ty1 = -1;
        int r2 = dilateR * dilateR + 1;
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                byte r, g, b; img.GetRgb(x0 + x, y0 + y, out r, out g, out b);
                if ((r + g + b) / 3 <= darkThresh) {
                    int gx = x0 + x, gy = y0 + y;
                    if (gx < tx0) tx0 = gx; if (gx > tx1) tx1 = gx;
                    if (gy < ty0) ty0 = gy; if (gy > ty1) ty1 = gy;
                    for (int oy = -dilateR; oy <= dilateR; oy++)
                        for (int ox = -dilateR; ox <= dilateR; ox++) {
                            if (ox * ox + oy * oy > r2) continue;
                            int nx = x + ox, ny = y + oy;
                            if (nx >= 0 && nx < w && ny >= 0 && ny < h) mask[ny * w + nx] = true;
                        }
                }
            }
        string smearWarn = AuditHarmonicSmear(before, mask, x0, y0, x1, y1);
        HarmonicInpaint(img, mask, x0, y0, x1, y1, iters, dirDx, dirDy);
        if (tx1 < tx0 && smearWarn == null) return null;
        var m = new BubbleMetrics();
        if (tx1 >= tx0) {
            m.orig_text_bbox = new int[] { tx0, ty0, tx1 - tx0 + 1, ty1 - ty0 + 1 };
            m.orig_text_center = new int[] { (tx0 + tx1) / 2, (ty0 + ty1) / 2 };
            m.optical_center = m.orig_text_center;
        }
        if (smearWarn != null) m.warning = smearWarn;
        return m;
    }

    public static long[] SaveDiffHeatmap(FastImg before, FastImg after, string path, int jpegQuality) {
        int W = after.W, H = after.H;
        var vis = after.CloneBuf();
        long majorCnt = 0, subtleCnt = 0;
        for (int y = 0; y < H; y++) {
            for (int x = 0; x < W; x++) {
                byte r0, g0, b0, r1, g1, b1;
                before.GetRgb(x, y, out r0, out g0, out b0);
                after.GetRgb(x, y, out r1, out g1, out b1);
                int dr = Math.Abs(r0 - r1);
                int dg = Math.Abs(g0 - g1);
                int db = Math.Abs(b0 - b1);
                int dMax = Math.Max(dr, Math.Max(dg, db));
                if (dMax >= 45) {
                    majorCnt++;
                    byte rr = (byte)Math.Min(255, (int)(r1 * 0.42 + 255 * 0.58));
                    byte gg = (byte)Math.Min(255, (int)(g1 * 0.42 + 0 * 0.58));
                    byte bb = (byte)Math.Min(255, (int)(b1 * 0.42 + 180 * 0.58));
                    vis.SetRgb(x, y, rr, gg, bb);
                } else if (dMax >= 10) {
                    subtleCnt++;
                    byte rr = (byte)Math.Min(255, (int)(r1 * 0.35 + 0 * 0.65));
                    byte gg = (byte)Math.Min(255, (int)(g1 * 0.35 + 195 * 0.65));
                    byte bb = (byte)Math.Min(255, (int)(b1 * 0.35 + 255 * 0.65));
                    vis.SetRgb(x, y, rr, gg, bb);
                } else {
                    vis.SetRgb(x, y, (byte)(r1 * 0.90), (byte)(g1 * 0.90), (byte)(b1 * 0.90));
                }
            }
        }
        using (var bmp = new Bitmap(W, H, PixelFormat.Format32bppArgb)) {
            var bd = bmp.LockBits(new Rectangle(0, 0, W, H), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
            Marshal.Copy(vis.Buf, 0, bd.Scan0, vis.Buf.Length);
            bmp.UnlockBits(bd);
            string ext = System.IO.Path.GetExtension(path).ToLowerInvariant();
            if (ext == ".jpg" || ext == ".jpeg") {
                ImageCodecInfo jpgCodec = null;
                foreach (var c in ImageCodecInfo.GetImageEncoders()) {
                    if (c.MimeType == "image/jpeg") { jpgCodec = c; break; }
                }
                if (jpgCodec != null) {
                    using (var ep = new EncoderParameters(1)) {
                        ep.Param[0] = new EncoderParameter(Encoder.Quality, (long)jpegQuality);
                        bmp.Save(path, jpgCodec, ep);
                    }
                } else {
                    bmp.Save(path, ImageFormat.Jpeg);
                }
            } else {
                bmp.Save(path, ImageFormat.Png);
            }
        }
        return new long[] { majorCnt, subtleCnt };
    }
}
'@

if (-not ("MangaBubbleCleanerV3" -as [type])) {
    Add-Type -TypeDefinition $csCode -ReferencedAssemblies System.Drawing
} else {
    Add-Type -AssemblyName System.Drawing
}

$swTimer = [System.Diagnostics.Stopwatch]::StartNew()
$orig = [System.Drawing.Bitmap]::FromFile((Resolve-Path -LiteralPath $ImagePath).Path)
$img = New-Object FastImg($orig)
$orig.Dispose()
$origBefore = if ($DiffOut) { $img.CloneBuf() } else { $null }

$jsonRaw = [System.IO.File]::ReadAllText($PlanPath, [System.Text.Encoding]::UTF8)
$plan = $jsonRaw | ConvertFrom-Json
$ops = if ($plan.operations) { $plan.operations } else { $plan }
$measuredBoxes = @{}

foreach ($op in $ops) {
    $type = $op.type
    $opId = if ($op.id) { [string]$op.id } else { "op" }
    $x0 = 0; $y0 = 0; $x1 = 0; $y1 = 0
    if ($op.box) {
        $x0 = [int]$op.box[0]; $y0 = [int]$op.box[1]; $x1 = [int]$op.box[2]; $y1 = [int]$op.box[3]
    }

    $keepRects = $null
    if ($op.keep_rects) {
        $list = New-Object System.Collections.Generic.List[System.Drawing.Rectangle]
        foreach ($kr in $op.keep_rects) {
            $list.Add((New-Object System.Drawing.Rectangle([int]$kr[0], [int]$kr[1], [int]$kr[2], [int]$kr[3])))
        }
        $keepRects = $list.ToArray()
    }
    $openSide = if ($op.open_side) { [string]$op.open_side } else { "" }
    $metrics = $null

    switch ($type) {
        "white_bubble" {
            $thresh = if ($op.thresh) { [int]$op.thresh } else { 220 }
            $metrics = [MangaBubbleCleanerV3]::CleanWhiteBubble($img, $x0, $y0, $x1, $y1, [int]$op.seed[0], [int]$op.seed[1], $thresh, $openSide, $keepRects)
        }
        "black_bubble" {
            $thresh = if ($op.thresh) { [int]$op.thresh } else { 80 }
            $fr = if ($op.fill_rgb) { [byte]$op.fill_rgb[0] } else { [byte]10 }
            $fg = if ($op.fill_rgb) { [byte]$op.fill_rgb[1] } else { [byte]10 }
            $fb = if ($op.fill_rgb) { [byte]$op.fill_rgb[2] } else { [byte]10 }
            $metrics = [MangaBubbleCleanerV3]::CleanBlackBubble($img, $x0, $y0, $x1, $y1, [int]$op.seed[0], [int]$op.seed[1], $thresh, $openSide, $keepRects, $fr, $fg, $fb)
        }
        "color_flood" {
            $tol = if ($op.tol) { [int]$op.tol } else { 32 }
            $metrics = [MangaBubbleCleanerV3]::CleanColorFlood($img, $x0, $y0, $x1, $y1, [int]$op.seed[0], [int]$op.seed[1], $tol, $openSide, $keepRects)
        }
        "solid_rect" {
            $fr = [byte]255; $fg = [byte]255; $fb = [byte]255
            if ($op.rgb) {
                $fr = [byte]$op.rgb[0]; $fg = [byte]$op.rgb[1]; $fb = [byte]$op.rgb[2]
            } elseif ($op.sample) {
                $img.GetRgb([int]$op.sample[0], [int]$op.sample[1], [ref]$fr, [ref]$fg, [ref]$fb)
            }
            $metrics = [MangaBubbleCleanerV3]::FillRect($img, $x0, $y0, $x1, $y1, $fr, $fg, $fb)
        }
        "poly_fill" {
            $pts = New-Object System.Collections.Generic.List[System.Drawing.Point]
            foreach ($pt in $op.points) { $pts.Add((New-Object System.Drawing.Point([int]$pt[0], [int]$pt[1]))) }
            $fr = if ($op.rgb) { [byte]$op.rgb[0] } else { [byte]255 }
            $fg = if ($op.rgb) { [byte]$op.rgb[1] } else { [byte]255 }
            $fb = if ($op.rgb) { [byte]$op.rgb[2] } else { [byte]255 }
            $metrics = [MangaBubbleCleanerV3]::FillPolygon($img, $pts.ToArray(), $fr, $fg, $fb)
        }
        "interp_v" {
            $pad = if ($op.pad) { [int]$op.pad } else { 4 }
            $wMsg = [MangaBubbleCleanerV3]::InterpV($img, $x0, $y0, $x1, $y1, $pad)
            if ($wMsg) { Write-Host "[CleanAudit] ${opId}: $wMsg" }
        }
        "interp_h" {
            $pad = if ($op.pad) { [int]$op.pad } else { 4 }
            $wMsg = [MangaBubbleCleanerV3]::InterpH($img, $x0, $y0, $x1, $y1, $pad)
            if ($wMsg) { Write-Host "[CleanAudit] ${opId}: $wMsg" }
        }
        "copy_col" {
            $srcX = [int]$op.src_x
            if ($op.points) {
                $pts = New-Object System.Collections.Generic.List[System.Drawing.Point]
                foreach ($pt in $op.points) { $pts.Add((New-Object System.Drawing.Point([int]$pt[0], [int]$pt[1]))) }
                [MangaBubbleCleanerV3]::CopyColPolygon($img, $pts.ToArray(), $srcX)
            } else {
                [MangaBubbleCleanerV3]::CopyColRect($img, $x0, $y0, $x1, $y1, $srcX)
            }
        }
        "copy_row" {
            $srcY = [int]$op.src_y
            if ($op.points) {
                $pts = New-Object System.Collections.Generic.List[System.Drawing.Point]
                foreach ($pt in $op.points) { $pts.Add((New-Object System.Drawing.Point([int]$pt[0], [int]$pt[1]))) }
                [MangaBubbleCleanerV3]::CopyRowPolygon($img, $pts.ToArray(), $srcY)
            } else {
                [MangaBubbleCleanerV3]::CopyRowRect($img, $x0, $y0, $x1, $y1, $srcY)
            }
        }
        "copy_along_dir" {
            $ptsArr = $null
            if ($op.points) {
                $pts = New-Object System.Collections.Generic.List[System.Drawing.Point]
                foreach ($pt in $op.points) { $pts.Add((New-Object System.Drawing.Point([int]$pt[0], [int]$pt[1]))) }
                $ptsArr = $pts.ToArray()
            }
            $ddx = if ($op.dir) { [double]$op.dir[0] } else { 1.0 }
            $ddy = if ($op.dir) { [double]$op.dir[1] } else { 0.0 }
            $side = if ($op.side) { [string]$op.side } else { "both" }
            $onlyDark = ($op.only_dark -eq $true)
            $dt = if ($op.dark_thresh) { [int]$op.dark_thresh } else { 185 }
            $dr = if ($null -ne $op.dilate) { [int]$op.dilate } else { 2 }
            $ms = if ($op.max_steps) { [int]$op.max_steps } else { 260 }
            $metrics = [MangaBubbleCleanerV3]::CopyAlongDir($img, $x0, $y0, $x1, $y1, $ptsArr, $ddx, $ddy, $side, $onlyDark, $dt, $dr, $ms)
        }
        "patch_copy" {
            $ptsArr = $null
            if ($op.points) {
                $pts = New-Object System.Collections.Generic.List[System.Drawing.Point]
                foreach ($pt in $op.points) { $pts.Add((New-Object System.Drawing.Point([int]$pt[0], [int]$pt[1]))) }
                $ptsArr = $pts.ToArray()
            }
            $offX = if ($op.offset) { [int]$op.offset[0] } else { 0 }
            $offY = if ($op.offset) { [int]$op.offset[1] } else { 0 }
            $autoAlign = if ($null -ne $op.auto_align) { ($op.auto_align -eq $true) } else { $true }
            $sRad = if ($null -ne $op.search_radius) { [int]$op.search_radius } else { 4 }
            $onlyDark = ($op.only_dark -eq $true)
            $dt = if ($op.dark_thresh) { [int]$op.dark_thresh } else { 185 }
            $dr = if ($null -ne $op.dilate) { [int]$op.dilate } else { 2 }
            $metrics = [MangaBubbleCleanerV3]::PatchCopy($img, $x0, $y0, $x1, $y1, $ptsArr, $offX, $offY, $autoAlign, $sRad, $onlyDark, $dt, $dr)
        }
        "draw_lines" {
            $polyList = New-Object System.Collections.Generic.List[System.Drawing.PointF[]]
            $wList = New-Object System.Collections.Generic.List[float]
            $cList = New-Object System.Collections.Generic.List[System.Drawing.Color]
            $sList = New-Object System.Collections.Generic.List[bool]
            foreach ($ln in $op.lines) {
                $pfList = New-Object System.Collections.Generic.List[System.Drawing.PointF]
                foreach ($pt in $ln.points) { $pfList.Add((New-Object System.Drawing.PointF([float]$pt[0], [float]$pt[1]))) }
                $polyList.Add($pfList.ToArray())
                $wList.Add($(if ($ln.width) { [float]$ln.width } else { [float]2.5 }))
                $cRgb = if ($ln.rgb) { $ln.rgb } else { @(0, 0, 0) }
                $cList.Add([System.Drawing.Color]::FromArgb(255, [int]$cRgb[0], [int]$cRgb[1], [int]$cRgb[2]))
                $sList.Add(($ln.smooth -eq $true))
            }
            [MangaBubbleCleanerV3]::DrawLinesOnImg($img, $polyList.ToArray(), $wList.ToArray(), $cList.ToArray(), $sList.ToArray())
        }
        "translucent_halo" {
            $ddx = if ($op.dir) { [double]$op.dir[0] } else { 0.0 }
            $ddy = if ($op.dir) { [double]$op.dir[1] } else { 0.0 }
            $defIt = if ($img.W -ge 1500) { 380 } else { 140 }
            $it = if ($op.iters) { [int]$op.iters } else { $defIt }
            if ($op.anchored -eq $true) {
                $bm = if ($op.black_max) { [int]$op.black_max } else { 70 }
                $defHR = [Math]::Max(4, [int][Math]::Round($img.W / 200.0))
                $hr = if ($op.halo_radius) { [int]$op.halo_radius } else { $defHR }
                $wc = if ($op.white_check) { [int]$op.white_check } else { 0 }
                $metrics = [MangaBubbleCleanerV3]::CleanTranslucentAnchored($img, $x0, $y0, $x1, $y1, $bm, $hr, $wc, $it, $ddx, $ddy)
            } else {
                $wt = if ($op.white_thresh) { [int]$op.white_thresh } else { 205 }
                $defDr = if ($img.W -ge 1500) { 5 } else { 2 }
                $dr = if ($op.dilate) { [int]$op.dilate } else { $defDr }
                $metrics = [MangaBubbleCleanerV3]::CleanTranslucentHalo($img, $x0, $y0, $x1, $y1, $wt, $dr, $it, $ddx, $ddy)
            }
        }
        "translucent_anchored" {
            $bm = if ($op.black_max) { [int]$op.black_max } else { 70 }
            $defHR = [Math]::Max(4, [int][Math]::Round($img.W / 200.0))
            $hr = if ($op.halo_radius) { [int]$op.halo_radius } else { $defHR }
            $wc = if ($op.white_check) { [int]$op.white_check } else { 0 }
            $defIt = if ($img.W -ge 1500) { 380 } else { 160 }
            $it = if ($op.iters) { [int]$op.iters } else { $defIt }
            $ddx = if ($op.dir) { [double]$op.dir[0] } else { 0.0 }
            $ddy = if ($op.dir) { [double]$op.dir[1] } else { 0.0 }
            $metrics = [MangaBubbleCleanerV3]::CleanTranslucentAnchored($img, $x0, $y0, $x1, $y1, $bm, $hr, $wc, $it, $ddx, $ddy)
        }
        "translucent_dark" {
            $dt = if ($op.dark_thresh) { [int]$op.dark_thresh } else { 170 }
            $defDr = if ($img.W -ge 1500) { 4 } else { 2 }
            $dr = if ($op.dilate) { [int]$op.dilate } else { $defDr }
            $defIt = if ($img.W -ge 1500) { 360 } else { 140 }
            $it = if ($op.iters) { [int]$op.iters } else { $defIt }
            $ddx = if ($op.dir) { [double]$op.dir[0] } else { 0.0 }
            $ddy = if ($op.dir) { [double]$op.dir[1] } else { 0.0 }
            $metrics = [MangaBubbleCleanerV3]::CleanTranslucentDark($img, $x0, $y0, $x1, $y1, $dt, $dr, $it, $ddx, $ddy)
        }
        default {
            Write-Warning "Unknown clean op type: $type"
        }
    }

    if ($null -ne $metrics) {
        if ($metrics.warning) { Write-Host "[CleanAudit] ${opId}: $($metrics.warning)" }
        $entry = [ordered]@{}
        if ($metrics.optical_center)   { $entry["optical_center"]   = $metrics.optical_center }
        if ($metrics.safe_rect)        { $entry["safe_rect"]        = $metrics.safe_rect }
        if ($metrics.bubble_bbox)      { $entry["bubble_bbox"]      = $metrics.bubble_bbox }
        if ($metrics.orig_text_center) { $entry["orig_text_center"] = $metrics.orig_text_center }
        if ($metrics.orig_text_bbox)   { $entry["orig_text_bbox"]   = $metrics.orig_text_bbox }
        if ($metrics.warning)          { $entry["warning"]          = $metrics.warning }
        $measuredBoxes[$opId] = $entry
    }
}

$outParent = Split-Path -Parent $OutputPath
if ($outParent) { New-Item -ItemType Directory -Force -Path $outParent | Out-Null }
$img.SavePng($OutputPath)

if ($BoxesOut) {
    $bJson = $measuredBoxes | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($BoxesOut, $bJson, (New-Object System.Text.UTF8Encoding $false))
}
if ($DiffOut -and $null -ne $origBefore) {
    $diffParent = Split-Path -Parent $DiffOut
    if ($diffParent) { New-Item -ItemType Directory -Force -Path $diffParent | Out-Null }
    $counts = [MangaBubbleCleanerV3]::SaveDiffHeatmap($origBefore, $img, $DiffOut, 88)
    Write-Host "[CleanDiff] Saved: $DiffOut (major=$($counts[0])px, subtle=$($counts[1])px)"
}
$swTimer.Stop()
Write-Host "CleanBubblesV3Saved: $OutputPath ($($ops.Count) ops in $($swTimer.ElapsedMilliseconds)ms)"
