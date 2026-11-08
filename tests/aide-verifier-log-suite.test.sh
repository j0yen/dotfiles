#!/usr/bin/env bash
# tests/aide-verifier-log-suite.test.sh (A649): launch --log writes suite.txt = the log's exact WM-VERIFY CMD= trailer (rb-merge.sh admits only the log whose CMD equals it).
# Fakes only, throwaway HOME: no systemd unit, no claude, no wm-decide row, no network. Run: bash tests/aide-verifier-log-suite.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../.local/bin/aide-verifier.sh"
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
th=$(mktemp -d "${TMPDIR:-/tmp}/aide-verifier-logsuite.XXXXXX"); trap 'rm -rf "$th"' EXIT
mkdir -p "$th/home/.config/environment.d" "$th/bin" "$th/av" "$th/gate/wm_decide" "$th/gate/gen"
: >"$th/home/.config/environment.d/90-claude-oauth.conf"
H=0123456789abcdef0123456789abcdef01234567; G=d-20261023-055214-aide-49cf
printf '[{"id":"%s","agent":"aide","what":"GATED j0yen/dotfiles#7 COMMIT=%s agent=coder:avl done","why":"","evidence":""}]\n' "$G" "$H" >"$th/rows.json"
printf '#!/bin/bash\nexit 0\n' >"$th/bin/fake-systemctl"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"$FAKE_DIR/sdrun.log"\n' >"$th/bin/fake-sdrun"
printf '#!/bin/bash\necho "{\\"ok\\":true,\\"room_mb\\":9000}"\n' >"$th/bin/fake-room"
printf '#!/bin/bash\nexit 0\n' >"$th/bin/fake-bell"
printf '#!/bin/bash\n[ "$1" = list ] && [ "$2" = --json ] && cat "$FAKE_DIR/rows.json"\nexit 0\n' >"$th/bin/fake-wmd"
printf '#!/bin/bash\nprintf "%%s\\n" "%s"\n' "$H" >"$th/bin/gh"
: >"$th/gate/wm_decide/__init__.py"
printf '{"repo_tokens": {"j0yen/dotfiles": ["tests/*.test.sh EXIT=0"]}}\n' >"$th/gate/gen/merge-gate.json"
printf 'def canon_agent(a):\n    return a\n' >"$th/gate/wm_decide/contract.py"
cat >"$th/gate/wm_decide/mergegate.py" <<'F'
import re
from . import contract
AGENT_RE = re.compile(r"\bagent=([A-Za-z0-9:._-]+)")
AUTHOR_RE = re.compile(r"\bauthor=([A-Za-z0-9:._-]+)")
ANY_OF = " || "
def strip_attachments(evidence):
    return evidence or ""
def _agent_token(row, rx=AGENT_RE):
    for k in ("what", "evidence", "why"):
        m = rx.search(row.get(k) or "")
        if m: return m.group(1)
    return None
def g3_missing(tokens, atts, commit):
    return [t for t in tokens if not (t.endswith(" EXIT=0") and any(t[:-7] in (a["trailer"].get("CMD") or "") for a in atts))], None
F
printf '#!/bin/bash\nif [ "$1" = local ]; then grep -m1 "^WM-VERIFY CMD=" "$2"; else echo "WM-VERIFY CMD=bash -c for t in tests/*.test.sh; do bash \\$t; done"; fi\n' >"$th/bin/fake-logcmd"
chmod +x "$th"/bin/*
TOK='tests/*.test.sh EXIT=0'
lc() {  # lc <name> <args...>: launch under fakes; stdout+stderr
  local nm="$1"; shift
  HOME="$th/home" FAKE_DIR="$th" AIDE_VERIFIER_DIR="$th/av" AIDE_VERIFIER_ROOM_CMD="$th/bin/fake-room" AIDE_VERIFIER_SYSTEMD_RUN="$th/bin/fake-sdrun" \
    AIDE_VERIFIER_SYSTEMCTL="$th/bin/fake-systemctl" AIDE_VERIFIER_BELL="$th/bin/fake-bell" AIDE_VERIFIER_WM_DECIDE="$th/bin/fake-wmd" AIDE_VERIFIER_GATE_ROOT="$th/gate" AIDE_VERIFIER_LOGCMD_CMD="$th/bin/fake-logcmd" \
    PATH="$th/bin:$PATH" AIDE_VERIFIER_CGROUP_FILE="$th/cgroup-absent" AIDE_VERIFIER_SELFTEST=1 AIDE_VERIFIER_SLOT_CEIL=2 AIDE_VERIFIER_POLL_S=1 \
    bash "$script" launch "$nm" --repo j0yen/dotfiles --pr 7 --gated "$G" --token "$TOK" --head "$H" "$@" 2>&1
}
P() { cat "$th/av/$1/prompt.md"; }
FULL='bash -c for t in tests/*.test.sh; do bash $t; done'
printf 'noise\nWM-VERIFY HEAD=%s\nWM-VERIFY CMD=%s\nWM-VERIFY EXIT=0\n' "$H" "$FULL" >"$th/good.log"
printf 'WM-VERIFY CMD=pytest -q\n' >"$th/other.log"
printf 'noise only\n' >"$th/nocmd.log"

# (a) token prefix shorter than the CMD -> suite.txt is the full CMD
out=$(lc a1 --log "$th/good.log"); rc=$?
[ "$rc" = 0 ] && [ "$(cat "$th/av/a1/suite.txt")" = "$FULL" ] && pass "(a) token prefix shorter than CMD: suite.txt = the log's full CMD" || bad "(a) rc=$rc suite.txt='$(cat "$th/av/a1/suite.txt" 2>/dev/null)' $out"
# (a2) remote log through the injected read
out=$(lc a2 --log ryzen7:/home/jsy/x.log); rc=$?
[ "$rc" = 0 ] && [ "$(cat "$th/av/a2/suite.txt")" = "$FULL" ] && pass "(a2) ryzen7: log: suite.txt = the CMD read through the injected read" || bad "(a2) rc=$rc $out"
# (b) CMD lacks the token prefix -> rc 2 naming both strings
out=$(lc b1 --log "$th/other.log"); rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"lint:"* ]] && [[ "$out" == *"pytest -q"* ]] && [[ "$out" == *"tests/*.test.sh"* ]] && [ ! -e "$th/av/b1/state" ] && pass "(b) CMD lacks the token prefix: rc 2, lint names both strings" || bad "(b) rc=$rc $out"
# (c) log without a CMD trailer -> rc 2
out=$(lc c1 --log "$th/nocmd.log"); rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"lint:"* ]] && [[ "$out" == *"WM-VERIFY CMD="* ]] && pass "(c) log without a CMD trailer: rc 2" || bad "(c) rc=$rc $out"
out=$(lc c2 --log "$th/missing.log"); rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"lint:"* ]] && pass "(c2) unreadable log: rc 2" || bad "(c2) rc=$rc $out"
# (d) suite mode unchanged
out=$(lc d1 --suite 'for t in tests/*.test.sh; do bash $t; done'); rc=$?
[ "$rc" = 0 ] && [ "$(cat "$th/av/d1/suite.txt")" = 'for t in tests/*.test.sh; do bash $t; done' ] && pass "(d) suite mode: suite.txt = --suite" || bad "(d) rc=$rc $out"

[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILED"
exit "$fail"
