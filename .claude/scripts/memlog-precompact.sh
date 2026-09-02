#!/usr/bin/env bash
# memlog-precompact.sh — PreCompact hook: snapshot session context to /dev/memlog.
#
# Receives the PreCompact event JSON on stdin (Claude Code hook protocol).
# Extracts transcript_path, composes a bounded snapshot record, and appends
# it to /dev/memlog via `memlog write`.
#
# Fails open: if /dev/memlog is absent, unwritable, or the record is empty,
# logs one line to ~/.cache/memlog/precompact.log and exits 0 — never blocks
# compaction. Safe to install before the memlog group is activated.
#
# Built from PRD-memlog-precompact-witness.md.

set -uo pipefail

MEMLOG_BIN="${HOME}/.local/bin/memlog"
LOG_DIR="${HOME}/.cache/memlog"
LOG_FILE="${LOG_DIR}/precompact.log"
LOG_MAX_AGE_DAYS=14
# /dev/memlog max payload is 64 KiB; leave ~1 KiB for framing overhead
RECORD_MAX_BYTES=65000
# Number of transcript turns to include as a head+tail window
HEAD_TURNS=20
TAIL_TURNS=20

mkdir -p "$LOG_DIR" 2>/dev/null || true

_log() {
    printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# Prune log entries older than LOG_MAX_AGE_DAYS days.
_prune_log() {
    if [ ! -f "$LOG_FILE" ]; then return; fi
    local cutoff
    cutoff=$(date -d "-${LOG_MAX_AGE_DAYS} days" +%Y-%m-%d 2>/dev/null) || return
    # Keep only lines whose leading timestamp is >= cutoff
    local tmpfile="${LOG_FILE}.tmp.$$"
    awk -v cut="$cutoff" '
        /^[0-9]{4}-[0-9]{2}-[0-9]{2}/ { if (substr($1,1,10) >= cut) print; next }
        { print }
    ' "$LOG_FILE" > "$tmpfile" 2>/dev/null && mv "$tmpfile" "$LOG_FILE" 2>/dev/null || rm -f "$tmpfile" 2>/dev/null
}

# Resolve session-id: /proc/self/agent_session (non-zero) > agorabus sid > comm: form.
_session_id() {
    local sid_kernel
    sid_kernel=$(cat /proc/self/agent_session 2>/dev/null || true)
    if [[ -n "$sid_kernel" ]] && [[ "$sid_kernel" != "00000000000000000000000000000000" ]]; then
        printf '%s' "agentns:${sid_kernel:0:16}"
        return
    fi
    # Try agorabus session id from cache (the session-start hook writes a pid->sid mapping).
    local cache_sock="${HOME}/.cache/agorabus/sock"
    if [ -S "$cache_sock" ]; then
        local abus_sid
        abus_sid=$(agorabus peer-id 2>/dev/null || true)
        if [[ -n "$abus_sid" ]]; then
            printf '%s' "agorabus:${abus_sid:0:20}"
            return
        fi
    fi
    # Fallback: comm-based form
    local comm
    comm=$(cat /proc/self/comm 2>/dev/null || echo "unknown")
    printf '%s' "comm:${comm}:$$"
}

_write_to_memlog() {
    local record="$1"
    # Check device presence
    if [ ! -e /dev/memlog ]; then
        _log "SKIP: /dev/memlog absent"
        return 1
    fi
    # Attempt write; capture error for logging
    local err_out
    if err_out=$(printf '%s' "$record" | "$MEMLOG_BIN" write 2>&1); then
        _log "OK: ${#record} bytes written — ${err_out:-success}"
        return 0
    else
        local exit_code=$?
        _log "FAIL(${exit_code}): ${err_out}"
        return 1
    fi
}

# --- Main ---

# Read the PreCompact JSON from stdin (may be empty or absent)
hook_json=""
if [ -t 0 ]; then
    # No stdin (running interactively for testing without piped input)
    _log "SKIP: no stdin (interactive/test run)"
    _prune_log
    exit 0
fi
hook_json=$(cat 2>/dev/null || true)

# Extract transcript_path from the hook event JSON
transcript_path=""
if [[ -n "$hook_json" ]]; then
    transcript_path=$(printf '%s' "$hook_json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('transcript_path', ''))
except Exception:
    pass
" 2>/dev/null || true)
fi

session_id=$(_session_id)
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Build the record payload
if [[ -n "$transcript_path" ]] && [[ -f "$transcript_path" ]]; then
    # Extract a bounded window of turns from the transcript
    transcript_excerpt=$(python3 - "$transcript_path" "$HEAD_TURNS" "$TAIL_TURNS" "$RECORD_MAX_BYTES" <<'PYEOF'
import sys, json, textwrap

path = sys.argv[1]
head_n = int(sys.argv[2])
tail_n = int(sys.argv[3])
max_bytes = int(sys.argv[4])

try:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        data = json.load(f)
except Exception as e:
    print(f"[transcript parse error: {e}]")
    sys.exit(0)

# Support both array-of-messages and {"messages": [...]} formats
if isinstance(data, list):
    messages = data
elif isinstance(data, dict):
    messages = data.get("messages", data.get("turns", []))
else:
    messages = []

total = len(messages)
if total == 0:
    print("[empty transcript]")
    sys.exit(0)

def fmt_turn(t):
    role = t.get("role", "?")
    content = t.get("content", "")
    if isinstance(content, list):
        # Content blocks — join text blocks
        parts = []
        for block in content:
            if isinstance(block, dict):
                if block.get("type") == "text":
                    parts.append(block.get("text", ""))
                elif block.get("type") == "tool_use":
                    parts.append(f"[tool:{block.get('name','')}]")
                elif block.get("type") == "tool_result":
                    parts.append(f"[tool_result]")
            else:
                parts.append(str(block))
        content = " ".join(parts)
    text = str(content)[:500]  # per-turn cap
    return f"{role}: {text}"

# head+tail window avoiding duplicates
if total <= head_n + tail_n:
    selected = list(range(total))
else:
    selected = list(range(head_n)) + list(range(total - tail_n, total))

lines = [f"[transcript: {total} turns, showing head={head_n} tail={tail_n}]"]
prev_idx = -1
for idx in selected:
    if prev_idx >= 0 and idx > prev_idx + 1:
        lines.append(f"  ... ({idx - prev_idx - 1} turns omitted) ...")
    lines.append(fmt_turn(messages[idx]))
    prev_idx = idx

out = "\n".join(lines)
# Truncate to max_bytes
if len(out.encode("utf-8")) > max_bytes:
    out = out.encode("utf-8")[:max_bytes].decode("utf-8", errors="replace") + "\n[truncated]"
print(out)
PYEOF
    )
else
    transcript_excerpt="[no transcript_path]"
    if [[ -n "$hook_json" ]]; then
        transcript_excerpt="[transcript_path not found or empty; hook_event keys=$(printf '%s' "$hook_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(list(d.keys()))" 2>/dev/null || echo '?')]"
    fi
fi

# Compose the record
record=$(printf '%s\n%s\n%s\n%s\n' \
    "=== memlog-precompact snapshot ===" \
    "session_id: ${session_id}" \
    "ts: ${ts}" \
    "${transcript_excerpt}")

# Truncate record to RECORD_MAX_BYTES bytes
record_bytes=$(printf '%s' "$record" | wc -c)
if (( record_bytes > RECORD_MAX_BYTES )); then
    record=$(printf '%s' "$record" | head -c "$RECORD_MAX_BYTES")
    record="${record}
[record truncated at ${RECORD_MAX_BYTES} bytes]"
fi

if [[ -z "${record// /}" ]]; then
    _log "SKIP: empty record"
    _prune_log
    exit 0
fi

_write_to_memlog "$record" || true
_prune_log
exit 0
