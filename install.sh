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
if ! file "$TARGET_APP/Contents/MacOS/VoiceCue" | grep -q 'Mach-O'; then
  echo "Installation failed: VoiceCue app binary was not built correctly." >&2
  exit 1
fi
codesign --verify --deep --strict "$TARGET_APP"
mkdir -p "$BIN_DIR"
rm -f "$LAUNCHER"
cat > "$LAUNCHER" <<LAUNCHER_SCRIPT
#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$ROOT_DIR"
APP_BINARY="$TARGET_APP/Contents/MacOS/VoiceCue"

if [[ "\${1:-}" == "update" ]]; then
  ORIGIN_URL="\$(git -C "\$SOURCE_DIR" config --get remote.origin.url || true)"
  case "\$ORIGIN_URL" in
    https://github.com/lucka643/voicecue.git|git@github.com:lucka643/voicecue.git) ;;
    *)
      echo "VoiceCue update refused: the repository origin is not the official VoiceCue repository." >&2
      exit 1
      ;;
  esac
  git -C "\$SOURCE_DIR" fetch --quiet origin main
  git -C "\$SOURCE_DIR" merge --ff-only origin/main
  exec "\$SOURCE_DIR/install.sh"
fi

exec "\$APP_BINARY" "\$@"
LAUNCHER_SCRIPT
chmod +x "$LAUNCHER"
if ! file "$TARGET_APP/Contents/MacOS/VoiceCue" | grep -q 'Mach-O'; then
  echo "Installation failed: launcher setup changed the VoiceCue app binary." >&2
  exit 1
fi
if [[ "${VOICECUE_KEEP_BUILD_CACHE:-}" != "1" ]]; then
  rm -rf "$ROOT_DIR/.build" "$ROOT_DIR/dist"
fi
echo "Installed VoiceCue. Run: voicecue"
echo "Update later with: voicecue update"
