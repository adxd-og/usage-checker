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
3. **Sparkle EdDSA keys** — already generated; the public key lives in
   `project.yml` (`info.properties.SUPublicEDKey`) and the private key in the
   release Mac's login keychain ("Private key for signing Sparkle updates").
   **Back it up** (`generate_keys -x <file>`, tools ship inside the Sparkle
   SPM artifact under `build/DerivedData/SourcePackages/artifacts/sparkle/`) —
   losing it breaks the update chain for every installed copy. Note: the SU*
   keys must stay in the `info:` block, NOT `INFOPLIST_KEY_*` build settings —
   Xcode silently drops custom keys passed that way.
4. Store notarization credentials once:
   ```bash
   xcrun notarytool store-credentials "UsageChecker-Notary" \
     --apple-id "you@example.com" \
     --team-id "XXXXXXXXXX" \
     --password "xxxx-xxxx-xxxx-xxxx"
   ```

### Local release

Bump `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` in `project.yml`, add the
CHANGELOG section (the appcast release notes are generated from it), then:

```bash
./scripts/build_dmg.sh
./scripts/notarize_dmg.sh
git tag vX.Y.Z && git push origin main vX.Y.Z
gh release create vX.Y.Z build/Omelette.dmg --title "Omelette vX.Y.Z 🍳" --notes "..."
./scripts/update_appcast.sh X.Y.Z <build>   # signs the DMG, prepends the appcast item
git add docs/appcast.xml && git commit -m "Appcast: vX.Y.Z" && git push
```

The appcast lives in `docs/appcast.xml`, served by GitHub Pages (`main`,
`/docs`) at the `SUFeedURL`. Installed apps see the update within a day, or
immediately via "Check for updates now".

### GitHub Actions

Every push to `main` runs an **unsigned build check** (`build-check` job) —
no secrets needed; it catches toolchain/package breakage.

Pushing a tag like `v1.0.0` additionally runs the **release** job: build,
notarize, publish the DMG to a GitHub Release. Without the ASC secrets below
it skips with a warning (release locally instead); the appcast update stays a
local step either way because the Sparkle private key never leaves the
release Mac.

Required secrets in repo Settings → Secrets and variables → Actions:

| Secret | Value |
|--------|-------|
| `APPLE_ID` | Your Apple ID email |
| `APPLE_ID_PASSWORD` | App-specific password (xxxx-xxxx-xxxx-xxxx) |
| `APPLE_TEAM_ID` | Team ID from developer.apple.com |
| `DEVELOPER_ID_CERT_BASE64` | Developer ID Application cert exported as .p12, base64-encoded |
| `DEVELOPER_ID_CERT_PASSWORD` | Password you set when exporting the .p12 |
| `KEYCHAIN_PASSWORD` | Any random string — used for the temporary CI keychain |
| `ASC_KEY_ID` | App Store Connect API key ID (role: Admin) — cloud signing needs it for the app-group provisioning profiles |
| `ASC_ISSUER_ID` | Issuer ID from the same App Store Connect API page |
| `ASC_KEY_P8_BASE64` | The `.p8` key file, base64-encoded |

To export the .p12:
1. Keychain Access → My Certificates → right-click "Developer ID Application: …" → Export → save as `cert.p12` with a password
2. `base64 -i cert.p12 | pbcopy`
3. Paste the contents into the `DEVELOPER_ID_CERT_BASE64` GitHub secret

### Sparkle appcast

`./scripts/update_appcast.sh <version> <build>` signs `build/Omelette.dmg`
with the keychain key and prepends an `<item>` to `docs/appcast.xml`, with
release notes converted to HTML from that version's CHANGELOG section (so
write the CHANGELOG entry before running it). Commit + push; GitHub Pages
serves the feed at the `SUFeedURL`.

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
