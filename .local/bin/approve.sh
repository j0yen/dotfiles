#!/usr/bin/env bash
# approve.sh — append one Joe approval to ~/.claude/state/approvals.log. Written ONLY by the aide session.
#   approve.sh "<verbatim Joe quote>" "<re: what it approves>"
#   approve.sh --last N        print the last N approval lines (non-comment) prefixed age=<N>m
#   approve.sh --selftest
#   approve.sh "<quote>" "<re>" --trial-id <id> --trial-ends <iso> --signal '<read>' --revert '<cmd>'   approval + an open trial row (all four flags or none)
#   approve.sh --trial-add --trial-id <id> --approval '#<n>' --started <iso> --trial-ends <iso> --signal '<read>' --revert '<cmd>' --state <open|kept|reverted|pending> [--start-gate '<text>']
#   approve.sh --trial-close <id> <kept|reverted>       approve.sh --trial-open <id> --trial-ends <iso>  (pending -> open)       approve.sh --trials
# Trials: ${APPROVE_TRIALS:-~/.claude/state/trials.json}, JSON array of {id, approval, started, ends, signal, revert, state, start_gate?, closed?}; atomic write under flock;
#   a malformed file is refused (exit 4) and never overwritten. Trial flags keep the tmux refusal (exit 3); bad input exits 2.
# Line format: #<id> | <YYYY-MM-DD h:MM AM/PM TZ> | <session> | Joe: "<verbatim>" | re: <what>
#   id = highest existing id + 1 (1 if none), strictly increasing, no dedupe (identical text appends a new id).
# Guard: refuses (exit 3) inside tmux session rb, r7 or ctl. Append-only: never edits existing lines. File mode 600.
# After a successful append it rings the controller: EVENT_SOURCE=approve seat-event.sh ctl "APPROVAL #<id> <re truncated 120>" (skipped if the bin is not executable;
#   a failure never fails the approval). Test overrides: APPROVALS_FILE, SEAT_EVENT_BIN (fake bell), SEAT_EVENT_DRY=1 / EVENTS_DIR (passed through to seat-event.sh).
set -uo pipefail
LOG="${APPROVALS_FILE:-$HOME/.claude/state/approvals.log}"
HEADER='# Joe approvals. Written ONLY by the aide session (approve.sh), append-only. One line per word: #<id> | <YYYY-MM-DD h:MM AM/PM TZ> | <aide session> | Joe: "<verbatim>" | re: <what it approves>'
DATA_RE='^#[0-9]+ \| '
TRIALS="${APPROVE_TRIALS:-$HOME/.claude/state/trials.json}"

age_lines() { # stdin = log lines; prints "age=<N>m <line>" for data lines
  local line ts e now; now=$(date +%s)
  while IFS= read -r line; do
    [[ "$line" =~ $DATA_RE ]] || continue
    ts="${line#* | }"; ts="${ts%% | *}"
    if e=$(date -d "$ts" +%s 2>/dev/null); then printf 'age=%sm %s\n' "$(( (now - e) / 60 ))" "$line"
    else printf 'age=?m %s\n' "$line"; fi
  done
}

tmux_session() {
  if [ -n "${TMUX_PANE:-}" ]; then tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null
  else tmux display-message -p '#S' 2>/dev/null; fi
}

if [ "${1:-}" = "--last" ]; then
  n="${2:-}"; case "$n" in ''|*[!0-9]*) echo "usage: approve.sh --last N" >&2; exit 2 ;; esac
  [ -r "$LOG" ] || { echo "none"; exit 0; }
  grep -E "$DATA_RE" "$LOG" | tail -n "$n" | age_lines
  exit 0
fi

