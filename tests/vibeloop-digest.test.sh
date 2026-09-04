#!/usr/bin/env bash
# tests/vibeloop-digest.test.sh — PRD-vibeloop-daily-digest P0 ACs 1-6 + P1 AC7: exercises
# vibeloop-digest.sh (and the vibeloop-ctl digest/--today wrapper) against fixture ledgers,
# a fixture $HOME (so ~/brain/journal/*.log, ~/.config/vibeloop/limits and the curl/nats
# binaries it shells out to are all isolated), and an isolated throwaway git repo for
# DREAM_PRD_DIR (no remote, so push warns to stderr harmlessly — same convention as
# tests/vibeloop-ctl-claim.test.sh). curl and nats are shadowed with fixture scripts placed
# first on the fixture $HOME's PATH (vibeloop-digest.sh pins its own PATH to
# "$HOME/.local/bin:...") so no real network call (hub /healthz, ntfy.sh, NATS) ever fires.
# Plain bash, no bats dependency. Run:
#   bash tests/vibeloop-digest.test.sh
# from the repo root. Exits nonzero (and prints every failure) if any assertion fails.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$here/../.local/bin/vibeloop-digest.sh"
CTL="$here/../.local/bin/vibeloop-ctl"

fail=0
assert_eq() { # $1=actual $2=expected $3=case description
  if [ "$1" = "$2" ]; then echo "ok - $3"
  else echo "NOT OK - $3: got '$1', want '$2'"; fail=1; fi
}
assert_contains() { # $1=haystack $2=needle $3=case description
  case "$1" in *"$2"*) echo "ok - $3" ;; *) echo "NOT OK - $3: '$1' does not contain '$2'"; fail=1 ;; esac
}
assert_count() { # $1=haystack $2=needle $3=expected count $4=case description
  n=$(grep -o -F -- "$2" <<<"$1" | wc -l)
  if [ "$n" = "$3" ]; then echo "ok - $4"
  else echo "NOT OK - $4: '$2' appears $n time(s) in output, want $3"; fail=1; fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Fixture curl: logs every invocation, serves a canned /healthz body, never touches the network.
mk_fake_curl() { # $1=bin dir  $2=log file  $3=healthz json file (may not exist)
  mkdir -p "$1"
  cat > "$1/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "curl \$*" >> "$2"
last="\${@: -1}"
case "\$last" in
  *"/healthz"*) [ -f "$3" ] && cat "$3"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$1/curl"
}
# Fixture nats: logs every invocation (subject + payload), never touches the network.
mk_fake_nats() { # $1=bin dir  $2=log file
  mkdir -p "$1"
  cat > "$1/nats" <<EOF
#!/usr/bin/env bash
printf '%s\n' "nats \$*" >> "$2"
exit 0
EOF
  chmod +x "$1/nats"
}

# ===========================================================================================
# Scenario 1 ("full"): every input present, STOP + MEASURE-STOP present, NTFY_TOPIC set.
# Covers AC1 (8 sections, order, Needs-you first), AC2 (STOP captured + commit lands,
# path-scoped), AC4 (ntfy POST + NATS publish fire), AC6 (numbers carry a source path on
# the same line — spot-checked inline with each section below rather than a separate pass).
# ===========================================================================================
H1="$work/home1"
repo="$work/prds1"
DATE="2026-01-15"
mkdir -p "$H1/.config/vibeloop" "$H1/brain/journal"
mkdir -p "$repo/vibeloop" "$repo/build-queue" "$repo/built-prds" "$repo/parked"
mkdir -p "$repo/evidence/mcp-host/measure/run1"
git init -q "$repo"
git -C "$repo" config user.email test@test.com
git -C "$repo" config user.name test

cat > "$repo/vibeloop/ledger.md" <<'EOF'
2026-01-15T09:00:00Z cycle=1 verdict=PROGRESS note="all fine"
2026-01-15T10:00:00Z cycle=2 verdict=ABORTED note="crashed during publish step"
2026-01-15T11:00:00Z cycle=3 verdict=PROGRESS note="a decision needs a human to confirm before proceeding"
EOF

cat > "$repo/vibeloop/measure-ledger.md" <<'EOF'
2026-01-15T09:05:00Z version=1.0.0 harness-probe=PASS sessions_spent=1
2026-01-15T09:10:00Z version=1.0.0 reason=calibration measured=OK sessions_spent=2
EOF

