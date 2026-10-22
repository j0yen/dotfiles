#!/usr/bin/env bash
# model-role-check.sh: warn loudly when a session's live model differs from its role's required model.
# Registered on SessionStart + UserPromptSubmit. Never blocks: always exits 0.
# PREMISE: role from tmux session name or no-TMUX-on-carbon; EXPIRES: 2026-11-21
# Roles: tmux rb|r7 -> that role; tmux ctl -> controller; non-tmux on carbon -> aide (a label: NO table row, any model allowed, silent).
# Table: /home/jsy/.claude/state/controller-model-required ("<role> <model-id>" per line).
# Test hooks (selftest only): MRC_TABLE, MRC_FORCE_ROLE, MRC_SKIP_FALLBACK.
set -u

TABLE="${MRC_TABLE:-/home/jsy/.claude/state/controller-model-required}"
SETTINGS_FILES=(/home/jsy/.claude/settings.local.json /home/jsy/.claude/settings.json)

norm() { # strip [1m]-style suffix and whitespace
  local m="${1%%\[*}"; m="${m//[$'\r\n\t ']/}"; printf '%s' "$m"
}

json_get() { # json_get <jq filter> reads stdin; empty on any failure
  if command -v jq >/dev/null 2>&1; then
    jq -r "$1 // empty" 2>/dev/null
  else
    python3 -I -c '
import sys,json
f=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
def g(path):
    cur=d
    for k in path:
        if not isinstance(cur,dict) or k not in cur: return ""
        cur=cur[k]
    return cur if isinstance(cur,str) else ""
paths={".message.model":["message","model"],".transcript_path":["transcript_path"],".model":["model"]}
print(g(paths.get(f,[])))' "$1" 2>/dev/null
  fi
}

detect_role() {
  if [ -n "${MRC_FORCE_ROLE:-}" ]; then printf '%s' "$MRC_FORCE_ROLE"; return; fi
  if [ -n "${TMUX:-}" ]; then
    local s
    if [ -n "${TMUX_PANE:-}" ]; then s=$(tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null)
    else s=$(tmux display-message -p '#S' 2>/dev/null); fi
    case "$s" in rb|r7) printf '%s' "$s" ;; ctl) printf 'controller' ;; esac
    return
  fi
  [ "$(hostname 2>/dev/null)" = "carbon" ] && printf 'aide'
}

model_from_transcript() { # (a) newest assistant line with a real model id
  local f="$1" line m
  [ -n "$f" ] && [ -s "$f" ] || return 0
  while IFS= read -r line; do
    m=$(printf '%s' "$line" | json_get '.message.model')
    case "$m" in ""|"<"*) continue ;; esac
    printf '%s' "$m"; return 0
  done < <(tail -n 400 "$f" 2>/dev/null | grep -E '"type": ?"assistant"' | tail -n 8 | tac)
}

model_from_cmdline() { # (b) --model <id> on nearest ancestor named claude
  local pid="${PPID:-0}" n=0 name cmd m
  while [ "$pid" -gt 1 ] && [ $n -lt 12 ]; do
    name=$(sed -n 's/^Name:[[:space:]]*//p' "/proc/$pid/status" 2>/dev/null)
    if [ "$name" = "claude" ]; then
      cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
      m=$(printf '%s' "$cmd" | grep -oE -- '--model[= ][^ ]+' | head -n1 | sed -E 's/^--model[= ]//')
      [ -n "$m" ] && { printf '%s' "$m"; return 0; }
      return 0
    fi
    pid=$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$pid/status" 2>/dev/null)
    [ -n "$pid" ] || return 0
    n=$((n+1))
  done
}

model_from_settings() { # (c)
  local f m
  for f in "${SETTINGS_FILES[@]}"; do
    [ -r "$f" ] || continue
    m=$(json_get '.model' < "$f")
    [ -n "$m" ] && { printf '%s' "$m"; return 0; }
  done
}

matches() { # matches <detected> <required>
  local d="$1" r="$2"
  case "$d" in "$r"*) return 0 ;; esac
  case "$d" in claude-*) return 1 ;; esac
  case "$r" in *"-$d-"*) return 0 ;; esac   # alias such as "fable" / "opus"
  return 1
}

