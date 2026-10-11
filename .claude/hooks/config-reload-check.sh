#!/usr/bin/env bash
# config-reload-check.sh — PostToolUse hook (PRD dotfiles-config-edit-reload-check).
# After a tool call that edits $WM_BUILD_CONFIG: print `wm-build config effective`'s
# verdict per differing key, then wait (detached) for the daemon's next tick and
# drop notices/<ts>-config-reload.txt saying what it actually loaded.
# Fail-open: always exits 0. Anything else exits silently on the fast path.
cfg="${WM_BUILD_CONFIG:-$HOME/.config/wm-build/config.toml}"
cache="${OPERATOR_CACHE_DIR:-$HOME/.cache/operator}"
journal="${WM_BUILD_JOURNAL:-$HOME/.local/state/wm-build/journal.jsonl}"
notices="${OPERATOR_NOTICES_DIR:-$cache/notices}"
export LC_ALL=C

# parse_effective — stdin: `wm-build config effective` text. Prints TSV
# key<TAB>old<TAB>new<TAB>class per differing key, then `#tick<TAB><secs>`.
# The only place that knows the text format.
parse_effective() {
  awk '
    /^[[:space:]]*tick_interval_secs[ =:]+[0-9]+/ { s=$0; gsub(/[^0-9]/, "", s); tick=s }
    match($0, /\((reloadable|restart-required)\)[[:space:]]*$/) {
      cls = substr($0, RSTART+1, RLENGTH-1); sub(/\).*/, "", cls)
      line = substr($0, 1, RSTART-1); sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
      key = line; sub(/[[:space:]].*/, "", key)
      rest = line; sub(/^[^[:space:]]+[[:space:]]*/, "", rest)
      old = rest; new = ""
      if (index(rest, " → ")) { old = rest; sub(/ → .*/, "", old); new = rest; sub(/.* → /, "", new) }
      printf "%s\t%s\t%s\t%s\n", key, old, new, cls
    }
    END { printf "#tick\t%s\n", (tick == "" ? 180 : tick) }'
}

# wait_for_tick — the detached waiter. $1 = state file written by the hook.
wait_for_tick() {
  local state="$1" edit_iso tick_secs timeout poll deadline now
  edit_iso=$(sed -n 's/^#edit\t//p' "$state"); tick_secs=$(sed -n 's/^#tick\t//p' "$state")
  timeout="${CRCHK_TIMEOUT:-$((2 * tick_secs + 60))}"; poll="${CRCHK_POLL:-15}"
  deadline=$(( $(date +%s) + timeout ))
  local tick="" stamp
  while :; do
    tick=$(tail -c 2000000 "$journal" 2>/dev/null | grep -a '"op":"tick"' | tail -n 50 \
      | jq -c --arg e "$edit_iso" 'select((.row.config_loaded_at // "") > $e)' 2>/dev/null | head -n 1)
    [ -n "$tick" ] && break
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep "$poll"
  done
  mkdir -p "$notices" "$cache" 2>/dev/null
  stamp=$(date +%Y%m%dT%H%M%S)
  local out="$cache/.config-reload.tmp.$$"
  {
    if [ -z "$tick" ]; then
      echo "CONFIG RELOAD: no tick within ${timeout} s — daemon stalled?"
    else
      echo "CONFIG RELOAD:"
      local rows key old new cls ts
      rows=$(tail -c 2000000 "$journal" 2>/dev/null | grep -a -E '"op":"config-(reloaded|restart-required)"')
      while IFS=$'\t' read -r key old new cls; do
        case "$key" in ''|'#'*) continue ;; esac
        if [ "$cls" = restart-required ] || printf '%s\n' "$rows" | jq -e --arg k "$key" --arg e "$edit_iso" \
            'select(.op=="config-restart-required" and .row.key==$k and (.ts > $e))' >/dev/null 2>&1; then
          echo "$key NOT loaded (restart-required)"
        elif ts=$(printf '%s\n' "$rows" | jq -r --arg k "$key" --arg e "$edit_iso" \
            'select(.op=="config-reloaded" and .row.key==$k and (.ts > $e)) | .ts' 2>/dev/null | tail -n 1) && [ -n "$ts" ]; then
          echo "$key loaded ${old}→${new} $(date -d "$ts" +'%-I:%M %P')"
        else
          echo "$key unchanged by daemon (no row)"
        fi
      done <"$state"
      printf '%s\n' "$tick" | jq -r '"admission: \(.row.admitted | length) admitted / \(.row.skipped | length) skipped in that tick"'
    fi
  } >"$out"
  cp -f "$out" "$cache/config-reload.last" 2>/dev/null
  mv -f "$out" "$notices/$stamp-config-reload.txt"
}

if [ "${1:-}" = "--last" ]; then
  cat "$cache/config-reload.last" 2>/dev/null
  exit 0
fi
if [ "${1:-}" = "--wait" ]; then
  wait_for_tick "$2"
  exit 0
fi

payload=$(cat)
# One jq call: the edited file_path, and whether a Bash command writes the config
# (mentions its path together with `>`, `sed -i`, `tee` or `cp`).
info=$(printf '%s' "$payload" | jq -r --arg c "$cfg" --arg t "~/.config/wm-build/config.toml" --arg h '$HOME/.config/wm-build/config.toml' '
  (.tool_input.command // "") as $m
  | (.tool_input.file_path // "") + "\t"
    + (if (($m | contains($c)) or ($m | contains($t)) or ($m | contains($h)))
          and ($m | test(">|sed +(-[a-zA-Z]+ +)*-i|sed +--in-place|\\btee\\b|\\bcp\\b"))
       then "1" else "0" end)' 2>/dev/null)
fp="${info%%$'\t'*}"; bash_edit="${info##*$'\t'}"
[ "$fp" = "$cfg" ] || [ "$bash_edit" = 1 ] || exit 0

if [ "$(systemctl --user is-active wm-build.service 2>/dev/null)" != active ]; then
  echo "daemon inactive; file saved, nothing to confirm"
  exit 0
fi

eff=$(timeout 5 wm-build config effective 2>/dev/null)
parsed=$(printf '%s\n' "$eff" | parse_effective)
tick_secs=$(printf '%s\n' "$parsed" | sed -n 's/^#tick\t//p')
diff=$(printf '%s\n' "$parsed" | grep -v '^#')
[ -n "$diff" ] || exit 0
while IFS=$'\t' read -r key old new cls; do
  if [ "$cls" = reloadable ]; then
    echo "config: $key ${old}→${new} reloadable; daemon tick in ≤ ${tick_secs} s"
  else
    echo "config: $key restart-required (NOT loaded until the daemon restarts)"
  fi
done <<<"$diff"

mkdir -p "$cache" 2>/dev/null
state="$cache/config-reload.state"
{ printf '#edit\t%s\n#tick\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%N)" "$tick_secs"; printf '%s\n' "$diff"; } >"$state"
# One waiter at a time: a newer edit replaces the old waiter (lock holds its pid).
lock="$cache/config-reload.lock"
old=$(cat "$lock" 2>/dev/null)
if [ -n "$old" ] && tr '\0' ' ' <"/proc/$old/cmdline" 2>/dev/null | grep -q 'config-reload-check.*--wait'; then
  kill "$old" 2>/dev/null
fi
setsid nohup "$0" --wait "$state" >/dev/null 2>&1 </dev/null &
echo $! >"$lock"
exit 0
