#!/bin/bash
# Build devPaste.app from the Swift package.
#   ./build.sh            build into build/devPaste.app
#   ./build.sh --install  build, copy to /Applications, relaunch
#
# Signing: uses your "Apple Development" identity if one is in the keychain, so macOS keeps the
# Accessibility permission across rebuilds. Set DEVPASTE_SIGN_IDENTITY to choose another.
# Without one it signs ad hoc, and you may need to re-grant Accessibility after each build.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/devPaste"

APP="build/devPaste.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/devPaste"
cp App/Info.plist "$APP/Contents/Info.plist"
cp App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${DEVPASTE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
fi
if [ -z "$IDENTITY" ]; then
    echo "note: no Apple Development identity found, signing ad hoc"
    IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" "$APP"
echo "built $APP (signed: $IDENTITY)"

if [ "${1:-}" = "--install" ]; then
    pkill -x devPaste 2>/dev/null || true
    sleep 0.5
    rm -rf /Applications/devPaste.app
    cp -R "$APP" /Applications/devPaste.app
    open /Applications/devPaste.app
    echo "installed /Applications/devPaste.app and launched it"
fi
