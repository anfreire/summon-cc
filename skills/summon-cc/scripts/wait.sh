#!/usr/bin/env bash
# summon-cc wait — tolerant single-shot waiter for one worker. Polls the worker's own
# state dir (never the terminal) and exits the moment something actionable happens,
# printing ONE self-contained block:
#
#   EVENT=STOP      worker ended its turn — its final message (from the transcript) follows
#   EVENT=QUESTION  worker is paused on AskUserQuestion — the numbered options follow
#   EVENT=DEAD      tmux session is gone with no unconsumed Stop — post-mortem pointers follow
#   EVENT=IDLE      nothing within max_secs — heartbeat age + recent activity follow
#
# Silent until then: run it in the background if your harness supports that, or blocking
# if not — either way the orchestrator spends zero context while the worker runs.
# The cursor is automatic (stored in the worker dir): each wait resumes from the last
# event it reported, so re-arming is the SAME command again — no since-bookkeeping.
# IDLE/DEAD do not advance the cursor. Long silence is normal (thinking, subagents,
# long subprocesses) — re-arm on IDLE; intervene only on evidence of a real stall.
#
# Usage: wait.sh <id> [max_secs]      (id from spawn.sh; max_secs default 1800)
# Linux + macOS. Requires the summon hooks (they write the signals this reads).
set -uo pipefail

id="${1:?usage: wait.sh <id> [max_secs]}"
max="${2:-1800}"
state="${SUMMON_STATE:-$HOME/.local/state/summon}"
d="$state/workers/$id"
[ -d "$d" ] || { printf 'ERROR: no such worker state dir: %s\n' "$d" >&2; exit 1; }

start="$(date +%s)"
cursor="$(cat "$d/cursor" 2>/dev/null || printf '0')"
case "$cursor" in (''|*[!0-9]*) cursor=0 ;; esac

final_message() {  # $1 = transcript path
  [ -n "$1" ] && [ -f "$1" ] || { printf '(transcript not found: %s)\n' "${1:-none}"; return; }
  printf -- '--- worker output (assistant text, tail; full transcript: %s) ---\n' "$1"
  jq -r 'select(.message.role=="assistant") | .message.content[]? | select(.type=="text") | .text' \
    "$1" 2>/dev/null | tail -n 300
}

while true; do
  # 1) Stop — the completion signal. Newest Stop line newer than the cursor wins.
  if [ -f "$d/events.jsonl" ]; then
    stopline="$(grep '"event":"Stop"' "$d/events.jsonl" 2>/dev/null | tail -1)"
    if [ -n "$stopline" ]; then
      ep="$(printf '%s' "$stopline" | jq -r '.epoch // 0' 2>/dev/null)"
      case "$ep" in (''|*[!0-9]*) ep=0 ;; esac
      if [ "$ep" -gt "$cursor" ]; then
        printf 'EVENT=STOP id=%s epoch=%s\n' "$id" "$ep"
        final_message "$(printf '%s' "$stopline" | jq -r '.transcript_path // empty' 2>/dev/null)"
        printf '%s\n' "$ep" > "$d/cursor"
        exit 0
      fi
    fi
  fi

  # 2) Pending question — presence == pending (answering archives the file).
  if [ -f "$d/question.json" ]; then
    qep="$(jq -r '.epoch // 0' "$d/question.json" 2>/dev/null)"
    case "$qep" in (''|*[!0-9]*) qep=0 ;; esac
    if [ "$qep" -gt "$cursor" ]; then
      printf 'EVENT=QUESTION id=%s epoch=%s\n' "$id" "$qep"
      jq -r '.questions[] | "Q: " + .question,
             (.options | to_entries[] | "  [" + ((.key+1)|tostring) + "] " + .value.label
              + (if (.value.description // "") != "" then " — "
                 + (.value.description | gsub("[\n\r]+";" ") | .[0:150]) else "" end))' \
        "$d/question.json" 2>/dev/null
      printf '(single question: a digit selects AND submits · multi: digits auto-advance, finish with Enter · e.g. tmux send-keys -t %s 2)\n' "$id"
      printf '%s\n' "$qep" > "$d/cursor"
      exit 0
    fi
  fi

  # 3) Dead pane with nothing left to report → post-mortem.
  if ! tmux has-session -t "$id" 2>/dev/null; then
    printf 'EVENT=DEAD id=%s (tmux session gone, no unconsumed Stop)\n' "$id"
    printf -- '--- last lifecycle events ---\n'; tail -n 5 "$d/events.jsonl" 2>/dev/null
    printf -- '--- last activity ---\n'; tail -n 5 "$d/activity.log" 2>/dev/null
    exit 0
  fi

  # 4) Cap.
  now="$(date +%s)"
  if [ $((now - start)) -ge "$max" ]; then
    hb="$(cat "$d/heartbeat" 2>/dev/null || printf '0')"
    case "$hb" in (''|*[!0-9]*) hb=0 ;; esac
    if [ "$hb" -gt 0 ]; then hb_age="$((now - hb))s ago"; else hb_age="never"; fi
    printf 'EVENT=IDLE id=%s waited=%ss last_tool=%s\n' "$id" "$((now - start))" "$hb_age"
    printf -- '--- recent activity ---\n'; tail -n 4 "$d/activity.log" 2>/dev/null
    printf '(usually still working — re-arm the same wait; poke only on real evidence of a stall)\n'
    exit 0
  fi

  sleep 10
done
