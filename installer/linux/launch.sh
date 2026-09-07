#!/bin/sh
set -eu

launcher_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
wizard="$launcher_dir/run-wizard.sh"
if [ "${1:-}" = --print-command ]; then
  exec sh "$wizard" --print-command
fi
if [ -t 0 ] && [ -t 1 ]; then
  exec sh "$wizard"
fi

# Desktop environments use different terminals; keep the wizard interactive.
if command -v x-terminal-emulator >/dev/null 2>&1; then
  exec x-terminal-emulator -e /bin/sh "$wizard"
elif command -v gnome-terminal >/dev/null 2>&1; then
  exec gnome-terminal -- /bin/sh "$wizard"
elif command -v konsole >/dev/null 2>&1; then
  exec konsole -e /bin/sh "$wizard"
elif command -v xfce4-terminal >/dev/null 2>&1; then
  exec xfce4-terminal --execute /bin/sh "$wizard"
elif command -v xterm >/dev/null 2>&1; then
  exec xterm -e /bin/sh "$wizard"
fi

message='No supported terminal was found. Open a terminal and run: sh launch.sh'
if command -v zenity >/dev/null 2>&1; then
  zenity --error --title='Velron Installer' --text="$message" || true
elif command -v kdialog >/dev/null 2>&1; then
  kdialog --error "$message" --title 'Velron Installer' || true
fi
printf '%s\n' "$message" >&2
exit 1
