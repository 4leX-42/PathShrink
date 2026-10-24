#Requires -Version 5.1

<#
.SYNOPSIS
    Builds out\PathShrink.zip and its .sha256 from the working tree, for a GitHub release.
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
$zip = Join-Path $OutDir 'PathShrink.zip'
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
Set-Content -LiteralPath "$zip.sha256" -Value ('{0}  PathShrink.zip' -f $hash) -Encoding ASCII
Remove-Item -LiteralPath $stage -Recurse -Force
Write-Host ('PathShrink {0}: {1} ({2:N0} KB)' -f $version, $zip, ((Get-Item $zip).Length / 1KB))
Write-Host ('SHA-256 {0}' -f $hash)
