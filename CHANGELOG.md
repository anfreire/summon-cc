# Changelog

## 0.2.0 — 2026-07-13

Zero-install, zero-staleness kernel, hardened by two independent adversarial review
passes. Verified live end to end on claude 2.1.207 / tmux 3.4 — spawn → STOP with the
hook-captured report; question → digit → QuestionAnswered → STOP; `/exit`,
`kill-session`, and hook-less hard kills → the DEAD shapes; every failure path
exercised for real.

- Hooks are injected per worker via `claude --settings` on the launch line — the
  Install section is gone; no user or project settings file is ever touched. Hook
  paths ride single-quoted, so any install path without a single quote in it just
  works (spaces, `&`, unicode). Machines with an older merged install coexist: those
  copies double-fire at worst, and every signal read tolerates duplicates (`tail -1`,
  `grep -q`, overwrite-then-archive).
- The Stop hook captures `last_assistant_message` plus the permission mode; `wait.sh`
  prints the final message from summon's own state. The transcript — whose entry
  format Claude Code documents as unstable — is never parsed; `transcript_path` stays
  recorded as a debug pointer.
- Effort and permission vocabularies are never validated: values pass through
  verbatim (`--effort`, `--permission-mode`), claude is the validator, and the TUI
  `/effort` keystroke step is gone entirely (the 0.1.0 enums were already stale:
  `xhigh` missing; `auto`, `manual`, `dontAsk` unknown). The docs name no example
  values either — `claude --help` is the only vocabulary reference. A bad permission
  mode fails boot fast with claude's own usage error; a bad effort runs silently at
  claude's default — and nothing reports the effective effort back: current CLIs omit
  effort from hook payloads entirely (verified by raw dump on a `--effort low`
  session), so the docs treat effort as fire-and-forget tuning. The Stop hook's
  tolerant pass-through stays, so the STOP line will show effort if a future CLI
  ships the field.
