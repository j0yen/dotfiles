#!/usr/bin/env bash
# wchg-reap.test.sh - wchg-reap (stub watchman on PATH, own mktemp HOME + XDG_CACHE_HOME; never the real watchman)
# plus the wchg-scope-check.sh skip guard (stub wchg via $WCHG) and the unit pair's shape.
# WCHG_REAP / WCHG_HOOK override the script paths (used for mutation runs).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
reap=${WCHG_REAP:-$here/../.local/bin/wchg-reap}
hook=${WCHG_HOOK:-$here/../.claude/scripts/wchg-scope-check.sh}
unit=$here/../.config/systemd/user
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

base=$(mktemp -d -p "${TEST_TMPBASE:-$HOME/.cache/tmp}" .wchg-reap-test.XXXXXX) || exit 1
trap 'rm -rf "$base"' EXIT

# stub watchman: roots in $STUB_ROOTS (JSON array), every call logged to $STUB_LOG, --no-spawn asserted on every call
mkdir -p "$base/bin"
cat > "$base/bin/watchman" <<'STUB'
#!/usr/bin/env python3
import json, os, sys
log = open(os.environ["STUB_LOG"], "a")
a = sys.argv[1:]
if not a or a[0] != "--no-spawn":
    log.write("NOFLAG %s\n" % " ".join(a)); sys.exit(99)
a = a[1:]
log.write("CALL %s\n" % " ".join(a))
rp = os.environ["STUB_ROOTS"]
roots = json.load(open(rp))
if a[0] == "watch-list":
    print(json.dumps({"roots": roots}))
elif a[0] == "watch-del":
    roots = [r for r in roots if r != a[1]]
    json.dump(roots, open(rp, "w"))
    print(json.dumps({"root": a[1]}))
elif a[0] == "get-pid":
    print(json.dumps({"pid": 2147483000}))
STUB
chmod +x "$base/bin/watchman"

seq_n=0
# new_env: fresh HOME/cache/roots/log
new_env() {
  seq_n=$((seq_n+1)); t=$base/t$seq_n
  export HOME=$t/home XDG_CACHE_HOME=$t/home/.cache STUB_ROOTS=$t/roots.json STUB_LOG=$t/log
  mkdir -p "$HOME" "$XDG_CACHE_HOME/wchg" "$HOME/proj"; : > "$STUB_LOG"; echo '[]' > "$STUB_ROOTS"
  export PATH=$base/bin:$ORIG_PATH
}
ORIG_PATH=$PATH
# add_root <root> [age_seconds|none]  (state mtime = now - age; none = no wchg state)
add_root() {
  local root=$1 age=${2:-none} h
  python3 -c 'import json,sys;p=sys.argv[1];r=json.load(open(p));r.append(sys.argv[2]);json.dump(r,open(p,"w"))' "$STUB_ROOTS" "$root"
  [ "$age" = none ] && return 0
  h=$(printf '%s' "$root" | sha1sum | cut -c1-16)
  mkdir -p "$XDG_CACHE_HOME/wchg/$h"
  printf '{"dir":"%s","watch":"%s","relative_path":null,"clock":"c:1"}\n' "$root" "$root" > "$XDG_CACHE_HOME/wchg/$h/state.json"
  touch -d "@$(( $(date +%s) - age ))" "$XDG_CACHE_HOME/wchg/$h/state.json"
}
has_root() { python3 -c 'import json,sys;sys.exit(0 if sys.argv[2] in json.load(open(sys.argv[1])) else 1)' "$STUB_ROOTS" "$1"; }
has_state() { [ -d "$XDG_CACHE_HOME/wchg/$(printf '%s' "$1" | sha1sum | cut -c1-16)" ]; }
H=3600

bash -n "$reap" 2>/dev/null || python3 -m py_compile "$reap" || bad "syntax"
[ -x "$reap" ] && pass "reap executable" || bad "reap not executable"

