#Requires -Version 5.1

<#
.SYNOPSIS
    Drives the real window through UI Automation on a demo folder: folder picker, scan, plan view, help, Pro, apply, checked revert, demo.
.DESCRIPTION
    Starts PathShrink in its own STA process, clicks through the main flow like a user, and
    checks that the folder is back to its original state at the end. Needs an interactive
    desktop (not for CI). Only touches a throw-away demo folder under %TEMP%, and keeps the
    run's reports next to it, out of the real history.
.PARAMETER Edition
    powershell (Windows PowerShell 5.1) or pwsh (PowerShell 7).
#>
[CmdletBinding()]
param([ValidateSet('powershell', 'pwsh')][string]$Edition = 'powershell')

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$repo = Split-Path $PSScriptRoot -Parent
$demo = Join-Path ([IO.Path]::GetTempPath()) ('PathShrinkTest-gui' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$reports = $demo + '-reports'
& (Join-Path $repo 'tools\New-DemoFolder.ps1') -Path $demo | Out-Null
$base = '\\?\' + $demo
function Get-Tree { @([IO.Directory]::GetFileSystemEntries($base, '*', 'AllDirectories') | Sort-Object) }
$original = Get-Tree
$AE = [Windows.Automation.AutomationElement]
$fails = 0
function Check([bool]$Cond, [string]$What) { if ($Cond) { Write-Host "  ok   $What" -ForegroundColor Green } else { Write-Host "  FAIL $What" -ForegroundColor Red; $script:fails++ } }
function Find([string]$Name, [int]$Timeout = 15, $Root = $script:win) {
    $cond = New-Object Windows.Automation.PropertyCondition($AE::NameProperty, $Name)
    $t = [DateTime]::Now
    while (([DateTime]::Now - $t).TotalSeconds -lt $Timeout) {
        foreach ($e in $Root.FindAll([Windows.Automation.TreeScope]::Descendants, $cond)) { if (-not $e.Current.IsOffscreen) { return $e } }
        Start-Sleep -Milliseconds 150
    }
    $null
}
function FindLike([string]$Pattern, [int]$Timeout = 15, [switch]$Enabled) {
    $t = [DateTime]::Now
    while (([DateTime]::Now - $t).TotalSeconds -lt $Timeout) {
        foreach ($e in $script:win.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)) {
            if ($e.Current.Name -like $Pattern -and -not $e.Current.IsOffscreen -and (-not $Enabled -or $e.Current.IsEnabled)) { return $e }
        }
        Start-Sleep -Milliseconds 200
    }
    $null
}
function Click($El) { $El.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke() }
function Press([string]$Name, [int]$Timeout = 15) {
    $e = Find $Name $Timeout
    if (-not $e) { throw "Button not found: $Name" }
    Click $e
}
function Choose($El) { $El.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select() }
function Set-Text($El, [string]$Text) { $El.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($Text) }
function Get-Text($El) { $El.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value }

