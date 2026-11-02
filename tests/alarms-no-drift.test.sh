#!/usr/bin/env bash
# alarms-no-drift (A238 L5): every status.json field a page names is in .config/fleet/alarms.json; claude-operated.sh lists unresolved
# gear pointers and honours the exempt list; fleet-status-write.sh --render shows each alarm ('unknown' when absent).
# Pages checked: $ALARM_PAGES (space list) if set, else the fixture pages below (CLAUDE.md lives outside the repo).
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
AL="$here/.config/fleet/alarms.json"; CO="$here/.local/bin/claude-operated.sh"; W="$here/.local/bin/fleet-status-write.sh"
fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

jq -e '.alarms | length >= 12' "$AL" >/dev/null && ok "contract lists >= 12 alarms" || bad "contract short"
for k in claude_operated idle_host_blocked hand_prs runs_unitless r7_verify runs_per_slug_24h lock_hold needs_joe carbon.build_procs; do
  jq -e --arg k "$k" '.alarms[] | select(.key==$k)' "$AL" >/dev/null && ok "alarm $k present" || bad "alarm $k missing"
done

# no-drift: a backticked status.json key on a page (`status.json key`) must be in the contract
mkdir -p "$tmp/pages"
printf 'rule A names status.json `idle_host_blocked` and status.json `hand_prs`.\n' >"$tmp/pages/ok.md"
printf 'rule B names status.json `brand_new_alarm`.\n' >"$tmp/pages/drift.md"
drift() { grep -ohE 'status\.json[ a-z.]* `[a-z_0-9.]+`' "$@" | grep -oE '`[^`]+`' | tr -d '`' | sort -u | while read -r k; do
  jq -e --arg k "$k" '.alarms[] | select(.key==$k)' "$AL" >/dev/null || echo "$k"; done; }
[ -z "$(drift "$tmp/pages/ok.md")" ] && ok "page naming contract keys: no drift" || bad "false drift"
[ "$(drift "$tmp/pages/drift.md")" = brand_new_alarm ] && ok "page naming an unknown key: drift reported" || bad "drift missed"
if [ -n "${ALARM_PAGES:-}" ]; then
  d="$(drift $ALARM_PAGES)"; [ -z "$d" ] && ok "real pages: no drift" || bad "real pages name keys outside the contract: $d"
fi

# claude-operated.sh
mkdir -p "$tmp/root/hooks"; : >"$tmp/root/hooks/real.sh"
cat >"$tmp/p.md" <<'P'
- rule one (⚙ hooks/real.sh) resolves
- rule two (⚙ hooks/missing.sh = SPEC) does not resolve
- grade rule (⚙ hooks/judge-missing.sh) is a judgment turn, exempt
- money rule: raise a cost limit (⚙ hooks/cost-missing.sh) exempt
- no pointer here, only text
P
r="$("$CO" --roots "$tmp/root" "$tmp/p.md")"
[ "$(printf '%s' "$r" | jq 'length')" = 1 ] && [ "$(printf '%s' "$r" | jq -r '.[0].pointer')" = hooks/missing.sh ] && [ "$(printf '%s' "$r" | jq '.[0].line')" = 2 ] \
  && ok "unresolved pointer listed once; resolved and exempt lines skipped" || bad "claude-operated output: $r"
"$CO" >/dev/null 2>&1; [ $? = 64 ] && ok "no pages: exit 64" || bad "no-arg exit"

# --render
printf '{"claude_operated":[],"needs_joe":["x","y"],"carbon":{"build_procs":0}}\n' >"$tmp/st.json"
FLEET_STATUS_DIR="$tmp/d" "$W" --render "$tmp/st.json"; rc=$?
f="$tmp/d/fleet-status.md"
[ "$rc" = 0 ] && grep -q '^claude_operated: 0 item(s)$' "$f" && grep -q '^needs_joe: 2 item(s)$' "$f" && grep -q '^carbon.build_procs: 0$' "$f" \
  && grep -q '^hand_prs: unknown$' "$f" && ok "render: values shown, absent field = unknown" || bad "render output"
! grep -q 'First act' "$f" && ok "render carries no ctl prompt line" || bad "prompt line in render"
FLEET_STATUS_DIR="$tmp/d" "$W" --render "$tmp/none.json" 2>/dev/null; [ $? = 64 ] && ok "render of missing file: exit 64" || bad "render missing-file exit"

[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAIL"; exit "$fail"
