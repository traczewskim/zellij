# Design notes

Empirical findings behind the `x1` workspace, and why each design decision
went the way it did. Everything below was tested on this machine — Zellij
0.44.1 (snap), Linux, bash, Claude Code v2.1.241 — not assumed from the docs.
See [README.md](../README.md) for usage; this file is the "why".

## The central trap: what actually gets serialized

Zellij persists a dead session by serializing pane **command lines**, not
processes. A pane started with a bare `claude` resurrects as a bare
`claude` — a brand-new, empty conversation. Resurrected command panes are
also written with `start_suspended true`, so each one waits for an ENTER
press even after `attach -f`.

The fix is to put a stable session UUID into the command line itself, so the
command line describes which conversation the pane belongs to. `ccs <slot>`
derives a stable UUID from a sha1 of the slot name (or reads an override
from `~/.config/claude-slots`), then launches Claude on that conversation.

### F1. `claude --session-id` is create-only, and it is what gets serialized

This is the finding that broke the naive first design. `ccs` `exec`s into
`claude`, so `ccs` itself drops out of the picture after the first launch —
Zellij only ever sees and serializes the *resolved* command, e.g.:

```kdl
pane command="claude" {
    args "--resume" "xxxxxxxx-…" "--name" "main"
}
```

`claude --session-id <uuid>` is **create-only**: running it a second time
with the same uuid dies with, verbatim, `Session ID <uuid> is already in
use`. Every brand-new slot's first launch has to take the create path (there
is no existing conversation to resume yet). If that create-path command were
what got serialized, the pane would come back broken on the very first
resurrection.

**Decision:** `ccs` materializes a new slot's conversation with one headless
turn — `claude --session-id <uuid> -p 'Slot "<slot>" initialised.'` — and
*always* `exec`s the idempotent `--resume` form afterwards, regardless of
whether the slot is new or existing. That `--resume` form is what ends up in
the serialized layout, and it is safe to replay indefinitely.

**Cost, stated plainly:** every new slot opens with one throwaway exchange
(`Slot "x" initialised.`) at the top of its transcript.

**Note on prior art:** the source material this design was adapted from
never hit this bug, because all of its slots were *adopted* pre-existing
conversations — they took the `--resume` branch from their very first
launch. The create path, and the bug in it, only shows up once you start
slots from nothing, which this workspace needs to do routinely (`Ctrl+t n`,
`ccs api` on a brand-new slot name).

### F2. `--resume` will not create

The converse of F1: `claude --resume <unknown-uuid>` exits with
`No conversation found with session ID: <uuid>`. So the create/resume branch
in `ccs` is load-bearing in both directions — there is no single command
that both creates and resumes.

### F3. `post_command_discovery_hook` is not a way out

Zellij's `post_command_discovery_hook` does fire on resurrection (verified
by pointing it at a logging probe). But `$RESURRECT_COMMAND` contains only
the bare binary name — `claude`, no arguments — so it can't recover which
slot a pane belonged to. It carries no information `ccs` could use. Not
used.

## Deriving the running/idle indicator

### F4. The `✳` in Claude's terminal title is not a running indicator

Claude Code writes its own OSC title sequences continuously. Captured
directly over a full work cycle: idle is `✳ <name>`; while working, the
glyph *animates* — `◐`/`◑`/`✳` cycling at roughly 10 Hz. So `✳` is present in
**both** states, and a sidebar reading the title can only ever sample an
arbitrary animation frame. This is the finding that killed every
title-based approach to the indicator.

### F5. Colour cannot vary with tab state via format strings

In the `zellij-vertical-tabs` plugin source, `expand_tmux_format` tokenises
the format string *before* variable substitution, so `#[fg=…]` written
inside a title value is inserted as literal text, not interpreted as a
colour code. There are also only two format variants — `format` and
`format_active` — neither is tied to agent state. So no combination of
format-string tricks can make a tab row change colour based on whether
Claude is working.

**Workaround used:** drive colour from the glyph itself. `🟢`/`⚪` carry
their own colour independent of the row's text style, so `ccs-state` writes
the glyph directly into the pane name instead of trying to style the row.

### F8. An explicit pane name permanently outranks the OSC title

Verified with a script spamming OSC title sequences at 10 Hz: after running
`zellij action rename-pane`, ten further seconds of title spam could not
reclaim the displayed title. This is the property the whole indicator is
built on — once `ccs-state` renames a pane, Claude's own title updates
become invisible to the sidebar, which is exactly what's needed for a stable
two-state readout.

### F9. `rename-pane -p` / `rename-tab -t` can target by id

`zellij action rename-pane -p <pane-id>` (and `rename-tab -t <tab-id>`) can
target a specific pane or tab without moving focus there. A pane knows its
own id via `$ZELLIJ_PANE_ID`. This is why a hook firing in a background tab
can still repaint that tab's row — no focus-stealing required.

**Decision:** the indicator is driven entirely by Claude Code hooks, wired
to `ccs-state`, which renames the firing pane by id:

| Event | State written |
|---|---|
| `SessionStart` | idle |
| `UserPromptSubmit` | working |
| `PostToolUse` | working |
| `Stop` | idle |

