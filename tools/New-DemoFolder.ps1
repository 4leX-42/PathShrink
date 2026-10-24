#Requires -Version 5.1

<#
.SYNOPSIS
    Creates a fake OneDrive folder with paths over the 400-character limit, for demos, screenshots and manual tests.
.DESCRIPTION
    Every name is invented. Files are a few bytes each. Open it with:
        Start-PathShrink -Root <folder> -Upn ana.perez@contoso.com
.PARAMETER Path
    Folder to create. Default: %TEMP%\PathShrinkDemo. Must not exist yet.
#>
[CmdletBinding()]
param([string]$Path = (Join-Path ([IO.Path]::GetTempPath()) 'PathShrinkDemo'))

$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $Path) { throw "Already exists: $Path" }

$clients = 'Contoso Holdings International Limited', 'Fabrikam Industrial Components Group', 'Northwind Traders and Logistics'
$matters = 'Mergers and Acquisitions - Due Diligence 2026', 'Employment and Labour Disputes - Regional Office', 'Commercial Lease Renegotiation   and Renewals'
$areas = 'Financial Statements and Tax Returns', 'Correspondence with Counterparties and Advisors', 'Board Minutes and Shareholder Resolutions'
$deep = '2026 Engagement - Fieldwork Testing and Reporting\Working Papers and Supporting Schedules\Quarterly Reconciliations and Adjustments\Reviewed by Partner - Final Versions'
$docs = 'Final report for the board of directors - signed copy.pdf', 'Appendix A - detailed general ledger export.xlsx', 'Memo on tax exposure and recommended next steps.docx'

$files = New-Object System.Collections.Generic.List[string]
foreach ($c in $clients) {
    foreach ($m in $matters) {
        foreach ($a in $areas) {
            foreach ($d in $docs) { $files.Add(('Desktop\CLIENTS - ACTIVE MATTERS\{0}\{1}\{2}\{3}\{4}' -f $c, $m, $a, $deep, $d)) }
            $files.Add(('Desktop\CLIENTS - ACTIVE MATTERS\{0}\{1}\{2}\Index.xlsx' -f $c, $m, $a))
        }
    }
}
$files.Add('Desktop\CLIENTS - ACTIVE MATTERS\Northwind Traders and Logistics\ARCHIVE - PREVIOUS DOCUMENT MANAGEMENT SYSTEM\EXPORTED MATTERS AND CORRESPONDENCE 2015-2020\LITIGATION AND REGULATORY PROCEEDINGS BEFORE THE HIGH COURT\EXHIBITS AND WITNESS STATEMENTS FILED BY ALL PARTIES\Witness statement of the former finance director.pdf')
$files.Add('Documents\Templates\Engagement letter.docx')
$files.Add('Documents\Templates\~$gagement letter.docx')
$files.Add('Pictures\Team offsite.jpg')

foreach ($f in $files) {
    $full = '\\?\' + (Join-Path $Path $f)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
    [IO.File]::WriteAllText($full, 'demo')
}
Write-Host ('Created {0} files under {1}' -f $files.Count, $Path)
Write-Host ('Open it: Start-PathShrink -Root "{0}" -Upn ana.perez@contoso.com' -f $Path)
