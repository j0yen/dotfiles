#!/usr/bin/env bash
# tests/aide-verifier.test.sh: runs aide-verifier.sh --selftest under a throwaway HOME (fakes only: no unit, no wm-decide row,
# no seat bell, no claude; the merge-gate lints (AVL) run against a stub gate tree inside the selftest), then greps the script for the anchored attribution regex and the merge-gate call. Run: bash tests/aide-verifier.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../.local/bin/aide-verifier.sh"
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
th=$(mktemp -d "${TMPDIR:-/tmp}/aide-verifier-test.XXXXXX"); trap 'rm -rf "$th"' EXIT
bash -n "$script" && pass "bash -n" || bad "bash -n"
out=$(HOME="$th" bash "$script" --selftest 2>&1); rc=$?
last=$(printf '%s\n' "$out" | tail -n1)
if [ $rc = 0 ] && [[ $last =~ ^selftest:\ ([0-9]+)/([0-9]+)\ passed$ ]] && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ] && [ "${BASH_REMATCH[2]}" -ge 90 ] \
   && ! printf '%s\n' "$out" | grep -q '^FAIL'; then pass "selftest ($last)"; else bad "selftest rc=$rc"; printf '%s\n' "$out" | grep -v '^PASS' | tail -n 20; fi
# AVL: the launch lints G0/G3/G6/G1/KIND each have their named case in the selftest output
for c in '(a)' '(b)' '(c)' '(d)' '(e)' '(f)' '(g)' '(h)' '(V1): the gated row'"'"'s author=' '(V1): the gated row'"'"'s agent column' '(V2)' '(V4)' '(V6): --head' '(V6): a gh failure' '(V8): AIDE_VERIFIER_GATE_ROOT unset' '(k1)' '(k2)' '(k3)' '(k4)' '(k5)' '(k6/W1)' '(k7/W2)' '(k8/W2)' '(k9/W3)' '(k10/W5)' '(k11/W5)' '(k12/W2)' '(C1/e2f0)' '(C1/0a48)' '(C1/864d)' '(C1/pos)' '(C1/rr)' '(C2/rc2)' '(C2/term)' '(C2/rc6)' '(C2/rc0)' '(s1)' '(s2)' '(s3)' '(s4/X1)' '(s5/X2)'; do
  printf '%s\n' "$out" | grep -qF "PASS gate lint $c" && pass "selftest case: gate lint $c" || bad "selftest case missing or failing: gate lint $c"
