#!/bin/bash
# A1577 source durability: the tracked lib files equal the reviewed pin, and the reviewed controls run against them.
set -u; root=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
trap 'rm -rf "$T"' EXIT
(cd "$root/.local/lib" && sha256sum -c a1577.SHA256SUMS >/dev/null) && echo "OK pin" || { echo "WRONG pin"; bad=1; }
(cd "$root/tests/a1577" && sha256sum -c SHA256SUMS >/dev/null) && echo "OK tests manifest" || { echo "WRONG tests manifest"; bad=1; }
cp "$root"/tests/a1577/* "$T"/; cp "$root/.local/lib/a1577_produce.py" "$T/a1577_produce.py"; cp "$root/.local/lib/a1577-succ.py" "$T/succ_v5.py"
cp "$root/.local/bin/ctl-account-follow.sh" "$T/ctl-account-follow.cand.sh"; cp "$root/.local/bin/ctl-relaunch.sh" "$T/ctl-relaunch.cand2.sh"
for t in layout_test.sh void_test.sh inv_eq_test.sh wiring_run_test.sh; do bash "$T/$t" >"$T/$t.out" 2>&1 && echo "OK $t" || { echo "WRONG $t"; tail -3 "$T/$t.out"; bad=1; }; done
exit $bad
