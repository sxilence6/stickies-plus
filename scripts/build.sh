#!/bin/zsh
# Builds build/Stickies+.app (release).
# Signs with your Apple Development certificate if you have one, so macOS sees every build as
# the same app and keeps its permissions (calendar). Otherwise ad-hoc.
#   SIGN_IDENTITY=-   ad-hoc, whatever certificates you have (for sharing the app)
#   UNIVERSAL=1       Apple Silicon + Intel in one app
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH_FLAGS=()
[[ "${UNIVERSAL:-0}" == 1 ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCH_FLAGS[@]}"
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/StickiesPlus"
APP="build/Stickies+.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Stickies+"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -p codesigning -v 2>/dev/null | awk '/Apple Development/ { print $2; exit }')}"
if [[ -n "$IDENTITY" && "$IDENTITY" != "-" ]]; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "Built $APP (signed with your Apple Development certificate)"
else
  codesign --force --sign - "$APP"
  echo "Built $APP (ad-hoc signed)"
fi
