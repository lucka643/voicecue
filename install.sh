#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
APP_BUNDLE="$ROOT_DIR/dist/VoiceCue.app"
TARGET_APP="/Applications/VoiceCue.app"

"$ROOT_DIR/script/build_and_run.sh" --bundle-only
rm -rf "$TARGET_APP"
cp -R "$APP_BUNDLE" "$TARGET_APP"
mkdir -p "$BIN_DIR"
ln -sf "$TARGET_APP/Contents/MacOS/VoiceCue" "$BIN_DIR/voicecue"
echo "Installed VoiceCue. Run: voicecue"
