#!/usr/bin/env bash
# watcher-lib-postapply.sh -- fleet-sync post-apply check of the shared watcher lib (dotfiles .local/lib/watcher-premise.sh).
# Called at the end of install.sh (the dotfiles source's fleet-sync `post`), i.e. after fleet-sync shipped the lib to this host.
# Writes ~/.local/state/watchers/_lib.json atomically:
#   {"sha": <sha256 of the lib|null>, "bash_n_ok": bool, "source_ok": bool, "checked_at": <ISO UTC>, "selftests": {"<consumer>": "ok"|"fail"|"no-selftest"}}
# Runs from install.sh (only when fleet-sync fast-forwards dotfiles) AND hourly from watcher-lib-postapply.timer (retries a failed check;
# picks up a consumer fixed outside dotfiles).
# Consumers are DISCOVERED, never hand-listed: files in ~/.local/bin with a non-comment line that mentions watcher-premise.sh.
# A consumer whose text has no --selftest is recorded "no-selftest" and is NOT run (running an unknown script could write).
# A jq failure replaces the file with a failed record (error write-failed), rc 2.
# Exit 0 = lib parses + sources and no consumer selftest failed; 1 otherwise (the JSON is written either way).
# Usage: watcher-lib-postapply.sh [--selftest]
# Env: WPA_LIB (default ~/.local/lib/watcher-premise.sh)  WPA_BIN (~/.local/bin)  WPA_OUT (~/.local/state/watchers/_lib.json)  WPA_TIMEOUT (120 s per consumer)
set -u

WPA_LIB=${WPA_LIB:-$HOME/.local/lib/watcher-premise.sh}
WPA_BIN=${WPA_BIN:-$HOME/.local/bin}
WPA_OUT=${WPA_OUT:-$HOME/.local/state/watchers/_lib.json}
WPA_TIMEOUT=${WPA_TIMEOUT:-120}
SELF_PATH=$(readlink -f "${BASH_SOURCE[0]}")
SELF_NAME=$(basename "$SELF_PATH")

