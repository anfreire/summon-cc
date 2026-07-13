#!/usr/bin/env bash
# summon-cc spawn — mint a worker id, launch an INTERACTIVE Claude Code session in a
# detached tmux pane, and drive the startup ritual entirely against summon's own hook
# signals: boot (SessionStart event) → paste the prompt as ONE bracketed block →
# verified submit (UserPromptSubmit event, resending Enter itself if the paste lags).
# A real PTY is required: a worker must be able to raise AskUserQuestion and take
# mid-run pokes — neither exists under `claude -p`.
#
# The six hooks are injected per worker via `--settings` on the launch line, their
# paths single-quoted (any install path without a single quote just works). Nothing
# is ever merged into the user's or the project's Claude settings; sessions not
# launched by summon never load these hooks at all. (Machines where an older summon
# install merged them are safe too: those copies double-fire at worst, and every
# signal read tolerates duplicates — tail -1, grep -q, overwrite-then-archive.)
#
# Effort and permission values are passed to claude VERBATIM — claude is the
# validator, so values that ship tomorrow work tomorrow. A bad permission mode aborts
# boot with claude's own usage error (spawn prints the pane tail and fails fast); a
# bad effort does NOT abort: claude silently runs at its default, and nothing reports
# the effective effort back (no pane warning, and current CLIs omit effort from hook
# payloads — verified 2.1.207). Treat effort as fire-and-forget tuning; the Stop hook
# passes it through into events.jsonl if a future CLI adds it to the payload.
#
# Prints exactly one line on success:   SUMMONED id=<id> state=<worker-dir>
# The id is the public handle for everything (wait, send-keys, kill); the state dir
# is the evidence. Claude's own session_id is recorded in events.jsonl as
# bookkeeping; no caller ever needs it.
#
# Usage: spawn.sh <name> <prompt-file> [effort] [cwd] [permissions]
#   name         [A-Za-z0-9_-]+ display alias, and must not embed an id-shaped run
#                (dash + 16 hex — i.e. never pass a worker's ID as a new NAME); the
#                minted id is <name>-<hex> (the hex is fixed-width; ids are never reused)
#   prompt-file  the worker's full prompt (a FILE: bracketed paste enters it as one
#                block); must not BEGIN with '/', '!' or '#' — the TUI reads those as
#                input prefixes (slash command / bash-mode / memory), not prompt text
#   effort       'default' leaves the session's own setting; anything else goes to
#                `claude --effort` verbatim (claude --help lists the vocabulary)
#   cwd          worker working directory (default: current directory)
#   permissions  'bypass' → --dangerously-skip-permissions (default — a detached pane
#                cannot answer permission prompts; have workers self-gate irreversible
#                actions via AskUserQuestion instead) · 'inherit' → no flag · anything
#                else goes to --permission-mode verbatim (claude --help lists the modes)
#
# SUMMON_CLAUDE_ARGS   optional extra flags appended verbatim to the claude launch
#                      line — e.g. '--model haiku' or '--resume <session_id>'.
#                      Simple space-separated flag words only (it rides a shell line).
#
# Needs a claude CLI with --settings and --effort. Linux + macOS. Fails loud; on
# failure the pane tail is printed as the debug payload.
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
# An id-shaped run in the NAME (dash + 16 hex — e.g. a previous worker's id pasted as
# the name) would mint an id that NESTS that worker's; once the shorter session dies,
# tmux -t prefix matching can aim keys or kills at this one (verified). Summon's own
# id format — under this repo's control, so this gate can't go stale.
if printf '%s\n' "$name" | grep -Eq -- '-[0-9a-f]{16}'; then
  die "name must not embed an id-shaped run (dash + 16 hex): ids would nest and tmux prefix matching could cross-wire them — pass a short fresh name, not a worker id (ids are minted, never reused), got: '$name'"