cat > "$repo/vibeloop/cost-ledger.jsonl" <<'EOF'
{"ts": "2026-01-15T09:00:00Z", "kind": "cycle", "usd": 5.0}
{"ts": "2026-01-15T10:00:00Z", "kind": "measure", "usd": 1.5}
EOF
recent_ts=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)
echo "{\"ts\": \"$recent_ts\", \"kind\": \"cycle\", \"usd\": 2.0}" >> "$repo/vibeloop/cost-ledger.jsonl"

printf '%s\n' "operator needs to check hub token expiry before resuming" > "$repo/vibeloop/STOP"
printf '%s\n' "waiting on human calibration decision" > "$repo/vibeloop/MEASURE-STOP"

cat > "$repo/built-prds/PRD-fixture-shipped.md" <<'EOF'
# PRD — fixture shipped thing

- Status: built
- Built: 2026-01-15
- Cost: $12.34
EOF

cat > "$repo/build-queue/PRD-fixture-drafted.md" <<'EOF'
# PRD — fixture drafted thing

- Status: queued
- Drafted: 2026-01-15
EOF

cat > "$repo/build-queue/PRD-fixture-blocked.md" <<'EOF'
# PRD — fixture blocked thing

- Status: blocked
- Blocked: needs human to approve a budget increase
EOF

printf 'run1\n' > "$repo/evidence/mcp-host/measure/LATEST"
cat > "$repo/evidence/mcp-host/measure/run1/measure.json" <<'EOF'
{"satisfaction": 0.5, "wow_rate": 0.2, "sessions": 10, "failures": 1,
 "by_segment": {"seg1": {"satisfaction": 0.5, "wow_rate": 0.2, "n": 10}}}
EOF
cat > "$repo/evidence/mcp-host/baseline.json" <<'EOF'
{"version": "1.0.0"}
EOF

cat > "$H1/.config/vibeloop/limits" <<'EOF'
MAX_COST_USD_PER_DAY=2.0
MAX_COST_USD_PER_WEEK=100.0
NTFY_TOPIC=test-topic-digest
EOF

cat > "$H1/brain/journal/vibeloop-auto.log" <<'EOF'
2026-01-15T09:00:00Z cycle=1 duration_s=120 status=ok
2026-01-15T10:00:00Z cycle=2 duration_s=340 status=failed reason=crashed
2026-01-15T10:05:00Z deploy rollback triggered for mcphost v1.2.3
2026-01-15T10:06:00Z build failed: connection error
2026-01-15T10:07:00Z build failed: connection error
EOF
cat > "$H1/brain/journal/vibeloop-measure.log" <<'EOF'
2026-01-15T09:30:00Z probe ABORTED for tenant probe-1
EOF

cat > "$H1/healthz.json" <<'EOF'
{"version": "9.9.9", "tenants_total": 42, "tools_total": 7}
EOF

CURL_LOG="$work/curl1.log"; : > "$CURL_LOG"
NATS_LOG="$work/nats1.log"; : > "$NATS_LOG"
mk_fake_curl "$H1/.local/bin" "$CURL_LOG" "$H1/healthz.json"
mk_fake_nats "$H1/.local/bin" "$NATS_LOG"

mkdir -p "$repo/.git-empty" 2>/dev/null; rmdir "$repo/.git-empty" 2>/dev/null
git -C "$repo" add -A
git -C "$repo" commit -q -m init

before_commits=$(git -C "$repo" rev-list --count HEAD)
out1=$(HOME="$H1" DREAM_PRD_DIR="$repo" bash "$SCRIPT" "$DATE" 2>"$work/stderr1.log")
rc1=$?
assert_eq "$rc1" "0" "scenario1: script exits 0"

DIGEST1="$repo/vibeloop/digest/$DATE.md"
[ -f "$DIGEST1" ] && echo "ok - AC1: digest file written at vibeloop/digest/$DATE.md" || { echo "NOT OK - AC1: $DIGEST1 missing"; fail=1; }
body1="$(cat "$DIGEST1" 2>/dev/null)"

