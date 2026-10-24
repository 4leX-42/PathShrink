#Requires -Version 5.1

<#
.SYNOPSIS
    Opens PathShrink, or runs it from the command line when parameters are given.
.DESCRIPTION
    No parameters: opens the window (Basic mode). With -Pro: opens in Pro mode.
    -Language en, es or pt picks the window language (default: last used, then Windows).
    Any other parameter is passed to Invoke-PathShrink (command line, no window).
    Run as the user who owns the OneDrive, without elevation.
.EXAMPLE
    .\PathShrink.ps1
.EXAMPLE
    .\PathShrink.ps1 -WhatIf
    Command line: scan the current user's OneDrive and show the plan without changing anything.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch]$Pro,
    [ValidateSet('en', 'es', 'pt')][string]$Language,
    [string]$Path,
    [string]$Upn,
    [string]$Root,
    [string]$Prefix,
    [int]$Limit = 400,
    [int]$Margin = 20,
    [switch]$AllowTrim,
    [int]$MinNameLength = 20,
    [string[]]$Exclude = @(),
    [string[]]$Protect = @(),
    [string]$ReportFolder
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PathShrink\PathShrink.psd1') -Force
$cli = @($PSBoundParameters.Keys | Where-Object { $_ -notin 'Pro', 'Language', 'Path', 'Upn', 'Root', 'Prefix', 'Verbose', 'Debug' })
if (-not $cli.Count -and -not $WhatIfPreference) {
    $gui = @{}
    foreach ($k in 'Pro', 'Language', 'Path', 'Upn', 'Root', 'Prefix') { if ($PSBoundParameters.ContainsKey($k)) { $gui[$k] = $PSBoundParameters[$k] } }
    try { Start-PathShrink @gui }
    catch {
        # Started from a shortcut there is no console to read, so show the reason.
        Add-Type -AssemblyName PresentationFramework
        [void][Windows.MessageBox]::Show($_.Exception.Message, 'PathShrink could not start', 'OK', 'Error')
        throw
    }
    return
}
$a = @{}
foreach ($k in $PSBoundParameters.Keys) { if ($k -ne 'Pro' -and $k -ne 'Language') { $a[$k] = $PSBoundParameters[$k] } }
Invoke-PathShrink @a
