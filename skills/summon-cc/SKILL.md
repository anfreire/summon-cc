---
name: summon-cc
description: Spawn and conduct Claude Code worker sessions in detached tmux panes — run Claude Code in the background, from any agent on any harness. Use when asked to orchestrate or delegate work to Claude Code sessions, spawn workers in tmux, fan tasks out across parallel sessions, run an implement-then-review loop, or supervise long unattended Claude Code runs. Workers are supervised through file signals — never by parsing the terminal.
---

# summon-cc — conduct Claude Code sessions from any agent

You are the **orchestrator**. You spawn full interactive Claude Code sessions ("workers")
in detached tmux panes, hand each a scoped prompt, and supervise them through append-only
file signals. You orchestrate; workers do the work. Three laws make this cheap and calm:

1. **Never parse the terminal.** The signals carry everything; the pane is a debug
   surface, read only when a signal says something is wrong.
2. **Never idle-poll.** One waiter per worker blocks silently until something happens.
3. **Act on signals, verify by signals.** Every move — spawn, prompt, answer — leaves a
   signal proving it landed. The scripts verify their own steps; you verify yours.

Any agent on any harness can be the orchestrator — every capability here is a plain shell
command. Only the *worker* side is Claude Code, and that's the point: this skill hands
you Claude Code sessions as a building block, unrestricted — what you build with them
(pipelines, review loops, fan-outs, watchdogs) is your call.

## Requirements

- Linux or macOS; `bash`, `tmux`, `jq`, and a `claude` CLI with `--settings` and
  `--effort` (any current one — `claude --help` to confirm).
- **Nothing to install or wire.** Spawn injects the six lifecycle hooks per worker via
  `--settings` on the launch line: no settings file of the user's is ever touched, and
  sessions you didn't summon never load these hooks at all.
- The two scripts sit next to this SKILL.md in `scripts/`; invoke them by **absolute
  path** (your working directory is usually elsewhere). `<skill-dir>` below means this
  skill's directory.

## Quickstart — one worker, start to finish

```
brief="$(mktemp)"   # a fresh file per worker
printf '%s\n' 'Fix the failing test in src/foo. END YOUR TURN with a one-paragraph report.' > "$brief"
bash <skill-dir>/scripts/spawn.sh fixer "$brief"
# → SUMMONED id=fixer-6a53bd1e00002f40 state=/home/you/.local/state/summon/workers/fixer-6a53bd1e00002f40
bash <skill-dir>/scripts/wait.sh fixer-6a53bd1e00002f40  # silent until → EVENT=STOP + the report
tmux kill-session -t '=fixer-6a53bd1e00002f40'           # done with it ('=' = exact match)
```

`SUMMONED` prints your two handles: the **id** (wait, send-keys, kill) and the **state
dir** (every signal file) — `<id>` and `<state>` below. Everything composes these two.

## Spawn

Write the worker's prompt to a **file** (multi-line pastes as one block). It must not
*begin* with `/`, `!`, or `#` — those are TUI input prefixes (slash command / bash mode /
memory), so the text would run as a command instead of submitting; spawn rejects such
files loudly. Then:

```
bash <skill-dir>/scripts/spawn.sh <name> <prompt-file> [effort] [cwd] [permissions]
```

- `effort` — handed to `claude --effort` verbatim: claude owns the vocabulary
  (`claude --help` lists it); `default` (the default) keeps the session's own
  setting. Fire-and-forget tuning: an unknown value doesn't abort — claude silently runs
  at its default, and nothing reports the effective effort back (no pane warning, and
  current CLIs omit effort from hook payloads; if a future CLI adds it to Stop's, the
  STOP line will show it).
