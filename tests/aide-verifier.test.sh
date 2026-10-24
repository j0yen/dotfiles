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
vl() { local nm="$1"; shift; HOME="$vc/home" FAKE_DIR="$vc" AIDE_VERIFIER_DIR="$vc/av" AIDE_VERIFIER_ROOM_CMD="$vc/bin/fake-room" AIDE_VERIFIER_SYSTEMD_RUN="$vc/bin/fake-sdrun" \
  AIDE_VERIFIER_SYSTEMCTL="$vc/bin/fake-systemctl" AIDE_VERIFIER_BELL="$vc/bin/fake-bell" AIDE_VERIFIER_WM_DECIDE="$vc/bin/fake-wmd" AIDE_VERIFIER_GATE_ROOT="$vc/gate" PATH="$vc/bin:$PATH" AIDE_VERIFIER_CGROUP_FILE="$vc/cgroup-absent" AIDE_VERIFIER_SELFTEST=1 AIDE_VERIFIER_SLOT_CEIL=2 AIDE_VERIFIER_POLL_S=1 \
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

grep -qF '^[[:space:]]*(co-authored-by:|generated with)' "$script" && pass "script carries the anchored attribution regex" || bad "anchored attribution regex missing"
grep -q 'merge-gate' "$script" && pass "script calls merge-gate" || bad "merge-gate missing"
grep -qF -- '--agent {{AGENT}} --via verifier --model sonnet --kind verdict --gates' "$script" && pass "prompt template records the verdict row shape" || bad "verdict row shape missing"
[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
