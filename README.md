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
- register the stdio Velron Client for Codex, Claude Code, or both;
- generate a generic stdio MCP configuration for another host;
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

## MCP connection and workspace paths

Velron Client is a regular stdio MCP server. The installer registers the absolute Client command with
`codex mcp add` or `claude mcp add --transport stdio --scope user`. It uses the host CLI to update its
configuration and preserves any existing MCP entry named `velron` for you to review. If a selected CLI
is unavailable or cannot register the entry, the installer prints a command to run after resolving it.

The installer also saves `stdio-mcp.json` in the chosen Velron data directory for manual setup. Merge
its `velron` entry into the host's existing `mcpServers` object without replacing unrelated entries.
On macOS/Linux the registered launcher reads `client.env` from that data directory. On Windows the
installer configures the connection environment. Restart your MCP host after installation.

For Agents that use VCP workspace tools, supply `workspaceDir` in each `call_agent` invocation. It must
be the absolute path of an existing project directory on the computer running Velron Client. Agents
without workspace tools may omit it. The installer no longer asks for a fixed project directory.

```json
{
  "agentId": "code-scout",
  "prompt": "Inspect this project's structure.",
  "workspaceDir": "/home/user/projects/example"
}
```

On Windows, use a path such as `C:\\Users\\user\\projects\\example` in JSON. Relative paths such as
`.` and `../project` are rejected. The MCP caller selects this directory; it is not a signed claim
about the host's current working directory.

When upgrading from an older Velron plugin, remove that plugin from Codex or Claude Code. Also remove
any separately registered Velron `PreToolUse` Hook and duplicate MCP entry, then register the new
stdio entry and restart the host. The installer does not automatically delete host plugins or Hooks.
The old `setup-plugin` and `hook` commands and the `VELRON_WORKSPACE_ROOT` fallback are no longer used.

Host configuration details: [Codex MCP](https://developers.openai.com/codex/mcp) and
[Claude Code MCP](https://code.claude.com/docs/en/mcp-quickstart).

## Manual downloads

Every GitHub Release contains Server and Client builds for Windows, macOS, and Linux on x64 and
arm64, plus `SHA256SUMS.txt`. Downloads are available from the
[latest release](https://github.com/CodingManFocus/velronRelease/releases/latest).

Use is subject to the terms in [LICENSE](LICENSE).
