# Contributing

## Build from source

Requirements:
- macOS 14 (Sonoma) or newer
- Xcode 26 or newer
- [xcodegen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

One-time setup:
```bash
./scripts/setup.sh
```

This copies `signing.xcconfig.example` to `signing.xcconfig` and regenerates the Xcode project. Edit `signing.xcconfig` with your Apple Developer Team ID — find it at [developer.apple.com/account](https://developer.apple.com/account) → Membership Details.

Then either:
- Open `UsageTracker.xcodeproj` in Xcode and hit Run, or
- `./scripts/build_dmg.sh` to produce a DMG

## Releasing (for maintainers)

Production releases are notarized DMGs distributed via GitHub Releases, with Sparkle auto-update enabled.

### One-time setup

1. **Developer ID Application certificate** — Xcode → Settings → Accounts → select your team → Manage Certificates → + → Developer ID Application
2. **App-specific password** — [appleid.apple.com/account/manage](https://appleid.apple.com/account/manage) → Sign-In and Security → App-Specific Passwords → label "Usage Checker notarize"
3. **Sparkle EdDSA keys** — Sparkle requires a key pair to verify updates. From your local clone of Sparkle's tools:
   ```bash
   ./bin/generate_keys
   ```
   This prints a base64 public key. Paste it into the `SUPublicEDKey` field of the Info.plist (currently configured as an empty placeholder via `project.yml`'s `INFOPLIST_KEY_SUPublicEDKey`). The private key is stored in your Keychain.
4. Store notarization credentials once:
   ```bash
   xcrun notarytool store-credentials "UsageChecker-Notary" \
     --apple-id "you@example.com" \
     --team-id "XXXXXXXXXX" \
     --password "xxxx-xxxx-xxxx-xxxx"
   ```

### Local release

Switch `CODE_SIGN_IDENTITY` to `Developer ID Application` in `signing.xcconfig` and `ENABLE_HARDENED_RUNTIME = YES`, then:

```bash
./scripts/build_dmg.sh
./scripts/notarize_dmg.sh
```

### GitHub Actions release

Push a tag like `v1.0.0` — the workflow in `.github/workflows/release.yml` builds, notarizes, and publishes the DMG to a GitHub Release automatically.

Required secrets in repo Settings → Secrets and variables → Actions:

| Secret | Value |
|--------|-------|
| `APPLE_ID` | Your Apple ID email |
| `APPLE_ID_PASSWORD` | App-specific password (xxxx-xxxx-xxxx-xxxx) |
| `APPLE_TEAM_ID` | Team ID from developer.apple.com |
| `DEVELOPER_ID_CERT_BASE64` | Developer ID Application cert exported as .p12, base64-encoded |
| `DEVELOPER_ID_CERT_PASSWORD` | Password you set when exporting the .p12 |
| `KEYCHAIN_PASSWORD` | Any random string — used for the temporary CI keychain |

To export the .p12:
1. Keychain Access → My Certificates → right-click "Developer ID Application: …" → Export → save as `cert.p12` with a password
2. `base64 -i cert.p12 | pbcopy`
3. Paste the contents into the `DEVELOPER_ID_CERT_BASE64` GitHub secret

### Sparkle appcast

After each release, generate or update `appcast.xml` and publish it where `SUFeedURL` points (default: GitHub Pages of this repo). The release workflow can be extended to do this automatically with Sparkle's `generate_appcast` tool; for now it's a manual step.

## Architecture overview

Plain SwiftUI + AppKit, ~3500 lines:

- `Core/` — models, `AppState` (ObservableObject), provider coordinator, `HistoryStore` (JSON-on-disk), `Analytics` (burn-rate), `Announcements` (time-bound banners), `ProjectName` decoder
- `Providers/` — Claude OAuth provider, optional Anthropic Admin
- `Services/` — Keychain reader, HTTP client (429 backoff + microsecond ISO date parsing), OAuth refresh, JSONL aggregator (with smart turn grouping), notifications, Sparkle updater wrapper, widget bridge
- `UI/` — `StatusBarController` (NSStatusItem + tooltip ticker), `PopoverView`, `SettingsView`, `OnboardingView`, `FloatingWindow`, Liquid Glass helpers
- `UI/Dashboard/` — Overview, Activity grid (off-main computation + cache), Session history (SwiftUI Charts), Insights (with WoW)
- `UsageTrackerWidget/` — separate target: TimelineProvider + SwiftUI views for Small/Medium/Large, shared via App Group

State flow: `DispatchSourceTimer` → `AppState.refreshNow()` → `ProviderCoordinator.snapshot()` → `@Published snapshot` → SwiftUI rerenders + `HistoryStore.append` + `WidgetBridge.publish` + `WidgetCenter.reloadAllTimelines`.

## Style

- Swift 6 (minimal strict concurrency)
- 4-space indents, no trailing semicolons
- Single-line `if`/`guard` are fine for short conditions
- Most types are file-private or internal; public Swift API surface is tiny

## Tests

There are no tests yet. PRs to add them are welcome.
