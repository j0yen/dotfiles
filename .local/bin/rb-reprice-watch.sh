#!/bin/bash
# rb 10-20 8:4x AM: reverse watcher for the Fable SET-10.5 inner-cap ruling (CTRL 8:36). Runs ON RedBaron.
# Triggers (any -> cap = max priced_peak + 3 G, ceil 0.5, via reprice-inner-cap.sh -- NEVER back to 13.5: Fable re-grade 8:38 / CTRL 8:40;
#   T2 also pauses the younger live inner; T1 re-arms, T2/T3 exit for the seat). Keep armed until n >= 10 priced inner rows.
#   T1 a new steps.priced_peak_kb > 7864320 (7.5 GiB)      T2 2 inners live AND (MemAvailable < MEM_AVAIL_MIN_KB | PSI full avg60 > PSI_FULL_AVG60_MAX)
#   rb 12:2x PM 10-20 (CTRL CORRECT, 3rd false pause today: 1015 9:21, 1018 11:3x, 1019 12:22): swap USED is a stock of cold pages, not pressure ->
#   swap dropped as a trigger; thresholds live in ONE file $CONF (re-read every loop) so the seat tunes them without a restart.
#   T3 app.slice memory.events max or oom_kill increments (also five-whys)
#   T4 (Fable 12:28 PM 10-22, row d-20261022-122657-rb-4acd fix 3, IO pressure; T4 no longer exits, the T4R recovery stage follows): 2 inners live (counted by live_inners, same as T2) AND
#      /proc/pressure/io full avg60 > IO_FULL_AVG60_MAX (conf key, default 10) for 5 consecutive minutes (T4_WINDOW=300 s / SLEEP, rounded up, consecutive
#      loop passes, reset on any pass at or under the threshold) AND no hand cargo scope (an app.slice run-*.scope whose cgroup.procs holds a pid with
#      /proc/<pid>/comm exactly cargo or rustc; comm only, never a cmdline match) -> same pause path as T2 (younger inner, RB-BELL line, then revert, exit).
#      A pass with fewer than 2 inners or with a hand scope resets the count (the window must be clean end to end).
#      rb 12:4x PM 10-22 review: T4 is the d-4acd REVERSE (max_runs 2 -> 1 + pause the newest inner), NOT the inner-cap reprice; T2 (MemAvailable/PSI,
#      also a 4acd reverse condition) now drops max_runs to 1 too. Past EXPIRES every write (pause, max_runs, reprice) is disarmed and logged.
#   T4R (rb 10-22 1:0x PM, CTRL note 3; the recovery stage of T4, which no longer exits): at the T4 pause the RB-BELL line carries pause_cost_coder_min
#      (minutes since the newest commit on the paused run's wt branch = coder work a pause throws away) and T4R_RUN/T4R_PAUSED_AT are recorded. Each later pass:
#      IO full avg60 <= IO_RECOVER_AVG60_MAX (conf key, default 5, hysteresis under the T4 fire threshold 10) AND mem_bad empty -> T4R_N+1, else 0; T4's own
#      fire check is NOT evaluated while recovering, T2 stays live. T4R_N >= ceil(T4R_WINDOW (conf key, default 600 s) / SLEEP) -> (a) re-read the run row and
#      redrive only if ended IS NULL AND stage='inner' AND paused_at IS NOT NULL (else log T4R skip-redrive and leave max_runs alone: whoever acted owns it), (b) only after (a) passed: max_runs 1 -> t4_lowered_from ONLY when t4_lowered_from > 1
#      (the live max_runs read at the pause BEFORE runs_to_1, persisted in the state file; empty = it was already <= 1, T4 lowered nothing, never raise) AND config.toml reads
#      exactly 1 (set + enforce, rc's logged), state persisted to RW_T4R_STATE (default /mnt/data/hand/rb-reprice-watch.t4r.state; loaded once at startup, stale = deleted), (c) redrive (clean wt: wm-build run redrive <id> --from inner; dirty wt: wip-redrive.sh <id>) in a subshell that
#      sources the fleet token (the driver is its own systemd-run unit, daemon.driver_via_systemd_run = true, so it does not live in this unit's cgroup),
#      (d) RB-BELL REPRICE-RECOVER, (e) clear T4R_*, T4_N=0, keep looping. No recovery by 2 h -> RB-BELL REPRICE-RECOVER-STUCK once. Never unpause/--force/--ungated.
# PREMISE: 2 inners compiling on RedBaron can saturate the SATA /mnt/data disk; IO full avg60 > 10 for 5 min with no hand job means the inners themselves are the cause.
# EXPIRES: 2026-11-21   (enforced by the shared lib: wp_gate (watcher-premise.sh) gates every fleet write; EXPIRES stays this ONE date, taken as the end of that day, same as the old bare check)
#   RWH3 (rb 10-23, hand PR rwh3): (1) premise + EXPIRES + write gate come from the shared lib (wp_arm / wp_gate / wp_emit_write); every FLEET write (wm-build run pause, wm-build run redrive, reprice --apply, the max_runs set) is
#      `wp_gate && wp_emit_write <kind> redbaron:<run> ... && <write>`; the watcher's own ledger / state / log files stay ungated. PREMISE cmd reads LOCAL FILES ONLY (host = "redbaron", 1 <= max_runs <= 2, a numeric inner cap): rc 2 = UNKNOWN = still armed.
#      (2) host guard: off RedBaron the watcher prints WRONG-HOST and exits 0 (--selftest skips it; --circuit-gate exits 2 so wip-redrive.sh never reads it as ok). (3) a HELD row is checked BEFORE the W1 circuit gate (it never touches rr_fail / the circuit counters)
#      and early_release SKIPS a held row and tries the next eligible one (still at most ONE release attempt per pass). (4) a disarmed gate with open ledger rows rings RB-BELL WP-DISARMED-LEDGER-NONEMPTY n=<k> once per ledger pass and sets status.json wp_disarmed_ledger=<k>.
#   ROUND 4 (rb 10-22 1:3x PM, row d-20261022-132754-rb-1012, Fable APPROVE-WITH-FIXES): T2 now ARMS T4R exactly like T4 (t4r_cost + t4r_arm BEFORE runs_to_1, revert kept, NO exit;
#      the loop continues). While T4R_RUN is set neither T2 nor T4 fires a second pause or arm (one arm, one state file). The state file gains lowered_from (new key; load falls back
#      to t4_lowered_from), t4r_cause=T2|T4 and daemon_restart_within=<secs since wm-build.service ActiveEnterTimestamp at the arm, or unknown>. A T2-armed pause adds a recovery gate to
#      every pass: MemAvailable_GiB >= 12 + INNER_PEAK_GIB - SIGMA_LIVE_INNER_CAPS (peak = max priced inner row, the target() SQL; sigma = live inners x [cargo_jobs.mem_caps_gb] inner);
#      T4-armed pauses keep the old gate. STUCK bell: 2 h, but 30 min when t4r_cause=T2 AND daemon_restart_within <= 300. R16: state present and the row open but no longer paused
#      (the seat redrove by hand) -> clear state, restore max_runs to lowered_from under the round-3 rule, ZERO redrive calls.
#   ROUND 5 (rb 10-22 2:4x PM, CTRL condition on row d-323d): (1) a redrive with rc != 0 KEEPS the state + file and retries on a later pass whose recovery gate holds (no re-earned window),
#      at most one attempt per 3 passes, until rc 0 (RECOVER bell + clear) or the row re-read shows ended / not paused (skip line + clear); every failed attempt logs `T4R redrive-retry run=<id> rc=<rc> attempt=<k>`
#      and attempts 1, 11, 21 .. also ring RB-BELL REPRICE-RECOVER-RETRY. (2) a state loaded for a run already redriven by hand is kept (no longer deleted) and takes the R16 restore on the first pass after the window.
#      (3) the R16 hand-redrive restore waits for the same IO/mem recovery window (T4R_N >= t4r_need) before it raises max_runs; logs `T4R hand-redrive seen run=<id>; restore waits for io window` once.
#   ROUND 6 (rb 10-22 3:xx PM): a redrive that exits 0 while the row is still open AND still paused (wip-redrive.sh's rc is its last echo, always 0) is treated as refused (rc=86) and retried like any rc != 0.
#      ROUND 6 part 2: (a) a SKIPPED redrive (stage != inner, wt unreadable) on a row that is still open and paused takes the same retry path as rc != 0 (state kept, `T4R redrive-retry ... rc=skipped(<why>)`);
#      the state clears only on a real rc 0 while not still paused, or a NON-EMPTY read showing the row ended / unpaused. (b) every ended / not-paused / missing conclusion needs a non-empty sqlite read (rowq):
#      empty or failed = unknown = keep the state, do nothing, log `T4R row read empty run=<id> at=<site>` once per 10 empty reads per site.
#   ROUND 7 (rb 10-22 4:xx PM, Fable DISAGREE on row b124; the § MG rule: grant iff sum of live caps + this run's cap <= mem_budget_gb, never on a MemAvailable count): BEFORE the max_runs restore AND the redrive
#      (t4r_fire) and before the R16 hand-redrive restore (t4r_step), t4r_sigma computes SIGMA = sum over the OTHER open unpaused runs (ended IS NULL AND paused_at IS NULL, id <> this run) of the config cap of the run's stage
#      (inner|gate|land from [cargo_jobs.mem_caps_gb]; any other stage has no class cap and adds 0) + every live hand cargo scope (an app.slice run-*.scope holding a cargo/rustc comm: its memory.max, which cargo-slot.sh sets from the
#      class / wm-build prefix cap; the config `hand` cap when memory.max is not a number). REFUSE (state kept, max_runs untouched, no redrive, the retry path: attempt bump + 3-pass hold) when SIGMA + inner cap > mem_budget_gb or any
#      read is empty / unparseable (config re-read every pass, same awk parse as mon-inner-ws.sh cap()).
#   ROUND 8 / APPENDIX W (rb 10-22, CTRL 8f7d/a903/ab5e, Fable G12-G16; spec ~/.cache/rb-seat/spec-pra-paused-lane-expiry.md): W1 circuit_gate before EVERY redrive (t4r_fire, the ledger release, wip-redrive.sh via --circuit-gate);
#      W2 every watcher pause = wpause (--cause "...; owner rb; expires <ISO +90m>" + a row in /mnt/data/hand/pause-ledger.tsv, run/paused_at/expires/cause/extensions) and a ledger_pass every 240 s (stale drop, adopt unledgered + bell,
#      ONE expired release per pass behind the W1 + Σ gates, refusal extends 30 min x2 then RB-BELL PAUSE-OVERDUE); W3 ~/.local/state/seat-watch/status.json by tmp+rename each pass. The new block is marked APPENDIX W below. EXPIRES bumped to 2026-11-21.
#   ROUND 9 / W4 (rb 10-22 4:4x PM, correction f9de, Fable APPROVE-WITH-CHANGES G1-G8; spec ~/.cache/rb-seat/spec-w4-sigma-one-source.md). WEAKEST-LINK FALLBACK APPLIED (Fable): change 2 (the daemon's Σ from `redrive --dry-run`) is NOT implementable:
#      in wm-build 0.77.89 run_redrive.rs redrive_with_mem returns `if opts.dry_run { return Ok(RedriveResult{..}) }` at :1236, BEFORE `release_gate(` at :1252, so a dry-run never evaluates release-mem and prints no grant/refuse.
#      So the decision stays the LOCAL t4r_sigma; sigma_drift() only COMPARES it with the newest journal `release-mem` row (the daemon's own Σ before the candidate; age <= 30 min) and logs
#      `SIGMA-DRIFT local=<x> daemon=<y> run=<r> age=<s>s local_parts=[..] daemon_parts=[..]` when they differ by > 0.5 G. (b) is never a decision. Change 3 (premise-recovery release) ships:
#      each ledger pass, after the expiry loop and ONLY if no expiry release fired this pass (G4), at most ONE non-expired row is tried (oldest expiry first) when ALL hold: stage=inner on the daemon row (G6, land/gate never);
#      the run is not T4R_RUN; the ledger cause is `unledgered` or `rb-reprice-watch T2*`; the DAEMON's runs.paused_cause matches EARLY_RE (sigma-guard | MemAvailable | a word-bounded T2); the pause is >= 2 passes old;
#      memory (mem_bad) AND io full avg60 <= IO_FULL_AVG60_MAX were clear for 2 consecutive ledger passes (G5); no early release of this run in the last EARLY_GRACE=1800 s (G5, $EARLY_REC). It goes through release_run unchanged
#      (W1 circuit gate, row re-read, local Σ, dirty wt -> wip-redrive.sh); a refusal does NOT extend, does NOT count toward EXT_MAX, logs `EARLY-RELEASE-REFUSED run=<id> why=..` at most once per 10 passes and backs off 2 passes;
#      a success rings `RB-BELL PAUSE-RELEASED run=<id> early premise-recovered`. PREMISE (W4): an adopted/foreign memory pause whose premise (MemAvailable < 12G, PSI) no longer holds waits the full 90 min for no reason. EXPIRES stays 2026-11-21.
# Output: /mnt/data/hand/reprice-watch.log ; lines with RB-BELL wake the seat. --selftest exercises the trigger arithmetic, the T4 cases and T4R R1-R18 (hermetic: DB/EV/CONF/LOG are fixtures under mktemp -d, no env var needed; RW_DB overrides the live state.db path only).
export PATH=$HOME/.cargo/bin:$HOME/.local/bin:$PATH
case "${1:-}" in --selftest) ;; *)  # E4 host guard: this watcher drives RedBaron's wm-build only; anywhere else it does nothing (and --circuit-gate is NOT an ok)
  [ "$(hostname -s 2>/dev/null)" = redbaron ] || { echo "WRONG-HOST rb-reprice-watch runs on redbaron only (this host: $(hostname -s 2>/dev/null))"; [ "${1:-}" = "--circuit-gate" ] && exit 2; exit 0; };; esac
WP_LIB=${WP_LIB:-$HOME/.local/lib/watcher-premise.sh}
if [ -r "$WP_LIB" ]; then . "$WP_LIB"; else wp_arm() { return 2; }; wp_gate() { return 1; }; wp_emit_write() { return 1; }; fi   # no lib = every fleet write disarmed
export WP_OWNER=rb
export WP_DECIDE_BIN=${WP_DECIDE_BIN:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/rb-reprice-watch-decide.sh}   # E6: wm-decide capped at `timeout 10` so a hung record cannot stall a pause
DB=${RW_DB:-$HOME/.local/state/wm-build/state.db}
EV=/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice/memory.events
LOG=/mnt/data/hand/reprice-watch.log
CONF=/mnt/data/hand/rb-reprice-watch.conf
IO_PSI=${RW_IO_PSI:-/proc/pressure/io}   # T4 inputs; the RW_* overrides exist for the hermetic --selftest only
APP_SLICE=${RW_APP_SLICE:-/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice}
PROC=${RW_PROC:-/proc}
T4R_STATE=${RW_T4R_STATE:-/mnt/data/hand/rb-reprice-watch.t4r.state}   # persisted T4R watch (survives a watcher restart)
MEM_PSI=${RW_MEM_PSI:-/proc/pressure/memory}; MEMINFO=${RW_MEMINFO:-/proc/meminfo}   # T4R inputs (RW_* = hermetic --selftest only; defaults = the real paths)
WT_ROOT=${RW_WT_ROOT:-/mnt/data/wm-build/wt}; CONFIG=${RW_CONFIG:-$HOME/.config/wm-build/config.toml}
REPRICE=${RW_REPRICE:-$HOME/.local/bin/reprice-inner-cap.sh}; WIP_REDRIVE=${RW_WIP_REDRIVE:-/mnt/data/hand/wip-redrive.sh}; ENVF=${RW_ENVFILE:-$HOME/.config/environment.d/90-claude-oauth.conf}
SLEEP=20; T4_WINDOW=300; T4_N=0; T4_WHY=; EXPIRES=2026-11-21
T4R_FROM=; T4R_RUN=; T4R_PAUSED_AT=; T4R_N=0; T4R_COST=unknown; T4R_LAST=; T4R_STUCK=0; T4R_EXPLOG=; T4R_IO=; T4R_CAUSE=T4; T4R_RESTART=unknown; T4R_ATT=0; T4R_HOLD=0; T4R_HRSEEN=; T4R_SATT=0; T4R_SOK=; declare -A T4R_EMPTYN
now_s(){ echo "${RW_NOW:-$(date +%s)}"; }
expired(){ ! wp_gate 2>/dev/null; }   # disarmed = premise GONE, past EXPIRES, or no lib; used for status/idle only. Every fleet write site below runs its own `wp_gate && wp_emit_write ... && <write>`
rw_premise_cmd(){ # $1 = config.toml path -> the `bash -c` text wp_gate runs. LOCAL FILES ONLY (E1): rc 0 HOLDS, rc 1 GONE, rc 2 UNKNOWN (unreadable) which stays armed until EXPIRES
  local q; q=$(printf '%q' "$1")
  printf '%s' "c=$q; [ -r \"\$c\" ] || exit 2; grep -Eq '^host *= *\"redbaron\"' \"\$c\" || exit 1; m=\$(grep -E '^max_runs *=' \"\$c\" | head -1 | sed -E 's/^max_runs *= *([0-9]+).*/\\1/'); case \"\$m\" in ''|*[!0-9]*) exit 2;; esac; [ \"\$m\" -ge 1 ] && [ \"\$m\" -le 2 ] || exit 1; i=\$(awk '/^\\[/{s=(\$0 ~ /^\\[cargo_jobs\\.mem_caps_gb\\]/)} s && /^inner *=/{v=\$0; sub(/^inner *= */,\"\",v); sub(/[^0-9.].*/,\"\",v); print v; exit}' \"\$c\"); case \"\$i\" in ''|*[!0-9.]*) exit 1;; esac; exit 0"; }
rw_arm(){ # $1 = config path for the premise, $2 = EXPIRES ISO (default: end of the EXPIRES day)
  wp_arm rb-reprice-watch "$(rw_premise_cmd "$1")" "${2:-$EXPIRES 23:59:59}" "RedBaron runs wm-build host mode with 1 <= max_runs <= 2 and an inner cap configured (local config.toml only)" || true; }
runs_to_1(){ # $1 why -> d-4acd reverse: max_runs 1 via limits-guard (set + enforce), logged
  if wp_gate && wp_emit_write limit redbaron:max_runs "max_runs -> 1 (d-4acd reverse: $1)" "$1" "wm-build-limits-guard set max_runs=<t4_lowered_from> (T4R restores it) or by hand"; then  # RWH3 gate: set + enforce are one write
    wm-build-limits-guard set max_runs=1 --by "joe-2026-10-22" "STOP WAITING FOR MY APPROVAL. rb-reprice-watch: d-4acd reverse ($1)" >> "$LOG" 2>&1; log "max_runs->1 set rc=$?"
    wm-build-limits-guard enforce >> "$LOG" 2>&1; log "limits enforce rc=$?"
  else log "WP-DISARMED max_runs->1 NOT set (${WP_VERDICT:-no-lib}${WP_DEFECT:+ defect=$WP_DEFECT})"; fi; }
load_conf(){ MEM_AVAIL_MIN_KB=12582912; PSI_FULL_AVG60_MAX=10; IO_FULL_AVG60_MAX=10; IO_RECOVER_AVG60_MAX=5; T4R_WINDOW=600; [ -f "$CONF" ] && . "$CONF"; }
log(){ echo "$(date '+%-I:%M:%S %p') $*" | tee -a "$LOG"; }
ev(){ awk -v k="$1" '$1==k{print $2}' "$EV"; }
target(){ # max priced_peak (GiB) + 3 G, rounded up to 0.5
  sqlite3 "$DB" "select coalesce(max(priced_peak_kb),0)/1048576.0 from steps where kind='inner' and priced_peak_kb is not null" | awk '{v=$1+3; printf "%.1f", (int(v*2)+(v*2>int(v*2)))/2}'; }
mem_bad(){ # $1 avail_kb $2 psi_full_avg60 -> prints reason or nothing (thresholds from load_conf)
  awk -v a="$1" -v p="$2" -v amin="$MEM_AVAIL_MIN_KB" -v pmax="$PSI_FULL_AVG60_MAX" 'BEGIN{ if (a<amin) print "MemAvailable_kb="a"<"amin; else if (p>pmax) print "psi_full_avg60="p">"pmax }'; }
unit_active(){ [ -n "${RW_ALL_ACTIVE:-}" ] && return 0; systemctl --user is-active -q "$1"; }
live_inners(){ # $1 db -> ids of stage='inner' open runs whose driver unit is active (9:22 AM 10-20: never a unit-name glob)
  sqlite3 -separator ' ' "$1" "select id, driver_unit from runs where stage='inner' and outcome is null and driver_unit is not null order by id" | while read -r i u; do unit_active "$u" && echo "$i"; done; }
nlive(){ echo "$1" | grep -c .; }   # $1 = live_inners output -> how many (T2 and T4 both use this)
t4_need(){ echo $(( (T4_WINDOW + ${1:-$SLEEP} - 1) / ${1:-$SLEEP} )); }   # consecutive passes that span T4_WINDOW at sleep $1
hand_scopes(){ # prints how many app.slice run-*.scope hold a process whose comm is EXACTLY cargo or rustc (never a cmdline/pgrep -f match)
  local n=0 s p c
  for s in "$APP_SLICE"/run-*.scope; do
    [ -f "$s/cgroup.procs" ] || continue
    while read -r p; do
      { read -r c < "$PROC/$p/comm"; } 2>/dev/null || continue
      case "$c" in cargo|rustc) n=$((n+1)); break;; esac
    done < "$s/cgroup.procs"
  done
  echo "$n"; }
t4_eval(){ # $1 = live inner count. Advances T4_N; returns 0 and sets T4_WHY when T4 should fire. Caller runs load_conf first.
  local psi; T4_WHY=
  [ "$1" -ge 2 ] || { T4_N=0; return 1; }
  psi=$(awk '/^full/{sub("avg60=","",$3); print $3}' "$IO_PSI" 2>/dev/null)
  if awk -v p="$psi" -v m="$IO_FULL_AVG60_MAX" 'BEGIN{exit !(p!="" && p+0>m+0)}'; then T4_N=$((T4_N+1)); else T4_N=0; return 1; fi
  [ "$(hand_scopes)" = 0 ] || { T4_N=0; return 1; }
  [ "$T4_N" -ge "$(t4_need)" ] || return 1
  T4_WHY="T4 io_full_avg60=$psi>$IO_FULL_AVG60_MAX for $T4_N passes (${T4_WINDOW}s window), no hand cargo scope"; return 0; }
t4r_need(){ echo $(( (T4R_WINDOW + SLEEP - 1) / SLEEP )); }   # consecutive recovered passes that span T4R_WINDOW
t4r_cost(){ # $1 run id -> sets T4R_COST (whole minutes since the newest commit on the run's wt branch, or "unknown") and T4R_LAST; never fails the pause
  local slug ct sha; T4R_COST=unknown; T4R_LAST="last_commit=unknown"
  slug=$(sqlite3 -readonly "$DB" "select slug from runs where id=$1" 2>/dev/null); [ -n "$slug" ] || return 0
  read -r ct sha < <(git -C "$WT_ROOT/$slug" log -1 --format='%ct %h' 2>/dev/null) || return 0
  case "$ct" in ''|*[!0-9]*) return 0;; esac
  T4R_COST=$(( ($(now_s) - ct) / 60 )); [ "$T4R_COST" -ge 0 ] || T4R_COST=0
  T4R_LAST="last_commit=$sha $(date -d "@$ct" '+%-I:%M %p' 2>/dev/null)"; return 0; }
t4r_cfg_max(){ grep -E "^max_runs *=" "$CONFIG" 2>/dev/null | head -1 | sed -nE "s/^max_runs *= *([0-9]+).*/\1/p"; }   # live max_runs from config.toml (read only); empty = unreadable
inner_peak_gib(){ # max priced inner peak in GiB (the SAME SQL as target() above and as PMAX in reprice-inner-cap.sh); empty = unreadable
  sqlite3 -readonly "$DB" "select coalesce(max(priced_peak_kb),0)/1048576.0 from steps where kind='inner' and priced_peak_kb is not null" 2>/dev/null; }
