#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\PathShrink\PathShrink.psd1') -Force
    . (Join-Path $PSScriptRoot 'Fixture.ps1')
}

Describe 'Name transforms' {
    It 'cleans up without losing letters' {
        InModuleScope PathShrink { Get-CleanName 'Contoso   Holdings , Ltd - Q3 .' } | Should -Be 'Contoso Holdings,Ltd-Q3'
    }
    It 'joins words and capitalises them' {
        InModuleScope PathShrink { Get-JoinedName 'Tax returns and schedules' } | Should -Be 'TaxReturnsAndSchedules'
    }
    It 'keeps the extension when trimming a file name' {
        InModuleScope PathShrink { Get-TrimmedName 'Quarterly report draft.docx' 5 $true 10 } | Should -Be 'Quarterly report.docx'
    }
    It 'never trims below the minimum length' {
        InModuleScope PathShrink { Get-TrimmedName 'Short name' 50 $false 8 } | Should -Be 'Short na'
    }
}

Describe 'Library resolution' {
    BeforeAll { $root = New-TestRoot; New-TestTree $root @('Desktop\a.txt', 'Desktop\Sub\b.txt') }
    AfterAll { Remove-TestRoot $root }

    It 'computes the personal prefix from the e-mail' {
        $lib = Get-PathShrinkLibrary -Root $root -Upn 'Ana.Perez@Contoso.com'
        $lib.Prefix | Should -Be 'personal/ana_perez_contoso_com/Documents/'
        $lib.IsPersonal | Should -BeTrue
        $lib.MinRenameDepth | Should -Be 1
    }
    It 'accepts a SharePoint prefix and allows renaming from the root' {
        $lib = Get-PathShrinkLibrary -Root $root -Prefix 'sites/Legal/Shared Documents'
        $lib.Prefix | Should -Be 'sites/Legal/Shared Documents/'
        $lib.MinRenameDepth | Should -Be 0
    }
    It 'never renames above the analysed subfolder' {
        $lib = Get-PathShrinkLibrary -Root $root -Path (Join-Path $root 'Desktop\Sub') -Prefix 'sites/x/'
        $lib.MinRenameDepth | Should -Be 2
    }
    It 'rejects a folder outside the root' {
        { Get-PathShrinkLibrary -Root (Join-Path $root 'Desktop') -Path $root -Prefix 'x/' } | Should -Throw
    }
    It 'requires a prefix or an e-mail with -Root' {
        { Get-PathShrinkLibrary -Root $root } | Should -Throw
    }
    It 'reads the prefix from the OneDrive registry when present' {
        Mock -ModuleName PathShrink Get-PathShrinkAccount { New-Object psobject -Property @{ LocalPath = $root; Email = 'old.name@contoso.com'; Name = 'Business1'; TenantName = '' } }
        Mock -ModuleName PathShrink Get-PathShrinkSyncMount { New-Object psobject -Property @{ LocalPath = $root; Url = 'https://contoso-my.sharepoint.com/personal/old_name_contoso_com/Documents'; Prefix = 'personal/old_name_contoso_com/Documents/'; Type = 'mysite' } }
        $lib = Get-PathShrinkLibrary
        $lib.PrefixSource | Should -Be 'OneDrive registry'
        $lib.Kind | Should -Be 'OneDrive'
    }
    It 'detects a synced SharePoint library inside the user profile' {
        $teams = Join-Path $root 'Desktop'
        Mock -ModuleName PathShrink Get-PathShrinkAccount { }
        Mock -ModuleName PathShrink Get-PathShrinkSyncMount { New-Object psobject -Property @{ LocalPath = $teams; Url = 'https://contoso.sharepoint.com/sites/Legal%20Team/Shared%20Documents'; Prefix = 'sites/Legal Team/Shared Documents/'; Type = 'teamsite' } }
        $lib = Get-PathShrinkLibrary -Path (Join-Path $teams 'Sub')
        $lib.Kind | Should -Be 'SharePoint library'
        $lib.Prefix | Should -Be 'sites/Legal Team/Shared Documents/'
    }
    It 'explains when there is no OneDrive account' {
        Mock -ModuleName PathShrink Get-PathShrinkAccount { }
        Mock -ModuleName PathShrink Get-PathShrinkSyncMount { }
        { Get-PathShrinkLibrary } | Should -Throw '*No OneDrive*'
    }
}

