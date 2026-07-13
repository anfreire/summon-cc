# AGENTS.md

This repository ships one skill: **`skills/summon-cc/SKILL.md`** — the complete operating
contract for spawning and conducting Claude Code worker sessions from any agent. Read it
before using anything here; it is the product, and the only document a working agent needs.

The two scripts (`scripts/spawn.sh`, `scripts/wait.sh`) and six hooks (`hooks/`) are
invoked by absolute path from wherever the skill is installed — nothing assumes a PATH
entry or a fixed location. Supported platforms: Linux and macOS. Windows is out of scope.

Design intent, for anyone changing this repo: it is a **skill, not a program**. Knowledge
lives in SKILL.md as prose the agent executes with its own tools; a file exists only where
prose cannot be reliable (hooks must be registered commands; spawn and wait are
timing-critical loops). Resist adding verbs, wrappers, or state machines — delegate
judgment to the agent. Keep the scripts BSD-clean: epoch-seconds time math only, no
`date -d`, no `sed -i`, no `flock`, no `timeout`.

Staleness rules, learned the hard way: **never gate on Claude's vocabularies** (effort
levels, permission modes — pass them through verbatim; claude is the validator and the
error surface) and **never parse undocumented formats** (the session transcript's entry
format is explicitly unstable — the worker's final message comes from the Stop hook's
`last_assistant_message` instead). Hooks are injected per worker via `--settings` at
spawn; nothing is ever merged into anyone's Claude settings. If a change adds an enum
gate, a transcript parser, or an install step, it is wrong.

One deliberate exception: spawn's input-framing guard (a prompt file may not *begin*
with `/`, `!`, or `#`). That gates how the TUI frames input, not a feature vocabulary —
without it, a prompt starting with `!` silently **executes as a shell command** in the
worker's cwd. A false reject is a loud, self-explaining error fixed by rewording;
the failure it prevents is destructive. Keep the guard; add no others.
