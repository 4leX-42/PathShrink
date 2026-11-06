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

function Get-PathShrinkLocalLength {
    <#
    .SYNOPSIS
        Measures the paths as Windows sees them on this PC, and the server limit that matches a local limit.
    .DESCRIPTION
        The plan works with server lengths: prefix + path inside the library. Windows and most
        programs fail on the full local path, which also counts the local OneDrive folder and the
        name of the shortcut, so a path can fit the server limit and still fail on this PC.
    .PARAMETER Inventory
        Output of Get-PathShrinkInventory.
    .PARAMETER LocalLimit
        Longest local path that should work. 259 is the classic Windows limit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Inventory,
        [ValidateRange(50, 400)][int]$LocalLimit = 259
    )
    $lib = $Inventory.Library
    $baseLen = $lib.Base.Length + 1
    $over = 0; $longest = 0
    foreach ($it in $Inventory.Items) {
        $len = $baseLen + $it.Rel.Length
        if ($len -gt $LocalLimit) { $over++ }
        if ($len -gt $longest) { $longest = $len }
    }
    $offset = $baseLen - $lib.Prefix.Length
    New-Object psobject -Property ([ordered]@{
        LocalLimit  = $LocalLimit
        OverLimit   = $over
        Longest     = $longest
        Offset      = $offset
        ServerLimit = $LocalLimit - $offset
    })
}

