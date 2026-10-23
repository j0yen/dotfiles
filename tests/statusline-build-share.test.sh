#!/usr/bin/env bash
# statusline.sh build_share segment (Joe 10-23 "add it to the status bar"): hermetic, temp TOKEN_LEDGER_STATE_DIR.
# Source of truth is token-ledger's build-share.json + today-summary.txt line 2; the statusline never recomputes thresholds.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
SL="$here/.claude/statusline.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
IN='{"model":{"display_name":"Opus"},"context_window":{"used_percentage":20.4,"context_window_size":200000}}'
today="$(date -u +%F)"
run() { printf '%s' "$IN" | TOKEN_LEDGER_STATE_DIR="$T" bash "$SL"; }
check() { # name, want-substring ("" = must have no 'build')
  local out; out="$(run)"
  if [ -n "$2" ]; then case "$out" in *"$2"*) echo "ok - $1 ($out)";; *) echo "NOT OK - $1: want '$2' got '$out'"; fail=1;; esac
  else case "$out" in *build*) echo "NOT OK - $1: unexpected segment in '$out'"; fail=1;; *) echo "ok - $1 ($out)";; esac; fi
}
reset() { rm -f "$T"/build-share.json "$T"/today-summary.txt; }

reset; check "no file -> no segment" ""
reset; printf '{"date":"2000-01-01","build_share":79.6}' > "$T/build-share.json"; check "stale date -> no segment" ""
reset; printf '{"date":"%s","build_share":null}' "$today" > "$T/build-share.json"; check "null build_share -> no segment" ""
reset; printf 'not json' > "$T/build-share.json"; check "unreadable json -> no segment" ""
reset; printf '{"date":"%s","build_share":79.6}' "$today" > "$T/build-share.json"
printf 'TOKENS today\n\n' > "$T/today-summary.txt"; check "normal 79.6 -> build 80%" " · build 80%"
reset; printf '{"date":"%s","build_share":79.6}' "$today" > "$T/build-share.json"; check "normal, no summary file -> build 80%" " · build 80%"
reset; printf '{"date":"%s","build_share":42.3}' "$today" > "$T/build-share.json"
printf 'TOKENS today\nALARM build_share 42%% < 50%%\n' > "$T/today-summary.txt"; check "alarm line 2 -> red segment" " · 🔴 build 42% <50%"
reset; printf '{"date":"%s","build_share":42.3}' "$today" > "$T/build-share.json"
printf 'ALARM build_share 42%%\nTOKENS today\n' > "$T/today-summary.txt"; check "alarm on line 1 only -> no alarm" " · build 42%"
reset; printf '{"date":"2000-01-01","build_share":42.3}' > "$T/build-share.json"
printf 'TOKENS today\nALARM build_share 42%%\n' > "$T/today-summary.txt"; check "alarm but stale json -> no segment" ""
exit $fail
