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

# Prefer the stable self-signed identity (see setup-signing.sh) so macOS keeps
# Accessibility / Local Network grants across rebuilds. Fall back to ad-hoc.
IDENTITY="StreamTalk Self-Signed"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "==> signing with '$IDENTITY'"
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    echo "==> ad-hoc signing (run ./setup-signing.sh for a stable identity)"
    codesign --force --deep --sign - "$APP"
fi

echo "==> done: $(pwd)/$APP"
echo "    open $APP   # launches the StreamTalk window"
