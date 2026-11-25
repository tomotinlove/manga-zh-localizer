param(
    [switch]$KeepTmp
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptsDir = Join-Path $repoRoot "skills\manga-zh-localizer\scripts"
$batchScript = Join-Path $scriptsDir "batch_job.ps1"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$runId = "smoke_" + [guid]::NewGuid().ToString("N").Substring(0, 8)
$smokeRoot = Join-Path $repoRoot ("_smoke_tmp\" + $runId)
$inDir = Join-Path $smokeRoot "inbox"
$tmpDir = Join-Path $smokeRoot "tmp"
$outDir = Join-Path $smokeRoot "out"
New-Item -ItemType Directory -Force -Path $inDir, $tmpDir, $outDir | Out-Null

function New-SyntheticMangaPage([string]$Path, [int]$PageNum) {
    $W = 800; $H = 1000
    $bmp = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    # Crisp checkered artwork background outside bubbles (used to verify 0-pixel lossless preservation)
    $g.Clear([System.Drawing.Color]::FromArgb(215, 224, 236))
    $penGrid = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(145, 162, 185), 2)
    for ($x = 20; $x -lt $W; $x += 40) { $g.DrawLine($penGrid, $x, 0, $x, $H) }
    for ($y = 20; $y -lt $H; $y += 40) { $g.DrawLine($penGrid, 0, $y, $W, $y) }

    # Outer panel border
    $penBlack = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(15, 15, 15), 5)
    $g.DrawRectangle($penBlack, 24, 24, $W - 48, $H - 48)

    $brBlack = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(18, 18, 18))
    $brWhite = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $penBubble = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(12, 12, 12), 4)

    if ($PageNum -eq 0) {
        # Bubble 1: Pure white ellipse with protruding tail on left + dark fake source strokes
        $g.FillEllipse($brWhite, 450, 90, 240, 320)
        $g.DrawEllipse($penBubble, 450, 90, 240, 320)
        # Simulated Japanese vertical strokes inside bubble 1
        $g.FillRectangle($brBlack, 545, 165, 16, 155)
        $g.FillRectangle($brBlack, 585, 175, 16, 130)
        $g.FillRectangle($brBlack, 520, 210, 95, 12)

        # Bubble 2: Grey flashback bubble (RGB 230,230,230) to verify color_flood preserves tint
        $brGrey = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(230, 230, 230))
        $g.FillEllipse($brGrey, 100, 480, 250, 310)
        $g.DrawEllipse($penBubble, 100, 480, 250, 310)
        $g.FillRectangle($brBlack, 195, 555, 16, 150)
        $g.FillRectangle($brBlack, 235, 570, 16, 125)
        $brGrey.Dispose()
    } else {
        # Page 1: Tinted pink bubble + white-stroked dark text
        $brPink = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(250, 205, 215))
        $g.FillEllipse($brPink, 440, 110, 250, 330)
        $g.DrawEllipse($penBubble, 440, 110, 250, 330)
        $g.FillRectangle($brWhite, 536, 190, 26, 155)
        $g.FillRectangle($brBlack, 541, 195, 16, 145)
        $g.FillRectangle($brWhite, 578, 200, 26, 135)
        $g.FillRectangle($brBlack, 583, 205, 16, 125)
        $brPink.Dispose()

        # White bubble 2 on bottom left
        $g.FillEllipse($brWhite, 110, 500, 240, 300)
        $g.DrawEllipse($penBubble, 110, 500, 240, 300)
        $g.FillRectangle($brBlack, 205, 575, 18, 145)
        $g.FillRectangle($brBlack, 242, 585, 16, 120)
    }

    $penGrid.Dispose(); $penBlack.Dispose(); $penBubble.Dispose(); $brBlack.Dispose(); $brWhite.Dispose()
    $g.Dispose()
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

function Assert-UntouchedRegionZeroDiff([string]$OrigPath, [string]$OutPath, [int]$X0, [int]$Y0, [int]$X1, [int]$Y1) {
    $b1 = [System.Drawing.Bitmap]::FromFile($OrigPath)
    $b2 = [System.Drawing.Bitmap]::FromFile($OutPath)
    try {
        if ($b1.Width -ne $b2.Width -or $b1.Height -ne $b2.Height) {
            throw ("Dimension mismatch: orig={0}x{1} vs out={2}x{3}" -f $b1.Width, $b1.Height, $b2.Width, $b2.Height)
        }
        $diff = 0
        for ($y = $Y0; $y -le $Y1; $y += 2) {
            for ($x = $X0; $x -le $X1; $x += 2) {
                if ($b1.GetPixel($x, $y).ToArgb() -ne $b2.GetPixel($x, $y).ToArgb()) {
                    $diff++
                }
            }
        }
        if ($diff -gt 0) {
            throw ("Lossless check FAILED on ({0},{1})-({2},{3}): {4} pixels differed!" -f $X0, $Y0, $X1, $Y1, $diff)
        }
    } finally {
        $b1.Dispose(); $b2.Dispose()
    }
}

