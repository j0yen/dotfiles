#!/usr/bin/env bash
# Tests that agorabus-session-start.sh brings the bus up through
# agorabus.service (A1447) and only falls back to a nohup spawn when no user
# manager answers. Fake systemctl/pgrep/agorabus on PATH, temp HOME.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
hook="$here/.claude/scripts/agorabus-session-start.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; pass=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin" "$T/home" "$T/cache"
mksock() { python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$1"; }

cat >"$T/bin/systemctl" <<'F'
#!/usr/bin/env bash
echo "systemctl $*" >>"$FAKE_CALLS"
case "$*" in
  *" cat "*)   [ "${FAKE_CAT_HANG:-0}" = 1 ] && exec sleep 5
               exit "${FAKE_CAT_RC:-0}" ;;
  *" start "*) [ "${FAKE_START_MAKES_SOCK:-0}" = 1 ] && python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$AGORABUS_CACHE/sock"
               [ "${FAKE_START_HANG:-0}" = 1 ] && exec sleep 5
               exit "${FAKE_START_RC:-0}" ;;
esac
exit 0
F
cat >"$T/bin/pgrep" <<'F'
#!/usr/bin/env bash
case "$*" in *"agorabus daemon"*) exit "${FAKE_PGREP_RC:-1}" ;; esac
exit 1
F
cat >"$T/bin/agorabus" <<'F'
#!/usr/bin/env bash
case "$1" in
  daemon) echo "nohup-daemon" >>"$FAKE_CALLS"; python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$AGORABUS_CACHE/sock" ;;
  peers)  printf '[{"session_id":"%s"}]\n' "$FAKE_SID" ;;
esac
exit 0
F
chmod +x "$T/bin/"*

run() { # env assignments as args; prints elapsed seconds in $T/elapsed
    rm -rf "$T/cache"; mkdir -p "$T/cache"; : >"$T/calls"
    [ "${LIVE_SOCK:-0}" = 1 ] && mksock "$T/cache/sock"
    local t0=$SECONDS
    env HOME="$T/home" PATH="$T/bin:$PATH" AGORABUS_BIN="$T/bin/agorabus" AGORABUS_CACHE="$T/cache" \
        FAKE_CALLS="$T/calls" FAKE_SID="$FAKE_SID" CLAUDE_PROJECT_DIR="$T/proj" "$@" \
        bash "$hook" >/dev/null 2>&1
    rc=$?; elapsed=$((SECONDS-t0))
}
mkdir -p "$T/proj"
FAKE_SID=$(env HOME="$T/home" AGORABUS_BIN="$T/bin/agorabus" AGORABUS_CACHE="$T/cache" AGORABUS_SID_DEBUG=1 CLAUDE_PROJECT_DIR="$T/proj" bash "$hook")

# (a) no daemon, unit present -> systemctl start, no nohup spawn
FAKE_START_MAKES_SOCK=1 run FAKE_START_MAKES_SOCK=1
grep -q 'systemctl --user start --no-block agorabus.service' "$T/calls" && ok "a: unit start called" || bad "a: unit start called"
grep -q nohup-daemon "$T/calls" && bad "a: no nohup spawn" || ok "a: no nohup spawn"
[ "$rc" = 0 ] && ok "a: exit 0" || bad "a: exit 0 (rc=$rc)"

# (b) live daemon -> neither called
run FAKE_PGREP_RC=0
{ grep -q 'start' "$T/calls" || grep -q nohup-daemon "$T/calls"; } && bad "b: neither called" || ok "b: neither called"
[ "$rc" = 0 ] && ok "b: exit 0" || bad "b: exit 0"

# (c) systemctl --user fails -> nohup fallback exactly once
run FAKE_CAT_RC=1
n=$(grep -c nohup-daemon "$T/calls")
[ "$n" = 1 ] && ok "c: nohup fallback once" || bad "c: nohup fallback once (n=$n)"
grep -q 'start' "$T/calls" && bad "c: no unit start" || ok "c: no unit start"
[ "$rc" = 0 ] && ok "c: exit 0" || bad "c: exit 0"

# (d) unit start ok but socket never appears -> exit 0 within 6 s, failure logged
run
[ "$rc" = 0 ] && ok "d: exit 0" || bad "d: exit 0 (rc=$rc)"
[ "$elapsed" -le 6 ] && ok "d: within 6s (${elapsed}s)" || bad "d: within 6s (${elapsed}s)"
grep -q nohup-daemon "$T/calls" && bad "d: no second owner" || ok "d: no second owner"
grep -qh '"phase":"daemon_up".*"result":"fail"' "$T/cache/handshake/"*.log 2>/dev/null && ok "d: failure logged" || bad "d: failure logged"

hl() { cat "$T/cache/handshake/"*.log 2>/dev/null; }

# (e) cat ok, start times out (rc 124, job may be queued), socket never
# appears -> no nohup spawn (one bus owner), exit 0 within 6 s, rc logged
run FAKE_START_HANG=1
grep -q nohup-daemon "$T/calls" && bad "e: no nohup spawn" || ok "e: no nohup spawn"
[ "$rc" = 0 ] && ok "e: exit 0" || bad "e: exit 0 (rc=$rc)"
[ "$elapsed" -le 6 ] && ok "e: within 6s (${elapsed}s)" || bad "e: within 6s (${elapsed}s)"
hl | grep -q '"phase":"daemon_up".*"result":"fail".*"start":"unit","start_rc":124' && ok "e: rc 124 logged" || bad "e: rc 124 logged"

# (f) cat ok, start rc 124 but the queued job brings the socket up -> adopt it
run FAKE_START_RC=124 FAKE_START_MAKES_SOCK=1
grep -q nohup-daemon "$T/calls" && bad "f: no nohup spawn" || ok "f: no nohup spawn"
[ "$rc" = 0 ] && ok "f: exit 0" || bad "f: exit 0 (rc=$rc)"
hl | grep -q '"phase":"daemon_up".*"result":"ok".*"start_rc":124' && ok "f: ok + rc 124 logged" || bad "f: ok + rc 124 logged"

# (g) cat ok, start refused (rc 5, nothing queued) -> nohup fallback once
run FAKE_START_RC=5
n=$(grep -c nohup-daemon "$T/calls")
[ "$n" = 1 ] && ok "g: nohup fallback once" || bad "g: nohup fallback once (n=$n)"
[ "$rc" = 0 ] && ok "g: exit 0" || bad "g: exit 0 (rc=$rc)"
hl | grep -q '"start":"nohup","start_rc":5' && ok "g: rc 5 logged" || bad "g: rc 5 logged"

# (h) cat hangs (manager hung, timeout rc 124) -> nohup fallback once, no start
run FAKE_CAT_HANG=1
n=$(grep -c nohup-daemon "$T/calls")
[ "$n" = 1 ] && ok "h: nohup fallback once" || bad "h: nohup fallback once (n=$n)"
grep -q 'start' "$T/calls" && bad "h: no unit start" || ok "h: no unit start"
[ "$rc" = 0 ] && ok "h: exit 0" || bad "h: exit 0 (rc=$rc)"

echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
