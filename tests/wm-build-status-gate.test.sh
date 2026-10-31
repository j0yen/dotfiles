#!/usr/bin/env bash
# tests/wm-build-status-gate.test.sh -- .claude/hooks/wm-build-status-gate.sh (PreToolUse Bash, every session) refuses a top-level
# `wm-build status` / `wm-build runs`, and shares ONE classifier (lib/wmb-classify.sh) with rb's host-side shim (dotfiles#94).
# Everything runs under a throwaway HOME (no real command is executed, nothing real is written). Run: bash tests/wm-build-status-gate.test.sh
set -uo pipefail
# repo paths are pinned BEFORE HOME is swapped
here=$(cd "$(dirname "$0")/.." && pwd)
hook="$here/.claude/hooks/wm-build-status-gate.sh"
lib="$here/.claude/hooks/lib/wmb-classify.sh"
shim="$here/.local/bin/wm-build-bound-shim.sh"
settings="$here/.claude/settings.json"
# the pin: wmb_classify as taken from dotfiles#94 at this head (text = `wmb_classify() {` .. closing `}`)
WMB_SRC_SHA=598678cd925ce89980fd3f67b859ea9f633039aa
WMB_FN_SHA256=b3ddff38d9f394bc38be7e45797ff64a2a2378d27a9f242c9e543ff4e57d69f4
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" XDG_CACHE_HOME="$tmp/home/.cache" XDG_STATE_HOME="$tmp/home/.state" TMPDIR="$tmp"
mkdir -p "$HOME"
fail=0
chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
fn_text() { sed -n '/^wmb_classify() {$/,/^}$/p' "$1"; }

out=$(bash "$hook" --selftest 2>&1); rc=$?
printf '%s\n' "$out" | grep -v '^PASS' | grep -E '^(FAIL|selftest)' || true
[ "$rc" = 0 ] && ! printf '%s\n' "$out" | grep -q '^FAIL'; chk "selftest rc 0, no FAIL (rc=$rc)" $?
n=$(printf '%s\n' "$out" | grep -c '^PASS'); [ "$n" -ge 35 ]; chk "selftest ran >= 35 passing cases (n=$n)" $?

command -v jq >/dev/null; chk "jq present" $?
[ -x "$hook" ]; chk "hook is executable" $?
jq -e '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]?.command | select(endswith("/.claude/hooks/wm-build-status-gate.sh"))] | length == 1' \
    "$settings" >/dev/null; chk "settings.json registers wm-build-status-gate.sh once under PreToolUse matcher Bash" $?

