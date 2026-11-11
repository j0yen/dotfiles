#!/usr/bin/env bash
# retired-tsv-guard.sh (A1255): PreToolUse denial of runtime create/edit/import of the retired shadow task ledger ~/.cache/aide/open-asks.tsv.
# Scope: the EXACT path only (no blanket .tsv block, reads are allowed). Second layer behind the filesystem tombstone (a directory with the
# immutable attribute at that path): the tombstone makes a write fail, this hook gives the actionable error and opens an owned incident row.
# Not hostile-root-proof: a process that runs `sudo chattr -i` can undo the tombstone; the hook only covers Claude tool calls.
# Env: RETIRED_TSV (path, tests), RETIRED_TSV_INCIDENT_CMD (default wm-asks), RETIRED_TSV_LOG. Usage: retired-tsv-guard.sh | --selftest
RETIRED="${RETIRED_TSV:-$HOME/.cache/aide/open-asks.tsv}"
LOG="${RETIRED_TSV_LOG:-$HOME/.cache/aide/retired-tsv-denials.jsonl}"
WMA="${RETIRED_TSV_INCIDENT_CMD:-wm-asks}"
deny() { # $1 what was attempted
  local msg="open-asks.tsv is RETIRED (Joe 11-07 \"Remove and block TSV\", A1255). The task ledger is the canonical wm-decide asks store. Do this instead: add = ctl-ledger-txn.sh add <due> <key> <check> <what> (or ask-row.py); update = wm-asks asks update ID --expect-rev N; read = asks-view. Recovery from backup: ~/wintermute-operations/ledger-retirement/20261107T150432-0800 (read-only archive); never recreate the file. Blocked: $1"
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  printf '{"ts":"%s","seat":"%s","attempt":%s}\n' "$(date -Iseconds)" "${WM_SEAT:-none}" "$(jq -Rn --arg a "$1" '$a')" >> "$LOG" 2>/dev/null
  # one owned incident row per hour (dedupe by key)
  local key="retired-tsv-attempt-$(date +%Y%m%d%H)"
  if [ -z "${RETIRED_TSV_NO_INCIDENT:-}" ] && ! "$WMA" asks query --text "$key" 2>/dev/null | grep -q "\"$key\"\|$key"; then
    "$WMA" asks add --owner ctl --due "$(date -d '+1 hour' +%Y-%m-%dT%H:%M)" --key "$key" --check "test -d $RETIRED" --what "retired-tsv-guard denied an attempt to write open-asks.tsv by seat ${WM_SEAT:-none}: $1 ($key)" --by retired-tsv-guard >/dev/null 2>&1 || true
  fi
  jq -cn --arg r "$msg" '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$r}}'
}
check() { # stdin hook json -> prints deny json or nothing
  local in tool fp cmd
  in="$(cat)"; command -v jq >/dev/null 2>&1 || return 0
  tool="$(jq -r '.tool_name // empty' <<<"$in" 2>/dev/null)"
  case "$tool" in
    Edit|Write|MultiEdit|NotebookEdit)
      fp="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$in" 2>/dev/null)"
      [ -n "$fp" ] && [ "$(readlink -m -- "$fp" 2>/dev/null)" = "$(readlink -m -- "$RETIRED")" ] && deny "$tool on $fp" ;;
    Bash)
      cmd="$(jq -r '.tool_input.command // empty' <<<"$in" 2>/dev/null)"
      grep -q 'open-asks\.tsv' <<<"$cmd" || return 0
      # a mutator naming the exact file: redirect, tee, sed -i, cp/mv/install/ln/rm/rmdir/touch/truncate/chattr/dd of=, python write/open w|a, asks import
      if grep -qE '>>?[[:space:]]*["'"'"']?[^[:space:];&|]*open-asks\.tsv|tee[^|;&]*open-asks\.tsv|sed[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*i|(^|[;&|[:space:]])(cp|mv|install|ln|rm|rmdir|touch|truncate|chattr|chmod|chown|mkfifo)[[:space:]][^;&|]*open-asks\.tsv|of=[^[:space:]]*open-asks\.tsv|\.write\(|open\([^)]*,[[:space:]]*["'"'"']?[wax]|asks[[:space:]]+import' <<<"$cmd"; then
        deny "Bash naming open-asks.tsv: $(cut -c1-120 <<<"$cmd")"
      fi ;;
  esac
  return 0
}
selftest() {
  local T n=0 f=0; T="$(mktemp -d -p "${TMPDIR:-$HOME/.cache}" rtg.XXXXXX)"
  export RETIRED_TSV="$T/open-asks.tsv" RETIRED_TSV_LOG="$T/log" RETIRED_TSV_NO_INCIDENT=1; RETIRED="$RETIRED_TSV"; LOG="$RETIRED_TSV_LOG"
  t() { n=$((n+1)); if [ "$1" = "$2" ]; then echo "PASS $3"; else echo "FAIL $3 (got $1 want $2)"; f=1; fi; }
  o() { jq -cn --arg c "$2" --arg t "$1" '{tool_name:$t,tool_input:{command:$c,file_path:$c}}' | check | grep -c permissionDecision; }
  t "$(o Write "$T/open-asks.tsv")" 1 "Write to the exact path denied"
  t "$(o Edit "$T/./x/../open-asks.tsv")" 1 "Edit via a dotted path denied"
  t "$(o Write "$T/other.tsv")" 0 "Write to another .tsv allowed (no blanket extension block)"
  t "$(o Bash "echo x >> $T/open-asks.tsv")" 1 "append redirect denied"
  t "$(o Bash "printf a > open-asks.tsv")" 1 "truncate redirect denied"
  t "$(o Bash "sed -i s/a/b/ $T/open-asks.tsv")" 1 "sed -i denied"
  t "$(o Bash "mv $T/new.tsv $T/open-asks.tsv")" 1 "atomic rename onto path denied"
  t "$(o Bash "cp a $T/open-asks.tsv")" 1 "cp denied"
  t "$(o Bash "touch $T/open-asks.tsv")" 1 "touch (recreate) denied"
  t "$(o Bash "rmdir $T/open-asks.tsv")" 1 "rmdir of the tombstone denied"
  t "$(o Bash "wm-decide asks import $T/open-asks.tsv")" 1 "asks import denied"
  t "$(o Bash "python3 -c \"open('$T/open-asks.tsv','w')\"")" 1 "python open w denied"
  t "$(o Bash "cat $T/open-asks.tsv; wc -l $T/open-asks.tsv")" 0 "read-only commands allowed"
  t "$(o Bash "ls $T/other.tsv > /dev/null")" 0 "unrelated command allowed"
  rm -rf "$T"; echo "retired-tsv-guard selftest: $n checks, $([ $f = 0 ] && echo ALL PASS || echo FAILURES)"; return $f
}
case "${1:-}" in --selftest) selftest; exit $? ;; *) check; exit 0 ;; esac
