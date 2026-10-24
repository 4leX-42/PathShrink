#Requires -Version 5.1

<#
.SYNOPSIS
    Renders the window off-screen in each state to PNG (docs\images), using the demo folder.
.PARAMETER DemoPath
    Where to create the demo folder (it must not exist). Use a neutral path, for example on a
    drive made with subst, so screenshots do not show your user name.
.PARAMETER Scale
    Render scale: 1 = 100 %, 1.5 = 150 %. Use it to check the layout at other display scalings.
#>
[CmdletBinding()]
param([double]$Scale = 1.0, [string]$OutDir, [string]$DemoPath, [ValidateSet('en', 'es', 'pt')][string]$Language = 'en')

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not $OutDir) { $OutDir = Join-Path $repo 'docs\images' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$demo = $DemoPath
if (-not $demo) { $demo = Join-Path ([IO.Path]::GetTempPath()) ('PathShrinkDemo-' + [guid]::NewGuid().ToString('N').Substring(0, 6)) }
& (Join-Path $PSScriptRoot 'New-DemoFolder.ps1') -Path $demo | Out-Null
try {
    $m = Import-Module (Join-Path $repo 'PathShrink\PathShrink.psd1') -Force -PassThru
    foreach ($s in 'start', 'results', 'pro', 'confirm', 'done') {
        $file = Join-Path $OutDir ('{0}{1}{2}.png' -f $s, $(if ($Language -ne 'en') { '.' + $Language } else { '' }), $(if ($Scale -ne 1) { '@' + $Scale + 'x' } else { '' }))
        & $m {
            param($demo, $s, $file, $Scale, $Language)
            . (Join-Path $script:ModuleRoot 'gui\Gui.ps1')
            Show-PathShrinkWindow -Root $demo -Upn 'ana.perez@contoso.com' -Screenshot $file -ScreenshotState $s -ScreenshotScale $Scale -Language $Language
        } $demo $s $file $Scale $Language
        Write-Host $file
    }
} finally {
    [IO.Directory]::Delete('\\?\' + $demo, $true)
}
