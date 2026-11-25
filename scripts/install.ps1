param(
    [string]$Targets = "auto",
    [ValidateSet("copy", "link")][string]$Mode = "copy",
    [string]$InboxDir = "",
    [string]$OutDir = "",
    [string]$TmpDir = "",
    [string]$BrowserPath = "",
    [string]$GlossaryDir = "",
    [switch]$InitConfig,
    [switch]$Uninstall,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$skillSrc = Join-Path $repoRoot "skills\manga-zh-localizer"
$cmdSrcDir = Join-Path $repoRoot "commands"
$cursorRuleSrc = Join-Path $repoRoot ".cursor\rules\manga-zh-localizer.mdc"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$validTargets = @("antigravity", "claude", "cursor", "codex", "dsh", "gemini-cli", "opencode", "agents")

function Resolve-TargetList([string]$spec) {
    $norm = $spec.Trim().ToLowerInvariant()
    if ($norm -eq "all") { return $validTargets }
    if ($norm -eq "auto" -or $norm -eq "") {
        $detected = @()
        if (Test-Path (Join-Path $HOME ".gemini\config\plugins")) { $detected += "antigravity" }
        if (Test-Path (Join-Path $HOME ".claude"))                { $detected += "claude" }
        if (Test-Path (Join-Path $HOME ".cursor"))                { $detected += "cursor" }
        if (Test-Path (Join-Path $HOME ".codex"))                 { $detected += "codex" }
        if (Test-Path (Join-Path $HOME ".dsh"))                   { $detected += "dsh" }
        if (Test-Path (Join-Path $HOME ".gemini\extensions"))     { $detected += "gemini-cli" }
        if (Test-Path (Join-Path $HOME ".config\opencode"))       { $detected += "opencode" }
        if (Test-Path (Join-Path $HOME ".agents"))                { $detected += "agents" }
        if ($detected.Count -eq 0) { $detected = @("agents") }
        return $detected
    }
    $list = @($norm -split '[,|;\s]+' | Where-Object { $_ })
    foreach ($t in $list) {
        if ($validTargets -notcontains $t) {
            throw ("Unknown target '{0}'. Valid targets: auto, all, {1}" -f $t, ($validTargets -join ", "))
        }
    }
    return $list
}

function Remove-DirSafe([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ($DryRun) {
        Write-Host ("[DRYRUN] Remove: {0}" -f $Path)
        return
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        # Safe junction removal without deleting target contents
        cmd /c rmdir "`"$Path`"" | Out-Null
    } else {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Install-Directory([string]$Source, [string]$Dest, [string]$InstallMode, [string[]]$ExcludeNames = @()) {
    if ($DryRun) {
        Write-Host ("[DRYRUN] {0}: {1} -> {2}" -f $InstallMode.ToUpper(), $Source, $Dest)
        return
    }
    $parent = Split-Path -Parent $Dest
    New-Item -ItemType Directory -Force -Path $parent | Out-Null

    if ($InstallMode -eq "link") {
        Remove-DirSafe -Path $Dest
        cmd /c mklink /J "`"$Dest`"" "`"$Source`"" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to create directory junction: $Dest -> $Source" }
        return
    }

    # Preserve existing personal glossaries when upgrading an installed copy
    $savedGlossaries = @()
    $destGlossDir = Join-Path $Dest "glossaries"
    $destNestedGlossDir = Join-Path $Dest "skills\manga-zh-localizer\glossaries"
    foreach ($gd in @($destGlossDir, $destNestedGlossDir)) {
        if (Test-Path -LiteralPath $gd) {
            Get-ChildItem -LiteralPath $gd -File -Filter "*.json" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "_*" } | ForEach-Object {
                $savedGlossaries += [PSCustomObject]@{
                    TargetDir = $gd
                    Name      = $_.Name
                    Bytes     = [System.IO.File]::ReadAllBytes($_.FullName)
                }
            }
        }
    }

    Remove-DirSafe -Path $Dest
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null

    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        if ($ExcludeNames -contains $_.Name) { return }
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Dest $_.Name) -Recurse -Force
    }

    foreach ($sg in $savedGlossaries) {
        New-Item -ItemType Directory -Force -Path $sg.TargetDir | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $sg.TargetDir $sg.Name), $sg.Bytes)
    }
}

