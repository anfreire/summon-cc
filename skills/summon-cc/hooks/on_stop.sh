#!/usr/bin/env bash
# summon-cc hook: Stop → the reliable "turn finished" signal. THIS is the completion
# cue (SessionEnd may or may not fire for any given death — never rely on it). The
# event line carries the worker's final message (last_assistant_message) so the
# orchestrator never parses the transcript — whose entry format Claude Code documents
# as unstable — and echoes permission_mode (plus effort, though current CLIs omit it
# from the payload) as spawn bookkeeping; transcript_path is a debug pointer only.
# A completed turn also proves no question modal is on screen: archive a stale
# question.json (e.g. orphaned by an interrupt) so presence keeps meaning pending.
# Gates on $SUMMON_ID. Pure logger; exit 0 always.
[ -n "${SUMMON_ID:-}" ] || exit 0
d="${SUMMON_STATE:-$HOME/.local/state/summon}/workers/$SUMMON_ID"
mkdir -p "$d" 2>/dev/null
cat | jq -c --arg t "$(date +%s)" \
  '{event:"Stop",epoch:($t|tonumber),session_id,transcript_path,effort,permission_mode,
    last_assistant_message:(.last_assistant_message // "")}' \
  >> "$d/events.jsonl" 2>/dev/null
[ -f "$d/question.json" ] && mv -f "$d/question.json" "$d/question.stale.json" 2>/dev/null
exit 0
