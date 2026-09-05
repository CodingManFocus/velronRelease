#!/usr/bin/env sh
set -eu

repo="CodingManFocus/velronRelease"
releaseBase="https://github.com/$repo/releases/latest/download"
defaultVcpPort="4143"
components=""
clientTarget=""
vcpUrl=""
vcpToken=""
workspaceRoot=""
serverHost=""
serverPort=""
localVcpPort=""
installDir="${VELRON_INSTALL_DIR:-$HOME/.local/bin}"
defaultDataDir="$HOME/.velron"
dataDir="${VELRON_HOME:-$defaultDataDir}"
autoStart=""
startServer=""
openDashboard=""
assumeYes="false"

if [ -t 1 ]; then
  cyan='\033[36m'; green='\033[32m'; yellow='\033[33m'; red='\033[31m'; dim='\033[2m'; reset='\033[0m'
else
  cyan=''; green=''; yellow=''; red=''; dim=''; reset=''
fi
singleQuote="'"

say() { printf '%b\n' "$*"; }
info() { say "${cyan}◆${reset} $*"; }
ok() { say "${green}✓${reset} $*"; }
warn() { say "${yellow}!${reset} $*"; }
fail() { say "${red}Error:${reset} $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Velron installer

Usage:
  install.sh [options]

Options:
  --components server|client|all
  --client-target codex|claude|both|other|none
  --vcp-url URL              Default: automatic local VCP discovery
  --vcp-token TOKEN          Required with a custom VCP URL
  --workspace PATH           Fixed workspace for --client-target other
  --install-dir PATH
  --server-host HOST         Default: 127.0.0.1
  --server-port PORT         Default: 4141
  --local-vcp-port PORT      Default: 4143
  --autostart yes|no
  --start-server yes|no
  --open-dashboard yes|no
  --yes                      Accept recommended defaults
  --help

Example:
  curl -fsSL https://raw.githubusercontent.com/CodingManFocus/velronRelease/main/install.sh | sh
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --components) components=${2-}; shift 2 ;;
    --client-target) clientTarget=${2-}; shift 2 ;;
    --vcp-url) vcpUrl=${2-}; shift 2 ;;
    --vcp-token) vcpToken=${2-}; shift 2 ;;
    --workspace) workspaceRoot=${2-}; shift 2 ;;
    --install-dir) installDir=${2-}; shift 2 ;;
    --server-host) serverHost=${2-}; shift 2 ;;
    --server-port) serverPort=${2-}; shift 2 ;;
    --local-vcp-port) localVcpPort=${2-}; shift 2 ;;
    --autostart) autoStart=${2-}; shift 2 ;;
    --start-server) startServer=${2-}; shift 2 ;;
    --open-dashboard) openDashboard=${2-}; shift 2 ;;
    --yes|-y) assumeYes="true"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

readAnswer() {
  prompt=$1
  if [ ! -r /dev/tty ]; then fail "Interactive input needs a terminal. Use --yes and explicit options."; fi
  printf '%b' "$prompt" >/dev/tty
  IFS= read -r answer </dev/tty || fail "Input was cancelled."
  printf '%s' "$answer"
}

promptDefault() {
  label=$1; defaultValue=$2
  answer=$(readAnswer "$label ${dim}[$defaultValue]${reset}: ")
  if [ -z "$answer" ]; then answer=$defaultValue; fi
  printf '%s' "$answer"
}

promptSecret() {
  label=$1
  [ -r /dev/tty ] || fail "A VCP token is required. Pass --vcp-token in non-interactive mode."
  printf '%b' "$label: " >/dev/tty
  stty -echo </dev/tty 2>/dev/null || true
  IFS= read -r answer </dev/tty || { stty echo </dev/tty 2>/dev/null || true; fail "Input was cancelled."; }
  stty echo </dev/tty 2>/dev/null || true
  printf '\n' >/dev/tty
  printf '%s' "$answer"
}

choose() {
  title=$1; defaultChoice=$2
  shift 2
  printf '%b\n' "\n${cyan}$title${reset}" >/dev/tty
  index=1
  for option in "$@"; do printf '%s\n' "  $index) $option" >/dev/tty; index=$((index + 1)); done
  while :; do
    answer=$(readAnswer "Choose ${dim}[$defaultChoice]${reset}: ")
    [ -n "$answer" ] || answer=$defaultChoice
    case "$answer" in *[!0-9]*|'') printf '%s\n' "! Enter a number." >/dev/tty ;; *)
      if [ "$answer" -ge 1 ] 2>/dev/null && [ "$answer" -lt "$index" ]; then printf '%s' "$answer"; return; fi
      printf '%s\n' "! Choose a listed option." >/dev/tty ;;
    esac
  done
}

