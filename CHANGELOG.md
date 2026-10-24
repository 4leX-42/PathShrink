# Changelog

All notable changes to this project are documented here. Versions follow [Semantic Versioning](https://semver.org/).

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
