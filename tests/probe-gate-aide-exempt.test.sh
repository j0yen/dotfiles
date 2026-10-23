#!/usr/bin/env bash
# probe-gate aide exemption: the aide (WM_SEAT=aide, exported only by
# aide-launch.sh) is NOT gated; a seat (WM_SEAT=ctl), a tmux session and a
# plain `claude` on carbon (no marker: Joe's own session, 10-23) ARE gated (exit 2).
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
gate="$here/.claude/hooks/probe-gate.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
tr="$tmp/transcript.jsonl"
id="toolu_test_aide_exempt_01"
printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"model\":\"claude-fable-5-1\",\"content\":[{\"type\":\"tool_use\",\"id\":\"$id\",\"name\":\"Bash\",\"input\":{\"command\":\"cat /etc/hostname\"}}]}}" > "$tr"
input="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat /etc/hostname\"},\"session_id\":\"s\",\"transcript_path\":\"$tr\",\"tool_use_id\":\"$id\"}"
fail=0
run() { # name expected_rc env...
    local name="$1" want="$2"; shift 2
    local rc=0
    printf '%s' "$input" | env -u WM_SEAT -u TMUX HOME="$tmp" "$@" bash "$gate" >/dev/null 2>&1 || rc=$?
    if [ "$rc" = "$want" ]; then echo "PASS $name (rc=$rc)"; else echo "FAIL $name (rc=$rc want $want)"; fail=1; fi
}
run aide-marker-exempt         0 PROBE_GATE_HOSTNAME=carbon WM_SEAT=aide
run aide-marker-exempt-anyhost 0 PROBE_GATE_HOSTNAME=redbaron WM_SEAT=aide
run plain-carbon-gated         2 PROBE_GATE_HOSTNAME=carbon
run seat-unit-gated            2 PROBE_GATE_HOSTNAME=carbon WM_SEAT=ctl
run tmux-seat-gated            2 PROBE_GATE_HOSTNAME=carbon TMUX=/tmp/tmux-1000/default,1,0
run other-host-gated           2 PROBE_GATE_HOSTNAME=redbaron
grep -q '"${WM_SEAT:-}" = aide' "$gate" && echo "PASS gate-has-aide-predicate" || { echo "FAIL gate-has-aide-predicate"; fail=1; }
if sed 's/#.*//' "$gate" | grep -q 'hostname'; then echo "FAIL gate-still-reads-hostname"; fail=1; else echo "PASS gate-does-not-infer-aide-from-hostname"; fi
exit $fail
