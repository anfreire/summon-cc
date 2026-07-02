#!/usr/bin/env bash
# summon-cc hook: PreToolUse(AskUserQuestion) → capture the EXACT pending question so the
# orchestrator can answer precisely by option number. Per-worker file (no cross-worker
# races); on_post_tool.sh archives it once answered, so presence == pending.
# Emits nothing to stdout, so the question panel still renders in the pane.
# Gates on $SUMMON_ID. Pure logger; exit 0 always.
[ -n "${SUMMON_ID:-}" ] || exit 0
d="${SUMMON_STATE:-$HOME/.local/state/summon}/workers/$SUMMON_ID"
mkdir -p "$d" 2>/dev/null
p="$(cat)"
t="$(date +%s)"
printf '%s' "$p" | jq --arg t "$t" \
  '{event:"AskUserQuestion",epoch:($t|tonumber),questions:(.tool_input.questions // [])}' \
  > "$d/question.json" 2>/dev/null
printf '%s' "$p" | jq -c --arg t "$t" \
  '{event:"AskUserQuestion",epoch:($t|tonumber),questions:(.tool_input.questions // [])}' \
  >> "$d/events.jsonl" 2>/dev/null
exit 0
