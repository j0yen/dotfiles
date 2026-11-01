#!/usr/bin/env bash
# rb-run-coder.sh <name> <prompt-file> [--no-cargo]: one `claude -p` coder turn for the rb seat, run ON REDBARON, never on this host
# (Joe 10-27 "Carbon is for administration and monitoring. Nothing should be built nor coded on carbon", approvals #47).
# The gates below run on the calling host; then the prompt is copied to <host>:/mnt/data/hand/coders/<name>.prompt and started there as
# `systemd-run --user --unit=rb-coder-<name>` (premise + expiry in the unit Description, RuntimeMaxSec). The caller polls
# `ssh <host> systemctl --user is-active` (ssh exit 255 = network flap = still running, one short ssh per poll), copies <name>.out/.err/.report.md back
# into ~/.cache/rb-seat/coders and rings the seat when the turn ends. The oauth env file is sourced on the REMOTE host only; this host never runs claude.
# If the remote unit cannot start (ssh fails 3 times or systemd-run errors) the report says `REFUSED remote-launch`, the seat is rung, exit 79: never a local fallback.
# Tracked in dotfiles (j0yen/dotfiles .local/bin, tests/rb-spawn-hold.test.sh); ~/.cache/rb-seat/coders/run-coder.sh is a symlink to it.
# --no-cargo (3rd positional or anywhere): exempt this spawn from the rb-spawn-hold gate; only for prompts that run no cargo on redbaron.
# gates, in order (exit): empty-prompt 74, pair-lint 77 (wm-decide record with --target AND --pr; .local/lib/rb-prompt-lint.sh),
# spawn-hold 76, spec-lint 73, STEP 0 75; then remote-launch 79.
# env: RB_CODER_MODEL = sonnet (default, medium effort) | opus (high effort: ambiguous multi-file refactor, architecture, or a sonnet coder's ESCALATE: opus; anything else exits 78).
# env: RB_CODER_HOST (default redbaron), RB_CODER_MAX_SEC (default 5400), RB_CODER_MEM (default 14G), RB_CODER_POLL_SEC (default 60), RB_CODER_RETRY_SEC (default 5).
# env: RB_SPAWN_HOLD_BIN (default ~/.local/bin/rb-spawn-hold.sh), RB_SPAWN_HOLD_EXTRA (extra args for it; tests).
set -uo pipefail
nocargo=0; args=(); for a in "$@"; do if [ "$a" = --no-cargo ]; then nocargo=1; else args+=("$a"); fi; done
n="${args[0]:?usage: rb-run-coder.sh <name> <prompt-file> [--no-cargo]}"; pf="${args[1]:?usage: rb-run-coder.sh <name> <prompt-file> [--no-cargo]}"; D="$HOME/.cache/rb-seat/coders"
model="${RB_CODER_MODEL:-sonnet}"; case "$model" in sonnet) effort=medium ;; opus) effort=high ;; *) echo "REFUSED model=$model (sonnet|opus)" >&2; exit 78 ;; esac
hold_bin="${RB_SPAWN_HOLD_BIN:-$HOME/.local/bin/rb-spawn-hold.sh}"; hold_extra="${RB_SPAWN_HOLD_EXTRA:-}"
host="${RB_CODER_HOST:-redbaron}"; maxs="${RB_CODER_MAX_SEC:-5400}"; mem="${RB_CODER_MEM:-14G}"; poll="${RB_CODER_POLL_SEC:-60}"; retry_sec="${RB_CODER_RETRY_SEC:-5}"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
cd "$HOME"
# empty-prompt gate (rb 10-23 12:5x AM: a failed sed left clp2.prompt at 0 bytes and the unit started anyway).
[ "$(wc -c < "$pf" 2>/dev/null || echo 0)" -ge 200 ] || { echo "REFUSED empty-prompt $pf" > "$D/$n.report.md"; EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n REFUSED empty-prompt" || true; exit 74; }
# pair-lint gate (rb 10-23, ctl 11:46 v347r: `wm-decide record --target redbaron --pr wm-build#347` is refused, the verifier stopped): exit 77.
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/rb-prompt-lint.sh"
if ! pl_msg=$(rb_prompt_pair_lint "$pf" 2>&1 >/dev/null); then
  pl_txt=$(sed -n "$(printf '%s\n' "$pl_msg" | head -n 1 | sed -n 's/^line \([0-9]*\):.*/\1/p')p" "$pf" | cut -c1-160)
  echo "REFUSED pair-lint $pf: $(printf '%s\n' "$pl_msg" | head -n 1) | text: $pl_txt" > "$D/$n.report.md"; EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n REFUSED pair-lint: $pl_txt" || true; exit 77
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
for sp in $(grep -oE '[~/A-Za-z0-9_.-]+\.spec\.md' "$pf" | sed "s|^~|$HOME|" | sort -u); do
  [ -f "$sp" ] || continue
  why=$(bash "$HOME/.cache/rb-seat/spec-lint.sh" "$sp") || { echo "REFUSED spec-lint $sp: $why" > "$D/$n.report.md"; EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n REFUSED spec-lint $sp" || true; exit 73; }
  # STEP 0 gate (rb 10-23 1:4x AM, ctl d2ec / Fable 5538): a spec with a PREMISE-UNVERIFIED bullet forces a STEP 0 verify in the prompt.
  if grep -q 'PREMISE-UNVERIFIED' "$sp" && ! grep -q 'STEP 0' "$pf"; then echo "REFUSED step0-missing $sp has PREMISE-UNVERIFIED but $pf has no STEP 0" > "$D/$n.report.md"; EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n REFUSED step0-missing" || true; exit 75; fi
done
# remote launch (Joe 10-27 approvals #47): the coder runs on $host, never here.
RD=/mnt/data/hand/coders; unit="rb-coder-$n"
sshq() { ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" "$@"; }
refuse_launch() { echo "REFUSED remote-launch $1" > "$D/$n.report.md"; EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n REFUSED remote-launch" || true; exit 79; }
# RB_CODER_ID = the rb marker .claude/hooks/land-push-gate.sh keys on (a coder may not `git push` a wm-build/* branch; rb-land-push.sh only)
inner='set -a; . "$HOME/.config/environment.d/90-claude-oauth.conf" >/dev/null 2>&1; set +a
export WM_SEAT=rb-coder CLAUDE_SESSION_NAME='"rb-coder-$n"' RB_CODER_ID='"$n"'
claude -p --dangerously-skip-permissions --model '"$model --effort $effort"' < '"$RD/$n.prompt > $RD/$n.out 2> $RD/$n.err"'
rc=$?; echo $rc > '"$RD/$n.rc"'; exit $rc'
exp=$(date -d "+${maxs} seconds" '+%F %T %Z')
desc="PREMISE: rb-run-coder $n runs one claude -p coder turn on $host for the rb seat; EXPIRES: $exp (RuntimeMaxSec=$maxs)"
start_cmd="systemd-run --user --collect --unit=$unit --description=$(printf %q "$desc") -p RuntimeMaxSec=$maxs -p MemoryMax=$mem -p WorkingDirectory=/mnt/data/hand --setenv=PATH=\"\$HOME/.local/bin:\$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin\" /bin/bash -c $(printf %q "$inner")"
prep_cmd="mkdir -p $RD && rm -f $RD/$n.out $RD/$n.err $RD/$n.rc $RD/$n.report.md /mnt/data/hand/$n.report.md"
started=0
for attempt in 1 2 3; do
  # a retry after a dropped ssh may find the unit already running: that counts as started
  if [ "$attempt" -gt 1 ]; then sleep "$retry_sec"; sshq systemctl --user is-active -q "$unit" && { started=1; break; }; fi
  sshq "$prep_cmd" >/dev/null 2>&1 || continue
  scp -q -o ConnectTimeout=10 -o BatchMode=yes "$pf" "$host:$RD/$n.prompt" >/dev/null 2>&1 || continue
  sshq "$start_cmd" >/dev/null 2>&1 && { started=1; break; }
done
[ "$started" = 1 ] || refuse_launch "$unit on $host (ssh/systemd-run failed 3 times)"
# wait with one short ssh per poll; 255 = ssh itself failed = still running. A host unreachable past RuntimeMaxSec + 900 s is lost, not running.
deadline=$((SECONDS + maxs + 900)); lost=0
while :; do
  sshq systemctl --user is-active -q "$unit" >/dev/null 2>&1; st=$?
  [ "$st" = 0 ] || [ "$st" = 255 ] || break
  [ "$SECONDS" -lt "$deadline" ] || { lost=1; break; }
  sleep "$poll"
done
[ "$lost" = 0 ] || refuse_launch "$unit on $host unreachable past RuntimeMaxSec+900"
# exit status: the .rc file the unit wrote, else the unit's ExecMainStatus (a unit killed by RuntimeMaxSec writes no .rc)
rc=$(sshq "cat $RD/$n.rc 2>/dev/null" 2>/dev/null | head -n 1 | tr -dc '0-9')
[ -n "$rc" ] || rc=$(sshq systemctl --user show -p ExecMainStatus "$unit" 2>/dev/null | sed -n 's/^ExecMainStatus=//p' | head -n 1 | tr -dc '0-9')
[ -n "$rc" ] || rc=1
for f in out err; do scp -q -o ConnectTimeout=10 -o BatchMode=yes "$host:$RD/$n.$f" "$D/$n.$f" >/dev/null 2>&1 || true; done
for r in "/mnt/data/hand/$n.report.md" "$RD/$n.report.md"; do scp -q -o ConnectTimeout=10 -o BatchMode=yes "$host:$r" "$D/$n.report.md" >/dev/null 2>&1 && break; done
EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n ended rc=$rc report=$D/$n.report.md" || true
exit "$rc"