inner_cap_gib(){ # the live [cargo_jobs.mem_caps_gb] inner value from config.toml (the cap_line reprice-inner-cap.sh reads, but section-scoped); empty = unreadable
  awk '/^\[/{s=($0 ~ /^\[cargo_jobs\.mem_caps_gb\]/)} s && /^inner *=/{v=$0; sub(/^inner *= */,"",v); sub(/[^0-9.].*/,"",v); print v; exit}' "$CONFIG" 2>/dev/null; }
t2_mem_gate(){ # $1 MemAvailable kB, $2 live inner count. T2-armed pauses only: MemAvailable_GiB >= 12 + INNER_PEAK_GIB - SIGMA_LIVE_INNER_CAPS (sigma = $2 x inner cap). Unreadable inputs = NOT recovered.
  local pk cap; pk=$(inner_peak_gib); cap=$(inner_cap_gib)
  case "$pk" in ''|*[!0-9.]*) return 1;; esac; case "$cap" in ''|*[!0-9.]*) return 1;; esac
  awk -v a="$1" -v pk="$pk" -v n="${2:-0}" -v cap="$cap" 'BEGIN{exit !(a/1048576 >= 12 + pk - n*cap)}'; }
daemon_restart_within(){ # secs since wm-build.service ActiveEnterTimestamp (RW_DAEMON_ENTER = epoch or "unknown", hermetic selftest only), or "unknown"
  local ts e; ts=${RW_DAEMON_ENTER:-}
  if [ -z "$ts" ]; then ts=$(systemctl --user show wm-build.service -p ActiveEnterTimestamp --value 2>/dev/null); [ -n "$ts" ] && ts=$(date -d "$ts" +%s 2>/dev/null); fi
  case "$ts" in ''|*[!0-9]*) echo unknown; return 0;; esac
  e=$(( $(now_s) - ts )); [ "$e" -ge 0 ] || { echo unknown; return 0; }; echo "$e"; }
t4r_arm(){ # $1 run id, $2 cause T2|T4 (default T4); called right after the pause and BEFORE runs_to_1: records the recovery watch and what max_runs the pause is about to lower (lowered_from; empty = it lowers nothing)
  local cur; T4R_RUN=$1; T4R_CAUSE=${2:-T4}; T4R_RESTART=$(daemon_restart_within); T4R_PAUSED_AT=$(now_s); T4R_N=0; T4R_STUCK=0; T4R_EXPLOG=; T4R_ATT=0; T4R_HOLD=0; T4R_HRSEEN=; T4R_SATT=0; T4R_SOK=; T4_N=0; cur=$(t4r_cfg_max); T4R_FROM=
  case "$cur" in ""|*[!0-9]*) ;; *) [ "$cur" -gt 1 ] && T4R_FROM=$cur;; esac
  t4r_save; log "T4R armed T4R_RUN=$T4R_RUN T4R_PAUSED_AT=$T4R_PAUSED_AT need=$(t4r_need) io_recover_max=$IO_RECOVER_AVG60_MAX pause_cost_coder_min=$T4R_COST max_runs_live=${cur:-unreadable} t4_lowered_from=${T4R_FROM:-none} t4r_cause=$T4R_CAUSE daemon_restart_within=$T4R_RESTART"; }
t4r_note_expired(){ [ -n "$T4R_EXPLOG" ] || { log "T4R disarmed (expired) run=$T4R_RUN"; T4R_EXPLOG=1; }; }
t4r_ok(){ # $1 live inner count. One recovery sample: IO full avg60 <= IO_RECOVER_AVG60_MAX and no mem_bad (+ the T2 mem gate when t4r_cause=T2). Sets T4R_IO. Unreadable inputs count as NOT recovered.
  local av mp
  T4R_IO=$(awk '/^full/{sub("avg60=","",$3); print $3}' "$IO_PSI" 2>/dev/null)
  awk -v p="$T4R_IO" -v m="$IO_RECOVER_AVG60_MAX" 'BEGIN{exit !(p!="" && p+0<=m+0)}' || return 1
  av=$(awk '/^MemAvailable:/{print $2}' "$MEMINFO" 2>/dev/null); mp=$(awk '/^full/{sub("avg60=","",$3); print $3}' "$MEM_PSI" 2>/dev/null)
  [ -z "$(mem_bad "${av:-0}" "${mp:-0}")" ] || return 1  # MEMGATE
  if [ "$T4R_CAUSE" = T2 ]; then t2_mem_gate "${av:-0}" "${1:-0}" || return 1; fi  # T2GATE
}
rowq(){ # $1 site $2 run id $3 sql -> sets ROWV and returns 0 on a NON-EMPTY read; empty / failed sqlite = unknown: returns 1 (callers keep the state and do nothing), logs once per 10 empty reads per site
  local n; ROWV=$(sqlite3 -readonly "$DB" "$3" 2>/dev/null) || ROWV=
  [ -n "$ROWV" ] && return 0
  n=$(( ${T4R_EMPTYN[$1]:-0} + 1 )); T4R_EMPTYN[$1]=$n
  [ $(( (n-1) % 10 )) = 0 ] && log "T4R row read empty run=$2 at=$1"
  return 1; }  # ROWQ
cfg_val(){ # $1 section name (no brackets), $2 key -> its number, empty if absent. The SAME awk parse as ~/.cache/rb-seat/mon-inner-ws.sh cap(), section-scoped and key-parameterised
  awk -v sec="[$1]" -v key="$2" '/^\[/{s=$0} s==sec{sub(/#.*/,""); n=split($0,kv,"="); gsub(/ /,"",kv[1]); gsub(/ /,"",kv[2]); if(n==2 && kv[1]==key){print kv[2]; exit}}' "$CONFIG" 2>/dev/null; }
isnum(){ case "$1" in ''|*[!0-9.]*|*.*.*|.) return 1;; esac; return 0; }
t4r_sigma_local(){ # MG gate (round 7). Sets SIG_SUM SIG_CAP SIG_BUD SIG_PARTS. 0 = grant (SIG_SUM + SIG_CAP <= SIG_BUD); 1 = refuse (over budget, or ANY read empty / unparseable = unknown)
  local c n id stg cp s p mm cnt rows; SIG_SUM=unknown; SIG_PARTS=; SIG_CAP=$(cfg_val cargo_jobs.mem_caps_gb inner); SIG_BUD=$(cfg_val cargo_jobs mem_budget_gb)
  isnum "$SIG_CAP" && isnum "$SIG_BUD" || { SIG_PARTS="config-unreadable(inner=${SIG_CAP:-empty},budget=${SIG_BUD:-empty})"; return 1; }
  cnt=$(sqlite3 -readonly "$DB" "select count(*) from runs where ended is null and paused_at is null and id<>${SIG_RUN:-$T4R_RUN}" 2>/dev/null); isnum "$cnt" || { SIG_PARTS="runs-read-empty"; return 1; }
  SIG_SUM=0
  if [ "$cnt" -gt 0 ]; then
    rows=$(sqlite3 -readonly -separator ' ' "$DB" "select id, coalesce(stage,'-') from runs where ended is null and paused_at is null and id<>${SIG_RUN:-$T4R_RUN} order by id" 2>/dev/null); [ -n "$rows" ] || { SIG_SUM=unknown; SIG_PARTS="runs-read-empty"; return 1; }
    while read -r id stg; do
      case "$stg" in inner|gate|land) ;; *) continue;; esac   # a stage with no class cap adds nothing
      c=$(cfg_val cargo_jobs.mem_caps_gb "$stg"); isnum "$c" || { SIG_SUM=unknown; SIG_PARTS="$SIG_PARTS${SIG_PARTS:+,}$id:$stg:cap-unreadable"; return 1; }
      SIG_SUM=$(awk -v a="$SIG_SUM" -v b="$c" 'BEGIN{printf "%g", a+b}'); SIG_PARTS="$SIG_PARTS${SIG_PARTS:+,}$id:$stg:$c"
    done <<< "$rows"
  fi
  for s in "$APP_SLICE"/run-*.scope; do   # live hand cargo scopes: same detection as hand_scopes (comm exactly cargo/rustc), one entry per scope
    [ -f "$s/cgroup.procs" ] || continue; n=0
    while read -r p; do { read -r c < "$PROC/$p/comm"; } 2>/dev/null || continue; case "$c" in cargo|rustc) n=1; break;; esac; done < "$s/cgroup.procs"
    [ "$n" = 1 ] || continue
    mm=$(cat "$s/memory.max" 2>/dev/null); case "$mm" in ''|*[!0-9]*) c=$(cfg_val cargo_jobs.mem_caps_gb hand);; *) c=$(awk -v b="$mm" 'BEGIN{printf "%g", b/1073741824}');; esac
    isnum "$c" || { SIG_SUM=unknown; SIG_PARTS="$SIG_PARTS${SIG_PARTS:+,}$(basename "$s"):hand:cap-unreadable"; return 1; }
    SIG_SUM=$(awk -v a="$SIG_SUM" -v b="$c" 'BEGIN{printf "%g", a+b}'); SIG_PARTS="$SIG_PARTS${SIG_PARTS:+,}$(basename "$s"):hand:$c"
  done
  awk -v a="$SIG_SUM" -v c="$SIG_CAP" -v b="$SIG_BUD" 'BEGIN{exit !(a+c<=b)}'; }
sigma_drift(){ # W4 (Weakest-link fallback): LOG-ONLY comparison of the local SIG_SUM with the newest journal release-mem row's sum_before_gb (the daemon's Σ before its candidate); never a verdict
  local row js jr jt jp je age
  [ -r "$JOURNAL" ] || return 0
  row=$(tail -c "${RW_JOURNAL_TAIL:-20000000}" "$JOURNAL" 2>/dev/null | tac | grep -m1 '"op":"release-mem"')   # bounded: the last 20 MB only, never the whole hot journal (RW_JOURNAL_TAIL = selftest override); [ -n "$row" ] || return 0
  js=$(jq -r '.row.sum_before_gb // empty' <<< "$row" 2>/dev/null); jr=$(jq -r '.row.run_id // empty' <<< "$row" 2>/dev/null); jt=$(jq -r '.ts // empty' <<< "$row" 2>/dev/null); jp=$(jq -r '(.row.parts // []) | join(",")' <<< "$row" 2>/dev/null)
  isnum "$js" && isnum "$SIG_SUM" || return 0
  je=$(epoch_of "$jt"); case "$je" in ''|*[!0-9]*) return 0;; esac; age=$(( $(now_s) - je )); [ "$age" -le 1800 ] || return 0
  if awk -v a="$SIG_SUM" -v b="$js" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d>0.5)}'; then log "SIGMA-DRIFT local=$SIG_SUM daemon=$js run=${jr:-unknown} age=${age}s local_parts=[${SIG_PARTS:-none}] daemon_parts=[${jp:-none}]"; fi
  return 0; }
t4r_sigma(){ local rc; t4r_sigma_local; rc=$?; sigma_drift; return "$rc"; }   # the decision is t4r_sigma_local's rc, unchanged; the drift line is a side note
t4r_sigma_gate(){ # $1 = fire|seat. Runs t4r_sigma; 0 = granted (logs sigma-ok once per arm). 1 = refused: attempt bump + 3-pass hold, sigma-refused line + RB-BELL on attempts 1, 11, 21 .. (the caller returns, state and max_runs untouched). fire bumps T4R_ATT (retry mode), seat bumps T4R_SATT (the R16 path must not enter retry mode: that would clear it as "not paused")
  local k
  if t4r_sigma; then [ -n "$T4R_SOK" ] || { log "T4R sigma-ok run=$T4R_RUN sigma=$SIG_SUM cap=$SIG_CAP budget=$SIG_BUD"; T4R_SOK=1; }; return 0; fi
  if [ "$1" = fire ]; then T4R_ATT=$((T4R_ATT+1)); k=$T4R_ATT; else T4R_SATT=$((T4R_SATT+1)); k=$T4R_SATT; fi; T4R_HOLD=3
  if [ $(( (k-1) % 10 )) = 0 ]; then log "T4R sigma-refused run=$T4R_RUN sigma=$SIG_SUM cap=$SIG_CAP budget=${SIG_BUD:-unknown} parts=${SIG_PARTS:-none}"; log "RB-BELL REPRICE-SIGMA-REFUSED run=$T4R_RUN attempt=$k sigma=$SIG_SUM cap=$SIG_CAP budget=${SIG_BUD:-unknown}"; fi  # SIGMADEDUP
  return 1; }
t4r_state_rm(){ [ -n "$T4R_STATE" ] && rm -f -- "$T4R_STATE"; return 0; }   # the exact variable path, never a glob
t4r_save(){ # persist the recovery watch (tmp + mv) so a watcher restart does not forget a T4-paused run
  local tmp="$T4R_STATE.tmp.$$"
  { echo "T4R_RUN=$T4R_RUN"; echo "T4R_PAUSED_AT=$T4R_PAUSED_AT"; echo "T4R_COST=$T4R_COST"; echo "T4R_LAST=$T4R_LAST"; echo "T4R_STUCK=$T4R_STUCK"; echo "lowered_from=$T4R_FROM"; echo "t4r_cause=$T4R_CAUSE"; echo "daemon_restart_within=$T4R_RESTART"; } > "$tmp" \
    && mv -f -- "$tmp" "$T4R_STATE" || log "T4R state save failed ($T4R_STATE)"; }
t4r_load(){ # once at startup: restore a persisted recovery watch; a run that ended or is no longer paused makes the file stale (deleted, no writes). T4R_N restarts at 0.
  local k v run= at= cost=unknown last= stuck=0 st from= oldfrom= newseen= cause=T4 restart=unknown
  [ -f "$T4R_STATE" ] || return 0  # LOADGUARD
  while IFS== read -r k v; do case "$k" in T4R_RUN) run=$v;; T4R_PAUSED_AT) at=$v;; T4R_COST) cost=$v;; T4R_LAST) last=$v;; T4R_STUCK) stuck=$v;; lowered_from) from=$v; newseen=1;; t4_lowered_from) oldfrom=$v;; t4r_cause) cause=$v;; daemon_restart_within) restart=$v;; esac; done < "$T4R_STATE"
  case "$run$at" in ''|*[!0-9]*) log "T4R state unreadable (run=[$run] paused_at=[$at]), deleted"; t4r_state_rm; return 0;; esac
  # round 5: a run no longer paused (hand redrive) is KEPT, t4r_step restores after the io window. Round 6: an EMPTY read is unknown, never stale: the state loads and t4r_step re-reads
  if rowq load "$run" "select ended is null from runs where id=$run"; then st=$ROWV
    if [ "$st" != 1 ]; then log "T4R state stale run=$run (row ended), deleted"; t4r_state_rm; return 0; fi; fi  # STALEDEL
  [ -n "$newseen" ] || from=$oldfrom  # T4LF-FALLBACK
  case "$from" in ""|*[!0-9]*) from=;; esac  # key absent / empty / junk = the pause lowered nothing, recovery never raises
  case "$cause" in T2|T4) ;; *) cause=T4;; esac; case "$restart" in ''|*[!0-9]*) restart=unknown;; esac
  T4R_CAUSE=$cause; T4R_RESTART=$restart; T4R_FROM=$from; T4R_RUN=$run; T4R_PAUSED_AT=$at; T4R_COST=$cost; T4R_LAST=$last; T4R_STUCK=$stuck; T4R_N=0; T4R_EXPLOG=; T4R_ATT=0; T4R_HOLD=0; T4R_HRSEEN=; T4R_SATT=0; T4R_SOK=
  log "T4R state loaded T4R_RUN=$T4R_RUN T4R_PAUSED_AT=$T4R_PAUSED_AT pause_cost_coder_min=$T4R_COST stuck_sent=$T4R_STUCK t4_lowered_from=${T4R_FROM:-none} t4r_cause=$T4R_CAUSE daemon_restart_within=$T4R_RESTART (window re-earned from 0)"; }
t4r_fire(){ # recovery window met: (a) re-read the row, (b) max_runs 1 -> t4_lowered_from only when (a) passed AND t4_lowered_from > 1 AND config reads exactly 1, (c) redrive, (d) bell, (e) clear
  local id=$T4R_RUN row slug e s p why= cur sr=- er=- rc=- wt d= res pm pan en unk
  expired && { t4r_note_expired; return 0; }  # EXPGATE
  pm=$(( ($(now_s) - T4R_PAUSED_AT) / 60 ))
  rowq fire-row "$id" "select slug, ended is null, coalesce(stage,''), paused_at is not null from runs where id=$id" || return 0  # REREAD: an empty read is unknown, keep the state, no action this pass
  row=$ROWV; IFS='|' read -r slug e s p <<< "$row"  # sqlite3 default separator is |
  if [ "$e" != 1 ]; then why="run ended"; elif [ "$s" != inner ]; then why="stage=$s, not inner"
  elif [ "$p" != 1 ]; then why="not paused, someone already acted"; fi
  if [ -z "$why" ]; then wt=$WT_ROOT/$slug
    d=$(git -C "$wt" status --porcelain 2>/dev/null) || why="wt unreadable: $wt"; fi
  if [ -n "$why" ] && [ "$e" = 1 ] && [ "$p" = 1 ]; then  # SKIPRETRY round 6: the row is still open AND paused (stage != inner, wt unreadable): a skip is not a success, retry like rc != 0 (never clears)
    T4R_ATT=$((T4R_ATT+1)); T4R_HOLD=3
    log "T4R redrive-retry run=$id rc=skipped($why) attempt=$T4R_ATT"
    [ $(( (T4R_ATT-1) % 10 )) = 0 ] && log "RB-BELL REPRICE-RECOVER-RETRY run=$id rc=skipped($why) attempt=$T4R_ATT"  # RETRYBELL
    return 0
  fi
  [ -z "$why" ] || log "T4R skip-redrive run=$id ($why)"
  [ -n "$why" ] || gate_ok t4r-fire || return 0  # W1 CIRCUIT: no redrive while the quota circuit is open / unreadable; state kept, no attempt bump, re-checked every loop (T4R_N stays >= need)
  [ -n "$why" ] || t4r_sigma_gate fire || return 0  # SIGMAFIRE round 7: refuse BEFORE the max_runs restore and the redrive (state kept, retry path)
  cur=$(grep -E '^max_runs *=' "$CONFIG" 2>/dev/null | head -1 | sed -E 's/^max_runs *= *([0-9]+).*/\1/')
  # NOTE (round 6): max_runs is restored here, BEFORE the redrive rc is known. Harmless if the redrive then fails or is refused: a paused run still counts toward max_runs, so the raised cap admits nothing extra while the run waits for its retry.
  if [ -n "$why" ]; then log "T4R max_runs=${cur:-unreadable} left (redrive skipped: $why; t4_lowered_from=${T4R_FROM:-none})"; res="left(${cur:-unreadable})"  # AGATE
  elif [ -n "$T4R_FROM" ] && [ "$T4R_FROM" -gt 1 ] && [ "$cur" = 1 ]; then  # MAXRUNS1 FLAGGATE
    if wp_gate && wp_emit_write limit redbaron:max_runs "max_runs 1 -> $T4R_FROM (T4R restore after run $id)" "io_full_avg60<=$IO_RECOVER_AVG60_MAX for $T4R_N passes" "wm-build-limits-guard set max_runs=1"; then  # RWH3 gate (set + enforce)
      wm-build-limits-guard set max_runs=$T4R_FROM --by "joe-2026-10-22" "STOP WAITING FOR MY APPROVAL. rb-reprice-watch T4R: io_full_avg60<=$IO_RECOVER_AVG60_MAX for $T4R_N passes" >> "$LOG" 2>&1; sr=$?; log "T4R max_runs->$T4R_FROM set rc=$sr t4_lowered_from=$T4R_FROM"
      wm-build-limits-guard enforce >> "$LOG" 2>&1; er=$?; log "T4R limits enforce rc=$er"; res="$T4R_FROM(set rc=$sr enforce rc=$er t4_lowered_from=$T4R_FROM)"
    else log "WP-DISARMED T4R max_runs->$T4R_FROM NOT set (${WP_VERDICT:-no-lib})"; res="disarmed(left $cur)"; fi
  else log "T4R max_runs=${cur:-unreadable} left (t4_lowered_from=${T4R_FROM:-none})"; res="left(${cur:-unreadable} t4_lowered_from=${T4R_FROM:-none})"; fi
  if [ -z "$why" ]; then
    if ! { wp_gate && wp_emit_write redrive "redbaron:$id" "redrive run $id --from inner (T4R recovery)" "T4R window met: io_full_avg60<=$IO_RECOVER_AVG60_MAX for $T4R_N passes, mem clear, sigma gate granted" "wm-build run pause $id"; }; then  # RWH3 gate: disarmed = rc 87 = the round-5 retry path keeps the state
      rc=87; log "WP-DISARMED T4R redrive run=$id NOT run (${WP_VERDICT:-no-lib}${WP_DEFECT:+ defect=$WP_DEFECT})"
    elif [ -n "$d" ]; then  # DIRTYSEL
      ( set -a; . "$ENVF" || exit 97; set +a; bash "$WIP_REDRIVE" "$id" ) >> "$LOG" 2>&1; rc=$?; log "T4R redrive run=$id via wip-redrive.sh (dirty wt) rc=$rc (the script's rc is its last echo, check paused_at_null)"
    else
      ( set -a; . "$ENVF" || exit 97; set +a; wm-build run redrive "$id" --from inner ) >> "$LOG" 2>&1; rc=$?; log "T4R redrive run=$id --from inner (clean wt) rc=$rc"; fi
    unk=; rowq fire-pan "$id" "select paused_at is null from runs where id=$id" && pan=$ROWV || { pan=; unk=1; }; log "T4R post-redrive run=$id paused_at_null=$pan"
    # STILLPAUSED round 6: wip-redrive.sh ends with an echo (rc always 0) and a refused redrive can also exit 0; rc 0 with the row still open AND still paused = refused (the round-5 retry path takes it)
    if [ "$rc" = 0 ] && [ -z "$unk" ] && [ "$pan" = 0 ]; then rowq fire-ended "$id" "select ended is null from runs where id=$id" && en=$ROWV || { en=; unk=1; }
      if [ "$en" = 1 ]; then rc=86; log "T4R redrive run=$id rc=0 but still paused -> treated as refused (rc=86)"; fi; fi
    if [ "$rc" = 0 ] && [ -n "$unk" ]; then  # UNKNOWNROW: rc 0 but the row cannot be read -> neither success nor refusal is proven: keep the state, re-check next eligible pass (retry mode re-reads before any new redrive)
      T4R_ATT=$((T4R_ATT+1)); T4R_HOLD=3; log "T4R redrive run=$id rc=0 but row unreadable -> state kept (attempt=$T4R_ATT)"; return 0; fi
    if [ "$rc" != 0 ]; then  # RETRYKEEP round 5: a failed redrive keeps the state + file; the next eligible pass retries (never --force/--ungated/unpause)
      T4R_ATT=$((T4R_ATT+1)); T4R_HOLD=3
      log "T4R redrive-retry run=$id rc=$rc attempt=$T4R_ATT"
      [ $(( (T4R_ATT-1) % 10 )) = 0 ] && log "RB-BELL REPRICE-RECOVER-RETRY run=$id rc=$rc attempt=$T4R_ATT"  # RETRYBELL one bell per 10 attempts
      return 0
    fi
  else rc="skipped($why)"; fi
  log "RB-BELL REPRICE-RECOVER run=$id paused_min=$pm pause_cost_coder_min=$T4R_COST max_runs=$res redrive_rc=$rc t4_lowered_from=${T4R_FROM:-none}"
  t4r_state_rm; T4R_FROM=; T4R_RUN=; T4R_PAUSED_AT=; T4R_N=0; T4R_STUCK=0; T4R_EXPLOG=; T4R_COST=unknown; T4R_LAST=; T4R_CAUSE=T4; T4R_RESTART=unknown; T4R_ATT=0; T4R_HOLD=0; T4R_HRSEEN=; T4R_SATT=0; T4R_SOK=; T4_N=0; return 0; }
