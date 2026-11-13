#!/usr/bin/env bash
# reap.test.sh - reap.sh (A239): own mktemp tree, stub systemctl/logger/git; never touches real paths.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
reap=$here/../.local/bin/reap.sh
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
base=$(mktemp -d "${TMPDIR:-/tmp}/reap-test.XXXXXX") || exit 1
trap 'rm -rf "$base"' EXIT
mkdir -p "$base/bin" "$base/old" "$base/big" "$base/state"
for s in systemctl logger git; do :; done
cat > "$base/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$2" in
  list-units) printf 'old.service failed failed x\nnew.service failed failed x\n';;
  show) [ "$5" = old.service ] && echo "StateChangeTimestamp=Mon 2020-01-01 00:00:00 UTC" || echo "StateChangeTimestamp=$(date '+%a %Y-%m-%d %H:%M:%S %Z')";;
esac
STUB
cat > "$base/bin/logger" <<'STUB'
#!/usr/bin/env bash
shift 2; echo "$*" >> "$STUB_JOURNAL"
STUB
cat > "$base/bin/git" <<'STUB'
#!/usr/bin/env bash
echo "git $*" >> "$STUB_LOG"
STUB
chmod +x "$base"/bin/*
export STUB_LOG=$base/calls STUB_JOURNAL=$base/journal
# old entry (mtime 10 days back) and fresh entry
mkdir "$base/old/stale" "$base/old/fresh"; touch -d '10 days ago' "$base/old/stale"
dd if=/dev/zero of="$base/big/fresh.bin" bs=1M count=3 2>/dev/null
cat > "$base/ret.json" <<EOF2
{"entries":[
 {"id":"t-old","kind":"dir-age","path":"$base/old","age_h":24,"cap_mb":100,"hosts":["h1"]},
 {"id":"t-big","kind":"dir-age","path":"$base/big","age_h":24,"cap_mb":1,"hosts":["h1"]},
 {"id":"t-root","kind":"dir-age","path":"/","age_h":1,"cap_mb":1,"hosts":["h1"]},
 {"id":"t-fail","kind":"failed-units","age_h":24,"hosts":["h1"]},
 {"id":"t-wt","kind":"worktree-prune","repos":["$base/old"],"hosts":["h1"]},
 {"id":"t-other","kind":"dir-age","path":"$base/old","age_h":1,"cap_mb":1,"hosts":["h2"]}
]}
EOF2
export PATH=$base/bin:$PATH
REAP_RETENTION=$base/ret.json REAP_HOST=h1 REAP_STATE_DIR=$base/state bash "$reap" >"$base/out" 2>&1; rc=$?
[ ! -e "$base/old/stale" ] && [ -d "$base/old/fresh" ] && pass "stale child reaped, fresh kept" || bad "age reap"
grep -q 'entry=t-old host=h1 reaped=1' "$base/journal" && pass "reaped=1 receipt" || bad "receipt t-old"
grep -q 'entry=t-big .*reaped=0 .*ALARM=over-cap-reaped-0' "$base/journal" && [ -f "$base/state/alarm-t-big" ] && pass "alarm on over cap with reaped=0" || bad "alarm"
grep -q 'entry=t-root .*error=unsafe-path' "$base/journal" && pass "root path refused" || bad "unsafe path"
grep -q 'entry=t-fail host=h1 reaped=1' "$base/journal" && grep -q 'reset-failed old.service' "$base/calls" && ! grep -q 'reset-failed new.service' "$base/calls" && pass "only old failed unit reset" || bad "failed-units"
grep -q 'git -C .* worktree prune' "$base/calls" && grep -q 'entry=t-wt' "$base/journal" && pass "worktree prune run" || bad "worktree"
! grep -q 't-other' "$base/journal" && pass "other-host entry skipped" || bad "host filter"
[ "$rc" = 2 ] && pass "exit 2 when alarmed" || bad "rc=$rc"
# dry run deletes nothing
mkdir "$base/old/stale2"; touch -d '10 days ago' "$base/old/stale2"
REAP_DRY_RUN=1 REAP_RETENTION=$base/ret.json REAP_HOST=h1 REAP_STATE_DIR=$base/state bash "$reap" >/dev/null 2>&1
[ -d "$base/old/stale2" ] && pass "dry run keeps files" || bad "dry run"
# exclude globs keep old claude-* dirs, reap other old dirs; --dry-run lists and removes nothing
mkdir -p "$base/ex"; mkdir "$base/ex/claude-1000" "$base/ex/other"; touch -d '10 days ago' "$base/ex/claude-1000" "$base/ex/other"
cat > "$base/ex.json" <<EOF2
{"entries":[{"id":"t-ex","kind":"dir-age","path":"$base/ex","age_h":24,"cap_mb":100,"exclude":["claude-*"],"hosts":["h1"]}]}
EOF2
: > "$base/journal"
REAP_RETENTION=$base/ex.json REAP_HOST=h1 REAP_STATE_DIR=$base/state bash "$reap" --dry-run >"$base/dry.out" 2>&1
[ -d "$base/ex/other" ] && [ -d "$base/ex/claude-1000" ] && grep -q 'would-remove=.*/other' "$base/dry.out" && ! grep -q 'would-remove=.*claude' "$base/dry.out" && grep -q 'entry=t-ex host=h1 reaped=1 excluded=1 .*dry_run=1' "$base/journal" && pass "--dry-run lists, removes nothing, dry_run=1 receipt" || bad "--dry-run flag"
: > "$base/journal"
REAP_RETENTION=$base/ex.json REAP_HOST=h1 REAP_STATE_DIR=$base/state bash "$reap" >/dev/null 2>&1
[ ! -e "$base/ex/other" ] && [ -d "$base/ex/claude-1000" ] && grep -q 'entry=t-ex host=h1 reaped=1 excluded=1' "$base/journal" && ! grep -q dry_run "$base/journal" && pass "exclude glob keeps old claude-x, reaps other" || bad "exclude"
grep -q '"exclude": \["claude-\*"\]' "$here/../.config/fleet/gen/retention.json" && pass "cache-tmp excludes claude-*" || bad "cache-tmp exclude"
# shipped contract parses and units exist
python3 -I -c "import json,sys;d=json.load(open(sys.argv[1]));assert all('id' in e and 'kind' in e and e['hosts'] for e in d['entries'])" "$here/../.config/fleet/gen/retention.json" && pass "retention.json valid" || bad "retention.json"
[ -f "$here/../.config/systemd/user/reap.timer" ] && grep -q 'reap.sh' "$here/../.config/systemd/user/reap.service" && pass "unit pair" || bad "units"
exit $fail
