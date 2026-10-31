#!/usr/bin/env bash
# tests/watchman-guard.test.sh: hermetic test of the watchman shim (.local/bin/watchman), the sweeper (.local/bin/watchman-root-guard.sh) and the shared
# lib/deny list. NEVER touches the real watchman server: every watchman is a stub script on a temp path, HOME/XDG/WP_STATE are mktemp dirs, seat-event is a stub,
# WP_DECIDE_BIN points at nothing (no wm-decide row). Run: bash tests/watchman-guard.test.sh
# Cases: t1 t1b t2 (shim) t3 t3b-d t4 (sweeper) t6 t7 t8 (shim fail-open / redaction / speed) t9 (one deny file) t10 (-j stdin). t5 is fleet-dash's.
# Mutations (i)-(vi): each patches a COPY of the shim/sweeper/lib, re-runs the suite against it (WGT_* env) and requires the named case to go red.
# Env: WGT_SHIM WGT_SWEEP WGT_LIB (the files under test; the mutation runs set them) WGT_NOMUT=1 (skip the mutation section)
set -u
here=$(cd "$(dirname "$0")" && pwd)
SHIM=${WGT_SHIM:-$here/../.local/bin/watchman}
SWEEP=${WGT_SWEEP:-$here/../.local/bin/watchman-root-guard.sh}
LIB=${WGT_LIB:-$here/../.local/lib/watchman-guard-lib.sh}
WPLIB=$here/../.local/lib/watcher-premise.sh
DENY=$here/../.config/watchman-guard/deny.list
BASE=$(mktemp -d "${TMPDIR:-/tmp}/watchman-guard-test.XXXXXX") || exit 2
trap 'rm -rf -- "${BASE:?}"' EXIT
fail=0; n=0
ok() { # name rc(0=ok) [detail]
  n=$((n+1)); if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1${3:+ -- $3}"; fail=$((fail+1)); fi; }

nenv=0
mkenv() { # sets E (env root) with home, state, stubs
  nenv=$((nenv+1)); E="$BASE/e$nenv"; mkdir -p "$E/home" "$E/st" "$E/wp" "$E/sw"; : > "$E/calls"; : > "$E/events"
  # stub watchman: logs argv; `watch-list` prints $E/roots.json (or exits $E/rc); -j / stdin copy to $E/stdin.out
  cat > "$E/stub" <<STUB
#!/bin/bash
echo "\$*" >> "$E/calls"
case " \$* " in
  *" -j "*) cat > "$E/stdin.out"; exit 0;;
  *" watch-list "*) [ -f "$E/slow" ] && sleep 5; [ -f "$E/rc" ] && exit "\$(cat "$E/rc")"; cat "$E/roots.json" 2>/dev/null; exit 0;;
esac
exit 0
STUB
  chmod +x "$E/stub"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/events"\n' "$E" > "$E/bell"; chmod +x "$E/bell"
}
shim() { # args... ; env: DENYF (default repo list) EXTRA_XDG
  env -i HOME="$E/home" PATH=/usr/bin:/bin WG_REAL="$E/stub" WG_LIB="$LIB" WG_DENY="${DENYF:-$DENY}" XDG_STATE_HOME="${XDGS:-$E/st}" "$SHIM" "$@"
}
rows() { cat "$E/st/watchman-guard/clients.jsonl" 2>/dev/null; }
sweep() { # extra env pairs...
  env -i HOME="$E/home" PATH=/usr/bin:/bin TZ=UTC WG_WATCHMAN="$E/stub" WG_LIB="$LIB" WG_WP_LIB="$WPLIB" WG_DENY="${DENYF:-$DENY}" WG_STATE="$E/sw" \
    XDG_STATE_HOME="$E/st" WG_SEAT_EVENT="$E/bell" WG_EXPIRES="$FUT" WP_STATE="$E/wp" WP_DECIDE_BIN=/nonexistent/wm-decide "$@" bash "$SWEEP" 2>&1
}
FUT=$(date -d '+30 days' -Is); PAST=$(date -d '-1 day' -Is)

