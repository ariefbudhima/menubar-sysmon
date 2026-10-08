#!/usr/bin/env bash
#
# Builds, installs to ~/Applications and launches the app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$HOME/Applications/SysMon.app"

"$ROOT/scripts/build.sh"

echo "==> installing to $DEST"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$ROOT/dist/SysMon.app" "$DEST"

# Restart cleanly if an older copy is running.
pkill -f "SysMon.app/Contents/MacOS/SysMon" 2>/dev/null || true
sleep 0.4

echo "==> launching"
open "$DEST"
echo "==> done. Look for the coloured RAM bar next to the battery."