done
# AVL mutations: each edit to a COPY of the script must make the named selftest case FAIL (so the case is not vacuous)
MUTS=()
mutate() {  # mutate <label> <sed expr> <FAIL pattern>: runs the mutated selftest in the BACKGROUND (own mktemp HOME), results read by mutate_report after `wait`
  local d; d=$(mktemp -d "$th/mut.XXXXXX"); cp "$script" "$d/aide-verifier.sh"
  cp "$(dirname "$script")/carbon-room.sh" "$d/carbon-room.sh"   # the selftest's real-room cases resolve carbon-room.sh next to the script; a copy without it can never find room
  sed -i -E "$2" "$d/aide-verifier.sh"
  if cmp -s "$script" "$d/aide-verifier.sh"; then bad "$1: the mutation changed nothing"; return; fi
  ( HOME="$d" timeout 400 bash "$d/aide-verifier.sh" --selftest >"$d/mo.out" 2>&1; echo "rc=$?" >"$d/mo.rc" ) &
  MUTS+=("$1"$'\x1f'"$3"$'\x1f'"$d")
}
mutate_report() {
  wait
  local e lbl pat d mo
  for e in "${MUTS[@]}"; do
    IFS=$'\x1f' read -r lbl pat d <<<"$e"; mo=$(cat "$d/mo.out" 2>/dev/null)
    printf '%s\n' "$mo" | grep -qF "FAIL gate lint $pat" && pass "$lbl: selftest case FAILS ($(printf '%s\n' "$mo" | grep -F "FAIL gate lint $pat" | head -n1))" || { bad "$lbl: no FAIL for gate lint $pat ($(cat "$d/mo.rc" 2>/dev/null))"; printf '%s\n' "$mo" | grep -E '^(FAIL|selftest:)' | head -n 5; }
  done
}
mutate "m1 drop L-G6" 's/^( *)lint_g6\(mg, row\) *# AVL-G6$/\1pass/' '(a)'
mutate "m2 drop the prefix-in-suite check" 's/"CMD": suite,/"CMD": " ".join(tokens),/' '(c)'
mutate "m3 fall back to a default root" 's/^( *)if \[ ! -f "\$root\/wm_decide\/mergegate.py" \](.*# AVL-ROOT)$/\1[ -f "$root\/wm_decide\/mergegate.py" ] || root="$HOME\/wintermute\/swarm-decide"\n\1if [ ! -f "$root\/wm_decide\/mergegate.py" ]\2/' '(f)'
mutate "m4 helper failure falls through" 's/(cut -c1-300\)"; return) 1( *# AVL-FAILCLOSED)/\1 0\2/' '(V4)'
mutate "m5 L-KIND accepts any row containing GATED" 's/if not re\.search\(gated_fmt % \(re\.escape\(repo\), re\.escape\(pr\)\), what\):/if "GATED" not in what:/' '(k2)'
mutate "m5b L-KIND drops the stale-COMMIT compare" 's/elif cs\[0\]\.lower\(\) != head\.lower\(\):/elif False:/' '(k3)'
mutate "m6 L-KIND drops the word boundaries" "s/^GATED_RE_FMT=.*/GATED_RE_FMT='GATED %s#%s'/" '(k7/W2)'
mutate "m7 drop the own-unit exclusion" 's/^( *act="\$\(printf .%s\\n. "\$raw" \| )grep -vxF -- "\$own" \| (tr .*# AVL-DROPOWN)$/\1cat | \2/' '(s1)'
mutate "m8 drop the own == target equality check" 's/\[ "\$own" = "\$target" \]; then( *# AVL-SELF)/false; then\1/' '(s4/X1)'
mutate "m9 drop the EXIT trap" 's/^trap gate_cleanup EXIT.*$/:/' '(C2/term)'
mutate_report
# ---- vcap4: which unit states count toward the cap (ported from r7's closed dotfiles#71; fakes only, throwaway HOME) ----
# The stub tells activating from deactivating: it honours the script's --state=a,b,c list by EXACT token, never by substring
# (a substring match makes "activating" also match "deactivating", so dropping activating from the list could never fail).
vc=$th/vc; mkdir -p "$vc/home/.config/environment.d" "$vc/bin" "$vc/av"; : >"$vc/home/.config/environment.d/90-claude-oauth.conf"
cat >"$vc/bin/fake-systemctl" <<'F'
#!/bin/bash
case "$2" in
  list-units) st=""; for a in "$@"; do case "$a" in --state=*) st="${a#--state=}" ;; esac; done
    while read -r u s; do [ -n "$u" ] || continue; case ",$st," in *",$s,"*) echo "$u loaded $s running fake" ;; esac; done <"$FAKE_DIR/units" ;;
  show) echo "[not set]" ;;
