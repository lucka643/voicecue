#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
APP_BUNDLE="$ROOT_DIR/dist/VoiceCue.app"
TARGET_APP="/Applications/VoiceCue.app"
LAUNCHER="$BIN_DIR/voicecue"

"$ROOT_DIR/script/build_and_run.sh" --bundle-only
rm -rf "$TARGET_APP"
cp -R "$APP_BUNDLE" "$TARGET_APP"
mkdir -p "$BIN_DIR"
cat > "$LAUNCHER" <<LAUNCHER_SCRIPT
#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$ROOT_DIR"
APP_BINARY="$TARGET_APP/Contents/MacOS/VoiceCue"

if [[ "\${1:-}" == "update" ]]; then
  git -C "\$SOURCE_DIR" pull --ff-only
  exec "\$SOURCE_DIR/install.sh"
fi

exec "\$APP_BINARY" "\$@"
LAUNCHER_SCRIPT
chmod +x "$LAUNCHER"
echo "Installed VoiceCue. Run: voicecue"
echo "Update later with: voicecue update"
