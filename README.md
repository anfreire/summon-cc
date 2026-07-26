# summon-cc

**Give your agent a crew.** Any agent, on any harness, spawns real Claude Code sessions
in the background — briefs them, watches them work, answers their questions, collects
their reports. No terminal scraping. No babysitting.

![summon-cc: an opencode agent conducts a Claude Code worker — brief, spawn, question, answer, report, teardown](https://raw.githubusercontent.com/anfreire/summon-cc/main/docs/demo.gif)

*Above, unscripted: an **opencode** agent running **Kimi K2.6** briefs and spawns a Claude
Code worker, waits on file signals, reads its question, answers by digit, collects the
report, and tears the session down — one prompt, "Build · Kimi K2.6 · 58.0s".*

## Install

```bash
npx skills add anfreire/summon-cc
```

**Needs:** Linux or macOS · `tmux` · `jq` · a current [`claude`](https://claude.com/claude-code) CLI
(one that knows `--settings` and `--effort`).
Installs into Claude Code, Codex, Cursor, Gemini CLI, OpenCode and
[70+ other harnesses](https://github.com/vercel-labs/skills).

## Use

Tell your agent:

```text
Use summon-cc: spawn a worker to build the feature, then a fresh worker to review it.
Supervise both and report back.
```

That's it. Nothing to wire up: each worker gets the six lifecycle hooks injected at
spawn (`--settings` on its own launch line) — your Claude Code settings are never
touched, and sessions you didn't summon never load them.

Your agent now knows how to:

- **spawn** — a real, interactive Claude Code session in a detached tmux pane
- **wait** — sleep silently until the worker finishes, asks a question, idles, or dies
- **answer** questions by number, **poke** mid-run, **read** the final report, **tear down**

Workers are full sessions: they use tools, ask before doing anything irreversible, and
end with a report. Run one at a time or a whole fleet. Born from a real run: a
trading-bot features layer implemented and peer-reviewed by supervised workers —
~40 minutes of unattended work, driven on a few hundred tokens of orchestrator context.

<details>
<summary><b>How it works</b></summary>

<br>

```
your agent (any harness)
   │  spawn ──►  tmux pane: env SUMMON_ID=<id> claude --settings <worker>/settings.json
   │  wait  ◄──  ~/.local/state/summon/workers/<id>/
   │               events.jsonl    SessionStart · UserPromptSubmit · AskUserQuestion
   │                               · QuestionAnswered · Stop (+ final message) · SessionEnd
   │               question.json   pending question (presence == pending)
   │               heartbeat · activity.log · meta.json · settings.json
   ▼
 act: read the report, answer by digit, poke, kill — plain tmux + jq one-liners
```

Six tiny hooks turn each worker's lifecycle into append-only files — including the
worker's final message, captured on Stop, so nothing ever parses Claude's transcript or
scrapes the pane. Two scripts cover the only timing-critical parts: `spawn.sh` (mints
the id, injects the hooks, launches, verifies boot and paste-and-submit against hook
signals) and `wait.sh` (blocks silently, exits with one event block: `STOP` + final
message · `QUESTION` + numbered options · `IDLE` · `DEAD`).

Everything else is deliberately **not** a program — answering, poking, status, teardown
are one-liners the skill teaches, so the agent stays free to compose them into
pipelines, review loops, fan-outs, watchdogs. It's a skill: the agent is the runtime.

Identity is summon's own (`reviewer-a1b2c3`, minted at spawn) — no harness's
session-id concept is needed anywhere. Hooks no-op outside summoned sessions, so your
own Claude Code use writes nothing.

Claude Code's native `claude --bg` runs fire-and-forget background agents managed from
inside Claude Code; summon is the other shape — any harness as the conductor, fully
interactive workers, questions and reports routed back as file signals.

</details>

<details>
<summary><b>In the box</b></summary>

<br>

```
skills/summon-cc/
├── SKILL.md            the complete operating contract (the product)
├── scripts/spawn.sh    mint id · inject hooks · launch · self-verifying startup
├── scripts/wait.sh     silent waiter → STOP | QUESTION | IDLE | DEAD
└── hooks/              6 pure loggers, gated on $SUMMON_ID
```

9 files. No daemon, no server, no install step, no dependencies beyond the four above.

</details>

## License

MIT — see [LICENSE](LICENSE).

---

**More agent tooling** — [patch-cc](https://github.com/anfreire/patch-cc): patch the Claude Code binary (live thinking, Codex models) · [cc-oc](https://github.com/anfreire/cc-oc): drive opencode from inside Claude Code · [omoctl](https://github.com/anfreire/omoctl): manage oh-my-openagent profiles · [wiki-spaces](https://github.com/anfreire/wiki-spaces): a wiki your AI agent keeps
