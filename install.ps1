#Requires -Version 5.1

<#
.SYNOPSIS
    Installs PathShrink for the current user (no admin), or removes it.
.DESCRIPTION
    Downloads the release zip from GitHub, checks its SHA-256 against the published hash,
    unpacks it to %LOCALAPPDATA%\Programs\PathShrink, adds a Start menu shortcut to
    PathShrink.exe and opens it. Run it from a normal PowerShell, not as administrator:
    PathShrink works on the OneDrive of the user who runs it.
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
.PARAMETER NoStart
    Do not open PathShrink when the install ends.
.EXAMPLE
    .\install.ps1
.EXAMPLE
    .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param([switch]$Uninstall, [switch]$RemoveData, [string]$Version = 'latest', [switch]$NoShortcut, [switch]$NoStart)

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

$elevated = $false
try { $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $elevated = $false }
if ($elevated) {
    Write-Warning ('Running as administrator: PathShrink is installed for {0} and works on that user''s OneDrive. If that is not your account, close this window and run the command in a normal PowerShell' -f $env:USERNAME)
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
    # .NET instead of Get-FileHash and Expand-Archive: started from PowerShell 7, Windows PowerShell
    # inherits its PSModulePath and those two cmdlets are not found.
    $sha = [Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::OpenRead($zip)
    try { $actual = -join ($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('X2') }) } finally { $fs.Dispose(); $sha.Dispose() }
    if ($actual -ne $expected) { throw "SHA-256 mismatch. Expected $expected, got $actual. Nothing was installed." }
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dest)
    foreach ($x in Get-ChildItem -LiteralPath $dest -Recurse -File) { Remove-Item -LiteralPath $x.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue }
    $exe = Join-Path $dest 'PathShrink.exe'
    if (-not $NoShortcut) {
        $sh = New-Object -ComObject WScript.Shell
        $s = $sh.CreateShortcut($lnk)
        if (Test-Path -LiteralPath $exe) { $s.TargetPath = $exe }
        else {
            # Releases before 1.1.0 have no exe.
            $s.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $s.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $dest 'PathShrink.ps1')
        }
        $s.WorkingDirectory = $dest
        $s.IconLocation = (Join-Path $dest 'PathShrink\gui\PathShrink.ico') + ',0'
        $s.Description = 'Fix OneDrive and SharePoint paths over the 400-character limit'
        $s.Save()
    }
    Write-Host "PathShrink installed in $dest" -ForegroundColor Green
    if (-not $NoShortcut) { Write-Host 'Open it from the Start menu: PathShrink' }
    Write-Host "Command line: Import-Module '$dest\PathShrink\PathShrink.psd1'; Invoke-PathShrink -WhatIf"
    if (-not $NoStart) {
        Write-Host 'Opening PathShrink'
        # From an elevated install, File Explorer opens it as the signed-in user, not as administrator.
        if (Test-Path -LiteralPath $exe) {
            if ($elevated) { Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList ('"{0}"' -f $exe) }
            else { Start-Process -FilePath $exe -WorkingDirectory $dest }
        } else { Start-Process -FilePath (Join-Path $dest 'PathShrink.cmd') -WorkingDirectory $dest -WindowStyle Hidden }
    }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