- Input-prefix guard: a prompt file beginning with `/`, `!`, or `#` fails spawn
  instantly with the real reason — the TUI reads those as input prefixes, so the
  paste never submits as a prompt (verified: `/x` runs as a slash command with no
  UserPromptSubmit; `! x` **executes x as a shell command** in the worker's cwd).
  SKILL.md warns the same for pokes (`/exit` in a poke kills the worker). AGENTS.md
  codifies this as the one deliberate guard on Claude's surface — it gates input
  framing, not a feature vocabulary, and the failure it prevents is destructive.
- Worker handles can't cross-wire under tmux's `-t` prefix matching (verified:
  `kill-session -t a-b` kills `a-b1` once `a-b` is gone — digit answers, pokes, and
  kills could all aim at the wrong worker). Three defenses: fixed-width ids
  (`%x%08x` — equal-length ids can't prefix each other), names must not embed an
  id-shaped run (dash + 16 hex: passing a previous worker's ID as a new worker's
  NAME would mint a nested id — the gate is summon's own format, so it can't go
  stale), and every documented target pins with tmux's `=` exact-match prefix
  (`=id` for session commands, `=id:` for pane commands — bare `=id` is not a valid
  pane target).
- Fail-fast boot via an exit sentinel: the launch line ends with
  `; touch <state>/claude_exited`, so the pane's shell drops a file signal the moment
  claude exits, for any reason. Spawn dies in ~a second on a bad flag value (claude's
  own usage error), claude missing from the pane shell's PATH, or a too-old CLI —
  instead of burning the full 45s boot window. The same sentinel guards the
  paste-and-submit phase, and failure remedies never interpolate the possibly-bad
  flags into the suggested command.
- New `QuestionAnswered` event: the answered question's choices land in events.jsonl,
  so digit answers are verifiable by signal — no pane capture needed.
- Ghost-question fix: an orphaned `question.json` (e.g. after an interrupt cancelled
  the modal) is archived by the next prompt submit or Stop — presence keeps meaning
  pending.
- `wait.sh`: every death shape reads DEAD, never eternal IDLE. "claude exited, pane
  shell survives" is seen via SessionEnd when hooks ran, via the `claude_exited`
  sentinel when they didn't (SIGKILL and OOM write no SessionEnd — hooks die with
  the process; verified live). Ended-vs-restarted is judged by line order in the
  append-only events.jsonl, never by epochs (`/clear` writes SessionEnd +
  SessionStart in the same second; an epoch tie read as a false DEAD — verified
  live), and the SessionEnd branch fires on `-ge`, so claude exiting in the same
  second as the last-reported event can't read as eternal IDLE. Unconsumed
  STOP/QUESTION still outrank death. The cursor commits before the event block
  prints, so a truncating consumer (`| head -1`, `grep -m1`) that SIGPIPEs the
  waiter can't make the same event re-deliver forever. Non-numeric `max_secs` fails
  loud instead of looping forever; small caps are honored exactly (`wait.sh <id> 3`
  waits ~3s, not 10); `wait.sh <id> 0` is the instant, cursor-safe status probe.
  IDLE notes a still-pending question; multi-select questions are marked in the
  QUESTION block.
- `spawn.sh`: `env`-prefixed launch line (fish/csh-safe), `SUMMON_CLAUDE_ARGS` escape
  hatch (`--model`, `--resume`, …), shell-safety-only argument checks; an empty
  prompt file fails instantly (it used to boot a worker, paste nothing, and die ~30s
  later on "prompt did not submit"); the submit loop never fires an Enter it can't
  observe (a submit landing in that blind spot reported failure for a worker that
  was actually running — inviting a duplicate spawn); every boot-failure path cleans
  up the state dir it minted; the meta.json write is checked like settings.json's.
- SKILL.md rewritten: three laws, quickstart-first, all one-liners in terms of the
  two printed handles, poke-vs-pending-question warning (text sent into an open
  question modal selects the highlighted option instead of queueing — verified
  live), the swallowed-poke remedy resends Enter before treating silence as a modal
  (a lagged paste leaves the text sitting in the input box; re-pasting would stack a
  second copy), round-robin waiting for harnesses without background execution,
  `mktemp` briefs — one file per worker (concurrent spawns must not share a path;
  sequential reuse was always safe — spawn consumes the file before SUMMONED prints).
- Interrupts: one Escape, never C-c. A rapid double Escape opens the Rewind menu
  (verified) — a modal invisible to the signals that can restore code/conversation;
  recovery: a poke that lands no UserPromptSubmit line means a modal is up — one
  Escape dismisses it, re-poke. A quick double C-c exits an idle claude entirely
  (verified live). An interrupted turn emits no Stop — the next completed one does.
  SessionEnd may or may not fire for any given death (kill-session wrote one on
  2.1.207; a hard kill won't): only its presence means anything, and nothing waits
  on it.
- New gotcha (verified live): permission and plan-approval dialogs are not
  AskUserQuestion — no hook fires, the heartbeat just goes stale. On a non-bypass
  worker, IDLE + old heartbeat + no pending question → peek the pane.
- One-liners hardened: pokes use `send-keys -l` (a one-word message matching a tmux
  key name — `Up`, `Home` — was sent as that key, verified) and a per-worker paste
  buffer (parallel pokes can't cross); fleet status uses `find` (space-safe, quiet
  with zero workers); the quickstart shows the absolute state path spawn actually
  prints.
- Repo slimmed to its lane: one contributor doc instead of three — `GEMINI.md`
  removed, `CLAUDE.md` is now a symlink to `AGENTS.md` (three identical tracked
  copies could only drift, and none of them ship with the skill). AGENTS.md states
  the design intent and the staleness rules, and names the input-framing guard as
  the one sanctioned guard on Claude's surface — add no others.

## 0.1.0 — 2026-07-02

Initial kernel.

- `skills/summon-cc/SKILL.md` — the operating contract: install (merge-don't-clobber),
  spawn, the wait loop (STOP / QUESTION / IDLE / DEAD), answering by digit, poking,
  results/status/teardown one-liners, worker-prompt guidance, decision routing, gotchas.
- `scripts/spawn.sh` — mints the worker id (`<name>-<hex>`, never reused), launches
  `SUMMON_ID=… claude` in a detached tmux pane, and self-verifies the whole startup
  ritual against hook signals (SessionStart for boot, UserPromptSubmit for the paste
  submit, with its own Enter retries). Permission stance is an explicit argument.
- `scripts/wait.sh` — silent single-shot waiter over the per-worker state dir with an
  automatic cursor; prints the worker's final message from the transcript on STOP.
- `hooks/` — six pure loggers (SessionStart, UserPromptSubmit, Stop, PostToolUse,
  PreToolUse[AskUserQuestion], SessionEnd), all gated on `$SUMMON_ID`, all `exit 0`.
- Identity is summon-minted; Claude's session_id is recorded bookkeeping only.
- Platform contract: Linux + macOS (BSD-clean shell), Windows out of scope.
