#!/bin/zsh
# Builds the app for sharing: Apple Silicon + Intel, ad-hoc signed (no personal certificate in
# it), zipped as build/Stickies+-<version>.zip.
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL=1 SIGN_IDENTITY=- ./scripts/build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
ZIP="build/Stickies+-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "build/Stickies+.app" "$ZIP"
echo "Packed $ZIP"
lipo -archs "build/Stickies+.app/Contents/MacOS/Stickies+"
