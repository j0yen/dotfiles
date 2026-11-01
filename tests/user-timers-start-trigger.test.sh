#!/usr/bin/env bash
# tests/user-timers-start-trigger.test.sh -- every user timer keeps a START TRIGGER after systemd merges its drop-ins, and live drop-ins are tracked in dotfiles.
#
# Trigger (five-whys 2026-10-24, ctl 3f76): an empty `OnUnitActiveSec=` in seat-tick@.timer.d/50-drain-brake.conf and swarm-decide-regrade.timer.d/15min.conf
# reset EVERY timer value (systemd's empty assignment clears the monotonic list AND OnCalendar), OnBootSec included. After the 10-24 11:09 AM reboot the seat ticks
# and the regrader had no starting point, never fired, and nothing alarmed.
#
# (a) STATIC  parse every *.timer + its drop-ins with systemd semantics and require a start trigger (OnBootSec/OnStartupSec/OnActiveSec/OnCalendar) at the end.
#             Merge order: the unit file, then ONE lexical sort by basename over name.timer.d + name@.timer.d + name@inst.timer.d (a same-named file in the
#             more specific dir replaces the other). Fixtures: tests/fixtures/timers/*/ (old broken drop-in FAILS, fixed PASSES, OnCalendar silenced FAILS ...).
# (c) STATIC  every live ~/.config/systemd/user/*.d/*.conf is a symlink into dotfiles or listed in tests/fixtures/timers/live-dropin-allowlist.txt.
#             Under a throwaway HOME there is no live dir: SKIP. Pre-install (before the aide links the new drop-ins) this FAILS on the real home, by design.
# (b) LIVE    when `systemctl --user` works: every enabled user timer shows OnBoot/OnStartup/OnActive or a calendar entry (.local/bin/timers-start-trigger-live.sh);
#             otherwise SKIP. seat-context-start.sh runs the same helper over carbon + redbaron + ryzen7 at SessionStart.
# Env: TIMERS_LIVE_HOME (default $HOME) = whose ~/.config/systemd/user (c) reads; TIMERS_EXTRA_BASE_DIRS (colon list) = where to find base units that live outside dotfiles
#      (default: the real user's ~/wintermute/swarm-decide/units when it exists).
# Run: bash tests/user-timers-start-trigger.test.sh
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
FX="$root/tests/fixtures/timers"; LIVE="$root/.local/bin/timers-start-trigger-live.sh"
fail=0
ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1"; fail=1; }
skip() { echo "SKIP $1"; }
chk()  { if [ "$2" = 0 ]; then ok "$1"; else bad "$1"; fi; }
T="$(mktemp -d "${TMPDIR:-/tmp}/user-timers.XXXXXX")"; trap 'rm -rf "$T"' EXIT

cat >"$T/merge.py" <<'PY'
"""usage: merge.py <unit-dir> [--base <dir>]...  -> one line per timer: `<unit> PASS|FAIL|SKIP <reason>`; exit 1 when any FAIL.
systemd semantics: an empty value on ANY On*Sec / OnCalendar directive clears the whole timer value list (monotonic AND calendar)."""
import os, re, sys

VALUE_KEYS = {"OnActiveSec", "OnBootSec", "OnStartupSec", "OnUnitActiveSec", "OnUnitInactiveSec", "OnCalendar"}
START_KEYS = {"OnBootSec", "OnStartupSec", "OnActiveSec", "OnCalendar"}


def timer_assignments(path):
    """-> [(key, value)] of the [Timer] section, in file order."""
    out, sect, pending = [], None, ""
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = pending + raw.rstrip("\n")
            pending = ""
            if line.endswith("\\"):
                pending = line[:-1] + " "
                continue
            s = line.strip()
            if not s or s[0] in "#;":
                continue
            m = re.match(r"\[(.+)\]$", s)
            if m:
                sect = m.group(1)
                continue
            if sect == "Timer" and "=" in s:
                k, v = s.split("=", 1)
                out.append((k.strip(), v.strip()))
    return out


