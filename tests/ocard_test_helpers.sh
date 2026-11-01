#!/usr/bin/env bash
# tests/ocard_test_helpers.sh — shared fixture builder for tests/ocard_ac*.test.sh
# (PRD dotfiles-operator-status-card). Builds an isolated wm-build state dir
# (state.db, journal, binary, fake proc/systemctl/agorabus), a synthorg chain
# dir and an operator cache dir, then points the scripts at them via env.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hermetic_sqlite3.sh"   # PATH sqlite3 that cannot create a db (ryzen7 ro wrapper) -> rw stand-in, else FAIL

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN="$ROOT/.claude/scripts/operator-status-gen.sh"
CARD="$ROOT/.claude/scripts/operator-status-card.sh"
NOTICES="$ROOT/.claude/hooks/operator-notices.sh"

fail=0
assert_eq() { # $1=actual $2=expected $3=description
  if [ "$1" = "$2" ]; then echo "ok - $3"
  else echo "NOT OK - $3: got '$1', want '$2'"; fail=1; fi
}
assert_contains() { # $1=haystack $2=needle $3=description
  case "$1" in *"$2"*) echo "ok - $3" ;; *) echo "NOT OK - $3: '$1' does not contain '$2'"; fail=1 ;; esac
}

iso_ago() { date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%S.000000000+00:00; }

# ocard_setup — creates $work with every source; exports the env the scripts read.
# Knobs (set before calling): OC_STARTED (daemon_started_at), OC_BIN_VERSION, OC_RUN_VERSION.
ocard_setup() {
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  mkdir -p "$work/state" "$work/bin" "$work/cache" "$work/syn/runs" "$work/proc/4242"
  local db="$work/state/state.db"
  sqlite3 "$db" "
    create table runs (id integer primary key, slug text, started text, ended text, stage text, created_by text, mode text);
    create table meta (key text primary key, value text);
    create table decisions (id integer primary key, question text, opened text, closed text, ref_ text, run_id text, cause text, closed_at text);
    create table effective_config (key text primary key, value text, source text, loaded_at text);
    insert into runs values (488,'alpha','$(iso_ago 1738)',null,'land','tick','daemon');
    insert into runs values (518,'beta','$(iso_ago 4)',null,'inner','tick','daemon');
    insert into runs values (519,'gamma','$(iso_ago 3)',null,'inner','hand','direct');
    insert into runs values (400,'old','$(iso_ago 900)','$(iso_ago 800)','land','tick','daemon');
    insert into meta values ('daemon_started_at','${OC_STARTED:-$(iso_ago 120)}');
    insert into decisions values (7,'q','$(iso_ago 30)',null,null,'488','cordon',null);
    insert into effective_config values ('inner.wall_minutes','240','file','$(iso_ago 60)');
    insert into effective_config values ('gate.wall_minutes','${OC_GATE_WALL:-180}','file','$(iso_ago 60)');"
  # journal: 300 MB sparse prefix, ~600 KB of filler, then the tick row in the last 1 MB
  local j="$work/state/journal.jsonl"
  truncate -s 300M "$j"
  printf '\n' >>"$j"
  head -c 600000 /dev/zero | tr '\0' 'x' >>"$j"
  printf '\n{"op":"tick","row":{"admitted":["s1","s2"],"skipped":[{"reason":"claimed-by:redbaron","slug":"s3","operands":{}},{"reason":"cap=max_runs","slug":"s4","operands":{}}],"slots":3,"boxes":{"coder":{"boxes":1}},"config_loaded_at":"%s"}}\n' "$(iso_ago 60)" >>"$j"
  # chain ledger: 2 rows
  printf '%s\n' '{"chain_run_id":"c1","link":"explore","status":"ok","ts":"2026-10-10T07:00:00Z"}' \
                '{"chain_run_id":"c2","link":"digest","status":"running","ts":"2026-10-11T07:00:00Z"}' >"$work/syn/runs/chain-ledger.jsonl"
  # binary on disk + the process the unit points at
  printf '#!/bin/sh\necho "wm-build %s"\n' "${OC_BIN_VERSION:-0.2.0}" >"$work/bin/wm-build"
  printf '#!/bin/sh\necho "wm-build %s"\n' "${OC_RUN_VERSION:-0.1.0}" >"$work/proc/4242/exe"
  chmod +x "$work/bin/wm-build" "$work/proc/4242/exe"
  # fake systemctl + agorabus
  cat >"$work/bin/systemctl" <<'SC'
#!/bin/sh
echo "ExecMainPID=4242"
echo "ExecMainStartTimestamp=Sun 2026-10-11 00:43:18 PDT"
SC
  cat >"$work/bin/agorabus" <<'AB'
#!/bin/sh
[ "$1 $2" = "intent list" ] && cat "$OC_INTENTS"
AB
  chmod +x "$work/bin/systemctl" "$work/bin/agorabus"
  export OC_INTENTS="$work/intents.json"
  cat >"$OC_INTENTS" <<'IN'
[{"session_id":"claude-self","skill":"claude","prd":"mine","since":"2026-10-11T06:00:00Z"},
 {"session_id":"claude-2576670","skill":"dream","prd":"T9","since":"2026-10-11T06:58:00Z"},
 {"session_id":"claude-9","skill":"build","prd":"p2","since":"2026-10-11T07:10:00Z"}]
IN
  export CLAUDE_AGORABUS_SID="claude-self"
  export WM_BUILD_STATE_DIR="$work/state" OPERATOR_WM_BIN="$work/bin/wm-build" OPERATOR_PROC_ROOT="$work/proc"
  export SYNTHORG_STATE_DIR="$work/syn" OPERATOR_CACHE_DIR="$work/cache" WM_BUILD_CONFIG="$work/config.toml"
  : >"$WM_BUILD_CONFIG"
  # fleet-dash status.json: fresh ts + the fleet-wide queue object the card reads
  export OPERATOR_FLEET_STATUS="$work/fleet-status.json"
  printf '{"ts":%s,"queue":{"queue_total":12,"queue_ready":5,"building":2,"blocked":3,"parked":2}}\n' "$(date +%s)" >"$OPERATOR_FLEET_STATUS"
  export PATH="$work/bin:$PATH"
  export HOME="$work/home"; mkdir -p "$HOME"
}
