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

STEP="startup"
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
trap 'log "FAILED during: $STEP (exit $?)"' ERR

phase_started=$SECONDS
phase() {
  STEP="$1"
  phase_started=$SECONDS
  log "==> $1"
}
phase_done() { log "    done in $((SECONDS - phase_started))s"; }

if [ ! -f "$DMG_PATH" ]; then
  log "DMG not found at $DMG_PATH — run ./scripts/build_dmg.sh first"
  exit 1
fi
log "DMG: $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1 | tr -d ' ')), profile: $KEYCHAIN_PROFILE"

# A corrupted DMG makes notarytool hang silently at upload (it fails an internal
# "disk image potentiality test" visible only with --verbose) — catch it here.
phase "DMG integrity check"
hdiutil verify "$DMG_PATH" > /dev/null 2>&1 \
  || { log "    DMG is corrupted (hdiutil verify failed) — rebuild with ./scripts/build_dmg.sh"; exit 1; }
phase_done

phase "network preflight (Apple reachability)"
curl -sS --max-time 10 -o /dev/null https://appstoreconnect.apple.com \
  || { log "    Apple is unreachable — check the connection and retry"; exit 1; }
phase_done

# Upload and verdict are separate phases so a stall is attributable: if the last
# line you see is the upload phase, it's the network; if it's the wait phase,
# it's Apple's queue.
phase "upload to Apple notary service"
SUBMIT_OUT=$(xcrun notarytool submit "$DMG_PATH" --keychain-profile "$KEYCHAIN_PROFILE" 2>&1) \
  || { printf '%s\n' "$SUBMIT_OUT"; exit 1; }
SUBMISSION_ID=$(printf '%s\n' "$SUBMIT_OUT" | awk '/^ *id: /{print $2; exit}')
[ -n "$SUBMISSION_ID" ] || { log "    could not parse submission id from:"; printf '%s\n' "$SUBMIT_OUT"; exit 1; }
log "    uploaded, submission id: $SUBMISSION_ID"
phase_done

phase "waiting for Apple's verdict (id $SUBMISSION_ID)"
xcrun notarytool wait "$SUBMISSION_ID" --keychain-profile "$KEYCHAIN_PROFILE" \
  || { log "    verdict not Accepted — fetching the notary log:"; \
       xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$KEYCHAIN_PROFILE" || true; exit 1; }
phase_done

phase "stapling ticket onto DMG"
xcrun stapler staple "$DMG_PATH"
phase_done

phase "validating staple"
xcrun stapler validate "$DMG_PATH"
# The DMG container itself is unsigned, so spctl prints "rejected / no usable
# signature" here — expected and harmless; the .app inside carries the ticket.
spctl -a -t open --context context:primary-signature -vv "$DMG_PATH" || true
phase_done

log "==> Done. $DMG_PATH is notarized and ready to publish."
