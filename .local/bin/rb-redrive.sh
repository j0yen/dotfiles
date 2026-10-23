#!/bin/bash
# rb-redrive.sh <run> --from <stage> --why "<text>" [--force] | --selftest   (rb 10-23 6:0x AM, ctl 2:4x item 6, row-first redrive wrapper)
# The ONLY way the rb seat redrives a RedBaron run:
#   1. reads the § MG Σ on RB (last cargo-admission parts + MemAvailable) -> the Σ line;
#   2. records the wm-decide run-state row FIRST (no row id = no redrive);
#   3. `wm-build run redrive <run> --from <stage> --operator rb --note "<row id>: <why>"` on RB; quotes the daemon reply;
#   4. after 15 s reads journal.jsonl for this run's release-mem ops newer than the enqueue:
#        release-mem-dropped -> re-issue ONCE (same row id), read again; dropped twice -> alarm
#        release-mem decision=refuse -> alarm (rb-freeze-rearm.timer re-arms the hand-cargo freeze from the same line)
#        release-mem decision=admit / redrive-reclaim -> OK
#   exit 0 OK, 2 usage/refused flag, 3 row refused, 4 redrive call failed, 5 alarm (refused or dropped twice).
# --expect STATE overrides the wm-decide expectation (default land->released, gate->land, inner->gate). Never --ungated. --force at --from land: prints the wt target-symlink reminder (LAND --force deletes the SSD link).
set -uo pipefail
. "$HOME/.cache/rb-seat/rb-watch-lib.sh" 2>/dev/null || true
RB=${RB_HOST:-redbaron}; WAIT_S=${RB_REDRIVE_WAIT:-15}

rssh() { # CMD -> RB stdout (FIX_SSH_DIR/<n>.out fixtures in the selftest, consumed in order)
  if [ -n "${FIX_SSH_DIR:-}" ]; then local n; n=$(( $(cat "$FIX_SSH_DIR/.n" 2>/dev/null || echo 0) + 1 )); echo $n > "$FIX_SSH_DIR/.n"
    echo "$1" >> "$FIX_SSH_DIR/argv"; cat "$FIX_SSH_DIR/$n.out" 2>/dev/null; return "$(cat "$FIX_SSH_DIR/$n.rc" 2>/dev/null || echo 0)"; fi
  timeout 60 ssh -o BatchMode=yes "$RB" "export PATH=\$HOME/.cargo/bin:\$HOME/.local/bin:\$PATH; $1"
}
sigma() {
  rssh 'echo "MemAvailable_G=$(awk "/MemAvailable/{printf \"%.1f\", \$2/1048576}" /proc/meminfo)"; tail -c 2000000 $HOME/.local/state/wm-build/journal.jsonl | grep "\"op\":\"cargo-admission\"" | tail -1 | jq -r "\"parts=\" + (.row.parts|join(\",\")) + \" at \" + .ts"' | tr '\n' ' '
}
ops_since() { # RUN SINCE_EPOCH -> one line per op: "<op> <decision|reason>"
  rssh "tail -c 4000000 \$HOME/.local/state/wm-build/journal.jsonl | grep -E '\"op\":\"(release-mem[a-z-]*|redrive-reclaim)\"' | jq -r --argjson s $2 --arg r $1 'select((.row.run_id|tostring)==\$r or (.row.run|tostring)==\$r) | select((.ts|sub(\"\\\\.[0-9]+\";\"\")|sub(\"\\\\+00:00\$\";\"Z\")|fromdateiso8601) >= \$s) | .op + \" \" + ((.row.decision // .row.reason // \"-\")|tostring)'"
}
classify() { # OPS -> admit | refuse | dropped | none
  # 1039 11:31 AM 10-23: a refuse FOLLOWED by admit/granted (queued, then granted) is admit, not refuse; only a refuse with no later admit alarms
  awk '/^release-mem refuse/{r=1} /^(release-mem admit|release-mem-granted)/{r=0} END{exit !r}' <<<"$1" && { echo refuse; return; }
  grep -qE '^release-mem-dropped' <<<"$1" && ! grep -qE '^(release-mem admit|redrive-reclaim)' <<<"$1" && { echo dropped; return; }
  grep -qE '^(release-mem admit|redrive-reclaim|release-mem-queued)' <<<"$1" && { echo admit; return; }
  echo none
}
alarm() { local m="RB-BELL redrive-alarm run=$RUN: $1"; echo "$m"; [ -n "${FIX_SSH_DIR:-}" ] && return 0; declare -F rb_bell >/dev/null && rb_bell "$m" || timeout 30 "$HOME/.local/bin/seat-event.sh" rb "$m" || true; }