def resolve(unit, root, bases):
    """-> (base file or None, merged drop-in file list in apply order) for a timer name, following systemd's template/instance rules."""
    m = re.match(r"^(.*)@(.*)\.timer$", unit)
    cands = [unit] + (["%s@.timer" % m.group(1)] if m and m.group(2) else [])
    base = None
    for c in cands:
        for d in [root] + bases:
            if os.path.isfile(os.path.join(d, c)):
                base = os.path.join(d, c)
                break
        if base:
            break
    dirs = []
    if m and m.group(2):
        dirs.append("%s@.timer.d" % m.group(1))
    dirs.append("%s.d" % unit)               # least to most specific: template dir, then the unit's own dir
    files = {}
    for d in dirs:
        p = os.path.join(root, d)
        if os.path.isdir(p):
            for fn in os.listdir(p):
                if fn.endswith(".conf"):
                    files[fn] = os.path.join(p, fn)       # same basename in the more specific dir replaces
    return base, [files[k] for k in sorted(files)]


def judge(unit, root, bases):
    base, drops = resolve(unit, root, bases)
    vals, reset_seen = [], False
    seq = ([base] if base else []) + drops
    for path in seq:
        for k, v in timer_assignments(path):
            if k not in VALUE_KEYS:
                continue
            if v == "":
                vals, reset_seen = [], True
            else:
                vals.append(k)
    if not base and not reset_seen:
        return "SKIP", "no base unit found and the drop-in never resets, so it cannot remove a trigger"
    if START_KEYS & set(vals):
        return "PASS", "start trigger: " + ",".join(sorted(START_KEYS & set(vals)))
    return "FAIL", "no OnBootSec/OnStartupSec/OnActiveSec/OnCalendar left after merge (has: %s)%s" % (
        ",".join(sorted(set(vals))) or "nothing", "" if base else "; base unit not found, judged from the drop-ins only")


def main(argv):
    root, bases, i = None, [], 0
    while i < len(argv):
        if argv[i] == "--base":
            bases.append(argv[i + 1]); i += 2
        else:
            root = argv[i]; i += 1
    units = set()
    for fn in os.listdir(root):
        if fn.endswith(".timer") and os.path.isfile(os.path.join(root, fn)):
            units.add(fn)
        elif fn.endswith(".timer.d") and os.path.isdir(os.path.join(root, fn)):
            units.add(fn[:-2])                                 # name.timer.d / name@.timer.d / name@inst.timer.d
    rc = 0
    for u in sorted(units):
        st, why = judge(u, root, bases)
        print("%s %s %s" % (u, st, why))
        rc |= st == "FAIL"
    return rc


sys.exit(main(sys.argv[1:]))
PY
merge() { python3 -I "$T/merge.py" "$@"; }