# 1. removal rules + fresh keep + unowned survive
new_env
mkdir -p "$HOME/proj/idle" "$HOME/proj/fresh" "$HOME/proj/unowned" "$HOME/tmp/x" "$HOME/proj/gone"
add_root "$HOME/proj/gone" $((8*H)); rmdir "$HOME/proj/gone"
add_root "$HOME" 600
add_root "$HOME/tmp/x" 600
add_root "$HOME/proj/idle" $((7*H))
add_root "$HOME/proj/fresh" 300
add_root "$HOME/proj/unowned" none
out=$("$reap" 2>&1); rc=$?
[ $rc -eq 0 ] && pass "rc 0" || bad "rc $rc: $out"
for r in "$HOME/proj/gone" "$HOME" "$HOME/tmp/x" "$HOME/proj/idle"; do
  if ! has_root "$r"; then pass "removed ${r#$HOME}"; else bad "not removed ${r#$HOME}"; fi
  if ! has_state "$r"; then pass "state deleted ${r#$HOME}"; else bad "state kept ${r#$HOME}"; fi
done
has_root "$HOME/proj/fresh" && has_state "$HOME/proj/fresh" && pass "fresh (5 min) root + state kept" || bad "fresh root removed"
has_root "$HOME/proj/unowned" && pass "unowned fresh root survives" || bad "unowned root removed"
[[ $out == "wchg-reap roots=6->2 removed=4 unowned=1 inotify="* ]] && pass "summary line: $out" || bad "summary: $out"
! grep -q NOFLAG "$STUB_LOG" && pass "every watchman call passed --no-spawn" || bad "watchman called without --no-spawn"

# 1b. unowned idle-forever root still survives with a very small idle limit
new_env; mkdir -p "$HOME/proj/u"; add_root "$HOME/proj/u" none
"$reap" --idle-min 0 --max-roots 0 >/dev/null 2>&1
has_root "$HOME/proj/u" && pass "unowned root survives idle=0 max-roots=0" || bad "unowned root removed by idle/LRU"

# 2. LRU cap: 15 fresh-ish roots (distinct mtimes 10..24 min), cap 12 -> the 3 oldest go
new_env
for i in $(seq 1 15); do mkdir -p "$HOME/proj/r$i"; add_root "$HOME/proj/r$i" $(( (9+i)*60 )); done
out=$("$reap" --max-roots 12 2>&1)
gone=0; for i in 13 14 15; do has_root "$HOME/proj/r$i" || gone=$((gone+1)); done
left=0; for i in $(seq 1 12); do has_root "$HOME/proj/r$i" && left=$((left+1)); done
[ $gone -eq 3 ] && [ $left -eq 12 ] && pass "LRU cap removed the 3 oldest, kept 12 ($out)" || bad "LRU cap gone=$gone left=$left: $out"

# 3. dry-run changes nothing and issues zero watch-del
new_env
mkdir -p "$HOME/proj/idle"; add_root "$HOME/proj/idle" $((8*H)); add_root "$HOME" $((8*H))
out=$("$reap" --dry-run 2>&1)
has_root "$HOME/proj/idle" && has_root "$HOME" && has_state "$HOME/proj/idle" && pass "dry-run: roots and state untouched" || bad "dry-run changed things"
! grep -q 'watch-del' "$STUB_LOG" && pass "dry-run: ZERO watch-del calls" || bad "dry-run called watch-del"
[[ $out == *"would remove"* ]] && pass "dry-run prints what it would remove" || bad "dry-run output: $out"

# 4. race guard: root in $HOME/tmp with state 60 s old is kept; idle limit 0 does not beat the 2-min guard
new_env
mkdir -p "$HOME/proj/new" "$HOME/tmp/new"; add_root "$HOME/proj/new" 60; add_root "$HOME/tmp/new" 60
"$reap" --idle-min 0 --max-roots 0 >/dev/null 2>&1
has_root "$HOME/proj/new" && has_root "$HOME/tmp/new" && pass "2-min race guard keeps a just-used root (idle, LRU and scratch)" || bad "race guard failed"

