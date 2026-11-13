#!/usr/bin/env bash
# rb-suite-unit-negatives.test.sh - black-box negatives for rb-suite-unit.sh OUTFILE handling (A1304 rev 2, Hermes 8:50 AM 11-12: on
# e39cefc a dangling-symlink OUTFILE passed the -e check and the payload created its target). Independent of --selftest: drives the
# launcher with a fake systemd-run that logs one line per call and then RUNS the payload (everything from /bin/bash on), so the unit side is
# exercised for real. Cases: dangling symlink, symlink to an existing file, 16 concurrent launches on one OUTFILE, OUTFILE swapped to a
# symlink between launch and unit start, plus one positive end-to-end run.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
L="$here/../.local/bin/rb-suite-unit.sh"
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
cd "$T" || exit 1   # a launcher that misreads its argv must not write into the caller's tree
fail=0
chk() { if [ "$2" = 0 ]; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }
cat > "$T/sdrun" <<'EOF'
#!/bin/bash
# fake systemd-run: log one line, optionally swap OUTFILE, then run the payload argv from /bin/bash on
echo call >> "$SDLOG"
while [ $# -gt 0 ] && [ "$1" != /bin/bash ]; do shift; done
if [ -n "${SWAP_TO:-}" ]; then rm -f -- "$5"; ln -s "$SWAP_TO" "$5"; fi
"$@"
EOF
chmod +x "$T/sdrun"
mkdir "$T/wd" "$T/o"
export SD_RUN="$T/sdrun" SDLOG="$T/sdrun.log"
: > "$SDLOG"

# positive: a normal run writes CMD output then EXIT=<rc>
"$L" rb-neg-ok "$T/wd" "$T/o/ok.txt" -- sh -c 'echo out; exit 4'; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$T/o/ok.txt")" = "$(printf 'out\nEXIT=4')" ]; chk "positive: rc 0, OUTFILE = output + EXIT=4" $?

# 1 dangling symlink at OUTFILE
: > "$SDLOG"; ln -s "$T/o/dangle-target" "$T/o/dl.txt"
"$L" rb-neg-dl "$T/wd" "$T/o/dl.txt" -- echo pwned 2>"$T/e1"; rc=$?
[ "$rc" = 2 ] && [ ! -e "$T/o/dangle-target" ] && [ ! -s "$SDLOG" ] && grep -q symlink "$T/e1"; ok=$?
chk "dangling-symlink OUTFILE: rc 2, target not created, systemd-run not called (rc=$rc, stderr: $(cat "$T/e1"))" "$ok"

# 2 symlink to an existing file
: > "$SDLOG"; echo keep > "$T/o/victim"; ln -s "$T/o/victim" "$T/o/sl.txt"
"$L" rb-neg-sl "$T/wd" "$T/o/sl.txt" -- echo pwned 2>/dev/null; rc=$?
[ "$rc" = 2 ] && [ "$(cat "$T/o/victim")" = keep ] && [ ! -s "$SDLOG" ]; chk "symlink-to-file OUTFILE: rc 2, target unchanged, systemd-run not called" $?

# 3 concurrent creation: 16 launches on one OUTFILE
: > "$SDLOG"
for i in $(seq 1 16); do ( "$L" "rb-neg-c$i" "$T/wd" "$T/o/race.txt" -- echo "winner $i" 2>/dev/null; echo $? > "$T/rc.$i" ) & done; wait
ok=$(cat "$T"/rc.* | grep -c '^0$'); ref=$(cat "$T"/rc.* | grep -c '^2$'); calls=$(grep -c . "$SDLOG")
[ "$ok" = 1 ] && [ "$ref" = 15 ] && [ "$calls" = 1 ] && [ "$(grep -c '^winner ' "$T/o/race.txt")" = 1 ] && [ "$(grep -c '^EXIT=0$' "$T/o/race.txt")" = 1 ]
chk "16 concurrent launches on one OUTFILE: $ok rc 0, $ref rc 2, $calls systemd-run call, one writer in OUTFILE" $?

# 4 OUTFILE swapped to a symlink after the launcher created it, before the unit starts
: > "$SDLOG"; echo keep > "$T/o/victim2"
SWAP_TO="$T/o/victim2" "$L" rb-neg-sw "$T/wd" "$T/o/sw.txt" -- echo pwned 2>/dev/null; rc=$?
[ "$rc" = 97 ] && [ "$(cat "$T/o/victim2")" = keep ]; chk "OUTFILE swapped to symlink-to-file before start: payload 97, target unchanged" $?
: > "$SDLOG"
SWAP_TO="$T/o/dangle2" "$L" rb-neg-sd "$T/wd" "$T/o/sd.txt" -- echo pwned 2>/dev/null; rc=$?
[ "$rc" = 97 ] && [ ! -e "$T/o/dangle2" ]; chk "OUTFILE swapped to dangling symlink before start: payload 97, target not created" $?

exit $fail
