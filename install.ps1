<#
.SYNOPSIS
Installs Velron Server, Velron Client, or both with an interactive setup wizard.

.DESCRIPTION
Selects the correct Windows release for the current architecture, verifies its SHA-256
checksum, configures PATH and optional login startup, and connects Velron Client to
Codex, Claude Code, or another stdio MCP host.

.PARAMETER Components
server, client, or all.

.PARAMETER ClientTarget
codex, claude, both, other, or none.

.EXAMPLE
irm https://raw.githubusercontent.com/CodingManFocus/velronRelease/main/install.ps1 | iex

.EXAMPLE
./install.ps1 -Components all -ClientTarget both -Yes
#>
[CmdletBinding()]
param(
    [ValidateSet('server', 'client', 'all')]
    [string]$Components,

    [ValidateSet('codex', 'claude', 'both', 'other', 'none')]
    [string]$ClientTarget,

    [string]$VcpUrl,
    [string]$VcpToken,
    [string]$Workspace,
    [string]$InstallDir = $(if ($env:VELRON_INSTALL_DIR) { $env:VELRON_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'Velron\bin' }),
    [string]$ServerHost,
    [int]$ServerPort,
    [int]$LocalVcpPort,
    [ValidateSet('yes', 'no')]
    [string]$Autostart,
    [ValidateSet('yes', 'no')]
    [string]$StartServer,
    [ValidateSet('yes', 'no')]
    [string]$OpenDashboard,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$repo = 'CodingManFocus/velronRelease'
$releaseBase = "https://github.com/$repo/releases/latest/download"
$defaultDataDir = Join-Path $HOME '.velron'
$dataDir = if ($env:VELRON_HOME) { $env:VELRON_HOME } else { $defaultDataDir }
$defaultVcpPort = 4143

function Write-Info([string]$Message) { Write-Host "◆ $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "✓ $Message" -ForegroundColor Green }
function Write-WarningMessage([string]$Message) { Write-Host "! $Message" -ForegroundColor Yellow }
function Stop-Setup([string]$Message) { throw "Velron setup: $Message" }

function Read-Default {
    param([string]$Label, [string]$Default)
    $answer = Read-Host "$Label [$Default]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function Read-SecretText([string]$Label) {
    $secure = Read-Host $Label -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Select-Menu {
    param([string]$Title, [string[]]$Options, [int]$Default = 1)
    Write-Host "`n$Title" -ForegroundColor Cyan
    for ($index = 0; $index -lt $Options.Count; $index++) {
        Write-Host ('  {0}) {1}' -f ($index + 1), $Options[$index])
    }
    while ($true) {
        $answer = Read-Host "Choose [$Default]"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Options.Count) {
            return $number
        }
        Write-WarningMessage 'Choose a listed number.'
    }
}

function Read-YesNo {
    param([string]$Label, [ValidateSet('yes', 'no')][string]$Default)
    if ($Yes) { return $Default }
    $suffix = if ($Default -eq 'yes') { 'Y/n' } else { 'y/N' }
    while ($true) {
        $answer = (Read-Host "$Label [$suffix]").Trim().ToLowerInvariant()
        if (-not $answer) { return $Default }
        if ($answer -in @('y', 'yes')) { return 'yes' }
        if ($answer -in @('n', 'no')) { return 'no' }
        Write-WarningMessage 'Enter y or n.'
    }
}

function Assert-Port([int]$Port, [string]$Name) {
    if ($Port -lt 1 -or $Port -gt 65535) { Stop-Setup "$Name must be between 1 and 65535." }
}

function Assert-VcpUrl([string]$Value) {
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'wss' -or $uri.AbsolutePath -ne '/vcp/v1' -or
        $uri.Query -or $uri.Fragment -or $uri.UserInfo) {
        Stop-Setup 'VCP URL must be a wss:// URL ending exactly in /vcp/v1, without credentials, query, or fragment.'
    }
}

function Assert-VcpToken([string]$Value) {
    if ($Value -notmatch '^[A-Za-z0-9_-]{43}$') {
        Stop-Setup 'VCP token must be a 43-character base64url token.'
    }
}

function Save-Json {
    param([string]$Path, [object]$Value)
    $json = ($Value | ConvertTo-Json -Depth 100) + "`n"
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Invoke-Download {
    param([string]$Url, [string]$Destination)
    $parameters = @{
        Uri = $Url
        OutFile = $Destination
        UseBasicParsing = $true
    }
    if ($env:GITHUB_TOKEN) { $parameters.Headers = @{ Authorization = "Bearer $($env:GITHUB_TOKEN)" } }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try { Invoke-WebRequest @parameters; return }
        catch {
            if ($attempt -eq 3) { throw }
            Start-Sleep -Seconds 2
        }
    }
}

function Install-VerifiedAsset {
    param([string]$Asset, [string]$Target, [string]$TempDir, [hashtable]$Checksums)
    $downloaded = Join-Path $TempDir $Asset
    Write-Info "Downloading $Asset…"
    Invoke-Download "$releaseBase/$Asset" $downloaded
    if (-not $Checksums.ContainsKey($Asset)) { Stop-Setup "No checksum was published for $Asset." }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $downloaded).Hash.ToLowerInvariant()
    if ($actual -ne $Checksums[$Asset]) {
        Stop-Setup "Checksum verification failed for $Asset. Existing files were not changed."
    }
    Write-Ok "Verified $Asset"
    Unblock-File -LiteralPath $downloaded -ErrorAction SilentlyContinue
    try { Move-Item -LiteralPath $downloaded -Destination $Target -Force }
    catch { Stop-Setup "Could not replace $Target. Close any running Velron process and try again. $($_.Exception.Message)" }
}

