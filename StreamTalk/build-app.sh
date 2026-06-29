#!/bin/bash
# Build StreamTalk.app: compile, assemble a proper .app bundle (so macOS will
# show the mic/speech permission prompts), and ad-hoc code-sign it.
set -euo pipefail
cd "$(dirname "$0")"

APP="StreamTalk.app"
CONF="${1:-release}"

echo "==> swift build ($CONF)"
swift build -c "$CONF"
BIN=".build/$CONF/StreamTalk"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/StreamTalk"
cp Info.plist "$APP/Contents/Info.plist"
[ -f icon/AppIcon.icns ] && cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> ad-hoc signing"
codesign --force --deep --sign - "$APP"

echo "==> done: $(pwd)/$APP"
echo "    open $APP   # launches the StreamTalk window"