# -- AC1: eight sections, in the PRD's required order, "Needs you" first ------------------
headings=$(grep '^## ' "$DIGEST1")
expected_headings=$'## Needs you\n## Shipped\n## Drafted\n## Cycles\n## Spend\n## Hub\n## Measurement\n## Errors'
assert_eq "$headings" "$expected_headings" "AC1: all 8 sections present, in required order, Needs-you first"

# -- AC2: STOP present is surfaced in Needs-you, and the run commits + pushes -------------
assert_contains "$body1" "**STOP present**: operator needs to check hub token expiry before resuming" "AC2: Needs-you surfaces STOP's first line"
assert_contains "$body1" "vibeloop/STOP" "AC2: STOP bullet carries its source path"
assert_contains "$body1" "**MEASURE-STOP present**: waiting on human calibration decision" "AC2: Needs-you surfaces MEASURE-STOP's first line"
assert_eq "$(git -C "$repo" log -1 --format=%s)" "vibeloop: digest $DATE" "AC2: run commits with the expected message"
after_commits=$(git -C "$repo" rev-list --count HEAD)
assert_eq "$after_commits" "$((before_commits + 1))" "AC2: exactly one new commit lands"
assert_eq "$(git -C "$repo" diff --name-only HEAD~1 HEAD)" "vibeloop/digest/$DATE.md" "AC2/req3: commit is path-scoped to vibeloop/digest/"

# -- Needs-you: budget ladder, blocked-on-human PRD, flagged cycle note, deploy rollback --
assert_contains "$body1" "near ceiling" "Needs-you: 24h spend at ceiling is flagged"
assert_contains "$body1" '$2.00 of $2.00 (100%)' "Needs-you: 24h budget ladder line — number + ceiling"
assert_contains "$body1" '$2.00 of $100.00 (2%)' "Needs-you: 7d budget ladder line — number + ceiling"
assert_contains "$body1" "vibeloop/cost-ledger.jsonl" "Needs-you: budget ladder line carries its source path"
assert_contains "$body1" "cycle=3: a decision needs a human to confirm before proceeding" "Needs-you: cycle note flagged for a human"
assert_contains "$body1" "build-queue/PRD-fixture-blocked.md: needs human to approve a budget increase" "Needs-you: PRD blocked on a human"
assert_contains "$body1" "deploy rollback triggered for mcphost v1.2.3" "Needs-you: deploy rollback surfaced"
assert_contains "$body1" "~/brain/journal/vibeloop-auto.log" "Needs-you: rollback bullet carries its source path"

# -- Shipped / Drafted (AC1 content + AC6 path-on-same-line) -------------------------------
assert_contains "$body1" "PRD-fixture-shipped.md: \$12.34  (built-prds/PRD-fixture-shipped.md)" "Shipped: entry shows cost + source path"
assert_contains "$body1" "PRD-fixture-drafted.md  (build-queue/PRD-fixture-drafted.md)" "Drafted: entry shows source path"

# -- Cycles (AC1 content + AC6) -------------------------------------------------------------
assert_contains "$body1" "3 cycles  (vibeloop/ledger.md)" "Cycles: count + source path"
assert_contains "$body1" "verdicts: ABORTED=1, PROGRESS=2  (vibeloop/ledger.md)" "Cycles: verdict breakdown"
assert_contains "$body1" "cycle=2 verdict=ABORTED" "Cycles: ABORTED line listed"
assert_contains "$body1" "longest cycle: 340s" "Cycles: longest cycle from duration_s"

# -- Spend (AC1 content + AC6) --------------------------------------------------------------
assert_contains "$body1" "24h total: \$2.00 of \$2.00  (vibeloop/cost-ledger.jsonl)" "Spend: 24h total + ceiling + path"
assert_contains "$body1" "24h by kind: cycle=\$2.00" "Spend: 24h breakdown by kind"
assert_contains "$body1" "day (2026-01-15) total: \$6.50  (vibeloop/cost-ledger.jsonl)" "Spend: day total + path"
assert_contains "$body1" "day by kind: cycle=\$5.00, measure=\$1.50" "Spend: day breakdown by kind"

# -- Hub (AC1 content + AC6) -----------------------------------------------------------------
assert_contains "$body1" "version: 9.9.9" "Hub: version from mocked /healthz"
assert_contains "$body1" "tenants: 42, tools: 7" "Hub: tenants/tools from mocked /healthz"
assert_contains "$body1" "last probe:" "Hub: last probe line present"
assert_contains "$body1" "harness-probe=PASS" "Hub: last probe pulls the harness-probe line"
assert_contains "$body1" "vibeloop/measure-ledger.md" "Hub: last-probe line carries its source path"