function Add-UserPath([string]$Directory) {
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($current -split ';' | Where-Object { $_ })
    if (-not ($entries | Where-Object { $_.TrimEnd('\') -ieq $Directory.TrimEnd('\') })) {
        $newPath = (@($entries) + $Directory) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-Ok 'Added Velron to your user PATH'
    }
    if (-not (($env:Path -split ';') | Where-Object { $_.TrimEnd('\') -ieq $Directory.TrimEnd('\') })) {
        $env:Path = "$Directory;$env:Path"
    }
}

function Set-PluginMcpEnvironment {
    param([string]$PluginDir, [string]$ClientPath, [hashtable]$Environment)
    foreach ($relativePath in @('.mcp.json', '.codex-plugin\plugin.json')) {
        $path = Join-Path $PluginDir $relativePath
        $document = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        $server = $document.mcpServers.velron
        $server.command = $ClientPath
        $server.args = @()
        if ($Environment.Count -gt 0) {
            $server | Add-Member -NotePropertyName env -NotePropertyValue $Environment -Force
        } elseif ($server.PSObject.Properties.Name -contains 'env') {
            $server.PSObject.Properties.Remove('env')
        }
        Save-Json $path $document
    }
}

function Install-CodexPlugin([string]$MarketplaceDir) {
    if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
        Write-WarningMessage 'Codex CLI was not found. The plugin is ready for later installation.'
        return
    }
    try {
        & codex plugin marketplace add $MarketplaceDir
        if ($LASTEXITCODE -ne 0) { throw 'marketplace add failed' }
        & codex plugin add 'velron@velron-local'
        if ($LASTEXITCODE -ne 0) { throw 'plugin add failed' }
        Write-Ok 'Installed the Velron plugin for Codex'
    } catch { Write-WarningMessage 'Codex did not accept automatic plugin setup. Run the fallback commands shown at the end.' }
}

function Install-ClaudePlugin([string]$MarketplaceDir) {
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Write-WarningMessage 'Claude Code CLI was not found. The plugin is ready for later installation.'
        return
    }
    try {
        & claude plugin marketplace add $MarketplaceDir --scope user
        if ($LASTEXITCODE -ne 0) { throw 'marketplace add failed' }
        & claude plugin install 'velron@velron-local' --scope user
        if ($LASTEXITCODE -ne 0) { throw 'plugin install failed' }
        Write-Ok 'Installed the Velron plugin for Claude Code'
    } catch { Write-WarningMessage 'Claude Code did not accept automatic plugin setup. Run the fallback commands shown at the end.' }
}

Write-Host '╭────────────────────────────────────╮' -ForegroundColor Cyan
Write-Host '│       VELRON SETUP  Initial wizard  │' -ForegroundColor Cyan
Write-Host '╰────────────────────────────────────╯' -ForegroundColor Cyan
Write-Host 'Server, local bridge, and coding-agent integration.' -ForegroundColor DarkGray
Write-Host "License: https://github.com/$repo/blob/main/LICENSE" -ForegroundColor DarkGray
if (-not $Yes -and (Read-YesNo 'Continue and accept the Velron license terms?' 'yes') -ne 'yes') {
    Write-Host 'Setup cancelled.'
    return
}

if (-not $Components) {
    if ($Yes) { $Components = 'all' }
    else {
        switch (Select-Menu 'What would you like to install?' @(
            'Server + Client (recommended)', 'Server only', 'Client only'
        ) 1) {
            1 { $Components = 'all' }
            2 { $Components = 'server' }
            3 { $Components = 'client' }
        }
    }
}
$installServerComponent = $Components -in @('server', 'all')
$installClientComponent = $Components -in @('client', 'all')

if (-not $Yes) { $InstallDir = Read-Default 'Install directory' $InstallDir }
$InstallDir = [IO.Path]::GetFullPath($InstallDir)
$dataDir = [IO.Path]::GetFullPath($dataDir)
$defaultDataDir = [IO.Path]::GetFullPath($defaultDataDir)
if ($InstallDir -match '[\x00-\x1f\x7f''"%!^&|<>()$`]') {
    Stop-Setup 'Install directory contains characters that cannot be safely pinned in a Velron Hook.'
}

$configPath = Join-Path $dataDir 'config.json'
$configExists = Test-Path -LiteralPath $configPath -PathType Leaf
$writeServerConfig = $false
if ($installServerComponent) {
    $keepSettings = if ($configExists) { Read-YesNo "Keep existing Server settings in $configPath?" 'yes' } else { 'no' }
    if ($configExists -and $keepSettings -eq 'yes') {
        Write-Info 'Existing Server settings will be preserved.'
        try {
            $existingSettings = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
            if (-not $ServerHost) { $ServerHost = [string]$existingSettings.host }
            if (-not $ServerPort) { $ServerPort = [int]$existingSettings.port }
            if (-not $LocalVcpPort) { $LocalVcpPort = [int]$existingSettings.localVcpPort }
        } catch { Stop-Setup "Existing Server settings are invalid: $($_.Exception.Message)" }
    } else {
        $writeServerConfig = $true
        if (-not $ServerHost) { $ServerHost = '127.0.0.1' }
        if (-not $ServerPort) { $ServerPort = 4141 }
        if (-not $LocalVcpPort) { $LocalVcpPort = $defaultVcpPort }
        if (-not $Yes) {
            Write-Host "`nServer settings" -ForegroundColor Cyan
            $ServerHost = Read-Default 'Bind host' $ServerHost
            $ServerPort = [int](Read-Default 'Dashboard port' ([string]$ServerPort))
            $LocalVcpPort = [int](Read-Default 'Local VCP port' ([string]$LocalVcpPort))
        }
        Assert-Port $ServerPort 'Dashboard port'
        Assert-Port $LocalVcpPort 'Local VCP port'
        if ($ServerPort -eq $LocalVcpPort) { Stop-Setup 'Dashboard and local VCP ports must differ.' }
        if ($ServerHost -notmatch '^[A-Za-z0-9.:-]+$') { Stop-Setup 'Bind host must be an IP address or DNS hostname.' }
        if ($ServerHost -in @('0.0.0.0', '::')) {
            Write-WarningMessage 'The dashboard will listen beyond localhost. Configure firewall and allowed hosts in Velron.'
        }
    }
    if (-not $Autostart) { $Autostart = Read-YesNo 'Start Velron Server automatically when you sign in?' 'yes' }
    if (-not $StartServer) { $StartServer = Read-YesNo 'Start Velron Server after installation?' 'yes' }
    if (-not $OpenDashboard) { $OpenDashboard = Read-YesNo 'Open the dashboard when setup finishes?' 'yes' }
}

if (-not $LocalVcpPort) {
    $discoveryPath = Join-Path $dataDir 'local-vcp.json'
    if (Test-Path -LiteralPath $discoveryPath -PathType Leaf) {
        try { $LocalVcpPort = [int](Get-Content -Raw -LiteralPath $discoveryPath | ConvertFrom-Json).port }
        catch { $LocalVcpPort = $defaultVcpPort }
    } else { $LocalVcpPort = $defaultVcpPort }
}
$localSuggestedUrl = "wss://127.0.0.1:$LocalVcpPort/vcp/v1"
$customVcp = $false
if ($installClientComponent) {
    if (-not $VcpUrl) {
        if ($Yes) { $VcpUrl = $localSuggestedUrl }
        else {
            Write-Host "`nClient connection" -ForegroundColor Cyan
            Write-Host 'Press Enter to use secure automatic local discovery.' -ForegroundColor DarkGray
            $VcpUrl = Read-Default 'VCP URL' $localSuggestedUrl
        }
    }
    Assert-VcpUrl $VcpUrl
    if ($VcpUrl -ne $localSuggestedUrl) {
        $customVcp = $true
        if (-not $VcpToken) { $VcpToken = Read-SecretText 'VCP access token' }
        Assert-VcpToken $VcpToken
    }
    if (-not $ClientTarget) {
        if ($Yes) { $ClientTarget = 'both' }
        else {
            switch (Select-Menu 'Where should Velron Client be connected?' @(
                'Codex', 'Claude Code', 'Codex + Claude Code (recommended)',
                'Other… (generic stdio MCP)', 'Not now'
            ) 3) {
                1 { $ClientTarget = 'codex' }
                2 { $ClientTarget = 'claude' }
                3 { $ClientTarget = 'both' }
                4 { $ClientTarget = 'other' }
                5 { $ClientTarget = 'none' }
            }
        }
    }
    if ($ClientTarget -eq 'other') {
        if (-not $Workspace) { $Workspace = Read-Default 'Workspace directory' (Get-Location).Path }
        $Workspace = [IO.Path]::GetFullPath($Workspace)
        if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) {
            Stop-Setup "Workspace directory does not exist: $Workspace"
        }
    }
}

$architectureName = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$architecture = switch ($architectureName) {
    'x64' { 'x64' }
    'arm64' { 'arm64' }
    default { Stop-Setup "Unsupported Windows architecture: $architectureName" }
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ("velron-install-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir | Out-Null
try {
    Write-Info 'Downloading release checksums…'
    $checksumPath = Join-Path $tempDir 'SHA256SUMS.txt'
    Invoke-Download "$releaseBase/SHA256SUMS.txt" $checksumPath
    $checksums = @{}
    foreach ($line in Get-Content -LiteralPath $checksumPath) {
        if ($line -match '^([a-fA-F0-9]{64})\s+\*?(.+)$') { $checksums[$Matches[2]] = $Matches[1].ToLowerInvariant() }
    }

    $serverPath = Join-Path $InstallDir 'velron.exe'
    $clientPath = Join-Path $InstallDir 'velron-client.exe'
    if ($installServerComponent) {
        Install-VerifiedAsset "velron-windows-$architecture.exe" $serverPath $tempDir $checksums
    }
    if ($installClientComponent) {
        Install-VerifiedAsset "velron-client-windows-$architecture.exe" $clientPath $tempDir $checksums
    }
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($installServerComponent -and $writeServerConfig) {
    $settings = [ordered]@{
        schemaVersion = 1
        host = $ServerHost
        port = $ServerPort
        localVcpPort = $LocalVcpPort
        allowedHosts = @()
        managementSecureCookies = $false
        maxConcurrentRuns = 4
        maxRunStartsPerMinute = 60
        maxRunContextBytes = 8388608
    }
    Save-Json $configPath $settings
    Write-Ok 'Created Server settings'
}

Add-UserPath $InstallDir

$marketplaceDir = Join-Path $dataDir 'plugin-marketplace'
$pluginDir = Join-Path $marketplaceDir 'plugins\velron'
$setupHostPlugins = $ClientTarget -in @('codex', 'claude', 'both')
if ($installClientComponent -and $setupHostPlugins) {
    Write-Info 'Generating a pinned Velron plugin…'
    $oldVelronHome = $env:VELRON_HOME
    try {
        $env:VELRON_HOME = $dataDir
        & $clientPath setup-plugin --client-path $clientPath | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "setup-plugin exited with $LASTEXITCODE" }
    } catch {
        if (Test-Path -LiteralPath (Join-Path $pluginDir '.velron-generated.json') -PathType Leaf) {
            Write-WarningMessage "An existing generated plugin was kept. Its pinned Client path must still be $clientPath."
        } else {
            Stop-Setup "Plugin generation failed. Review or move $marketplaceDir and rerun setup. $($_.Exception.Message)"
        }
    } finally {
        $env:VELRON_HOME = $oldVelronHome
    }
    $mcpEnvironment = @{}
    if ($dataDir -ne $defaultDataDir) { $mcpEnvironment.VELRON_HOME = $dataDir }
    if ($customVcp) {
        $mcpEnvironment.VELRON_VCP_URL = $VcpUrl
        $mcpEnvironment.VELRON_VCP_TOKEN = $VcpToken
    }
    Set-PluginMcpEnvironment $pluginDir $clientPath $mcpEnvironment
}

switch ($ClientTarget) {
    'codex' { Install-CodexPlugin $marketplaceDir }
    'claude' { Install-ClaudePlugin $marketplaceDir }
    'both' { Install-CodexPlugin $marketplaceDir; Install-ClaudePlugin $marketplaceDir }
}

$genericConfig = $null
if ($installClientComponent -and $ClientTarget -eq 'other') {
    $genericConfig = Join-Path $dataDir 'stdio-mcp.json'
    $genericEnvironment = [ordered]@{ VELRON_WORKSPACE_ROOT = $Workspace }
    if ($dataDir -ne $defaultDataDir) { $genericEnvironment['VELRON_HOME'] = $dataDir }
    if ($customVcp) {
        $genericEnvironment['VELRON_VCP_URL'] = $VcpUrl
        $genericEnvironment['VELRON_VCP_TOKEN'] = $VcpToken
    }
    $document = [ordered]@{
        mcpServers = [ordered]@{
            velron = [ordered]@{
                command = $clientPath
                args = @()
                env = $genericEnvironment
            }
        }
    }
    Save-Json $genericConfig $document
    Write-Ok 'Created generic stdio MCP configuration'
}

if ($installServerComponent -and $Autostart -eq 'yes') {
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    New-Item -Path $runKey -Force | Out-Null
    $startupScript = Join-Path $dataDir 'server-start.ps1'
    $escapedDataDir = $dataDir.Replace("'", "''")
    $escapedServerPath = $serverPath.Replace("'", "''")
    $startupContents = "`$env:VELRON_HOME = '$escapedDataDir'`r`n& '$escapedServerPath'`r`n"
    [IO.File]::WriteAllText($startupScript, $startupContents, [Text.UTF8Encoding]::new($false))
    Set-ItemProperty -Path $runKey -Name 'Velron Server' -Value ("powershell.exe -NoProfile -WindowStyle Hidden -File `"{0}`"" -f $startupScript)
    Write-Ok 'Registered Velron Server in Windows startup apps'
} elseif ($installServerComponent -and $Autostart -eq 'no') {
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Velron Server' -ErrorAction SilentlyContinue
}

if ($installServerComponent -and $StartServer -eq 'yes') {
    $oldVelronHomeForServer = $env:VELRON_HOME
    try {
        $env:VELRON_HOME = $dataDir
        Start-Process -FilePath $serverPath -WorkingDirectory $InstallDir -WindowStyle Hidden
    } finally { $env:VELRON_HOME = $oldVelronHomeForServer }
    Write-Ok 'Started Velron Server'
}

if (-not $ServerHost) { $ServerHost = '127.0.0.1' }
if (-not $ServerPort) { $ServerPort = 4141 }
$dashboardHost = if ($ServerHost -in @('0.0.0.0', '::')) { '127.0.0.1' } else { $ServerHost }
$dashboardUrl = "http://${dashboardHost}:$ServerPort/"
if ($installServerComponent -and $StartServer -eq 'yes') {
    $ready = $false
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try {
            Invoke-WebRequest -Uri $dashboardUrl -UseBasicParsing -TimeoutSec 1 | Out-Null
            $ready = $true
            break
        } catch { Start-Sleep -Seconds 1 }
    }
    if ($ready) { Write-Ok "Server is ready at $dashboardUrl" }
    else { Write-WarningMessage "Server is still starting. Run $serverPath in a terminal to inspect its output." }
}

Write-Host "`nVelron is ready." -ForegroundColor Green
Write-Host "  Binaries: $InstallDir"
Write-Host "  Data:     $dataDir"
if ($installServerComponent) { Write-Host "  Dashboard: $dashboardUrl" }
if ($genericConfig) { Write-Host "  stdio MCP config: $genericConfig" }
if ($ClientTarget -in @('codex', 'both')) {
    Write-Host "  Codex fallback: codex plugin marketplace add `"$marketplaceDir`"; codex plugin add velron@velron-local"
}
if ($ClientTarget -in @('claude', 'both')) {
    Write-Host "  Claude fallback: claude plugin marketplace add `"$marketplaceDir`" --scope user; claude plugin install velron@velron-local --scope user"
}
Write-Host 'Open a new terminal before using velron or velron-client from PATH.' -ForegroundColor DarkGray
if ($ClientTarget -in @('codex', 'both')) {
    Write-WarningMessage 'Start a new Codex session, open /hooks, and trust the Velron PreToolUse hook after checking its pinned path.'
}

if ($installServerComponent -and $OpenDashboard -eq 'yes') {
    $tokenPath = Join-Path $dataDir 'management-token'
    if (Test-Path -LiteralPath $tokenPath -PathType Leaf) {
        $token = (Get-Content -Raw -LiteralPath $tokenPath).Trim()
        $dashboardUrl = "$dashboardUrl#managementToken=$token"
    }
    Start-Process $dashboardUrl
}
