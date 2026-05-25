#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="UsageTracker"
SCHEME="UsageTracker"
CONFIG="Release"
BUILD_DIR="$ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"

cd "$ROOT"

if [ ! -f signing.xcconfig ]; then
  echo "ERROR: signing.xcconfig not found."
  echo "Run ./scripts/setup.sh first."
  exit 1
fi

echo "==> Regenerating project"
xcodegen generate

echo "==> Archiving Release build"
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  -archivePath "$ARCHIVE_PATH" \
  archive

echo "==> Copying app out of archive"
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"
cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME.app" "$EXPORT_DIR/"

echo "==> Building DMG"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$EXPORT_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "==> Done"
echo "App:  $EXPORT_DIR/$APP_NAME.app"
echo "DMG:  $DMG_PATH"
du -h "$DMG_PATH"
