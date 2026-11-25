param(
    [Parameter(Mandatory=$true)][string]$Url,
    [string]$OutDir = "",
    [string]$ConfigPath = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot "_common.ps1")
$cfg = Get-MangaLocalizerConfig -ScriptDir $PSScriptRoot

# Locate gallery-dl executable (PATH, WinGet, or optional local bin/)
$gdl = Get-Command gallery-dl -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1
if (-not $gdl) {
    $gdl = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\mikf.gallery-dl*" -Recurse -Filter "gallery-dl.exe" -ErrorAction SilentlyContinue |
           Select-Object -ExpandProperty FullName -First 1
}
if (-not $gdl) {
    $localBin = Join-Path $cfg.PluginRoot "bin\gallery-dl.exe"
    if (Test-Path -LiteralPath $localBin) { $gdl = $localBin }
}
if (-not $gdl) {
    throw "gallery-dl.exe not found. Install via: winget install mikf.gallery-dl"
}

if (-not $ConfigPath) {
    $userGdl = Join-Path $HOME ".manga-zh-localizer\gallery-dl.json"
    $localGdl = Join-Path $cfg.PluginRoot "config\gallery-dl.local.json"
    $exampleGdl = Join-Path $cfg.PluginRoot "config\gallery-dl.example.json"
    if (Test-Path -LiteralPath $userGdl) { $ConfigPath = $userGdl }
    elseif (Test-Path -LiteralPath $localGdl) { $ConfigPath = $localGdl }
    elseif (Test-Path -LiteralPath $exampleGdl) { $ConfigPath = $exampleGdl }
}

if (-not $OutDir) { $OutDir = $cfg.InboxDir }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$argsList = @()
if ($ConfigPath) { $argsList += @("-c", $ConfigPath) }
$argsList += @("-D", $OutDir, $Url)

Write-Host "Running: $gdl $($argsList -join ' ')"
$output = & $gdl @argsList 2>&1
$exitCode = $LASTEXITCODE
$output | ForEach-Object { Write-Host $_ }
if ($exitCode -ne 0) {
    throw "gallery-dl exited with code $exitCode"
}

# Report downloaded image files with exact native pixel dimensions
$imgLines = $output | ForEach-Object { $_.ToString().Trim() } | Where-Object {
    $p = $_ -replace '^#\s*', ''
    (Test-Path -LiteralPath $p) -and ($p -match '\.(png|jpg|jpeg|webp|gif)$')
} | ForEach-Object { $_ -replace '^#\s*', '' }

foreach ($img in $imgLines) {
    $b = [System.Drawing.Bitmap]::FromFile($img)
    $kb = [Math]::Round((Get-Item -LiteralPath $img).Length / 1024, 1)
    Write-Host "FETCHED_ORIGINAL: $img | $($b.Width)x$($b.Height) | ${kb}KB"
    $b.Dispose()
}