function Get-PathShrinkShortcut {
    <#
    .SYNOPSIS
        Measures the shortcuts to other libraries that a scan of this folder leaves out. Read only.
    .DESCRIPTION
        A shortcut has another server path, so a scan of the folder above it skips it. Its deep paths
        are still on this PC: without this, a plain run says there is nothing to change while OneDrive
        and Windows fail on them. Only what is on disk is measured: an item that OneDrive never
        brought to this PC does not appear.
    .PARAMETER Library
        Output of Get-PathShrinkLibrary.
    .PARAMETER LocalLimit
        Longest local path that should work.
    .PARAMETER Limit
        Server limit.
    .PARAMETER Exclude
        Patterns of folders or files that are not measured.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Library,
        [ValidateRange(50, 400)][int]$LocalLimit = 259,
        [ValidateRange(50, 400)][int]$Limit = 400,
        [string[]]$Exclude = @()
    )
    foreach ($path in @($Library.SkipPaths)) {
        if (-not [IO.Directory]::Exists((ConvertTo-LongPath $path))) { continue }
        $row = [ordered]@{ Path = $path; Items = 0; OverLocal = 0; LongestLocal = 0; OverServer = 0; LongestServer = 0; Error = $null }
        try {
            $inv = Get-PathShrinkInventory -Library (Get-PathShrinkLibrary -Path $path) -Exclude $Exclude
            $m = Get-PathShrinkLocalLength -Inventory $inv -LocalLimit $LocalLimit
            $row.Items = $inv.Items.Count
            $row.OverLocal = $m.OverLimit
            $row.LongestLocal = $m.Longest
            $pre = $inv.Library.Prefix.Length
            foreach ($it in $inv.Items) {
                $len = $pre + $it.Rel.Length
                if ($len -gt $Limit) { $row.OverServer++ }
                if ($len -gt $row.LongestServer) { $row.LongestServer = $len }
            }
        } catch { $row.Error = $_.Exception.Message }
        New-Object psobject -Property $row
    }
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
# Items that cannot be renamed: which program holds them open, and closing it
# --------------------------------------------------------------------------------------
# Restart Manager (rstrtmgr.dll, Windows Vista and later) is the API installers use to
# find which processes have a file open. C# 5 so the compiler of .NET Framework 4 builds it.
$script:RmSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
namespace PathShrinkNative {
    public class Locker {
        public int Id; public string Title; public string Service; public int AppType; public bool Restartable;
    }
    public static class RestartManager {
        [StructLayout(LayoutKind.Sequential)]
        struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct RM_PROCESS_INFO {
            public RM_UNIQUE_PROCESS Process;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string strServiceShortName;
            public int ApplicationType; public uint AppStatus; public uint TSSessionId;
            [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
        }
        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmStartSession(out uint handle, int flags, StringBuilder key);
        [DllImport("rstrtmgr.dll")] static extern int RmEndSession(uint handle);
        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmRegisterResources(uint handle, uint nFiles, string[] files, uint nApps, IntPtr apps, uint nServices, string[] services);
        [DllImport("rstrtmgr.dll")] static extern int RmGetList(uint handle, out uint needed, ref uint count, [In, Out] RM_PROCESS_INFO[] info, ref uint reasons);
        public static List<Locker> Find(string[] files) {
            List<Locker> list = new List<Locker>();
            if (files == null || files.Length == 0) { return list; }
            uint h; StringBuilder key = new StringBuilder(64);
            if (RmStartSession(out h, 0, key) != 0) { return list; }
            try {
                if (RmRegisterResources(h, (uint)files.Length, files, 0, IntPtr.Zero, 0, null) != 0) { return list; }
                uint needed = 0, count = 0, reasons = 0;
                int r = RmGetList(h, out needed, ref count, null, ref reasons);
                if (r == 234 && needed > 0) {
                    RM_PROCESS_INFO[] info = new RM_PROCESS_INFO[needed + 8];
                    count = (uint)info.Length;
                    r = RmGetList(h, out needed, ref count, info, ref reasons);
                    if (r == 0) {
                        for (int i = 0; i < count; i++) {
                            Locker l = new Locker();
                            l.Id = info[i].Process.dwProcessId; l.Title = info[i].strAppName; l.Service = info[i].strServiceShortName;
                            l.AppType = info[i].ApplicationType; l.Restartable = info[i].bRestartable;
                            list.Add(l);
                        }
                    }
                }
            } finally { RmEndSession(h); }
            return list;
        }
    }
}
'@

function Get-PathShrinkLock {
    <#
    .SYNOPSIS
        Lists the programs that have a file open in the given files or folders (Restart Manager).
    .DESCRIPTION
        A folder cannot be renamed while a program has a file inside it open, so for a folder
        the files under it are checked (up to -MaxFiles). Each program is returned once with
        Kind: App (has a window, can be asked to close), Background, Service, Explorer or
        System. CanClose is true only for App and Background: PathShrink never stops a
        service, Windows itself or File Explorer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Path,
        [int]$MaxFiles = 2000
    )
    if (-not ('PathShrinkNative.RestartManager' -as [type])) { Add-Type -TypeDefinition $script:RmSource -Language CSharp }
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($p in $Path) {
        $lp = ConvertTo-LongPath $p
        if (Test-Path -LiteralPath $lp -PathType Leaf) { $files.Add((ConvertFrom-LongPath $p)); continue }
        if (-not (Test-Path -LiteralPath $lp -PathType Container)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $lp -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            if ($files.Count -ge $MaxFiles) { break }
            $files.Add((ConvertFrom-LongPath $f.FullName))
        }
    }
    if (-not $files.Count) { return }
    # Restart Manager finds nothing for a path of 260 characters or more, which is every path
    # this tool is about. Those files are looked up through a chain of short junctions in TEMP
    # that point at their folder (each junction target stays short), removed right after.
    $junctions = New-Object System.Collections.Generic.List[string]
    $alias = @{}
    $jroot = Join-Path ([IO.Path]::GetTempPath()) ('psrm' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $names = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($f in $files) {
            if ($f.Length -lt 250) { $names.Add($f); continue }
            $dir = Split-Path $f -Parent
            if (-not $alias.ContainsKey($dir)) {
                $segs = $dir.Split('\')
                $cur = $segs[0]
                for ($i = 1; $i -lt $segs.Length; $i++) {
                    if (($cur.Length + 1 + $segs[$i].Length) -ge 200) {
                        if (-not $junctions.Count) { [void][IO.Directory]::CreateDirectory($jroot) }
                        $j = Join-Path $jroot ([string]$junctions.Count)
                        New-Item -ItemType Junction -Path $j -Target $cur -ErrorAction Stop | Out-Null
                        $junctions.Add($j); $cur = $j
                    }
                    $cur = $cur + '\' + $segs[$i]
                }
                # A last junction to the folder itself leaves room for the file name.
                if (-not $junctions.Count) { [void][IO.Directory]::CreateDirectory($jroot) }
                $j = Join-Path $jroot ([string]$junctions.Count)
                New-Item -ItemType Junction -Path $j -Target $cur -ErrorAction Stop | Out-Null
                $junctions.Add($j)
                $alias[$dir] = $j
            }
            $names.Add((Join-Path $alias[$dir] (Split-Path $f -Leaf)))
        }
        $found = [PathShrinkNative.RestartManager]::Find($names.ToArray())
    } catch {
        Write-Verbose ('Lock check failed: {0}' -f $_.Exception.Message)
        $found = @()
    } finally {
        # Deleting a junction (not recursive) removes only the link, never what it points at.
        for ($i = $junctions.Count - 1; $i -ge 0; $i--) { try { [IO.Directory]::Delete($junctions[$i], $false) } catch { Write-Verbose ('Junction not removed: {0}' -f $junctions[$i]) } }
        if ($junctions.Count) { try { [IO.Directory]::Delete($jroot, $false) } catch { Write-Verbose ('Folder not removed: {0}' -f $jroot) } }
    }
    $seen = @{}
    foreach ($l in $found) {
        if ($l.Id -eq $PID -or $seen.ContainsKey($l.Id)) { continue }
        $seen[$l.Id] = $true
        $proc = Get-Process -Id $l.Id -ErrorAction SilentlyContinue
        $kind = switch ($l.AppType) { 1 { 'App' } 2 { 'App' } 3 { 'Service' } 4 { 'Explorer' } 1000 { 'System' } default { 'Background' } }
        if ($kind -eq 'App' -and $proc -and $proc.MainWindowHandle -eq [IntPtr]::Zero) { $kind = 'Background' }
        [pscustomobject]@{
            Id = $l.Id; Name = $(if ($proc) { $proc.ProcessName } else { '' }); Title = $l.Title; Service = $l.Service
            Kind = $kind; CanClose = [bool]($kind -in 'App', 'Background')
        }
    }
}

function Stop-PathShrinkLock {
    <#
    .SYNOPSIS
        Closes the programs returned by Get-PathShrinkLock so the items they hold can be renamed.
    .DESCRIPTION
        Without -Force each program is asked to close as if the user closed its window, so it
        can still offer to save changes, and PathShrink waits up to -TimeoutSeconds. With -Force
        the programs that are still open after that are ended, and unsaved changes in them are
        lost. Services, Windows processes and File Explorer are never closed.
        Returns one line per program with Closed true or false.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][psobject[]]$Lock,
        [switch]$Force,
        [int]$TimeoutSeconds = 15
    )
    $todo = @($Lock | Where-Object { $_.CanClose -and $_.Id -ne $PID })
    $procs = @()
    foreach ($l in $todo) {
        $p = Get-Process -Id $l.Id -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        if (-not $PSCmdlet.ShouldProcess(('{0} ({1})' -f $p.ProcessName, $p.Id), $(if ($Force) { 'Close, end if it does not close' } else { 'Close' }))) { continue }
        try { if (-not $p.CloseMainWindow() -and $Force) { $p.Kill() } } catch { Write-Verbose ('Close {0}: {1}' -f $p.Id, $_.Exception.Message) }
        $procs += $p
    }
    $until = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $until -and @($procs | Where-Object { -not $_.HasExited }).Count) { Start-Sleep -Milliseconds 250 }
    if ($Force) {
        foreach ($p in $procs) { if (-not $p.HasExited) { try { $p.Kill(); [void]$p.WaitForExit(5000) } catch { Write-Verbose ('End {0}: {1}' -f $p.Id, $_.Exception.Message) } } }
    }
    foreach ($l in $Lock) {
        $p = $null; foreach ($x in $procs) { if ($x.Id -eq $l.Id) { $p = $x } }
        $closed = $(if ($p) { [bool]$p.HasExited } else { -not (Get-Process -Id $l.Id -ErrorAction SilentlyContinue) })
        Write-Verbose ('{0} {1} ({2})' -f $(if ($closed) { 'Closed' } else { 'Still open' }), $l.Name, $l.Id)
        [pscustomobject]@{ Id = $l.Id; Name = $l.Name; Title = $l.Title; Kind = $l.Kind; CanClose = $l.CanClose; Closed = $closed }
    }
}

