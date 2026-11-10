#!/bin/bash
# r7-cargo-slot.sh v3 — the ONLY way hand cargo runs on ryzen7 (CTRL 12:5x PM 10-21; v2 = daemon acquire 3bae; v3 adds the bwrap sandbox, CTRL 1:16 PM).
# PREMISE: (a) the daemon's own memory gate (`wm-build builder cargo-jobs acquire`, .59 § MG) is the one source of truth for hand admission;
#   (b) hand test binaries can delete or write anywhere the uid can, so they run inside bwrap with / read-only and rw binds only on the clone,
#   the cargo target dir, a PRIVATE cargo home and one self-created scratch dir (lib: ~/.local/lib/hand-sandbox.sh, Fable F1-F4 10-21).
# EXPIRES: when rb's cargo-slot.sh is ported here (this file then execs it) or 2026-11-18, whichever first. Decision rows: 3bae (gate), guard row 10-21 1:3x PM (sandbox).
# usage: r7-cargo-slot.sh [--cap-gb N] [--wait-s S] -- cargo <args>   (exit 75 = refused by the gate, 77 = sandbox refused, 2 = usage)
#        r7-cargo-slot.sh --selftest | --check
#        r7-cargo-slot.sh --run-confined [--rw PATH]... -- <exe> [args...]   (run an ALREADY-BUILT exe in a systemd user unit with no bwrap, so nested userns works; exit = the exe's rc, 75 = gate refused, 77 = unit did not start / no rc file, 2 = usage)
# PRECHECK-1021 (CTRL 2:05 PM 10-21): default class is INNER (rank 0), never land. Prefix from the top dir name: mcphost* → --prefix mcphost- (inner 11.5 G),
#   synthorg* → --prefix synthorg- (inner 6.0 G); both caps are READ from [cargo_jobs.mem_caps_gb.<prefix>.<class>] in the config (hardcoded fallback only if that key is missing:
#   inner 11.5 / hand 5). wm-build* tops stay class hand, no prefix. The scope MemoryMax = that cap rounded UP to whole G (mcphost 12, synthorg 6); --cap-gb still overrides the scope only.
# PRE-CHECK before the acquire: live Σ (caps of the NON-`waiting:` holders) + own cap > mem_budget_gb → stderr `would-not-admit: live Σ=X cap=Y budget=Z holders=[id:class:cap,…]`,
#   an END row (rc=75 + that text) in slot.log, exit 75, no acquire. Waiters are never counted (two hand jobs would refuse each other forever). The daemon acquire stays the source of truth;
#   a pre-check that cannot run (journal/python error) warns and falls through to it.
# live holders: fallback = newest journal cargo-admission row parts, no daemon list subcommand with class/cap on 0.77.85 (the journal tail is read with `tail -c 4000000`, never a full grep).
#   `cargo-jobs list` (id/run/pid/alive only, no caps) is used for two things: drop parts whose run is no longer alive, and add the row's OWN granted run (parts = holders BEFORE that grant).
# selftest/dry-run env (documented here, names ours): R7_SLOT_FAKE_PARTS='["483:inner:11.5","waiting:hand-1:land:12.5"]' (JSON list of cargo-admission parts) and R7_SLOT_FAKE_BUDGET=22 replace the journal/config budget.
# --wait-s is rounded UP to whole --wait-minutes (450 s → 8 min)
# --run-confined (A1542): AppArmor's bwrap-userns-restrict profile denies the nested uid_map inside the bwrap sandbox, so a test that creates a user namespace (mcphost) cannot run in the slot.
#   This mode runs the built binary (build it first with `-- cargo test --no-run`) via `systemd-run --user --wait --pipe --quiet --collect` with ProtectSystem=strict, ProtectHome=read-only, PrivateTmp, NoNewPrivileges;
#   rw only on /mnt/ssd/cargo-target, /mnt/ssd/r7-legs, ~/.cache/mcphost-dev (each if it exists) and every --rw PATH; env TMPDIR=/tmp UV_CACHE_DIR=/tmp/uvc LC_ALL=C (+ CARGO_MANIFEST_DIR when set). The exe's rc travels in an rc file
#   (runt() in /mnt/ssd/r7-legs/gate562i-fff.sh, mcphost#562). The pre-check memory gate fronts it (refusal = 75); it takes no daemon acquire and no scope, the exe is not memory-capped.
# Order (Fable 6): acquire → systemd scope (MemoryMax = cap, the 2 G tmpfs is charged to it) → host-side `cargo fetch` with the REAL cargo home
#   (downloads only, no build script runs) → bwrap → cargo. Never an unsandboxed fallback.
set -u
usage() { echo "usage: r7-cargo-slot.sh [--cap-gb N] [--wait-s S] -- cargo <args> | --selftest | --check | --run-confined [--rw PATH]... -- <exe> [args...]  (--run-confined = userns-capable run, no bwrap)" >&2; }
CONFINED=0; for a in "$@"; do [ "$a" = -- ] && break; [ "$a" = --run-confined ] && CONFINED=1; done   # the confined mode uses neither the bwrap lib nor the placement lib
LIB=/home/jsy/.local/lib/hand-sandbox.sh; [ "$CONFINED" = 1 ] || . "$LIB" || { echo "r7-cargo-slot: sandbox lib missing ($LIB); refusing" >&2; exit 77; }
PLACE=$(dirname "$(readlink -f "$0")")/../lib/r7-cargo-place.sh; [ -r "$PLACE" ] || PLACE=/home/jsy/.local/lib/r7-cargo-place.sh   # A681 root-device guard (shared with the cargo shim)
[ "$CONFINED" = 1 ] || . "$PLACE" || { echo "r7-cargo-slot: placement lib missing ($PLACE); refusing" >&2; exit 77; }
LOGD=/home/jsy/.local/state/r7-cargo-slot; mkdir -p "$LOGD"; LOG=$LOGD/slot.log
REAL_CARGO=${R7_SLOT_REAL_CARGO:-/home/jsy/.cargo}
export RUSTUP_HOME=${RUSTUP_HOME:-/home/jsy/.rustup}
availg() { awk '/MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo; }
mk_cargo_home() { # private, per-tree cargo home: index/cache/bin shared read-only through symlinks, config copied, lock + local files rw
  local h=$1 d; mkdir -p "$h" || return 1
  for d in registry git bin; do [ -e "$h/$d" ] || ln -s "$REAL_CARGO/$d" "$h/$d"; done
  [ -f "$REAL_CARGO/config.toml" ] && [ ! -f "$h/config.toml" ] && cp "$REAL_CARGO/config.toml" "$h/config.toml"
  : > "$h/.r7-private-cargo-home"
}
if [ "${1:-}" = --__inner ]; then  # runs inside the acquired slot + scope; env R7I_* set by the parent
  shift
  command -v sccache >/dev/null 2>&1 && { sccache --start-server >/dev/null 2>&1 || true; }   # the server lives on the host and owns the cache dir
  ( cd "$R7I_TOP" && CARGO_HOME=$REAL_CARGO cargo fetch >>"$R7I_SCR/fetch.log" 2>&1 ) || echo "r7-cargo-slot: cargo fetch rc=$? (continuing; see $R7I_SCR/fetch.log)" >&2
  RW=("$R7I_TOP" "$R7I_TGT" "$R7I_CH" "$R7I_SCR"); [ -n "${R7I_JOBHOME:-}" ] && RW+=("$R7I_JOBHOME")
  sandbox_exec --tmpfs-gb "${R7_SLOT_TMPFS_GB:-2}" "${RW[@]}" -- env CARGO_HOME="$R7I_CH" CARGO_TARGET_DIR="$R7I_TGT" SLOT_RESULTS_DIR="$R7I_SCR" "$@"; exit $?   # not exec: sandbox_exec is a lib FUNCTION (exec: not found rc 127, #373 verifier 14:02 10-21)
fi
CFG=${R7_SLOT_CONFIG:-/home/jsy/.config/wm-build/config.toml}
WM=${R7_SLOT_WMBUILD:-/home/jsy/.cargo/bin/wm-build}
CAP=""; WAIT_S=480; MODE=run; DD=0; RWX=(); RUNN=0
while [ $# -gt 0 ]; do case "$1" in
  --run-confined) MODE=confined; shift;;
  --rw) [ $# -ge 2 ] || { echo "r7-cargo-slot: --rw needs a PATH" >&2; usage; exit 2; }; RWX+=("$2"); shift 2;;
  --cap-gb) CAP=$2; shift 2;; --wait-s) WAIT_S=$2; shift 2;; --check) MODE=check; shift;; --selftest) MODE=selftest; shift;;
  --) DD=1; shift; break;; *) echo "r7-cargo-slot: unknown flag $1" >&2; exit 2;; esac; done
