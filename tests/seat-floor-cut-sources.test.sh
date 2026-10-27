#!/usr/bin/env bash
# tests/seat-floor-cut-sources.test.sh -- M9 step 1 falsifier (.local/bin/seat-floor-cut-sources.sh) on a synthetic seat JSONL: an action whose distinctive token comes ONLY from a cut line is a HIT;
# tokens carried by CLAUDE.md / AGENTS.md / § Stage / the segment summary / earlier messages / the LIVE TRAPS section are not; the SessionStart seat-context-start stdout and the
# MEMORY.md copy in `instructions` do not count as carried; out-of-window lines and sidechains are ignored; --fail-on-hit exits 1. No live JSONL, no network.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"; F="$root/.local/bin/seat-floor-cut-sources.sh"
fail=0; chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
T="$(mktemp -d "${TMPDIR:-/tmp}/sfcs.XXXXXX")"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/jd/memory" "$T/skills/dream" "$T/skills/wwhtbt" "$T/skills/improv"
printf 'seat\trole\tsid\ttick_min\ttimeout\tgoal\told\tmax\nrb\trb\tsid-rb\t30\t3600\t-\t-\t80\naide\tinbox\t-\t0\t0\t-\t-\t-\n' >"$T/seats.tsv"
printf '# rules\nCLAUDE-RULE-TOKEN rule-in-claude.sh\n' >"$T/CLAUDE.md"; printf '# agents\nagents-only-token.md\n' >"$T/AGENTS.md"
printf '## Stage\nstage-line-token.md here\n## Other\nother-section-token.md\n' >"$T/goal.md"
printf '# playbook\nPLAYBOOK-ONLY-SCRIPT: run playbook_only_script.sh now\nsummary-carried-script.sh is also in the playbook\nclaude-md-script rule-in-claude.sh also here\nstage-line-token.md again\nhook-injected-script.sh is only in the hook\n' >"$T/playbook.md"
printf '%s\n' '- [index line](x.md)' '- [handoff pointer](handoff-rb-20261013.md)' 'LIVE TRAPS (last 3 days):' '- [KEPT TRAP kept_trap_script.sh](t.md)' 'ARCHIVES (read only for a dated detail):' '- [ARCHIVE line archive_only_script.sh](a.md)' >"$T/MEMORY.md"
now=$(date -u -d 2026-10-27T00:00:00Z +%s)
J="$T/jd/sid-rb.jsonl"
L() { printf '%s\n' "$1" >>"$J"; }
act() { # <ts> <bash command> [sidechain]
  L "{\"type\":\"assistant\",\"timestamp\":\"$1\",\"isSidechain\":${3:-false},\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"$2\"}}]}}"; }
