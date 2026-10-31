#!/usr/bin/env bash
# hostname guard (tracked in dotfiles; carbon-only hook): silent no-op on every other node
[ "$(hostname -s)" = carbon ] || exit 0
# cargo-block-carbon.sh — PreToolUse hook (Bash), ALL models: carbon never
# compiles Rust (14 G RAM, tmpfs /tmp 7 G — the 10-07 death). Added
# 2026-10-13 9:1x pm PDT when the `op` seat moved to carbon (Joe "move op
# to carbon"): a seat-spawned coder on carbon must run cargo on RedBaron
# through ssh/the shim, never here. Classifier = cargo-block-carbon.py
# (command-position match only; quotes, heredoc bodies and ssh lines are
# ignored — the first version's bare word match blocked a tmux message and
# a python heredoc that merely mentioned cargo, 9:19 pm).
# Escape hatch (unconditional, one call): touch ~/.claude/.allow-cargo-carbon
set -u
[ "$(hostname -s)" = "carbon" ] || exit 0
if [ -e "$HOME/.claude/.allow-cargo-carbon" ]; then rm -f "$HOME/.claude/.allow-cargo-carbon"; exit 0; fi
verdict=$(python3 -I "$HOME/.claude/hooks/cargo-block-carbon.py" 2>/dev/null)
[ "$verdict" = "deny" ] || exit 0
cat >&2 <<EOF
cargo-block-carbon: carbon never runs cargo/rustc (14 G RAM, 10-07 tmpfs death).
Run it on RedBaron: ssh redbaron '~/.cargo/bin/cargo …' (or the /rustbuild shim).
Escape hatch (one call): touch ~/.claude/.allow-cargo-carbon
EOF
exit 2
