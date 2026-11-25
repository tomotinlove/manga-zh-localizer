param(
    [Parameter(Mandatory=$true)][ValidateSet("scan", "build", "package", "doctor")][string]$Mode,
    [string]$Job = "",
    [string]$JobDir = "",
    [string]$Pattern = "",
    [string]$Images = "",
    [switch]$Latest,
    [string]$Pages = "",
    [switch]$CleanOnly,
    [switch]$ForceClean,
    [string]$InboxDir = "",
    [string]$OutDir = "",
    [string]$TmpDir = "",
    [string]$BrowserPath = "",
    [string]$ConfigPath = "",
    [int]$MaxParallel = 0,
    [int]$ColWidth = 0,
    [int]$SuperSample = 0
)

$ErrorActionPreference = "Stop"
$S = $PSScriptRoot
. (Join-Path $S "_common.ps1")

$cfg = Get-MangaLocalizerConfig `
    -ScriptDir $S `
    -ConfigPath $ConfigPath `
    -InboxDir $InboxDir `
    -OutDir $OutDir `
    -TmpDir $TmpDir `
    -BrowserPath $BrowserPath

$inboxDir = $cfg.InboxDir
$outRoot = $cfg.OutDir
$tmpRoot = $cfg.TmpDir
if ($MaxParallel -le 0) { $MaxParallel = $cfg.MaxParallel }
if ($ColWidth -le 0)    { $ColWidth = $cfg.ColWidth }
if ($SuperSample -le 0) { $SuperSample = $cfg.SuperSample }
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Invoke-ParallelPs([array]$Tasks, [int]$Limit, [hashtable]$EnvOverrides = @{}) {
    $running = New-Object System.Collections.Generic.List[object]
    $idx = 0
    $results = @{}
    while ($idx -lt $Tasks.Count -or $running.Count -gt 0) {
        while ($idx -lt $Tasks.Count -and $running.Count -lt $Limit) {
            $t = $Tasks[$idx]
            $idx++
            $argStr = "-NoProfile -ExecutionPolicy Bypass -File `"$($t.Script)`" $($t.Args)"
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "powershell.exe"
            $psi.Arguments = $argStr
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            foreach ($k in $EnvOverrides.Keys) {
                $val = $EnvOverrides[$k]
                if ($null -ne $val -and $val -ne "") {
                    $psi.EnvironmentVariables[$k] = [string]$val
                }
            }
            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi
            [void]$proc.Start()
            $outTask = $proc.StandardOutput.ReadToEndAsync()
            $errTask = $proc.StandardError.ReadToEndAsync()
            $running.Add([PSCustomObject]@{ Key = $t.Key; Proc = $proc; OutTask = $outTask; ErrTask = $errTask; Task = $t })
        }
        Start-Sleep -Milliseconds 120
        for ($r = $running.Count - 1; $r -ge 0; $r--) {
            $item = $running[$r]
            if ($item.Proc.HasExited) {
                $stdout = $item.OutTask.GetAwaiter().GetResult()
                $stderr = $item.ErrTask.GetAwaiter().GetResult()
                $code = $item.Proc.ExitCode
                $item.Proc.Dispose()
                $results[$item.Key] = [PSCustomObject]@{ ExitCode = $code; StdOut = $stdout; StdErr = $stderr; Key = $item.Key }
                $running.RemoveAt($r)
            }
        }
    }
    return $results
}

function Build-Sheets([string[]]$Paths, [string[]]$Labels, [string]$BaseOutPath, [int]$Width) {
    if ($Paths.Count -eq 0) { return }
    $perSheet = if ($Paths.Count -ge 5) { 4 } else { $Paths.Count }
    $numSheets = [int][Math]::Ceiling($Paths.Count / [double]$perSheet)
    for ($si = 0; $si -lt $numSheets; $si++) {
        $start = $si * $perSheet
        $end = [Math]::Min($Paths.Count - 1, $start + $perSheet - 1)
        $subPaths = $Paths[$start..$end]
        $subLabels = $Labels[$start..$end]
        $outPath = if ($numSheets -eq 1) { $BaseOutPath } else {
            $dir = Split-Path -Parent $BaseOutPath
            $nm = [System.IO.Path]::GetFileNameWithoutExtension($BaseOutPath)
            $ext = [System.IO.Path]::GetExtension($BaseOutPath)
            Join-Path $dir ("{0}_{1}{2}" -f $nm, ($si + 1), $ext)
        }
        & "$S\make_sheet.ps1" -Images ($subPaths -join '|') -OutputPath $outPath -ColWidth $Width -Labels ($subLabels -join '|')
    }
}

function Resolve-JobDir() {
    if ($JobDir) { return $JobDir }
    if ($Job) { return (Join-Path $tmpRoot $Job) }
    throw "Please specify -Job <name> or -JobDir <path>."
}

$childEnv = @{
    MANGA_TMP_DIR     = $tmpRoot
    MANGA_BROWSER_BIN = if ($cfg.BrowserBin) { $cfg.BrowserBin } else { "" }
    MANGA_CONFIG_PATH = $ConfigPath
}

$swAll = [System.Diagnostics.Stopwatch]::StartNew()

if ($Mode -eq "doctor") {
    $doctorScript = Join-Path $S "doctor.ps1"
    & $doctorScript -ConfigPath $ConfigPath -InboxDir $InboxDir -OutDir $OutDir -TmpDir $TmpDir -BrowserPath $BrowserPath
    exit $LASTEXITCODE
}
elseif ($Mode -eq "scan") {
    $selected = @()
    if ($Images) {
        foreach ($p in ($Images -split '\|')) {
            $tp = $p.Trim()
            if ($tp -and (Test-Path -LiteralPath $tp)) { $selected += (Get-Item -LiteralPath $tp) }
        }
    } elseif ($Pattern) {
        if (-not (Test-Path -LiteralPath $inboxDir)) { throw "Inbox directory does not exist: $inboxDir (pass -Images or configure inbox_dir)" }
        $selected = @(Get-ChildItem -LiteralPath $inboxDir -File -Filter $Pattern | Where-Object { $_.Extension -match '^\.(png|jpe?g|webp|bmp)$' } | Sort-Object Name)
    } elseif ($Latest.IsPresent -or (-not $Job)) {
        if (-not (Test-Path -LiteralPath $inboxDir)) { throw "Inbox directory does not exist: $inboxDir (pass -Images `"<path>`" or configure inbox_dir via ~/.manga-zh-localizer/config.json)" }
        $allFiles = @(Get-ChildItem -LiteralPath $inboxDir -File | Where-Object { $_.Extension -match '^\.(png|jpe?g|webp|bmp)$' } | Sort-Object LastWriteTime -Descending)
        if ($allFiles.Count -eq 0) { throw "Inbox is empty: $inboxDir" }
        $newest = $allFiles[0]
        $baseStem = [System.IO.Path]::GetFileNameWithoutExtension($newest.Name)
        if ($baseStem -match '^(.+?)_p\d+(_master\d+)?$') {
            $prefix = $Matches[1]
            $isMaster = [bool]$Matches[2]
            $selected = @($allFiles | Where-Object {
                $st = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
                if ($isMaster) { $st -match ("^" + [regex]::Escape($prefix) + "_p\d+_master\d+$") }
                else { $st -match ("^" + [regex]::Escape($prefix) + "_p\d+$") }
            } | Sort-Object {
                if ([System.IO.Path]::GetFileNameWithoutExtension($_.Name) -match '_p(\d+)') { [int]$Matches[1] } else { 0 }
            })
            if (-not $Job) { $Job = $prefix }
        } else {
            $selected = @($newest)
            if (-not $Job) { $Job = $baseStem }
        }
    } else {
        if (-not (Test-Path -LiteralPath $inboxDir)) { throw "Inbox directory does not exist: $inboxDir (pass -Images or configure inbox_dir)" }
        $selected = @(Get-ChildItem -LiteralPath $inboxDir -File -Filter ("$Job*") | Where-Object { $_.Extension -match '^\.(png|jpe?g|webp|bmp)$' } | Sort-Object Name)
    }

    if ($selected.Count -eq 0) { throw "No matching input images found." }
    if (-not $Job) {
        $st0 = [System.IO.Path]::GetFileNameWithoutExtension($selected[0].Name)
        $Job = if ($st0 -match '^(.+?)_p\d+') { $Matches[1] } else { $st0 }
    }
    if (-not $JobDir) { $JobDir = Join-Path $tmpRoot $Job }
    New-Item -ItemType Directory -Force -Path $JobDir | Out-Null

    Write-Host "=== SCAN JOB: $Job ($($selected.Count) pages, parallel=$MaxParallel) ==="
    Write-Host ("Paths: job_dir={0} | out_dir={1}" -f $JobDir, $outRoot)
    $glossaries = @(Get-MangaGlossaries -GlossaryDirs $cfg.GlossaryDirs)
    if ($glossaries.Count -gt 0) {
        Write-Host ("Glossaries: " + ($glossaries -join " | "))
    }

    $manifestPages = @()
    $tasks = @()
    for ($i = 0; $i -lt $selected.Count; $i++) {
        $fi = $selected[$i]
        $pkey = "p$i"
        $pdir = Join-Path $JobDir $pkey
        New-Item -ItemType Directory -Force -Path $pdir | Out-Null
        $base = [System.IO.Path]::GetFileNameWithoutExtension($fi.Name)
        $prevOut = Join-Path $pdir "preview.jpg"
        $autoOut = Join-Path $pdir "bubbles_auto.json"
        $manifestPages += [ordered]@{
            key = $pkey
            base = $base
            input = $fi.FullName
            work_dir = $pdir
        }
        $tasks += [PSCustomObject]@{
            Key = $pkey
            Script = (Join-Path $S "grid_inspect.ps1")
            Args = "-ImagePath `"$($fi.FullName)`" -OutDir `"$pdir`" -PreviewOut `"$prevOut`" -AutoBubblesOut `"$autoOut`" -FastPreview -PrintSummary"
        }
    }

    $res = Invoke-ParallelPs -Tasks $tasks -Limit $MaxParallel -EnvOverrides $childEnv
    $prevPaths = @(); $prevLabels = @()
    foreach ($mp in $manifestPages) {
        $r = $res[$mp.key]
        Write-Host ("--- {0} ({1}) [exit={2}] ---" -f $mp.key.ToUpper(), $mp.base, $r.ExitCode)
        if ($r.StdOut) { Write-Host $r.StdOut.TrimEnd() }
        if ($r.ExitCode -ne 0) {
            if ($r.StdErr) { Write-Host $r.StdErr.TrimEnd() }
            throw "grid_inspect failed for $($mp.key)"
        }
        $prevPaths += (Join-Path $mp.work_dir "preview.jpg")
        $prevLabels += ("{0} ({1})" -f $mp.key.ToUpper(), $mp.base)
    }

    $manifest = [ordered]@{
        job = $Job
        job_dir = $JobDir
        out_dir = $outRoot
        created = (Get-Date).ToString("o")
        pages = $manifestPages
    }
    $manPath = Join-Path $JobDir "job_manifest.json"
    [System.IO.File]::WriteAllText($manPath, ($manifest | ConvertTo-Json -Depth 5), $utf8NoBom)

    Build-Sheets -Paths $prevPaths -Labels $prevLabels -BaseOutPath (Join-Path $JobDir "preview_sheet.jpg") -Width $ColWidth
    Write-Host ("ScanComplete: manifest={0} elapsed={1:N1}s" -f $manPath, $swAll.Elapsed.TotalSeconds)
}
elseif ($Mode -eq "build") {
    $JobDir = Resolve-JobDir
    $manPath = Join-Path $JobDir "job_manifest.json"
    if (-not (Test-Path -LiteralPath $manPath)) { throw "Manifest not found: $manPath (run -Mode scan first)" }
    $man = ([System.IO.File]::ReadAllText($manPath, [System.Text.Encoding]::UTF8)) | ConvertFrom-Json
    $allPages = @($man.pages)
    $targetKeys = if ($Pages) { @($Pages -split '\|' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }) } else { @($allPages | ForEach-Object { $_.key.ToLower() }) }

    # Phase 1: Parallel clean_bubbles (auto-skip unchanged clean_final.png unless -ForceClean)
    $cleanTasks = @()
    foreach ($mp in $allPages) {
        if ($targetKeys -notcontains $mp.key.ToLower()) { continue }
        $planPath = Join-Path $mp.work_dir "clean_plan.json"
        if (-not (Test-Path -LiteralPath $planPath)) { continue }
        $cleanOut = Join-Path $mp.work_dir "clean_final.png"
        $boxesOut = Join-Path $mp.work_dir "boxes.json"
        $diffOut = Join-Path $mp.work_dir "diff.jpg"
        $needClean = $ForceClean.IsPresent -or (-not (Test-Path -LiteralPath $cleanOut)) -or (-not (Test-Path -LiteralPath $boxesOut))
        if (-not $needClean) {
            if ((Get-Item -LiteralPath $planPath).LastWriteTimeUtc -gt (Get-Item -LiteralPath $cleanOut).LastWriteTimeUtc) {
                $needClean = $true
            }
        }
        if ($needClean) {
            $cleanTasks += [PSCustomObject]@{
                Key = $mp.key
                Script = (Join-Path $S "clean_bubbles.ps1")
                Args = "-ImagePath `"$($mp.input)`" -PlanPath `"$planPath`" -OutputPath `"$cleanOut`" -BoxesOut `"$boxesOut`" -DiffOut `"$diffOut`""
            }
        } else {
            Write-Host "=== CLEAN $($mp.key.ToUpper()): up-to-date (skipped) ==="
        }
    }

    if ($cleanTasks.Count -gt 0) {
        Write-Host "=== CLEAN PHASE ($($cleanTasks.Count) pages, parallel=$MaxParallel) ==="
        $cRes = Invoke-ParallelPs -Tasks $cleanTasks -Limit $MaxParallel -EnvOverrides $childEnv
        foreach ($t in $cleanTasks) {
            $r = $cRes[$t.Key]
            Write-Host ("--- CLEAN {0} [exit={1}] ---" -f $t.Key.ToUpper(), $r.ExitCode)
            if ($r.StdOut) { Write-Host $r.StdOut.TrimEnd() }
            if ($r.ExitCode -ne 0) {
                if ($r.StdErr) { Write-Host $r.StdErr.TrimEnd() }
                throw "clean_bubbles failed for $($t.Key)"
            }
        }
    }

    # Phase 2: Parallel render_typeset (unless -CleanOnly)
    if (-not $CleanOnly.IsPresent) {
        $typeTasks = @()
        foreach ($mp in $allPages) {
            if ($targetKeys -notcontains $mp.key.ToLower()) { continue }
            $layoutPath = Join-Path $mp.work_dir "layout.json"
            $cleanOut = Join-Path $mp.work_dir "clean_final.png"
            if (-not (Test-Path -LiteralPath $layoutPath)) { continue }
            if (-not (Test-Path -LiteralPath $cleanOut)) { $cleanOut = $mp.input }
            $zhOut = Join-Path $mp.work_dir ("{0}_zh.png" -f $mp.base)
            $auditOut = Join-Path $mp.work_dir "audit.jpg"
            $extraArgs = "-TmpDir `"$tmpRoot`""
            if ($cfg.BrowserBin) { $extraArgs += " -BrowserPath `"$($cfg.BrowserBin)`"" }
            $typeTasks += [PSCustomObject]@{
                Key = $mp.key
                Script = (Join-Path $S "render_typeset.ps1")
                Args = "-CleanImage `"$cleanOut`" -LayoutPath `"$layoutPath`" -OutputPath `"$zhOut`" -AuditOverlay `"$auditOut`" -SuperSample $SuperSample $extraArgs"
            }
        }
        if ($typeTasks.Count -gt 0) {
            Write-Host "=== TYPESET PHASE ($($typeTasks.Count) pages, parallel=$MaxParallel) ==="
            $tRes = Invoke-ParallelPs -Tasks $typeTasks -Limit $MaxParallel -EnvOverrides $childEnv
            foreach ($t in $typeTasks) {
                $r = $tRes[$t.Key]
                Write-Host ("--- TYPESET {0} [exit={1}] ---" -f $t.Key.ToUpper(), $r.ExitCode)
                if ($r.StdOut) {
                    $filtered = ($r.StdOut -split "`r?`n") | Where-Object { $_ -notmatch '^\[.*ERROR:' -and $_ -notmatch 'bytes written to file' }
                    Write-Host ($filtered -join "`n")
                }
                if ($r.ExitCode -ne 0) {
                    if ($r.StdErr) { Write-Host $r.StdErr.TrimEnd() }
                    throw "render_typeset failed for $($t.Key)"
                }
            }
        }
    }

    # Phase 3: Rebuild contact sheets for all available pages
    $diffPaths = @(); $diffLabels = @()
    $qaPaths = @(); $qaLabels = @()
    $audPaths = @(); $audLabels = @()
    foreach ($mp in $allPages) {
        $df = Join-Path $mp.work_dir "diff.jpg"
        $zh = Join-Path $mp.work_dir ("{0}_zh.png" -f $mp.base)
        $au = Join-Path $mp.work_dir "audit.jpg"
        if (Test-Path -LiteralPath $df) { $diffPaths += $df; $diffLabels += "$($mp.key.ToUpper())_diff" }
        if (Test-Path -LiteralPath $zh) { $qaPaths += $zh; $qaLabels += "$($mp.key.ToUpper())_zh" }
        if (Test-Path -LiteralPath $au) { $audPaths += $au; $audLabels += "$($mp.key.ToUpper())_audit" }
    }
    Build-Sheets -Paths $diffPaths -Labels $diffLabels -BaseOutPath (Join-Path $JobDir "diff_sheet.jpg") -Width $ColWidth
    if (-not $CleanOnly.IsPresent) {
        Build-Sheets -Paths $qaPaths -Labels $qaLabels -BaseOutPath (Join-Path $JobDir "qa_sheet.jpg") -Width $ColWidth
        Build-Sheets -Paths $audPaths -Labels $audLabels -BaseOutPath (Join-Path $JobDir "audit_sheet.jpg") -Width $ColWidth
    }
    Write-Host ("BuildComplete: job={0} elapsed={1:N1}s" -f $man.job, $swAll.Elapsed.TotalSeconds)
}
elseif ($Mode -eq "package") {
    $JobDir = Resolve-JobDir
    $manPath = Join-Path $JobDir "job_manifest.json"
    if (-not (Test-Path -LiteralPath $manPath)) { throw "Manifest not found: $manPath" }
    $man = ([System.IO.File]::ReadAllText($manPath, [System.Text.Encoding]::UTF8)) | ConvertFrom-Json
    if (-not $OutDir -and $man.out_dir) { $outRoot = [string]$man.out_dir }
    $allPages = @($man.pages)
    $zhPaths = @()
    foreach ($mp in $allPages) {
        $zh = Join-Path $mp.work_dir ("{0}_zh.png" -f $mp.base)
        if (-not (Test-Path -LiteralPath $zh)) { throw "Missing rendered page: $zh" }
        $zhPaths += $zh
    }
    New-Item -ItemType Directory -Force -Path $outRoot | Out-Null
    if ($zhPaths.Count -eq 1) {
        $dest = Join-Path $outRoot ("{0}_zh.png" -f $allPages[0].base)
        Copy-Item -LiteralPath $zhPaths[0] -Destination $dest -Force
        Write-Host "PackagedSinglePage: $dest"
    } else {
        $jobOutDir = Join-Path $outRoot $man.job
        $longOut = Join-Path $jobOutDir ("00_{0}_long_zh.png" -f $man.job)
        & "$S\make_longstrip.ps1" -Images ($zhPaths -join '|') -OutputPath $longOut -OrderedOutDir $jobOutDir -ShowPageNumbers
        Get-ChildItem -LiteralPath $jobOutDir | Sort-Object Name | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
    }
    Write-Host ("PackageComplete: job={0} elapsed={1:N1}s" -f $man.job, $swAll.Elapsed.TotalSeconds)
}
