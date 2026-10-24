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
if [ $rc = 0 ] && [[ $last =~ ^selftest:\ ([0-9]+)/([0-9]+)\ passed$ ]] && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ] && [ "${BASH_REMATCH[2]}" -ge 102 ] \
   && ! printf '%s\n' "$out" | grep -q '^FAIL'; then pass "selftest ($last)"; else bad "selftest rc=$rc"; printf '%s\n' "$out" | grep -v '^PASS' | tail -n 20; fi
# AVL: the launch lints G0/G3/G6/G1/KIND each have their named case in the selftest output
for c in '(a)' '(b)' '(c)' '(d)' '(e)' '(f)' '(g)' '(h)' '(V1): the gated row'"'"'s author=' '(V1): the gated row'"'"'s agent column' '(V2)' '(V4)' '(V6): --head' '(V6): a gh failure' '(V8): AIDE_VERIFIER_GATE_ROOT unset' '(k1)' '(k2)' '(k3)' '(k4)' '(k5)' '(k6/W1)' '(k7/W2)' '(k8/W2)' '(k9/W3)' '(k10/W5)' '(k11/W5)' '(k12/W2)' '(C1/e2f0)' '(C1/0a48)' '(C1/864d)' '(C1/pos)' '(C1/rr)' '(C2/rc2)' '(C2/term)' '(C2/rc6)' '(C2/rc0)' '(s1)' '(s2)' '(s3)' '(s4/X1)' '(s5/X2)'; do
  printf '%s\n' "$out" | grep -qF "PASS gate lint $c" && pass "selftest case: gate lint $c" || bad "selftest case missing or failing: gate lint $c"
done
# AVL mutations: each edit to a COPY of the script must make the named selftest case FAIL (so the case is not vacuous)
mutate() {  # mutate <label> <sed expr> <FAIL pattern>
  local d; d=$(mktemp -d "$th/mut.XXXXXX"); cp "$script" "$d/aide-verifier.sh"
  sed -i -E "$2" "$d/aide-verifier.sh"
  if cmp -s "$script" "$d/aide-verifier.sh"; then bad "$1: the mutation changed nothing"; return; fi
  local mo; mo=$(HOME="$d" bash "$d/aide-verifier.sh" --selftest 2>&1)
  printf '%s\n' "$mo" | grep -qF "FAIL gate lint $3" && pass "$1: selftest case FAILS ($(printf '%s\n' "$mo" | grep -F "FAIL gate lint $3" | head -n1))" || { bad "$1: no FAIL for gate lint $3"; printf '%s\n' "$mo" | grep -E '^(FAIL|selftest:)' | head -n 5; }
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
# vtg1 (ctl fef9 / Fable a798): suite.txt, the pkill hook, the template sentences -- each named selftest case must be present and passing
for c in '(v1)' '(v1b)' '(v2)' '(v3)' '(v4)' '(v5)' '(v6)' '(v6b)' '(v7)' '(v7b)' '(v8)' '(v9)'; do
  printf '%s\n' "$out" | grep -qF "PASS vtg1 $c" && pass "selftest case: vtg1 $c" || bad "selftest case missing or failing: vtg1 $c"
done
# the hook source is wrapped in '...' by write_hook: no single quote may appear inside the HOOK_PY heredoc body
n=$(sed -n '/^read -r -d .. HOOK_PY <<.PY.$/,/^PY$/p' "$script" | sed '1d;$d' | grep -c "'"); [ "$n" = 0 ] && pass "HOOK_PY body has no single quote" || bad "HOOK_PY body has $n single-quote lines"
mutate_v() {  # mutate_v <label> <sed expr> <FAIL pattern after 'FAIL vtg1 '>
  local d; d=$(mktemp -d "$th/mut.XXXXXX"); cp "$script" "$d/aide-verifier.sh"
  sed -i -E "$2" "$d/aide-verifier.sh"
  if cmp -s "$script" "$d/aide-verifier.sh"; then bad "$1: the mutation changed nothing"; return; fi
  local mo; mo=$(HOME="$d" bash "$d/aide-verifier.sh" --selftest 2>&1)
  printf '%s\n' "$mo" | grep -qF "FAIL vtg1 $3" && pass "$1: selftest case FAILS ($(printf '%s\n' "$mo" | grep -F "FAIL vtg1 $3" | head -n1 | cut -c1-120))" || { bad "$1: no FAIL for vtg1 $3"; printf '%s\n' "$mo" | grep -E '^(FAIL|selftest:)' | head -n 5; }
}
mutate_v "mv1 launch stops writing suite.txt" 's/^( *)printf .%s. "\$SUITE" >"\$DIR\/suite.txt" \|\| die 2 .*$/\1:/' '(v1)'
mutate_v "mv2 launch line drops --settings/--disallowedTools" 's/ --settings "\$D\/settings.json" --disallowedTools %q %q --/ --/; s/"\$claude" .Bash\(pkill:\*\). .Bash\(killall:\*\).$/"$claude"/' '(v2)'
mutate_v "mv3 hook stops refusing pkill/killall" 's/\(pkill\|killall\)\(\[\^A-Za-z0-9_\]\|\$\)", cmd\)/(pkillx|killallx)([^A-Za-z0-9_]|$)", cmd)/' '(v4)'
mutate_v "mv4 hook stops refusing kill -9 -1 (group target)" 's/if t.startswith\("-"\) or t.startswith\("%"\) or t == "0":/if False:/' '(v4)'
mutate_v "mv5 hook stops protecting meta/suite.txt" 's/^NAMES = r"\/\(meta\|suite/NAMES = r"\/(metax|suitex/' '(v6)'
mutate_v "mv6 template drops the no-replay sentence" 's/^   The merge gate admits only the one attached log whose CMD equals.*$/   (removed)/' '(v9)'
mutate_v "mv7 prompt drops the pkill HARD CONSTRAINT" 's/^- NEVER pkill\/killall by pattern .*$/- (removed)/' '(v8)'
grep -qF '^[[:space:]]*(co-authored-by:|generated with)' "$script" && pass "script carries the anchored attribution regex" || bad "anchored attribution regex missing"
grep -q 'merge-gate' "$script" && pass "script calls merge-gate" || bad "merge-gate missing"
grep -qF -- '--agent {{AGENT}} --via verifier --model sonnet --kind verdict --gates' "$script" && pass "prompt template records the verdict row shape" || bad "verdict row shape missing"
[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