`ccs-state` labels the row with, in order: a registered slot name via
`~/.config/claude-slots`; Claude's own session name (F16); and the pane's
directory as a last resort (F15). It no-ops only when there is no Zellij
pane id in the environment, so the hooks are safe to leave installed
globally.

**Verified timeline**, from a real session where a prompt was sent at t=45s
and the agent backgrounded a long-running command, went idle, then resumed
when the command completed:

| t | State shown |
|---|---|
| 36s | ⚪ |
| 48s | 🟢 |
| 54s | ⚪ |
| 81s | 🟢 |
| 84s | ⚪ |

**Tradeoff:** the pane title is now permanently `<state> <label>`; Claude's
own live task-summary title is never shown again for any hooked pane, `ccs`
or not. `zellij action undo-rename-pane -p <id>` restores the OSC title for one
pane; removing the four hooks restores it everywhere.

### F13. `Notification` was tried and rejected

Claude Code's `Notification` hook event fires on ordinary turn completion,
not only when input is genuinely required. Wiring a third "needs attention"
state to it made that state the *resting* state in testing — nearly every
turn ended by tripping it — so it carried no signal. Only `SessionStart`,
`UserPromptSubmit`, and `Stop` are hooked.

### F14. An unpinned pane fails *silently*, in two different ways

The indicator has no way to report "this pane isn't managed", so a bare
`claude` pane degrades into something that still looks plausible in the
sidebar. Observed live, with three panes open and only one of them started
through `ccs`:

| Tab | Process | Row shown | Why |
|---|---|---|---|
| 1 | `claude --resume … --name main` | `⚪ main` | correct |
| 2 | `claude` | `⚪ gamma` | **stale** — frozen leftover name |
| 3 | `claude` | `✳ Claude Code` | raw OSC title, never renamed |

Tab 3 is the benign case: no `--name`, so the title falls back to Claude's
default, and the `session_id` is absent from `~/.config/claude-slots`, so
`ccs-state` exits at the slot lookup and never calls `rename-pane`.

Tab 2 is the dangerous one. It had been a `ccs` slot earlier, was renamed
once, and was later relaunched bare. By F8 a rename permanently outranks the
OSC title — so the row kept reading `⚪ gamma` with nothing behind it
updating that value. A frozen row is pixel-identical to a genuinely idle
one. The indicator was not wrong so much as *unfalsifiable*.

Both cases are also the persistence bug, not just cosmetics: neither pane
carries a session id, so both resurrect empty.

**Decision:** the indicator must not depend on `ccs` at all. See F15.

### F15. The indicator was wrongly coupled to `claude-slots`

`ccs-state` looked the `session_id` up in `~/.config/claude-slots` and
exited when there was no match, so the whole indicator was inert for any
pane not launched through `ccs`. Observed with four tabs open, none
registered: every row showed Claude's own summary title, and the tab that
was actively working showed the same `✳` as the three idle ones — F4,
reproduced end to end.

That coupling was a design error. `ccs` exists for *persistence*; gating the
*indicator* on it meant the common case (a hand-made tab) silently got
nothing, which reads as "the indicator is broken" rather than "this pane is
unmanaged".

`ccs-state` now falls back to the `cwd` from the hook payload
(`basename`), so every Claude pane in Zellij gets a `🟢`/`⚪` row. A
registered slot name still wins when there is one.

**Rejected: a shell guard on bare `claude`.** A `claude()` bash function
that prompted before starting an unpinned session was built and worked
(scripts bypass it, since bash does not export functions to scripts), but it
put a confirmation in front of the single most common command in the
workspace to defend against a resurrection edge case. Removed. The
indicator fix above addresses the visible half of the problem; the
persistence half stays a convention, not an interruption.

### F16. `/rename` drives the label, with a one-message lag

Zellij tab names are unreachable from this sidebar (F15), so the label has
to come from the pane name, and the pane name is set from Claude's own
session name — what `/rename` writes, and what `ccs` passes as `--name`.
It lives in `~/.claude/sessions/<pid>.json` as `name`, keyed by `sessionId`,
which is how `ccs-state` finds it.

**The lag:** `/rename` is a local slash command and fires no hook, so the
row does not repaint until the next `UserPromptSubmit` or `Stop`. Verified:
two panes renamed to `tab1`/`tab2` still displayed their old names, while
the session files already held the new ones. Sending any message in the
pane updates it immediately. There is no rename hook event to subscribe to,
so this is accepted rather than fixed.

**Claude auto-names sessions.** When several sessions share a directory,
Claude Code generates `code`, `code-76`, `code-ea` and so on. So the
cwd-basename branch in `ccs-state` is nearly dead code — a name is almost
always already present. It is kept only as a safety net.

### F17. A mid-turn rename needs `PostToolUse`, which needs a fast script

Claude renames a session *during* a turn as the topic becomes clear. With
only `SessionStart`/`UserPromptSubmit`/`Stop` hooked, the row froze for the
whole turn: observed on an 11-minute turn where the session was already
named `tokens-monitor` while the pane still read `code-ea`. That is a gap,
not a delay — no hook fires between the first prompt and the last token.

