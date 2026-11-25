# Shared configuration and path resolver for manga-zh-localizer (Windows PowerShell 5.1, pure ASCII)
# Precedence: CLI parameter > Environment variable > Explicit -ConfigPath > Repo config/config.local.json > ~/.manga-zh-localizer/config.json > Safe defaults

function Resolve-MangaLocalizerRoots {
    param([string]$ScriptDir = $PSScriptRoot)
    $skillDir = Split-Path -Parent $ScriptDir
    $skillsParent = Split-Path -Parent $skillDir
    $pluginRoot = Split-Path -Parent $skillsParent
    return [PSCustomObject]@{
        ScriptDir  = $ScriptDir
        SkillDir   = $skillDir
        PluginRoot = $pluginRoot
    }
}

function Find-MangaHeadlessBrowser {
    param([string]$PreferredPath = "")
    if ($PreferredPath -and (Test-Path -LiteralPath $PreferredPath)) {
        return (Resolve-Path -LiteralPath $PreferredPath).Path
    }
    if ($env:MANGA_BROWSER_BIN -and (Test-Path -LiteralPath $env:MANGA_BROWSER_BIN)) {
        return (Resolve-Path -LiteralPath $env:MANGA_BROWSER_BIN).Path
    }
    $candidates = @(
        "$env:ProgramFiles (x86)\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "$env:ProgramFiles (x86)\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
        "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe",
        "$env:LOCALAPPDATA\Chromium\Application\chrome.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    foreach ($cmdName in @("msedge", "chrome", "chromium", "brave")) {
        $cmd = Get-Command $cmdName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) {
            return $cmd.Source
        }
    }
    return $null
}

