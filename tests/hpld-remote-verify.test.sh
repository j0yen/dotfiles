#!/usr/bin/env bash
# tests/hpld-remote-verify.test.sh: hermetic cases for .local/bin/hpld-remote-verify.sh with git, systemd-run and wm-verify-run stubbed. Run: bash tests/hpld-remote-verify.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd); RV="$here/../.local/bin/hpld-remote-verify.sh"
fail=0; pass() { echo "PASS: $1"; }; bad() { echo "FAIL: $1"; fail=1; }
chk() { if [ "$2" = 0 ]; then pass "$1"; else bad "$1"; fi; }
S=$(printf 'a%.0s' $(seq 40)); O=$(printf 'b%.0s' $(seq 40)); REPO=j0yen/synthorg
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/bin"
cat >"$T/bin/git" <<'E'
#!/usr/bin/env bash
echo "git $*" >>"$T/git.log"
[ "$1" = init ] && { mkdir -p "$3"; exit 0; }
[ "$1" = -C ] && shift 2
case "$1" in rev-parse) [ "${2:-}" = FETCH_HEAD ] && echo "$FAKE_REF" || echo "$FAKE_HEAD" ;; status) [ -z "${FAKE_DIRTY:-}" ] || echo " M x" ;; esac
exit 0
E
cat >"$T/bin/sdrun" <<'E'
#!/usr/bin/env bash
echo "sdrun $*" >>"$T/sd.log"
[ -z "${SD_EXEC:-}" ] || { while [ "${1:-}" != "$HPLD_SELF" ] && [ $# -gt 0 ]; do shift; done; "$@"; }
E
cat >"$T/bin/wmv" <<'E'
#!/usr/bin/env bash
echo "suite ran: $1"; echo "WM-VERIFY EXIT=${FAKE_RC:-0}"; exit "${FAKE_RC:-0}"
E
chmod +x "$T"/bin/*
export T HPLD_SELF="$(readlink -f "$RV")" HPLD_GIT="$T/bin/git" HPLD_SYSTEMD_RUN="$T/bin/sdrun" HPLD_WM_VERIFY_RUN="$T/bin/wmv" \
  HPLD_SUITE_WT="$T/wt" HPLD_SUITE_TMP="$T/tmp" HPLD_SUITE_LOGS="$T/logs" HPLD_SUITE_MEMMAX=3G
export FAKE_REF="$S" FAKE_HEAD="$S"
U="hpld-verify-synthorg-7-${S:0:12}"

out=$(bash "$RV" $REPO 7 "$S" --suite 'uv run pytest -q' 2>&1); rc=$?
[ $rc = 0 ] && [[ "$out" == *"UNIT=$U"* ]] && [[ "$out" == *"LOG=$T/logs/$U.log"* ]]; chk "starts: exit 0, unit name carries repo-pr-sha12, log path derived from it" $?
grep -q -- "sdrun --user --unit=$U -p MemoryMax=3G" "$T/sd.log" && grep -q -- "--setenv=TMPDIR=$T/tmp" "$T/sd.log"; chk "systemd-run: --user, unit=hpld-verify-..., MemoryMax, TMPDIR off tmpfs" $?
grep -q "fetch -q https://github.com/$REPO.git refs/pull/7/head" "$T/git.log" && grep -q "checkout -q --detach $S" "$T/git.log"; chk "fetches the pull ref and checks out the exact sha, detached" $?
[ "$(grep -c '^sdrun' "$T/sd.log")" = 1 ]; chk "exactly one unit started" $?

: >"$T/sd.log"; rm -rf "$T/wt"; FAKE_REF="$O" bash "$RV" $REPO 8 "$S" >/dev/null 2>"$T/err"; rc=$?
[ $rc = 4 ] && [ ! -s "$T/sd.log" ] && grep -q "not $S" "$T/err"; chk "pull ref != sha -> exit 4, no unit started" $?

mkdir -p "$T/logs"; : >"$T/logs/hpld-verify-synthorg-9-${S:0:12}.log"; : >"$T/sd.log"
bash "$RV" $REPO 9 "$S" >/dev/null 2>&1; rc=$?
[ $rc = 3 ] && [ ! -s "$T/sd.log" ]; chk "existing log path -> refused (exit 3), no unit started" $?

bash "$RV" $REPO x "$S" >/dev/null 2>&1; [ $? = 2 ]; chk "bad pr -> exit 2" $?
bash "$RV" $REPO 7 "${S:0:12}" >/dev/null 2>&1; [ $? = 2 ]; chk "short sha -> exit 2" $?

# exec mode: the log is written once, header first
rm -rf "$T/wt" "$T/logs"; export SD_EXEC=1 FAKE_RC=1 FAKE_DIRTY=1 FAKE_HEAD="$S"
bash "$RV" $REPO 10 "$S" --suite 'the suite' >/dev/null 2>&1; rc=$?
L="$T/logs/hpld-verify-synthorg-10-${S:0:12}.log"
[ $rc = 0 ] && head -1 "$L" | grep -qE "^HPLD-VERIFY COMMIT=$S HEAD=$S DIRTY=1 EXIT=1 HOST=.+"; chk "log header carries COMMIT HEAD DIRTY EXIT HOST (dirty tree, rc 1)" $?
grep -q '^suite ran: the suite$' "$L" && grep -q '^WM-VERIFY EXIT=1$' "$L"; chk "log body is the wm-verify-run output" $?
[ -z "$(ls "$T/tmp" | grep -v '^$' | grep -vE 'hpld-body')" ] && [ ! -d "$T/wt/hpld-verify-synthorg-10-${S:0:12}" ]; chk "worktree removed after the run" $?
exit $fail
