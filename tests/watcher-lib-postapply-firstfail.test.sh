#!/usr/bin/env bash
# watcher-lib-postapply-firstfail: a failing consumer --selftest names itself on stderr (consumer=, rc=, first_fail=) before the script
# exits; post_rc stays 1. Fixture consumers only, all under a mktemp -d root with WPA_* overrides; nothing under the real HOME is read or written.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
S=$here/../.local/bin/watcher-lib-postapply.sh
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/wpa-firstfail.XXXXXX") || exit 2
trap 'case "$T" in */wpa-firstfail.*) rm -rf -- "$T";; esac' EXIT
mkdir -p "$T/bin"
printf 'wp_arm() { :; }; wp_gate() { :; }; wp_emit_write() { :; }; wp_selftest() { :; }\n' > "$T/lib.sh"
printf '#!/bin/bash\nsource /x/watcher-premise.sh\nif [ "${1:-}" = "--selftest" ]; then echo "x FAIL y"; echo "later FAIL z"; exit 3; fi\n' > "$T/bin/fx-fail.sh"
printf '#!/bin/bash\nsource /x/watcher-premise.sh\nif [ "${1:-}" = "--selftest" ]; then exit 4; fi\n' > "$T/bin/fx-silent.sh"
printf '#!/bin/bash\nsource /x/watcher-premise.sh\nif [ "${1:-}" = "--selftest" ]; then exit 0; fi\n' > "$T/bin/fx-ok.sh"
chmod +x "$T/bin/"*
run() { WPA_LIB=$T/lib.sh WPA_BIN=$T/bin WPA_OUT=$T/state/_lib.json WPA_TIMEOUT=10 HOME=$T/home bash "$S" 2>"$T/err"; echo $?; }
rc=$(run)
[ "$rc" = 1 ] && ok "post_rc stays 1 with failing consumers" || bad "rc=$rc"
grep -qx 'POSTAPPLY SELFTEST FAIL consumer=fx-fail.sh rc=3 first_fail=x FAIL y' "$T/err" && ok "line names consumer, rc=3, first FAIL line" || bad "fx-fail line: $(grep POSTAPPLY "$T/err")"
grep -qx 'POSTAPPLY SELFTEST FAIL consumer=fx-silent.sh rc=4 first_fail=<none>' "$T/err" && ok "no FAIL output -> first_fail=<none>" || bad "fx-silent line: $(grep POSTAPPLY "$T/err")"
! grep -q 'consumer=fx-ok.sh' "$T/err" && grep -q '^consumer fx-ok.sh: ok' "$T/err" && ok "passing consumer unchanged" || bad "fx-ok"
[ "$(jq -r '.selftests["fx-fail.sh"]' "$T/state/_lib.json")" = fail ] && ok "JSON record still says fail" || bad "json"
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
