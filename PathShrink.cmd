@echo off
rem Opens PathShrink. Runs as the current user; administrator rights are not needed.
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0PathShrink.ps1" %*
