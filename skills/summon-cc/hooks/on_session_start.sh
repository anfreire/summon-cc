#!/usr/bin/env bash
# summon-cc hook: SessionStart → lifecycle event line. Records Claude's session_id and
# transcript_path as bookkeeping — summon's own id ($SUMMON_ID) is the public handle.
# Gates on $SUMMON_ID: sessions not launched by summon write nothing. Pure logger; exit 0 always.
[ -n "${SUMMON_ID:-}" ] || exit 0
d="${SUMMON_STATE:-$HOME/.local/state/summon}/workers/$SUMMON_ID"
mkdir -p "$d" 2>/dev/null
cat | jq -c --arg t "$(date +%s)" --arg id "$SUMMON_ID" \
  '{event:"SessionStart",epoch:($t|tonumber),summon_id:$id,session_id,source,cwd,transcript_path}' \
  >> "$d/events.jsonl" 2>/dev/null
exit 0
