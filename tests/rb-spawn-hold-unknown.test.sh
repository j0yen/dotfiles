#!/usr/bin/env bash
# rb-spawn-hold-unknown.test.sh - a failed journal read prints UNKNOWN (never OK); a healthy read still prints OK; reads are serial.
# Fake reader = RB_SPAWN_HOLD_SSH (the script's own ssh override); everything lives under a mktemp -d root.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
hold=${RB_SPAWN_HOLD_UNDER_TEST:-$here/../.local/bin/rb-spawn-hold.sh}
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
R=$(mktemp -d "${TMPDIR:-/tmp}/rb-spawn-hold-unknown.XXXXXX") || exit 2
trap 'case "$R" in */rb-spawn-hold-unknown.*) rm -rf "$R";; esac' EXIT
NOW=2026-10-23T09:30:00Z
mkdir -p "$R/home"

# reader that fails the way the 11-01 probe did: stderr "Killed", rc 137, no rows
printf '#!/usr/bin/env bash\necho Killed >&2\nexit 137\n' > "$R/ssh.killed"
# reader that exits 0 with nothing at all (no table frames)
printf '#!/usr/bin/env bash\nexit 0\n' > "$R/ssh.empty"
# healthy reader: four framed tables, no rows
printf '#!/usr/bin/env bash\nfor t in runs land daemon builder; do echo "### table=$t rc=0 wall_s=1"; done\n' > "$R/ssh.ok"
# records the remote command so the test can read the script text
printf '#!/usr/bin/env bash\nshift\nprintf "%%s" "$*" > "$SHU_CMD"\nfor t in runs land daemon builder; do echo "### table=$t rc=0 wall_s=1"; done\n' > "$R/ssh.rec"
chmod +x "$R"/ssh.*

go() { # go <name> <reader>; sets out rc first
  rm -f "$R/$1.json"
  out=$(env HOME="$R/home" TMPDIR="$R" RB_SPAWN_HOLD_SSH="$R/$2" RB_SPAWN_HOLD_RETRY_S=0 SHU_CMD="$R/cmd.txt" \
    bash "$hold" --state-file "$R/$1.json" --now "$NOW" --no-flag --probe-only 2>/dev/null); rc=$?
  first=${out%%$'\n'*}
}

go k ssh.killed
[ "$rc" = 0 ] && [[ $first == "UNKNOWN unknown: ssh redbaron journal failed: "*"rc=137 source=unknown" ]] && pass "(k) killed reader -> $first" || bad "(k) rc=$rc out=$out"
[[ $first != OK* ]] && pass "(k2) first line does not start with OK" || bad "(k2) $first"
go e ssh.empty
[ "$rc" = 0 ] && [[ $first == UNKNOWN*"source=unknown" ]] && pass "(e) empty output -> $first" || bad "(e) rc=$rc out=$out"
go h ssh.ok
[ "$rc" = 0 ] && [[ $first == "OK no unresolved memory refusal"*"source=ssh"* ]] && pass "(h) healthy reader -> $first" || bad "(h) rc=$rc out=$out"
# non-probe spawn gate with a failing read: UNKNOWN, rc 0 (blind window not yet reached), never OK
rm -f "$R/g.json"
out=$(env HOME="$R/home" TMPDIR="$R" RB_SPAWN_HOLD_SSH="$R/ssh.killed" RB_SPAWN_HOLD_RETRY_S=0 bash "$hold" --state-file "$R/g.json" --now "$NOW" --no-flag 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [[ $out == UNKNOWN* ]] && pass "(g) spawn gate, failing read -> rc 0 $out" || bad "(g) rc=$rc out=$out"
# serial reads: the remote script has no background '&' reads and no 'wait'
go s ssh.rec
cmd=$(cat "$R/cmd.txt" 2>/dev/null)
[[ $cmd == *'rd runs ""; rd land ""'* && $cmd != *"wait"* && $cmd != *'"" &'* ]] && pass "(s) the four table reads are serial" || bad "(s) cmd=$cmd"
# engine crash (state dir not writable), --probe-only: UNKNOWN, rc unchanged (0)
if [ "$(id -u)" != 0 ]; then
  RO=$R/ro; mkdir -p "$RO"; chmod 500 "$RO"
  out=$(env HOME="$R/home" TMPDIR="$R" bash "$hold" --journal-file "$R/none.jsonl" --state-file "$RO/state.json" --now "$NOW" --no-flag --probe-only 2>/dev/null); rc=$?
  chmod 700 "$RO"
  [ "$rc" = 0 ] && [ "$out" = "UNKNOWN unknown: decision engine failed source=unknown" ] && pass "(x) engine crash -> $out" || bad "(x) rc=$rc out=$out"
fi
[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
