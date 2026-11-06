# Changelog

All notable changes to this project are documented here. Versions follow [Semantic Versioning](https://semver.org/).

## [1.3.3] - 2026-11-06

### Added
- **Install and run without the exe.** `install.ps1 -NoExe` downloads the new `PathShrink-script.zip`,
  which has no `PathShrink.exe`, and opens the window directly with Windows PowerShell. For computers
  where an antivirus or EDR stops the exe. The README has a ready-to-paste command for each route.

### Fixed
- `PathShrink.cmd` no longer inherits the PowerShell 7 module path.

## [1.3.2] - 2026-11-06

Tested with the real OneDrive client on a real shortcut.

### Fixed
- **Server length of a shortcut to a folder.** The registry value used for the library URL leaves out
  the folder the shortcut points to, so every server length came out short by that folder (16
  characters in the test: 383 reported for a real 399). It is now read from the client. If it cannot
  be read, PathShrink says so.
- **Renamed shortcuts.** The registry keeps the old name until OneDrive restarts, so the folder was read
  as part of the personal OneDrive. PathShrink now says to restart OneDrive and renames nothing until then.
- "The local path is -13 characters longer" now reads "13 characters shorter".
- A shortcut to the OneDrive of someone else no longer counts as a personal OneDrive.

### Added
- For each shortcut: the items only on this PC that stop the sync, and what a 2-character shortcut name
  would leave.
- The window offers the shortcuts as folders, has the limit on this PC in Pro mode, and reports paths too
  long on this PC, shortcuts and shared folders.

### Changed
- Removed the advice to use the length minus the N in "shorten the path by N characters": in the test
  OneDrive said 1 for paths 1, 7 and 17 over the limit.

## [1.3.1] - 2026-11-06

### Fixed
- **Shortcuts with long paths went unnoticed.** A scan skips the shortcuts to other libraries inside
  the folder, so a plain run could say "Nothing to change" while OneDrive and Windows failed on them.
  The command line now measures each shortcut, read only, and prints its counts and the command to
  plan for it. New `Get-PathShrinkShortcut`. It never renames inside a shortcut unless you point
  `-Path` at it.
- "Nothing to change" no longer appears when there are paths too long on this PC.

### Added
- The command line warns before renaming in a shared library or in a shortcut to the OneDrive of
  someone else: everyone with access sees the new names.

## [1.3.0] - 2026-11-06

### Added
- **Paths too long on this PC.** The limit measures the server path, which does not count the local
  OneDrive folder or the name of the shortcut, so a path could fit and still fail in Windows. The
  command line now reports how many paths are over 259 characters on this PC and the longest one.
  New `Get-PathShrinkLocalLength`.
- `Invoke-PathShrink -LocalLimit 259` plans for those paths, using the matching server limit with no
  margin unless `-Margin` is given. Without it, the plan is the same as before.

## [1.2.0] - 2026-11-05

### Added
- **Copies brought back** in Changes applied: after renaming, OneDrive can ask "Do you want to delete
  these items?" and, with Keep, download the cloud copies again at the old names. PathShrink finds
  them, compares each one with the file at the new place (SHA-256, or size and date for files that
  are only in the cloud, so nothing is downloaded) and takes out only the identical ones: moved out
  of OneDrive to `%LOCALAPPDATA%\PathShrink\Duplicates`, or deleted to the OneDrive recycle bin when
  only in the cloud. Copies that differ or have no file at the new place are kept. A revert still
  works afterwards. New `Find-PathShrinkDuplicate` and `Move-PathShrinkDuplicate`.
- The confirmation, the result screen and the command line say what to answer to that OneDrive prompt.

### Fixed
- Cancel or Close in any dialog closed the whole window (`IsCancel` on a window shown modally).
- The Pro log no longer fills with "importing function" lines on every task.

## [1.1.1] - 2026-11-05

### Fixed
- `install.ps1` failed with "Get-FileHash is not recognized" when Windows PowerShell was started
  from PowerShell 7 (Windows Terminal default): it now hashes and unpacks with .NET.
- `PathShrink.exe` starts Windows PowerShell without the inherited PowerShell 7 module path.

## [1.1.0] - 2026-11-05

### Added
- `PathShrink.exe` in the release zip: double-click to open the window, no console. A small
  launcher built from `tools/Launcher.cs` with the .NET Framework 4 compiler, so it runs on
  Windows 10 and 11 as they come.
- Items that could not be renamed now say why: open in another program (and which one, through
  the Windows Restart Manager) or no permission.
- The window offers to close those programs and retry only the failed items. Each program is
  asked to close first, so it can still offer to save; ending it is a second, explicit choice.
  Services, Windows processes and File Explorer are never closed.
- When permission is missing, the window offers to open again as administrator on the same folder.
- `Invoke-PathShrinkPlan -Retry` tries the failed items of a run again into the same report folder,
  so one revert still undoes the whole run. New `Get-PathShrinkLock` and `Stop-PathShrinkLock`.
- With more than one OneDrive account or synced library, the window asks which one to check.
- `install.ps1` opens PathShrink when it finishes (`-NoStart` to skip), and its shortcut points to the exe.

### Changed
- New logo: the Windows logo (a Microsoft trademark) is replaced by a folder with two inward chevrons.
  Window, shortcut icon, social preview and screenshots are regenerated.

## [1.0.0] - 2026-10-24

First public release. The renaming rules come from a support script used on real
OneDrive incidents; this version turns it into a module with a window, tests and an installer.

### Added
- Window in English, Spanish and Portuguese, with an EN / ES / PT switch; the choice is remembered.
- Window with Basic (guided) and Pro modes: five steps that say which ones only read and which one
  renames, scan in the background, summary tiles, plain-language explanation, confirmation summary,
  verified result.
- Before and after comparison: the ten most relevant paths per page (problems first), both full paths
  with the changed names highlighted, length bars against the limit and the target, the reason for
  each change; filter, search and paging for the rest.
- Execution plan view: every rename in full (no truncated text), why it is needed, which long paths
  it serves and how much they shrink, what else it affects; Back and Summary keep the selection.
- Applied changes: a history of the runs that renamed something, each checked on disk before it can be
  reverted (`Test-PathShrinkUndo`, `Get-PathShrinkHistory`).
- Names typed by hand: *Edit names* on a before/after card or in the plan, checked as you type
  (characters Windows refuses, reserved names, names in use, file extension, only shorter), with the
  path length updated live (`Test-PathShrinkRename`, `Set-PathShrinkRename`).
- Contextual help: a `?` next to each option with a one-line answer, and a help panel (F1) with the
  full explanation and a glossary.
- Interactive demonstration, step by step (clean up spaces, join words, shorten names): the real
  planner on made-up paths held in memory, showing what each step removes and when a step is not
  needed; it never reads or writes files.
- Windows folder picker (the Explorer dialog with address bar and search) instead of the old tree, a
  path box that accepts a pasted path, and drag and drop.
- Pro settings, grouped by purpose: limit, safety margin, shorten names, shortest name, exclude and
  never-rename wildcards, server prefix under Advanced; a marker when the rules no longer match the
  plan; per-rename selection in the plan view; log, other sync issues, undo from another file,
  environment check, copy as command line.
- Logo, window and shortcut icon, and a social preview image.
- Command line: `Invoke-PathShrink` with `-WhatIf` / `-Confirm`, and `Undo-PathShrink`.
- Exported building blocks: library detection, inventory, plan, apply, sync issues, reports.
- Reports in CSV, JSON and HTML under `%LOCALAPPDATA%\PathShrink\Reports`.
- `undo.csv` written rename by rename (with the time of each), plus `run.json`, so an interrupted
  run can still be reverted. Reverting checks every item first and never overwrites: items moved,
  renamed again, replaced or deleted since are skipped and listed; the outcome goes to `restore.csv`.
- The HTML report shows each long path before and after, with the changed names highlighted.
- Detection of other sync blockers: reserved names, `_vti_`, `~$`, leading or trailing spaces, names over 255.
- `install.ps1` (per user, SHA-256 checked, Start menu shortcut, `-Uninstall`).
- Pester tests, GUI smoke test through UI Automation, static checks, GitHub Actions.

### Changed (compared with the original script)
- Renames that do not fix any path, or bring it under the hard limit, are dropped from the plan.
- Junctions and symbolic links are no longer followed during the scan.
- Clean-up now removes a space left before a trailing dot (`Q3 .` became `Q3 ` before).
- Reports moved from `%TEMP%` to `%LOCALAPPDATA%\PathShrink`, so undo files survive temp clean-up.
- Planning is about three times faster on large trees.
