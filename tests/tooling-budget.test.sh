#!/usr/bin/env bash
# tests/tooling-budget.test.sh — tooling budget (Joe 10-29 approvals #62, goal.md § Stage TOOLING BUDGET):
#  1. token-ledger attributes a session to tooling by its transcript cwd's git origin (dotfiles clone = tooling, mcphost clone and a
#     session with no cwd = not), writes tooling_share/tooling_weighted/tooling_window_days/tooling_budget into build-share.json,
#     and adds `ALARM tooling_share=X.X % >= 80 % of 5 % budget` at >= 4 %.
#  2. rb-run-coder.sh exits 4 `REFUSED tooling-budget ...` before `claude -p` for a tooling brief at share >= 0.05; product briefs are
#     never refused; a missing or stale build-share.json prints `WARN tooling-budget unknown` and allows.
# Hermetic: fixture transcripts + fixture git repos + fixture build-share.json under a temp dir; never reads ~/.claude or the live ledger.
# Run with: bash tests/tooling-budget.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ledgerday_test_helpers.sh
. "$here/ledgerday_test_helpers.sh"
ledgerday_setup   # NOW=2026-09-12T10:15:00Z, single host carbon (today = 2026-09-12)

# --- fixture git checkouts: origin is only a URL string, nothing is fetched ---
mkrepo() { mkdir -p "$1"; git -C "$1" init -q; [ -z "${2:-}" ] || git -C "$1" remote add origin "$2"; }
mkrepo "$work/clones/dotfiles-x" https://github.com/j0yen/dotfiles.git
mkrepo "$work/clones/sd-x"       git@github.com:j0yen/swarm-decide.git
mkrepo "$work/clones/mcphost-x"  https://github.com/j0yen/mcphost.git
mkrepo "$work/clones/noorigin"

asst() { printf '{"type":"assistant","cwd":"%s","timestamp":"2026-09-12T09:00:00Z","message":{"id":"%s","model":"m","usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}\n' "$3" "$1" "$2"; }
# mk NAME CWD IN — one top-level session transcript (cwd may be empty: record without a cwd field)
mk() {
  mkdir -p "$jsonl/-p"
  if [ -n "$2" ]; then asst "m-$1" "$3" "$2" > "$jsonl/-p/$1.jsonl"
  else asst "m-$1" "$3" "" | jq -c 'del(.cwd)' > "$jsonl/-p/$1.jsonl"; fi
}
# fixtures TOOLING_IN — dotfiles clone TOOLING_IN, other repos + no-cwd + missing dir fill the rest of a 100M day
fixtures() {
  rm -rf "$jsonl" "$state"; mkdir -p "$jsonl" "$state"
  mk dot  "$work/clones/dotfiles-x" "$(( $1 * 3 / 4 ))"
  mk sd   "$work/clones/sd-x"       "$(( $1 - $1 * 3 / 4 ))"
  mk mcp  "$work/clones/mcphost-x"  50000000
  mk noo  "$work/clones/noorigin"   20000000
  mk gone "$work/clones/deleted"    10000000
  mk nocwd ""                       "$(( 20000000 - $1 ))"
}

# --- 1a. emit mode tags only the tooling sessions ---
fixtures 4000000
tagged="$("$TL" --emit-local-records --since 2026-09-12T00:00:00Z | jq -r 'select(.tooling==true) | .id' | sort | paste -sd' ')"
assert_eq "$tagged" "m-dot m-sd" "dotfiles + swarm-decide clones are tooling; mcphost clone, no-origin repo, deleted cwd and no-cwd session are not"

# --- 1b. 3 % of 100M: share written, no alarm ---
fixtures 3000000
"$TL"; rc=$?
assert_eq "$rc" "0" "run exits 0 (3 %)"
bs="$state/build-share.json"
assert_eq "$(jq -r '.tooling_share' "$bs")" "0.0300" "tooling_share = 3M / 100M (fraction)"
assert_eq "$(jq -r '.tooling_weighted' "$bs")" "3000000" "tooling_weighted"
assert_eq "$(jq -r '.tooling_window_days' "$bs")" "7" "tooling_window_days = 7"
assert_eq "$(jq -r '.tooling_budget' "$bs")" "0.05" "tooling_budget = 0.05"
assert_not_contains "$(cat "$state/today-summary.txt")" "tooling_share" "3 % -> no tooling alarm"

# --- 1c. 4.5 %: alarm line beside the summary ---
fixtures 4500000
"$TL"
assert_eq "$(jq -r '.tooling_share' "$bs")" "0.0450" "tooling_share 4.5 %"
assert_eq "$(sed -n 2p "$state/today-summary.txt")" "ALARM tooling_share=4.5 % >= 80 % of 5 % budget" "4.5 % -> alarm on line 2"

