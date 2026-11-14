#!/usr/bin/env bash
# Test (A1572 ops-identity amendment 11-13, leaf 3): private fixture with a fake child and isolated HOME/inbox/ledger/wake roots.
# `--seat ops` reaches the same coordinator identity and state as legacy ctl/aide with one consumer; bld/rls/plain stay separate.
# Negative controls: concurrent alias (inbox reads and a real private-socket tmux launch), wrong seat, wrong task lane,
# unavailable authority, malformed mapping, alias spelling gets no separate model row.
# Source fixture only: the installed alias stays UNPROVEN until a fresh-child canary or natural resume runs the installed path on its host.
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"; L="$R/.local/bin/ctl-launch.sh"; IH="$R/.claude/hooks/aide-inbox.sh"; MRC="$R/.claude/hooks/model-role-check.sh"
T=$(mktemp -d); S=$(mktemp -d /tmp/oa.XXXXXX)   # S = short dir for the private tmux socket (sun_path limit)
cleanup() { [ -S "$S/s" ] && tmux -S "$S/s" kill-server >/dev/null 2>&1; rm -rf "$T" "$S"; }
trap cleanup EXIT
fail=0
chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" CHILD_LOG="$T/child.log"
D="$HOME/.cache/fleet-dash"
mkdir -p "$HOME/.config/environment.d" "$HOME/.config/wm-decide" "$D"
POL='{"ctl":{"model":"claude-sonnet-5-5","effort":"medium"}}'
set_pol() { printf '%s\n' "$1" > "$HOME/.config/wm-decide/seat-model-hold.json"; }
set_pol "$POL"
printf 'CLAUDE_CODE_OAUTH_TOKEN=fixture-not-a-token\n' > "$HOME/.config/environment.d/90-claude-oauth.conf"
printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$HOME" > "$T/cj"
printf 'MemAvailable: 33554432 kB\n' > "$T/meminfo"
# fake child: appends the identity it was handed, one line per start; CHILD_HOLD keeps it alive (tmux duplicate check)
cat > "$T/child" <<'EOF'
#!/bin/sh
printf 'SEAT=%s WAKE=%s LANE=%s ARGS=%s\n' "${WM_SEAT:-}" "${AIDE_WAKE_DIR:-}" "${WM_AIDE_LANE:-}" "$*" >> "$CHILD_LOG"
[ -n "${CHILD_HOLD:-}" ] && exec sleep 60
exit 0
EOF
chmod +x "$T/child"
CLEAN=(-u TMUX -u TMUX_PANE -u WM_SEAT -u WM_AIDE_LANE -u AIDE_WAKE_DIR -u AIDE_TMUX -u AIDE_TMUX_BIN -u AIDE_USE_AGENTNS -u EVENTS_DIR -u FLEET_DASH_DIR -u ACCOUNT_LANE_POLICY -u ACCOUNT_LANE_PY)
launch() { : > "$CHILD_LOG"; env "${CLEAN[@]}" AIDE_CLAUDE_JSON="$T/cj" AIDE_CLAUDE_BIN="$T/child" "$L" "$@" >"$T/launch.err" 2>&1; echo $?; }
starts() { local n; n=$(grep -c '' "$CHILD_LOG" 2>/dev/null); echo "${n:-0}"; }
refused() { # refused <name> <rc> : non-zero exit and the fake child never started (status taken before chk's own substitutions)
  local n ok; n=$(starts); [ "$2" != 0 ] && [ "$n" = 0 ]; ok=$?; chk "$1 (rc=$2, child starts=$n)" $ok; }
hook() { # hook <seat> <event> [stdin-json]; lane from $LANE
  printf '%s' "${3:-}" | env "${CLEAN[@]}" WM_AIDE_LANE="${LANE:-main}" WM_SEAT="$1" bash "$IH" "$2" 2>&1; }
M=claude-sonnet-5-5
ARGS="--dangerously-skip-permissions --model $M --effort medium"

