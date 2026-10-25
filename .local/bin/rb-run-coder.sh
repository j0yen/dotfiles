#!/usr/bin/env bash
# rb-run-coder.sh <name> <prompt-file> [--no-cargo]: one sonnet `claude -p` coder turn for the rb seat, under a systemd-run unit
# (premise + expiry in the unit Description/RuntimeMaxSec). Rings the seat when the turn ends.
# Tracked in dotfiles (j0yen/dotfiles .local/bin, tests/rb-spawn-hold.test.sh); ~/.cache/rb-seat/coders/run-coder.sh is a symlink to it.
# --no-cargo (3rd positional or anywhere): exempt this spawn from the rb-spawn-hold gate; only for prompts that run no cargo on redbaron.
# gates, in order (exit): empty-prompt 74, pair-lint 77 (wm-decide record with --target AND --pr; .local/lib/rb-prompt-lint.sh),
# spawn-hold 76, spec-lint 73, STEP 0 75, room 78 (carbon-room.sh <need-MB>, CLAUDE.md § Hosts ROOM; runs last, just before `claude -p`).
# env: RB_SPAWN_HOLD_BIN (default ~/.local/bin/rb-spawn-hold.sh), RB_SPAWN_HOLD_EXTRA (extra args for it; tests),
# RB_ROOM_BIN (default ~/.local/bin/carbon-room.sh), RB_ROOM_PEAK_MB (the coder's peak in MB; skips the journal read).
set -uo pipefail
nocargo=0; args=(); for a in "$@"; do if [ "$a" = --no-cargo ]; then nocargo=1; else args+=("$a"); fi; done
n="${args[0]:?usage: rb-run-coder.sh <name> <prompt-file> [--no-cargo]}"; pf="${args[1]:?usage: rb-run-coder.sh <name> <prompt-file> [--no-cargo]}"; D="$HOME/.cache/rb-seat/coders"
hold_bin="${RB_SPAWN_HOLD_BIN:-$HOME/.local/bin/rb-spawn-hold.sh}"; hold_extra="${RB_SPAWN_HOLD_EXTRA:-}"
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
room_out=$(CARBON_ROOM_CALLER="rb-run-coder:$n" "$room_bin" "$need_mb" 2>&1); rc_r=$?
room_l1=$(printf '%s\n' "$room_out" | head -n 1)
room_tail="need_mb=$need_mb peak_mb=$peak_mb peak_src=$peak_src active=$act_txt"
if [ "$rc_r" != 0 ] || ! [[ $room_l1 =~ ^room\ (ok|n/a): ]]; then
  echo "REFUSED room rc=$rc_r: $room_l1 $room_tail" > "$D/$n.report.md"; EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n REFUSED room rc=$rc_r: $room_l1 $room_tail" || true; exit 78
fi
echo "$room_l1 $room_tail" > "$D/$n.room"; EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n ROOM $room_l1 $room_tail" || true
claude -p --dangerously-skip-permissions --model sonnet "$(cat "$pf")" > "$D/$n.out" 2> "$D/$n.err"; rc=$?
EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n ended rc=$rc report=$D/$n.report.md" || true
exit $rc
