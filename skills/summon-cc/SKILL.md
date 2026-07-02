---
name: summon-cc
description: Spawn and drive Claude Code worker sessions in detached tmux panes, from any agent on any harness. Use when asked to orchestrate or delegate work to Claude Code sessions, spawn workers, fan tasks out across parallel sessions, run an implement-then-review loop, or supervise long unattended Claude Code runs. Workers are supervised through file signals — never by parsing the terminal.
---

# summon-cc — conduct Claude Code sessions from any agent

You are the **orchestrator**. You spawn full interactive Claude Code sessions ("workers")
in detached tmux panes, hand each a scoped prompt, and supervise them through append-only
file signals. You orchestrate; workers do the work. Two rules make this cheap and calm:
**never parse the terminal** (the signals carry everything; the pane is a debug surface),
and **never idle-poll** (one waiter per worker blocks silently until something happens).

Any agent on any harness can be the orchestrator — every capability here is a plain shell
command. Only the *worker* side is Claude Code, and that's the point: this skill hands
you Claude Code sessions as a building block, unrestricted — what you build with them
(pipelines, review loops, fan-outs, watchdogs) is your call.

## Requirements

- Linux or macOS. Windows is out of scope.
- `bash`, `tmux`, `jq`, and the `claude` CLI on PATH.
- The summon hooks merged into the Claude Code settings that govern the worker's cwd
  (one-time, next section).
- The two scripts sit next to this SKILL.md in `scripts/`; invoke them by **absolute
  path** (your working directory is usually elsewhere). `<skill-dir>` below means this
  skill's directory.

Every worker owns one state directory: `${SUMMON_STATE:-~/.local/state/summon}/workers/<id>/`

| file | meaning |
|---|---|
| `meta.json` | what was spawned: name, cwd, prompt file, effort, permissions |
| `events.jsonl` | lifecycle: SessionStart, UserPromptSubmit, Stop, AskUserQuestion, SessionEnd — Stop lines carry `transcript_path` |
| `question.json` | the pending AskUserQuestion; **presence == pending** (answering archives it) |
| `heartbeat` / `activity.log` | epoch of last tool call / one attributed line per tool call |
| `cursor` | waiter bookkeeping — automatic, don't touch |

## Install (one-time per machine or per project)

Merge this into `.claude/settings.local.json` of the project workers will run in, or into
`~/.claude/settings.json` (global is safe: every hook no-ops unless `$SUMMON_ID` is set,
so ordinary sessions write nothing):

```json
{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "bash <skill-dir>/hooks/on_session_start.sh", "timeout": 10 }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "bash <skill-dir>/hooks/on_prompt_submit.sh", "timeout": 10 }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "bash <skill-dir>/hooks/on_stop.sh",          "timeout": 10 }] }],
    "PostToolUse":      [{ "hooks": [{ "type": "command", "command": "bash <skill-dir>/hooks/on_post_tool.sh",     "timeout": 10 }] }],
    "PreToolUse":       [{ "matcher": "AskUserQuestion", "hooks": [{ "type": "command", "command": "bash <skill-dir>/hooks/on_ask_question.sh", "timeout": 10 }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "bash <skill-dir>/hooks/on_session_end.sh",   "timeout": 10 }] }]
  }
}
```

Merge rules — this is a judgment task and it's yours: replace `<skill-dir>` with this
skill's absolute directory; read the target file first; if it already has hooks for an
event, **append** our entry to that event's existing array — never replace or remove
anything that's there; create the file/keys only where missing. Verify with a hello
worker (spawn one whose prompt is "Reply DONE and end your turn", wait for its STOP).

## Spawn

Write the worker's prompt to a **file** (multi-line pastes as one block), then:

```
bash <skill-dir>/scripts/spawn.sh <name> <prompt-file> [effort] [cwd] [permissions]
```

- `effort`: `low|medium|high|max|default` · `cwd`: worker's project dir (default: yours)
- `permissions`: `bypass` (default — a detached pane can't answer permission prompts;
  workers self-gate instead, see Worker prompts) · `plan` · `accept-edits` · `inherit`

Prints `SUMMONED id=<name>-<hex> state=<dir>` — **the id is the handle for everything.**
Spawn is self-verifying end to end (boot, effort, paste, submit — all against hook
signals, with its own retries). If it fails it says why, loudly, with the pane tail and
the remedy; the two first-run dialogs are the usual cause (Gotchas).

## The loop

`spawn → wait → act on the event → wait again → … → down`

```
bash <skill-dir>/scripts/wait.sh <id> [max_secs]     # default 1800
```

