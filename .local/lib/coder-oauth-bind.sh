#!/usr/bin/env bash
# coder-oauth-bind.sh — per-run credential binding for rb-run-coder.sh / r7-run-coder.sh (A1300; Hermes 11-11 13:59 PST).
# Sourced AFTER the host-global claude oauth env file. CODER_ACCOUNT + CODER_OAUTH_ENV paired, both unset = no change (the host-global token stays).
# CODER_OAUTH_ENV must be a regular, non-symlink file of this uid, mode 0600, one line CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat...; its value replaces the
# token for this child only. Never printed. One of the pair set, or any check failing => return 3 (the caller exits 3, no claude started).
coder_oauth_bind() {
  local a="${CODER_ACCOUNT:-}" f="${CODER_OAUTH_ENV:-}" line tok
  [ -z "$a$f" ] && return 0
  [ -n "$a" ] && [ -n "$f" ] || { echo "coder-oauth-bind: CODER_ACCOUNT and CODER_OAUTH_ENV must be set together" >&2; return 3; }
  case "$a" in *[!A-Za-z0-9._-]*|"") echo "coder-oauth-bind: bad account name" >&2; return 3;; esac
  case "$f" in /*) ;; *) echo "coder-oauth-bind: CODER_OAUTH_ENV must be absolute" >&2; return 3;; esac
  [ -f "$f" ] && [ ! -L "$f" ] && [ -O "$f" ] && [ "$(stat -c %a "$f")" = 600 ] || { echo "coder-oauth-bind: $f must be a regular non-symlink file of this uid, mode 600" >&2; return 3; }
  [ "$(wc -l < "$f")" = 1 ] || { echo "coder-oauth-bind: $f must hold exactly one line" >&2; return 3; }
  line="$(cat "$f")"
  case "$line" in CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat*) ;; *) echo "coder-oauth-bind: $f is not a single CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat line" >&2; return 3;; esac
  tok="${line#CLAUDE_CODE_OAUTH_TOKEN=}"
  case "$tok" in *[!A-Za-z0-9_-]*) echo "coder-oauth-bind: token has unexpected characters" >&2; return 3;; esac
  export CLAUDE_CODE_OAUTH_TOKEN="$tok"
  echo "coder-oauth-bind: bound account=$a for this child (value not printed)" >&2
}
