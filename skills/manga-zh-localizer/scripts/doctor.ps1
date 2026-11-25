param(
    [string]$ConfigPath = "",
    [string]$InboxDir = "",
    [string]$OutDir = "",
    [string]$TmpDir = "",
    [string]$BrowserPath = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_common.ps1")

$cfg = Get-MangaLocalizerConfig `
    -ScriptDir $PSScriptRoot `
    -ConfigPath $ConfigPath `
    -InboxDir $InboxDir `
    -OutDir $OutDir `
    -TmpDir $TmpDir `
    -BrowserPath $BrowserPath

$issues = @()
Write-Host "============================================================"
Write-Host "  manga-zh-localizer Environment Doctor (v4.4.0)"
Write-Host "============================================================"

# 1. PowerShell & .NET System.Drawing
Write-Host ("[OK]   PowerShell : {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
try {
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap(4, 4)
    $bmp.Dispose()
    Write-Host "[OK]   .NET GDI+  : System.Drawing LockBits ready"
} catch {
    $issues += "System.Drawing unavailable: $($_.Exception.Message)"
    Write-Host "[FAIL] .NET GDI+  : $($_.Exception.Message)"
}

# 2. Headless Browser
if ($cfg.BrowserBin) {
    Write-Host ("[OK]   Browser    : {0}" -f $cfg.BrowserBin)
} else {
    $issues += "No headless Chromium/Edge/Chrome browser found."
    Write-Host "[FAIL] Browser    : Not found (install Microsoft Edge or Google Chrome, or set MANGA_BROWSER_BIN)"
}

# 3. Installed CJK Fonts
try {
    $ifc = New-Object System.Drawing.Text.InstalledFontCollection
    $famNames = @($ifc.Families | ForEach-Object { $_.Name })
    $checkFonts = @(
        @{ Label = "dialogue/narration"; Names = @("Microsoft YaHei", "Source Han Sans SC", "Microsoft JhengHei") },
        @{ Label = "scream";             Names = @("SimHei", "Source Han Sans SC Heavy") },
        @{ Label = "serif";              Names = @("STZhongsong", "Source Han Serif SC", "SimSun") },
        @{ Label = "handwritten";        Names = @("STKaiti", "LXGW WenKai", "KaiTi") },
        @{ Label = "round";              Names = @("YouYuan", "Source Han Rounded SC") },
        @{ Label = "brush";              Names = @("STXingkai", "FZShuTi") }
    )
    foreach ($cf in $checkFonts) {
        $hits = @($cf.Names | Where-Object { $famNames -contains $_ })
        if ($hits.Count -gt 0) {
            Write-Host ("[OK]   Font ({0,-18}): {1}" -f $cf.Label, ($hits -join ", "))
        } else {
            Write-Host ("[WARN] Font ({0,-18}): none of [{1}] installed (will fall back)" -f $cf.Label, ($cf.Names -join ", "))
        }
    }
} catch {
    Write-Host "[WARN] Font check skipped: $($_.Exception.Message)"
}

# 4. Resolved Paths & Config Sources
Write-Host "------------------------------------------------------------"
Write-Host ("ScriptDir      : {0}" -f $cfg.ScriptDir)
Write-Host ("Configs loaded : {0}" -f $(if ($cfg.LoadedConfigs.Count -gt 0) { $cfg.LoadedConfigs -join " -> " } else { "(none; using defaults)" }))
Write-Host ("User config    : {0} ({1})" -f $cfg.UserConfigPath, $(if (Test-Path -LiteralPath $cfg.UserConfigPath) { "exists" } else { "not created yet" }))
Write-Host ("InboxDir       : {0} ({1})" -f $cfg.InboxDir, $(if (Test-Path -LiteralPath $cfg.InboxDir) { "exists" } else { "pass -Images or create dir" }))
Write-Host ("OutDir         : {0} ({1})" -f $cfg.OutDir, $(if (Test-Path -LiteralPath $cfg.OutDir) { "exists" } else { "auto-created on package" }))
Write-Host ("TmpDir         : {0} ({1})" -f $cfg.TmpDir, $(if (Test-Path -LiteralPath $cfg.TmpDir) { "exists" } else { "auto-created on scan" }))
Write-Host ("Defaults       : MaxParallel={0}, SuperSample={1}, ColWidth={2}" -f $cfg.MaxParallel, $cfg.SuperSample, $cfg.ColWidth)

# 5. Glossaries
$glossaries = @(Get-MangaGlossaries -GlossaryDirs $cfg.GlossaryDirs)
Write-Host ("Glossary dirs  : {0}" -f ($cfg.GlossaryDirs -join " ; "))
Write-Host ("Glossaries     : {0}" -f $(if ($glossaries.Count -gt 0) { $glossaries -join " | " } else { "(none active; copy _template.json to ~/.manga-zh-localizer/glossaries/)" }))

# 6. Optional gallery-dl
$gdl = Get-Command gallery-dl -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1
if (-not $gdl) {
    $gdl = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\mikf.gallery-dl*" -Recurse -Filter "gallery-dl.exe" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName -First 1
}
Write-Host ("Optional fetch : gallery-dl = {0}" -f $(if ($gdl) { $gdl } else { "not installed (optional)" }))
Write-Host "============================================================"

if ($issues.Count -gt 0) {
    Write-Host ("DoctorResult: FAILED ({0} issue(s))" -f $issues.Count)
    foreach ($is in $issues) { Write-Host ("  - {0}" -f $is) }
    exit 1
} else {
    Write-Host "DoctorResult: READY"
    exit 0
}
