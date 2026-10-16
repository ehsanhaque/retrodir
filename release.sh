#!/bin/zsh
# Builds a universal RetroDir.app, signs it with your Developer ID, wraps it in a DMG,
# notarizes the DMG with Apple and staples the ticket. Output: build/RetroDir.dmg
#
# One-time setup on this Mac:
#   - a "Developer ID Application" certificate (with its private key) in the login keychain
#   - xcrun notarytool store-credentials retrodir-notary --apple-id <id> --team-id <team>
# Overrides: IDENTITY="Developer ID Application: ..." NOTARY_PROFILE=other-profile ./release.sh
set -e
cd "$(dirname "$0")"

IDENTITY=${IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')}
PROFILE=${NOTARY_PROFILE:-retrodir-notary}
if [ -z "$IDENTITY" ]; then
  echo "No 'Developer ID Application' signing identity found in the keychain." >&2
  exit 1
fi
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "Notary profile '$PROFILE' not found. Run: xcrun notarytool store-credentials $PROFILE ..." >&2
  exit 1
fi
VERSION=$(plutil -extract CFBundleShortVersionString raw Info.plist)
APP=build/RetroDir.app
DMG=build/RetroDir.dmg
echo "Releasing RetroDir $VERSION, signed by: $IDENTITY"

ARCHS="arm64 x86_64" ./build.sh

echo "Signing app..."
codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "Creating DMG..."
rm -rf build/dmg "$DMG"
mkdir -p build/dmg
ditto "$APP" build/dmg/RetroDir.app
ln -s /Applications build/dmg/Applications
hdiutil create -quiet -volname "RetroDir $VERSION" -srcfolder build/dmg -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "Notarizing (this usually takes a few minutes)..."
OUT=$(xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait 2>&1) || true
echo "$OUT"
if ! print -r -- "$OUT" | grep -q "status: Accepted"; then
  ID=$(print -r -- "$OUT" | awk '/^  id:/ { print $2; exit }')
  [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE"
  echo "Notarization failed." >&2
  exit 1
fi

xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
shasum -a 256 "$DMG"
echo "Ready: $DMG"