fi
[ -f "$prompt" ] || die "prompt file not found: $prompt"
[ -s "$prompt" ] || die "prompt file is empty: $prompt (a worker can't submit an empty prompt)"
# Not a vocabulary gate — input framing: the TUI treats a leading '/', '!' or '#' as
# a mode prefix ('/' runs a slash command, '!' EXECUTES the rest as a shell command,
# '#' opens the memory picker), so the paste would never submit as a prompt (verified,
# typed and bracketed-paste alike). Fail here, loudly, instead of ~30s later.
case "$(head -c 1 "$prompt")" in
  [/!#]) die "prompt file must not begin with '/', '!' or '#' (TUI input prefixes — the text would run as a command instead of submitting as a prompt): $prompt" ;;
esac
[ -d "$cwd" ] || die "cwd not found: $cwd"
command -v tmux >/dev/null || die "tmux not installed"
command -v jq >/dev/null || die "jq not installed"
command -v claude >/dev/null || die "claude CLI not on PATH"

# Shell-safety only — NOT a vocabulary gate: both values ride the launch line, so
# they must be plain flag-value words. Whether they MEAN anything is claude's call.
case "$effort" in
  *[!A-Za-z0-9_-]*) die "effort must be a plain word (it is passed to claude verbatim), got: '$effort'" ;;
esac
case "$perm" in
  *[!A-Za-z0-9_-]*) die "permissions must be a plain word (it is passed to claude verbatim), got: '$perm'" ;;
esac
case "$perm" in
  bypass)  permflag='--dangerously-skip-permissions' ;;
  inherit) permflag='' ;;
  *)       permflag="--permission-mode $perm" ;;
esac

# The hooks ship next to this script (scripts/ and hooks/ are siblings). Their
# absolute paths go into the worker's settings file single-quoted — hook commands run
# through a shell, so quoting makes any path without a single quote in it just work
# (spaces, '&', unicode, …). A legacy merged install's unquoted copies won't dedupe
# against these; harmless — they double-fire at worst and every signal read tolerates
# duplicates.
hooks_dir="$(cd "$(dirname "$0")/../hooks" 2>/dev/null && pwd)" \
  || die "cannot resolve hooks/ next to this script (scripts/ and hooks/ ship together)"
[ -f "$hooks_dir/on_stop.sh" ] || die "hooks missing from: $hooks_dir"
case "$hooks_dir" in
  *"'"*) die "the skill path must not contain a single quote (hook commands single-quote it), got: $hooks_dir" ;;
esac

state="${SUMMON_STATE:-$HOME/.local/state/summon}"
case "$state" in
  *"'"*) die "state root must not contain single quotes, got: $state" ;;
esac
# Fixed-width hex (epoch + zero-padded pid): equal-length ids can never be a strict
# prefix of one another, so tmux's prefix-matching -t can never cross-wire two workers.
id="$name-$(printf '%x%08x' "$(date +%s)" "$$")"
d="$state/workers/$id"

[ -e "$d" ] && die "worker dir already exists (should be impossible): $d"
# '=' forces exact-match everywhere a session is targeted; without it tmux falls back
# to prefix matching and could hit a similarly named session.
tmux has-session -t "=$id" 2>/dev/null && die "tmux session '$id' already exists"
mkdir -p "$d" || die "cannot create state dir: $d"
printf '0\n' > "$d/cursor"

# The worker's own settings file: the six hooks by absolute path, injected with
# --settings at launch. No settings file of the user's is ever touched.
jq -n --arg h "$hooks_dir" --arg q "'" '
  def ev(f): [{hooks: [{type: "command", command: ("bash " + $q + $h + "/" + f + $q), timeout: 10}]}];
  {hooks: {
    SessionStart:     ev("on_session_start.sh"),
    UserPromptSubmit: ev("on_prompt_submit.sh"),
    Stop:             ev("on_stop.sh"),
    PostToolUse:      ev("on_post_tool.sh"),
    PreToolUse:       [{matcher: "AskUserQuestion",
                        hooks: [{type: "command", command: ("bash " + $q + $h + "/on_ask_question.sh" + $q), timeout: 10}]}],
    SessionEnd:       ev("on_session_end.sh")
  }}' > "$d/settings.json" || die "cannot write $d/settings.json"

jq -n --arg id "$id" --arg name "$name" --arg cwd "$cwd" --arg prompt "$prompt" \
      --arg effort "$effort" --arg perm "$perm" --arg extra "${SUMMON_CLAUDE_ARGS:-}" \
      --arg t "$(date +%s)" \
      '{id:$id,name:$name,tmux:$id,cwd:$cwd,prompt_file:$prompt,effort:$effort,
        permissions:$perm,claude_args:$extra,created:($t|tonumber)}' > "$d/meta.json" \
  || die "cannot write $d/meta.json"

# Pane-target commands need '=name:' (exact session, its current window); bare
# '=name' is only valid for session-target commands like has/kill-session.
pane_tail() { printf -- '--- pane tail (debug) ---\n'; tmux capture-pane -t "=$id:" -p 2>/dev/null | tail -14; }