$launch = "Import-Module '$repo\PathShrink\PathShrink.psd1'; Start-PathShrink -Root '$demo' -Upn 'ana.perez@contoso.com' -Language en -ReportRoot '$reports'"
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

    # Folder: the Windows picker (Explorer-style dialog), then a typed path with spaces.
    $sub = Join-Path $demo 'Desktop'
    Press 'Browse for a folder'
    $dlg = $null; $t = [DateTime]::Now
    while (-not $dlg -and ([DateTime]::Now - $t).TotalSeconds -lt 15) {
        $c = New-Object Windows.Automation.AndCondition((New-Object Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $proc.Id)), (New-Object Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [Windows.Automation.ControlType]::Window)))
        $dlg = $script:win.FindFirst('Children', $c)
        if (-not $dlg) { $dlg = $AE::RootElement.FindFirst('Children', (New-Object Windows.Automation.AndCondition((New-Object Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $proc.Id)), (New-Object Windows.Automation.PropertyCondition($AE::ClassNameProperty, '#32770'))))) }
        Start-Sleep -Milliseconds 200
    }
    Check ([bool]$dlg) 'Windows folder picker opens'
    if ($dlg) {
        Check ([bool]($dlg.FindFirst('Descendants', (New-Object Windows.Automation.PropertyCondition($AE::ClassNameProperty, 'SearchEditBox'))) -or $dlg.FindFirst('Descendants', (New-Object Windows.Automation.PropertyCondition($AE::AutomationIdProperty, 'SearchEditBox'))))) 'picker has the Explorer search box'
        # The "Folder:" box and the select button are plain Win32 children of the dialog: the
        # path is pasted with WM_SETTEXT and the button pressed with BM_CLICK, as a user would type.
        Add-Type -Namespace PathShrinkTest -Name User32 -MemberDefinition '[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, string l);'
        $kids = @($dlg.FindAll('Children', [Windows.Automation.Condition]::TrueCondition))
        $edit = $kids | Where-Object { $_.Current.ClassName -eq 'Edit' } | Select-Object -First 1
        $ok = $kids | Where-Object { $_.Current.ClassName -eq 'Button' } | Select-Object -First 1
        [void][PathShrinkTest.User32]::SendMessage([IntPtr]$edit.Current.NativeWindowHandle, 0x000C, [IntPtr]::Zero, $sub)
        [void][PathShrinkTest.User32]::SendMessage([IntPtr]$ok.Current.NativeWindowHandle, 0x00F5, [IntPtr]::Zero, $null)
        $box = Find 'Folder path'
        $t = [DateTime]::Now; while ((Get-Text $box) -ne $sub -and ([DateTime]::Now - $t).TotalSeconds -lt 10) { Start-Sleep -Milliseconds 200 }
        Check ((Get-Text $box) -eq $sub -and [bool](FindLike 'Folder  /  ana.perez*' 5)) 'folder chosen in the picker is used'
    }
    $box = Find 'Folder path'
    Set-Text $box $demo
    Click (Find 'Use this path' 5)
    Check ((Get-Text $box) -eq $demo -and [bool](FindLike 'Folder  /  ana.perez*' 5) -and (Find 'Scan for long paths').Current.IsEnabled) 'typed path is used'

    Press 'Scan for long paths'
    $t1 = [DateTime]::Now
    $apply = FindLike 'Apply * changes' 60
    Check ([bool]$apply) ('scan finishes and shows the summary ({0:N1} s)' -f ([DateTime]::Now - $t1).TotalSeconds)
    Check ([bool](Find 'Simulation, nothing has been changed yet' 3)) 'summary says nothing has changed yet'
    Check ([bool](FindLike 'BEFORE' 3)) 'before and after comparison is shown'
    Check ([bool](Find 'Show a plan that also shortens folder names' 3)) 'offers shortening for paths that do not fit'
    Check (-not (Find 'Log' 1)) 'Pro tabs hidden in Basic mode'

    Press 'View plan'
    Check ([bool](FindLike 'Rename folder*' 10)) 'plan view lists the operations'
    Check ([bool](FindLike 'Needed for * long paths*' 3)) 'each operation says why it is needed'
    Press 'Back'
    Check ([bool](Find 'Simulation, nothing has been changed yet' 5)) 'Back returns to the summary'

    Press 'Help'
    Check ([bool](Find 'What PathShrink does' 5)) 'help opens'
    Check ([bool](Find 'Shorten names (removes letters)' 3)) 'help explains shortening names'
    Press 'Close help'

    Choose (Find 'Pro mode')
    Check ([bool](Find 'Log' 5)) 'Pro mode shows the Log tab'
    Check ([bool](Find 'Limit' 3)) 'Pro mode shows the rules'

    Press 'Show a plan that also shortens folder names'
    $apply = FindLike 'Apply * changes' 60
    Check ([bool]$apply) 'shortening plan computed in the background'
    Check (-not (Find 'Show a plan that also shortens folder names' 2)) 'offer gone once shortening is on'

    Press 'Edit names'
    Check ([bool](Find 'Edit the names in this path' 5)) 'name editor opens from the comparison'
    $box = @($script:win.FindAll('Descendants', (New-Object Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [Windows.Automation.ControlType]::Edit))) | Where-Object { $_.Current.Name -eq 'Level 2' })[0]
    Set-Text $box 'a:b'
    Press 'Use these names'
    Check ([bool](FindLike '*cannot contain*' 5)) 'editor refuses a name Windows does not allow and stays open'
    Set-Text $box 'Act'
    Press 'Use these names'
    Check ([bool](FindLike '*edited by hand*' 10)) 'name typed by hand is used in the plan'
    $apply = FindLike 'Apply * changes' 30

    Click $apply
    $go = FindLike 'Rename * items' 10
    Check ([bool]$go) 'confirmation dialog appears'
    Check ([bool](FindLike 'Some names lose letters*' 3)) 'dialog warns that letters are removed'
    Click $go
    $revert = Find 'Revert changes' 60
    Check ([bool]$revert) 'apply finishes and offers to revert'
    Check ([bool](FindLike '* items renamed, checked on disk*' 3)) 'result is checked on disk'
    $changed = Get-Tree
    Check (($changed -join '|') -ne ($original -join '|')) 'folders were renamed on disk'
    $prefix = 'personal/ana_perez_contoso_com/Documents/'.Length
    $over = @($changed | Where-Object { $prefix + $_.Length - $base.Length - 1 -gt 400 }).Count
    Check ($over -eq 0) ('no path over 400 after apply ({0})' -f $over)

    Click $revert
    $go = FindLike 'Revert * changes*' 30 -Enabled
    Check ([bool]$go) 'history checks the run and offers the revert'
    Check ([bool](FindLike 'All * items are where PathShrink left them*' 3)) 'check confirms every item can be restored'
    Click $go
    Click (FindLike 'Restore * names' 10)
    Check ([bool](Find 'Revert finished' 60)) 'revert finishes'
    Check (((Get-Tree) -join '|') -eq ($original -join '|')) 'folder is back to its original state'
    Press 'OK' 5
    Check ([bool](FindLike 'Reverted' 10)) 'history marks the run as reverted'

    Press 'Back'
    Press 'See how it works' 10
    Check ([bool](Find 'Made-up example, your files are not touched' 5)) 'demo opens'
    Choose (FindLike '3 ? Shorten names' 5)
    Check ([bool](FindLike 'Not needed, the path already fits*' 5)) 'demo says when shortening names is not needed'
    Choose (Find 'Engineering project' 5)
    Choose (FindLike '2 ? Join words' 5)
    Check ([bool](FindLike 'There are no spaces between words here*' 5)) 'demo says when a step changes nothing'
    Choose (FindLike '3 ? Shorten names' 5)
    Check ([bool](FindLike '*fits with margin' 5)) 'demo shows the result of shortening names'
    Check (((Get-Tree) -join '|') -eq ($original -join '|')) 'demo did not touch the disk'
} finally {
    if (-not $proc.HasExited) { $proc.CloseMainWindow() | Out-Null; if (-not $proc.WaitForExit(5000)) { $proc.Kill() } }
    foreach ($d in $base, ('\\?\' + $reports)) { if ([IO.Directory]::Exists($d)) { [IO.Directory]::Delete($d, $true) } }
}
if ($fails) { Write-Host "$fails checks failed" -ForegroundColor Red; exit 1 } else { Write-Host 'GUI smoke test passed' -ForegroundColor Green }