selftest() {
  local d fail=0 out rc f line id1 id2 id3 ids; d=$(mktemp -d "$HOME/.cache/tmp/approve-selftest.XXXXXX") || { echo "FAIL setup"; return 1; }
  f="$d/approvals.log"; mkdir -p "$d/bin"
  ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
  export APPROVALS_FILE="$f"; unset TMUX TMUX_PANE
  printf '#!/bin/bash\necho "src=${EVENT_SOURCE:-} $*" >>"%s/bell"\n' "$d" >"$d/fake-bell"; chmod +x "$d/fake-bell"
  export SEAT_EVENT_BIN="$d/fake-bell" SEAT_EVENT_DRY=1 EVENTS_DIR="$d/ev"   # never a real tick, never the real events log
  out=$("$0" 'go ahead with the aide split' 're: test approval' 2>&1); rc=$?
  [ $rc -eq 0 ] && ok "append exit 0" || bad "append exit $rc: $out"
  [ "$(stat -c %a "$f")" = 600 ] && ok "mode 600 on create" || bad "mode $(stat -c %a "$f")"
  head -n1 "$f" | grep -q '^# Joe approvals' && ok "header comment present" || bad "header missing"
  line=$(grep -E "$DATA_RE" "$f" | tail -n1)
  re='^#1 \| [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{1,2}:[0-9]{2} [AP]M [A-Z]{2,5} \| aide \| Joe: "go ahead with the aide split" \| re: test approval$'
  [[ "$line" =~ $re ]] && ok "line format regex (id #1): $line" || bad "format: $line"
  cp "$f" "$d/snap1"
  chmod 644 "$f"; "$0" 'go ahead with the aide split' 're: test approval' >/dev/null 2>&1   # IDENTICAL text: must append, not dedupe
  [ "$(stat -c %a "$f")" = 600 ] && ok "mode restored to 600 on append" || bad "mode not restored"
  [ "$(grep -cE "$DATA_RE" "$f")" = 2 ] && ok "identical text appended a new line (no dedupe)" || bad "dedupe or lost line"
  CLAUDE_SESSION_NAME=jsy-zz "$0" "third" "re: y" >/dev/null 2>&1
  grep -q '^#3 | .* | jsy-zz | Joe: "third"' "$f" && ok "CLAUDE_SESSION_NAME used, id #3" || bad "session name / id 3"
  ids=$(grep -oE '^#[0-9]+' "$f" | tr -d '#' | tr '\n' ' ')
  [ "$ids" = "1 2 3 " ] && ok "ids strictly increase: $ids" || bad "ids: $ids"
  cmp -s <(head -c "$(stat -c %s "$d/snap1")" "$f") "$d/snap1" && ok "existing bytes untouched (append-only)" || bad "existing bytes changed"
  out=$("$0" "" "re: x" 2>&1); rc=$?; [ $rc -ne 0 ] && ok "empty quote refused (exit $rc)" || bad "empty quote accepted"
  out=$("$0" "q" "" 2>&1); rc=$?; [ $rc -ne 0 ] && ok "empty re refused (exit $rc)" || bad "empty re accepted"
  [ "$(grep -cE "$DATA_RE" "$f")" = 3 ] && ok "refusals wrote nothing" || bad "refusal wrote a line"
  for name in ctl rb r7 other; do
    printf '#!/bin/sh\n[ "$1" = display-message ] && echo %s\n' "$name" > "$d/bin/tmux"; chmod +x "$d/bin/tmux"
    out=$(PATH="$d/bin:$PATH" TMUX=fake "$0" "from $name" "re: z" 2>&1); rc=$?
    if [ "$name" = other ]; then [ $rc -eq 0 ] && ok "tmux session '$name' allowed" || bad "tmux other refused: $out"
    else [ $rc -eq 3 ] && ok "tmux session '$name' refused (exit 3)" || bad "tmux $name exit $rc"; fi
  done
  grep -q 'from ctl' "$f" && bad "ctl line leaked" || ok "no ctl line written"
  out=$("$0" --last 2); echo "$out" | head -n2 | grep -Eq '^age=[0-9]+m #[0-9]+ \| [0-9]{4}-' && [ "$(echo "$out" | wc -l)" = 2 ] && ok "--last 2: $(echo "$out" | head -n1 | cut -c1-50)" || bad "--last: $out"
  [ "$(sed -n 1p "$d/bell")" = 'src=approve ctl APPROVAL #1 test approval' ] && ok "bell after append: '$(sed -n 1p "$d/bell")'" || bad "bell line 1: $(sed -n 1p "$d/bell")"
  [ "$(wc -l <"$d/bell")" = "$(grep -cE "$DATA_RE" "$f")" ] && ok "one bell per appended line, none for refusals ($(wc -l <"$d/bell"))" || bad "bell count $(wc -l <"$d/bell") vs lines $(grep -cE "$DATA_RE" "$f")"
  "$0" 'long' "re: $(printf 'x%.0s' $(seq 1 200))" >/dev/null 2>&1
  [ "$(tail -n1 "$d/bell" | sed -E 's/^src=approve ctl APPROVAL #[0-9]+ //' | tr -d '\n' | wc -c)" = 120 ] && ok "re text truncated to 120 chars in the bell" || bad "truncation: $(tail -n1 "$d/bell" | wc -c)"
  SEAT_EVENT_BIN="$d/nonexistent" "$0" 'no bin' 're: no bell bin' >/dev/null 2>&1; rc=$?
  [ $rc -eq 0 ] && grep -q 'no bin' "$f" && ok "missing bell bin: approval still appended, exit 0" || bad "missing bin: rc $rc"
  printf '#!/bin/bash\nexit 9\n' >"$d/bad-bell"; chmod +x "$d/bad-bell"
  SEAT_EVENT_BIN="$d/bad-bell" "$0" 'bad bin' 're: bell fails' >/dev/null 2>&1; rc=$?
  [ $rc -eq 0 ] && grep -q 'bad bin' "$f" && ok "failing bell: approval still appended, exit 0" || bad "failing bin: rc $rc"
  rm -rf "$d"; return $fail
}
[ "${1:-}" = "--selftest" ] && { selftest; rc=$?; [ $rc -eq 0 ] && echo "SELFTEST PASS" || echo "SELFTEST FAIL"; exit $rc; }

