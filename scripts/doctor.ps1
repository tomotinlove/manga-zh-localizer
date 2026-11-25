param(
    [string]$ConfigPath = "",
    [string]$InboxDir = "",
    [string]$OutDir = "",
    [string]$TmpDir = "",
    [string]$BrowserPath = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$target = Join-Path $repoRoot "skills\manga-zh-localizer\scripts\doctor.ps1"
& $target -ConfigPath $ConfigPath -InboxDir $InboxDir -OutDir $OutDir -TmpDir $TmpDir -BrowserPath $BrowserPath
exit $LASTEXITCODE
