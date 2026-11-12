#!/bin/bash
# A1577 source durability: the tracked lib files equal the reviewed pin, and the reviewed controls run against them.
set -u; root=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
trap 'rm -rf "$T"' EXIT
(cd "$root/.local/lib" && sha256sum -c a1577.SHA256SUMS >/dev/null) && echo "OK pin" || { echo "WRONG pin"; bad=1; }
(cd "$root/tests/a1577" && sha256sum -c SHA256SUMS >/dev/null) && echo "OK tests manifest" || { echo "WRONG tests manifest"; bad=1; }
cp "$root"/tests/a1577/* "$T"/; cp "$root/.local/lib/a1577_produce.py" "$T/a1577_produce.py"; cp "$root/.local/lib/a1577-succ.py" "$T/succ_v5.py"
cp "$root/.local/bin/ctl-account-follow.sh" "$T/ctl-account-follow.cand.sh"; for pair in layout_test.sh:A1577-LAYOUT-CONTROLS-PASS void_test.sh:A1577-VOID-CONTROLS-PASS inv_eq_test.sh:A1577-INV-EQ-CONTROLS-PASS wiring_run_test.sh:A1577-WIRING-RUN-CONTROLS-PASS; do
  t=${pair%%:*}; m=${pair##*:}
  bash "$T/$t" >"$T/$t.out" 2>&1; rc=$?
  if [ $rc = 0 ] && grep -qx "$m" "$T/$t.out" && ! grep -q '^WRONG' "$T/$t.out"; then echo "OK $t"; else echo "WRONG $t (rc=$rc, marker $m)"; tail -3 "$T/$t.out"; bad=1; fi
done
exit $bad
