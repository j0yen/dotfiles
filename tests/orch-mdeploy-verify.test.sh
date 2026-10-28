#!/usr/bin/env bash
# tests/orch-mdeploy-verify.test.sh: orch-mdeploy-verify.sh refuses bad sha / non-orch host, writes WM-VERIFY trailers with pytest's rc, keeps TMPDIR in the sha dir, never writes the live checkout.
# Stubs uv, git, hostname in a throwaway HOME. Run: bash tests/orch-mdeploy-verify.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd); script="$here/../.local/bin/orch-mdeploy-verify.sh"
fail=0; pass() { echo "PASS: $1"; }; bad() { echo "FAIL: $1"; fail=1; }
th=$(mktemp -d "${TMPDIR:-/tmp}/omv-test.XXXXXX"); trap 'rm -rf "$th"' EXIT
mkdir -p "$th/.local/bin" "$th/repos/mcphost-deploy"
sha=$(printf 'a%.0s' $(seq 40))
cat > "$th/.local/bin/hostname" <<'S'
#!/bin/sh
echo "${STUB_HOST:-orch}"
S
cat > "$th/.local/bin/git" <<'S'
#!/bin/sh
[ "$1" = -C ] && { d=$2; shift 2; }
case "$1" in
  remote) echo "https://example.invalid/mcphost-deploy.git" ;;
  clone) mkdir -p "$4/.git" ;;
  rev-parse) echo "$STUB_SHA" ;;
  status) : ;;
  *) : ;;
esac
exit 0
S
cat > "$th/.local/bin/uv" <<'S'
#!/bin/sh
echo "TMPDIR=$TMPDIR HERMETIC=$MCPHOST_DEPLOY_GATE_HERMETIC ARGS=$*"
exit "$(cat "$HOME/stub-rc" 2>/dev/null || echo 0)"
S
chmod +x "$th"/.local/bin/*
export HOME="$th" STUB_SHA="$sha"
run() { env PATH="$th/.local/bin:/usr/bin:/bin" "$@"; }
before=$(find "$th/repos" -printf '%p %T@\n' | sort)

run bash "$script" nothex >/dev/null 2>&1; [ $? = 2 ] && pass "bad sha refused" || bad "bad sha accepted"
run bash "$script" abc123 >/dev/null 2>&1; [ $? = 2 ] && pass "short sha refused" || bad "short sha accepted"
STUB_HOST=ryzen7 run bash "$script" "$sha" >/dev/null 2>&1; [ $? = 2 ] && pass "non-orch host refused" || bad "non-orch host ran"

for rc in 0 1; do
  rm -rf "$th/.cache"
  echo "$rc" > "$th/stub-rc"
  out=$(ORCH_MDV_ALLOW_HOST=1 STUB_HOST=ryzen7 run bash "$script" "$sha" 2>&1); got=$?
  log="$th/.cache/mdeploy-verify/$sha/verify.log"
  [ "$got" = "$rc" ] && pass "exit code $rc propagated" || bad "exit $got, wanted $rc"
  grep -qx "WM-VERIFY EXIT=$rc" "$log" && pass "EXIT trailer = $rc" || bad "EXIT trailer wrong for $rc"
  for t in HOST= HEAD="$sha" DIRTY=0; do grep -q "^WM-VERIFY $t" "$log" && pass "trailer $t" || bad "trailer $t missing"; done
  printf '%s\n' "$out" | grep -q '^sha256: ' && pass "sha256 printed" || bad "sha256 not printed"
done
grep -q "^TMPDIR=$th/.cache/mdeploy-verify/$sha/tmp " "$log" && pass "TMPDIR inside the sha dir" || bad "TMPDIR outside the sha dir"
grep -q 'HERMETIC=1' "$log" && pass "gate hermetic flag set" || bad "hermetic flag missing"
cmdline=$(grep '^WM-VERIFY CMD=' "$log")
[ "$(printf '%s' "$cmdline" | grep -o 'not live and not slow and not www_pin' | wc -l)" = 1 ] && pass "CMD has the marker expression once" || bad "marker expression count wrong"
printf '%s' "$cmdline" | grep -q -- '--locked' && pass "CMD has --locked" || bad "CMD lacks --locked"
after=$(find "$th/repos" -printf '%p %T@\n' | sort)
[ "$before" = "$after" ] && pass "live mcphost-deploy dir untouched" || bad "live mcphost-deploy dir changed"
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILED"; exit 1; }