try {
    Write-Host "=== [1/5] Environment doctor ==="
    & $batchScript -Mode doctor -InboxDir $inDir -OutDir $outDir -TmpDir $tmpDir
    if ($LASTEXITCODE -ne 0) { throw "doctor failed with exit code $LASTEXITCODE" }

    Write-Host "=== [2/5] Generate synthetic 2-page manga ==="
    $p0 = Join-Path $inDir "sample_p0.png"
    $p1 = Join-Path $inDir "sample_p1.png"
    New-SyntheticMangaPage -Path $p0 -PageNum 0
    New-SyntheticMangaPage -Path $p1 -PageNum 1

    Write-Host "=== [3/5] Turn 1: Parallel scan ==="
    $scanOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $batchScript -Mode scan -Images "$p0|$p1" -Job "smoke_comic" -InboxDir $inDir -OutDir $outDir -TmpDir $tmpDir 2>&1
    $scanCode = $LASTEXITCODE
    $scanOut | ForEach-Object { Write-Host $_ }
    if ($scanCode -ne 0) { throw "scan failed with exit code $scanCode" }

    $jobDir = Join-Path $tmpDir "smoke_comic"
    foreach ($req in @("job_manifest.json", "preview_sheet.jpg", "p0\bubbles_auto.json", "p1\bubbles_auto.json")) {
        $fp = Join-Path $jobDir $req
        if (-not (Test-Path -LiteralPath $fp)) { throw "Missing scan output: $fp" }
    }

    Write-Host "=== [4/5] Turn 2: Parallel clean + 2xSS typeset ==="
    $clean0 = @{
        operations = @(
            @{ id = "b1_white"; type = "white_bubble"; box = @(445, 85, 695, 415); seed = @(570, 120); thresh = 220 },
            @{ id = "b2_grey";  type = "color_flood";  box = @(95, 475, 355, 795); seed = @(225, 515); tol = 32 }
        )
    }
    $clean1 = @{
        operations = @(
            @{ id = "b1_pink";  type = "color_flood";  box = @(435, 105, 695, 445); seed = @(565, 140); tol = 80 },
            @{ id = "b2_white"; type = "white_bubble"; box = @(105, 495, 355, 805); seed = @(230, 530); thresh = 220 }
        )
    }

    # Build Chinese text via Unicode escapes so this .ps1 stays pure ASCII
    $txtP0B1L1 = -join ([char[]]@(0x4ECA,0x5929,0x5929,0x6C14,0x771F,0x597D))
    $txtP0B1L2 = -join ([char[]]@(0x4E00,0x8D77,0x53BB,0x5496,0x5561,0x9986,0x5427,0xFF5E))
    $txtP0B2L1 = -join ([char[]]@(0x5514,0x2026,0x2026,0x8FD9,0x662F))
    $txtP0B2L2 = -join ([char[]]@(0x56DE,0x5FC6,0x6C14,0x6CE1,0x5417))

    $txtP1B1L1 = -join ([char[]]@(0x592A,0x68D2,0x4E86,0x2049))
    $txtP1B1L2 = "Ave " + (-join ([char[]]@(0x6F14,0x51FA,0x5F00,0x59CB,0x4E86)))
    $txtP1B2L1 = -join ([char[]]@(0x65E0,0x635F,0x6392,0x7248,0x2014))
    $txtP1B2L2 = -join ([char[]]@(0x5B8C,0x7F8E,0x5C45,0x4E2D))

    $layout0 = @{
        meta = @{ title = "Smoke Page 0"; series = "smoke" }
        blocks = @(
            @{ id = 1; rect = @(485, 130, 170, 240); preset = "dialogue"; font_size = 20; line_height = 1.30; optical_center = $true; lines = @($txtP0B1L1, $txtP0B1L2) },
            @{ id = 2; rect = @(140, 520, 170, 230); preset = "serif";    font_size = 20; line_height = 1.30; optical_center = $true; lines = @($txtP0B2L1, $txtP0B2L2) }
        )
    }
    $layout1 = @{
        meta = @{ title = "Smoke Page 1"; series = "smoke" }
        blocks = @(
            @{ id = 1; rect = @(475, 150, 180, 250); preset = "round";    font_size = 20; line_height = 1.30; optical_center = $true; stroke = @{ color = "#ffffff"; width = 2 }; lines = @($txtP1B1L1, $txtP1B1L2) },
            @{ id = 2; rect = @(145, 540, 170, 220); preset = "dialogue"; font_size = 20; line_height = 1.30; optical_center = $true; lines = @($txtP1B2L1, $txtP1B2L2) }
        )
    }

    [System.IO.File]::WriteAllText((Join-Path $jobDir "p0\clean_plan.json"), ($clean0 | ConvertTo-Json -Depth 6), $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $jobDir "p1\clean_plan.json"), ($clean1 | ConvertTo-Json -Depth 6), $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $jobDir "p0\layout.json"), ($layout0 | ConvertTo-Json -Depth 6), $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $jobDir "p1\layout.json"), ($layout1 | ConvertTo-Json -Depth 6), $utf8NoBom)

    $buildOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $batchScript -Mode build -Job "smoke_comic" -InboxDir $inDir -OutDir $outDir -TmpDir $tmpDir 2>&1
    $buildCode = $LASTEXITCODE
    $buildText = ($buildOut | Out-String)
    Write-Host $buildText
    if ($buildCode -ne 0) { throw "build failed with exit code $buildCode" }

    foreach ($warnPat in @("WARN_BORDER_HITS", "WARN_OFFCENTER", "WARN_RECT_OVERLAP", "WARN_GREY_BUBBLE_SEED", "WARN_HARMONIC_SMEAR", "WARN_INTERP_DARK_EDGE")) {
        if ($buildText -match $warnPat) { throw "Unexpected audit warning detected during smoke build: $warnPat" }
    }

    # Verify lossless preservation on untouched artwork regions + grey tint preserved
    $zh0 = Join-Path $jobDir "p0\sample_p0_zh.png"
    $zh1 = Join-Path $jobDir "p1\sample_p1_zh.png"
    Assert-UntouchedRegionZeroDiff -OrigPath $p0 -OutPath $zh0 -X0 40 -Y0 40 -X1 380 -Y1 420
    Assert-UntouchedRegionZeroDiff -OrigPath $p1 -OutPath $zh1 -X0 40 -Y0 40 -X1 380 -Y1 440

    # Verify grey bubble (230,230,230) was NOT bleached to 255
    $clean0Bmp = [System.Drawing.Bitmap]::FromFile((Join-Path $jobDir "p0\clean_final.png"))
    $greyPx = $clean0Bmp.GetPixel(225, 515)
    $clean0Bmp.Dispose()
    if ([Math]::Abs($greyPx.R - 230) -gt 2) { throw ("Grey bubble tint not preserved! Got RGB({0},{1},{2})" -f $greyPx.R, $greyPx.G, $greyPx.B) }
    Write-Host "[OK]   Lossless untouched artwork diff = 0px, grey bubble RGB preserved (230,230,230)"

    Write-Host "=== [5/5] Turn 3: Package ordered folder + vertical long strip ==="
    $pkgOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $batchScript -Mode package -Job "smoke_comic" -InboxDir $inDir -OutDir $outDir -TmpDir $tmpDir 2>&1
    $pkgCode = $LASTEXITCODE
    $pkgOut | ForEach-Object { Write-Host $_ }
    if ($pkgCode -ne 0) { throw "package failed with exit code $pkgCode" }

    $pkgDir = Join-Path $outDir "smoke_comic"
    $longFile = Join-Path $pkgDir "00_smoke_comic_long_zh.png"
    $ord1 = Join-Path $pkgDir "01_sample_p0_zh.png"
    $ord2 = Join-Path $pkgDir "02_sample_p1_zh.png"
    foreach ($f in @($longFile, $ord1, $ord2)) {
        if (-not (Test-Path -LiteralPath $f)) { throw "Missing packaged output: $f" }
    }
    $t1 = (Get-Item -LiteralPath $ord1).LastWriteTimeUtc
    $t2 = (Get-Item -LiteralPath $ord2).LastWriteTimeUtc
    if ($t2 -le $t1) { throw "Monotonic timestamp check failed: 01=$t1 >= 02=$t2" }

    Write-Host "============================================================"
    Write-Host "  SMOKE TEST PASSED (doctor + scan + build + lossless + package)"
    Write-Host "============================================================"
} finally {
    if (-not $KeepTmp -and (Test-Path -LiteralPath $smokeRoot)) {
        Remove-Item -LiteralPath $smokeRoot -Recurse -Force -ErrorAction SilentlyContinue
        $smokeParent = Join-Path $repoRoot "_smoke_tmp"
        if ((Test-Path -LiteralPath $smokeParent) -and @(Get-ChildItem -LiteralPath $smokeParent).Count -eq 0) {
            Remove-Item -LiteralPath $smokeParent -Force -ErrorAction SilentlyContinue
        }
    }
}
