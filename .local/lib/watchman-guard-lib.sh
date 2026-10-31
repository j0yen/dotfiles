#!/usr/bin/env bash
# watchman-guard-lib.sh -- SOURCED by .local/bin/watchman (the shim) and .local/bin/watchman-root-guard.sh (the sweeper).
# One DENY file (~/.config/watchman-guard/deny.list), one equality matcher, one JSON-row writer; neither caller keeps a second copy.
# Nothing here exits or sets -e: the shim sources it on the wchg hot path and must fail OPEN.
#   wg_load_deny          fill WG_DENY_LIST from $WG_DENY (default ~/.config/watchman-guard/deny.list); rc 1 = unreadable or empty
#   wg_is_denied PATH     rc 0 iff PATH is byte-equal to a WG_DENY_LIST member (EQUALITY ONLY, never a prefix)
#   wg_json_esc STR       REPLY = STR as a JSON string body
#   wg_redact_many ARGS.. REDACTED=(...) each arg with secrets replaced by <REDACTED>, then cut to 200 chars (redact BEFORE cut); sed failure = all <REDACTED>
#   wg_state_dir          ${XDG_STATE_HOME:-~/.local/state}/watchman-guard
#   wg_append_row LINE    append one line to clients.jsonl, rotating at 5 MB (keeps clients.jsonl.1); every step || true
WG_DENY_LIST=()

wg_load_deny() {
  local f=${WG_DENY:-$HOME/.config/watchman-guard/deny.list} line
  WG_DENY_LIST=()
  [ -r "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line%"${line##*[![:space:]]}"}
    line=${line#"${line%%[![:space:]]*}"}
    case "$line" in /*) WG_DENY_LIST+=("$line");; esac
  done < "$f"
  [ "${#WG_DENY_LIST[@]}" -gt 0 ]
}

wg_is_denied() {
  local d
  for d in "${WG_DENY_LIST[@]}"; do
    [ "$1" = "$d" ] && return 0
  done
  return 1
}

wg_json_esc() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/ }; s=${s//$'\r'/ }; s=${s//$'\t'/ }
  s=${s//[$'\001'-$'\037']/ }
  REPLY=$s
}

wg_redact_many() {   # ARGS... -> REDACTED=(...) one per arg; ONE sed for all of them (fork budget on the hot path)
  local a out=() i
  REDACTED=()
  for a in "$@"; do a=${a//$'\n'/ }; REDACTED+=("$a"); done
  mapfile -t out < <(printf '%s\n' "${REDACTED[@]}" | sed -E -e 's/sk-ant-[^[:space:]]+/<REDACTED>/g' -e 's/gh[pousr]_[^[:space:]]+/<REDACTED>/g' \
        -e 's/github_pat_[^[:space:]]+/<REDACTED>/g' -e 's/Bearer [^[:space:]]+/<REDACTED>/g' -e 's/AKIA[[:alnum:]_]+/<REDACTED>/g' \
        -e 's/[A-Za-z0-9_-]{32,}/<REDACTED>/g') || out=()
  for ((i = 0; i < ${#REDACTED[@]}; i++)); do
    if [ "${#out[@]}" -eq "${#REDACTED[@]}" ]; then REDACTED[i]=${out[i]:0:200}; else REDACTED[i]='<REDACTED>'; fi   # a sed failure never leaks the raw text
  done
}

wg_state_dir() { REPLY=${XDG_STATE_HOME:-$HOME/.local/state}/watchman-guard; }

wg_append_row() {
  local dir f sz
  wg_state_dir; dir=$REPLY; f=$dir/clients.jsonl
  [ -d "$dir" ] || mkdir -p -m 700 "$dir" 2>/dev/null || return 0   # no fork once the dir exists (wchg hot path)
  sz=$(stat -c %s "$f" 2>/dev/null) || sz=0
  if [ "${sz:-0}" -ge "${WG_ROTATE_BYTES:-5242880}" ]; then mv -f "$f" "$f.1" 2>/dev/null || true; fi
  printf '%s\n' "$1" >> "$f" 2>/dev/null || true
  return 0
}