[ "$MODE" = confined ] || [ ${#RWX[@]} -eq 0 ] || { echo "r7-cargo-slot: --rw is only valid with --run-confined" >&2; usage; exit 2; }
[ "$MODE" != confined ] || { [ "$DD" = 1 ] && [ $# -gt 0 ]; } || { echo "r7-cargo-slot: --run-confined needs -- <exe> [args...]" >&2; usage; exit 2; }
TOP=$(realpath -e "$(git rev-parse --show-toplevel 2>/dev/null || pwd)") || exit 77
CLS=inner; PFX=""; case "$(basename "$TOP")" in wm-build*) CLS=hand;; mcphost*) PFX=mcphost-;; synthorg*) PFX=synthorg-;; esac
# A566 (r7 11-02): a clone whose dir name matches none of the above is classed by its origin URL, then its Cargo.toml package name, so a renamed wm-build clone stays class hand.
if [ "$CLS" = inner ] && [ -z "$PFX" ]; then ID="$(git -C "$TOP" remote get-url origin 2>/dev/null) $(sed -n '/^\[package\]/,/^\[/s/^name *= *"\([^"]*\)".*/\1/p' "$TOP/Cargo.toml" 2>/dev/null | head -n 1)"
  case "$ID" in *wm-build*) CLS=hand;; *mcphost*) PFX=mcphost-;; *synthorg*) PFX=synthorg-;; esac; fi