function Get-MangaLocalizerConfig {
    param(
        [string]$ScriptDir = $PSScriptRoot,
        [string]$ConfigPath = "",
        [string]$InboxDir = "",
        [string]$OutDir = "",
        [string]$TmpDir = "",
        [string]$BrowserPath = ""
    )

    $roots = Resolve-MangaLocalizerRoots -ScriptDir $ScriptDir
    $userConfigDir = Join-Path $HOME ".manga-zh-localizer"
    $userConfigPath = Join-Path $userConfigDir "config.json"
    $localConfigPath = Join-Path $roots.PluginRoot "config\config.local.json"

    $loadedFrom = @()
    $cfgObj = [ordered]@{
        inbox_dir     = ""
        out_dir       = ""
        tmp_dir       = ""
        browser_bin   = ""
        max_parallel  = 4
        super_sample  = 2
        col_width     = 950
        glossary_dirs = @()
    }

    # Layer 1 (lowest file priority): user-global ~/.manga-zh-localizer/config.json
    # Layer 2: repo/plugin local config/config.local.json
    # Layer 3: explicit env MANGA_CONFIG_PATH
    # Layer 4: explicit CLI -ConfigPath
    $fileCandidates = @($userConfigPath, $localConfigPath)
    if ($env:MANGA_CONFIG_PATH) { $fileCandidates += $env:MANGA_CONFIG_PATH }
    if ($ConfigPath) { $fileCandidates += $ConfigPath }

    foreach ($cf in $fileCandidates) {
        if ($cf -and (Test-Path -LiteralPath $cf)) {
            try {
                $raw = [System.IO.File]::ReadAllText($cf, [System.Text.Encoding]::UTF8)
                $parsed = $raw | ConvertFrom-Json
                if ($parsed.inbox_dir)     { $cfgObj.inbox_dir    = [string]$parsed.inbox_dir }
                if ($parsed.out_dir)       { $cfgObj.out_dir      = [string]$parsed.out_dir }
                if ($parsed.tmp_dir)       { $cfgObj.tmp_dir      = [string]$parsed.tmp_dir }
                if ($parsed.browser_bin)   { $cfgObj.browser_bin  = [string]$parsed.browser_bin }
                if ($parsed.max_parallel)  { $cfgObj.max_parallel = [int]$parsed.max_parallel }
                if ($parsed.super_sample)  { $cfgObj.super_sample = [int]$parsed.super_sample }
                if ($parsed.col_width)     { $cfgObj.col_width    = [int]$parsed.col_width }
                if ($parsed.glossary_dirs) {
                    foreach ($gd in @($parsed.glossary_dirs)) {
                        if ($gd -and ($cfgObj.glossary_dirs -notcontains [string]$gd)) {
                            $cfgObj.glossary_dirs += [string]$gd
                        }
                    }
                }
                $loadedFrom += $cf
            } catch {
                Write-Warning ("Failed to parse config file {0}: {1}" -f $cf, $_.Exception.Message)
            }
        }
    }

    # Environment variable overrides
    if ($env:MANGA_INBOX_DIR)    { $cfgObj.inbox_dir   = $env:MANGA_INBOX_DIR }
    if ($env:MANGA_OUT_DIR)      { $cfgObj.out_dir     = $env:MANGA_OUT_DIR }
    if ($env:MANGA_TMP_DIR)      { $cfgObj.tmp_dir     = $env:MANGA_TMP_DIR }
    if ($env:MANGA_BROWSER_BIN)  { $cfgObj.browser_bin = $env:MANGA_BROWSER_BIN }
    if ($env:MANGA_GLOSSARY_DIR) {
        foreach ($gd in ($env:MANGA_GLOSSARY_DIR -split ';')) {
            $t = $gd.Trim()
            if ($t -and ($cfgObj.glossary_dirs -notcontains $t)) { $cfgObj.glossary_dirs += $t }
        }
    }

    # Explicit CLI overrides (highest priority)
    if ($InboxDir)    { $cfgObj.inbox_dir   = $InboxDir }
    if ($OutDir)      { $cfgObj.out_dir     = $OutDir }
    if ($TmpDir)      { $cfgObj.tmp_dir     = $TmpDir }
    if ($BrowserPath) { $cfgObj.browser_bin = $BrowserPath }

    # Portable safe defaults
    $cwd = (Get-Location).Path
    if (-not $cfgObj.inbox_dir) { $cfgObj.inbox_dir = Join-Path $cwd "inbox" }
    if (-not $cfgObj.out_dir)   { $cfgObj.out_dir   = Join-Path $cwd "out" }
    if (-not $cfgObj.tmp_dir)   { $cfgObj.tmp_dir   = Join-Path $env:TEMP "manga-zh-localizer" }

    # Default glossary search directories: user-global first, then bundled skill glossaries
    $userGlossaryDir = Join-Path $userConfigDir "glossaries"
    $skillGlossaryDir = Join-Path $roots.SkillDir "glossaries"
    foreach ($defGd in @($userGlossaryDir, $skillGlossaryDir)) {
        if ($cfgObj.glossary_dirs -notcontains $defGd) {
            $cfgObj.glossary_dirs += $defGd
        }
    }

    $resolvedBrowser = Find-MangaHeadlessBrowser -PreferredPath $cfgObj.browser_bin

    return [PSCustomObject]@{
        InboxDir       = $cfgObj.inbox_dir
        OutDir         = $cfgObj.out_dir
        TmpDir         = $cfgObj.tmp_dir
        BrowserBin     = $resolvedBrowser
        MaxParallel    = [int]$cfgObj.max_parallel
        SuperSample    = [int]$cfgObj.super_sample
        ColWidth       = [int]$cfgObj.col_width
        GlossaryDirs   = @($cfgObj.glossary_dirs)
        UserConfigPath = $userConfigPath
        LoadedConfigs  = @($loadedFrom)
        ScriptDir      = $roots.ScriptDir
        SkillDir       = $roots.SkillDir
        PluginRoot     = $roots.PluginRoot
    }
}

function Get-MangaGlossaries {
    param([string[]]$GlossaryDirs)
    $found = @()
    $seen = @{}
    foreach ($gd in $GlossaryDirs) {
        if (-not $gd -or -not (Test-Path -LiteralPath $gd)) { continue }
        Get-ChildItem -LiteralPath $gd -File -Filter "*.json" -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
            if ($_.Name -like "_*") { return }
            $key = $_.Name.ToLowerInvariant()
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $found += $_.FullName
            }
        }
    }
    return $found
}
