#!/usr/bin/env bash
#
# Notarize the built DMG with Apple and staple the result.
#
# Prerequisites (one-time setup):
#
#   1. Create a Developer ID Application certificate:
#      Xcode → Settings → Accounts → select team → Manage Certificates
#      → + → Developer ID Application
#
#   2. Generate an app-specific password:
#      https://appleid.apple.com/account/manage → Sign-In and Security
#      → App-Specific Passwords → Generate (label: "UsageChecker notarize")
#
#   3. Store credentials in Keychain once:
#      xcrun notarytool store-credentials "UsageChecker-Notary" \
#         --apple-id "you@example.com" \
#         --team-id "XXXXXXXXXX" \
#         --password "abcd-efgh-ijkl-mnop"
#
# Then run this script: ./scripts/notarize_dmg.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG_PATH="$ROOT/build/UsageChecker.dmg"
KEYCHAIN_PROFILE="${NOTARY_PROFILE:-UsageChecker-Notary}"

if [ ! -f "$DMG_PATH" ]; then
  echo "DMG not found at $DMG_PATH — run ./scripts/build_dmg.sh first"
  exit 1
fi

echo "==> Submitting $DMG_PATH for notarization (profile: $KEYCHAIN_PROFILE)"
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait

echo "==> Stapling notarization ticket onto DMG"
xcrun stapler staple "$DMG_PATH"

echo "==> Verifying"
xcrun stapler validate "$DMG_PATH"
spctl -a -t open --context context:primary-signature -vv "$DMG_PATH" || true

echo "==> Done. $DMG_PATH is notarized and ready to publish."
