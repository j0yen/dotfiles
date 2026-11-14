#!/usr/bin/env bash
# followup-eval alive(): a pgrep match on the evaluator's own ancestors is dropped, except the claimed worker itself: an ancestor whose comm is exactly
# claude AND whose argv passes the token as its session argument (--resume <tok…> / --session-id <tok…> / the =<v> forms) IS the live worker
# (A1307 rev 13: inside the ctl session the canonical handle ctl:<sid> read dead because the session's claude pid was the evaluator's ancestor, while
# the same handle read live from any other session). A comm prefix (claude-*, tmux-*), the token anywhere else in argv (a prompt) and the tmux server
# (startup argv, stale for its whole life) are dropped (A1307 fix1: F1, F2). The real tmux/pgrep path runs here: no FOLLOWUP_WORKER_ALIVE_CMD.
# A script's comm is its filename (15 chars), so one wrapper body under several names stands in for each ancestor kind: the one named `claude` is a
# TEST WRAPPER standing in for a session's claude process, never a real Claude Code process. Tmux runs on private -L sockets under this test's tmpdir.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
base="$(mktemp -d "${TMPDIR:-/tmp}/followup-eval-alive.XXXXXX")"
pids=(); socks=()
cleanup() {
  [ "$BASHPID" = "$$" ] || return 0   # a forked child inherits this trap: only the test shell itself cleans up
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  for s in "${socks[@]}"; do tmux -L "$s" kill-server 2>/dev/null; done
  rm -rf "$base"
}
trap cleanup EXIT
fail=0; pass=0
chk() { if [ "$2" = 0 ]; then echo "PASS $1"; pass=$((pass + 1)); else echo "FAIL $1"; fail=$((fail + 1)); fi; }
EV="$here/.local/bin/followup-eval.py"
unset FOLLOWUP_WORKER_ALIVE_CMD TMUX TMUX_PANE
export TMUX_TMPDIR="$base" SHELL=/bin/sh
command -v pgrep >/dev/null; chk "0: pgrep present" $?
command -v tmux >/dev/null; chk "0b: tmux present (K14, K14b, K15b need it)" $?
rnd() { printf 'tok%s%s' "$1" "$(od -An -N5 -tx1 /dev/urandom | tr -d ' \n')"; }   # a fresh token names no tmux session and no process yet
tok="$(rnd alive)"
cat >"$base/probe.py" <<'PY'
import importlib.util, sys
sys.dont_write_bytecode = True   # no __pycache__ beside the evaluator under test
spec = importlib.util.spec_from_file_location("fe", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("live" if m.alive(sys.argv[2]) else "dead")
PY
# the wrapper ignores its own argv (the case sets it), probes FE_HANDLE, and stays the probe's parent (the `exit` after the probe keeps bash from exec'ing it)
for name in claude hookshell claude-hookwrap tmux-helper; do
  printf '#!/bin/bash\npython3 -I "$FE_PROBE" "$FE_EV" "$FE_HANDLE"\nexit $?\n' >"$base/$name"; chmod +x "$base/$name"
done
export FE_PROBE="$base/probe.py" FE_EV="$EV"
as() { local w="$1" h="$2"; shift 2; FE_HANDLE="$h" "$base/$w" "$@" 2>&1; }   # as <wrapper> <handle> <wrapper argv...>
direct() { python3 -I "$base/probe.py" "$EV" "$1" 2>&1; }                     # probe with no wrapper ancestor naming anything
sleeper() { python3 -I -c 'import time; time.sleep(600)' "$@" & pids+=("$!"); }  # a non-ancestor worker whose argv is "$@"

out="$(as claude "ctl:$tok" --resume "$tok-5f3c-4e1a-9d2b" -p hello)"
[ "$out" = live ]; chk "K1: test wrapper named claude (stand-in for the session's claude process), argv --resume <tok…>, handle ctl:<tok>: the claimed worker is kept, reads LIVE (got: $out)" $?
out="$(as claude "ctl:$tok" "--session-id=$tok-5f3c")"
[ "$out" = live ]; chk "K1b: same stand-in with --session-id=<tok…> (the =<v> form): reads LIVE (got: $out)" $?
out="$(as hookshell "ctl:$tok" --resume "$tok-5f3c")"
[ "$out" = dead ]; chk "K2: a wrapper ancestor with comm hookshell, even with --resume <tok…>, is dropped: reads DEAD (got: $out)" $?
out="$(bash -c "python3 -I '$base/probe.py' '$EV' '$tok'; exit \$?" 2>&1)"
[ "$out" = dead ]; chk "K3: a bash -c ancestor naming the token (kept as parent by the trailing exit) is dropped: reads DEAD (the 5f0bd35 self-match fix holds; got: $out)" $?
out="$(direct "")"
[ "$out" = dead ]; chk "K4: an empty handle reads DEAD (got: $out)" $?

u="$(rnd live)"; sleeper --resume "$u-0000"
out="$(direct "ctl:$u")"
[ "$out" = live ]; chk "K7a: an unrelated live worker (non-ancestor, argv names its own token U) reads LIVE for ctl:U: normal matching unchanged (got: $out)" $?
out="$(direct "ctl:$tok")"
[ "$out" = dead ]; chk "K7b: with that worker live, our token (named by nothing) reads DEAD (got: $out)" $?
v="$(rnd dead)"; sleeper --resume "$v-0000"; vp="$!"
for _ in $(seq 1 50); do pgrep -f -- "$v" >/dev/null && break; sleep 0.1; done   # the worker's argv is visible before it is killed
kill "$vp"; wait "$vp" 2>/dev/null
out="$(direct "ctl:$v")"
[ "$out" = dead ]; chk "K8: an unrelated worker after it exited reads DEAD (got: $out)" $?

b="$(rnd other)"
out="$(as claude "ctl:$tok" --resume "$b-0000")"
[ "$out" = dead ]; chk "K9: claude stand-in ancestor whose --resume names a different session B, handle ctl:<tok>: reads DEAD (got: $out)" $?
out="$(as claude "ctl:$tok" --resume "ffff$tok")"
[ "$out" = dead ]; chk "K9b: claude stand-in whose --resume value contains the token but does not start with it (a different session): reads DEAD (got: $out)" $?
out="$(as claude "ctl:$tok" --resume "$b-0000" -p "check the claim ctl:$tok and report")"
[ "$out" = dead ]; chk "K10: claude stand-in naming the token only in a prompt argument (its session is B): not the claimed worker, reads DEAD (got: $out)" $?
out="$(as claude-hookwrap "ctl:$tok" --resume "$tok-5f3c")"
[ "$out" = dead ]; chk "K11: comm claude-hookwrap (a claude* prefix, not claude) with --resume <tok…>: dropped, reads DEAD (got: $out)" $?
out="$(as tmux-helper "ctl:$tok" --resume "$tok-5f3c")"
[ "$out" = dead ]; chk "K12: comm tmux-helper (a tmux* prefix) with --resume <tok…>: dropped, reads DEAD (got: $out)" $?

# K14: a session named exactly T on a private server; T is set by rename, so no live argv names it and only tmux has-session can find it
t="$(rnd sess)"; socks+=(fe14)
tmux -L fe14 new-session -d -s anon "exec sleep 600" && tmux -L fe14 rename-session -t anon "$t"
sp="$(tmux -L fe14 display-message -p -t "$t" '#{socket_path}' 2>/dev/null)"
case "$sp" in "$base"/*) ! pgrep -f -- "$t" >/dev/null ;; *) false ;; esac
chk "K14 precondition: private session T exists on a socket under this test's tmpdir and no process argv names T (got socket: ${sp:-none})" $?
out="$(TMUX="$sp,0,0" direct "ctl:$t")"
[ "$out" = live ]; chk "K14: a real tmux session named exactly <tok> (private -L socket) reads LIVE through tmux has-session alone (got: $out)" $?

inpane() {   # inpane <socket> <session> <name> <shell command>: run the command in a new window of that server, print its output
  tmux -L "$1" new-window -d -t "$2" "sleep 0.3; $4 >'$base/$3.tmp' 2>&1; mv '$base/$3.tmp' '$base/$3.out'"
  for _ in $(seq 1 100); do [ -s "$base/$3.out" ] && break; sleep 0.1; done
  cat "$base/$3.out" 2>/dev/null || echo "no-output"
}
# K14b: the seat layout, inside a real pane: pane sh -> claude stand-in (--resume P…) -> probe; the server (comm "tmux: server") is an ancestor and is dropped
p="$(rnd pane)"; socks+=(fe14b)
tmux -L fe14b new-session -d -s seat "exec sleep 600"
out="$(inpane fe14b seat k14b "FE_HANDLE='ctl:$p' FE_PROBE='$FE_PROBE' FE_EV='$EV' '$base/claude' --resume '$p-5f3c'")"
[ "$out" = live ]; chk "K14b: inside a real tmux pane, claude stand-in with --resume <tok…> above the probe reads LIVE (seat layout; got: $out)" $?

# K15b: a server started with a worker naming D; the worker's window is killed, so only the server's startup argv still names D
d="$(rnd stale)"; socks+=(fe15)
tmux -L fe15 new-session -d -s holder -n w "exec python3 -I -c 'import time; time.sleep(600)' --resume $d-0000"
tmux -L fe15 new-window -d -t holder -n keep "exec sleep 600"; tmux -L fe15 kill-window -t holder:w
for _ in $(seq 1 50); do [ "$(pgrep -f -- "$d" | wc -l)" = 1 ] && break; sleep 0.1; done
sv="$(pgrep -f -- "$d")"
[ "$(cat "/proc/${sv:-0}/comm" 2>/dev/null)" = "tmux: server" ]; chk "K15b precondition: the worker exited and the only process naming D is the tmux server (comm 'tmux: server', pid ${sv:-none})" $?
out="$(inpane fe15 holder k15b "python3 -I '$base/probe.py' '$EV' 'ctl:$d'")"
[ "$out" = dead ]; chk "K15b: inside a pane of that server (server = ancestor, its stale argv names D, no session named D): reads DEAD (got: $out)" $?

echo "pass=$pass fail=$fail"; [ "$fail" = 0 ]
