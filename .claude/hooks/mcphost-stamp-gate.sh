#!/usr/bin/env bash
# mcphost-stamp-gate.sh — PreToolUse hook (Bash): a write call to the mcphost hub that carries NO auth and NO
# synthetic stamp creates a tenant the hub counts as a REAL user (the hub stamps a tenant synthetic at creation only
# when the signup request has `x-mcphost-synthetic: <label>`, label ^[a-z0-9][a-z0-9:_-]{0,63}$; that covers an
# explicit `signup` AND the first keyless call, which signs up implicitly).
#
# Trigger (all four): (1) the command invokes curl/wget/http/https/xh, (2) it names a hub URL (mcphost.dev, any
# subdomain, or $MCPHOST_URL / $MCPHOST_PUBLIC_URL / $MCPHOST_HUB spelled in the command), (3) it is a write: -X POST/
# PUT/PATCH/DELETE, -d/--data*/--json/-F/--form/--post-data/--post-file (so `-d @file.json` counts: the body is hidden,
# we key on the ABSENCE OF AUTH, never on the strings `signup` or `tools/call`), or a literal jsonrpc / tools/call body,
# (4) it has none of: an Authorization header, --oauth2-bearer, -u, `tenant_key`, `x-mcphost-synthetic`.
# Allowed untouched: GET, -I/--head, -G, and hub URLs whose path is /healthz, /health, /.well-known/*, /docs*, /status.json.
#
# MODE: WARN first, then BLOCK. WARN = exit 0 + a stderr line naming the exact header to add; from
# DEPLOY_TS + WARN_HOURS on it BLOCKS (exit 2, probe-gate's deny shape). Every hit is appended to
# ~/.local/state/mcphost-stamp-gate/warn.log (ts, mode, cwd, first 80 chars of the command with Bearer/key-shaped
# tokens redacted) so the BLOCK decision can be read off hit counts. Nothing is exempt by seat or model.
# DEPLOY_TS is the clock start recorded in this file; if the merge lands later than that, bump it in a one-line follow-up.
#
# KNOWN GAPS (not covered, do not claim otherwise): MCP-tool signups through Claude Code's mcp__mcphost__* tools; scripts
# that read the URL from a file or env (the script's own curl is never in the Bash command); non-Bash tools (WebFetch,
# python/node HTTP inside a script, etc.). A `-d @file` that holds a tenant_key warns too (false positive: add the header).
# Mentions of curl+hub inside echo/commit text can also warn: WARN-first exists to count those before BLOCK.
#
# Fails OPEN on malformed input, missing jq or an unparsable DEPLOY_TS: a bug here must never block unrelated Bash.
# Test hooks (honored only with MCPHOST_STAMP_GATE_SELFTEST=1): MCPHOST_STAMP_GATE_NOW=<epoch>.
set -uo pipefail

DEPLOY_TS="2026-10-23T15:30:31-07:00"
WARN_HOURS=24

Q=$'["\x27]'   # a double or single quote, for the regexes below
JQ=$(command -v jq) || exit 0
INPUT=$(cat) || exit 0
[ -n "$INPUT" ] || exit 0
[ "$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null)" = "Bash" ] || exit 0
CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0
CWD=$(printf '%s' "$INPUT" | "$JQ" -r '.cwd // empty' 2>/dev/null); [ -n "$CWD" ] || CWD="$PWD"

# (1) an HTTP client invocation, (2) a hub URL
printf '%s' "$CMD" | grep -qE "(^|[;&|(\`]|[[:space:]]|${Q})(curl|wget|http|https|xh)[[:space:]]" || exit 0
HUB_RE='mcphost\.dev|MCPHOST_(PUBLIC_)?URL|MCPHOST_HUB'
printf '%s' "$CMD" | grep -qiE "$HUB_RE" || exit 0

