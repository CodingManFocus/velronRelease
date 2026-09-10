param([switch]$NonInteractive)

# Compatibility entry point. Installer development lives in velronInstaller.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$installerUrl = 'https://raw.githubusercontent.com/CodingManFocus/velronInstaller/4f2a7538c238805aa5e62853baa98a29d144625a/install.ps1'
$installerSource = Invoke-RestMethod -Uri $installerUrl
if ([string]::IsNullOrWhiteSpace($installerSource)) { throw 'The Installer script download was empty.' }
. ([ScriptBlock]::Create($installerSource)) -NonInteractive:$NonInteractive
