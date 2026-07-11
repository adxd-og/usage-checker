#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_NAME="UsageTracker"           # internal Xcode project / scheme name
PRODUCT_NAME="Omelette"                # user-facing app name (from project.yml PRODUCT_NAME)
SCHEME="UsageTracker"
CONFIG="Release"
BUILD_DIR="$ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/$PROJECT_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG_PATH="$BUILD_DIR/$PRODUCT_NAME.dmg"

cd "$ROOT"

if [ ! -f signing.xcconfig ]; then
  echo "ERROR: signing.xcconfig not found."
  echo "Run ./scripts/setup.sh first."
  exit 1
fi

# CI cloud signing: an App Store Connect API key lets xcodebuild create/fetch
# the Developer ID provisioning profiles (required by the app-group
# entitlement) without a logged-in Xcode. Locally these vars are unset and the
# behavior is unchanged (your Xcode session manages profiles).
AUTH_ARGS=()
if [ -n "${ASC_KEY_PATH:-}" ] && [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
  echo "==> Using App Store Connect API key for provisioning"
  AUTH_ARGS=(
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
fi

echo "==> Regenerating project"
xcodegen generate

echo "==> Archiving Release build"
xcodebuild \
  -project "$PROJECT_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
  archive

echo "==> Generating exportOptions.plist (Team ID from signing.xcconfig — kept out of git)"
TEAM_ID="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*//p' signing.xcconfig | tr -d '[:space:]')"
if [ -z "$TEAM_ID" ]; then
  echo "ERROR: DEVELOPMENT_TEAM not found in signing.xcconfig"
  exit 1
fi
cat > "$ROOT/scripts/exportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

echo "==> Exporting archive with Developer ID re-sign"
rm -rf "$EXPORT_DIR"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$ROOT/scripts/exportOptions.plist" \
  -allowProvisioningUpdates \
  ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}

echo "==> Verifying signatures"
APP="$EXPORT_DIR/$PRODUCT_NAME.app"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -5

echo "==> Building DMG"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$PRODUCT_NAME" \
  -srcfolder "$EXPORT_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

# Note: signing the DMG itself is optional. The .app inside is already signed +
# hardened-runtime via exportArchive, and notarization staples the ticket to the DMG.

echo "==> Done"
echo "App:  $APP"
echo "DMG:  $DMG_PATH"
du -h "$DMG_PATH"