askYesNo() {
  label=$1; defaultValue=$2
  if [ "$assumeYes" = "true" ]; then printf '%s' "$defaultValue"; return; fi
  suffix="y/N"; [ "$defaultValue" = "yes" ] && suffix="Y/n"
  while :; do
    answer=$(readAnswer "$label ${dim}[$suffix]${reset}: ")
    [ -n "$answer" ] || answer=$defaultValue
    case "$answer" in y|Y|yes|YES) printf 'yes'; return ;; n|N|no|NO) printf 'no'; return ;; *) printf '%s\n' "! Enter y or n." >/dev/tty ;; esac
  done
}

validatePort() {
  value=$1
  case "$value" in ''|*[!0-9]*) fail "Invalid port: $value" ;; esac
  if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then fail "Port must be between 1 and 65535."; fi
}

validateVcpUrl() {
  value=$1
  case "$value" in
    wss://*/vcp/v1) ;;
    *) fail "VCP URL must be a wss:// URL ending exactly in /vcp/v1." ;;
  esac
  case "$value" in *'?'*|*'#'*|*'"'*) fail "VCP URL cannot contain query, fragment, or quote characters." ;; esac
  case "$value" in *"$singleQuote"*) fail "VCP URL cannot contain quote characters." ;; esac
  authority=${value#wss://}; authority=${authority%/vcp/v1}
  case "$authority" in ''|*'/'*|*'@'*) fail "VCP URL must contain only a host and optional port before /vcp/v1." ;; esac
}

validateToken() {
  value=$1
  [ "${#value}" -eq 43 ] || fail "VCP token must be a 43-character base64url token."
  case "$value" in *[!A-Za-z0-9_-]*) fail "VCP token contains invalid characters." ;; esac
}

