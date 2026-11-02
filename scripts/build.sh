#!/bin/zsh
# Builds and signs PastAi.app with SwiftPM. Output stays on the local disk because the source tree
# lives on a network share. Usage: scripts/build.sh [debug|release]
set -euo pipefail

cd "${0:A:h}/.."
CONFIGURATION="${1:-debug}"
CACHE="$HOME/Library/Caches/PastAi"
APP="$CACHE/dist/PastAi.app"
# A stable Developer ID signature keeps the Accessibility grant across rebuilds. Without a certificate
# the build is signed ad hoc, which works but asks for the permission again after every build.
IDENTITY="${PASTAI_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Developer ID Application/ { print $2; exit }')}"
IDENTITY="${IDENTITY:--}"

swift build -c "$CONFIGURATION" --product PastAi --scratch-path "$CACHE/spm" 2>&1 \
  | sed 's/\x1b\[[0-9;]*m//g' | grep -E ' error: |Compiling PastAi|Build complete' | grep -v 'Compiling' || true

BINARY="$CACHE/spm/$CONFIGURATION/PastAi"
[[ -f "$BINARY" ]] || { echo "build failed: no binary" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/PastAi"
cp App/Info.plist "$APP/Contents/Info.plist"
cp App/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The built-in copy of the market: seeds first launch and keeps working without network access.
rsync -a --exclude '._*' --exclude '.DS_Store' --exclude 'README.md' extensions/ "$APP/Contents/Resources/extensions/"

codesign --force --options runtime --timestamp=none \
  --entitlements App/PastAi.entitlements --sign "$IDENTITY" "$APP"

echo "$APP"