# ---------- (a) fixtures ----------
for d in "$FX"/*/; do
  c="$(basename "$d")"; [ -f "$d/expect" ] || continue
  args=("$d/units"); [ -d "$d/base" ] && args+=(--base "$d/base")
  got="$(merge "${args[@]}" 2>&1 | awk '{print $1, $2}' | sort)"
  [ "$got" = "$(sort "$d/expect")" ]; s=$?
  chk "(a) fixture $c: $(tr '\n' ';' <"$d/expect")" "$s"
  [ "$s" = 0 ] || { echo "    expected: $(tr '\n' ';' <"$d/expect")"; echo "    got:      $(printf '%s' "$got" | tr '\n' ';')"; }
done
# the three headline fixtures, asserted by name so a deleted fixture cannot pass silently
grep -q 'FAIL' "$FX/broken-reset/expect" && grep -q 'PASS' "$FX/fixed/expect" && grep -q 'nightly.timer FAIL' "$FX/calendar-silenced/expect"; chk "(a) headline fixtures present: broken FAILS, fixed PASSES, OnCalendar silenced FAILS" $?

# ---------- (a) the real units in this repo ----------
extra=()
IFS=: read -ra ebd <<<"${TIMERS_EXTRA_BASE_DIRS:-}"
for e in "${ebd[@]}"; do [ -n "$e" ] && extra+=(--base "$e"); done
if [ "${#extra[@]}" = 0 ]; then
  real_home="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
  [ -d "$real_home/wintermute/swarm-decide/units" ] && extra+=(--base "$real_home/wintermute/swarm-decide/units")
fi
real="$(merge "$root/.config/systemd/user" "${extra[@]}" 2>&1)"; rc=$?
[ "$rc" = 0 ]; chk "(a) every timer under .config/systemd/user (+ drop-ins) keeps a start trigger" $?
[ "$rc" = 0 ] || printf '%s\n' "$real" | grep ' FAIL ' | sed 's/^/    /'
printf '%s\n' "$real" | grep -q '^seat-tick@\.timer PASS'; chk "(a) seat-tick@.timer (template + 50-drain-brake.conf) is evaluated and PASSES" $?
printf '%s\n' "$real" | grep -q '^swarm-decide-regrade\.timer PASS'; chk "(a) swarm-decide-regrade.timer (15min.conf) is evaluated and PASSES" $?
[ -f "$root/.config/systemd/user/seat-tick@.timer.d/50-drain-brake.conf" ] && [ -f "$root/.config/systemd/user/swarm-decide-regrade.timer.d/15min.conf" ]; chk "(a) both timer drop-ins are tracked in dotfiles" $?

# ---------- (c) live drop-ins are symlinks into dotfiles or allowlisted ----------
# live_dropins <home> <allowlist> -> prints one `PASS|FAIL <relpath> <why>` per file; rc 1 on any FAIL
live_dropins() {
  local h="$1" al="$2" d f rel tgt rc=0
  d="$h/.config/systemd/user"; [ -d "$d" ] || { echo "SKIP no $d"; return 0; }
  for f in "$d"/*.d/*.conf; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    rel="${f#"$d"/}"
    if [ -L "$f" ]; then
      tgt="$(readlink -f "$f" 2>/dev/null)"; [ -n "$tgt" ] || tgt="$(readlink "$f")"
      case "$tgt" in
        "$root"/*|*/dotfiles/*) [ -e "$tgt" ] && { echo "PASS $rel symlink into dotfiles"; continue; }; echo "FAIL $rel dangling symlink into dotfiles ($(readlink "$f"))"; rc=1; continue ;;
      esac
    fi
    if grep -qxF -- "$rel" "$al" 2>/dev/null; then echo "PASS $rel allowlisted"; else
      echo "FAIL $rel is $( [ -L "$f" ] && echo "a symlink outside dotfiles" || echo "a regular file"): track it in dotfiles (.config/systemd/user/$rel) or add it to tests/fixtures/timers/live-dropin-allowlist.txt"; rc=1
    fi
  done
  return "$rc"
}
H="$T/fakehome"; U="$H/.config/systemd/user"; mkdir -p "$U/a.timer.d" "$U/b.service.d"
mkdir -p "$T/dotfiles/.config/systemd/user/a.timer.d"; echo '[Timer]' >"$T/dotfiles/.config/systemd/user/a.timer.d/10.conf"
ln -s "$T/dotfiles/.config/systemd/user/a.timer.d/10.conf" "$U/a.timer.d/10.conf"
printf '[Service]\n' >"$U/b.service.d/x.conf"; printf 'b.service.d/x.conf\n' >"$T/al.txt"
out="$(live_dropins "$H" "$T/al.txt")"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^PASS a.timer.d/10.conf symlink into dotfiles' && printf '%s' "$out" | grep -q '^PASS b.service.d/x.conf allowlisted'; chk "(c) fixture: symlink into dotfiles and an allowlisted file PASS" $?
printf '[Timer]\nOnUnitActiveSec=\n' >"$U/a.timer.d/50-reset.conf"
out="$(live_dropins "$H" "$T/al.txt")"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q '^FAIL a.timer.d/50-reset.conf is a regular file'; chk "(c) fixture: an untracked regular-file timer drop-in FAILS" $?
rm "$U/a.timer.d/50-reset.conf"; ln -s /nonexistent/dotfiles/x.conf "$U/a.timer.d/60-dangling.conf"
out="$(live_dropins "$H" "$T/al.txt")"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q '^FAIL a.timer.d/60-dangling.conf dangling'; chk "(c) fixture: a dangling symlink into dotfiles FAILS" $?
rm "$U/a.timer.d/60-dangling.conf"; mkdir -p "$T/elsewhere"; echo '[Timer]' >"$T/elsewhere/z.conf"; ln -s "$T/elsewhere/z.conf" "$U/a.timer.d/70-foreign.conf"
out="$(live_dropins "$H" "$T/al.txt")"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q '^FAIL a.timer.d/70-foreign.conf is a symlink outside dotfiles'; chk "(c) fixture: a symlink to somewhere other than dotfiles FAILS" $?
# the real live dir
# LIVE-HOST check: reads the real ~/.config, so it runs only with DOTFILES_LIVE_CHECKS=1 (the fixture cases above prove the detector).
lh="${TIMERS_LIVE_HOME:-$HOME}"
if [ "${DOTFILES_LIVE_CHECKS:-}" != 1 ]; then echo "SKIP live: $lh/.config/systemd/user drop-in check (set DOTFILES_LIVE_CHECKS=1)"
elif [ -d "$lh/.config/systemd/user" ]; then
  out="$(live_dropins "$lh" "$FX/live-dropin-allowlist.txt")"; rc=$?
  chk "(c) live $lh/.config/systemd/user/*.d/*.conf: all symlinks into dotfiles or allowlisted" "$rc"
  [ "$rc" = 0 ] || printf '%s\n' "$out" | grep '^FAIL' | sed 's/^/    /'
else skip "(c) no $lh/.config/systemd/user (throwaway HOME): live drop-in check not applicable"; fi

# ---------- (b) live check ----------
[ -x "$LIVE" ]; chk "(b) helper .local/bin/timers-start-trigger-live.sh is executable" $?
got="$(TIMERS_LIVE_SHOW_FILE="$FX/live-show.txt" "$LIVE" --hosts "$(hostname -s)" 2>&1)"; rc=$?
[ "$rc" = 1 ] && [ "$(printf '%s\n' "$got" | sed 's/^\(.*\) testhost /\1 testhost /')" != "" ]; chk "(b) fixture: any FAIL line makes the helper exit 1" $?
exp="$(sed "s/ testhost / $(hostname -s) /" "$FX/live-show.expect")"
[ "$got" = "$exp" ]; chk "(b) fixture: OK for calendar/boot/startup, FAIL for OnUnitActiveSec-only and empty, disabled + transient ignored" $?
got="$(TIMERS_LIVE_SHOW_FILE="$FX/live-show.txt" "$LIVE" --hosts "$(hostname -s)" --failures-only 2>&1)"
[ "$(printf '%s\n' "$got" | grep -c '^FAIL ')" = 2 ] && ! printf '%s' "$got" | grep -q '^OK '; chk "(b) fixture: --failures-only prints only FAIL/SKIP" $?
printf 'Id=only-ok.timer\nUnitFileState=enabled\nTimersCalendar={ OnCalendar=daily ; next_elapse=x }\n' >"$T/ok-show.txt"
TIMERS_LIVE_SHOW_FILE="$T/ok-show.txt" "$LIVE" >/dev/null 2>&1; chk "(b) fixture: all OK exits 0" $?
mkdir -p "$T/nosys"; printf '#!/bin/sh\nexit 1\n' >"$T/nosys/systemctl"; chmod +x "$T/nosys/systemctl"
got="$(PATH="$T/nosys:$PATH" "$LIVE" 2>&1)"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$got" | grep -q '^SKIP .* systemctl --user unavailable'; chk "(b) fixture: systemctl --user unavailable prints SKIP, exit 0" $?
if [ "${DOTFILES_LIVE_CHECKS:-}" != 1 ]; then echo "SKIP live: systemctl --user timer check (set DOTFILES_LIVE_CHECKS=1)"
elif timeout 10 systemctl --user show-environment >/dev/null 2>&1; then
  got="$("$LIVE" 2>&1)"; rc=$?
  chk "(b) live: every enabled user timer on this host shows a start trigger ($(printf '%s\n' "$got" | grep -c '^OK ') ok)" "$rc"
  [ "$rc" = 0 ] || printf '%s\n' "$got" | grep '^FAIL' | sed 's/^/    /'
else skip "(b) systemctl --user unavailable here (throwaway HOME / no user manager): live timer check not applicable"; fi

[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
