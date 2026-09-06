# Omelette 🍳

![Omelette — AI usage at a glance](docs/banner.png)

A native macOS menu bar widget that tracks your **AI coding limits** in real time — Claude session and weekly windows, Codex (OpenAI) limits, Antigravity/Gemini quotas, Grok (xAI) usage, Enterprise spend limits, and local $ cost accounting. Built in SwiftUI with Liquid Glass styling for macOS 26 Tahoe.

> **Why "Omelette"?** While reverse-engineering the usage API we found that
> Anthropic's internal codename for Claude Design is `omelette` (the weekly
> window arrives as `seven_day_omelette`). The name was too good to leave
> buried in a JSON key.

## What it shows

If you use Claude Code, Codex, Gemini CLI, Antigravity or Grok, this is the
one place that shows where you stand across all of them, so a rate limit
never catches you mid-task.

- **Claude** — 5-hour session, weekly limits per model (decoded dynamically,
  so new models appear without an update), extra usage credits and
  Enterprise spend limits
- **Codex (OpenAI)** — session and weekly limits from the local Codex CLI,
  plus local $ cost accounting from its session logs
- **Gemini CLI / Antigravity** — Gemini CLI's daily model quotas using its
  Google sign-in, or Antigravity's model-pool quotas (the path for personal
  Google accounts)
- **Grok (xAI)** — billing-period credit usage from the local Grok CLI,
  falling back to grok.com web billing when the CLI is unavailable
- **Costs from local logs, not invented numbers** — every dollar figure is
  computed from the CLI's own session logs at models.dev list prices
- **Last known numbers** — a provider that's closed or signed out keeps its
  last good reading, dimmed, with "· as of 14:05" on the chip, on every
  surface (All tab, popover, dashboard, menu bar, widgets); a **Forget last
  known numbers** button per provider in Settings clears it on demand
- **Pay-as-you-go mode** — accounts without rate windows get a "$ spent"
  pill and an optional weekly budget with percentage bars and alerts

## Agents at a glance

The popover doubles as a control panel for the Claude Code and Codex
sessions you already have running.

- **Live sessions** — every session, grouped *Needs you / Working / Done /
  Idle*, with the project and what it's doing
- **Needs you** covers three things: a permission request, a question
  (`AskUserQuestion`), or a plan waiting for approval — each shows the real
  text (the question's options, the plan's opening lines), one click away
- **Allow / Deny** from the notification and from the session's row, when
  its terminal isn't in front — held for two minutes, then released
  untouched to the terminal if you don't answer; when the terminal is
  already in front, the CLI just asks there
- **Hooks for both CLIs** — eight Claude Code hooks in
  `~/.claude/settings.json`, seven Codex hooks in `~/.codex/hooks.json`,
  installed with one click (Settings → Agents shows the exact JSON first).
  Codex refuses a hook until you trust it once with `/hooks` inside Codex —
  Settings → Agents says when that's still outstanding
- **Jump to the tab** — clicking a row brings its terminal back. Terminal
  and iTerm2 select the exact tab; cmux selects the exact workspace and
  surface over its own socket; Ghostty, Warp, kitty, Alacritty, WezTerm,
  VS Code, VS Code Insiders, Cursor and Windsurf all come to the front

## Command line and MCP

A tiny `omelette` tool ships inside the app, for the terminal and for your
agents.

- `omelette status` prints every provider's windows with exact reset times,
  today's and this week's cost, and what your agents are doing;
  `--json` prints the same snapshot as JSON
- `omelette statusline` prints one line for Claude Code's status bar —
  `◐ 42% · resets in 1h 10m · $4.20 today · ⚑ 1` — installed with one click
  from Settings → General → Command line
- `omelette mcp` is a read-only MCP server on stdio: `get_usage` (every
  provider's windows, resets and costs) and `get_agents` (which sessions
  are working or waiting on you). Nothing is written, nothing leaves your Mac
- One-click install for Claude Code (adds `omelette` to `~/.claude.json`)
  and Codex (adds an `[mcp_servers.omelette]` table to
  `~/.codex/config.toml`) from that same Settings section
- Or add it by hand:
  ```bash
  claude mcp add omelette -- "$HOME/Library/Application Support/UsageTracker/bin/omelette" mcp
  ```
  or, in `~/.codex/config.toml`:
  ```toml
  [mcp_servers.omelette]
  command = "/Users/you/Library/Application Support/UsageTracker/bin/omelette"  # full path, no $HOME
  args = ["mcp"]
  ```
- What an agent actually does with it: before a long task it asks
  `get_usage` and waits for the reset, or picks a cheaper model.

## Dashboard

A separate window, per provider, built from the same local logs.

- **Overview** — the leading window as a ring with the burn verdict, and
  the day's cost
