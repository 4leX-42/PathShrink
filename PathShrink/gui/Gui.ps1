# PathShrink window. Dot-sourced by Start-PathShrink inside the module, so it can call the
# core functions directly. Long work (scan, apply, undo) runs in a background runspace and
# reports through a synchronized hashtable that a DispatcherTimer reads: the window never
# blocks. Event handlers run inside ShowDialog, so they see the locals of
# Show-PathShrinkWindow; everything they change lives in the $state and $ui hashtables.

function Show-PathShrinkWindow {
    [CmdletBinding()]
    param(
        [string]$Path,
        [switch]$Pro,
        [string]$Root,
        [string]$Upn,
        [string]$Prefix,
        [string]$Screenshot,
        [ValidateSet('start', 'results', 'confirm', 'done', 'pro')][string]$ScreenshotState = 'start',
        [double]$ScreenshotScale = 1.0
    )
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        throw 'PowerShell is in Constrained Language Mode here (AppLocker or WDAC policy), which blocks windows. Use the command line instead: Invoke-PathShrink -WhatIf'
    }
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        throw 'The window needs a single-threaded apartment. Start PowerShell with -STA, or use PathShrink.cmd.'
    }

    $xaml = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'MainWindow.xaml'))
    $win = [Windows.Markup.XamlReader]::Parse($xaml)
    $ui = @{}
    foreach ($n in @('RootGrid', 'VersionText', 'ModeBasic', 'ModePro', 'BtnMin', 'BtnMax', 'BtnClose', 'SideColumn', 'SidePanel',
            'Step1', 'Step2', 'Step3', 'Step4', 'Step5', 'FolderPath', 'FolderInfo', 'BtnFolder',
            'PanelStart', 'BtnScan', 'StartNote', 'PanelWork', 'WorkTitle', 'WorkBar', 'WorkDetail', 'BtnCancel',
            'PanelResults', 'TileItems', 'TileLong', 'TileLongLabel', 'TileFixed', 'TileLeft', 'ExplainText', 'BtnTrimOffer',
            'TabChanges', 'TabPaths', 'TabIssues', 'TabLog', 'GridChanges', 'GridPaths', 'GridIssues', 'LogBox', 'EmptyText',
            'ColSelect', 'ColMethod', 'BtnRescan', 'BtnExport', 'BtnApply',
            'PanelDone', 'DoneTitle', 'DoneText', 'BtnUndo', 'BtnReports', 'BtnAgain',
            'OptLimit', 'OptMargin', 'OptTrim', 'OptMinName', 'OptExclude', 'OptProtect', 'OptPrefix', 'BtnReplan',
            'BtnUndoFile', 'BtnEnv', 'BtnOpenReports', 'BtnCopyCli', 'StatusText', 'StatusRight',
            'Overlay', 'DlgTitle', 'DlgBody', 'DlgNo', 'DlgYes')) {
        $ui[$n] = $win.FindName($n)
    }
    $state = @{
        Library = $null; Plan = $null; Issues = @(); Result = $null; Busy = $false; Kind = ''
        Job = $null; DlgAction = $null; ScanArgs = $null; LogLines = (New-Object System.Collections.Generic.List[string])
        Manual = $null; NoAnim = [bool]$Screenshot
    }
    $brush = { param($hex) $c = New-Object Windows.Media.BrushConverter; $c.ConvertFromString($hex) }
    $gold = & $brush '#C9A96E'; $text2 = & $brush '#B8B8BC'; $dim = & $brush '#5E5E66'
    $okBrush = & $brush '#7FC97F'; $warnBrush = & $brush '#E0C060'; $badBrush = & $brush '#FF7B72'; $textBrush = & $brush '#E6E6E8'
    $logDir = Join-Path $env:LOCALAPPDATA 'PathShrink\Logs'
    $logFile = Join-Path $logDir ('gui-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
    $ui.VersionText.Text = Get-PathShrinkVersion

    # ---------------------------------------------------------------- helpers
    function Add-Log([string]$Message) {
        $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
        $state.LogLines.Add($line)
        $ui.LogBox.AppendText($line + [Environment]::NewLine)
        $ui.LogBox.ScrollToEnd()
        try {
            if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
            Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
        } catch { Write-Verbose $_.Exception.Message }
    }
    function Set-Status([string]$Left, [string]$Right) {
        $ui.StatusText.Text = $Left
        if ($PSBoundParameters.ContainsKey('Right')) { $ui.StatusRight.Text = $Right }
    }
    function Set-Step([int]$Active) {
        for ($i = 1; $i -le 5; $i++) {
            $t = $ui["Step$i"]
            if ($i -lt $Active) { $t.Foreground = $text2; $t.FontFamily = 'Segoe UI' }
            elseif ($i -eq $Active) { $t.Foreground = $gold; $t.FontFamily = 'Segoe UI Semibold' }
            else { $t.Foreground = $dim; $t.FontFamily = 'Segoe UI' }
        }
    }
    function Show-Panel([string]$Name) {
        foreach ($p in 'PanelStart', 'PanelWork', 'PanelResults', 'PanelDone') {
            $ui[$p].Visibility = $(if ($p -eq $Name) { 'Visible' } else { 'Collapsed' })
        }
        if ($state.NoAnim) { return }
        $fade = New-Object Windows.Media.Animation.DoubleAnimation(0.0, 1.0, (New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(180))))
        $ui[$Name].BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
    }
    function Set-CutShape($Button) {
        try {
            [void]$Button.ApplyTemplate()
            $w = $Button.ActualWidth; $h = $Button.ActualHeight
            if ($w -lt 20 -or $h -lt 20) { return }
            $w = [Math]::Round($w); $h = [Math]::Round($h)
            $inv = [Globalization.CultureInfo]::InvariantCulture
            $c = 9; $s = $Button.Template.FindName('Shape', $Button)
            if ($s) { $s.Data = [Windows.Media.Geometry]::Parse([string]::Format($inv, 'M{0},1 L{1},1 L{1},{2} L{3},{4} L1,{4} L1,{0} Z', (1 + $c), ($w - 1), ($h - 1 - $c), ($w - 1 - $c), ($h - 1))) }
            $f = $Button.Template.FindName('Focus', $Button)
            if ($f) { $w2 = $w - 8; $h2 = $h - 8; $c2 = 6; $f.Data = [Windows.Media.Geometry]::Parse([string]::Format($inv, 'M{0},0 L{1},0 L{1},{2} L{3},{4} L0,{4} L0,{0} Z', $c2, $w2, ($h2 - $c2), ($w2 - $c2), $h2)) }
        } catch { Write-Verbose $_.Exception.Message }
    }
    function Get-Buttons($Node) {
        foreach ($child in [Windows.LogicalTreeHelper]::GetChildren($Node)) {
            if ($child -is [Windows.Controls.Button]) { $child }
            if ($child -is [Windows.DependencyObject]) { Get-Buttons $child }
        }
    }
    function Get-IntOption($Box, [int]$Min, [int]$Max, [int]$Default, [string]$Label) {
        $v = 0
        if (-not [int]::TryParse($Box.Text.Trim(), [ref]$v) -or $v -lt $Min -or $v -gt $Max) {
            throw ('{0} must be a whole number from {1} to {2}.' -f $Label, $Min, $Max)
        }
        $v
    }
    function Get-Lines($Box) { @($Box.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    function Get-PlanArgs {
        $a = @{
            Limit         = (Get-IntOption $ui.OptLimit 50 400 400 'Limit')
            Margin        = (Get-IntOption $ui.OptMargin 0 200 20 'Safety margin')
            MinNameLength = (Get-IntOption $ui.OptMinName 3 200 20 'Shortest name')
            AllowTrim     = [bool]$ui.OptTrim.IsChecked
            Protect       = @(Get-Lines $ui.OptProtect)
        }
        if ($a.Margin -ge $a.Limit) { throw 'The safety margin must be smaller than the limit.' }
        $a
    }
    function Test-CustomRules {
        $ui.OptLimit.Text.Trim() -ne '400' -or $ui.OptMargin.Text.Trim() -ne '20' -or $ui.OptTrim.IsChecked -or
        @(Get-Lines $ui.OptExclude).Count -or @(Get-Lines $ui.OptProtect).Count -or $ui.OptPrefix.Text.Trim()
    }
    function Get-LibraryArgs([string]$Folder) {
        $a = @{}
        if ($Folder) { $a.Path = $Folder }
        $pre = $ui.OptPrefix.Text.Trim()
        if ($state.Manual) {
            $a.Root = $state.Manual.Root
            if ($state.Manual.Upn) { $a.Upn = $state.Manual.Upn }
            if ($state.Manual.ContainsKey('Prefix')) { $a.Prefix = $state.Manual.Prefix }
        }
        if ($pre) { $a.Prefix = $pre; if (-not $a.ContainsKey('Root') -and $Folder) { $a.Root = $Folder } }
        $a
    }
    function Show-Dialog {
        param([string]$Title, [object[]]$Lines, [string]$Yes = 'OK', [string]$No = '', [scriptblock]$OnYes)
        $ui.DlgTitle.Text = $Title
        $ui.DlgBody.Children.Clear()
        foreach ($l in $Lines) {
            $tb = New-Object Windows.Controls.TextBlock
            $tb.TextWrapping = 'Wrap'; $tb.Margin = '0,0,0,8'; $tb.FontSize = 13; $tb.LineHeight = 20
            if ($l -is [hashtable]) { $tb.Text = $l.Text; if ($l.Color) { $tb.Foreground = $l.Color }; if ($l.Mono) { $tb.FontFamily = 'Consolas'; $tb.FontSize = 12 } }
            else { $tb.Text = [string]$l; $tb.Foreground = $textBrush }
            [void]$ui.DlgBody.Children.Add($tb)
        }
        $ui.DlgYes.Content = $Yes
        $ui.DlgNo.Content = $No
        $ui.DlgNo.Visibility = $(if ($No) { 'Visible' } else { 'Collapsed' })
        $state.DlgAction = $OnYes
        $ui.Overlay.Visibility = 'Visible'
        if (-not $state.NoAnim) {
            $fade = New-Object Windows.Media.Animation.DoubleAnimation(0.0, 1.0, (New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(140))))
            $ui.Overlay.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
        }
        $win.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Loaded, [Action] { foreach ($b in (Get-Buttons $ui.Overlay)) { Set-CutShape $b }; if ($ui.DlgNo.Visibility -eq 'Visible') { [void]$ui.DlgNo.Focus() } else { [void]$ui.DlgYes.Focus() } }) | Out-Null
    }
    function Show-Error([string]$What, $Err) {
        $msg = [string]$Err
        if ($Err -is [Management.Automation.ErrorRecord]) { $msg = $Err.Exception.Message }
        Add-Log ('ERROR {0}: {1}' -f $What, $msg)
        $tips = @()
        if ($msg -match 'No OneDrive') { $tips += 'Sign in to OneDrive, or pick a folder with Change folder.' }
        elseif ($msg -match 'not inside OneDrive') { $tips += 'Pick a folder inside OneDrive or a synced SharePoint library. To check any other folder, switch to Pro and type its server prefix.' }
        elseif ($msg -match 'denied|access') { $tips += 'Close any file open from that folder, then try again. Run PathShrink as the user who owns the OneDrive, not as an administrator.' }
        elseif ($msg -match 'used by another process|being used') { $tips += 'A file is open in another program. Close it and try again.' }
        else { $tips += 'Details are in the log (Pro mode) and in ' + $logFile }
        Show-Dialog -Title $What -Lines (@(@{ Text = $msg; Color = $badBrush }) + $tips)
    }
    function Set-Busy([bool]$Busy) {
        $state.Busy = $Busy
        foreach ($b in 'BtnFolder', 'BtnReplan', 'BtnUndoFile', 'BtnScan') { $ui[$b].IsEnabled = -not $Busy }
    }

    # ---------------------------------------------------------------- folder
    function Set-Library($Lib) {
        $state.Library = $Lib
        $ui.FolderPath.Text = $Lib.Path
        $parts = @($Lib.Kind)
        if ($Lib.Account) { $parts += $Lib.Account }
        $parts += ('web path prefix {0} characters' -f $Lib.Prefix.Length)
        if ($ui.ModePro.IsChecked) { $parts += ('"{0}" ({1})' -f $Lib.Prefix, $Lib.PrefixSource) }
        if (Test-CustomRules) { $parts += 'custom rules active' }
        $ui.FolderInfo.Text = $parts -join '  /  '
        $ui.FolderInfo.Foreground = $text2
        $ui.BtnScan.IsEnabled = $true
        $ui.StartNote.Text = 'Read-only. Cloud-only files are not downloaded.'
    }
    function Select-Library([string]$Folder) {
        try {
            $la = Get-LibraryArgs $Folder; $lib = Get-PathShrinkLibrary @la
            Set-Library $lib
            Add-Log ('Folder: {0} ({1}, prefix {2} chars from {3})' -f $lib.Path, $lib.Kind, $lib.Prefix.Length, $lib.PrefixSource)
            $state.Plan = $null
            Show-Panel 'PanelStart'; Set-Step 2
            Set-Status 'Ready to scan' ''
            return $true
        } catch {
            $state.Library = $null
            $ui.FolderPath.Text = $(if ($Folder) { $Folder } else { 'No OneDrive folder found' })
            $ui.FolderInfo.Text = $_.Exception.Message
            $ui.FolderInfo.Foreground = $warnBrush
            $ui.BtnScan.IsEnabled = $false
            $ui.StartNote.Text = 'Choose a folder to start.'
            Set-Step 1
            Add-Log ('Folder not usable: {0}' -f $_.Exception.Message)
            return $false
        }
    }

    # ---------------------------------------------------------------- background jobs
    $worker = {
        param($ModulePath, $Kind, $A, $Sync)
        $ErrorActionPreference = 'Stop'
        $VerbosePreference = 'Continue'
        try {
            Import-Module $ModulePath -Force
            switch ($Kind) {
                'scan' {
                    $la = $A.LibraryArgs; $lib = Get-PathShrinkLibrary @la
                    $Sync.Phase = 'scan'
                    $inv = Get-PathShrinkInventory -Library $lib -Exclude $A.Exclude -OnProgress { param($n) $Sync.Count = $n }
                    $Sync.Phase = 'plan'
                    $pa = $A.PlanArgs
                    $plan = New-PathShrinkPlan -Inventory $inv -Limit $pa.Limit -Margin $pa.Margin -AllowTrim:$pa.AllowTrim -MinNameLength $pa.MinNameLength -Protect $pa.Protect
                    $issues = @(Find-PathShrinkSyncIssue -Inventory $inv)
                    $Sync.Result = @{ Library = $lib; Inventory = $inv; Plan = $plan; Issues = $issues }
                }
                'plan' {
                    $pa = $A.PlanArgs
                    $plan = New-PathShrinkPlan -Inventory $A.Inventory -Limit $pa.Limit -Margin $pa.Margin -AllowTrim:$pa.AllowTrim -MinNameLength $pa.MinNameLength -Protect $pa.Protect
                    $Sync.Result = @{ Library = $A.Inventory.Library; Inventory = $A.Inventory; Plan = $plan; Issues = $A.Issues }
                }
                'apply' {
                    $Sync.Result = Invoke-PathShrinkPlan -Plan $A.Plan -Confirm:$false -OnProgress { param($i, $t) $Sync.Count = $i; $Sync.Total = $t }
                }
                'undo' {
                    $Sync.Result = Undo-PathShrink -UndoFile $A.UndoFile -Confirm:$false
                }
            }
        } catch { $Sync.Error = $_.Exception.Message } finally { $Sync.Done = $true }
    }

    function Start-Work([string]$Kind, [hashtable]$JobArgs, [string]$Title) {
        $sync = [hashtable]::Synchronized(@{ Done = $false; Error = $null; Result = $null; Count = 0; Total = 0; Phase = '' })
        $ps = [PowerShell]::Create()
        $ps.Runspace = [RunspaceFactory]::CreateRunspace()
        $ps.Runspace.Open()
        [void]$ps.AddScript($worker).AddArgument((Join-Path $script:ModuleRoot 'PathShrink.psd1')).AddArgument($Kind).AddArgument($JobArgs).AddArgument($sync)
        $state.Job = @{ PS = $ps; Handle = $ps.BeginInvoke(); Sync = $sync; Kind = $Kind; LogIndex = 0; Started = [DateTime]::Now; Cancelled = $false }
        $state.Kind = $Kind
        Set-Busy $true
        $ui.WorkTitle.Text = $Title
        $ui.WorkDetail.Text = ''
        $ui.WorkBar.IsIndeterminate = $true
        $ui.BtnCancel.Visibility = $(if ($Kind -eq 'scan' -or $Kind -eq 'plan') { 'Visible' } else { 'Collapsed' })
        Show-Panel 'PanelWork'
        $timer.Start()
    }

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(120)
    $timer.Add_Tick({
        $j = $state.Job
        if (-not $j) { $timer.Stop(); return }
        $verbose = $j.PS.Streams.Verbose
        while ($j.LogIndex -lt $verbose.Count) { Add-Log $verbose[$j.LogIndex].Message; $j.LogIndex++ }
        $s = $j.Sync
        $secs = ([DateTime]::Now - $j.Started).TotalSeconds
        switch ($j.Kind) {
            'scan' {
                if ($s.Phase -eq 'plan') { $ui.WorkDetail.Text = ('{0:N0} items read. Working out the shortest changes...' -f $s.Count) }
                else { $ui.WorkDetail.Text = ('{0:N0} items read' -f $s.Count) }
            }
            'apply' {
                if ($s.Total) { $ui.WorkBar.IsIndeterminate = $false; $ui.WorkBar.Maximum = $s.Total; $ui.WorkBar.Value = $s.Count }
                $ui.WorkDetail.Text = $(if ($s.Count -ge $s.Total -and $s.Total) { 'Checking the result on disk...' } else { '{0} of {1} renamed' -f $s.Count, $s.Total })
            }
        }
        Set-Status $ui.WorkTitle.Text ('{0:N0} s' -f $secs)
        if (-not $s.Done) { return }
        $timer.Stop()
        try { $j.PS.EndInvoke($j.Handle) } catch { Write-Verbose $_.Exception.Message }
        $j.PS.Runspace.Dispose(); $j.PS.Dispose()
        $state.Job = $null
        Set-Busy $false
        if ($j.Cancelled) { Show-Panel 'PanelStart'; Set-Step 2; Set-Status 'Cancelled' ''; return }
        if ($s.Error) {
            Show-Panel $(if ($state.Plan -and $j.Kind -ne 'scan') { 'PanelResults' } else { 'PanelStart' })
            Show-Error $(switch ($j.Kind) { 'scan' { 'The scan failed' } 'plan' { 'The plan failed' } 'apply' { 'Renaming failed' } default { 'Undo failed' } }) $s.Error
            Set-Status 'Error' ''
            return
        }
        switch ($j.Kind) {
            'scan' { Complete-Scan $s.Result }
            'plan' { Complete-Scan $s.Result }
            'apply' { Complete-Apply $s.Result }
            'undo' { Complete-Undo $s.Result }
        }
    })

    # ---------------------------------------------------------------- scan and plan
    function Start-Scan {
        if (-not $state.Library) { return }
        try { $pa = Get-PlanArgs } catch { Show-Error 'Check the rules' $_; return }
        $state.ScanArgs = @{ LibraryArgs = (Get-LibraryArgs $state.Library.Path); Exclude = @(Get-Lines $ui.OptExclude); PlanArgs = $pa }
        Add-Log ('Scan: {0}  limit {1}, margin {2}, trim {3}' -f $state.Library.Path, $pa.Limit, $pa.Margin, $pa.AllowTrim)
        Set-Step 2
        Start-Work 'scan' $state.ScanArgs 'Scanning...'
    }
    function Start-Replan {
        if (-not $state.Inventory) { Start-Scan; return }
        try { $pa = Get-PlanArgs } catch { Show-Error 'Check the rules' $_; return }
        $sameScope = (@(Get-Lines $ui.OptExclude) -join '|') -eq (@($state.ScanArgs.Exclude) -join '|') -and
                     ($ui.OptPrefix.Text.Trim() -eq [string]$state.ScanArgs.LibraryArgs.Prefix)
        if (-not $sameScope) { Start-Scan; return }
        $state.ScanArgs.PlanArgs = $pa
        Add-Log ('Re-plan: limit {0}, margin {1}, trim {2}, shortest name {3}' -f $pa.Limit, $pa.Margin, $pa.AllowTrim, $pa.MinNameLength)
        Start-Work 'plan' @{ Inventory = $state.Inventory; Issues = $state.Issues; PlanArgs = $pa } 'Working out the changes...'
    }
    function Complete-Scan($R) {
        $state.Library = $R.Library; $state.Inventory = $R.Inventory; $state.Plan = $R.Plan; $state.Issues = @($R.Issues)
        Set-Library $R.Library
        Update-Results
        Show-Panel 'PanelResults'
        Set-Step 3
        $sum = Get-PathShrinkSummary -Plan $state.Plan
        Set-Status ('Scanned {0:N0} items' -f $sum.Items) ('{0} long paths, {1} renames planned' -f $sum.LongPaths, $sum.Renames)
        Add-Log ('Plan: {0} long paths, {1} renames, {2} fixed, {3} no margin, {4} too long' -f $sum.LongPaths, $sum.Renames, $sum.Fixed, $sum.NoMargin, $sum.TooLong)
    }
    function Update-Results {
        $p = $state.Plan
        $sum = Get-PathShrinkSummary -Plan $p
        $left = $sum.NoMargin + $sum.TooLong
        $ui.TileItems.Text = '{0:N0}' -f $sum.Items
        $ui.TileLong.Text = '{0:N0}' -f $sum.LongPaths
        $ui.TileLongLabel.Text = 'paths over {0} characters' -f $p.Target
        $ui.TileFixed.Text = '{0:N0}' -f $sum.Fixed
        $ui.TileLeft.Text = '{0:N0}' -f $left
        $ui.TileLeft.Foreground = $(if ($left) { $warnBrush } else { $textBrush })

        $msg = @()
        if (-not $sum.LongPaths) {
            $msg += 'No path is longer than {0} characters (limit {1}, safety margin {2}). Nothing needs to change.' -f $p.Target, $p.Limit, $p.Margin
        } else {
            if ($sum.OverLimit) { $msg += '{0} paths are longer than {1} characters; {2} of them are over the {3}-character limit and cannot sync now.' -f $sum.LongPaths, $p.Target, $sum.OverLimit, $p.Limit }
            else { $msg += '{0} paths are longer than {1} characters. They still sync, but are within {2} characters of the {3} limit.' -f $sum.LongPaths, $p.Target, $p.Margin, $p.Limit }
            if ($sum.Renames) {
                $how = $(if ($p.AllowTrim) { 'removing spaces and, where that is not enough, trimming letters (see the How column in Pro mode)' } else { 'only removing spaces, so no letter is lost ("Tax Returns" becomes "TaxReturns")' })
                $what = $(if ($sum.Files) { '{0} folders and {1} files' -f $sum.Folders, $sum.Files } else { '{0} folders' -f $sum.Folders })
                $fixes = $(if ($sum.Rescued) { 'fixes {0} of them and brings {1} more back under the {2} limit' -f $sum.Fixed, $sum.Rescued, $p.Limit } else { 'fixes {0} of them' -f $sum.Fixed })
                $msg += 'Renaming {0} {1} by {2}.' -f $what, $fixes, $how
                if (-not $sum.Files) { $msg += 'File names are not changed.' }
            }
            if ($left -and -not $p.AllowTrim) { $msg += '{0} still need more room: they only fit if letters are removed from folder names.' -f $left }
            elseif ($left) { $msg += '{0} still do not fit, because they are nested too deep. Move those folders closer to the top of the library.' -f $left }
        }
        if ($sum.Unreadable) { $msg += '{0} folders could not be read and were not checked.' -f $sum.Unreadable }
        $ui.ExplainText.Text = $msg -join ' '
        $ui.BtnTrimOffer.Visibility = $(if ($left -and -not $p.AllowTrim) { 'Visible' } else { 'Collapsed' })

        $ui.GridChanges.ItemsSource = $null
        $ui.GridChanges.ItemsSource = @($p.Renames)
        Update-PathsGrid
        $ui.GridIssues.ItemsSource = @($state.Issues)
        $ui.TabIssues.Content = $(if ($state.Issues.Count) { 'Other sync issues ({0})' -f $state.Issues.Count } else { 'Other sync issues' })
        Update-ApplyButton
        Update-Tab
    }
    function Update-PathsGrid {
        $labels = @{ Fixed = 'Fixed'; NoMargin = 'Fits, no margin'; TooLong = 'Still too long' }
        $colors = @{ Fixed = $okBrush; NoMargin = $warnBrush; TooLong = $badBrush }
        $ui.GridPaths.ItemsSource = @($state.Plan.Paths | Sort-Object @{ e = { $_.Status -eq 'Fixed' } }, @{ e = 'After'; Descending = $true } | ForEach-Object {
            New-Object psobject -Property @{ Label = $labels[$_.Status]; Color = $colors[$_.Status]; Before = $_.Before; After = $_.After; Rel = $_.Rel; NewRel = $_.NewRel }
        })
    }
    function Update-ApplyButton {
        $n = @($state.Plan.Renames | Where-Object { $_.Selected }).Count
        $ui.BtnApply.IsEnabled = $n -gt 0
        $ui.BtnApply.Content = $(if ($n) { '_Review and apply {0} changes' -f $n } else { 'Nothing to apply' })
    }
    function Update-Tab {
        $pro = [bool]$ui.ModePro.IsChecked
        if (-not $pro -and ($ui.TabIssues.IsChecked -or $ui.TabLog.IsChecked)) { $ui.TabChanges.IsChecked = $true }
        $ui.GridChanges.Visibility = $(if ($ui.TabChanges.IsChecked) { 'Visible' } else { 'Collapsed' })
        $ui.GridPaths.Visibility = $(if ($ui.TabPaths.IsChecked) { 'Visible' } else { 'Collapsed' })
        $ui.GridIssues.Visibility = $(if ($ui.TabIssues.IsChecked) { 'Visible' } else { 'Collapsed' })
        $ui.LogBox.Visibility = $(if ($ui.TabLog.IsChecked) { 'Visible' } else { 'Collapsed' })
        $empty = ''
        if ($state.Plan) {
            if ($ui.TabChanges.IsChecked -and -not $state.Plan.Renames.Count) { $empty = $(if ($state.Plan.Paths.Count) { 'No automatic change is possible.' } else { 'Nothing to change.' }) }
            if ($ui.TabPaths.IsChecked -and -not $state.Plan.Paths.Count) { $empty = 'No long paths.' }
            if ($ui.TabIssues.IsChecked -and -not $state.Issues.Count) { $empty = 'No other sync issues found: no reserved names, lock files or characters OneDrive refuses.' }
        }
        $ui.EmptyText.Text = $empty
        $ui.EmptyText.Visibility = $(if ($empty) { 'Visible' } else { 'Collapsed' })
    }

    # ---------------------------------------------------------------- apply, undo
    function Confirm-Apply {
        $sel = @($state.Plan.Renames | Where-Object { $_.Selected })
        if (-not $sel.Count) { return }
        $folders = @($sel | Where-Object { $_.Type -eq 'Folder' }).Count; $files = $sel.Count - $folders
        $lines = @()
        $lines += '{0} new names in {1}.' -f $(if ($files) { '{0} folders and {1} files get' -f $folders, $files } else { '{0} folders get' -f $folders }), $state.Library.Path
        if ($state.Plan.AllowTrim -and @($sel | Where-Object { $_.Method -like '*trim*' }).Count) {
            $lines += @{ Text = 'Some names lose letters. Check the New name column before you continue.'; Color = $warnBrush }
        }
        $lines += 'File contents and dates do not change. OneDrive uploads the new names by itself.'
        $lines += 'Desktop shortcuts, Quick access pins, recent-file lists and copied links that point inside these folders stop working, as with any rename.'
        $lines += 'Close files that are open from these folders first. An undo file is saved so you can restore the original names.'
        Set-Step 4
        Show-Dialog -Title ('Rename {0} items?' -f $sel.Count) -Lines $lines -Yes ('Rename {0} items' -f $sel.Count) -No 'Cancel' -OnYes {
            Add-Log ('Apply: {0} renames' -f @($state.Plan.Renames | Where-Object { $_.Selected }).Count)
            Start-Work 'apply' @{ Plan = $state.Plan } 'Renaming...'
        }
    }
    function Complete-Apply($R) {
        $state.Result = $R
        Set-Step 5
        $clean = -not $R.Failed -and -not $R.StillLong.Count
        $ui.DoneTitle.Text = $(if ($clean) { 'All paths fit now' } elseif (-not $R.Failed -and -not $R.StillOverLimit) { 'Done, with some paths still close to the limit' } else { 'Finished with warnings' })
        $t = @('Renamed {0} items. Checked on disk: {1} of {2} paths are now under {3} characters.' -f $R.Renamed, $R.VerifiedFixed, $R.ExpectedFixed, $state.Plan.Target)
        if ($R.Failed) { $t += '{0} items could not be renamed, usually because a file is open in another program or access is denied. Close them and scan again.' -f $R.Failed }
        if ($R.StillLong.Count) { $t += '{0} paths are still over {1} characters ({2} over the {3} limit). Scan again for the next step.' -f $R.StillLong.Count, $state.Plan.Target, $R.StillOverLimit, $state.Plan.Limit }
        $t += 'OneDrive syncs the new names in the next few minutes; the "path too long" notice then clears by itself.'
        $ui.DoneText.Text = $t -join "`n`n"
        $ui.BtnUndo.IsEnabled = [bool]$R.UndoFile
        Show-Panel 'PanelDone'
        Set-Status ('Renamed {0}, failed {1}' -f $R.Renamed, $R.Failed) ('Undo file: {0}' -f $R.UndoFile)
        Add-Log ('Applied: renamed {0}, failed {1}, still long {2}. Undo file {3}' -f $R.Renamed, $R.Failed, $R.StillLong.Count, $R.UndoFile)
        foreach ($x in $R.Results) { if ($x.Result -ne 'OK') { Add-Log ('  {0}: {1}' -f $x.OriginalPath, $x.Result) } }
    }
    function Confirm-Undo([string]$File) {
        $n = @(Import-Csv -LiteralPath $File | Where-Object { $_.Result -eq 'OK' }).Count
        Show-Dialog -Title ('Restore {0} original names?' -f $n) -Lines @(
            'Every item listed in this undo file gets its original name back.',
            @{ Text = $File; Mono = $true; Color = $text2 },
            'Close files that are open from these folders first.') -Yes 'Restore names' -No 'Cancel' -OnYes {
            Add-Log ('Undo: {0}' -f $state.UndoFile)
            Start-Work 'undo' @{ UndoFile = $state.UndoFile } 'Restoring names...'
        }
        $state.UndoFile = $File
    }
    function Complete-Undo($R) {
        Add-Log ('Undo: restored {0}, failed {1}' -f $R.Restored, $R.Failed)
        foreach ($x in $R.Results) { if ($x.Result -ne 'OK') { Add-Log ('  {0}: {1}' -f $x.Path, $x.Result) } }
        $state.Plan = $null; $state.Inventory = $null
        Show-Panel 'PanelStart'; Set-Step 2
        Set-Status ('Restored {0} names' -f $R.Restored) ''
        $lines = @('Restored {0} names.' -f $R.Restored)
        if ($R.Failed) { $lines += @{ Text = ('{0} could not be restored; see the log.' -f $R.Failed); Color = $warnBrush } }
        Show-Dialog -Title 'Undo finished' -Lines $lines
    }
    function Get-CliCommand {
        $c = 'Invoke-PathShrink'
        $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
        if ($state.Manual -or $ui.OptPrefix.Text.Trim()) {
            $la = Get-LibraryArgs $state.Library.Path
            foreach ($k in 'Root', 'Path', 'Upn', 'Prefix') { if ($la.ContainsKey($k)) { $c += ' -{0} {1}' -f $k, (& $q $la[$k]) } }
        } elseif ($state.Library) { $c += ' -Path ' + (& $q $state.Library.Path) }
        try { $pa = Get-PlanArgs } catch { $pa = @{ Limit = 400; Margin = 20; AllowTrim = $false; MinNameLength = 20; Protect = @() } }
        if ($pa.Limit -ne 400) { $c += ' -Limit ' + $pa.Limit }
        if ($pa.Margin -ne 20) { $c += ' -Margin ' + $pa.Margin }
        if ($pa.AllowTrim) { $c += ' -AllowTrim -MinNameLength ' + $pa.MinNameLength }
        $ex = @(Get-Lines $ui.OptExclude); if ($ex.Count) { $c += ' -Exclude ' + (($ex | ForEach-Object { & $q $_ }) -join ',') }
        if ($pa.Protect.Count) { $c += ' -Protect ' + (($pa.Protect | ForEach-Object { & $q $_ }) -join ',') }
        $c + ' -WhatIf'
    }
    function Set-Mode([bool]$IsPro) {
        $ui.SideColumn.Width = $(if ($IsPro) { New-Object Windows.GridLength 330 } else { New-Object Windows.GridLength 0 })
        $ui.SidePanel.Visibility = $(if ($IsPro) { 'Visible' } else { 'Collapsed' })
        $v = $(if ($IsPro) { 'Visible' } else { 'Collapsed' })
        $ui.ColSelect.Visibility = $v; $ui.ColMethod.Visibility = $v; $ui.TabIssues.Visibility = $v; $ui.TabLog.Visibility = $v
        if ($state.Library) { Set-Library $state.Library }
        Update-Tab
        $win.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Loaded, [Action] { foreach ($b in (Get-Buttons $win)) { Set-CutShape $b } }) | Out-Null
    }

    # ---------------------------------------------------------------- wiring
    foreach ($b in (Get-Buttons $win)) {
        if ($b.Tag -eq 'cut') { $b.Add_SizeChanged({ param($s, $e) Set-CutShape $s }); $b.Add_Loaded({ param($s, $e) Set-CutShape $s }) }
    }
    $ui.BtnMin.Add_Click({ $win.WindowState = 'Minimized' })
    $ui.BtnMax.Add_Click({ $win.WindowState = $(if ($win.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }) })
    $ui.BtnClose.Add_Click({ $win.Close() })
    $win.Add_StateChanged({
        # A maximised WindowChrome window overhangs the screen by the resize border.
        $ui.RootGrid.Margin = $(if ($win.WindowState -eq 'Maximized') { '6' } else { '0' })
        $ui.BtnMax.Content = $(if ($win.WindowState -eq 'Maximized') { [string][char]0xE923 } else { [string][char]0xE922 })
    })
    $win.Add_Closing({
        param($s, $e)
        if ($state.Job -and ($state.Job.Kind -eq 'apply' -or $state.Job.Kind -eq 'undo')) {
            $e.Cancel = $true
            Show-Dialog -Title 'Renaming in progress' -Lines @('Wait until it finishes, so the undo file is complete.')
        } elseif ($state.Job) { try { $state.Job.PS.Stop() } catch { Write-Verbose $_.Exception.Message } }
    })
    $win.Add_SourceInitialized({
        $wa = [Windows.SystemParameters]::WorkArea
        if ($win.Width -gt $wa.Width * 0.96) { $win.Width = [Math]::Max($win.MinWidth, $wa.Width * 0.96) }
        if ($win.Height -gt $wa.Height * 0.94) { $win.Height = [Math]::Max($win.MinHeight, $wa.Height * 0.94) }
    })
    $win.Add_PreviewKeyDown({
        param($s, $e)
        if ($ui.Overlay.Visibility -eq 'Visible' -and $e.Key -eq 'Escape') { $ui.Overlay.Visibility = 'Collapsed'; $state.DlgAction = $null; $e.Handled = $true }
    })
    $win.Add_Drop({
        param($s, $e)
        if ($state.Busy) { return }
        $files = $e.Data.GetData([Windows.DataFormats]::FileDrop)
        if ($files -and (Test-Path -LiteralPath $files[0] -PathType Container)) { [void](Select-Library $files[0]) }
    })

    $ui.ModeBasic.Add_Checked({ Set-Mode $false; Add-Log 'Mode: Basic' })
    $ui.ModePro.Add_Checked({ Set-Mode $true; Add-Log 'Mode: Pro' })
    foreach ($t in 'TabChanges', 'TabPaths', 'TabIssues', 'TabLog') { $ui[$t].Add_Checked({ Update-Tab }) }

    $ui.BtnFolder.Add_Click({
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = 'Folder in OneDrive or a synced SharePoint library'
        if ($state.Library) { $d.SelectedPath = $state.Library.Path }
        if ($d.ShowDialog() -ne 'OK') { return }
        $state.Manual = $null
        [void](Select-Library $d.SelectedPath)
    })
    $ui.BtnScan.Add_Click({ Start-Scan })
    $ui.BtnRescan.Add_Click({ Start-Scan })
    $ui.BtnAgain.Add_Click({ Start-Scan })
    $ui.BtnCancel.Add_Click({
        if ($state.Job) { $state.Job.Cancelled = $true; $ui.WorkDetail.Text = 'Stopping...'; [void]$state.Job.PS.BeginStop($null, $null); Add-Log 'Scan cancelled' }
    })
    $ui.BtnTrimOffer.Add_Click({
        $ui.OptTrim.IsChecked = $true
        Add-Log 'Trimming allowed from the results page'
        Start-Replan
    })
    $ui.BtnReplan.Add_Click({ if ($state.Library) { if ($state.Inventory) { Start-Replan } else { [void](Select-Library $state.Library.Path); Start-Scan } } })
    $ui.BtnApply.Add_Click({ Confirm-Apply })
    $ui.GridChanges.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler] {
        param($s, $e)
        $cb = $e.OriginalSource
        if (-not ($cb -is [Windows.Controls.CheckBox]) -or $cb.Tag -ne 'sel') { return }
        $item = $cb.DataContext
        $item.Selected = [bool]$cb.IsChecked
        [void](Update-PathShrinkPlan -Plan $state.Plan)
        $sum = Get-PathShrinkSummary -Plan $state.Plan
        $ui.TileFixed.Text = '{0:N0}' -f $sum.Fixed
        $ui.TileLeft.Text = '{0:N0}' -f ($sum.NoMargin + $sum.TooLong)
        Update-PathsGrid
        Update-ApplyButton
    })
    $ui.DlgYes.Add_Click({
        $ui.Overlay.Visibility = 'Collapsed'
        $a = $state.DlgAction; $state.DlgAction = $null
        if ($a) { & $a }
    })
    $ui.DlgNo.Add_Click({
        $ui.Overlay.Visibility = 'Collapsed'; $state.DlgAction = $null
        if ($state.Plan -and $ui.PanelResults.Visibility -eq 'Visible') { Set-Step 3 }
    })
    $ui.BtnExport.Add_Click({
        try {
            $f = Export-PathShrinkReport -Plan $state.Plan -SyncIssues $state.Issues
            [IO.File]::WriteAllLines((Join-Path $f 'gui.log'), $state.LogLines)
            Add-Log ('Report: {0}' -f $f)
            Set-Status ('Report saved to {0}' -f $f)
            Start-Process explorer.exe -ArgumentList ('"{0}"' -f $f)
        } catch { Show-Error 'Could not write the report' $_ }
    })
    $ui.BtnReports.Add_Click({ if ($state.Result -and $state.Result.ReportFolder) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $state.Result.ReportFolder) } })
    $ui.BtnOpenReports.Add_Click({
        $d = Join-Path $env:LOCALAPPDATA 'PathShrink\Reports'
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        Start-Process explorer.exe -ArgumentList ('"{0}"' -f $d)
    })
    $ui.BtnUndo.Add_Click({ if ($state.Result -and $state.Result.UndoFile) { Confirm-Undo $state.Result.UndoFile } })
    $ui.BtnUndoFile.Add_Click({
        $d = New-Object Microsoft.Win32.OpenFileDialog
        $d.Filter = 'Undo file (undo.csv)|undo.csv|CSV files (*.csv)|*.csv'
        $rep = Join-Path $env:LOCALAPPDATA 'PathShrink\Reports'
        if (Test-Path -LiteralPath $rep) { $d.InitialDirectory = $rep }
        if ($d.ShowDialog($win)) {
            try { Confirm-Undo $d.FileName } catch { Show-Error 'Could not read the undo file' $_ }
        }
    })
    $ui.BtnEnv.Add_Click({
        $envInfo = Get-PathShrinkEnvironment
        Add-Log 'This computer:'
        foreach ($p in $envInfo.PSObject.Properties) { Add-Log ('  {0,-18} {1}' -f $p.Name, $p.Value) }
        if ($envInfo.Elevated) { Add-Log '  Note: running elevated. Run as the OneDrive user without elevation if the folder belongs to another profile.' }
        $ui.TabLog.IsChecked = $true
        if ($ui.PanelResults.Visibility -ne 'Visible') { Show-Dialog -Title 'This computer' -Lines @($envInfo.PSObject.Properties | ForEach-Object { @{ Text = ('{0,-18} {1}' -f $_.Name, $_.Value); Mono = $true; Color = $textBrush } }) }
    })
    $ui.BtnCopyCli.Add_Click({
        $cmd = Get-CliCommand
        [Windows.Clipboard]::SetText($cmd)
        Add-Log ('Copied: {0}' -f $cmd)
        Set-Status 'Command copied to the clipboard'
    })

    # ---------------------------------------------------------------- start
    if ($Root) { $state.Manual = @{ Root = $Root }; if ($Upn) { $state.Manual.Upn = $Upn }; if ($PSBoundParameters.ContainsKey('Prefix')) { $state.Manual.Prefix = $Prefix } }
    elseif ($PSBoundParameters.ContainsKey('Prefix')) { $ui.OptPrefix.Text = $Prefix }
    Set-Step 1
    Set-Mode ([bool]($Pro -or $ScreenshotState -eq 'pro'))
    if ($Pro -or $ScreenshotState -eq 'pro') { $ui.ModePro.IsChecked = $true }
    Add-Log ('PathShrink {0} on PowerShell {1}' -f (Get-PathShrinkVersion), $PSVersionTable.PSVersion)
    [void](Select-Library $Path)

    if ($Screenshot) {
        # Off-screen render for documentation and visual checks. Runs the real scan and plan.
        $win.WindowStartupLocation = 'Manual'; $win.Left = -30000; $win.Top = 0; $win.ShowActivated = $false; $win.ShowInTaskbar = $false
        $win.Add_ContentRendered({
            if ($ScreenshotState -ne 'start' -and $state.Library) {
                $pa = Get-PlanArgs
                $la = Get-LibraryArgs $state.Library.Path; $lib = Get-PathShrinkLibrary @la
                $inv = Get-PathShrinkInventory -Library $lib -Exclude @(Get-Lines $ui.OptExclude)
                $state.ScanArgs = @{ LibraryArgs = (Get-LibraryArgs $lib.Path); Exclude = @(); PlanArgs = $pa }
                Complete-Scan @{ Library = $lib; Inventory = $inv; Plan = (New-PathShrinkPlan -Inventory $inv -Limit $pa.Limit -Margin $pa.Margin -AllowTrim:$pa.AllowTrim -MinNameLength $pa.MinNameLength); Issues = @(Find-PathShrinkSyncIssue -Inventory $inv) }
                if ($ScreenshotState -eq 'confirm') { Confirm-Apply }
                if ($ScreenshotState -eq 'done') {
                    # Real apply: only ever used on the throw-away demo folder.
                    $rf = Join-Path (Split-Path $state.Library.Base -Parent) ('PathShrinkTest-shot' + [guid]::NewGuid().ToString('N').Substring(0, 6))
                    Complete-Apply (Invoke-PathShrinkPlan -Plan $state.Plan -Confirm:$false -ReportFolder $rf)
                    [IO.Directory]::Delete($rf, $true)
                }
            }
            $win.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Loaded, [Action] {
                foreach ($b in (Get-Buttons $win)) { Set-CutShape $b }
                $win.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::ApplicationIdle, [Action] {
                    $root = $win.Content
                    $w = [int]($root.ActualWidth * $ScreenshotScale); $h = [int]($root.ActualHeight * $ScreenshotScale)
                    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap($w, $h, (96 * $ScreenshotScale), (96 * $ScreenshotScale), [Windows.Media.PixelFormats]::Pbgra32)
                    $bmp.Render($root)
                    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
                    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
                    $fs = [IO.File]::Create($Screenshot); $enc.Save($fs); $fs.Close()
                    $win.Close()
                }) | Out-Null
            }) | Out-Null
        })
    }
    [void]$win.ShowDialog()
}