- `cwd` — the worker's project dir (default: yours).
- `permissions` — `bypass` (default → `--dangerously-skip-permissions`: a detached pane
  can't answer permission prompts, so workers self-gate instead — see Worker prompts) ·
  `inherit` (no flag: claude's own default in that cwd) · anything else is handed to
  `--permission-mode` verbatim (`claude --help` lists the modes). A bad mode fails boot
  with claude's own error.
- `SUMMON_CLAUDE_ARGS` — optional env var of extra flags appended verbatim to the launch
  line: `--model haiku` for cheap scouts, `--resume <session_id>` to revive a dead
  worker's conversation in a fresh pane (its session_id is in `<state>/events.jsonl`).

Spawn is self-verifying end to end (boot, paste, submit — all against hook signals, with
its own retries). If it fails it says why, loudly, with the pane tail and the remedy;
the two first-run consent dialogs are the usual cause (Gotchas).

## The loop

`spawn → wait → act on the event → wait again → … → down`

```
bash <skill-dir>/scripts/wait.sh <id> [max_secs]     # default 1800
```

Run it in the background if your harness supports that (it's silent until it exits);
otherwise run it blocking. It costs you nothing while the worker runs, and exits with one
self-contained block:

- **`EVENT=STOP`** — the worker ended its turn; its final message follows, captured by
  the Stop hook (the transcript is never parsed). Usually the report you asked for — but
  a worker sometimes ends a turn just to tell you something: read it, then poke or re-wait.
- **`EVENT=QUESTION`** — paused on AskUserQuestion; the numbered options follow.
  Answer (next section), then wait again.
- **`EVENT=IDLE`** — cap hit, nothing happened; heartbeat age + recent tool activity
  follow. Long silence is normal (thinking, subagents, long subprocesses) — re-arm the
  same command. Intervene only on real evidence of a stall.
- **`EVENT=DEAD`** — the worker is gone: pane killed, or claude exited leaving a bare
  shell behind (the block says which, with post-mortem pointers).

Re-arming is literally the same command again — the cursor (kept in the worker dir)
resumes from the last event reported.

## Answer a question

Options are numbered in `question.json` order; the pane appends its own entries ("Type
something", "Chat about this") *after* the real options, so your numbers are the real ones.

- Single question — a digit selects **and submits**: `tmux send-keys -t <id> 2`
- Several questions — digits auto-advance; after the last, Enter submits the review step:
  `tmux send-keys -t <id> 1; sleep 1; tmux send-keys -t <id> 3; sleep 1; tmux send-keys -t <id> Enter`
- `[multi-select]` — digits toggle, Enter submits.
- Free text exists (the "Type something" option) but is fiddly — prefer a listed option.
- **Verify, don't assume.** The landed answer appends a `QuestionAnswered` line (with the
  chosen labels) to `<state>/events.jsonl`, and the next wait moves past the question. A
  single-question digit commits instantly — there is no review screen — so when the choice
  matters, read the QuestionAnswered line. Multi-question flows end on an Enter-gated
  review screen: before submitting a **destructive** choice, peek it:
  `tmux capture-pane -t <id> -p | tail -30`

## Poke a running worker

**Only when no question is pending** (`<state>/question.json` absent). While a question
modal is up, typed text is captured by the modal and a trailing Enter selects whatever is
highlighted — it answers the question by accident instead of queueing your message
(verified). Answer the question first, or interrupt to cancel it.

- Queue a follow-up (read at the worker's next turn boundary; `-l` = literal, so a
  one-word message like `Up` isn't sent as the tmux key of that name):
  `tmux send-keys -t <id> -l 'your message' && tmux send-keys -t <id> Enter`
- Long or quote-heavy follow-up — paste it the way spawn does (per-worker buffer name,
  so parallel pokes can't cross):
  `tmux load-buffer -b poke-<id> <file> && tmux paste-buffer -t <id> -b poke-<id> -p -d && sleep 1 && tmux send-keys -t <id> Enter`
- Never start a poke with `/`, `!`, or `#` — TUI input prefixes, typed or pasted alike:
  `/` runs a slash command (`/exit` kills the worker), `!` **executes the rest as a
  shell command** in the worker's cwd, `#` opens the memory picker; none submits a
  prompt (verified — no UserPromptSubmit lands). Need a literal one? Lead with
  something else ("Note: /foo …").
- Interrupt generation to redirect: `tmux send-keys -t <id> Escape`, then poke. Escape
  is the TUI's own interrupt key and a no-op on an idle worker — but send it **once**:
  a rapid double Escape opens the Rewind menu (verified), a modal the signals can't
  see that can restore code and conversation. If a poke seems swallowed (no
  UserPromptSubmit line lands), resend Enter first — a lagged paste leaves your text
  sitting in the input box, and one more Enter just submits it (re-pasting first
  would stack a second copy). Still nothing? A modal is up: one Escape dismisses it,
  then re-poke.
  **Never C-c** — a quick double C-c exits claude entirely (verified), and a misjudged
  stall is exactly when you'd hit an idle one. An interrupted turn emits no Stop — the
  next completed turn (your poke's) does. Interrupting cancels a pending question; the
  orphaned question.json is archived automatically the moment your next message submits.
- A fresh spawn is a blank context — to continue a worker, poke its pane; don't respawn.

## Results, status, debugging

- **Final message** — printed by wait on STOP; re-read any time:
  `grep '"event":"Stop"' <state>/events.jsonl | tail -1 | jq -r .last_assistant_message`
- **Answers given** — `grep '"event":"QuestionAnswered"' <state>/events.jsonl | tail -1 | jq -c .answers`
- **All workers** —
  `find "${SUMMON_STATE:-$HOME/.local/state/summon}/workers" -name meta.json -exec jq -r '"\(.id)  \(.name)  \(.cwd)"' {} + 2>/dev/null`
  — cross-check liveness with `tmux ls`, pending questions with
  `find "${SUMMON_STATE:-$HOME/.local/state/summon}/workers" -name question.json 2>/dev/null`.
- **Instant probe** — `bash <skill-dir>/scripts/wait.sh <id> 0` returns at once: any
  unconsumed event, else an IDLE snapshot (heartbeat age + recent activity). Same
  single-shot, cursor-safe semantics as any wait — probing costs nothing.
- **Peek** (debug only — every pane capture costs orchestrator context; the signals above
  are the normal path): `tmux capture-pane -t <id> -p | tail -40`

## Teardown

When you've consumed a worker's result: `tmux kill-session -t '=<id>'` — keep the `=`:
it pins the exact name, where a bare `-t` falls back to prefix matching once the exact
session is gone (Gotchas). The Claude transcript persists on disk regardless. Remove
the state dir when you're done with its evidence: `rm -rf <state>`. Ids are never
reused — a stale dir can't collide.

## Worker prompts — what makes orchestration work

- **Self-contained and scoped.** The worker shares none of your context: state the goal,
  the exact scope, what's out of scope, and "read X and Y yourself". One job per worker.
- **Tell it how to finish**: "END YOUR TURN with a report of A/B/C." Stop is your
  completion signal, so finishing the turn — with the facts you need in the final
  message — is part of the worker's job. The final message is all you should ever need.
- **Self-gate risky actions** (essential under `bypass`): instruct the worker to pause
  and ask via **AskUserQuestion before anything irreversible, destructive, or
  out-of-scope** — that routes the decision to you through the QUESTION event, with
  numbered options you answer by digit.
- **Independent review catches more**: for pipelines, have one worker do the step and a
  *fresh* worker review it; repeat until a reviewer that changed nothing approves.

## Decision routing

When a worker asks: answer it yourself if the task's constraints already determine the
answer, or the choice is recoverable — keep the work moving. Escalate to the human only
what is genuinely new, material, or irreversible. When unsure whether something is
reversible, treat it as escalate-worthy. Agree this boundary with the human up front.

## One-by-one vs batch

- **One-by-one**: spawn → wait to completion → act → down → next. Each result gates the
  next step; trivial bookkeeping. Default for dependent steps.
- **Batch**: spawn N workers (distinct names, a brief file per worker; keep each
  printed id and state), arm one waiter per worker, handle whichever exits first,
  re-arm just that one. Every signal
  file is per-worker — concurrent workers never cross wires. No background execution on
  your harness? Round-robin with short caps — `wait.sh w1 60; wait.sh w2 60; …` — waits
  are single-shot and cursor-safe, so taking turns loses nothing. Cap concurrency to
  what the machine and your attention can handle.

## The state dir — reference

One per worker: `${SUMMON_STATE:-~/.local/state/summon}/workers/<id>/` (spawn prints it).

| file | meaning |
|---|---|
| `meta.json` | what was spawned: name, cwd, prompt file, effort, permissions, extra args |
| `settings.json` | the six hooks injected into this worker via `--settings` |
| `events.jsonl` | lifecycle: SessionStart, UserPromptSubmit, AskUserQuestion, QuestionAnswered, Stop (carries the final message + permission mode), SessionEnd |
| `question.json` | the pending AskUserQuestion; **presence == pending** (answered/stale copies are archived beside it) |
| `heartbeat` / `activity.log` | epoch of last tool call / one attributed line per tool call |
| `claude_exited` | exit sentinel: the pane's shell drops it the moment claude exits, for any reason (spawn fails fast on it during startup; wait reads it as DEAD when claude dies without a SessionEnd — hard kill, OOM) |
| `cursor` | waiter bookkeeping — automatic, don't touch |

## Gotchas

- **Stop is completion; SessionEnd is bookkeeping** — SessionEnd may or may not fire
  for any given death: a clean `/exit` writes one, `tmux kill-session` sometimes does
  too (2.1.207 did), a hard kill never. Only its presence means anything — never wait
  on it, never read anything into its absence. wait.sh encodes all of this: claude
  gone with the pane's shell still alive reads DEAD — via SessionEnd when it fired,
  via the `claude_exited` sentinel when it didn't (SIGKILL, OOM) — never eternal IDLE.
- **First-run dialogs stall boot** (spawn fails loud at the SessionStart step): a machine
  that has never accepted `--dangerously-skip-permissions`, or a cwd Claude doesn't trust
  yet, shows an interactive dialog first. Remedy: run `claude` once in that dir
  interactively, accept, respawn. Don't script past these — they're consent gates.
- **Non-bypass workers can stall on a permission dialog** — permission and plan-approval
  prompts are not AskUserQuestion: no hook fires, no signal appears, the heartbeat just
  goes stale. On a non-bypass worker, IDLE + old heartbeat + no pending question → peek
  the pane; answer the dialog with send-keys, or respawn under bypass.
- **Vocabularies live in claude, not here.** Effort levels and permission modes are
  passed through verbatim and never validated — `claude --help` is the source of truth.
- **Ghost text** in a pane's input box is autocomplete ghosting, not real input.
- **tmux `-t` prefix-matches once no exact name survives** — a dead worker's id could
  then resolve to a similarly named session (verified: killing a dead id's prefix
  killed the longer live one). Defense in depth: ids are fixed-width, spawn rejects
  names that embed an id-shaped run (so one id can never nest another — don't pass an
  old worker's *id* as a new worker's *name*), and the teardown one-liner pins with
  `=`. Pane-target commands take the same pinning as `-t '=<id>:'` if you want it for
  send-keys/paste/capture.
- **Hooks gate on `$SUMMON_ID`** and are injected per worker — no session you didn't
  summon loads or writes anything. Machines with an older merged install coexist fine:
  those copies double-fire at worst, and every signal read tolerates duplicates
  (`tail -1`, `grep -q`, overwrite-then-archive).
- **Don't extend the scripts with GNU-isms** (`date -d`, `sed -i`, `flock`, `timeout`) —
  epoch-seconds arithmetic and plain POSIX tools are what keep macOS supported.
