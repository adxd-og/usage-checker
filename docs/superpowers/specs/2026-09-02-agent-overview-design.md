# Phase 2 — Agent Overview

Part of the [agent control plane roadmap](2026-09-02-agent-control-plane-roadmap.md).
Depends on phase 1 (design system, `All` / provider popover, reserved agents-pill slot).

Hook facts below were verified against the current Claude Code docs
(code.claude.com/docs/en/hooks-guide) and the Codex config reference on 2026-09-02.

## Goal

Omelette shows every live Claude Code and Codex session with a state
(`needs you` / `working` / `done` / `idle`), alerts when a session waits for
approval, and gets you back to that session in one click. Observation only:
no approve / deny yet, but the channel is request/response-capable so phase 4
changes no hook configuration.

## Data sources

### Claude Code hooks (precise state)

Registered in `~/.claude/settings.json` (user scope; merges with project hooks).
All entries call the same helper with no arguments; the helper reads the hook JSON
from stdin. Common stdin fields: `session_id`, `transcript_path`, `cwd`,
`permission_mode`, `hook_event_name`; subagent runs add `agent_id` / `agent_type`.

| Event | Matcher | Fields used | Effect on session |
|---|---|---|---|
| `SessionStart` | `""` | `source` | create/refresh session → `idle` |
| `UserPromptSubmit` | `""` | — | `working`, activity cleared |
| `PreToolUse` | `""` | `tool_name`, `tool_input` | `working`, activity = tool summary |
| `PostToolUse` | `""` | `tool_name` | `working` (activity kept until next tool) |
| `PermissionRequest` | `""` | `tool_name`, `tool_input` | `needsYou`, activity = tool summary. Hook emits no decision, so Claude Code prompts as usual. |
| `Notification` | `permission_prompt` | `notification_type` | `needsYou` (fallback if `PermissionRequest` did not fire) |
| `Notification` | `idle_prompt` | `notification_type` | `idle` |
| `Stop` | `""` | `stop_hook_active` | `done` (turn finished, waiting for the next prompt) |
| `SessionEnd` | `""` | `reason` | session closed, moved to history |

Events carrying `agent_id` (subagents) are ignored in this phase.
All hooks are registered with `"async": true` except `PermissionRequest`
(kept synchronous with `"timeout": 5` so phase 4 can answer it without a config
change). `SessionEnd` shares a 1.5 s budget across hooks; the helper's total
budget is 300 ms connect + 500 ms round trip, always exit 0.

Hooks fire identically in the terminal CLI and the VS Code extension. Cloud
sessions never reach the local machine and are out of scope.

### Codex (reduced state)

`~/.codex/config.toml` → `notify = ["<helper>", "--codex"]`. Codex passes one
JSON argument, kebab-case keys, only `type: "agent-turn-complete"` today, with
`thread-id`, `turn-id`, `cwd`. Effect: session `thread-id` → `done`.
No approval event exists (open upstream request), so Codex never shows `needsYou`.
`working` is inferred passively: the session's rollout file under
`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` modified within the last 30 s.

### Passive fallback (no hooks installed)

So the Agents section is useful before the user opts in, and as a safety net:

- Claude Code: JSONL files under `~/.claude/projects/**/*.jsonl` modified in the
  last 30 min → one session each; `cwd` from the log's first `cwd` field; state
  `working` if modified < 30 s ago, else `idle`. Project name via `ProjectName`.
- Codex: same rule on rollout files.

Passive sessions are labelled "approximate" in the UI (grey dot, no `needsYou`).
Once a hook event arrives for a session id, hook state wins and the passive
reading for that id is ignored.

## Components

### `omelette-hook` (new executable target, ships in `Omelette.app/Contents/Helpers/`)

- Reads stdin (Claude) or `--codex '<json>'` (argv) and forwards the raw payload
  plus `source: "claude" | "codex"`, `helper_version`, `received_at`, and
  **host process info**: walks its parent chain with `proc_pidinfo` up to the
  first process whose bundle id is a known terminal / IDE (Terminal, iTerm2,
  Ghostty, Warp, kitty, Alacritty, WezTerm, VS Code, Cursor, Windsurf) and sends
  `host_pid`, `host_bundle_id`, `tty` (of the `claude` / `codex` process).
- Transport: Unix domain socket at
  `~/Library/Application Support/UsageTracker/agent.sock`, one newline-delimited
  JSON message, optional one-line JSON reply (unused in this phase; the helper
  reads it only for `PermissionRequest`, with the 500 ms cap, and prints nothing).
- Invariants: never blocks longer than 800 ms in total, never exits non-zero,
  never writes to stdout except a future decision, never logs payloads to disk.
- Installed through a stable path: on every app launch the app refreshes the
  symlink `~/Library/Application Support/UsageTracker/bin/omelette-hook` →
  bundle helper. Hooks reference the symlink, so moving the app breaks nothing.

### `AgentEventServer` (app)

`NWListener` on the socket path, mode 0600, max 64 KB per message, JSON only.
Decodes into `AgentEvent` (source, event name, session id, cwd, tool summary,
host info, timestamp) and forwards to the store on the main actor. Malformed input
is dropped and counted (visible in Settings → Agents diagnostics).

