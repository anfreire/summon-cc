#!/usr/bin/env bash
# summon-cc spawn — mint a worker id, launch an INTERACTIVE Claude Code session in a
# detached tmux pane, and drive the startup ritual entirely against summon's own hook
# signals: boot (SessionStart event) → /effort → paste prompt as ONE bracketed block →
# verified submit (UserPromptSubmit event, resending Enter itself if the paste lags).
# A real PTY is required — AskUserQuestion and hooks don't fire under `claude -p`.
#
# Prints exactly one line on success:   SUMMONED id=<id> state=<workers-dir>
# The id is the public handle for everything (wait, send-keys, kill). Claude's own
# session_id is recorded in events.jsonl as bookkeeping; no caller ever needs it.
#
# Usage: spawn.sh <name> <prompt-file> [effort] [cwd] [permissions]
#   name         [A-Za-z0-9_-]+ display alias; the minted id is <name>-<hex>, never reused
#   prompt-file  the worker's full prompt (a FILE: bracketed paste enters it as one block)
#   effort       low|medium|high|max|default   (default: leave the session's setting)
#   cwd          worker working directory       (default: current directory)
#   permissions  bypass|plan|accept-edits|inherit   (default: bypass — a detached pane
#                cannot answer permission prompts; have workers self-gate irreversible
#                actions via AskUserQuestion instead)
#
# Requires the summon hooks merged into the settings governing <cwd> (see SKILL.md).
# Linux + macOS. Fails loud; on failure the pane tail is printed as debug payload.
set -uo pipefail

name="${1:?usage: spawn.sh <name> <prompt-file> [effort] [cwd] [permissions]}"
prompt="${2:?prompt file required}"
effort="${3:-default}"
cwd="${4:-$PWD}"
perm="${5:-bypass}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

case "$name" in
  ''|*[!A-Za-z0-9_-]*) die "name must be [A-Za-z0-9_-]+ (tmux-safe), got: '$name'" ;;
esac
[ -f "$prompt" ] || die "prompt file not found: $prompt"
[ -d "$cwd" ] || die "cwd not found: $cwd"
command -v tmux >/dev/null || die "tmux not installed"
command -v jq >/dev/null || die "jq not installed"
command -v claude >/dev/null || die "claude CLI not on PATH"

case "$effort" in
  low|medium|high|max|default) ;;
  *) die "effort must be low|medium|high|max|default, got: '$effort'" ;;
esac

case "$perm" in
  bypass)       permflag='--dangerously-skip-permissions' ;;
  plan)         permflag='--permission-mode plan' ;;
  accept-edits) permflag='--permission-mode acceptEdits' ;;
  inherit)      permflag='' ;;
  *) die "permissions must be bypass|plan|accept-edits|inherit, got: '$perm'" ;;
esac

state="${SUMMON_STATE:-$HOME/.local/state/summon}"
id="$name-$(printf '%x%x' "$(date +%s)" "$$")"
d="$state/workers/$id"

[ -e "$d" ] && die "worker dir already exists (should be impossible): $d"
tmux has-session -t "$id" 2>/dev/null && die "tmux session '$id' already exists"
mkdir -p "$d" || die "cannot create state dir: $d"
printf '0\n' > "$d/cursor"
jq -n --arg id "$id" --arg name "$name" --arg cwd "$cwd" --arg prompt "$prompt" \
      --arg effort "$effort" --arg perm "$perm" --arg t "$(date +%s)" \
      '{id:$id,name:$name,tmux:$id,cwd:$cwd,prompt_file:$prompt,effort:$effort,
        permissions:$perm,created:($t|tonumber)}' > "$d/meta.json"

pane_tail() { printf -- '--- pane tail (debug) ---\n'; tmux capture-pane -t "$id" -p 2>/dev/null | tail -14; }

# Launch. The env prefix on the command line is what attributes every hook event to this
# worker — SUMMON_ID keys the state dir, SUMMON_STATE pins it to the same root spawn uses.
tmux new-session -d -s "$id" -x 220 -y 50 -c "$cwd" || die "tmux new-session failed"
tmux send-keys -t "$id" "SUMMON_ID=$id SUMMON_STATE='$state' claude $permflag" Enter

# Boot: our SessionStart hook line IS the boot signal — no fixed sleeps, no pane parsing.
booted=""
i=0
while [ $i -lt 45 ]; do
  if grep -q '"event":"SessionStart"' "$d/events.jsonl" 2>/dev/null; then booted=1; break; fi
  tmux has-session -t "$id" 2>/dev/null || { pane_tail; die "tmux session died during boot"; }
  sleep 1; i=$((i+1))
done
if [ -z "$booted" ]; then
  pane_tail
  tmux kill-session -t "$id" 2>/dev/null
  rm -rf "$d"
  die "no SessionStart within 45s. Likely causes: summon hooks not merged into the settings governing $cwd (see SKILL.md · Install); or a first-run dialog is blocking (folder trust, or --dangerously-skip-permissions acceptance) — run 'claude $permflag' once in $cwd interactively, accept, then respawn."
fi
sleep 1  # let the input box settle after boot

# Effort (skip on 'default'). /effort is a TUI command — no hook proof exists; the boot
# signal above guarantees a live input box, which removes the lost-keystroke hazard.
if [ "$effort" != "default" ]; then
  tmux send-keys -t "$id" "/effort $effort" Enter
  sleep 2
fi

# Paste the prompt as ONE bracketed block, submit, and verify against the
# UserPromptSubmit hook line — resending Enter for a lagged paste is OUR job, not the
# orchestrating agent's.
tmux load-buffer -b "summon-$id" "$prompt" || { pane_tail; die "tmux load-buffer failed"; }
tmux paste-buffer -t "$id" -b "summon-$id" -p -d
sleep 1
tmux send-keys -t "$id" Enter
submitted=""
round=0
while [ $round -lt 4 ]; do
  i=0
  while [ $i -lt 6 ]; do
    if grep -q '"event":"UserPromptSubmit"' "$d/events.jsonl" 2>/dev/null; then submitted=1; break 2; fi
    sleep 1; i=$((i+1))
  done
  round=$((round+1))
  tmux send-keys -t "$id" Enter   # paste lag: the final Enter didn't take — resend
done
if [ -z "$submitted" ]; then
  pane_tail
  die "prompt did not submit after $round retries — inspect: tmux attach -t $id (worker left alive; state: $d)"
fi

printf 'SUMMONED id=%s state=%s\n' "$id" "$d"
