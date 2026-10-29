#!/usr/bin/env bash
# tests/hpld-fetch-verify.test.sh: hermetic cases for .local/bin/hpld-fetch-verify.sh and the verifier guard's ssh denial, with ssh/scp stubbed (never a real host).
# Run: bash tests/hpld-fetch-verify.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd); FV="$here/../.local/bin/hpld-fetch-verify.sh"; GUARD="$here/../.local/bin/verifier-kill-guard.sh"
fail=0; pass() { echo "PASS: $1"; }; bad() { echo "FAIL: $1"; fail=1; }
chk() { if [ "$2" = 0 ]; then pass "$1"; else bad "$1"; fi; }
S=$(printf 'a%.0s' $(seq 40)); O=$(printf 'b%.0s' $(seq 40)); REPO=j0yen/synthorg
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/bin" "$T/out"
U="hpld-verify-synthorg-7-${S:0:12}"; RLOG="/mnt/data/hpld/logs/$U.log"
cat >"$T/bin/ssh" <<'E'
#!/usr/bin/env bash
echo "ssh $*" >>"$T/ssh.log"
[ "${FAKE_SSH_RC:-0}" = 0 ] || exit "$FAKE_SSH_RC"
case "$*" in *" test -f "*) exit "${FAKE_TEST_RC:-0}" ;; esac
echo "UNIT=$U"; echo "LOG=$RLOG"; exit "${FAKE_START_RC:-0}"
E
cat >"$T/bin/scp" <<'E'
#!/usr/bin/env bash
echo "scp $*" >>"$T/scp.log"; cp "$T/remote.log" "${@: -1}"
E
cat >"$T/bin/wm-decide" <<'E'
#!/usr/bin/env bash
echo "wm-decide $*" >>"$T/wmd.log"
E
chmod +x "$T"/bin/*
export T U RLOG HPLD_SSH="$T/bin/ssh" HPLD_SCP="$T/bin/scp" AIDE_VERIFIER_SUITE_HOST=ryzen7 HPLD_FETCH_POLL_S=0 HPLD_FETCH_TIMEOUT_S=1 HPLD_HOSTNAME_CMD="echo carbon-box" PATH="$T/bin:$PATH"
hdr() { printf 'HPLD-VERIFY COMMIT=%s HEAD=%s DIRTY=%s EXIT=%s HOST=ryzen7\nWM-VERIFY EXIT=%s\n' "$1" "$2" "$3" "$4" "$4" >"$T/remote.log"; }
run() { : >"$T/ssh.log"; : >"$T/scp.log"; rm -f "$T"/out/*; bash "$FV" $REPO 7 "$S" --out "$T/out" "$@" >"$T/stdout" 2>"$T/stderr"; }

hdr "$S" "$S" 0 0; run --suite 'uv run pytest -q'; rc=$?
[ $rc = 0 ] && grep -q "^LOG: $T/out/$U.log$" "$T/stdout" && grep -q '^EXIT: 0$' "$T/stdout" && cmp -s "$T/remote.log" "$T/out/$U.log"; chk "good log: exit 0, byte-identical copy in the out dir, EXIT printed" $?
head -1 "$T/ssh.log" | grep -q -- "-o BatchMode=yes ryzen7 .local/bin/hpld-remote-verify.sh $REPO 7 $S --suite uv run pytest -q"; chk "ssh stub saw -o BatchMode=yes and the runner argv with the full sha (whose first 12 hex name the unit)" $?

hdr "$S" "$S" 0 1; run; rc=$?
[ $rc = 0 ] && grep -q '^EXIT: 1$' "$T/stdout"; chk "suite EXIT=1 inside a good-provenance log: exit 0, EXIT: 1 reported (the verdict stays in the log)" $?

FAKE_SSH_RC=255 run; rc=$?
[ $rc = 6 ] && [ "$(grep -c '^ssh' "$T/ssh.log")" = 2 ] && [ -z "$(ls "$T/out")" ] && [ ! -e "$T/wmd.log" ]; chk "ssh 255 twice: exit 6, retried exactly once, no log, no wm-decide row" $?
grep -q UNVERIFIED "$T/stderr"; chk "255 is reported UNVERIFIED, not a failure" $?

hdr "$O" "$S" 0 0; run; rc=$?
[ $rc = 5 ] && [ -z "$(ls "$T/out")" ]; chk "COMMIT != sha: exit 5, nothing placed" $?
hdr "$S" "$O" 0 0; run; [ $? = 5 ]; chk "HEAD != sha: exit 5" $?
hdr "$S" "$S" 1 0; run; [ $? = 5 ]; chk "DIRTY=1: exit 5" $?
printf 'WM-VERIFY EXIT=0\n' >"$T/remote.log"; run; [ $? = 5 ]; chk "no HPLD-VERIFY header: exit 5" $?
hdr "$S" "$S" 0 x; run; [ $? = 5 ]; chk "EXIT not a number: exit 5" $?

hdr "$S" "$S" 0 0; FAKE_START_RC=4 run; [ $? = 5 ]; chk "runner rc 4 (PR head moved): exit 5" $?
FAKE_START_RC=3 run; [ $? = 0 ]; chk "runner rc 3 (already started): polls the same log, exit 0" $?
FAKE_TEST_RC=1 run; [ $? = 6 ]; chk "log never appears: exit 6 after the timeout" $?
: >"$T/out/$U.log"; bash "$FV" $REPO 7 "$S" --out "$T/out" >/dev/null 2>&1; [ $? = 6 ]; chk "existing destination is never overwritten (write-once): exit 6" $?

for h in carbon localhost carbon-box; do
  AIDE_VERIFIER_SUITE_HOST=$h run; rc=$?
  [ $rc = 2 ] && [ ! -s "$T/ssh.log" ]; chk "host=$h: refused (exit 2), no ssh" $?
done
AIDE_VERIFIER_SUITE_HOST= run; rc=$?; [ $rc = 2 ] && [ ! -s "$T/ssh.log" ]; chk "host unset: refused (exit 2), no ssh" $?

g() { printf '{"tool_input":{"command":%s}}' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")" | bash "$GUARD" >/dev/null 2>&1; }
g 'ssh ryzen7 true'; [ $? = 2 ]; chk "guard: ssh denied" $?
g 'cd x && scp ryzen7:/a /b'; [ $? = 2 ]; chk "guard: scp denied" $?
g "bash -c 'ssh ryzen7 id'"; [ $? = 2 ]; chk "guard: ssh inside bash -c denied" $?
g "~/.local/bin/hpld-fetch-verify.sh $REPO 7 $S --out /x --suite 'uv run pytest'"; [ $? = 0 ]; chk "guard: the one script invocation is allowed" $?
g 'echo ssh is a word'; [ $? = 0 ]; chk "guard: text that merely contains ssh is allowed" $?
exit $fail
