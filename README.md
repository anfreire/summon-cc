# summon-cc

**Give your agent a crew.** Any agent, on any harness, spawns real Claude Code sessions
in the background — briefs them, watches them work, answers their questions, collects
their reports. No terminal scraping. No babysitting.

## Install

```bash
npx skills add anfreire/summon-cc
```

**Needs:** Linux or macOS · `tmux` · `jq` · the [`claude`](https://claude.com/claude-code) CLI.
Installs into Claude Code, Codex, Cursor, Gemini CLI, OpenCode and
[70+ other harnesses](https://github.com/vercel-labs/skills).

## Use

Tell your agent:

```text
Use summon-cc: spawn a worker to build the feature, then a fresh worker to review it.
Supervise both and report back.
```

That's it. First run only, the agent wires six hooks into your Claude Code settings
(it carries the exact config; anything already there is preserved).

Your agent now knows how to:

- **spawn** — a real, interactive Claude Code session in a detached tmux pane
- **wait** — sleep silently until the worker finishes, asks a question, idles, or dies
- **answer** questions by number, **poke** mid-run, **read** the final report, **tear down**

Workers are full sessions: they use tools, ask before doing anything irreversible, and
end with a report. Run one at a time or a whole fleet.

<details>
<summary><b>How it works</b></summary>

<br>

```
your agent (any harness)
   │  spawn ──►  tmux pane: SUMMON_ID=<id> claude   (interactive, hooks live)
   │  wait  ◄──  ~/.local/state/summon/workers/<id>/
   │               events.jsonl    SessionStart · UserPromptSubmit · Stop
   │               question.json   pending question (presence == pending)
   │               heartbeat · activity.log · meta.json
   ▼
 act: read the report, answer by digit, poke, kill — plain tmux + jq one-liners
```

Six tiny hooks turn each worker's lifecycle into append-only files. Two scripts cover
the only timing-critical parts: `spawn.sh` (mints the id, launches, verifies its own
paste-and-submit against hook signals) and `wait.sh` (blocks silently, exits with one
event block: `STOP` + final message · `QUESTION` + numbered options · `IDLE` · `DEAD`).

Everything else is deliberately **not** a program — answering, poking, status, teardown
are one-liners the skill teaches, so the agent stays free to compose them into
pipelines, review loops, fan-outs, watchdogs. It's a skill: the agent is the runtime.

Identity is summon's own (`reviewer-a1b2c3`, minted at spawn) — no harness's
session-id concept is needed anywhere. Hooks no-op outside summoned sessions, so your
own Claude Code use writes nothing.

Born from a real run: a trading-bot features layer implemented and peer-reviewed by
supervised workers — ~40 minutes of unattended work, driven on a few hundred tokens of
orchestrator context.

</details>

<details>
<summary><b>In the box</b></summary>

<br>

```
skills/summon-cc/
├── SKILL.md            the complete operating contract (the product)
├── scripts/spawn.sh    mint id · launch · self-verifying startup
├── scripts/wait.sh     silent waiter → STOP | QUESTION | IDLE | DEAD
└── hooks/              6 pure loggers, gated on $SUMMON_ID
```

8 files. No daemon, no server, no dependencies beyond the four above.

</details>

## License

MIT — see [LICENSE](LICENSE).