TRIAL_PY=$(cat <<'PYEOF'
import sys, json, os, re, tempfile
from datetime import datetime
op, path = sys.argv[1], sys.argv[2]
kv = dict(zip(sys.argv[3::2], sys.argv[4::2]))
STATES = ("open", "kept", "reverted", "pending")
def die(code, msg):
    sys.stderr.write("approve.sh: " + msg + "\n"); sys.exit(code)
def iso(s):
    try: d = datetime.fromisoformat(s)
    except (ValueError, TypeError): return False
    return d.tzinfo is not None
def now(): return datetime.now().astimezone().isoformat(timespec="seconds")
rows = []
if os.path.exists(path):
    try:
        with open(path) as f: rows = json.load(f)
    except (ValueError, OSError):
        die(4, "malformed trials file %s (left untouched)" % path)
    if not isinstance(rows, list) or not all(isinstance(r, dict) and isinstance(r.get("id"), str) for r in rows):
        die(4, "malformed trials file %s (not an array of rows with an id; left untouched)" % path)
def find(i):
    for r in rows:
        if r["id"] == i: return r
    return None
def save():
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".trials.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(json.dumps(rows, indent=2, ensure_ascii=False) + "\n"); f.flush(); os.fsync(f.fileno())
        os.chmod(tmp, 0o600); os.replace(tmp, path)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise
def need_new_id(i):
    if not i or not re.fullmatch(r"[A-Za-z0-9._-]+", i): die(2, "bad trial id %r" % i)
    if find(i) is not None: die(2, "duplicate trial id %s" % i)
if op == "list":
    for r in rows: print(json.dumps(r, ensure_ascii=False))
elif op == "precheck":
    need_new_id(kv.get("id", ""))
    if not iso(kv.get("ends", "")): die(2, "--trial-ends must be ISO-8601 with an offset")
elif op == "add":
    i = kv.get("id", ""); need_new_id(i)
    st = kv.get("state", "")
    if st not in STATES: die(2, "state must be one of open|kept|reverted|pending")
    if not re.fullmatch(r"#[0-9]+", kv.get("approval", "")): die(2, "approval must look like #<n>")
    for k in ("signal", "revert"):
        if not kv.get(k, "").strip(): die(2, "%s is required" % k)
    for k, flag in (("started", "--started"), ("ends", "--trial-ends")):
        v = kv.get(k)
        if v is None: die(2, "%s is required" % flag)
        if v == "" and st != "pending": die(2, "%s may be empty only for state pending" % flag)
        if v != "" and not iso(v): die(2, "%s must be ISO-8601 with an offset" % flag)
    row = {"id": i, "approval": kv["approval"], "started": kv["started"], "ends": kv["ends"],
           "signal": kv["signal"], "revert": kv["revert"], "state": st}
    if kv.get("start_gate"): row["start_gate"] = kv["start_gate"]
    if st in ("kept", "reverted") and kv.get("closed"): row["closed"] = kv["closed"]
    rows.append(row); save(); print("approve.sh: trial added: %s (%s)" % (i, st))
elif op == "close":
    r = find(kv.get("id", ""))
    if r is None: die(2, "unknown trial id %s" % kv.get("id", ""))
    if kv.get("state") not in ("kept", "reverted"): die(2, "close state must be kept or reverted")
    r["state"] = kv["state"]; r["closed"] = now(); save(); print("approve.sh: trial closed: %s -> %s" % (r["id"], r["state"]))
elif op == "open":
    r = find(kv.get("id", ""))
    if r is None: die(2, "unknown trial id %s" % kv.get("id", ""))
    if r.get("state") != "pending": die(2, "trial %s is %s, only a pending trial can be opened" % (r["id"], r.get("state")))
    if not iso(kv.get("ends", "")): die(2, "--trial-ends must be ISO-8601 with an offset")
    r["started"] = now(); r["ends"] = kv["ends"]; r["state"] = "open"; save()
    print("approve.sh: trial opened: %s ends %s" % (r["id"], r["ends"]))
else:
    die(2, "internal: unknown op")
PYEOF
)
trial_py() { mkdir -p "$(dirname "$TRIALS")"; ( flock 8; python3 -I -c "$TRIAL_PY" "$1" "$TRIALS" "${@:2}" ) 8>>"$TRIALS.lock"; }
trial_refuse_seat() {
  if [ -n "${TMUX:-}" ]; then
    case "$(tmux_session)" in rb|r7|ctl) echo "approve.sh: refused: only the aide writes approvals (tmux seat $(tmux_session))" >&2; exit 3 ;; esac
  fi
}
declare -A T=()
trial_parse() { # trial_parse "<allowed keys, space separated>" args...: fills T[key]=value; unknown flag, repeat or missing value exits 2
  local allowed="$1" f k; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --trial-id) k=id ;; --trial-ends) k=ends ;; --signal) k=signal ;; --revert) k=revert ;; --approval) k=approval ;;
      --started) k=started ;; --state) k=state ;; --start-gate) k=start_gate ;;
      *) echo "approve.sh: unexpected argument: $1" >&2; exit 2 ;;
    esac
    f="$1"
    case " $allowed " in *" $k "*) ;; *) echo "approve.sh: $f not valid here" >&2; exit 2 ;; esac
    [ $# -ge 2 ] || { echo "approve.sh: $f needs a value" >&2; exit 2; }
    [ -z "${T[$k]+x}" ] || { echo "approve.sh: $f given twice" >&2; exit 2; }
    T[$k]="$2"; shift 2
  done
}
trial_mode() {
  local mode="$1" rc; shift
  trial_refuse_seat
  case "$mode" in
    --trials) [ $# -eq 0 ] || { echo "usage: approve.sh --trials" >&2; exit 2; }; trial_py list; exit $? ;;
    --trial-close)
      [ $# -eq 2 ] || { echo "usage: approve.sh --trial-close <id> <kept|reverted>" >&2; exit 2; }
      trial_py close id "$1" state "$2"; exit $? ;;
    --trial-open)
      [ $# -ge 1 ] || { echo "usage: approve.sh --trial-open <id> --trial-ends <iso>" >&2; exit 2; }
      T[id]="$1"; shift; trial_parse "ends" "$@"
      [ -n "${T[ends]+x}" ] || { echo "usage: approve.sh --trial-open <id> --trial-ends <iso>" >&2; exit 2; }
      trial_py open id "${T[id]}" ends "${T[ends]}"; exit $? ;;
    --trial-add)
      trial_parse "id approval started ends signal revert state start_gate" "$@"
      local k; for k in id approval started ends signal revert state; do
        [ -n "${T[$k]+x}" ] || { echo "usage: approve.sh --trial-add --trial-id <id> --approval '#<n>' --started <iso> --trial-ends <iso> --signal '<read>' --revert '<cmd>' --state <open|kept|reverted|pending> [--start-gate '<text>']" >&2; exit 2; }
      done
      trial_py add id "${T[id]}" approval "${T[approval]}" started "${T[started]}" ends "${T[ends]}" signal "${T[signal]}" revert "${T[revert]}" state "${T[state]}" start_gate "${T[start_gate]-}"
      exit $? ;;
  esac
}
case "${1:-}" in --trial-add|--trial-close|--trial-open|--trials) trial_mode "$@" ;; esac
# approval + trial: "<quote>" "<re>" then the four trial flags (all or none)
has_trial=0
for a in "$@"; do case "$a" in --trial-id|--trial-ends|--signal|--revert) has_trial=1 ;; esac; done

