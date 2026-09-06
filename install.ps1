$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repository = 'CodingManFocus/velronRelease'
$latestBaseUrl = "https://github.com/$repository/releases/latest/download"
$defaultHttpPort = 4141
$defaultVcpPort = 4143
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-Info([string]$Message) {
    Write-Host 'i ' -ForegroundColor Blue -NoNewline
    Write-Host $Message
}

function Write-Success([string]$Message) {
    Write-Host "$([char]0x2713) " -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Write-WarningMessage([string]$Message) {
    Write-Host '! ' -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}

function Read-Value([string]$Label, [string]$Default = '') {
    if ($Default) {
        $answer = Read-Host "$Label [$Default]"
    } else {
        $answer = Read-Host $Label
    }
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function Read-SecretValue([string]$Label) {
    $secure = Read-Host $Label -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Read-Menu([string]$Title, [string[]]$Items) {
    Write-Host ''
    Write-Host $Title -ForegroundColor White
    for ($index = 0; $index -lt $Items.Count; $index++) {
        Write-Host "  $($index + 1)) " -ForegroundColor Blue -NoNewline
        Write-Host $Items[$index]
    }
    while ($true) {
        $answer = Read-Host 'Select [1]'
        if ([string]::IsNullOrWhiteSpace($answer)) { return 1 }
        $choice = 0
        if ([int]::TryParse($answer, [ref]$choice) -and $choice -ge 1 -and $choice -le $Items.Count) {
            return $choice
        }
        Write-WarningMessage "Enter a number from 1 to $($Items.Count)."
    }
}

function Read-Confirmation([string]$Label, [bool]$Default = $true) {
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $answer = (Read-Host "$Label [$hint]").Trim().ToLowerInvariant()
        if (-not $answer) { return $Default }
        if ($answer -in @('y', 'yes')) { return $true }
        if ($answer -in @('n', 'no')) { return $false }
        Write-WarningMessage 'Enter y or n.'
    }
}

function Resolve-AbsolutePath([string]$Value) {
    $expanded = [Environment]::ExpandEnvironmentVariables($Value)
    if ($expanded -eq '~') { $expanded = $HOME }
    if ($expanded.StartsWith('~\') -or $expanded.StartsWith('~/')) {
        $expanded = Join-Path $HOME $expanded.Substring(2)
    }
    if (-not [IO.Path]::IsPathRooted($expanded)) {
        throw "Path must be absolute: $expanded"
    }
    return [IO.Path]::GetFullPath($expanded)
}

function Read-Port([string]$Label, [int]$Default) {
    while ($true) {
        $text = Read-Value $Label "$Default"
        $port = 0
        if ([int]::TryParse($text, [ref]$port) -and $port -ge 1 -and $port -le 65535) {
            return $port
        }
        Write-WarningMessage 'Enter an integer between 1 and 65535.'
    }
}

function Assert-VcpUrl([string]$Value) {
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'wss' -or
        $uri.AbsolutePath -ne '/vcp/v1' -or
        $uri.Query -or
        $uri.Fragment -or
        $uri.UserInfo) {
        throw 'Remote VCP URL must use wss://, target exactly /vcp/v1, and contain no credentials, query, or fragment.'
    }
}

function Write-PrivateUtf8File([string]$Path, [string]$Content) {
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = "$Path.tmp.$PID"
    [IO.File]::WriteAllText($temporary, $Content, $script:utf8NoBom)
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Install-VerifiedAsset([string]$AssetName, [string]$Destination, [string]$ChecksumsPath, [string]$TemporaryDirectory) {
    $downloadPath = Join-Path $TemporaryDirectory $AssetName
    Write-Info "Downloading $AssetName..."
    Invoke-WebRequest -UseBasicParsing -Uri "$script:latestBaseUrl/$AssetName" -OutFile $downloadPath
    $line = Get-Content -LiteralPath $ChecksumsPath | Where-Object {
        $_ -match "^[0-9a-fA-F]{64}\s+\*?$([regex]::Escape($AssetName))$"
    } | Select-Object -First 1
    if (-not $line) { throw "No checksum was published for $AssetName." }
    $expected = ($line -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $downloadPath).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw "SHA-256 verification failed for $AssetName." }
    Write-Success "Verified $AssetName"
    $destinationDirectory = Split-Path -Parent $Destination
    [IO.Directory]::CreateDirectory($destinationDirectory) | Out-Null
    $staged = "$Destination.new.$PID"
    Copy-Item -LiteralPath $downloadPath -Destination $staged -Force
    Move-Item -LiteralPath $staged -Destination $Destination -Force
}

function Add-UserPath([string]$Directory) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($userPath -split ';' | Where-Object { $_ })
    if (-not ($parts | Where-Object { $_.TrimEnd('\') -ieq $Directory.TrimEnd('\') })) {
        $newPath = (@($Directory) + $parts) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    }
    if (-not (($env:Path -split ';') | Where-Object { $_.TrimEnd('\') -ieq $Directory.TrimEnd('\') })) {
        $env:Path = "$Directory;$env:Path"
    }
}

function Set-OptionalUserEnvironment([string]$Name, [string]$Value) {
    if ($Value) {
        [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
        [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
    } else {
        [Environment]::SetEnvironmentVariable($Name, $null, 'User')
        [Environment]::SetEnvironmentVariable($Name, $null, 'Process')
    }
}

function Install-StartupShortcut([string]$ServerPath, [string]$WorkingDirectory) {
    $startupDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
    [IO.Directory]::CreateDirectory($startupDirectory) | Out-Null
    $shortcutPath = Join-Path $startupDirectory 'Velron Server.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $ServerPath
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.Description = 'Start Velron Server when signing in'
    $shortcut.Save()
    Write-Success 'Registered Velron Server in Startup'
}

function Remove-StartupShortcut {
    $startupDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
    $shortcutPath = Join-Path $startupDirectory 'Velron Server.lnk'
    if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
        Remove-Item -LiteralPath $shortcutPath -Force
    }
}

function Invoke-HostCommandSilently([string]$HostName, [string[]]$Arguments) {
    # Host diagnostics may include configured environment variables and tokens.
    $ErrorActionPreference = 'Continue'
    try {
        & $HostName @Arguments *> $null
        return $LASTEXITCODE
    } catch {
        return -1
    }
}

function Install-HostMcp(
    [ValidateSet('codex', 'claude')][string]$HostName,
    [string]$ClientPath,
    [System.Collections.IDictionary]$ClientEnvironment,
    [string]$ConfigPath
) {
    $hostLabel = if ($HostName -eq 'codex') { 'Codex' } else { 'Claude Code' }
    $commandArguments = if ($HostName -eq 'codex') {
        @('mcp', 'add', 'velron')
    } else {
        @('mcp', 'add', '--transport', 'stdio', '--scope', 'user', 'velron')
    }
    $commandText = "$HostName $($commandArguments -join ' ')"
    foreach ($name in $ClientEnvironment.Keys) {
        $commandArguments += @('--env', "$name=$($ClientEnvironment[$name])")
        # Print references to the installed user environment, never its secret values.
        $commandText += ' --env "{0}=$env:{0}"' -f $name
    }
    $commandArguments += @('--', $ClientPath, 'mcp')
    $quotedClientPath = "'" + $ClientPath.Replace("'", "''") + "'"
    $commandText += " -- $quotedClientPath mcp"

    if (-not (Get-Command $HostName -ErrorAction SilentlyContinue)) {
        Write-WarningMessage "$hostLabel CLI was not found. Install it, open a new terminal, and run:"
        Write-Host "  $commandText"
        Write-Info "The equivalent stdio MCP configuration is saved at $ConfigPath"
        return
    }

    if ((Invoke-HostCommandSilently $HostName @('mcp', 'get', '--help')) -ne 0) {
        Write-WarningMessage "Could not inspect $hostLabel MCP settings. Check existing entries, then run:"
        Write-Host "  $commandText"
        return
    }

    if ((Invoke-HostCommandSilently $HostName @('mcp', 'get', 'velron')) -eq 0) {
        Write-WarningMessage "$hostLabel already has a velron MCP entry; it was preserved."
        Write-Host "  Review it with: $HostName mcp get velron"
        if ($HostName -eq 'codex') {
            Write-Host '  To replace that entry, first run: codex mcp remove velron'
        } else {
            Write-Host '  To replace that entry, first run: claude mcp remove velron'
            Write-Host '  Select the existing entry''s scope if prompted.'
        }
        Write-Host '  Then register the new Client with:'
        Write-Host "  $commandText"
        return
    }

    if ((Invoke-HostCommandSilently $HostName $commandArguments) -eq 0) {
        Write-Success "Registered Velron as a stdio MCP server for $hostLabel"
    } else {
        Write-WarningMessage "$hostLabel MCP registration did not finish. Review the host settings, then run:"
        Write-Host "  $commandText"
        Write-Info "The equivalent stdio MCP configuration is saved at $ConfigPath"
    }
}

Write-Host 'Velron installer' -ForegroundColor Blue
Write-Host 'Server, Client, stdio MCP, PATH, and startup setup'

$architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$architectureName = switch ($architecture) {
    'x64' { 'x64' }
    'arm64' { 'arm64' }
    default { throw "Unsupported Windows architecture: $architecture" }
}

$installChoice = Read-Menu 'What do you want to install?' @('Server and Client', 'Server only', 'Client only')
$installServer = $installChoice -in @(1, 2)
$installClient = $installChoice -in @(1, 3)

$defaultVelronHome = Join-Path $HOME '.velron'
$velronHome = Resolve-AbsolutePath (Read-Value 'Velron data and configuration directory' $defaultVelronHome)
$defaultInstallDirectory = Join-Path $env:LOCALAPPDATA 'Programs\Velron\bin'
$installDirectory = Resolve-AbsolutePath (Read-Value 'Command directory (added to PATH)' $defaultInstallDirectory)

$serverHost = '127.0.0.1'
$serverHttpPort = $defaultHttpPort
$serverVcpPort = $defaultVcpPort
$serverAllowedHosts = @()
$writeServerConfig = $false
$enableAutostart = $false
$startServerNow = $false
if ($installServer) {
    $existingConfigPath = Join-Path $velronHome 'config.json'
    if ((Test-Path -LiteralPath $existingConfigPath -PathType Leaf) -and
        (Read-Confirmation "Keep the existing Server config at $existingConfigPath?" $true)) {
        try {
            $existingConfig = Get-Content -Raw -LiteralPath $existingConfigPath | ConvertFrom-Json
            if ($existingConfig.localVcpPort) { $serverVcpPort = [int]$existingConfig.localVcpPort }
        } catch {
            Write-WarningMessage 'The existing config could not be read by the installer; Velron will validate it when started.'
        }
    } else {
        $writeServerConfig = $true
        $serverHost = Read-Value 'Server bind host' $serverHost
        $serverHttpPort = Read-Port 'Management HTTP port' $serverHttpPort
        $serverVcpPort = Read-Port 'Pinned local VCP port' $serverVcpPort
        if ($serverHttpPort -eq $serverVcpPort) { throw 'HTTP and VCP ports must differ.' }
        $allowedText = Read-Value 'Additional allowed hosts (comma-separated, optional)'
        if ($allowedText) { $serverAllowedHosts = @($allowedText -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    }
    $enableAutostart = Read-Confirmation 'Start Velron Server automatically when you sign in?' $true
    $startServerNow = Read-Confirmation 'Start Velron Server after installation?' $true
}

$vcpMode = 'local'
$vcpUrl = "wss://127.0.0.1:$serverVcpPort/vcp/v1"
$vcpToken = ''
$integrationChoice = 0
if ($installClient) {
    Write-Host ''
    Write-Host 'Client connection' -ForegroundColor White
    Write-Host 'Press Enter to use automatic local discovery. Enter a different wss:// URL for a remote Server.'
    $enteredVcpUrl = Read-Value 'VCP URL' $vcpUrl
    if ($enteredVcpUrl -ne $vcpUrl) {
        Assert-VcpUrl $enteredVcpUrl
        $vcpMode = 'remote'
        $vcpUrl = $enteredVcpUrl
        $vcpToken = Read-SecretValue 'VCP access token'
        if ($vcpToken -notmatch '^[A-Za-z0-9_-]{43}$') {
            throw 'VCP token must be a 43-character base64url value.'
        }
    }
    $integrationChoice = Read-Menu 'Where should Velron Client be connected?' @(
        'Codex',
        'Claude Code',
        'Codex and Claude Code',
        'Other... (generic stdio MCP)'
    )
    Write-Info 'The agent supplies the absolute workspaceDir path in each call_agent invocation.'
}

Write-Host ''
Write-Host 'Installation summary' -ForegroundColor White
$components = if ($installServer -and $installClient) { 'Server + Client' } elseif ($installServer) { 'Server' } else { 'Client' }
Write-Host "  Platform:        windows-$architectureName"
Write-Host "  Components:      $components"
Write-Host "  Velron home:     $velronHome"
Write-Host "  Command path:    $installDirectory"
if ($installClient) { Write-Host "  VCP:             $vcpUrl ($vcpMode)" }
if (-not (Read-Confirmation 'Continue?' $true)) {
    Write-Info 'Installation cancelled.'
    return
}

$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) "velron-installer-$([guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($temporaryDirectory) | Out-Null
try {
    $checksumsPath = Join-Path $temporaryDirectory 'SHA256SUMS.txt'
    Write-Info 'Downloading release checksums...'
    Invoke-WebRequest -UseBasicParsing -Uri "$latestBaseUrl/SHA256SUMS.txt" -OutFile $checksumsPath
    [IO.Directory]::CreateDirectory($installDirectory) | Out-Null
    [IO.Directory]::CreateDirectory($velronHome) | Out-Null

    $serverPath = Join-Path $installDirectory 'velron.exe'
    $clientPath = Join-Path $installDirectory 'velron-client.exe'
    if ($installServer) {
        Install-VerifiedAsset "velron-windows-$architectureName.exe" $serverPath $checksumsPath $temporaryDirectory
    }
    if ($installClient) {
        Install-VerifiedAsset "velron-client-windows-$architectureName.exe" $clientPath $checksumsPath $temporaryDirectory
    }

    [Environment]::SetEnvironmentVariable('VELRON_HOME', $velronHome, 'User')
    [Environment]::SetEnvironmentVariable('VELRON_HOME', $velronHome, 'Process')
    if ($installClient) {
        if ($vcpMode -eq 'remote') {
            Set-OptionalUserEnvironment 'VELRON_VCP_URL' $vcpUrl
            Set-OptionalUserEnvironment 'VELRON_VCP_TOKEN' $vcpToken
        } else {
            Set-OptionalUserEnvironment 'VELRON_VCP_URL' ''
            Set-OptionalUserEnvironment 'VELRON_VCP_TOKEN' ''
        }
    }

    if ($installServer -and $writeServerConfig) {
        $serverConfig = [ordered]@{
            schemaVersion = 1
            host = $serverHost
            port = $serverHttpPort
            localVcpPort = $serverVcpPort
            allowedHosts = $serverAllowedHosts
            managementSecureCookies = $false
            maxConcurrentRuns = 4
            maxRunStartsPerMinute = 60
            maxRunContextBytes = 8388608
        }
        Write-PrivateUtf8File (Join-Path $velronHome 'config.json') (($serverConfig | ConvertTo-Json -Depth 4) + "`n")
    }

    Add-UserPath $installDirectory
    Write-Success 'Added Velron commands to the user PATH'

    if ($installClient) {
        $clientEnvironment = [ordered]@{ VELRON_HOME = $velronHome }
        if ($vcpMode -eq 'remote') {
            $clientEnvironment['VELRON_VCP_URL'] = $vcpUrl
            $clientEnvironment['VELRON_VCP_TOKEN'] = $vcpToken
        }
        $stdioConfig = [ordered]@{
            mcpServers = [ordered]@{
                velron = [ordered]@{
                    type = 'stdio'
                    command = $clientPath
                    args = @('mcp')
                    env = $clientEnvironment
                }
            }
        }
        $stdioConfigPath = Join-Path $velronHome 'stdio-mcp.json'
        Write-PrivateUtf8File $stdioConfigPath (($stdioConfig | ConvertTo-Json -Depth 8) + "`n")
        Write-Success "Wrote generic stdio MCP configuration to $stdioConfigPath"
        switch ($integrationChoice) {
            1 { Install-HostMcp codex $clientPath $clientEnvironment $stdioConfigPath }
            2 { Install-HostMcp claude $clientPath $clientEnvironment $stdioConfigPath }
            3 {
                Install-HostMcp codex $clientPath $clientEnvironment $stdioConfigPath
                Install-HostMcp claude $clientPath $clientEnvironment $stdioConfigPath
            }
            4 {
                Write-Info "Merge the velron entry from $stdioConfigPath into your MCP host settings."
            }
        }
        Write-Info 'If upgrading from the old Plugin, remove its host Plugin and Velron PreToolUse Hook registrations manually, then restart the host.'
        Write-Info 'call_agent accepts workspaceDir as an absolute path on the Client machine; no workspace setup or Hook approval is required.'
    }

    if ($installServer) {
        if ($enableAutostart) {
            Install-StartupShortcut $serverPath $installDirectory
        } else {
            Remove-StartupShortcut
            Write-Info 'Velron Server autostart is disabled'
        }
        if ($startServerNow) {
            Start-Process -FilePath $serverPath -WorkingDirectory $installDirectory
            Write-Success 'Started Velron Server'
        }
    }
} finally {
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}

Write-Host ''
Write-Success 'Velron installation is complete.'
Write-Host 'Open a new terminal, then run:'
if ($installServer) { Write-Host '  velron' }
if ($installClient) { Write-Host '  velron-client --help' }
if ($installClient) { Write-Host 'Restart your MCP host to load the stdio connection.' }
