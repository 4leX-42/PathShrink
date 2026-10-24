#Requires -Version 5.1

<#
.SYNOPSIS
    Drives the real window through UI Automation on a demo folder: scan, Pro mode, trim plan, apply, undo.
.DESCRIPTION
    Starts PathShrink in its own STA process, clicks through the main flow like a user, and
    checks that the folder is back to its original state at the end. Needs an interactive
    desktop (not for CI). Only touches a throw-away demo folder under %TEMP%.
.PARAMETER Edition
    powershell (Windows PowerShell 5.1) or pwsh (PowerShell 7).
#>
[CmdletBinding()]
param([ValidateSet('powershell', 'pwsh')][string]$Edition = 'powershell')

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$repo = Split-Path $PSScriptRoot -Parent
$demo = Join-Path ([IO.Path]::GetTempPath()) ('PathShrinkTest-gui' + [guid]::NewGuid().ToString('N').Substring(0, 6))
& (Join-Path $repo 'tools\New-DemoFolder.ps1') -Path $demo | Out-Null
$base = '\\?\' + $demo
$original = @([IO.Directory]::GetFileSystemEntries($base, '*', 'AllDirectories') | Sort-Object)
$AE = [Windows.Automation.AutomationElement]
$fails = 0
function Check([bool]$Cond, [string]$What) { if ($Cond) { Write-Host "  ok   $What" -ForegroundColor Green } else { Write-Host "  FAIL $What" -ForegroundColor Red; $script:fails++ } }
function Find([string]$Name, [int]$Timeout = 15) {
    $cond = New-Object Windows.Automation.PropertyCondition($AE::NameProperty, $Name)
    $t = [DateTime]::Now
    while (([DateTime]::Now - $t).TotalSeconds -lt $Timeout) {
        $e = $script:win.FindFirst([Windows.Automation.TreeScope]::Descendants, $cond)
        if ($e -and -not $e.Current.IsOffscreen) { return $e }
        Start-Sleep -Milliseconds 150
    }
    $null
}
function FindLike([string]$Pattern, [int]$Timeout = 15) {
    $t = [DateTime]::Now
    while (([DateTime]::Now - $t).TotalSeconds -lt $Timeout) {
        foreach ($e in $script:win.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)) {
            if ($e.Current.Name -like $Pattern -and -not $e.Current.IsOffscreen) { return $e }
        }
        Start-Sleep -Milliseconds 200
    }
    $null
}
function Click($El) { $El.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke() }
function Choose($El) { $El.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select() }

$launch = "Import-Module '$repo\PathShrink\PathShrink.psd1'; Start-PathShrink -Root '$demo' -Upn 'ana.perez@contoso.com'"
$proc = Start-Process $Edition -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-Command', $launch -WindowStyle Hidden -PassThru
try {
    $t0 = [DateTime]::Now
    $script:win = $null
    while (-not $script:win -and ([DateTime]::Now - $t0).TotalSeconds -lt 30) {
        $proc.Refresh()
        if ($proc.MainWindowHandle -ne 0) { $script:win = $AE::FromHandle($proc.MainWindowHandle) }
        Start-Sleep -Milliseconds 100
    }
    Check ([bool]$script:win) ('window opens ({0:N1} s)' -f ([DateTime]::Now - $t0).TotalSeconds)
    if (-not $script:win) { throw 'No window' }

    Click (Find 'Scan for long paths')
    $t1 = [DateTime]::Now
    $apply = FindLike 'Review and apply * changes' 60
    Check ([bool]$apply) ('scan finishes and shows the plan ({0:N1} s)' -f ([DateTime]::Now - $t1).TotalSeconds)
    Check ([bool](Find 'Show a plan that also trims letters' 3)) 'offers trimming for paths that do not fit'
    Check (-not (Find 'Log' 1)) 'Pro tabs hidden in Basic mode'

    Choose (Find 'Pro mode')
    Check ([bool](Find 'Log' 5)) 'Pro mode shows the Log tab'
    Check ([bool](Find 'Limit' 3)) 'Pro mode shows the rules'

    Click (Find 'Show a plan that also trims letters')
    $apply = FindLike 'Review and apply * changes' 60
    Check ([bool]$apply) 'trim plan computed in the background'
    Check (-not (Find 'Show a plan that also trims letters' 2)) 'trim offer gone once trimming is on'

    Click $apply
    $go = FindLike 'Rename * items' 10
    Check ([bool]$go) 'confirmation dialog appears'
    Check ([bool](FindLike 'Some names lose letters*' 3)) 'dialog warns that letters are removed'
    Click $go
    $undo = Find 'Undo these changes' 60
    Check ([bool]$undo) 'apply finishes and shows the result'
    Check ([bool](FindLike 'Renamed * items. Checked on disk*' 3)) 'result is verified on disk'
    $changed = @([IO.Directory]::GetFileSystemEntries($base, '*', 'AllDirectories') | Sort-Object)
    Check (($changed -join '|') -ne ($original -join '|')) 'folders were renamed on disk'
    $prefix = 'personal/ana_perez_contoso_com/Documents/'.Length
    $over = @($changed | Where-Object { $prefix + $_.Length - $base.Length - 1 -gt 400 }).Count
    Check ($over -eq 0) ('no path over 400 after apply ({0})' -f $over)

    Click $undo
    Click (FindLike 'Restore names' 10)
    Check ([bool](Find 'Undo finished' 60)) 'undo finishes'
    $after = @([IO.Directory]::GetFileSystemEntries($base, '*', 'AllDirectories') | Sort-Object)
    Check (($after -join '|') -eq ($original -join '|')) 'folder is back to its original state'
} finally {
    if (-not $proc.HasExited) { $proc.CloseMainWindow() | Out-Null; if (-not $proc.WaitForExit(5000)) { $proc.Kill() } }
    [IO.Directory]::Delete($base, $true)
}
if ($fails) { Write-Host "$fails checks failed" -ForegroundColor Red; exit 1 } else { Write-Host 'GUI smoke test passed' -ForegroundColor Green }
