#!/usr/bin/env bash
# rb-run-coder.sh <name> <prompt-file> [--no-cargo]: one sonnet `claude -p` coder turn for the rb seat, under a systemd-run unit
# (premise + expiry in the unit Description/RuntimeMaxSec). Rings the seat when the turn ends.
# Tracked in dotfiles (j0yen/dotfiles .local/bin, tests/rb-spawn-hold.test.sh); ~/.cache/rb-seat/coders/run-coder.sh is a symlink to it.
# --no-cargo (3rd positional or anywhere): exempt this spawn from the rb-spawn-hold gate; only for prompts that run no cargo on redbaron.
# env: RB_SPAWN_HOLD_BIN (default ~/.local/bin/rb-spawn-hold.sh), RB_SPAWN_HOLD_EXTRA (extra args for it; tests).
set -uo pipefail
nocargo=0; args=(); for a in "$@"; do if [ "$a" = --no-cargo ]; then nocargo=1; else args+=("$a"); fi; done
n="${args[0]:?usage: rb-run-coder.sh <name> <prompt-file> [--no-cargo]}"; pf="${args[1]:?usage: rb-run-coder.sh <name> <prompt-file> [--no-cargo]}"; D="$HOME/.cache/rb-seat/coders"
hold_bin="${RB_SPAWN_HOLD_BIN:-$HOME/.local/bin/rb-spawn-hold.sh}"; hold_extra="${RB_SPAWN_HOLD_EXTRA:-}"
set -a; . "$HOME/.config/environment.d/90-claude-oauth.conf"; set +a
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH" WM_SEAT=rb-coder CLAUDE_SESSION_NAME="rb-coder-$n"
cd "$HOME"
# empty-prompt gate (rb 10-23 12:5x AM: a failed sed left clp2.prompt at 0 bytes and the unit started anyway).
[ "$(wc -c < "$pf" 2>/dev/null || echo 0)" -ge 200 ] || { echo "REFUSED empty-prompt $pf" > "$D/$n.report.md"; EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n REFUSED empty-prompt" || true; exit 74; }
# spawn-hold gate (CSH, replaces the interim freeze-file gate of row 2041): EVERY spawn asks rb-spawn-hold.sh
# whether a daemon redrive on redbaron is memory-refused; HOLD -> exit 76 + report + seat-event. The only exemption is
# --no-cargo (a prompt that never runs cargo on redbaron); it is logged in the seat-event and as `exempt` in spawn-hold.json.
# --no-flag: a spawn must not write/remove the HAND-YIELD flag (the 2-min timer owns it).
if [ "$nocargo" = 1 ]; then hold_out=$("$hold_bin" --no-flag --probe-only --exempt "$n" $hold_extra 2>&1); rc_h=0; else hold_out=$("$hold_bin" --no-flag $hold_extra 2>&1); rc_h=$?; fi
hold_out=$(printf '%s\n' "$hold_out" | head -n 1)
if [ "$nocargo" = 1 ]; then EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n EXEMPT spawn-hold --no-cargo ($hold_out)" || true
elif [ "$rc_h" = 76 ]; then echo "REFUSED spawn-hold: $hold_out" > "$D/$n.report.md"; EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n REFUSED spawn-hold" || true; exit 76; fi
# spec-lint gate (rb 10-23, Fable QPA-v4 process fix, row 9ea3): every *.spec.md the prompt cites must pass spec-lint.sh.
for sp in $(grep -oE '[~/A-Za-z0-9_.-]+\.spec\.md' "$pf" | sed "s|^~|$HOME|" | sort -u); do
  [ -f "$sp" ] || continue
  why=$(bash "$HOME/.cache/rb-seat/spec-lint.sh" "$sp") || { echo "REFUSED spec-lint $sp: $why" > "$D/$n.report.md"; EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n REFUSED spec-lint $sp" || true; exit 73; }
  # STEP 0 gate (rb 10-23 1:4x AM, ctl d2ec / Fable 5538): a spec with a PREMISE-UNVERIFIED bullet forces a STEP 0 verify in the prompt.
  if grep -q 'PREMISE-UNVERIFIED' "$sp" && ! grep -q 'STEP 0' "$pf"; then echo "REFUSED step0-missing $sp has PREMISE-UNVERIFIED but $pf has no STEP 0" > "$D/$n.report.md"; EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n REFUSED step0-missing" || true; exit 75; fi
done
claude -p --dangerously-skip-permissions --model sonnet "$(cat "$pf")" > "$D/$n.out" 2> "$D/$n.err"; rc=$?
EVENT_SOURCE="rb-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" rb "RB-CODER $n ended rc=$rc report=$D/$n.report.md" || true
exit $rc