esac
exit 0
F
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"$FAKE_DIR/sdrun.log"\n' >"$vc/bin/fake-sdrun"
printf '#!/bin/bash\necho "$1" >>"$FAKE_DIR/room.log"\necho "{\\"ok\\":true,\\"room_mb\\":9000}"\n' >"$vc/bin/fake-room"
printf '#!/bin/bash\nexit 0\n' >"$vc/bin/fake-bell"
# the launch gate lints (AVL) run before the cap: give vl a fake wm-decide (the GATED row), a fake gh (the live head) and a stub merge-gate tree (same stub shape as the script's selftest mkgate)
VH=0123456789abcdef0123456789abcdef01234567; VG=d-20261023-055214-aide-49cf
printf '[{"id":"%s","agent":"aide","what":"GATED j0yen/dotfiles#7 COMMIT=%s agent=coder:avl done","why":"","evidence":""}]\n' "$VG" "$VH" >"$vc/rows.json"
printf '#!/bin/bash\n[ "$1" = list ] && [ "$2" = --json ] && cat "$FAKE_DIR/rows.json"\nexit 0\n' >"$vc/bin/fake-wmd"
printf '#!/bin/bash\nprintf "%%s\\n" "%s"\n' "$VH" >"$vc/bin/gh"
mkdir -p "$vc/gate/wm_decide" "$vc/gate/gen"; : >"$vc/gate/wm_decide/__init__.py"
printf '{"repo_tokens": {"j0yen/dotfiles": ["tests/*.test.sh EXIT=0"]}}\n' >"$vc/gate/gen/merge-gate.json"
printf 'def canon_agent(a):\n    return {"coder:aide": "aide"}.get(a, a)\n' >"$vc/gate/wm_decide/contract.py"
cat >"$vc/gate/wm_decide/mergegate.py" <<'F'
import re
from . import contract
AGENT_RE = re.compile(r"\bagent=([A-Za-z0-9:._-]+)")
AUTHOR_RE = re.compile(r"\bauthor=([A-Za-z0-9:._-]+)")
def strip_attachments(evidence):
    return evidence or ""
def _agent_token(row, rx=AGENT_RE):
    for k in ("what", "evidence", "why"):
        m = rx.search(row.get(k) or "")
        if m: return m.group(1)
    return None
def g3_missing(tokens, atts, commit):
    return [t for t in tokens if not (t.endswith(" EXIT=0") and any(t[:-7] in (a["trailer"].get("CMD") or "") for a in atts))], None