isAbsolutePath() { case "$1" in /*) return 0 ;; *) return 1 ;; esac; }

say "${cyan}╭────────────────────────────────────╮${reset}"
say "${cyan}│${reset}       ${green}VELRON SETUP${reset}  Initial wizard   ${cyan}│${reset}"
say "${cyan}╰────────────────────────────────────╯${reset}"
say "${dim}Server, local bridge, and coding-agent integration.${reset}"
say "${dim}License: https://github.com/$repo/blob/main/LICENSE${reset}"
if [ "$assumeYes" != "true" ]; then
  accepted=$(askYesNo "Continue and accept the Velron license terms?" "yes")
  [ "$accepted" = "yes" ] || { say "Setup cancelled."; exit 0; }
fi

if [ -z "$components" ]; then
  if [ "$assumeYes" = "true" ]; then components="all"; else
    choice=$(choose "What would you like to install?" 1 "Server + Client (recommended)" "Server only" "Client only")
    case "$choice" in 1) components="all" ;; 2) components="server" ;; 3) components="client" ;; esac
  fi
fi
case "$components" in server|client|all) ;; *) fail "--components must be server, client, or all." ;; esac

installServer="false"; installClient="false"
case "$components" in server) installServer="true" ;; client) installClient="true" ;; all) installServer="true"; installClient="true" ;; esac

if [ "$assumeYes" != "true" ]; then installDir=$(promptDefault "Install directory" "$installDir"); fi
isAbsolutePath "$installDir" || fail "Install directory must be absolute."
case "$installDir" in *'"'*|*'\\'*|*'&'*|*'<'*|*'>'*|*'\n'*) fail "Install directory contains characters that cannot be safely pinned in a Velron Hook." ;; esac
case "$installDir" in *"$singleQuote"*) fail "Install directory contains a quote character that cannot be safely pinned in a Velron Hook." ;; esac
case "$dataDir" in *'"'*|*'&'*|*'<'*|*'>'*|*'\n'*) fail "VELRON_HOME contains characters that cannot be safely written to startup configuration." ;; esac
case "$dataDir" in *"$singleQuote"*) fail "VELRON_HOME cannot contain a quote character during installation." ;; esac

configExists="false"
[ -f "$dataDir/config.json" ] && configExists="true"
if [ "$installServer" = "true" ]; then
  configureServer="yes"
  if [ "$configExists" = "true" ]; then configureServer=$(askYesNo "Keep existing Server settings in $dataDir/config.json?" "yes"); fi
  if [ "$configureServer" = "yes" ] && [ "$configExists" = "true" ]; then
    info "Existing Server settings will be preserved."
    existingHost=$(sed -n 's/^[[:space:]]*"host"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$dataDir/config.json" | head -n 1)
    existingPort=$(sed -n 's/^[[:space:]]*"port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$dataDir/config.json" | head -n 1)
    existingVcpPort=$(sed -n 's/^[[:space:]]*"localVcpPort"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$dataDir/config.json" | head -n 1)
    serverHost="${serverHost:-${existingHost:-127.0.0.1}}"
    serverPort="${serverPort:-${existingPort:-4141}}"
    localVcpPort="${localVcpPort:-${existingVcpPort:-$defaultVcpPort}}"
  else
    serverHost="${serverHost:-127.0.0.1}"; serverPort="${serverPort:-4141}"; localVcpPort="${localVcpPort:-$defaultVcpPort}"
    if [ "$assumeYes" != "true" ]; then
      say "\n${cyan}Server settings${reset}"
      serverHost=$(promptDefault "Bind host" "$serverHost")
      serverPort=$(promptDefault "Dashboard port" "$serverPort")
      localVcpPort=$(promptDefault "Local VCP port" "$localVcpPort")
    fi
    validatePort "$serverPort"; validatePort "$localVcpPort"
    [ "$serverPort" != "$localVcpPort" ] || fail "Dashboard and local VCP ports must differ."
    case "$serverHost" in ''|*[!A-Za-z0-9.:-]*) fail "Bind host must be an IP address or DNS hostname." ;; esac
    case "$serverHost" in 0.0.0.0|::) warn "The dashboard will listen beyond localhost. Configure firewall and allowed hosts in Velron." ;; esac
  fi
  autoStart=${autoStart:-$(askYesNo "Start Velron Server automatically when you sign in?" "yes")}
  startServer=${startServer:-$(askYesNo "Start Velron Server after installation?" "yes")}
  openDashboard=${openDashboard:-$(askYesNo "Open the dashboard when setup finishes?" "yes")}
fi

if [ -z "$localVcpPort" ] && [ -f "$dataDir/local-vcp.json" ]; then
  discoveredPort=$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$dataDir/local-vcp.json" | head -n 1)
  localVcpPort=${discoveredPort:-$defaultVcpPort}
fi
validatePort "${localVcpPort:-$defaultVcpPort}"
localSuggestedUrl="wss://127.0.0.1:${localVcpPort:-$defaultVcpPort}/vcp/v1"
customVcp="false"
if [ "$installClient" = "true" ]; then
  if [ -z "$vcpUrl" ]; then
    if [ "$assumeYes" = "true" ]; then vcpUrl=$localSuggestedUrl; else
      say "\n${cyan}Client connection${reset}"
      say "${dim}Press Enter to use secure automatic local discovery.${reset}"
      vcpUrl=$(promptDefault "VCP URL" "$localSuggestedUrl")
    fi
  fi
  validateVcpUrl "$vcpUrl"
  if [ "$vcpUrl" != "$localSuggestedUrl" ]; then
    customVcp="true"
    [ -n "$vcpToken" ] || vcpToken=$(promptSecret "VCP access token")
    validateToken "$vcpToken"
  fi
  if [ -z "$clientTarget" ]; then
    if [ "$assumeYes" = "true" ]; then clientTarget="both"; else
      choice=$(choose "Where should Velron Client be connected?" 3 "Codex" "Claude Code" "Codex + Claude Code (recommended)" "Other… (generic stdio MCP)" "Not now")
      case "$choice" in 1) clientTarget="codex" ;; 2) clientTarget="claude" ;; 3) clientTarget="both" ;; 4) clientTarget="other" ;; 5) clientTarget="none" ;; esac
    fi
  fi
  case "$clientTarget" in codex|claude|both|other|none) ;; *) fail "Invalid --client-target." ;; esac
  if [ "$clientTarget" = "other" ]; then
    [ -n "$workspaceRoot" ] || workspaceRoot=$(promptDefault "Workspace directory" "$(pwd)")
    isAbsolutePath "$workspaceRoot" || fail "Workspace directory must be absolute."
    [ -d "$workspaceRoot" ] || fail "Workspace directory does not exist: $workspaceRoot"
    case "$workspaceRoot" in *'"'*|*'\n'*) fail "Workspace directory cannot contain quote or newline characters." ;; esac
  fi
fi

case "$(uname -s)" in Linux) platform="linux" ;; Darwin) platform="macos" ;; *) fail "Unsupported OS. Use install.ps1 on Windows." ;; esac
case "$(uname -m)" in x86_64|amd64) architecture="x64" ;; arm64|aarch64) architecture="arm64" ;; *) fail "Unsupported architecture: $(uname -m)" ;; esac

command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || fail "curl or wget is required."
mkdir -p "$installDir" "$dataDir"
chmod 700 "$dataDir" 2>/dev/null || true
tempDir=$(mktemp -d "${TMPDIR:-/tmp}/velron-install.XXXXXX")
trap 'rm -rf -- "$tempDir"' EXIT HUP INT TERM

download() {
  url=$1; destination=$2
  if command -v curl >/dev/null 2>&1; then
    if [ -n "${GITHUB_TOKEN:-}" ]; then curl -fL --retry 3 --connect-timeout 15 -H "Authorization: Bearer $GITHUB_TOKEN" -o "$destination" "$url"
    else curl -fL --retry 3 --connect-timeout 15 -o "$destination" "$url"; fi
  else
    if [ -n "${GITHUB_TOKEN:-}" ]; then wget --header="Authorization: Bearer $GITHUB_TOKEN" -O "$destination" "$url"
    else wget -O "$destination" "$url"; fi
  fi
}

verifyAsset() {
  asset=$1; file=$2
  expected=$(awk -v name="$asset" '$2 == name || $2 == "*" name { print $1; exit }' "$tempDir/SHA256SUMS.txt")
  [ -n "$expected" ] || fail "No checksum was published for $asset."
  if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$file" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then actual=$(shasum -a 256 "$file" | awk '{print $1}')
  else fail "sha256sum or shasum is required to verify downloads."; fi
  [ "$actual" = "$expected" ] || fail "Checksum verification failed for $asset. Existing files were not changed."
  ok "Verified $asset"
}

info "Downloading release checksums…"
download "$releaseBase/SHA256SUMS.txt" "$tempDir/SHA256SUMS.txt"

serverPath="$installDir/velron"
clientPath="$installDir/velron-client"
if [ "$installServer" = "true" ]; then
  serverAsset="velron-$platform-$architecture"
  info "Downloading Velron Server ($platform/$architecture)…"
  download "$releaseBase/$serverAsset" "$tempDir/$serverAsset"
  verifyAsset "$serverAsset" "$tempDir/$serverAsset"
fi
if [ "$installClient" = "true" ]; then
  clientAsset="velron-client-$platform-$architecture"
  info "Downloading Velron Client ($platform/$architecture)…"
  download "$releaseBase/$clientAsset" "$tempDir/$clientAsset"
  verifyAsset "$clientAsset" "$tempDir/$clientAsset"
fi

if [ "$installServer" = "true" ]; then chmod 755 "$tempDir/$serverAsset"; mv -f "$tempDir/$serverAsset" "$serverPath"; fi
if [ "$installClient" = "true" ]; then chmod 755 "$tempDir/$clientAsset"; mv -f "$tempDir/$clientAsset" "$clientPath"; fi

if [ "$installServer" = "true" ] && { [ "$configExists" = "false" ] || [ "$configureServer" = "no" ]; }; then
  umask 077
  configTemp="$dataDir/config.json.new.$$"
  cat >"$configTemp" <<EOF
{
  "schemaVersion": 1,
  "host": "$serverHost",
  "port": $serverPort,
  "localVcpPort": $localVcpPort,
  "allowedHosts": [],
  "managementSecureCookies": false,
  "maxConcurrentRuns": 4,
  "maxRunStartsPerMinute": 60,
  "maxRunContextBytes": 8388608
}
EOF
  mv -f "$configTemp" "$dataDir/config.json"
  ok "Created Server settings"
fi

addPathLine() {
  profile=$1
  marker="# Added by Velron installer"
  [ -f "$profile" ] && grep -F "$marker" "$profile" >/dev/null 2>&1 && return
  {
    printf '\n%s\n' "$marker"
    printf 'export PATH="%s:$%s"\n' "$installDir" 'PATH'
  } >>"$profile"
  ok "Added Velron to PATH in $profile"
}
case "${SHELL:-}" in */zsh) addPathLine "$HOME/.zshrc" ;; */bash) addPathLine "$HOME/.bashrc" ;; *) addPathLine "$HOME/.profile" ;; esac
export PATH="$installDir:$PATH"

