#!/usr/bin/env bash
# summon-cc wait — tolerant single-shot waiter for one worker. Polls the worker's own
# state dir (never the terminal, never the transcript) and exits the moment something
# actionable happens, printing ONE self-contained block:
#
#   EVENT=STOP      worker ended its turn — its final message follows (captured by the
#                   Stop hook; the transcript is never parsed, its format is unstable)
#   EVENT=QUESTION  worker is paused on AskUserQuestion — the numbered options follow
#   EVENT=DEAD      worker is gone: tmux session killed, or claude exited leaving the
#                   pane's shell behind — seen via SessionEnd when hooks ran, via the
#                   claude_exited sentinel when they didn't (SIGKILL, OOM) — with
#                   post-mortem pointers
#   EVENT=IDLE      nothing within max_secs — heartbeat age + recent activity follow
#
# Silent until then: run it in the background if your harness supports that, or
# blocking if not — either way the orchestrator spends zero context while the worker
# runs. The cursor is automatic (stored in the worker dir): each wait resumes from the
# last event it reported, so re-arming is the SAME command again — no bookkeeping.
# IDLE/DEAD do not advance the cursor. Long silence is normal (thinking, subagents,
# long subprocesses) — re-arm on IDLE; intervene only on evidence of a real stall.
#
# Usage: wait.sh <id> [max_secs]      (id from spawn.sh; max_secs default 1800;
#                                      0 = instant probe: report or IDLE right away)
# Linux + macOS. Requires the summon hooks (they write the signals this reads).
set -uo pipefail

id="${1:?usage: wait.sh <id> [max_secs]}"
max="${2:-1800}"
case "$max" in (''|*[!0-9]*)
  printf 'ERROR: max_secs must be a plain number of seconds, got: %s\n' "$max" >&2; exit 1 ;;
esac
state="${SUMMON_STATE:-$HOME/.local/state/summon}"
d="$state/workers/$id"
[ -d "$d" ] || { printf 'ERROR: no such worker state dir: %s\n' "$d" >&2; exit 1; }

start="$(date +%s)"
cursor="$(cat "$d/cursor" 2>/dev/null || printf '0')"
case "$cursor" in (''|*[!0-9]*) cursor=0 ;; esac

