#!/bin/sh
# opencode launcher for FreeBSD (runs under Linuxulator)
# The Linuxulator/SSH session may inherit a Windows HOME (e.g. /c/Users/skywalk),
# which breaks opencode's data dir creation (EACCES). Force the real Unix HOME.
export HOME=/home/workbuddy
[ -d "$HOME/.local" ] || mkdir -p "$HOME/.local/share" "$HOME/.local/state" "$HOME/.local/cache" "$HOME/.config" 2>/dev/null
exec /home/workbuddy/github/opencode-freebsd/node_modules/opencode-linux-x64-baseline/bin/opencode "$@"
