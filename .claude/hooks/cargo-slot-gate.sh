#!/usr/bin/env bash
# cargo-slot-gate.sh — PreToolUse hook (Bash), ALL models, every host: refuses an
# ssh to a build host (redbaron, ryzen7) that runs a compiling cargo subcommand
# without a memory gate (cargo-slot.sh / r7-cargo-slot.sh / `wm-build builder
# cargo-jobs acquire`) on the same ssh segment. Added 2026-10-21 (Joe "hook yes",
# HKS, widened to both hosts + all three gates). PREMISE: ungated hand cargo froze
# RedBaron x3 (10-16, 10-17 x2) and ran ~13x ungated on ryzen7 10-21. Backstop only:
# cargo inside a script file is not seen. Classifier = cargo-slot-gate.py.
# Each refusal logs time, host and subcommand (never the command) to
# ~/.local/state/cargo-slot-gate/refusals.log.
# Escape hatch (unconditional, one call): touch ~/.claude/.allow-cargo-ungated
set -u
if [ -e "$HOME/.claude/.allow-cargo-ungated" ]; then rm -f "$HOME/.claude/.allow-cargo-ungated"; exit 0; fi
verdict=$(python3 -I "$HOME/.claude/hooks/cargo-slot-gate.py" 2>/dev/null)
case "$verdict" in deny*) ;; *) exit 0 ;; esac
read -r _ host sub <<<"$verdict"
d="$HOME/.local/state/cargo-slot-gate"; mkdir -p "$d" 2>/dev/null
printf '%s host=%s sub=%s cwd=%s\n' "$(date -Is)" "$host" "$sub" "$PWD" >>"$d/refusals.log" 2>/dev/null
cat >&2 <<EOF
cargo-slot-gate: ungated \`cargo $sub\` on $host refused (ungated hand cargo froze RedBaron x3).
Run it through the memory gate on the same ssh line:
  redbaron: ssh redbaron '/mnt/data/hand/cargo-slot.sh … -- cargo $sub …'
  ryzen7:   ssh ryzen7 '~/.local/bin/r7-cargo-slot.sh … -- cargo $sub …'
  either:   wm-build builder cargo-jobs acquire --class land --producer cargo-slot -- cargo $sub …
Escape hatch (one call): touch ~/.claude/.allow-cargo-ungated
EOF
exit 2
