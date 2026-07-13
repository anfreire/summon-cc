#!/usr/bin/env bash
# summon-cc hook: PostToolUse → liveness. Overwrites `heartbeat` (epoch) and appends one
# attributed line to `activity.log` per tool call, so a watcher can tell "quietly working"
# from "hung" without capturing the pane. When the answered tool is AskUserQuestion, a
# QuestionAnswered event (carrying the response verbatim) is appended so the orchestrator
# can verify BY SIGNAL that its digit answer landed as intended, and the pending
# question.json is archived — its absence means "no question pending".
# Gates on $SUMMON_ID. Pure logger; exit 0 always.
[ -n "${SUMMON_ID:-}" ] || exit 0
d="${SUMMON_STATE:-$HOME/.local/state/summon}/workers/$SUMMON_ID"
mkdir -p "$d" 2>/dev/null
p="$(cat)"
now="$(date +%s)"
printf '%s\n' "$now" > "$d/heartbeat" 2>/dev/null
printf '%s' "$p" | jq -r --arg t "$now" '
  $t + "  " + (.tool_name // "?") + "  | "
  + ((.tool_input.command // .tool_input.file_path // .tool_input.pattern
      // .tool_input.path // .tool_input.url // (.tool_input | tostring))
     | tostring | gsub("[\n\r]+"; " ") | .[0:160])' >> "$d/activity.log" 2>/dev/null
if [ "$(printf '%s' "$p" | jq -r '.tool_name // ""' 2>/dev/null)" = "AskUserQuestion" ]; then
  printf '%s' "$p" | jq -c --arg t "$now" \
    '{event:"QuestionAnswered",epoch:($t|tonumber),
      answers:((.tool_response.answers? // .tool_response) // {})}' \
    >> "$d/events.jsonl" 2>/dev/null
  [ -f "$d/question.json" ] && mv -f "$d/question.json" "$d/question.answered.json" 2>/dev/null
fi
exit 0
