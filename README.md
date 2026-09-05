# Velron Release

Standalone Velron Server and Client releases for Windows, macOS, and Linux.

## One-line installation

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/CodingManFocus/velronRelease/main/install.ps1 | iex
```

### macOS and Linux

```sh
curl -fsSL https://raw.githubusercontent.com/CodingManFocus/velronRelease/main/install.sh | sh
```

The interactive setup wizard lets you:

- install Server, Client, or both;
- configure the Server ports and optional login startup;
- use automatic local VCP discovery or enter a remote `wss://.../vcp/v1` endpoint;
- install the generated Client plugin into Codex, Claude Code, or both;
- create a ready-to-copy stdio MCP configuration for another host and a fixed workspace;
- add stable `velron` and `velron-client` commands to your user `PATH`;
- verify every downloaded executable against the release SHA-256 manifest.

Run `install.sh --help` or download `install.ps1` and run `Get-Help ./install.ps1 -Detailed` for automation options.

> The one-line commands require this release repository to be public. Until then, download the scripts with an authenticated GitHub client; `GITHUB_TOKEN` is also supported for private release-asset downloads.

## License

See [LICENSE](LICENSE) before using Velron. Public download availability does not grant commercial-use rights.
