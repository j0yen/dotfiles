#!/usr/bin/env bash
# r7-pressure-shed.sh v4 (r7 seat 10-16 8:3x pm, controller 8:30 pm order). Every 30 s (timer). HOT when MemAvailable < 4 GiB OR PSI memory full avg10 > 20
# OR PSI memory some avg10 > 40 OR T7 swap used > 24 GiB (50 % of 48 G) OR swap-in+out > 20 MB/s over 5 s with avail < 8 G.
# Order: (0) HAND CARGO OUTSIDE THE DAEMON'S BUDGET FIRST = cargo/rustc whose cwd is a wm-build wt of an ENDED run (a hand coder working in an ended
#   run's tree, e.g. 306's coder) -> SIGSTOP, auto-SIGCONT after 55 s (never a longer freeze); (1) cargo/rustc whose cwd is under ~/hand -> kill (as v3);
#   (2) still hot after 20 s and nothing was shed -> `wm-build run pause <id>` (.47 real stop, no unit stop, no PRD block) on the NEWEST open GATE-stage run;
#   NEVER a land-stage unit. max one pause per 120 s. R7_SHED_DRY=1 logs the plan and acts on nothing. Journal: ~/.local/state/r7-pressure-shed.log.
# v5 (r7 seat 10-20 6:1x PM, Fable ADOPT-WITH-CHANGES): the max_runs drop is GUARD-OWNED — quote = the guard's own $TAG (read from
#   the guard script, one source), drop record "<from> 1" written to the guard's DROPF before the set, calm counter reset, and
#   ~/.local/state/r7-pressure-shed.last-hot stamped on every HOT, so ryzen7-pressure-guard re-raises toward <from> once the shed has
#   been quiet 10 min (10-20 5:46 PM: a 30 s spike dropped 3->1 tagged as a seat ruling and the guard never re-raised). TAG missing =
#   fail OPEN: drop anyway with the old attribution, log `shed-drop-unowned`. `--selftest` = throwaway HOME, fake readings, no process touched.
set -u
export PATH=$HOME/.cargo/bin:$HOME/.local/bin:/usr/bin:/bin
LOG=$HOME/.local/state/r7-pressure-shed.log; STAMP=$HOME/.local/state/r7-pressure-shed.laststop; DRY=${R7_SHED_DRY:-0}
WT=$HOME/.local/state/wm-build/wt
log() { echo "$(date -Is) $*" >> "$LOG"; [ "$DRY" = 1 ] && echo "$*"; }
read_hot() {
  if [ -n "${SH_SELFTEST:-}" ]; then avail=$SH_AVAIL; full10=$SH_FULL10; some10=$SH_SOME10; swapg=$SH_SWAPG; siso=$SH_SISO
  else
  avail=$(awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo)
  full10=$(awk -F'avg10=' '/^full/{split($2,a," "); print int(a[1])}' /proc/pressure/memory)
  some10=$(awk -F'avg10=' '/^some/{split($2,a," "); print int(a[1])}' /proc/pressure/memory)
  swapg=$(awk '$1 ~ /^\/mnt\/ssd\/swap/{u+=$4}END{print int(u/1048576)}' /proc/swaps)
  read -r si1 so1 < <(awk '/^pswpin/{i=$2}/^pswpout/{o=$2}END{print i,o}' /proc/vmstat); sleep 5
  read -r si2 so2 < <(awk '/^pswpin/{i=$2}/^pswpout/{o=$2}END{print i,o}' /proc/vmstat)
  siso=$(( ((si2-si1)+(so2-so1))*4/1024/5 ))
  fi
  hot=0; { [ "$avail" -lt 4 ] || [ "$full10" -gt 20 ] || [ "$some10" -gt 40 ] || [ "${swapg:-0}" -gt 24 ] || { [ "$siso" -gt 20 ] && [ "$avail" -lt 8 ]; }; } && hot=1
}
GUARD=${R7_SHED_GUARD:-$HOME/.local/bin/ryzen7-pressure-guard.sh}
DROPF=$HOME/.local/state/ryzen7-pressure-guard.drop; CALMF=$HOME/.local/state/ryzen7-pressure-guard.calm
LASTHOT=$HOME/.local/state/r7-pressure-shed.last-hot; GLOG=$HOME/.local/state/wm-build/limits-guard.log
# ---- PROW (r7 10-22 4:5x PM, CTRL a358 + Fable FIX): every limits-guard set leaves a wm-decide row; a shed drop stamps pressure-last-shed and the
#      guard holds raises for HOLD_MIN after it (a shed itself is never held). Premise + expiry come from the shared watcher lib (watcher-premise.sh).
#      Row: first `ssh carbon wm-decide record --kind limit ...` under timeout 20s (a rejected flag or a hung ssh = failure); else one JSON line in
#      $R7_SEAT_STATE/pending-decisions.jsonl + `PROW-PENDING <n>` on every run while that file is non-empty. A failed row never blocks or reverts a set.
PREMISE="max_runs on ryzen7 is moved by memory pressure only while the wm-build daemon runs; raises wait HOLD_MIN after the last shed drop"
EXPIRES=${PROW_EXPIRES:-2026-11-21T23:59:59-08:00}
R7_SEAT_STATE=${R7_SEAT_STATE:-$HOME/.local/state/r7-seat}; PROW_PENDING=$R7_SEAT_STATE/pending-decisions.jsonl; PROW_LASTSHED=$R7_SEAT_STATE/pressure-last-shed
HOLD_MIN=${PROW_HOLD_MIN:-30}
WP_LIB=${WP_LIB:-$HOME/.local/lib/watcher-premise.sh}
if [ -r "$WP_LIB" ]; then . "$WP_LIB"; else wp_arm() { return 2; }; wp_gate() { return 1; }; fi   # no lib = disarmed, never armed-by-default
PROW_PREMISE_DEFAULT='export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}; systemctl --user is-active -q wm-build.service || exit 1'
wp_arm r7-pressure-shed "${PROW_PREMISE_CMD:-$PROW_PREMISE_DEFAULT}" "$EXPIRES" "$PREMISE" || true
prow_say() { echo "$*"; log "$*"; }
prow_state() { # per run (journal only): PROW_ARMED 0|1 (premise holds and unexpired); PROW-EXPIRED / PROW-DISARMED; PROW-PENDING <n>
  local n
  if wp_gate 2>/dev/null; then PROW_ARMED=1; else PROW_ARMED=0; fi
  if [ "${WP_DEFECT:-}" = expired ]; then echo "PROW-EXPIRED r7-pressure-shed expires=$EXPIRES (drops stay live; only the audit is expired)"
  elif [ "$PROW_ARMED" != 1 ]; then echo "PROW-DISARMED r7-pressure-shed verdict=${WP_VERDICT:-?} defect=${WP_DEFECT:--} (drops stay live; only the audit is expired)"; fi
  n=$(grep -c . "$PROW_PENDING" 2>/dev/null || true); if [ "${n:-0}" -gt 0 ]; then echo "PROW-PENDING $n"; fi
  return 0
}
prow_stamp() { mkdir -p "$R7_SEAT_STATE" 2>/dev/null && date +%s > "$PROW_LASTSHED.tmp" 2>/dev/null && mv -f "$PROW_LASTSHED.tmp" "$PROW_LASTSHED" 2>/dev/null || prow_say "PROW-STAMP-FAILED $PROW_LASTSHED"; return 0; }
prow_hold() { # rc 0 = a shed dropped less than HOLD_MIN ago; sets PROW_REMAINING (whole minutes, rounded up)
  local ls el now=${NOW:-$(date +%s)}
  ls=$(cat "$PROW_LASTSHED" 2>/dev/null || echo 0); case "$ls" in ''|*[!0-9]*) ls=0;; esac
  el=$((now-ls)); if [ "$el" -lt 0 ]; then el=0; fi
  if [ "$ls" -gt 0 ] && [ "$el" -lt $((HOLD_MIN*60)) ]; then PROW_REMAINING=$(( (HOLD_MIN*60-el+59)/60 )); return 0; fi
  return 1
}
prow_row() { # SCRIPT OLD NEW WHY: call right after a limits-guard set. Never fails, never reverts the set.
  ( set +e
    scr=$1; old=$2; new=$3; why=$4
    gl=$(grep "limits-set key=max_runs value=$new " "$GLOG" 2>/dev/null | tail -1)
    gts=${gl%% *}; gep=$(date -d "$gts" +%s 2>/dev/null || echo 0)
    if [ -z "$gl" ] || [ $(( $(date +%s) - gep )) -gt 300 ]; then prow_say "PROW-SKIP $scr max_runs $old->$new: no fresh limits-set value=$new line in limits-guard.log (set not applied), no row"; exit 0; fi
    what="$scr: max_runs $old->$new"; ev="ryzen7 limits-guard.log line ts $gts: limits-set key=max_runs value=$new"; rev="max_runs $old"
    rcmd='export PATH=$HOME/.local/bin:$PATH; wm-decide record'
    for a in --agent r7 --via "$scr" --kind limit --target host:ryzen7 --key max_runs --expect "$new" --what "$what" --why "$why" --evidence "$ev" --reverse-text "$rev" --tag "by=joe-$(date +%Y%m%d)+${scr%.sh}"; do rcmd="$rcmd $(printf '%q' "$a")"; done
    out=$(timeout 20s ssh -o BatchMode=yes -o ConnectTimeout=10 carbon "$rcmd" 2>&1); rc=$?
    if [ "$rc" = 0 ] && [ -n "$out" ]; then prow_say "PROW-ROW $(printf '%s' "$out" | tail -1) $what"; exit 0; fi
    err=$(printf '%s' "$out" | tail -1 | cut -c1-200)
    mkdir -p "$R7_SEAT_STATE" 2>/dev/null
    json=$(python3 -I -c 'import json,sys,time
a=sys.argv[1:]
print(json.dumps({"ts":time.strftime("%Y-%m-%dT%H:%M:%S%z"),"agent":"r7","via":a[0],"kind":"limit","target":"host:ryzen7","key":"max_runs","expect":a[1],"what":a[2],"why":a[3],"evidence":a[4],"reverse_text":a[5],"rc":int(a[6]),"err":a[7]},ensure_ascii=False,separators=(",",":")))' "$scr" "$new" "$what" "$why" "$ev" "$rev" "$rc" "$err" 2>/dev/null)
    if [ -n "$json" ] && printf '%s\n' "$json" >> "$PROW_PENDING" 2>/dev/null; then prow_say "PROW-PENDING $(grep -c . "$PROW_PENDING") (row not recorded: rc=$rc ${err:--}; $what)"
    else prow_say "PROW-LOST $what (rc=$rc ${err:--}; pending append failed)"; fi
  ) || true
  return 0
}
if [ "${1:-}" = "--selftest" ]; then
  for b in wm-build wm-build-limits-guard; do command -v "$b" >/dev/null && [ -x "$(command -v "$b")" ] || { echo "selftest FAILED: $b not executable on PATH=$PATH"; exit 1; }; done
  self=$(readlink -f "$0"); real_lg=$(command -v wm-build-limits-guard || echo "$HOME/.local/bin/wm-build-limits-guard"); real_wb=$(command -v wm-build || echo "$HOME/.cargo/bin/wm-build")
  real_pg=${R7_SHED_GUARD:-$HOME/.local/bin/ryzen7-pressure-guard.sh}; pass=0; fail=0; n=0
  real_state=$R7_SEAT_STATE; real_state_m=$(stat -c %y "$real_state" 2>/dev/null || echo absent); real_glog_m=$(stat -c %y "$GLOG" 2>/dev/null || echo absent)   # PROW: asserted unchanged at the end
  # ---- PROW sandbox: stub ssh (runs the "remote" command locally under the sandbox HOME) + stub wm-decide (accepts only the real `wm-decide record --help` flag set;
  #      a limit row needs --target/--key/--expect) + sandbox env. Nothing here can reach carbon, the real limits-guard, the real state dir or the real wm-decide ledger.
  mkstubs() {
    cat > "$T/.local/bin/ssh" <<'S'
#!/usr/bin/env bash
printf '%s|' "$@" >> "$HOME/ssh.calls"; echo >> "$HOME/ssh.calls"
[ -e "$HOME/ssh.fail" ] && exit 255
while [ "${1:-}" = -o ]; do shift 2; done; shift
exec bash -c "$*"
S
    cat > "$T/.local/bin/wm-decide" <<'S'
#!/usr/bin/env bash
printf '%s|' "$@" >> "$HOME/wmd.calls"; echo >> "$HOME/wmd.calls"
[ "${1:-}" = record ] || exit 2; shift; kind=""; have=" "
while [ $# -gt 0 ]; do
  case "$1" in
    --agent|--via|--model|--gates|--attach|--kind|--what|--why|--evidence|--reverse-text|--target|--run|--pr|--slug|--expect-by|--key|--expect|--expect-within-h|--check|--rule|--tag|--from-text)
      [ $# -ge 2 ] || exit 2; have="$have$1 "; [ "$1" = --kind ] && kind=$2; shift 2;;
    *) echo "wm-decide: error: unrecognized arguments: $1" >&2; exit 2;;
  esac
done
case "$have" in *" --agent "*) ;; *) exit 2;; esac
case "$kind" in limit|config|run-state|prod|binary|prd|design|verdict|plan|test|other|correction|restart|guard|observe|gate) ;; *) exit 2;; esac
if [ "$kind" = limit ]; then for r in --target --key --expect; do case "$have" in *" $r "*) ;; *) echo "refused: limit needs $r" >&2; exit 2;; esac; done; fi
[ -e "$HOME/wmd.reject" ] && { echo "wm-decide: error: stub forced rejection" >&2; exit 2; }
echo "d-20261022-000000-r7-stub"
S
    chmod +x "$T/.local/bin/ssh" "$T/.local/bin/wm-decide"
    export R7_SEAT_STATE="$T/.local/state/r7-seat" WP_STATE="$T/.local/state/watcher-premise" WP_LIB PROW_PREMISE_CMD=true PROW_EXPIRES="$(date -d '+1 day' -Iseconds)"
  }
  # stub limits-guard: `set max_runs=N --by X QUOTE` appends the log line + rewrites config.toml; enforce is a no-op
  mkstubs_lg() {
    cat > "$T/.local/bin/wm-build-limits-guard" <<'S'
#!/usr/bin/env bash
case "${1:-}" in
  set) v=${2#max_runs=}; echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) limits-set key=max_runs value=$v by=$4 quote=\"$5\"" >> "$HOME/.local/state/wm-build/limits-guard.log"
       sed -i "s/^max_runs = .*/max_runs = $v/" "$HOME/.config/wm-build/config.toml"; echo x >> "$HOME/set.calls"; echo "set max_runs=$v";;
  *) :;;
