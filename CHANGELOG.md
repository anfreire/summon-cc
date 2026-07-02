# Changelog

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
