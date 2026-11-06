#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the modules CI needs, retrying: PowerShell Gallery downloads fail now and then.
.EXAMPLE
    ./tools/Install-TestModule.ps1 -Analyzer
#>
[CmdletBinding()]
param(
    [switch]$Analyzer,
    [int]$Attempts = 5,
    [int]$WaitSeconds = 20
)
$ErrorActionPreference = 'Stop'
Set-PSRepository PSGallery -InstallationPolicy Trusted

function Install-WithRetry([hashtable]$Module) {
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            Install-Module @Module -Scope CurrentUser -Force
            Write-Host ('Installed {0} (attempt {1}).' -f $Module.Name, $i)
            return
        } catch {
            if ($i -eq $Attempts) { throw }
            Write-Host ('{0}: attempt {1} of {2} failed: {3}' -f $Module.Name, $i, $Attempts, $_.Exception.Message)
            Start-Sleep -Seconds ($WaitSeconds * $i)
        }
    }
}

Install-WithRetry @{ Name = 'Pester'; MinimumVersion = '5.5.0'; SkipPublisherCheck = $true }
if ($Analyzer) { Install-WithRetry @{ Name = 'PSScriptAnalyzer' } }