# 1. identity: default, --seat ctl and --seat ops hand the child the same identity, one start each
rc=$(launch --model $M); a=$(cat "$CHILD_LOG"); n1=$(starts)
rc2=$(launch --seat ctl --model $M); b=$(cat "$CHILD_LOG")
rc3=$(launch --seat ops --model $M); c=$(cat "$CHILD_LOG"); n3=$(starts)
[ "$rc$rc2$rc3" = 000 ] && [ "$n1$n3" = 11 ] && [ "$a" = "SEAT=ctl WAKE= LANE=main ARGS=$ARGS" ] && [ "$b" = "$a" ] && [ "$c" = "$a" ]
chk "ops = ctl = default: same WM_SEAT, wake, lane, pinned args; one child start" $?
rc=$(launch --seat bld --model $M); [ "$rc" = 0 ] && [ "$(cat "$CHILD_LOG")" = "SEAT=bld WAKE=$HOME/.cache/bld LANE=main ARGS=$ARGS" ]
chk "bld stays a separate seat and wake root" $?

# 2. wake root inside tmux: ops records the pane where ctl does; bld records its own and leaves the coordinator's pane alone
TMUX=fx TMUX_PANE=%7 env -u WM_SEAT -u AIDE_WAKE_DIR AIDE_CLAUDE_JSON="$T/cj" AIDE_CLAUDE_BIN="$T/child" "$L" --seat ops --model $M >/dev/null 2>&1
TMUX=fx TMUX_PANE=%8 env -u WM_SEAT -u AIDE_WAKE_DIR AIDE_CLAUDE_JSON="$T/cj" AIDE_CLAUDE_BIN="$T/child" "$L" --seat bld --model $M >/dev/null 2>&1
[ "$(cat "$HOME/.cache/aide/pane" 2>/dev/null)" = %7 ] && [ "$(cat "$HOME/.cache/bld/pane" 2>/dev/null)" = %8 ]
chk "ops pane in ~/.cache/aide (ctl wake root), bld pane in ~/.cache/bld" $?

# 3. one consumer across spellings: ops, ctl, aide share one inbox cursor and one sid ledger
printf 't | x | m1\nt | x | m2\n' > "$D/aide-events.log"
o=$(hook ops UserPromptSubmit); grep -q m1 <<<"$o" && grep -q m2 <<<"$o"; chk "ops reads the ctl inbox" $?
o1=$(hook ctl UserPromptSubmit); o2=$(hook aide UserPromptSubmit); [ -z "$o1$o2" ]; chk "ctl and aide see the lines ops consumed as read" $?
printf 't | x | m3\n' >> "$D/aide-events.log"
o=$(hook aide UserPromptSubmit); o2=$(hook ops UserPromptSubmit); grep -q m3 <<<"$o" && [ -z "$o2" ]; chk "a line read by aide is not re-delivered to ops" $?
hook ops SessionStart '{"session_id":"sid-opsx-0001"}' >/dev/null; hook ctl SessionStart '{"session_id":"sid-opsx-0001"}' >/dev/null
hook bld SessionStart '{"session_id":"sid-bldx-0001"}' >/dev/null
[ "$(grep -c '^sid-opsx-0001 ' "$D/aide-sids")" = 1 ] && ! grep -q sid-bldx "$D/aide-sids" && grep -q '^sid-bldx-0001 ' "$HOME/.cache/bld/aide-sids"
chk "sid ledger: ops and ctl one row in the coordinator ledger, bld in its own" $?

# 4. separate seats do not consume the coordinator inbox
printf 't | x | m4\n' >> "$D/aide-events.log"; cur=$(cat "$D/aide-events.cursor")
leak=""; for s in bld rls rb r7 ""; do leak="$leak$(hook "$s" UserPromptSubmit)"; done
! grep -q m4 <<<"$leak" && [ "$(cat "$D/aide-events.cursor")" = "$cur" ]; chk "bld/rls/rb/r7/plain leave the coordinator line and cursor alone" $?
o=$(hook ops UserPromptSubmit); grep -q m4 <<<"$o"; chk "ops then reads it" $?

