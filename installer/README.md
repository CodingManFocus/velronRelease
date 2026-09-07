# Velron Installer launchers

These launchers only open the existing One-line install wizard. They do not duplicate its
installation logic, require administrator access, or bundle Velron Server or Client. An internet
connection is required. Installation options, checksums, stdio MCP configuration, and startup
registration remain implemented by the root `install.ps1` and `install.sh` scripts.

## Downloads

The `Installer release` workflow publishes these assets under the fixed `installer-latest` tag:

| File | How to open |
| --- | --- |
| `Velron-Installer-windows-x64.exe` | Double-click on an Intel/AMD Windows PC. |
| `Velron-Installer-windows-arm64.exe` | Double-click on an ARM Windows PC. |
| `Velron-Installer-macos-universal.zip` | Extract, then open `Velron Installer.app` on Apple Silicon or Intel. |
| `Velron-Installer-linux.tar.gz` | Extract, allow launching `Velron-Installer.desktop` if your desktop asks, then open it. You can also run `sh launch.sh` in the extracted folder. |
| `SHA256SUMS-installers.txt` | SHA-256 checksums for all four downloads. |

The macOS app requests permission to open Terminal on first use. The Windows and macOS launchers
are currently unsigned, so OS reputation or app security checks may require explicit approval.
One-line install remains available when local policy does not allow opening these launchers.
Neither launcher changes operating-system security settings.

The dedicated release always uses `make_latest: "false"`, preserving the main application's
`releases/latest` URL used by the installation scripts. All release updates explicitly repeat this
flag. Application release workflows should continue to publish their own versioned releases.

## Build and checks

- Windows: Go 1.26 or newer, standard library only. From `installer/windows`, use
  `GOOS=windows GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o Velron-Installer-windows-x64.exe .`.
  Use `GOARCH=arm64` for ARM. These are console executables without a separately installed runtime.
- macOS: the workflow compiles the AppleScript with `osacompile`, bundles `run-wizard.sh`, verifies
  that the applet supports both architectures, and archives the app with `ditto`.
- Linux: the workflow packages the desktop entry and shell launchers, preserving executable bits.
- `python3 installer/tests/test_unix_launcher.py` verifies successful execution, partial-download
  failure, empty downloads, exit status, input forwarding, path quoting, and temporary-file cleanup
  with a fake downloader. It never installs Velron or makes network requests.
- Each launcher supports `--print-command` where it has a command-line interface. This prints the
  official command without downloading or executing anything.

The workflow builds and checks pull requests without publishing. A push to `main` touching launcher
sources or the workflow, or a manual run on `main`, publishes the reviewed artifacts. `contents: write`
is granted only to the publish job; build jobs have read-only repository access.
