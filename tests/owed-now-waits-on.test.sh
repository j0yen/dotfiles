#!/usr/bin/env bash
# A1307: owed-now lint skips an OVERDUE row whose what-column has a well-formed waits-on=<host|seat|person|event>:<target> with a
# plausible target, and keeps reporting rows with no waits-on=, a malformed one, a placeholder target, or a marker older than
# OWED_WAITS_MAX_H. Exercises the legacy-file source (OPEN_ASKS set to a temp file) and the canonical-store filter via a fu_eval stub.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
H="$root/.claude/hooks/owed-now.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
f=0; chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; f=1; fi; }
LEG="$T/legacy-rows.tsv"
printf '%s\n' '# rows' \
  $'A1\t2026-11-08T00:00\tctl\t2026-11-08T01:00\tk\tc\toverdue, no marker' \
  $'A2\t2026-11-08T00:00\tctl\t2026-11-08T01:00\tk\tc\twaits-on=seat:merge verifier | PR 321' \
  $'A3\t2026-11-08T00:00\tctl\t2026-11-08T01:00\tk\tc\twaits-on=event:step3 acceptance' \
  $'A4\t2026-11-08T00:00\tctl\t2026-11-08T01:00\tk\tc\tmalformed waits-on=soon' \
  $'A5\t2026-11-08T00:00\tctl\t2026-11-08T01:00\tk\tc\twaits-on=seat:none' \
  $'A6\t2026-11-01T00:00\tctl\t2026-11-01T01:00\tk\tc\twaits-on=host:ryzen7 stale week-old marker' \
  $'A7\t2026-11-08T00:00\tctl\t2026-11-08T01:00\tk\tc\twaits-on=person:Joe | decision' > "$LEG"
out="$(env OPEN_ASKS="$LEG" OWED_NOW_SOURCE=tsv OWED_NOW_STATE="$T/st" bash "$H" lint --seat ctl --now 2026-11-08T05:00 2>&1)"
has() { grep -q "^OVERDUE	$1	" <<<"$out"; }
has A1; chk "A1 no waits-on: reported" $?
! has A2; chk "A2 waits-on=seat:...: skipped" $?
! has A3; chk "A3 waits-on=event:...: skipped" $?
has A4; chk "A4 malformed waits-on=soon: reported" $?
has A5; chk "A5 placeholder target seat:none: reported" $?
has A6; chk "A6 marker 7 days past due: reported" $?
! has A7; chk "A7 waits-on=person:Joe: skipped" $?

# canonical-store path: fu_eval is stubbed through a followup-lib replacement on the hook's own directory copy
mkdir -p "$T/hk"; cp "$H" "$T/hk/owed-now.sh"
cat > "$T/hk/followup-lib.sh" <<'LIB'
fu_eval() { FU_EVAL='[{"id":"B1","due":"2026-11-08T01:00","kind":"ask","detail":"no marker"},{"id":"B2","due":"2026-11-08T01:00","kind":"ask","detail":"x | waits-on=seat:verifier | y"},{"id":"B3","due":"2026-11-08T01:00","kind":"ask","detail":"waits-on=later"}]'; FU_REASON=; return 0; }
LIB
out="$(env -u OPEN_ASKS OWED_NOW_SOURCE=asks OWED_NOW_STATE="$T/st" bash "$T/hk/owed-now.sh" lint --seat ctl --now 2026-11-08T05:00 2>&1)"
has B1; chk "ledger path: B1 no waits-on reported" $?
! has B2; chk "ledger path: B2 well-formed waits-on skipped" $?
has B3; chk "ledger path: B3 malformed waits-on reported" $?
echo "owed-now-waits-on test: $([ $f = 0 ] && echo ALL PASS || echo FAILURES)"; exit $f
