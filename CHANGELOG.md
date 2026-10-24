# Changelog

All notable changes to this project are documented here. Versions follow [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-10-24

First public release. The renaming rules come from a support script used on real
OneDrive incidents; this version turns it into a module with a window, tests and an installer.

### Added
- Window in English, Spanish and Portuguese, with an EN / ES / PT switch; the choice is remembered.
- Window with Basic (guided) and Pro modes: detected folder, scan in the background,
  summary tiles, plain-language explanation, per-rename selection with live totals (Pro),
  confirmation summary, verified result, undo.
- Pro settings: limit, safety margin, trimming, shortest name, exclude and protect wildcards,
  server prefix override; log, other sync issues, undo from a file, environment check,
  copy as command line.
- Command line: `Invoke-PathShrink` with `-WhatIf` / `-Confirm`, and `Undo-PathShrink`.
- Exported building blocks: library detection, inventory, plan, apply, sync issues, reports.
- Reports in CSV, JSON and HTML under `%LOCALAPPDATA%\PathShrink\Reports`.
- `undo.csv` written rename by rename, so an interrupted run can still be undone.
- Detection of other sync blockers: reserved names, `_vti_`, `~$`, leading or trailing spaces, names over 255.
- `install.ps1` (per user, SHA-256 checked, Start menu shortcut, `-Uninstall`).
- Pester tests, GUI smoke test through UI Automation, static checks, GitHub Actions.

### Changed (compared with the original script)
- Renames that do not fix any path, or bring it under the hard limit, are dropped from the plan.
- Junctions and symbolic links are no longer followed during the scan.
- Clean-up now removes a space left before a trailing dot (`Q3 .` became `Q3 ` before).
- Reports moved from `%TEMP%` to `%LOCALAPPDATA%\PathShrink`, so undo files survive temp clean-up.
- Planning is about three times faster on large trees.
