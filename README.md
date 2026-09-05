# Velron

Velron is distributed as separate Server and Client executables for Windows, macOS, and Linux.
The interactive installer downloads the correct release for the current OS and CPU architecture,
verifies its SHA-256 checksum, and walks through the initial setup.

## One-line install

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/CodingManFocus/velronRelease/main/install.ps1 | iex
```

### macOS and Linux

```sh
curl -fsSL https://raw.githubusercontent.com/CodingManFocus/velronRelease/main/install.sh | sh
```

Both commands open an interactive terminal wizard. It lets you:

- install Velron Server, Velron Client, or both;
- choose the Velron data directory and command directory;
- configure the Server bind host, management port, pinned local VCP port, and allowed hosts;
- view or replace the Client VCP URL and securely enter the token required by a remote Server;
- install the generated Velron plugin for Codex, Claude Code, or both;
- generate a generic stdio MCP configuration for another host and restrict it to a selected workspace;
- add `velron` and `velron-client` to the user `PATH`;
- register Velron Server to start when the user signs in, and optionally start it immediately.

The default Client endpoint shown by the wizard is
`wss://127.0.0.1:4143/vcp/v1`. Accepting it keeps automatic local discovery enabled: Client reads
the active port, access token, and pinned CA from the shared Velron data directory. A custom remote
URL must use `wss://`, must end in `/vcp/v1`, and requires a VCP access token.

## Default locations

| Platform | Commands | Runtime binaries | Data and configuration |
| --- | --- | --- | --- |
| Windows | `%LOCALAPPDATA%\Programs\Velron\bin` | Same as commands | `%USERPROFILE%\.velron` |
| macOS/Linux | `~/.local/bin` | `~/.local/share/velron/bin` | `~/.velron` |

All locations can be changed in the wizard where doing so is safe. The Server startup registration
uses a per-user Startup shortcut on Windows, a LaunchAgent on macOS, and a systemd user service
(or desktop autostart fallback) on Linux.

## Plugin security step

The installer asks Velron Client to generate a local marketplace whose MCP command and
`PreToolUse` Hook pin the installed Client by absolute path. After installing for Codex, start a
new Codex session, open `/hooks`, confirm the absolute path, and trust the generated Hook. Until it
is trusted, pathless Agents still work, while workspace-enabled VCP Agents fail safely with
`vcp_context_required`.

If the selected Codex or Claude Code CLI is not on `PATH`, installation still succeeds and the
wizard prints the exact plugin registration commands to run later.

## Manual downloads

Every GitHub Release contains Server and Client builds for Windows, macOS, and Linux on x64 and
arm64, plus `SHA256SUMS.txt`. Downloads are available from the
[latest release](https://github.com/CodingManFocus/velronRelease/releases/latest).

Use is subject to the terms in [LICENSE](LICENSE).