# t1: refuse /home/jsy; a temp dir passes with argv unchanged; a row lands
mkenv; mkdir -p "$E/ok"
shim watch-project /home/jsy >/dev/null 2>"$E/err"; rc=$?
[ "$rc" = 1 ] && grep -q '^watchman-guard: refused root /home/jsy$' "$E/err" && [ ! -s "$E/calls" ]; ok "t1 refuse /home/jsy rc=1, stub never ran" $? "rc=$rc"
shim watch-project "$E/ok" >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(tail -n1 "$E/calls")" = "watch-project $E/ok" ]; ok "t1 temp dir passes, argv unchanged" $? "rc=$rc calls=$(cat "$E/calls")"
[ "$(rows | wc -l)" = 2 ] && rows | head -n1 | grep -q '"kind":"refused"' && rows | tail -n1 | grep -q '"kind":"watch"' && rows | tail -n1 | grep -q '"pid":[0-9]'; ok "t1 clients.jsonl rows (refused, watch)" $?
# t1b: descendants pass (equality only)
mkenv
shim watch-project /home/jsy/.claude >/dev/null; r1=$?; shim watch-project /home/jsy/Documents/PRDs/build-queue >/dev/null; r2=$?
[ "$r1$r2" = 00 ] && [ "$(cat "$E/calls")" = "watch-project /home/jsy/.claude
watch-project /home/jsy/Documents/PRDs/build-queue" ]; ok "t1b .claude + build-queue pass, argv unchanged" $?
# t2: a symlink to $HOME is refused
mkenv; ln -s /home/jsy "$E/lnk"
shim watch-project "$E/lnk" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ ! -s "$E/calls" ]; ok "t2 symlink to /home/jsy refused" $? "rc=$rc"
# t3: sweeper watch-del for /home/jsy only + one seat-event
mkenv; mkdir -p "$E/keep"
printf '{"version":"4.9.0","roots":["/home/jsy","%s","/home/jsy/.claude"]}\n' "$E/keep" > "$E/roots.json"
out=$(sweep)
dels=$(grep -c 'watch-del' "$E/calls")
[ "$dels" = 1 ] && grep -qx -- '--no-spawn --no-local watch-del /home/jsy' "$E/calls" && [ "$(wc -l < "$E/events")" = 1 ] \
  && grep -qx 'ctl WATCHMAN-GUARD removed root /home/jsy' "$E/events" && echo "$out" | grep -q 'removed /home/jsy$'; ok "t3 sweeper: watch-del /home/jsy only + 1 seat-event" $? "dels=$dels out=$out events=$(cat "$E/events")"
