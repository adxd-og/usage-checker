# Omelette 🍳

![Omelette — AI usage at a glance](docs/banner.png)

A native macOS menu bar widget that tracks your **AI coding limits** in real time — Claude session and weekly windows, Codex (OpenAI) limits, Antigravity/Gemini quotas, Enterprise spend limits, and local $ cost accounting. Built in SwiftUI with Liquid Glass styling for macOS 26 Tahoe.

> **Why "Omelette"?** While reverse-engineering the usage API we found that
> Anthropic's internal codename for Claude Design is `omelette` (the weekly
> window arrives as `seven_day_omelette`). The name was too good to leave
> buried in a JSON key.

![Screenshot](docs/screenshot.png)

## Why

If you use [Claude Code](https://docs.anthropic.com/claude-code) heavily, you've probably hit a 5-hour or weekly rate limit mid-task. This widget shows exactly where you are at a glance — across every provider you use — so you can plan ahead and never get caught off guard.

## Features

- **Compact menu bar pill per provider** — no Dock icon, no clutter
- **Claude** — 5-hour session, weekly limits per model (decoded dynamically, so new
  models appear without an update), extra usage credits / Enterprise spend limits
- **Codex (OpenAI)** — session and weekly limits from the local Codex CLI, plus
  local $ cost accounting from its session logs
- **Antigravity / Gemini** — model-pool quotas from a running Antigravity
  (the Gemini-quota path for personal Google accounts), or Gemini CLI daily quotas
- **Pay-as-you-go mode** — accounts without rate windows get a "$ spent" pill and
  an optional weekly budget with percentage bars and alerts
- **Native notifications** at 80% and 95% (configurable thresholds) with quiet-hours support
- **Daily summary notification** — wake up to "Yesterday: $4.20 across 23 turns"
- **Dashboard window** with Activity heatmap (GitHub-style, last 52 weeks), Session History chart, and Insights (top project, week-over-week, peak day)
- **Desktop widgets** — per-provider Small / Medium / Large widgets (right-click →
  Edit Widget to pick the provider) and an "All providers" overview widget
- **Floating mini window** — always-on-top compact view, dock it to a corner
- **Burn rate prediction** — "At this pace, limit in ~2h 15m"
- **Live model pricing** from [models.dev](https://models.dev) — newly launched
  models are priced correctly without an app update
- **Optional Anthropic Admin API** — org-level spend for Team/Enterprise
- **Liquid Glass** styling on macOS 26+, graceful fallback on macOS 14+

## How it works

Reads the OAuth token that **Claude Code** stores in your macOS Keychain (item name `Claude Code-credentials`) and calls `https://api.anthropic.com/api/oauth/usage` — the same undocumented endpoint Claude Code itself uses for its `/usage` command and status line. Other providers are read the same reuse-what's-already-there way: the local Codex CLI's RPC server, a running Antigravity's local language server, or the Gemini CLI's Google sign-in.

The widget:
- Uses **only your own credentials**, already obtained by the tools themselves — it never asks you to log in anywhere
- Talks only to: `api.anthropic.com` / `console.anthropic.com` (usage + token refresh), `models.dev` (public pricing data), `cloudcode-pa.googleapis.com` (Gemini quota, only if enabled), `github.com` (update check), and localhost RPC for Codex/Antigravity
- Polls at human-paced intervals (default 60s), honours server `Retry-After`
- **No telemetry, no analytics** — usage history and cost accounting stay on your Mac
- Open source end to end — audit anything above

## Requirements

- macOS 14 (Sonoma) or newer — Liquid Glass activates on macOS 26 Tahoe+
- [Claude Code](https://docs.anthropic.com/claude-code) installed and signed in (`claude login`)
- Works with Pro / Max / Team / Enterprise subscriptions **and** pay-as-you-go Enterprise accounts
- Optional: Codex CLI (ChatGPT sign-in) and/or Antigravity for their providers

## Install

1. Download the latest `Omelette.dmg` from [Releases](../../releases)
2. Open the DMG and drag `Omelette.app` to `~/Applications/` (or `/Applications/`).
   Upgrading from Usage Checker ≤ 1.5? Delete the old `UsageChecker.app` first —
   settings, history and widgets carry over automatically
3. Launch it. macOS will ask once for permission to read the `Claude Code-credentials` Keychain item — click **Always Allow**
4. The icon appears in your menu bar; click it to see usage

## Settings

Open via the popover's gear icon (or `⌘,`):

- **General** — refresh interval (30s / 1m / 5m), launch at login, provider toggles (Codex / Gemini / Antigravity), update check
- **Notifications** — threshold alerts, quiet hours, daily summary
- **Account** — subscription tier, optional Admin API key, pay-as-you-go weekly budget
- **Advanced** — override the `anthropic-beta` OAuth header, reset settings

> **Updating:** automatic updates aren't wired up yet — grab new versions from
> [Releases](../../releases) (they ship often).

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

Omelette is **not** affiliated with or endorsed by Anthropic — the name is an
affectionate nod to a codename in their API, nothing more.

## License

[MIT](LICENSE) — do what you like, no warranty.
