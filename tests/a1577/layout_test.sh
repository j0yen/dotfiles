#!/bin/bash
# R6-b exact install-layout controls: ONLY a1577_produce.py + a1577-succ.py in one lib dir, run under python3 -I as the wiring/launcher do
set -u; D=$(mktemp -d); H=$(mktemp -d); here=$(cd "$(dirname "$0")" && pwd); bad=0
cp "$here/a1577_produce.py" "$D/a1577_produce.py"; cp "$here/succ_v5.py" "$D/a1577-succ.py"
ok(){ if [ "$1" = 0 ]; then echo "OK LAYOUT $2"; else echo "WRONG LAYOUT $2"; bad=1; fi; }
HOME=$H python3 -I "$D/a1577_produce.py" --ask A-NOPE --outdir "$H/o" --inv rl-x 2>"$H/err"; rc=$?
[ "$rc" = 2 ] && ! grep -q "ModuleNotFoundError\|ImportError\|Traceback" "$H/err"; ok $? "producer imports checker from a1577-succ.py and refuses cleanly (rc=$rc: $(head -c 120 "$H/err"))"
HOME=$H python3 -I "$D/a1577-succ.py" 2>"$H/err2"; rc2=$?
! grep -q "ModuleNotFoundError\|ImportError" "$H/err2"; ok $? "checker runs standalone under -I (rc=$rc2)"
HOME=$H python3 -I -c "
import importlib.util,sys
sp=importlib.util.spec_from_file_location('a1577_succ','$D/a1577-succ.py');m=importlib.util.module_from_spec(sp);sp.loader.exec_module(m)
sys.exit(0 if m.live_priors('A-NOPE','rl-x') is None else 1)"; ok $? "installed-name checker live_priors resolves the producer next to it and refuses unknown effect (None)"
[ "$bad" = 0 ] && echo A1577-LAYOUT-CONTROLS-PASS || echo LAYOUT-FAILED
