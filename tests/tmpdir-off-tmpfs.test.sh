#!/usr/bin/env bash
# tmpdir-off-tmpfs.test.sh - fleet TMPDIR contract no-drift check.
# Static part (always): 92-tmpdir.conf content, install.sh ships it and creates ~/.cache/tmp mode 700.
# Host part: the user manager must export TMPDIR and it must not sit on tmpfs; SKIP when there is no user manager.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$here/..
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

conf=$repo/.config/environment.d/92-tmpdir.conf
# shellcheck disable=SC2016  # literal ${HOME}: environment.d expands it, not the shell
if [ -f "$conf" ] && [ "$(cat "$conf")" = 'TMPDIR=${HOME}/.cache/tmp' ]; then pass "92-tmpdir.conf content"; else bad "92-tmpdir.conf missing or wrong (want TMPDIR=\${HOME}/.cache/tmp)"; fi
if grep -q 'cache/tmp' "$repo/install.sh" && grep -q 'chmod 700' "$repo/install.sh"; then pass "install.sh creates ~/.cache/tmp 0700"; else bad "install.sh does not create ~/.cache/tmp with chmod 700"; fi
# install.sh links every tracked file, so the conf ships unless skipped
if grep -E 'skip_pattern=' "$repo/install.sh" | grep -q '92-tmpdir'; then bad "install.sh skips 92-tmpdir.conf"; else pass "install.sh ships 92-tmpdir.conf"; fi

if ! command -v systemctl >/dev/null 2>&1 || ! env=$(systemctl --user show-environment 2>/dev/null); then
  echo "SKIP no user manager (host part)"
else
  t=$(printf '%s\n' "$env" | sed -n 's/^TMPDIR=//p' | head -n1)
  if [ -z "$t" ]; then
    bad "user manager has no TMPDIR (systemctl --user show-environment | grep ^TMPDIR= is empty): install 92-tmpdir.conf, then relogin or systemctl --user set-environment TMPDIR=\$HOME/.cache/tmp"
  else
    fs=$(findmnt -T "$t" -o FSTYPE -n 2>/dev/null | head -n1)
    if [ "$fs" = tmpfs ]; then bad "TMPDIR=$t is on tmpfs"; else pass "TMPDIR=$t on ${fs:-unknown} (not tmpfs)"; fi
  fi
fi

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