# --- 1d. trailing window: yesterday's sidecar row counts, an 8-day-old one does not; rerun is idempotent ---
printf '2026-09-06\t999999999\n2026-09-05\t999999999\n' > "$state/tooling-daily.tsv"   # 6 and 7 days back: only 09-06 is inside 09-06..09-12
printf '2026-09-06\tm\t100000000\tbudget off\tyes\tcarbon\t\tg\t\t\t0\t\n' >> "$state/ledger.tsv"
"$TL"; "$TL"
assert_eq "$(jq -r '.tooling_weighted' "$bs")" "$((999999999 + 4500000))" "sidecar rows inside the 7-day window sum in, older ones do not; rerun does not double-count today"
assert_eq "$(awk -F'\t' '$1=="2026-09-12"' "$state/tooling-daily.tsv" | wc -l)" "1" "one sidecar row per day"

# --- 2. rb-run-coder.sh gate ---
runc="$here/../.local/bin/rb-run-coder.sh"
H="$work/home"; mkdir -p "$H/.config/environment.d" "$H/.local/bin" "$H/.cache/rb-seat/coders"
: > "$H/.config/environment.d/90-claude-oauth.conf"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/events.log"\n' "$work" > "$H/.local/bin/seat-event.sh"
printf '#!/usr/bin/env bash\necho ran >> "%s/claude.ran"\nexit 0\n' "$work" > "$H/.local/bin/claude"
printf '#!/usr/bin/env bash\necho "OK stub"\nexit 0\n' > "$work/hold-ok.sh"
chmod +x "$H/.local/bin/seat-event.sh" "$H/.local/bin/claude" "$work/hold-ok.sh"
brief() { # file repo-url
  { echo "# Coder brief"; echo "Work in: git clone $2 /mnt/data/hand/x-clone, branch rb/x off origin/main. bash + python3 only."
    head -c 300 /dev/zero | tr '\0' 'y'; echo; } > "$1"
}
brief "$work/b-tool.md" https://github.com/j0yen/dotfiles.git
brief "$work/b-sd.md"   https://github.com/j0yen/swarm-decide.git
brief "$work/b-prod.md" https://github.com/j0yen/mcphost.git
brief "$work/b-syn.md"  https://github.com/j0yen/synthorg.git
bsj() { printf '{"date":"2026-09-12","tooling_share":%s,"tooling_window_days":7,"tooling_budget":0.05}\n' "$1" > "$work/bs.json"; }
spawn() { # name brief -> sets rc, out; claude.ran present iff claude -p would have run
  rm -f "$work/claude.ran"
  out="$(HOME="$H" TOOLING_BUDGET_JSON="$work/bs.json" RB_SPAWN_HOLD_BIN="$work/hold-ok.sh" bash "$runc" "$1" "$2" 2>&1)"; rc=$?
  ran=no; [ -e "$work/claude.ran" ] && ran=yes
}
bsj 0.03;  spawn g1 "$work/b-tool.md"; assert_eq "$rc/$ran" "0/yes" "share 0.03, tooling brief -> allowed"
bsj 0.045; spawn g2 "$work/b-tool.md"; assert_eq "$rc/$ran" "0/yes" "share 0.045, tooling brief -> allowed"
bsj 0.05;  spawn g3 "$work/b-tool.md"; assert_eq "$rc/$ran" "4/no" "share 0.05, dotfiles brief -> exit 4, claude not run"
assert_contains "$out" "REFUSED tooling-budget share=0.05 >= 0.05 (goal.md TOOLING BUDGET, approvals #62)" "refusal line verbatim"
assert_contains "$(cat "$H/.cache/rb-seat/coders/g3.report.md")" "REFUSED tooling-budget" "report file carries the refusal"
bsj 0.05;  spawn g4 "$work/b-sd.md";   assert_eq "$rc/$ran" "4/no" "share 0.05, swarm-decide brief -> exit 4"
bsj 0.09;  spawn g5 "$work/b-prod.md"; assert_eq "$rc/$ran" "0/yes" "share 0.09, mcphost brief -> allowed"
bsj 0.09;  spawn g6 "$work/b-syn.md";  assert_eq "$rc/$ran" "0/yes" "share 0.09, synthorg brief -> allowed"
bsj 0.09; touch -d '3 hours ago' "$work/bs.json"
spawn g7 "$work/b-tool.md"; assert_eq "$rc/$ran" "0/yes" "stale (3 h) build-share.json, tooling brief -> allowed (fail-open)"
assert_contains "$out" "WARN tooling-budget unknown" "stale file prints WARN tooling-budget unknown"
rm -f "$work/bs.json"
spawn g8 "$work/b-tool.md"; assert_eq "$rc/$ran" "0/yes" "missing build-share.json -> allowed (fail-open)"
assert_contains "$out" "WARN tooling-budget unknown" "missing file prints WARN tooling-budget unknown"
printf '{"date":"2026-09-12","tooling_share":null}\n' > "$work/bs.json"
spawn g9 "$work/b-tool.md"; assert_eq "$rc/$ran" "0/yes" "tooling_share null -> allowed (fail-open)"

exit "$fail"
