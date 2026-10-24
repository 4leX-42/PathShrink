#Requires -Version 5.1

<#
.SYNOPSIS
    Static checks: ASCII only, UTF-8 BOM on PowerShell files, parses on this edition, XAML loads, manifest valid, PSScriptAnalyzer clean.
.DESCRIPTION
    Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI, so one typographic dash breaks a
    whole file there. That is why every PowerShell file is ASCII and has a BOM.
    Run it under both powershell.exe and pwsh before a release.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$fail = 0
function Fail([string]$m) { Write-Host "  FAIL $m" -ForegroundColor Red; $script:fail++ }

$ps = Get-ChildItem -LiteralPath $repo -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' -and $_.FullName -notmatch '\\(out|\.git)\\' }
foreach ($f in $ps) {
    $rel = $f.FullName.Substring($repo.Length + 1)
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) { Fail "$rel has no UTF-8 BOM" }
    for ($i = 3; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -gt 127) { Fail ("$rel has a non-ASCII byte at offset {0}" -f $i); break } }
    $errs = $null
    [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
    foreach ($e in $errs) { Fail ("{0}:{1} {2}" -f $rel, $e.Extent.StartLineNumber, $e.Message) }
}
foreach ($f in Get-ChildItem -LiteralPath $repo -Recurse -File | Where-Object { $_.Extension -in '.xaml', '.cmd', '.yml' -and $_.FullName -notmatch '\\(out|\.git)\\' }) {
    $t = [IO.File]::ReadAllText($f.FullName)
    if ($t -match '[^\x00-\x7F]') { Fail ($f.FullName.Substring($repo.Length + 1) + ' is not ASCII') }
}

try { [void](Test-ModuleManifest (Join-Path $repo 'PathShrink\PathShrink.psd1')) } catch { Fail ('manifest: ' + $_.Exception.Message) }

if ([Threading.Thread]::CurrentThread.ApartmentState -eq 'STA') {
    try {
        Add-Type -AssemblyName PresentationFramework
        [void][Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $repo 'PathShrink\gui\MainWindow.xaml')))
    } catch { Fail ('XAML: ' + $_.Exception.Message) }
} else { Write-Host '  skip XAML load (not an STA thread)' }

if (Get-Module -ListAvailable PSScriptAnalyzer) {
    $r = @(Invoke-ScriptAnalyzer -Path (Join-Path $repo 'PathShrink') -Recurse -Settings (Join-Path $repo 'PSScriptAnalyzerSettings.psd1') -Severity Warning, Error)
    $r += @(Invoke-ScriptAnalyzer -Path (Join-Path $repo 'PathShrink.ps1') -Settings (Join-Path $repo 'PSScriptAnalyzerSettings.psd1') -Severity Warning, Error)
    foreach ($x in $r) { Fail ('{0}:{1} {2} {3}' -f (Split-Path $x.ScriptPath -Leaf), $x.Line, $x.RuleName, $x.Message) }
} else { Write-Host '  skip PSScriptAnalyzer (not installed)' }

if ($fail) { Write-Host "$fail static checks failed" -ForegroundColor Red; exit 1 }
Write-Host ('Static checks passed on PowerShell {0}' -f $PSVersionTable.PSVersion) -ForegroundColor Green
