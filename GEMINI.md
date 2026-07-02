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
