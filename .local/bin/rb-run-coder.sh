#!/usr/bin/env bash
# rb-run-coder.sh <name> <prompt-file> [--no-cargo]: one sonnet `claude -p` coder turn for the rb seat, under a systemd-run unit
# (premise + expiry in the unit Description/RuntimeMaxSec). Rings the seat when the turn ends.
# Tracked in dotfiles (j0yen/dotfiles .local/bin, tests/rb-spawn-hold.test.sh); ~/.cache/rb-seat/coders/run-coder.sh is a symlink to it.
# --no-cargo (3rd positional or anywhere): exempt this spawn from the rb-spawn-hold gate; only for prompts that run no cargo on redbaron.
# gates, in order (exit): model 78, host 79 (redbaron|ryzen7 only), empty-prompt 74, pair-lint 77 (wm-decide record with --target AND --pr; .local/lib/rb-prompt-lint.sh),
# spawn-hold 76, spec-lint 73, STEP 0 75, fable-verdict 80 (78 is the model gate), room 78 (carbon-room.sh <need-MB>, CLAUDE.md § Hosts ROOM; shares exit 78 with the model gate, told apart by the REFUSED text),
# memcap 71 (rb-coder-memcap.sh caps this coder's own unit; runs last, just before `claude -p`).
# env: RB_ROOM_BIN (default ~/.local/bin/carbon-room.sh), RB_ROOM_PEAK_MB (the coder's peak in MB; skips the journal read), RB_MEMCAP_BIN (default ~/.local/bin/rb-coder-memcap.sh).
# fable-verdict 80 (ctl b209 10-23 9:50 PM; sqw5's verdict row d-20261023-224235-rb-cdf6 was filed after the spawn): every cited *.spec.md must be
# covered, BY SHA256 OF ITS BYTES, by the newest decisions row carrying `sha256:<hex>` in its evidence, which must be kind=verdict, model fable, final
# verdict AGREE|AGREE-WITH-EDITS (.local/lib/rb-fable-gate.py); a prompt citing no spec needs a `Hatch: d-<id>` NO-SPEC-SPAWN decision row. This gate
# checks the row; the 30-min Fable regrader checks the row's provenance (evidence names the Fable spawn: agent/task id or transcript path:line).
# rules-lint 72 (prompt lacks the kill-by-pid or LIVE CLONES rule; rb_prompt_rules_lint) runs with the spawn gates.
# env: RB_CODER_MODEL = sonnet (default, medium effort) | opus (high effort: ambiguous multi-file refactor, architecture, or a sonnet coder's ESCALATE: opus; anything else exits 78).
# env: RB_SPAWN_HOLD_BIN (default ~/.local/bin/rb-spawn-hold.sh), RB_SPAWN_HOLD_EXTRA (extra args for it; tests), RB_DECISIONS_DB (default
# ~/.local/state/swarm-decide/decisions-carbon.sqlite = carbon's ledger copied to RB every 10 min, opened read-only, refused when over 30 min old;
# RB's own decisions.sqlite is a stub with no seat rows (ctl 4bed); tests use a fixture).
set -uo pipefail
nocargo=0; args=(); for a in "$@"; do if [ "$a" = --no-cargo ]; then nocargo=1; else args+=("$a"); fi; done
n="${args[0]:?usage: rb-run-coder.sh <name> <prompt-file> [--no-cargo]}"; pf="${args[1]:?usage: rb-run-coder.sh <name> <prompt-file> [--no-cargo]}"; D="$HOME/.cache/rb-seat/coders"
model="${RB_CODER_MODEL:-sonnet}"; case "$model" in sonnet) effort=medium ;; opus) effort=high ;; *) echo "REFUSED model=$model (sonnet|opus)" >&2; exit 78 ;; esac
hold_bin="${RB_SPAWN_HOLD_BIN:-$HOME/.local/bin/rb-spawn-hold.sh}"; hold_extra="${RB_SPAWN_HOLD_EXTRA:-}"
# host gate (aide A25, rb row d-20261031-152854-rb-9122; Joe 10-27 "Carbon is for administration and monitoring. Nothing should be built nor coded on carbon"):
# a coder session runs on redbaron or ryzen7 only; any other host exits 79 before the OAuth source, every other gate and STEP 0.
h="$(hostname -s 2>/dev/null)"; case "$h" in redbaron|ryzen7) ;; *) echo "REFUSED host=${h:-unknown} (rb-run-coder.sh runs on redbaron or ryzen7 only)" >&2; exit 79 ;; esac
set -a; . "$HOME/.config/environment.d/90-claude-oauth.conf"; set +a
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH" WM_SEAT=rb-coder CLAUDE_SESSION_NAME="rb-coder-$n" RB_CODER_ID="$n"   # RB_CODER_ID = the rb marker .claude/hooks/land-push-gate.sh keys on (a coder may not `git push` a wm-build/* branch; rb-land-push.sh only)
cd "$HOME"
# empty-prompt gate (rb 10-23 12:5x AM: a failed sed left clp2.prompt at 0 bytes and the unit started anyway).
[ "$(wc -c < "$pf" 2>/dev/null || echo 0)" -ge 200 ] || { echo "REFUSED empty-prompt $pf" > "$D/$n.report.md"; EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n REFUSED empty-prompt" || true; exit 74; }
# pair-lint gate (rb 10-23, ctl 11:46 v347r: `wm-decide record --target redbaron --pr wm-build#347` is refused, the verifier stopped): exit 77.
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/rb-prompt-lint.sh"
if ! pl_msg=$(rb_prompt_pair_lint "$pf" 2>&1 >/dev/null); then
  pl_txt=$(sed -n "$(printf '%s\n' "$pl_msg" | head -n 1 | sed -n 's/^line \([0-9]*\):.*/\1/p')p" "$pf" | cut -c1-160)
  echo "REFUSED pair-lint $pf: $(printf '%s\n' "$pl_msg" | head -n 1) | text: $pl_txt" > "$D/$n.report.md"; EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n REFUSED pair-lint: $pl_txt" || true; exit 77
fi
# rules-lint gate (aide A725, row d-20261023-054617-rb-a725: prompts a375 and a361m ran without the kill-by-pid and LIVE CLONES rules): exit 72.
if ! rl_msg=$(rb_prompt_rules_lint "$pf" 2>&1); then
  rl_txt=$(printf '%s\n' "$rl_msg" | head -n 1)
  echo "REFUSED rules-lint $pf: $rl_txt" > "$D/$n.report.md"; EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n REFUSED rules-lint: $rl_txt" || true; exit 72
fi
# spawn-hold gate (CSH, replaces the interim freeze-file gate of row 2041): EVERY spawn asks rb-spawn-hold.sh
# whether a daemon redrive on redbaron is memory-refused; HOLD -> exit 76 + report + seat-event. The only exemption is
# --no-cargo (a prompt that never runs cargo on redbaron); it is logged in the seat-event and as `exempt` in spawn-hold.json.
# --no-flag: a spawn must not write/remove the HAND-YIELD flag (the 2-min timer owns it).
if [ "$nocargo" = 1 ]; then hold_out=$("$hold_bin" --no-flag --probe-only --exempt "$n" $hold_extra 2>&1); rc_h=0; else hold_out=$("$hold_bin" --no-flag $hold_extra 2>&1); rc_h=$?; fi
hold_all=$hold_out; hold_out=$(printf '%s\n' "$hold_out" | head -n 1)
if [ "$nocargo" = 1 ]; then EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n EXEMPT spawn-hold --no-cargo ($hold_out)" || true
elif [ "$rc_h" = 76 ]; then echo "REFUSED spawn-hold: $hold_out" > "$D/$n.report.md"; EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n REFUSED spawn-hold" || true; exit 76
# shu (ctl 12:27): the gate fails CLOSED. Any rc but 0/76 (126/127 = hold_bin missing or not executable, a crash) refuses too; the report
# quotes the first line starting HOLD|OK|REFUSED, else the first non-empty line (bash's own 126/127 message).
elif [ "$rc_h" != 0 ]; then
  why=$(printf '%s\n' "$hold_all" | grep -m1 -E '^(HOLD|OK|REFUSED)'); [ -n "$why" ] || why=$(printf '%s\n' "$hold_all" | grep -m1 .)
  echo "REFUSED spawn-hold rc=$rc_h: $why" > "$D/$n.report.md"; EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n REFUSED spawn-hold rc=$rc_h" || true; exit 76; fi
# spec-lint gate (rb 10-23, Fable QPA-v4 process fix, row 9ea3): every *.spec.md the prompt cites must pass spec-lint.sh.
# fable-verdict gate (fvg): a cited spec that does not exist refuses (spec-missing); each existing spec needs its Fable verdict row (exit 80).
gate_py="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/rb-fable-gate.py"; fg_db="${RB_DECISIONS_DB:-$HOME/.local/state/swarm-decide/decisions-carbon.sqlite}"
fg_refuse() { echo "REFUSED fable-verdict $1: $2" > "$D/$n.report.md"; EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n REFUSED fable-verdict" || true; exit 80; }
ncited=0
for sp in $(grep -oE '[~/A-Za-z0-9_.-]+\.spec\.md' "$pf" | sed "s|^~|$HOME|" | sort -u); do
  [ -f "$sp" ] || fg_refuse "$sp" "spec-missing $sp"
  why=$(bash "$HOME/.cache/rb-seat/spec-lint.sh" "$sp") || { echo "REFUSED spec-lint $sp: $why" > "$D/$n.report.md"; EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n REFUSED spec-lint $sp" || true; exit 73; }
  # STEP 0 gate (rb 10-23 1:4x AM, ctl d2ec / Fable 5538): a spec with a PREMISE-UNVERIFIED bullet forces a STEP 0 verify in the prompt.
  if grep -q 'PREMISE-UNVERIFIED' "$sp" && ! grep -q 'STEP 0' "$pf"; then echo "REFUSED step0-missing $sp has PREMISE-UNVERIFIED but $pf has no STEP 0" > "$D/$n.report.md"; EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n REFUSED step0-missing" || true; exit 75; fi
  ncited=$((ncited+1))
  fg_out=$(python3 -I "$gate_py" spec "$sp" "$fg_db" 2>&1) || fg_refuse "$sp" "$(printf '%s\n' "$fg_out" | head -n 1)"
done
if [ "$ncited" = 0 ]; then
  hatch_id=$(python3 -I "$gate_py" hatch "$pf" "$fg_db" 2>&1) || fg_refuse "$pf" "no-spec${hatch_id:+ ($(printf '%s\n' "$hatch_id" | head -n 1))}"
  EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n HATCH no-spec $hatch_id" || true
fi
# room gate (rcr, ctl 375e / Fable DISAGREE fd8c: two coder spawns cited no ROOM check): need = peak * (1 + other active rb-launch units), asked of
# carbon-room.sh (MemAvailable - need - 3072 reserve >= 0). peak = RB_ROOM_PEAK_MB, else the MAX `memory peak` over the last 20 finished
# rb-launch-* units in the user journal (>= 5 lines; fewer = floored at 1500 MB; none = 1500). Fails CLOSED: only rc 0 + a `room ok|n/a:` first line allows.
room_bin="${RB_ROOM_BIN:-$HOME/.local/bin/carbon-room.sh}"
if [ -n "${RB_ROOM_PEAK_MB:-}" ]; then peak_mb=$RB_ROOM_PEAK_MB; peak_src=env
else
  peaks=$(timeout 20 journalctl --user -u 'rb-launch-*' -g 'memory peak' -o cat --since -7d --no-pager 2>/dev/null | grep -E 'Consumed .* memory peak' | tail -n 20 \
    | sed -n -E 's/^.*Consumed .*[ ,]([0-9.]+)([BKMGT]) memory peak.*$/\1 \2/p' \
    | awk '{v=$1; u=$2; m=(u=="B")?v/1048576:(u=="K")?v/1024:(u=="M")?v:(u=="G")?v*1024:v*1048576; c=int(m); if (c<m) c++; if (c<1) c=1; print c}')
  k=$(printf '%s\n' "$peaks" | grep -c .); jmax=$(printf '%s\n' "$peaks" | grep . | sort -n | tail -n 1)
  if [ "$k" -ge 5 ]; then peak_mb=$jmax; peak_src="journal(n=$k)"
  elif [ "$k" -ge 1 ]; then peak_mb=$(( jmax > 1500 ? jmax : 1500 )); peak_src="journal(n=$k)+floor"
  else peak_mb=1500; peak_src=default; fi
fi
if act_out=$(timeout 20 systemctl --user list-units 'rb-launch-*' --state=active --no-legend --plain 2>/dev/null); then
  n_active=$(printf '%s\n' "$act_out" | awk -v self="rb-launch-$n.service" '$1 ~ /^rb-launch-.*\.service$/ && $1 != self' | grep -c .); act_txt=$n_active
else n_active=0; act_txt='?'; fi
need_mb=$(( peak_mb * (1 + n_active) ))
# Non-carbon host (RedBaron): carbon-room.sh would print `room n/a: not carbon`, so force its measure with CARBON_ROOM_HOST and a reserve of
# mem_headroom_gb (config.toml [cargo_jobs], default 4; env RB_ROOM_HEADROOM_MB), then check MemGate's own Σ: budget (mem_budget_gb, default 26;
# env RB_ROOM_BUDGET_MB; config path env RB_ROOM_CONFIG) minus the class caps of the live `wm-build builder cargo-jobs list` slots (env RB_ROOM_MEMGATE_SUM_MB) must cover need.
# Class = run-name prefix (land|inner|gate|hand); anything else takes the largest cap. Sigma unreadable = refuse (memgate NO).
room_host=${RB_ROOM_HOSTNAME:-$(hostname 2>/dev/null)}; mg_txt=''; mg_no=''; room_env=()
if [ "$room_host" != carbon ]; then
  mg_cfg=${RB_ROOM_CONFIG:-$HOME/.config/wm-build/config.toml}
  mg_cfgout=$(python3 -I -c 'import sys,tomllib
try: c=tomllib.load(open(sys.argv[1],"rb")).get("cargo_jobs",{})
except Exception: c={}
print(int(float(c.get("mem_budget_gb",26))*1024),int(float(c.get("mem_headroom_gb",4))*1024))' "$mg_cfg" 2>/dev/null) || mg_cfgout=''
  read -r mg_budget mg_head <<< "${mg_cfgout:-26624 4096}"
  mg_budget=${RB_ROOM_BUDGET_MB:-$mg_budget}; mg_head=${RB_ROOM_HEADROOM_MB:-$mg_head}
  room_env=(CARBON_ROOM_HOST="$room_host" CARBON_ROOM_RESERVE_MB="$mg_head")
  if [ -n "${RB_ROOM_MEMGATE_SUM_MB:-}" ]; then mg_sum=$RB_ROOM_MEMGATE_SUM_MB
  else
    mg_sum=$(cd ~ && timeout 30 "${RB_ROOM_WMB_BIN:-$HOME/.cargo/bin/wm-build}" builder cargo-jobs list 2>/dev/null | python3 -I -c 'import sys,tomllib,re
try: caps=tomllib.load(open(sys.argv[1],"rb")).get("cargo_jobs",{}).get("mem_caps_gb",{})
except Exception: caps={}
caps={k:float(v) for k,v in caps.items() if not isinstance(v,dict)}
big=max(caps.values(),default=12.5); rows=sys.stdin.read().splitlines()
if not rows or rows[0].split("\t")[:5]!=["id","run","producer","pid","alive"]: sys.exit(1)
t=0.0
for r in rows[1:]:
    f=r.split("\t")
    if len(f)<7: sys.exit(1)
    if f[4]!="yes": continue
    m=re.match(r"(land|inner|gate|hand)(?:[-.]|$)",f[1]); t+=caps.get(m.group(1),big) if m else big
print(int(t*1024))' "$mg_cfg" 2>/dev/null) || mg_sum=''
  fi
  if [[ $mg_sum =~ ^[0-9]+$ ]]; then mg_free=$(( mg_budget - mg_sum )); mg_txt="memgate free_mb=$mg_free sum_mb=$mg_sum budget_mb=$mg_budget"
    [ "$mg_free" -lt "$need_mb" ] && mg_no="memgate NO: free_mb=$mg_free < need_mb=$need_mb"
  else mg_no="memgate NO: sigma unreadable"; mg_txt="memgate sigma=unreadable"; fi
fi
room_out=$(env "${room_env[@]}" CARBON_ROOM_CALLER="rb-run-coder:$n" "$room_bin" "$need_mb" 2>&1); rc_r=$?
room_l1=$(printf '%s\n' "$room_out" | head -n 1)
room_tail="need_mb=$need_mb peak_mb=$peak_mb peak_src=$peak_src active=$act_txt${mg_txt:+ $mg_txt}"
if [ "$rc_r" = 0 ] && [[ $room_l1 =~ ^room\ (ok|n/a): ]] && [ -n "$mg_no" ]; then rc_r=3; room_l1=$mg_no; fi
if [ "$rc_r" != 0 ] || ! [[ $room_l1 =~ ^room\ (ok|n/a): ]]; then
  echo "REFUSED room rc=$rc_r: $room_l1 $room_tail" > "$D/$n.report.md"; EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n REFUSED room rc=$rc_r: $room_l1 $room_tail" || true; exit 78
fi
echo "$room_l1 $room_tail" > "$D/$n.room"; EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n ROOM $room_l1 $room_tail" || true
# memcap gate (rb 11-02, Fable CORRECT fcdf/05b3: coders ran on redbaron with MemoryMax=infinity): rb-coder-memcap.sh sets MemoryHigh/MemoryMax
# (12G/14G) on this coder's own unit and reads the cgroup back. Fails CLOSED: only rc 0 + a `memcap ok:` first line allows; anything else exits 71.
memcap_bin="${RB_MEMCAP_BIN:-$HOME/.local/bin/rb-coder-memcap.sh}"
mc_out=$("$memcap_bin" 2>&1); rc_m=$?; mc_l1=$(printf '%s\n' "$mc_out" | head -n 1)
if [ "$rc_m" != 0 ] || ! [[ $mc_l1 =~ ^memcap\ ok: ]]; then
  echo "REFUSED memcap rc=$rc_m: $mc_l1" > "$D/$n.report.md"; EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n REFUSED memcap rc=$rc_m: $mc_l1" || true; exit 71
fi
echo "$mc_l1" > "$D/$n.memcap"
claude -p --dangerously-skip-permissions --model "$model" --effort "$effort" "$(cat "$pf")" > "$D/$n.out" 2> "$D/$n.err"; rc=$?
EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n ended rc=$rc report=$D/$n.report.md" || true
exit $rc
