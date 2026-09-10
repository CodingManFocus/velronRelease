#!/usr/bin/env sh
# Compatibility entry point. Installer development lives in velronInstaller.
set -eu

installer_url='https://raw.githubusercontent.com/CodingManFocus/velronInstaller/4f2a7538c238805aa5e62853baa98a29d144625a/install.sh'
installer_path=$(mktemp "${TMPDIR:-/tmp}/velron-install.XXXXXXXX")
trap 'rm -f "$installer_path"' EXIT
trap 'exit 1' HUP INT TERM

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$installer_url" -o "$installer_path"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$installer_path" "$installer_url"
else
  printf '%s\n' 'Install curl or wget, then run the Velron installer again.' >&2
  exit 1
fi

sh "$installer_path" "$@"
