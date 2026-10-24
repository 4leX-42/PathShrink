#Requires -Version 5.1

<#
.SYNOPSIS
    Renders the window off-screen in each state to PNG (docs\images), using the demo folder.
.PARAMETER DemoPath
    Where to create the demo folder (it must not exist). Use a neutral path, for example on a
    drive made with subst, so screenshots do not show your user name.
.PARAMETER Scale
    Render scale: 1 = 100 %, 1.5 = 150 %. Use it to check the layout at other display scalings.
.PARAMETER Width
    Window width in pixels at 100 %, to check narrow and wide (maximised) layouts.
.PARAMETER State
    The states to render. Default: all.
#>
[CmdletBinding()]
param(
    [double]$Scale = 1.0,
    [string]$OutDir,
    [string]$DemoPath,
    [ValidateSet('en', 'es', 'pt')][string]$Language = 'en',
    [int]$Width,
    [int]$Height,
    [string[]]$State = @('start', 'results', 'plan', 'pro', 'confirm', 'done', 'history', 'demo', 'help')
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not $OutDir) { $OutDir = Join-Path $repo 'docs\images' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$demo = $DemoPath
if (-not $demo) { $demo = Join-Path ([IO.Path]::GetTempPath()) ('PathShrinkDemo-' + [guid]::NewGuid().ToString('N').Substring(0, 6)) }
# Reports of the demo runs stay next to the demo folder, never in the real history.
$reports = $demo.TrimEnd('\') + '-reports'
try {
    $m = Import-Module (Join-Path $repo 'PathShrink\PathShrink.psd1') -Force -PassThru
    foreach ($s in $State) {
        foreach ($d in $demo, $reports) { if (Test-Path -LiteralPath $d) { [IO.Directory]::Delete('\\?\' + $d, $true) } }
        & (Join-Path $PSScriptRoot 'New-DemoFolder.ps1') -Path $demo | Out-Null
        $suffix = ''
        if ($Language -ne 'en') { $suffix += '.' + $Language }
        if ($Width) { $suffix += '-w' + $Width }
        if ($Scale -ne 1) { $suffix += '@' + $Scale + 'x' }
        $file = Join-Path $OutDir ('{0}{1}.png' -f $s, $suffix)
        & $m {
            param($demo, $s, $file, $Scale, $Language, $reports, $Width, $Height)
            . (Join-Path $script:ModuleRoot 'gui\Gui.ps1')
            Show-PathShrinkWindow -Root $demo -Upn 'ana.perez@contoso.com' -ReportRoot $reports -Screenshot $file -ScreenshotState $s -ScreenshotScale $Scale -Language $Language -ScreenshotWidth $Width -ScreenshotHeight $Height
        } $demo $s $file $Scale $Language $reports $Width $Height
        Write-Host $file
    }
} finally {
    foreach ($d in $demo, $reports) { if (Test-Path -LiteralPath $d) { [IO.Directory]::Delete('\\?\' + $d, $true) } }
}
