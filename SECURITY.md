# Security policy

## Supported versions

Only the latest release receives fixes.

## Reporting a vulnerability

Please report privately through **GitHub Security Advisories**
(*Security* tab, *Report a vulnerability*). Do not open a public issue.
I aim to answer within a week.

## What PathShrink can do on a computer

Knowing this helps judge a report:

- Runs as the current user. It never asks for or uses administrator rights.
- Renames files and folders inside the folder the user picks, after confirmation (or with
  `-Confirm:$false` on the command line). It does not delete, move, download or upload anything.
- Reads two registry keys under `HKCU` to find OneDrive libraries. Writes only to
  `%LOCALAPPDATA%\PathShrink`.
- Makes no network connections. `install.ps1` downloads the release zip and its SHA-256 from
  GitHub over HTTPS and refuses to install on a mismatch.

Undo files and reports contain file and folder names from the scanned library. Treat them as
you would the library itself.
