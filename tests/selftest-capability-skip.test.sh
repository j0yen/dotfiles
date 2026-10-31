#!/usr/bin/env bash
# selftest-capability-skip: with PATH shims systemctl/systemd-run that exit 1 (no user bus), the four bus-dependent tests print
# `SKIP <test>: ...` and exit 77, and tests/run.sh counts them under skip= (never as pass or fail). The shims also guarantee no test
# body runs: the probe is the first executable block, so nothing touches a real bus or ssh.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/cap-skip.XXXXXX") || exit 2
trap 'case "$T" in */cap-skip.*) rm -rf -- "$T";; esac' EXIT
mkdir -p "$T/shim" "$T/home"
for c in systemctl systemd-run ssh; do printf '#!/bin/bash\necho "$0 $*" >> "%s/shim.log"\nexit 1\n' "$T" > "$T/shim/$c"; chmod +x "$T/shim/$c"; done
four=(aide-inbox seat-event-lanes seat-time-stamp vibeloop-ctl-claim)
files=(); for t in "${four[@]}"; do files+=("$here/$t.test.sh"); done

out=$(PATH="$T/shim:$PATH" HOME=$T/home bash "$here/run.sh" "${files[@]}" 2>&1); rc=$?
last=$(printf '%s\n' "$out" | tail -n 1)
[ "$last" = "GLOB main n=4 fail=0 skip=4" ] && [ "$rc" = 0 ] && ok "runner: $last (rc=$rc)" || bad "runner rc=$rc last='$last'"
for t in "${four[@]}"; do
  printf '%s\n' "$out" | grep -q "^SKIP $t.test.sh: no systemd user bus (probe 'systemctl --user show-environment' rc=1)" && ok "SKIP line for $t" || bad "no SKIP line for $t"
done
[ "$(grep -c . "$T/shim.log")" = 4 ] && ! grep -q '^'"$T"'/shim/ssh' "$T/shim.log" && ok "only the 4 first-probe calls ran; no ssh" || bad "shim log: $(tr '\n' '|' < "$T/shim.log")"

# a pass is still a pass and a real failure is still a failure
printf '#!/bin/bash\nexit 0\n' > "$T/p.test.sh"; printf '#!/bin/bash\nexit 5\n' > "$T/f.test.sh"
l=$(bash "$here/run.sh" "$T/p.test.sh" "$T/f.test.sh" 2>&1 | tail -n 1)
[ "$l" = "GLOB main n=2 fail=1 skip=0" ] && ok "pass/fail counting unchanged ($l)" || bad "counting: $l"
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
