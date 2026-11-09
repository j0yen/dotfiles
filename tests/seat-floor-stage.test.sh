#!/usr/bin/env bash
# tests/seat-floor-stage.test.sh -- M9 mechanism 7 (dotfiles side): the per-stage flag in seat-lean.sh. Default OFF (stage 0); env SEAT_FLOOR_STAGE wins over floor-stage.json;
# junk values read as 0; seat_floor_stage_on n is >= n. The shipped floor-stage.json is stage 0 with an expected_p50 for ctl/rb/r7 (the probe's alarm threshold source).
# Also pins that the LEAN_FLAGS / LEAN_ENV_VARS contract lines are unchanged by the flag.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"; L="$root/.local/bin/seat-lean.sh"; SF="$root/.config/claude-seat/floor-stage.json"
fail=0; chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
T="$(mktemp -d "${TMPDIR:-/tmp}/sfs.XXXXXX")"; trap 'rm -rf "$T"' EXIT
st() { env -i PATH="$PATH" HOME="$T" "$@" bash -c '. "'"$L"'"; seat_floor_stage'; }
on() { env -i PATH="$PATH" HOME="$T" "${@:2}" bash -c '. "'"$L"'"; seat_floor_stage_on '"$1"; }
jq -e '.stage == 0 and (.expected_p50 | has("ctl") and has("rb") and has("r7"))' "$SF" >/dev/null; chk "shipped floor-stage.json = stage 0 with expected_p50 ctl/rb/r7" $?
[ "$(st)" = 0 ]; chk "no env, no file -> stage 0 (OFF)" $?
mkdir -p "$T/.config/claude-seat"; echo '{"stage":2}' >"$T/.config/claude-seat/floor-stage.json"
[ "$(st)" = 2 ]; chk "file stage 2 -> 2" $?
[ "$(st SEAT_FLOOR_STAGE=1)" = 1 ]; chk "env wins over the file" $?
[ "$(st SEAT_FLOOR_STAGE=junk)" = 0 ]; chk "junk env -> 0" $?
echo '{"stage":"x"}' >"$T/.config/claude-seat/floor-stage.json"; [ "$(st)" = 0 ]; chk "junk file value -> 0" $?
echo '{"stage":3}' >"$T/.config/claude-seat/floor-stage.json"
on 3; a=$?; on 4; b=$?; on 1; c=$?
[ "$a" = 0 ] && [ "$b" != 0 ] && [ "$c" = 0 ]; chk "seat_floor_stage_on: 3>=3 yes, 3>=4 no, 3>=1 yes" $?
[ "$(env -i PATH="$PATH" HOME="$T" bash -c '. "'"$L"'"; echo "$LEAN_ENV_VARS|$LEAN_FLAGS"')" = 'SEAT_LEAN=1 CLAUDE_LEAN_START=1|--settings $HOME/.config/claude-seat/settings.json --mcp-config $HOME/.config/claude-seat/mcp.json --strict-mcp-config' ]; chk "LEAN_ENV_VARS / LEAN_FLAGS contract unchanged" $?
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"; exit "$fail"