slotcalc() { # $1 = cap (print own class cap) | verdict (print admit|refuse, then the message); $2 class, $3 prefix
  python3 -I - "$CFG" "$1" "$2" "$3" "$WM" <<'PY'
import sys,os,json,tomllib,subprocess
sys.stdout.reconfigure(encoding="utf-8")
cfg,mode,cls,pfx,wm=sys.argv[1:6]
c=tomllib.load(open(cfg,"rb")).get("cargo_jobs",{}); caps=c.get("mem_caps_gb",{})
p=pfx.rstrip("-"); own=None
if p and isinstance(caps.get(p),dict): own=caps[p].get(cls)
if own is None and not isinstance(caps.get(cls),dict): own=caps.get(cls)
if own is None: own=11.5 if cls=="inner" else 5.0   # hardcoded fallback: config key cargo_jobs.mem_caps_gb.<prefix>.<class> not found
own=float(own)
if mode=="cap": print(own); sys.exit(0)
budget=float(os.environ.get("R7_SLOT_FAKE_BUDGET") or c.get("mem_budget_gb") or 22)
fake=os.environ.get("R7_SLOT_FAKE_PARTS")
if fake is not None: parts=json.loads(fake)
else:
    parts=[]
    last=None
    for ln in subprocess.run(["tail","-c","4000000","/home/jsy/.local/state/wm-build/journal.jsonl"],capture_output=True,text=True,errors="replace").stdout.splitlines():
        if '"cargo-admission"' in ln: last=ln
    if last is None: raise SystemExit("no cargo-admission row in the journal tail")
    row=json.loads(last)["row"]
    parts=list(row.get("parts") or [])
    if row.get("decision")=="grant" and row.get("run_id") and row.get("class"): parts.append("%s:%s:%s"%(row["run_id"],row["class"],row.get("cap_gb")))
    lo=subprocess.run([wm,"builder","cargo-jobs","list","--config",cfg,"--state-dir","/home/jsy/.local/state/wm-build"],capture_output=True,text=True,timeout=20)
    if lo.returncode==0:
        live={f[1] for f in (ln.split("\t") for ln in lo.stdout.splitlines()[1:]) if len(f)>4 and f[4]=="yes"}
        parts=[x for x in parts if x.startswith("waiting:") or x.split(":")[0] in live]
best={}   # one entry per run at its largest cap, the daemon's own Σ fold (sigma_parts); a grant row's parts already hold the granted run when it re-acquires (r7 c2b1 11-09: 542 counted twice)
for x in parts:
    if x.startswith("waiting:"): continue
    f=x.split(":")
    try: g=float(f[2])
    except (IndexError,ValueError): continue
    if f[0] not in best or g>best[f[0]][0]: best[f[0]]=(g,":".join(f[:3]))
tot=sum(g for g,_ in best.values()); hs=[h for _,h in best.values()]
if tot+own>budget+1e-9:
    print("refuse"); print("would-not-admit: live Σ=%.1f cap=%.1f budget=%g holders=[%s]"%(tot,own,budget,",".join(hs)))
else:
    print("admit"); print("would-admit: live Σ=%.1f cap=%.1f"%(tot,own))
PY
}
precheck() { # $1 = slot.log for the END row on refusal; sets PCV (admit|refuse|error) + PCM; returns 75 on refuse
  { IFS= read -r PCV; IFS= read -r PCM; } < <(slotcalc verdict "$CLS" "$PFX" 2>/dev/null)
  [ "$PCV" = refuse ] || [ "$PCV" = admit ] || { PCV=error; PCM="pre-check unavailable (journal/python error); daemon acquire decides"; }
  [ "$PCV" = refuse ] || return 0
  echo "$PCM" >&2; echo "$(date -Is) END pid=$$ rc=75 class=$CLS $PCM" >> "$1"; return 75
}
selftest_precheck() { # exit-75 path + pass-through, driven by the FAKE env; own tempdir, no real acquire, no holders, no config writes
  local D rc SC=$CLS SP=$PFX fail=0
  D=$(mktemp -d /home/jsy/hand/.slot-selftest.XXXX) || { echo "SELFTEST FAIL: mktemp"; return 1; }
  CLS=inner; export R7_SLOT_FAKE_PARTS='["483:inner:11.5","waiting:hand-1:land:12.5"]' R7_SLOT_FAKE_BUDGET=22
  PFX=mcphost-; precheck "$D/slot.log" 2>"$D/err"; rc=$?
  if [ $rc = 75 ] && grep -qxE 'would-not-admit: live Σ=11\.5 cap=[0-9]+(\.[0-9]+)? budget=22 holders=\[483:inner:11\.5\]' "$D/err" && grep -q ' END pid=[0-9]* rc=75 class=inner would-not-admit' "$D/slot.log"
  then echo "PASS precheck inner mcphost: exit 75, $(cat "$D/err")"; else echo "FAIL precheck inner mcphost rc=$rc err=$(cat "$D/err")"; fail=1; fi
  PFX=synthorg-; precheck "$D/slot.log" 2>"$D/err"; rc=$?
  if [ $rc = 0 ] && [[ $PCM =~ ^would-admit:\ live\ Σ=11\.5\ cap=[0-9]+(\.[0-9]+)?$ ]] && [ ! -s "$D/err" ] && [ "$(wc -l < "$D/slot.log")" = 1 ]   # cap = the live config class cap, not a literal (ryzen7 synthorg- is 7.6)
  then echo "PASS precheck inner synthorg: pass-through (stops before any acquire), $PCM"; else echo "FAIL precheck inner synthorg rc=$rc PCM=$PCM"; fail=1; fi
  export R7_SLOT_FAKE_PARTS='["542:inner:12.5","542:inner:12.5"]'   # c2b1: one run listed twice counts once
  PFX=synthorg-; precheck "$D/slot.log" 2>"$D/err"; rc=$?
  if [ $rc = 0 ] && [[ $PCM =~ ^would-admit:\ live\ Σ=12\.5\ cap=[0-9]+(\.[0-9]+)?$ ]]
  then echo "PASS precheck one run twice counts once: $PCM"; else echo "FAIL precheck one run twice rc=$rc PCM=$PCM"; fail=1; fi
  unset R7_SLOT_FAKE_PARTS R7_SLOT_FAKE_BUDGET; CLS=$SC; PFX=$SP
  case $D in /home/jsy/hand/.slot-selftest.????*) rm -rf -- "$D";; esac
  return $fail
}
run_confined() { # $1 = exe, rest = its args; gate first, then a transient user unit (no bwrap: nested userns works); the exe's rc comes back through an rc file
  local exe n=$((++RUNN)) rcd rc="" p unit; local -a rwa=()
  exe=$(command -v -- "$1" 2>/dev/null) && [ -f "$exe" ] && [ -x "$exe" ] || { echo "r7-cargo-slot: --run-confined: no such executable: $1" >&2; usage; return 2; }
  shift; exe=$(realpath -e "$exe") || return 2
  precheck "$LOG" || return 75; [ "$PCV" = error ] && echo "r7-cargo-slot: $PCM" >&2
  for p in /mnt/ssd/cargo-target /mnt/ssd/r7-legs "$HOME/.cache/mcphost-dev"; do [ -d "$p" ] && rwa+=(-p "ReadWritePaths=$p"); done
  for p in "${RWX[@]}"; do rwa+=(-p "ReadWritePaths=$(realpath -m -- "$p")"); done
  rcd=$(mktemp -d "$LOGD/rc.XXXXXX") || return 77; rwa+=(-p "ReadWritePaths=$rcd"); unit=r7-slotrun-$$-$n
  systemd-run --user --wait --pipe --quiet --collect --unit "$unit" -E TMPDIR=/tmp -E UV_CACHE_DIR=/tmp/uvc -E LC_ALL=C ${CARGO_MANIFEST_DIR:+-E "CARGO_MANIFEST_DIR=$CARGO_MANIFEST_DIR"} -E "RCF=$rcd/rc" \
    -p ProtectSystem=strict -p ProtectHome=read-only -p PrivateTmp=yes -p NoNewPrivileges=yes "${rwa[@]}" \
    /bin/bash -c '"$@"; echo $? > "$RCF"' runt "$exe" "$@"
  [ -s "$rcd/rc" ] && rc=$(cat "$rcd/rc")
  case $rcd in "$LOGD"/rc.??????) rm -rf -- "$rcd";; esac
  echo "$(date -Is) RUNCONF pid=$$ unit=$unit rc=${rc:-missing} exe=$exe" >> "$LOG"
  case $rc in ''|*[!0-9]*) echo "r7-cargo-slot: --run-confined: unit $unit gave no rc file (did not start?)" >&2; return 77;; esac
  return "$rc"
}
selftest_confined() { # needs a reachable user manager; each case PASS/FAIL; own env drives the gate (FAKE parts) so a busy fleet cannot flake it
  local st D P rc fail=0 S=$0
  st=$(systemctl --user is-system-running 2>/dev/null)
  case $st in running|degraded) ;; *) echo "SKIP confined: no user manager (is-system-running=${st:-none})"; return 0;; esac
  export R7_SLOT_FAKE_PARTS='[]' R7_SLOT_FAKE_BUDGET=22
  "$S" --run-confined -- /bin/sh -c 'exit 3' 2>/dev/null; rc=$?
  if [ $rc = 3 ]; then echo "PASS confined (a) exit code 3 carried"; else echo "FAIL confined (a) rc=$rc want 3"; fail=1; fi
  P=$HOME/slotrun-probe-$$
  "$S" --run-confined -- /bin/sh -c 'echo x > "$1"' sh "$P" 2>/dev/null; rc=$?
  if [ $rc != 0 ] && [ ! -e "$P" ]; then echo "PASS confined (b) write to \$HOME refused, no file"; else echo "FAIL confined (b) rc=$rc exists=$([ -e "$P" ] && echo yes || echo no)"; rm -f -- "$P"; fail=1; fi
  mkdir -p "$HOME/.cache"; D=$(mktemp -d "$HOME/.cache/slotrun-selftest.XXXXXX")
  "$S" --run-confined --rw "$D" -- /bin/sh -c 'echo x > "$1/f"' sh "$D" 2>/dev/null; rc=$?
  if [ $rc = 0 ] && [ -f "$D/f" ]; then echo "PASS confined (c) --rw dir writable"; else echo "FAIL confined (c) rc=$rc"; fail=1; fi
  case $D in "$HOME"/.cache/slotrun-selftest.??????) rm -rf -- "$D";; esac
  if command -v unshare >/dev/null 2>&1; then
    "$S" --run-confined -- unshare -Ur true 2>/dev/null; rc=$?
    if [ $rc = 0 ]; then echo "PASS confined (d) nested userns (unshare -Ur)"; else echo "FAIL confined (d) unshare -Ur rc=$rc"; fail=1; fi
  else echo "SKIP confined (d): no unshare"; fi
  unset R7_SLOT_FAKE_PARTS R7_SLOT_FAKE_BUDGET
  return $fail
}
# --cap-gb sets ONLY the scope MemoryMax/High; the daemon prices its config class cap (CTRL 1:38 PM 10-21: no per-call cap overrides; the mem_caps_gb override key is unknown on 0.77.85 anyway)
[ -n "$CAP" ] || CAP=$(slotcalc cap "$CLS" "$PFX" | awk '{printf "%d", ($1==int($1)) ? $1 : int($1)+1}'); [ -n "$CAP" ] || CAP=$([ "$CLS" = hand ] && echo 5 || echo 12)
HIGH=$((CAP - 2)); [ "$HIGH" -lt 1 ] && HIGH=1
WAIT_MIN=$(( (WAIT_S + 59) / 60 )); [ "$WAIT_MIN" -lt 1 ] && WAIT_MIN=1
case "$MODE" in
  selftest) "$WM" builder cargo-jobs selftest 2>&1 | tail -2; selftest_precheck || exit 1; sandbox_selftest || exit 1; selftest_confined || exit 1; echo "SELFTEST v3: class=$CLS cap=${CAP}G high=${HIGH}G wait=${WAIT_MIN}m avail=$(availg)G lib=$(sha256sum "$LIB" | cut -c1-8)"; exit 0;;
  confined) run_confined "$@"; exit $?;;
  check) "$WM" builder cargo-jobs list 2>&1 | tail -5; precheck /dev/null 2>/dev/null; echo "PRECHECK: $PCV: $PCM"; echo "CHECK v3: class=$CLS cap=${CAP}G avail=$(availg)G top=$TOP (grant decided by the daemon acquire; sandbox lib $(sha256sum "$LIB" | cut -c1-8))"; exit 0;;