t4r_seat_redrove(){ # R16: the state is present and the row is open but no longer paused (the seat redrove by hand): clear state, restore max_runs under the round-3 rule (lowered_from > 1 AND live == 1), ZERO redrive calls
  local id=$T4R_RUN cur pm sr=- er=- res; cur=$(t4r_cfg_max); pm=$(( ($(now_s) - T4R_PAUSED_AT) / 60 ))
  log "T4R seat-redrove run=$id (row open, no longer paused): state cleared, no redrive"
  if [ -n "$T4R_FROM" ] && [ "$T4R_FROM" -gt 1 ] && [ "$cur" = 1 ]; then  # SEATRESTORE
    if wp_gate && wp_emit_write limit redbaron:max_runs "max_runs 1 -> $T4R_FROM (T4R restore, seat redrove run $id)" "row open, no longer paused" "wm-build-limits-guard set max_runs=1"; then  # RWH3 gate (set + enforce)
      wm-build-limits-guard set max_runs=$T4R_FROM --by "joe-2026-10-22" "STOP WAITING FOR MY APPROVAL. rb-reprice-watch T4R: the seat redrove run $id by hand, restoring what the pause lowered" >> "$LOG" 2>&1; sr=$?; log "T4R max_runs->$T4R_FROM set rc=$sr t4_lowered_from=$T4R_FROM"
      wm-build-limits-guard enforce >> "$LOG" 2>&1; er=$?; log "T4R limits enforce rc=$er"; res="$T4R_FROM(set rc=$sr enforce rc=$er t4_lowered_from=$T4R_FROM)"
    else log "WP-DISARMED T4R max_runs->$T4R_FROM NOT set (${WP_VERDICT:-no-lib})"; res="disarmed(left $cur)"; fi
  else log "T4R max_runs=${cur:-unreadable} left (t4_lowered_from=${T4R_FROM:-none})"; res="left(${cur:-unreadable} t4_lowered_from=${T4R_FROM:-none})"; fi
  log "RB-BELL REPRICE-RECOVER run=$id paused_min=$pm pause_cost_coder_min=$T4R_COST max_runs=$res redrive_rc=skipped(seat redrove by hand) t4_lowered_from=${T4R_FROM:-none}"
  t4r_state_rm; T4R_FROM=; T4R_RUN=; T4R_PAUSED_AT=; T4R_N=0; T4R_STUCK=0; T4R_EXPLOG=; T4R_COST=unknown; T4R_LAST=; T4R_CAUSE=T4; T4R_RESTART=unknown; T4R_ATT=0; T4R_HOLD=0; T4R_HRSEEN=; T4R_SATT=0; T4R_SOK=; T4_N=0; return 0; }
t4r_step(){ # $1 live inner count. One loop pass while T4R_RUN is set. Neither T2 nor T4 fires while recovering (their fire functions refuse while T4R_RUN is set).
  local now need after=7200 rv; now=$(now_s); need=$(t4r_need)
  expired && { t4r_note_expired; return 0; }  # EXPGATE
  rowq step "$T4R_RUN" "select (ended is null)||(paused_at is null) from runs where id=$T4R_RUN" || return 0  # one read per pass: 10 = open+paused, 11 = open+hand-redriven, 0x = ended; EMPTY = unknown, keep the state, do nothing
  rv=$ROWV
  if [ "$T4R_ATT" -gt 0 ]; then  # RETRYMODE round 5: a redrive failed; the window stays earned (T4R_N untouched), one attempt per 3 passes, only on a pass whose recovery gate holds
    if [ "$rv" != 10 ]; then t4r_fire; return 0; fi  # row ended / no longer paused (non-empty read) -> the skip line + clear
    [ "$T4R_HOLD" -le 0 ] || T4R_HOLD=$((T4R_HOLD-1))
    if [ "$T4R_HOLD" -le 0 ] && t4r_ok "${1:-0}"; then t4r_fire; return 0; fi
  elif [ "$rv" = 11 ]; then  # R16 (the seat redrove by hand): restore only after the same io/mem window
    [ -n "$T4R_HRSEEN" ] || { log "T4R hand-redrive seen run=$T4R_RUN; restore waits for io window"; T4R_HRSEEN=1; }
    if t4r_ok "${1:-0}"; then T4R_N=$((T4R_N+1)); else T4R_N=0; fi
    [ "$T4R_HOLD" -le 0 ] || T4R_HOLD=$((T4R_HOLD-1))
    if [ "$T4R_N" -ge "$need" ] && [ "$T4R_HOLD" -le 0 ]; then t4r_sigma_gate seat && t4r_seat_redrove; fi  # R16WINDOW + SIGMASEAT round 7: the hand-redrive restore raises max_runs too, so it passes the same MG gate
    return 0
  else
    if t4r_ok "${1:-0}"; then T4R_N=$((T4R_N+1)); else T4R_N=0; fi
    if [ "$T4R_N" -ge "$need" ]; then t4r_fire; return 0; fi
  fi
  if [ "$T4R_CAUSE" = T2 ]; then case "$T4R_RESTART" in ''|*[!0-9]*) ;; *) [ "$T4R_RESTART" -le 300 ] && after=1800;; esac; fi  # STUCK30
  if [ $((now - T4R_PAUSED_AT)) -ge "$after" ] && [ "$T4R_STUCK" != 1 ]; then
    log "RB-BELL REPRICE-RECOVER-STUCK run=$T4R_RUN paused_min=$(( (now - T4R_PAUSED_AT) / 60 )) io_full_avg60=${T4R_IO:-unknown}"
    T4R_STUCK=1  # STUCKONCE
    t4r_save
  fi
  return 0; }
# ---- APPENDIX W (rb 10-22 CTRL 8f7d/a903/ab5e; Fable G12-G16): W1 circuit gate on every redrive, W2 expiring pauses + pause-ledger, W3 status.json ----
# PREMISE (W): a pause with no expiry holds a lane forever, and a redrive while the quota circuit is open only burns claim-reaps (run 1037 10-22: 5 reaps, then unit-gone); every
#   watcher/hand pause carries expires = +90 m in pause-ledger.tsv and every redrive passes circuit_gate first. Real circuit evidence (quoted 10-22, hot journal + state.db):
#   journal ops circuit-skip / circuit-pending ONLY (no close/half-open op exists); the OPEN is alarms.ref_='circuit:quota' (cause quota) and circuits.state; the CLOSE is that alarm's `closed`
#   (alarm 3460 closed 21:33:55Z by `wm-build circuit reset --class quota`) and circuits.state='closed' (CLI: `wm-build circuit status`). Close-like journal ops are accepted if a future build adds them.
JOURNAL=${RW_JOURNAL:-$HOME/.local/state/wm-build-hot/journal.jsonl}
LEDGER=${RW_LEDGER:-/mnt/data/hand/pause-ledger.tsv}; LEDGER_LOCK=$LEDGER.lock
DEFERLOG=${RW_DEFERLOG:-/mnt/data/hand/redrive-defer.tsv}; STATUS=${RW_STATUS:-$HOME/.local/state/seat-watch/status.json}
PAUSE_PASS_S=${RW_PASS_S:-240}; PAUSE_MIN=90; EXT_MIN=30; EXT_MAX=2   # pass period 240 s > the 180 s tick + admit latency, so each Σ check sees the previous release's cap
EARLY_REC=${RW_EARLY:-/mnt/data/hand/pause-early.tsv}; EARLY_N=0; EARLY_HOLD=0; EARLY_LOG_AT=0; EARLY_GRACE=1800   # W4: early-release record (run<TAB>epoch), clear-pass counter, backoff, refusal-log clock
EARLY_RE='sigma-guard|MemAvailable|(^|[^A-Za-z0-9])T2([^A-Za-z0-9]|$)'   # memory-class pause causes on the DAEMON row; T2 is word-bounded so a timestamp (...T22:43...) never matches
HELD_REC=${RW_HELD:-/mnt/data/hand/pause-held.tsv}   # RWH: once-per (run, paused_at) record for HELD rows (run<TAB>paused_at<TAB>epoch)
HELD_RE='squash|(^|[^a-z])(hold|held)([^a-z]|$)|never (redrive|unpause)|do not (release|redrive)|release (only )?(by hand|via redrive --from land)|keep paused'   # RWH: a non-watcher pause cause that says a human holds the row (case-insensitive; hold/held word-bounded so threshold/holder never match)
row_held(){ # $1 stage $2 DAEMON paused_cause $3 train_hold_reason -> 0 when the row is HELD (RWH rules; ONE definition for release_run and early_release)
  local h=0; [ -z "$3" ] || h=1
  case "$2" in "rb-reprice-watch T2 "*|"rb-reprice-watch T4 "*) ;; *) [ "$1" != land ] || h=1;; esac
  case "$2" in "rb-reprice-watch T"*) ;; *) ! grep -qiE "$HELD_RE" <<< "$2" || h=1;; esac
  [ "$h" = 1 ]; }
held_skip(){ # $1 run $2 paused_at $3 stage $4 cause $5 train_hold_reason. RWH: log + one bell per (run, paused_at); no redrive, no extension, no rr_fail; the ledger row stays
  local now; [ -z "$(awk -F'\t' -v r="$1" -v p="$2" '$1==r && $2==p' "$HELD_REC" 2>/dev/null)" ] || return 0
  now=$(now_s); mkdir -p "$(dirname "$HELD_REC")"; { awk -F'\t' -v m=$((now - 1209600)) '$3 >= m' "$HELD_REC" 2>/dev/null; printf '%s\t%s\t%s\n' "$1" "$2" "$now"; } > "$HELD_REC.tmp.$$" && mv -f -- "$HELD_REC.tmp.$$" "$HELD_REC"
  log "LEDGER-HELD-SKIP run=$1 stage=$3 cause=\"${4:0:80}\" train_hold=\"${5:0:40}\""
  log "RB-BELL PAUSE-HELD run=$1 stage=$3 cause=\"${4:0:80}\" (held row; release by hand: rb-redrive.sh $1 --from $3)"; }
LP_LAST=0; CG_V=; CG_OP=none; CG_RESETS=unknown; CG_WHY=; CG_LOG_AT=0; CG_NOTE_AT=0; CG_BELL_AT=0; LP_NBELL=0
epoch_of(){ date -d "$1" +%s 2>/dev/null; }
iso_at(){ date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
circuit_gate(){ # W1. rc 0 = redrive allowed, 1 = defer, 2 = unparsable (defer + bell). Sets CG_V CG_OP (latest journal circuit op) CG_RESETS CG_WHY. Read-only.
  local st oa cl row ts tsE rs now; CG_V=unparsable; CG_OP=none; CG_RESETS=unknown; CG_WHY=; now=$(now_s)
  st=$(sqlite3 -readonly "$DB" "select state||'|'||coalesce(resets_at,'') from circuits where class='quota'" 2>/dev/null)
  [ -n "$st" ] || { CG_WHY="circuits row unreadable"; return 2; }
  CG_RESETS=${st#*|}; st=${st%%|*}; [ -n "$CG_RESETS" ] || CG_RESETS=unknown
  oa=$(sqlite3 -readonly "$DB" "select count(*) from alarms where ref_='circuit:quota' and closed is null" 2>/dev/null); case "$oa" in ''|*[!0-9]*) CG_WHY="alarms unreadable"; return 2;; esac
  cl=$(sqlite3 -readonly "$DB" "select coalesce(strftime('%s',max(closed)),0) from alarms where ref_='circuit:quota'" 2>/dev/null); case "$cl" in ''|*[!0-9]*) CG_WHY="alarm close time unreadable"; return 2;; esac
  [ -r "$JOURNAL" ] || { CG_WHY="journal unreadable"; return 2; }
  row=$(timeout 120 tac "$JOURNAL" 2>/dev/null | grep --line-buffered -E '"op":"circuit-[a-z-]+"' | grep -m1 -v -E '"class":"(auth|api-unavailable)"')   # whole journal, newest first
  if [ -n "$row" ]; then
    CG_OP=$(sed -nE 's/.*"op":"(circuit-[a-z-]+)".*/\1/p' <<< "$row"); ts=$(sed -nE 's/.*"ts":"([^"]+)".*/\1/p' <<< "$row"); tsE=$(epoch_of "$ts")
    rs=$(sed -nE 's/.*resets=([0-9T:+Z-]+).*/\1/p' <<< "$row"); [ -z "$rs" ] || CG_RESETS=$rs
    case "$tsE" in ''|*[!0-9]*) CG_WHY="journal ts unparsable ($ts)"; return 2;; esac
  fi
  if [ "$st" != closed ]; then CG_V=defer; CG_WHY="circuits.state=$st"; return 1; fi
  if [ "$oa" -gt 0 ]; then CG_V=defer; CG_WHY="open circuit:quota alarm"; return 1; fi
  case "$CG_OP" in
    none|circuit-close|circuit-closed|circuit-half-open-success|circuit-half-open-ok) ;;
    circuit-skip|circuit-pending|circuit-open|circuit-opened|circuit-half-open*)  # a skip / open newer than the last close (and under 6 h old: a tick emits one every 3 min while open) means the circuit still gates
      if [ "$tsE" -gt "$cl" ] && [ $((now - tsE)) -lt 21600 ]; then CG_V=defer; CG_WHY="$CG_OP at $ts is newer than the last close"; return 1; fi;;
    *) CG_WHY="unknown circuit op $CG_OP"; return 2;;
  esac
  CG_V=ok; return 0; }
cg_note(){ local now; now=$(now_s); [ $((now - CG_NOTE_AT)) -ge 60 ] || return 0; CG_NOTE_AT=$now; mkdir -p "$(dirname "$DEFERLOG")"; printf '%s\t%s\n' "$now" "$1" >> "$DEFERLOG"; }
gate_ok(){ # $1 site. 0 = a redrive may go. Else logs REDRIVE-DEFER (at most one line per 60 s), notes it for status.json, rings once per 10 min when the evidence is unparsable.
  local rc now; circuit_gate; rc=$?; [ "$rc" = 0 ] && return 0; now=$(now_s)
  if [ $((now - CG_LOG_AT)) -ge 60 ]; then CG_LOG_AT=$now; log "REDRIVE-DEFER circuit=quota last_op=$CG_OP resets=$CG_RESETS why=\"$CG_WHY\" at=$1"; fi
  cg_note "$CG_OP"
  if [ "$rc" = 2 ] && [ $((now - CG_BELL_AT)) -ge 600 ]; then CG_BELL_AT=$now; log "RB-BELL REDRIVE-DEFER-UNPARSABLE circuit=quota why=\"$CG_WHY\" at=$1"; fi
  return 1; }
ledger_lockrun(){ ( flock -x 9; "$@" ) 9>"$LEDGER_LOCK"; }
ledger_add_u(){ # run paused_at expires cause ext -> upsert on (run,paused_at)
  local c=${4//$'\t'/ }; c=${c//$'\n'/ }; touch "$LEDGER"
  awk -F'\t' -v OFS='\t' -v r="$1" -v p="$2" '!($1==r && $2==p)' "$LEDGER" > "$LEDGER.tmp.$$" && printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$c" "$5" >> "$LEDGER.tmp.$$" && mv -f -- "$LEDGER.tmp.$$" "$LEDGER"; }
ledger_add(){ ledger_lockrun ledger_add_u "$@"; }
ledger_drop_u(){ touch "$LEDGER"; awk -F'\t' -v OFS='\t' -v r="$1" -v p="$2" '!($1==r && $2==p)' "$LEDGER" > "$LEDGER.tmp.$$" && mv -f -- "$LEDGER.tmp.$$" "$LEDGER"; }
ledger_drop(){ ledger_lockrun ledger_drop_u "$@"; }
ledger_set_u(){ # run paused_at expires ext
  touch "$LEDGER"; awk -F'\t' -v OFS='\t' -v r="$1" -v p="$2" -v e="$3" -v x="$4" '$1==r && $2==p{$3=e; $5=x} {print}' "$LEDGER" > "$LEDGER.tmp.$$" && mv -f -- "$LEDGER.tmp.$$" "$LEDGER"; }
ledger_set(){ ledger_lockrun ledger_set_u "$@"; }
wpause(){ # $1 run id, $2 trigger text -> `wm-build run pause <id> --cause "<trigger>; owner rb; expires <ISO now+90m>"` + a ledger row carrying the DAEMON's paused_at (W2)
  local id=$1 exp cause rc pa; exp=$(iso_at $(( $(now_s) + PAUSE_MIN*60 ))); cause="rb-reprice-watch $2; owner rb; expires $exp"
  if wp_gate && wp_emit_write pause "redbaron:$id" "pause run $id ($2)" "$2" "wm-build run redrive $id --from inner (release); ledger expiry $exp"; then  # RWH3 gate
    wm-build run pause "$id" --cause "$cause" >> "$LOG" 2>&1; rc=$?; log "pause rc=$rc"
  else rc=87; log "WP-DISARMED pause run=$id NOT run (${WP_VERDICT:-no-lib}${WP_DEFECT:+ defect=$WP_DEFECT})"; fi
  [ "$rc" = 0 ] || return 0
  pa=$(sqlite3 -readonly "$DB" "select paused_at from runs where id=$id" 2>/dev/null)
  if [ -n "$pa" ]; then ledger_add "$id" "$pa" "$exp" "$cause" 0; log "LEDGER-ADD run=$id paused_at=$pa expires=$exp"
  else log "LEDGER-ADD-DEFER run=$id (paused_at unreadable); the next pass adopts it as unledgered"; fi; }
status_write(){ # W3: tmp + rename every pass. pause_ledger{open,oldest_expires,overdue}, redrive_defer{count_24h,last_ts,last_op}, premise{verdict,expires}
  local now open=0 old= over=0 e x r p d c n lt lo v wk tmp; now=$(now_s)
  if [ -s "$LEDGER" ]; then
    while IFS=$'\t' read -r r p e d x; do [ -n "$r" ] || continue; open=$((open+1)); n=$(epoch_of "$e"); case "$n" in ''|*[!0-9]*) continue;; esac
      if [ -z "$old" ] || [ "$n" -lt "$old" ]; then old=$n; fi
      if [ "${x:-0}" -ge "$EXT_MAX" ] && [ "$n" -le "$now" ]; then over=$((over+1)); fi
    done < "$LEDGER"
  fi
  c=0; lt=; lo=
  if [ -s "$DEFERLOG" ]; then  # prune to 24 h under the same lock discipline (single writer: this loop), then count
    awk -F'\t' -v m=$((now-86400)) '$1>=m' "$DEFERLOG" > "$DEFERLOG.tmp.$$" && mv -f -- "$DEFERLOG.tmp.$$" "$DEFERLOG"
    c=$(wc -l < "$DEFERLOG"); if [ "$c" -gt 0 ]; then lt=$(tail -n 1 "$DEFERLOG" | cut -f1); lo=$(tail -n 1 "$DEFERLOG" | cut -f2); fi
  fi
  wk=0; if expired; then if [ "${WP_DEFECT:-}" = expired ]; then v=expired; else v=disarmed; fi; wk=$open; else v=armed; fi   # RWH3 E2: wp_disarmed_ledger = open ledger rows while the gate is down
  mkdir -p "$(dirname "$STATUS")"; tmp="$STATUS.tmp.$$"
  jq -n --arg ts "$(iso_at "$now")" --argjson open "$open" --arg old "${old:+$(iso_at "$old")}" --argjson over "$over" --argjson cnt "$c" --arg lt "${lt:+$(iso_at "$lt")}" --arg lo "$lo" --arg v "$v" --arg ex "$EXPIRES" --argjson wk "$wk" \
    '{watcher:"rb-reprice-watch", ts:$ts, pause_ledger:{open:$open, oldest_expires:(if $old=="" then null else $old end), overdue:$over}, redrive_defer:{count_24h:$cnt, last_ts:(if $lt=="" then null else $lt end), last_op:(if $lo=="" then null else $lo end)}, premise:{verdict:$v, expires:$ex}, wp_disarmed_ledger:$wk}' > "$tmp" \
    && mv -f -- "$tmp" "$STATUS" || log "status.json write failed ($STATUS)"; }
release_refused(){ # $1 run $2 paused_at $3 ext $4 why. (d): extend +30 min up to EXT_MAX times, then PAUSE-OVERDUE once (ext -> EXT_MAX+1) and keep re-checking every pass
  local now x=$3; now=$(now_s)
  if [ "$x" -lt "$EXT_MAX" ]; then x=$((x+1)); ledger_set "$1" "$2" "$(iso_at $((now + EXT_MIN*60)))" "$x"; log "LEDGER-EXTEND run=$1 ext=$x expires=$(iso_at $((now + EXT_MIN*60))) why=\"$4\""
  elif [ "$x" -eq "$EXT_MAX" ]; then ledger_set "$1" "$2" "$(iso_at "$now")" $((EXT_MAX+1)); log "RB-BELL PAUSE-OVERDUE run=$1 paused_at=$2 extensions=$x why=\"$4\""
  else log "LEDGER-OVERDUE-RECHECK run=$1 why=\"$4\""; fi; }
rr_fail(){ # $1 run $2 paused_at $3 ext $4 why $5 early(0|1). Expiry path: the extend / overdue ladder (release_refused). EARLY path (W4): NO extension, NOT counted toward EXT_MAX, backs off 2 passes, logs EARLY-RELEASE-REFUSED at most once per 10 passes
  local now; if [ "${5:-0}" != 1 ]; then release_refused "$1" "$2" "$3" "$4"; return 0; fi
  now=$(now_s); EARLY_HOLD=2; if [ $((now - EARLY_LOG_AT)) -ge $((10 * PAUSE_PASS_S)) ]; then EARLY_LOG_AT=$now; log "EARLY-RELEASE-REFUSED run=$1 why=\"$4\""; fi; return 0; }
early_note(){ local now; now=$(now_s); mkdir -p "$(dirname "$EARLY_REC")"; { awk -F'\t' -v m=$((now - 7200)) '$2 >= m' "$EARLY_REC" 2>/dev/null; printf '%s\t%s\n' "$1" "$now"; } > "$EARLY_REC.tmp.$$" && mv -f -- "$EARLY_REC.tmp.$$" "$EARLY_REC"; }
release_run(){ # $1 run $2 paused_at $3 ext $4 early(0|1, default 0). Returns 0 only when the run was released (redrive took, row no longer paused). Gate order (RWH3): row re-read + stale drop, HELD skip, W1 circuit, stage, Σ (MG), then the redrive.
  local id=$1 pa=$2 x=$3 early=${4:-0} q slug e st pnow wt d rc stg2 cp hc cause thr
  q=$(sqlite3 -readonly -separator '|' "$DB" "select slug, ended is null, coalesce(stage,''), coalesce(paused_at,'') from runs where id=$id" 2>/dev/null); [ -n "$q" ] || { log "LEDGER-RELEASE run=$id row read empty, left alone"; return 1; }
  IFS='|' read -r slug e st pnow <<< "$q"
  if [ "$e" != 1 ] || [ "$pnow" != "$pa" ]; then log "LEDGER-STALE run=$id ledger_paused_at=$pa daemon_paused_at=${pnow:-NULL} ended=$([ "$e" = 1 ] && echo no || echo yes); row dropped, NO redrive"; ledger_drop "$id" "$pa"; return 1; fi
  hc=$(sqlite3 -readonly -separator $'\x1f' "$DB" "select replace(coalesce(paused_cause,''), char(10), ' '), replace(coalesce(train_hold_reason,''), char(10), ' ') from runs where id=$id" 2>/dev/null) || { log "LEDGER-RELEASE run=$id cause read failed, left alone"; return 1; }
  IFS=$'\x1f' read -r cause thr <<< "$hc"   # RWH: a HELD row (train hold, a land not paused by this watcher, or a hand/CTRL cause saying hold) is never redriven, extended or counted by the ledger
  if row_held "$st" "$cause" "$thr"; then held_skip "$id" "$pa" "$st" "$cause" "$thr"; return 1; fi   # RWH3 AC3: the HELD check runs BEFORE the W1 circuit gate, so a held row never reaches rr_fail or the circuit counters
  if [ "$CGDONE" = 0 ]; then gate_ok ledger-release; CGRC=$?; CGDONE=1; fi   # evidence read once per pass
  [ "$CGRC" = 0 ] || { rr_fail "$id" "$pa" "$x" "circuit gate: $CG_V ($CG_WHY)" "$early"; return 1; }
  case "$st" in inner|gate|land) ;; *) rr_fail "$id" "$pa" "$x" "stage=$st has no redrive class" "$early"; return 1;; esac
  SIG_RUN=$id; t4r_sigma; rc=$?; SIG_RUN=
  if [ "$rc" != 0 ]; then
    [ "$early" = 1 ] || log "LEDGER-RELEASE run=$id sigma-refused sigma=$SIG_SUM cap=$SIG_CAP budget=${SIG_BUD:-unknown} parts=${SIG_PARTS:-none}"
    rr_fail "$id" "$pa" "$x" "sigma refused (sum $SIG_SUM + cap $SIG_CAP > budget ${SIG_BUD:-unknown}; parts ${SIG_PARTS:-none})" "$early"; return 1; fi
  wt=$WT_ROOT/$slug; d=; [ "$st" = inner ] && d=$(git -C "$wt" status --porcelain 2>/dev/null)
  if ! { wp_gate && wp_emit_write redrive "redbaron:$id" "redrive run $id --from $st (ledger release${early:+, early=$early})" "pause-ledger row expired or premise recovered; W1 circuit + sigma gates passed" "wm-build run pause $id"; }; then rc=87; log "WP-DISARMED LEDGER-RELEASE run=$id redrive NOT run (${WP_VERDICT:-no-lib}${WP_DEFECT:+ defect=$WP_DEFECT})"   # RWH3 gate
  elif [ -n "$d" ]; then ( set -a; . "$ENVF" || exit 97; set +a; bash "$WIP_REDRIVE" "$id" ) >> "$LOG" 2>&1; rc=$?; log "LEDGER-RELEASE run=$id via wip-redrive.sh (dirty wt) rc=$rc"
  else ( set -a; . "$ENVF" || exit 97; set +a; wm-build run redrive "$id" --from "$st" ) >> "$LOG" 2>&1; rc=$?; log "LEDGER-RELEASE run=$id --from $st rc=$rc"; fi
  cp=$(sqlite3 -readonly "$DB" "select coalesce(paused_at,'') from runs where id=$id" 2>/dev/null)
  if [ "$rc" = 0 ] && [ -z "$cp" ] && [ -n "$(sqlite3 -readonly "$DB" "select id from runs where id=$id and ended is null" 2>/dev/null)" ]; then
    ledger_drop "$id" "$pa"
    if [ "$early" = 1 ]; then early_note "$id"; EARLY_N=0; log "RB-BELL PAUSE-RELEASED run=$id early premise-recovered"
    else log "RB-BELL PAUSE-RELEASED run=$id stage=$st expired pause redriven (W1+Σ gated)"; fi
    return 0; fi
  rr_fail "$id" "$pa" "$x" "redrive rc=$rc, row paused_at=${cp:-NULL}" "$early"; return 1; }
