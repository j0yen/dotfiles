#!/usr/bin/env bash
# mech-registry.sh: parse, probe (fake runner, never ssh), counts, status fields. Throwaway dirs only.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="$here/../.local/bin/mech-registry.sh"
fx="$here/fixtures/mech-registry"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; n=0
chk() { n=$((n+1)); if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=$((fail+1)); fi; }
export WIKI="$fx/wiki" CLAUDE_MD="$fx/claude.md" MECH_EXTRA="$fx/extra" OUT="$T/m.json" MECH_NOW=2026-10-30 \
  PROBE_CMD="$fx/fake-probe.sh" PROBE_LOG="$T/probe.log" HOME="$T/home"
mkdir -p "$T/home"
bash -n "$bin" ; chk "bash -n wrapper" $?
"$bin" >"$T/run.out" 2>&1; chk "run rc 0" $?
q() { python3 -I -c "import json,sys;d=json.load(open('$OUT'));$1"; }
row() { q "r=[m for m in d['mechanisms'] if m['page'].endswith('$1') and m['line']==$2][0];print(r['$3'])"; }

[ "$(row 2026-10-20-alpha-five-whys-rhyme.md 11 state_probed)" = "LIVE" ] ; chk "a: remote-line with existing artifact LIVE" $?
l="$(q "print([m for m in d['mechanisms'] if 'alpha' in m['page'] and 'exists-art.sh' in m['artifact']][0]['state_probed'])")"
[ "$l" = LIVE ]; chk "a: existing artifact -> LIVE" $?
[ "$(row 2026-10-20-alpha-five-whys-rhyme.md 8 state_probed)" = NOT-LIVE ] && [ "$(row 2026-10-20-alpha-five-whys-rhyme.md 8 reason)" = probe-failed ]; chk "b: missing artifact -> NOT-LIVE probe-failed" $?
[ "$(row 2026-10-20-alpha-five-whys-rhyme.md 9 reason)" = no-artifact ] && [ "$(row 2026-10-20-alpha-five-whys-rhyme.md 9 state_probed)" = NOT-LIVE ]; chk "c: no artifact -> NOT-LIVE no-artifact" $?
[ "$(row 2026-10-20-alpha-five-whys-rhyme.md 10 state_probed)" = NOT-LIVE ] && [ "$(row 2026-10-20-alpha-five-whys-rhyme.md 10 reason)" = pr-only ]; chk "d: PR-merged-only -> NOT-LIVE pr-only" $?
grep -q '^redbaron ' "$T/probe.log"; chk "host rb routes the probe to redbaron" $?
grep -q '^carbon ' "$T/probe.log"; chk "default host carbon" $?
! grep -qi 'merge' "$T/probe.log"; chk "no probe issued for PR-only line" $?
q "assert [m for m in d['mechanisms'] if 'beta' in m['page']].__len__()==2"; chk "e: malformed line not registered" $?
q "assert d['parse_mismatch']['count']==1 and d['parse_mismatch']['pages'][0]['page'].endswith('beta-decision.md'), d['parse_mismatch']"; chk "e: 3 gear, 2 parsed -> parse_mismatch 1" $?
q "assert d['status_fields']['mechanisms_parse_mismatch']=={'count':1,'pages':['decisions/2026-10-29-beta-decision.md']}"; chk "f: parse_mismatch field" $?
# not live: alpha 8,9,10 + beta 2 + claude.md 1 = 5; >48h: all but beta (10-29, 1 day old)
q "f=d['status_fields']['mechanisms_not_live'];assert f['count']==5 and len(f['oldest'])==5, f"; chk "f: mechanisms_not_live count 5" $?
q "f=d['status_fields']['mechanisms_spec_over_48h'];assert f['count']==4 and f['oldest'][0]['first_seen']=='2026-10-01', f"; chk "f: spec_over_48h count 4 (beta 10-29 is < 48 h), oldest is the CLAUDE.md 10-01 line" $?
q "assert len(d['alarms'])==2, d['alarms']"; chk "f: both alarms raised" $?
[ "$(row claude.md 1 state_as_written)" = SPEC ]; chk "CLAUDE.md SPEC pointer registered, first_seen from dated quote" $?
q "assert [m for m in d['mechanisms'] if m['owner']=='coder'][0]['state_probed']=='LIVE'"; chk "MECH_EXTRA docs/mechanisms.md line registered and probed" $?
# recent (<=48h) NOT-LIVE does not count toward spec_over_48h
MECH_NOW=2026-10-21 OUT="$T/m2.json" "$bin" >/dev/null; python3 -I -c "
import json;d=json.load(open('$T/m2.json'));f=d['status_fields']
assert f['mechanisms_spec_over_48h']['count']<f['mechanisms_not_live']['count'],f"; chk "fresh NOT-LIVE (<48 h) excluded from spec_over_48h" $?
"$bin" --fields | python3 -I -c "import json,sys;j=json.load(sys.stdin);assert set(j['fields'])=={'mechanisms_not_live','mechanisms_spec_over_48h','mechanisms_parse_mismatch'}"; chk "--fields prints the three fields" $?
# FLEET STATUS line: unmeasured when wm-decide followups is absent; numbers when present
WM_DECIDE=/nonexistent/wm-decide "$bin" --line | grep -Eq '^follow-ups: corrections owed unmeasured, mechanisms not live 5 \(>48h 4\), oldest '; chk "--line: unmeasured without wm-decide followups" $?
cat >"$T/wmd" <<'X'
#!/usr/bin/env bash
echo '{"owed":3,"overdue":1,"oldest":"d9f2"}'
X
chmod +x "$T/wmd"
WM_DECIDE="$T/wmd" "$bin" --line | grep -Fxq 'follow-ups: corrections owed 3 (overdue 1), mechanisms not live 5 (>48h 4), oldest d9f2'; chk "--line: numbers from followups --json" $?
echo "COUNTS: ran=$n pass=$((n-fail)) fail=$fail"
exit $((fail>0))
