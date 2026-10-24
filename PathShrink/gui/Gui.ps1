# PathShrink window. Dot-sourced by Start-PathShrink inside the module, so it can call the
# core functions directly. Long work (scan, apply, check, revert) runs in a background
# runspace and reports through a synchronized hashtable that a DispatcherTimer reads: the
# window never blocks. Event handlers run inside ShowDialog, so they see the locals of
# Show-PathShrinkWindow; everything they change lives in the $state and $ui hashtables.
# Texts live in strings.<lang>.json (UTF-8, so accents never touch a PowerShell file);
# the XAML holds {{key}} markers that are filled in before it is parsed.

$script:PathShrinkLanguages = @('en', 'es', 'pt')
$script:HelpKeys = @('longPath', 'pathLength', 'scan', 'plan', 'dryRun', 'apply', 'revert', 'report', 'clean', 'join', 'trim', 'limit', 'margin', 'minName', 'exclude', 'protect', 'prefix', 'limits')

# Windows folder picker (IFileOpenDialog with FOS_PICKFOLDERS): the Explorer window with the
# address bar, search box and navigation pane. Windows PowerShell 5.1 has no managed wrapper
# for it (FolderBrowserDialog there is the old tree), so it is declared here and compiled the
# first time it is needed. PowerShell 7 uses WPF's own OpenFolderDialog, the same dialog.
$script:FolderPickerSource = @'
using System;
using System.Runtime.InteropServices;
namespace PathShrinkNative {
    public static class FolderPicker {
        [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")] private class FileOpenDialogCom { }
        [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IFileDialog {
            [PreserveSig] int Show(IntPtr parent);
            void SetFileTypes(uint count, IntPtr specs);
            void SetFileTypeIndex(uint index);
            void GetFileTypeIndex(out uint index);
            void Advise(IntPtr events, out uint cookie);
            void Unadvise(uint cookie);
            void SetOptions(uint options);
            void GetOptions(out uint options);
            void SetDefaultFolder(IShellItem item);
            void SetFolder(IShellItem item);
            void GetFolder(out IShellItem item);
            void GetCurrentSelection(out IShellItem item);
            void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
            void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string name);
            void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
            void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
            void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
            void GetResult(out IShellItem item);
        }
        [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellItem {
            void BindToHandler(IntPtr bc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
            void GetParent(out IShellItem parent);
            void GetDisplayName(uint sigdn, [MarshalAs(UnmanagedType.LPWStr)] out string name);
            void GetAttributes(uint mask, out uint attributes);
            void Compare(IShellItem other, uint hint, out int order);
        }
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void SHCreateItemFromParsingName([MarshalAs(UnmanagedType.LPWStr)] string path, IntPtr bc, [In] ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IShellItem item);

        public static string Pick(IntPtr owner, string title, string start) {
            IFileDialog d = (IFileDialog)new FileOpenDialogCom();
            try {
                uint o; d.GetOptions(out o);
                d.SetOptions(o | 0x20u | 0x40u | 0x8u | 0x800u); // pick folders, file system only, keep cwd, path must exist
                if (!String.IsNullOrEmpty(title)) d.SetTitle(title);
                if (!String.IsNullOrEmpty(start)) {
                    try { IShellItem f; Guid g = typeof(IShellItem).GUID; SHCreateItemFromParsingName(start, IntPtr.Zero, ref g, out f); d.SetFolder(f); } catch { }
                }
                int hr = d.Show(owner);
                if (hr == unchecked((int)0x800704C7)) return null;
                if (hr != 0) Marshal.ThrowExceptionForHR(hr);
                IShellItem r; d.GetResult(out r);
                string p; r.GetDisplayName(0x80058000u, out p);
                return p;
            } finally { Marshal.ReleaseComObject(d); }
        }
    }
}
'@

function Select-PathShrinkFolder {
    param($Owner, [string]$Title, [string]$Start)
    $wpf = 'Microsoft.Win32.OpenFolderDialog' -as [type]
    if ($wpf) {
        $d = New-Object $wpf
        $d.Title = $Title
        if ($Start -and (Test-Path -LiteralPath $Start)) { $d.InitialDirectory = $Start }
        if ($d.ShowDialog($Owner)) { return $d.FolderName }
        return $null
    }
    if (-not ('PathShrinkNative.FolderPicker' -as [type])) { Add-Type -TypeDefinition $script:FolderPickerSource -Language CSharp }
    $h = [IntPtr]::Zero
    if ($Owner) { $h = (New-Object Windows.Interop.WindowInteropHelper $Owner).Handle }
    ('PathShrinkNative.FolderPicker' -as [type])::Pick($h, $Title, $Start)
}

function Get-PathShrinkLanguage {
    param([string]$Requested)
    if ($Requested -and $script:PathShrinkLanguages -contains $Requested) { return $Requested }
    $file = Join-Path $env:LOCALAPPDATA 'PathShrink\settings.json'
    try {
        $saved = [string](Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json).language
        if ($script:PathShrinkLanguages -contains $saved) { return $saved }
    } catch { Write-Verbose 'No saved language' }
    $ui = [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName
    if ($script:PathShrinkLanguages -contains $ui) { return $ui }
    'en'
}

function Save-PathShrinkLanguage([string]$Code) {
    $dir = Join-Path $env:LOCALAPPDATA 'PathShrink'
    try {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        (@{ language = $Code } | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $dir 'settings.json') -Encoding UTF8
    } catch { Write-Verbose $_.Exception.Message }
}

function Read-PathShrinkStrings([string]$Code) {
    $h = @{}
    $p = Join-Path $PSScriptRoot ('strings.{0}.json' -f $Code)
    $json = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($prop in $json.PSObject.Properties) { $h[$prop.Name] = [string]$prop.Value }
    $h
}

function New-PathShrinkDemoPlan {
    # The real planner on a made-up tree held in memory: no folder is read or written.
    param([string]$Rel, [bool]$AllowTrim)
    $lib = New-PathShrinkLibrary -Path 'X:\Demo' -Base 'X:\Demo' -Prefix 'personal/ana_perez_contoso_com/Documents/' -PrefixSource 'given' -Personal -Kind 'OneDrive'
    $seg = $Rel.Split('\')
    $items = for ($k = 0; $k -lt $seg.Count; $k++) {
        [pscustomobject]@{ Rel = ($seg[0..$k] -join '\'); Name = $seg[$k]; IsFolder = ($k -lt $seg.Count - 1) }
    }
    $inv = New-Object psobject -Property @{ Library = $lib; Items = @($items); Errors = @(); Skipped = @() }
    New-PathShrinkPlan -Inventory $inv -AllowTrim:$AllowTrim
}

function Show-PathShrinkWindow {
    [CmdletBinding()]
    param(
        [string]$Path,
        [switch]$Pro,
        [string]$Root,
        [string]$Upn,
        [string]$Prefix,
        [string]$Language,
        [string]$ReportRoot,
        [string]$Screenshot,
        [ValidateSet('start', 'results', 'plan', 'confirm', 'done', 'pro', 'history', 'demo', 'help')][string]$ScreenshotState = 'start',
        [double]$ScreenshotScale = 1.0,
        [int]$ScreenshotWidth,
        [int]$ScreenshotHeight
    )
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        throw 'PowerShell is in Constrained Language Mode here (AppLocker or WDAC policy), which blocks windows. Use the command line instead: Invoke-PathShrink -WhatIf'
    }
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        throw 'The window needs a single-threaded apartment. Start PowerShell with -STA, or use PathShrink.cmd.'
    }
    if (-not $ReportRoot) { $ReportRoot = Join-Path $env:LOCALAPPDATA 'PathShrink\Reports' }

    $lang = Get-PathShrinkLanguage $Language
    $stringsEn = Read-PathShrinkStrings 'en'
    $strings = $(if ($lang -eq 'en') { $stringsEn } else { Read-PathShrinkStrings $lang })
    $culture = [Globalization.CultureInfo]::GetCultureInfo($(switch ($lang) { 'es' { 'es-ES' } 'pt' { 'pt-PT' } default { 'en-GB' } }))
    function T([string]$Key) {
        $v = $strings[$Key]
        if (-not $v) { $v = $stringsEn[$Key] }
        if (-not $v) { $v = $Key }
        if ($args.Count) { [string]::Format($culture, $v, [object[]]$args) } else { $v }
    }

    function Get-Template([string]$Key) { $v = $strings[$Key]; if (-not $v) { $v = $stringsEn[$Key] }; if (-not $v) { $v = $Key }; $v }
    $methodText = @{}
    function Get-MethodText([string]$Method) {
        # A handful of combinations ("clean-up + no spaces"...), translated once.
        if (-not $methodText.ContainsKey($Method)) { $methodText[$Method] = @($Method -split ' \+ ' | ForEach-Object { T ('method.' + $_) }) -join '  /  ' }
        $methodText[$Method]
    }

    $xaml = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'MainWindow.xaml'))
    $xaml = [regex]::Replace($xaml, '\{\{([^}]+)\}\}', [Text.RegularExpressions.MatchEvaluator] { param($m) [Security.SecurityElement]::Escape((T $m.Groups[1].Value)) })
    $win = [Windows.Markup.XamlReader]::Parse($xaml)
    $ui = @{}
    foreach ($n in @('RootGrid', 'TitleLogo', 'VersionText', 'BtnHistory', 'BtnHelp', 'LangEN', 'LangES', 'LangPT', 'ModeBasic', 'ModePro', 'BtnMin', 'BtnMax', 'BtnClose',
            'BodyHost', 'SideColumn', 'SidePanel', 'Steps', 'FolderCard', 'FolderLabel', 'FolderPath', 'FolderInfo', 'BtnFolder', 'BtnFolderGo',
            'PanelStart', 'StartLogo', 'BtnScan', 'BtnDemo', 'StartNote', 'PanelWork', 'WorkTitle', 'WorkBar', 'WorkDetail', 'WorkNote', 'BtnCancel',
            'PanelResults', 'TileItems', 'TileLong', 'TileLongLabel', 'TileFixed', 'TileLeft', 'ExplainText', 'TrimOfferRow', 'BtnTrimOffer',
            'TabCompare', 'TabIssues', 'TabLog', 'CompareTools', 'FilterAll', 'FilterFixed', 'FilterLeft', 'SearchBox', 'SearchHint',
            'ResultsScroll', 'CompareList', 'IssuesBox', 'GridIssues', 'LogBorder', 'LogBox', 'EmptyText', 'Pager', 'BtnPrev', 'PageText', 'BtnNext',
            'BtnExport', 'BtnRescan', 'BtnPlan', 'BtnApply',
            'PanelPlan', 'BtnPlanBack', 'BtnCrumbSummary', 'PlanSummary', 'PlanSearch', 'PlanSearchHint', 'PlanSelectTools', 'BtnSelAll', 'BtnSelNone', 'PlanCount',
            'PlanList', 'PlanEmpty', 'BtnPlanSummary', 'BtnPlanApply',
            'PanelDone', 'DoneIcon', 'DoneTitle', 'DoneText', 'DoneRenamed', 'DoneVerified', 'DoneStill', 'DoneFailed', 'RevertCard', 'RevertText', 'BtnUndo', 'BtnReports', 'BtnAgain',
            'PanelHistory', 'BtnHistBack', 'HistList', 'HistEmpty', 'HistDetail', 'HistPick', 'HistWhen', 'HistFolder', 'HistMeta', 'HistCheckText', 'HistCounts',
            'HistReady', 'HistAlready', 'HistBlocked', 'HistBlockedList', 'BtnHistRevert', 'BtnHistCheck', 'BtnHistReport', 'BtnUndoFile', 'BtnOpenReports',
            'PanelDemo', 'BtnDemoBack', 'DemoEx1', 'DemoEx2', 'DemoEx3', 'DemoTrim', 'DemoBefore', 'DemoAfter', 'BtnDemoPlay', 'DemoLen', 'DemoRuler', 'DemoBar',
            'DemoTargetLine', 'DemoLimitLine', 'DemoTargetLabel', 'DemoLimitLabel', 'DemoTree', 'DemoExplain',
            'RulesChip', 'RulesState', 'OptLimit', 'OptMargin', 'OptTrim', 'MinNameRow', 'OptMinName', 'OptExclude', 'OptProtect', 'OptPrefix', 'RulesDirty', 'BtnReplan', 'BtnEnv', 'BtnCopyCli',
            'StatusText', 'StatusRight', 'HelpLayer', 'HelpScrim', 'HelpDrawer', 'BtnHelpClose', 'HelpList', 'HelpPop', 'HelpPopTitle', 'HelpPopBody', 'HelpPopMore',
            'Overlay', 'DlgTitle', 'DlgBody', 'DlgNo', 'DlgYes')) {
        $ui[$n] = $win.FindName($n)
    }
    $state = @{
        Library = $null; Plan = $null; Inventory = $null; Issues = @(); Result = $null; Busy = $false
        Job = $null; DlgAction = $null; ScanArgs = $null; LogLines = (New-Object System.Collections.Generic.List[string])
        Manual = $null; NoAnim = [bool]$Screenshot; Relaunch = $null; Loading = $true
        View = 'PanelStart'; Back = $null; Page = 0; CompareItems = @(); RenameMap = @{}; PlanItems = @()
        History = @(); HistRun = $null; Check = $null; PickAfterHistory = $null; HelpEntries = @{}; HelpKey = $null; HelpFocus = $null
        DemoPlan = $null; DemoShowAfter = $false; SettingPath = $false; Sorted = @(); SortedFor = $null; RenameMapFor = $null; PlanItemsFor = $null
    }
    $brush = { param($hex) $c = New-Object Windows.Media.BrushConverter; $b = $c.ConvertFromString($hex); $b.Freeze(); $b }
    $gold = & $brush '#C9A96E'; $goldHi = & $brush '#E2C48A'; $text2 = & $brush '#B4B4BA'; $text3 = & $brush '#8C8C94'; $lineBrush = & $brush '#303036'
    $okBrush = & $brush '#7FC97F'; $warnBrush = & $brush '#E0C060'; $badBrush = & $brush '#FF7B72'; $textBrush = & $brush '#ECECEE'; $bgBrush = & $brush '#141416'
    $surface = & $brush '#1C1C1F'; $chipBg = & $brush '#262218'
    $beforeBg = & $brush '#201A1A'; $beforeLine = & $brush '#8A5A55'; $beforeMark = & $brush '#4A2A28'; $beforeText = & $brush '#FFB3AC'
    $afterBg = & $brush '#1F1C15'; $afterMark = & $brush '#4A3C1E'; $trackBrush = & $brush '#2A2A30'
    $logDir = Join-Path $env:LOCALAPPDATA 'PathShrink\Logs'
    $logFile = Join-Path $logDir ('gui-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
    $ui.VersionText.Text = Get-PathShrinkVersion
    $ui[('Lang' + $lang.ToUpperInvariant())].IsChecked = $true
    try {
        $logo = New-Object Windows.Media.Imaging.BitmapImage
        $logo.BeginInit(); $logo.UriSource = New-Object Uri (Join-Path $PSScriptRoot 'logo.png'); $logo.CacheOption = 'OnLoad'; $logo.EndInit(); $logo.Freeze()
        $ui.TitleLogo.Source = $logo; $ui.StartLogo.Source = $logo
        $win.Icon = New-Object Windows.Media.Imaging.BitmapImage (New-Object Uri (Join-Path $PSScriptRoot 'PathShrink.ico'))
    } catch { Write-Verbose ('Logo not loaded: {0}' -f $_.Exception.Message) }

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
            $dot = $ui.Steps.FindName("Step${i}Dot"); $num = $ui.Steps.FindName("Step${i}Num"); $lbl = $ui.Steps.FindName("Step$i")
            if ($null -eq $dot) { $dot = $win.FindName("Step${i}Dot"); $num = $win.FindName("Step${i}Num"); $lbl = $win.FindName("Step$i") }
            if ($i -lt $Active) { $dot.Background = $null; $dot.BorderBrush = $gold; $num.Foreground = $gold; $lbl.Foreground = $text2; $lbl.FontFamily = 'Segoe UI' }
            elseif ($i -eq $Active) { $dot.Background = $gold; $dot.BorderBrush = $gold; $num.Foreground = $bgBrush; $lbl.Foreground = $textBrush; $lbl.FontFamily = 'Segoe UI Semibold' }
            else { $dot.Background = $null; $dot.BorderBrush = $lineBrush; $num.Foreground = $text3; $lbl.Foreground = $text3; $lbl.FontFamily = 'Segoe UI' }
        }
    }
    function Show-View([string]$Name) {
        # Plan, history and demo are side trips: "Back" returns to where they were opened from.
        $side = @('PanelPlan', 'PanelHistory', 'PanelDemo')
        if ($side -contains $Name -and $side -notcontains $state.View -and $state.View -ne 'PanelWork') { $state.Back = $state.View }
        $state.View = $Name
        foreach ($p in 'PanelStart', 'PanelWork', 'PanelResults', 'PanelPlan', 'PanelDone', 'PanelHistory', 'PanelDemo') {
            $ui[$p].Visibility = $(if ($p -eq $Name) { 'Visible' } else { 'Collapsed' })
        }
        $ui.Steps.Visibility = $(if ($Name -in 'PanelHistory', 'PanelDemo') { 'Collapsed' } else { 'Visible' })
        $ui.FolderCard.Visibility = $(if ($side -contains $Name) { 'Collapsed' } else { 'Visible' })
        # Full folder card to choose; a compact one while reviewing, so the results get the room.
        $full = $Name -eq 'PanelStart'
        $ui.FolderCard.Padding = $(if ($full) { '20,14' } else { '20,6' })
        $ui.FolderLabel.Visibility = $(if ($full) { 'Visible' } else { 'Collapsed' })
        $ui.FolderInfo.Visibility = $(if ($full -or $ui.FolderInfo.Foreground -ne $text2) { 'Visible' } else { 'Collapsed' })
        if ($state.NoAnim) { return }
        $fade = New-Object Windows.Media.Animation.DoubleAnimation(0.0, 1.0, (New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(160))))
        $ui[$Name].BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
    }
    function Get-HomeView {
        if ($state.Result -and -not $state.Plan) { return 'PanelDone' }
        if ($state.Plan) { return 'PanelResults' }
        'PanelStart'
    }
    function Restore-View {
        $b = $state.Back
        if (-not $b -or ($b -eq 'PanelResults' -and -not $state.Plan) -or ($b -eq 'PanelDone' -and -not $state.Result)) { $b = Get-HomeView }
        if ($b -eq 'PanelResults') { Update-Results }
        Show-View $b
    }
    function Set-CutShape($Button) {
        try {
            [void]$Button.ApplyTemplate()
            $w = $Button.ActualWidth; $h = $Button.ActualHeight
            if ($w -lt 20 -or $h -lt 20) { return }
            $w = [Math]::Round($w); $h = [Math]::Round($h)
            $inv = [Globalization.CultureInfo]::InvariantCulture
            $c = 10; $s = $Button.Template.FindName('Shape', $Button)
            if ($s) { $s.Data = [Windows.Media.Geometry]::Parse([string]::Format($inv, 'M{0},1 L{1},1 L{1},{2} L{3},{4} L1,{4} L1,{0} Z', (1 + $c), ($w - 1), ($h - 1 - $c), ($w - 1 - $c), ($h - 1))) }
            $f = $Button.Template.FindName('Focus', $Button)
            if ($f) { $w2 = $w - 8; $h2 = $h - 8; $c2 = 7; $f.Data = [Windows.Media.Geometry]::Parse([string]::Format($inv, 'M{0},0 L{1},0 L{1},{2} L{3},{4} L0,{4} L0,{0} Z', $c2, $w2, ($h2 - $c2), ($w2 - $c2), $h2)) }
        } catch { Write-Verbose $_.Exception.Message }
    }
    function Get-Buttons($Node) {
        foreach ($child in [Windows.LogicalTreeHelper]::GetChildren($Node)) {
            if ($child -is [Windows.Controls.Button]) { $child }
            if ($child -is [Windows.DependencyObject]) { Get-Buttons $child }
        }
    }
    function Get-IntOption($Box, [int]$Min, [int]$Max, [string]$Label) {
        $v = 0
        if (-not [int]::TryParse($Box.Text.Trim(), [ref]$v) -or $v -lt $Min -or $v -gt $Max) { throw (T 'opt.int' $Label $Min $Max) }
        $v
    }
    function Get-Lines($Box) { @($Box.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    function Get-PlanArgs {
        $a = @{
            Limit         = (Get-IntOption $ui.OptLimit 50 400 (T 'side.limit'))
            Margin        = (Get-IntOption $ui.OptMargin 0 200 (T 'side.margin'))
            MinNameLength = (Get-IntOption $ui.OptMinName 3 200 (T 'side.minName'))
            AllowTrim     = [bool]$ui.OptTrim.IsChecked
            Protect       = @(Get-Lines $ui.OptProtect)
        }
        if ($a.Margin -ge $a.Limit) { throw (T 'opt.marginLimit') }
        $a
    }
    function Test-CustomRules {
        $ui.OptLimit.Text.Trim() -ne '400' -or $ui.OptMargin.Text.Trim() -ne '20' -or $ui.OptTrim.IsChecked -or $ui.OptMinName.Text.Trim() -ne '20' -or
        @(Get-Lines $ui.OptExclude).Count -or @(Get-Lines $ui.OptProtect).Count -or $ui.OptPrefix.Text.Trim()
    }
    function Update-RulesState {
        $custom = [bool](Test-CustomRules)
        $ui.RulesState.Text = $(if ($custom) { T 'side.custom' } else { T 'side.default' })
        $ui.RulesState.Foreground = $(if ($custom) { $warnBrush } else { $text2 })
        $ui.MinNameRow.IsEnabled = [bool]$ui.OptTrim.IsChecked
        $dirty = $false
        if ($state.Plan -and $state.ScanArgs) {
            $p = $state.ScanArgs.PlanArgs
            $dirty = $ui.OptLimit.Text.Trim() -ne [string]$p.Limit -or $ui.OptMargin.Text.Trim() -ne [string]$p.Margin -or
                     [bool]$ui.OptTrim.IsChecked -ne [bool]$p.AllowTrim -or ($p.AllowTrim -and $ui.OptMinName.Text.Trim() -ne [string]$p.MinNameLength) -or
                     ((Get-Lines $ui.OptProtect) -join '|') -ne (@($p.Protect) -join '|') -or
                     ((Get-Lines $ui.OptExclude) -join '|') -ne (@($state.ScanArgs.Exclude) -join '|') -or
                     $ui.OptPrefix.Text.Trim() -ne [string]$state.ScanArgs['OptPrefix']
        }
        $ui.RulesDirty.Visibility = $(if ($dirty) { 'Visible' } else { 'Collapsed' })
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
    function Get-ErrorText([string]$Message) {
        # Core messages are English; the common ones get the window language.
        if ($Message -match '^No OneDrive') { return (T 'err.noOneDrive') }
        if ($Message -match 'not inside OneDrive') { return ((T 'err.notInside') + ' ' + ($Message -replace '^.*?: ', '' -replace '\. Use -Root.*$', '')) }
        if ($Message -match 'Cannot find path|does not exist') { return (T 'err.noFolder') }
        $Message
    }
    function Get-Translated([string]$Prefix, [string]$Value, [string]$Separator, [string]$Join = $Separator) {
        @($Value -split [regex]::Escape($Separator) | ForEach-Object { T ($Prefix + $_) }) -join $Join
    }
    function New-Text([string]$Text, [double]$Size = 14, $Brush = $textBrush, [string]$Font = 'Segoe UI', [string]$Margin = '0') {
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = $Text; $t.FontSize = $Size; $t.Foreground = $Brush; $t.FontFamily = $Font; $t.Margin = $Margin; $t.TextWrapping = 'Wrap'
        $t
    }
    function Show-Dialog {
        param([string]$Title, [object[]]$Lines, [string]$Yes, [string]$No = '', [scriptblock]$OnYes)
        if (-not $Yes) { $Yes = T 'dlg.ok' }
        $ui.DlgTitle.Text = $Title
        $ui.DlgBody.Children.Clear()
        foreach ($l in $Lines) {
            $tb = New-Text '' 14 $textBrush 'Segoe UI' '0,0,0,10'
            $tb.LineHeight = 21
            if ($l -is [hashtable]) { $tb.Text = $l['Text']; if ($l['Color']) { $tb.Foreground = $l['Color'] }; if ($l['Mono']) { $tb.FontFamily = 'Consolas'; $tb.FontSize = 13 }; if ($l['Bold']) { $tb.FontFamily = 'Segoe UI Semibold' } }
            else { $tb.Text = [string]$l }
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
        if ($msg -match 'No OneDrive') { $tips += T 'tip.noOneDrive' }
        elseif ($msg -match 'not inside OneDrive') { $tips += T 'tip.notInside' }
        elseif ($msg -match 'denied|access') { $tips += T 'tip.denied' }
        elseif ($msg -match 'used by another process|being used') { $tips += T 'tip.inUse' }
        else { $tips += T 'tip.log' $logFile }
        Show-Dialog -Title $What -Lines (@(@{ Text = (Get-ErrorText $msg); Color = $badBrush }) + $tips)
    }
    function Set-Busy([bool]$Busy) {
        $state.Busy = $Busy
        foreach ($b in 'BtnFolder', 'BtnFolderGo', 'FolderPath', 'BtnReplan', 'BtnScan', 'BtnHistory', 'BtnHistRevert', 'BtnHistCheck', 'BtnUndoFile', 'LangEN', 'LangES', 'LangPT') { $ui[$b].IsEnabled = -not $Busy }
    }

    # ---------------------------------------------------------------- folder
    function Set-PathText([string]$Text) {
        $state.SettingPath = $true; $ui.FolderPath.Text = $Text; $state.SettingPath = $false
        $ui.BtnFolderGo.Visibility = 'Collapsed'
    }
    function Set-Library($Lib) {
        $state.Library = $Lib
        Set-PathText $Lib.Path
        $parts = @(T ('kind.' + $Lib.Kind))
        if ($Lib.Account) { $parts += $Lib.Account }
        $parts += T 'folder.prefix' $Lib.Prefix.Length
        if ($ui.ModePro.IsChecked) { $parts += ('"{0}" ({1})' -f $Lib.Prefix, (T ('source.' + $Lib.PrefixSource))) }
        if (Test-CustomRules) { $parts += T 'folder.custom' }
        $ui.FolderInfo.Text = $parts -join '  /  '
        $ui.FolderInfo.Foreground = $text2
        $ui.BtnScan.IsEnabled = $true
        $ui.StartNote.Text = T 'start.note'
    }
    function Select-Library([string]$Folder) {
        try {
            $la = Get-LibraryArgs $Folder; $lib = Get-PathShrinkLibrary @la
            Set-Library $lib
            Add-Log ('Folder: {0} ({1}, prefix {2} chars from {3})' -f $lib.Path, $lib.Kind, $lib.Prefix.Length, $lib.PrefixSource)
            $state.Plan = $null; $state.Inventory = $null
            Show-View 'PanelStart'; Set-Step 2
            Set-Status (T 'status.readyScan') ''
            Update-RulesState
            return $true
        } catch {
            $state.Library = $null
            Set-PathText $(if ($Folder) { $Folder } else { '' })
            $ui.FolderInfo.Text = Get-ErrorText $_.Exception.Message
            $ui.FolderInfo.Foreground = $warnBrush
            $ui.FolderInfo.Visibility = 'Visible'
            $ui.BtnScan.IsEnabled = $false
            $ui.StartNote.Text = T 'start.choose'
            Set-Step 1
            Add-Log ('Folder not usable: {0}' -f $_.Exception.Message)
            return $false
        }
    }
    function Select-NewFolder([string]$Folder) {
        # A library given by hand (-Root) still applies to folders inside it.
        if ($state.Manual -and -not (Test-UnderPath $Folder.TrimEnd('') $state.Manual.Root)) { $state.Manual = $null }
        [void](Select-Library $Folder)
    }
    function Select-TypedFolder {
        $p = $ui.FolderPath.Text.Trim().Trim('"').Trim()
        if ($p) { Select-NewFolder $p }
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
                    # The plan report goes in the same folder as undo.csv, so one folder tells the whole story.
                    $f = Export-PathShrinkReport -Plan $A.Plan -Folder $A.ReportFolder -SyncIssues $A.Issues
                    $Sync.Result = Invoke-PathShrinkPlan -Plan $A.Plan -ReportFolder $f -Confirm:$false -OnProgress { param($i, $t) $Sync.Count = $i; $Sync.Total = $t }
                }
                'check' { $Sync.Result = Test-PathShrinkUndo -UndoFile $A.UndoFile }
                'undo' { $Sync.Result = Undo-PathShrink -UndoFile $A.UndoFile -Confirm:$false }
            }
        } catch { $Sync.Error = $_.Exception.Message } finally { $Sync.Done = $true }
    }

    function Start-Work([string]$Kind, [hashtable]$JobArgs, [string]$Title, [switch]$Quiet) {
        $sync = [hashtable]::Synchronized(@{ Done = $false; Error = $null; Result = $null; Count = 0; Total = 0; Phase = '' })
        $ps = [PowerShell]::Create()
        $ps.Runspace = [RunspaceFactory]::CreateRunspace()
        $ps.Runspace.Open()
        [void]$ps.AddScript($worker).AddArgument((Join-Path $script:ModuleRoot 'PathShrink.psd1')).AddArgument($Kind).AddArgument($JobArgs).AddArgument($sync)
        $state.Job = @{ PS = $ps; Handle = $ps.BeginInvoke(); Sync = $sync; Kind = $Kind; LogIndex = 0; Started = [DateTime]::Now; Cancelled = $false; Quiet = [bool]$Quiet }
        Set-Busy $true
        if (-not $Quiet) {
            $ui.WorkTitle.Text = $Title
            $ui.WorkDetail.Text = ''
            $ui.WorkNote.Text = $(switch ($Kind) { 'apply' { T 'work.note.apply' } 'undo' { T 'work.note.undo' } default { T 'work.note.read' } })
            $ui.WorkBar.IsIndeterminate = $true
            $ui.BtnCancel.Visibility = $(if ($Kind -eq 'scan' -or $Kind -eq 'plan') { 'Visible' } else { 'Collapsed' })
            Show-View 'PanelWork'
        }
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
                if ($s.Phase -eq 'plan') { $ui.WorkDetail.Text = T 'work.readPlan' $s.Count }
                else { $ui.WorkDetail.Text = T 'work.read' $s.Count }
            }
            'apply' {
                if ($s.Total) { $ui.WorkBar.IsIndeterminate = $false; $ui.WorkBar.Maximum = $s.Total; $ui.WorkBar.Value = $s.Count }
                $ui.WorkDetail.Text = $(if ($s.Count -ge $s.Total -and $s.Total) { T 'work.checking' } else { T 'work.renamed' $s.Count $s.Total })
            }
        }
        if (-not $j.Quiet) { Set-Status $ui.WorkTitle.Text ('{0:N0} s' -f $secs) }
        if (-not $s.Done) { return }
        $timer.Stop()
        try { $j.PS.EndInvoke($j.Handle) } catch { Write-Verbose $_.Exception.Message }
        $j.PS.Runspace.Dispose(); $j.PS.Dispose()
        $state.Job = $null
        Set-Busy $false
        if ($j.Cancelled) { Show-View 'PanelStart'; Set-Step 2; Set-Status (T 'status.cancelled') ''; return }
        if ($s.Error) {
            if (-not $j.Quiet) { Show-View $(if ($j.Kind -eq 'undo') { 'PanelHistory' } elseif ($state.Plan -and $j.Kind -ne 'scan') { 'PanelResults' } else { 'PanelStart' }) }
            Show-Error $(switch ($j.Kind) { 'scan' { T 'err.scan' } 'plan' { T 'err.plan' } 'apply' { T 'err.apply' } 'check' { T 'err.check' } default { T 'err.undo' } }) $s.Error
            Set-Status (T 'status.error') ''
            return
        }
        switch ($j.Kind) {
            'scan' { Complete-Scan $s.Result }
            'plan' { Complete-Scan $s.Result }
            'apply' { Complete-Apply $s.Result }
            'check' { Complete-Check $s.Result }
            'undo' { Complete-Undo $s.Result }
        }
    })

    # ---------------------------------------------------------------- scan and plan
    function Start-Scan {
        if (-not $state.Library) { return }
        try { $pa = Get-PlanArgs } catch { Show-Error (T 'err.rules') $_; return }
        $state.ScanArgs = @{ LibraryArgs = (Get-LibraryArgs $state.Library.Path); Exclude = @(Get-Lines $ui.OptExclude); PlanArgs = $pa; OptPrefix = $ui.OptPrefix.Text.Trim() }
        Add-Log ('Scan: {0}  limit {1}, margin {2}, trim {3}' -f $state.Library.Path, $pa.Limit, $pa.Margin, $pa.AllowTrim)
        Set-Step 2
        Start-Work 'scan' $state.ScanArgs (T 'work.scanning')
    }
    function Start-Replan {
        if (-not $state.Inventory) { Start-Scan; return }
        try { $pa = Get-PlanArgs } catch { Show-Error (T 'err.rules') $_; return }
        $sameScope = (@(Get-Lines $ui.OptExclude) -join '|') -eq (@($state.ScanArgs.Exclude) -join '|') -and
                     ($ui.OptPrefix.Text.Trim() -eq [string]$state.ScanArgs['OptPrefix'])
        if (-not $sameScope) { Start-Scan; return }
        $state.ScanArgs.PlanArgs = $pa
        Add-Log ('Re-plan: limit {0}, margin {1}, trim {2}, shortest name {3}' -f $pa.Limit, $pa.Margin, $pa.AllowTrim, $pa.MinNameLength)
        Start-Work 'plan' @{ Inventory = $state.Inventory; Issues = $state.Issues; PlanArgs = $pa } (T 'work.planning')
    }
    function Complete-Scan($R) {
        $state.Library = $R.Library; $state.Inventory = $R.Inventory; $state.Plan = $R.Plan; $state.Issues = @($R.Issues); $state.Result = $null
        Set-Library $R.Library
        $state.Page = 0
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Update-Results
        Add-Log ('Results view built in {0} ms' -f $sw.ElapsedMilliseconds)
        Show-View 'PanelResults'
        Set-Step 3
        Update-RulesState
        $sum = Get-PathShrinkSummary -Plan $state.Plan
        Set-Status (T 'status.scanned' $sum.Items) (T 'status.planned' $sum.LongPaths $sum.Renames)
        Add-Log ('Plan: {0} long paths, {1} renames, {2} fixed, {3} no margin, {4} too long' -f $sum.LongPaths, $sum.Renames, $sum.Fixed, $sum.NoMargin, $sum.TooLong)
    }
    function Update-Tiles {
        $p = $state.Plan
        $sum = Get-PathShrinkSummary -Plan $p
        $left = $sum.NoMargin + $sum.TooLong
        $ui.TileItems.Text = '{0:N0}' -f $sum.Items
        $ui.TileLong.Text = '{0:N0}' -f $sum.LongPaths
        $ui.TileLongLabel.Text = T 'tile.long' $p.Target
        $ui.TileFixed.Text = '{0:N0}' -f $sum.Fixed
        $ui.TileLeft.Text = '{0:N0}' -f $left
        $ui.TileLeft.Foreground = $(if ($left) { $warnBrush } else { $textBrush })
        $sum
    }
    function Update-Results {
        $p = $state.Plan
        if (-not $p) { return }
        $sum = Update-Tiles
        $left = $sum.NoMargin + $sum.TooLong
        $msg = @()
        if (-not $sum.LongPaths) {
            $msg += T 'explain.none' $p.Target $p.Limit $p.Margin
        } else {
            if ($sum.OverLimit) { $msg += T 'explain.over' $sum.LongPaths $p.Target $sum.OverLimit $p.Limit }
            else { $msg += T 'explain.near' $sum.LongPaths $p.Target $p.Margin $p.Limit }
            if ($sum.Renames) {
                $how = $(if ($p.AllowTrim) { T 'explain.howTrim' } else { T 'explain.howSpaces' })
                $what = $(if ($sum.Files) { T 'explain.whatBoth' $sum.Folders $sum.Files } else { T 'explain.whatFolders' $sum.Folders })
                $fixes = $(if ($sum.Rescued) { T 'explain.fixesRescued' $sum.Fixed $sum.Rescued $p.Limit } else { T 'explain.fixes' $sum.Fixed })
                $msg += T 'explain.renaming' $what $fixes $how
                if (-not $sum.Files) { $msg += T 'explain.filesKept' }
            }
            if ($left -and -not $p.AllowTrim) { $msg += T 'explain.needTrim' $left }
            elseif ($left) { $msg += T 'explain.tooDeep' $left }
        }
        if ($sum.Unreadable) { $msg += T 'explain.unreadable' $sum.Unreadable }
        $ui.ExplainText.Text = $msg -join ' '
        $ui.TrimOfferRow.Visibility = $(if ($left -and -not $p.AllowTrim) { 'Visible' } else { 'Collapsed' })

        if ($state.RenameMapFor -ne $p) {
            $state.RenameMap = @{}
            foreach ($r in $p.Renames) { $state.RenameMap[$r.Rel] = $r }
            $state.RenameMapFor = $p; $state.PlanItems = @(); $state.PlanItemsFor = $null
        }
        $ui.GridIssues.ItemsSource = @($state.Issues | ForEach-Object {
            New-Object psobject -Property @{ Issue = (Get-Translated 'issue.' $_.Issue ', '); TypeText = (T ('type.' + $_.Type)); Rel = $_.Rel }
        })
        $ui.TabIssues.Content = $(if ($state.Issues.Count) { T 'tab.issuesN' $state.Issues.Count } else { T 'tab.issues' })
        Update-Compare
        Update-ApplyButton
        Update-Tab
    }
    function Update-ApplyButton {
        $n = @($state.Plan.Renames | Where-Object { $_.Selected }).Count
        foreach ($b in 'BtnApply', 'BtnPlanApply') {
            $ui[$b].IsEnabled = $n -gt 0
            $ui[$b].Content = $(if ($n) { T 'results.apply' $n } else { T 'results.apply0' })
        }
        $ui.BtnPlan.IsEnabled = [bool]$state.Plan.Renames.Count
    }
    function Update-Tab {
        $pro = [bool]$ui.ModePro.IsChecked
        if (-not $pro -and ($ui.TabIssues.IsChecked -or $ui.TabLog.IsChecked)) { $ui.TabCompare.IsChecked = $true }
        $cmp = [bool]$ui.TabCompare.IsChecked
        $ui.CompareList.Visibility = $(if ($cmp) { 'Visible' } else { 'Collapsed' })
        $ui.CompareTools.Visibility = $(if ($cmp) { 'Visible' } else { 'Collapsed' })
        $ui.IssuesBox.Visibility = $(if ($ui.TabIssues.IsChecked) { 'Visible' } else { 'Collapsed' })
        $ui.LogBorder.Visibility = $(if ($ui.TabLog.IsChecked) { 'Visible' } else { 'Collapsed' })
        $empty = ''
        if ($state.Plan) {
            if ($cmp -and -not $state.CompareItems.Count) {
                $empty = $(if (-not $state.Plan.Paths.Count) { T 'empty.noPaths' } elseif ($ui.SearchBox.Text.Trim() -or -not $ui.FilterAll.IsChecked) { T 'empty.noMatch' } else { T 'empty.noAuto' })
            }
            if ($ui.TabIssues.IsChecked -and -not $state.Issues.Count) { $empty = T 'empty.noIssues' }
        }
        $ui.EmptyText.Text = $empty
        $ui.EmptyText.Visibility = $(if ($empty) { 'Visible' } else { 'Collapsed' })
        $ui.Pager.Visibility = $(if ($cmp -and $state.CompareItems.Count) { 'Visible' } else { 'Collapsed' })
    }

    # ---------------------------------------------------------------- before / after comparison
    function Get-PathDiff($P) {
        # One entry per level: the old and new name, and the rename that changed it.
        $a = $P.Rel.Split('\'); $b = $P.NewRel.Split('\')
        $rel = ''
        for ($k = 0; $k -lt $a.Count; $k++) {
            $rel = $(if ($k) { $rel + '\' + $a[$k] } else { $a[$k] })
            [pscustomobject]@{ Level = $k; Old = $a[$k]; New = $b[$k]; Changed = ($a[$k] -cne $b[$k]); Rename = $state.RenameMap[$rel]; IsLast = ($k -eq $a.Count - 1) }
        }
    }
    function New-PathBlock([string]$Caption, $Diff, [bool]$After, [string]$Prefix) {
        $box = New-Object Windows.Controls.Border
        $box.BorderThickness = '3,0,0,0'; $box.Padding = '14,10'; $box.Margin = '0,10,0,0'
        $box.BorderBrush = $(if ($After) { $gold } else { $beforeLine }); $box.Background = $(if ($After) { $afterBg } else { $beforeBg })
        $sp = New-Object Windows.Controls.StackPanel
        [void]$sp.Children.Add((New-Text $Caption 12 $(if ($After) { $gold } else { $beforeText }) 'Segoe UI Semibold' '0,0,0,4'))
        $tb = New-Text '' 13 $textBrush 'Consolas'
        $tb.LineHeight = 20
        $pre = New-Object Windows.Documents.Run $Prefix
        $pre.Foreground = $text3
        $pre.ToolTip = T 'cmp.prefixTip' $Prefix.Length
        [void]$tb.Inlines.Add($pre)
        $first = $true
        foreach ($d in $Diff) {
            if (-not $first) { $sep = New-Object Windows.Documents.Run '\'; $sep.Foreground = $text3; [void]$tb.Inlines.Add($sep) }
            $first = $false
            $r = New-Object Windows.Documents.Run $(if ($After) { $d.New } else { $d.Old })
            if ($d.Changed) {
                $r.Background = $(if ($After) { $afterMark } else { $beforeMark })
                $r.Foreground = $(if ($After) { $goldHi } else { $beforeText })
            }
            [void]$tb.Inlines.Add($r)
        }
        [void]$sp.Children.Add($tb)
        $box.Child = $sp
        $box
    }
    function New-LengthBar([int]$Len, [int]$Max, [int]$Limit, [int]$Target, $Fill) {
        # Star-sized columns, so the bar scales with the card and needs no measuring.
        $g = New-Object Windows.Controls.Grid
        $g.Height = 8; $g.VerticalAlignment = 'Center'
        $track = New-Object Windows.Controls.Border; $track.Background = $trackBrush
        [void]$g.Children.Add($track)
        $fillGrid = New-Object Windows.Controls.Grid
        foreach ($w in @([Math]::Max(1, $Len), [Math]::Max(0.001, $Max - $Len))) { $c = New-Object Windows.Controls.ColumnDefinition; $c.Width = New-Object Windows.GridLength $w, 'Star'; $fillGrid.ColumnDefinitions.Add($c) }
        $f = New-Object Windows.Controls.Border; $f.Background = $Fill
        [void]$fillGrid.Children.Add($f)
        [void]$g.Children.Add($fillGrid)
        foreach ($m in @(@($Target, $gold), @($Limit, $badBrush))) {
            $mg = New-Object Windows.Controls.Grid; $mg.Margin = '0,-3'
            foreach ($w in @($m[0], [Math]::Max(0.001, $Max - $m[0]))) { $c = New-Object Windows.Controls.ColumnDefinition; $c.Width = New-Object Windows.GridLength $w, 'Star'; $mg.ColumnDefinitions.Add($c) }
            $line = New-Object Windows.Controls.Border; $line.BorderBrush = $m[1]; $line.BorderThickness = '2,0,0,0'
            [Windows.Controls.Grid]::SetColumn($line, 1)
            [void]$mg.Children.Add($line)
            [void]$g.Children.Add($mg)
        }
        $g
    }
    function New-CompareCard($P) {
        $plan = $state.Plan
        $diff = @(Get-PathDiff $P)
        $changed = @($diff | Where-Object { $_.Changed })
        $color = @{ Fixed = $okBrush; NoMargin = $warnBrush; TooLong = $badBrush }[$P.Status]
        $card = New-Object Windows.Controls.Border
        $card.Background = $surface; $card.BorderBrush = $lineBrush; $card.BorderThickness = '1'; $card.Padding = '20,16'; $card.Margin = '0,0,0,12'
        $sp = New-Object Windows.Controls.StackPanel

        $head = New-Object Windows.Controls.DockPanel
        $len = New-Text (T 'cmp.lengths' $P.Before $P.After ($P.Before - $P.After)) 14 $goldHi 'Segoe UI Semibold'
        $len.TextWrapping = 'NoWrap'
        [Windows.Controls.DockPanel]::SetDock($len, 'Right'); [void]$head.Children.Add($len)
        $chip = New-Object Windows.Controls.Border
        $chip.BorderBrush = $color; $chip.BorderThickness = '1'; $chip.Padding = '9,2'; $chip.Margin = '0,0,12,0'; $chip.VerticalAlignment = 'Center'
        $chip.Child = New-Text (T ('status.' + $P.Status)) 12.5 $color 'Segoe UI Semibold'
        [Windows.Controls.DockPanel]::SetDock($chip, 'Left'); [void]$head.Children.Add($chip)
        $why = $(if ($P.Before -gt $plan.Limit) { T 'cmp.whyOver' $plan.Limit } else { T 'cmp.whyNear' $plan.Margin $plan.Limit })
        [void]$head.Children.Add((New-Text ((T ('type.' + $P.Type)) + '  /  ' + $why) 13 $text2))
        [void]$sp.Children.Add($head)

        # Length before and after against the limit (red) and the target (gold).
        $max = [Math]::Max($P.Before, $plan.Limit) + 12
        $bars = New-Object Windows.Controls.Grid
        $bars.Margin = '0,14,0,2'
        foreach ($w in @('Auto', '*', 'Auto')) { $c = New-Object Windows.Controls.ColumnDefinition; $c.Width = $(if ($w -eq '*') { New-Object Windows.GridLength 1, 'Star' } else { [Windows.GridLength]::Auto }); $bars.ColumnDefinitions.Add($c) }
        $row = 0
        foreach ($x in @(@((T 'cmp.before'), $P.Before, $beforeLine), @((T 'cmp.after'), $P.After, $color))) {
            $bars.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
            $l = New-Text $x[0] 12.5 $text2 'Segoe UI' '0,2,14,2'; $l.MinWidth = 64
            [Windows.Controls.Grid]::SetRow($l, $row); [void]$bars.Children.Add($l)
            $b = New-LengthBar $x[1] $max $plan.Limit $plan.Target $x[2]
            [Windows.Controls.Grid]::SetRow($b, $row); [Windows.Controls.Grid]::SetColumn($b, 1); [void]$bars.Children.Add($b)
            $v = New-Text ('{0}' -f $x[1]) 12.5 $textBrush 'Segoe UI Semibold' '14,2,0,2'; $v.MinWidth = 34; $v.TextAlignment = 'Right'
            [Windows.Controls.Grid]::SetRow($v, $row); [Windows.Controls.Grid]::SetColumn($v, 2); [void]$bars.Children.Add($v)
            $row++
        }
        [void]$sp.Children.Add($bars)

        [void]$sp.Children.Add((New-PathBlock (T 'cmp.before.caption') $diff $false $plan.Library.Prefix))
        if ($changed.Count) { [void]$sp.Children.Add((New-PathBlock (T 'cmp.after.caption') $diff $true $plan.Library.Prefix)) }
        else { [void]$sp.Children.Add((New-Text (T 'cmp.noChange') 13.5 $warnBrush 'Segoe UI' '0,10,0,0')) }

        if ($changed.Count) {
            $exp = New-Object Windows.Controls.Expander
            $exp.Style = $win.FindResource('Exp'); $exp.Margin = '0,10,0,0'; $exp.FontSize = 13.5
            $exp.Header = T 'cmp.details' $changed.Count ($diff.Count - $changed.Count)
            $list = New-Object Windows.Controls.StackPanel
            foreach ($d in $changed) {
                $how = $(if ($d.Rename) { Get-MethodText $d.Rename.Method } else { '' })
                $kind = $(if ($d.IsLast -and $P.Type -eq 'File') { T 'cmp.file' } else { T 'cmp.level' ($d.Level + 1) })
                $t = New-Text '' 13.5 $textBrush 'Segoe UI' '0,0,0,8'
                $t.LineHeight = 20
                $r1 = New-Object Windows.Documents.Run ($kind + ': '); $r1.Foreground = $text2; [void]$t.Inlines.Add($r1)
                [void]$t.Inlines.Add((New-Object Windows.Documents.Run $d.Old))
                $r2 = New-Object Windows.Documents.Run '  >  '; $r2.Foreground = $gold; [void]$t.Inlines.Add($r2)
                $r3 = New-Object Windows.Documents.Run $d.New; $r3.Foreground = $goldHi; [void]$t.Inlines.Add($r3)
                $r4 = New-Object Windows.Documents.Run ('   ' + (T 'cmp.how' $how ($d.Old.Length - $d.New.Length))); $r4.Foreground = $text2; [void]$t.Inlines.Add($r4)
                [void]$list.Children.Add($t)
            }
            [void]$list.Children.Add((New-Text (T 'cmp.same' ($diff.Count - $changed.Count)) 13 $text2))
            $exp.Content = $list
            [void]$sp.Children.Add($exp)
        }
        $card.Child = $sp
        $card
    }
    function Update-Compare([switch]$Scroll) {
        if (-not $state.Plan) { return }
        $q = $ui.SearchBox.Text.Trim()
        if ($state.SortedFor -ne $state.Plan.Paths) {
            # Problems first (they need a decision), then the biggest transformations. Sorted once per plan.
            $rank = @{ TooLong = 0; NoMargin = 1; Fixed = 2 }
            $all = @($state.Plan.Paths)
            $keys = New-Object 'long[]' $all.Count
            for ($i = 0; $i -lt $all.Count; $i++) { $x = $all[$i]; $keys[$i] = [long]$rank[$x.Status] * 1000000000 + [long](99999 - ($x.Before - $x.After)) * 10000 + (9999 - $x.Before) }
            [Array]::Sort($keys, $all)
            $state.Sorted = $all
            $state.SortedFor = $state.Plan.Paths
        }
        $fixed = [bool]$ui.FilterFixed.IsChecked; $left = [bool]$ui.FilterLeft.IsChecked
        $ic = [StringComparison]::OrdinalIgnoreCase
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($x in $state.Sorted) {
            if ($fixed -and $x.Status -ne 'Fixed') { continue }
            if ($left -and $x.Status -eq 'Fixed') { continue }
            if ($q -and $x.Rel.IndexOf($q, $ic) -lt 0 -and $x.NewRel.IndexOf($q, $ic) -lt 0) { continue }
            $items.Add($x)
        }
        $state.CompareItems = $items.ToArray()
        $pages = [Math]::Max(1, [Math]::Ceiling($state.CompareItems.Count / 10))
        if ($state.Page -ge $pages) { $state.Page = $pages - 1 }
        if ($state.Page -lt 0) { $state.Page = 0 }
        $first = $state.Page * 10
        $ui.CompareList.Children.Clear()
        if ($state.CompareItems.Count) {
            foreach ($p in $state.CompareItems[$first..([Math]::Min($first + 9, $state.CompareItems.Count - 1))]) { [void]$ui.CompareList.Children.Add((New-CompareCard $p)) }
            $more = $state.CompareItems.Count - $first - 10
            if ($more -gt 0) {
                $row = New-Object Windows.Controls.StackPanel
                $row.Orientation = 'Horizontal'; $row.Margin = '2,4,0,10'
                $next = New-Object Windows.Controls.Button
                $next.Style = $win.FindResource('LinkButton'); $next.Content = T 'cmp.next' ([Math]::Min(10, $more))
                $next.Add_Click({ $state.Page++; Update-Compare -Scroll })
                [void]$row.Children.Add($next)
                [void]$row.Children.Add((New-Text ('   ' + (T 'cmp.more' $more)) 13 $text2))
                [void]$ui.CompareList.Children.Add($row)
            }
        }
        $ui.PageText.Text = T 'pager.text' ($first + 1) ([Math]::Min($first + 10, $state.CompareItems.Count)) $state.CompareItems.Count
        $ui.BtnPrev.IsEnabled = $state.Page -gt 0
        $ui.BtnNext.IsEnabled = $state.Page -lt $pages - 1
        Update-Tab
        if ($Scroll) {
            # Paging keeps the list in view: scroll so the filter row is at the top.
            $win.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Loaded, [Action] {
                $y = $ui.CompareTools.TranslatePoint((New-Object Windows.Point 0, 0), $ui.ResultsScroll.Content).Y
                $ui.ResultsScroll.ScrollToVerticalOffset($y)
            }) | Out-Null
        }
    }

    # ---------------------------------------------------------------- plan view
    function Update-PlanItems {
        # One row per rename: which long paths it serves and the longest of them. Rows are made
        # once per plan and refreshed in place when the selection changes; the list of affected
        # paths is only written out when its row is expanded.
        $p = $state.Plan
        if ($state.PlanItemsFor -ne $p) {
            $pro = $(if ($ui.ModePro.IsChecked) { 'Visible' } else { 'Collapsed' })
            $tFolder = T 'plan.op.folder'; $tFile = T 'plan.op.file'; $tSaved = Get-Template 'plan.saved'
            $tImpF = Get-Template 'plan.impact.folder'; $tImpFile = T 'plan.impact.file'
            $rows = New-Object System.Collections.Generic.List[object]
            foreach ($r in $p.Renames) {
                $rows.Add([pscustomobject]@{
                    Rename = $r; Rel = $r.Rel; Selected = $r.Selected; OriginalName = $r.OriginalName; NewName = $r.NewName
                    OpTitle = $(if ($r.Type -eq 'Folder') { $tFolder } else { $tFile })
                    MethodText = Get-MethodText $r.Method
                    SavedText = [string]::Format($culture, $tSaved, $r.Saved)
                    ParentText = $(if ($r.Parent) { $p.Library.Base + '\' + $r.Parent } else { $p.Library.Base })
                    ImpactText = $(if ($r.Type -eq 'Folder') { [string]::Format($culture, $tImpF, [Math]::Max(0, $r.Affects - 1)) } else { $tImpFile })
                    WhyText = ''; PathsHeader = ''; Hits = $null; CheckVisibility = $pro
                })
            }
            $state.PlanItems = $rows.ToArray(); $state.PlanItemsFor = $p
        }
        $hits = @{}
        foreach ($x in $p.Paths) {
            $rel = $x.Rel
            while ($true) {
                if ($state.RenameMap.ContainsKey($rel)) { $h = $hits[$rel]; if ($null -eq $h) { $h = New-Object System.Collections.Generic.List[object]; $hits[$rel] = $h }; $h.Add($x) }
                $i = $rel.LastIndexOf('\'); if ($i -lt 0) { break }; $rel = $rel.Substring(0, $i)
            }
        }
        $tWhy = Get-Template 'plan.why'; $tNone = T 'plan.whyNone'; $tPaths = Get-Template 'plan.paths'
        foreach ($w in $state.PlanItems) {
            $list = $hits[$w.Rel]; $n = 0; $worst = $null
            if ($list) { $n = $list.Count; foreach ($x in $list) { if ($null -eq $worst -or $x.Before -gt $worst.Before) { $worst = $x } } }
            $w.Selected = $w.Rename.Selected
            $w.Hits = $list
            $w.WhyText = $(if ($worst) { [string]::Format($culture, $tWhy, $n, $worst.Before, $worst.After, $p.Target) } else { $tNone })
            $w.PathsHeader = [string]::Format($culture, $tPaths, $n)
        }
    }
    function Get-PathLines($Row) {
        $list = @(); if ($Row.Hits) { $list = @($Row.Hits | Sort-Object Before -Descending) }
        $lines = @($list | Select-Object -First 40 | ForEach-Object { T 'plan.pathLine' $_.Before $_.After $_.Rel })
        if ($list.Count -gt 40) { $lines += T 'plan.pathMore' ($list.Count - 40) }
        $lines
    }
    function Update-PlanList {
        $q = $ui.PlanSearch.Text.Trim()
        $items = $state.PlanItems
        if ($q) {
            $ic = [StringComparison]::OrdinalIgnoreCase
            $items = @(foreach ($w in $state.PlanItems) { if ($w.Rel.IndexOf($q, $ic) -ge 0 -or $w.NewName.IndexOf($q, $ic) -ge 0) { $w } })
        }
        $ui.PlanList.ItemsSource = @($items)
        $ui.PlanEmpty.Text = $(if ($state.PlanItems.Count) { T 'empty.noMatch' } else { T 'empty.noAuto' })
        $ui.PlanEmpty.Visibility = $(if (@($items).Count) { 'Collapsed' } else { 'Visible' })
        Update-PlanSummary
    }
    function Update-PlanSummary {
        $sum = Get-PathShrinkSummary -Plan $state.Plan
        $ui.PlanSummary.Text = T 'plan.summary' $sum.Renames $sum.Folders $sum.Files $sum.Fixed $sum.LongPaths ($sum.NoMargin + $sum.TooLong)
        $ui.PlanCount.Text = T 'plan.count' $sum.Renames $state.Plan.Renames.Count
        $ui.PlanSelectTools.Visibility = $(if ($ui.ModePro.IsChecked) { 'Visible' } else { 'Collapsed' })
        Update-ApplyButton
    }
    function Show-Plan {
        if (-not $state.Plan) { return }
        if ($state.PlanItemsFor -ne $state.Plan -and $state.Plan.Renames.Count -gt 1500 -and -not $state.NoAnim) {
            # Thousands of rows take a moment to build: say so first, then build once it is drawn.
            $state.Back = $state.View
            $ui.WorkTitle.Text = T 'work.preparing'; $ui.WorkDetail.Text = T 'work.preparingN' $state.Plan.Renames.Count; $ui.WorkNote.Text = ''
            $ui.WorkBar.IsIndeterminate = $true; $ui.BtnCancel.Visibility = 'Collapsed'
            Show-View 'PanelWork'
            $win.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background, [Action] { Show-PlanNow }) | Out-Null
            return
        }
        Show-PlanNow
    }
    function Show-PlanNow {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Update-PlanItems
        $ui.PlanSearch.Text = ''
        Update-PlanList
        Add-Log ('Plan view built in {0} ms' -f $sw.ElapsedMilliseconds)
        Show-View 'PanelPlan'
        Set-Step 3
    }
    function Set-Selection([bool]$On) {
        foreach ($r in $state.Plan.Renames) { $r.Selected = $On }
        [void](Update-PathShrinkPlan -Plan $state.Plan)
        Update-PlanItems; $ui.PlanList.Items.Refresh(); Update-PlanSummary
    }

    # ---------------------------------------------------------------- apply
    function Confirm-Apply {
        $sel = @($state.Plan.Renames | Where-Object { $_.Selected })
        if (-not $sel.Count) { return }
        $sum = Get-PathShrinkSummary -Plan $state.Plan
        $folders = @($sel | Where-Object { $_.Type -eq 'Folder' }).Count; $files = $sel.Count - $folders
        $lines = @()
        $lines += @{ Text = $(if ($files) { T 'confirm.both' $folders $files } else { T 'confirm.folders' $folders }); Bold = $true }
        $lines += @{ Text = $state.Library.Path; Mono = $true; Color = $text2 }
        $lines += T 'confirm.result' $sum.Fixed $sum.LongPaths ($sum.NoMargin + $sum.TooLong)
        if ($state.Plan.AllowTrim -and @($sel | Where-Object { $_.Method -like '*trim*' }).Count) { $lines += @{ Text = (T 'confirm.trim'); Color = $warnBrush } }
        $lines += T 'confirm.content'
        $lines += T 'confirm.undo'
        $lines += @{ Text = (T 'confirm.links'); Color = $text2 }
        Set-Step 4
        Show-Dialog -Title (T 'confirm.title' $sel.Count) -Lines $lines -Yes (T 'confirm.yes' $sel.Count) -No (T 'dlg.cancel') -OnYes {
            Add-Log ('Apply: {0} renames' -f @($state.Plan.Renames | Where-Object { $_.Selected }).Count)
            Start-Work 'apply' @{ Plan = $state.Plan; Issues = $state.Issues; ReportFolder = (Join-Path $ReportRoot (Get-Date -Format 'yyyyMMdd-HHmmss-fff')) } (T 'work.renaming')
        }
    }
    function Complete-Apply($R) {
        $state.Result = $R
        Set-Step 5
        $clean = -not $R.Failed -and -not $R.StillLong.Count
        $ui.DoneTitle.Text = $(if ($clean) { T 'done.allFit' } elseif (-not $R.Failed -and -not $R.StillOverLimit) { T 'done.close' } else { T 'done.warn' })
        $ui.DoneIcon.Text = $(if ($clean) { [string][char]0xE73E } else { [string][char]0xE7BA })
        $ui.DoneIcon.Foreground = $(if ($clean) { $okBrush } else { $warnBrush })
        $t = @(T 'done.renamed' $R.Renamed $R.VerifiedFixed $R.ExpectedFixed $state.Plan.Target)
        if ($R.Failed) { $t += T 'done.failed' $R.Failed }
        if ($R.StillLong.Count) { $t += T 'done.still' $R.StillLong.Count $state.Plan.Target $R.StillOverLimit $state.Plan.Limit }
        $t += T 'done.sync'
        $ui.DoneText.Text = $t -join "`n"
        $ui.DoneRenamed.Text = '{0:N0}' -f $R.Renamed
        $ui.DoneVerified.Text = T 'done.ofTotal' $R.VerifiedFixed $R.ExpectedFixed
        $ui.DoneStill.Text = '{0:N0}' -f $R.StillLong.Count
        $ui.DoneStill.Foreground = $(if ($R.StillLong.Count) { $warnBrush } else { $textBrush })
        $ui.DoneFailed.Text = '{0:N0}' -f $R.Failed
        $ui.DoneFailed.Foreground = $(if ($R.Failed) { $badBrush } else { $textBrush })
        $ui.RevertCard.Visibility = $(if ($R.UndoFile) { 'Visible' } else { 'Collapsed' })
        $state.Plan = $null; $state.Inventory = $null
        Show-View 'PanelDone'
        Set-Status (T 'status.renamed' $R.Renamed $R.Failed) (T 'status.report' $R.ReportFolder)
        Add-Log ('Applied: renamed {0}, failed {1}, still long {2}. Undo file {3}' -f $R.Renamed, $R.Failed, $R.StillLong.Count, $R.UndoFile)
        foreach ($x in $R.Results) { if ($x.Result -ne 'OK') { Add-Log ('  {0}: {1}' -f $x.OriginalPath, $x.Result) } }
    }

    # ---------------------------------------------------------------- history and revert
    function Update-History([string]$Select) {
        $state.History = @(Get-PathShrinkHistory -Folder $ReportRoot | ForEach-Object {
            $reverted = [bool]$_.RestoredAt
            Add-Member -InputObject $_ -NotePropertyName TimeText -NotePropertyValue ($_.Time.ToString('g', $culture)) -Force
            Add-Member -InputObject $_ -NotePropertyName StateText -NotePropertyValue $(if ($reverted) { T 'hist.state.reverted' } else { T 'hist.state.applied' }) -Force
            Add-Member -InputObject $_ -NotePropertyName StateColor -NotePropertyValue $(if ($reverted) { $text2 } else { $okBrush }) -Force
            Add-Member -InputObject $_ -NotePropertyName CountText -NotePropertyValue $(if ($reverted) { T 'hist.count.reverted' $_.Renamed $_.RestoredCount } else { T 'hist.count' $_.Renamed }) -Force
            $_
        })
        if ($Select -and -not @($state.History | Where-Object { $_.UndoFile -eq $Select }).Count) {
            # An undo.csv from elsewhere (Pro): listed for this session.
            $state.History = @(New-Object psobject -Property @{ Time = (Get-Item -LiteralPath $Select).LastWriteTime; TimeText = (T 'hist.fromFile'); Folder = (Split-Path $Select -Parent)
                Renamed = @(Import-Csv -LiteralPath $Select | Where-Object { $_.Result -eq 'OK' }).Count; RestoredAt = $null; RestoredCount = 0; UndoFile = $Select; ReportFolder = (Split-Path $Select -Parent)
                StateText = ''; StateColor = $text2; CountText = $Select }) + $state.History
        }
        $ui.HistList.ItemsSource = $state.History
        $ui.HistEmpty.Visibility = $(if ($state.History.Count) { 'Collapsed' } else { 'Visible' })
        $pick = $null
        if ($Select) { $pick = $state.History | Where-Object { $_.UndoFile -eq $Select } | Select-Object -First 1 }
        if ($pick) { $ui.HistList.SelectedItem = $pick } else { $ui.HistList.SelectedIndex = -1; $ui.HistDetail.Visibility = 'Collapsed'; $ui.HistPick.Visibility = 'Visible' }
    }
    function Show-History([string]$Select) {
        Show-View 'PanelHistory'
        try { Update-History $Select } catch { Show-Error (T 'err.history') $_ }
    }
    function Select-HistoryRun($Run) {
        $state.HistRun = $Run; $state.Check = $null
        if (-not $Run) { $ui.HistDetail.Visibility = 'Collapsed'; $ui.HistPick.Visibility = 'Visible'; return }
        $ui.HistPick.Visibility = 'Collapsed'; $ui.HistDetail.Visibility = 'Visible'
        $ui.HistWhen.Text = $Run.TimeText
        $ui.HistFolder.Text = $Run.Folder
        $meta = @(T 'hist.meta' $Run.Renamed)
        if ($Run.RestoredAt) { $meta += T 'hist.meta.reverted' ($Run.RestoredAt.ToString('g', $culture)) $Run.RestoredCount }
        $ui.HistMeta.Text = $meta -join '  /  '
        $ui.HistCheckText.Text = T 'hist.checking'
        foreach ($n in 'HistReady', 'HistAlready', 'HistBlocked') { $ui[$n].Text = '-' }
        $ui.HistBlockedList.Children.Clear()
        $ui.BtnHistRevert.IsEnabled = $false
        $ui.BtnHistRevert.Content = T 'hist.revert0'
        Start-Work 'check' @{ UndoFile = $Run.UndoFile } '' -Quiet
    }
    function Complete-Check($C) {
        $state.Check = $C
        if (-not $C -or -not $state.HistRun -or $C.UndoFile -ne $state.HistRun.UndoFile) { return }
        $ui.HistReady.Text = '{0:N0}' -f $C.Ready
        $ui.HistAlready.Text = '{0:N0}' -f $C.Restored
        $ui.HistBlocked.Text = '{0:N0}' -f $C.Blocked
        $ui.HistBlocked.Foreground = $(if ($C.Blocked) { $warnBrush } else { $textBrush })
        $ui.HistCheckText.Text = $(if (-not $C.Total) { T 'hist.check.empty' }
            elseif ($C.Ready -and -not $C.Blocked) { T 'hist.check.allReady' $C.Ready }
            elseif ($C.Ready) { T 'hist.check.some' $C.Ready $C.Blocked }
            elseif ($C.Blocked) { T 'hist.check.none' $C.Blocked }
            else { T 'hist.check.done' })
        $ui.HistBlockedList.Children.Clear()
        $blocked = @($C.Items | Where-Object { $_.Status -notin 'Ready', 'Restored' })
        foreach ($b in ($blocked | Select-Object -First 25)) {
            $t = New-Text '' 13 $textBrush 'Segoe UI' '0,0,0,8'
            $t.LineHeight = 19
            $r1 = New-Object Windows.Documents.Run ((T ('undo.status.' + $b.Status)) + '  '); $r1.Foreground = $warnBrush; [void]$t.Inlines.Add($r1)
            $r2 = New-Object Windows.Documents.Run $b.CurrentPath; $r2.FontFamily = 'Consolas'; $r2.Foreground = $text2; [void]$t.Inlines.Add($r2)
            [void]$ui.HistBlockedList.Children.Add($t)
        }
        if ($blocked.Count -gt 25) { [void]$ui.HistBlockedList.Children.Add((New-Text (T 'hist.blockedMore' ($blocked.Count - 25)) 13 $text2)) }
        if ($blocked.Count) { [void]$ui.HistBlockedList.Children.Add((New-Text (T 'hist.blockedHelp') 13 $text2 'Segoe UI' '0,6,0,0')) }
        $ui.BtnHistRevert.IsEnabled = $C.Ready -gt 0
        $ui.BtnHistRevert.Content = $(if ($C.Ready) { T 'hist.revert' $C.Ready } else { T 'hist.revert0' })
        $win.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Loaded, [Action] { Set-CutShape $ui.BtnHistRevert }) | Out-Null
    }
    function Confirm-Revert {
        $C = $state.Check
        if (-not $C -or -not $C.Ready) { return }
        $lines = @(@{ Text = (T 'undo.body' $C.Ready); Bold = $true }, @{ Text = $state.HistRun.Folder; Mono = $true; Color = $text2 })
        if ($C.Restored) { $lines += T 'undo.already' $C.Restored }
        if ($C.Blocked) { $lines += @{ Text = (T 'undo.blocked' $C.Blocked); Color = $warnBrush } }
        $lines += T 'undo.safe'
        $lines += @{ Text = (T 'undo.close'); Color = $text2 }
        Show-Dialog -Title (T 'undo.title' $C.Ready) -Lines $lines -Yes (T 'undo.yes' $C.Ready) -No (T 'dlg.cancel') -OnYes {
            Add-Log ('Revert: {0}' -f $state.HistRun.UndoFile)
            Start-Work 'undo' @{ UndoFile = $state.HistRun.UndoFile } (T 'work.restoring')
        }
    }
    function Complete-Undo($R) {
        Add-Log ('Revert: restored {0}, skipped {1}, failed {2}' -f $R.Restored, $R.Skipped, $R.Failed)
        foreach ($x in $R.Results) { if ($x.Result -ne 'OK') { Add-Log ('  {0}: {1}' -f $x.Path, $x.Result) } }
        # Names on disk changed: an earlier analysis no longer describes the folder.
        $state.Plan = $null; $state.Inventory = $null; $state.Result = $null
        $undoFile = $state.HistRun.UndoFile
        Show-History $undoFile
        Set-Status (T 'status.restored' $R.Restored) ''
        $lines = @(T 'undo.restored' $R.Restored)
        if ($R.Skipped) { $lines += @{ Text = (T 'undo.skipped' $R.Skipped); Color = $warnBrush } }
        if ($R.Failed) { $lines += @{ Text = (T 'undo.failed' $R.Failed); Color = $badBrush } }
        $lines += T 'undo.rescan'
        Show-Dialog -Title (T 'undo.doneTitle') -Lines $lines
    }

    # ---------------------------------------------------------------- demo
    function Update-Demo {
        $ex = $(if ($ui.DemoEx2.IsChecked) { 2 } elseif ($ui.DemoEx3.IsChecked) { 3 } else { 1 })
        $state.DemoPlan = New-PathShrinkDemoPlan (T "demo.ex$ex.path") ([bool]$ui.DemoTrim.IsChecked)
        $state.DemoShowAfter = [bool]$ui.DemoAfter.IsChecked
        Update-DemoView $false
    }
    function Update-DemoView([bool]$Animate) {
        $plan = $state.DemoPlan
        if (-not $plan -or -not $plan.Paths.Count) { return }
        $p = $plan.Paths | Sort-Object { $_.Rel.Length } -Descending | Select-Object -First 1
        $after = $state.DemoShowAfter
        $map = @{}; foreach ($r in $plan.Renames) { $map[$r.Rel] = $r }
        $a = $p.Rel.Split('\'); $b = $p.NewRel.Split('\')
        $prefix = $plan.Library.Prefix
        $len = $(if ($after) { $p.After } else { $p.Before })
        $ui.DemoLen.Text = T 'demo.len' $len $(if ($len -gt $plan.Limit) { T 'demo.len.over' } elseif ($len -gt $plan.Target) { T 'demo.len.near' } else { T 'demo.len.ok' })
        $ui.DemoLen.Foreground = $(if ($len -gt $plan.Limit) { $badBrush } elseif ($len -gt $plan.Target) { $warnBrush } else { $okBrush })

        # Ruler: one block per level, as wide as its characters (separator included).
        $width = $ui.DemoRuler.ActualWidth
        if ($width -lt 100) { $width = 760 }
        $scale = $width / 480
        $blocks = @(@{ Chars = $prefix.Length; Brush = '#3A3A44'; Changed = $false })
        for ($k = 0; $k -lt $a.Count; $k++) {
            $name = $(if ($after) { $b[$k] } else { $a[$k] })
            $blocks += @{ Chars = $name.Length + $(if ($k -lt $a.Count - 1) { 1 } else { 0 }); Changed = ($a[$k] -cne $b[$k]) }
        }
        if ($ui.DemoBar.Children.Count -ne $blocks.Count) {
            $ui.DemoBar.Children.Clear()
            foreach ($x in $blocks) { $r = New-Object Windows.Controls.Border; $r.Height = 34; $r.Margin = '0,0,2,0'; [void]$ui.DemoBar.Children.Add($r) }
            $Animate = $false
        }
        for ($i = 0; $i -lt $blocks.Count; $i++) {
            $el = $ui.DemoBar.Children[$i]
            $el.Background = $(if ($i -eq 0) { & $brush '#3A3A44' } elseif ($blocks[$i].Changed -and $after) { $gold } elseif ($blocks[$i].Changed) { & $brush '#8A6F45' } else { & $brush '#5A5A64' })
            $el.ToolTip = $(if ($i -eq 0) { T 'cmp.prefixTip' $prefix.Length } else { $(if ($after) { $b[$i - 1] } else { $a[$i - 1] }) })
            $w = [Math]::Max(2, $blocks[$i].Chars * $scale - 2)
            if ($Animate -and -not $state.NoAnim) {
                $an = New-Object Windows.Media.Animation.DoubleAnimation($el.ActualWidth, $w, (New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(650))))
                $ease = New-Object Windows.Media.Animation.CubicEase; $ease.EasingMode = 'EaseInOut'; $an.EasingFunction = $ease
                $el.BeginAnimation([Windows.FrameworkElement]::WidthProperty, $an)
            } else { $el.BeginAnimation([Windows.FrameworkElement]::WidthProperty, $null); $el.Width = $w }
        }
        $ui.DemoLimitLine.Margin = New-Object Windows.Thickness ($plan.Limit * $scale), 0, 0, 0
        $ui.DemoTargetLine.Margin = New-Object Windows.Thickness ($plan.Target * $scale), 0, 0, 0
        $ui.DemoLimitLabel.Text = T 'demo.limit' $plan.Limit
        $ui.DemoTargetLabel.Text = T 'demo.target' $plan.Target
        $ui.DemoLimitLabel.Margin = New-Object Windows.Thickness ($plan.Limit * $scale + 6), 0, 0, 0
        $ui.DemoTargetLabel.Margin = New-Object Windows.Thickness ([Math]::Max(0, $plan.Target * $scale - 6 - 110)), 0, 0, 0
        $ui.DemoTargetLabel.Width = 110; $ui.DemoTargetLabel.TextAlignment = 'Right'

        # Tree: every level of the path, old name and new name side by side.
        $ui.DemoTree.Children.Clear()
        $rel = ''
        for ($k = 0; $k -lt $a.Count; $k++) {
            $rel = $(if ($k) { $rel + '\' + $a[$k] } else { $a[$k] })
            $isFile = $k -eq $a.Count - 1
            $row = New-Object Windows.Controls.StackPanel
            $row.Margin = New-Object Windows.Thickness ($k * 18), 0, 0, 10
            $line = New-Text '' 14 $textBrush
            $icon = New-Object Windows.Documents.Run $(if ($isFile) { [string][char]0xE8A5 } else { [string][char]0xE8B7 })
            $icon.FontFamily = 'Segoe MDL2 Assets'; $icon.Foreground = $(if ($isFile) { $text2 } else { $gold })
            [void]$line.Inlines.Add($icon); [void]$line.Inlines.Add((New-Object Windows.Documents.Run '  '))
            $changed = $a[$k] -cne $b[$k]
            $nm = New-Object Windows.Documents.Run $(if ($after) { $b[$k] } else { $a[$k] })
            if ($changed -and $after) { $nm.Foreground = $goldHi; $nm.Background = $afterMark }
            elseif ($changed) { $nm.Foreground = $beforeText; $nm.Background = $beforeMark }
            [void]$line.Inlines.Add($nm)
            [void]$row.Children.Add($line)
            $sub = ''
            if ($k -lt $plan.Library.MinRenameDepth) { $sub = T 'demo.protected' }
            elseif ($changed) {
                $r = $map[$rel]
                $other = $(if ($after) { T 'demo.was' $a[$k] } else { T 'demo.becomes' $b[$k] })
                $sub = $other + '   ' + (T 'cmp.how' (Get-Translated 'method.' $r.Method ' + ' '  /  ') $r.Saved)
            }
            if ($sub) { [void]$row.Children.Add((New-Text $sub 12.5 $text2 'Segoe UI' '24,2,0,0')) }
            [void]$ui.DemoTree.Children.Add($row)
        }

        $changedCount = @(for ($k = 0; $k -lt $a.Count; $k++) { if ($a[$k] -cne $b[$k]) { 1 } }).Count
        $txt = @(T 'demo.explain.start' $p.Before $plan.Limit $prefix.Length)
        if ($changedCount) { $txt += T 'demo.explain.changed' $changedCount $a.Count ($p.Before - $p.After) $p.After }
        else { $txt += T 'demo.explain.nothing' }
        if ($p.Status -eq 'TooLong' -and -not $plan.AllowTrim) { $txt += T 'demo.explain.needTrim' }
        elseif ($plan.AllowTrim -and @($plan.Renames | Where-Object { $_.Method -like '*trim*' }).Count) { $txt += T 'demo.explain.trimmed' }
        $ui.DemoExplain.Text = $txt -join "`n`n"
    }
    function Show-Demo {
        Show-View 'PanelDemo'
        $ui.DemoBefore.IsChecked = $true
        Update-Demo
        $win.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Loaded, [Action] { Update-DemoView $false }) | Out-Null
    }

    # ---------------------------------------------------------------- help
    function Show-Help([string]$Key) {
        $ui.HelpPop.IsOpen = $false
        if (-not $ui.HelpList.Children.Count) {
            [void]$ui.HelpList.Children.Add((New-Text (T 'help.about.t') 15 $goldHi 'Segoe UI Semibold' '0,4,0,6'))
            $about = New-Text (T 'help.about.b') 14 $textBrush; $about.LineHeight = 22
            [void]$ui.HelpList.Children.Add($about)
            $demo = New-Object Windows.Controls.Button
            $demo.Style = $win.FindResource('LinkButton'); $demo.Content = T 'help.demo'; $demo.Margin = '0,10,0,18'; $demo.HorizontalAlignment = 'Left'
            $demo.Add_Click({ $ui.HelpLayer.Visibility = 'Collapsed'; Show-Demo })
            [void]$ui.HelpList.Children.Add($demo)
            [void]$ui.HelpList.Children.Add((New-Text (T 'help.glossary') 12 $gold 'Segoe UI Semibold' '0,0,0,10'))
            foreach ($k in $script:HelpKeys) {
                $box = New-Object Windows.Controls.Border
                $box.BorderBrush = $lineBrush; $box.BorderThickness = '0,1,0,0'; $box.Padding = '0,12,0,12'
                $sp = New-Object Windows.Controls.StackPanel
                [void]$sp.Children.Add((New-Text (T "help.$k.t") 14.5 $textBrush 'Segoe UI Semibold'))
                $b = New-Text (T "help.$k.b") 13.5 $text2 'Segoe UI' '0,4,0,0'; $b.LineHeight = 20
                [void]$sp.Children.Add($b)
                $box.Child = $sp
                $state.HelpEntries[$k] = $box
                [void]$ui.HelpList.Children.Add($box)
            }
        }
        foreach ($k in $state.HelpEntries.Keys) { $state.HelpEntries[$k].Background = $null }
        $ui.HelpLayer.Visibility = 'Visible'
        if ($Key -and $state.HelpEntries.ContainsKey($Key)) {
            $state.HelpFocus = $state.HelpEntries[$Key]; $state.HelpFocus.Background = $chipBg
            $win.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Loaded, [Action] { $state.HelpFocus.BringIntoView() }) | Out-Null
        }
        if (-not $state.NoAnim) {
            $tt = New-Object Windows.Media.TranslateTransform 40, 0
            $ui.HelpDrawer.RenderTransform = $tt
            $tt.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, (New-Object Windows.Media.Animation.DoubleAnimation(40, 0, (New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(160))))))
        }
        [void]$ui.BtnHelpClose.Focus()
    }
    function Show-HelpTip($Button) {
        $k = [string]$Button.Tag
        $state.HelpKey = $k
        $ui.HelpPopTitle.Text = T "help.$k.t"
        $ui.HelpPopBody.Text = T "help.$k.b"
        $ui.HelpPop.PlacementTarget = $Button
        $ui.HelpPop.IsOpen = $true
    }

    # ---------------------------------------------------------------- misc
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
        $ui.SideColumn.Width = $(if ($IsPro) { New-Object Windows.GridLength 360 } else { New-Object Windows.GridLength 0 })
        $ui.SidePanel.Visibility = $(if ($IsPro) { 'Visible' } else { 'Collapsed' })
        $ui.BodyHost.MaxWidth = $(if ($IsPro) { 1560 } else { 1180 })
        # The rules panel needs room next to the results; Pro widens a narrow window once.
        $win.MinWidth = $(if ($IsPro) { 1180 } else { 980 })
        if ($IsPro -and $win.WindowState -eq 'Normal' -and $win.Width -lt 1180) { $win.Width = [Math]::Min(1240, [Windows.SystemParameters]::WorkArea.Width) }
        $v = $(if ($IsPro) { 'Visible' } else { 'Collapsed' })
        $ui.TabIssues.Visibility = $v; $ui.TabLog.Visibility = $v
        foreach ($w in @($state.PlanItems)) { $w.CheckVisibility = $v }
        if ($state.View -eq 'PanelPlan') { $ui.PlanList.Items.Refresh(); Update-PlanSummary }
        if ($state.Library) { Set-Library $state.Library }
        Update-Tab
        $win.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Loaded, [Action] { foreach ($b in (Get-Buttons $win)) { Set-CutShape $b } }) | Out-Null
    }
    function Set-Language([string]$Code) {
        if ($state.Loading -or $Code -eq $lang) { return }
        Save-PathShrinkLanguage $Code
        # The texts are baked in when the window is built, so it is built again; the folder
        # and the mode carry over, a scan in progress or its results do not.
        $state.Relaunch = @{ Language = $Code; Pro = [bool]$ui.ModePro.IsChecked; Path = $(if ($state.Library) { $state.Library.Path } else { $Path }) }
        $win.Close()
    }

    # ---------------------------------------------------------------- wiring
    foreach ($b in (Get-Buttons $win)) {
        if ($b.Tag -eq 'cut') { $b.Add_SizeChanged({ param($s, $e) Set-CutShape $s }); $b.Add_Loaded({ param($s, $e) Set-CutShape $s }) }
        elseif ($script:HelpKeys -contains [string]$b.Tag) {
            [Windows.Automation.AutomationProperties]::SetName($b, (T 'help.dot' (T ('help.' + $b.Tag + '.t'))))
            $b.ToolTip = T ('help.' + $b.Tag + '.t')
            $b.Add_Click({ param($s, $e) Show-HelpTip $s })
        }
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
            $e.Cancel = $true; $state.Relaunch = $null
            Show-Dialog -Title (T 'busy.title') -Lines @(T 'busy.body')
        } elseif ($state.Job) { try { $state.Job.PS.Stop() } catch { Write-Verbose $_.Exception.Message } }
    })
    $win.Add_SourceInitialized({
        $wa = [Windows.SystemParameters]::WorkArea
        if ($win.Width -gt $wa.Width * 0.96) { $win.Width = [Math]::Max($win.MinWidth, $wa.Width * 0.96) }
        if ($win.Height -gt $wa.Height * 0.94) { $win.Height = [Math]::Max($win.MinHeight, $wa.Height * 0.94) }
    })
    $win.Add_PreviewKeyDown({
        param($s, $e)
        if ($e.Key -eq 'Escape') {
            if ($ui.Overlay.Visibility -eq 'Visible') { $ui.Overlay.Visibility = 'Collapsed'; $state.DlgAction = $null; $e.Handled = $true }
            elseif ($ui.HelpLayer.Visibility -eq 'Visible') { $ui.HelpLayer.Visibility = 'Collapsed'; $e.Handled = $true }
            elseif ($state.View -in 'PanelPlan', 'PanelHistory', 'PanelDemo' -and -not $state.Busy) { Restore-View; $e.Handled = $true }
        } elseif ($e.Key -eq 'F1') { Show-Help $null; $e.Handled = $true }
    })
    $win.Add_Drop({
        param($s, $e)
        if ($state.Busy) { return }
        $files = $e.Data.GetData([Windows.DataFormats]::FileDrop)
        if ($files -and (Test-Path -LiteralPath $files[0] -PathType Container)) { Select-NewFolder $files[0] }
    })

    $ui.LangEN.Add_Checked({ Set-Language 'en' })
    $ui.LangES.Add_Checked({ Set-Language 'es' })
    $ui.LangPT.Add_Checked({ Set-Language 'pt' })
    $ui.ModeBasic.Add_Checked({ Set-Mode $false; Add-Log 'Mode: Basic' })
    $ui.ModePro.Add_Checked({ Set-Mode $true; Add-Log 'Mode: Pro' })
    foreach ($t in 'TabCompare', 'TabIssues', 'TabLog') { $ui[$t].Add_Checked({ Update-Tab }) }
    foreach ($t in 'FilterAll', 'FilterFixed', 'FilterLeft') { $ui[$t].Add_Checked({ $state.Page = 0; Update-Compare }) }
    # Searching waits for a pause in typing, so long lists do not redraw on every key.
    $searchTimer = New-Object Windows.Threading.DispatcherTimer
    $searchTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $searchTimer.Add_Tick({ $searchTimer.Stop(); if ($state.View -eq 'PanelPlan') { Update-PlanList } else { $state.Page = 0; Update-Compare } })
    $ui.SearchBox.Add_TextChanged({ $ui.SearchHint.Visibility = $(if ($ui.SearchBox.Text) { 'Collapsed' } else { 'Visible' }); $searchTimer.Stop(); $searchTimer.Start() })
    $ui.PlanSearch.Add_TextChanged({ $ui.PlanSearchHint.Visibility = $(if ($ui.PlanSearch.Text) { 'Collapsed' } else { 'Visible' }); $searchTimer.Stop(); $searchTimer.Start() })
    $ui.BtnPrev.Add_Click({ $state.Page--; Update-Compare -Scroll })
    $ui.BtnNext.Add_Click({ $state.Page++; Update-Compare -Scroll })

    $ui.BtnFolder.Add_Click({
        $start = $(if ($state.Library) { $state.Library.Path } else { $ui.FolderPath.Text.Trim() })
        try { $picked = Select-PathShrinkFolder -Owner $win -Title (T 'folder.dialog') -Start $start }
        catch { Show-Error (T 'err.picker') $_; return }
        if ($picked) { Select-NewFolder $picked }
    })
    $ui.FolderPath.Add_TextChanged({
        if ($state.SettingPath) { return }
        $ui.BtnFolderGo.Visibility = $(if ($ui.FolderPath.Text.Trim() -and (-not $state.Library -or $ui.FolderPath.Text.Trim() -ne $state.Library.Path)) { 'Visible' } else { 'Collapsed' })
    })
    $ui.FolderPath.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Select-TypedFolder; $e.Handled = $true } })
    $ui.BtnFolderGo.Add_Click({ Select-TypedFolder })
    $ui.BtnScan.Add_Click({ Start-Scan })
    $ui.BtnRescan.Add_Click({ Start-Scan })
    $ui.BtnAgain.Add_Click({ if ($state.Library) { [void](Select-Library $state.Library.Path); Start-Scan } })
    $ui.BtnDemo.Add_Click({ Show-Demo })
    $ui.BtnCancel.Add_Click({
        if ($state.Job) { $state.Job.Cancelled = $true; $ui.WorkDetail.Text = T 'work.stopping'; [void]$state.Job.PS.BeginStop($null, $null); Add-Log 'Scan cancelled' }
    })
    $ui.BtnTrimOffer.Add_Click({
        $ui.OptTrim.IsChecked = $true
        Add-Log 'Trimming allowed from the results page'
        Start-Replan
    })
    $ui.BtnReplan.Add_Click({ if ($state.Library) { if ($state.Inventory) { Start-Replan } else { Start-Scan } } })
    $ui.BtnPlan.Add_Click({ Show-Plan })
    $ui.BtnApply.Add_Click({ Confirm-Apply })
    $ui.BtnPlanApply.Add_Click({ Confirm-Apply })
    $ui.BtnPlanBack.Add_Click({ Restore-View })
    $ui.BtnCrumbSummary.Add_Click({ Update-Results; Show-View 'PanelResults' })
    $ui.BtnPlanSummary.Add_Click({ Update-Results; Show-View 'PanelResults' })
    $ui.BtnSelAll.Add_Click({ Set-Selection $true })
    $ui.BtnSelNone.Add_Click({ Set-Selection $false })
    $ui.PlanList.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler] {
        param($s, $e)
        $cb = $e.OriginalSource
        if (-not ($cb -is [Windows.Controls.CheckBox]) -or $cb.Tag -ne 'sel') { return }
        $cb.DataContext.Rename.Selected = [bool]$cb.IsChecked
        [void](Update-PathShrinkPlan -Plan $state.Plan)
        Update-PlanItems
        $ui.PlanList.Items.Refresh()
        Update-PlanSummary
    })
    $ui.PlanList.AddHandler([Windows.Controls.Expander]::ExpandedEvent, [Windows.RoutedEventHandler] {
        param($s, $e)
        $x = $e.OriginalSource
        if ($x -is [Windows.Controls.Expander] -and $x.Content -is [Windows.Controls.ItemsControl]) { $x.Content.ItemsSource = @(Get-PathLines $x.DataContext) }
    })
    foreach ($o in 'OptLimit', 'OptMargin', 'OptMinName', 'OptExclude', 'OptProtect', 'OptPrefix') { $ui[$o].Add_TextChanged({ Update-RulesState }) }
    $ui.OptTrim.Add_Click({ Update-RulesState })
    $ui.DlgYes.Add_Click({
        $ui.Overlay.Visibility = 'Collapsed'
        $a = $state.DlgAction; $state.DlgAction = $null
        if ($a) { & $a }
    })
    $ui.DlgNo.Add_Click({
        $ui.Overlay.Visibility = 'Collapsed'; $state.DlgAction = $null
        if ($state.Plan -and $state.View -in 'PanelResults', 'PanelPlan') { Set-Step 3 }
    })
    $ui.BtnExport.Add_Click({
        try {
            $f = Export-PathShrinkReport -Plan $state.Plan -SyncIssues $state.Issues -Folder (Join-Path (Split-Path $ReportRoot -Parent) ('Exports\' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
            [IO.File]::WriteAllLines((Join-Path $f 'gui.log'), $state.LogLines)
            Add-Log ('Report: {0}' -f $f)
            Set-Status (T 'status.report' $f)
            Start-Process -FilePath (Join-Path $f 'report.html')
        } catch { Show-Error (T 'err.report') $_ }
    })
    $ui.BtnReports.Add_Click({ if ($state.Result -and $state.Result.ReportFolder) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $state.Result.ReportFolder) } })
    $ui.BtnUndo.Add_Click({ if ($state.Result -and $state.Result.UndoFile) { Show-History $state.Result.UndoFile } })
    $ui.BtnHistory.Add_Click({ Show-History $null })
    $ui.BtnHistBack.Add_Click({ Restore-View })
    $ui.HistList.Add_SelectionChanged({ if ($ui.HistList.SelectedItem -ne $state.HistRun) { Select-HistoryRun $ui.HistList.SelectedItem } })
    $ui.BtnHistCheck.Add_Click({ if ($state.HistRun) { Select-HistoryRun $state.HistRun } })
    $ui.BtnHistRevert.Add_Click({ Confirm-Revert })
    $ui.BtnHistReport.Add_Click({ if ($state.HistRun) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $state.HistRun.ReportFolder) } })
    $ui.BtnOpenReports.Add_Click({
        if (-not (Test-Path -LiteralPath $ReportRoot)) { New-Item -ItemType Directory -Path $ReportRoot -Force | Out-Null }
        Start-Process explorer.exe -ArgumentList ('"{0}"' -f $ReportRoot)
    })
    $ui.BtnUndoFile.Add_Click({
        $d = New-Object Microsoft.Win32.OpenFileDialog
        $d.Filter = T 'undo.filter'
        if (Test-Path -LiteralPath $ReportRoot) { $d.InitialDirectory = $ReportRoot }
        if ($d.ShowDialog($win)) {
            try { [void](Import-Csv -LiteralPath $d.FileName | Select-Object -First 1 OriginalPath, NewName); Update-History $d.FileName } catch { Show-Error (T 'err.undoRead') $_ }
        }
    })
    $ui.BtnHelp.Add_Click({ Show-Help $null })
    $ui.BtnHelpClose.Add_Click({ $ui.HelpLayer.Visibility = 'Collapsed' })
    $ui.HelpScrim.Add_MouseLeftButtonDown({ $ui.HelpLayer.Visibility = 'Collapsed' })
    $ui.HelpPopMore.Add_Click({ Show-Help $state.HelpKey })
    $ui.BtnDemoBack.Add_Click({ Restore-View })
    foreach ($x in 'DemoEx1', 'DemoEx2', 'DemoEx3') { $ui[$x].Add_Checked({ if ($state.View -eq 'PanelDemo') { $ui.DemoBefore.IsChecked = $true; Update-Demo } }) }
    $ui.DemoTrim.Add_Click({ Update-Demo })
    $ui.DemoBefore.Add_Checked({ if ($state.DemoPlan) { $state.DemoShowAfter = $false; Update-DemoView $true } })
    $ui.DemoAfter.Add_Checked({ if ($state.DemoPlan) { $state.DemoShowAfter = $true; Update-DemoView $true } })
    $ui.BtnDemoPlay.Add_Click({
        $ui.DemoBefore.IsChecked = $true
        $t = New-Object Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromMilliseconds(700)
        $t.Add_Tick({ param($s, $e) $s.Stop(); $ui.DemoAfter.IsChecked = $true })
        $t.Start()
    })
    $ui.DemoRuler.Add_SizeChanged({ if ($state.View -eq 'PanelDemo') { Update-DemoView $false } })
    $ui.BtnEnv.Add_Click({
        $envInfo = Get-PathShrinkEnvironment
        Add-Log 'This computer:'
        foreach ($p in $envInfo.PSObject.Properties) { Add-Log ('  {0,-18} {1}' -f $p.Name, $p.Value) }
        if ($envInfo.Elevated) { Add-Log '  Note: running elevated. Run as the OneDrive user without elevation if the folder belongs to another profile.' }
        Show-Dialog -Title (T 'env.title') -Lines @($envInfo.PSObject.Properties | ForEach-Object { @{ Text = ('{0,-18} {1}' -f $_.Name, $_.Value); Mono = $true; Color = $textBrush } })
    })
    $ui.BtnCopyCli.Add_Click({
        $cmd = Get-CliCommand
        [Windows.Clipboard]::SetText($cmd)
        Add-Log ('Copied: {0}' -f $cmd)
        Set-Status (T 'status.copied')
    })

    # ---------------------------------------------------------------- start
    if ($Root) { $state.Manual = @{ Root = $Root }; if ($Upn) { $state.Manual.Upn = $Upn }; if ($PSBoundParameters.ContainsKey('Prefix')) { $state.Manual.Prefix = $Prefix } }
    elseif ($PSBoundParameters.ContainsKey('Prefix')) { $ui.OptPrefix.Text = $Prefix }
    Set-Step 1
    $startPro = [bool]($Pro -or $ScreenshotState -eq 'pro')
    Set-Mode $startPro
    if ($startPro) { $ui.ModePro.IsChecked = $true }
    Add-Log ('PathShrink {0} on PowerShell {1}, language {2}' -f (Get-PathShrinkVersion), $PSVersionTable.PSVersion, $lang)
    [void](Select-Library $Path)
    Update-RulesState
    $state.Loading = $false

    if ($Screenshot) {
        # Off-screen render for documentation and visual checks. Runs the real scan and plan.
        $win.WindowStartupLocation = 'Manual'; $win.Left = -30000; $win.Top = 0; $win.ShowActivated = $false; $win.ShowInTaskbar = $false
        if ($ScreenshotWidth) { $win.Width = $ScreenshotWidth }
        if ($ScreenshotHeight) { $win.Height = $ScreenshotHeight }
        $win.Add_ContentRendered({
            if ($ScreenshotState -notin 'start', 'demo', 'help' -and $state.Library) {
                $pa = Get-PlanArgs
                $la = Get-LibraryArgs $state.Library.Path; $lib = Get-PathShrinkLibrary @la
                $inv = Get-PathShrinkInventory -Library $lib -Exclude @(Get-Lines $ui.OptExclude)
                $state.ScanArgs = @{ LibraryArgs = (Get-LibraryArgs $lib.Path); Exclude = @(); PlanArgs = $pa; OptPrefix = '' }
                Complete-Scan @{ Library = $lib; Inventory = $inv; Plan = (New-PathShrinkPlan -Inventory $inv -Limit $pa.Limit -Margin $pa.Margin -AllowTrim:$pa.AllowTrim -MinNameLength $pa.MinNameLength); Issues = @(Find-PathShrinkSyncIssue -Inventory $inv) }
                if ($ScreenshotState -eq 'plan') { Show-Plan }
                if ($ScreenshotState -eq 'confirm') { Confirm-Apply }
                if ($ScreenshotState -in 'done', 'history') {
                    # Real apply: only ever used on the throw-away demo folder, with its own report root.
                    $rf = Join-Path $ReportRoot (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
                    $f = Export-PathShrinkReport -Plan $state.Plan -Folder $rf
                    Complete-Apply (Invoke-PathShrinkPlan -Plan $state.Plan -Confirm:$false -ReportFolder $f)
                    if ($ScreenshotState -eq 'history') {
                        Show-History $state.Result.UndoFile
                        Complete-Check (Test-PathShrinkUndo -UndoFile $state.Result.UndoFile)
                    }
                }
            }
            if ($ScreenshotState -eq 'demo') { Show-Demo; $ui.DemoAfter.IsChecked = $true }
            if ($ScreenshotState -eq 'help') { Show-Help 'trim' }
            $win.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Loaded, [Action] {
                foreach ($b in (Get-Buttons $win)) { Set-CutShape $b }
                if ($ScreenshotState -eq 'demo') { Update-DemoView $false }
                $win.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::ApplicationIdle, [Action] {
                    $root = $win.Content
                    $w = [int]($root.ActualWidth * $ScreenshotScale); $h = [int]($root.ActualHeight * $ScreenshotScale)
                    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap($w, $h, (96 * $ScreenshotScale), (96 * $ScreenshotScale), [Windows.Media.PixelFormats]::Pbgra32)
                    $bmp.Render($root)
                    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
                    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
                    $fs = [IO.File]::Create($Screenshot); $enc.Save($fs); $fs.Close()
                    if ($env:PATHSHRINK_SHOTLOG) { [IO.File]::WriteAllLines($env:PATHSHRINK_SHOTLOG, $state.LogLines) }
                    $win.Close()
                }) | Out-Null
            }) | Out-Null
        })
    }
    [void]$win.ShowDialog()
    $state.Relaunch
}