early_clear(){ # W4: one sample, 0 = memory AND io are clear NOW (mem_bad empty; io full avg60 <= IO_FULL_AVG60_MAX). An unreadable input is NOT clear.
  local av psi io
  av=$(awk '/^MemAvailable:/{print $2}' "$MEMINFO" 2>/dev/null); psi=$(awk '/^full/{sub("avg60=","",$3); print $3}' "$MEM_PSI" 2>/dev/null); io=$(awk '/^full/{sub("avg60=","",$3); print $3}' "$IO_PSI" 2>/dev/null)
  isnum "$av" && isnum "$psi" && isnum "$io" || return 1
  [ -z "$(mem_bad "$av" "$psi")" ] || return 1
  awk -v p="$io" -v m="$IO_FULL_AVG60_MAX" 'BEGIN{exit !(p+0 <= m+0)}'; }
early_release(){ # W4 change 3. $1 = now, $2 = ledger lines "expires<TAB>run<TAB>paused_at<TAB>cause<TAB>ext" sorted oldest first. At most ONE attempt per pass (first eligible row). Returns release_run's rc, 1 when nothing was eligible.
  local now=$1 e r p lc x q st pa cause thr pe n last
  if [ "$EARLY_HOLD" -gt 0 ]; then EARLY_HOLD=$((EARLY_HOLD - 1)); return 1; fi
  while IFS=$'\t' read -r e r p lc x; do [ -n "$r" ] || continue
    n=$(epoch_of "$e"); case "$n" in ''|*[!0-9]*) continue;; esac; [ "$n" -gt "$now" ] || continue   # NON-expired rows only; the expiry loop owns the rest
    [ "$r" != "$T4R_RUN" ] || continue
    case "$lc" in unledgered|"rb-reprice-watch T2"*) ;; *) continue;; esac
    q=$(sqlite3 -readonly -separator $'\x1f' "$DB" "select coalesce(stage,''), coalesce(paused_at,''), replace(coalesce(paused_cause,''), char(10), ' '), replace(coalesce(train_hold_reason,''), char(10), ' ') from runs where id=$r and ended is null" 2>/dev/null); [ -n "$q" ] || continue
    IFS=$'\x1f' read -r st pa cause thr <<< "$q"
    [ "$st" = inner ] || continue   # G6: a land / gate row is never early-released
    [ "$pa" = "$p" ] || continue
    grep -qE "$EARLY_RE" <<< "$cause" || continue   # daemon truth, memory-class only
    pe=$(epoch_of "$pa"); case "$pe" in ''|*[!0-9]*) continue;; esac; [ $((now - pe)) -ge $((2 * PAUSE_PASS_S)) ] || continue   # the pause must predate the two clear samples
    last=$(awk -F'\t' -v r="$r" '$1==r{v=$2} END{print v}' "$EARLY_REC" 2>/dev/null)
    case "$last" in ''|*[!0-9]*) ;; *) [ $((now - last)) -ge "$EARLY_GRACE" ] || continue;; esac   # G5: re-paused within 30 min of an early release -> waits for expiry
    if row_held "$st" "$cause" "$thr"; then held_skip "$r" "$p" "$st" "$cause" "$thr"; continue; fi   # RWH3 AC4: a HELD row never uses the one attempt of this pass; try the next eligible row
    log "EARLY-RELEASE-TRY run=$r paused_at=$p clear_passes=$EARLY_N cause=\"${cause:0:80}\""
    release_run "$r" "$p" "${x:-0}" 1; return $?
  done <<< "$2"
  return 1; }
ledger_pass(){ # W2, throttled to PAUSE_PASS_S. (a) stale drop (b) adopt unledgered + one bell (c) at most ONE expired release, oldest first (d) refusal -> extend/overdue. Always ends with status.json.
  local now r p e d x q pa n ids rel=0 row rows k; now=$(now_s)
  [ $((now - LP_LAST)) -ge "$PAUSE_PASS_S" ] || return 0; LP_LAST=$now
  if expired; then k=$(grep -c . "$LEDGER" 2>/dev/null); [ "${k:-0}" -le 0 ] || log "RB-BELL WP-DISARMED-LEDGER-NONEMPTY n=$k"; status_write; return 0; fi   # RWH3 E2: a disarmed gate with paused rows left in the ledger rings once per ledger pass
  if [ -s "$LEDGER" ]; then  # (a) the daemon is the source of truth: a ledger row whose run is ended / not paused / paused at another time is dropped; an empty read is unknown and keeps the row
    while IFS=$'\t' read -r r p e d x; do [ -n "$r" ] || continue
      q=$(sqlite3 -readonly -separator '|' "$DB" "select ended is null, coalesce(paused_at,'') from runs where id=$r" 2>/dev/null); [ -n "$q" ] || continue
      if [ "${q%%|*}" != 1 ] || [ "${q#*|}" != "$p" ]; then log "LEDGER-STALE run=$r ledger_paused_at=$p daemon=[${q}]; row dropped, NO redrive"; ledger_drop "$r" "$p"; fi
    done < "$LEDGER"
  fi
  rows=$(sqlite3 -readonly -separator $'\t' "$DB" "select id, paused_at from runs where ended is null and paused_at is not null order by id" 2>/dev/null)  # (b)
  while IFS=$'\t' read -r r pa; do [ -n "$r" ] || continue
    [ -n "$(awk -F'\t' -v r="$r" -v p="$pa" '$1==r && $2==p' "$LEDGER" 2>/dev/null)" ] && continue
    n=$(epoch_of "$pa"); case "$n" in ''|*[!0-9]*) log "LEDGER-ADOPT run=$r paused_at=$pa unparsable, skipped"; continue;; esac
    e=$(iso_at $((n + PAUSE_MIN*60))); ledger_add "$r" "$pa" "$e" "unledgered" 0; log "RB-BELL PAUSE-UNLEDGERED run=$r paused_at=$pa adopted expires=$e (a CTRL or hand pause with no ledger row)"
  done <<< "$rows"
  if early_clear; then EARLY_N=$((EARLY_N + 1)); else EARLY_N=0; fi   # W4: consecutive clear ledger passes (mem + io)
  CGDONE=0; CGRC=0  # (c) expired rows, oldest first; a run owned by the T4R recovery watch is left to it
  ids=$(awk -F'\t' '{print $3 "\t" $1 "\t" $2 "\t" $5}' "$LEDGER" 2>/dev/null | sort)
  while IFS=$'\t' read -r e r p x; do [ -n "$r" ] || continue
    n=$(epoch_of "$e"); case "$n" in ''|*[!0-9]*) continue;; esac; [ "$n" -le "$now" ] || continue
    [ "$r" != "$T4R_RUN" ] || continue
    log "LEDGER-EXPIRED run=$r paused_at=$p expires=$e extensions=${x:-0}"
    if release_run "$r" "$p" "${x:-0}"; then rel=$((rel+1)); break; fi
  done <<< "$ids"
  if [ "$rel" = 0 ] && [ "$EARLY_N" -ge 2 ]; then early_release "$now" "$(awk -F'\t' '{print $3 "\t" $1 "\t" $2 "\t" $4 "\t" $5}' "$LEDGER" 2>/dev/null | sort)"; fi   # W4/G4: ONE release per pass in total
  status_write; }
revert(){ gb=$(target); log "RB-BELL REPRICE-REVERSE $1 -> apply inner=$gb (max priced + 3 G)"
  if wp_gate && wp_emit_write limit redbaron:inner-cap "reprice inner cap -> $gb (max priced + 3 G)" "$1" "reprice-inner-cap.sh --apply <previous cap>"; then  # RWH3 gate
    bash "$REPRICE" --apply "$gb" --by "rb-reprice-watch 10-20 (Fable SET-10.5 reverse = max priced + 3 G): $1" >> "$LOG" 2>&1; log "reprice rc=$?"
  else log "WP-DISARMED reprice --apply $gb NOT run (${WP_VERDICT:-no-lib}${WP_DEFECT:+ defect=$WP_DEFECT})"; fi; }
t2_fire(){ # $1 = live_inners output. T2 (MemAvailable/PSI with 2 inners live). Returns 0 when it fired. Refuses while a recovery watch is armed (one arm, one state file).
  local young av psi why
  [ -z "$T4R_RUN" ] || return 1  # ARMED2
  [ "$(nlive "$1")" -ge 2 ] || return 1
  load_conf; av=$(awk '/^MemAvailable:/{print $2}' "$MEMINFO")
  psi=$(awk '/^full/{sub("avg60=","",$3); print $3}' "$MEM_PSI"); why=$(mem_bad "$av" "$psi")
  [ -n "$why" ] || return 1
  young=$(echo "$1" | tail -1); t4r_cost "$young"
  log "RB-BELL REPRICE-PAUSE younger inner $young ($why) pause_cost_coder_min=$T4R_COST $T4R_LAST"
  wpause "$young" "T2 10-20: $why with 2 inners at inner cap 10.5 (Fable SET-10.5 reverse); release = wm-build run redrive $young --from inner"
  t4r_arm "$young" T2; runs_to_1 "T2 $why"; revert "T2 $why live=[$(echo $1)]"; return 0; }  # arm BEFORE runs_to_1 (it reads the live max_runs); no exit: the T4R recovery stage follows
t4_fire(){ # $1 = live_inners output. T4 (IO pressure with 2 inners live, no hand cargo). Returns 0 when it fired. Caller ran load_conf. Refuses while a recovery watch is armed.
  local young
  [ -z "$T4R_RUN" ] || return 1  # ARMED4
  t4_eval "$(nlive "$1")" || return 1
  young=$(echo "$1" | tail -1); t4r_cost "$young"
  log "RB-BELL REPRICE-PAUSE younger inner $young ($T4_WHY) pause_cost_coder_min=$T4R_COST $T4R_LAST"
  wpause "$young" "T4 10-22: io_full_avg60=$(awk '/^full/{sub("avg60=","",$3); print $3}' "$IO_PSI")>$IO_FULL_AVG60_MAX for the 5-min window ($T4_N passes) with 2 inners live and no hand cargo scope; release = wm-build run redrive $young --from inner"
  t4r_arm "$young" T4; runs_to_1 "$T4_WHY"; return 0; }   # arm (and persist) right after the pause so a crash between the two steps cannot lose the paused run
t4_selftest(){ # hermetic: fake io pressure, app.slice and /proc under a mktemp -d; prints a short ok string or SELFTEST FAIL T4 <case>
  local t need i; t=$(mktemp -d) && [ -d "$t" ] || { echo "SELFTEST FAIL T4 mktemp"; return 1; }
  IO_PSI=$t/io; APP_SLICE=$t/app; PROC=$t/proc; IO_FULL_AVG60_MAX=10; mkdir -p "$APP_SLICE" "$PROC/501" "$PROC/502"
  io(){ printf 'some avg10=1.00 avg60=%s avg300=1.00 total=1\nfull avg10=1.00 avg60=%s avg300=1.00 total=1\n' "$1" "$1" > "$IO_PSI"; }
  need=$(t4_need); [ "$need" = 15 ] && [ "$(t4_need 30)" = 10 ] && [ "$(t4_need 7)" = 43 ] || { echo "SELFTEST FAIL T4 need=$need"; rm -rf "$t"; return 1; }
  echo cargo > "$PROC/501/comm"; echo rustc > "$PROC/502/comm"
  # S4: no hand scope -> exactly 0
  [ "$(hand_scopes)" = 0 ] || { echo "SELFTEST FAIL T4 S4 hand=[$(hand_scopes)]"; rm -rf "$t"; return 1; }
  # S1: avg60 12 for need-1 passes -> no fire; one more -> fire; a pass at the threshold (10) resets the count
  io 12; T4_N=0; for ((i=1;i<need;i++)); do t4_eval 2 && { echo "SELFTEST FAIL T4 S1 early fire pass=$i"; rm -rf "$t"; return 1; }; done
  t4_eval 2 && [ -n "$T4_WHY" ] || { echo "SELFTEST FAIL T4 S1 no fire at pass=$need"; rm -rf "$t"; return 1; }
  T4_N=0; for ((i=1;i<need;i++)); do t4_eval 2; done; io 10; t4_eval 2 && { echo "SELFTEST FAIL T4 S1 fired at threshold"; rm -rf "$t"; return 1; }
  io 12; t4_eval 2 && { echo "SELFTEST FAIL T4 S1 reset not honoured (N=$T4_N)"; rm -rf "$t"; return 1; }
  # S2: a hand scope whose process comm is rustc -> no fire even after the full window
  mkdir -p "$APP_SLICE/run-r1.scope"; echo 502 > "$APP_SLICE/run-r1.scope/cgroup.procs"
  [ "$(hand_scopes)" = 1 ] || { echo "SELFTEST FAIL T4 S2 hand=[$(hand_scopes)]"; rm -rf "$t"; return 1; }
  T4_N=0; for ((i=1;i<=need+2;i++)); do t4_eval 2 && { echo "SELFTEST FAIL T4 S2 fired with a hand rustc pass=$i"; rm -rf "$t"; return 1; }; done
  # S3: scope whose only process is bash with "rustc" in its cmdline -> NOT a hand job (self-match regression), fire allowed
  echo bash > "$PROC/502/comm"; printf 'bash\0-c\0rustc --edition 2021\0' > "$PROC/502/cmdline"
  [ "$(hand_scopes)" = 0 ] || { echo "SELFTEST FAIL T4 S3 self-match hand=[$(hand_scopes)]"; rm -rf "$t"; return 1; }
  T4_N=0; for ((i=1;i<need;i++)); do t4_eval 2; done; t4_eval 2 || { echo "SELFTEST FAIL T4 S3 no fire with only a bash/cmdline-rustc scope"; rm -rf "$t"; return 1; }
  # S5: one inner live -> never fires, and the count resets
  T4_N=0; for ((i=1;i<need;i++)); do t4_eval 2; done; t4_eval 1 && { echo "SELFTEST FAIL T4 S5 fired with 1 inner"; rm -rf "$t"; return 1; }
  [ "$T4_N" = 0 ] || { echo "SELFTEST FAIL T4 S5 count not reset (N=$T4_N)"; rm -rf "$t"; return 1; }
  # S6: EXPIRES gate lives in the shared lib: the ONE date is 2026-11-21 (end of that day), an EXPIRES in the past disarms (expired), one in the future stays armed
  [ "$EXPIRES" = 2026-11-21 ] || { echo "SELFTEST FAIL T4 S6 EXPIRES=$EXPIRES, not the single 2026-11-21"; rm -rf "$t"; return 1; }
  sim_expire; expired && [ "$WP_DEFECT" = expired ] || { echo "SELFTEST FAIL T4 S6 not expired after EXPIRES (defect=${WP_DEFECT:-})"; rm -rf "$t"; return 1; }
  rw_arm "$RWT/premise.toml" "$(date -d '+1 hour' '+%F %T')"; expired && { echo "SELFTEST FAIL T4 S6 expired before EXPIRES"; rm -rf "$t"; return 1; }; sim_arm
  rm -rf "$t"; echo "T4 S1-S6 ok need=$need"; }
