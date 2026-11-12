#!/bin/bash
# A1577 source durability: the tracked lib files equal the reviewed pin, and the reviewed controls run against them.
set -u; root=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
trap 'rm -rf "$T"' EXIT
(cd "$root/.local/lib" && sha256sum -c a1577.SHA256SUMS >/dev/null) && echo "OK pin" || { echo "WRONG pin"; bad=1; }
(cd "$root/tests/a1577" && sha256sum -c SHA256SUMS >/dev/null) && echo "OK tests manifest" || { echo "WRONG tests manifest"; bad=1; }
cp "$root"/tests/a1577/* "$T"/; cp "$root/.local/bin/ctl-relaunch.sh" "$T/ctl-relaunch.cand2.sh"; cp "$root/.local/lib/a1577_produce.py" "$T/a1577_produce.py"; cp "$root/.local/lib/a1577-succ.py" "$T/succ_v5.py"
cp "$root/.local/bin/ctl-account-follow.sh" "$T/ctl-account-follow.cand.sh"; # governed launcher: pinned bytes; the only delta to the installed ~/.local/bin/ctl-relaunch.sh (83e9e5f0) is the A1300 model-policy lookup (adoption by install is a separate reviewed step; DRIFT is reported, never overwritten)
gsha=$(sha256sum "$root/.local/bin/ctl-relaunch.sh" | cut -d' ' -f1)
[ "$gsha" = bc7c48919847d28d7f436c3a5a5ace89872b27ec3a608d89333240a8b901738b ] && echo "OK governed launcher pin" || { echo "WRONG governed launcher pin $gsha"; bad=1; }
python3 - "$root/.local/bin/ctl-relaunch.sh" <<'PY' >"$T/gov-as-live" || { echo "WRONG governed launcher lookup block"; bad=1; }
import sys
s=open(sys.argv[1]).read()
new='for _pl in "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/ctl-model-policy.sh" "$HOME/.local/lib/ctl-model-policy.sh"; do [ -r "$_pl" ] && break; done\n. "$_pl" || exit 64\n'
assert s.count(new)==1
sys.stdout.write(s.replace(new,'. "$HOME/.local/lib/ctl-model-policy.sh" || exit 64\n'))
PY
[ "$(sha256sum <"$T/gov-as-live" | cut -c1-16)" = 83e9e5f043407add ] && echo "OK governed launcher = reviewed candidate 83e9e5f0 plus the A1300 lookup block only" || { echo "WRONG governed launcher differs from the reviewed candidate beyond the lookup block"; bad=1; }
inst=$(sha256sum "$HOME/.local/bin/ctl-relaunch.sh" 2>/dev/null | cut -c1-8); echo "INFO installed launcher ${inst:-absent} (reviewed candidate 83e9e5f0; governed $(echo $gsha | cut -c1-8)); drift is reported, not an error"
for pair in layout_test.sh:A1577-LAYOUT-CONTROLS-PASS void_test.sh:A1577-VOID-CONTROLS-PASS inv_eq_test.sh:A1577-INV-EQ-CONTROLS-PASS wiring_run_test.sh:A1577-WIRING-RUN-CONTROLS-PASS; do
  t=${pair%%:*}; m=${pair##*:}
  bash "$T/$t" >"$T/$t.out" 2>&1; rc=$?
  if [ $rc = 0 ] && grep -qx "$m" "$T/$t.out" && ! grep -q '^WRONG' "$T/$t.out"; then echo "OK $t"; else echo "WRONG $t (rc=$rc, marker $m)"; tail -3 "$T/$t.out"; bad=1; fi
done
exit $bad