esac
S
    chmod +x "$T/.local/bin/wm-build-limits-guard"
  }
  mk() { T=$(mktemp -d "$HOME/.cache/shed-selftest.XXXXXX"); mkdir -p "$T/.config/wm-build" "$T/.local/state/wm-build" "$T/.local/bin"
    mkdir -p "$T/.cargo/bin"; ln -s "$real_wb" "$T/.cargo/bin/wm-build"   # enforce validates via `wm-build config show` on the shed PATH
    cp "$real_lg" "$T/.local/bin/wm-build-limits-guard"; cp "$real_pg" "$T/.local/bin/ryzen7-pressure-guard.sh"
    printf 'box.grace_minutes=20\nbuilder.idle_minutes=20\nbox.roles.coder.max_boxes=4\nbox.roles.coder.max_leases_per_box=7\nmax_runs=%s\nbuilder.type=ccx43\n' "$1" > "$T/.config/wm-build/limits.lock"
    printf 'max_runs = %s  # limits.lock — one record; see wm-build-limits-guard\n[box]\ngrace_minutes = 20\n[box.roles.coder]\nmax_boxes = 4\nmax_leases_per_box = 7\n[builder]\nidle_minutes = 20\ntype = "ccx43"\n' "$1" > "$T/.config/wm-build/config.toml"
    echo "2026-10-14T00:00:00Z limits-set key=max_runs value=$1 by=joe-20261014 quote=\"seat\"" > "$T/.local/state/wm-build/limits-guard.log"
    python3 -I -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("create table runs(id integer, outcome text, stage text, slug text, started text, ended text, worktree text)"); c.execute("create table land(slug text, run_id integer, stage text)"); c.commit()' "$T/.local/state/wm-build/state.db"; mkstubs; }
  sh() { HOME=$T SH_SELFTEST=1 R7_SHED_GUARD="${G:-$T/.local/bin/ryzen7-pressure-guard.sh}" PATH="$T/.local/bin:$PATH" "$@" bash "$self" >/dev/null 2>&1 || true; }
  pg() { HOME=$T PG_SELFTEST=1 PATH="$T/.local/bin:$PATH" "$@" bash "$T/.local/bin/ryzen7-pressure-guard.sh" >/dev/null 2>&1 || true; }
  cur() { grep -E '^max_runs = ' "$T/.config/wm-build/config.toml" | awk '{print $3}'; }
  lastset() { grep 'limits-set key=max_runs ' "$T/.local/state/wm-build/limits-guard.log" | tail -1; }
  ok() { n=$((n+1)); if [ "$1" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $3: got $1 want $2"; fi; }
  # today's real numbers: spike 17:46:46 (avail 7 full10 20 some10 20 swapT7 8 siso 639); post-spike calm 18:00 (swap 6 %, full60 0, siso 0, avail 16)
  SPIKE=(env SH_AVAIL=7 SH_FULL10=21 SH_SOME10=20 SH_SWAPG=8 SH_SISO=639); HEALTHY=(env SH_AVAIL=16 SH_FULL10=0 SH_SOME10=0 SH_SWAPG=3 SH_SISO=0)
  POST=(env PG_SWAPPCT=6 PG_FULL60=0 PG_SISO=0 PG_AVAIL=16 PG_HAND=0)
  TAGV=$(sed -n 's/^TAG="\(.*\)"$/\1/p' "$real_pg" | head -1)
  # (a) HOT at 3, no record -> 1, record "3 1", quote = guard TAG, last-hot stamped
  mk 3; sh "${SPIKE[@]}"; ok "$(cur)/$(cat "$T/.local/state/ryzen7-pressure-guard.drop" 2>/dev/null)/$(lastset | grep -cF "$TAGV")/$([ -s "$T/.local/state/r7-pressure-shed.last-hot" ] && echo hot)" "1/3 1/1/hot" "a:owned-drop"; rm -rf "$T"
  # (b) guard-owned record "3 2" (last set = guard), HOT -> record "3 1" (original from kept)
  mk 2; echo "3 2" > "$T/.local/state/ryzen7-pressure-guard.drop"; echo "2026-10-20T00:00:00Z limits-set key=max_runs value=2 by=joe-20261020 quote=\"$TAGV\"" >> "$T/.local/state/wm-build/limits-guard.log"
  sh "${SPIKE[@]}"; ok "$(cur)/$(cat "$T/.local/state/ryzen7-pressure-guard.drop")" "1/3 1" "b:keep-original-from"; rm -rf "$T"
  # (c) HEALTHY real input must NOT fire: no set, no record, no last-hot, no HOT log line
  mk 3; sh "${HEALTHY[@]}"; ok "$(cur)/$([ -e "$T/.local/state/ryzen7-pressure-guard.drop" ] && echo rec || echo none)/$([ -e "$T/.local/state/r7-pressure-shed.last-hot" ] && echo hot || echo quiet)/$(grep -c HOT "$T/.local/state/r7-pressure-shed.log" 2>/dev/null || echo 0)" "3/none/quiet/0" "c:healthy-no-fire"; rm -rf "$T"
  # (d) TAG missing in the guard -> fail OPEN: still drops to 1, logs shed-drop-unowned, no record
  mk 3; echo '#!/bin/bash' > "$T/noguard.sh"; G=$T/noguard.sh sh "${SPIKE[@]}"; ok "$(cur)/$(grep -c shed-drop-unowned "$T/.local/state/r7-pressure-shed.log")/$([ -e "$T/.local/state/ryzen7-pressure-guard.drop" ] && echo rec || echo none)" "1/1/none" "d:fail-open"; rm -rf "$T"
  # (e) HOT at floor 1 -> no set (never 0 = UNLIMITED)
  mk 1; sh "${SPIKE[@]}"; ok "$(cur)/$(grep -c 'limits-set' "$T/.local/state/wm-build/limits-guard.log")" "1/1" "e:floor-1"; rm -rf "$T"
  # (f) TODAY'S FAILURE end to end: shed drop 3->1, guard on real post-spike calm. Within 10 min of the HOT: no raise.
  #     After the shed is quiet 10 min, 2 calm reads per step: 1->2->3 = back at the lock value.
  mk 3; sh "${SPIKE[@]}"; h=$(cat "$T/.local/state/r7-pressure-shed.last-hot")
  pg "${POST[@]}" PG_NOW=$((h+300)); pg "${POST[@]}" PG_NOW=$((h+590)); early=$(cur)
  for k in 1 2 3 4 5 6 7 8; do pg "${POST[@]}" PG_NOW=$((h+600+k*300)); done   # PROW: raises wait 30 min after the shed drop, so 8 reads not 4
  ok "$early/$(cur)/$(grep -E '^max_runs=' "$T/.config/wm-build/limits.lock" | cut -d= -f2)/$([ -e "$T/.local/state/ryzen7-pressure-guard.drop" ] && echo rec || echo none)" "1/3/3/none" "f:shed-drop-then-calm-ends-at-lock"; rm -rf "$T"
  # ---- PROW cases: stub limits-guard/ssh/wm-decide in a fresh mktemp root. (1) drop -> exactly 1 row call with old/new/reverse + the shed stamp; (2) ssh failure and a
  #      wm-decide flag rejection -> 1 pending JSON line, the set still applied; (3) expired shed still drops and prints PROW-EXPIRED; (4) pending file -> PROW-PENDING n each run
  mkp() { T=$(mktemp -d "$HOME/.cache/prow-selftest.XXXXXX"); mkdir -p "$T/.config/wm-build" "$T/.local/state/wm-build" "$T/.local/bin"
    printf 'max_runs = %s\n' "$1" > "$T/.config/wm-build/config.toml"; echo "2026-10-22T00:00:00Z limits-set key=max_runs value=$1 by=joe-20261022 quote=\"seat\"" > "$T/.local/state/wm-build/limits-guard.log"
    cp "$real_pg" "$T/.local/bin/ryzen7-pressure-guard.sh"; mkstubs; mkstubs_lg; }
  shp() { HOME=$T SH_SELFTEST=1 R7_SHED_GUARD="$T/.local/bin/ryzen7-pressure-guard.sh" PATH="$T/.local/bin:$PATH" "$@" bash "$self" > "$T/out" 2>&1 || true; }
  lines() { if [ -e "$1" ]; then grep -c . "$1" || true; else echo 0; fi; }
  mkp 3; shp "${SPIKE[@]}"
  ok "$(cur)/$(lines "$T/set.calls")/$(lines "$T/wmd.calls")/$(grep -cF '|--kind|limit|--target|host:ryzen7|--key|max_runs|--expect|1|' "$T/wmd.calls")/$(grep -cF 'r7-pressure-shed.sh: max_runs 3->1|' "$T/wmd.calls")/$(grep -cF '|--reverse-text|max_runs 3|' "$T/wmd.calls")/$([ -s "$T/.local/state/r7-seat/pressure-last-shed" ] && echo stamp)/$([ -e "$T/.local/state/r7-seat/pending-decisions.jsonl" ] && echo pend || echo nopend)/$(grep -c '^PROW-ROW d-' "$T/out")" "1/1/1/1/1/1/stamp/nopend/1" "prow-a:drop-one-row"; rm -rf "$T"
  mkp 3; touch "$T/ssh.fail"; shp "${SPIKE[@]}"
  ok "$(cur)/$(lines "$T/set.calls")/$(lines "$T/.local/state/r7-seat/pending-decisions.jsonl")/$(python3 -I -c 'import json,sys; d=json.loads(open(sys.argv[1]).readline()); print(d["kind"],d["expect"],d["reverse_text"].replace(" ","_"),d["rc"])' "$T/.local/state/r7-seat/pending-decisions.jsonl")/$(grep -c '^PROW-PENDING 1' "$T/out")" "1/1/1/limit 1 max_runs_3 255/1" "prow-b:ssh-fail-pending-set-applied"; rm -rf "$T"
  mkp 3; touch "$T/wmd.reject"; shp "${SPIKE[@]}"
  ok "$(cur)/$(lines "$T/wmd.calls")/$(lines "$T/.local/state/r7-seat/pending-decisions.jsonl")/$(grep -c '^PROW-PENDING 1' "$T/out")" "1/1/1/1" "prow-c:flag-rejection-is-failure"; rm -rf "$T"
  mkp 3; shp env PROW_EXPIRES=2020-01-01T00:00:00Z "${SPIKE[@]}"
  ok "$(cur)/$(lines "$T/wmd.calls")/$(grep -c '^PROW-EXPIRED' "$T/out")" "1/1/1" "prow-d:expired-shed-still-drops"; rm -rf "$T"
  mkp 3; mkdir -p "$T/.local/state/r7-seat"; printf '{"x":1}\n{"x":2}\n' > "$T/.local/state/r7-seat/pending-decisions.jsonl"
  shp "${HEALTHY[@]}"; ok "$(cur)/$(lines "$T/set.calls")/$(grep -c '^PROW-PENDING 2' "$T/out")" "3/0/1" "prow-e:pending-visible-every-run"; rm -rf "$T"
  ok "$([ "$(stat -c %y "$real_state" 2>/dev/null || echo absent)" = "$real_state_m" ] && [ "$(stat -c %y "$GLOG" 2>/dev/null || echo absent)" = "$real_glog_m" ] && echo unchanged || echo CHANGED)" "unchanged" "prow-f:real-state-dir-and-limits-guard.log-untouched"
  if [ "$fail" = 0 ]; then echo "selftest ok $pass/$n"; exit 0; else echo "selftest FAILED $fail/$n"; exit 1; fi
fi
prow_state
[ "$DRY" = 1 ] || { read_hot; [ "$hot" = 1 ] || exit 0; }
[ "$DRY" = 1 ] && { read_hot; log "DRY read: avail=${avail}G full10=$full10 some10=$some10 swapT7=${swapg}G siso=${siso}MBps hot=$hot"; }
log "HOT avail=${avail}G full10=$full10 some10=$some10 swapT7=${swapg}G siso=${siso}MBps"
[ "$DRY" = 1 ] || { date +%s > "$LASTHOT.tmp" && mv "$LASTHOT.tmp" "$LASTHOT"; echo 0 > "$CALMF"; }
if [ -z "${SH_SELFTEST:-}" ]; then
# open wt dirs (runs not ended) — a cargo whose cwd is under any other wt dir belongs to a hand coder in an ended run's tree
open_wts=$(python3 -I -c '
import sqlite3,os
c=sqlite3.connect("file:/home/jsy/.local/state/wm-build/state.db?mode=ro",uri=True)
print("\n".join(os.path.basename(r[0] or "") for r in c.execute("select worktree from runs where ended is null")))' 2>/dev/null)
stopped=0
for p in $(pgrep -x cargo; pgrep -x rustc; pgrep -x rust-lld 2>/dev/null); do
  cwd=$(readlink /proc/$p/cwd 2>/dev/null)
  case "$cwd" in "$WT"/*) w=${cwd#$WT/}; w=${w%%/*}; grep -qx "$w" <<<"$open_wts" && continue
    if [ "$DRY" = 1 ]; then log "DRY would deprioritize pid $p ($cwd) "; else { for tid in $(ls /proc/$p/task 2>/dev/null); do renice -n 19 -p "$tid" >/dev/null 2>&1; chrt -i -p 0 "$tid" >/dev/null 2>&1; done; stopped=$((stopped+1)); }; fi;; esac
done
if [ "$stopped" -gt 0 ]; then
  # 10-16 8:5x pm: NO signals to hand compile processes (SIGSTOP of an sccache-spawned rustc wedged the sccache server twice); deprioritized instead (nice 19 + SCHED_IDLE)
  log "deprioritized $stopped hand cargo/rustc outside the daemon budget (ended-run wt): nice 19 + SCHED_IDLE, no signal"
fi
killed=0
for p in $(pgrep -x cargo; pgrep -x rustc; pgrep -x sccache 2>/dev/null); do
  case "$(readlink /proc/$p/cwd 2>/dev/null)" in *"/hand/"*) if [ "$DRY" = 1 ]; then log "DRY would kill pid $p (~/hand)"; else kill -TERM "$p" 2>/dev/null && killed=$((killed+1)); fi;; esac
done
[ "$DRY" = 1 ] || { sleep 3; for p in $(pgrep -x cargo; pgrep -x rustc 2>/dev/null); do case "$(readlink /proc/$p/cwd 2>/dev/null)" in *"/hand/"*) kill -KILL "$p" 2>/dev/null && killed=$((killed+1));; esac; done; }
[ "$killed" -gt 0 ] && log "killed $killed hand cargo/rustc processes (~/hand)"
fi  # end of the process levers (skipped in --selftest)
cur=$(grep -E "^max_runs = " $HOME/.config/wm-build/config.toml | awk '{print $3}')
if [ "${cur:-1}" -gt 1 ] && [ "$DRY" != 1 ]; then
  TAG=$(sed -n 's/^TAG="\(.*\)"$/\1/p' "$GUARD" 2>/dev/null | head -1)
  if [ -n "$TAG" ]; then
    # keep the ORIGINAL ceiling only when the record is still guard-owned (newest max_runs set carries TAG), else this drop's cur
    from=""; grep 'limits-set key=max_runs ' "$GLOG" 2>/dev/null | tail -1 | grep -qF "$TAG" && from=$(awk '{print $1}' "$DROPF" 2>/dev/null || true)
    printf '%s 1\n' "${from:-$cur}" > "$DROPF.tmp" && mv "$DROPF.tmp" "$DROPF"
    out=$(wm-build-limits-guard set max_runs=1 --by "joe-$(date +%Y%m%d)+r7-pressure-shed" "$TAG" 2>&1 | tail -1); wm-build-limits-guard enforce >/dev/null 2>&1 || true
    prow_stamp
    log "DROPPED max_runs ${cur}->1 guard-owned (ceiling ${from:-$cur}; guard re-raises after 10 min quiet + 2 calm reads/step) ($out)"
    prow_row r7-pressure-shed.sh "$cur" 1 "shed HOT avail=${avail}G full10=$full10 some10=$some10 swapT7=${swapg}G siso=${siso}MBps (HOT = avail<4G | full10>20 | some10>40 | swapT7>24G | siso>20MBps with avail<8G)"
  else
    out=$(wm-build-limits-guard set max_runs=1 --by "joe-$(date +%Y%m%d)+r7-pressure-shed" "STOP WAITING FOR MY APPROVAL." 2>&1 | tail -1); wm-build-limits-guard enforce >/dev/null 2>&1 || true
    prow_stamp
    log "DROPPED max_runs ${cur}->1 shed-drop-unowned (no TAG in $GUARD; the guard will NOT re-raise — seat restores) ($out)"
    prow_row r7-pressure-shed.sh "$cur" 1 "shed HOT avail=${avail}G full10=$full10 some10=$some10 swapT7=${swapg}G siso=${siso}MBps (unowned drop: no TAG in the guard)"
  fi
fi
[ -n "${SH_SELFTEST:-}" ] && exit 0
[ "$killed" -gt 0 ] || [ "$stopped" -gt 0 ] && exit 0
[ "$DRY" = 1 ] && { log "DRY: nothing hand-owned to shed; lever 2 would pause the newest open GATE-stage run via 'wm-build run pause' (never land)"; exit 0; }
sleep 15; read_hot; [ "$hot" = 1 ] || { log "cooled after pass (nothing to kill)"; exit 0; }
last=$(cat "$STAMP" 2>/dev/null || echo 0); now=$(date +%s); [ $((now-last)) -ge 120 ] || { log "still HOT, pause on cooldown"; exit 0; }
row=$(python3 -I -c '
import sqlite3; c=sqlite3.connect("file:/home/jsy/.local/state/wm-build/state.db?mode=ro",uri=True)
r=c.execute("select id,slug from runs where outcome is null and stage=\"gate\" order by started desc limit 1").fetchone()
print(f"{r[0]} {r[1]}" if r else "")' 2>/dev/null)
[ -n "$row" ] || { log "still HOT, no open gate-stage run to pause (inners/lands only, never a land) — pressure guard owns max_runs"; exit 0; }
id=${row%% *}; slug=${row#* }
if [ ! -e "$HOME/.local/state/r7-shed-lever2.armed" ]; then log "would-pause $id ($slug) (lever 2 DRY until the live pause/unpause proof; arm = touch ~/.local/state/r7-shed-lever2.armed)"; exit 0; fi
out=$(wm-build run pause "$id" --cause "r7-pressure-shed hot avail=${avail}G some10=$some10 swapT7=${swapg}G" 2>&1 | tail -1)
echo "$now" > "$STAMP"; grep -q "^$id " "$HOME/.local/state/r7-paused-runs" 2>/dev/null || echo "$id $slug $now verb" >> "$HOME/.local/state/r7-paused-runs"
log "PAUSED run $id ($slug) via 'wm-build run pause' (.47 real stop): $out; unpause = wm-build run unpause $id (guard on calm)"
