#!/usr/bin/env bash
# W4 runner hardening: service-state unit must start alphanumeric (no option injection, `--` before the unit); named-test has no built-in kill timer
# (hang guard = explicit owner-set OBL_RUN_TIMEOUT_SEC, default none; Joe 11-01 #195). Sandbox: temp dirs and a stub systemctl, no live write.
set -u
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"; R="$here/.local/bin/ctl-obligation-run.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; p=0; f=0
ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1 (got [$2] want [$3])"; fi; }
mkdir -p "$T/tests" "$T/bin"
printf '#!/bin/sh\necho "$@" > %s/argv\nexit 0\n' "$T" > "$T/bin/systemctl"; chmod +x "$T/bin/systemctl"
run(){ env PATH="$T/bin:$PATH" OBL_TESTS_DIR="$T/tests" "${@:3}" python3 -I "$R" run --dir "$T/d" --key "$1" --approval '#1' --action "$2"; }
rec(){ python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["status"],r["rc"])' "$T/d/$1.run.json"; }
run k1 '{"verb":"service-state","unit":"-Hevil@host.invalid.service"}'
ck "leading '-' unit refused rc 126" "$(rec k1)" "refused 126"
ck "leading '-' unit never reached systemctl" "$([ -e "$T/argv" ] && echo ran || echo clean)" clean
run k2 '{"verb":"service-state","unit":"ctl-event-bridge.service"}'
ck "good unit runs" "$(rec k2)" "ran 0"
ck "argv carries -- before the unit" "$(cat "$T/argv")" "--user is-active -- ctl-event-bridge.service"
printf '#!/bin/sh\nsleep 3\nexit 0\n' > "$T/tests/slow.test.sh"
run k3 '{"verb":"named-test","name":"slow"}'
ck "named-test with no owner-set guard runs to completion" "$(rec k3)" "ran 0"
run k4 '{"verb":"named-test","name":"slow"}' OBL_RUN_TIMEOUT_SEC=1
ck "owner-set OBL_RUN_TIMEOUT_SEC=1 is honoured (rc 124)" "$(rec k4)" "ran 124"
ck "no hard-coded 600 s kill in the runner" "$(grep -c 'timeout=600' "$R")" 0
rm -f "$T/argv"
run k5 '{"verb":"service-state","unit":"x.service\n"}'
ck "unit with trailing newline refused rc 126" "$(rec k5)" "refused 126"
ck "trailing-newline unit never reached systemctl" "$([ -e "$T/argv" ] && echo ran || echo clean)" clean
printf '#!/bin/sh\necho ran > %s/nl-ran\nexit 0\n' "$T" > "$T/tests/nl.test.sh"; cp "$T/tests/nl.test.sh" "$T/tests/"$'nl\n'".test.sh"
run k6 '{"verb":"named-test","name":"nl\n"}'
ck "name with trailing newline refused rc 126" "$(rec k6)" "refused 126"
ck "trailing-newline name never ran" "$([ -e "$T/nl-ran" ] && echo ran || echo clean)" clean
echo "pass=$p fail=$f"; [ "$f" = 0 ]
