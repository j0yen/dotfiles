#!/usr/bin/env bash
# PRD agorabus-overlap-warning-hook AC6: with no daemon socket the hook exits
# 0, prints nothing, and finishes in < 200 ms — with the real agorabus binary
# (if installed) pointed at an empty HOME, with no agorabus on PATH, and with
# a daemon that hangs.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/agorabus-overlap-warning-hook_test_helpers.sh"
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

check() { # $1=label $2=PATH $3=HOME
  local start end ms out rc
  start=$(date +%s%N)
  out=$(printf '%s' "$payload" | env -u CLAUDE_AGORABUS_SID CLAUDE_AGORABUS_SID="$sid" \
    AGORABUS_INTENT_STATE_DIR="$work/state" HOME="$3" PATH="$2" "$HOOK"); rc=$?
  end=$(date +%s%N); ms=$(( (end - start) / 1000000 ))
  assert_eq "$rc" "0" "$1: exit 0"
  assert_eq "$out" "" "$1: no stdout"
  [ "$ms" -lt 200 ] && echo "ok - $1: ${ms} ms < 200" || { echo "NOT OK - $1: ${ms} ms"; fail=1; }
}
check "no agorabus binary" "$work/nobin" "$work/home"
check "hanging daemon" "$work/hangbin:$work/nobin" "$work/home"
[ -n "$real" ] && check "real binary, no socket" "$(dirname "$real"):$work/nobin" "$work/home"
exit $fail
