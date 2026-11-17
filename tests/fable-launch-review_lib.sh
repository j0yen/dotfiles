#!/usr/bin/env bash
# fable-launch-review_lib.sh: shared harness for tests/fable-launch-review_ac0N_*.test.sh (PRD fable-launch-review-scope-guard, A1719).
# The skill-launch-route.test.sh seams: spy claude (records its args; sleeps FLR_SPY_SLEEP s and exits FLR_SPY_RC when set), FABLE_LAUNCH_TEST=1,
# private lane state, the test lane policy, SKILL_ROUTING_DECISIONS in a temp dir, decision_class plus evidence refs, liveness by
# `exec -a 'claude --session-id <sid>' sleep`. No provider call, no real credential, no real decisions log. Source it from a test file.
set -u
# A1300 FFDR F11: a routed worker or a launcher-started session that runs this suite must not leak its markers into the launches under test
# (an inherited SKILL_ROUTE_ROLE=review would deny every routed launch as nested dispatch). A test that wants one sets it after sourcing.
unset SKILL_ROUTE_ROLE SKILL_ROUTE_SESSION SKILL_ROUTE_SCOPE_ID SKILL_ROUTE_TASK_ID SKILL_ROUTE_SKILL SKILL_ROUTE_ROUTE SKILL_ROUTE_EFFORT \
  SKILL_ROUTE_TERMINAL SKILL_ROUTE_RESOLVER FABLE_LAUNCH_ACCOUNT FABLE_LAUNCH_MODEL FABLE_LAUNCH_ACK_UNKNOWN_EFFECT
