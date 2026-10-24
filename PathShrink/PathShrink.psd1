@{
    RootModule           = 'PathShrink.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'c4344eca-54bf-4248-9977-c8ad06c8ff01'
    Author               = '4leX-42'
    CompanyName          = 'Community'
    Copyright            = '(c) 2026 4leX-42. MIT License.'
    Description          = 'Find and fix OneDrive and SharePoint paths over the 400-character limit. Measures the real server-side path, renames folders without losing letters first (clean-up, remove spaces), optional trimming, preview, verification on disk and undo. GUI with Basic and Pro modes, plus a command line.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @(
        'Start-PathShrink', 'Invoke-PathShrink',
        'Get-PathShrinkLibrary', 'Get-PathShrinkAccount', 'Get-PathShrinkSyncMount', 'Get-PathShrinkInventory',
        'New-PathShrinkPlan', 'Update-PathShrinkPlan', 'Test-PathShrinkRename', 'Set-PathShrinkRename', 'Get-PathShrinkSummary', 'Invoke-PathShrinkPlan', 'Undo-PathShrink', 'Test-PathShrinkUndo', 'Get-PathShrinkHistory',
        'Find-PathShrinkSyncIssue', 'Export-PathShrinkReport', 'Get-PathShrinkEnvironment'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    FileList             = @('PathShrink.psd1', 'PathShrink.psm1', 'gui\Gui.ps1', 'gui\MainWindow.xaml', 'gui\strings.en.json', 'gui\strings.es.json', 'gui\strings.pt.json', 'gui\logo.png', 'gui\PathShrink.ico')
    PrivateData          = @{
        PSData = @{
            Tags         = @('OneDrive', 'SharePoint', 'LongPath', 'PathTooLong', 'Sync', 'Microsoft365', 'M365', 'SysAdmin', 'Windows', 'GUI', 'WPF')
            LicenseUri   = 'https://github.com/4leX-42/PathShrink/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/4leX-42/PathShrink'
            ReleaseNotes = 'https://github.com/4leX-42/PathShrink/blob/main/CHANGELOG.md'
        }
    }
}