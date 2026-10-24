# Builds throw-away folder trees for the tests. Only ever writes under the folder it is given.

function New-TestTree {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$Files)
    foreach ($f in $Files) {
        $full = '\\?\' + (Join-Path $Root $f)
        $dir = [IO.Path]::GetDirectoryName($full)
        [void][IO.Directory]::CreateDirectory($dir)
        if (-not $f.EndsWith('\')) { [IO.File]::WriteAllText($full, 'x') }
    }
}

function New-TestRoot {
    $r = Join-Path ([IO.Path]::GetTempPath()) ('PathShrinkTest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][IO.Directory]::CreateDirectory($r)
    $r
}

function Remove-TestRoot([string]$Root) {
    if ($Root -and $Root -like '*PathShrinkTest-*' -and [IO.Directory]::Exists('\\?\' + $Root)) {
        [IO.Directory]::Delete('\\?\' + $Root, $true)
    }
}

function Get-TestRels([string]$Root) {
    $base = '\\?\' + $Root
    @([IO.Directory]::GetFileSystemEntries($base, '*', [IO.SearchOption]::AllDirectories) | ForEach-Object { $_.Substring($base.Length + 1) } | Sort-Object)
}

# A personal OneDrive layout whose longest file is 451 server characters with the prefix below.
$script:TestUpn = 'ana.perez@contoso.com'   # prefix personal/ana_perez_contoso_com/Documents/ = 41 chars
function Get-DeepFiles {
    $a = 'Desktop\Clients and Matters\Contoso Holdings   International , Limited\Mergers and Acquisitions - Due Diligence\Financial Statements and Tax Returns'
    $b = 'Working Papers and Supporting Schedules\Quarterly Reconciliations and Adjustments'
    @(
        ($a + '\' + $b + '\Final report for the board of directors 2026 Q3.docx'),
        ($a + '\' + $b + '\Appendix A - detailed ledger export.xlsx'),
        ($a + '\Short.txt'),
        'Desktop\Notes.txt',
        'Documents\PROJECTS ARCHIVE\OLD CLIENT FILES FROM THE PREVIOUS SYSTEM\EXPORTED DOCUMENTS AND ATTACHMENTS\SCANNED CORRESPONDENCE WITH COUNTERPARTIES\Letter.pdf'
    )
}