- **Tokens today** — input, output, cache read, cache write and (nested
  under output) thinking, plus the share of context that came from cache
- **History** — a Cost / Tokens switch: cost per day, or the same
  categories stacked per day
- **Insights** — top project, week-over-week change, peak day, busiest hour
- **Activity** — a GitHub-style heatmap of the last 52 weeks
- **Agents tab** — live sessions plus the run history: sessions, agent
  time, approval requests and busiest project over the range you pick,
  finished sessions grouped by day
- Every dollar figure here is the API-equivalent cost of your CLI usage,
  not what your subscription bills — except on a pay-as-you-go account,
  where it's the real bill

## Notifications

- **Threshold alerts** at 80% and 95% (configurable), with quiet-hours support
- **Session-timing alerts** — "burning fast" (would hit the limit before
  the window resets) and "resets soon"
- **Daily summary** — wake up to "Yesterday: $4.20 across 23 turns"
- **Agent banners** — "needs you" (ignores quiet hours by default, opt-out)
  and "finished a turn" (opt-in), each naming its source ("· Claude Code" /
  "· Codex")

## Widgets and floating window

- **Desktop widgets** — per-provider Small / Medium / Large (right-click →
  Edit Widget to pick the provider) and an "All providers" overview widget
- **Floating mini window** — always-on-top, dockable to a corner, shows
  the leading window as a ring plus how many agent sessions are running

## Settings

- **General** — refresh interval, menu bar (percentage mode, per-provider
  visibility), the global peek shortcut, launch at login, provider toggles
  with Forget last known numbers, and **Command line** (PATH, status line,
  MCP server, both installers above)
- **Notifications** — threshold %, session timing, quiet hours, daily summary
- **Agents** — hooks status and install for Claude Code and Codex (with the
  Codex trust line), the Codex `notify` line, alert toggles, the Allow/Deny
  switch with its pending/answered/expired counts, socket diagnostics
- **Account** — connected services, keychain access, optional Admin API
  key, pay-as-you-go weekly budget
- **Advanced** — override the `anthropic-beta` OAuth header, replay the
  welcome tour, force a refresh, reset all settings

## How it works

Reads the OAuth token that **Claude Code** stores in your macOS Keychain
(item name `Claude Code-credentials`) and calls
`https://api.anthropic.com/api/oauth/usage` — the same undocumented endpoint
Claude Code itself uses for its `/usage` command and status line. Omelette
never refreshes that token itself — Claude Code owns its own refresh cycle.
Other providers are read the same reuse-what's-already-there way: the local
Codex CLI's RPC server, a running Antigravity's local language server, the
Gemini CLI's Google sign-in, or the local Grok CLI (with a grok.com fallback).

- Uses **only your own credentials**, already obtained by the tools
  themselves — it never asks you to log in anywhere
- Talks only to: `api.anthropic.com` (usage endpoint, plus Enterprise cost
  reports if you add an Admin API key), `models.dev` (public pricing data),
  `cloudcode-pa.googleapis.com` (Gemini quota, only if enabled),
  `grok.com` (Grok web-billing fallback, only if enabled), `github.com` +
  `adxd-og.github.io` (Sparkle update feed & DMG download), and local RPC to
  the Codex CLI or Antigravity's language server
- Agent status comes from a tiny `omelette-hook` helper inside the app that
  Claude Code and Codex run on their hook events; it talks to Omelette over
  a local Unix socket (0600, 64 KB cap) and forwards only the session id,
  tool name, a truncated summary, folder and host process — never prompts
  or file contents. Every hook exits within 0.8 s except a permission
  request, which the helper holds open for up to 140 s so Omelette can
  answer Allow/Deny; a helper that gets no reply always fails safe
- The `omelette` command-line tool and MCP server only ever read
  `~/Library/Application Support/UsageTracker/status.json`, written after
  every poll. They never start the app, open a socket, or touch the network
- Polls at human-paced intervals (default 60s), honours server `Retry-After`
- **No telemetry, no analytics** — usage history and cost accounting stay
  on your Mac
- Open source end to end — audit anything above

## Requirements

- macOS 14 (Sonoma) or newer — Liquid Glass activates on macOS 26 Tahoe+
- [Claude Code](https://docs.anthropic.com/claude-code) installed and
  signed in (`claude login`)
- Works with Pro / Max / Team / Enterprise subscriptions **and**
  pay-as-you-go Enterprise accounts
- Optional: Codex CLI (ChatGPT sign-in), Gemini CLI or Antigravity (Google
  sign-in), and/or Grok CLI (xAI sign-in) for their providers
- No extra setup for the terminal: Terminal, iTerm2, cmux and every other
  supported host work out of the box

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
