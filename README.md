# Usage Checker

A native macOS menu bar widget that tracks your **Claude AI subscription usage** in real time — current 5-hour session, weekly limits per model, and extra credits. Built in SwiftUI with Liquid Glass styling for macOS 26 Tahoe.

![Screenshot](docs/screenshot.png)

## Why

If you use [Claude Code](https://docs.anthropic.com/claude-code) heavily, you've probably hit a 5-hour or weekly rate limit mid-task. This widget shows exactly where you are at a glance, so you can plan when to switch from Opus to Sonnet, and never get caught off guard.

## Features

- **Compact menu bar pill** — no Dock icon, no clutter
- **One-click popover** with all usage windows: 5-hour session, weekly limits (All models, Opus only, Sonnet only, Claude Design, Cowork, OAuth apps), extra usage credits
- **Native notifications** at 80% and 95% (configurable thresholds) with quiet-hours support
- **Daily summary notification** — wake up to "Yesterday: $4.20 across 23 turns"
- **Dashboard window** with Activity heatmap (GitHub-style, last 52 weeks), Session History chart, and Insights (top project, week-over-week, peak day)
- **Desktop widgets** — Small / Medium / Large WidgetKit widgets for desktop or Notification Center
- **Floating mini window** — always-on-top compact view, dock it to a corner
- **Burn rate prediction** — "Hit limit in ~2h 15m at current rate"
- **Claude Code CLI stats** — parse `~/.claude/projects/**/*.jsonl` with smart turn grouping for accurate token / $ accounting
- **Optional Anthropic Admin API** — for Team/Enterprise organisations
- **Auto-update** via Sparkle — get new releases automatically
- **Liquid Glass** styling on macOS 26+, graceful fallback on macOS 14+

## How it works

Reads the OAuth token that **Claude Code** stores in your macOS Keychain (item name `Claude Code-credentials`) and calls `https://api.anthropic.com/api/oauth/usage` — the same undocumented endpoint Claude Code itself uses for its `/usage` command and status line.

The widget:
- Uses **only your own OAuth token** (the one Claude Code already obtained)
- Talks **only to `api.anthropic.com`** and (for updates) `github.com`
- Sends `User-Agent: claude-code/<version>` to match the official client
- Polls at human-paced intervals (default 60s)
- **No telemetry, no analytics**

## Requirements

- macOS 14 (Sonoma) or newer — Liquid Glass activates on macOS 26 Tahoe+
- [Claude Code](https://docs.anthropic.com/claude-code) installed and signed in (`claude login`)
- An active Claude subscription (Pro / Max / Team / Enterprise)

## Install

1. Download the latest `UsageChecker.dmg` from [Releases](../../releases)
2. Open the DMG and drag `UsageChecker.app` to `~/Applications/` (or `/Applications/`)
3. Launch it. macOS will ask once for permission to read the `Claude Code-credentials` Keychain item — click **Always Allow**
4. The icon appears in your menu bar; click it to see usage

## Settings

Open via the popover's gear icon (or `⌘,`):

- **General** — refresh interval (30s / 1m / 5m), launch at login, auto-update toggle
- **Notifications** — threshold alerts, quiet hours, daily summary
- **Account** — see your subscription tier, manage optional Admin API key
- **Advanced** — override the `anthropic-beta` OAuth header, reset settings

## Build from source

See [CONTRIBUTING.md](CONTRIBUTING.md).

TL;DR:
```bash
brew install xcodegen
./scripts/setup.sh      # creates signing.xcconfig from the example
./scripts/build_dmg.sh
```

## Disclaimer

`/api/oauth/usage` is an **undocumented** endpoint that the official Claude Code CLI uses internally. Anthropic may change or remove it at any time. If that happens, this widget will gracefully show "Error" until it's updated.

Usage Checker is **not** affiliated with or endorsed by Anthropic.

## License

[MIT](LICENSE) — do what you like, no warranty.