while true; do
  # 1) Stop — the completion signal. Newest Stop line newer than the cursor wins;
  #    it carries the final message, so results outrank everything below.
  if [ -f "$d/events.jsonl" ]; then
    stopline="$(grep '"event":"Stop"' "$d/events.jsonl" 2>/dev/null | tail -1)"
    if [ -n "$stopline" ]; then
      ep="$(printf '%s' "$stopline" | jq -r '.epoch // 0' 2>/dev/null)"
      case "$ep" in (''|*[!0-9]*) ep=0 ;; esac
      if [ "$ep" -gt "$cursor" ]; then
        # Commit the cursor BEFORE printing: a consumer that truncates our output
        # (| head -1, grep -m1) SIGPIPEs this script mid-block, and a cursor written
        # last would never advance — the same event re-delivered forever (verified).
        # Committing first just costs detail lines the consumer chose not to read;
        # the final message stays in events.jsonl either way.
        printf '%s\n' "$ep" > "$d/cursor"
        # permission_mode is echoed verbatim by the hook (a string today). effort is
        # projected too, but current CLIs omit it from the Stop payload (verified
        # 2.1.207 — raw dump has no effort key), so it usually prints nothing; the
        # tolerant display below handles either shape if a future CLI adds it.
        eff="$(printf '%s' "$stopline" | jq -r '.effort | if . == null then empty elif type == "object" then (.level // tojson) else . end' 2>/dev/null)"
        pm="$(printf '%s' "$stopline" | jq -r '.permission_mode | if . == null then empty elif type == "object" then tojson else . end' 2>/dev/null)"
        tp="$(printf '%s' "$stopline" | jq -r '.transcript_path // empty' 2>/dev/null)"
        msg="$(printf '%s' "$stopline" | jq -r '.last_assistant_message // empty' 2>/dev/null)"
        printf 'EVENT=STOP id=%s epoch=%s%s%s\n' "$id" "$ep" "${eff:+ effort=$eff}" "${pm:+ mode=$pm}"
        if [ -n "$msg" ]; then
          printf -- '--- final message ---\n%s\n--- end (transcript, for deep debug only: %s) ---\n' "$msg" "${tp:-none}"
        else
          printf '(no final message captured on this Stop — hook drift, or a turn that ended without text; transcript: %s)\n' "${tp:-unknown}"
        fi
        exit 0
      fi
    fi
  fi

  # 2) Pending question — presence == pending (answering or superseding archives it).
  if [ -f "$d/question.json" ]; then
    qep="$(jq -r '.epoch // 0' "$d/question.json" 2>/dev/null)"
    case "$qep" in (''|*[!0-9]*) qep=0 ;; esac
    if [ "$qep" -gt "$cursor" ]; then
      printf '%s\n' "$qep" > "$d/cursor"   # commit before print — see the Stop branch
      printf 'EVENT=QUESTION id=%s epoch=%s\n' "$id" "$qep"
      jq -r '.questions[] | "Q: " + .question + (if .multiSelect then "  [multi-select]" else "" end),
             (.options | to_entries[] | "  [" + ((.key+1)|tostring) + "] " + .value.label
              + (if (.value.description // "") != "" then " — "
                 + (.value.description | gsub("[\n\r]+";" ") | .[0:150]) else "" end))' \
        "$d/question.json" 2>/dev/null
      printf '(a digit answers a single question: tmux send-keys -t %s 2 · multi-select or several questions: finish with Enter · proof it landed: a QuestionAnswered line in events.jsonl, then re-arm the wait)\n' "$id"
      exit 0
    fi
  fi

  # 3) Claude exited (SessionEnd) with no SessionStart after it → the worker is gone
  #    even if its shell survives, so tmux liveness alone would read as IDLE forever.
  #    Ended-vs-restarted is judged by LINE ORDER in the append-only log, never by
  #    epochs: /clear writes SessionEnd + SessionStart in the same second, and that
  #    tie must read as alive (verified live). kill-session may or may not deliver a
  #    SessionEnd (2.1.207 wrote one; a hard kill won't) — the tmux check below is
  #    the backstop for when it doesn't.
  if [ -f "$d/events.jsonl" ]; then
    seline="$(grep -n '"event":"SessionEnd"' "$d/events.jsonl" 2>/dev/null | tail -1)"
    if [ -n "$seline" ]; then
      se_ln="${seline%%:*}"; seline="${seline#*:}"
      case "$se_ln" in (''|*[!0-9]*) se_ln=0 ;; esac
      ss_ln="$(grep -n '"event":"SessionStart"' "$d/events.jsonl" 2>/dev/null | tail -1)"
      ss_ln="${ss_ln%%:*}"
      case "$ss_ln" in (''|*[!0-9]*) ss_ln=0 ;; esac
      se_ep="$(printf '%s' "$seline" | jq -r '.epoch // 0' 2>/dev/null)"
      case "$se_ep" in (''|*[!0-9]*) se_ep=0 ;; esac
      # -ge, not -gt: claude can exit in the same second as the last-reported event
      # (a /exit right on the heels of a reported STOP) — -gt would suppress this
      # branch forever and a surviving pane shell means eternal IDLE. Safe: the
      # line-order guard alone rejects the /clear tie, and DEAD never advances the
      # cursor anyway.
      if [ "$se_ep" -ge "$cursor" ] && [ "$ss_ln" -lt "$se_ln" ]; then
        printf 'EVENT=DEAD id=%s (claude exited: %s; the pane may still hold a bare shell)\n' \
          "$id" "$(printf '%s' "$seline" | jq -r '.reason // "reason unknown"' 2>/dev/null)"
        printf -- '--- last lifecycle events ---\n'; tail -n 5 "$d/events.jsonl" 2>/dev/null
        printf -- '--- last activity ---\n'; tail -n 5 "$d/activity.log" 2>/dev/null
        exit 0
      fi
    fi
  fi

  # 3b) Exit sentinel with nothing logged after it → claude's process is gone even
  #     though no SessionEnd fired (SIGKILL, OOM — hooks die with the process) while
  #     the pane's shell survives; without this check that death reads as IDLE
  #     forever. An events.jsonl newer than the sentinel means a relaunch wrote
  #     SessionStart after the exit — the tie goes to alive. Ranked below Stop and
  #     question on purpose: unconsumed results outrank death, exactly as in 3.
  if [ -e "$d/claude_exited" ] && [ ! "$d/events.jsonl" -nt "$d/claude_exited" ]; then
    printf 'EVENT=DEAD id=%s (claude exited without a SessionEnd — hard kill or OOM likely; the pane may still hold a bare shell)\n' "$id"
    printf -- '--- last lifecycle events ---\n'; tail -n 5 "$d/events.jsonl" 2>/dev/null
    printf -- '--- last activity ---\n'; tail -n 5 "$d/activity.log" 2>/dev/null
    exit 0
  fi

  # 4) Dead pane with nothing left to report → post-mortem. ('=' pins the target to
  #    an exact session name; tmux would otherwise fall back to prefix matching and
  #    another session could masquerade as this worker.)
  if ! tmux has-session -t "=$id" 2>/dev/null; then
    printf 'EVENT=DEAD id=%s (tmux session gone, no unconsumed Stop)\n' "$id"
    printf -- '--- last lifecycle events ---\n'; tail -n 5 "$d/events.jsonl" 2>/dev/null
    printf -- '--- last activity ---\n'; tail -n 5 "$d/activity.log" 2>/dev/null
    exit 0
  fi

  # 5) Cap.
  now="$(date +%s)"
  if [ $((now - start)) -ge "$max" ]; then
    hb="$(cat "$d/heartbeat" 2>/dev/null || printf '0')"
    case "$hb" in (''|*[!0-9]*) hb=0 ;; esac
    if [ "$hb" -gt 0 ]; then hb_age="$((now - hb))s ago"; else hb_age="never"; fi
    printf 'EVENT=IDLE id=%s waited=%ss last_tool=%s\n' "$id" "$((now - start))" "$hb_age"
    printf -- '--- recent activity ---\n'; tail -n 4 "$d/activity.log" 2>/dev/null
    [ -f "$d/question.json" ] && printf 'note: a question is still pending — if you already answered, the keys may not have taken; peek the pane.\n'
    printf '(usually still working — re-arm the same wait; poke only on real evidence of a stall)\n'
    exit 0
  fi

  # Sleep the remainder when the cap is nearer than the 10s poll, so small caps are
  # honored exactly (the cap check above guarantees left >= 1 here).
  left=$((max - (now - start)))
  [ "$left" -gt 10 ] && left=10
  sleep "$left"
done
