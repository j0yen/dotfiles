#!/usr/bin/env bash
# ledger-mirror-rb.test.sh: fake scp/ssh act on local dirs; no real host or ledger is touched (A1467).
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$HERE/.local/bin/ledger-mirror-rb.sh
W=$(mktemp -d "${TMPDIR:-/tmp}/lmrb-test.XXXXXX")
trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
check() { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }

RH=$W/remote-home; BIN=$W/bin; mkdir -p "$BIN"
SD=$RH/.local/state/swarm-decide
cat > "$BIN/scp" <<'S'
#!/usr/bin/env bash
src=${*: -2:1}; dst=${*: -1}
[ -n "${FAKE_SCP_FAIL:-}" ] && exit 1
p=${dst#*:}; p=${p/#\~/$FAKE_RH}
cp "$src" "$p"
[ -n "${FAKE_SCP_TRUNC:-}" ] && truncate -s "$(( $(stat -c %s "$p") / 2 ))" "$p"
exit 0
S
cat > "$BIN/ssh" <<'S'
#!/usr/bin/env bash
cmd=${*: -1}
HOME=$FAKE_RH exec bash -c "$cmd"
S
chmod +x "$BIN/scp" "$BIN/ssh"

SRC=$W/src.sqlite
sqlite3 "$SRC" "create table t(a); with recursive c(x) as (select 1 union all select x+1 from c where x<20000) insert into t select randomblob(50) from c;"
run() { PATH=$BIN:$PATH FAKE_RH=$RH TMPDIR=$W LEDGER_MIRROR_SRC=$SRC LEDGER_MIRROR_HOST=fakehost bash "$SCRIPT" >"$W/out" 2>"$W/err"; }
nolitter() { compgen -G "$SD/*.tmp" >/dev/null && return 1; compgen -G "$W/ledger-mirror*" >/dev/null && return 1; return 0; }

for round in 1 2; do
  rm -rf "$RH"; mkdir -p "$SD"; echo old-mirror > "$SD/decisions-carbon.sqlite"

  run; rc=$?
  check "r$round a: happy exit 0" [ $rc -eq 0 ]
  check "r$round a: quick_check ok" [ "$(sqlite3 -readonly "$SD/decisions-carbon.sqlite" 'pragma quick_check')" = ok ]
  check "r$round a: row count equal" [ "$(sqlite3 "$SD/decisions-carbon.sqlite" 'select count(*) from t')" = "$(sqlite3 "$SRC" 'select count(*) from t')" ]
  check "r$round a: no tmp either side" nolitter
  check "r$round a: echo line" grep -q '^ledger-mirror-rb: .* bytes (.* zst) -> fakehost:' "$W/out"

  before=$(sha256sum "$SD/decisions-carbon.sqlite")
  FAKE_SCP_TRUNC=1 run; rc=$?
  check "r$round b: corrupt transfer nonzero" [ $rc -ne 0 ]
  check "r$round b: old mirror unchanged" [ "$(sha256sum "$SD/decisions-carbon.sqlite")" = "$before" ]
  check "r$round b: no tmp left" nolitter

  FAKE_SCP_FAIL=1 run; rc=$?
  check "r$round c: scp failure nonzero" [ $rc -ne 0 ]
  check "r$round c: old mirror unchanged" [ "$(sha256sum "$SD/decisions-carbon.sqlite")" = "$before" ]
  check "r$round c: no tmp left" nolitter
done
echo "passed=$pass failed=$fail"
[ $fail -eq 0 ]