F
chmod +x "$vc"/bin/*
printf '0.10 0.10 0.10 1/1 1\n' >"$vc/loadavg"
vl() { local nm="$1"; shift; HOME="$vc/home" FAKE_DIR="$vc" AIDE_VERIFIER_DIR="$vc/av" AIDE_VERIFIER_ROOM_CMD="$vc/bin/fake-room" AIDE_VERIFIER_SYSTEMD_RUN="$vc/bin/fake-sdrun" \
  AIDE_VERIFIER_SYSTEMCTL="$vc/bin/fake-systemctl" AIDE_VERIFIER_BELL="$vc/bin/fake-bell" AIDE_VERIFIER_WM_DECIDE="$vc/bin/fake-wmd" AIDE_VERIFIER_GATE_ROOT="$vc/gate" PATH="$vc/bin:$PATH" AIDE_VERIFIER_CGROUP_FILE="$vc/cgroup-absent" AIDE_VERIFIER_LOADAVG_FILE="${AIDE_VERIFIER_LOADAVG_FILE:-$vc/loadavg}" AIDE_VERIFIER_SELFTEST=1 AIDE_VERIFIER_SLOT_CEIL=2 AIDE_VERIFIER_POLL_S=1 \
  bash "$script" launch "$nm" --repo j0yen/dotfiles --pr 7 --gated "$VG" --token 'tests/*.test.sh EXIT=0' --suite 'bash tests/run.sh; echo "tests/*.test.sh EXIT=$?"' \
  --head 0123456789abcdef0123456789abcdef01234567 "$@" 2>&1; }
# stub self-check: the state filter is exact-token (activating is not deactivating)
printf 'rb-verifier-s.service activating\n' >"$vc/units"
[ -z "$(FAKE_DIR=$vc bash "$vc/bin/fake-systemctl" --user list-units '*-verifier-*' --state=active,deactivating,reloading)" ] \
  && [ -n "$(FAKE_DIR=$vc bash "$vc/bin/fake-systemctl" --user list-units '*-verifier-*' --state=activating)" ] \
  && pass "vcap4 stub: --state matches exact tokens (activating != deactivating)" || bad "vcap4 stub does not tell activating from deactivating"
# (1) an ACTIVATING unit counts: 1 active + 1 activating at ceiling 2 -> cap reached, exit 2, nothing started
printf 'rb-verifier-a.service active\nr7-verifier-b.service activating\n' >"$vc/units"; rm -f "$vc/sdrun.log"
out=$(vl act1); rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"verifier cap reached: 2 of 2"* ]] && [ ! -e "$vc/sdrun.log" ] \
  && pass "vcap4 (1) 1 active + 1 activating at ceiling 2 -> exit 2, nothing started" || bad "vcap4 (1) activating unit did not count (rc=$rc: $out)"
# (1b) a DEACTIVATING unit counts too (control: the stub must not conflate it with activating)
printf 'rb-verifier-a.service active\nr7-verifier-b.service deactivating\n' >"$vc/units"; rm -f "$vc/sdrun.log"
out=$(vl deact1); rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"2 of 2"* ]] && [ ! -e "$vc/sdrun.log" ] \
  && pass "vcap4 (1b) 1 active + 1 deactivating at ceiling 2 -> exit 2" || bad "vcap4 (1b) deactivating unit did not count (rc=$rc: $out)"
# (2) FAILED units never count: 1 active + 2 failed at ceiling 2 -> launches, room priced for 1 active (1024 x 2 = 2048 MB)
printf 'rb-verifier-a.service active\nr7-verifier-f1.service failed\naide-verifier-f2.service failed\n' >"$vc/units"; rm -f "$vc/sdrun.log" "$vc/room.log"
out=$(vl fail1); rc=$?
[ "$rc" = 0 ] && [ "$(wc -l <"$vc/sdrun.log")" = 1 ] && [ "$(cat "$vc/room.log")" = 2048 ] \
  && pass "vcap4 (2) 1 active + 2 failed at ceiling 2 -> launches, room asked 2048 MB" || bad "vcap4 (2) failed units counted (rc=$rc room=$(cat "$vc/room.log" 2>/dev/null): $out)"

# ---- vguard: a verdict whose log shows tests SKIPPED by the load guard is retracted before merge-gate (finish rc 12); launch refuses a loaded host (rc 13) ----
fx="$here/fixtures/vguard-443-tail.log"
fg=$th/fg; mkdir -p "$fg/bin" "$fg/av" "$fg/home" "$fg/gate/gen" "$fg/gate/wm_decide"
printf '{"repo_tokens": {}}\n' >"$fg/gate/gen/merge-gate.json"
cat >"$fg/bin/fake-wmd" <<'F'
#!/bin/bash
echo "$*" >>"$FAKE_DIR/wmd.log"
case "$1" in
  list) cat "$FAKE_DIR/rows.json" ;;
  record) [ -e "$FAKE_DIR/record.fail" ] && { echo "refused: stub" >&2; exit 2; }; echo d-20261027-000000-aide-ffff ;;
  merge-gate) echo "PASS stub gate"; exit 0 ;;
esac
F
printf '#!/bin/bash\necho "$*" >>"$FAKE_DIR/bell.log"\n' >"$fg/bin/fake-bell"; chmod +x "$fg/bin"/*
GV=d-20261027-041958-aide-c01a; GG=d-20261027-040000-aide-0001
fin() {  # fin <name> <logfile> [verdict what]: runs finish on a fresh unit dir whose result.json names $GV and the log; stdout+stderr in $fg/out, rc returned
  local nm=$1 lg=$2 vw="${3:-MERGE-OK j0yen/synthorg#443 COMMIT=c01a5f98efd103c833032b11a3b99346b2d9e9fe agent=verifier:aide-verifier-$1}"
  mkdir -p "$fg/av/$nm"; printf 'repo=j0yen/synthorg\npr=443\nhead=c01a5f98efd103c833032b11a3b99346b2d9e9fe\ngated=%s\nagent=aide\ntimeout_s=2400\n' "$GG" >"$fg/av/$nm/meta"
  jq -n --arg r "head ok
LOG: $lg
VERDICT: $GV" '{is_error:false,result:$r}' >"$fg/av/$nm/result.json"
  jq -n --arg id "$GV" --arg w "$vw" '[{id:$id,agent:"aide",kind:"verdict",what:$w}]' >"$fg/rows.json"
  : >"$fg/wmd.log"; : >"$fg/bell.log"; rm -f "$fg/record.fail"; [ -z "${FAILREC:-}" ] || touch "$fg/record.fail"
  HOME="$fg/home" FAKE_DIR="$fg" AIDE_VERIFIER_DIR="$fg/av" AIDE_VERIFIER_WM_DECIDE="$fg/bin/fake-wmd" AIDE_VERIFIER_BELL="$fg/bin/fake-bell" AIDE_VERIFIER_GATE_ROOT="$fg/gate" \
    bash "$script" finish "$nm" >"$fg/out" 2>&1
}
# (a) the #443 golden-skip line DEEP above the tail (40 neutral lines between it and the tail)
{ grep -F 'LOAD_GUARD=1:' "$fx"; for i in $(seq 40); do echo "tests/test_neutral_$i.py ......  [ $i%]"; done; grep -vF 'LOAD_GUARD=1:' "$fx"; } >"$fg/deep.log"
fin deep "$fg/deep.log"; rc=$?
[ "$rc" = 12 ] && grep -q ' GUARD-SKIP rc=12 ' "$fg/av/deep/finished" && ! grep -q FAIL "$fg/av/deep/finished" \
  && grep -q '^record .*--kind verdict .*--gates '"$GV"' .*CORRECT-RETRACT '"$GV"': GUARD-SKIP 1 test(s) SKIPPED by the load guard (first: tests/test_golden.py:163)' "$fg/wmd.log" \
  && grep -q 'EVENT GUARD-SKIP j0yen/synthorg#443 head c01a5f98efd103c833032b11a3b99346b2d9e9fe row '"$GV"' .*MERGE-OK RETRACTED; re-verify when load is below core count' "$fg/bell.log" \
  && ! grep -q '^merge-gate' "$fg/wmd.log" \
  && pass "vguard (a) golden skip far above the tail -> rc 12, finished GUARD-SKIP without FAIL, CORRECT-RETRACT row, GUARD-SKIP bell, merge-gate not called" || { bad "vguard (a) (rc=$rc finished=$(cat "$fg/av/deep/finished" 2>/dev/null))"; cat "$fg/out" "$fg/wmd.log" | head -n 8; }
# (b) the same log without the line -> merge-gate runs, rc 0
grep -vF 'LOAD_GUARD=1:' "$fx" >"$fg/clean.log"
fin clean "$fg/clean.log"; rc=$?
[ "$rc" = 0 ] && grep -q '^merge-gate '"$GV" "$fg/wmd.log" && ! grep -q GUARD-SKIP "$fg/bell.log" && pass "vguard (b) same log without the line -> merge-gate called, rc 0" || { bad "vguard (b) (rc=$rc)"; head -n 5 "$fg/out"; }
# (c) SKIPPED [2] -> K=2 in the retraction and the bell
printf 'SKIPPED [2] tests/wtp_support.py:43: SYNTHORG_LOAD_GUARD=1: 1-minute load average 12.0 exceeds core count 8\n' >"$fg/k2.log"
fin k2 "$fg/k2.log"; rc=$?
[ "$rc" = 12 ] && grep -q 'GUARD-SKIP 2 test(s) SKIPPED by the load guard (first: tests/wtp_support.py:43)' "$fg/wmd.log" && grep -q ': 2 test(s) skipped by the load guard' "$fg/bell.log" && pass "vguard (c) SKIPPED [2] -> K=2 in the row and the bell" || bad "vguard (c) (rc=$rc)"
# (d) an ANSI-coloured skip line (pytest --color=yes) -> rc 12;  (d2) CR-led and CRLF lines
printf '\033[33mSKIPPED\033[0m [1] tests/a.py:5: SYNTHORG_LOAD_GUARD=1: 1-minute load average 9.00 exceeds core count 8\n' >"$fg/ansi.log"
fin ansi "$fg/ansi.log"; rc=$?; [ "$rc" = 12 ] && pass "vguard (d) ANSI-coloured skip line -> rc 12" || bad "vguard (d) (rc=$rc)"
printf '\rSKIPPED [1] tests/a.py:5: SYNTHORG_LOAD_GUARD=1: 1-minute load average 9.00 exceeds core count 8\r\n' >"$fg/cr.log"
fin cr "$fg/cr.log"; rc=$?; [ "$rc" = 12 ] && pass "vguard (d2) CR-led / CRLF skip line -> rc 12" || bad "vguard (d2) (rc=$rc)"
# (e) `set SYNTHORG_LOAD_GUARD=1 to run it` is a different skip reason: not a guard skip
printf 'SKIPPED [1] tests/test_cli_backend.py:354: real-claude probe: set SYNTHORG_LOAD_GUARD=1 to run it\n' >"$fg/excl.log"
fin excl "$fg/excl.log"; rc=$?
[ "$rc" = 0 ] && grep -q '^merge-gate ' "$fg/wmd.log" && pass "vguard (e) 'set SYNTHORG_LOAD_GUARD=1 to run it' is not a guard skip" || bad "vguard (e) (rc=$rc)"
# (f) unitemized `3 skipped` summary with no SKIPPED lines: one WARN, merge-gate still called
printf '10 passed, 3 skipped in 1.20s\n' >"$fg/unit.log"
fin unit "$fg/unit.log"; rc=$?
[ "$rc" = 0 ] && grep -q 'WARN skips not itemized (suite lacks -rs)' "$fg/out" && grep -q '^merge-gate ' "$fg/wmd.log" && pass "vguard (f) '3 skipped' with no SKIPPED lines -> WARN, merge-gate called" || bad "vguard (f) (rc=$rc)"
# (h) amendment 4: only a GREEN verdict is retracted; a red one goes to merge-gate
fin red "$fg/deep.log" "REFUSE j0yen/synthorg#443 tests red"; rc=$?
[ "$rc" = 0 ] && grep -q '^merge-gate ' "$fg/wmd.log" && ! grep -q 'CORRECT-RETRACT' "$fg/wmd.log" && pass "vguard (h) a non-green verdict row goes to merge-gate, not the guard path" || bad "vguard (h) (rc=$rc)"
# (i) amendment 5: the retraction row failing -> finished carries FAIL (driver rings stuck), bell says RETRACT FAILED, rc 12, merge-gate not called
FAILREC=1 fin rfail "$fg/deep.log"; rc=$?
[ "$rc" = 12 ] && grep -q ' GUARD-SKIP rc=12 RETRACT-FAILED ' "$fg/av/rfail/finished" && grep -q FAIL "$fg/av/rfail/finished" && grep -q 'RETRACT FAILED' "$fg/bell.log" && ! grep -q '^merge-gate' "$fg/wmd.log" && pass "vguard (i) retraction write fails -> finished RETRACT-FAILED (has FAIL), bell RETRACT FAILED, rc 12" || bad "vguard (i) (rc=$rc: $(cat "$fg/av/rfail/finished" 2>/dev/null))"
# (j) the retraction is written BEFORE the finished file and before the bell
python3 - "$script" <<'P' && pass "vguard (j) order in the script: record row, then bell, then finished" || bad "vguard (j) write order"
import re, sys
s = open(sys.argv[1]).read()
i = s.index("CORRECT-RETRACT $verdict"); j = s.index('EVENT GUARD-SKIP', i); k = s.index('GUARD-SKIP rc=12 $verdict', j)
sys.exit(0 if i < j < k else 1)
P
# (k) the scan reads the log only when readable; a missing log keeps the old path
fin nolog "$fg/does-not-exist.log"; rc=$?
[ "$rc" = 0 ] && grep -q '^merge-gate ' "$fg/wmd.log" && pass "vguard (k) a missing log keeps today's path (merge-gate decides)" || bad "vguard (k) (rc=$rc)"
# (l) --guard-skip-re prints the built-in default when the live gen has no key, the gen value when it has one, exit 2 + built-in when grep -E rejects it
def=$(AIDE_VERIFIER_GATE_ROOT="$fg/gate" bash "$script" --guard-skip-re 2>/dev/null)
[ "$def" = '^SKIPPED \[([0-9]+)\] ([^ ]+): .*([A-Z_]*LOAD_GUARD=1: |load average [0-9.]+ exceeds core count)' ] && pass "vguard (l) --guard-skip-re prints the built-in default without a live key" || bad "vguard (l) default: $def"
printf '{"repo_tokens": {}, "load_guard_skip_re": "^SKIPPED .*LOAD_GUARD=1: "}\n' >"$fg/gate/gen/merge-gate.json"
[ "$(AIDE_VERIFIER_GATE_ROOT="$fg/gate" bash "$script" --guard-skip-re 2>/dev/null)" = '^SKIPPED .*LOAD_GUARD=1: ' ] && pass "vguard (l) a live load_guard_skip_re wins" || bad "vguard (l) live key"
printf '{"repo_tokens": {}, "load_guard_skip_re": "^SKIPPED (?:\\\\[1\\\\]) \\\\d+"}\n' >"$fg/gate/gen/merge-gate.json"
o=$(AIDE_VERIFIER_GATE_ROOT="$fg/gate" bash "$script" --guard-skip-re 2>/dev/null); rc=$?
[ "$rc" = 2 ] && [ "$o" = "$def" ] && pass "vguard (l) a Python-only regex (?: / \\d -> exit 2, built-in printed" || bad "vguard (l) bad regex (rc=$rc: $o)"
printf '{"repo_tokens": {}, "load_guard_skip_re": "(?:x"}\n' >"$fg/gate/gen/merge-gate.json"
fin badre2 "$fg/deep.log"; rc=$?
[ "$rc" = 12 ] && grep -q 'WARN live load_guard_skip_re' "$fg/out" && pass "vguard (l) finish with a rejected live regex falls back to the built-in default and WARNs (the skip is still caught)" || bad "vguard (l) finish fallback (rc=$rc)"
printf '{"repo_tokens": {}}\n' >"$fg/gate/gen/merge-gate.json"

# ---- vguard launch: load gate (exit 13 / queue / exit 9 / amendment 1 term / default nproc-3 / wait bound) and PYTEST_ADDOPTS -rs ----
printf '' >"$vc/units"; rm -f "$vc/sdrun.log"; printf '9.50 8.00 7.00 3/900 1\n' >"$vc/lo"
out=$(AIDE_VERIFIER_LOADAVG_FILE="$vc/lo" AIDE_VERIFIER_MAX_LOAD=8 vl ld1); rc=$?
[ "$rc" = 13 ] && [[ "$out" == *"load 9.50"*">= MAX_LOAD 8"* ]] && [ ! -e "$vc/sdrun.log" ] && pass "vguard (g) loadavg 9.5, MAX 8 -> exit 13, nothing started" || bad "vguard (g) exit 13 (rc=$rc: $out)"
( sleep 2; printf '1.00 1.00 1.00 1/9 1\n' >"$vc/lo" ) &
out=$(AIDE_VERIFIER_LOADAVG_FILE="$vc/lo" AIDE_VERIFIER_MAX_LOAD=8 vl ld2 --queue); rc=$?; wait
[ "$rc" = 0 ] && [ "$(wc -l <"$vc/sdrun.log")" = 1 ] && pass "vguard (g) --queue waits, load rewritten to 1.0 -> launches" || bad "vguard (g) queue (rc=$rc: $out)"
rm -f "$vc/sdrun.log"
out=$(AIDE_VERIFIER_LOADAVG_FILE="$vc/lo" AIDE_VERIFIER_MAX_LOAD=0 vl ld3); rc=$?
[ "$rc" = 9 ] && [ ! -e "$vc/sdrun.log" ] && pass "vguard (g) AIDE_VERIFIER_MAX_LOAD=0 -> exit 9" || bad "vguard (g) MAX_LOAD=0 (rc=$rc: $out)"
# amendment 1: load1 + 2 x running verifier units < MAX
printf 'rb-verifier-a.service active\n' >"$vc/units"; printf '6.50 1 1 1/1 1\n' >"$vc/lo"; rm -f "$vc/sdrun.log"
out=$(AIDE_VERIFIER_LOADAVG_FILE="$vc/lo" AIDE_VERIFIER_MAX_LOAD=8 vl ld4); rc=$?
[ "$rc" = 13 ] && [[ "$out" == *"2 x 1 running"* ]] && pass "vguard (g) load 6.5 + 2 x 1 running unit >= 8 -> exit 13" || bad "vguard (g) unit term (rc=$rc: $out)"
printf '5.50 1 1 1/1 1\n' >"$vc/lo"
out=$(AIDE_VERIFIER_LOADAVG_FILE="$vc/lo" AIDE_VERIFIER_MAX_LOAD=8 vl ld5); rc=$?
[ "$rc" = 0 ] && pass "vguard (g) load 5.5 + 2 x 1 running unit < 8 -> launches" || bad "vguard (g) unit term pass (rc=$rc: $out)"
# default MAX_LOAD = nproc - 3 (min 1): a fake nproc of 6 -> 3, of 2 -> 1
printf '' >"$vc/units"; printf '#!/bin/bash\necho 6\n' >"$vc/bin/nproc"; chmod +x "$vc/bin/nproc"; printf '3.20 1 1 1/1 1\n' >"$vc/lo"
out=$(AIDE_VERIFIER_LOADAVG_FILE="$vc/lo" vl ld6); rc=$?; [ "$rc" = 13 ] && [[ "$out" == *"MAX_LOAD 3"* ]] && pass "vguard (g) default MAX_LOAD = nproc - 3 (6 -> 3)" || bad "vguard (g) default 3 (rc=$rc: $out)"
printf '#!/bin/bash\necho 2\n' >"$vc/bin/nproc"; printf '1.20 1 1 1/1 1\n' >"$vc/lo"
out=$(AIDE_VERIFIER_LOADAVG_FILE="$vc/lo" vl ld7); rc=$?; [ "$rc" = 13 ] && [[ "$out" == *"MAX_LOAD 1"* ]] && pass "vguard (g) default MAX_LOAD floors at 1 (nproc 2 -> 1)" || bad "vguard (g) default floor (rc=$rc: $out)"
rm -f "$vc/bin/nproc"
# the load wait is bounded by AIDE_VERIFIER_LOAD_WAIT_S -> exit 6
printf '9.50 1 1 1/1 1\n' >"$vc/lo"
out=$(AIDE_VERIFIER_LOADAVG_FILE="$vc/lo" AIDE_VERIFIER_MAX_LOAD=8 AIDE_VERIFIER_LOAD_WAIT_S=2 vl ld8 --queue); rc=$?
[ "$rc" = 6 ] && [[ "$out" == *"load wait exceeded 2s"* ]] && pass "vguard (g) --queue load wait bounded by AIDE_VERIFIER_LOAD_WAIT_S -> exit 6" || bad "vguard (g) load wait bound (rc=$rc: $out)"
# amendment 7: the unit's environment carries -rs (and keeps a caller's PYTEST_ADDOPTS)
out=$(vl pt1); rc=$?
grep -qxF 'export PYTEST_ADDOPTS=-rs' "$vc/av/pt1/launch.sh" && pass "vguard (m) the unit env (launch.sh) carries PYTEST_ADDOPTS=-rs" || bad "vguard (m) PYTEST_ADDOPTS (rc=$rc: $out; $(grep PYTEST "$vc/av/pt1/launch.sh" 2>/dev/null))"
out=$(PYTEST_ADDOPTS="-x" vl pt2); rc=$?
grep -qxF 'export PYTEST_ADDOPTS=-x\ -rs' "$vc/av/pt2/launch.sh" && pass "vguard (m) a caller's PYTEST_ADDOPTS is kept: '-x -rs'" || bad "vguard (m) PYTEST_ADDOPTS append"

grep -qF '^[[:space:]]*(co-authored-by:|generated with)' "$script" && pass "script carries the anchored attribution regex" || bad "anchored attribution regex missing"
grep -q 'merge-gate' "$script" && pass "script calls merge-gate" || bad "merge-gate missing"
grep -qF -- '--agent {{AGENT}} --via verifier --model sonnet --kind verdict --gates' "$script" && pass "prompt template records the verdict row shape" || bad "verdict row shape missing"
[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