Describe 'Planning' {
    BeforeAll {
        $root = New-TestRoot
        New-TestTree $root (Get-DeepFiles)
        $lib = Get-PathShrinkLibrary -Root $root -Upn $TestUpn
        $inv = Get-PathShrinkInventory -Library $lib
    }
    AfterAll { Remove-TestRoot $root }

    It 'measures the server length as prefix + relative path' {
        $plan = New-PathShrinkPlan -Inventory $inv -Limit 300 -Margin 0
        foreach ($p in $plan.Paths) { $p.Before | Should -Be ($lib.Prefix.Length + $p.Rel.Length) }
    }
    It 'reports nothing when every path fits' {
        $plan = New-PathShrinkPlan -Inventory $inv -Limit 400 -Margin 0
        $plan.Paths.Count | Should -Be 0
        $plan.Renames.Count | Should -Be 0
    }
    It 'without -AllowTrim never removes letters and never renames files' {
        $plan = New-PathShrinkPlan -Inventory $inv -Limit 260 -Margin 0
        $plan.Renames.Count | Should -BeGreaterThan 0
        foreach ($r in $plan.Renames) {
            $r.Type | Should -Be 'Folder'
            ($r.NewName -replace '[\s]', '').ToLower() | Should -Be (($r.OriginalName -replace '[\s]', '').TrimEnd('.').ToLower())
        }
    }
    It 'stops as soon as the path fits (minimal changes)' {
        $plan = New-PathShrinkPlan -Inventory $inv -Limit 320 -Margin 0
        $plan.Renames.Count | Should -BeLessThan (New-PathShrinkPlan -Inventory $inv -Limit 260 -Margin 0).Renames.Count
        @($plan.Paths | Where-Object Status -ne 'Fixed').Count | Should -Be 0
    }
    It 'with -AllowTrim fixes paths that spaces alone cannot' {
        $plain = New-PathShrinkPlan -Inventory $inv -Limit 200 -Margin 0
        $trim = New-PathShrinkPlan -Inventory $inv -Limit 200 -Margin 0 -AllowTrim -MinNameLength 8
        @($plain.Paths | Where-Object Status -eq 'TooLong').Count | Should -BeGreaterThan 0
        @($trim.Paths | Where-Object Status -eq 'Fixed').Count | Should -BeGreaterThan @($plain.Paths | Where-Object Status -eq 'Fixed').Count
    }
    It 'never renames first-level folders of a personal OneDrive' {
        $plan = New-PathShrinkPlan -Inventory $inv -Limit 150 -Margin 0 -AllowTrim -MinNameLength 3
        @($plan.Renames | Where-Object Depth -eq 1).Count | Should -Be 0
    }
    It 'respects protected names' {
        $plan = New-PathShrinkPlan -Inventory $inv -Limit 260 -Margin 0 -Protect 'Clients and Matters'
        @($plan.Renames | Where-Object OriginalName -eq 'Clients and Matters').Count | Should -Be 0
    }
    It 'counts how many items each rename moves' {
        $plan = New-PathShrinkPlan -Inventory $inv -Limit 260 -Margin 0
        $r = $plan.Renames | Where-Object OriginalName -eq 'Clients and Matters'
        $expected = @($inv.Items | Where-Object { $_.Rel -like 'Desktop\Clients and Matters*' }).Count
        $r.Affects | Should -Be $expected
    }
    It 'recomputes lengths when a rename is deselected' {
        $plan = New-PathShrinkPlan -Inventory $inv -Limit 300 -Margin 0
        $before = ($plan.Paths | Measure-Object After -Sum).Sum
        foreach ($r in $plan.Renames) { $r.Selected = $false }
        [void](Update-PathShrinkPlan -Plan $plan)
        ($plan.Paths | Measure-Object After -Sum).Sum | Should -BeGreaterThan $before
        foreach ($p in $plan.Paths) { $p.After | Should -Be $p.Before }
    }
    It 'does not rename folders that only serve paths it cannot fix' {
        $plan = New-PathShrinkPlan -Inventory $inv -Limit 200 -Margin 0
        foreach ($r in $plan.Renames) {
            $helped = @($plan.Paths | Where-Object { $_.Status -ne 'TooLong' -and ($_.Rel -eq $r.Rel -or $_.Rel.StartsWith($r.Rel + '\')) })
            $helped.Count | Should -BeGreaterThan 0
        }
    }
    It 'rejects a target that does not leave room after the prefix' {
        { New-PathShrinkPlan -Inventory $inv -Limit 50 -Margin 10 } | Should -Throw
    }
    It 'gives the same plan on every run' {
        $a = (New-PathShrinkPlan -Inventory $inv -Limit 200 -Margin 0 -AllowTrim -MinNameLength 8).Renames | ForEach-Object { $_.Rel + '>' + $_.NewName }
        $b = (New-PathShrinkPlan -Inventory $inv -Limit 200 -Margin 0 -AllowTrim -MinNameLength 8).Renames | ForEach-Object { $_.Rel + '>' + $_.NewName }
        ($a -join '|') | Should -Be ($b -join '|')
    }
}

Describe 'Name collisions' {
    BeforeAll { $root = New-TestRoot }
    AfterAll { Remove-TestRoot $root }
    It 'does not reuse a sibling name' {
        $long = 'x' * 60
        New-TestTree $root @("Area\Big Project\$long\a.txt", "Area\BigProject\keep.txt")
        $lib = Get-PathShrinkLibrary -Root $root -Prefix 'sites/s/'
        $plan = New-PathShrinkPlan -Inventory (Get-PathShrinkInventory -Library $lib) -Limit 90 -Margin 0
        $r = $plan.Renames | Where-Object OriginalName -eq 'Big Project'
        $r.NewName | Should -Not -Be 'BigProject'
        $r.NewName | Should -Match '~2$'
    }
}

Describe 'Inventory' {
    BeforeAll { $root = New-TestRoot }
    AfterAll { Remove-TestRoot $root }
    It 'reads items deeper than 260 characters' {
        $deep = (1..12 | ForEach-Object { 'Folder number ' + $_ + ' with a long descriptive name' }) -join '\'
        New-TestTree $root @("$deep\file.txt")
        ($root.Length + $deep.Length) | Should -BeGreaterThan 260
        $inv = Get-PathShrinkInventory -Library (Get-PathShrinkLibrary -Root $root -Prefix '')
        $inv.Items.Count | Should -Be 13
        $inv.Errors.Count | Should -Be 0
    }
    It 'skips excluded folders' {
        New-TestTree $root @('Keep\a.txt', 'Archive\b.txt', 'Archive\Sub\c.txt')
        $inv = Get-PathShrinkInventory -Library (Get-PathShrinkLibrary -Root $root -Prefix '') -Exclude 'Archive'
        @($inv.Items | Where-Object { $_.Rel -like 'Archive*' }).Count | Should -Be 0
        @($inv.Skipped).Count | Should -BeGreaterThan 0
    }
    It 'does not follow junctions' {
        $target = New-TestRoot
        try {
            New-TestTree $target @('outside.txt')
            New-TestTree $root @('Linked\')
            cmd /c mklink /J "$root\Jump" "$target" | Out-Null
            $inv = Get-PathShrinkInventory -Library (Get-PathShrinkLibrary -Root $root -Prefix '')
            @($inv.Items | Where-Object { $_.Rel -like 'Jump\*' }).Count | Should -Be 0
            @($inv.Items | Where-Object { $_.Rel -eq 'Jump' }).Count | Should -Be 1
        } finally {
            cmd /c rmdir "$root\Jump" | Out-Null
            Remove-TestRoot $target
        }
    }
}

Describe 'Apply, verify and undo' {
    BeforeEach { $root = New-TestRoot; New-TestTree $root (Get-DeepFiles); $original = Get-TestRels $root }
    AfterEach { Remove-TestRoot $root; Remove-TestRoot "$root-reports" }

    It 'changes nothing with -WhatIf' {
        $lib = Get-PathShrinkLibrary -Root $root -Upn $TestUpn
        $plan = New-PathShrinkPlan -Inventory (Get-PathShrinkInventory -Library $lib) -Limit 260 -Margin 0
        Invoke-PathShrinkPlan -Plan $plan -WhatIf | Out-Null
        Get-TestRels $root | Should -Be $original
    }
    It 'renames, verifies on disk and restores everything with undo' {
        $lib = Get-PathShrinkLibrary -Root $root -Upn $TestUpn
        $plan = New-PathShrinkPlan -Inventory (Get-PathShrinkInventory -Library $lib) -Limit 260 -Margin 0
        $res = Invoke-PathShrinkPlan -Plan $plan -ReportFolder "$root-reports" -Confirm:$false
        $res.Failed | Should -Be 0
        $res.Renamed | Should -Be $plan.Renames.Count
        $res.VerifiedFixed | Should -Be $res.ExpectedFixed
        Get-TestRels $root | Should -Not -Be $original
        Test-Path $res.UndoFile | Should -BeTrue

        $u = Undo-PathShrink -UndoFile $res.UndoFile -Confirm:$false
        $u.Failed | Should -Be 0
        Get-TestRels $root | Should -Be $original
    }
    It 'applies only the selected renames' {
        $lib = Get-PathShrinkLibrary -Root $root -Upn $TestUpn
        $plan = New-PathShrinkPlan -Inventory (Get-PathShrinkInventory -Library $lib) -Limit 260 -Margin 0
        $plan.Renames[0].Selected = $false
        $res = Invoke-PathShrinkPlan -Plan $plan -ReportFolder "$root-reports" -Confirm:$false
        $res.Renamed | Should -Be ($plan.Renames.Count - 1)
        Test-Path -LiteralPath ('\\?\' + (Join-Path $root $plan.Renames[0].Rel)) | Should -BeTrue
    }
    It 'records a failed rename and carries on' {
        $lib = Get-PathShrinkLibrary -Root $root -Upn $TestUpn
        $plan = New-PathShrinkPlan -Inventory (Get-PathShrinkInventory -Library $lib) -Limit 260 -Margin 0
        $victim = $plan.Renames | Sort-Object Depth -Descending | Select-Object -First 1
        New-TestTree $root @(($victim.Parent + '\' + $victim.NewName + '\'))   # target name already taken
        $res = Invoke-PathShrinkPlan -Plan $plan -ReportFolder "$root-reports" -Confirm:$false
        $res.Failed | Should -Be 1
        $res.Renamed | Should -Be ($plan.Renames.Count - 1)
        ($res.Results | Where-Object { $_.Result -like 'ERROR*' }).OriginalName | Should -Be $victim.OriginalName
    }
}

Describe 'Sync issues' {
    It 'flags reserved and lock names' {
        $inv = New-Object psobject -Property @{ Items = @(
            (New-Object psobject -Property @{ Rel = 'a\CON.txt'; Name = 'CON.txt'; IsFolder = $false }),
            (New-Object psobject -Property @{ Rel = 'a\~$report.docx'; Name = '~$report.docx'; IsFolder = $false }),
            (New-Object psobject -Property @{ Rel = 'a\my_vti_folder'; Name = 'my_vti_folder'; IsFolder = $true }),
            (New-Object psobject -Property @{ Rel = 'a\ ok.txt'; Name = ' ok.txt'; IsFolder = $false }),
            (New-Object psobject -Property @{ Rel = 'a\Console.txt'; Name = 'Console.txt'; IsFolder = $false }),
            (New-Object psobject -Property @{ Rel = 'a\desktop.ini'; Name = 'desktop.ini'; IsFolder = $false })) }
        $r = @(Find-PathShrinkSyncIssue -Inventory $inv)
        $r.Count | Should -Be 4
        ($r | Where-Object Name -eq 'CON.txt').Issue | Should -Be 'reserved name'
        ($r | Where-Object Name -eq ' ok.txt').Issue | Should -Be 'leading or trailing space'
    }
}

Describe 'Reports' {
    BeforeAll { $root = New-TestRoot; New-TestTree $root (Get-DeepFiles) }
    AfterAll { Remove-TestRoot $root; Remove-TestRoot "$root-reports" }
    It 'writes csv, json and html' {
        $lib = Get-PathShrinkLibrary -Root $root -Upn $TestUpn
        $plan = New-PathShrinkPlan -Inventory (Get-PathShrinkInventory -Library $lib) -Limit 260 -Margin 0
        $f = Export-PathShrinkReport -Plan $plan -Folder "$root-reports"
        foreach ($n in 'paths.csv', 'planned-renames.csv', 'summary.json', 'report.html') { Test-Path (Join-Path $f $n) | Should -BeTrue }
        (Get-Content (Join-Path $f 'summary.json') -Raw | ConvertFrom-Json).summary.Renames | Should -Be $plan.Renames.Count
    }
}
