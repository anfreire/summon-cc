#!/usr/bin/env bash
# summon-cc hook: Stop → the reliable "turn finished" signal. THIS is the completion cue
# (SessionEnd does not fire on tmux kill / Ctrl-C / Ctrl-D). Carries transcript_path so
# the orchestrator can read the worker's final message without touching the pane.
# Gates on $SUMMON_ID. Pure logger; exit 0 always.
[ -n "${SUMMON_ID:-}" ] || exit 0
d="${SUMMON_STATE:-$HOME/.local/state/summon}/workers/$SUMMON_ID"
mkdir -p "$d" 2>/dev/null
cat | jq -c --arg t "$(date +%s)" \
  '{event:"Stop",epoch:($t|tonumber),session_id,transcript_path}' \
  >> "$d/events.jsonl" 2>/dev/null
exit 0