marketplaceDir="$dataDir/plugin-marketplace"
pluginDir="$marketplaceDir/plugins/velron"
clientCommand="$clientPath"
if [ "$installClient" = "true" ] && { [ "$customVcp" = "true" ] || [ "$dataDir" != "$defaultDataDir" ]; }; then
  envFile="$dataDir/client.env"
  umask 077
  printf "VELRON_HOME='%s'\nexport VELRON_HOME\n" "$dataDir" >"$envFile"
  if [ "$customVcp" = "true" ]; then
    printf "VELRON_VCP_URL='%s'\nVELRON_VCP_TOKEN='%s'\nexport VELRON_VCP_URL VELRON_VCP_TOKEN\n" "$vcpUrl" "$vcpToken" >>"$envFile"
  fi
  chmod 600 "$envFile"
  clientCommand="$installDir/velron-client-connect"
  cat >"$clientCommand" <<EOF
#!/bin/sh
. '$envFile'
exec '$clientPath' "\$@"
EOF
  chmod 700 "$clientCommand"
fi

patchPluginCommand() {
  file=$1; replacement=$2
  tempFile="$file.new.$$"
  awk -v replacement="$replacement" '
    /"command":/ { sub(/"command": "[^"]*"/, "\"command\": \"" replacement "\"") }
    { print }
  ' "$file" >"$tempFile"
  chmod 600 "$tempFile" 2>/dev/null || true
  mv -f "$tempFile" "$file"
}