esac
[ $# -gt 0 ] || { echo "r7-cargo-slot: no command after --" >&2; exit 2; }
[ "$1" = cargo ] || [ "$(basename "$1")" = cargo ] || { echo "r7-cargo-slot: only cargo commands (got $1)" >&2; exit 2; }
precheck "$LOG" || exit 75; [ "$PCV" = error ] && echo "r7-cargo-slot: $PCM" >&2
[ -n "${CARGO_TARGET_DIR:-}" ] || export CARGO_TARGET_DIR=/mnt/ssd/cargo-target/hand-$(basename "$TOP")  # /mnt/ssd itself is root-owned; cargo-target is jsy
r7_cargo_place "$TOP" || exit $?   # A681: a target on the root device moves to /mnt/ssd/cargo-target/hand-<top>; ssd unmounted = exit 75
mkdir -p "$CARGO_TARGET_DIR" || exit 77; TGT=$(realpath -e "$CARGO_TARGET_DIR") || exit 77
CH=/home/jsy/.cargo-hand/$(basename "$TOP"); mk_cargo_home "$CH" || { echo "r7-cargo-slot: cannot make private cargo home $CH" >&2; exit 77; }
SCRROOT=${R7_SLOT_SCRATCH:-/home/jsy/hand/.slot-scratch}; mkdir -p "$SCRROOT" || exit 77
SCR=$(mktemp -d "$SCRROOT/$(basename "$TOP").XXXX") || exit 77
JOBHOME=""; case "$HOME" in /home/jsy/hand/?*) JOBHOME=$(realpath -e "$HOME") || exit 77;; /home/jsy) ;; *) echo "r7-cargo-slot: HOME=$HOME is neither /home/jsy nor under /home/jsy/hand/<job>/ (F1)" >&2; exit 77;; esac
echo "$(date -Is) ACQ pid=$$ class=$CLS cap=${CAP}G wait=${WAIT_MIN}m avail=$(availg)G top=$TOP tgt=$TGT scratch=$SCR jobhome=${JOBHOME:--} cmd=$*" >> "$LOG"
R7I_TOP=$TOP R7I_TGT=$TGT R7I_CH=$CH R7I_SCR=$SCR R7I_JOBHOME=$JOBHOME \
"$WM" builder cargo-jobs acquire --class "$CLS" ${PFX:+--prefix "$PFX"} --producer cargo-slot --config "$CFG" --state-dir /home/jsy/.local/state/wm-build --wait-minutes "$WAIT_MIN" -- \
  systemd-run --user --scope --slice=app.slice --quiet -p MemoryHigh=${HIGH}G -p MemoryMax=${CAP}G nice -n 10 ionice -c2 -n7 "$0" --__inner "$@"
rc=$?
[ "$rc" = 75 ] && echo "$(date -Is) REFUSE pid=$$ class=$CLS cap=${CAP}G avail=$(availg)G (acquire 75)" >> "$LOG" || echo "$(date -Is) END pid=$$ rc=$rc avail=$(availg)G scratch=$SCR" >> "$LOG"
exit "$rc"