# -- Measurement (AC1 content + AC6) ---------------------------------------------------------
assert_contains "$body1" "2 runs today  (vibeloop/measure-ledger.md)" "Measurement: run count + path"
assert_contains "$body1" "satisfaction=0.5 wow_rate=0.2 sessions=10 failures=1" "Measurement: proxy/latest results"
assert_contains "$body1" "evidence/mcp-host/measure/run1/measure.json" "Measurement: proxy/latest results carry source path"
assert_contains "$body1" "seg1: sat=0.5 wow=0.2 n=10" "Measurement: decisions per segment"
assert_contains "$body1" "baseline pointer: evidence/mcp-host/baseline.json" "Measurement: baseline pointer path"

# -- Errors: deduplicated, each line sourced -------------------------------------------------
assert_contains "$body1" "status=failed reason=crashed" "Errors: cycle failure surfaced"
assert_contains "$body1" "probe ABORTED for tenant probe-1" "Errors: measure-log ABORTED surfaced"
assert_count "$body1" "build failed: connection error" 1 "Errors: identical repeated failure deduplicated to one line"
assert_contains "$body1" "~/brain/journal/vibeloop-measure.log" "Errors: measure-log line carries its source path"

# -- AC4: NTFY_TOPIC set -> Needs-you POSTed to ntfy, published on NATS ----------------------
nats_log="$(cat "$NATS_LOG" 2>/dev/null)"
assert_contains "$nats_log" "wm.vibeloop.digest" "AC4: NATS publish targets wm.vibeloop.digest"
assert_contains "$nats_log" "STOP present" "AC4: NATS payload is the Needs-you section"
curl_log="$(cat "$CURL_LOG" 2>/dev/null)"
assert_contains "$curl_log" "ntfy.sh/test-topic-digest" "AC4: ntfy POST hits the configured topic"
assert_contains "$curl_log" "Title: vibeloop $DATE" "AC4: ntfy POST carries the dated title"

# ===========================================================================================
# Scenario 2 (AC5): every optional input missing — digest must still generate and every
# missing section must read "not available" rather than erroring out.
# ===========================================================================================
H2="$work/home2"
repo2="$work/prds2"
DATE2="2026-02-20"
mkdir -p "$H2"
mkdir -p "$repo2"
git init -q "$repo2"
git -C "$repo2" config user.email test@test.com
git -C "$repo2" config user.name test
: > "$repo2/.gitkeep"
git -C "$repo2" add -A && git -C "$repo2" commit -q -m init

CURL_LOG2="$work/curl2.log"; : > "$CURL_LOG2"
mk_fake_curl "$H2/.local/bin" "$CURL_LOG2" "$H2/no-such-healthz.json"

out2=$(HOME="$H2" DREAM_PRD_DIR="$repo2" bash "$SCRIPT" "$DATE2" --no-commit 2>"$work/stderr2.log")
rc2=$?
assert_eq "$rc2" "0" "AC5: script still exits 0 with every optional input missing"
DIGEST2="$repo2/vibeloop/digest/$DATE2.md"
[ -f "$DIGEST2" ] && echo "ok - AC5: digest file still written when inputs are missing" || { echo "NOT OK - AC5: $DIGEST2 missing"; fail=1; }
body2="$(cat "$DIGEST2" 2>/dev/null)"

assert_contains "$body2" "STOP: absent" "AC5: STOP absent renders explicitly"
assert_contains "$body2" "open questions flagged by cycles: not available" "AC5: missing ledger.md renders not available"
assert_contains "$body2" "PRDs blocked on a human: none" "AC5: missing build-queue renders none, not an error"
assert_contains "$body2" "deploy rollbacks: not available" "AC5: missing RedBaron log renders not available"
assert_contains "$body2" "none shipped $DATE2" "AC5: missing built-prds renders none shipped"
assert_contains "$body2" "none drafted $DATE2" "AC5: missing build-queue renders none drafted"
assert_contains "$body2" "not available" "AC5: Cycles section renders not available for missing ledger.md"
assert_contains "$body2" "hub /healthz: not available" "AC5: unreachable/mocked-empty /healthz renders not available"
assert_contains "$body2" "last probe: not available" "AC5: missing measure-ledger.md renders not available"
assert_contains "$body2" "proxy/latest results: not available" "AC5: missing evidence/measure/LATEST renders not available"
assert_contains "$body2" "baseline pointer: not available" "AC5: missing baseline.json renders not available"
assert_contains "$body2" "not available (RedBaron-only journal logs not present on this host)" "AC5: Errors section renders not available, not an error"