quote="${1:-}"; re="${2:-}"
quote=$(printf '%s' "$quote" | tr '\r\n' '  '); re=$(printf '%s' "$re" | tr '\r\n' '  ')
re="${re#re: }"
if [ -z "${quote//[[:space:]]/}" ] || [ -z "${re//[[:space:]]/}" ]; then
  echo 'usage: approve.sh "<verbatim Joe quote>" "<re: what it approves>" (both non-empty)' >&2; exit 2
fi
if [ "$has_trial" = 1 ]; then   # all four trial flags or none; any subset refuses before anything is written
  case "$1" in --trial-*|--signal|--revert) echo "approve.sh: the quote and re come before the trial flags" >&2; exit 2 ;; esac
  case "${2:-}" in --trial-*|--signal|--revert) echo "approve.sh: the quote and re come before the trial flags" >&2; exit 2 ;; esac
  trial_parse "id ends signal revert" "${@:3}"
  for k in id ends signal revert; do
    [ -n "${T[$k]:-}" ] || { echo "approve.sh: --trial-id, --trial-ends, --signal and --revert are required together (missing $k)" >&2; exit 2; }
  done
fi
if [ -n "${TMUX:-}" ]; then
  case "$(tmux_session)" in rb|r7|ctl) echo "approve.sh: refused: only the aide writes approvals (tmux seat $(tmux_session))" >&2; exit 3 ;; esac