# Consumer script names (one per line) under $WPA_BIN, sorted.
wpa_discover() {
  local f n
  for f in "$WPA_BIN"/*; do
    [ -f "$f" ] || continue
    n=$(basename "$f")
    case "$n" in *.bak|*.bak[-.]*|*.orig|*~|*.pre-*|*.retired.*) continue;; esac
    [ "$n" = "$SELF_NAME" ] && continue
    [ "$(readlink -f "$f")" = "$SELF_PATH" ] && continue
    grep -Iv '^[[:space:]]*#' "$f" 2>/dev/null | grep -q 'watcher-premise\.sh' && printf '%s\n' "$n"
  done | sort
}

# Atomic write of $WPA_OUT: tmp in the SAME dir, mv -f. WPA_TMP is global so the EXIT trap can see it (a `local` is out of
# scope when the trap fires and `set -u` then errors). If jq fails, replace the previous file with a FAILED record
# (printf only, no jq; "error":"write-failed", sha null, both flags false) so a stale pass can never be read as current.
WPA_TMP=""
wpa_write() {  # sha bash_n source pairs
  local sha=$1 bn=$2 so=$3 pairs=$4 out_dir now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  out_dir=$(dirname "$WPA_OUT")
  mkdir -p "$out_dir" || return 2
  WPA_TMP=$(mktemp "$out_dir/.${SELF_NAME%.sh}.XXXXXX") || { WPA_TMP=""; return 2; }
  trap 'rm -f "${WPA_TMP:-}"' EXIT
  if printf '%s' "$pairs" | jq -R -s --argjson sha "$(jq -n --arg s "$sha" 'if $s == "null" then null else $s end')" \
      --argjson bn "$bn" --argjson so "$so" --arg now "$now" \
      '{sha: $sha, bash_n_ok: $bn, source_ok: $so, checked_at: $now,
        selftests: (split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: .[1]}) | from_entries)}' > "$WPA_TMP" 2>/dev/null; then
    chmod 644 "$WPA_TMP"; mv -f "$WPA_TMP" "$WPA_OUT" || return 2
    trap - EXIT; WPA_TMP=""; return 0
  fi
  printf '{"sha":null,"bash_n_ok":false,"source_ok":false,"selftests":{},"checked_at":"%s","error":"write-failed"}\n' "$now" > "$WPA_TMP" \
    && chmod 644 "$WPA_TMP" && mv -f "$WPA_TMP" "$WPA_OUT"
  rm -f "$WPA_TMP"; trap - EXIT; WPA_TMP=""
  echo "watcher-lib-postapply: jq failed; wrote a failed record to $WPA_OUT" >&2
  return 2
}

wpa_run() {
  command -v jq >/dev/null 2>&1 || { echo "watcher-lib-postapply: jq required" >&2; return 2; }
  local sha=null bash_n=false src=false rc=0 n f res
  if [ -r "$WPA_LIB" ]; then
    sha=$(sha256sum "$WPA_LIB" | cut -d' ' -f1)
    bash -n "$WPA_LIB" 2>/dev/null && bash_n=true
    # Source in a fresh shell; the lib must define its public functions and must not run anything at source time.
    bash -c 'source "$1" && declare -F wp_arm wp_gate wp_emit_write wp_selftest >/dev/null' _ "$WPA_LIB" >/dev/null 2>&1 </dev/null && src=true
  fi
  [ "$bash_n" = true ] && [ "$src" = true ] || rc=1

  local pairs=""
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    f=$WPA_BIN/$n
    if ! grep -Iq -- '--selftest' "$f" 2>/dev/null; then
      res=no-selftest
    elif [ -x "$f" ] && timeout "$WPA_TIMEOUT" "$f" --selftest >/dev/null 2>&1 </dev/null; then
      res=ok
    else
      res=fail; rc=1
    fi
    echo "consumer $n: $res" >&2
    pairs+="$n"$'\t'"$res"$'\n'
  done < <(wpa_discover)

  wpa_write "$sha" "$bash_n" "$src" "$pairs" || return 2
  echo "watcher-lib: sha=${sha:0:12} bash_n_ok=$bash_n source_ok=$src -> $WPA_OUT" >&2
  return $rc
}

wpa_selftest() {
  local T pass=0 total=0 out rc
  T=$(mktemp -d "${TMPDIR:-/tmp}/wpa-selftest.XXXXXX") || return 1
  trap 'rm -rf "$T"' RETURN
  ck() { total=$((total+1)); if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "FAIL $1: got [$2] want [$3]"; fi; }
  mkdir -p "$T/bin"
  cat > "$T/lib.sh" <<'EOF'
wp_arm() { :; }; wp_gate() { :; }; wp_emit_write() { :; }; wp_selftest() { :; }
EOF
  local want_sha; want_sha=$(sha256sum "$T/lib.sh" | cut -d' ' -f1)
  printf '#!/bin/bash\nsource /x/watcher-premise.sh\n[ "${1:-}" = "--selftest" ] && exit 0\n' > "$T/bin/c-ok.sh"
  printf '#!/bin/bash\n. $HOME/.local/lib/watcher-premise.sh\nif [ "$1" = "--selftest" ]; then exit 1; fi\n' > "$T/bin/c-fail.sh"
  printf '#!/bin/bash\nsource /x/watcher-premise.sh\necho hi\n' > "$T/bin/c-none.sh"
  printf '#!/bin/bash\n# source /x/watcher-premise.sh   (comment only)\n--selftest\n' > "$T/bin/c-comment.sh"
  printf '#!/bin/bash\nsource /x/watcher-premise.sh\nexit 1 # --selftest\n' > "$T/bin/c-ok.sh.bak-20261022"
  printf '#!/bin/bash\necho unrelated --selftest\n' > "$T/bin/other.sh"
  chmod +x "$T/bin/"*
  local env=(WPA_LIB="$T/lib.sh" WPA_BIN="$T/bin" WPA_OUT="$T/state/watchers/_lib.json" WPA_TIMEOUT=10)

  # 1. mixed consumers: ok / fail / no-selftest recorded, commented + .bak + non-consumers ignored; rc 1 because one failed.
  env "${env[@]}" bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "rc with a failing consumer" "$rc" 1
  out=$(cat "$T/state/watchers/_lib.json" 2>/dev/null)
  ck "sha"       "$(jq -r .sha <<<"$out")" "$want_sha"
  ck "bash_n_ok" "$(jq -r .bash_n_ok <<<"$out")" true
  ck "source_ok" "$(jq -r .source_ok <<<"$out")" true
  ck "checked_at is ISO UTC" "$(jq -r .checked_at <<<"$out" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$')" 1
  ck "selftests" "$(jq -cS .selftests <<<"$out")" '{"c-fail.sh":"fail","c-none.sh":"no-selftest","c-ok.sh":"ok"}'
  ck "no tmp left behind" "$(ls -A "$T/state/watchers" | tr '\n' ' ')" "_lib.json "

  # 2. only passing consumers -> rc 0, and the previous file is replaced atomically.
  rm "$T/bin/c-fail.sh"
  env "${env[@]}" bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "rc all ok" "$rc" 0
  ck "selftests after removal" "$(jq -cS .selftests "$T/state/watchers/_lib.json")" '{"c-none.sh":"no-selftest","c-ok.sh":"ok"}'

  # 3. syntax error in the lib -> bash_n_ok false, source_ok false, rc 1, file still written.
  printf 'wp_arm() {\n' > "$T/lib.sh"
  env "${env[@]}" bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "rc broken lib" "$rc" 1
  ck "broken lib flags" "$(jq -c '[.bash_n_ok,.source_ok]' "$T/state/watchers/_lib.json")" '[false,false]'

  # 4. lib sources but lacks a public function -> source_ok false while bash -n passes.
  printf 'wp_arm() { :; }\n' > "$T/lib.sh"
  env "${env[@]}" bash "$SELF_PATH" >/dev/null 2>&1
  ck "missing function flags" "$(jq -c '[.bash_n_ok,.source_ok]' "$T/state/watchers/_lib.json")" '[true,false]'

  # 5. lib absent -> sha null, rc 1.
  rm "$T/lib.sh"
  env "${env[@]}" bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "rc absent lib" "$rc" 1
  ck "absent lib sha" "$(jq -c '[.sha,.bash_n_ok,.source_ok]' "$T/state/watchers/_lib.json")" '[null,false,false]'

  # 6. jq fails on -R (failure path): rc 2, no tmp left behind, no "unbound variable", the previous good file is replaced by a failed record.
  printf 'wp_arm() { :; }; wp_gate() { :; }; wp_emit_write() { :; }; wp_selftest() { :; }\n' > "$T/lib.sh"
  env "${env[@]}" bash "$SELF_PATH" >/dev/null 2>&1   # a good record first
  ck "good record before failure" "$(jq -r .sha "$T/state/watchers/_lib.json")" "$(sha256sum "$T/lib.sh" | cut -d' ' -f1)"
  mkdir -p "$T/shim"
  printf '#!/bin/bash\nfor a in "$@"; do [ "$a" = -R ] && exit 5; done\nexec %s "$@"\n' "$(command -v jq)" > "$T/shim/jq"; chmod +x "$T/shim/jq"
  local err; err=$(env "${env[@]}" PATH="$T/shim:$PATH" bash "$SELF_PATH" 2>&1 >/dev/null); rc=$?
  ck "rc jq failure" "$rc" 2
  ck "no unbound-variable error" "$(grep -c 'unbound variable' <<<"$err")" 0
  ck "no tmp left after jq failure" "$(ls -A "$T/state/watchers" | tr '\n' ' ')" "_lib.json "
  ck "failed record replaces the old file" "$(jq -c '[.sha,.bash_n_ok,.source_ok,.error]' "$T/state/watchers/_lib.json")" '[null,false,false,"write-failed"]'

  if [ "$pass" = "$total" ]; then echo "SELFTEST PASS $pass/$total"; return 0; fi
  echo "SELFTEST FAIL $pass/$total"; return 1
}

if [ "${1:-}" = "--selftest" ]; then wpa_selftest; exit $?; fi
wpa_run
exit $?