function Install-StandaloneCommands([string]$DestCmdDir, [string]$InstalledScriptsDir) {
    $cmdFiles = Get-ChildItem -LiteralPath $cmdSrcDir -File -Filter "manga-*.md"
    if ($DryRun) {
        Write-Host ("[DRYRUN] Copy {0} slash commands -> {1}" -f $cmdFiles.Count, $DestCmdDir)
        return
    }
    New-Item -ItemType Directory -Force -Path $DestCmdDir | Out-Null
    foreach ($cf in $cmdFiles) {
        $text = [System.IO.File]::ReadAllText($cf.FullName, [System.Text.Encoding]::UTF8)
        $text = $text.Replace('${CLAUDE_PLUGIN_ROOT}\skills\manga-zh-localizer\scripts', $InstalledScriptsDir)
        $text = $text.Replace('${CLAUDE_PLUGIN_ROOT}', (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $InstalledScriptsDir))))
        [System.IO.File]::WriteAllText((Join-Path $DestCmdDir $cf.Name), $text, $utf8NoBom)
    }
}

function Remove-StandaloneCommands([string]$DestCmdDir) {
    if (-not (Test-Path -LiteralPath $DestCmdDir)) { return }
    Get-ChildItem -LiteralPath $DestCmdDir -File -Filter "manga-*.md" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($DryRun) { Write-Host ("[DRYRUN] Remove command: {0}" -f $_.FullName) }
        else { Remove-Item -LiteralPath $_.FullName -Force }
    }
}

function Update-UserSharedConfig {
    $userRoot = Join-Path $HOME ".manga-zh-localizer"
    $cfgPath = Join-Path $userRoot "config.json"
    $glossDir = Join-Path $userRoot "glossaries"
    $binDir = Join-Path $userRoot "bin"
    $shimPath = Join-Path $binDir "manga-zh.cmd"

    $needWriteCfg = $InitConfig.IsPresent -or $InboxDir -or $OutDir -or $TmpDir -or $BrowserPath -or $GlossaryDir -or (-not (Test-Path -LiteralPath $cfgPath))

    if ($DryRun) {
        Write-Host ("[DRYRUN] Ensure shared dir : {0}" -f $userRoot)
        if ($needWriteCfg) { Write-Host ("[DRYRUN] Write/update cfg  : {0}" -f $cfgPath) }
        Write-Host ("[DRYRUN] Write CLI shim    : {0}" -f $shimPath)
        return
    }

    New-Item -ItemType Directory -Force -Path $userRoot, $glossDir, $binDir | Out-Null

    # Copy blank glossary template if not present
    $tplSrc = Join-Path $skillSrc "glossaries\_template.json"
    $tplDst = Join-Path $glossDir "_template.json"
    if ((Test-Path -LiteralPath $tplSrc) -and (-not (Test-Path -LiteralPath $tplDst))) {
        Copy-Item -LiteralPath $tplSrc -Destination $tplDst -Force
    }

    # Merge or create ~/.manga-zh-localizer/config.json
    if ($needWriteCfg) {
        $existing = [ordered]@{
            inbox_dir     = ""
            out_dir       = ""
            tmp_dir       = ""
            browser_bin   = ""
            max_parallel  = 4
            super_sample  = 2
            col_width     = 950
            glossary_dirs = @()
        }
        if (Test-Path -LiteralPath $cfgPath) {
            try {
                $p = ([System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8)) | ConvertFrom-Json
                if ($p.inbox_dir)     { $existing.inbox_dir    = [string]$p.inbox_dir }
                if ($p.out_dir)       { $existing.out_dir      = [string]$p.out_dir }
                if ($p.tmp_dir)       { $existing.tmp_dir      = [string]$p.tmp_dir }
                if ($p.browser_bin)   { $existing.browser_bin  = [string]$p.browser_bin }
                if ($p.max_parallel)  { $existing.max_parallel = [int]$p.max_parallel }
                if ($p.super_sample)  { $existing.super_sample = [int]$p.super_sample }
                if ($p.col_width)     { $existing.col_width    = [int]$p.col_width }
                if ($p.glossary_dirs) { $existing.glossary_dirs = @($p.glossary_dirs) }
            } catch {}
        }
        if ($InboxDir)    { $existing.inbox_dir   = $InboxDir }
        if ($OutDir)      { $existing.out_dir     = $OutDir }
        if ($TmpDir)      { $existing.tmp_dir     = $TmpDir }
        if ($BrowserPath) { $existing.browser_bin = $BrowserPath }
        if ($GlossaryDir -and ($existing.glossary_dirs -notcontains $GlossaryDir)) {
            $existing.glossary_dirs += $GlossaryDir
        }
        [System.IO.File]::WriteAllText($cfgPath, ($existing | ConvertTo-Json -Depth 4), $utf8NoBom)
        Write-Host ("[OK]   Shared config saved : {0}" -f $cfgPath)
    }

    # Install CLI shim pointing to this repo's batch_job.ps1 (allows: manga-zh scan -Latest)
    $batchScript = Join-Path $skillSrc "scripts\batch_job.ps1"
    $shimContent = "@echo off`r`nsetlocal`r`nif `"%~1`"==`"`" (`r`n  echo Usage: manga-zh ^<scan^|build^|package^|doctor^> [options]`r`n  exit /b 1`r`n)`r`nset MODE=%~1`r`nshift`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$batchScript`" -Mode %MODE% %1 %2 %3 %4 %5 %6 %7 %8 %9`r`nexit /b %ERRORLEVEL%`r`n"
    [System.IO.File]::WriteAllText($shimPath, $shimContent, $utf8NoBom)
    Write-Host ("[OK]   CLI shim ready      : {0}" -f $shimPath)
}