# 5. concurrent alias reads: 5 rounds x 40 lines, 5 readers (ops/ctl/aide) at once; each line delivered exactly once
: > "$D/aide-events.log"; rm -f "$D/aide-events.cursor"
for r in 1 2 3 4 5; do
  for i in $(seq -w 1 40); do printf 't | x | c=%s-%s\n' "$r" "$i" >> "$D/aide-events.log"; done
  j=0; for s in ops ctl aide ops ctl; do j=$((j+1)); hook "$s" UserPromptSubmit > "$T/cc.$r.$j" & done; wait
done
hook ops UserPromptSubmit > "$T/cc.drain"
cat "$T"/cc.* | grep -oE 'c=[0-9]-[0-9]{2}' | sort | uniq -c > "$T/counts"
[ "$(grep -c '' "$T/counts")" = 200 ] && ! awk '$1!=1{f=1} END{exit !f}' "$T/counts"
chk "concurrent ops/ctl/aide readers: 200 lines, each delivered once" $?

# 6. concurrent alias launch (real tmux, private socket): ops holds session `aide`; ctl collides on it; bld gets its own session
if command -v tmux >/dev/null 2>&1; then
  # wrapper: the launcher's own `new-session -s <name> <script> args...`, detached (-d), on the private socket
  cat > "$T/tmuxw" <<EOF
#!/usr/bin/env bash
c=\$1; shift; exec tmux -S "$S/s" "\$c" -d "\$@"
EOF
  chmod +x "$T/tmuxw"
  tl() { : > "$CHILD_LOG"; env "${CLEAN[@]}" CHILD_HOLD=1 AIDE_TMUX=1 AIDE_TMUX_BIN="$T/tmuxw" AIDE_CLAUDE_JSON="$T/cj" AIDE_CLAUDE_BIN="$T/child" "$L" "$@" >"$T/launch.err" 2>&1; echo $?; }
  waitc() { for _ in $(seq 50); do [ "$(starts)" -ge 1 ] && return 0; sleep 0.1; done; return 1; }
  rm -f "$HOME/.cache/aide/pane"
  r1=$(tl --seat ops --model $M); waitc; o1=$(cat "$CHILD_LOG")
  [ "$r1" = 0 ] && [ "$o1" = "SEAT=ctl WAKE= LANE=main ARGS=$ARGS" ] && grep -qE '^%[0-9]+$' "$HOME/.cache/aide/pane" && tmux -S "$S/s" has-session -t aide 2>/dev/null
  chk "tmux: ops starts in session aide with ctl identity and records the pane" $?
  r2=$(tl --seat ctl --model $M); sleep 0.5
  [ "$r2" != 0 ] && [ "$(starts)" = 0 ] && grep -q 'duplicate session' "$T/launch.err"
  chk "tmux: concurrent ctl launch refused while ops holds aide (rc=$r2), no second child" $?
  r3=$(tl --seat bld --model $M); waitc
  [ "$r3" = 0 ] && [ "$(cat "$CHILD_LOG")" = "SEAT=bld WAKE=$HOME/.cache/bld LANE=main ARGS=$ARGS" ] && tmux -S "$S/s" has-session -t bld 2>/dev/null
  chk "tmux: bld is its own session alongside the coordinator" $?
  tmux -S "$S/s" kill-server >/dev/null 2>&1
else
  echo "FAIL tmux not installed: concurrent alias launch not exercised"; fail=1
fi

# 7. wrong seat: refused before any child start
for w in nope aide rb r7 OPS 'ops ' 'ops,ctl' ../bld ''; do refused "wrong seat '$w'" "$(launch --seat "$w" --model $M)"; done
refused "--seat with no value" "$(launch --seat)"

