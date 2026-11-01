#!/usr/bin/env bash
# tests/aide-verifier-log-model.test.sh (A39): aide-verifier.sh launch --log (log-only verifier, no suite on carbon) and --model sonnet|opus.
# Fakes only, throwaway HOME: no systemd unit, no claude, no wm-decide row, no network (fake gh, fake systemd-run, stub merge-gate tree). Run: bash tests/aide-verifier-log-model.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../.local/bin/aide-verifier.sh"
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
th=$(mktemp -d "${TMPDIR:-/tmp}/aide-verifier-logmodel.XXXXXX"); trap 'rm -rf "$th"' EXIT
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
chmod +x "$th"/bin/*
TOK='tests/*.test.sh EXIT=0'
lc() {  # lc <name> <args...>: launch under fakes; stdout+stderr
  local nm="$1"; shift
  HOME="$th/home" FAKE_DIR="$th" AIDE_VERIFIER_DIR="$th/av" AIDE_VERIFIER_ROOM_CMD="$th/bin/fake-room" AIDE_VERIFIER_SYSTEMD_RUN="$th/bin/fake-sdrun" \
    AIDE_VERIFIER_SYSTEMCTL="$th/bin/fake-systemctl" AIDE_VERIFIER_BELL="$th/bin/fake-bell" AIDE_VERIFIER_WM_DECIDE="$th/bin/fake-wmd" AIDE_VERIFIER_GATE_ROOT="$th/gate" \
    PATH="$th/bin:$PATH" AIDE_VERIFIER_CGROUP_FILE="$th/cgroup-absent" AIDE_VERIFIER_SELFTEST=1 AIDE_VERIFIER_SLOT_CEIL=2 AIDE_VERIFIER_POLL_S=1 \
    bash "$script" launch "$nm" --repo j0yen/dotfiles --pr 7 --gated "$G" --token "$TOK" --head "$H" "$@" 2>&1
}
P() { cat "$th/av/$1/prompt.md"; }

# --log local
out=$(lc lg1 --log /tmp/x.log); rc=$?
p=$(P lg1)
[ "$rc" = 0 ] && pass "--log /tmp/x.log launches (rc 0)" || bad "--log /tmp/x.log rc=$rc: $out"
! grep -q 'wm-verify-run .*\(cd\|&&\)' <<<"$p" && ! grep -qF 'cd $d/repo && ~/.local/bin/wm-verify-run' <<<"$p" && pass "log prompt has no wm-verify-run call" || bad "log prompt still calls wm-verify-run"
grep -qF 'FORBIDDEN on carbon: pytest, uv, cargo, make, wm-verify-run' <<<"$p" && pass "log prompt names the forbidden tools" || bad "FORBIDDEN line missing"
grep -qF "cp /tmp/x.log $th/av/lg1/bundle.log" <<<"$p" && pass "log prompt copies the log with cp /tmp/x.log" || bad "cp line missing"
! grep -q 'scp' <<<"$(grep -F 'Fetch the log' <<<"$p")" && pass "local log renders no scp fetch" || bad "local log renders scp"
grep -qF "grep -c '^WM-VERIFY HEAD=$H\$'" <<<"$p" && grep -qF "grep -c '^WM-VERIFY EXIT=0\$'" <<<"$p" && grep -qF "grep -c '^WM-VERIFY DIRTY=0\$'" <<<"$p" && grep -qF "grep '^WM-VERIFY CMD='" <<<"$p" \
  && pass "log prompt has the three WM-VERIFY greps and the CMD print" || bad "WM-VERIFY greps missing"
grep -qF "sha256sum $th/av/lg1/bundle.log" <<<"$p" && grep -qF -- "--attach $th/av/lg1/bundle.log" <<<"$p" && grep -qF 'log-only (suite ran on local under wm-verify-run)' <<<"$p" \
  && pass "log prompt records sha256, attaches bundle.log, says log-only" || bad "sha/attach/log-only wording missing"
grep -qF -- "grep -cF -- 'tests/*.test.sh'" <<<"$p" && pass "log prompt checks the token prefix in the CMD line" || bad "CMD prefix check missing"
grep -qx 'log=/tmp/x.log' "$th/av/lg1/meta" && grep -qx 'model=sonnet' "$th/av/lg1/meta" && pass "meta has log= and model=sonnet" || bad "meta log=/model= missing"
grep -qF 'wm-decide record --agent aide --via verifier --model sonnet --kind verdict' <<<"$p" && grep -q -- '--model claude-sonnet-5-5 ' "$th/av/lg1/launch.sh" && pass "default model stays sonnet (row and launch.sh)" || bad "default model is not sonnet"
bash -n "$th/av/lg1/launch.sh" && pass "launch.sh parses" || bad "launch.sh does not parse"

# --log remote
out=$(lc lg2 --log ryzen7:/home/jsy/x.log); rc=$?
p=$(P lg2)
[ "$rc" = 0 ] && [ "$(grep -cF 'scp -q ryzen7:/home/jsy/x.log' <<<"$p")" = 1 ] && [ "$(grep -o 'scp -q' <<<"$p" | wc -l)" = 1 ] && pass "remote log renders exactly one scp -q ryzen7:/home/jsy/x.log" || bad "remote scp count wrong (rc=$rc)"
grep -qF 'log-only (suite ran on ryzen7 under wm-verify-run)' <<<"$p" && pass "remote log row says log-only on ryzen7" || bad "remote log-only wording missing"
out=$(lc lg3 --log redbaron:/a/b.log); rc=$?
[ "$rc" = 0 ] && grep -qF 'scp -q redbaron:/a/b.log' "$th/av/lg3/prompt.md" && pass "redbaron host accepted" || bad "redbaron host rejected"
out=$(lc lg4 --log carbon:/a/b.log); rc=$?
[ "$rc" = 2 ] && [ ! -e "$th/av/lg4" ] && pass "unknown host exits 2" || bad "unknown host not refused (rc=$rc)"
out=$(lc lg5 --log 'rel/x.log'); rc=$?
[ "$rc" = 2 ] && pass "relative log path exits 2" || bad "relative path not refused (rc=$rc)"

# suite mode unchanged
out=$(lc su1 --suite 'bash tests/run.sh; echo "tests/*.test.sh EXIT=$?"'); rc=$?
p=$(P su1)
[ "$rc" = 0 ] && grep -qF "wm-verify-run 'bash tests/run.sh; echo \"tests/*.test.sh EXIT=\$?\"'" <<<"$p" && ! grep -qF 'log-only' <<<"$p" && grep -qx 'log=' "$th/av/su1/meta" && pass "suite mode still runs wm-verify-run, no log-only text, meta log= empty" || bad "suite mode changed (rc=$rc)"

# exclusivity
out=$(lc ex1 --log /tmp/x.log --suite 's'); rc=$?
[ "$rc" != 0 ] && [[ "$out" == *"mutually exclusive"* ]] && pass "--log with --suite exits non-zero" || bad "--log+--suite accepted (rc=$rc)"
out=$(lc ex2); rc=$?
[ "$rc" != 0 ] && [[ "$out" == *"exactly one of"* ]] && pass "neither --log nor --suite exits non-zero" || bad "neither accepted (rc=$rc)"

# model
out=$(lc md1 --log /tmp/x.log --model opus); rc=$?
[ "$rc" = 0 ] && grep -q -- '--model claude-opus-5-5 ' "$th/av/md1/launch.sh" && ! grep -q 'claude-sonnet-5-5' "$th/av/md1/launch.sh" && grep -qF 'wm-decide record --agent aide --via verifier --model opus --kind verdict' "$th/av/md1/prompt.md" \
  && grep -qx 'model=opus' "$th/av/md1/meta" && pass "--model opus: claude-opus-5-5 in launch.sh, --model opus on the row, model=opus in meta" || bad "--model opus wiring wrong (rc=$rc)"
out=$(lc md2 --suite s --model haiku); rc=$?
[ "$rc" != 0 ] && [[ "$out" == *"--model must be sonnet or opus"* ]] && [ ! -e "$th/av/md2" ] && pass "--model haiku exits non-zero" || bad "--model haiku accepted (rc=$rc)"
out=$(lc md3 --suite 'bash tests/run.sh; echo "tests/*.test.sh EXIT=$?"' --model opus); rc=$?
[ "$rc" = 0 ] && grep -q -- '--model claude-opus-5-5 ' "$th/av/md3/launch.sh" && pass "--model opus works in suite mode too" || bad "--model opus in suite mode failed (rc=$rc)"

# usage text
u=$(HOME="$th/home" bash "$script" launch 2>&1)
[[ "$u" == *"--log"* ]] && [[ "$u" == *"--model"* ]] && pass "usage lists --log and --model" || bad "usage lacks --log or --model"
grep -qF -- '[--model sonnet|opus]' "$script" && grep -qF -- '--log <abs path' "$script" && pass "header usage lists --log and --model" || bad "header usage lacks --log/--model"

[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILED"
exit "$fail"
