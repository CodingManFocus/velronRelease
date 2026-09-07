#!/bin/sh
# Fetch and run the same wizard as One-line install, with a visible failure state.
set -u

wizard_url='https://raw.githubusercontent.com/CodingManFocus/velronRelease/main/install.sh'
if [ "${1:-}" = --print-command ]; then
  printf 'curl -fsSL %s | sh\n' "$wizard_url"
  exit 0
fi

finish() {
  result=$1
  if [ "$result" -ne 0 ]; then
    printf '\nThe installer could not finish (exit %s). Review the error above and try again.\n' "$result" >&2
    printf 'One-line install is also available at https://velron.codenamemc.kr.\n' >&2
  else
    printf '\nThe installation wizard has closed.\n'
  fi
  printf 'Press Enter to close...'
  IFS= read -r _ignored || true
  exit "$result"
}

printf 'Velron Installer\nStarting the official interactive installation wizard...\n\n'
umask 077
wizard_dir=$(mktemp -d "${TMPDIR:-/tmp}/velron-launcher.XXXXXX") || finish 1
trap 'rm -rf "$wizard_dir"' 0
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# Download completely before execution so a failed or partial download cannot run.
if command -v curl >/dev/null 2>&1; then
  curl -fL --retry 3 --connect-timeout 15 "$wizard_url" -o "$wizard_dir/install.sh"
  download_status=$?
elif command -v wget >/dev/null 2>&1; then
  wget -O "$wizard_dir/install.sh" "$wizard_url"
  download_status=$?
else
  printf 'Install curl or wget, then open Velron Installer again.\n' >&2
  finish 1
fi
[ "$download_status" -eq 0 ] || finish "$download_status"
[ -s "$wizard_dir/install.sh" ] || { printf 'The downloaded installer is empty.\n' >&2; finish 1; }
sh "$wizard_dir/install.sh"
finish "$?"