main() {
  RUN=""; FROM=""; WHY=""; FORCE=""; STOP=""; EXPECT=""
  while [ $# -gt 0 ]; do case "$1" in
    --from) FROM=${2:-}; shift 2;; --why) WHY=${2:-}; shift 2;; --force) FORCE=--force; shift;; --stop) STOP=--stop; shift;; --expect) EXPECT=${2:-}; shift 2;;
    --ungated) echo "REFUSED: never --ungated"; return 2;;
    [0-9]*) RUN=$1; shift;; *) echo "usage: rb-redrive.sh <run> --from <stage> --why <text> [--force]"; return 2;; esac; done
  [ -n "$RUN" ] && [ -n "$FROM" ] && [ -n "$WHY" ] || { echo "usage: rb-redrive.sh <run> --from <stage> --why <text> [--force]"; return 2; }
  local sig row t0 rep ops c exp DECIDE=${RB_REDRIVE_DECIDE:-wm-decide}
  case $FROM in land) exp=released;; gate) exp=land;; inner) exp=gate;; *) exp=inner;; esac; exp=${EXPECT:-$exp}
  sig=$(sigma); echo "SIGMA run=$RUN $sig"
  row=$($DECIDE record --agent rb --model claude-opus-5-5 --kind run-state --run "rb:$RUN" --expect "$exp" --what "REDRIVE $RUN --from $FROM $FORCE $STOP via rb-redrive.sh: $WHY" --why "$WHY" --evidence "Σ at redrive: $sig" --reverse-text "pause the run / redrive from the prior stage" 2>&1 | tail -1)
  [[ "$row" =~ ^d-[0-9]{8}-[0-9]{6}-rb-[0-9a-f]{4}$ ]] || { echo "ROW REFUSED, no redrive: $row"; return 3; }
  echo "ROW $row"
  [ "$FORCE" = --force ] && [ "$FROM" = land ] && echo "REMINDER: a LAND --force reset deletes the wt target -> SSD symlink; ls -ld wt/<slug>/target after it"
  for attempt in 1 2; do
    t0=$(date +%s)
    rep=$(rssh "o=\$(wm-build run redrive $RUN --from $FROM $FORCE $STOP --operator rb --note $(printf '%q' "$row: $WHY") 2>&1); r=\$?; printf '%s\n' \"\$o\" | head -6; exit \$r"); rc=$?
    echo "DAEMON[$attempt] rc=$rc: $(tr '\n' ' ' <<<"$rep" | cut -c1-400)"
    # rb 6:16 AM: `| head -6` masked the CLI rc (1042 prefix-cap refusal read as rc 0) -> rc comes from wm-build itself, and an `error:` reply is a refusal either way
    [ $rc = 0 ] && ! grep -q 'wm-build: error:' <<<"$rep" || { echo "REFUSED by the daemon (rc=$rc), no journal wait"; return 4; }
    [ -n "${FIX_SSH_DIR:-}" ] || sleep "$WAIT_S"
    ops=$(ops_since "$RUN" "$t0"); c=$(classify "$ops"); echo "JOURNAL[$attempt] +${WAIT_S}s: $c ($(tr '\n' ';' <<<"$ops"))"
    case $c in
      admit) echo "OK run=$RUN row=$row"; return 0;;
      refuse) alarm "release-mem refused row=$row $sig"; return 5;;
      dropped) [ $attempt = 1 ] && { echo "release-mem-dropped -> re-issue once"; continue; }; alarm "release-mem-dropped twice row=$row"; return 5;;
      none) echo "OK-NO-MEM-OP run=$RUN row=$row (no release-mem op in ${WAIT_S}s; a non-cargo stage or still queued)"; return 0;;
    esac
  done
}

