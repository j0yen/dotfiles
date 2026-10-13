#!/usr/bin/env bash
# statusline-prd-counts.sh — refresh the PRD counts the status line shows.
# Writes ~/.cache/wm-build-statusline/counts as one line:
#   building=<open runs> queued=<eligible PRDs> shipped6=<tags in 6h> ts=<epoch>
# building = `runs` rows with ended IS NULL (what the daemon is driving now).
# queued   = `wm-build queue` rows with eligible=true (what it can admit next).
# shipped6 = `wm-build ledger --since 6h --json` .shipped (0.73.4+: distinct runs tagged in
#   the window at/after `archived`). ONE source of truth; never re-derive it in sqlite here
#   (10-09: a hand query compared RFC3339 'T' stamps against sqlite's ' ' stamps and overcounted).
# Only meaningful on the host whose wm-build daemon is alive; the status line
# checks that before calling this. Runs detached, at most once per interval,
# under an flock so N Claude sessions share one refresh.
set -uo pipefail
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
dir="$HOME/.cache/wm-build-statusline"; mkdir -p "$dir"
exec 9>"$dir/lock"; flock -n 9 || exit 0
pidfile="$HOME/.local/state/wm-build/daemon.pid"
if ! { [ -r "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; }; then
  # 10-12: no daemon here (carbon/orch seat) -- refresh on the build host and copy its line back.
  # Build host = $WM_BUILD_STATUS_HOST or redbaron (daemon moved there 10-08). BatchMode: never prompt.
  # 10-12 3:5x pm: TWO build hosts (RedBaron = mcphost, ryzen7 = synthorg; Joe "utilize ryzen7 for build however best"):
  # building and shipped6 are summed across hosts; queued/total come from the first host that answers
  # (the PRDs repo is shared, so the queue is one queue). src= lists the hosts that answered.
  hosts="${WM_BUILD_STATUS_HOSTS:-redbaron ryzen7}"
  bsum=0; ssum=0; q=""; tot=""; answered=""
  for host in $hosts; do
    line=$(timeout 50 ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" \
      'bash "$HOME/.claude/statusline-prd-counts.sh" >/dev/null 2>&1; cat "$HOME/.cache/wm-build-statusline/counts" 2>/dev/null' 2>/dev/null)
    case "$line" in building=*) ;; *) continue ;; esac
    read -r b qq s t tt rest <<<"$line"
    # a host's own line must be fresh (< 10 min) and its own (no src= tag): a stale fallback copy is not a second host
    case "$rest" in *src=*) continue ;; esac
    [ $(( $(date +%s) - ${t#ts=} )) -lt 600 ] || continue
    bsum=$(( bsum + ${b#building=} )); ssum=$(( ssum + ${s#shipped6=} ))
    [ -z "$q" ] && { q=${qq#queued=}; tot=${tt#total=}; }
    answered="${answered:+$answered+}$host"
  done
  [ -n "$answered" ] || exit 1
  printf 'building=%s queued=%s shipped6=%s ts=%s total=%s src=%s\n' "$bsum" "$q" "$ssum" "$(date +%s)" "${tot:-?}" "$answered" >"$dir/counts.tmp" && mv -f "$dir/counts.tmp" "$dir/counts"
  exit 0
fi
db="$HOME/.local/state/wm-build/state.db"
# 10-12 9:5x pm: ryzen7 has no sqlite3 binary, so this line was empty there, the script exited 1, and its
# 2:44 pm fallback copy of RedBaron's line (building=8) sat in the cache and got SUMMED into carbon's bar (12 vs 7 real).
if command -v sqlite3 >/dev/null 2>&1; then
  building=$(sqlite3 -readonly "$db" "select count(*) from runs where ended is null;" 2>/dev/null)
else
  building=$(python3 -I -c 'import sqlite3,sys;print(sqlite3.connect("file:"+sys.argv[1]+"?mode=ro",uri=True).execute("select count(*) from runs where ended is null").fetchone()[0])' "$db" 2>/dev/null)
fi
shipped6=$(timeout 10 wm-build ledger --since 6h --json 2>/dev/null | jq -r '.shipped' 2>/dev/null)
queued=$(timeout 30 wm-build queue 2>/dev/null | jq '[.[]|select(.eligible)]|length' 2>/dev/null)
# total = PRD files still `Status: queued` (eligible + waiting on Depends-on/claims); 10-10 Joe "status bar prd queue count seems wrong" — 191 ready read as the whole queue of 377
total=$(grep -l '^- Status: queued' "$HOME/Documents/PRDs/build-queue/"*.md 2>/dev/null | wc -l)
[ -n "${building:-}" ] && [ -n "${queued:-}" ] && [ -n "${shipped6:-}" ] || exit 1
printf 'building=%s queued=%s shipped6=%s ts=%s total=%s\n' "$building" "$queued" "$shipped6" "$(date +%s)" "${total:-?}" >"$dir/counts.tmp" \
  && mv -f "$dir/counts.tmp" "$dir/counts"
