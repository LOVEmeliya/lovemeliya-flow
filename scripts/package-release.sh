#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
APP="$PROJECT_ROOT/dist/LOVEmeliya Flow.app"
[[ -d "$APP" ]] || { print -u2 'Run ./scripts/build-app.sh first.'; exit 1; }
codesign --verify --deep --strict "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCH="$(lipo -archs "$APP/Contents/MacOS/MediaFlow")"
[[ "$ARCH" != *' '* ]] || ARCH=universal
ARCHIVE="LOVEmeliya-Flow-$VERSION-macos-$ARCH.zip"
# Do not include Finder metadata, personal extended attributes or test artifacts.
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" "$PROJECT_ROOT/dist/$ARCHIVE"
(cd "$PROJECT_ROOT/dist" && shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256")
printf 'Packaged: %s\n' "$PROJECT_ROOT/dist/$ARCHIVE"