# 8. wrong task lane: a lane-addressed queue is not the main queue, either way
rc=$(AIDE_INBOX_HOOK="$IH" AIDE_LANE_MEMINFO="$T/meminfo" launch --seat ops --lane a1999 --model $M)
[ "$rc" = 0 ] && [ "$(cat "$CHILD_LOG")" = "SEAT=ctl WAKE= LANE=a1999 ARGS=--dangerously-skip-permissions --disallowedTools ScheduleWakeup --model $M --effort medium" ]
chk "ops --lane a1999: coordinator identity, lane a1999" $?
refused "bad lane name" "$(launch --seat ops --lane ../x --model $M)"
printf 't | x | lane-only\n' > "$D/aide-a1999-events.log"; printf 't | x | main-only\n' >> "$D/aide-events.log"; cur=$(cat "$D/aide-events.cursor")
o=$(LANE=a1999 hook ops UserPromptSubmit); grep -q lane-only <<<"$o" && ! grep -q main-only <<<"$o" && [ "$(cat "$D/aide-events.cursor")" = "$cur" ]
chk "lane a1999 reads its own queue only, main cursor untouched" $?
o=$(hook ops UserPromptSubmit); o2=$(LANE=b2000 hook ctl UserPromptSubmit); grep -q main-only <<<"$o" && ! grep -q lane-only <<<"$o" && [ -z "$o2" ]
chk "main reads main only; an unknown lane reads nothing" $?

# 9. unavailable authority: no token, missing store entry, missing policy
mv "$HOME/.config/environment.d/90-claude-oauth.conf" "$T/conf.bak"
refused "no fleet token" "$(launch --seat ops --model $M)"
mv "$T/conf.bak" "$HOME/.config/environment.d/90-claude-oauth.conf"
refused "missing --account store entry" "$(launch --seat ops --account nosuch --model $M)"
rm -f "$HOME/.config/wm-decide/seat-model-hold.json"; refused "missing model policy" "$(launch --seat ops --model $M)"

# 10. malformed mapping: broken, off-policy or ops-only policy; conflicting override
set_pol '{"ctl":'; refused "malformed policy JSON" "$(launch --seat ops --model $M)"
set_pol '{"ctl":{"model":"claude-opus-5-5","effort":"medium"}}'; refused "off-policy ctl model" "$(launch --seat ops)"
set_pol '{"ops":{"model":"claude-sonnet-5-5","effort":"medium"}}'; refused "ops-only row gives no authority" "$(launch --seat ops --model $M)"
set_pol "$POL"; refused "conflicting --model override" "$(launch --seat ops --model claude-opus-5-5)"
rc=$(launch --seat ops --model $M); [ "$rc" = 0 ] && [ "$(starts)" = 1 ]; chk "restored policy launches again" $?

# 11. an alias spelling earns no separate model row: ops is checked against the ctl row even when an ops row exists
printf 'ctl claude-sonnet-5-5\nops claude-opus-5-5\n' > "$T/table"
printf '{"type":"assistant","message":{"model":"claude-opus-5-5"}}\n' > "$T/opus.jsonl"
printf '{"type":"assistant","message":{"model":"claude-sonnet-5-5-20261101"}}\n' > "$T/sonnet.jsonl"
mrc() { printf '{"transcript_path":"%s"}' "$2" | env "${CLEAN[@]}" -u MRC_FORCE_ROLE MRC_TABLE="$T/table" MRC_SKIP_FALLBACK=1 WM_SEAT="$1" bash "$MRC" 2>&1; }
o=$(mrc ops "$T/opus.jsonl"); o2=$(mrc ops "$T/sonnet.jsonl")
grep -q 'role=ctl running=claude-opus-5-5 required=claude-sonnet-5-5' <<<"$o" && [ -z "$o2" ]
chk "ops uses the ctl model row, the ops row is ignored" $?

[ "$fail" = 0 ] && echo "TEST PASS" || { echo "TEST FAIL"; exit 1; }
