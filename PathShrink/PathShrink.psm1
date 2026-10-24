#Requires -Version 5.1

# PathShrink core. No UI in this file: the GUI and the CLI both call these functions.
# Windows PowerShell 5.1 and PowerShell 7. ASCII only (5.1 reads BOM-less files as ANSI).

Set-StrictMode -Version 2

$script:ModuleRoot = $PSScriptRoot
$script:DefaultLimit = 400
$script:DefaultMargin = 20

# --------------------------------------------------------------------------------------
# Long path helpers: every disk call goes through \\?\ so Windows PowerShell 5.1 works
# even when LongPathsEnabled is off, and does not silently skip the very items we need.
# --------------------------------------------------------------------------------------
function ConvertTo-LongPath([string]$Path) {
    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\')) { return '\\?\UNC\' + $Path.Substring(2) }
    '\\?\' + $Path
}
function ConvertFrom-LongPath([string]$Path) {
    if ($Path.StartsWith('\\?\UNC\')) { return '\\' + $Path.Substring(8) }
    if ($Path.StartsWith('\\?\')) { return $Path.Substring(4) }
    $Path
}

function Get-ServerPrefix([string]$Url) {
    # https://contoso-my.sharepoint.com/personal/ana_contoso_com/Documents -> personal/ana_contoso_com/Documents/
    try {
        $p = [Uri]::UnescapeDataString(([Uri]$Url).AbsolutePath).TrimStart('/')
        if (-not $p.EndsWith('/')) { $p += '/' }
        $p
    } catch { $null }
}

function ConvertTo-PersonalPrefix([string]$Upn) {
    'personal/' + ($Upn.ToLowerInvariant() -replace '[.@]', '_') + '/Documents/'
}

# --------------------------------------------------------------------------------------
# Registry readers (kept small so tests can mock them)
# --------------------------------------------------------------------------------------
function Get-PathShrinkSyncMount {
    <#
    .SYNOPSIS
        Lists the folders the OneDrive client syncs for the current user, with the library URL of each.
    #>
    [CmdletBinding()]
    param()
    foreach ($k in @(Get-ChildItem 'HKCU:\Software\SyncEngines\Providers\OneDrive' -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        $names = $p.PSObject.Properties.Name
        if (-not ($names -contains 'MountPoint') -or -not $p.MountPoint) { continue }
        $url = $null; if ($names -contains 'UrlNamespace') { $url = [string]$p.UrlNamespace }
        $type = ''; if ($names -contains 'LibraryType') { $type = [string]$p.LibraryType }
        New-Object psobject -Property @{
            LocalPath = ([string]$p.MountPoint).TrimEnd('\')
            Url       = $url
            Prefix    = $(if ($url) { Get-ServerPrefix $url } else { $null })
            Type      = $type
        }
    }
}

function Get-PathShrinkAccount {
    <#
    .SYNOPSIS
        Lists the OneDrive for work or school accounts configured in the current Windows profile.
    #>
    [CmdletBinding()]
    param()
    foreach ($k in @(Get-ChildItem 'HKCU:\Software\Microsoft\OneDrive\Accounts' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'Business*' })) {
        $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        $names = $p.PSObject.Properties.Name
        if (-not ($names -contains 'UserFolder') -or -not $p.UserFolder) { continue }
        if (-not (Test-Path -LiteralPath $p.UserFolder)) { continue }
        New-Object psobject -Property @{
            Name       = $k.PSChildName
            LocalPath  = ([string]$p.UserFolder).TrimEnd('\')
            Email      = $(if ($names -contains 'UserEmail') { [string]$p.UserEmail } else { '' })
            TenantName = $(if ($names -contains 'DisplayName') { [string]$p.DisplayName } else { '' })
        }
    }
}

function Test-UnderPath([string]$Path, [string]$Parent) {
    $Path -eq $Parent -or $Path.StartsWith($Parent + '\', [StringComparison]::OrdinalIgnoreCase)
}

# --------------------------------------------------------------------------------------
# Library: which synced library a folder belongs to, and its server-side prefix
# --------------------------------------------------------------------------------------
function Get-PathShrinkLibrary {
    <#
    .SYNOPSIS
        Resolves the synced library that contains a folder and the server-side path prefix used to measure lengths.
    .DESCRIPTION
        OneDrive and SharePoint count the decoded server path: library path plus the path
        inside it, for example personal/ana_contoso_com/Documents/Clients/... . This function
        finds that prefix from the OneDrive client registry, or computes it from the account
        e-mail. With -Root and -Prefix (or -Upn) it works on any folder without the registry,
        which is how tests and copied folders are analysed.
    .PARAMETER Path
        Folder to analyse. Default: the root of the first OneDrive for work or school account.
    .PARAMETER Upn
        Account e-mail, used to compute a personal OneDrive prefix when the registry has no URL.
    .PARAMETER Root
        Local root of the library given by hand (skips the registry). Needs -Prefix or -Upn.
    .PARAMETER Prefix
        Server-side prefix given by hand, for example "sites/Legal/Shared Documents/".
    .PARAMETER Personal
        With -Root: treat the root as a personal OneDrive (its first-level folders are protected).
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$Upn,
        [string]$Root,
        [AllowEmptyString()][string]$Prefix,
        [switch]$Personal
    )
    $prefixGiven = $PSBoundParameters.ContainsKey('Prefix')
    if ($Path) { $Path = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath.TrimEnd('\') }

    if ($Root) {
        $Root = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).ProviderPath.TrimEnd('\')
        if (-not $Path) { $Path = $Root }
        if (-not (Test-UnderPath $Path $Root)) { throw "The folder is not inside the root: $Path" }
        if ($prefixGiven) { $pre = $Prefix; $src = 'given' }
        elseif ($Upn) { $pre = ConvertTo-PersonalPrefix $Upn; $src = 'computed from e-mail'; $Personal = $true }
        else { throw '-Root needs -Prefix or -Upn.' }
        if ($pre -and -not $pre.EndsWith('/')) { $pre += '/' }
        return New-PathShrinkLibrary -Path $Path -Base $Root -Prefix $pre -PrefixSource $src -Account $Upn -Personal:$Personal -Kind 'Folder'
    }

    $accounts = @(Get-PathShrinkAccount)
    $mounts = @(Get-PathShrinkSyncMount)
    if (-not $Path) {
        if (-not $accounts.Count) { throw 'No OneDrive for work or school account is set up in this Windows profile. Pick a folder by hand.' }
        $Path = $accounts[0].LocalPath
    }

    $account = $accounts | Where-Object { Test-UnderPath $Path $_.LocalPath } | Select-Object -First 1
    $mount = @($mounts | Where-Object { Test-UnderPath $Path $_.LocalPath } | Sort-Object { $_.LocalPath.Length } -Descending) | Select-Object -First 1
    # The personal OneDrive wins when it is the most specific match.
    if ($mount -and $account -and $mount.LocalPath.Length -le $account.LocalPath.Length) { $mount = $null }

    $email = $Upn
    if ($mount) {
        $pre = $mount.Prefix; $src = 'OneDrive registry'
        if ($prefixGiven) { $pre = $Prefix; $src = 'given' }
        if ($null -eq $pre) { throw "Could not read the library URL for $($mount.LocalPath). Pass -Prefix." }
        if ($pre -and -not $pre.EndsWith('/')) { $pre += '/' }
        $isPersonal = $pre -like 'personal/*'
        if (-not $email -and $account) { $email = $account.Email }
        $kind = $(if ($isPersonal) { 'OneDrive' } else { 'SharePoint library' })
        return New-PathShrinkLibrary -Path $Path -Base $mount.LocalPath -Prefix $pre -PrefixSource $src -Account $email -Personal:$isPersonal -Kind $kind -Mounts $mounts
    }
    if ($account) {
        if (-not $email) { $email = $account.Email }
        # The real URL wins over the e-mail: after a UPN change the URL keeps the old name.
        $m = $mounts | Where-Object { $_.LocalPath -eq $account.LocalPath -and $_.Prefix -match '^personal/[^/]+/Documents/$' } | Select-Object -First 1
        if ($prefixGiven) { $pre = $Prefix; $src = 'given' }
        elseif ($m) { $pre = $m.Prefix; $src = 'OneDrive registry' }
        elseif ($email) { $pre = ConvertTo-PersonalPrefix $email; $src = 'computed from e-mail' }
        else { throw 'Could not read the OneDrive account e-mail. Pass -Upn.' }
        if ($pre -and -not $pre.EndsWith('/')) { $pre += '/' }
        return New-PathShrinkLibrary -Path $Path -Base $account.LocalPath -Prefix $pre -PrefixSource $src -Account $email -Personal -Kind 'OneDrive' -Mounts $mounts
    }
    throw "This folder is not inside OneDrive or a synced SharePoint library: $Path. Use -Root and -Prefix to analyse it anyway."
}

function New-PathShrinkLibrary {
    param([string]$Path, [string]$Base, [string]$Prefix, [string]$PrefixSource, [string]$Account, [switch]$Personal, [string]$Kind, [object[]]$Mounts = @())
    $depth = 0
    if ($Path -ne $Base) { $depth = $Path.Substring($Base.Length + 1).Split('\').Count }
    # Never rename above the analysed folder, nor the first level of a personal OneDrive
    # (Desktop, Documents, Pictures are redirected known folders).
    $minDepth = $depth
    if ($Personal) { $minDepth = [Math]::Max(1, $depth) }
    # Shortcuts to other libraries inside the folder have another server path: skipped.
    $skip = @($Mounts | Where-Object { $_.LocalPath -ne $Base -and $_.LocalPath.StartsWith($Path + '\', [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { $_.LocalPath })
    New-Object psobject -Property @{
        Path = $Path; Base = $Base; Prefix = $Prefix; PrefixSource = $PrefixSource
        Account = $Account; IsPersonal = [bool]$Personal; Kind = $Kind
        MinRenameDepth = $minDepth; SkipPaths = $skip
    }
}

# --------------------------------------------------------------------------------------
# Inventory
# --------------------------------------------------------------------------------------
function Test-PathShrinkExcluded([string]$Rel, [string]$Name, [string[]]$Patterns) {
    foreach ($p in $Patterns) {
        if (-not $p) { continue }
        if ($Name -like $p -or $Rel -like $p) { return $true }
    }
    $false
}

function Get-PathShrinkInventory {
    <#
    .SYNOPSIS
        Lists every file and folder under the library folder, without downloading cloud-only files.
    .PARAMETER Exclude
        Wildcards matched against the item name or its path inside the library. Matching
        folders are not scanned and nothing inside them is renamed.
    .PARAMETER OnProgress
        Script block called every 500 items with the number of items read.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Library,
        [string[]]$Exclude = @(),
        [scriptblock]$OnProgress
    )
    $Exclude = @($Exclude | Where-Object { $_ })
    $items = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]
    $skip = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($s in $Library.SkipPaths) { [void]$skip.Add($s) }
    $base = $Library.Base
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Library.Path)
    $n = 0
    while ($stack.Count) {
        $dir = $stack.Pop()
        try { $children = ([IO.DirectoryInfo](ConvertTo-LongPath $dir)).GetFileSystemInfos() }
        catch {
            $msg = $_.Exception.Message; if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
            $errors.Add(('{0}: {1}' -f $dir, $msg)); continue
        }
        foreach ($c in $children) {
            $full = ConvertFrom-LongPath $c.FullName
            if ($skip.Contains($full)) { $skipped.Add($full + '  (shortcut to another library)'); continue }
            $rel = $full.Substring($base.Length + 1)
            $isDir = [bool]($c.Attributes -band [IO.FileAttributes]::Directory)
            if ($Exclude.Count -and (Test-PathShrinkExcluded $rel $c.Name $Exclude)) { $skipped.Add($full + '  (excluded)'); continue }
            $recurse = $isDir
            if ($isDir -and ($c.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                # OneDrive folders are cloud reparse points and must be scanned; junctions and
                # symbolic links point outside the library and are not followed.
                $lt = $null
                try { $lt = (Get-Item -LiteralPath $c.FullName -Force -ErrorAction Stop).LinkType } catch { Write-Verbose ('Link type unknown: {0}' -f $full) }
                if ($lt -eq 'Junction' -or $lt -eq 'SymbolicLink') { $recurse = $false; $skipped.Add($full + '  (link not followed)') }
            }
            $items.Add([pscustomobject]@{ Rel = $rel; Name = $c.Name; IsFolder = $isDir })
            if ($recurse) { $stack.Push($full) }
            $n++
            if ($OnProgress -and ($n % 500) -eq 0) { & $OnProgress $n }
        }
    }
    if ($OnProgress) { & $OnProgress $n }
    Write-Verbose ('Read {0} items, {1} unreadable, {2} skipped.' -f $items.Count, $errors.Count, $skipped.Count)
    New-Object psobject -Property @{ Library = $Library; Items = $items; Errors = $errors; Skipped = $skipped }
}

# --------------------------------------------------------------------------------------
# Name transforms (pure)
# --------------------------------------------------------------------------------------
function Get-CleanName([string]$Name) {
    # Lossless clean-up: double spaces, spaces around - _ , and trailing spaces or dots.
    $s = $Name -replace '\s{2,}', ' '
    $s = $s -replace '\s*([-_,])\s*', '$1'
    $s.TrimStart().TrimEnd(' ', '.')
}
function Get-JoinedName([string]$Name) {
    # "Changes and fixes" -> "ChangesAndFixes": spaces go, no letter is lost.
    $out = ''
    foreach ($w in ($Name.Split(' ') | Where-Object { $_ })) {
        if ($out -and [char]::IsLower($w[0])) { $w = $w.Substring(0, 1).ToUpper() + $w.Substring(1) }
        $out += $w
    }
    $out
}
function Get-TrimmedName([string]$Name, [int]$By, [bool]$IsFile, [int]$MinLength) {
    $ext = ''; if ($IsFile) { $ext = [IO.Path]::GetExtension($Name) }
    $b = $Name.Substring(0, $Name.Length - $ext.Length)
    $len = [Math]::Max($MinLength, $b.Length - $By)
    if ($len -ge $b.Length) { return $Name }
    $b.Substring(0, $len).TrimEnd(' ', '.', '-', '_', ',') + $ext
}

# --------------------------------------------------------------------------------------
# Plan
# --------------------------------------------------------------------------------------
function New-PathShrinkPlan {
    <#
    .SYNOPSIS
        Works out the smallest set of renames that brings every long path under the target length. Changes nothing on disk.
    .DESCRIPTION
        For each path above Limit - Margin, and stopping as soon as it fits:
          1. clean-up without loss (double spaces, spaces around - _ , trailing spaces and dots)
          2. remove spaces from folder names, capitalising each word ("Tax returns" -> "TaxReturns");
             ALL-CAPS names last, because without spaces they are hard to read
          3. only with -AllowTrim: remove letters from the end of the longest folder name, one at
             a time, never below -MinNameLength
        File names are never touched unless -AllowTrim is set and no folder can give more.
    .PARAMETER Inventory
        Output of Get-PathShrinkInventory.
    .PARAMETER Protect
        Wildcards for names that must never be renamed (they still count towards the length).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Inventory,
        [ValidateRange(50, 400)][int]$Limit = 400,
        [ValidateRange(0, 200)][int]$Margin = 20,
        [switch]$AllowTrim,
        [ValidateRange(3, 200)][int]$MinNameLength = 20,
        [string[]]$Protect = @()
    )
    $Protect = @($Protect | Where-Object { $_ })
    $lib = $Inventory.Library
    $prefixLen = $lib.Prefix.Length
    $target = $Limit - $Margin
    if ($target -le $prefixLen) { throw ('The target length ({0}) is not above the server prefix ({1} characters).' -f $target, $prefixLen) }
    $minK = $lib.MinRenameDepth

    $newName = @{}   # rel (original) -> new name
    $method = @{}    # rel (original) -> steps applied
    $siblings = @{}  # parent rel -> names in use
    foreach ($it in $Inventory.Items) {
        $i = $it.Rel.LastIndexOf('\')
        $parent = ''; if ($i -ge 0) { $parent = $it.Rel.Substring(0, $i) }
        if (-not $siblings.ContainsKey($parent)) { $siblings[$parent] = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase) }
        [void]$siblings[$parent].Add($it.Name)
    }

    $long = New-Object System.Collections.Generic.List[object]
    foreach ($it in $Inventory.Items) {
        if ($prefixLen + $it.Rel.Length -le $target) { continue }
        $seg = $it.Rel.Split('\')
        $rels = New-Object string[] $seg.Count
        $rels[0] = $seg[0]
        for ($k = 1; $k -lt $seg.Count; $k++) { $rels[$k] = $rels[$k - 1] + '\' + $seg[$k] }
        $long.Add([pscustomobject]@{ Item = $it; Seg = $seg; Rels = $rels; Full = $prefixLen + $it.Rel.Length })
    }
    # Shallowest first, ties in scan order: a stable sort, so 5.1 and 7 plan the same renames.
    $long = $long.ToArray()
    $depthKey = New-Object 'long[]' $long.Count
    for ($i = 0; $i -lt $long.Count; $i++) { $depthKey[$i] = [long]$long[$i].Seg.Count * 10000000 + $i }
    [Array]::Sort($depthKey, $long)
    Write-Verbose ('{0} paths above {1} characters.' -f $long.Count, $target)

    $nameAt = { param($p, $k) $r = $p.Rels[$k]; if ($newName.ContainsKey($r)) { $newName[$r] } else { $p.Seg[$k] } }
    # Characters saved per renamed level, so a length is the original minus the savings of its levels.
    $saved = @{}
    $lengthOf = { param($p) $n = $p.Full; foreach ($r in $p.Rels) { $s = $saved[$r]; if ($s) { $n -= $s } }; $n }
    $setName = {
        param($p, $k, [string]$candidate, [string]$step)
        $r = $p.Rels[$k]
        $current = & $nameAt $p $k
        if (-not $candidate -or $candidate -ceq $current) { return $false }
        if ($Protect.Count -and (Test-PathShrinkExcluded $r $p.Seg[$k] $Protect)) { return $false }
        $parent = ''; if ($k -gt 0) { $parent = $p.Rels[$k - 1] }
        $used = $siblings[$parent]
        $isFile = ($k -eq $p.Seg.Count - 1) -and -not $p.Item.IsFolder
        $n = 2; $first = $candidate
        while ($used.Contains($candidate) -and $candidate -ne $current) {
            $ext = ''; if ($isFile) { $ext = [IO.Path]::GetExtension($first) }
            $stem = $first.Substring(0, $first.Length - $ext.Length)
            $candidate = '{0}~{1}{2}' -f $stem.Substring(0, [Math]::Max(1, $stem.Length - 2)), $n, $ext
            $n++
        }
        [void]$used.Remove($current); [void]$used.Add($candidate)
        $newName[$r] = $candidate
        $saved[$r] = $p.Seg[$k].Length - $candidate.Length
        if ($method.ContainsKey($r)) { if ($method[$r] -notlike "*$step*") { $method[$r] += ' + ' + $step } } else { $method[$r] = $step }
        $true
    }
    $split = { param($name, $isFile) if ($isFile) { $e = [IO.Path]::GetExtension($name); , @($name.Substring(0, $name.Length - $e.Length), $e) } else { , @($name, '') } }

    # Orderings below are stable (ties keep the level order) and built with [Array]::Sort on
    # numeric keys: Sort-Object in this loop made planning ten times slower on large trees.
    $shorten = {
        param($p, [int[]]$ks, [bool]$isFile)
        $n = $ks.Count
        $keys = New-Object 'long[]' $n; $order = New-Object 'int[]' $n
        for ($i = 0; $i -lt $n; $i++) {
            $nm = & $nameAt $p $ks[$i]
            $keys[$i] = - [long]($nm.Length - (Get-CleanName $nm).Length) * 1000 + $i; $order[$i] = $ks[$i]
        }
        [Array]::Sort($keys, $order)
        foreach ($k in $order) {
            if ((& $lengthOf $p) -le $target) { return }
            $parts = & $split (& $nameAt $p $k) $isFile
            [void](& $setName $p $k ((Get-CleanName $parts[0]) + $parts[1]) 'clean-up')
        }
        # Names with lower-case letters first (ALL-CAPS names are hard to read joined), then the most spaces.
        for ($i = 0; $i -lt $n; $i++) {
            $nm = & $nameAt $p $ks[$i]
            $keys[$i] = - ([long]([int]($nm -cmatch '[a-z]')) * 100000 + ([regex]::Matches($nm, ' ')).Count) * 1000 + $i; $order[$i] = $ks[$i]
        }
        [Array]::Sort($keys, $order)
        foreach ($k in $order) {
            if ((& $lengthOf $p) -le $target) { return }
            $parts = & $split (& $nameAt $p $k) $isFile
            [void](& $setName $p $k ((Get-JoinedName $parts[0]) + $parts[1]) 'no spaces')
        }
        # Trim one letter at a time from the longest name, so the cut is spread over the long
        # names and none is reduced to its first words. Ties go to the deepest level.
        $guard = 0
        while ($AllowTrim -and (& $lengthOf $p) -gt $target -and $guard -lt 5000) {
            $guard++
            $k = -1; $best = -1
            foreach ($c in $ks) {
                $len = (& $split (& $nameAt $p $c) $isFile)[0].Length
                if ($len -gt $MinNameLength -and ($len -gt $best -or ($len -eq $best -and $c -gt $k))) { $k = $c; $best = $len }
            }
            if ($k -lt 0) { return }
            if (-not (& $setName $p $k (Get-TrimmedName (& $nameAt $p $k) 1 $isFile $MinNameLength) 'trim')) { return }
        }
    }

    foreach ($p in $long) {
        $last = $p.Seg.Count - 1
        $n = $p.Full; foreach ($r in $p.Rels) { $s = $saved[$r]; if ($s) { $n -= $s } }
        if ($n -le $target -or $last -lt $minK) { continue }
        # Folders first, with every step. The document name matters more than its folder.
        $lastFolder = $last; if (-not $p.Item.IsFolder) { $lastFolder = $last - 1 }
        if ($lastFolder -ge $minK) { & $shorten $p @($minK..$lastFolder) $false }
        if (-not $p.Item.IsFolder -and $AllowTrim -and (& $lengthOf $p) -gt $target) { & $shorten $p @($last) $true }
    }

    # Keep only renames that help a path that ends up fixed, or that drop it under the hard
    # limit. Shaving a few characters off paths that stay too long would rename folders for
    # nothing; with -AllowTrim those paths are planned in full anyway.
    $useful = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $long) {
        $after = $p.Full; foreach ($r in $p.Rels) { $s = $saved[$r]; if ($s) { $after -= $s } }
        if ($after -le $target -or ($p.Full -gt $Limit -and $after -le $Limit)) {
            foreach ($r in $p.Rels) { if ($newName.ContainsKey($r)) { [void]$useful.Add($r) } }
        }
    }
    foreach ($r in @($newName.Keys)) { if (-not $useful.Contains($r)) { $newName.Remove($r) } }

    # Renames, with how many items each one moves.
    $byRel = @{}; foreach ($it in $Inventory.Items) { $byRel[$it.Rel] = $it }
    $renamed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $newName.Keys) { if ($newName[$r] -cne $byRel[$r].Name) { [void]$renamed.Add($r) } }
    $affects = @{}; foreach ($r in $renamed) { $affects[$r] = 1 }
    if ($renamed.Count) {
        foreach ($it in $Inventory.Items) {
            $i = $it.Rel.LastIndexOf('\')
            while ($i -gt 0) {
                $anc = $it.Rel.Substring(0, $i)
                if ($renamed.Contains($anc)) { $affects[$anc]++ }
                $i = $anc.LastIndexOf('\')
            }
        }
    }
    $id = 0
    $renames = @(foreach ($r in ($renamed | Sort-Object)) {
        $id++
        $it = $byRel[$r]
        $i = $r.LastIndexOf('\')
        New-Object psobject -Property @{
            Id = $id; Rel = $r; Depth = $r.Split('\').Count
            Parent = $(if ($i -ge 0) { $r.Substring(0, $i) } else { '' })
            Type = $(if ($it.IsFolder) { 'Folder' } else { 'File' })
            OriginalName = $it.Name; NewName = $newName[$r]; Saved = $it.Name.Length - $newName[$r].Length
            Affects = $affects[$r]; Method = $method[$r]; Selected = $true
        }
    })

    $plan = New-Object psobject -Property @{
        Library = $lib; Limit = $Limit; Margin = $Margin; Target = $target; AllowTrim = [bool]$AllowTrim
        MinNameLength = $MinNameLength; Protect = $Protect
        ItemCount = $Inventory.Items.Count; Errors = $Inventory.Errors; Skipped = $Inventory.Skipped
        LongItems = $long; Renames = $renames; Paths = @()
        Inventory = $Inventory; CreatedAt = (Get-Date)
    }
    Update-PathShrinkPlan -Plan $plan
}

function Update-PathShrinkPlan {
    <#
    .SYNOPSIS
        Recomputes the before/after length of every long path using only the selected renames.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Plan)
    $map = @{}
    foreach ($r in $Plan.Renames) { if ($r.Selected) { $map[$r.Rel] = $r.NewName } }
    $prefixLen = $Plan.Library.Prefix.Length
    $Plan.Paths = @(foreach ($p in $Plan.LongItems) {
        $names = for ($k = 0; $k -lt $p.Seg.Count; $k++) { if ($map.ContainsKey($p.Rels[$k])) { $map[$p.Rels[$k]] } else { $p.Seg[$k] } }
        $newRel = @($names) -join '\'
        $before = $prefixLen + $p.Item.Rel.Length
        $after = $prefixLen + $newRel.Length
        [pscustomobject]@{
            Rel = $p.Item.Rel; NewRel = $newRel; Type = $(if ($p.Item.IsFolder) { 'Folder' } else { 'File' })
            Before = $before; After = $after; Saved = $before - $after
            Status = $(if ($after -le $Plan.Target) { 'Fixed' } elseif ($after -le $Plan.Limit) { 'NoMargin' } else { 'TooLong' })
        }
    })
    $Plan
}

function Test-PathShrinkRename {
    <#
    .SYNOPSIS
        Checks a name typed by hand for one item of a plan. Returns nothing when it can be used, or the reason why not.
    .DESCRIPTION
        Codes: Empty, BadChar, Trailing, Reserved, TooLong (over 255), Longer (longer than the
        original: PathShrink only shortens), InUse (another item in the same folder has that
        name, counting the planned renames), Protected (above the analysed folder or a first-level
        folder of a personal OneDrive), Extension (a file must keep its extension), NotFound.
    .PARAMETER Rel
        The item, as its original path inside the library.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Plan, [Parameter(Mandatory)][string]$Rel, [AllowEmptyString()][string]$NewName)
    $fail = { param($c, $d) [pscustomobject]@{ Code = $c; Detail = $d } }
    $item = $null
    foreach ($it in $Plan.Inventory.Items) { if ($it.Rel -eq $Rel) { $item = $it; break } }
    if (-not $item) { return (& $fail 'NotFound' $Rel) }
    $k = $Rel.Split('\').Count - 1
    if ($k -lt $Plan.Library.MinRenameDepth) { return (& $fail 'Protected' '') }
    if ($NewName -ceq $item.Name) { return }
    if (-not $NewName) { return (& $fail 'Empty' '') }
    if ($NewName.IndexOfAny($script:BadChars) -ge 0 -or $NewName -match '[\x00-\x1f]') { return (& $fail 'BadChar' '') }
    if ($NewName -ne $NewName.Trim() -or $NewName.EndsWith('.')) { return (& $fail 'Trailing' '') }
    $stem = $NewName; $dot = $NewName.IndexOf('.'); if ($dot -gt 0) { $stem = $NewName.Substring(0, $dot) }
    if ($NewName -eq '.lock' -or $script:DeviceNames -contains $stem -or $NewName -like '*_vti_*' -or $NewName.StartsWith('~$')) { return (& $fail 'Reserved' '') }
    if ($NewName.Length -gt 255) { return (& $fail 'TooLong' '') }
    if ($NewName.Length -gt $item.Name.Length) { return (& $fail 'Longer' '') }
    if (-not $item.IsFolder) {
        $ext = [IO.Path]::GetExtension($item.Name)
        if ([IO.Path]::GetExtension($NewName) -ne $ext) { return (& $fail 'Extension' $ext) }
    }
    $i = $Rel.LastIndexOf('\'); $parent = $(if ($i -ge 0) { $Rel.Substring(0, $i) } else { '' })
    $planned = @{}; foreach ($r in $Plan.Renames) { if ($r.Selected) { $planned[$r.Rel] = $r.NewName } }
    foreach ($it in $Plan.Inventory.Items) {
        if ($it.Rel -eq $Rel) { continue }
        $j = $it.Rel.LastIndexOf('\'); $pp = $(if ($j -ge 0) { $it.Rel.Substring(0, $j) } else { '' })
        if ($pp -ne $parent) { continue }
        $name = $(if ($planned.ContainsKey($it.Rel)) { $planned[$it.Rel] } else { $it.Name })
        if ($name -eq $NewName) { return (& $fail 'InUse' $name) }
    }
}

function Set-PathShrinkRename {
    <#
    .SYNOPSIS
        Uses a name typed by hand for one item of a plan, then recomputes the plan. Changes nothing on disk.
    .DESCRIPTION
        The name is checked with Test-PathShrinkRename first and an error is thrown if it cannot be
        used. Typing the original name back removes the rename from the plan. A name for an item
        the plan did not rename adds a rename.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Plan, [Parameter(Mandatory)][string]$Rel, [Parameter(Mandatory)][string]$NewName)
    $e = Test-PathShrinkRename -Plan $Plan -Rel $Rel -NewName $NewName
    if ($e) { throw ('Cannot use "{0}" for {1}: {2} {3}' -f $NewName, $Rel, $e.Code, $e.Detail).Trim() }
    $item = $null
    foreach ($it in $Plan.Inventory.Items) { if ($it.Rel -eq $Rel) { $item = $it; break } }
    $existing = $null
    foreach ($r in $Plan.Renames) { if ($r.Rel -eq $Rel) { $existing = $r; break } }
    if ($NewName -ceq $item.Name) {
        $Plan.Renames = @($Plan.Renames | Where-Object { $_.Rel -ne $Rel })
    } elseif ($existing) {
        $existing.NewName = $NewName; $existing.Saved = $item.Name.Length - $NewName.Length
        $existing.Method = 'manual'; $existing.Selected = $true
    } else {
        $affects = 1
        foreach ($it in $Plan.Inventory.Items) { if ($it.Rel.StartsWith($Rel + '\', [StringComparison]::OrdinalIgnoreCase)) { $affects++ } }
        $i = $Rel.LastIndexOf('\')
        $id = 0; foreach ($r in $Plan.Renames) { if ($r.Id -gt $id) { $id = $r.Id } }
        $new = New-Object psobject -Property @{
            Id = $id + 1; Rel = $Rel; Depth = $Rel.Split('\').Count
            Parent = $(if ($i -ge 0) { $Rel.Substring(0, $i) } else { '' })
            Type = $(if ($item.IsFolder) { 'Folder' } else { 'File' })
            OriginalName = $item.Name; NewName = $NewName; Saved = $item.Name.Length - $NewName.Length
            Affects = $affects; Method = 'manual'; Selected = $true
        }
        $Plan.Renames = @(@($Plan.Renames) + $new | Sort-Object Rel)
    }
    Write-Verbose ('Manual name: {0} -> {1}' -f $Rel, $NewName)
    Update-PathShrinkPlan -Plan $Plan
}

function Get-PathShrinkSummary {
    <#
    .SYNOPSIS
        Counts for a plan: paths found, fixed, still too long, renames by type.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Plan)
    # Plain loops: the window calls this on every selection change, with thousands of paths.
    $renames = 0; $folders = 0; $saved = 0
    foreach ($r in $Plan.Renames) { if ($r.Selected) { $renames++; $saved += $r.Saved; if ($r.Type -eq 'Folder') { $folders++ } } }
    $fixed = 0; $noMargin = 0; $rescued = 0; $tooLong = 0; $over = 0
    foreach ($p in $Plan.Paths) {
        if ($p.Before -gt $Plan.Limit) { $over++ }
        switch ($p.Status) {
            'Fixed' { $fixed++ }
            'NoMargin' { $noMargin++; if ($p.Before -gt $Plan.Limit) { $rescued++ } }
            'TooLong' { $tooLong++ }
        }
    }
    New-Object psobject -Property ([ordered]@{
        Items        = $Plan.ItemCount
        LongPaths    = $Plan.Paths.Count
        OverLimit    = $over
        Fixed        = $fixed
        NoMargin     = $noMargin
        Rescued      = $rescued
        TooLong      = $tooLong
        Renames      = $renames
        Folders      = $folders
        Files        = $renames - $folders
        CharsRemoved = $saved
        Unreadable   = $Plan.Errors.Count
    })
}

# --------------------------------------------------------------------------------------
# Apply, verify, undo
# --------------------------------------------------------------------------------------
function Get-PathShrinkReportFolder {
    $root = Join-Path $env:LOCALAPPDATA 'PathShrink\Reports'
    $dir = Join-Path $root (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null
    $dir
}

function Invoke-PathShrinkPlan {
    <#
    .SYNOPSIS
        Applies the selected renames of a plan, records an undo file as it goes, and re-reads the disk to verify.
    .DESCRIPTION
        Renames run deepest first, so each item is renamed while its parent still has its
        original name. Every successful rename is appended to undo.csv immediately: if the
        run is interrupted, the file still lists what was changed.
    .PARAMETER ReportFolder
        Where undo.csv and the reports go. Default: %LOCALAPPDATA%\PathShrink\Reports\<timestamp>.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [string]$ReportFolder,
        [scriptblock]$OnProgress
    )
    $sel = @($Plan.Renames | Where-Object { $_.Selected } | Sort-Object Depth -Descending)
    if (-not $sel.Count) { Write-Verbose 'Nothing selected.'; return }
    if (-not $PSCmdlet.ShouldProcess(('{0} items in {1}' -f $sel.Count, $Plan.Library.Path), 'Rename')) { return }
    if (-not $ReportFolder) { $ReportFolder = Get-PathShrinkReportFolder }
    elseif (-not (Test-Path -LiteralPath $ReportFolder)) { New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null }
    $undo = Join-Path $ReportFolder 'undo.csv'
    $base = $Plan.Library.Base
    # run.json says what this run was, so the history can list it later without the plan.
    $run = [ordered]@{
        tool = 'PathShrink'; version = (Get-PathShrinkVersion); started = (Get-Date).ToString('s'); finished = $null
        folder = $Plan.Library.Path; library = $Plan.Library.Base; prefixLength = $Plan.Library.Prefix.Length
        limit = $Plan.Limit; target = $Plan.Target; allowTrim = $Plan.AllowTrim; selected = $sel.Count; renamed = 0; failed = 0
    }
    $runFile = Join-Path $ReportFolder 'run.json'
    $run | ConvertTo-Json | Set-Content -LiteralPath $runFile -Encoding UTF8
    $results = New-Object System.Collections.Generic.List[object]
    $ok = 0; $failed = 0; $n = 0
    foreach ($r in $sel) {
        $n++
        $path = Join-Path $base $r.Rel
        $row = New-Object psobject -Property ([ordered]@{
            Depth = $r.Depth; Type = $r.Type; OriginalPath = $path; OriginalName = $r.OriginalName; NewName = $r.NewName; Result = ''; Time = '' })
        try {
            Rename-Item -LiteralPath (ConvertTo-LongPath $path) -NewName $r.NewName -ErrorAction Stop
            $row.Result = 'OK'; $row.Time = (Get-Date).ToString('s'); $ok++
            $row | Select-Object Depth, Type, OriginalPath, OriginalName, NewName, Result, Time | Export-Csv -LiteralPath $undo -NoTypeInformation -Encoding UTF8 -Append
            Write-Verbose ('Renamed: {0} -> {1}' -f $path, $r.NewName)
        } catch {
            $row.Result = 'ERROR: ' + $_.Exception.Message; $failed++
            Write-Verbose ('Failed: {0}: {1}' -f $path, $_.Exception.Message)
        }
        $results.Add($row)
        if ($OnProgress) { & $OnProgress $n $sel.Count }
    }
    $results | Export-Csv -LiteralPath (Join-Path $ReportFolder 'renames.csv') -NoTypeInformation -Encoding UTF8
    $run.finished = (Get-Date).ToString('s'); $run.renamed = $ok; $run.failed = $failed
    $run | ConvertTo-Json | Set-Content -LiteralPath $runFile -Encoding UTF8

    # Verify against the disk: re-read everything rather than trust Rename-Item.
    $inv = Get-PathShrinkInventory -Library $Plan.Library
    $prefixLen = $Plan.Library.Prefix.Length
    $still = @($inv.Items | Where-Object { $prefixLen + $_.Rel.Length -gt $Plan.Target } | ForEach-Object {
        New-Object psobject -Property @{ Rel = $_.Rel; Length = $prefixLen + $_.Rel.Length } })
    $fixed = @($Plan.Paths | Where-Object { $_.Status -eq 'Fixed' })
    $exist = @($fixed | Where-Object { Test-Path -LiteralPath (ConvertTo-LongPath (Join-Path $base $_.NewRel)) })
    New-Object psobject -Property @{
        Renamed = $ok; Failed = $failed; Results = $results
        UndoFile = $(if ($ok) { $undo } else { $null }); ReportFolder = $ReportFolder
        StillLong = $still; StillOverLimit = @($still | Where-Object { $_.Length -gt $Plan.Limit }).Count
        VerifiedFixed = $exist.Count; ExpectedFixed = $fixed.Count
    }
}

function Resolve-UndoPath([hashtable]$Now, [string]$Path) {
    # Where an original path is now: its nearest renamed ancestor is looked up in $Now
    # (original path -> path on disk), the rest of the path is appended unchanged.
    $cur = $Path; $tail = ''
    while ($cur) {
        if ($Now.ContainsKey($cur)) { return $Now[$cur] + $tail }
        $leaf = Split-Path $cur -Leaf
        $up = Split-Path $cur -Parent
        if (-not $up -or $up -eq $cur) { break }
        $tail = '\' + $leaf + $tail; $cur = $up
    }
    $Path
}

function Get-UndoRowState($Row, [hashtable]$Now, [hashtable]$States) {
    $parentOrig = Split-Path $Row.OriginalPath -Parent
    $parent = Resolve-UndoPath $Now $parentOrig
    $current = Join-Path $parent $Row.NewName
    $restore = Join-Path $parent $Row.OriginalName
    $isNow = Test-Path -LiteralPath (ConvertTo-LongPath $current)
    $isOld = Test-Path -LiteralPath (ConvertTo-LongPath $restore)
    $blockedParent = $false
    $p = $parentOrig
    while ($p -and -not $blockedParent) {
        if ($States.ContainsKey($p) -and $States[$p] -in 'Missing', 'Conflict', 'ParentMissing', 'TypeChanged') { $blockedParent = $true }
        $up = Split-Path $p -Parent; if ($up -eq $p) { break }; $p = $up
    }
    $status = 'Ready'
    if ($isNow -and $isOld) { $status = 'Conflict' }
    elseif ($isOld) { $status = 'Restored' }
    elseif (-not $isNow) { $status = $(if ($blockedParent) { 'ParentMissing' } else { 'Missing' }) }
    elseif ([bool]($Row.Type -eq 'Folder') -ne (Test-Path -LiteralPath (ConvertTo-LongPath $current) -PathType Container)) { $status = 'TypeChanged' }
    [pscustomobject]@{ Row = $Row; Status = $status; CurrentPath = $current; RestorePath = $restore }
}

function Test-PathShrinkUndo {
    <#
    .SYNOPSIS
        Checks, without changing anything, which renames of an undo.csv can be reverted safely.
    .DESCRIPTION
        For every rename in the file, looks at the disk now:
          Ready         the item is where PathShrink left it and its old name is free
          Restored      it already has its original name again
          Conflict      it is there, but something else now uses the original name
          Missing       it is no longer where PathShrink left it (moved, renamed or deleted since)
          ParentMissing a folder above it is Missing or blocked, so it cannot be found
          TypeChanged   a file where a folder was renamed, or the other way round
        Only Ready items are restored by Undo-PathShrink. Nothing is ever overwritten.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UndoFile)
    $rows = @(Import-Csv -LiteralPath $UndoFile | Where-Object { $_.Result -eq 'OK' } | Sort-Object { [int]$_.Depth }, OriginalPath)
    $now = @{}; $states = @{}
    $items = foreach ($r in $rows) {
        $s = Get-UndoRowState $r $now $states
        $states[$r.OriginalPath] = $s.Status
        $now[$r.OriginalPath] = $(if ($s.Status -eq 'Restored') { $s.RestorePath } else { $s.CurrentPath })
        [pscustomobject]@{
            Type = $r.Type; OriginalPath = $r.OriginalPath; OriginalName = $r.OriginalName; NewName = $r.NewName
            Renamed = $(if ($r.PSObject.Properties.Name -contains 'Time') { $r.Time } else { '' })
            CurrentPath = $s.CurrentPath; Status = $s.Status
        }
    }
    $items = @($items)
    New-Object psobject -Property ([ordered]@{
        UndoFile = $UndoFile
        Total    = $items.Count
        Ready    = @($items | Where-Object { $_.Status -eq 'Ready' }).Count
        Restored = @($items | Where-Object { $_.Status -eq 'Restored' }).Count
        Blocked  = @($items | Where-Object { $_.Status -notin 'Ready', 'Restored' }).Count
        Items    = $items
    })
}

function Undo-PathShrink {
    <#
    .SYNOPSIS
        Restores the original names listed in an undo.csv written by Invoke-PathShrinkPlan.
    .DESCRIPTION
        Checks every item first (see Test-PathShrinkUndo) and restores only those that are
        still where PathShrink left them and whose original name is free. Anything moved,
        renamed again, replaced or deleted since is skipped and reported, never overwritten.
        Restores outermost first, so each child is found under its already restored parent.
        The outcome is appended to restore.csv next to the undo file.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$UndoFile)
    $rows = @(Import-Csv -LiteralPath $UndoFile | Where-Object { $_.Result -eq 'OK' } | Sort-Object { [int]$_.Depth }, OriginalPath)
    if (-not $rows.Count) { Write-Verbose 'The undo file lists no renames.'; return }
    if (-not $PSCmdlet.ShouldProcess(('{0} items' -f $rows.Count), 'Restore original names')) { return }
    $ok = 0; $failed = 0; $skipped = 0; $already = 0
    $now = @{}; $states = @{}
    $results = foreach ($f in $rows) {
        $s = Get-UndoRowState $f $now $states
        $res = $s.Status
        $where = $s.CurrentPath
        if ($s.Status -eq 'Ready') {
            try {
                Rename-Item -LiteralPath (ConvertTo-LongPath $s.CurrentPath) -NewName $f.OriginalName -ErrorAction Stop
                $res = 'OK'; $ok++; $where = $s.RestorePath
            } catch { $res = 'ERROR: ' + $_.Exception.Message; $failed++ }
        } elseif ($s.Status -eq 'Restored') { $already++; $where = $s.RestorePath }
        else { $skipped++ }
        $states[$f.OriginalPath] = $(if ($res -eq 'OK') { 'Restored' } elseif ($res -like 'ERROR*') { 'Conflict' } else { $s.Status })
        $now[$f.OriginalPath] = $where
        Write-Verbose ('Undo {0}: {1}' -f $res, $s.CurrentPath)
        [pscustomobject]@{ Time = (Get-Date).ToString('s'); Path = $s.CurrentPath; RestoredName = $f.OriginalName; Result = $res }
    }
    $results = @($results)
    try { $results | Export-Csv -LiteralPath (Join-Path (Split-Path $UndoFile -Parent) 'restore.csv') -NoTypeInformation -Encoding UTF8 -Append -WhatIf:$false }
    catch { Write-Verbose ('restore.csv not written: {0}' -f $_.Exception.Message) }
    New-Object psobject -Property @{ Restored = $ok; Failed = $failed; Skipped = $skipped; AlreadyRestored = $already; Results = $results }
}

function Get-PathShrinkHistory {
    <#
    .SYNOPSIS
        Lists the runs that renamed something (folders with an undo.csv), newest first, and whether they were reverted.
    .PARAMETER Folder
        Reports folder to read. Default: %LOCALAPPDATA%\PathShrink\Reports.
    #>
    [CmdletBinding()]
    param([string]$Folder = (Join-Path $env:LOCALAPPDATA 'PathShrink\Reports'))
    if (-not (Test-Path -LiteralPath $Folder)) { return }
    $runs = foreach ($d in @(Get-ChildItem -LiteralPath $Folder -Directory -ErrorAction SilentlyContinue)) {
        $undo = Join-Path $d.FullName 'undo.csv'
        if (-not (Test-Path -LiteralPath $undo)) { continue }
        $info = $null
        try { $info = Get-Content -LiteralPath (Join-Path $d.FullName 'run.json') -Raw -ErrorAction Stop | ConvertFrom-Json } catch { Write-Verbose ('No run.json in {0}' -f $d.FullName) }
        $rows = @(Import-Csv -LiteralPath $undo | Where-Object { $_.Result -eq 'OK' })
        $when = $d.CreationTime
        if ($info -and $info.started) { try { $when = [datetime]::Parse($info.started, [Globalization.CultureInfo]::InvariantCulture) } catch { Write-Verbose 'Bad start time' } }
        $restore = Join-Path $d.FullName 'restore.csv'
        $restoredAt = $null; $restoredCount = 0
        if (Test-Path -LiteralPath $restore) {
            $rr = @(Import-Csv -LiteralPath $restore)
            $restoredCount = @($rr | Where-Object { $_.Result -eq 'OK' }).Count
            $restoredAt = (Get-Item -LiteralPath $restore).LastWriteTime
        }
        $folderPath = $(if ($info -and $info.folder) { [string]$info.folder } elseif ($rows.Count) { Split-Path ($rows | Sort-Object { [int]$_.Depth } | Select-Object -First 1).OriginalPath -Parent } else { '' })
        New-Object psobject -Property ([ordered]@{
            Time = $when; Folder = $folderPath; Renamed = $rows.Count
            Failed = $(if ($info) { [int]$info.failed } else { 0 })
            RestoredAt = $restoredAt; RestoredCount = $restoredCount
            UndoFile = $undo; ReportFolder = $d.FullName
        })
    }
    @($runs) | Sort-Object Time -Descending
}

# --------------------------------------------------------------------------------------
# Other sync blockers (report only)
# --------------------------------------------------------------------------------------
$script:BadChars = [char[]]'"*:<>?/\|'
$script:DeviceNames = @('CON', 'PRN', 'AUX', 'NUL') + (0..9 | ForEach-Object { 'COM' + $_; 'LPT' + $_ })

function Find-PathShrinkSyncIssue {
    <#
    .SYNOPSIS
        Reports names that OneDrive or SharePoint refuse to sync for reasons other than length. Changes nothing.
    .DESCRIPTION
        Checks: characters not allowed, leading or trailing spaces, reserved names (.lock,
        CON, PRN, AUX, NUL, COM0-9, LPT0-9), names containing _vti_, names starting with ~$,
        and single names over 255 characters. desktop.ini is not reported: OneDrive skips it
        on purpose.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Inventory)
    foreach ($it in $Inventory.Items) {
        $n = $it.Name
        $issues = New-Object System.Collections.Generic.List[string]
        if ($n.IndexOfAny($script:BadChars) -ge 0) { $issues.Add('character not allowed') }
        if ($n -ne $n.Trim()) { $issues.Add('leading or trailing space') }
        $stem = $n; $dot = $n.IndexOf('.'); if ($dot -gt 0) { $stem = $n.Substring(0, $dot) }
        if ($n -eq '.lock' -or $script:DeviceNames -contains $stem) { $issues.Add('reserved name') }
        if ($n -like '*_vti_*') { $issues.Add('contains _vti_') }
        if ($n.StartsWith('~$')) { $issues.Add('Office lock file (~$)') }
        if ($n.Length -gt 255) { $issues.Add('name over 255 characters') }
        if ($issues.Count) {
            New-Object psobject -Property @{ Rel = $it.Rel; Name = $n; Type = $(if ($it.IsFolder) { 'Folder' } else { 'File' }); Issue = ($issues -join ', ') }
        }
    }
}

# --------------------------------------------------------------------------------------
# Reports
# --------------------------------------------------------------------------------------
function Export-PathShrinkReport {
    <#
    .SYNOPSIS
        Writes the plan to a folder: paths.csv, renames.csv (planned), summary.json and report.html.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [string]$Folder,
        [object[]]$SyncIssues = @()
    )
    if (-not $Folder) { $Folder = Get-PathShrinkReportFolder }
    elseif (-not (Test-Path -LiteralPath $Folder)) { New-Item -ItemType Directory -Path $Folder -Force -WhatIf:$false | Out-Null }
    $s = Get-PathShrinkSummary -Plan $Plan
    $Plan.Paths | Select-Object Status, Before, After, Saved, Type, Rel, NewRel |
        Export-Csv -LiteralPath (Join-Path $Folder 'paths.csv') -NoTypeInformation -Encoding UTF8 -WhatIf:$false
    $Plan.Renames | Select-Object Id, Selected, Type, Depth, Saved, Affects, Method, Rel, OriginalName, NewName |
        Export-Csv -LiteralPath (Join-Path $Folder 'planned-renames.csv') -NoTypeInformation -Encoding UTF8 -WhatIf:$false
    if ($SyncIssues.Count) { $SyncIssues | Select-Object Issue, Type, Rel | Export-Csv -LiteralPath (Join-Path $Folder 'sync-issues.csv') -NoTypeInformation -Encoding UTF8 -WhatIf:$false }
    $meta = [ordered]@{
        tool = 'PathShrink'; version = (Get-PathShrinkVersion); created = (Get-Date).ToString('s')
        folder = $Plan.Library.Path; library = $Plan.Library.Base; kind = $Plan.Library.Kind
        serverPrefixLength = $Plan.Library.Prefix.Length; prefixSource = $Plan.Library.PrefixSource
        limit = $Plan.Limit; margin = $Plan.Margin; target = $Plan.Target; allowTrim = $Plan.AllowTrim
        summary = $s
    }
    $meta | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Folder 'summary.json') -Encoding UTF8 -WhatIf:$false
    $enc = { param($t) [Net.WebUtility]::HtmlEncode([string]$t) }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('<!doctype html><html><head><meta charset="utf-8"><title>PathShrink report</title><style>')
    [void]$sb.Append('body{font:14px Segoe UI,sans-serif;background:#161618;color:#e6e6e8;margin:24px}h1{color:#c9a96e;font-weight:300}')
    [void]$sb.Append('table{border-collapse:collapse;width:100%;margin:12px 0 28px}td,th{border-bottom:1px solid #333;padding:4px 8px;text-align:left;vertical-align:top}')
    [void]$sb.Append('th{color:#c9a96e;font-weight:600}.n{text-align:right}.Fixed{color:#7fc97f}.NoMargin{color:#e0c060}.TooLong{color:#ff7b72}code{color:#bbb;word-break:break-all}del{color:#ff9b92;text-decoration:line-through}mark{background:#3a3020;color:#e2c48a}</style></head><body>')
    [void]$sb.Append(('<h1>PathShrink report</h1><p>Folder: <code>{0}</code><br>Server prefix: {1} characters ({2})<br>Limit {3}, target {4}. Scanned {5} items, {6} long paths, {7} fixed by the plan, {8} renames.</p>' -f (& $enc $Plan.Library.Path), $Plan.Library.Prefix.Length, (& $enc $Plan.Library.PrefixSource), $Plan.Limit, $Plan.Target, $s.Items, $s.LongPaths, $s.Fixed, $s.Renames))
    [void]$sb.Append('<h2>Renames</h2><table><tr><th>Type</th><th class="n">Saved</th><th class="n">Items</th><th>Folder</th><th>Current name</th><th>New name</th></tr>')
    foreach ($r in ($Plan.Renames | Where-Object { $_.Selected })) { [void]$sb.Append(('<tr><td>{0}</td><td class="n">{1}</td><td class="n">{2}</td><td><code>{3}</code></td><td>{4}</td><td>{5}</td></tr>' -f $r.Type, $r.Saved, $r.Affects, (& $enc $r.Parent), (& $enc $r.OriginalName), (& $enc $r.NewName))) }
    [void]$sb.Append('</table><h2>Long paths</h2><p>Changed names are highlighted; everything else in the path stays as it is.</p><table><tr><th>Status</th><th class="n">Before</th><th class="n">After</th><th>Path before / after</th></tr>')
    foreach ($p in $Plan.Paths) {
        $a = $p.Rel.Split('\'); $b = $p.NewRel.Split('\')
        $old = @(for ($i = 0; $i -lt $a.Count; $i++) { if ($a[$i] -cne $b[$i]) { '<del>' + (& $enc $a[$i]) + '</del>' } else { & $enc $a[$i] } }) -join '\'
        $new = @(for ($i = 0; $i -lt $b.Count; $i++) { if ($a[$i] -cne $b[$i]) { '<mark>' + (& $enc $b[$i]) + '</mark>' } else { & $enc $b[$i] } }) -join '\'
        $after = $(if ($p.NewRel -ceq $p.Rel) { '' } else { '<br><code>' + $new + '</code>' })
        [void]$sb.Append(('<tr><td class="{0}">{0}</td><td class="n">{1}</td><td class="n">{2}</td><td><code>{3}</code>{4}</td></tr>' -f $p.Status, $p.Before, $p.After, $old, $after))
    }
    [void]$sb.Append('</table></body></html>')
    [IO.File]::WriteAllText((Join-Path $Folder 'report.html'), $sb.ToString(), (New-Object Text.UTF8Encoding $true))
    $Folder
}

function Get-PathShrinkVersion { [string]$ExecutionContext.SessionState.Module.Version }

function Get-PathShrinkEnvironment {
    <#
    .SYNOPSIS
        Facts that explain how PathShrink will behave on this machine (PowerShell edition, language mode, long paths, OneDrive).
    #>
    [CmdletBinding()]
    param()
    $lp = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -ErrorAction SilentlyContinue
    $lpOn = $false; if ($lp -and ($lp.PSObject.Properties.Name -contains 'LongPathsEnabled')) { $lpOn = $lp.LongPathsEnabled -eq 1 }
    $admin = $false
    try { $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { Write-Verbose 'Elevation check failed' }
    New-Object psobject -Property ([ordered]@{
        PathShrink        = Get-PathShrinkVersion
        PowerShell        = $PSVersionTable.PSVersion.ToString()
        Edition           = $(if ($PSVersionTable.PSObject.Properties.Name -contains 'PSEdition') { $PSVersionTable.PSEdition } else { 'Desktop' })
        LanguageMode      = $ExecutionContext.SessionState.LanguageMode.ToString()
        OS                = [Environment]::OSVersion.VersionString
        Elevated          = $admin
        LongPathsEnabled  = $lpOn
        OneDriveAccounts  = @(Get-PathShrinkAccount).Count
        SyncedLibraries   = @(Get-PathShrinkSyncMount).Count
        OneDriveRunning   = [bool](Get-Process OneDrive -ErrorAction SilentlyContinue)
    })
}

# --------------------------------------------------------------------------------------
# One-shot command line
# --------------------------------------------------------------------------------------
function Invoke-PathShrink {
    <#
    .SYNOPSIS
        Finds OneDrive and SharePoint paths over the 400-character limit and shortens them, from the command line.
    .DESCRIPTION
        Scans, plans, prints the planned renames and asks for confirmation before renaming
        (-WhatIf shows the plan and changes nothing; -Confirm:$false applies without asking).
        Writes reports and undo.csv under %LOCALAPPDATA%\PathShrink\Reports.
        Run it as the user who owns the OneDrive, without elevation.
    .EXAMPLE
        Invoke-PathShrink -WhatIf
        Scans the OneDrive of the current user and shows what would change.
    .EXAMPLE
        Invoke-PathShrink -Path "$env:OneDriveCommercial\Clients" -AllowTrim
    .EXAMPLE
        Invoke-PathShrink -Root D:\Export\Legal -Prefix "sites/Legal/Shared Documents/" -WhatIf
    .EXAMPLE
        Undo-PathShrink -UndoFile "$env:LOCALAPPDATA\PathShrink\Reports\20261024-101500-000\undo.csv"
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [string]$Path,
        [string]$Upn,
        [string]$Root,
        [string]$Prefix,
        [ValidateRange(50, 400)][int]$Limit = 400,
        [ValidateRange(0, 200)][int]$Margin = 20,
        [switch]$AllowTrim,
        [ValidateRange(3, 200)][int]$MinNameLength = 20,
        [string[]]$Exclude = @(),
        [string[]]$Protect = @(),
        [string]$ReportFolder,
        [switch]$PassThru
    )
    $libArgs = @{}
    foreach ($k in 'Path', 'Upn', 'Root', 'Prefix') { if ($PSBoundParameters.ContainsKey($k)) { $libArgs[$k] = $PSBoundParameters[$k] } }
    $lib = Get-PathShrinkLibrary @libArgs
    Write-Host ('Scanning {0} ...' -f $lib.Path) -ForegroundColor Cyan
    $inv = Get-PathShrinkInventory -Library $lib -Exclude $Exclude
    $plan = New-PathShrinkPlan -Inventory $inv -Limit $Limit -Margin $Margin -AllowTrim:$AllowTrim -MinNameLength $MinNameLength -Protect $Protect
    $s = Get-PathShrinkSummary -Plan $plan
    $folder = Export-PathShrinkReport -Plan $plan -Folder $ReportFolder -SyncIssues @(Find-PathShrinkSyncIssue -Inventory $inv)

    Write-Host ''
    Write-Host ('Library       : {0} ({1})' -f $lib.Base, $lib.Kind)
    Write-Host ('Server prefix : {0} characters ({1})' -f $lib.Prefix.Length, $lib.PrefixSource)
    Write-Host ('Items         : {0} read, {1} unreadable' -f $s.Items, $s.Unreadable)
    Write-Host ('Long paths    : {0} above {1} ({2} above the {3} limit)' -f $s.LongPaths, $plan.Target, $s.OverLimit, $Limit)
    Write-Host ('Plan          : {0} renames ({1} folders, {2} files) fix {3}; {4} without margin; {5} still too long' -f $s.Renames, $s.Folders, $s.Files, $s.Fixed, $s.NoMargin, $s.TooLong)
    Write-Host ('Reports       : {0}' -f $folder)
    if ($plan.Renames.Count) {
        $plan.Renames | Sort-Object Rel | Select-Object -First 25 | Format-Table @{ n = 'Saved'; e = { $_.Saved } }, @{ n = 'Items'; e = { $_.Affects } }, Method, OriginalName, NewName,
            @{ n = 'Folder'; e = { if ($_.Parent) { $_.Parent } else { '(root)' } } } -Wrap | Out-Host
        if ($plan.Renames.Count -gt 25) { Write-Host ('... and {0} more: see planned-renames.csv in the reports folder.' -f ($plan.Renames.Count - 25)) }
    }
    if ($s.TooLong -and -not $AllowTrim) { Write-Host 'Some paths only fit by removing letters: run again with -AllowTrim to see that plan.' -ForegroundColor Yellow }
    if (-not $plan.Renames.Count) {
        Write-Host $(if ($s.LongPaths) { 'No automatic change is possible.' } else { 'Nothing to change.' }) -ForegroundColor Green
        if ($PassThru) { return $plan }
        return
    }
    if ($PSCmdlet.ShouldProcess(('{0} items in {1}. Shortcuts and links to renamed folders stop working.' -f $s.Renames, $lib.Path), 'Rename')) {
        $res = Invoke-PathShrinkPlan -Plan $plan -ReportFolder $folder -Confirm:$false
        Write-Host ''
        Write-Host ('Renamed {0}, failed {1}. Verified on disk: {2} of {3} fixed paths. Still above {4}: {5}.' -f $res.Renamed, $res.Failed, $res.VerifiedFixed, $res.ExpectedFixed, $plan.Target, $res.StillLong.Count) -ForegroundColor $(if ($res.Failed -or $res.StillOverLimit) { 'Yellow' } else { 'Green' })
        if ($res.UndoFile) { Write-Host ('Undo: Undo-PathShrink -UndoFile "{0}"' -f $res.UndoFile) }
        if ($PassThru) { return $res }
    } elseif ($PassThru) { return $plan }
}

function Start-PathShrink {
    <#
    .SYNOPSIS
        Opens the PathShrink window.
    .PARAMETER ReportRoot
        Where runs keep their reports and undo records. Default: %LOCALAPPDATA%\PathShrink\Reports.
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        [switch]$Pro,
        [string]$Root,
        [string]$Upn,
        [string]$Prefix,
        [ValidateSet('en', 'es', 'pt')][string]$Language,
        [string]$ReportRoot
    )
    . (Join-Path $script:ModuleRoot 'gui\Gui.ps1')
    $a = @{} + $PSBoundParameters
    do {
        # Changing the language rebuilds the window; it reopens on the same folder and mode.
        $next = Show-PathShrinkWindow @a
        if ($next) { $a.Language = $next.Language; $a.Pro = [switch]$next.Pro; if ($next.Path) { $a.Path = $next.Path } }
    } while ($next)
}

Export-ModuleMember -Function Get-PathShrinkLibrary, Get-PathShrinkAccount, Get-PathShrinkSyncMount, Get-PathShrinkInventory,
    New-PathShrinkPlan, Update-PathShrinkPlan, Test-PathShrinkRename, Set-PathShrinkRename, Get-PathShrinkSummary, Invoke-PathShrinkPlan, Undo-PathShrink, Test-PathShrinkUndo, Get-PathShrinkHistory,
    Find-PathShrinkSyncIssue, Export-PathShrinkReport, Get-PathShrinkEnvironment, Invoke-PathShrink, Start-PathShrink