D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; L="$D/.local/bin/fable-launch.sh"
FX="$D/tests/fixtures/skill-routing/review-scope"
T="$(mktemp -d)"; FLR_BG=()
flr_cleanup(){ local q; for q in "${FLR_BG[@]}"; do kill "$q" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$T"; }
trap flr_cleanup EXIT
mkdir -p "$T/store"; printf 'TOKEN-JOSEPH-xxxxxxxx' >"$T/store/josephsyen"; printf 'TOKEN-TECH-zzzzzzzz' >"$T/store/jyen.tech"
printf 'TOKEN-PM-yyyyyyyy' >"$T/store/jyen.pm"; printf 'TOKEN-MCP-wwwwwwww' >"$T/store/mcphost.dev"; chmod 600 "$T/store"/*
cat >"$T/claude" <<'S'
#!/usr/bin/env bash
case "${CLAUDE_CODE_OAUTH_TOKEN:-}" in TOKEN-PM-*) a=jyen.pm;; TOKEN-JOSEPH-*) a=josephsyen;; TOKEN-TECH-*) a=jyen.tech;; TOKEN-MCP-*) a=mcphost.dev;; *) a=none;; esac
echo "spy acct=$a task=${SKILL_ROUTE_TASK_ID:-} args=$*" >>"$SPYLOG"
[ -z "${FLR_SPY_SLEEP:-}" ] || sleep "$FLR_SPY_SLEEP"
exit "${FLR_SPY_RC:-0}"
S
chmod +x "$T/claude"; echo e >"$T/ev.md"
DEC="$T/dec.jsonl"
export FABLE_RR_DIR="$T/rr" FABLE_LAUNCH_TEST=1 FABLE_TOKEN_STORE="$T/store" FABLE_CLAUDE_BIN="$T/claude" SPYLOG="$T/spy.log"
export ACCOUNT_LANE_STATE="$T/lanes" ACCOUNT_LANE_POLICY="${ACCOUNT_LANE_POLICY:-$D/tests/fixtures/account-lanes/policy.test.json}" ACCOUNT_LANE_TEST=1 ACCOUNT_LANE_NOW=1800000000
export SKILL_ROUTE_POLICY="$D/.config/skill-routing/policy.json" SKILL_ROUTING_DECISIONS="$DEC" SKILL_ROUTE_LEDGER_IDS="$T/ids.txt"
printf 'A1300\n' >"$SKILL_ROUTE_LEDGER_IDS"
FLR_FIELDS='["ts","decision","task_id","skill","route","model","effort","account","session","resume","reasons","role","scope","scope_id"]'
p=0; f=0; ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
uuid(){ cat /proc/sys/kernel/random/uuid; }

# flr_begin [torn]: seed the log with rows written before install (no role); `torn` adds a torn line and a non-object line after them.
flr_begin(){
  cat >"$DEC" <<'J'
{"ts":"2026-11-01T00:00:00-08:00","decision":"launch","task_id":"LEGACY1","skill":"dream","route":"fable-xhigh","model":"claude-fable-5-1","effort":"xhigh","account":"jyen.pm","session":"00000000-0000-4000-8000-000000000001","resume":false,"reasons":"row written before install"}
{"ts":"2026-11-01T00:00:01-08:00","decision":"denied","task_id":"LEGACY1","skill":"dream","route":"","model":"","effort":"","account":"","session":"","resume":false,"reasons":"denied before install"}
J
  [ "${1:-}" != torn ] || printf '%s\n' '{"ts":"2026-11-01T00:00:02-08:00","decision":"launch","task_id":"LEG' '123' >>"$DEC"
  FLR_P0="$(wc -c <"$DEC")"; FLR_P0SHA="$(sha256sum <"$DEC" | cut -c1-64)"; flr_mark
}
flr_mark(){ FLR_CK="$(wc -c <"$DEC")"; FLR_CKSHA="$(head -c "$FLR_CK" "$DEC" | sha256sum | cut -c1-64)"; }
# The log's first bytes (at flr_begin and at the last mark) are unchanged, and every row appended since the mark is one JSON object with R1's fourteen fields in order.
flr_appended_ok(){
  [ "$(head -c "$FLR_P0" "$DEC" | sha256sum | cut -c1-64)" = "$FLR_P0SHA" ] || return 1
  [ "$(head -c "$FLR_CK" "$DEC" | sha256sum | cut -c1-64)" = "$FLR_CKSHA" ] || return 1
  [ -z "$(tail -c1 "$DEC" | tr -d '\n')" ] || return 1
  tail -c +"$((FLR_CK+1))" "$DEC" | jq -R -s -e --argjson k "$FLR_FIELDS" 'split("\n") | map(select(length>0) | fromjson | type=="object" and keys_unsorted==$k) | all' >/dev/null 2>&1
}
# flr_inject JSON: append a hand-written row (a test fixture, not a launcher row) after checking what the launcher appended so far.
flr_inject(){ ck "log prefix unchanged, launcher rows carry the fourteen fields (before an injected row)" flr_appended_ok; printf '%s\n' "$1" >>"$DEC"; flr_mark; }
flr_end(){ ck "log prefix unchanged, every appended launcher row carries R1's fourteen fields" flr_appended_ok; echo "pass=$p fail=$f"; [ "$f" = 0 ] && echo ALL PASS; [ "$f" = 0 ]; }

# flr_req NAME TASK [SNAPSHOT|-] [jq filter]: a dream route request (decision_class + evidence refs); SNAPSHOT adds review{reason,evidence,snapshot}.
# The class, consequential_uncertainty, resolves to opus-xhigh (claude-opus-5-5 xhigh) since A1300 FFDR: the nonfable lane, see flr_nf.
flr_req(){
  local s="${3:--}"
  jq -nc --arg t "$2" --arg s "$s" --arg ev "file:$T/ev.md" \
    '{task_id:$t,skill:"dream",decision_class:"consequential_uncertainty",evidence_refs:["ledger:A1300",$ev]}
     | if $s != "-" then .review={reason:"independent_verifier_required",evidence:["ledger:A1300",$ev],snapshot:$s} else . end' \
    | jq -c "${4:-.}" >"$T/req.$1.json"
}
# flr_run NAME REQ args...: run the launcher in the foreground; FLR_RC (also $T/rc.NAME), $T/err.NAME, $T/spy.NAME and the rows it appended in $T/new.NAME.
flr_run(){
  local n="$1" r="$2" before; shift 2; before="$(wc -l <"$DEC")"; : >"$T/spy.$n"
  SPYLOG="$T/spy.$n" "$L" --route-request "$T/req.$r.json" "$@" 2>"$T/err.$n"; FLR_RC=$?; echo "$FLR_RC" >"$T/rc.$n"
  tail -n +"$((before+1))" "$DEC" >"$T/new.$n"
}
# flr_bg NAME REQ args...: the same in the background; the exit code lands in $T/rc.NAME.
flr_bg(){ local n="$1" r="$2"; shift 2; : >"$T/spy.$n"; ( SPYLOG="$T/spy.$n" "$L" --route-request "$T/req.$r.json" "$@" 2>"$T/err.$n"; echo $? >"$T/rc.$n" ) & FLR_BG+=($!); }
# flr_live SID: a process whose argv carries the id (the liveness both argv-substring tests see); its pid is FLR_LIVE.
flr_live(){ bash -c "exec -a 'claude --session-id $1' sleep 60" & FLR_LIVE=$!; FLR_BG+=("$FLR_LIVE"); sleep 0.3; }
flr_kill(){ kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }
flr_count(){ jq -R -r --arg d "$2" 'fromjson? | objects | select(.decision==$d) | .decision' "$T/new.$1" | wc -l | tr -d ' '; }
flr_get(){ jq -R -r "fromjson? | objects | $2" "$T/new.$1" | tail -1; }   # prints one line: end an object-valued filter in tojson
flr_spy_empty(){ [ ! -s "$T/spy.$1" ]; }
# flr_nf N: the account the nonfable lane's persistent round-robin (A1221) gives the N-th fresh claim (from 0) of this file's private lane
# state when no primary is exhausted: primaries[N % length] of the lane policy in use. flr_req's dream route is Opus since A1300 FFDR,
# a non-Fable model, so its launches take their account by this rule (a Fable route would take the fable lane's first account).
flr_nf(){ jq -r --argjson n "$1" '.lanes.nonfable.primaries | .[$n % length]' "$ACCOUNT_LANE_POLICY"; }

# The rows.jsonl scenario (R9): author launch, review launch, same-scope denied, author denied, resume denied, for task $1, run from $FX/..
flr_rows_scenario(){
  local t="$1" sa sr sr2 lp
  flr_req rsA "$t"; (cd "$FX/.." && flr_run rs1 rsA -p x)
  sa="$(flr_get rs1 .session)"; sr="$(uuid)"; sr2="$(uuid)"
  flr_req rsR "$t" review-scope/happy.sha256; (cd "$FX/.." && flr_run rs2 rsR --session-id "$sr" -p x)
  flr_req rsP "$t" review-scope/prefixed.sha256; flr_live "$sr"; lp=$FLR_LIVE
  (cd "$FX/.." && flr_run rs3 rsP --session-id "$sr2" -p x); flr_kill "$lp"
  flr_live "$sa"; lp=$FLR_LIVE; (cd "$FX/.." && flr_run rs4 rsA -p x); flr_kill "$lp"
  (cd "$FX/.." && flr_run rs5 rsR --resume "$sa" -p x)
  cat "$T/new.rs1" "$T/new.rs2" "$T/new.rs3" "$T/new.rs4" "$T/new.rs5"
}
# Comparable form of a row: ts, session and account dropped, ids and pids inside reasons masked, scope made relative to the fixture directory.
flr_norm(){ jq -c --arg fx "$FX/" 'del(.ts,.session,.account)
  | .reasons |= (gsub("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";"<id>") | gsub("pid [0-9 ]+";"pid <pid> "))
  | .scope |= (if startswith($fx) then .[($fx|length):] else . end)'; }

# Recording (not run by any test; AC 7 compares against the checked-in files and never regenerates them).
# flr_record_inputs: stubs and manifests; every digest is sha256sum's own output.
flr_record_inputs(){
  local o="$FX" s; mkdir -p "$o/sub" "$o/other"; s="$(mktemp -d)"
  printf '# PRD-rs-alpha\n\nReview-scope fixture stub alpha.\n' >"$o/PRD-rs-alpha.md"
  printf '# PRD-rs-beta\n\nReview-scope fixture stub beta.\n' >"$o/PRD-rs-beta.md"
  printf 'notes stub\n' >"$o/notes.md"
  cp "$o/PRD-rs-alpha.md" "$o/PRD-rs-beta.md" "$o/notes.md" "$o/sub/"
  printf 'notes stub (other)\n' >"$o/other/notes.md"
  printf '# PRD-rs-alpha\n\nReview-scope fixture stub alpha (other, differing).\n' >"$o/other/PRD-rs-alpha.md"
  printf '# PRD-rs-alpha\n\nReview-scope fixture stub alpha, before an edit.\n' >"$s/PRD-rs-alpha.md"
  ( cd "$o" || exit 1
    sha256sum PRD-rs-alpha.md PRD-rs-beta.md notes.md >happy.sha256
    sha256sum notes.md PRD-rs-beta.md PRD-rs-alpha.md >reordered.sha256
    sha256sum sub/PRD-rs-alpha.md sub/PRD-rs-beta.md sub/notes.md >prefixed.sha256
    { cat happy.sha256; sha256sum PRD-rs-alpha.md; } >dupline.sha256
    { cat happy.sha256; sha256sum other/notes.md; } >dupname.sha256
    sha256sum PRD-rs-alpha.md >single.sha256
    sed 's/$/\r/' happy.sha256 >crlf.sha256
    { head -1 happy.sha256; echo; tail -n +2 happy.sha256; } >blank.sha256
    head -c -1 happy.sha256 >nonl.sha256
    sha256sum notes.md >noprd.sha256
    { cat happy.sha256; sha256sum other/PRD-rs-alpha.md; } >dupprd.sha256
    { (cd "$s" && sha256sum PRD-rs-alpha.md); sha256sum PRD-rs-beta.md; } >stale.sha256
    (cd .. && sha256sum review-scope/PRD-rs-alpha.md review-scope/PRD-rs-beta.md) >cwdonly.sha256
    { sha256sum PRD-rs-alpha.md; printf '%s  missing-\377.md\n' "$(sha256sum notes.md | cut -c1-64)"; } >nonutf8.sha256 )
  rm -rf "$s"
}
FLR_VECTORS="happy reordered prefixed dupline dupname single crlf blank nonl noprd dupprd stale cwdonly nonutf8"
# flr_vector NAME: one review launch for a manifest from $FX/.. under its own task and pre-drawn id; prints the launcher column and the row's scope_id.
flr_vector(){
  local n="$1" sid; sid="$(uuid)"; flr_req "v$n" "VEC-$n" "review-scope/$n.sha256"; (cd "$FX/.." && flr_run "v$n" "v$n" --session-id "$sid" -p x)
  if [ "$(flr_count "v$n" launch)" = 1 ]; then printf 'ok\t%s\n' "$(flr_get "v$n" .scope_id)"; return; fi
  local why; why="$(flr_get "v$n" 'select(.decision=="denied") | .reasons')"
  local c; for c in line-rule no-prd prd-repeat sha256sum; do case "$why" in *": $c "*|*": $c") printf 'refused:%s\t%s\n' "$c" "$(flr_get "v$n" 'select(.decision=="denied") | .scope_id')"; return;; esac; done
  printf 'unexpected\t\n'
}
# flr_record_vectors: scope-vectors.tsv from the launcher's own rows, rows.jsonl from the scenario, README with the provenance.
flr_record_vectors(){
  local n out id head lsha
  flr_begin; printf 'manifest\tcanonical\tlauncher\n' >"$FX/scope-vectors.tsv"
  for n in $FLR_VECTORS; do
    out="$(flr_vector "$n")"; id="${out#*$'\t'}"
    case "$out" in ok*|refused:no-prd*|refused:sha256sum*) printf '%s.sha256\t%s\t%s\n' "$n" "$id" "${out%%$'\t'*}" ;;
                   *) printf '%s.sha256\t%s\t%s\n' "$n" "${out%%$'\t'*}" "${out%%$'\t'*}" ;; esac >>"$FX/scope-vectors.tsv"
  done
  flr_rows_scenario RS-ROWS >"$T/rows.raw"
  jq -c --arg fx "$FX/" '.scope |= (if startswith($fx) then .[($fx|length):] else . end)' "$T/rows.raw" >"$FX/rows.jsonl"
  head="$(git -C "$D" rev-parse HEAD)"; lsha="$(sha256sum "$L" | cut -c1-64)"
  { echo "# review-scope fixture (PRD fable-launch-review-scope-guard R9)"
    echo
    echo "Recorded by running the launcher's own path (\`flr_record_inputs\` then \`flr_record_vectors\` in \`tests/fable-launch-review_lib.sh\`); no digest or scope id here was computed by hand."
    echo
    echo "- Launcher source commit: \`$head\` (dotfiles), \`.local/bin/fable-launch.sh\` sha256 \`$lsha\`."
    echo "- Stubs: \`PRD-rs-alpha.md\`, \`PRD-rs-beta.md\`, \`notes.md\`; byte-identical copies under \`sub/\`; differing \`other/notes.md\` and \`other/PRD-rs-alpha.md\`."
    echo "- Manifests (\`<name>.sha256\`, paths relative to this directory): $(for n in $FLR_VECTORS; do printf '`%s` ' "$n"; done)."
    echo "- \`scope-vectors.tsv\`: \`manifest\`, \`canonical\` (the scope_id, or \`refused:line-rule\` | \`refused:prd-repeat\`), \`launcher\` (\`ok\` or \`refused:<check>\`). Each id is the \`scope_id\` of the row the launcher wrote for that manifest: launch rows for \`ok\`, denied rows for \`refused:no-prd\` and \`refused:sha256sum\`. Each vector was launched from the parent directory as \`review-scope/<name>.sha256\` under task \`VEC-<name>\` with a pre-drawn \`--session-id\`."
    echo "- \`rows.jsonl\`: the rows the launcher wrote for task \`RS-ROWS\`, in order: author launch, review launch (\`happy\`), same-scope denied (\`prefixed\` beside a live \`happy\` reviewer), author denied (beside the live author), resume denied (the author session resumed with \`happy\`)."
    echo "- Rewrite: \`scope\` in \`rows.jsonl\` is the manifest's path relative to this directory; the original values were the absolute paths \`$FX/<name>.sha256\` (recorded in a clone at that path). AC 7 compares every field but \`ts\`, \`session\`, \`account\` and the ids and pids inside \`reasons\`."
    echo "- \`crlf.sha256\` and \`nonutf8.sha256\` are byte-exact fixtures (CR line ends; a non-UTF-8 byte in a path): mark them \`-text\` in any \`.gitattributes\` either repo adds. Neither repo has one today."
  } >"$FX/README.md"
}
