#!/usr/bin/env bash
set -euo pipefail

INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Release -destination 'platform=macOS' build
pkill -x cmux || true
sleep 0.2
APP_PATH="$(
  find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Release/cmux.app" -print0 \
  | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
  | sort -nr \
  | head -n 1 \
  | cut -d' ' -f2-
)"
if [[ -z "${APP_PATH}" ]]; then
  echo "cmux.app not found in DerivedData" >&2
  exit 1
fi

if [[ "$INSTALL" -eq 1 ]]; then
  rm -rf /Applications/cmux.app
  cp -R "$APP_PATH" /Applications/cmux.app
  echo "Installed to /Applications/cmux.app"
  APP_PATH="/Applications/cmux.app"
fi

# Dev shells (including CI/Codex) often force-disable paging by exporting these.
# Don't leak that into cmux, otherwise `git diff` won't page even with PAGER=less.
env -u GIT_PAGER -u GH_PAGER open -g "$APP_PATH"
