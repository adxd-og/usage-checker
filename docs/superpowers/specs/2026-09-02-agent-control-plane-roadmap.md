# Omelette → "everything about your agents at a glance" — roadmap

Status: approved by the owner on 2026-09-02 (brainstorm session). Each phase gets
its own spec + plan + release; this document only fixes the direction, the
phase boundaries and the decisions already taken.

## Direction

Omelette today is a usage-limits tracker. The initiative widens it into a menu-bar
"control plane light" for coding agents: limits, which agent sessions are running,
which one is waiting for you, and (later) what shapes those agents. Explicitly
**not** an IDE: no diff review, no team features, no auto-fixes.

Inspiration: blume.codes (Agent Overview / Hidden Files & Rules / Usage Tracking /
See Every Change). We take the first three, keep the glance-first menu-bar format,
stay local-first and open source.

## Decisions already taken

| Topic | Decision |
|---|---|
| Visual direction | "Apple-authored": real Liquid Glass on macOS 26 with a quiet fallback on 14+, ring gauges, battery-style semantic colours (green → amber → red), SF typography with rounded tabular numerals. |
| Popover structure | Segmented control `All · Claude · Codex · …`. **All** = provider tiles (Control-Center style) + agents grouped by status. A provider tab = hero ring for the leading window, weekly windows as small rings, extra usage, 7-day cost, that provider's agents. Default tab: **All**. One enabled provider hides the segment. |
| Menu bar | Existing per-provider pills restyled + a separate **agents pill** with a count: grey when idle, blue when agents are working, amber "1 needs you" when one waits for approval. |
| Agents covered first | Claude Code (full state machine via hooks) + Codex (reduced: working / finished, via `notify` + rollout logs). Antigravity / Cursor deferred (no hook APIs). |
| Depth of Agent Overview | Observation + alerts first; **approve / deny from Omelette is a later phase**, but the hook ↔ app channel is request/response-capable from day one so hook config never changes between phases. |
| Channel | A small helper executable inside the app bundle, invoked by hooks, talking to the app over a Unix domain socket. Invariant: if Omelette is not running or the socket does not answer, the helper exits 0 immediately — an agent must never hang because of us. |
| Colour semantics | Usage: comfortable green, ≥70 % amber, ≥90 % red (was accent/amber/red). Agents: amber "needs you", blue pulse "working", green "done", grey "idle". |

## Phases

### Phase 1 — Design system, new popover, menu bar restyle
Tokens + component kit, the `All` / provider popover, restyled pills. No new data.
Spec: `2026-09-02-design-system-popover-design.md`.

### Phase 2 — Agent Overview
Helper + socket + hook installer (opt-in, previewed, removable), Claude Code hooks,
Codex `notify`, session/state model, passive fallback from the JSONL/rollout logs
(session list + last activity) when hooks are not installed, Agents section in the
popover, agents pill, "needs you" notification with Open, "jump to session".
Spec: `2026-09-02-agent-overview-design.md` (hook facts verified 2026-09-02).

### Phase 3 — Remaining surfaces in the new style
Dashboard (new Agents tab: run history), Settings, floating window, onboarding,
widgets. Each surface is its own plan step; old and new styles never mix on one screen.

### Phase 4 — Approve / deny from Omelette
`PermissionRequest` hook waits on the socket; popover and notification actions
answer it. Needs a security pass (who may answer, timeouts, what happens when the
app quits mid-request).

Prerequisites recorded by the phase-2 code review (hook config needs no change,
the app/helper shape does): `AgentEventServer.serve` handles one connection at a
time on a serial queue with a 1 s read budget and replies inline — holding a
`PermissionRequest` connection open while the user decides would block every
other hook, so `serve` must become per-connection-concurrent and event-kind-aware;
the helper's 500 ms reply wait / 800 ms watchdog must become conditional on
`PermissionRequest` (the hook is registered with `timeout: 5`); the reply line
gains a `decision` payload the helper prints to stdout only for that event.

### Phase 5 — Rules inventory
Read-only map of what shapes a session: CLAUDE.md chain, hooks, MCP servers,
skills, permissions. "Open file" only, no editing.

## Sequencing rationale

Design first because every later surface inherits the tokens and components, and
the popover without agents is a compact low-risk release. The Agents section is
born in the new style instead of being restyled later.