# check <role> <transcript_path>: prints the mismatch block or nothing.
check() {
  local role="$1" tp="$2" required model src
  required=$(awk -v r="$role" '$1==r {print $2; exit}' "$TABLE" 2>/dev/null)
  [ -n "$required" ] || return 0
  model=$(model_from_transcript "$tp"); src=transcript
  if [ -z "$model" ] && [ -z "${MRC_SKIP_FALLBACK:-}" ]; then
    model=$(model_from_cmdline); src=cmdline
    [ -n "$model" ] || { model=$(model_from_settings); src=settings; }
  fi
  model=$(norm "$model")
  [ -n "$model" ] || return 0
  matches "$model" "$required" && return 0
  printf '⚠⚠ MODEL MISMATCH: role=%s running=%s required=%s (per %s). Run /model %s now and note it in status.\n' \
    "$role" "$model" "$required" "$TABLE" "$required"
}

selftest() {
  echo "PREMISE: role from tmux session name or no-TMUX-on-carbon; EXPIRES: 2026-11-21"
  local d fail=0 out
  d=$(mktemp -d /home/jsy/.cache/tmp/mrc-selftest.XXXXXX) || { echo "FAIL setup"; return 1; }
  printf 'controller claude-fable-5-1\nrb claude-opus-5-5\nr7 claude-fable-5-1\n' > "$d/table"
  export MRC_TABLE="$d/table" MRC_SKIP_FALLBACK=1
  TABLE="$MRC_TABLE"
  printf '{"type":"user"}\n{"type":"assistant","message":{"model":"claude-fable-5-1-20261001"}}\n' > "$d/match.jsonl"
  printf '{"type":"assistant","message":{"model":"claude-opus-5-5"}}\n' > "$d/mismatch.jsonl"

  out=$(check controller "$d/match.jsonl")
  if [ -z "$out" ]; then echo "PASS matching model: silent"; else echo "FAIL matching model: got: $out"; fail=1; fi
  out=$(check controller "$d/mismatch.jsonl")
  case "$out" in "⚠⚠ MODEL MISMATCH: role=controller running=claude-opus-5-5 required=claude-fable-5-1"*) echo "PASS mismatching model: warned" ;;
    *) echo "FAIL mismatching model: got: '$out'"; fail=1 ;; esac
  out=$(check controller "$d/does-not-exist.jsonl")
  if [ -z "$out" ]; then echo "PASS missing transcript: silent"; else echo "FAIL missing transcript: got: $out"; fail=1; fi
  # role detection + aide silence (shim tmux prints the session name; TMUX=fake)
  mkdir -p "$d/bin"
  for sn in ctl rb r7 other; do
    printf '#!/bin/sh\necho %s\n' "$sn" > "$d/bin/tmux"; chmod +x "$d/bin/tmux"
    out=$(unset TMUX_PANE MRC_FORCE_ROLE; PATH="$d/bin:$PATH" TMUX=fake detect_role)
    case "$sn:$out" in ctl:controller|rb:rb|r7:r7|other:) echo "PASS tmux '$sn' -> role '${out:-<none>}'" ;; *) echo "FAIL tmux '$sn' -> '$out'"; fail=1 ;; esac
  done
  out=$(unset TMUX TMUX_PANE MRC_FORCE_ROLE; detect_role)
  if [ "$(hostname 2>/dev/null)" = carbon ]; then [ "$out" = aide ] && echo "PASS no tmux on carbon -> role aide" || { echo "FAIL no tmux on carbon -> '$out'"; fail=1; }
  else echo "SKIP no-tmux role (host is not carbon)"; fi
  out=$(check aide "$d/mismatch.jsonl")
  if [ -z "$out" ]; then echo "PASS role aide: silent on any model (no table row)"; else echo "FAIL role aide warned: $out"; fail=1; fi
  rm -rf "$d"
  return $fail
}

if [ "${1:-}" = "--selftest" ]; then
  selftest; rc=$?
  [ $rc -eq 0 ] && exit 0 || exit 1
fi

input=$(cat 2>/dev/null || true)
role=$(detect_role)
[ -n "$role" ] || exit 0
tp=$(printf '%s' "$input" | json_get '.transcript_path')
check "$role" "$tp"
exit 0
