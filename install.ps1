param([switch]$NonInteractive)

# Compatibility entry point. Installer development lives in velronInstaller.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$installerUrl = 'https://raw.githubusercontent.com/CodingManFocus/velronInstaller/main/install.ps1'
$installerSource = Invoke-RestMethod -Uri $installerUrl
if ([string]::IsNullOrWhiteSpace($installerSource)) { throw 'The Installer script download was empty.' }
. ([ScriptBlock]::Create($installerSource)) -NonInteractive:$NonInteractive