# 5. watchman missing / not running -> exit 0 + message, daemon never started
new_env; export PATH=/usr/bin:/bin
rm -f "$base/bin/watchman.off"
out=$(PATH=/nonexistent-wchg-reap "$(command -v python3)" "$reap" 2>&1); rc=$?
[ $rc -eq 0 ] && [[ $out == "wchg-reap: watchman not running" ]] && pass "watchman missing -> exit 0 + message" || bad "missing: rc=$rc $out"
export PATH=$base/bin:$ORIG_PATH
mv "$base/bin/watchman" "$base/bin/watchman.real"
printf '#!/bin/sh\nexit 1\n' > "$base/bin/watchman"; chmod +x "$base/bin/watchman"
out=$("$reap" 2>&1); rc=$?
[ $rc -eq 0 ] && [[ $out == "wchg-reap: watchman not running" ]] && pass "watch-list failing (--no-spawn, daemon down) -> exit 0 + message" || bad "down: rc=$rc $out"
mv "$base/bin/watchman.real" "$base/bin/watchman"

# 6. hook: skip guard
mkdir -p "$base/bin2"
cat > "$base/bin2/wchg" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$WCHG_LOG"
STUB
chmod +x "$base/bin2/wchg"
hook_run() { # <mode> <file>
  printf '{"tool_input":{"file_path":"%s"}}' "$2" | WCHG=$base/bin2/wchg WCHG_LOG=$base/wchg.log bash "$hook" "$1"
}
new_env; : > "$base/wchg.log"
mkdir -p "$HOME/tmp/a" "$HOME/.local/state/x" "$HOME/proj/sub/deep" "$HOME/proj/.git" "$HOME/plain/dir" "$HOME/proj/nested/.git" "$HOME/proj/nested/src"
for f in "$HOME/tmp/a/f" "$HOME/.local/state/x/f" "$HOME/f"; do hook_run pre "$f"; done
[ ! -s "$base/wchg.log" ] && pass "pre on ~/tmp, ~/.local/state, ~/f: wchg never called" || bad "wchg called for skipped paths: $(cat "$base/wchg.log")"
hook_run pre "$HOME/proj/f"
grep -q "^watch $HOME/proj\$" "$base/wchg.log" && pass "pre on ~/proj/f (repo): wchg called" || bad "~/proj/f not watched"
: > "$base/wchg.log"
# HOME itself is a repo (contains .git): nested non-repo dir resolves to HOME -> skip
mkdir -p "$HOME/.git"; hook_run pre "$HOME/plain/dir/f"; hook_run pre "$HOME/f2"
[ ! -s "$base/wchg.log" ] && pass "HOME contains .git: nested non-repo dir skipped" || bad "watched under HOME repo: $(cat "$base/wchg.log")"
hook_run pre "$HOME/proj/sub/deep/f"
grep -q "^watch $HOME/proj/sub/deep\$" "$base/wchg.log" && pass "nested dir under a repo (.git above, below HOME) watched" || bad "repo child not watched"
: > "$base/wchg.log"; hook_run pre "$HOME/proj/nested/src/f"
grep -q "^watch " "$base/wchg.log" && pass "nested dir with its own .git watched" || bad "nested repo not watched"
rmdir "$HOME/.git"; : > "$base/wchg.log"
hook_run pre "$HOME/plain/dir/f"
[ ! -s "$base/wchg.log" ] && pass "no repo marker found: skipped" || bad "no-marker dir watched"
# post exits 0 silently on a missing state (stub wchg since fails)
printf '#!/usr/bin/env bash\nexit 1\n' > "$base/bin2/wchg"
out=$(hook_run post "$HOME/proj/f"); rc=$?
[ $rc -eq 0 ] && [ -z "$out" ] && pass "post exits 0 silently when 'since' fails" || bad "post rc=$rc out=$out"

# 7. units
t=$unit/wchg-reap.timer s=$unit/wchg-reap.service
grep -qx 'OnBootSec=5min' "$t" && grep -qx 'OnUnitActiveSec=30min' "$t" && grep -qx 'Persistent=false' "$t" && grep -qx 'WantedBy=timers.target' "$t" \
  && pass "timer fields" || bad "timer fields"
grep -qx 'Type=oneshot' "$s" && grep -qx 'Nice=19' "$s" && grep -qx 'IOSchedulingClass=idle' "$s" && grep -qx 'ExecStart=%h/.local/bin/wchg-reap' "$s" \
  && pass "service fields" || bad "service fields"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