setupHostPlugins="false"
case "$clientTarget" in codex|claude|both) setupHostPlugins="true" ;; esac
if [ "$installClient" = "true" ] && [ "$setupHostPlugins" = "true" ]; then
  info "Generating a pinned Velron plugin…"
  if VELRON_HOME="$dataDir" "$clientPath" setup-plugin --client-path "$clientPath" >/dev/null 2>&1; then :
  elif [ -f "$pluginDir/.velron-generated.json" ]; then
    warn "An existing generated plugin was kept. Its pinned Client path must still be $clientPath."
  else
    fail "Plugin generation failed. Review or move the existing $marketplaceDir directory, then rerun setup."
  fi
  if [ "$clientCommand" != "$clientPath" ]; then
    patchPluginCommand "$pluginDir/.mcp.json" "$clientCommand"
    patchPluginCommand "$pluginDir/.codex-plugin/plugin.json" "$clientCommand"
  fi
fi

installCodexPlugin() {
  if command -v codex >/dev/null 2>&1; then
    if codex plugin marketplace add "$marketplaceDir" && codex plugin add velron@velron-local; then ok "Installed the Velron plugin for Codex"
    else warn "Codex did not accept automatic plugin setup. Run the commands shown below."; fi
  else warn "Codex CLI was not found. The plugin is ready for later installation."; fi
}
installClaudePlugin() {
  if command -v claude >/dev/null 2>&1; then
    if claude plugin marketplace add "$marketplaceDir" --scope user && claude plugin install velron@velron-local --scope user; then ok "Installed the Velron plugin for Claude Code"
    else warn "Claude Code did not accept automatic plugin setup. Run the commands shown below."; fi
  else warn "Claude Code CLI was not found. The plugin is ready for later installation."; fi
}
case "$clientTarget" in codex) installCodexPlugin ;; claude) installClaudePlugin ;; both) installCodexPlugin; installClaudePlugin ;; esac

genericConfig=""
if [ "$installClient" = "true" ] && [ "$clientTarget" = "other" ]; then
  genericConfig="$dataDir/stdio-mcp.json"
  umask 077
  escapedWorkspace=$(printf '%s' "$workspaceRoot" | sed 's/\\/\\\\/g; s/"/\\"/g')
  escapedCommand=$(printf '%s' "$clientCommand" | sed 's/\\/\\\\/g; s/"/\\"/g')
  cat >"$genericConfig" <<EOF
{
  "mcpServers": {
    "velron": {
      "command": "$escapedCommand",
      "args": [],
      "env": {
        "VELRON_WORKSPACE_ROOT": "$escapedWorkspace"
      }
    }
  }
}
EOF
  chmod 600 "$genericConfig"
  ok "Created generic stdio MCP configuration"
fi

