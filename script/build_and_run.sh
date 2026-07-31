#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="VoiceCue"
BUNDLE_ID="local.voicecue.listener"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
plutil -create xml1 "$INFO_PLIST"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string VoiceCue' "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string VoiceCue' "$INFO_PLIST"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$INFO_PLIST"
/usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 14.0' "$INFO_PLIST"
/usr/libexec/PlistBuddy -c 'Add :NSSpeechRecognitionUsageDescription string VoiceCue listens locally for its wake phrase.' "$INFO_PLIST"
/usr/libexec/PlistBuddy -c 'Add :NSMicrophoneUsageDescription string VoiceCue needs microphone access to recognize its wake phrase.' "$INFO_PLIST"

case "$MODE" in
  run) exec "$APP_BINARY" ;;
  --bundle-only|bundle-only) exit 0 ;;
  --debug|debug) exec lldb -- "$APP_BINARY" ;;
  --logs|logs) "$APP_BINARY" & /usr/bin/log stream --info --style compact --predicate 'process == "VoiceCue"' ;;
  --telemetry|telemetry) "$APP_BINARY" & /usr/bin/log stream --info --style compact --predicate 'subsystem == "local.voicecue.listener"' ;;
  --verify|verify) "$APP_BINARY" & sleep 1; pgrep -x "$APP_NAME" >/dev/null ;;
  *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac
