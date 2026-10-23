#!/bin/bash
# r7-mcp-gate.sh <pr> — carbon side of the mcphost hand-PR merge-gate log: wm-verify-run in a clean detached worktree at the PR
# head (HEAD/DIRTY trailer); cargo runs on ryzen7 via r7-mcp-gate-remote.sh. Never cargo on carbon.
# Memory (ctl c0f8 10-23): the remote run holds a ryzen7 MemGate slot (`builder cargo-jobs acquire`, class land + prefix mcphost-
# = the 12.5 G land price, above the measured 12.0 GiB mcphost peak) and its cgroup scope is capped at that same price, so the
# daemon's Σ live caps counts it. A fixed 8 G scope with no slot was a planned OOM. Exit 75 = no slot inside the wait = INFRA,
# never a red gate. Log path printed last.
# --selftest: the remote command line and the exit classification, no ssh, no git.
set -u
SLOT_GB=12.5 WAIT_MIN=${R7_GATE_WAIT_MIN:-90}
REMOTE=/home/jsy/.cache/r7-mcp-gate-remote.sh

remote_cmd() {  # remote_cmd <base> <head>: the ssh argument run on ryzen7
  printf '%s' "~/.cargo/bin/wm-build --state-dir ~/.local/state/wm-build builder cargo-jobs acquire --class land --prefix mcphost- --producer r7-mcp-gate --wait-minutes $WAIT_MIN -- systemd-run --user --scope -q -p MemoryMax=${SLOT_GB}G bash $REMOTE $1 $2"
}
classify() {  # classify <rc>: the verdict word for the gate log
  case $1 in 0) echo GREEN ;; 75) echo "INFRA no-memgate-slot-in-${WAIT_MIN}m" ;; 3) echo "INFRA clone-or-fetch" ;; *) echo "RED rc=$1" ;; esac
}

selftest() {
  local fail=0 c; ck() { if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
  c=$(remote_cmd b0 h1)
  printf '%s' "$c" | grep -q 'cargo-jobs acquire --class land --prefix mcphost- '; ck $? "the remote run holds a MemGate slot at the mcphost land price"
  printf '%s' "$c" | grep -q -- "-- systemd-run --user --scope -q -p MemoryMax=12.5G bash $REMOTE b0 h1\$"; ck $? "the scope cap equals the slot price and wraps the remote script"
  ! printf '%s' "$c" | grep -q 'MemoryMax=8G'; ck $? "no fixed 8 G cap (ctl c0f8)"
  [ "$(classify 75)" = "INFRA no-memgate-slot-in-${WAIT_MIN}m" ]; ck $? "exit 75 = INFRA, not red"
  [ "$(classify 0)" = GREEN ] && [ "$(classify 101)" = "RED rc=101" ]; ck $? "0 = GREEN, other = RED"
  [ $fail = 0 ] && echo "selftest ok" || echo "selftest FAIL"; return $fail
}
if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

PR=$1; R=${MCP_REPO:-/home/jsy/.cache/tmp/tmp.niruEdOVA7/mcphost}
git -C $R fetch -q origin main "pull/$PR/head:refs/r7/mpr$PR" || exit 3
H=$(git -C $R rev-parse refs/r7/mpr$PR); B=$(git -C $R merge-base origin/main $H)
T=$(mktemp -d); git -C $R worktree add -q --detach $T/w $H || exit 3
scp -q "$(dirname "$(readlink -f "$0")")/r7-mcp-gate-remote.sh" ryzen7:$REMOTE || exit 3
cd $T/w
wm-verify-run "ssh ryzen7 \"$(remote_cmd $B $H)\" # MemGate slot + RUSTFLAGS=-D warnings cargo check + clippy delta + cargo test on touched tests"
rc=$?; echo "r7-mcp-gate: $(classify $rc)"
cd $R; git worktree remove $T/w; git update-ref -d refs/r7/mpr$PR; rmdir $T 2>/dev/null; exit $rc
