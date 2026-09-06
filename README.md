# Omelette 🍳

![Omelette — AI usage at a glance](docs/banner.png)

A native macOS menu bar widget that tracks your **AI coding limits** in real time — Claude session and weekly windows, Codex (OpenAI) limits, Antigravity/Gemini quotas, Grok (xAI) usage, Enterprise spend limits, and local $ cost accounting. Built in SwiftUI with Liquid Glass styling for macOS 26 Tahoe.

> **Why "Omelette"?** While reverse-engineering the usage API we found that
> Anthropic's internal codename for Claude Design is `omelette` (the weekly
> window arrives as `seven_day_omelette`). The name was too good to leave
> buried in a JSON key.

## Why

If you use [Claude Code](https://docs.anthropic.com/claude-code) heavily, you've probably hit a 5-hour or weekly rate limit mid-task. This widget shows exactly where you are at a glance — across every provider you use — so you can plan ahead and never get caught off guard.

## Features

- **Agent Overview (2.0)** — every live Claude Code and Codex session in the popover,
  grouped *Needs you / Working / Done / Idle*, with the project, what the agent is
  doing and for how long. Click a row to jump back to its terminal tab — Terminal,
  iTerm2 and cmux land on the exact tab, every other terminal or IDE comes to the front
- **Agents pill in the menu bar** — grey when quiet, blue while agents work, amber
  "1 needs you" when one waits for your approval — plus a notification with an
  **Open** button. Powered by Claude Code hooks you enable with one click
  (Settings → Agents shows the exact JSON first and removes it again); without
  hooks, sessions are still read from the CLIs' own logs
- **Approve or deny from Omelette (2.2)** — when a Claude Code or Codex session asks
  for permission and its terminal isn't in front, the notification and the session's
  popover row both offer **Allow** / **Deny**. The request is held for two minutes,
  answered once, and released to the terminal if you don't answer; when the terminal
  is in front, the CLI asks there as usual. Codex runs Omelette's hooks only after
  you trust them once with `/hooks` inside Codex — Settings → Agents says when that
  is still outstanding
- **`omelette` in your terminal (2.4.1)** — a tiny companion tool inside the app.
  `omelette status` prints every provider's windows with exact reset times, today's
  and this week's cost and what your agents are doing; `omelette statusline` prints one
  line for Claude Code's status bar (`◐ 42% · resets in 1h 10m · $4.20 today · ⚑ 1`);
  `omelette mcp` is a read-only MCP server, so Claude Code and Codex can ask what your
  limits are *before* starting something expensive. Settings → General → Command line
  puts it on your PATH and installs the status line and the MCP entries with one click
- **All tab** — one tile per provider with a ring for the leading window, and
  provider tabs with a large session ring and weekly windows as rings
- **Compact menu bar pill per provider** — no Dock icon, no clutter
- **Claude** — 5-hour session, weekly limits per model (decoded dynamically, so new
  models appear without an update), extra usage credits / Enterprise spend limits
- **Codex (OpenAI)** — session and weekly limits from the local Codex CLI, plus
  local $ cost accounting from its session logs
- **Antigravity / Gemini** — model-pool quotas from a running Antigravity
  (the Gemini-quota path for personal Google accounts), or Gemini CLI daily quotas
- **Grok (xAI)** — billing-period credit usage from the local Grok CLI, falling
  back to grok.com web billing when the CLI is unavailable
- **Pay-as-you-go mode** — accounts without rate windows get a "$ spent" pill and
  an optional weekly budget with percentage bars and alerts
- **Native notifications** at 80% and 95% (configurable thresholds) with quiet-hours support
- **Daily summary notification** — wake up to "Yesterday: $4.20 across 23 turns"
- **Dashboard window** with Activity heatmap (GitHub-style, last 52 weeks), Session History chart (cost per day, or tokens split into input / output / cache read / cache write), a "Tokens today" card, and Insights (top project, week-over-week, peak day) — for Claude Code, Codex and the Grok CLI, all read from their local session logs
- **Agents tab in the dashboard (2.1)** — live sessions plus the run history: sessions, agent time,
  approval requests and busiest project over the range you pick, finished sessions grouped by day
- **Desktop widgets** — per-provider Small / Medium / Large widgets (right-click →
  Edit Widget to pick the provider) and an "All providers" overview widget
- **Floating mini window** — always-on-top compact view, dock it to a corner
- **Burn rate prediction** — "At this pace, limit in ~2h 15m"
- **Live model pricing** from [models.dev](https://models.dev) — newly launched
  models are priced correctly without an app update
- **Optional Anthropic Admin API** — org-level spend for Team/Enterprise
- **Liquid Glass** styling on macOS 26+, graceful fallback on macOS 14+

## How it works

Reads the OAuth token that **Claude Code** stores in your macOS Keychain (item name `Claude Code-credentials`) and calls `https://api.anthropic.com/api/oauth/usage` — the same undocumented endpoint Claude Code itself uses for its `/usage` command and status line. Omelette never refreshes that token itself — Claude Code owns its own refresh cycle. Other providers are read the same reuse-what's-already-there way: the local Codex CLI's RPC server, a running Antigravity's local language server, the Gemini CLI's Google sign-in, or the local Grok CLI (with a grok.com fallback).

The widget:
- Uses **only your own credentials**, already obtained by the tools themselves — it never asks you to log in anywhere
- Talks only to: `api.anthropic.com` (usage endpoint, plus Enterprise cost reports if you add an Admin API key), `models.dev` (public pricing data), `cloudcode-pa.googleapis.com` (Gemini quota, only if enabled), `grok.com` (Grok web-billing fallback, only if enabled), `github.com` + `adxd-og.github.io` (Sparkle update feed & DMG download), and local RPC to the Codex CLI or Antigravity's language server
- Agent status comes from a tiny `omelette-hook` helper inside the app that Claude Code / Codex
  run on their hook events; it talks to Omelette over a local Unix socket (0600, 64 KB cap) and
  forwards only the session id, tool name, a truncated tool summary, folder and host process —
  never prompts or file contents. Every hook exits within 0.8 s except a permission
  request: since 2.2 the helper holds that one open for up to 140 s so Omelette can answer
  Allow/Deny (or the terminal answers first), and it still fails safe — no reply from Omelette
  ever means no decision reaches the CLI
- The `omelette` command-line tool reads one file — `~/Library/Application
  Support/UsageTracker/status.json`, which the app writes after every poll — and never
  starts the app, opens a socket or touches the network. With Omelette closed it says
  so and exits 2. Its MCP server is read-only: two tools that answer questions, none
  that change anything
- Polls at human-paced intervals (default 60s), honours server `Retry-After`
- **No telemetry, no analytics** — usage history and cost accounting stay on your Mac
- Open source end to end — audit anything above

## Requirements

- macOS 14 (Sonoma) or newer — Liquid Glass activates on macOS 26 Tahoe+
- [Claude Code](https://docs.anthropic.com/claude-code) installed and signed in (`claude login`)
- Works with Pro / Max / Team / Enterprise subscriptions **and** pay-as-you-go Enterprise accounts
- Optional: Codex CLI (ChatGPT sign-in), Gemini CLI or Antigravity (Google sign-in), and/or Grok CLI (xAI sign-in) for their providers

## Install

1. Download the latest `Omelette.dmg` from [Releases](../../releases)
2. Open the DMG and drag `Omelette.app` to `~/Applications/` (or `/Applications/`).
   Upgrading from Usage Checker ≤ 1.5? Delete the old `UsageChecker.app` first —
   settings, history and widgets carry over automatically
3. Launch it. macOS asks for permission to read the `Claude Code-credentials` Keychain item — click **Always Allow**.
   From then on Omelette works off its own copy and never raises that dialog from a background refresh. It can
   reappear after something resets the item's access list — a reinstall, or a differently signed build — in which
   case Settings → Account → **Request keychain access now** brings it back on demand
4. The icon appears in your menu bar; click it to see usage
5. That's the last manual install — updates arrive automatically via Sparkle (signed & notarized), or on demand via Settings → **Check for updates now**

## Settings

Open via the popover's gear icon (or `⌘,`):

- **General** — refresh interval (30s / 1m / 5m), launch at login, provider toggles (Codex / Gemini / Antigravity / Grok), the `omelette` command line (PATH, Claude Code status line, MCP server), update check
- **Notifications** — threshold alerts, session-timing (burn-fast / reset-soon) alerts, quiet hours, daily summary
- **Agents** — enable/remove the Claude Code hooks, the Codex hooks and the Codex
  `notify` line (with the exact JSON/TOML shown first), the Codex trust status, agent
  alert toggles, menu-bar pill toggle, the switch for answering permission requests
  with its pending / answered / expired counts, socket diagnostics
- **Account** — subscription tier, re-request keychain access, optional Admin API key, pay-as-you-go weekly budget
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

Omelette is **not** affiliated with or endorsed by Anthropic — the name is an
affectionate nod to a codename in their API, nothing more.

## License

[MIT](LICENSE) — do what you like, no warranty.