autoStartLaunched="false"
installAutostart() {
  if [ "$platform" = "macos" ]; then
    launchDir="$HOME/Library/LaunchAgents"; plist="$launchDir/com.codenamemc.velron.plist"
    mkdir -p "$launchDir"
    cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.codenamemc.velron</string>
  <key>ProgramArguments</key><array><string>$serverPath</string></array>
  <key>EnvironmentVariables</key><dict><key>VELRON_HOME</key><string>$dataDir</string></dict>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardOutPath</key><string>$dataDir/server.log</string>
  <key>StandardErrorPath</key><string>$dataDir/server.log</string>
</dict></plist>
EOF
    if [ "$startServer" = "yes" ]; then
      launchctl bootout "gui/$(id -u)/com.codenamemc.velron" >/dev/null 2>&1 || true
      if launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1; then autoStartLaunched="true"
      else warn "LaunchAgent was created but could not be started now."; fi
    fi
    ok "Registered Velron Server as a macOS LaunchAgent"
  elif command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    unitDir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"; unit="$unitDir/velron.service"
    mkdir -p "$unitDir"
    cat >"$unit" <<EOF
[Unit]
Description=Velron Server
After=network-online.target

[Service]
Environment="VELRON_HOME=$dataDir"
ExecStart="$serverPath"
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable velron.service >/dev/null
    if [ "$startServer" = "yes" ] && systemctl --user restart velron.service; then autoStartLaunched="true"; fi
    ok "Registered Velron Server as a systemd user service"
  else
    autostartDir="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"; desktop="$autostartDir/velron.desktop"
    mkdir -p "$autostartDir"
    cat >"$desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Velron Server
Exec=env VELRON_HOME="$dataDir" "$serverPath"
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
    chmod 600 "$desktop"
    ok "Registered Velron Server for desktop login"
  fi
}

removeAutostart() {
  if [ "$platform" = "macos" ]; then
    rm -f -- "$HOME/Library/LaunchAgents/com.codenamemc.velron.plist"
  else
    unit="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/velron.service"
    if [ -f "$unit" ] && command -v systemctl >/dev/null 2>&1; then
      systemctl --user disable velron.service >/dev/null 2>&1 || true
      rm -f -- "$unit"
      systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
    rm -f -- "${XDG_CONFIG_HOME:-$HOME/.config}/autostart/velron.desktop"
  fi
}

if [ "$installServer" = "true" ] && [ "$autoStart" = "yes" ]; then installAutostart; fi
if [ "$installServer" = "true" ] && [ "$autoStart" = "no" ]; then removeAutostart; fi
if [ "$installServer" = "true" ] && [ "$startServer" = "yes" ] && [ "$autoStartLaunched" != "true" ]; then
  VELRON_HOME="$dataDir" nohup "$serverPath" >>"$dataDir/server.log" 2>&1 &
  ok "Started Velron Server"
fi

dashboardHost=$serverHost
case "$dashboardHost" in 0.0.0.0|::) dashboardHost="127.0.0.1" ;; esac
dashboardUrl="http://$dashboardHost:${serverPort:-4141}/"
if [ "$installServer" = "true" ] && [ "$startServer" = "yes" ]; then
  attempts=0
  while [ "$attempts" -lt 20 ]; do
    if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 1 "$dashboardUrl" >/dev/null 2>&1; then break; fi
    attempts=$((attempts + 1)); sleep 1
  done
  if [ "$attempts" -lt 20 ]; then ok "Server is ready at $dashboardUrl"
  else warn "Server is still starting. Check $dataDir/server.log"; fi
fi

say "\n${green}Velron is ready.${reset}"
say "  Binaries: $installDir"
say "  Data:     $dataDir"
[ "$installServer" = "true" ] && say "  Dashboard: $dashboardUrl"
[ -n "$genericConfig" ] && say "  stdio MCP config: $genericConfig"
case "$clientTarget" in
  codex|both) say "  Codex fallback: codex plugin marketplace add '$marketplaceDir' && codex plugin add velron@velron-local" ;;
esac
case "$clientTarget" in
  claude|both) say "  Claude fallback: claude plugin marketplace add '$marketplaceDir' --scope user && claude plugin install velron@velron-local --scope user" ;;
esac
say "${dim}Open a new terminal before using velron or velron-client from PATH.${reset}"
case "$clientTarget" in codex|both) warn "Start a new Codex session, open /hooks, and trust the Velron PreToolUse hook after checking its pinned path." ;; esac

if [ "$installServer" = "true" ] && [ "$openDashboard" = "yes" ]; then
  if [ -f "$dataDir/management-token" ]; then token=$(tr -d '\r\n' <"$dataDir/management-token"); dashboardUrl="${dashboardUrl}#managementToken=$token"; fi
  if [ "$platform" = "macos" ]; then open "$dashboardUrl" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$dashboardUrl" >/dev/null 2>&1 || true; fi
fi
