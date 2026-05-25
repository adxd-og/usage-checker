#!/usr/bin/env bash
# One-time setup for contributors / first-time builders.
# Copies signing.xcconfig.example to signing.xcconfig if missing, then regenerates the project.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not installed. Install with: brew install xcodegen"
  exit 1
fi

if [ ! -f signing.xcconfig ]; then
  echo "==> Creating signing.xcconfig from example"
  cp signing.xcconfig.example signing.xcconfig
  echo ""
  echo "    Edit signing.xcconfig with your Apple Developer Team ID."
  echo "    Find it at: https://developer.apple.com/account → Membership Details"
  echo ""
fi

echo "==> Generating Xcode project"
xcodegen generate

echo ""
echo "==> Setup complete. Open UsageTracker.xcodeproj in Xcode, or run:"
echo "    ./scripts/build_dmg.sh"