Run it in the background if your harness supports that (it's silent until it exits);
otherwise run it blocking. It costs you nothing while the worker runs, and exits with one
self-contained block:

- **`EVENT=STOP`** — the worker ended its turn; its final message (read from the
  transcript, not the pane) is printed below. Usually the report you asked for — but a
  worker sometimes ends a turn just to tell you something: read it, then poke or re-wait.
- **`EVENT=QUESTION`** — paused on AskUserQuestion; the numbered options are printed.
  Answer (next section), then wait again.
- **`EVENT=IDLE`** — cap hit, nothing happened; heartbeat age + recent tool activity
  printed. Long silence is normal (thinking, subagents, long subprocesses) — re-arm the
  same command. Intervene only on real evidence of a stall.
- **`EVENT=DEAD`** — the tmux session is gone without an unconsumed Stop; post-mortem
  pointers printed (events tail, activity tail).

The cursor is automatic: re-arming is literally the same command; each wait resumes from
the last event it reported.

## Answer a question

Options are numbered in `question.json` order; the pane lists the real options first,
then "Type something" and "Chat". The worker is paused, so keys are unambiguous:

- Single question — a digit selects **and submits**: `tmux send-keys -t <id> 2`
- Multi-question — digits auto-advance per question; after the last, press Enter on the
  Submit step: `tmux send-keys -t <id> 1; sleep 1; tmux send-keys -t <id> 3; sleep 1; tmux send-keys -t <id> Enter`
- Free text exists but is fiddly — prefer a listed option.
- Before submitting a **destructive** choice, confirm the selection on the review screen:
  `tmux capture-pane -t <id> -p | tail -30`

## Poke a running worker

- Queue a follow-up (read at the next turn boundary; queues *behind* a pending question):
  `tmux send-keys -t <id> 'your message' Enter`
- Interrupt generation to redirect: `tmux send-keys -t <id> C-c` (twice to be sure), then
  peek to confirm state.
- A fresh spawn is a blank context — to continue a worker, poke its pane; don't respawn.

## Results, status, debugging

- **Final message**: printed by wait on STOP. Re-read any time:
  `tp=$(grep '"event":"Stop"' $SUMMON_STATE/workers/<id>/events.jsonl | tail -1 | jq -r .transcript_path)`
  `jq -r 'select(.message.role=="assistant")|.message.content[]?|select(.type=="text")|.text' "$tp" | tail -n 200`
  (default `SUMMON_STATE` is `~/.local/state/summon`)
- **Status across workers**:
  `for m in $SUMMON_STATE/workers/*/meta.json; do jq -r '"\(.id)  \(.name)  \(.cwd)"' "$m"; done`
  — cross-check liveness with `tmux ls`, pending questions with `ls $SUMMON_STATE/workers/*/question.json`.
- **Peek** (debug only — every pane capture costs orchestrator context; the signals above
  are the normal path): `tmux capture-pane -t <id> -p | tail -40`

## Teardown

When you've consumed a worker's result: `tmux kill-session -t <id>`. The Claude transcript
persists on disk regardless. Remove the state dir when you're done with its evidence:
`rm -rf $SUMMON_STATE/workers/<id>`. Ids are never reused — a stale dir can't collide.

## Worker prompts — what makes orchestration work

- **Self-contained and scoped.** The worker shares none of your context: state the goal,
  the exact scope, what's out of scope, and "read X and Y yourself". One job per worker.
- **Tell it how to finish**: "END YOUR TURN with a report of A/B/C." Stop is your
  completion signal, so finishing the turn — with the facts you need in the final
  message — is part of the worker's job. You should almost never need its transcript
  beyond that final message.
- **Self-gate risky actions** (essential under `bypass`): instruct the worker to pause
  and ask via **AskUserQuestion before anything irreversible, destructive, or
  out-of-scope** — that routes the decision to you through the QUESTION event, with
  numbered options you can answer by digit.
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
- **Batch**: spawn N workers (distinct names; keep the printed ids), arm one waiter per
  worker, handle whichever exits first, re-arm just that one. Every signal file is
  per-worker — concurrent workers never cross wires. Cap concurrency to what the machine
  and your attention can handle.

## Gotchas

- **Stop is completion; SessionEnd is bookkeeping** — SessionEnd doesn't fire on tmux
  kill or Ctrl-C, so never wait on it. wait.sh already encodes this.
- **First-run dialogs stall boot** (spawn fails loud at the SessionStart step): a machine
  that has never accepted `--dangerously-skip-permissions`, or a cwd Claude doesn't trust
  yet, shows an interactive dialog first. Remedy: `tmux attach -t <id>` (or run `claude`
  in that dir) once, accept, respawn. Don't script past these — they're consent gates.
- **Ghost text** in a pane's input box is autocomplete ghosting, not real input.
- **Hooks gate on `$SUMMON_ID`** — your own and the human's sessions never write to the
  state root, even with the hooks installed globally.
- **Don't extend the scripts with GNU-isms** (`date -d`, `sed -i`, `flock`, `timeout`) —
  epoch-seconds arithmetic and plain POSIX tools are what keep macOS supported.
