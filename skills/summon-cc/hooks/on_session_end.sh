#!/usr/bin/env bash
# summon-cc hook: SessionEnd → exit bookkeeping ONLY. It cannot be trusted to fire
# (a hard kill skips it; tmux kill-session may or may not write one — 2.1.207 did) —
# never treat its absence as "still running" and never use it as the completion
# signal (that's Stop).
# Gates on $SUMMON_ID; exit 0 always.
[ -n "${SUMMON_ID:-}" ] || exit 0
d="${SUMMON_STATE:-$HOME/.local/state/summon}/workers/$SUMMON_ID"
mkdir -p "$d" 2>/dev/null
cat | jq -c --arg t "$(date +%s)" \
  '{event:"SessionEnd",epoch:($t|tonumber),reason,session_id}' \
  >> "$d/events.jsonl" 2>/dev/null
exit 0