# every literal hub URL is a read-only path (health, discovery, docs, status) -> allow
urls=$(printf '%s' "$CMD" | grep -oiE "(https?://)?[A-Za-z0-9.-]*mcphost\.dev[^[:space:]'\"\\\\]*" || true)
if [ -n "$urls" ] && ! printf '%s' "$CMD" | grep -qiE 'MCPHOST_(PUBLIC_)?URL|MCPHOST_HUB'; then
  allsafe=1
  while IFS= read -r u; do
    path="${u#*mcphost.dev}"; path="${path%%\?*}"
    case "$path" in
      /healthz|/healthz/*|/health|/health/*|/.well-known/*|/docs|/docs/*|/status.json) ;;
      *) allsafe=0 ;;
    esac
  done <<<"$urls"
  [ "$allsafe" = 1 ] && exit 0
fi

# GET-shaped: -I/--head, -G/--get, -X GET|HEAD
printf '%s' "$CMD" | grep -qE '(^|[[:space:]])(-[A-Za-z]*[IG]|--head|--get)([[:space:]]|$)' && exit 0
printf '%s' "$CMD" | grep -qiE "(-X|--request)[[:space:]=]*${Q}?(GET|HEAD)\\b" && exit 0

# (3) a write: explicit method, a data/form flag, or a JSON-RPC body
WRITE_FLAGS="(^|[[:space:]])(-[A-Za-z]*[dF]([[:space:]\"'@{]|\$)|--(data|data-raw|data-binary|data-urlencode|data-ascii|json|form|post-data|post-file)([[:space:]=]|\$))"   # case-sensitive: -d/-F, not -D/-f
WRITE_WORDS="(-X|--request)[[:space:]=]*${Q}?(POST|PUT|PATCH|DELETE)|jsonrpc|tools/call"
{ printf '%s' "$CMD" | grep -qE "$WRITE_FLAGS" || printf '%s' "$CMD" | grep -qiE "$WRITE_WORDS"; } || exit 0

# (4) any auth or stamp present -> not our case
printf '%s' "$CMD" | grep -qiE 'authorization|--oauth2-bearer|tenant_key|x-mcphost-synthetic' && exit 0
printf '%s' "$CMD" | grep -qE '(^|[[:space:]])-u[[:space:]]' && exit 0

# --- hit: decide WARN vs BLOCK from the clock --------------------------------
DEPLOY_EPOCH=$(date -d "$DEPLOY_TS" +%s 2>/dev/null) || exit 0
BLOCK_EPOCH=$(( DEPLOY_EPOCH + WARN_HOURS * 3600 ))
NOW=$(date +%s)
[ "${MCPHOST_STAMP_GATE_SELFTEST:-}" = 1 ] && [ -n "${MCPHOST_STAMP_GATE_NOW:-}" ] && NOW="$MCPHOST_STAMP_GATE_NOW"
if [ "$NOW" -ge "$BLOCK_EPOCH" ]; then MODE=BLOCK; else MODE=WARN; fi

# warn.log: ts, mode, cwd, first 80 chars of the command, Bearer/key-shaped tokens redacted BEFORE truncation
redacted=$(printf '%s' "$CMD" | tr '\n\t' '  ' \
  | sed -E 's/(Bearer[[:space:]]+)[^[:space:]"'"'"']+/\1<redacted>/Ig; s/(mcp|mh|tk|sk|pk|ak|key)[_-][A-Za-z0-9_-]{8,}/<redacted>/Ig; s/[A-Za-z0-9_+\/=-]{32,}/<redacted>/g')
LOGDIR="${HOME}/.local/state/mcphost-stamp-gate"
( umask 077; mkdir -p "$LOGDIR" 2>/dev/null \
  && printf '%s\t%s\t%s\t%s\n' "$(date -Is)" "$MODE" "$CWD" "${redacted:0:80}" >> "$LOGDIR/warn.log" ) 2>/dev/null || true

HDR="x-mcphost-synthetic: <label>"
if [ "$MODE" = WARN ]; then
  cat >&2 <<MSG
mcphost-stamp-gate WARN: keyless write to the mcphost hub creates a tenant counted as a REAL user. Add the header
  -H '$HDR'   (label ^[a-z0-9][a-z0-9:_-]{0,63}\$, e.g. harness:<script> or agent:<seat>) or send Authorization/tenant_key.
This becomes a BLOCK at $(date -d "@$BLOCK_EPOCH" '+%Y-%m-%d %I:%M %p %Z').
MSG
  exit 0
fi
cat >&2 <<MSG
mcphost-stamp-gate: BLOCKED. A keyless write to the mcphost hub creates a tenant counted as a REAL user.
Add the header  -H '$HDR'  (label ^[a-z0-9][a-z0-9:_-]{0,63}\$, e.g. harness:<script> or agent:<seat>), or send Authorization/tenant_key.
MSG
exit 2