grep -q '"kind":"sweeper-removed","root":"/home/jsy"' "$E/st/watchman-guard/clients.jsonl" 2>/dev/null; ok "t3 refusal row in clients.jsonl" $?
# t3b: rate limit (one seat-event per root per 10 min) while the delete still happens
mkenv; printf '{"roots":["/home/jsy"]}\n' > "$E/roots.json"
sweep WG_DEBOUNCE_S=-1 >/dev/null; sweep WG_DEBOUNCE_S=-1 >/dev/null
[ "$(grep -c watch-del "$E/calls")" = 2 ] && [ "$(wc -l < "$E/events")" = 1 ]; ok "t3b rate limit: 2 deletes, 1 seat-event" $?
# t3c: debounce (same watch-list sha within 5 s = no-op)
mkenv; printf '{"roots":["/home/jsy"]}\n' > "$E/roots.json"
sweep >/dev/null; out=$(sweep)
[ "$(grep -c watch-del "$E/calls")" = 1 ] && echo "$out" | grep -q 'noop-debounce'; ok "t3c debounce: second pass is a no-op" $? "out=$out"
# t3d: re-added >= 3 times in 1 h names the client (event gap forced to 0)
mkenv; printf '{"roots":["/home/jsy"]}\n' > "$E/roots.json"
for i in 1 2 3; do sweep WG_DEBOUNCE_S=-1 WG_EVENT_GAP_S=0 >/dev/null; done
[ "$(wc -l < "$E/events")" = 3 ] && ! sed -n 2p "$E/events" | grep -q 'NAME THE CLIENT' && sed -n 3p "$E/events" | grep -q 'NAME THE CLIENT: see clients.jsonl'; ok "t3d 3rd re-add adds NAME THE CLIENT" $?
# t3e: no server / timeout
mkenv; echo 1 > "$E/rc"; out=$(sweep); [ "$out" = "watchman-root-guard: no-server" ] && [ ! -s "$E/events" ]; ok "t3e no-server exits 0, no event" $? "out=$out"
mkenv; : > "$E/slow"; out=$(sweep WG_TIMEOUT=1); [ "$out" = "watchman-root-guard: unresponsive" ] && grep -q 'watchman-unresponsive' "$E/events" && ! grep -q watch-del "$E/calls"; ok "t3e timeout -> unresponsive + 1 event, no watch-del" $? "out=$out"
# t4: expired premise -> no watch-del, an expired line
mkenv; printf '{"roots":["/home/jsy"]}\n' > "$E/roots.json"
out=$(sweep WG_EXPIRES="$PAST")
[ ! -s "$E/calls" ] && [ ! -s "$E/events" ] && [ "$out" = "watchman-root-guard: DISARMED expired" ]; ok "t4 EXPIRES in the past: no watch-del, 'expired' line" $? "out=$out"
# t6: unwritable XDG_STATE_HOME -> still execs, argv unchanged
mkenv; : > "$E/notadir"
XDGS="$E/notadir/x" shim watch-project "$E/ok" extra >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$E/calls")" = "watch-project $E/ok extra" ]; ok "t6 unwritable state dir: stub still execs, argv unchanged" $? "rc=$rc"
mkenv; WG_LIB=/nonexistent shim version >/dev/null 2>&1; env -i HOME="$E/home" PATH=/usr/bin:/bin WG_REAL="$E/stub" WG_LIB=/nonexistent "$SHIM" watch-project /home/jsy >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(tail -n1 "$E/calls")" = "watch-project /home/jsy" ]; ok "t6 missing lib: fail open (pass through)" $? "rc=$rc"
# t7: a fixture cmdline holding fake secrets -> <REDACTED>, never the token
mkenv
TOK1="sk-ant-api03-FAKEFAKEFAKE1234567890abcdef"; TOK2="ghp_FAKEfakeFAKEfake0123456789"; TOK3="abcdefghijklmnopqrstuvwxyz0123456789ABCD"
env -i HOME="$E/home" PATH=/usr/bin:/bin WG_REAL="$E/stub" WG_LIB="$LIB" WG_DENY="$DENY" XDG_STATE_HOME="$E/st" \
  bash -c "\"$SHIM\" version --tok=$TOK2; true # $TOK1 Bearer $TOK3"
