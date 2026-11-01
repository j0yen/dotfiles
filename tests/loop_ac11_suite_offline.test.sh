#!/usr/bin/env bash
# tests/loop_ac11_suite_offline.test.sh — PRD-grand-loop-scaffold AC11: the
# loop test suite passes offline and attempts no network call.
# Runs every sibling loop_ac*.test.sh (explicit list, not this file itself).
# Every fixture in this suite is the local fake-mcphost-deploy plus a
# throwaway git repo with no remote — a stray network attempt would only ever
# come from a bug, not from the fixtures.
#
# What the old "< 20s" wall-clock assertion protected: no network call and no
# wait on a network timeout. A wall clock does not measure that (the suite
# takes 18-24s on an idle host and 33s+ under load, because every tick
# runs real git work), so it failed on load without any offline violation.
# The property is now asserted directly: network clients on PATH are
# replaced by recording shims (any call is logged and fails), git is limited
# to the file protocol, and the log must be empty afterwards. The wall clock
# is kept only as a generous backstop against a hang / network timeout;
# SUITE_WALL_BUDGET_S overrides it (default 120s, > 3x the loaded time).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
budget_s="${SUITE_WALL_BUDGET_S:-120}"

guard="$(mktemp -d)"; trap 'rm -rf "$guard"' EXIT
net_log="$guard/net-calls.log"; : > "$net_log"
mkdir -p "$guard/bin"
for tool in curl wget ssh scp sftp nc ncat socat telnet ftp; do
  cat > "$guard/bin/$tool" <<SHIM
#!/usr/bin/env bash
echo "$tool \$*" >> "$net_log"
exit 1
SHIM
  chmod +x "$guard/bin/$tool"
done
export PATH="$guard/bin:$PATH"
export GIT_ALLOW_PROTOCOL=file   # git refuses http/https/ssh/git transports

siblings=(
  loop_ac1_basic_tick.test.sh
  loop_ac2_flock.test.sh
  loop_ac3_stop.test.sh
  loop_ac4_unvalidated.test.sh
  loop_ac5_distribution.test.sh
  loop_ac6_families.test.sh
  loop_ac7_growing.test.sh
  loop_ac8_budget_cap.test.sh
  loop_ac9_tenant_mismatch.test.sh
  loop_ac10_loop_notes.test.sh
  loop_ac12_status.test.sh
  loop_ac13_daily_section.test.sh
)

fail=0
start=$(date +%s%N)
for t in "${siblings[@]}"; do
  # Unset any per-test env leaking from a prior iteration's `export` (each
  # sibling calls loop_setup, which overrides PATH/GRAND_LOOP_* anyway).
  if bash "$here/$t"; then
    echo "ok - $t"
  else
    echo "NOT OK - $t"
    fail=1
  fi
done
end=$(date +%s%N)
elapsed_s=$(( (end - start) / 1000000000 ))

if [ ! -s "$net_log" ]; then
  echo "ok - suite attempted no network call"
else
  echo "NOT OK - suite attempted network calls:"; cat "$net_log"
  fail=1
fi

# Backstop only (see header): catches a hang or a network timeout wait.
if [ "$elapsed_s" -lt "$budget_s" ]; then
  echo "ok - suite ran in ${elapsed_s}s (< ${budget_s}s backstop)"
else
  echo "NOT OK - suite took ${elapsed_s}s (>= ${budget_s}s backstop)"
  fail=1
fi

exit $fail
