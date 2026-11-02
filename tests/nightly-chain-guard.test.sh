#!/usr/bin/env bash
# tests/nightly-chain-guard.test.sh: nightly-chain.sh refuses (exit 78) when
# SYNTHORG_CHAIN_LINK_MAX_USD_EXPLORE is unset, empty, a comment, zero or non-numeric,
# and passes the guard when it is a positive number. uv and wm-build are stubs; HOME is a
# throwaway. Run: bash tests/nightly-chain-guard.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
S="$here/../.local/bin/nightly-chain.sh"
BASE=$(mktemp -d "${TMPDIR:-/tmp}/nightly-chain-guard.XXXXXX") || exit 2
trap 'rm -rf -- "${BASE:?}"' EXIT
mkdir -p "$BASE/home/repos/synthorg" "$BASE/home/.local/bin"
cat > "$BASE/home/.local/bin/uv" <<'EOS'
#!/bin/bash
echo "uv $*" >> "$HOME/uv.calls"; exit 0
EOS
chmod +x "$BASE/home/.local/bin/uv"
fail=0
run() { # name expected_rc value|UNSET
  local name=$1 want=$2 val=$3 rc
  : > "$BASE/home/uv.calls"
  if [ "$val" = UNSET ]; then
    env -u SYNTHORG_CHAIN_LINK_MAX_USD_EXPLORE HOME="$BASE/home" bash "$S" >/dev/null 2>&1; rc=$?
  else
    SYNTHORG_CHAIN_LINK_MAX_USD_EXPLORE="$val" HOME="$BASE/home" bash "$S" >/dev/null 2>&1; rc=$?
  fi
  if [ "$rc" = "$want" ]; then echo "PASS: $name rc=$rc"; else echo "FAIL: $name rc=$rc want $want"; fail=$((fail+1)); fi
  if [ "$want" = 78 ] && [ -s "$BASE/home/uv.calls" ]; then echo "FAIL: $name ran a link"; fail=$((fail+1)); fi
}
run unset 78 UNSET
run empty 78 ""
run comment-value 78 "  # set me"
run zero 78 "0"
run word 78 "abc"
run negative 78 "-5"
run ok-int 0 "5"
run ok-decimal 0 "2.50"
run ok-trailing-comment 0 "5  # cap"
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "$fail FAILED"; exit 1; }