# ===========================================================================================
# Scenario 3 (AC3): the vibeloop-ctl wrapper — `digest --today` generates without committing,
# plain `digest` then prints the already-generated page after a pull.
# ===========================================================================================
H3="$work/home3"
repo3="$work/prds3"
mkdir -p "$H3"
mkdir -p "$repo3"
git init -q "$repo3"
git -C "$repo3" config user.email test@test.com
git -C "$repo3" config user.name test
: > "$repo3/.gitkeep"
git -C "$repo3" add -A && git -C "$repo3" commit -q -m init
mk_fake_curl "$H3/.local/bin" "$work/curl3.log" "$H3/no-such-healthz.json"

before3=$(git -C "$repo3" rev-list --count HEAD)
today="$(date -u +%F)"
out_today=$(HOME="$H3" DREAM_PRD_DIR="$repo3" PATH="$here/../.local/bin:$PATH" bash "$CTL" digest --today 2>"$work/ctl_today.stderr")
rc3=$?
assert_eq "$rc3" "0" "AC3: vibeloop-ctl digest --today exits 0"
assert_contains "$out_today" "# vibeloop daily digest" "AC3: --today prints a freshly generated page"
after3=$(git -C "$repo3" rev-list --count HEAD)
assert_eq "$after3" "$before3" "AC3: --today generates without committing"
[ -f "$repo3/vibeloop/digest/$today.md" ] && echo "ok - AC3: --today wrote today's digest file" || { echo "NOT OK - AC3: today's digest file missing"; fail=1; }

out_default=$(HOME="$H3" DREAM_PRD_DIR="$repo3" PATH="$here/../.local/bin:$PATH" bash "$CTL" digest 2>"$work/ctl_default.stderr")
rc4=$?
assert_eq "$rc4" "0" "AC3: plain 'digest' exits 0"
assert_eq "$out_default" "$(cat "$repo3/vibeloop/digest/$today.md")" "AC3: plain 'digest' prints today's already-generated page"

# ===========================================================================================
# Scenario 4 (P1 AC7): a Monday date also writes a weekly roll-up alongside the daily page.
# ===========================================================================================
MONDAY="2024-01-01"
out4=$(HOME="$H1" DREAM_PRD_DIR="$repo" bash "$SCRIPT" "$MONDAY" --no-commit 2>"$work/stderr4.log")
rc5=$?
assert_eq "$rc5" "0" "AC7: Monday run exits 0"
WEEKLY="$repo/vibeloop/digest/$MONDAY-weekly.md"
[ -f "$WEEKLY" ] && echo "ok - AC7: Monday run also writes a weekly roll-up" || { echo "NOT OK - AC7: $WEEKLY missing"; fail=1; }
weekly_body="$(cat "$WEEKLY" 2>/dev/null)"
assert_contains "$weekly_body" "week ending $MONDAY" "AC7: weekly roll-up header"
assert_contains "$weekly_body" "Total spend this week" "AC7: weekly roll-up includes spend"
assert_contains "$weekly_body" "Still-open questions" "AC7: weekly roll-up includes still-open questions"
# A non-Monday date must NOT produce a weekly file.
TUESDAY="2024-01-02"
HOME="$H1" DREAM_PRD_DIR="$repo" bash "$SCRIPT" "$TUESDAY" --no-commit >/dev/null 2>>"$work/stderr4.log"
[ -f "$repo/vibeloop/digest/$TUESDAY-weekly.md" ] && { echo "NOT OK - AC7: non-Monday date wrote a weekly file"; fail=1; } || echo "ok - AC7: non-Monday date writes no weekly file"

if [ "$fail" -eq 0 ]; then
  echo "all vibeloop-digest tests passed"
else
  echo "vibeloop-digest tests FAILED"
fi
exit "$fail"
