#!/usr/bin/env bash
# ctl-relaunch.sh <account> [why...] (was aide-relaunch.sh, shim kept; hermes-handover item 2.1): stop the running ctl-seat claude (WM_SEAT=ctl or aide), relaunch it in tmux session `aide` under <account>,
# resuming the same session id (~/.config/aide/session-id) with the resume prompt (~/.config/aide/resume-prompt.tmpl).
# Joe 11-01 1:1x AM "can this aide session switch back to mcphost.dev at 2:10am?" + 1:2x AM "how will you guarantee this?":
# the kill comes FIRST so the old account stops spending even if the relaunch fails; the token is read by ctl-launch.sh
# from the store and never printed. Done-check: ctl-relaunch-check.sh <account>.
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"
# A1577 W2: a planned invocation whose launch ends before any kill is voided, so its bind line no longer blocks the next bind for the ask (H2: installed before any early exit, so the model-policy and hold-gate refusals void it too; an unvalidated, multi-token or already-launched id is never written)
_KILLED=0; _NOVOID=0; LAUNCHED="$HOME/.local/state/aide/succ-launched"; _void(){ case "${WM_SUCC_INV:-}" in ""|*[!A-Za-z0-9._-]*) return;; esac; grep -qxF -- "$WM_SUCC_INV" "$LAUNCHED" 2>/dev/null && return; [ -n "${WM_SUCC_INV:-}" ] && [ "${_KILLED:-0}" = 0 ] && [ "${_NOVOID:-0}" = 0 ] && { mkdir -p "$HOME/.local/state/aide"; printf '%s\n' "$WM_SUCC_INV" >> "$HOME/.local/state/aide/succ-void"; }; }; trap _void EXIT
ACCT="${1:?account}"; shift; WHY="${*:-relaunch}"
# Validate approved model/effort BEFORE stopping any existing seat.
for _pl in "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/ctl-model-policy.sh" "$HOME/.local/lib/ctl-model-policy.sh"; do [ -r "$_pl" ] && break; done
. "$_pl" || exit 64
ctl_model_policy || exit $?
EFFORT=medium
"$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/hold-gate.sh" ctl-relaunch || exit 1   # hold gate (hermes-handover 2.4): before anything is stopped or launched; aide-relaunch.sh (shim) inherits
SID="$(cat "$HOME/.config/aide/session-id")"
LOG="$HOME/.local/state/aide/relaunch.log"; mkdir -p "$(dirname "$LOG")"
TTY="$(cat "$HOME/.config/aide/joe-tty" 2>/dev/null || true)"
STORE="$HOME/.config/fleet-token/store/$ACCT"
CTL_DIR="$(dirname "$(readlink -f "$0")")"   # sibling ctl-launch.sh (same dir as this script, symlink-resolved)
log(){ echo "$(date +%Y-%m-%dT%H:%M:%S%z) $*" | tee -a "$LOG" >&2; }
note(){ log "$*"; [ -n "$TTY" ] && [ -w "$TTY" ] && printf '\n\033[1m[ctl-relaunch %s]\033[0m %s\n' "$(date +%I:%M%p)" "$*" > "$TTY" 2>/dev/null || true; }
# S2: the planned invocation id is one token of [A-Za-z0-9._-]; anything else refuses before anything is stopped (exit 78, nothing voided)
if [ -n "${WM_SUCC_INV:-}" ] && { case "$WM_SUCC_INV" in *[!A-Za-z0-9._-]*) true;; *) false;; esac; }; then _NOVOID=1; note "REFUSED WM_SUCC_INV is not a single [A-Za-z0-9._-] token; nothing stopped"; exit 78; fi
# an id whose launch already reached the kill step is spent: refuse before anything is stopped and never void it (exit 77)
if [ -n "${WM_SUCC_INV:-}" ] && grep -qxF -- "$WM_SUCC_INV" "$LAUNCHED" 2>/dev/null; then _NOVOID=1; note "REFUSED WM_SUCC_INV already launched (spent); nothing stopped, its bind stays live"; exit 77; fi
# A1577 v6: a binding without the planned invocation id (the id the producer bound in the canonical row) refuses before anything is stopped (exit 74)
if [ -n "${WM_SUCC_BINDING:-}" ] && [ -z "${WM_SUCC_INV:-}" ]; then note "REFUSED WM_SUCC_BINDING without WM_SUCC_INV (planned invocation); nothing stopped, nothing launched"; exit 74; fi
if [ -n "${WM_SUCC_BINDING:-}" ] && ! python3 -I -c 'import json,sys; b=json.load(open(sys.argv[1])); sys.exit(0 if b.get("invocation")==sys.argv[2] and b.get("ask") and b.get("effect_sha") else 1)' "$WM_SUCC_BINDING" "$WM_SUCC_INV" 2>/dev/null; then note "REFUSED binding file unreadable or its invocation differs from WM_SUCC_INV; nothing stopped, nothing launched"; exit 76; fi   # pre-kill check (reviewer gap)
[ -r "$STORE" ] || { note "FAIL no store entry $ACCT; nothing stopped, nothing launched"; exit 64; }
# 1. stop the aide CHANNEL claude only: the pid in ~/.config/aide/channel-pid plus every claude under tmux session =aide
#    (exact name; the aide-chain session also carries WM_SEAT=aide and is never touched). WM_SEAT=ctl or aide matches (transition). Never this script's own tree.
desc(){ local p; for p in $(pgrep -P "$1" 2>/dev/null); do echo "$p"; desc "$p"; done; }
aide_pids(){ { [ -r "$HOME/.config/aide/channel-pid" ] && cat "$HOME/.config/aide/channel-pid";
  for pp in $(tmux list-panes -a -F '#{session_name} #{pane_pid}' 2>/dev/null | awk '$1=="aide"{print $2}'); do echo "$pp"; desc "$pp"; done; } | sort -u | while read -r p; do
  [ -n "$p" ] && [ "$p" != "$$" ] && grep -qa 'claude' "/proc/$p/cmdline" 2>/dev/null && tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qxE 'WM_SEAT=(ctl|aide)' && echo "$p"; done; }
