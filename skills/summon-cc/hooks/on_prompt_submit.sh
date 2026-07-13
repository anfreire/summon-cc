#!/usr/bin/env bash
# summon-cc hook: UserPromptSubmit → proof a prompt actually entered the conversation.
# spawn.sh polls for this line to verify its paste submitted — no terminal parsing.
# A submitted prompt also proves no question modal is on screen: archive a stale
# question.json (e.g. orphaned when an interrupt cancelled the question) so presence
# keeps meaning pending and a later wait can't report a ghost question.
# Gates on $SUMMON_ID. Pure logger; emits nothing to stdout (stdout would inject context).
[ -n "${SUMMON_ID:-}" ] || exit 0
d="${SUMMON_STATE:-$HOME/.local/state/summon}/workers/$SUMMON_ID"
mkdir -p "$d" 2>/dev/null
cat | jq -c --arg t "$(date +%s)" \
  '{event:"UserPromptSubmit",epoch:($t|tonumber),prompt:((.prompt // "")|tostring|.[0:200])}' \
  >> "$d/events.jsonl" 2>/dev/null
[ -f "$d/question.json" ] && mv -f "$d/question.json" "$d/question.stale.json" 2>/dev/null
exit 0
