#!/usr/bin/env bash
# Render a one-page Markdown summary from a ctrace NDJSON session log.
#
# Usage: summarize-ctrace-session.sh <path-to-log.ndjson>
# Output: writes <log>.summary.md next to the input; prints its path to stdout.

set -u

log="${1:-}"
if [ -z "$log" ] || [ ! -f "$log" ]; then
    echo "usage: $0 <log.ndjson>" >&2
    exit 2
fi

summary="${log%.ndjson}.summary.md"

# Paths under these prefixes are "in scope" for Claude writes. Anything else
# bubbles up to the "outside expected scope" section.
in_scope='^(/home/jsy/projects/|/home/jsy/Notes/|/home/jsy/brain/|/tmp/|/home/jsy/\.cache/|/home/jsy/\.claude/|/home/jsy/\.local/|/dev/|/proc/|/sys/|/run/user/|/var/tmp/)'

# Always-loud writes — surface separately even if they happen via a tool.
flag_paths='^(/etc/|/home/jsy/\.ssh/|/home/jsy/\.aws/|/home/jsy/\.gnupg/|/root/|/home/jsy/Notes/Journals/Accounts\.md)'

total_events=$(wc -l < "$log" 2>/dev/null || echo 0)

# Duration from min/max ts (boot-relative ms from bpftrace nsecs/1000000).
duration_ms=$(awk '
    {
        if (match($0, /"ts":[0-9]+/)) {
            t = substr($0, RSTART+5, RLENGTH-5) + 0
            if (min == 0 || t < min) min = t
            if (t > max) max = t
        }
    }
    END { print (max - min) }
' "$log" 2>/dev/null)
duration_ms=${duration_ms:-0}

top_exec=$(jq -r 'select(.type=="execve") | .file' "$log" 2>/dev/null \
    | sort | uniq -c | sort -rn | head -10)

writes=$(jq -r 'select(.type=="openat") | .path' "$log" 2>/dev/null)
total_writes=$(printf '%s' "$writes" | grep -cv '^$' 2>/dev/null || true)
total_writes=${total_writes:-0}

out_of_scope=$(printf '%s\n' "$writes" | grep -Ev "$in_scope" | sort -u | head -30)
flagged=$(printf '%s\n' "$writes" | grep -E "$flag_paths" | sort -u | head -20)

deletes=$(jq -r 'select(.type=="unlinkat") | .path' "$log" 2>/dev/null | sort -u | head -20)

connects=$(jq -r 'select(.type=="connect") | .comm' "$log" 2>/dev/null \
    | sort | uniq -c | sort -rn | head -10)

children=$(jq -r 'select(.type=="execve") | .pid' "$log" 2>/dev/null \
    | sort -u | wc -l)

{
    echo "# Claude session trace summary"
    echo
    echo "- Log: \`$log\`"
    echo "- Duration: $(( duration_ms / 1000 ))s · $total_events events · $children unique exec'd PIDs · $total_writes writes"

    echo
    echo "## Top binaries executed"
    echo
    if [ -n "$top_exec" ]; then
        echo '```'
        printf '%s\n' "$top_exec"
        echo '```'
    else
        echo "(none)"
    fi

    echo
    echo "## Writes outside expected scope"
    echo
    if [ -n "$out_of_scope" ]; then
        echo '```'
        printf '%s\n' "$out_of_scope"
        echo '```'
    else
        echo "(none)"
    fi

    if [ -n "$flagged" ]; then
        echo
        echo "## ⚠ Flagged sensitive-path writes"
        echo
        echo '```'
        printf '%s\n' "$flagged"
        echo '```'
    fi

    echo
    echo "## Deletions"
    echo
    if [ -n "$deletes" ]; then
        echo '```'
        printf '%s\n' "$deletes"
        echo '```'
    else
        echo "(none)"
    fi

    echo
    echo "## Outbound connect() by process"
    echo
    if [ -n "$connects" ]; then
        echo '```'
        printf '%s\n' "$connects"
        echo '```'
    else
        echo "(none)"
    fi
} > "$summary"

echo "$summary"
