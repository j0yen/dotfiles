#!/usr/bin/env bash
# Test (A1572 stage3 AC2): model-role-check.sh knows bld/rls (default claude-sonnet-5-5); ctl/ops/rb/r7 unchanged.
set -u
H="$(dirname "$0")/../.claude/hooks/model-role-check.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
printf 'ctl claude-sonnet-5-5\nrb claude-opus-5-5\nr7 claude-fable-5-1\n' > "$T/table"
printf '' > "$T/empty"
printf '{"type":"assistant","message":{"model":"claude-opus-5-5"}}\n' > "$T/opus.jsonl"
printf '{"type":"assistant","message":{"model":"claude-sonnet-5-5-20261101"}}\n' > "$T/sonnet.jsonl"
run() { # run <seat> <transcript> [table]
  printf '{"transcript_path":"%s"}' "$2" | env -u TMUX -u TMUX_PANE -u MRC_FORCE_ROLE MRC_TABLE="${3:-$T/table}" MRC_SKIP_FALLBACK=1 WM_SEAT="$1" bash "$H"; echo "rc=$?"; }
c=$(run ctl "$T/opus.jsonl" | sed 's/role=ctl/role=X/')
for s in bld rls; do
  o=$(run $s "$T/opus.jsonl" | sed "s/role=$s/role=X/")
  [ "$o" = "$c" ] && grep -q "^⚠⚠ MODEL MISMATCH: role=X running=claude-opus-5-5 required=claude-sonnet-5-5 " <<<"$o" && grep -q "^rc=0$" <<<"$o"; chk "$s mismatch: same shape + exit as ctl" $?
  o=$(run $s "$T/sonnet.jsonl"); [ "$o" = "rc=0" ]; chk "$s matching sonnet-5-5: silent" $?
  o=$(run $s "$T/opus.jsonl" "$T/empty"); grep -q "role=$s running=claude-opus-5-5 required=claude-sonnet-5-5" <<<"$o"; chk "$s default applies with empty table" $?
  o=$(run $s "$T/opus.jsonl" "$T/nonexistent"); grep -q "role=$s running=claude-opus-5-5 required=claude-sonnet-5-5" <<<"$o"; chk "$s default applies with absent table" $?
done
printf 'bld claude-opus-5-5\n' > "$T/t2"; o=$(run bld "$T/opus.jsonl" "$T/t2"); [ "$o" = "rc=0" ]; chk "table row overrides default" $?
o=$(run ctl "$T/sonnet.jsonl"); [ "$o" = "rc=0" ]; chk "ctl match silent" $?
o=$(run ops "$T/opus.jsonl"); grep -q 'role=ctl running=claude-opus-5-5 required=claude-sonnet-5-5' <<<"$o"; chk "ops maps to ctl role" $?
o=$(run rb "$T/opus.jsonl"); [ "$o" = "rc=0" ]; chk "rb opus match silent" $?
o=$(run r7 "$T/opus.jsonl"); grep -q 'role=r7 running=claude-opus-5-5 required=claude-fable-5-1' <<<"$o"; chk "r7 mismatch unchanged" $?
o=$(run ctl "$T/opus.jsonl" "$T/empty"); [ "$o" = "rc=0" ]; chk "ctl with empty table: silent (no default for ctl)" $?
# unchanged-gates list: no bld|rls hits
d="$(dirname "$H")"
for f in probe-gate.sh carbon-no-build.sh hold-gate.sh never-ask-joe.sh owed-now.sh; do
  [ -e "$d/$f" ] || [ -e "$d/../../.local/bin/$f" ] || { echo "NOTE $f not in repo hooks dir"; continue; }
  p="$d/$f"; [ -e "$p" ] || p="$d/../../.local/bin/$f"
  ! grep -qE '\b(bld|rls)\b' "$p"; chk "$f has no bld|rls hits" $?
done
[ "$fail" = 0 ] && echo "TEST PASS" || { echo "TEST FAIL"; exit 1; }