# Launch. `env` (not VAR=x prefix syntax) so any login shell — bash, zsh, fish, csh —
# accepts the line; SUMMON_ID keys every hook write to this worker's dir,
# SUMMON_STATE pins it to the same root spawn uses. The trailing `; touch` is the
# exit sentinel: the pane's shell drops the file the moment claude exits, for any
# reason — a file signal (no sampling race, no pane parsing) that turns fail-fast
# startup deaths into loud, instant errors. `;` sequencing is valid in all four shells.
tmux new-session -d -s "$id" -x 220 -y 50 -c "$cwd" || { rm -rf "$d"; die "tmux new-session failed"; }
launch="env SUMMON_ID=$id SUMMON_STATE='$state' claude --settings '$d/settings.json'"
[ "$effort" != "default" ] && launch="$launch --effort $effort"
[ -n "$permflag" ] && launch="$launch $permflag"
[ -n "${SUMMON_CLAUDE_ARGS:-}" ] && launch="$launch $SUMMON_CLAUDE_ARGS"
launch="$launch; touch '$d/claude_exited'"
tmux send-keys -t "=$id:" "$launch" Enter

# Boot: our SessionStart hook line IS the boot signal — no fixed sleeps, no pane
# parsing. The exit sentinel fails the slow path fast: claude's own usage error for a
# bad flag, claude missing from the pane shell's PATH, a CLI too old for --settings —
# all die in ~a second instead of burning the whole 45s window.
booted=""
i=0
while [ $i -lt 45 ]; do
  if grep -q '"event":"SessionStart"' "$d/events.jsonl" 2>/dev/null; then booted=1; break; fi
  if [ -e "$d/claude_exited" ]; then
    pane_tail
    tmux kill-session -t "=$id" 2>/dev/null
    rm -rf "$d"
    die "claude exited during boot (no SessionStart) — the pane tail above shows its parting words. Usual causes: claude's own usage error for a bad flag value, claude not on the pane shell's PATH, or a claude too old for --settings/--effort (check: claude --help)."
  fi
  tmux has-session -t "=$id" 2>/dev/null || { pane_tail; die "tmux session died during boot"; }
  sleep 1; i=$((i+1))
done
if [ -z "$booted" ]; then
  pane_tail
  tmux kill-session -t "=$id" 2>/dev/null
  rm -rf "$d"
  die "no SessionStart within 45s and claude still looks alive — almost always a first-run consent dialog (folder trust, or accepting --dangerously-skip-permissions); the pane tail above shows it. Remedy: run claude once in $cwd interactively with the same flags spawn used, accept, then respawn. These are consent gates — do not script past them. (If the tail shows claude exited instead, it died too fast to catch: its error is right there.)"
fi
sleep 1  # let the input box settle after boot

# Paste the prompt as ONE bracketed block, submit, and verify against the
# UserPromptSubmit hook line — resending Enter for a lagged paste is OUR job, not the
# orchestrating agent's.
tmux load-buffer -b "summon-$id" "$prompt" || { pane_tail; die "tmux load-buffer failed"; }
tmux paste-buffer -t "=$id:" -b "summon-$id" -p -d
sleep 1
tmux send-keys -t "=$id:" Enter
submitted=""
round=0
while [ $round -lt 4 ]; do
  i=0
  while [ $i -lt 6 ]; do
    if grep -q '"event":"UserPromptSubmit"' "$d/events.jsonl" 2>/dev/null; then submitted=1; break 2; fi
    if [ -e "$d/claude_exited" ]; then
      pane_tail
      die "claude exited before the prompt submitted — the pane tail above shows its parting words (session and state kept for post-mortem: $d)"
    fi
    sleep 1; i=$((i+1))
  done
  round=$((round+1))
  # Paste lag: the final Enter didn't take — resend, except after the last poll: an
  # Enter nothing observes could submit invisibly, and a false "did not submit" on a
  # worker that IS running would invite a duplicate spawn.
  [ $round -lt 4 ] && tmux send-keys -t "=$id:" Enter
done
if [ -z "$submitted" ]; then
  pane_tail
  die "prompt did not submit after $((round-1)) Enter retries — inspect: tmux attach -t '=$id' (worker left alive; state: $d)"
fi

printf 'SUMMONED id=%s state=%s\n' "$id" "$d"