`PostToolUse` closes it, but it fires after *every* tool call, and the
script cost 176ms per fire. Measured breakdown:

| Step | Cost |
|---|---|
| `zellij action rename-pane` | 117ms |
| `python3` startup | ~43ms |
| `grep -l` over `~/.claude/sessions` | 15ms |

`zellij action` dominates because it spawns a client that round-trips to the
Zellij server. Two changes made the hook affordable:

- **Skip the rename when the row would not change.** The last-written name
  is cached per pane under `~/.cache/x1-ccs-state/<pane_id>`; an unchanged
  fire never calls Zellij at all.
- **Drop `python3` for `grep`+`sed`.** Interpreter startup alone cost more
  than the whole lookup now does.

| Case | Before | After |
|---|---|---|
| Unchanged (the common case) | 176ms | **17ms** |
| Name or state actually changed | 176ms | 138ms |

**Still not fixed:** a pane sitting fully idle fires no hooks, so a rename
there is invisible until the next message. Only polling could close that,
which is not worth a background timer.

### Deferred: the plugin's activity rows

`zellij-vertical-tabs` master, as of the "activity-sidebar" PR (#3, merged
around June 2026), adds an `activity` pipe and `activity_format` addressed
by session name + tab name, so a hook can update an unfocused tab's row
directly. Activity rows *are* substituted before colour parsing (unlike the
`format`/`format_active` tab rows — see F5), so unlike this design, they
could carry real `#[fg=…]` colour codes rather than relying on an emoji
glyph for colour. What master's activity rows add beyond that is extra rows
*under* each tab — subagent lines, todo checklists — which this design
doesn't attempt at all.

Master does **not** fix F5 for the tab rows themselves; `expand_tmux_format`
is unchanged there. It only adds the new activity-row mechanism alongside
the old one.

The installed v0.1.0 release (Feb 2026) predates this — verified directly,
there are no `activity` strings in the shipped `.wasm`. A master build is
available from the project's CI artifacts: artifact id `7935060782`, built
2026-06-28, **expires 2026-09-26**. A copy is stashed locally at
`~/.config/zellij/plugins/zellij-vertical-tabs.master-20260628.wasm` for
that window. Master pins `zellij-tile` 0.44.0, which is compatible with the
installed Zellij 0.44.1. After the artifact expires, using master would
require `rustup update` — master needs edition 2024, i.e. Rust ≥1.85; this
machine currently has 1.66, with rustup already present.

This is recorded as a considered-and-deferred option with a real expiry
date, not an open TODO. The rename-pane design in this repo needs no plugin
rebuild and no toolchain upgrade, and was preferred for that reason alone —
not because the activity-row approach is worse in principle.

## Plugin permissions

### F6. Plugins render blank, not a prompt, without permissions

Both `zellij-vertical-tabs` and `zjstatus` loaded without error but painted
**nothing** until `~/.cache/zellij/permissions.kdl` explicitly granted
`ReadApplicationState` / `ChangeApplicationState` (plus `RunCommands` for
zjstatus's git-branch widget). There was no visible permission prompt to
answer and no error in the logs — just a blank pane, which looks identical
to a misconfigured plugin path. Anyone debugging "the sidebar is empty" on
this setup should check permissions before anything else.

## KDL layout gotchas

### F7. Inline child nodes do not parse

`slot { args "main" }` written on one line is rejected by Zellij's KDL
parser with `Failed to deserialize KDL node`. The child node must be on its
own line inside braces, as it is in `layouts/x1.kdl`.

### F10. Exiting Claude does not close the tab

Layout panes started with `command=` are *held open* when the command
exits — the pane survives, showing a re-run prompt instead of closing.
`close_on_exit=true` fixes this, but it is **not serialized** by Zellij, so
it would work once and silently revert after the first resurrection.
Deliberately not applied here; close finished tabs with `Ctrl+t x` instead.

### F11. `serialization_interval 60` is a loss window

A session that dies younger than 60 seconds after its last write was never
serialized at all, and vanishes entirely on resurrection rather than coming
back in a stale-but-recoverable state. There is no finer-grained recovery
below the serialization interval.

### F12. CLI shapes that don't match intuition

- `zellij attach` has no `--layout` flag.
- `-s X --layout Y` means "add tabs to the **existing** session X" and fails
  with `Session 'X' not found` if it doesn't exist — it is not a way to
  create `X` with layout `Y`.
- Creating a new session with a layout is `zellij -s <name> -n <layout>`
  (`-n` = `--new-session-with-layout`).
- `delete-session` takes `-f`; `kill-session` takes **no** options.
- `delete-session` erases only Zellij's saved layout state for that session
  name — `ccs <slot>` still resumes the underlying Claude conversation
  afterwards, because that lives under `~/.claude/projects/`, untouched by
  Zellij entirely.

These shapes are why the `zj` alias exists as a single memorized entry
point (`shell/bashrc.fragment`) rather than something to re-derive each
time:

```bash
alias zj='zellij attach -f x1 || zellij -s x1 -n x1'
```