if [ "${1:-}" = --selftest ]; then
  T=$(mktemp -d) || exit 70; f=0; ok() { echo "ok   $1"; }; no() { echo "FAIL $1"; f=1; }
  export FIX_SSH_DIR="$T/s" RB_REDRIVE_DECIDE="$T/dec"   # 10-23 11:48 AM leak (a case without fixtures redrove the real 1046, row 0cd9): hermetic default, no case reaches real ssh or wm-decide
  echo "HERMETIC FIX_SSH_DIR=$FIX_SSH_DIR RB_REDRIVE_DECIDE=$RB_REDRIVE_DECIDE"   # tests/rb-redrive.test.sh asserts both sit under the selftest mktemp
  printf '#!/bin/bash\necho d-20261023-060000-rb-abcd\n' > "$T/dec"; chmod +x "$T/dec"; printf '#!/bin/bash\necho refused: bad\n' > "$T/decbad"; chmod +x "$T/decbad"
  mk() { rm -rf -- "${T:?}/s"; mkdir "$T/s"; local i=1; for o in "$@"; do printf '%s\n' "$o" > "$T/s/$i.out"; i=$((i+1)); done; }
  [ "$(classify 'release-mem refuse')" = refuse ] && ok "classify refuse" || no "classify refuse"
  [ "$(classify $'release-mem-dropped run-ended')" = dropped ] && ok "classify dropped" || no "classify dropped"
  [ "$(classify $'release-mem-dropped x\nrelease-mem admit')" = admit ] && ok "classify dropped then admit -> admit" || no "classify dropped+admit"
  [ "$(classify '')" = none ] && ok "classify none" || no "classify none"
  [ "$(classify $'release-mem refuse\nrelease-mem-queued -\nrelease-mem admit\nredrive-reclaim -\nrelease-mem-granted -')" = admit ] && ok "classify refuse then admit+granted -> admit" || no "classify refuse+granted"
  [ "$(classify $'release-mem admit\nrelease-mem refuse')" = refuse ] && ok "classify admit then refuse -> refuse" || no "classify admit+refuse"
  mk "MemAvailable_G=25.0 parts=1047:land:12.5" "redrive ok attempt 5" "release-mem admit"
  out=$(FIX_SSH_DIR="$T/s" RB_REDRIVE_DECIDE="$T/dec" main 1039 --from land --why test 2>&1); rc=$?
  [ $rc = 0 ] && grep -q '^ROW d-20261023-060000-rb-abcd' <<<"$out" && grep -qE 'redrive 1039 --from land +--operator rb --note' "$T/s/argv" && ok "admit path: row first, redrive carries the row id in --note, rc 0" || no "admit path rc=$rc: $out"
  mk "MemAvailable_G=25.0" "x" "release-mem-dropped run-ended" "x" "release-mem admit"
  out=$(FIX_SSH_DIR="$T/s" RB_REDRIVE_DECIDE="$T/dec" main 1039 --from land --why test 2>&1); rc=$?
  [ $rc = 0 ] && [ "$(grep -c 'run redrive 1039' "$T/s/argv")" = 2 ] && ok "dropped once -> re-issued once -> admit" || no "re-issue rc=$rc: $out"
  mk "MemAvailable_G=25.0" "x" "release-mem-dropped a" "x" "release-mem-dropped b"
  out=$(FIX_SSH_DIR="$T/s" RB_REDRIVE_DECIDE="$T/dec" main 1039 --from land --why test 2>&1); rc=$?
  [ $rc = 5 ] && grep -q 'dropped twice' <<<"$out" && ok "dropped twice -> alarm rc 5" || no "dropped twice rc=$rc"
  mk "MemAvailable_G=25.0" "x" "release-mem refuse"
  out=$(FIX_SSH_DIR="$T/s" RB_REDRIVE_DECIDE="$T/dec" main 1039 --from land --why test 2>&1); rc=$?
  [ $rc = 5 ] && [ "$(grep -c 'run redrive' "$T/s/argv")" = 1 ] && ok "refused -> alarm rc 5, no re-issue" || no "refuse rc=$rc"
  mk "MemAvailable_G=25.0"
  out=$(FIX_SSH_DIR="$T/s" RB_REDRIVE_DECIDE="$T/decbad" main 1039 --from land --why test 2>&1); rc=$?
  [ $rc = 3 ] && ! grep -q 'run redrive' "$T/s/argv" && ok "row refused -> no redrive call, rc 3" || no "row-first rc=$rc"
  mk "MemAvailable_G=25.0" "wm-build: error: prefix-cap:mcphost-:1/1: redrive of run 1042 would exceed the cap"
  out=$(FIX_SSH_DIR="$T/s" RB_REDRIVE_DECIDE="$T/dec" main 1042 --from gate --why test 2>&1); rc=$?
  [ $rc = 4 ] && grep -q 'REFUSED by the daemon' <<<"$out" && [ "$(cat "$T/s/.n")" = 2 ] && ok "daemon 'error:' reply with rc 0 -> refused rc 4, no journal read" || no "error reply rc=$rc: $out"
  out=$(main 1039 --from land --why t --ungated 2>&1); [ $? = 2 ] && ok "--ungated refused" || no "--ungated accepted"
  # 1046 11:48 AM 10-23: daemon 'redrive-refused reason=run-open … pass --stop' -> --stop passes through to wm-build run redrive (the daemon's operator-stop path; never systemctl stop)
  mk "MemAvailable_G=25.0" "QUEUED run=1046" "release-mem admit"; FIX_SSH_DIR="$T/s" RB_REDRIVE_DECIDE="$T/dec" main 1046 --from land --why t --stop >/dev/null 2>&1
  grep -qE 'run redrive 1046 --from land +--stop --operator rb' "$T/s/argv" && ok "--stop passed to the daemon" || no "--stop not passed: $(grep 'run redrive' "$T/s/argv")"
  case "$T" in */tmp.*) rm -rf -- "${T:?}";; esac
  [ $f = 0 ] && echo "SELFTEST PASS rb-redrive.sh" || echo "SELFTEST FAIL rb-redrive.sh"; exit $f
fi
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0
main "$@"