$selectedTargets = Resolve-TargetList -spec $Targets
Write-Host "============================================================"
Write-Host ("  manga-zh-localizer Installer ({0}, mode={1})" -f $(if ($Uninstall) { "UNINSTALL" } else { "INSTALL" }), $Mode)
Write-Host ("  Repo    : {0}" -f $repoRoot)
Write-Host ("  Targets : {0}" -f ($selectedTargets -join ", "))
Write-Host "============================================================"

$repoExclude = @(".git", "inbox", "out", "tmp", ".tmp", "_smoke_tmp")

foreach ($t in $selectedTargets) {
    switch ($t) {
        "antigravity" {
            $dest = Join-Path $HOME ".gemini\config\plugins\manga-zh-localizer"
            if ($Uninstall) {
                Remove-DirSafe -Path $dest
                Write-Host ("[OK]   antigravity : removed {0}" -f $dest)
            } else {
                Install-Directory -Source $repoRoot -Dest $dest -InstallMode $Mode -ExcludeNames ($repoExclude + @(".claude-plugin", ".cursor-plugin", ".cursor", "dsh", "cordis.patch.yml", "package.json", "gemini-extension.json", "GEMINI.md", "CLAUDE.md"))
                Write-Host ("[OK]   antigravity : installed full plugin -> {0}" -f $dest)
            }
        }
        "claude" {
            $skillDest = Join-Path $HOME ".claude\skills\manga-zh-localizer"
            $cmdDest = Join-Path $HOME ".claude\commands"
            if ($Uninstall) {
                Remove-DirSafe -Path $skillDest
                Remove-StandaloneCommands -DestCmdDir $cmdDest
                Write-Host "[OK]   claude      : removed skill & slash commands"
            } else {
                Install-Directory -Source $skillSrc -Dest $skillDest -InstallMode $Mode
                Install-StandaloneCommands -DestCmdDir $cmdDest -InstalledScriptsDir (Join-Path $skillDest "scripts")
                Write-Host ("[OK]   claude      : installed skill -> {0} + commands -> {1}" -f $skillDest, $cmdDest)
            }
        }
        "cursor" {
            $skillDest = Join-Path $HOME ".cursor\skills\manga-zh-localizer"
            $cmdDest = Join-Path $HOME ".cursor\commands"
            $ruleDestDir = Join-Path $HOME ".cursor\rules"
            $ruleDest = Join-Path $ruleDestDir "manga-zh-localizer.mdc"
            if ($Uninstall) {
                Remove-DirSafe -Path $skillDest
                Remove-StandaloneCommands -DestCmdDir $cmdDest
                if (Test-Path -LiteralPath $ruleDest) {
                    if ($DryRun) { Write-Host "[DRYRUN] Remove: $ruleDest" }
                    else { Remove-Item -LiteralPath $ruleDest -Force }
                }
                Write-Host "[OK]   cursor      : removed skill, rule & commands"
            } else {
                Install-Directory -Source $skillSrc -Dest $skillDest -InstallMode $Mode
                Install-StandaloneCommands -DestCmdDir $cmdDest -InstalledScriptsDir (Join-Path $skillDest "scripts")
                if ($DryRun) {
                    Write-Host ("[DRYRUN] Copy rule -> {0}" -f $ruleDest)
                } else {
                    New-Item -ItemType Directory -Force -Path $ruleDestDir | Out-Null
                    Copy-Item -LiteralPath $cursorRuleSrc -Destination $ruleDest -Force
                }
                Write-Host ("[OK]   cursor      : installed skill -> {0} + rule + commands" -f $skillDest)
            }
        }
        "codex" {
            $skillDest = Join-Path $HOME ".codex\skills\manga-zh-localizer"
            if ($Uninstall) {
                Remove-DirSafe -Path $skillDest
                Write-Host ("[OK]   codex       : removed {0}" -f $skillDest)
            } else {
                Install-Directory -Source $skillSrc -Dest $skillDest -InstallMode $Mode
                Write-Host ("[OK]   codex       : installed skill -> {0}" -f $skillDest)
            }
        }
        "dsh" {
            $skillDest = Join-Path $HOME ".dsh\skills\manga-zh-localizer"
            if ($Uninstall) {
                Remove-DirSafe -Path $skillDest
                Write-Host ("[OK]   dsh         : removed {0}" -f $skillDest)
            } else {
                Install-Directory -Source $skillSrc -Dest $skillDest -InstallMode $Mode
                Write-Host ("[OK]   dsh         : installed skill -> {0} (or run: dsh plugin --profile desktop add github:tomotinlove/manga-zh-localizer)" -f $skillDest)
            }
        }
        "gemini-cli" {
            $extDest = Join-Path $HOME ".gemini\extensions\manga-zh-localizer"
            if ($Uninstall) {
                Remove-DirSafe -Path $extDest
                Write-Host ("[OK]   gemini-cli  : removed {0}" -f $extDest)
            } else {
                Install-Directory -Source $repoRoot -Dest $extDest -InstallMode $Mode -ExcludeNames ($repoExclude + @(".claude-plugin", ".cursor-plugin", ".cursor", "dsh", "cordis.patch.yml", "package.json", "CLAUDE.md"))
                Write-Host ("[OK]   gemini-cli  : installed extension -> {0}" -f $extDest)
            }
        }
        "opencode" {
            $skillDest = Join-Path $HOME ".config\opencode\skills\manga-zh-localizer"
            if ($Uninstall) {
                Remove-DirSafe -Path $skillDest
                Write-Host ("[OK]   opencode    : removed {0}" -f $skillDest)
            } else {
                Install-Directory -Source $skillSrc -Dest $skillDest -InstallMode $Mode
                Write-Host ("[OK]   opencode    : installed skill -> {0}" -f $skillDest)
            }
        }
        "agents" {
            $skillDest = Join-Path $HOME ".agents\skills\manga-zh-localizer"
            if ($Uninstall) {
                Remove-DirSafe -Path $skillDest
                Write-Host ("[OK]   agents      : removed {0}" -f $skillDest)
            } else {
                Install-Directory -Source $skillSrc -Dest $skillDest -InstallMode $Mode
                Write-Host ("[OK]   agents      : installed standard skill -> {0}" -f $skillDest)
            }
        }
    }
}

if (-not $Uninstall) {
    Update-UserSharedConfig
    Write-Host "------------------------------------------------------------"
    Write-Host "Tip: Run doctor to verify browser, fonts, and paths:"
    Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File `"$repoRoot\scripts\doctor.ps1`""
}
Write-Host "============================================================"
