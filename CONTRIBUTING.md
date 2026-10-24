# Contributing

Thanks for helping. The most useful things are bug reports from real OneDrive and SharePoint
setups, and fixes that come with a test.

## Reporting a bug

Open an issue with the bug template and include the output of:

```powershell
Import-Module .\PathShrink\PathShrink.psd1
Get-PathShrinkEnvironment
```

Do not paste real paths or names of clients or colleagues: replace them, or attach the
`summary.json` from the reports folder, which holds counts only.

## Running the tests

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser

.\tools\Test-Static.ps1                                   # encoding, syntax, XAML, analyzer
Invoke-Pester .\tests\PathShrink.Tests.ps1 -Output Detailed
.\tests\Gui.Smoke.ps1                                      # drives the real window; needs a desktop
```

Run the first two under both `powershell.exe` (5.1) and `pwsh` (7). Tests only write inside
throw-away folders under `%TEMP%` named `PathShrinkTest-*`.

`tools\New-DemoFolder.ps1` creates a fake OneDrive with long paths to try things by hand, and
`tools\Save-Screenshots.ps1` renders the window states to `docs\images`.

## Code rules

- Must run on **Windows PowerShell 5.1** and PowerShell 7. No `??`, no ternary, no `?.`.
- PowerShell files are **ASCII only and saved as UTF-8 with BOM**: 5.1 reads BOM-less files as
  ANSI and one typographic dash breaks the whole file. `Test-Static.ps1` checks this.
- No new runtime dependencies. The core (`PathShrink.psm1`) has no UI code; the window
  (`gui\`) calls the core and never renames anything itself.
- Anything that changes files supports `-WhatIf` and writes to the undo file.
- Plain English in the interface; no marketing words.

## Pull requests

One topic per pull request, tests green on both editions, and a line in `CHANGELOG.md`
under *Unreleased*.
