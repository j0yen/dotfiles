#!/usr/bin/env bash
# fleet-status.sh — the one status block. Cargo/ssh only, never Claude. Prints and (with --journal) appends to the build journal.
# Lines: LOOP, QUEUE, PROD, COST, QUOTA, GATE, DISK. Every status Joe asks for is this script's output.
set -uo pipefail
J=$HOME/brain/journal/build/$(date -u +%F).md
P=$HOME/Documents/PRDs
set -a; . "$HOME/.config/wm-burst/.env" 2>/dev/null; set +a
now=$(date -u +%FT%TZ)
out=()
# LOOP
lp=$(systemctl --user is-active claude-build.path 2>/dev/null); lt=$(systemctl --user is-active claude-build.timer 2>/dev/null)
agents=$(pgrep -fc "[c]laude -p" 2>/dev/null || echo 0)
out+=("LOOP: path=$lp timer=$lt agents=$agents ticks_today=$(grep -c 'tick: start' "$HOME/brain/journal/build-auto.log" 2>/dev/null | head -1)")
# QUEUE
q=$(ls "$P"/build-queue/PRD-*.md 2>/dev/null | wc -l); b=$(ls "$P"/built-prds/PRD-*.md 2>/dev/null | wc -l)
building=$(grep -lE '^- Status: (building|in_progress)' "$P"/build-queue/PRD-*.md 2>/dev/null | xargs -rn1 basename | sed 's/^PRD-//; s/\.md$//' | paste -sd, -)
out+=("QUEUE: queued=$q archived=$b building=[${building:-none}]")
# PROD
d=$(cd "$HOME/wintermute/mcphost-deploy" 2>/dev/null && timeout 60 uv run mcphost-deploy doctor --host mcphost-1 2>/dev/null | grep -oE 'main=[0-9a-f]{7}|last_pass=[0-9a-f]{7}|deployed=[0-9a-f]{7}|drift=[0-9]+' | paste -sd' ' -)
hz=$(curl -s -m 8 https://mcphost.dev/healthz | grep -q '"ok":true' && echo ok || echo FAIL)
ref=$(grep -c 'cannot run the migrated schema\|refuse:' "$HOME/brain/journal/build/vibeloop-measure.log" 2>/dev/null || echo 0)
out+=("PROD: ${d:-doctor-unreadable} healthz=$hz refusals_logged=$ref")
# COST (Hetzner burst boxes)
boxes=$(hcloud server list -o noheader -o columns=name,age 2>/dev/null | awk '/burst/{print $1"("$2")"}' | paste -sd, -)
today_eur=$(grep -E "^$(date -u +%F).*cost_eur=" "$HOME/brain/journal/build/burst-lane.log" 2>/dev/null | grep -oE 'cost_eur=[0-9.]+' | cut -d= -f2 | awk '{s+=$1} END{printf "%.2f", s}')
vol=$(hcloud volume list -o noheader 2>/dev/null | grep -c . || echo 0)
last_run=$(grep -E 'run  routed' "$HOME/brain/journal/build/burst-lane.log" 2>/dev/null | tail -1 | cut -c1-20)
out+=("COST: burst_boxes=[${boxes:-none}] eur_today_deleted_boxes=${today_eur:-0} volumes=$vol last_routed_run=${last_run:-none} idle_guard=$(systemctl --user is-active burst-idle-guard.timer 2>/dev/null)")
# QUOTA proxy (headless sessions started in the last 24h on this host)
sess=$(find "$HOME/.claude/projects/-home-jsy" -maxdepth 1 -name '*.jsonl' -mmin -1440 2>/dev/null | wc -l)
sat=$( [ -f "$HOME/.claude/skills/build/state/quota-saturated" ] && echo SATURATED || echo ok )
out+=("QUOTA: claude_sessions_24h=$sess state=$sat (account meter not readable here; Joe's number wins)")
# GATE outcome contract
lastv=$(grep -hE '  gate  [a-z-]+  (pass|block)' "$J" 2>/dev/null | tail -1 | cut -c1-19)
gates=$(pgrep -fc 'scripts/extend-gate.sh' 2>/dev/null || echo 0)
out+=("GATE: last_verdict=${lastv:-none today} gate_procs=$gates")
# DISK
out+=("DISK: redbaron_root=$(df -h / | awk 'NR==2{print $5}') data=$(df -h /mnt/data 2>/dev/null | awk 'NR==2{print $5}')")
printf '%s\n' "${out[@]}"
if [ "${1:-}" = "--journal" ]; then
  { echo "$now  fleet-status"; printf '  %s\n' "${out[@]}"; } >> "$J"
fi