# out-of-window segment (10 days old): must be ignored entirely
L '{"type":"system","subtype":"compact_boundary","timestamp":"2026-10-17T01:00:00.000Z","compactMetadata":{"trigger":"auto"}}'
act 2026-10-17T01:00:05.000Z 'bash playbook_only_script.sh'
# in-window segment
L '{"type":"system","subtype":"compact_boundary","timestamp":"2026-10-26T01:00:00.000Z","compactMetadata":{"trigger":"auto"}}'
L '{"type":"attachment","timestamp":"2026-10-26T01:00:01.000Z","attachment":{"type":"instructions","files":[{"path":"/h/.claude/projects/-home-jsy/memory/MEMORY.md","content":"archive_only_script.sh in the memory copy"}]}}'
L '{"type":"attachment","timestamp":"2026-10-26T01:00:01.000Z","attachment":{"type":"hook_success","hookEvent":"SessionStart","command":"sh -c exec seat-context-start.sh","content":"hook-injected-script.sh playbook_only_script.sh"}}'
L '{"type":"user","isCompactSummary":true,"timestamp":"2026-10-26T01:00:02.000Z","message":{"role":"user","content":"summary mentions summary-carried-script.sh and then moves on"}}'
act 2026-10-26T01:01:00.000Z 'bash playbook_only_script.sh --now'
act 2026-10-26T01:02:00.000Z 'bash summary-carried-script.sh'
act 2026-10-26T01:03:00.000Z 'bash rule-in-claude.sh && cat stage-line-token.md agents-only-token.md'
act 2026-10-26T01:04:00.000Z 'bash hook-injected-script.sh'
act 2026-10-26T01:05:00.000Z 'bash archive_only_script.sh'
act 2026-10-26T01:06:00.000Z 'bash kept_trap_script.sh'
act 2026-10-26T01:07:00.000Z 'bash playbook_only_script.sh again' true
# a token the seat has already seen in the segment (a tool result) is carried
L '{"type":"user","timestamp":"2026-10-26T02:00:00.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"ls shows playbook_only_script.sh"}]}}'
act 2026-10-26T02:01:00.000Z 'bash playbook_only_script.sh once more'
run() { env -i PATH="$PATH" HOME="$T" SEATS_TSV="$T/seats.tsv" JSONL_DIR="$T/jd" MEMORY_MD="$T/MEMORY.md" PLAYBOOK="$T/playbook.md" GOAL="$T/goal.md" CLAUDE_MD="$T/CLAUDE.md" AGENTS_MD="$T/AGENTS.md" SKILLS_DIR="$T/skills" SEAT_FLOOR_NOW="$now" bash "$F" "$@" 2>&1; }
out="$(run)"; rc=$?
[ "$rc" = 0 ]; chk "report mode exits 0" $?
echo "$out" | grep -q '^HIT rb 2026-10-26T01:01:00.000Z Bash token=playbook_only_script.sh <- playbook:2'; chk "playbook-only token in an action = HIT naming playbook:2" $?
echo "$out" | grep -q '^HIT rb 2026-10-26T01:04:00.000Z Bash token=hook-injected-script.sh <- playbook:6'; chk "token only in the seat-context-start hook stdout still HITs (the cut removes it)" $?
echo "$out" | grep -q '^HIT rb 2026-10-26T01:05:00.000Z Bash token=archive_only_script.sh <- memory:6'; chk "token only in the MEMORY.md copy / an ARCHIVES line = HIT memory:6" $?
! echo "$out" | grep -q 'summary-carried-script.sh <-'; chk "token in the segment summary is not a hit" $?
! echo "$out" | grep -q 'rule-in-claude.sh <-' && ! echo "$out" | grep -q 'stage-line-token.md <-' && ! echo "$out" | grep -q 'agents-only-token.md <-'; chk "tokens in CLAUDE.md / AGENTS.md / § Stage are not hits" $?
! echo "$out" | grep -q 'kept_trap_script.sh <-'; chk "a LIVE TRAPS line is in the kept set: no hit" $?
! echo "$out" | grep -q '2026-10-17'; chk "out-of-window segment ignored" $?
! echo "$out" | grep -q '2026-10-26T01:07'; chk "sidechain action ignored" $?
! echo "$out" | grep -q '2026-10-26T02:01'; chk "a token already seen in the segment (tool result) is carried: no hit" $?
echo "$out" | grep -q '^HITS=3 UNIQUE_LINES=3 SEGMENTS=1 '; chk "totals: 3 hits, 3 unique lines, 1 in-window segment ($(echo "$out" | tail -1))" $?
echo "$out" | sed -n '/^KEEP/,$p' | grep -q 'playbook:2 seats=rb' && echo "$out" | grep -q '^skills rb: seat set .*dream'; chk "KEEP list + per-seat skills line printed" $?
echo "$out" | grep -q 'rb: 1 segments'; chk "aide (sid -) not scanned" $?
run --fail-on-hit >/dev/null; [ "$?" = 1 ]; chk "--fail-on-hit exits 1 when there are hits" $?
: >"$J"; out="$(run --fail-on-hit)"; rc=$?; [ "$rc" = 0 ] && echo "$out" | grep -q '^HITS=0 '; chk "no hits: HITS=0, --fail-on-hit exits 0" $?
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"; exit "$fail"
