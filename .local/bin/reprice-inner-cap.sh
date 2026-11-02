#!/usr/bin/env bash
# rb 10-20: STAGED inner-cap reprice (CTRL 6:2x "pre-build the config switch"). Runs ON RedBaron.
#   reprice-inner-cap.sh               -> report: priced inner rows, max priced vs cap 13.5, proposed value; validates via --set (no write)
#   reprice-inner-cap.sh --apply <gb> --by "<who> <quote>"  -> ONLY after Fable/CTRL approval: tmp + mv -f of config.toml line, status rc 0 or restore
# limits-guard has no mem_caps key (DOTKEYS = box/builder/max_runs only), so the switch is a guarded in-place edit.
# FABLE-DISAGREE 10-20 6:55 AM (via CTRL): the SAME guarded edit couples [daemon] admit_min_avail_x_peak = PA_X (1.0; file had 0.5 since
#   10-16, live through all 3 freezes; 2.0 never admits a 2nd inner on 32 G), and REFUSES a cap < 0.75 x the memory.peak max of the priced rows.
set -uo pipefail
export PATH=$HOME/.cargo/bin:$HOME/.local/bin:$PATH
CFG=$HOME/.config/wm-build/config.toml
DB=$HOME/.local/state/wm-build/state.db
read -r N PMAX MMAX < <(sqlite3 -separator ' ' "$DB" "select count(*), coalesce(round(max(priced_peak_kb)/1048576.0,2),0), coalesce(round(max(peak_rss_kb)/1048576.0,2),0) from steps where kind='inner' and priced_peak_kb is not null")
CUR=$(grep -nE '^inner = ' "$CFG" | head -1)
echo "priced_inner_rows=$N priced_max_gib=$PMAX memory_peak_max_gib=$MMAX cap_line=[$CUR]"
sqlite3 -separator ' ' "$DB" "select run_id, round(priced_peak_kb/1048576.0,2), round(peak_rss_kb/1048576.0,2) from steps where kind='inner' and priced_peak_kb is not null order by rowid desc limit 5" | sed 's/^/  row run priced_gib peak_gib: /'
# proposal = priced max + 2 G headroom (same rule as the land cap: never below @anon peak + 2 G), rounded up to 0.5
PROP=$(awk -v p="$PMAX" 'BEGIN{v=p+2; printf "%.1f", (int(v*2)+(v*2>int(v*2)))/2}')
PA_X=1.0
# FABLE SET-10.5 10-20 (CTRL 8:36): the 0.75 x memory.peak floor was a hidden constant -- every inner peak_rss_kb is the
#   MemoryHigh=14G throttle ceiling (wm-build-.service.d/10-inner-memory.conf), not a measurement. Floor = priced max + 3 G while n < 10, + 2 G after.
FLOOR=$(awk -v p="$PMAX" -v n="$N" 'BEGIN{printf "%.2f", p + (n<10 ? 3 : 2)}')
floor_ok() { awk -v g="$1" -v f="$FLOOR" 'BEGIN{exit !(g>=f)}'; }
echo "proposed_inner_cap_gb=$PROP (priced max + 2 G, ceil 0.5); 2 inners = $(awk -v p="$PROP" 'BEGIN{print 2*p}') vs mem_budget_gb 26"
render() { # $1 = gb -> writes a candidate config to $TMP (never the live file)
  TMP=$(mktemp "$CFG.XXXX")
  awk -v gb="$1" -v by="${BY:-dry-run}" -v st="$(date '+%-m-%d %-I:%M %p')" '
    /^\[cargo_jobs\.mem_caps_gb\]/{s=1; print; next}
    /^\[/{s=0}
    s && /^inner = /{print "inner = " gb "  # rb " st " reprice on priced_peak_kb (" by "); was: " substr($0,9); next}
    /^admit_min_avail_x_peak = /{print "admit_min_avail_x_peak = " px "  # rb " st " Fable 6:55 AM: coupled with the inner reprice (" by "); was: " substr($0,26); next}
    {print}' px="$PA_X" "$CFG" > "$TMP"
  SHOW=$(wm-build config --config "$TMP" show 2>&1)
  GOT=$(grep -A4 '"mem_caps_gb"' <<<"$SHOW" | grep -oE '"inner": [0-9.]+')
  GOTX=$(grep -A3 '"admit_min_avail_x_peak"' <<<"$SHOW" | grep -oE '"value": [0-9.]+' | grep -oE '[0-9.]+$')
}
J=$HOME/.local/state/wm-build/journal.jsonl
# (a) hot reload: daemon/mod.rs reload_mem_gate re-reads [cargo_jobs] mem_* from the FILE every tick (PAC-A2) and journals cargo-gate-reloaded -> no restart
echo "(a) HOT_RELOAD=per-tick (daemon/mod.rs:714 reload_mem_gate, journals cargo-gate-reloaded); last_reload_row=[$(grep '"cargo-gate-reloaded"' "$J" 2>/dev/null | tail -1 | grep -oE '"ts":"[^"]+"' )]"
# (b) limits-guard rewrites only its 6 locked keys (box/builder/max_runs), sed on that key line, and only on drift
echo "(b) GUARD_KEYS=box.grace_minutes,builder.idle_minutes,coder.max_boxes,coder.max_leases_per_box,max_runs,builder.type (no mem_caps); guard_check=[$(wm-build-limits-guard check 2>&1 | tail -1 | cut -c1-80)]"
# (c) PA for a 2nd inner: MemAvailable >= admit_min_avail_x_peak x inner_peak_kb (max peak_rss_kb, last 20 ended inner steps; default while < 3)
X=$(wm-build config show 2>/dev/null | grep -A3 '"admit_min_avail_x_peak"' | grep -oE '"value": [0-9.]+' | grep -oE '[0-9.]+$')
read -r PN PK < <(sqlite3 -separator ' ' "$DB" "select count(*), coalesce(max(peak_rss_kb),0) from (select peak_rss_kb from steps where kind='inner' and ended is not null and peak_rss_kb>0 order by id desc limit 20)")
AV=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo); PSI=$(awk '/^some/{sub("avg10=","",$2); print $2}' /proc/pressure/memory)
for xx in "$X" "$PA_X"; do [ "$xx" = "$X" ] && tag=BEFORE || tag=AFTER
awk -v tag="$tag" -v x="$xx" -v pk="$PK" -v pn="$PN" -v av="$AV" -v psi="$PSI" 'BEGIN{need=x*pk; printf "(c) PA_%s x=%s inner_peak=%.2fGiB(n=%d) need=%.2fGiB MemAvailable=%.2fGiB psi10=%s -> %s\n", tag, x, pk/1048576, pn, need/1048576, av/1048576, psi, (av>=need && psi<=25)?"PA_ADMITS":"PA_REFUSES"}'
done
if [ "${1:-}" != "--apply" ]; then
  render "$PROP"; [ "$GOT" = "\"inner\": $PROP" ] && [ "$GOTX" = "$PA_X" ] && echo "VALIDATE_RC=0 (candidate parses: $GOT, admit_min_avail_x_peak $GOTX)" || echo "VALIDATE_RC=1 got=[$GOT] x=[$GOTX]"; rm -f "$TMP"
  floor_ok "$PROP" && echo "FLOOR_OK: proposed $PROP >= priced max $PMAX + headroom (n=$N) = $FLOOR -> ACCEPT" || echo "FLOOR_REFUSE: proposed $PROP < priced max $PMAX + headroom (n=$N) = $FLOOR -> --apply would REFUSE"
  echo "APPLY_CMD: bash ~/.local/bin/reprice-inner-cap.sh --apply $PROP --by \"<who> <quote>\""
  [ "$N" -ge 3 ] || echo "HOLD: fewer than 3 priced inner rows (Fable rule)"
  exit 0
fi
GB=${2:?gb}; [ "${3:-}" = "--by" ] || { echo "need --by"; exit 2; }; BY=${4:?by}
[ "$N" -ge 3 ] || { echo "REFUSE: $N < 3 priced inner rows"; exit 3; }
floor_ok "$GB" || { echo "REFUSE: cap $GB < priced max $PMAX + headroom (n=$N) = $FLOOR (Fable SET-10.5 10-20)"; exit 6; }
STAMP=$(date +%Y%m%d-%H%M%S); cp -p "$CFG" "$CFG.bak-reprice-$STAMP"
render "$GB"; [ "$GOT" = "\"inner\": $GB" ] && [ "$GOTX" = "$PA_X" ] || { echo "CANDIDATE_BAD got=[$GOT] x=[$GOTX]"; rm -f "$TMP"; exit 4; }
mv -f "$TMP" "$CFG"
if wm-build status >/dev/null 2>&1; then
  for i in $(seq 1 24); do grep -q '"cargo-gate-reloaded"' <(tail -n 200 "$J") && tail -n 200 "$J" | grep '"cargo-gate-reloaded"' | tail -1 | grep -q "\"inner\":$GB" && { echo "RELOADED (journal cargo-gate-reloaded inner=$GB)"; RL=1; break; }; sleep 5; done
  [ "${RL:-0}" = 1 ] || echo "NO_RELOAD_ROW in 120 s: hot reload unproven live -> restart wm-build.service under PROMOTE ANYTIME (no land in commit/merge/tag)"
  wm-build-limits-guard check 2>&1 | tail -1; grep -nE '^inner = ' "$CFG" | head -1 | cut -c1-60
  echo "APPLIED inner=$GB status_rc=0 backup=$CFG.bak-reprice-$STAMP"; wm-build config show | grep -A4 '"mem_caps_gb"' | head -5; wm-build config show | grep -A3 '"admit_min_avail_x_peak"' | head -3
else cp -p "$CFG.bak-reprice-$STAMP" "$CFG"; echo "RESTORED (status rc!=0)"; exit 5; fi
