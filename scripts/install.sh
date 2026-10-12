#!/bin/zsh
# Builds Stickies+ and installs it as /Applications/Stickies+.app.
# An older installed copy goes to the Trash first. Your notes aren't touched: they live in
# ~/Library/Application Support/Stickies+, whichever copy of the app you run.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh

TARGET="/Applications/Stickies+.app"
if [[ -d "$TARGET" ]]; then
  mv "$TARGET" "$HOME/.Trash/Stickies+ $(date '+%Y-%m-%d %H.%M.%S').app"
fi
ditto "build/Stickies+.app" "$TARGET"
echo "Installed $TARGET"
if pgrep -qf "Stickies\+.app/Contents/MacOS/Stickies\+"; then
  echo "Stickies+ is running: quit it (⌘Q) and open it again from Applications to use the new version."
fi
