#!/bin/bash
# rb-wmb-capped.sh: run any hand wm-build CLI on RedBaron under a 4G memory cap, no swap (ctl af15 10-30; a hand wm-build hit anon-rss 15.5 GB and triggered the 11:49 AM global OOM).
# PREMISE (A1304 W11 2026-11-20, classified REQUIRED SAFETY, not a discretionary cap): installed wm-build 0.77.112 (f4c0592, also origin/main 65cd0df)
#   `runs` and `status` call status::build_daemon (src/status.rs:1291) -> State::journal_lines (src/state.rs:2392), which read_to_string's the WHOLE
#   journal.jsonl (1.66 GB on 11-20) into a Vec<String> and parses every line; 10-30 that path reached 15.5 GB anon-rss and global-OOMed RedBaron.
# EXPIRES: when the installed wm-build's runs/status stream or bound the journal read (owner: wm-build source owner via Hermes, A1304/A1300);
#   then this file execs wm-build without the scope properties and the session-scope 8G drop-in is removed with it. No date; no other caller.
# Caller: the host-only RB PATH shim ~/.local/bin/wm-build (ctl b108 10-30) routes runs|status here; every other subcommand is unbounded.
# Usage: rb-wmb-capped.sh <wm-build subcommand> [args...]   |   rb-wmb-capped.sh --selftest
set -uo pipefail
WMB=/home/jsy/.cargo/bin/wm-build
CAP=(systemd-run --user --scope --quiet -p TasksMax=infinity -p MemoryMax=4G -p MemorySwapMax=0)
if [ "${1:-}" = "--selftest" ]; then
  [ -x "$WMB" ] || { echo "selftest FAIL: $WMB not executable"; exit 1; }
  systemd-run --user --scope --quiet -p TasksMax=infinity -p MemoryMax=64M -p MemorySwapMax=0 python3 -I -c 'b=bytearray(256*1024*1024); print(len(b))' >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || { echo "selftest FAIL: 256M alloc survived a 64M scope cap"; exit 1; }
  "${CAP[@]}" /bin/true || { echo "selftest FAIL: capped scope did not start"; exit 1; }
  echo "selftest PASS: cap enforced (over-cap rc=$rc), scope starts, $WMB executable"
  exit 0
fi
[ $# -ge 1 ] || { echo "usage: rb-wmb-capped.sh <subcmd> [args...] | --selftest" >&2; exit 2; }
exec "${CAP[@]}" "$WMB" "$@"
