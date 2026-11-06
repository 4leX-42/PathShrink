@echo off
rem Opens PathShrink. Runs as the current user; administrator rights are not needed.
rem Without PSModulePath, Windows PowerShell builds its own: the one inherited from PowerShell 7 does not load.
set "PSModulePath="
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0PathShrink.ps1" %*
