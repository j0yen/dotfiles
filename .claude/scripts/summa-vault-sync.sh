#!/usr/bin/env bash
# summa-vault-sync.sh — dual-purpose hook.
#   Claude Code: SessionStart (async, timeout 20).
#   hermes: on_session_start — hermes only accepts nothing or
#     {"context":...} on stdout for that event, so this script prints
#     NOTHING on stdout, ever, in either caller.
#
# Keeps the summa wiki vault (~/Notes) current on every node that runs
# it: clone if absent, `git pull --rebase --autostash` if present, and
# `summa index` if wiki/ actually changed. All observability goes to a
# log file, never stdout: one line per run at $SYNC_LOG, shape
#   <ts> <host> <action> <result>
#
# Never retries in a loop and never pushes — this script only pulls the
# vault forward; summa-commit.service (on the node that owns writes)
# still owns pushing.
#
# Best-effort; silent on stdout on every path.

set -uo pipefail

SUMMA_VAULT="${SUMMA_VAULT:-$HOME/Notes}"
SUMMA_VAULT_REMOTE="${SUMMA_VAULT_REMOTE:-https://github.com/j0yen/notes.git}"
SYNC_LOG="${SYNC_LOG:-$HOME/.cache/summa/sync.log}"

mkdir -p "$(dirname "$SYNC_LOG")" 2>/dev/null || true
host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"

log() {
    # log <action> <result...> — appended to $SYNC_LOG only, never stdout.
    local action="$1"
    shift
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s %s %s %s\n' "$ts" "$host" "$action" "$*" >>"$SYNC_LOG" 2>/dev/null || true
}

if ! command -v git >/dev/null 2>&1; then
    log "skip" "no-git"
    exit 0
fi

err_file="$(mktemp 2>/dev/null || echo /dev/null)"
cleanup() { [ "$err_file" = "/dev/null" ] || rm -f "$err_file"; }
trap cleanup EXIT

# ---- Vault absent: clone -------------------------------------------------
if [ ! -d "$SUMMA_VAULT" ]; then
    if timeout 60 git clone --quiet --depth 50 "$SUMMA_VAULT_REMOTE" "$SUMMA_VAULT" >/dev/null 2>"$err_file"; then
        log "clone" "ok"
    else
        first_err="$(head -n1 "$err_file" 2>/dev/null)"
        log "clone" "fail ${first_err:-unknown error}"
    fi
    exit 0
fi

# ---- Vault present but not a git repo: nothing safe to do ----------------
if [ ! -d "$SUMMA_VAULT/.git" ]; then
    log "skip" "not-a-git-repo"
    exit 0
fi

# ---- Vault present and a git repo: pull ----------------------------------
before_head="$(git -C "$SUMMA_VAULT" rev-parse HEAD 2>/dev/null || true)"

if timeout 45 git -C "$SUMMA_VAULT" pull --rebase --autostash --quiet >/dev/null 2>"$err_file"; then
    log "pull" "ok"
    after_head="$(git -C "$SUMMA_VAULT" rev-parse HEAD 2>/dev/null || true)"
    if [ -n "$before_head" ] && [ "$before_head" != "$after_head" ] && command -v summa >/dev/null 2>&1; then
        changed="$(git -C "$SUMMA_VAULT" diff --name-only "$before_head" "$after_head" -- wiki/ 2>/dev/null)"
        if [ -n "$changed" ]; then
            if SUMMA_VAULT="$SUMMA_VAULT" timeout 60 summa index >/dev/null 2>&1; then
                log "index" "ok"
            else
                log "index" "fail"
            fi
        fi
    fi
else
    # Leave the tree as it was — abort any rebase pull left in progress
    # rather than leaving the working tree mid-rebase.
    if [ -d "$SUMMA_VAULT/.git/rebase-merge" ] || [ -d "$SUMMA_VAULT/.git/rebase-apply" ]; then
        git -C "$SUMMA_VAULT" rebase --abort >/dev/null 2>&1 || true
    fi
    first_err="$(head -n1 "$err_file" 2>/dev/null)"
    log "pull" "fail ${first_err:-unknown error}"
fi

exit 0
