#!/usr/bin/env bash
# tests/ledgerday_ac6_install_symlink.test.sh — PRD-token-ledger-day-buckets
# AC6 (P0, test_prefix: ledgerday): given a fresh checkout of dotfiles, when
# install.sh runs, then ~/.local/bin/token-ledger is a symlink into the
# repo and the tracked token-ledger.timer/.service unit files are present
# at their install.sh-managed paths.
#
# This copies the current repo tree (the same convention as running
# install.sh against "a checkout") into an isolated $HOME and runs
# install.sh there — no mutation of the real machine's ~/.local/bin or
# ~/.config. `systemctl --user cat` itself is NOT exercised here: the
# running user systemd instance is a single long-lived daemon tied to the
# real session's XDG paths, so pointing $HOME at a temp dir does not (and
# should not) change what that live daemon resolves — verifying the
# *installed unit file's own well-formedness* is the hermetic proxy for
# "systemctl --user cat would show the tracked unit". Run with:
#   bash tests/ledgerday_ac6_install_symlink.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
# shellcheck source=ledgerday_test_helpers.sh
. "$here/ledgerday_test_helpers.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
checkout="$work/checkout"
fakehome="$work/home"
mkdir -p "$checkout" "$fakehome"
# Mirror the repo's tracked-file surface without .git (matches what a real
# checkout's working tree looks like to install.sh, which never reads .git).
(cd "$repo" && tar --exclude=.git -cf - .) | (cd "$checkout" && tar -xf -)

HOME="$fakehome" bash "$checkout/install.sh" >/dev/null
rc=$?
assert_eq "$rc" "0" "install.sh exits 0 against a fresh checkout"

link="$fakehome/.local/bin/token-ledger"
assert "[ -L '$link' ]" "~/.local/bin/token-ledger is a symlink"
target="$(readlink -f "$link")"
assert_eq "$target" "$checkout/.local/bin/token-ledger" "symlink resolves into the checkout, not a copy"
assert "[ -x '$link' ]" "the installed script is executable"

svc="$fakehome/.config/systemd/user/token-ledger.service"
timer="$fakehome/.config/systemd/user/token-ledger.timer"
assert "[ -L '$svc' ] && [ -L '$timer' ]" "token-ledger.service and .timer are both installed as symlinks"
assert_contains "$(cat "$timer")" "[Timer]" "installed timer unit has a [Timer] section"
assert_contains "$(cat "$timer")" "OnCalendar=" "installed timer unit declares OnCalendar"
assert_contains "$(cat "$svc")" "ExecStart=" "installed service unit declares ExecStart"

exit "$fail"
