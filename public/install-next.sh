#!/bin/sh
# RemoteClaw "next" channel installer — latest build from main branch.
# Usage: curl -fsSL https://next.remoteclaw.sh | sh
#
# This wrapper runs the standard installer with the "next" dist-tag,
# which tracks every commit on main. Newest features, updated continuously.
#
# All flags are forwarded (e.g., --local, --dry-run, --verbose).

export REMOTECLAW_VERSION="${REMOTECLAW_VERSION:-next}"

_script="$(mktemp)" || { echo "Error: mktemp failed" >&2; exit 1; }
trap 'rm -f "$_script"' EXIT

if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --tlsv1.2 https://remoteclaw.org/install.sh -o "$_script" || exit 1
elif command -v wget >/dev/null 2>&1; then
    wget -q --https-only https://remoteclaw.org/install.sh -O "$_script" || exit 1
else
    echo "Error: curl or wget is required" >&2
    exit 1
fi

exec bash "$_script" "$@"