### `AgentSessionStore` (app, `@MainActor ObservableObject`)

- `sessions: [AgentSession]` — id, source, projectName, cwd, state, activity,
  stateSince, lastEventAt, host (pid, bundle id, tty), isApproximate.
- State machine per the tables above; unknown events keep the current state but
  refresh `lastEventAt`.
- Staleness: a hook-tracked session with no event for 2 h and no live host pid
  (checked with `kill(pid, 0)`) is dropped. `SessionEnd` drops immediately.
- Passive scan every poll tick (reuses the existing 60 s cadence) merged as
  described above.
- History: appends `{id, source, project, startedAt, endedAt, turns, needsYouCount}`
  to `agent-sessions.jsonl` in App Support on session end (phase 3 dashboard reads it).
  No tool inputs are ever persisted.

### Tool summary

`tool summary = "<Tool>: <detail>"`, detail = first 80 chars of `tool_input.command`
(Bash), `file_path` basename (Edit/Write/Read), `pattern` (Grep/Glob), otherwise
empty. This string lives in memory only.

### Hook installer (`AgentHooksInstaller`)

- Reads `~/.claude/settings.json` (creates it if missing), merges our entries
  under `hooks.<Event>` identified by the command path containing
  `UsageTracker/bin/omelette-hook`, preserves everything else, writes atomically
  with a one-time backup `settings.json.omelette-backup`.
- Status: `installed` / `outdated` (entry set differs from the current template)
  / `notInstalled`, recomputed at launch and after each install/remove.
- Codex: if `notify` is absent, writes `notify = [...]` to `config.toml` the
  same atomic way; if `notify` already exists with another value, does **not**
  overwrite — shows the line to paste instead.
- Removal deletes exactly our entries and, for Codex, our `notify` line only.

## UI

### Popover — Agents section (uses phase-1 components)

- **All tab**: after the tiles, `AGENTS · N sessions` header, then groups
  `Needs you` → `Working` → `Done` → `Idle`, each row `OMAgentRow`: provider icon,
  project name, activity or state text, elapsed time since `stateSince`.
  Empty state: one quiet row "No agent sessions" plus, when hooks are not
  installed, a link "Enable precise status" → Settings → Agents.
- **Provider tab**: same rows filtered to that provider, flat list ordered
  `needsYou` first, then by `lastEventAt`.
- Row click = **jump to session**: activate `host_pid`'s app; for Terminal.app
  and iTerm2 additionally select the tab whose tty matches via Apple Events
  (needs `NSAppleEventsUsageDescription`; failure degrades to activation only).
  Sessions without host info fall back to revealing `cwd` in Finder.
- Segmented control shows the amber dot on a provider item while any of its
  sessions is `needsYou`.

### Menu bar — agents pill (`OMAgentsPill`)

Leading slot reserved in phase 1. Hidden when there are no sessions. Grey with
the count when all are idle/done, blue when any is working, amber
`N needs you` when any waits. Reduce Motion respected (no pulse).

### Notifications (`UsageNotifier` extension)

- `needsYou`: immediate notification "Usage tracker needs your approval —
  Bash: xcodegen generate" with an **Open** action (jump to session). One per
  session per `needsYou` episode; cleared when the state leaves `needsYou`.
  Bypasses quiet hours by default (toggle in Settings).
- `done`: opt-in toggle, default off.

### Settings → Agents (new tab)

Enable/Disable buttons per source with the exact JSON / TOML preview, status
line, "Open settings.json", notification toggles, diagnostics (events received,
dropped, socket path, helper version).

### Onboarding

The existing tour gets one card: what Agents shows, with the same Enable button.

## Security and privacy

- Socket 0600 in the user's App Support dir; only JSON; size-capped; parsed
  with `JSONDecoder` into fixed types — no dynamic execution of anything received.
- Hook payload content is treated as data: displayed truncated, never persisted
  beyond the summarised history record above.
- The installer only touches the `hooks` key (Claude) and the `notify` key
  (Codex); it refuses to write when the existing file does not parse.

## Testing

- Unit: state machine transitions (table-driven), tool summary, installer merge
  / remove / outdated detection on fixture JSON and TOML, passive scan on fixture
  directories, staleness rules, notification dedupe rules.
- Integration: launch the app, run the helper against the live socket with
  canned payloads for every event; assert store state.
- Manual: the owner runs a real Claude Code session with hooks installed and a
  Codex turn.

## Packages (for parallel planning)

1. **Helper + transport**: `omelette-hook` target, socket server, `AgentEvent`
   decoding, symlink refresh, build integration (target, copy phase, signing).
2. **Session store + passive scan + history**: state machine, staleness,
   passive Claude/Codex scans, `agent-sessions.jsonl`.
3. **Installer + Settings → Agents + onboarding card**: JSON/TOML merge,
   status, previews, diagnostics.
4. **Popover Agents section + segmented dots + jump to session**.
5. **Agents pill + notifications**.

Packages 1–2 are prerequisites for 4–5; 3 is independent.
