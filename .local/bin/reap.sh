#!/usr/bin/env bash
# reap.sh - L6 retention contract executor (A239): runs every entry of gen/retention.json for this host,
# writes one journal receipt per entry (`reap entry=<id> host=<h> reaped=<N> ...`), and raises an ALARM line
# (journal err + $REAP_STATE_DIR/alarm-<id>) when an entry is still over its cap_mb with reaped=0.
# Env: REAP_RETENTION (json), REAP_HOST, REAP_DRY_RUN=1, REAP_STATE_DIR, REAP_SYSTEMCTL, REAP_LOGGER, REAP_GIT.
# Exit 0 on a clean pass, 2 when any alarm was raised. Reaps only direct children of a dir-age path; never follows symlinks.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
json=${REAP_RETENTION:-$here/../../.config/fleet/gen/retention.json}
[ -f "$json" ] || json=$HOME/.config/fleet/gen/retention.json
host=${REAP_HOST:-$(hostname -s)}
dry=${REAP_DRY_RUN:-0}
state=${REAP_STATE_DIR:-$HOME/.local/state/reap}
sysctl=${REAP_SYSTEMCTL:-systemctl}
logger_bin=${REAP_LOGGER:-logger}
git_bin=${REAP_GIT:-git}
mkdir -p "$state" || exit 1
[ -f "$json" ] || { echo "reap: no retention json" >&2; exit 1; }

say() { "$logger_bin" -t reap -- "$1"; echo "$1"; }
expand() { local p=$1; p=${p/#\~/$HOME}; echo "${p//\$HOME/$HOME}"; }
size_mb() { local k; k=$(du -sk -- "$1" 2>/dev/null | cut -f1); echo $(( ${k:-0} / 1024 )); }

rc=0
while IFS=$'\t' read -r id kind path age_h cap_mb repos; do
  alarm="$state/alarm-$id"
  reaped=0 note=""
  case "$kind" in
    dir-age)
      p=$(expand "$path")
      case "$p" in /|""|"$HOME"|/mnt|/mnt/data) say "reap entry=$id host=$host reaped=0 error=unsafe-path"; rc=2; continue;; esac
      if [ ! -d "$p" ] || [ -L "$p" ]; then say "reap entry=$id host=$host reaped=0 note=absent"; rm -f "$alarm"; continue; fi
      before=$(size_mb "$p")
      while IFS= read -r -d '' victim; do
        if [ "$dry" = 1 ]; then reaped=$((reaped+1)); continue; fi
        rm -rf -- "$victim" && reaped=$((reaped+1))
      done < <(find "$p" -mindepth 1 -maxdepth 1 -mmin +$(( age_h * 60 )) -print0 2>/dev/null)
      after=$(size_mb "$p")
      note="size_mb=$after before_mb=$before cap_mb=$cap_mb"
      if [ "$after" -gt "$cap_mb" ] && [ "$reaped" -eq 0 ]; then
        say "reap entry=$id host=$host reaped=$reaped $note ALARM=over-cap-reaped-0"; echo "$(date +%s) $note" > "$alarm"; rc=2
      else
        say "reap entry=$id host=$host reaped=$reaped $note"; rm -f "$alarm"
      fi
      ;;
    failed-units)
      cutoff=$(( $(date +%s) - age_h * 3600 ))
      while read -r unit; do
        [ -n "$unit" ] || continue
        ts=$("$sysctl" --user show -p StateChangeTimestamp "$unit" 2>/dev/null | sed -n 's/^StateChangeTimestamp=//p')
        t=$(date -d "$ts" +%s 2>/dev/null || echo 0)
        [ "$t" -gt 0 ] && [ "$t" -gt "$cutoff" ] && continue
        if [ "$dry" = 1 ] || "$sysctl" --user reset-failed "$unit" >/dev/null 2>&1; then reaped=$((reaped+1)); fi
      done < <("$sysctl" --user list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}')
      say "reap entry=$id host=$host reaped=$reaped"
      rm -f "$alarm"
      ;;
    worktree-prune)
      for r in $repos; do
        rp=$(expand "$r"); [ -d "$rp" ] || continue
        n=$("$git_bin" -C "$rp" worktree prune --dry-run -v 2>/dev/null | grep -c '^Removing')
        [ "$dry" = 1 ] || "$git_bin" -C "$rp" worktree prune 2>/dev/null
        reaped=$((reaped+n))
      done
      say "reap entry=$id host=$host reaped=$reaped"
      rm -f "$alarm"
      ;;
    *) say "reap entry=$id host=$host reaped=0 error=unknown-kind"; rc=2;;
  esac
done < <(python3 -I - "$json" "$host" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for e in d["entries"]:
    if sys.argv[2] not in e.get("hosts", []):
        continue
    print("\t".join([e["id"], e["kind"], e.get("path", "-"), str(e.get("age_h", 0)), str(e.get("cap_mb", 0)), " ".join(e.get("repos", [])) or "-"]))
PY
)
exit $rc