t4r_selftest(){ # hermetic: fake state.db, wt, io/mem pressure, config, clock and fake wm-build / limits-guard / wip-redrive under a mktemp -d; prints a short ok string or SELFTEST FAIL T4R <case>
  local t need i CT NOW0 CALLS L2=$'6\n7'; t=$(mktemp -d) && [ -d "$t" ] || { echo "SELFTEST FAIL T4R mktemp"; return 1; }
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null; CALLS=$t/calls; export FAKE_CALLS=$CALLS
  LOG=$t/log; DB=$t/s.db; IO_PSI=$t/io; MEM_PSI=$t/mpsi; MEMINFO=$t/meminfo; WT_ROOT=$t/wt; CONFIG=$t/config.toml; WIP_REDRIVE=$t/wip.sh; ENVF=$t/env
  CONF=$t/conf; REPRICE=$t/bin/reprice.sh; APP_SLICE=$t/app; PROC=$t/proc; T4_WINDOW=300; SLEEP=20; mkdir -p "$APP_SLICE" "$PROC"   # R14-R18 fire the real t2_fire/t4_fire against fakes
  JOURNAL=$t/journal.jsonl; : > "$JOURNAL"; LEDGER=$t/ledger.tsv; LEDGER_LOCK=$LEDGER.lock; DEFERLOG=$t/defer.tsv; STATUS=$t/sw/status.json   # W: the pause ledger / defer log / status.json stay under $t too
  T4R_STATE=$t/t4r.state; HELD_REC=$t/held.tsv; PATH=$t/bin:$PATH; IO_RECOVER_AVG60_MAX=5; T4R_WINDOW=600; MEM_AVAIL_MIN_KB=12582912; PSI_FULL_AVG60_MAX=10; CT=1700000000; NOW0=$((CT + 37*60 + 30))
  log(){ echo "$*" >> "$LOG"; }   # no tee: the real log must never be touched by the selftest
  mkdir -p "$t/bin" "$t/wt"; local b
  for b in wm-build wm-build-limits-guard; do printf '#!/bin/bash\necho "%s $*" >> "$FAKE_CALLS"\n' "$b" > "$t/bin/$b"; chmod +x "$t/bin/$b"; done
  export FAKE_RCS=$t/rcs   # one rc per line, popped per `wm-build run redrive` call (empty/absent = 0)
  cat > "$t/bin/wm-build" <<'FAKEWB'
#!/bin/bash
echo "wm-build $*" >> "$FAKE_CALLS"
if [ "$1 $2" = "run redrive" ] && [ -s "$FAKE_RCS" ]; then r=$(head -n 1 "$FAKE_RCS"); sed -i 1d "$FAKE_RCS"; exit "$r"; fi
[ "$1 $2" = "run redrive" ] && sqlite3 "$FAKE_DB" "update runs set paused_at=NULL where id=$3"   # a successful redrive un-pauses the row (round 6: the watcher now checks)
exit 0
FAKEWB
  chmod +x "$t/bin/wm-build"
  printf '#!/bin/bash\necho "reprice $*" >> "$FAKE_CALLS"\n' > "$REPRICE"
  export FAKE_DB=$DB FAKE_WIPSTILL=$t/wipstill   # FAKE_WIPSTILL = how many more wip calls exit 0 but leave the row paused
  cat > "$WIP_REDRIVE" <<'FAKEWIP'
#!/bin/bash
echo "wip $*" >> "$FAKE_CALLS"
n=$(cat "$FAKE_WIPSTILL" 2>/dev/null || echo 0)
if [ "$n" -gt 0 ]; then echo $((n-1)) > "$FAKE_WIPSTILL"; else sqlite3 "$FAKE_DB" "update runs set paused_at=NULL where id=$1"; fi
echo "after: fake"
FAKEWIP
  echo ': fake fleet token env' > "$ENVF"
  io(){ printf 'some avg10=1.00 avg60=%s avg300=1.00 total=1\nfull avg10=1.00 avg60=%s avg300=1.00 total=1\n' "$1" "$1" > "$IO_PSI"; }
  mem(){ printf 'MemTotal: 65000000 kB\nMemAvailable: %s kB\n' "$1" > "$MEMINFO"; printf 'some avg10=0.00 avg60=0.10 avg300=0.00 total=1\nfull avg10=0.00 avg60=0.10 avg300=0.00 total=1\n' > "$MEM_PSI"; }
  passes(){ local k; for ((k=0;k<$1;k++)); do t4r_step; done; }
  cnt(){ grep -c -- "$1" "$CALLS" 2>/dev/null || true; }
  fail(){ echo "SELFTEST FAIL T4R $*"; rm -rf "$t"; }
  SIGTAIL=$'\n[cargo_jobs]\nmem_budget_gb = 26  # y\n\n[cargo_jobs.mem_caps_gb]\ninner = 11.5\ngate = 13\nland = 12.5\nhand = 9\n'   # round 7: the MG gate reads the budget + class caps from the config; a config without them REFUSES
  cfg(){ printf '[daemon]\nmax_runs = %s  # limits.lock\n\n[cargo_jobs]\nmem_budget_gb = 26  # y\n\n[cargo_jobs.mem_caps_gb.wm-build]\ninner = 99\n\n[cargo_jobs.mem_caps_gb]\nland = 12.5\ninner = 11.5  # x\ngate = 13\nhand = 9\n' "$1" > "$CONFIG"; }   # the wm-build sub-table inner (listed first) is a decoy: the cap read is section-scoped
  fresh0(){ : > "$CALLS"; : > "$LOG"; rm -rf "$t/wt/s1"; git init -q "$t/wt/s1" 2>/dev/null
    GIT_AUTHOR_DATE="$CT +0000" GIT_COMMITTER_DATE="$CT +0000" git -C "$t/wt/s1" -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -q --allow-empty -m c1
    rm -f "$t/s.db"; sqlite3 "$t/s.db" "create table runs(id INTEGER PRIMARY KEY AUTOINCREMENT, slug TEXT NOT NULL, ended TEXT, stage TEXT, paused_at TEXT); insert into runs(id,slug,ended,stage,paused_at) values (7,'s1',NULL,'inner','2026-10-22 13:00:00'); create table circuits(class text primary key, state text, resets_at text); insert into circuits values('quota','closed',null); create table alarms(id integer primary key, ref_ text, closed text); create table steps(id INTEGER PRIMARY KEY, kind TEXT, priced_peak_kb INTEGER); insert into steps(kind,priced_peak_kb) values ('inner',8388608),('inner',4194304),('gate',99999999)"
    cfg "${ARM_MR:-2}"; io 3; mem 30000000; RW_NOW=$NOW0; sim_arm; SELF_NLIVE=1; load_conf
    if [ -n "${ARM_DEW:-}" ]; then RW_DAEMON_ENTER=$((NOW0-ARM_DEW)); else RW_DAEMON_ENTER=unknown; fi
    rm -f -- "$T4R_STATE" "$FAKE_RCS" "$FAKE_WIPSTILL"; T4R_EMPTYN=(); T4R_SATT=0; T4R_SOK=; DB=$t/s.db; T4R_ATT=0; T4R_HOLD=0; T4R_HRSEEN=; T4R_SATT=0; T4R_SOK=; T4R_RUN=; T4R_FROM=; T4R_N=0; T4R_STUCK=0; T4R_EXPLOG=; T4R_CAUSE=T4; T4R_RESTART=unknown; T4R_COST=unknown; T4R_LAST=; T4_N=0; }
  fresh(){ fresh0; t4r_cost 7; t4r_arm 7 "${ARM_CAUSE:-T4}"; cfg 1; }   # arm reads max_runs BEFORE the pause lowers it; then runs_to_1 is done: live config reads 1
  nth(){ sed -n "$1p" "$CALLS"; }
  case "$LOG$T4R_STATE" in "$t"/*"$t"/*) ;; *) fail "hermetic LOG=$LOG STATE=$T4R_STATE"; return 1;; esac
  need=$(t4r_need); [ "$need" = 30 ] || { fail "need=$need"; return 1; }
  # R1: paused inner row + clean wt (one commit 37 min ago); recovered for need passes -> one set max_runs=2, one enforce, one redrive --from inner, cost 37
  fresh; passes $((need-1)); [ ! -s "$CALLS" ] || { fail "R1 early fire"; return 1; }
  [ "$(git -C "$t/wt/s1" status --porcelain | wc -l)" = 0 ] || { fail "R1 wt not clean"; return 1; }
  grep -qx 'lowered_from=2' "$T4R_STATE" && ! grep -q '^t4_lowered_from' "$T4R_STATE" && grep -qx 't4r_cause=T4' "$T4R_STATE" && [ "$T4R_FROM" = 2 ] || { fail "R1 pause did not record lowered_from=2 state=[$(tr '\n' '|' < "$T4R_STATE")]"; return 1; }
  t4r_step
  [ "$(cnt '^wm-build-limits-guard set max_runs=2 ')" = 1 ] && [ "$(cnt '^wm-build-limits-guard enforce$')" = 1 ] && [ "$(cnt '^wm-build run redrive 7 --from inner$')" = 1 ] \
    && [ "$(wc -l < "$CALLS")" = 3 ] && [ "$(cnt '^wip ')" = 0 ] || { fail "R1 calls=[$(tr '\n' '|' < "$CALLS")]"; return 1; }
  grep -q 'RB-BELL REPRICE-RECOVER run=7 paused_min=0 pause_cost_coder_min=37 max_runs=2(set rc=0 enforce rc=0 t4_lowered_from=2) redrive_rc=0 t4_lowered_from=2' "$LOG" \
    && grep -q 'T4R armed T4R_RUN=7 T4R_PAUSED_AT=' "$LOG" && [ -z "$T4R_RUN" ] && [ "$T4_N" = 0 ] || { fail "R1 bell/clear log=[$(tail -n 5 "$LOG" | tr '\n' '|')]"; return 1; }
  # R2: one pass above IO_RECOVER_AVG60_MAX at need-1 resets the count -> no fire at need
  fresh; passes $((need-1)); io 8; t4r_step; io 3; t4r_step
  [ ! -s "$CALLS" ] && [ "$T4R_N" = 1 ] || { fail "R2 reset not honoured N=$T4R_N calls=[$(tr '\n' '|' < "$CALLS")]"; return 1; }
  # R3: the row was redriven by someone else (paused_at NULL) -> no redrive call, skip line logged
  fresh; sqlite3 "$DB" "update runs set paused_at=NULL where id=7"; t4r_fire   # the fire-level re-read (R16 clears the state earlier on the per-pass path)
  [ "$(cnt "run redrive")" = 0 ] && [ "$(cnt "^wm-build-limits-guard")" = 0 ] && [ "$(cnt "^wip ")" = 0 ] && grep -q "T4R skip-redrive run=7 (not paused" "$LOG" || { fail "R3 calls=[$(tr '\n' '|' < "$CALLS")]"; return 1; }
  # R4: config max_runs = 3 -> no set / enforce, the "left" line is logged, the redrive still happens
  fresh; printf '[daemon]\nmax_runs = 3  # limits.lock\n%s' "$SIGTAIL" > "$CONFIG"; passes "$need"
  [ "$(cnt '^wm-build-limits-guard')" = 0 ] && [ "$(cnt '^wm-build run redrive 7 --from inner$')" = 1 ] && grep -q 'T4R max_runs=3 left (t4_lowered_from=2)' "$LOG" \
    && grep -q 'max_runs=left(3 t4_lowered_from=2) redrive_rc=0 t4_lowered_from=2' "$LOG" || { fail "R4 calls=[$(tr '\n' '|' < "$CALLS")]"; return 1; }
  # R5: dirty wt -> the wip-redrive fake is called, not run redrive
  fresh; echo wip > "$t/wt/s1/dirty.txt"; passes "$need"
  [ "$(cnt '^wip 7$')" = 1 ] && [ "$(cnt 'run redrive')" = 0 ] || { fail "R5 calls=[$(tr '\n' '|' < "$CALLS")]"; return 1; }
  # R6: expired (lib EXPIRES in the past) -> zero fake calls
  fresh; sim_expire; passes $((need+2))
  [ ! -s "$CALLS" ] && grep -q 'T4R disarmed (expired)' "$LOG" || { fail "R6 calls=[$(tr '\n' '|' < "$CALLS")]"; return 1; }
  # R7: mem_bad true on one pass inside the window -> the count resets, no fire after need passes
  fresh; passes 9; mem 1000000; t4r_step; mem 30000000; passes $((need-10))
  [ ! -s "$CALLS" ] || { fail "R7 fired with mem_bad in the window N=$T4R_N"; return 1; }
  # R8: the stuck bell fires once at 2 h (fake clock) and not twice
  fresh; io 8; RW_NOW=$((NOW0+7199)); t4r_step; [ "$(grep -c 'REPRICE-RECOVER-STUCK' "$LOG")" = 0 ] || { fail "R8 early stuck"; return 1; }
  RW_NOW=$((NOW0+7200)); t4r_step; RW_NOW=$((NOW0+7500)); t4r_step; t4r_step
  [ "$(grep -c 'RB-BELL REPRICE-RECOVER-STUCK run=7 paused_min=120 io_full_avg60=8' "$LOG")" = 1 ] && [ "$(grep -c 'REPRICE-RECOVER-STUCK' "$LOG")" = 1 ] && [ ! -s "$CALLS" ] || { fail "R8 stuck lines=$(grep -c 'REPRICE-RECOVER-STUCK' "$LOG")"; return 1; }
  # R9: pause (arm persists the state), then a simulated restart (a fresh process: every T4R var reset, only the state file survives), then recovery passes -> exactly one set, one enforce, one redrive
  fresh; [ -s "$T4R_STATE" ] || { fail "R9 no state file written at the pause"; return 1; }
  T4R_RUN=; T4R_FROM=; T4R_PAUSED_AT=; T4R_COST=unknown; T4R_LAST=; T4R_STUCK=0; T4R_N=0; T4R_EXPLOG=; RW_NOW=$((NOW0+60)); t4r_load
  [ "$T4R_FROM" = 2 ] && [ "$T4R_RUN" = 7 ] && [ "$T4R_PAUSED_AT" = "$NOW0" ] && [ "$T4R_COST" = 37 ] && [ "$T4R_N" = 0 ] || { fail "R9 load run=[$T4R_RUN] at=[$T4R_PAUSED_AT] cost=[$T4R_COST]"; return 1; }
  passes $((need-1)); [ ! -s "$CALLS" ] || { fail "R9 early fire after load (window must be re-earned)"; return 1; }
  t4r_step
  [ "$(cnt '^wm-build-limits-guard set max_runs=2 ')" = 1 ] && [ "$(cnt '^wm-build-limits-guard enforce$')" = 1 ] && [ "$(cnt '^wm-build run redrive 7 --from inner$')" = 1 ] \
    && [ "$(wc -l < "$CALLS")" = 3 ] && grep -q 'RB-BELL REPRICE-RECOVER run=7 paused_min=1 pause_cost_coder_min=37 max_runs=2' "$LOG" && [ ! -e "$T4R_STATE" ] \
    || { fail "R9 calls=[$(tr '\n' '|' < "$CALLS")] state_left=$([ -e "$T4R_STATE" ] && echo yes || echo no)"; return 1; }
  # R10: (a) skip (the run row ended) -> zero limits-guard calls, zero redrive calls, the "left (redrive skipped" line is logged
  fresh; sqlite3 "$DB" "update runs set ended='2026-10-22 13:30:00' where id=7"; passes "$need"
  [ ! -s "$CALLS" ] && grep -q 'T4R max_runs=1 left (redrive skipped: run ended; t4_lowered_from=2)' "$LOG" && grep -q 'redrive_rc=skipped(run ended)' "$LOG" && [ ! -e "$T4R_STATE" ] \
    || { fail "R10 calls=[$(tr '\n' '|' < "$CALLS")] log=[$(tail -n 3 "$LOG" | tr '\n' '|')]"; return 1; }
  # R11: a stale state file (row no longer paused) is deleted at load, no writes, no recovery watch
  fresh; sqlite3 "$DB" "update runs set ended='2026-10-22 13:30:00' where id=7"   # round 5: a hand-redriven (paused_at NULL) run is no longer stale at load, see R21; stale = ended
  T4R_RUN=; T4R_PAUSED_AT=; T4R_COST=unknown; T4R_LAST=; T4R_STUCK=0; T4R_N=0; t4r_load
  [ ! -e "$T4R_STATE" ] && [ -z "$T4R_RUN" ] && [ ! -s "$CALLS" ] && grep -q 'T4R state stale run=7' "$LOG" || { fail "R11 state_left=$([ -e "$T4R_STATE" ] && echo yes || echo no) run=[$T4R_RUN] calls=[$(tr '\n' '|' < "$CALLS")]"; return 1; }
  fresh0; t4r_load; [ -z "$T4R_RUN" ] && [ ! -s "$CALLS" ] && ! grep -q 'T4R state' "$LOG" || { fail "R11 absent state file was not a silent no-op log=[$(tr '\n' '|' < "$LOG")]"; return 1; }   # LOADGUARD
  # R12: a state file WITHOUT t4_lowered_from (a manual hold at 1, T4 lowered nothing) -> zero limits-guard calls (no set, no enforce), the redrive still happens; also an arm with live max_runs 1 persists an empty key
  fresh; grep -v '^lowered_from=' "$T4R_STATE" > "$T4R_STATE.x" && mv -f -- "$T4R_STATE.x" "$T4R_STATE"
  T4R_RUN=; T4R_FROM=; T4R_PAUSED_AT=; T4R_COST=unknown; T4R_LAST=; T4R_STUCK=0; T4R_N=0; T4R_EXPLOG=; t4r_load; passes "$need"
  [ "$(cnt '^wm-build-limits-guard')" = 0 ] && [ "$(cnt '^wm-build run redrive 7 --from inner$')" = 1 ] && grep -q 'T4R max_runs=1 left (t4_lowered_from=none)' "$LOG" \
    && grep -q 'redrive_rc=0 t4_lowered_from=none' "$LOG" || { fail "R12 calls=[$(tr '\n' '|' < "$CALLS")]"; return 1; }
  ARM_MR=1 fresh; grep -qx 'lowered_from=' "$T4R_STATE" && [ -z "$T4R_FROM" ] && passes "$need"
  [ "$(cnt '^wm-build-limits-guard')" = 0 ] && [ "$(cnt '^wm-build run redrive 7 --from inner$')" = 1 ] || { fail "R12 arm-at-1 state=[$(tr '\n' '|' < "$T4R_STATE" 2>/dev/null)] calls=[$(tr '\n' '|' < "$CALLS")]"; return 1; }
  # R13: T4 lowered 3 -> 1 (arm records 3), live still 1 -> the restore is EXACTLY set max_runs=3 (never a hardcoded 2), one enforce, one redrive
  ARM_MR=3 fresh; grep -qx 'lowered_from=3' "$T4R_STATE" && [ "$T4R_FROM" = 3 ] || { fail "R13 arm did not record 3"; return 1; }
  passes "$need"
  [ "$(cnt '^wm-build-limits-guard set max_runs=3 ')" = 1 ] && [ "$(cnt '^wm-build-limits-guard set ')" = 1 ] && [ "$(cnt '^wm-build-limits-guard enforce$')" = 1 ] && [ "$(cnt '^wm-build run redrive 7 --from inner$')" = 1 ] \
    && grep -q 'T4R max_runs->3 set rc=0 t4_lowered_from=3' "$LOG" || { fail "R13 calls=[$(tr '\n' '|' < "$CALLS")]"; return 1; }
  # R14: T2 fires (mem) -> state t4r_cause=T2, lowered_from=2; IO ok but mem below the T2 gate (12 + peak 8 - 0 live caps = 20 GiB) -> no fire; above the gate for the whole window -> set max_runs=2 + enforce + one redrive
  fresh0; mem 5000000; t2_fire "$L2" || { fail "R14 T2 did not fire"; return 1; }
  [ "$(cnt '^wm-build run pause 7 ')" = 1 ] && [ "$(cnt '^wm-build-limits-guard set max_runs=1 ')" = 1 ] && [ "$(cnt '^reprice --apply 11.0 ')" = 1 ] && [ "$T4R_RUN" = 7 ] && [ "$T4R_CAUSE" = T2 ] \
    && grep -qx 'lowered_from=2' "$T4R_STATE" && grep -qx 't4r_cause=T2' "$T4R_STATE" && grep -qx 'daemon_restart_within=unknown' "$T4R_STATE" && ! grep -q '^t4_lowered_from' "$T4R_STATE" \
    && [ "$(grep -n 'T4R armed' "$LOG" | head -1 | cut -d: -f1)" -lt "$(grep -n 'max_runs->1 set' "$LOG" | head -1 | cut -d: -f1)" ] \
    || { fail "R14 fire calls=[$(tr '\n' '|' < "$CALLS")] state=[$(tr '\n' '|' < "$T4R_STATE")]"; return 1; }
  [ "$(inner_cap_gib)" = 11.5 ] && [ "$(inner_peak_gib)" = 8.0 ] || { fail "R14 cap=[$(inner_cap_gib)] peak=[$(inner_peak_gib)]"; return 1; }
  t2_mem_gate 9000000 1 && ! t2_mem_gate 8800000 1 && ! t2_mem_gate 19922944 0 && t2_mem_gate 22000000 0 || { fail "R14 gate arithmetic (12 + 8 - n x 11.5 GiB)"; return 1; }
  cfg 1; : > "$CALLS"; io 3; mem 19922944; passes_n(){ local k; for ((k=0;k<$1;k++)); do t4r_step 0; done; }
  passes_n $((need+5)); [ ! -s "$CALLS" ] && [ "$T4R_N" = 0 ] || { fail "R14 fired below the T2 mem gate N=$T4R_N calls=[$(tr '\n' '|' < "$CALLS")]"; return 1; }
  mem 22000000; passes_n $((need-1)); mem 19922944; passes_n 1; mem 22000000; passes_n $((need-1))
  [ ! -s "$CALLS" ] || { fail "R14 a failing gate pass did not reset the window N=$T4R_N"; return 1; }
  t4r_step 0
  [ "$(wc -l < "$CALLS")" = 3 ] && nth 1 | grep -q '^wm-build-limits-guard set max_runs=2 ' && [ "$(nth 2)" = "wm-build-limits-guard enforce" ] && [ "$(nth 3)" = "wm-build run redrive 7 --from inner" ] && [ ! -e "$T4R_STATE" ] \
    || { fail "R14 recovery calls=[$(tr '\n' '|' < "$CALLS")]"; return 1; }
  # R15: one arm, one state file. (1) T2 armed, then T4 conditions for 17 passes -> no second pause/arm; (2) T4 armed, then T2 conditions -> no second pause/arm (positive controls: each first fire does happen)
  fresh0; mem 5000000; t2_fire "$L2" || { fail "R15.1 T2 did not arm"; return 1; }
  io 12; mem 30000000; for ((i=1;i<=need+2 && i<=17;i++)); do t4_fire "$L2" && { fail "R15.1 T4 fired a second pause at pass $i"; return 1; }; done
  [ "$(cnt '^wm-build run pause ')" = 1 ] && [ "$(grep -c 'T4R armed' "$LOG")" = 1 ] && grep -qx 't4r_cause=T2' "$T4R_STATE" || { fail "R15.1 calls=[$(tr '\n' '|' < "$CALLS")]"; return 1; }
  fresh0; io 12; for ((i=1;i<15;i++)); do t4_fire "$L2" && { fail "R15.2 T4 early fire pass=$i"; return 1; }; done
  t4_fire "$L2" || { fail "R15.2 T4 did not arm at pass 15"; return 1; }
  mem 5000000; t2_fire "$L2" && { fail "R15.2 T2 fired a second pause"; return 1; }
  [ "$(cnt '^wm-build run pause ')" = 1 ] && [ "$(grep -c 'T4R armed' "$LOG")" = 1 ] && grep -qx 't4r_cause=T4' "$T4R_STATE" && [ "$(cnt '^reprice ')" = 0 ] || { fail "R15.2 calls=[$(tr '\n' '|' < "$CALLS")]"; return 1; }
  # R16: the row is open but no longer paused (the seat redrove by hand) -> state cleared, set max_runs=2 + enforce (in that order), ZERO redrive calls; the round-3 rule still gates the restore
  fresh; sqlite3 "$DB" "update runs set paused_at=NULL where id=7"; passes $((need-1)); [ ! -s "$CALLS" ] || { fail "R16 restored before the io window"; return 1; }; t4r_step 1   # round 5: the restore waits for the window (need recovered passes)
  [ "$(wc -l < "$CALLS")" = 2 ] && nth 1 | grep -q '^wm-build-limits-guard set max_runs=2 ' && [ "$(nth 2)" = "wm-build-limits-guard enforce" ] && [ "$(cnt 'redrive')" = 0 ] && [ "$(cnt '^wip ')" = 0 ] \
    && [ ! -e "$T4R_STATE" ] && [ -z "$T4R_RUN" ] && grep -q 'T4R seat-redrove run=7' "$LOG" && grep -q 'redrive_rc=skipped(seat redrove by hand)' "$LOG" || { fail "R16 calls=[$(tr '\n' '|' < "$CALLS")] state_left=$([ -e "$T4R_STATE" ] && echo yes || echo no)"; return 1; }
  fresh; printf '[daemon]\nmax_runs = 2  # limits.lock\n%s' "$SIGTAIL" > "$CONFIG"; sqlite3 "$DB" "update runs set paused_at=NULL where id=7"; passes "$need"
  [ ! -s "$CALLS" ] && [ ! -e "$T4R_STATE" ] || { fail "R16 live!=1 restored calls=[$(tr '\n' '|' < "$CALLS")]"; return 1; }
  ARM_MR=1 fresh; sqlite3 "$DB" "update runs set paused_at=NULL where id=7"; passes "$need"
  [ ! -s "$CALLS" ] && [ ! -e "$T4R_STATE" ] || { fail "R16 lowered_from empty restored calls=[$(tr '\n' '|' < "$CALLS")]"; return 1; }
  # R17: a T2 arm within 300 s of a daemon restart (daemon_restart_within=60) -> STUCK bell at 30 min, once; 301 s or a T4 arm keeps 2 h; 300 s is inside the rule
  ARM_CAUSE=T2 ARM_DEW=60 fresh; grep -qx 'daemon_restart_within=60' "$T4R_STATE" && grep -qx 't4r_cause=T2' "$T4R_STATE" || { fail "R17 state=[$(tr '\n' '|' < "$T4R_STATE")]"; return 1; }
  io 8; RW_NOW=$((NOW0+1799)); t4r_step 0; [ "$(grep -c 'REPRICE-RECOVER-STUCK' "$LOG")" = 0 ] || { fail "R17 stuck before 30 min"; return 1; }
  RW_NOW=$((NOW0+1800)); t4r_step 0; RW_NOW=$((NOW0+1900)); t4r_step 0; t4r_step 0
  [ "$(grep -c 'RB-BELL REPRICE-RECOVER-STUCK run=7 paused_min=30 ' "$LOG")" = 1 ] && [ "$(grep -c 'REPRICE-RECOVER-STUCK' "$LOG")" = 1 ] && [ ! -s "$CALLS" ] || { fail "R17 stuck lines=$(grep -c 'REPRICE-RECOVER-STUCK' "$LOG")"; return 1; }
  ARM_CAUSE=T2 ARM_DEW=301 fresh; io 8; RW_NOW=$((NOW0+1800)); t4r_step 0; [ "$(grep -c 'REPRICE-RECOVER-STUCK' "$LOG")" = 0 ] || { fail "R17 within=301 stuck at 30 min"; return 1; }
  RW_NOW=$((NOW0+7200)); t4r_step 0; [ "$(grep -c 'REPRICE-RECOVER-STUCK' "$LOG")" = 1 ] || { fail "R17 within=301 no stuck at 2 h"; return 1; }
  ARM_CAUSE=T4 ARM_DEW=60 fresh; io 8; RW_NOW=$((NOW0+1800)); t4r_step 0; [ "$(grep -c 'REPRICE-RECOVER-STUCK' "$LOG")" = 0 ] || { fail "R17 T4 cause stuck at 30 min"; return 1; }
  ARM_CAUSE=T2 ARM_DEW=300 fresh; io 8; RW_NOW=$((NOW0+1800)); t4r_step 0; [ "$(grep -c 'REPRICE-RECOVER-STUCK' "$LOG")" = 1 ] || { fail "R17 within=300 no stuck at 30 min"; return 1; }
  # R18: a state file with ONLY t4_lowered_from=2 (the shape of the live run-1037 file) loads as lowered_from=2, cause T4, restart unknown, then restores exactly 2; the new key wins when both exist
  fresh; printf 'T4R_RUN=7\nT4R_PAUSED_AT=%s\nT4R_COST=0\nT4R_LAST=last_commit=5ddad49a\nT4R_STUCK=0\nt4_lowered_from=2\n' "$NOW0" > "$T4R_STATE"
  T4R_RUN=; T4R_FROM=; T4R_PAUSED_AT=; T4R_COST=unknown; T4R_LAST=; T4R_STUCK=0; T4R_N=0; T4R_EXPLOG=; T4R_CAUSE=T4; T4R_RESTART=unknown; t4r_load
  [ "$T4R_FROM" = 2 ] && [ "$T4R_RUN" = 7 ] && [ "$T4R_CAUSE" = T4 ] && [ "$T4R_RESTART" = unknown ] || { fail "R18 legacy load from=[$T4R_FROM] run=[$T4R_RUN] cause=[$T4R_CAUSE]"; return 1; }
  passes "$need"
  [ "$(cnt '^wm-build-limits-guard set max_runs=2 ')" = 1 ] && [ "$(cnt '^wm-build-limits-guard enforce$')" = 1 ] && [ "$(cnt '^wm-build run redrive 7 --from inner$')" = 1 ] || { fail "R18 legacy restore calls=[$(tr '\n' '|' < "$CALLS")]"; return 1; }
  fresh; printf 'T4R_RUN=7\nT4R_PAUSED_AT=%s\nlowered_from=3\nt4_lowered_from=2\nt4r_cause=T2\ndaemon_restart_within=45\n' "$NOW0" > "$T4R_STATE"
  T4R_RUN=; T4R_FROM=; T4R_PAUSED_AT=; T4R_CAUSE=T4; T4R_RESTART=unknown; t4r_load
  [ "$T4R_FROM" = 3 ] && [ "$T4R_CAUSE" = T2 ] && [ "$T4R_RESTART" = 45 ] || { fail "R18 new key precedence from=[$T4R_FROM] cause=[$T4R_CAUSE] restart=[$T4R_RESTART]"; return 1; }
  # R19: the redrive returns rc 3 (prefix-cap) twice, then 0 -> exactly 3 redrive calls, each >= 3 passes apart, one RETRY bell, then the RECOVER bell, state file gone after the third call; never --force/--ungated/unpause
  fresh; printf '3\n3\n' > "$FAKE_RCS"; passes "$need"
  [ "$(cnt '^wm-build run redrive 7 --from inner$')" = 1 ] && [ -e "$T4R_STATE" ] && [ "$T4R_RUN" = 7 ] && grep -q 'T4R redrive-retry run=7 rc=3 attempt=1' "$LOG" || { fail "R19 first failure did not keep the state calls=[$(tr '\n' '|' < "$CALLS")] log=[$(tail -n 3 "$LOG" | tr '\n' '|')]"; return 1; }
  local p1=0 p2=0 rd=1 pn=0 rd2
  while [ -n "$T4R_RUN" ] && [ "$pn" -lt 20 ]; do pn=$((pn+1)); t4r_step; rd2=$(cnt '^wm-build run redrive 7 --from inner$'); [ "$rd2" -gt "$rd" ] && { rd=$rd2; [ "$rd" = 2 ] && p1=$pn; [ "$rd" = 3 ] && p2=$pn; }; done
  [ "$rd" = 3 ] && [ "$p1" = 3 ] && [ "$((p2-p1))" = 3 ] && [ -z "$T4R_RUN" ] && [ ! -e "$T4R_STATE" ] || { fail "R19 redrives=$rd at passes p1=$p1 p2=$p2 (want 3 calls, 3 passes apart) state_left=$([ -e "$T4R_STATE" ] && echo yes || echo no)"; return 1; }
  [ "$(grep -c 'RB-BELL REPRICE-RECOVER-RETRY run=7 rc=3 attempt=1' "$LOG")" = 1 ] && [ "$(grep -c 'RB-BELL REPRICE-RECOVER-RETRY' "$LOG")" = 1 ] && grep -q 'T4R redrive-retry run=7 rc=3 attempt=2' "$LOG" \
    && [ "$(grep -c 'RB-BELL REPRICE-RECOVER run=7 ' "$LOG")" = 1 ] && ! grep -Eq -- '--force|--ungated|unpause' "$CALLS" || { fail "R19 bells retry=$(grep -c 'RECOVER-RETRY' "$LOG") recover=$(grep -c 'RB-BELL REPRICE-RECOVER run=7 ' "$LOG")"; return 1; }
  # R20: rc 3, then the row ends -> no further redrive call, the skip line, state cleared
  fresh; printf '3\n' > "$FAKE_RCS"; passes "$need"; [ "$(cnt '^wm-build run redrive 7 --from inner$')" = 1 ] && [ -e "$T4R_STATE" ] || { fail "R20 first failure did not keep the state"; return 1; }
  sqlite3 "$DB" "update runs set ended='2026-10-22 13:30:00' where id=7"; t4r_step   # the ended re-read bypasses the 3-pass hold: one pass clears
  [ "$(cnt '^wm-build run redrive 7 --from inner$')" = 1 ] && grep -q 'T4R skip-redrive run=7 (run ended)' "$LOG" && [ ! -e "$T4R_STATE" ] && [ -z "$T4R_RUN" ] || { fail "R20 calls=[$(tr '\n' '|' < "$CALLS")] log=[$(tail -n 3 "$LOG" | tr '\n' '|')]"; return 1; }
  # R21: a state loaded for a run already hand-redriven (paused_at NULL, lowered_from=2) is kept at load (no writes), takes the R16 restore only after the io window (bad io passes reset it), and logs the waiting line once
  fresh; sqlite3 "$DB" "update runs set paused_at=NULL where id=7"
  T4R_RUN=; T4R_FROM=; T4R_PAUSED_AT=; T4R_COST=unknown; T4R_LAST=; T4R_STUCK=0; T4R_N=0; T4R_EXPLOG=; T4R_HRSEEN=; t4r_load
  [ "$T4R_RUN" = 7 ] && [ "$T4R_FROM" = 2 ] && [ -e "$T4R_STATE" ] && [ ! -s "$CALLS" ] || { fail "R21 load run=[$T4R_RUN] from=[$T4R_FROM] calls=[$(tr '\n' '|' < "$CALLS")]"; return 1; }
  io 8; passes 5; [ ! -s "$CALLS" ] || { fail "R21 restored on a bad-io pass calls=[$(tr '\n' '|' < "$CALLS")]"; return 1; }
  io 3; passes $((need-1)); [ ! -s "$CALLS" ] || { fail "R21 restored before the window N=$T4R_N calls=[$(tr '\n' '|' < "$CALLS")]"; return 1; }
  t4r_step
  [ "$(wc -l < "$CALLS")" = 2 ] && nth 1 | grep -q '^wm-build-limits-guard set max_runs=2 ' && [ "$(nth 2)" = "wm-build-limits-guard enforce" ] && [ "$(cnt 'redrive')" = 0 ] && [ ! -e "$T4R_STATE" ] \
    && [ "$(grep -c 'T4R hand-redrive seen run=7; restore waits for io window' "$LOG")" = 1 ] || { fail "R21 calls=[$(tr '\n' '|' < "$CALLS")] seen=$(grep -c 'hand-redrive seen' "$LOG")"; return 1; }
  # R22: dirty wt; the wip-redrive fake exits 0 but leaves paused_at set for 2 calls, then clears it -> 3 calls 3 passes apart, the "still paused" line twice, one RETRY bell, then RECOVER, state gone
  fresh; echo wip > "$t/wt/s1/dirty.txt"; echo 2 > "$FAKE_WIPSTILL"; passes "$need"
  [ "$(cnt '^wip 7$')" = 1 ] && [ -e "$T4R_STATE" ] && [ "$T4R_RUN" = 7 ] && grep -q 'T4R redrive run=7 rc=0 but still paused -> treated as refused (rc=86)' "$LOG" && grep -q 'T4R redrive-retry run=7 rc=86 attempt=1' "$LOG" || { fail "R22 first refusal counted as success calls=[$(tr '\n' '|' < "$CALLS")] log=[$(tail -n 3 "$LOG" | tr '\n' '|')]"; return 1; }
  p1=0; p2=0; rd=1; pn=0
  while [ -n "$T4R_RUN" ] && [ "$pn" -lt 20 ]; do pn=$((pn+1)); t4r_step; rd2=$(cnt '^wip 7$'); [ "$rd2" -gt "$rd" ] && { rd=$rd2; [ "$rd" = 2 ] && p1=$pn; [ "$rd" = 3 ] && p2=$pn; }; done
  [ "$rd" = 3 ] && [ "$p1" = 3 ] && [ "$((p2-p1))" = 3 ] && [ -z "$T4R_RUN" ] && [ ! -e "$T4R_STATE" ] && [ "$(cnt 'run redrive')" = 0 ] || { fail "R22 wip calls=$rd at passes p1=$p1 p2=$p2 (want 3 calls, 3 passes apart) state_left=$([ -e "$T4R_STATE" ] && echo yes || echo no)"; return 1; }
  [ "$(grep -c 'rc=0 but still paused -> treated as refused (rc=86)' "$LOG")" = 2 ] && [ "$(grep -c 'RB-BELL REPRICE-RECOVER-RETRY' "$LOG")" = 1 ] && [ "$(grep -c 'RB-BELL REPRICE-RECOVER run=7 ' "$LOG")" = 1 ] && grep -q 'redrive_rc=0 ' "$LOG" \
    || { fail "R22 still=$(grep -c 'but still paused' "$LOG") retry=$(grep -c 'RECOVER-RETRY' "$LOG") recover=$(grep -c 'RB-BELL REPRICE-RECOVER run=7 ' "$LOG")"; return 1; }
  # R23: the skip path keeps the state (stage != inner): state file survives, the retry line is logged, no RECOVER bell, no calls; then the stage becomes inner -> the redrive runs, then RECOVER and the state is cleared
  fresh; sqlite3 "$DB" "update runs set stage='land' where id=7"; passes "$need"
  [ -e "$T4R_STATE" ] && [ "$T4R_RUN" = 7 ] && [ ! -s "$CALLS" ] && grep -q 'T4R redrive-retry run=7 rc=skipped(stage=land, not inner) attempt=1' "$LOG" && grep -q 'RB-BELL REPRICE-RECOVER-RETRY run=7 rc=skipped' "$LOG" && ! grep -q 'RB-BELL REPRICE-RECOVER run=' "$LOG" \
    || { fail "R23 skip cleared the state calls=[$(tr '\n' '|' < "$CALLS")] log=[$(tail -n 3 "$LOG" | tr '\n' '|')]"; return 1; }
  passes 4; [ ! -s "$CALLS" ] && [ -e "$T4R_STATE" ] || { fail "R23 acted while still stage=land calls=[$(tr '\n' '|' < "$CALLS")]"; return 1; }
  sqlite3 "$DB" "update runs set stage='inner' where id=7"; pn=0
  while [ -n "$T4R_RUN" ] && [ "$pn" -lt 12 ]; do pn=$((pn+1)); t4r_step; done
  [ "$(cnt '^wm-build run redrive 7 --from inner$')" = 1 ] && [ "$(grep -c 'RB-BELL REPRICE-RECOVER run=7 ' "$LOG")" = 1 ] && [ -z "$T4R_RUN" ] && [ ! -e "$T4R_STATE" ] || { fail "R23 resume calls=[$(tr '\n' '|' < "$CALLS")] state_left=$([ -e "$T4R_STATE" ] && echo yes || echo no)"; return 1; }
  # R24: an EMPTY sqlite read (DB path that does not exist) is unknown: at load the state is kept (no stale-delete), in retry mode it is kept (no clear, no calls); the line is logged once per 10 empty reads per site
  fresh; DB=$t/missing.db; T4R_RUN=; T4R_FROM=; T4R_PAUSED_AT=; T4R_COST=unknown; T4R_LAST=; T4R_STUCK=0; T4R_N=0; T4R_EXPLOG=; t4r_load
  [ "$T4R_RUN" = 7 ] && [ -e "$T4R_STATE" ] && [ ! -s "$CALLS" ] && ! grep -q 'T4R state stale' "$LOG" && grep -q 'T4R row read empty run=7 at=load' "$LOG" || { fail "R24 load emptied the state run=[$T4R_RUN] state=$([ -e "$T4R_STATE" ] && echo kept || echo gone) log=[$(tail -n 3 "$LOG" | tr '\n' '|')]"; return 1; }
  fresh; printf '3\n' > "$FAKE_RCS"; passes "$need"; [ "$T4R_ATT" = 1 ] && [ -e "$T4R_STATE" ] || { fail "R24 setup: no retry mode"; return 1; }
  DB=$t/missing.db; : > "$LOG"; local c0; c0=$(wc -l < "$CALLS"); passes 11
  [ "$T4R_RUN" = 7 ] && [ -e "$T4R_STATE" ] && [ "$(wc -l < "$CALLS")" = "$c0" ] && [ "$(grep -c 'T4R row read empty run=7 at=step' "$LOG")" = 2 ] && ! grep -q 'RB-BELL REPRICE-RECOVER run=' "$LOG" && ! grep -q 'skip-redrive' "$LOG" \
    || { fail "R24 retry-mode empty read cleared/acted run=[$T4R_RUN] state=$([ -e "$T4R_STATE" ] && echo kept || echo gone) empties=$(grep -c 'row read empty' "$LOG") log=[$(tail -n 3 "$LOG" | tr '\n' '|')]"; return 1; }
  DB=$t/s.db
  # R25: the MG sigma gate. 2 other open unpaused inners (caps inner=11.5, budget 26): 23 + 11.5 > 26 -> refused (no limits-guard call, no redrive, state kept, one sigma-refused line + one bell however many attempts); one ends -> 11.5 + 11.5 <= 26 -> restore + redrive, RECOVER, state cleared
  fresh; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at) values (8,'s8',NULL,'inner',NULL),(9,'s9',NULL,'inner',NULL)"; passes "$need"
  [ ! -s "$CALLS" ] && [ -e "$T4R_STATE" ] && [ "$T4R_RUN" = 7 ] && grep -q 'T4R sigma-refused run=7 sigma=23 cap=11.5 budget=26 parts=8:inner:11.5,9:inner:11.5' "$LOG" && [ "$(grep -c 'RB-BELL REPRICE-SIGMA-REFUSED run=7 attempt=1 ' "$LOG")" = 1 ] \
    || { fail "R25 first refusal calls=[$(tr '\n' '|' < "$CALLS")] state=$([ -e "$T4R_STATE" ] && echo kept || echo gone) log=[$(tail -n 3 "$LOG" | tr '\n' '|')]"; return 1; }
  passes 9; [ ! -s "$CALLS" ] && [ -e "$T4R_STATE" ] && [ "$(grep -c 'T4R sigma-refused' "$LOG")" = 1 ] && [ "$(grep -c 'RB-BELL REPRICE-SIGMA-REFUSED' "$LOG")" = 1 ] && [ "$(grep -c 'RB-BELL REPRICE-RECOVER run=' "$LOG")" = 0 ] || { fail "R25 kept refusing wrongly calls=[$(tr '\n' '|' < "$CALLS")] refused=$(grep -c 'sigma-refused' "$LOG")"; return 1; }
  sqlite3 "$DB" "update runs set ended='2026-10-22 13:30:00' where id=9"; pn=0
  while [ -n "$T4R_RUN" ] && [ "$pn" -lt 12 ]; do pn=$((pn+1)); t4r_step; done
  [ "$(wc -l < "$CALLS")" = 3 ] && nth 1 | grep -q '^wm-build-limits-guard set max_runs=2 ' && [ "$(nth 2)" = "wm-build-limits-guard enforce" ] && [ "$(nth 3)" = "wm-build run redrive 7 --from inner" ] && [ "$(grep -c 'T4R sigma-ok run=7 sigma=11.5 cap=11.5 budget=26' "$LOG")" = 1 ] \
    && [ "$(grep -c 'RB-BELL REPRICE-RECOVER run=7 ' "$LOG")" = 1 ] && [ ! -e "$T4R_STATE" ] || { fail "R25 grant calls=[$(tr '\n' '|' < "$CALLS")] state=$([ -e "$T4R_STATE" ] && echo kept || echo gone) log=[$(tail -n 4 "$LOG" | tr '\n' '|')]"; return 1; }
  # R25b: an empty / unparseable caps read refuses (no [cargo_jobs.mem_caps_gb] inner, then no budget); a live hand cargo scope (memory.max 5 GiB) counts: 11.5 + 5 + 11.5 > 26
  fresh; printf '[daemon]\nmax_runs = 1\n\n[cargo_jobs]\nmem_budget_gb = 26\n' > "$CONFIG"; passes "$need"
  [ ! -s "$CALLS" ] && [ -e "$T4R_STATE" ] && grep -q 'T4R sigma-refused run=7 sigma=unknown cap= budget=26 parts=config-unreadable(inner=empty,budget=26)' "$LOG" || { fail "R25b empty caps calls=[$(tr '\n' '|' < "$CALLS")] log=[$(tail -n 3 "$LOG" | tr '\n' '|')]"; return 1; }
  fresh; printf '[daemon]\nmax_runs = 1\n\n[cargo_jobs.mem_caps_gb]\ninner = 11.5\n' > "$CONFIG"; passes "$need"
  [ ! -s "$CALLS" ] && [ -e "$T4R_STATE" ] && grep -q 'T4R sigma-refused run=7 sigma=unknown cap=11.5 budget=unknown ' "$LOG" || { fail "R25b empty budget calls=[$(tr '\n' '|' < "$CALLS")] log=[$(tail -n 3 "$LOG" | tr '\n' '|')]"; return 1; }
  fresh; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at) values (8,'s8',NULL,'inner',NULL)"; mkdir -p "$APP_SLICE/run-h1.scope" "$PROC/601"; echo cargo > "$PROC/601/comm"; echo 601 > "$APP_SLICE/run-h1.scope/cgroup.procs"; echo 5368709120 > "$APP_SLICE/run-h1.scope/memory.max"; passes "$need"
  [ ! -s "$CALLS" ] && grep -q 'T4R sigma-refused run=7 sigma=16.5 cap=11.5 budget=26 parts=8:inner:11.5,run-h1.scope:hand:5' "$LOG" || { fail "R25b hand scope calls=[$(tr '\n' '|' < "$CALLS")] log=[$(tail -n 3 "$LOG" | tr '\n' '|')]"; return 1; }
  rm -rf "$APP_SLICE/run-h1.scope" "$PROC/601"
  # R25c: the R16 hand-redrive restore passes the same gate: refused while 2 other inners are live (no set, no enforce, state kept), granted when one ends (set + enforce, zero redrive)
  fresh; sqlite3 "$DB" "update runs set paused_at=NULL where id=7; insert into runs(id,slug,ended,stage,paused_at) values (8,'s8',NULL,'inner',NULL),(9,'s9',NULL,'inner',NULL)"; passes $((need+4))
  [ ! -s "$CALLS" ] && [ -e "$T4R_STATE" ] && grep -q 'T4R sigma-refused run=7 sigma=23 ' "$LOG" || { fail "R25c seat refusal calls=[$(tr '\n' '|' < "$CALLS")]"; return 1; }
  sqlite3 "$DB" "update runs set ended='2026-10-22 13:30:00' where id=9"; pn=0
  while [ -n "$T4R_RUN" ] && [ "$pn" -lt 12 ]; do pn=$((pn+1)); t4r_step; done
  [ "$(wc -l < "$CALLS")" = 2 ] && nth 1 | grep -q '^wm-build-limits-guard set max_runs=2 ' && [ "$(nth 2)" = "wm-build-limits-guard enforce" ] && [ ! -e "$T4R_STATE" ] || { fail "R25c seat grant calls=[$(tr '\n' '|' < "$CALLS")]"; return 1; }
  # R26 (W1): an open quota circuit at the recovery window -> no max_runs change, no redrive, state kept and re-checked every pass; once closed the normal redrive goes
  fresh; sqlite3 "$DB" "update circuits set state='open'"; CG_LOG_AT=0; passes $((need+2))
  [ ! -s "$CALLS" ] && grep -q 'REDRIVE-DEFER circuit=quota' "$LOG" && [ "$T4R_RUN" = 7 ] && [ "$T4R_ATT" = 0 ] || { fail "R26 open circuit did not hold the redrive calls=[$(tr '\n' '|' < "$CALLS")]"; return 1; }
  sqlite3 "$DB" "update circuits set state='closed'"; t4r_step
  [ "$(cnt '^wm-build run redrive 7 --from inner$')" = 1 ] && [ -z "$T4R_RUN" ] || { fail "R26 closed circuit did not release calls=[$(tr '\n' '|' < "$CALLS")]"; return 1; }
  rm -rf "$t"; echo "T4R R1-R18 ok need=$need R19-R21 ok R22 ok R23-R24 ok R25 ok R26 ok"; }
w_selftest(){ # hermetic Appendix W selftest (W1 circuit gate, W2 expiring pauses, W3 status.json): fake DB, journal, ledger, clock and fake wm-build under a mktemp -d; prints a short ok string or SELFTEST FAIL W <case>
  local t NOW0 P1 P1B P3 Z rc
  t=$(mktemp -d) && [ -d "$t" ] || { echo "SELFTEST FAIL W mktemp"; return 1; }
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null FAKE_CALLS=$t/calls FAKE_DB=$t/s.db FAKE_REFUSE=$t/refuse
  LOG=$t/log; DB=$t/s.db; JOURNAL=$t/journal.jsonl; LEDGER=$t/ledger.tsv; LEDGER_LOCK=$LEDGER.lock; DEFERLOG=$t/defer.tsv; STATUS=$t/sw/status.json
  WT_ROOT=$t/wt; CONFIG=$t/config.toml; WIP_REDRIVE=$t/wip.sh; ENVF=$t/env; APP_SLICE=$t/app; PROC=$t/proc; mkdir -p "$APP_SLICE" "$PROC" "$t/bin" "$t/wt"
  PATH=$t/bin:$PATH; MEMINFO=$t/meminfo; MEM_PSI=$t/mpsi; IO_PSI=$t/ipsi; EARLY_REC=$t/early.tsv; HELD_REC=$t/held.tsv; MEM_AVAIL_MIN_KB=12582912; PSI_FULL_AVG60_MAX=10; IO_FULL_AVG60_MAX=10; NOW0=$(date -u -d 2026-10-22T20:00:00Z +%s); RW_NOW=$NOW0; EXPIRES=2026-11-21; T4R_RUN=; PAUSE_PASS_S=240
  P1=2026-10-22T18:00:00.000000000+00:00; P1B=2026-10-22T18:10:00.000000000+00:00; P3=2026-10-22T19:30:00.000000000+00:00
  log(){ echo "$*" >> "$LOG"; }   # no tee: the real log must never be touched by the selftest
  case "$LOG$LEDGER$STATUS$DEFERLOG$DB$JOURNAL$EARLY_REC$HELD_REC$MEMINFO$IO_PSI" in "$t"/*"$t"/*"$t"/*"$t"/*"$t"/*"$t"/*"$t"/*"$t"/*"$t"/*"$t"/*) ;; *) echo "SELFTEST FAIL W hermetic"; return 1;; esac
  cat > "$t/bin/wm-build" <<'FAKEWB'
#!/bin/bash
echo "wm-build $*" >> "$FAKE_CALLS"
case "$1 $2" in
  "run redrive") [ -e "$FAKE_REFUSE" ] && exit 0; sqlite3 "$FAKE_DB" "update runs set paused_at=NULL where id=$3"; exit 0;;
  "run pause") sqlite3 "$FAKE_DB" "update runs set paused_at='2026-10-22T20:00:01.500000000+00:00' where id=$3"; exit 0;;
esac
exit 0
FAKEWB
  chmod +x "$t/bin/wm-build"; printf '#!/bin/bash\necho "wip $*" >> "$FAKE_CALLS"\n' > "$WIP_REDRIVE"; echo ': fake env' > "$ENVF"
  printf '[cargo_jobs]\nmem_budget_gb = 26\n\n[cargo_jobs.mem_caps_gb]\ninner = 11.5\ngate = 13\nland = 12.5\nhand = 9\n' > "$CONFIG"
  wfail(){ echo "SELFTEST FAIL W $*"; rm -rf "$t"; return 1; }
  setmem(){ printf 'MemAvailable:   %s kB\n' "$1" > "$MEMINFO"; printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=%s avg300=0.00 total=0\n' "$2" > "$MEM_PSI"; printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=%s avg300=0.00 total=0\n' "$3" > "$IO_PSI"; }   # avail_kb mem_psi io_psi
  nextpass(){ RW_NOW=$((RW_NOW + PAUSE_PASS_S)); }
  wreset(){ rm -rf -- "$LEDGER" "$LEDGER_LOCK" "$DEFERLOG" "$t/sw" "$FAKE_REFUSE" "$DB" "$EARLY_REC" "$HELD_REC"; setmem 26000000 0.00 0.00; EARLY_N=0; EARLY_HOLD=0; EARLY_LOG_AT=0; : > "$FAKE_CALLS"; : > "$LOG"; : > "$JOURNAL"; LP_LAST=0; CGDONE=0; CGRC=0; CG_LOG_AT=0; CG_NOTE_AT=0; CG_BELL_AT=0; T4R_RUN=; RW_NOW=$NOW0; sim_arm; : > "$FAKE_DECIDE_REC"
    sqlite3 "$DB" "create table runs(id integer primary key, slug text, ended text, stage text, paused_at text, paused_cause text, train_hold_reason text); create table circuits(class text primary key, state text, resets_at text); create table alarms(id integer primary key, ref_ text, closed text); insert into circuits values('quota','closed',null);"; }
  jl(){ printf '{"op":"%s","row":{"class":"quota","reason":"quota-circuit resets=%s","run_id":1,"slug":"s","stage":"inner"},"table":"daemon","ts":"%s"}\n' "$1" "$3" "$(date -u -d "@$2" +%Y-%m-%dT%H:%M:%S.123456789+00:00)" >> "$JOURNAL"; }
  cnt(){ grep -c -- "$1" "$2" 2>/dev/null || true; }
  led(){ awk -F'\t' -v r="$1" '$1==r' "$LEDGER" 2>/dev/null; }
  # ---- W1 circuit_gate: five spec cases + two ----
  wreset; sqlite3 "$DB" "update circuits set state='open', resets_at='2026-10-22T23:00:00+00:00'; insert into alarms values(1,'circuit:quota',NULL)"; jl circuit-skip $((NOW0-60)) 2026-10-22T23:00:00+00:00
  circuit_gate; rc=$?; [ "$rc" = 1 ] && [ "$CG_OP" = circuit-skip ] && [ "$CG_RESETS" = 2026-10-22T23:00:00+00:00 ] || { wfail "G1 open -> defer rc=$rc op=$CG_OP resets=$CG_RESETS why=$CG_WHY"; return 1; }
  gate_ok selftest && { wfail "G1 gate_ok allowed an open circuit"; return 1; }
  grep -q 'REDRIVE-DEFER circuit=quota last_op=circuit-skip resets=2026-10-22T23:00:00+00:00' "$LOG" && [ "$(cnt . "$DEFERLOG")" = 1 ] || { wfail "G1 log/deferlog [$(cat "$LOG")]"; return 1; }
  wreset; sqlite3 "$DB" "insert into alarms values(1,'circuit:quota','$(date -u -d "@$((NOW0-3600))" +%Y-%m-%dT%H:%M:%S.5+00:00)')"; jl circuit-skip $((NOW0-120)) "$(date -u -d "@$((NOW0-600))" +%Y-%m-%dT%H:%M:%S+00:00)"
  circuit_gate; rc=$?; [ "$rc" = 1 ] && [ "$CG_V" = defer ] || { wfail "G2 skip after resets (state closed, skip newer than the last close) -> defer rc=$rc why=$CG_WHY"; return 1; }
  wreset; sqlite3 "$DB" "insert into alarms values(1,'circuit:quota','$(date -u -d "@$((NOW0-60))" +%Y-%m-%dT%H:%M:%S.5+00:00)')"; jl circuit-skip $((NOW0-3600)) 2026-10-22T19:00:00+00:00
  circuit_gate; rc=$?; [ "$rc" = 0 ] && [ "$CG_V" = ok ] || { wfail "G3 close after the last skip -> redrive rc=$rc why=$CG_WHY"; return 1; }
  wreset; jl circuit-skip $((NOW0-500)) 2026-10-22T19:00:00+00:00; jl circuit-half-open-success $((NOW0-30)) none; sqlite3 "$DB" "insert into alarms values(1,'circuit:quota','$(date -u -d "@$((NOW0-3600))" +%Y-%m-%dT%H:%M:%S.5+00:00)')"
  circuit_gate; rc=$?; [ "$rc" = 0 ] && [ "$CG_OP" = circuit-half-open-success ] || { wfail "G4 half-open success -> redrive rc=$rc op=$CG_OP why=$CG_WHY"; return 1; }
  sqlite3 "$DB" "update circuits set state='half_open'"; circuit_gate; rc=$?; [ "$rc" = 1 ] || { wfail "G4b state half_open (probe in flight) -> defer rc=$rc"; return 1; }
  wreset; printf '{"op":"circuit-skip","row":{"class":"quota"},"table":"daemon","ts":"garbage"}\n' >> "$JOURNAL"
  gate_ok selftest && { wfail "G5 unparsable ts allowed a redrive"; return 1; }; circuit_gate; rc=$?; [ "$rc" = 2 ] && grep -q 'RB-BELL REDRIVE-DEFER-UNPARSABLE' "$LOG" || { wfail "G5 unparsable ts -> defer + bell rc=$rc [$(cat "$LOG")]"; return 1; }
  wreset; sqlite3 "$DB" "drop table circuits; create table circuits(class text primary key, state text, resets_at text)"; circuit_gate; rc=$?; [ "$rc" = 2 ] || { wfail "G5b no circuits row -> unparsable rc=$rc"; return 1; }
  wreset; mv "$JOURNAL" "$JOURNAL.gone"; circuit_gate; rc=$?; [ "$rc" = 2 ] || { wfail "G5c journal missing -> unparsable rc=$rc"; return 1; }
  wreset; circuit_gate; rc=$?; [ "$rc" = 0 ] && [ "$CG_OP" = none ] || { wfail "G6 closed, no circuit op in the journal -> redrive rc=$rc"; return 1; }
  # ---- W2 ledger passes ----
  wreset; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at) values(7,'s1',NULL,'inner','$P1')"; ledger_add 7 "$P1" "$(iso_at $((NOW0-60)))" "rb-reprice-watch T4: x; owner rb; expires t" 0   # E1
  ledger_pass; [ "$(cnt '^wm-build run redrive 7 --from inner$' "$FAKE_CALLS")" = 1 ] && [ -z "$(led 7)" ] && grep -q 'RB-BELL PAUSE-RELEASED run=7' "$LOG" || { wfail "E1 expiry -> release calls=[$(tr '\n' '|' < "$FAKE_CALLS")] ledger=[$(cat "$LEDGER")]"; return 1; }
  wreset; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at) values(7,'s1',NULL,'inner','$P1'),(8,'s2',NULL,'inner',NULL),(9,'s3',NULL,'inner',NULL)"; ledger_add 7 "$P1" "$(iso_at $((NOW0-60)))" c 0   # E2: Σ 23 + 11.5 > 26 refuses
  ledger_pass; q=$(led 7 | cut -f3,5)
  [ ! -s "$FAKE_CALLS" ] && [ "$q" = "$(iso_at $((NOW0+1800)))"$'\t'1 ] || { wfail "E2 refused -> extend q=[$q] calls=[$(cat "$FAKE_CALLS")]"; return 1; }
  wreset; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at) values(7,'s1',NULL,'inner','$P1'),(8,'s2',NULL,'inner',NULL),(9,'s3',NULL,'inner',NULL)"; ledger_add 7 "$P1" "$(iso_at $((NOW0-60)))" c 2   # E3: two extensions used -> bell once
  ledger_pass; LP_LAST=0; RW_NOW=$((NOW0+300)); ledger_pass
  [ "$(cnt 'RB-BELL PAUSE-OVERDUE run=7' "$LOG")" = 1 ] && [ "$(led 7 | cut -f5)" = 3 ] && [ ! -s "$FAKE_CALLS" ] && [ "$(jq -r .pause_ledger.overdue "$STATUS")" = 1 ] || { wfail "E3 2 extensions -> bell once [$(cat "$LOG")] ledger=[$(cat "$LEDGER")]"; return 1; }
  wreset; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at) values(7,'s1',NULL,'inner',NULL)"; ledger_add 7 "$P1" "$(iso_at $((NOW0-60)))" c 0   # E4: row's paused_at no longer on the daemon row (redriven) -> drop, no redrive
  ledger_pass; [ -z "$(led 7)" ] && [ ! -s "$FAKE_CALLS" ] && grep -q 'LEDGER-STALE run=7' "$LOG" || { wfail "E4 stale row -> drop, no redrive [$(cat "$LOG")] calls=[$(cat "$FAKE_CALLS")]"; return 1; }
  wreset; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at) values(7,'s1',NULL,'inner','$P3')"; ledger_add 7 "$P1" "$(iso_at $((NOW0+3000)))" c 0   # E4b: NOT yet expired, but the run was re-paused at another time: stale -> dropped by (a), then the new pause is adopted
  ledger_pass; [ "$(led 7 | cut -f2)" = "$P3" ] && [ "$(cnt 'LEDGER-STALE run=7' "$LOG")" = 1 ] && [ ! -s "$FAKE_CALLS" ] || { wfail "E4b stale unexpired row [$(cat "$LOG")] ledger=[$(cat "$LEDGER")]"; return 1; }
  wreset; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at) values(7,'s1',NULL,'inner','$P3')"; ledger_pass; LP_LAST=0; ledger_pass   # E5: unledgered -> adopt (+90 m) and ring once
  q=$(led 7 | cut -f2,3,4,5)
  [ "$q" = "$P3"$'\t'2026-10-22T21:00:00Z$'\t'unledgered$'\t'0 ] && [ "$(cnt 'RB-BELL PAUSE-UNLEDGERED run=7' "$LOG")" = 1 ] && [ ! -s "$FAKE_CALLS" ] || { wfail "E5 unledgered adopt q=[$q] log=[$(cat "$LOG")]"; return 1; }
  wreset; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at) values(7,'s1',NULL,'inner','$P1'),(8,'s2',NULL,'inner','$P1B')"; ledger_add 8 "$P1B" "$(iso_at $((NOW0-60)))" c 0; ledger_add 7 "$P1" "$(iso_at $((NOW0-120)))" c 0   # E6: two expired, oldest (7) first, only one per pass
  ledger_pass; [ "$(cnt 'run redrive' "$FAKE_CALLS")" = 1 ] && [ "$(cnt '^wm-build run redrive 7 --from inner$' "$FAKE_CALLS")" = 1 ] && [ -z "$(led 7)" ] && [ -n "$(led 8)" ] || { wfail "E6 2 expired -> 1 released calls=[$(tr '\n' '|' < "$FAKE_CALLS")] ledger=[$(cat "$LEDGER")]"; return 1; }
  wreset; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at) values(7,'s1',NULL,'inner',NULL)"; wpause 7 "T4: io pressure"   # E7: wpause carries the expiry in --cause and writes the ledger with the daemon's paused_at
  [ "$(cnt '^wm-build run pause 7 --cause rb-reprice-watch T4: io pressure; owner rb; expires 2026-10-22T21:30:00Z$' "$FAKE_CALLS")" = 1 ] && [ "$(led 7 | cut -f2,3,5)" = "2026-10-22T20:00:01.500000000+00:00"$'\t'2026-10-22T21:30:00Z$'\t'0 ] || { wfail "E7 wpause calls=[$(cat "$FAKE_CALLS")] ledger=[$(cat "$LEDGER")]"; return 1; }
  wreset; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at) values(7,'s1',NULL,'inner','$P1')"; ledger_add 7 "$P1" "$(iso_at $((NOW0-60)))" c 0; : > "$FAKE_REFUSE"   # E8: redrive exits 0 but the row stays paused -> refused -> extend
  ledger_pass; [ "$(led 7 | cut -f5)" = 1 ] && [ "$(cnt 'run redrive 7' "$FAKE_CALLS")" = 1 ] && [ -n "$(led 7)" ] || { wfail "E8 still-paused redrive -> extend [$(cat "$LEDGER")]"; return 1; }
  wreset; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at) values(7,'s1',NULL,'inner','$P1')"; ledger_add 7 "$P1" "$(iso_at $((NOW0-60)))" c 0; T4R_RUN=7   # E9: the T4R recovery watch owns its run
  ledger_pass; [ ! -s "$FAKE_CALLS" ] && [ "$(led 7 | cut -f5)" = 0 ] || { wfail "E9 T4R-owned run touched"; return 1; }
  wreset; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at) values(7,'s1',NULL,'inner','$P1')"; ledger_add 7 "$P1" "$(iso_at $((NOW0-60)))" c 0; sqlite3 "$DB" "update circuits set state='open'"; jl circuit-skip $((NOW0-60)) 2026-10-22T23:00:00+00:00   # W1 on the W2 path: open circuit -> no redrive, extension, defer logged
  ledger_pass; [ ! -s "$FAKE_CALLS" ] && [ "$(led 7 | cut -f5)" = 1 ] && grep -q 'REDRIVE-DEFER circuit=quota last_op=circuit-skip' "$LOG" && [ "$(jq -r .redrive_defer.count_24h "$STATUS")" = 1 ] && [ "$(jq -r .redrive_defer.last_op "$STATUS")" = circuit-skip ] || { wfail "I1 open circuit on the ledger path [$(cat "$LOG")] calls=[$(cat "$FAKE_CALLS")]"; return 1; }
  wreset; sim_expire; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at) values(7,'s1',NULL,'inner','$P1')"; ledger_add 7 "$P1" "$(iso_at $((NOW0-60)))" c 0   # premise expired: no write, status says expired
  ledger_pass; [ ! -s "$FAKE_CALLS" ] && [ "$(jq -r .premise.verdict "$STATUS")" = expired ] && [ "$(jq -r .premise.expires "$STATUS")" = 2026-11-21 ] || { wfail "X1 expired premise wrote or status wrong"; return 1; }
  wreset; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at) values(7,'s1',NULL,'inner','$P1')"; ledger_add 7 "$P1" "$(iso_at $((NOW0+600)))" c 0; ledger_pass   # S1: status shape (tmp+rename leaves no tmp file)
  [ "$(jq -r '.pause_ledger.open' "$STATUS")" = 1 ] && [ "$(jq -r '.pause_ledger.oldest_expires' "$STATUS")" = "$(iso_at $((NOW0+600)))" ] && [ "$(jq -r '.pause_ledger.overdue' "$STATUS")" = 0 ] && [ "$(jq -r '.redrive_defer.last_ts' "$STATUS")" = null ] \
    && [ "$(jq -r '.premise.verdict' "$STATUS")" = armed ] && [ "$(ls "$t/sw" | wc -l)" = 1 ] || { wfail "S1 status shape [$(cat "$STATUS")] ls=[$(ls "$t/sw")]"; return 1; }
  # ---- W4 (Weakest-link fallback): SIGMA-DRIFT is log-only; premise-recovery early release (G4-G6) ----
  P4=2026-10-22T19:40:00.000000000+00:00; CSG="rb sigma-guard: MemAvailable 11G < 12G (Σ=15.5G [7(inner):10.5, hand:5.0]); newest-started compiling inner paused (started 2026-10-22T19:30:18); released by redrive --from inner"
  C4="rb-reprice-watch T4 10-22: io_full_avg60=12>10 for the 5-min window (15 passes) with 2 inners live and no hand cargo scope (started 2026-10-22T22:30:18)"; ins7(){ sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at,paused_cause) values(7,'s1',NULL,'${3:-inner}','${2:-$P4}','$1')"; }
  rdr(){ cnt '^wm-build run redrive 7 --from inner$' "$FAKE_CALLS"; }   # redrive calls for run 7
  wreset; ins7 "$CSG"; ledger_pass   # V1 acceptance 3 (grant): adopted memory pause, mem clear x2, local Σ grants -> released BEFORE expiry; one pass is not enough
  [ "$(rdr)" = 0 ] && [ "$EARLY_N" = 1 ] || { wfail "V1a one clear pass must not release n=$EARLY_N [$(cat "$LOG")]"; return 1; }
  nextpass; ledger_pass
  [ "$(rdr)" = 1 ] && [ -z "$(led 7)" ] && grep -q '^RB-BELL PAUSE-RELEASED run=7 early premise-recovered$' "$LOG" && [ "$(cnt '^7	' "$EARLY_REC")" = 1 ] && [ "$EARLY_N" = 0 ] || { wfail "V1b two clear passes -> early release calls=[$(tr '\n' '|' < "$FAKE_CALLS")] ledger=[$(cat "$LEDGER")] log=[$(cat "$LOG")]"; return 1; }
  wreset; ins7 "$CSG"; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at) values(8,'s2',NULL,'inner',NULL),(9,'s3',NULL,'inner',NULL)"; ledger_pass; nextpass; ledger_pass   # V2 acceptance 3 (refuse): Σ 23 + 11.5 > 26 -> no redrive, NO extension
  [ "$(rdr)" = 0 ] && [ "$(led 7 | cut -f3,5)" = "2026-10-22T21:10:00Z"$'\t'0 ] && [ "$(cnt '^EARLY-RELEASE-REFUSED run=7 why="sigma refused' "$LOG")" = 1 ] || { wfail "V2a refused early -> no extension q=[$(led 7)] log=[$(cat "$LOG")]"; return 1; }
  for _ in 1 2 3 4; do nextpass; ledger_pass; done
  [ "$(led 7 | cut -f5)" = 0 ] && [ "$(cnt '^EARLY-RELEASE-REFUSED run=7' "$LOG")" = 1 ] && [ "$(rdr)" = 0 ] && ! grep -q 'LEDGER-EXTEND' "$LOG" || { wfail "V2b still 0 extensions, refusal logged once in 6 passes [$(cat "$LOG")]"; return 1; }
  wreset; ins7 "$CSG"; ledger_pass; setmem 10000000 0.00 0.00; nextpass; ledger_pass; setmem 26000000 0.00 0.00; nextpass; ledger_pass   # V3: mem bad on pass 2 resets the count; clear again is only 1 -> no release; the next clear pass is 2 -> release
  [ "$(rdr)" = 0 ] && [ "$EARLY_N" = 1 ] || { wfail "V3a mem_bad reset n=$EARLY_N calls=$(rdr)"; return 1; }
  nextpass; ledger_pass; [ "$(rdr)" = 1 ] || { wfail "V3b second consecutive clear pass releases calls=$(rdr)"; return 1; }
  wreset; ins7 "$CSG"; setmem 26000000 0.00 12.00; for _ in 1 2 3 4; do ledger_pass; nextpass; done   # V4: io full avg60 12 > 10 -> never clear
  [ "$(rdr)" = 0 ] && [ "$EARLY_N" = 0 ] || { wfail "V4 io bad must block n=$EARLY_N calls=$(rdr)"; return 1; }
  wreset; ins7 "$CSG" "$P4" land; for _ in 1 2 3 4; do ledger_pass; nextpass; done   # V5 (G6): a paused LAND row is never early-released
  [ "$(cnt 'run redrive' "$FAKE_CALLS")" = 0 ] && [ -n "$(led 7)" ] && [ "$EARLY_N" -ge 2 ] || { wfail "V5 land row skipped calls=[$(cat "$FAKE_CALLS")] n=$EARLY_N"; return 1; }
  wreset; ins7 "$C4"; for _ in 1 2 3 4; do ledger_pass; nextpass; done   # V6: a T4 (io) pause whose text carries a timestamp ...T22:... is NOT memory-class (T2 is word-bounded)
  [ "$(rdr)" = 0 ] && [ -n "$(led 7)" ] || { wfail "V6 T4/timestamp cause must not early-release calls=$(rdr)"; return 1; }
  wreset; ins7 "$CSG"; T4R_RUN=7; for _ in 1 2 3 4; do ledger_pass; nextpass; done; T4R_RUN=   # V7: the T4R recovery watch owns its run
  [ "$(rdr)" = 0 ] && [ -n "$(led 7)" ] || { wfail "V7 T4R-owned run touched calls=$(rdr)"; return 1; }
  wreset; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at,paused_cause) values(7,'s1',NULL,'inner','$P1','$CSG'),(8,'s2',NULL,'inner','$P4','$CSG')"; ledger_add 7 "$P1" "$(iso_at $((NOW0-60)))" c 0; ledger_add 8 "$P4" "$(iso_at $((NOW0+3000)))" unledgered 0; EARLY_N=5   # V8 (G4): one release per pass in total
  ledger_pass; [ "$(cnt 'run redrive' "$FAKE_CALLS")" = 1 ] && [ "$(cnt '^wm-build run redrive 7 --from inner$' "$FAKE_CALLS")" = 1 ] && [ -n "$(led 8)" ] && ! grep -q 'early premise-recovered' "$LOG" || { wfail "V8a expiry release + early in one pass calls=[$(tr '\n' '|' < "$FAKE_CALLS")]"; return 1; }
  nextpass; ledger_pass; [ "$(cnt '^wm-build run redrive 8 --from inner$' "$FAKE_CALLS")" = 1 ] && grep -q 'RB-BELL PAUSE-RELEASED run=8 early premise-recovered' "$LOG" || { wfail "V8b the next pass early-releases 8 [$(cat "$LOG")]"; return 1; }
  wreset; ins7 "$CSG"; EARLY_N=5; printf '7\t%s\n' $((NOW0-600)) > "$EARLY_REC"; ledger_pass   # V9 (G5): an early release 10 min ago -> a re-pause waits for expiry; 2000 s ago it may go
  [ "$(rdr)" = 0 ] || { wfail "V9a early release 600 s ago must block calls=$(rdr)"; return 1; }
  wreset; ins7 "$CSG"; EARLY_N=5; printf '7\t%s\n' $((NOW0-2000)) > "$EARLY_REC"; ledger_pass; [ "$(rdr)" = 1 ] || { wfail "V9b early release 2000 s ago must not block calls=$(rdr)"; return 1; }
  wreset; ins7 "$CSG" "$(iso_at $((NOW0-100)))"; EARLY_N=5; ledger_pass   # V10: a pause younger than 2 passes cannot be recovered by samples that predate it
  [ "$(rdr)" = 0 ] || { wfail "V10 young pause must wait calls=$(rdr)"; return 1; }
  wreset; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at,paused_cause) values(7,'s1',NULL,'inner','$P4','rb-reprice-watch T2 10-20: MemAvailable_kb=11000000<12582912 with 2 inners at inner cap 10.5'),(8,'s2',NULL,'inner','$P4','$CSG')"; ledger_add 7 "$P4" "$(iso_at $((NOW0+3100)))" "rb-reprice-watch T2 10-20: MemAvailable_kb=11000000<12582912; owner rb; expires t" 0; ledger_add 8 "$P4" "$(iso_at $((NOW0+3000)))" "rb-reprice-watch T4 10-22: x; owner rb; expires t" 0; EARLY_N=5   # V11: a watcher T2 row qualifies; a ledger row owned by T4 does not, whatever the daemon cause says
  ledger_pass; [ "$(rdr)" = 1 ] && [ "$(cnt '^wm-build run redrive 8 ' "$FAKE_CALLS")" = 0 ] && [ -n "$(led 8)" ] || { wfail "V11 T2 row released, T4-owned row kept calls=[$(tr '\n' '|' < "$FAKE_CALLS")]"; return 1; }
  wreset; ins7 "$CSG"; EARLY_N=5; : > "$FAKE_REFUSE"; ledger_pass; nextpass; ledger_pass; nextpass; ledger_pass   # V12: a redrive that exits 0 but leaves the row paused is a refusal: no extension, backs off 2 passes (1 attempt in 3 passes)
  [ "$(rdr)" = 1 ] && [ "$(led 7 | cut -f5)" = 0 ] && [ "$(cnt '^EARLY-RELEASE-REFUSED run=7 why="redrive rc=0' "$LOG")" = 1 ] || { wfail "V12 backoff calls=$(rdr) q=[$(led 7)] log=[$(cat "$LOG")]"; return 1; }
  nextpass; ledger_pass; [ "$(rdr)" = 2 ] || { wfail "V12b the 4th pass retries calls=$(rdr)"; return 1; }
  wreset; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at,paused_cause) values(7,'s1',NULL,'inner','$P4','$CSG'),(8,'s2',NULL,'inner','$P4','$CSG')"; ledger_add 7 "$P4" "$(iso_at $((NOW0+3100)))" unledgered 0; ledger_add 8 "$P4" "$(iso_at $((NOW0+3000)))" unledgered 0; EARLY_N=5   # V16: oldest expiry first, one attempt per pass
  ledger_pass; [ "$(cnt 'run redrive' "$FAKE_CALLS")" = 1 ] && [ "$(cnt '^wm-build run redrive 8 --from inner$' "$FAKE_CALLS")" = 1 ] && [ -n "$(led 7)" ] || { wfail "V16 oldest-first single attempt calls=[$(tr '\n' '|' < "$FAKE_CALLS")]"; return 1; }
  # RWH: a HELD row is never redriven by the ledger (i) hand-held land (ii) train hold (iii) the watcher's own T2 cause still releases, a non-watcher cause with `threshold`/`holder` is not a hold word
  hins(){ sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at,paused_cause,train_hold_reason) values(7,'s1',NULL,'$1','$P4','$2','$3')"; }
  CH="squash-reverts-main hold (row 67a7); release = redrive --from land, never unpause"
  wreset; hins land "$CH" ''; ledger_add 7 "$P4" "$(iso_at $((NOW0-60)))" unledgered 0; ledger_pass; nextpass; ledger_pass
  [ "$(cnt 'run redrive' "$FAKE_CALLS")" = 0 ] && [ "$(cnt 'wip' "$FAKE_CALLS")" = 0 ] && [ "$(cnt '^LEDGER-HELD-SKIP run=7 stage=land cause="squash-reverts-main hold' "$LOG")" = 1 ] && [ "$(cnt '^RB-BELL PAUSE-HELD run=7 stage=land .*rb-redrive.sh 7 --from land)$' "$LOG")" = 1 ] && [ "$(led 7 | cut -f3,5)" = "$(printf '%s\t0' "$(iso_at $((NOW0-60)))")" ] && [ "$(cnt 'LEDGER-EXTEND\|PAUSE-OVERDUE\|EXPIRED.*extensions=[1-9]' "$LOG")" = 0 ] || { wfail "H1 hand-held land must not be redriven/extended; calls=[$(tr '\n' '|' < "$FAKE_CALLS")] ledger=[$(led 7)] log=[$(cat "$LOG")]"; return 1; }
  wreset; hins inner 'CTRL pause' 'ci-main-red'; ledger_add 7 "$P4" "$(iso_at $((NOW0-60)))" unledgered 0; ledger_pass
  [ "$(cnt 'run redrive' "$FAKE_CALLS")" = 0 ] && [ "$(cnt '^LEDGER-HELD-SKIP run=7 stage=inner cause="CTRL pause" train_hold="ci-main-red"$' "$LOG")" = 1 ] && [ -n "$(led 7)" ] || { wfail "H2 train_hold_reason row must be skipped; calls=[$(tr '\n' '|' < "$FAKE_CALLS")] log=[$(cat "$LOG")]"; return 1; }
  wreset; hins inner "rb-reprice-watch T2 10-20: MemAvailable_kb=11000000<12582912 threshold with 2 inners at inner cap 10.5; owner rb; expires 2026-10-22T21:00:00Z" ''; ledger_add 7 "$P4" "$(iso_at $((NOW0-60)))" "rb-reprice-watch T2 10-20: x; owner rb; expires t" 0; ledger_pass
  [ "$(rdr)" = 1 ] && [ "$(cnt 'LEDGER-HELD-SKIP' "$LOG")" = 0 ] && [ -z "$(led 7)" ] || { wfail "H3 the watcher's own T2 cause (with 'threshold') must still release; calls=$(rdr) log=[$(cat "$LOG")]"; return 1; }
  wreset; hins inner 'ctrl pause: threshold crossed, holder gone, withheld' ''; ledger_add 7 "$P4" "$(iso_at $((NOW0-60)))" unledgered 0; ledger_pass
  [ "$(rdr)" = 1 ] && [ "$(cnt 'LEDGER-HELD-SKIP' "$LOG")" = 0 ] || { wfail "H3b a non-watcher cause with threshold/holder/withheld must not be HELD; calls=$(rdr) log=[$(cat "$LOG")]"; return 1; }
  wreset; hins gate 'hand: HELD for review' ''; ledger_add 7 "$P4" "$(iso_at $((NOW0-60)))" unledgered 0; ledger_pass
  [ "$(cnt 'run redrive' "$FAKE_CALLS")" = 0 ] && [ "$(cnt 'LEDGER-HELD-SKIP run=7 stage=gate' "$LOG")" = 1 ] || { wfail "H4 the word HELD (upper case, bounded) must hold; log=[$(cat "$LOG")]"; return 1; }
  wreset; hins inner 'CTRL pause' ''; ledger_add 7 "$P4" "$(iso_at $((NOW0-60)))" unledgered 0; ledger_pass
  [ "$(rdr)" = 1 ] && [ "$(cnt 'LEDGER-HELD-SKIP' "$LOG")" = 0 ] || { wfail "H5 an ordinary hand inner pause still releases on expiry; calls=$(rdr) log=[$(cat "$LOG")]"; return 1; }
  # SIGMA-DRIFT: the journal's newest release-mem row is compared, never obeyed
  jrm(){ printf '{"op":"release-mem","row":{"decision":"%s","sum_before_gb":%s,"parts":["hand-1:land:12.5","waiting:hand-2:land:12.5"],"run_id":7,"stage":"inner"},"table":"runs","ts":"%s"}\n' "$1" "$2" "$(date -u -d "@$3" +%Y-%m-%dT%H:%M:%S.123456789+00:00)" >> "$JOURNAL"; }
  wreset; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at) values(7,'s1',NULL,'inner','$P1')"; ledger_add 7 "$P1" "$(iso_at $((NOW0-60)))" c 0; jrm refuse 36.5 $((NOW0-100))   # V13: daemon journal says refuse (36.5) but the local Σ is 0: SIGMA-DRIFT logged, the LOCAL decision still grants
  ledger_pass; [ "$(rdr)" = 1 ] && grep -q '^SIGMA-DRIFT local=0 daemon=36.5 run=7 age=100s local_parts=\[none\] daemon_parts=\[hand-1:land:12.5,waiting:hand-2:land:12.5\]$' "$LOG" || { wfail "V13 drift line / local decision [$(cat "$LOG")] calls=$(rdr)"; return 1; }
  wreset; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at) values(7,'s1',NULL,'inner','$P1'),(8,'s2',NULL,'inner',NULL)"; ledger_add 7 "$P1" "$(iso_at $((NOW0-60)))" c 0; jrm admit 11.5 $((NOW0-100))   # V14: local Σ 11.5 == journal 11.5 -> no drift line
  ledger_pass; [ "$(rdr)" = 1 ] && ! grep -q 'SIGMA-DRIFT' "$LOG" || { wfail "V14 agreeing Σ must not log drift [$(cat "$LOG")]"; return 1; }
  wreset; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at) values(7,'s1',NULL,'inner','$P1')"; ledger_add 7 "$P1" "$(iso_at $((NOW0-60)))" c 0; jrm refuse 36.5 $((NOW0-100)); for _ in $(seq 1 40); do jl circuit-close $((NOW0-50)) none; done   # V17: the only release-mem row sits OUTSIDE the tail window (scaled to 300 bytes) -> bounded read, no drift line, rc 0 (the same journal with a wide window does log it)
  RW_JOURNAL_TAIL=300 ledger_pass; [ "$(rdr)" = 1 ] && ! grep -q 'SIGMA-DRIFT' "$LOG" || { wfail "V17a row outside the tail window must not be read [$(cat "$LOG")]"; return 1; }
  wreset >/dev/null; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at) values(7,'s1',NULL,'inner','$P1')"; ledger_add 7 "$P1" "$(iso_at $((NOW0-60)))" c 0; jrm refuse 36.5 $((NOW0-100)); for _ in $(seq 1 40); do jl circuit-close $((NOW0-50)) none; done
  RW_JOURNAL_TAIL=1000000 ledger_pass; grep -q '^SIGMA-DRIFT local=0 daemon=36.5' "$LOG" || { wfail "V17b the same journal with a wide window logs drift [$(cat "$LOG")]"; return 1; }
  wreset; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at) values(7,'s1',NULL,'inner','$P1')"; ledger_add 7 "$P1" "$(iso_at $((NOW0-60)))" c 0; jrm refuse 36.5 $((NOW0-7200))   # V15: a 2 h old journal row is not comparable -> silent
  ledger_pass; [ "$(rdr)" = 1 ] && ! grep -q 'SIGMA-DRIFT' "$LOG" || { wfail "V15 stale journal row must not log drift [$(cat "$LOG")]"; return 1; }
  # ---- RWH3: held-row follow-ups + the shared-lib premise gate (fake wm-decide records argv under $RWT; every write site goes through wp_gate && wp_emit_write) ----
  wreset; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at,paused_cause) values(7,'s1',NULL,'inner','$P4','hold: MemAvailable 11G, do not release'),(8,'s2',NULL,'inner','$P4','$CSG')"; ledger_add 7 "$P4" "$(iso_at $((NOW0+1000)))" unledgered 0; ledger_add 8 "$P4" "$(iso_at $((NOW0+3000)))" unledgered 0; EARLY_N=5
  ledger_pass   # (i) a HELD head row (oldest expiry) must not use the pass's one early attempt: the next eligible row is released
  [ "$(cnt 'run redrive' "$FAKE_CALLS")" = 1 ] && [ "$(cnt '^wm-build run redrive 8 --from inner$' "$FAKE_CALLS")" = 1 ] && [ "$(cnt '^LEDGER-HELD-SKIP run=7 stage=inner' "$LOG")" = 1 ] && [ "$(cnt '^RB-BELL PAUSE-RELEASED run=8 early premise-recovered$' "$LOG")" = 1 ] && [ -n "$(led 7)" ] && [ -z "$(led 8)" ] || { wfail "(i) held head row blocked the early release; calls=[$(tr '\n' '|' < "$FAKE_CALLS")] log=[$(cat "$LOG")]"; return 1; }
  wreset; hins land "$CH" ''; ledger_add 7 "$P4" "$(iso_at $((NOW0-60)))" unledgered 1; sqlite3 "$DB" "update circuits set state='open', resets_at='2026-10-22T23:00:00+00:00'; insert into alarms values(1,'circuit:quota',NULL)"; jl circuit-skip $((NOW0-60)) 2026-10-22T23:00:00+00:00
  ledger_pass   # (ii) a HELD row with the W1 circuit open and ext = EXT_MAX-1: rr_fail is never reached, the ext counter and expiry stay, no REDRIVE-DEFER
  [ "$(led 7 | cut -f3,5)" = "$(printf '%s\t1' "$(iso_at $((NOW0-60)))")" ] && [ "$(cnt '^LEDGER-HELD-SKIP run=7' "$LOG")" = 1 ] && [ "$(cnt 'LEDGER-EXTEND\|PAUSE-OVERDUE\|REDRIVE-DEFER' "$LOG")" = 0 ] && [ ! -s "$DEFERLOG" ] && [ ! -s "$FAKE_CALLS" ] || { wfail "(ii) held row touched rr_fail/circuit counters; ledger=[$(led 7)] log=[$(cat "$LOG")]"; return 1; }
  wreset; hins inner 'CTRL pause' ''; ledger_add 7 "$P4" "$(iso_at $((NOW0-60)))" unledgered 1; sqlite3 "$DB" "update circuits set state='open', resets_at='2026-10-22T23:00:00+00:00'; insert into alarms values(1,'circuit:quota',NULL)"; jl circuit-skip $((NOW0-60)) 2026-10-22T23:00:00+00:00
  ledger_pass   # (ii) control: the SAME circuit with a non-held row does move the counter (1 -> 2), so the fixture can see the difference
  [ "$(led 7 | cut -f5)" = 2 ] && [ "$(cnt '^LEDGER-EXTEND run=7 ext=2' "$LOG")" = 1 ] && [ ! -s "$FAKE_CALLS" ] || { wfail "(ii) control: an open circuit must extend a non-held row to ext=2; ledger=[$(led 7)] log=[$(cat "$LOG")]"; return 1; }
  wreset; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at,paused_cause) values(7,'s1',NULL,'inner','$P4','CTRL pause')"; ledger_add 7 "$P4" "$(iso_at $((NOW0-60)))" unledgered 0; ob0=$(cat "$WP_STATE"/outbox-*.jsonl 2>/dev/null | wc -l); sim_expire
  wpause 7 t; runs_to_1 t; revert t 2>/dev/null; release_run 7 "$P4" 0 0; release_run 7 "$P4" 0 1   # (iii) premise expired: no fleet write runs at ANY site and the fake decide records nothing
  [ ! -s "$FAKE_CALLS" ] && [ ! -s "$FAKE_DECIDE_REC" ] && [ "$(cat "$WP_STATE"/outbox-*.jsonl 2>/dev/null | wc -l)" = "$ob0" ] && [ "$(cnt '^WP-DISARMED' "$LOG")" = 5 ] || { wfail "(iii) expired premise: calls=[$(tr '\n' '|' < "$FAKE_CALLS")] decide=[$(cat "$FAKE_DECIDE_REC")] log=[$(cat "$LOG")]"; return 1; }
  wreset; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at,paused_cause) values(7,'s1',NULL,'inner','$P4','CTRL pause')"; rw_arm "$RWT/no-such-config.toml"
  wpause 7 t   # (v) E1: the premise cmd cannot read its config (rc 2 = UNKNOWN): still ARMED, the pause runs and exactly one decide record lands
  [ "$WP_VERDICT" = UNKNOWN ] && [ "$WP_ARMED" = 1 ] && [ "$(cnt '^wm-build run pause 7 ' "$FAKE_CALLS")" = 1 ] && [ "$(cnt '--target redbaron:7 ' "$FAKE_DECIDE_REC")" = 1 ] && [ "$(cnt '--via rb-reprice-watch --model none --kind guard' "$FAKE_DECIDE_REC")" = 1 ] && [ "$(cnt '--agent rb ' "$FAKE_DECIDE_REC")" = 1 ] || { wfail "(v) premise rc 2 must stay armed and write; verdict=$WP_VERDICT armed=$WP_ARMED calls=[$(tr '\n' '|' < "$FAKE_CALLS")] decide=[$(cat "$FAKE_DECIDE_REC")]"; return 1; }
  wreset; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at,paused_cause) values(7,'s1',NULL,'inner','$P4','CTRL pause')"; printf '[daemon]\nhost = "redbaron"\nmax_runs = 3\n\n[cargo_jobs.mem_caps_gb]\ninner = 10.5\n' > "$RWT/gone.toml"; rw_arm "$RWT/gone.toml"
  wpause 7 t   # (v-b) a premise that is really GONE (max_runs 3) blocks the write: rc 1 = GONE, nothing recorded
  [ "$WP_VERDICT" = GONE ] && [ "$WP_ARMED" = 0 ] && [ ! -s "$FAKE_CALLS" ] && [ ! -s "$FAKE_DECIDE_REC" ] || { wfail "(v-b) premise GONE must disarm; verdict=$WP_VERDICT calls=[$(tr '\n' '|' < "$FAKE_CALLS")]"; return 1; }
  wreset; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at) values(7,'s1',NULL,'inner','$P1')"; ledger_add 7 "$P1" "$(iso_at $((NOW0+600)))" c 0; sim_expire
  ledger_pass; nextpass; ledger_pass   # (vi) E2: gate down + 1 ledger row: one bell per ledger pass, status.json carries wp_disarmed_ledger=1
  [ "$(cnt '^RB-BELL WP-DISARMED-LEDGER-NONEMPTY n=1$' "$LOG")" = 2 ] && [ "$(jq -r .wp_disarmed_ledger "$STATUS")" = 1 ] && [ ! -s "$FAKE_CALLS" ] || { wfail "(vi) disarmed-with-ledger bell/status; log=[$(cat "$LOG")] status=[$(cat "$STATUS")]"; return 1; }
  wreset; sqlite3 "$DB" "insert into runs(id,slug,ended,stage,paused_at) values(7,'s1',NULL,'inner','$P1')"; ledger_add 7 "$P1" "$(iso_at $((NOW0+600)))" c 0
  ledger_pass   # (vi-b) armed: no bell, wp_disarmed_ledger=0
  [ "$(cnt 'WP-DISARMED-LEDGER-NONEMPTY' "$LOG")" = 0 ] && [ "$(jq -r .wp_disarmed_ledger "$STATUS")" = 0 ] || { wfail "(vi-b) armed gate must not bell; log=[$(cat "$LOG")]"; return 1; }
  sim_arm
  rm -rf "$t"; echo "W1 G1-G6 ok W2 E1-E9 E4b I1 X1 S1 ok W4 V1-V17 ok RWH H1-H5 ok RWH3 i ii iii v vi ok"; }
if [ "${1:-}" = "--circuit-gate" ]; then  # read-only W1 gate for wip-redrive.sh and the seat: prints "<ok|defer|unparsable> last_op=.. resets=.. why=..", exit 0 ok / 1 defer / 2 unparsable
  circuit_gate; rc=$?; echo "$CG_V last_op=$CG_OP resets=$CG_RESETS why=\"$CG_WHY\""; exit "$rc"; fi
if [ "${1:-}" = "--selftest" ]; then
  # RWH4: hermetic - no host path, env var or state.db is needed; the lib falls back to the one next to this script when $HOME has none
  if [ ! -r "$WP_LIB" ]; then WP_LIB=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/watcher-premise.sh; [ -r "$WP_LIB" ] && . "$WP_LIB"; fi
  [ -r "$WP_LIB" ] || { echo "SELFTEST FAIL RWH3 shared lib not readable: $WP_LIB"; exit 1; }
  RWT=$(mktemp -d) && [ -d "$RWT" ] || { echo "SELFTEST FAIL RWH3 mktemp"; exit 1; }   # RWH3: the lib's state, log and the fake wm-decide all live under this root; sim_arm / sim_expire re-arm the gate against a fixed premise file
  # RWH4: DB / EV / CONF / LOG point at synthetic fixtures under $RWT (real schema: steps(kind, priced_peak_kb)); the 7.29 GiB inner row makes target() = 10.5 (7.29+3 -> 10.5)
  DB=$RWT/state.db; EV=$RWT/memory.events; CONF=$RWT/rb-reprice-watch.conf; LOG=$RWT/reprice-watch.log
  sqlite3 "$DB" "create table steps(id integer primary key, run_id integer, kind text, priced_peak_kb integer); insert into steps(run_id,kind,priced_peak_kb) values(1,'inner',7644528),(2,'gate',9999999)" || { echo "SELFTEST FAIL RWH4 fixture db"; exit 1; }
  printf 'low 0\nhigh 0\nmax 0\noom 0\n' > "$EV"; : > "$CONF"; load_conf
  export WP_STATE=$RWT/wp WP_LOG=$RWT/wp.log WP_GATE_TTL=30 WP_DECIDE_BIN=$RWT/decide.sh FAKE_DECIDE_REC=$RWT/decide.rec; : > "$FAKE_DECIDE_REC"; trap 'rm -rf -- "${RWT:?}"' EXIT
  printf '#!/bin/bash\necho "$*" >> "$FAKE_DECIDE_REC"\n' > "$WP_DECIDE_BIN"; chmod +x "$WP_DECIDE_BIN"
  printf '[daemon]\nhost = "redbaron"\nmax_runs = 2\n\n[cargo_jobs.mem_caps_gb]\ninner = 10.5\n' > "$RWT/premise.toml"
  sim_arm(){ rw_arm "$RWT/premise.toml"; }; sim_expire(){ rw_arm "$RWT/premise.toml" "2020-01-01 00:00:00"; }; sim_arm
  # 12:22 PM case: swap 2.4 G, MemAvailable 19 G, PSI full avg60 1.6 -> NO pause (swap is not an input any more)
  [ -z "$(mem_bad 19230476 1.63)" ] && [ -z "$(mem_bad 12582912 10)" ] && [ -n "$(mem_bad 12000000 0)" ] && [ -n "$(mem_bad 20000000 10.5)" ] \
    && [ -n "$(ev max)" ] && [ "$(echo 7.29 | awk '{v=$1+3; printf "%.1f", (int(v*2)+(v*2>int(v*2)))/2}')" = "10.5" ] \
    && [ "$(echo 8.0 | awk '{v=$1+3; printf "%.1f", (int(v*2)+(v*2>int(v*2)))/2}')" = "11.0" ] && [ "$(target)" = "10.5" ] \
    || { echo "SELFTEST FAIL (trigger arithmetic)"; exit 1; }
  # CTRL 9:2x: 1 land + 2 gates (all units named wm-build-inner<id>-a, all active) = ZERO inners; + 1 inner = that inner only
  t=$(mktemp -d); sqlite3 "$t/s.db" "create table runs(id integer, stage text, outcome text, driver_unit text); insert into runs values (1012,'land',null,'wm-build-inner1012-a'),(1014,'gate',null,'wm-build-inner1014-a'),(1015,'gate',null,'wm-build-inner1015-a')"
  z=$(RW_ALL_ACTIVE=1 live_inners "$t/s.db" | grep -c .); sqlite3 "$t/s.db" "insert into runs values (1020,'inner',null,'wm-build-inner1020-a'),(1021,'inner','done','wm-build-inner1021-a')"
  one=$(RW_ALL_ACTIVE=1 live_inners "$t/s.db" | tr '\n' ' '); rm -rf "$t"
  # TODO 2026-10-29: drop the t4_lowered_from read (the T4LF-FALLBACK line in t4r_load), this check, and the back-compat note in the header (the live run-1037 state file uses the old key until then)
  todo_check(){ [ "$1" \> 2026-10-29 ] && grep -q '# T4LF-FALLBACK$' "${BASH_SOURCE[0]}" && return 1; return 0; }
  todo_check 2026-10-29 && ! todo_check 2026-10-30 || { echo "SELFTEST FAIL TODO check is not live (fallback marker missing or date logic wrong)"; exit 1; }
  todo_check "${RW_TODAY:-$(date +%F)}" || { echo "SELFTEST FAIL TODO 2026-10-29: drop the t4_lowered_from read (T4LF-FALLBACK in t4r_load)"; exit 1; }
  t4r=$(t4_selftest) || { echo "$t4r"; exit 1; }
  t4rr=$(t4r_selftest) || { echo "$t4rr"; exit 1; }
  ww=$(w_selftest) || { echo "$ww"; exit 1; }
  tn=$(target); rm -rf -- "${RWT:?}"   # RWH4: target_now is read before the fixture root goes
  [ "$z" = 0 ] && [ "$one" = "1020 " ] && echo "SELFTEST PASS target_now=$tn land+2gates->inners=0 +inner->[$one] $t4r $t4rr $ww" || { echo "SELFTEST FAIL inners: land+2gates=$z +inner=[$one]"; exit 1; }; exit 0; fi
STEP0=$(sqlite3 "$DB" "select max(id) from steps"); MAX0=$(ev max); OOM0=$(ev oom_kill)
DISARM_SEEN=; rw_arm "$CONFIG"   # RWH3: the premise is read from the real config.toml (local file only)
load_conf; log "ARMED avail_min_kb=$MEM_AVAIL_MIN_KB psi_full60_max=$PSI_FULL_AVG60_MAX io_full60_max=$IO_FULL_AVG60_MAX t4_passes=$(t4_need) step0=$STEP0 max0=$MAX0 oom_kill0=$OOM0"
t4r_load   # restore a persisted T4R watch after a restart (stale -> deleted); the --selftest path exits before this line
while :; do
  hi=$(sqlite3 -separator ' ' "$DB" "select run_id, priced_peak_kb from steps where id>$STEP0 and priced_peak_kb > 7864320 limit 1")
  if expired; then  # RWH3: wp_gate down (premise GONE, past EXPIRES, no lib): no trigger is evaluated, no fleet write runs; the ledger pass keeps status.json and the E2 bell alive
    [ -z "$T4R_RUN" ] || t4r_note_expired
    [ "$DISARM_SEEN" = "${WP_VERDICT:-}/${WP_DEFECT:-}" ] || { log "PREMISE DISARMED (verdict=${WP_VERDICT:-none} defect=${WP_DEFECT:--} expires=$EXPIRES): fleet writes disarmed, watcher idle; re-arm = new PREMISE/EXPIRES + DECISION row"; DISARM_SEEN="${WP_VERDICT:-}/${WP_DEFECT:-}"; }
    ledger_pass; status_write; if [ "${WP_DEFECT:-}" = expired ]; then sleep 3600; else sleep 60; fi; continue; fi
  DISARM_SEEN=
  [ -n "$hi" ] && { revert "T1 priced_peak_kb>7.5GiB run/kb=$hi"; STEP0=$(sqlite3 "$DB" "select max(id) from steps"); log "T1 re-armed step0=$STEP0"; }
  if [ "$(ev max)" != "$MAX0" ] || [ "$(ev oom_kill)" != "$OOM0" ]; then revert "T3 app.slice memory.events max $MAX0->$(ev max) oom_kill $OOM0->$(ev oom_kill) (five-whys due)"; exit 0; fi
  # 9:22 AM 10-20: EVERY run's driver unit is named wm-build-inner<id>-a whatever its stage, so the unit glob counted a land + 2 gates
  # as 3 inners and paused gate 1015 at 9:21 on residual swap -> count only stage='inner' runs whose driver unit is active.
  live=$(live_inners "$DB")
  ledger_pass   # W2/W3: self-throttled to one pass per PAUSE_PASS_S (240 s); also writes status.json
  if t2_fire "$live"; then sleep "$SLEEP"; continue; fi   # T2 armed T4R; the next pass starts the recovery count
  load_conf   # IO_FULL_AVG60_MAX / IO_RECOVER_AVG60_MAX re-read every loop
  if [ -n "$T4R_RUN" ]; then t4r_step "$(nlive "$live")"   # T4R: recovering, T4's own fire check is not evaluated
  else t4_fire "$live"; fi
  sleep "$SLEEP"
done