function Test-PathShrinkElevated {
    try { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    catch { $false }
}

function Get-RenameFailReason($Err) {
    # InUse: a sharing or lock violation; Denied: no permission (for a folder this is also what
    # Windows says when a file inside it is open, so the caller checks for programs as well).
    # Windows PowerShell 5.1 reports a folder that cannot be renamed as a plain IOException
    # (COR_E_IO, 0x80131620) with the "access denied" text in the system language.
    $e = $Err.Exception
    $denied = $false; $inUse = $false
    while ($e) {
        $code = $e.HResult -band 0xFFFF
        if ($e -is [UnauthorizedAccessException] -or $code -eq 5 -or $e.HResult -eq -2146232800) { $denied = $true }
        if ($code -eq 32 -or $code -eq 33 -or $e.Message -match 'used by another process') { $inUse = $true }
        $e = $e.InnerException
    }
    if ($inUse) { 'InUse' } elseif ($denied) { 'Denied' } else { 'Other' }
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
    .PARAMETER Retry
        Run again into the -ReportFolder of an earlier run of the same plan: renames already done
        there are skipped, the ones that failed are tried again where their parent folders are now,
        and undo.csv keeps growing, so one revert still undoes the whole run.
    .OUTPUTS
        Renamed and Failed count the whole run (all tries). Each failed row has Reason (InUse,
        Denied or Other) and LockedBy; Locks lists the programs that hold failed items open.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [string]$ReportFolder,
        [switch]$Retry,
        [scriptblock]$OnProgress
    )
    if ($Retry -and -not $ReportFolder) { throw '-Retry needs the -ReportFolder of the earlier run.' }
    $base = $Plan.Library.Base
    $sel = @($Plan.Renames | Where-Object { $_.Selected } | Sort-Object Depth -Descending)
    $earlier = @()
    $now = @{}
    if ($Retry) {
        $rf = Join-Path $ReportFolder 'renames.csv'
        if (Test-Path -LiteralPath $rf) { $earlier = @(Import-Csv -LiteralPath $rf) }
        $done = @{}; foreach ($e in $earlier) { if ($e.Result -eq 'OK') { $done[$e.OriginalPath] = $true } }
        $sel = @($sel | Where-Object { -not $done.ContainsKey((Join-Path $base $_.Rel)) })
        # Where each renamed item is now, so a retried item is found under its renamed parents.
        $uf = Join-Path $ReportFolder 'undo.csv'
        if (Test-Path -LiteralPath $uf) {
            foreach ($u in @(Import-Csv -LiteralPath $uf | Where-Object { $_.Result -eq 'OK' } | Sort-Object { [int]$_.Depth })) {
                $now[$u.OriginalPath] = Join-Path (Resolve-UndoPath $now (Split-Path $u.OriginalPath -Parent)) $u.NewName
            }
        }
    }
    if (-not $sel.Count) { Write-Verbose 'Nothing selected.'; return }
    if (-not $PSCmdlet.ShouldProcess(('{0} items in {1}' -f $sel.Count, $Plan.Library.Path), 'Rename')) { return }
    if (-not $ReportFolder) { $ReportFolder = Get-PathShrinkReportFolder }
    elseif (-not (Test-Path -LiteralPath $ReportFolder)) { New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null }
    $undo = Join-Path $ReportFolder 'undo.csv'
    # run.json says what this run was, so the history can list it later without the plan.
    $run = [ordered]@{
        tool = 'PathShrink'; version = (Get-PathShrinkVersion); started = (Get-Date).ToString('s'); finished = $null
        folder = $Plan.Library.Path; library = $Plan.Library.Base; prefixLength = $Plan.Library.Prefix.Length
        limit = $Plan.Limit; target = $Plan.Target; allowTrim = $Plan.AllowTrim; selected = $sel.Count; renamed = 0; failed = 0; retries = 0
    }
    $runFile = Join-Path $ReportFolder 'run.json'
    if ($Retry -and (Test-Path -LiteralPath $runFile)) {
        try {
            $old = Get-Content -LiteralPath $runFile -Raw | ConvertFrom-Json
            $run.started = $old.started; $run.selected = $old.selected
            if ($old.PSObject.Properties.Name -contains 'retries') { $run.retries = [int]$old.retries }
        } catch { Write-Verbose ('run.json not read: {0}' -f $_.Exception.Message) }
        $run.retries++
    }
    $run | ConvertTo-Json | Set-Content -LiteralPath $runFile -Encoding UTF8
    $results = New-Object System.Collections.Generic.List[object]
    $locks = @{}; $lockChecks = 0
    $n = 0
    foreach ($r in $sel) {
        $n++
        $path = Join-Path $base $r.Rel
        $cur = Resolve-UndoPath $now $path
        $row = New-Object psobject -Property ([ordered]@{
            Depth = $r.Depth; Type = $r.Type; OriginalPath = $path; OriginalName = $r.OriginalName; NewName = $r.NewName; Result = ''; Time = ''; Reason = ''; LockedBy = '' })
        try {
            Rename-Item -LiteralPath (ConvertTo-LongPath $cur) -NewName $r.NewName -ErrorAction Stop
            $row.Result = 'OK'; $row.Time = (Get-Date).ToString('s')
            $now[$path] = Join-Path (Split-Path $cur -Parent) $r.NewName
            $row | Select-Object Depth, Type, OriginalPath, OriginalName, NewName, Result, Time | Export-Csv -LiteralPath $undo -NoTypeInformation -Encoding UTF8 -Append
            Write-Verbose ('Renamed: {0} -> {1}' -f $cur, $r.NewName)
        } catch {
            $row.Result = 'ERROR: ' + $_.Exception.Message
            $row.Reason = Get-RenameFailReason $_
            # The new name already taken is not a permission problem.
            if ($row.Reason -eq 'Denied' -and (Test-Path -LiteralPath (ConvertTo-LongPath (Join-Path (Split-Path $cur -Parent) $r.NewName)))) { $row.Reason = 'Other' }
            # Look for the programs holding it (capped: a folder means reading the files under it).
            if ($lockChecks -lt 50) {
                $lockChecks++
                $held = @(try { Get-PathShrinkLock -Path $cur } catch { Write-Verbose ('Lock check failed: {0}' -f $_.Exception.Message) })
                if ($held.Count) {
                    $row.Reason = 'InUse'
                    $row.LockedBy = (@($held | ForEach-Object { '{0} ({1})' -f $(if ($_.Title) { $_.Title } else { $_.Name }), $_.Id }) -join '; ')
                    foreach ($h in $held) { $locks[$h.Id] = $h }
                }
            }
            Write-Verbose ('Failed ({0}): {1}: {2}{3}' -f $row.Reason, $cur, $_.Exception.Message, $(if ($row.LockedBy) { ' Open in: ' + $row.LockedBy } else { '' }))
        }
        $results.Add($row)
        if ($OnProgress) { & $OnProgress $n $sel.Count }
    }
    # On a retry the rows of this try replace those of the earlier ones.
    $mine = @{}; foreach ($x in $results) { $mine[$x.OriginalPath] = $true }
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($e in $earlier) {
        if ($mine.ContainsKey($e.OriginalPath)) { continue }
        foreach ($c in 'Reason', 'LockedBy') { if ($e.PSObject.Properties.Name -notcontains $c) { $e | Add-Member -NotePropertyName $c -NotePropertyValue '' } }
        $all.Add($e)
    }
    foreach ($x in $results) { $all.Add($x) }
    $results = $all
    $ok = @($results | Where-Object { $_.Result -eq 'OK' }).Count
    $failed = $results.Count - $ok
    $results | Select-Object Depth, Type, OriginalPath, OriginalName, NewName, Result, Time, Reason, LockedBy |
        Export-Csv -LiteralPath (Join-Path $ReportFolder 'renames.csv') -NoTypeInformation -Encoding UTF8
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
        InUse = @($results | Where-Object { $_.Reason -eq 'InUse' }).Count; Denied = @($results | Where-Object { $_.Reason -eq 'Denied' }).Count
        Locks = @($locks.Values); Elevated = (Test-PathShrinkElevated)
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

# --------------------------------------------------------------------------------------
# Copies OneDrive brings back to the old names ("Do you want to delete these items?" > Keep)
# --------------------------------------------------------------------------------------
function Test-CloudOnly($Item) {
    # Files On-Demand placeholder: reading it would download it.
    [bool](([int]$Item.Attributes) -band (0x1000 -bor 0x40000 -bor 0x400000))
}

function Get-FileSha256([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::OpenRead((ConvertTo-LongPath $Path))
    try { -join ($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('X2') }) } finally { $fs.Dispose(); $sha.Dispose() }
}

function Find-PathShrinkDuplicate {
    <#
    .SYNOPSIS
        Finds the copies OneDrive brought back to the old names after a run, without changing anything.
    .DESCRIPTION
        After folders are renamed, OneDrive can ask "Do you want to delete these items?". With
        Keep, it downloads the cloud copies again at their old paths, so the same files are in
        the old and in the new place. For every renamed item whose old name exists again, each
        file under the old place is compared with the same file under the new name:
          Same       same content (SHA-256), or same size and date when one of them is only in the cloud
          Different  the two differ: both are kept
          OnlyOld    nothing at the new place (maybe new work saved there since): kept
        Method says how Same was decided: Hash or SizeDate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UndoFile,
        [scriptblock]$OnProgress
    )
    $rows = @(Import-Csv -LiteralPath $UndoFile | Where-Object { $_.Result -eq 'OK' } | Sort-Object { [int]$_.Depth }, OriginalPath)
    $now = @{}
    foreach ($r in $rows) { $now[$r.OriginalPath] = Join-Path (Resolve-UndoPath $now (Split-Path $r.OriginalPath -Parent)) $r.NewName }
    $roots = New-Object System.Collections.Generic.List[string]
    $n = 0
    foreach ($r in $rows) {
        $old = $r.OriginalPath
        $inside = $false
        foreach ($d in $roots) { if ($old.StartsWith($d + '\', [StringComparison]::OrdinalIgnoreCase)) { $inside = $true; break } }
        if ($inside) { continue }
        $lo = ConvertTo-LongPath $old
        if (-not (Test-Path -LiteralPath $lo) -or -not (Test-Path -LiteralPath (ConvertTo-LongPath $now[$old]))) { continue }
        $roots.Add($old)
        $files = $(if (Test-Path -LiteralPath $lo -PathType Leaf) { @(Get-Item -LiteralPath $lo -Force) } else { @(Get-ChildItem -LiteralPath $lo -Recurse -File -Force -ErrorAction SilentlyContinue) })
        foreach ($f in $files) {
            $n++
            if ($OnProgress) { & $OnProgress $n }
            $op = ConvertFrom-LongPath $f.FullName
            $np = Resolve-UndoPath $now $op
            $nl = ConvertTo-LongPath $np
            $status = 'OnlyOld'; $method = ''
            if (Test-Path -LiteralPath $nl -PathType Leaf) {
                $nf = Get-Item -LiteralPath $nl -Force
                $status = 'Different'
                if ($nf.Length -eq $f.Length) {
                    if ((Test-CloudOnly $f) -or (Test-CloudOnly $nf)) {
                        $method = 'SizeDate'
                        if ([Math]::Abs(($nf.LastWriteTimeUtc - $f.LastWriteTimeUtc).TotalSeconds) -lt 2) { $status = 'Same' }
                    } else {
                        $method = 'Hash'
                        if ((Get-FileSha256 $f.FullName) -eq (Get-FileSha256 $nl)) { $status = 'Same' }
                    }
                }
            }
            [pscustomobject]@{ OldPath = $op; NewPath = $np; Status = $status; Method = $method; Size = [long]$f.Length; CloudOnly = (Test-CloudOnly $f); Root = $old }
        }
    }
}

function Move-PathShrinkDuplicate {
    <#
    .SYNOPSIS
        Takes the copies found by Find-PathShrinkDuplicate (Status Same only) out of the old places.
    .DESCRIPTION
        A copy that is on this PC is moved, not deleted, to -Destination (default
        %LOCALAPPDATA%\PathShrink\Duplicates\<time>), keeping its full path. A copy that is only in
        the cloud is deleted: moving it would download it first, and OneDrive keeps it in its
        recycle bin. Before each one the file at the new place is checked again. Old folders left
        empty are removed. OneDrive may then ask again whether to delete these items: this time
        Delete is right, they are copies. Copies that differ or have no file at the new place are
        never touched. The outcome is written to duplicates.csv in -Destination.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][psobject[]]$Duplicate,
        [string]$Destination
    )
    $same = @($Duplicate | Where-Object { $_.Status -eq 'Same' })
    if (-not $same.Count) { Write-Verbose 'No identical copies.'; return }
    if (-not $PSCmdlet.ShouldProcess(('{0} copies' -f $same.Count), 'Take out of the old folders')) { return }
    if (-not $Destination) { $Destination = Join-Path $env:LOCALAPPDATA ('PathShrink\Duplicates\' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
    [void][IO.Directory]::CreateDirectory((ConvertTo-LongPath $Destination))
    $moved = 0; $deleted = 0; $failed = 0
    $results = foreach ($d in $same) {
        $res = ''
        try {
            if (-not (Test-Path -LiteralPath (ConvertTo-LongPath $d.NewPath) -PathType Leaf)) { throw 'The file at the new place is not there any more' }
            $src = ConvertTo-LongPath $d.OldPath
            $item = Get-Item -LiteralPath $src -Force
            if (Test-CloudOnly $item) {
                [IO.File]::Delete($src)
                $res = 'Deleted (OneDrive recycle bin)'; $deleted++
            } else {
                $rel = $d.OldPath -replace '^([A-Za-z]):', '$1' -replace '^\\\\', 'UNC\'
                $dst = ConvertTo-LongPath (Join-Path $Destination $rel)
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dst))
                [IO.File]::Move($src, $dst)
                $res = 'Moved'; $moved++
            }
        } catch { $res = 'ERROR: ' + $_.Exception.Message; $failed++ }
        Write-Verbose ('{0}: {1}' -f $res, $d.OldPath)
        [pscustomobject]@{ Time = (Get-Date).ToString('s'); OldPath = $d.OldPath; NewPath = $d.NewPath; Size = $d.Size; Result = $res }
    }
    $results = @($results)
    # Old folders that are now empty go too, deepest first; a folder with anything left stays.
    $removed = 0
    foreach ($root in @($same | ForEach-Object { $_.Root } | Sort-Object -Unique)) {
        $lr = ConvertTo-LongPath $root
        if (-not (Test-Path -LiteralPath $lr -PathType Container)) { continue }
        $dirs = @(Get-ChildItem -LiteralPath $lr -Recurse -Directory -Force -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending) + @(Get-Item -LiteralPath $lr -Force)
        foreach ($dir in $dirs) {
            if (@(Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue).Count) { continue }
            try { [IO.Directory]::Delete($dir.FullName, $false); $removed++ } catch { Write-Verbose ('Folder kept: {0}' -f $dir.FullName) }
        }
    }
    try { $results | Export-Csv -LiteralPath (Join-Path $Destination 'duplicates.csv') -NoTypeInformation -Encoding UTF8 -WhatIf:$false }
    catch { Write-Verbose ('duplicates.csv not written: {0}' -f $_.Exception.Message) }
    New-Object psobject -Property @{ Moved = $moved; Deleted = $deleted; Failed = $failed; FoldersRemoved = $removed; Destination = $Destination; Results = $results }
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
    $admin = Test-PathShrinkElevated
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
        -Limit and -Margin are server lengths. Also reports the paths that are too long on this PC;
        -LocalLimit plans for those instead, using the matching server limit with no margin unless
        -Margin is given. If OneDrive says to shorten a path by N characters, use its length minus N.
        Shortcuts to other libraries are not renamed from the folder above them: they are measured and
        listed, with the command to analyse each one.
    .EXAMPLE
        Invoke-PathShrink -WhatIf
        Scans the OneDrive of the current user and shows what would change.
    .EXAMPLE
        Invoke-PathShrink -Path "$env:OneDriveCommercial\Clients" -AllowTrim
    .EXAMPLE
        Invoke-PathShrink -Root D:\Export\Legal -Prefix "sites/Legal/Shared Documents/" -WhatIf
    .EXAMPLE
        Invoke-PathShrink -Path "$env:OneDriveCommercial\Clients" -LocalLimit 259 -WhatIf
        Plans for the paths that fail on this PC, not only those over the server limit.
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
        [ValidateRange(0, 400)][int]$LocalLimit = 0,
        [string]$ReportFolder,
        [switch]$PassThru
    )
    $libArgs = @{}
    foreach ($k in 'Path', 'Upn', 'Root', 'Prefix') { if ($PSBoundParameters.ContainsKey($k)) { $libArgs[$k] = $PSBoundParameters[$k] } }
    $lib = Get-PathShrinkLibrary @libArgs
    Write-Host ('Scanning {0} ...' -f $lib.Path) -ForegroundColor Cyan
    $inv = Get-PathShrinkInventory -Library $lib -Exclude $Exclude
    $local = Get-PathShrinkLocalLength -Inventory $inv -LocalLimit $(if ($LocalLimit) { $LocalLimit } else { 259 })
    # Measured before -LocalLimit lowers $Limit: that lower limit is only valid for this folder.
    $shortcutLimit = $Limit
    $shortcuts = @(Get-PathShrinkShortcut -Library $lib -LocalLimit $local.LocalLimit -Limit $shortcutLimit -Exclude $Exclude)
    if ($LocalLimit) {
        if ($local.ServerLimit -lt 50) { throw ('A local limit of {0} leaves only {1} characters on the server: the local folder is too long.' -f $LocalLimit, $local.ServerLimit) }
        $Limit = [Math]::Min($Limit, $local.ServerLimit)
        if (-not $PSBoundParameters.ContainsKey('Margin')) { $Margin = 0 }
    }
    $plan = New-PathShrinkPlan -Inventory $inv -Limit $Limit -Margin $Margin -AllowTrim:$AllowTrim -MinNameLength $MinNameLength -Protect $Protect
    $s = Get-PathShrinkSummary -Plan $plan
    $folder = Export-PathShrinkReport -Plan $plan -Folder $ReportFolder -SyncIssues @(Find-PathShrinkSyncIssue -Inventory $inv)

    Write-Host ''
    Write-Host ('Library       : {0} ({1})' -f $lib.Base, $lib.Kind)
    Write-Host ('Server prefix : {0} characters ({1})' -f $lib.Prefix.Length, $lib.PrefixSource)
    Write-Host ('Items         : {0} read, {1} unreadable' -f $s.Items, $s.Unreadable)
    Write-Host ('Long paths    : {0} above {1} ({2} above the {3} limit)' -f $s.LongPaths, $plan.Target, $s.OverLimit, $Limit)
    Write-Host ('Plan          : {0} renames ({1} folders, {2} files) fix {3}; {4} without margin; {5} still too long' -f $s.Renames, $s.Folders, $s.Files, $s.Fixed, $s.NoMargin, $s.TooLong)
    Write-Host ('On this PC    : {0} above {1} (longest {2}). The local path is {3} characters longer than the server path.' -f $local.OverLimit, $local.LocalLimit, $local.Longest, $local.Offset)
    if ($local.OverLimit -and -not $LocalLimit) { Write-Host ('                To plan for them, use -LocalLimit {0} (the same as -Limit {1} -Margin 0).' -f $local.LocalLimit, $local.ServerLimit) -ForegroundColor Yellow }
    if ($shortcuts.Count) {
        Write-Host ('Shortcuts     : {0} to other libraries, not part of this plan:' -f $shortcuts.Count)
        foreach ($c in $shortcuts) {
            if ($c.Error) { Write-Host ('  {0}: could not be read ({1})' -f $c.Path, $c.Error) -ForegroundColor Yellow; continue }
            $bad = $c.OverLocal -or $c.OverServer
            Write-Host ('  {0}: {1} items, {2} above {3} on this PC (longest {4}), {5} above the {6} limit on the server (longest {7})' -f $c.Path, $c.Items, $c.OverLocal, $local.LocalLimit, $c.LongestLocal, $c.OverServer, $shortcutLimit, $c.LongestServer) -ForegroundColor $(if ($bad) { 'Yellow' } else { 'Gray' })
            if ($bad) { Write-Host ('    To plan for it: -Path "{0}" -LocalLimit {1} -WhatIf' -f $c.Path, $local.LocalLimit) -ForegroundColor Yellow }
        }
    }
    Write-Host ('Reports       : {0}' -f $folder)
    if ($plan.Renames.Count) {
        $plan.Renames | Sort-Object Rel | Select-Object -First 25 | Format-Table @{ n = 'Saved'; e = { $_.Saved } }, @{ n = 'Items'; e = { $_.Affects } }, Method, OriginalName, NewName,
            @{ n = 'Folder'; e = { if ($_.Parent) { $_.Parent } else { '(root)' } } } -Wrap | Out-Host
        if ($plan.Renames.Count -gt 25) { Write-Host ('... and {0} more: see planned-renames.csv in the reports folder.' -f ($plan.Renames.Count - 25)) }
    }
    if ($s.TooLong -and -not $AllowTrim) { Write-Host 'Some paths only fit by removing letters: run again with -AllowTrim to see that plan.' -ForegroundColor Yellow }
    if (-not $plan.Renames.Count) {
        $pending = ($local.OverLimit -and -not $LocalLimit) -or @($shortcuts | Where-Object { $_.Error -or $_.OverLocal -or $_.OverServer }).Count
        if ($s.LongPaths) { Write-Host 'No automatic change is possible.' -ForegroundColor Green }
        elseif ($pending) { Write-Host 'No rename planned, but there are long paths: see above.' -ForegroundColor Yellow }
        else { Write-Host 'Nothing to change.' -ForegroundColor Green }
        if ($PassThru) { return $plan }
        return
    }
    # A shortcut can also point to a folder in the OneDrive of someone else.
    $own = @(Get-PathShrinkAccount | Where-Object { $_.LocalPath -eq $lib.Base }).Count
    if ($lib.Prefix -notlike 'personal/*' -or ($lib.Kind -ne 'Folder' -and -not $own)) {
        Write-Host 'This folder is shared: everyone with access will see the new names. If only this PC has the problem, stop syncing the folder instead (OneDrive settings, Choose folders).' -ForegroundColor Yellow
    }
    if ($PSCmdlet.ShouldProcess(('{0} items in {1}. Shortcuts and links to renamed folders stop working.' -f $s.Renames, $lib.Path), 'Rename')) {
        $res = Invoke-PathShrinkPlan -Plan $plan -ReportFolder $folder -Confirm:$false
        Write-Host ''
        Write-Host ('Renamed {0}, failed {1}. Verified on disk: {2} of {3} fixed paths. Still above {4}: {5}.' -f $res.Renamed, $res.Failed, $res.VerifiedFixed, $res.ExpectedFixed, $plan.Target, $res.StillLong.Count) -ForegroundColor $(if ($res.Failed -or $res.StillOverLimit) { 'Yellow' } else { 'Green' })
        if ($res.UndoFile) { Write-Host ('Undo: Undo-PathShrink -UndoFile "{0}"' -f $res.UndoFile) }
        if ($res.Renamed) {
            Write-Host 'If OneDrive asks "Do you want to delete these items?", choose Keep: nothing is lost.' -ForegroundColor Yellow
            Write-Host ('Once it has synced, find and take out the copies it brings back: Find-PathShrinkDuplicate -UndoFile "{0}" | Move-PathShrinkDuplicate' -f $res.UndoFile)
        }
        if ($res.InUse) {
            Write-Host ('{0} items are open in another program:' -f $res.InUse) -ForegroundColor Yellow
            foreach ($l in $res.Locks) { Write-Host ('  {0} ({1}, process {2}){3}' -f $(if ($l.Title) { $l.Title } else { $l.Name }), $l.Name, $l.Id, $(if (-not $l.CanClose) { ', not closed by PathShrink' } else { '' })) }
            Write-Host 'Close them and retry: Invoke-PathShrinkPlan -Plan <plan> -Retry -ReportFolder <folder>, or run the same command again'
        }
        if ($res.Denied) {
            Write-Host ('{0} items: access denied.{1}' -f $res.Denied, $(if (-not $res.Elevated) { ' Run PowerShell as administrator and try again.' } else { ' Check the permissions or the owner of those items.' })) -ForegroundColor Yellow
        }
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

Export-ModuleMember -Function Get-PathShrinkLibrary, Get-PathShrinkAccount, Get-PathShrinkSyncMount, Get-PathShrinkInventory, Get-PathShrinkLocalLength, Get-PathShrinkShortcut,
    New-PathShrinkPlan, Update-PathShrinkPlan, Test-PathShrinkRename, Set-PathShrinkRename, Get-PathShrinkSummary, Invoke-PathShrinkPlan, Undo-PathShrink, Test-PathShrinkUndo, Get-PathShrinkHistory,
    Find-PathShrinkSyncIssue, Export-PathShrinkReport, Get-PathShrinkEnvironment, Get-PathShrinkLock, Stop-PathShrinkLock, Find-PathShrinkDuplicate, Move-PathShrinkDuplicate, Invoke-PathShrink, Start-PathShrink
