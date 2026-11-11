#!/usr/bin/env bash
# A1300: coder per-run credential binding. Isolated temp dir, fake tokens only, no provider call.
set -u; R="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; pass=0; fail=0
ok() { pass=$((pass+1)); }; bad() { fail=$((fail+1)); echo "FAIL $1"; }
run() { env "$@" bash -c ". $R/.local/lib/coder-oauth-bind.sh; coder_oauth_bind"; }
t() { local want=$1 name=$2; shift 2; run "$@" >/dev/null 2>"$T/err"; local rc=$?; [ $rc = "$want" ] && ok || bad "$name rc=$rc want=$want"; }
good="$T/good.env"; printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-FAKEFAKE_fake-1\n' > "$good"; chmod 600 "$good"
t 0 unset-default -u CODER_ACCOUNT -u CODER_OAUTH_ENV
t 3 account-only -u CODER_OAUTH_ENV CODER_ACCOUNT=jyen.pm
t 3 file-only -u CODER_ACCOUNT CODER_OAUTH_ENV="$good"
t 0 valid CODER_ACCOUNT=jyen.pm CODER_OAUTH_ENV="$good"
got="$(env CODER_ACCOUNT=jyen.pm CODER_OAUTH_ENV="$good" CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-HOSTGLOBAL bash -c ". $R/.local/lib/coder-oauth-bind.sh; coder_oauth_bind 2>/dev/null; printf %s \"\$CLAUDE_CODE_OAUTH_TOKEN\"")"
[ "$got" = sk-ant-oat01-FAKEFAKE_fake-1 ] && ok || bad "binding did not replace the host-global token"
v="$(run CODER_ACCOUNT=jyen.pm CODER_OAUTH_ENV="$good" 2>&1)"; case "$v" in *FAKEFAKE*) bad "token printed";; *) ok;; esac
ln -s "$good" "$T/link.env"; t 3 symlink CODER_ACCOUNT=jyen.pm CODER_OAUTH_ENV="$T/link.env"
cp "$good" "$T/wide.env"; chmod 644 "$T/wide.env"; t 3 mode644 CODER_ACCOUNT=jyen.pm CODER_OAUTH_ENV="$T/wide.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-A\nX=1\n' > "$T/two.env"; chmod 600 "$T/two.env"; t 3 two-lines CODER_ACCOUNT=jyen.pm CODER_OAUTH_ENV="$T/two.env"
printf 'FOO=bar\n' > "$T/foo.env"; chmod 600 "$T/foo.env"; t 3 wrong-var CODER_ACCOUNT=jyen.pm CODER_OAUTH_ENV="$T/foo.env"
t 3 relative CODER_ACCOUNT=jyen.pm CODER_OAUTH_ENV=good.env
t 3 bad-account "CODER_ACCOUNT=a b" CODER_OAUTH_ENV="$good"
t 3 missing CODER_ACCOUNT=jyen.pm CODER_OAUTH_ENV="$T/none.env"
# source-failure controls: the wired launcher line itself, extracted, must refuse (rc 3) before a child sentinel when the helper is missing or unreadable
for s in rb-run-coder r7-run-coder; do
  ln="$(grep -F 'coder-oauth-bind.sh"' "$R/.local/bin/$s.sh")"
  for mode in missing unreadable present; do
    H="$T/h-$s-$mode"; mkdir -p "$H/.local/lib"
    [ $mode = missing ] || cp "$R/.local/lib/coder-oauth-bind.sh" "$H/.local/lib/"
    [ $mode = unreadable ] && chmod 000 "$H/.local/lib/coder-oauth-bind.sh"
    out="$(HOME="$H" bash -c "set -euo pipefail; rc=1; $ln
echo CHILD_REACHED" 2>/dev/null)"; rc=$?
    if [ $mode = present ]; then [ $rc = 0 ] && [ "$out" = CHILD_REACHED ] && ok || bad "$s present rc=$rc"
    else [ $rc = 3 ] && [ -z "$out" ] && ok || bad "$s $mode rc=$rc out=$out"; fi
    chmod 600 "$H/.local/lib/coder-oauth-bind.sh" 2>/dev/null
  done
done
for s in rb-run-coder r7-run-coder; do grep -q 'coder_oauth_bind' "$R/.local/bin/$s.sh" && ok || bad "$s not wired"; bash -n "$R/.local/bin/$s.sh" && ok || bad "$s syntax"; done
[ $fail = 0 ] && echo "PASS coder-oauth-bind $pass ok 0 FAIL" || { echo "FAIL $fail of $((pass+fail))"; exit 1; }