pids="$(aide_pids | tr '\n' ' ')"
log "stopping aide claude pid(s): ${pids:-none} (account switch to $ACCT: $WHY)"
_KILLED=1; [ -n "${WM_SUCC_INV:-}" ] && { mkdir -p "$(dirname "$LAUNCHED")"; printf '%s\n' "$WM_SUCC_INV" >> "$LAUNCHED"; }; [ -n "$pids" ] && kill $pids 2>/dev/null
for _ in $(seq 1 20); do [ -z "$(aide_pids)" ] && break; sleep 1; done
left="$(aide_pids | tr '\n' ' ')"; [ -n "$left" ] && { log "SIGKILL leftover $left"; kill -9 $left 2>/dev/null; sleep 1; }
tmux list-sessions -F "#{session_name}" 2>/dev/null | grep -qx aide && tmux kill-session -t aide
# 2. relaunch, resuming the same session, under <account>
# Effort was validated as medium before any existing seat was stopped.
# A1577 successor binding (candidate, uninstalled): a unique invocation id rides into the child's environ; WM_SUCC_BINDING (optional) names the durable binding file
INV="${WM_SUCC_INV:-rl-$(date +%Y%m%d-%H%M%S)-$$}"; LAUNCH_EPOCH="$(date +%s.%N)"; SPENT="$HOME/.local/state/aide/succ-produced"; mkdir -p "$(dirname "$SPENT")"; grep -qxF -- "$INV" "$SPENT" 2>/dev/null || printf '%s\n' "$INV" >> "$SPENT"; SUCC="$HOME/.local/lib/a1577-succ.py"
P="$HOME/.local/state/aide/resume-prompt-$(date +%Y%m%d-%H%M%S).txt"
sed -e "s|@ACCT@|$ACCT|g" -e "s|@TIME@|$(date +'%I:%M %p %Z')|g" -e "s|@WHY@|$WHY|g" "$HOME/.config/aide/resume-prompt.tmpl" > "$P"
printf '\na1577-inv=%s\n' "$INV" >> "$P"   # v6: the transcript user record carrying this marker is the successor evidence (live claude holds no transcript fd)
tmux new-session -d -s aide -e "WM_RELAUNCH_INVOCATION=$INV" -x 200 -y 50 -c "$HOME" \
  "exec $CTL_DIR/ctl-launch.sh --account $ACCT --effort $EFFORT --resume $SID \"\$(cat $P)\"" \
  || { note "FAIL tmux new-session for aide under $ACCT (old aide stopped; $ACCT not running)"; exit 70; }
sleep 8
: > "$HOME/.config/aide/channel-pid"
newp="$(aide_pids | tr '\n' ' ')"; [ -n "$newp" ] && echo "$newp" | tr " " "\n" | head -1 > "$HOME/.config/aide/channel-pid"
if [ -n "$newp" ]; then note "aide relaunched under $ACCT, pid(s) $newp, tmux session 'aide' (attach: tmux attach -t aide). Old pid(s): ${pids:-none}."
else note "FAIL aide not running 8 s after relaunch under $ACCT (tmux session 'aide'); old pid(s) ${pids:-none} stopped. See: tmux attach -t aide"; exit 71; fi
# 3. successor evidence: the child (parent = the tmux server) must hold --resume $SID, show the a1577-inv marker in its SID transcript user record, carry this invocation id, and match the canonical ledger binding
if [ -n "${WM_SUCC_BINDING:-}" ]; then
  tsrv="$(tmux display-message -p '#{pid}' 2>/dev/null)"; okc=""; res=""
  for c in $(aide_pids); do res="$(python3 -I "$SUCC" "$SID" "$tsrv" "$c" "$WM_SUCC_BINDING" "$HOME/.local/state/aide/succ-consumed" "$LAUNCH_EPOCH" 2>&1)" && { okc="$c"; break; }; done
  if [ -n "$okc" ]; then log "SUCCESSOR-BOUND child pid $okc: $res"; else note "SUCCESSOR-UNBOUND: no child met the A1577 binding (relaunched, equivalence NOT claimed): ${res:-no child}"; exit 75; fi
else
  log "SUCCESSOR-UNVERIFIED: no WM_SUCC_BINDING; relaunch proceeds, equivalence not claimed"
fi
seat-event.sh aide "ctl-relaunch.sh: aide relaunched under $ACCT at $(date +%I:%M%p) in tmux 'aide', resumed $SID; stopped ${pids:-none}; why: $WHY" >/dev/null 2>&1 || true