fi
mkdir -p "$(dirname "$LOG")"
if [ "$has_trial" = 1 ]; then   # nothing is written unless the trial row will also be accepted (bad file 4, duplicate id or bad ends 2)
  trial_py precheck id "${T[id]}" ends "${T[ends]}" || exit $?
fi
if [ ! -e "$LOG" ]; then ( umask 077; printf '%s\n' "$HEADER" > "$LOG" ); fi
chmod 600 "$LOG"
# id allocation + append under one lock so concurrent writers never share an id
line=$( ( flock 9
  last=$(grep -oE '^#[0-9]+' "$LOG" | tr -d '#' | sort -n | tail -n1); id=$(( ${last:-0} + 1 ))
  l=$(printf '#%s | %s | %s | Joe: "%s" | re: %s' "$id" "$(date '+%F %-I:%M %p %Z')" "${CLAUDE_SESSION_NAME:-aide}" "$quote" "$re")
  printf '%s\n' "$l" >> "$LOG"; printf '%s' "$l" ) 9>>"$LOG" )
chmod 600 "$LOG"
echo "approve.sh: appended: $line"
trial_rc=0
if [ "$has_trial" = 1 ]; then   # the approval is already on the log; a trial failure is reported but still rings the bell
  new_id="${line#\#}"; new_id="${new_id%% *}"
  trial_py add id "${T[id]}" approval "#$new_id" started "$(date -Iseconds)" ends "${T[ends]}" signal "${T[signal]}" revert "${T[revert]}" state open || trial_rc=$?
fi
EV="${SEAT_EVENT_BIN:-$HOME/.local/bin/seat-event.sh}"
if [ -x "$EV" ]; then   # ring the controller; never fails the approval
  id="${line#\#}"; id="${id%% *}"
  EVENT_SOURCE=approve "$EV" ctl "APPROVAL #$id ${re:0:120}" >/dev/null 2>&1 || true
fi
exit "$trial_rc"
