#!/usr/bin/env bash
# PRD agorabus-overlap-warning-hook AC6: with no daemon socket the hook exits
# 0, prints nothing, and finishes in < 200 ms — with the real agorabus binary
# (if installed) pointed at an empty HOME, with no agorabus on PATH, and with
# a daemon that hangs.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/agorabus-overlap-warning-hook_test_helpers.sh"
. "$here/lib/timing.sh"
overlap_setup
payload="{\"cwd\":\"$cwd\",\"prompt\":\"hi\"}"
mkdir -p "$work/home" "$work/nobin"
for t in jq bash cat mktemp rm mkfifo kill sleep cksum date; do
  p=$(command -v "$t") && ln -sf "$p" "$work/nobin/$t"
done
cat >"$work/hang" <<'SH'
#!/usr/bin/env bash
exec sleep 30
SH
chmod +x "$work/hang"
mkdir -p "$work/hangbin"; ln -s "$work/hang" "$work/hangbin/agorabus"
real=$(PATH="${PATH#"$work/bin:"}" command -v agorabus || true)

# One sample: the hook run under $1=PATH $2=HOME with a fresh state dir
# ($MED_STATE, from med_ms). Functional asserts hold on EVERY sample.
one_sample() {
  local out rc
  out=$(printf '%s' "$payload" | env -u CLAUDE_AGORABUS_SID CLAUDE_AGORABUS_SID="$sid" \
    AGORABUS_INTENT_STATE_DIR="$MED_STATE" HOME="$S_HOME" PATH="$S_PATH" "$HOOK"); rc=$?
  [ "$rc" = 0 ] || { echo "NOT OK - $S_LABEL: exit $rc"; fail=1; }
  [ -z "$out" ] || { echo "NOT OK - $S_LABEL: stdout '$out'"; fail=1; }
}
check() { # $1=label $2=PATH $3=HOME
  S_LABEL="$1" S_PATH="$2" S_HOME="$3"
  med_ms 3 one_sample && echo "ok - $1: median ${MED_MS} ms < 200, every sample < 1000" \
    || { echo "NOT OK - $1: median ${MED_MS} ms, samples ${MED_SAMPLES[*]}"; fail=1; }
}
check "no agorabus binary" "$work/nobin" "$work/home"
check "hanging daemon" "$work/hangbin:$work/nobin" "$work/home"
[ -n "$real" ] && check "real binary, no socket" "$(dirname "$real"):$work/nobin" "$work/home"
exit $fail
