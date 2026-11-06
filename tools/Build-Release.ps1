#Requires -Version 5.1

<#
.SYNOPSIS
    Builds out\PathShrink.zip, out\PathShrink-script.zip and their .sha256 from the working tree, for a GitHub release.
.DESCRIPTION
    The zip holds PathShrink.exe, a small launcher compiled here from tools\Launcher.cs with the
    C# compiler of .NET Framework 4 (in every Windows 10 and 11), next to the scripts it opens.
    PathShrink-script.zip is the same without the exe, for computers where an antivirus or EDR stops it.
#>
[CmdletBinding()]
param([string]$OutDir)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not $OutDir) { $OutDir = Join-Path $repo 'out' }
$version = (Test-ModuleManifest (Join-Path $repo 'PathShrink\PathShrink.psd1')).Version
$stage = Join-Path $OutDir 'stage'
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'PathShrink') -Destination $stage -Recurse
foreach ($f in 'PathShrink.ps1', 'PathShrink.cmd', 'README.md', 'LICENSE', 'CHANGELOG.md') { Copy-Item -LiteralPath (Join-Path $repo $f) -Destination $stage }

# Launcher exe, with the icon and the module version.
$csc = @('Framework64', 'Framework') | ForEach-Object { Join-Path $env:WINDIR "Microsoft.NET\$_\v4.0.30319\csc.exe" } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) { throw 'csc.exe of .NET Framework 4 not found, cannot build PathShrink.exe' }
$info = Join-Path $OutDir 'AssemblyInfo.cs'
$v4 = '{0}.{1}.{2}.0' -f $version.Major, $version.Minor, [Math]::Max(0, $version.Build)
Set-Content -LiteralPath $info -Encoding ASCII -Value @(
    'using System.Reflection;'
    '[assembly: AssemblyTitle("PathShrink")]'
    '[assembly: AssemblyProduct("PathShrink")]'
    '[assembly: AssemblyDescription("Fix OneDrive and SharePoint paths over the 400-character limit")]'
    '[assembly: AssemblyCompany("4leX-42")]'
    '[assembly: AssemblyCopyright("(c) 2026 4leX-42. MIT License.")]'
    ('[assembly: AssemblyVersion("{0}")]' -f $v4)
    ('[assembly: AssemblyFileVersion("{0}")]' -f $v4)
    ('[assembly: AssemblyInformationalVersion("{0}")]' -f $version)
)
$exe = Join-Path $stage 'PathShrink.exe'
$out = & $csc /nologo /target:winexe /platform:anycpu /optimize+ "/out:$exe" "/win32icon:$(Join-Path $repo 'PathShrink\gui\PathShrink.ico')" /reference:System.Windows.Forms.dll (Join-Path $PSScriptRoot 'Launcher.cs') $info 2>&1
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exe)) { throw ('PathShrink.exe did not build: ' + ($out -join ' ')) }
Remove-Item -LiteralPath $info -Force

$zip = Join-Path $OutDir 'PathShrink.zip'
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
Set-Content -LiteralPath "$zip.sha256" -Value ('{0}  PathShrink.zip' -f $hash) -Encoding ASCII

# Same files without the exe: that route must never put it on disk.
Remove-Item -LiteralPath $exe -Force
$scriptZip = Join-Path $OutDir 'PathShrink-script.zip'
if (Test-Path -LiteralPath $scriptZip) { Remove-Item -LiteralPath $scriptZip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $scriptZip
Add-Type -AssemblyName System.IO.Compression.FileSystem
$check = [IO.Compression.ZipFile]::OpenRead($scriptZip)
try { if (@($check.Entries | Where-Object { $_.Name -like '*.exe' }).Count) { throw 'PathShrink-script.zip must not contain an exe' } } finally { $check.Dispose() }
$scriptHash = (Get-FileHash -LiteralPath $scriptZip -Algorithm SHA256).Hash
Set-Content -LiteralPath "$scriptZip.sha256" -Value ('{0}  PathShrink-script.zip' -f $scriptHash) -Encoding ASCII
Remove-Item -LiteralPath $stage -Recurse -Force
Write-Host ('PathShrink {0}: {1} ({2:N0} KB)' -f $version, $zip, ((Get-Item $zip).Length / 1KB))
Write-Host ('SHA-256 {0}' -f $hash)
Write-Host ('PathShrink {0}: {1} ({2:N0} KB)' -f $version, $scriptZip, ((Get-Item $scriptZip).Length / 1KB))
Write-Host ('SHA-256 {0}' -f $scriptHash)