# --- stdin-JSON end to end -------------------------------------------------------------------------
run_hook() { # run_hook <hook-path> <stdin>: sets rc / err
    err=$(printf '%s' "$2" | bash "$1" 2>&1 >/dev/null); rc=$?
}
j() { jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
run_hook "$hook" "$(j "timeout 20 ssh ryzen7 'wm-build status'")"
[ "$rc" = 2 ] && [[ $err == *'cat ~/.cache/fleet-dash/status.json'* ]]; chk "e2e deny: rc 2 + refusal on stderr (rc=$rc)" $?
run_hook "$hook" "$(j 'wm-build land status')"
[ "$rc" = 0 ] && [ -z "$err" ]; chk "e2e allow: rc 0, silent (rc=$rc)" $?
rm -rf "$XDG_CACHE_HOME"
run_hook "$hook" '{not json'
[ "$rc" = 0 ] && grep -qE '^[0-9T:Z-]+ bad-json$' "$XDG_CACHE_HOME/wm-build-status-gate/fail-open.log"; chk "e2e malformed JSON: rc 0 and one counted line in fail-open.log (rc=$rc)" $?
mkdir -p "$tmp/nolib/.claude/hooks"; cp "$hook" "$tmp/nolib/.claude/hooks/"
run_hook "$tmp/nolib/.claude/hooks/wm-build-status-gate.sh" "$(j 'wm-build status')"
[ "$rc" = 0 ] && grep -q ' lib-missing$' "$XDG_CACHE_HOME/wm-build-status-gate/fail-open.log"; chk "e2e lib missing: fails open rc 0, counted as lib-missing (rc=$rc)" $?
big=$(head -c 14000 /dev/zero | tr '\0' a); big="echo $big"
run_hook "$hook" "$(j "$big")"
[ "$rc" = 0 ] && grep -q ' oversize$' "$XDG_CACHE_HOME/wm-build-status-gate/fail-open.log"; chk "e2e oversize (> 12 KB non-heredoc): fails open rc 0, counted (rc=$rc)" $?
! grep -qE 'wm-build|status' "$XDG_CACHE_HOME/wm-build-status-gate/fail-open.log"; chk "fail-open.log carries no command text" $?

# --- NO-DRIFT: one pattern ---------------------------------------------------------------------------
# (a) the lib function is pinned to the text of dotfiles#94 at $WMB_SRC_SHA; a #94 amendment must land as a red test, never a SKIP
got=$(fn_text "$lib" | sha256sum | cut -d' ' -f1)
[ "$got" = "$WMB_FN_SHA256" ]; chk "no-drift (a) lib wmb_classify sha256 == pin from #94@${WMB_SRC_SHA:0:8} (got ${got:0:12})" $?
if [ -f "$shim" ]; then
    [ "$(fn_text "$shim")" = "$(fn_text "$lib")" ] && [ -n "$(fn_text "$shim")" ]; chk "no-drift (a) shim wmb_classify body byte-identical to the lib's" $?
else
    echo "NOTE no-drift (a): shim not in tree; the lib is held by the sha pin only"
fi

# (b) bound set is exactly {status, runs} (premise: rb 1e3f; log/live/run list not measured; widening = lib + fixture edit)
( . "$lib"; set=''; for w in status runs queue scan daemon builder run drive land circuit log live list show close redrive pause unpause config \
        doctor version help probe release promote merge dream prd prds ledger cap limits unit units slot slots journal history gc; do
      [ "$(wmb_classify "$w")" = bound ] && set="$set $w"; done; echo "$set" ) > "$tmp/boundset" 2>/dev/null
bset=$(tr ' ' '\n' < "$tmp/boundset" | grep . | sort | tr '\n' ' ')
[ "$bset" = "runs status " ]; chk "bound subcommand set is exactly {status, runs} (got: $bset)" $?
[ "$(fn_text "$lib" | grep -c 'status|runs)')" = 2 ]; chk "lib has exactly the two status|runs arms (fallback + subcommand)" $?

# (c) the shim's 29-case selftest table through the LIB and through the HOOK (deny iff bound)
if [ -f "$shim" ]; then
    sed -n "/<<'CASES'\$/,/^CASES\$/p" "$shim" | sed '1d;$d' > "$tmp/cases"; src=shim
else
    cat > "$tmp/cases" <<'CASES'
bound status
bound runs
bound status --json
bound status --brief
bound status --flakes --days 3
bound --state-dir /x status --brief
bound --config /c runs
bound --prd-dir /p --state-dir /s status
bound --max-runs 2 status
bound --set a.b=status status
bound --state-dir=/x runs
bound -j4 status
bound --json status
pass --set status=1 queue
pass --config status queue
pass run close 5 --reason status
pass run redrive 5 --from land
pass run show 5
pass drive --run 1042
pass daemon
pass --version
pass -V
pass --help
pass builder probe
pass queue
pass scan
pass
pass --state-dir /x
pass --config
CASES
    src=fixture
fi
nc=$(grep -c . "$tmp/cases"); [ "$nc" -ge 29 ]; chk "no-drift (c) fixture has >= 29 cases (n=$nc, from $src)" $?
lbad=0; hbad=0
while IFS= read -r line; do
    [ -n "$line" ] || continue
    want=${line%% *}; argv=${line#"$want"}; argv=${argv# }
    # shellcheck disable=SC2086
    got=$( . "$lib"; wmb_classify $argv )
    [ "$got" = "$want" ] || { echo "  lib drift: [$argv] want $want got $got"; lbad=$((lbad + 1)); }
    run_hook "$hook" "$(j "wm-build $argv")"
    if [ "$want" = bound ]; then [ "$rc" = 2 ] || { echo "  hook drift: [wm-build $argv] want deny got rc=$rc"; hbad=$((hbad + 1)); }
    else [ "$rc" = 0 ] || { echo "  hook drift: [wm-build $argv] want allow got rc=$rc"; hbad=$((hbad + 1)); }; fi
done < "$tmp/cases"
[ "$lbad" = 0 ]; chk "no-drift (c) every fixture case through the LIB matches the table ($lbad bad)" $?
[ "$hbad" = 0 ]; chk "no-drift (c) every fixture case through the HOOK denies iff bound ($hbad bad)" $?
exit $fail
