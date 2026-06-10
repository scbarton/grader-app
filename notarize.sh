#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/Release/Grader.app"
ZIP="$DIR/build/Release/Grader.zip"
SIGN_ID="Developer ID Application: Scott Calabrese Barton (WR7X27PQB5)"
ENTITLEMENTS="$DIR/GraderApp/Resources/GraderApp.entitlements"
VERSION="v$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")"

echo "==> Signing..."
codesign --deep --force --verify \
  --sign "$SIGN_ID" \
  --options runtime \
  --entitlements "$ENTITLEMENTS" \
  "$APP"

echo "==> Zipping..."
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting for notarization..."
xcrun notarytool submit "$ZIP" \
  --keychain-profile "notarytool" \
  --wait

echo "==> Stapling..."
xcrun stapler staple "$APP"

echo "==> Re-zipping stapled app..."
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Uploading to GitHub release $VERSION..."
gh release upload "$VERSION" "$ZIP" --clobber --repo scbarton/grader-app

echo "Done: signed, notarized, stapled, uploaded."