r=$(rows)
[ -n "$r" ] && echo "$r" | grep -q '<REDACTED>' && ! echo "$r" | grep -q -e "$TOK1" -e "$TOK2" -e "$TOK3" -e FAKEFAKE -e FAKEfake; ok "t7 fake sk-ant/ghp/long token redacted in clients.jsonl" $? "rows=$(echo "$r" | cut -c1-300)"
# t8: 20 invocations, each <= 50 ms (one retry of the whole batch on a loaded host)
mkenv
t8() { local i s e worst=0 ms; for i in $(seq 20); do s=$(date +%s%N); shim version >/dev/null; e=$(date +%s%N); ms=$(((e-s)/1000000)); [ "$ms" -gt "$worst" ] && worst=$ms; done; T8=$worst; [ "$worst" -le 50 ]; }
t8 || t8; ok "t8 20 shim invocations, worst ${T8} ms (<= 50)" $?
# t9: shim and sweeper consume the SAME deny.list; no second copy in code
mkenv; mkdir -p "$E/custom"; printf '# custom\n%s\n' "$E/custom" > "$E/deny.custom"
DENYF="$E/deny.custom" shim watch-project "$E/custom" >/dev/null 2>&1; a=$?
DENYF="$E/deny.custom" shim watch-project /home/jsy >/dev/null 2>&1; b=$?
printf '{"roots":["%s","/home/jsy"]}\n' "$E/custom" > "$E/roots.json"
DENYF="$E/deny.custom" sweep >/dev/null
copies=$(cat "$SHIM" "$SWEEP" | grep -c '/home/jsy/.local/state')
[ "$a" = 1 ] && [ "$b" = 0 ] && grep -qx -- "--no-spawn --no-local watch-del $E/custom" "$E/calls" && ! grep -qx -- '--no-spawn --no-local watch-del /home/jsy' "$E/calls" && [ "$copies" = 0 ]; ok "t9 shim + sweeper read the same deny file, no inline copy" $? "a=$a b=$b copies=$copies"
# t10: -j stdin mode passes through unrefused, kind json-stdin, stdin never read
mkenv; printf 'XYZ-PAYLOAD' | shim -j >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$E/stdin.out")" = "XYZ-PAYLOAD" ] && rows | grep -q '"kind":"json-stdin"'; ok "t10 -j passes through, kind json-stdin, stdin intact" $? "rc=$rc"
printf '["watch-project","/home/jsy"]' | shim --server-encoding=json -j >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$E/stdin.out")" = '["watch-project","/home/jsy"]' ]; ok "t10 json payload naming /home/jsy passes (shim cannot refuse stdin modes)" $?

# ---- mutations -------------------------------------------------------------------------------------------------------------------------------
if [ -z "${WGT_NOMUT:-}" ]; then
  mutate() { # label file-kind(shim|sweep|lib) sed-expr expected-red-case
    local label=$1 kind=$2 expr=$3 want=$4 M="$BASE/mut-$1" src dst out
    mkdir -p "$M"; cp "$SHIM" "$M/watchman"; cp "$SWEEP" "$M/sweep.sh"; cp "$LIB" "$M/lib.sh"
    case $kind in shim) dst=$M/watchman;; sweep) dst=$M/sweep.sh;; lib) dst=$M/lib.sh;; esac
    cp "$dst" "$dst.orig"; sed -i -E "$expr" "$dst"
    if cmp -s "$dst" "$dst.orig"; then ok "mutation $label: patch applied" 1 "sed changed nothing"; return; fi
    out=$(WGT_NOMUT=1 WGT_SHIM="$M/watchman" WGT_SWEEP="$M/sweep.sh" WGT_LIB="$M/lib.sh" bash "$here/watchman-guard.test.sh" 2>&1)
    if printf '%s\n' "$out" | grep -q "^FAIL $want"; then ok "mutation $label: $want went red" 0; else ok "mutation $label: $want went red" 1 "$(printf '%s\n' "$out" | grep -c '^FAIL') FAIL lines, none for $want"; fi
  }
  mutate "(i) drop the DENY check" shim 's/wg_is_denied "\$real"/false/' "t1 "
  mutate "(ii) drop the realpath" shim 's/real=\$\(realpath -m -- "\$root" 2>\/dev\/null\) \|\| real=""/real=$root/' "t2 "
  mutate "(iii) sweeper deletes every root" sweep 's/wg_is_denied "\$root" \|\| continue/: /' "t3 "
  mutate "(v) prefix match" lib 's/\[ "\$1" = "\$d" \] && return 0/case "$1" in "$d"|"$d"\/*) return 0;; esac/' "t1b "
  mutate "(vi) shim keeps its own inline list" shim 's/wg_load_deny \&\& wg_is_denied/{ WG_DENY_LIST=(\/ \/home \/home\/jsy); } \&\& wg_is_denied/' "t9 "
fi

echo "watchman-guard: $((n-fail))/$n passed"
[ "$fail" = 0 ]
