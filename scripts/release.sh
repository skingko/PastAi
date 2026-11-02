#!/bin/zsh
# Builds a signed, timestamped DMG in dist/ and notarizes it when a notarytool profile exists.
# One-time setup: xcrun notarytool store-credentials pastai-notary
set -euo pipefail

cd "${0:A:h}/.."
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/Info.plist)
IDENTITY="${PASTAI_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Developer ID Application/ { print $2; exit }')}"
[[ -n "$IDENTITY" ]] || { echo "release builds need a Developer ID Application certificate" >&2; exit 1; }
PROFILE="${PASTAI_NOTARY_PROFILE:-pastai-notary}"
CACHE="$HOME/Library/Caches/PastAi"
APP="$CACHE/dist/PastAi.app"
DMG="$CACHE/dist/PastAi-$VERSION.dmg"

./scripts/build.sh release >/dev/null

# Notarization requires a secure timestamp, which the day-to-day build skips to stay fast.
codesign --force --options runtime --timestamp --entitlements App/PastAi.entitlements --sign "$IDENTITY" "$APP"

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "PastAi" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "notarized"
else
  echo "not notarized: no '$PROFILE' profile. Run: xcrun notarytool store-credentials $PROFILE"
fi

mkdir -p dist
cp "$DMG" dist/
echo "dist/PastAi-$VERSION.dmg"
