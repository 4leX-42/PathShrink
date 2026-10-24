#Requires -Version 5.1

<#
.SYNOPSIS
    Installs PathShrink for the current user (no admin), or removes it.
.DESCRIPTION
    Downloads the release zip from GitHub, checks its SHA-256 against the published hash,
    unpacks it to %LOCALAPPDATA%\Programs\PathShrink and adds a Start menu shortcut.
    -Uninstall removes the program and the shortcut. Reports and undo files in
    %LOCALAPPDATA%\PathShrink are kept unless -RemoveData is given, because an undo file
    may still be needed.
.PARAMETER Uninstall
    Remove PathShrink.
.PARAMETER RemoveData
    With -Uninstall: also delete reports, undo files and logs.
.PARAMETER Version
    Release tag to install, for example v1.0.0. Default: the latest release.
.PARAMETER NoShortcut
    Do not create the Start menu shortcut.
.EXAMPLE
    .\install.ps1
.EXAMPLE
    .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param([switch]$Uninstall, [switch]$RemoveData, [string]$Version = 'latest', [switch]$NoShortcut)

$ErrorActionPreference = 'Stop'
$repo = 'https://github.com/4leX-42/PathShrink'
$dest = Join-Path $env:LOCALAPPDATA 'Programs\PathShrink'
$data = Join-Path $env:LOCALAPPDATA 'PathShrink'
$lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'PathShrink.lnk'

if ($Uninstall) {
    if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    if ($RemoveData -and (Test-Path -LiteralPath $data)) { Remove-Item -LiteralPath $data -Recurse -Force }
    Write-Host 'PathShrink removed.' -ForegroundColor Green
    if (-not $RemoveData -and (Test-Path -LiteralPath $data)) { Write-Host "Reports and undo files kept in $data" }
    return
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
$base = $(if ($Version -eq 'latest') { "$repo/releases/latest/download" } else { "$repo/releases/download/$Version" })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('PathShrink-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $zip = Join-Path $tmp 'PathShrink.zip'
    Write-Host "Downloading $base/PathShrink.zip"
    Invoke-WebRequest -Uri "$base/PathShrink.zip" -OutFile $zip -UseBasicParsing
    Invoke-WebRequest -Uri "$base/PathShrink.zip.sha256" -OutFile "$zip.sha256" -UseBasicParsing
    $expected = ((Get-Content -LiteralPath "$zip.sha256" -Raw).Trim() -split '\s+')[0]
    $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    if ($actual -ne $expected) { throw "SHA-256 mismatch. Expected $expected, got $actual. Nothing was installed." }
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
    Get-ChildItem -LiteralPath $dest -Recurse -File | Unblock-File
    if (-not $NoShortcut) {
        $sh = New-Object -ComObject WScript.Shell
        $s = $sh.CreateShortcut($lnk)
        $s.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $s.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $dest 'PathShrink.ps1')
        $s.WorkingDirectory = $dest
        $s.Description = 'Fix OneDrive and SharePoint paths over the 400-character limit'
        $s.Save()
    }
    Write-Host "PathShrink installed in $dest" -ForegroundColor Green
    if (-not $NoShortcut) { Write-Host 'Open it from the Start menu: PathShrink' }
    Write-Host "Command line: Import-Module '$dest\PathShrink\PathShrink.psd1'; Invoke-PathShrink -WhatIf"
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
