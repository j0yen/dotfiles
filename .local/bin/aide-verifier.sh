#!/usr/bin/env bash
# aide-verifier.sh: the aide's merge-gate VERIFIER unit as a mechanism (controller DECISION 0e71; was hand-written prompt.md + launch.sh per PR).
#   AGENT: AIDE_VERIFIER_AGENT (default aide; aide|rb|r7, anything else -> exit 2) is the wm-decide --agent of every row (verdict template, GATE-PASS, RETRACT),
#   the template's agent=verifier:/recorded_by=unit: fields, the bell text prefix ("<agent> EVENT ...", EVENT_SOURCE) and the unit prefix <agent>-verifier-<name>.
#   The rb/r7 seats run their own claude on carbon too, so ROOM and systemd-run are unchanged; the verdict row still comes from the headless unit's own session (G7).
#   Below, "aide" in unit/field names means <agent>; the one-at-a-time check looks at every (aide|rb|r7)-verifier-* unit.
#   launch <name> --repo O/R --pr N --head <40-hex> --gated <d-id> --token '<G3 token line>' --suite '<ONE command for wm-verify-run>'
#          [--clone-url URL] [--notes TEXT] [--expect TEXT] [--queue]
#       LINT (exit 2): name not [a-z0-9-]; head not 40 hex; --gated not d-YYYYMMDD-HHMMSS-<agent>-<4hex>; empty token (or one with " ` $ newline);
#       empty suite; the rendered verdict --what lacking COMMIT=<head> or agent=verifier:<agent>-verifier-<name>; another *-verifier-* unit active
#       (one at a time) unless --queue (wait, poll AIDE_VERIFIER_POLL_S=20, up to AIDE_VERIFIER_QUEUE_MAX_S=3600, then exit 6).
#       Then ROOM (carbon-room.sh 2048 --json, .ok true else exit 3), then systemd-run --user --unit <agent>-verifier-<name> -p MemoryMax=2G.
#       Writes $AIDE_VERIFIER_DIR/<name>/{prompt.md,launch.sh,meta,state}; launch.sh reads the prompt from the FILE (never bash -c); prints the unit name.
#   finish <name> [--pr N --repo O/R] [--again]  | watch <name> [...]  (watch waits for the unit to go inactive first, AIDE_VERIFIER_WATCH_MAX_S=3000 -> exit 6)
#       Reads result.json; no verdict row id in .result (or is_error) -> prints the verifier's final text, NO bell, exit 4. Else
#       `wm-decide merge-gate <verdict> --pr N --repo O/R`: PASS line -> gate.txt + GATE-PASS row + bell to ctl; anything else -> RETRACT correction row + bell, exit 5.
#       A second finish is a no-op (prints the first outcome) unless --again, so a bell is never doubled. Row-record failure on PASS: bell still sent, exit 7.
#   --selftest   fakes for systemd-run/systemctl/wm-decide/bell/room in a throwaway dir; touches no real unit, row or seat.
# Env: AIDE_VERIFIER_AGENT AIDE_VERIFIER_DIR (~/.local/state/aide-verifier) AIDE_VERIFIER_ROOM_CMD (carbon-room.sh) AIDE_VERIFIER_SYSTEMD_RUN AIDE_VERIFIER_SYSTEMCTL
#      AIDE_VERIFIER_WM_DECIDE AIDE_VERIFIER_BELL (seat-event.sh) AIDE_VERIFIER_TEMPLATE (a template file with {{PLACEHOLDERS}}; tests) AIDE_VERIFIER_CLAUDE
#      AIDE_VERIFIER_OAUTH_CONF AIDE_VERIFIER_UNIT_PATH (the PATH given to the unit)
# Exit: 0 ok / 1 systemd-run failed / 2 lint or usage / 3 no room / 4 no verdict row / 5 merge-gate FAIL / 6 wait timeout / 7 gate passed, row not recorded.
# Never runs the real claude itself (only the generated launch.sh does, under the unit), never merges, never prints a token (output is redacted).
set -u
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
shopt -u patsub_replacement 2>/dev/null
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
AGENT="${AIDE_VERIFIER_AGENT:-aide}"
ROOT="${AIDE_VERIFIER_DIR:-$HOME/.local/state/aide-verifier}"
ROOM_CMD="${AIDE_VERIFIER_ROOM_CMD:-carbon-room.sh}"
SD_RUN="${AIDE_VERIFIER_SYSTEMD_RUN:-systemd-run}"
SYSTEMCTL="${AIDE_VERIFIER_SYSTEMCTL:-systemctl}"
WMD="${AIDE_VERIFIER_WM_DECIDE:-wm-decide}"
BELL="${AIDE_VERIFIER_BELL:-seat-event.sh}"
POLL="${AIDE_VERIFIER_POLL_S:-20}"
UNIT_PATH="${AIDE_VERIFIER_UNIT_PATH:-$HOME/.npm-global/bin:$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin}"

die() { local rc="$1"; shift; echo "aide-verifier: $*" >&2; exit "$rc"; }
redact() { sed -E 's/(sk-[A-Za-z0-9_-]{16,}|[A-Za-z0-9_-]*oat[0-9]+-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|(TOKEN|KEY|SECRET)=[^[:space:]]+)/[redacted]/g'; }
iso() { date -Iseconds; }
case "$AGENT" in aide|rb|r7) ;; *) die 2 "AIDE_VERIFIER_AGENT must be aide, rb or r7 (got '$AGENT')" ;; esac
active_units() {
  "$SYSTEMCTL" --user list-units '*-verifier-*' --state=active,activating,deactivating,reloading --no-legend --plain 2>/dev/null \
    | awk '{print $1}' | grep -E '^(aide|rb|r7)-verifier-.*\.service$'
}
meta_get() { sed -n "s/^$2=//p" "$1/meta" 2>/dev/null | head -n1; }

default_template() {
  cat <<'TPL'
You are a merge-gate VERIFIER running as your own headless claude session (systemd unit {{AGENT}}-verifier-{{NAME}} on carbon). Target: {{REPO}} PR {{PR}}, head {{HEAD}}{{NOTES}}. Scratch dir: {{DIR}}/ — everything you create goes there. GATED row to gate: {{GATED}}.

STEPS
1. Refuse if `gh pr view {{PR}} --repo {{REPO}} --json headRefOid -q .headRefOid` != {{HEAD}} (report the real head, record no row).
2. d=$(mktemp -d -p {{DIR}}); `git clone -q {{CLONE_URL}} $d/repo && git -C $d/repo checkout -q {{HEAD}}`; confirm `git rev-parse HEAD` equals {{HEAD}}.
3. Attribution: `gh api repos/{{REPO}}/pulls/{{PR}}/commits --paginate -q '.[].commit.message'` and `gh pr view {{PR}} --repo {{REPO}} --json body -q .body`; grep each with the anchored case-insensitive regex `^[[:space:]]*(co-authored-by:|generated with)`; both counts must be 0.
4. Suite under the LIVE wrapper from inside the clone as ONE quoted string. The wrapper ~/.local/bin/wm-verify-run has NO --help flag: read its header first; it runs `bash -c` on its single argument and appends WM-VERIFY HEAD/CMD/DIRTY/EXIT lines; the log lands in ~/.local/state/swarm-decide/verify/. Shape:
   cd $d/repo && ~/.local/bin/wm-verify-run {{SUITE_Q}}
   The G3 token is `{{TOKEN}}`: that literal line must appear in the log, the wrapper's EXIT must be 0, and no FAIL line may appear.{{EXPECT}} If anything fails: STOP, report the failing names, record NO verdict.
5. ONE verdict row:
   wm-decide record --agent {{AGENT}} --via verifier --model sonnet --kind verdict --gates {{GATED}} --attach <log path> --target carbon --what "MERGE-OK {{REPO}}#{{PR}} COMMIT={{HEAD}} agent=verifier:{{AGENT}}-verifier-{{NAME}} recorded_by=unit:{{AGENT}}-verifier-{{NAME}} session=own-headless-claude-p: fresh clone == head; <N passed / 0 FAIL, from the log> via wm-verify-run ({{TOKEN}}); attribution 0/0" --why "aide-verifier.sh (DECISION 0e71): the verifier is its own session" --evidence "<log path>" --reverse-text "none (verdict row)"
   The 'ungradable:' line is informational; report any refusal verbatim.

HARD CONSTRAINTS: never merge or push; never run the real interactive claude; no ssh; no systemd changes; never write outside your scratch dir except the wm-decide row and the wrapper's own log; never touch /home/jsy/dotfiles, ~/.claude/state, ~/.cache/fleet-dash; never delete anything outside your own mktemp dirs; tool output > 2 KB to a file in the scratch dir; never print key material or a token.

FINAL OUTPUT (plain text, at most 15 lines): head, attribution counts, test counts + the token line, then exactly `LOG: <absolute log path>` and `VERDICT: <verdict row id>` on their own lines, refusals.
TPL
}

# render <template-text>: substitute {{X}} with the launch variables (literal replacement, no shell evaluation of values)
render() {
  local t="$1"
  t="${t//'{{AGENT}}'/$AGENT}"; t="${t//'{{NAME}}'/$NAME}"; t="${t//'{{REPO}}'/$REPO}"; t="${t//'{{PR}}'/$PR}"; t="${t//'{{HEAD}}'/$HEAD}"
  t="${t//'{{GATED}}'/$GATED}"; t="${t//'{{TOKEN}}'/$TOKEN}"; t="${t//'{{DIR}}'/$DIR}"
  t="${t//'{{CLONE_URL}}'/$CLONE_URL}"; t="${t//'{{SUITE_Q}}'/$SUITE_Q}"
  t="${t//'{{NOTES}}'/$NOTES_TXT}"; t="${t//'{{EXPECT}}'/$EXPECT_TXT}"
  printf '%s\n' "$t"
}

cmd_launch() {
  [ $# -ge 1 ] || die 2 "usage: launch <name> --repo O/R --pr N --head <40-hex> --gated <d-id> --token '<line>' --suite '<cmd>' [--clone-url URL] [--notes T] [--expect T] [--queue]"
  NAME="$1"; shift
  REPO=""; PR=""; HEAD=""; GATED=""; TOKEN=""; SUITE=""; CLONE_URL=""; NOTES=""; EXPECT=""; QUEUE=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --queue) QUEUE=1; shift; continue ;;
      --repo|--pr|--head|--gated|--token|--suite|--clone-url|--notes|--expect)
        [ $# -ge 2 ] || die 2 "$1 needs a value" ;;
      *) die 2 "unknown argument: $1" ;;
    esac
    case "$1" in
      --repo) REPO="$2" ;; --pr) PR="$2" ;; --head) HEAD="$2" ;; --gated) GATED="$2" ;; --token) TOKEN="$2" ;;
      --suite) SUITE="$2" ;; --clone-url) CLONE_URL="$2" ;; --notes) NOTES="$2" ;; --expect) EXPECT="$2" ;;
    esac
    shift 2
  done
  # ---- LINT ----
  [[ "$NAME" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die 2 "lint: name must match [a-z0-9][a-z0-9-]{0,30}: '$NAME'"
  [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die 2 "lint: --repo must be OWNER/NAME"
  [[ "$PR" =~ ^[0-9]+$ ]] || die 2 "lint: --pr must be a number"
  [[ "$HEAD" =~ ^[0-9a-f]{40}$ ]] || die 2 "lint: --head must be 40 lowercase hex chars (got ${#HEAD} chars)"
  [[ "$GATED" =~ ^d-[0-9]{8}-[0-9]{6}-[a-z0-9]+-[0-9a-f]{4}$ ]] || die 2 "lint: --gated must look like d-YYYYMMDD-HHMMSS-<agent>-<4hex>"
  [ -n "${TOKEN//[[:space:]]/}" ] || die 2 "lint: --token (the G3 token line) is empty"
  case "$TOKEN" in *'"'*|*'`'*|*'$'*|*$'\n'*) die 2 "lint: --token must not contain \" \` \$ or a newline" ;; esac
  [ -n "${SUITE//[[:space:]]/}" ] || die 2 "lint: --suite is empty"
  [ -n "$CLONE_URL" ] || CLONE_URL="https://github.com/$REPO.git"
  [ -d "$ROOT/$NAME" ] && [ -e "$ROOT/$NAME/state" ] && die 2 "lint: name '$NAME' already used ($ROOT/$NAME/state exists)"
  DIR="$ROOT/$NAME"
  SUITE_Q="'${SUITE//\'/\'\\\'\'}'"
  NOTES_TXT=""; [ -z "$NOTES" ] || NOTES_TXT=" ($(printf '%s' "$NOTES" | tr '\n' ' '))"
  EXPECT_TXT=""; [ -z "$EXPECT" ] || EXPECT_TXT=" Expected: $(printf '%s' "$EXPECT" | tr '\n' ' ')."
  local tpl rendered what
  if [ -n "${AIDE_VERIFIER_TEMPLATE:-}" ]; then tpl="$(cat "$AIDE_VERIFIER_TEMPLATE" 2>/dev/null)" || die 2 "lint: cannot read AIDE_VERIFIER_TEMPLATE"
  else tpl="$(default_template)"; fi
  rendered="$(render "$tpl")"
  what="$(printf '%s\n' "$rendered" | grep -m1 -o -- '--what "[^"]*"')"
  [ -n "$what" ] || die 2 "lint: the rendered prompt has no verdict --what \"...\""
  [[ "$what" == *"COMMIT=$HEAD"* ]] || die 2 "lint: the verdict --what lacks COMMIT=$HEAD"
  [[ "$what" == *"agent=verifier:$AGENT-verifier-$NAME"* ]] || die 2 "lint: the verdict --what lacks agent=verifier:$AGENT-verifier-$NAME"
  # ---- one at a time ----
  mkdir -p "$ROOT" || die 2 "cannot create $ROOT"
  exec 9>"$ROOT/.launch.lock"
  local waited=0 maxw="${AIDE_VERIFIER_QUEUE_MAX_S:-3600}" act
  while :; do
    flock -x 9
    act="$(active_units | tr '\n' ' ')"
    [ -z "${act// /}" ] && break
    if [ "$QUEUE" != 1 ]; then die 2 "another verifier unit is active (${act% }); one at a time (use --queue to wait)"; fi
    flock -u 9
    [ "$waited" -lt "$maxw" ] || die 6 "queue wait exceeded ${maxw}s (active: ${act% })"
    sleep "$POLL"; waited=$((waited + POLL))
  done
  # ---- room ----
  local room
  # shellcheck disable=SC2086
  room="$($ROOM_CMD 2048 --json 2>/dev/null)"
  [ "$(printf '%s' "$room" | jq -r '.ok' 2>/dev/null)" = true ] || die 3 "no room for a 2048 MB verifier: $(printf '%s' "$room" | tr -d '\n' | cut -c1-200)"
  # ---- write ----
  local unit="$AGENT-verifier-$NAME" claude="${AIDE_VERIFIER_CLAUDE:-$HOME/.npm-global/bin/claude}" oauth="${AIDE_VERIFIER_OAUTH_CONF:-$HOME/.config/environment.d/90-claude-oauth.conf}"
  mkdir -p "$DIR" || die 2 "cannot create $DIR"
  printf '%s\n' "$rendered" >"$DIR/prompt.md"
  {
    echo '#!/bin/bash'
    echo "# generated by aide-verifier.sh: headless verifier for $REPO PR $PR (unit $unit). The prompt is read from the FILE by cat, never passed through a shell -c string."
    printf 'OAUTH=%q\n' "$oauth"
    printf '[ -r "$OAUTH" ] || { echo "aide-verifier: cannot read $OAUTH" >&2; exit 71; }\n'
    echo 'set -a; . "$OAUTH"; set +a'
    printf 'D=%q\n' "$DIR"
    echo 'cd "$D" || exit 70'
    printf 'exec timeout 2400 %q -p --dangerously-skip-permissions --model claude-sonnet-5-5 --output-format json "$(cat "$D/prompt.md")" > "$D/result.json" 2> "$D/stderr.log"\n' "$claude"
  } >"$DIR/launch.sh"
  chmod 755 "$DIR/launch.sh"
  printf 'repo=%s\npr=%s\nhead=%s\ngated=%s\ntoken=%s\nagent=%s\n' "$REPO" "$PR" "$HEAD" "$GATED" "$TOKEN" "$AGENT" >"$DIR/meta"
  # ---- start ----
  if ! "$SD_RUN" --user --unit "$unit" -p MemoryMax=2G --setenv=HOME="$HOME" --setenv=PATH="$UNIT_PATH" "$DIR/launch.sh" >"$DIR/run.out" 2>&1 9>&-; then
    echo "$(iso) launch-failed unit=$unit: $(head -c 300 "$DIR/run.out" | tr '\n' ' ')" >>"$DIR/state"
    die 1 "systemd-run failed: $(head -c 300 "$DIR/run.out" | tr '\n' ' ' | redact)"
  fi
  echo "$(iso) launched unit=$unit repo=$REPO pr=$PR head=$HEAD gated=$GATED" >>"$DIR/state"
  echo "$unit"
}

cmd_finish() {
  [ $# -ge 1 ] || die 2 "usage: finish <name> [--pr N --repo O/R] [--again]"
  local name="$1"; shift
  local pr="" repo="" again=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr) pr="${2:-}"; shift 2 ;; --repo) repo="${2:-}"; shift 2 ;; --again) again=1; shift ;;
      *) die 2 "unknown argument: $1" ;;
    esac
  done
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die 2 "bad name '$name'"
  local d="$ROOT/$name" agent unit
  [ -d "$d" ] || die 2 "no such verifier dir: $d"
  agent="$(meta_get "$d" agent)"; [ -n "$agent" ] || agent="$AGENT"   # the agent the unit was launched under
  unit="$agent-verifier-$name"
  [ -n "$pr" ] || pr="$(meta_get "$d" pr)"; [ -n "$repo" ] || repo="$(meta_get "$d" repo)"
  local head gated; head="$(meta_get "$d" head)"; gated="$(meta_get "$d" gated)"
  [[ "$pr" =~ ^[0-9]+$ ]] && [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die 2 "need --pr N --repo O/R (not in meta)"
  if [ -e "$d/finished" ] && [ "$again" != 1 ]; then
    echo "already finished: $(cat "$d/finished") (no second bell; --again to redo)"
    exit "$(awk '{print $3}' "$d/finished" | sed 's/^rc=//' | grep -E '^[0-9]+$' || echo 0)"
  fi
  [ -s "$d/result.json" ] || die 4 "no result.json in $d (unit not finished or it died; see $d/stderr.log)"
  local iserr text verdict log
  iserr="$(jq -r '.is_error // false' "$d/result.json" 2>/dev/null)" || die 4 "result.json is not JSON"
  text="$(jq -r '.result // ""' "$d/result.json" 2>/dev/null)"
  verdict="$(printf '%s\n' "$text" | grep -oE "d-[0-9]{8}-[0-9]{6}-$agent-[0-9a-f]{4}" | grep -vxF "$gated" | tail -n1)"
  if [ "$iserr" = true ] || [ -z "$verdict" ]; then
    echo "aide-verifier: NO verdict row id in the verifier's result (is_error=$iserr); NOT belling. Final text:" >&2
    printf '%s\n' "$text" | head -n 40 | redact >&2
    exit 4
  fi
  log="$(printf '%s\n' "$text" | sed -n 's/^LOG: *//p' | tail -n1)"
  [ -n "$log" ] || log="$(printf '%s\n' "$text" | grep -oE '/[^[:space:]"`]*/verify/[^[:space:]"`]*\.log' | tail -n1)"
  [ -n "$log" ] || log="(no log path in result)"
  local out rc pass reason
  out="$("$WMD" merge-gate "$verdict" --pr "$pr" --repo "$repo" 2>&1)"; rc=$?
  pass="$(printf '%s\n' "$out" | grep -m1 -E '^PASS ')"
  export EVENT_SOURCE="$agent"
  if [ "$rc" = 0 ] && [ -n "$pass" ]; then
    pass="$(printf '%s' "$pass" | redact)"
    printf '%s\n' "$pass" >>"$d/gate.txt"
    local recrc=0
    "$WMD" record --agent "$agent" --kind other --target carbon \
      --what "GATE-PASS $repo#$pr $verdict: $pass" \
      --why "aide-verifier.sh finish: merge-gate PASS for verifier unit $unit" \
      --evidence "$pass; $log" --reverse-text "none (gate record)" >/dev/null 2>"$d/record.err" || recrc=$?
    "$BELL" ctl "$agent EVENT MERGE-OK $repo#$pr head $head row $verdict gates $gated (own-session unit $unit): $pass; log $log" >/dev/null 2>&1
    if [ "$recrc" != 0 ]; then
      echo "$(iso) PASS rc=7 $verdict" >"$d/finished"
      echo "aide-verifier: gate PASSED and ctl belled, but the GATE-PASS row failed to record (rc=$recrc): $(head -c 200 "$d/record.err" | redact)" >&2
      echo "$pass"; exit 7
    fi
    echo "$(iso) PASS rc=0 $verdict" >"$d/finished"
    echo "$pass"; exit 0
  fi
  reason="$(printf '%s\n' "$out" | grep -m1 -E '^G[0-9]+ FAIL')"
  [ -n "$reason" ] || reason="$(printf '%s\n' "$out" | grep -m1 -v '^[[:space:]]*$')"
  [ -n "$reason" ] || reason="merge-gate rc=$rc with no output"
  reason="$(printf '%s' "$reason" | redact | cut -c1-300)"
  "$WMD" record --agent "$agent" --kind correction --target carbon \
    --what "RETRACT $verdict: merge-gate $reason" \
    --why "aide-verifier.sh finish: merge-gate refused the verifier's MERGE-OK for $repo#$pr" \
    --evidence "$reason; $log" --reverse-text "none (retraction)" >/dev/null 2>"$d/record.err" || echo "aide-verifier: RETRACT row failed to record: $(head -c 200 "$d/record.err" | redact)" >&2
  "$BELL" ctl "$agent EVENT MERGE-GATE FAIL $repo#$pr head $head row $verdict gates $gated (unit $unit): $reason; MERGE-OK RETRACTED; log $log" >/dev/null 2>&1
  echo "$(iso) FAIL rc=5 $verdict" >"$d/finished"
  echo "FAIL $reason" >&2
  exit 5
}

cmd_watch() {
  [ $# -ge 1 ] || die 2 "usage: watch <name> [--pr N --repo O/R]"
  local name="$1"; shift
  local agent unit waited=0 maxw="${AIDE_VERIFIER_WATCH_MAX_S:-3000}" st
  agent="$(meta_get "$ROOT/$name" agent)"; [ -n "$agent" ] || agent="$AGENT"; unit="$agent-verifier-$name"
  while :; do
    st="$("$SYSTEMCTL" --user is-active "$unit" 2>/dev/null)"
    case "$st" in active|activating|deactivating|reloading) ;; *) break ;; esac
    [ "$waited" -lt "$maxw" ] || die 6 "unit $unit still $st after ${maxw}s"
    sleep "$POLL"; waited=$((waited + POLL))
  done
  cmd_finish "$name" "$@"
}

selftest() {
  local T fail=0 n=0 out rc; T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN
  chk() { n=$((n + 1)); if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=$((fail + 1)); fi; }
  local H=0123456789abcdef0123456789abcdef01234567 G=d-20261023-055214-aide-49cf V=d-20261023-061500-aide-7e1a
  mkdir -p "$T/home/.config/environment.d" "$T/bin"
  : >"$T/home/.config/environment.d/90-claude-oauth.conf"
  cat >"$T/bin/fake-sdrun" <<'F'
#!/bin/bash
printf '%s\n' "$*" >>"$FAKE_DIR/sdrun.log"
[ -z "${FAKE_SDRUN_FAIL:-}" ] || { echo "Failed to connect to bus" >&2; exit 1; }
d="$(dirname "${@: -1}")"
printf '%s' "${FAKE_RESULT_JSON:-{\"is_error\":false,\"result\":\"ok\"\}}" >"$d/result.json"
F
  cat >"$T/bin/fake-systemctl" <<'F'
#!/bin/bash
case "$2" in
  list-units) cat "$FAKE_DIR/active" 2>/dev/null ;;
  is-active) if grep -qx "$3.service" "$FAKE_DIR/active" 2>/dev/null; then echo active; else echo inactive; exit 3; fi ;;
esac
exit 0
F
  cat >"$T/bin/fake-wmd" <<'F'
#!/bin/bash
printf '%s\n' "$*" >>"$FAKE_DIR/wmd.log"
case "$1" in
  merge-gate) if [ "${FAKE_GATE:-pass}" = pass ]; then echo "PASS verdict=$2 pr=7 oid=0123456789ab"; else echo "G3 FAIL token 'tests/x EXIT=0' missing from the log"; exit 1; fi ;;
  record) [ -z "${FAKE_RECORD_FAIL:-}" ] || { echo "refused" >&2; exit 2; }; echo "d-20261023-070000-aide-0001" ;;
esac
F
  printf '#!/bin/bash\nprintf "%%s|%%s\\n" "${EVENT_SOURCE:-}" "$*" >>"$FAKE_DIR/bell.log"\n' >"$T/bin/fake-bell"
  printf '#!/bin/bash\nif [ "${FAKE_ROOM:-ok}" = ok ]; then echo "{\\"ok\\":true,\\"room_mb\\":9000}"; else echo "{\\"ok\\":false,\\"room_mb\\":-5}"; exit 1; fi\n' >"$T/bin/fake-room"
  chmod +x "$T"/bin/*
  export HOME="$T/home" FAKE_DIR="$T" AIDE_VERIFIER_DIR="$T/av" AIDE_VERIFIER_ROOM_CMD="$T/bin/fake-room" AIDE_VERIFIER_SYSTEMD_RUN="$T/bin/fake-sdrun" \
    AIDE_VERIFIER_SYSTEMCTL="$T/bin/fake-systemctl" AIDE_VERIFIER_WM_DECIDE="$T/bin/fake-wmd" AIDE_VERIFIER_BELL="$T/bin/fake-bell" AIDE_VERIFIER_POLL_S=1
  unset AIDE_VERIFIER_TEMPLATE AIDE_VERIFIER_AGENT
  local A=(--repo j0yen/dotfiles --pr 7 --gated "$G" --token 'tests/*.test.sh EXIT=0' --suite 'bash tests/run.sh; echo "tests/*.test.sh EXIT=$?"')
  L() { local nm="$1"; shift; "$SELF" launch "$nm" "$@" 2>&1; }

  out="$(L bad1 "${A[@]}" --head abc123)"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"40 lowercase hex"* ]] && [ ! -e "$T/sdrun.log" ]; chk "lint: short head -> exit 2, nothing started" $?
  out="$(L bad1 "${A[@]}" --head "${H^^}")"; rc=$?; [ "$rc" = 2 ]; chk "lint: uppercase head -> exit 2" $?
  out="$("$SELF" launch bad2 --repo j0yen/dotfiles --pr 7 --head "$H" --gated d-2026-bad --token t --suite s 2>&1)"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"--gated"* ]]; chk "lint: bad gated id -> exit 2" $?
  out="$("$SELF" launch bad3 --repo j0yen/dotfiles --pr 7 --head "$H" --gated "$G" --token '  ' --suite s 2>&1)"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"token"* ]]; chk "lint: empty token -> exit 2" $?
  printf 'target {{REPO}}#{{PR}}\nwm-decide record --what "MERGE-OK {{REPO}}#{{PR}} agent=verifier:aide-verifier-{{NAME}} ok" --gates {{GATED}}\n' >"$T/tpl-nocommit"
  out="$(AIDE_VERIFIER_TEMPLATE="$T/tpl-nocommit" L bad4 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"lacks COMMIT="* ]]; chk "lint: a --what lacking COMMIT= -> exit 2" $?
  printf 'wm-decide record --what "MERGE-OK {{REPO}}#{{PR}} COMMIT={{HEAD}} by someone" --gates {{GATED}}\n' >"$T/tpl-noagent"
  out="$(AIDE_VERIFIER_TEMPLATE="$T/tpl-noagent" L bad5 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"lacks agent=verifier:"* ]]; chk "lint: a --what lacking agent=verifier: -> exit 2" $?
  out="$(L Bad_Name "${A[@]}" --head "$H")"; rc=$?; [ "$rc" = 2 ]; chk "lint: bad unit name -> exit 2" $?

  echo "aide-verifier-other.service" >"$T/active"
  out="$(L act1 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"one at a time"* ]] && [ ! -e "$T/sdrun.log" ]; chk "another unit active, no --queue -> exit 2, nothing started" $?
  ( sleep 2; : >"$T/active" ) & local t0=$SECONDS
  out="$(L act2 "${A[@]}" --head "$H" --queue)"; rc=$?; wait
  [ "$rc" = 0 ] && [ $((SECONDS - t0)) -ge 1 ] && [ "$out" = aide-verifier-act2 ]; chk "--queue waits until the other unit is gone, then launches ($out, $((SECONDS - t0)) s)" $?
  echo "aide-verifier-other.service" >"$T/active"
  out="$(AIDE_VERIFIER_QUEUE_MAX_S=2 L act3 "${A[@]}" --head "$H" --queue)"; rc=$?
  [ "$rc" = 6 ]; chk "--queue gives up after AIDE_VERIFIER_QUEUE_MAX_S -> exit 6" $?
  : >"$T/active"

  rm -f "$T/sdrun.log"
  out="$(FAKE_ROOM=no L room1 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 3 ] && [ ! -e "$T/sdrun.log" ]; chk "room not ok -> exit 3, systemd-run not called" $?

  out="$(L ok1 "${A[@]}" --head "$H" --notes 'a "quoted" note; $(not run)' --expect '663 tests')"; rc=$?
  local D="$T/av/ok1"
  [ "$rc" = 0 ] && [ "$out" = aide-verifier-ok1 ]; chk "launch ok: exit 0, prints the unit name" $?
  grep -q -- "--user --unit aide-verifier-ok1 -p MemoryMax=2G --setenv=HOME=$T/home --setenv=PATH=.*/.local/bin.*:/usr/bin:/bin $D/launch.sh\$" "$T/sdrun.log"; chk "systemd-run argv: unit, MemoryMax=2G, HOME, PATH, launch.sh" $?
  grep -q "$H" "$D/prompt.md" && grep -q "$G" "$D/prompt.md" && grep -qF 'tests/*.test.sh EXIT=0' "$D/prompt.md" && grep -q 'HARD CONSTRAINTS' "$D/prompt.md" \
    && grep -qF '^[[:space:]]*(co-authored-by:|generated with)' "$D/prompt.md" && grep -q 'wm-verify-run' "$D/prompt.md" && grep -qF '$(not run)' "$D/prompt.md" \
    && grep -q -- "--what \"MERGE-OK j0yen/dotfiles#7 COMMIT=$H agent=verifier:aide-verifier-ok1 recorded_by=unit:aide-verifier-ok1 session=own-headless-claude-p" "$D/prompt.md" \
    && grep -qF "wm-verify-run 'bash tests/run.sh; echo \"tests/*.test.sh EXIT=\$?\"'" "$D/prompt.md"; chk "prompt.md: head, gated id, token line, HARD CONSTRAINTS, anchored attribution regex, one quoted suite, verdict --what" $?
  [ -x "$D/launch.sh" ] && grep -q 'aide-verifier-ok1' "$D/launch.sh" && bash -n "$D/launch.sh"; chk "launch.sh is executable, names the unit, parses" $?
  grep -q '"$(cat "$D/prompt.md")"' "$D/launch.sh" && ! grep -qE 'bash -c|sh -c' "$D/launch.sh" && ! grep -qE ' -c ' "$T/sdrun.log"; chk "the prompt is read from the file by launch.sh, never passed through bash -c" $?
  grep -q ' launched unit=aide-verifier-ok1 ' "$D/state"; chk "state has a launched line" $?
  out="$(L ok1 "${A[@]}" --head "$H")"; rc=$?; [ "$rc" = 2 ]; chk "a reused name is refused" $?
  FAKE_SDRUN_FAIL=1 L sdf "${A[@]}" --head "$H" >/dev/null; rc=$?
  [ "$rc" = 1 ] && grep -q launch-failed "$T/av/sdf/state"; chk "systemd-run failure -> exit 1, state records it" $?

  # ---- finish ----
  rm -f "$T/bell.log" "$T/wmd.log"
  printf '{"is_error":false,"result":"refused: head moved to 99. Gated row %s only."}' "$G" >"$D/result.json"
  out="$("$SELF" finish ok1 2>&1)"; rc=$?
  [ "$rc" = 4 ] && [ ! -e "$T/bell.log" ] && [ ! -e "$T/wmd.log" ] && [[ "$out" == *"head moved"* ]]; chk "finish: no verdict row (the gated id alone does not count) -> exit 4, no bell, no merge-gate, text shown" $?
  printf '{"is_error":true,"result":"x %s died sk-ant-oat01-abcdefghijklmnopqrstuvwx"}' "$V" >"$D/result.json"
  out="$("$SELF" finish ok1 2>&1)"; rc=$?
  [ "$rc" = 4 ] && [ ! -e "$T/bell.log" ] && [[ "$out" != *abcdefghijklmnop* ]]; chk "finish: is_error -> exit 4, no bell, key-looking text redacted" $?
  printf '{"is_error":false,"result":"head ok\\nLOG: /x/verify/20261023T1-%s.log\\nVERDICT: %s\\nsk-ant-api03-zzzzzzzzzzzzzzzzzzzzzzzz"}' "${H:0:12}" "$V" >"$D/result.json"
  out="$(FAKE_GATE=pass "$SELF" finish ok1 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [[ "$out" == "PASS verdict=$V pr=7 oid="* ]]; chk "finish PASS: exit 0, prints the PASS line" $?
  grep -q "merge-gate $V --pr 7 --repo j0yen/dotfiles" "$T/wmd.log"; chk "finish runs wm-decide merge-gate <verdict> --pr --repo (meta defaults)" $?
  grep -q "^PASS verdict=$V" "$D/gate.txt"; chk "finish PASS: PASS line appended to gate.txt" $?
  grep -q -- "record --agent aide --kind other .*--what GATE-PASS j0yen/dotfiles#7 $V: PASS verdict=$V" "$T/wmd.log" && grep -q -- "--evidence PASS verdict=$V pr=7 oid=0123456789ab; /x/verify/20261023T1-" "$T/wmd.log"; chk "finish PASS: GATE-PASS row with the PASS line + log path as evidence" $?
  [ "$(wc -l <"$T/bell.log")" = 1 ] && grep -q "^aide|ctl aide EVENT MERGE-OK j0yen/dotfiles#7 head $H row $V gates $G (own-session unit aide-verifier-ok1): PASS verdict=$V" "$T/bell.log" \
    && grep -q '; log /x/verify/' "$T/bell.log" && ! grep -q 'zzzzzz' "$T/bell.log"; chk "finish PASS: exactly one bell (source aide) carrying the PASS line and log" $?
  out="$("$SELF" finish ok1 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [ "$(wc -l <"$T/bell.log")" = 1 ] && [[ "$out" == "already finished"* ]]; chk "a second finish is a no-op (no second bell)" $?

  L ok2 "${A[@]}" --head "$H" >/dev/null; D="$T/av/ok2"; rm -f "$T/bell.log" "$T/wmd.log"
  printf '{"is_error":false,"result":"LOG: /x/verify/b.log\\nVERDICT: %s"}' "$V" >"$D/result.json"
  out="$(FAKE_GATE=fail "$SELF" finish ok2 2>&1)"; rc=$?
  [ "$rc" = 5 ] && [[ "$out" == *"G3 FAIL"* ]]; chk "finish FAIL: exit 5, reason shown" $?
  grep -q -- "record --agent aide --kind correction .*--what RETRACT $V: merge-gate G3 FAIL" "$T/wmd.log"; chk "finish FAIL: RETRACT correction row" $?
  [ "$(wc -l <"$T/bell.log")" = 1 ] && grep -q "ctl aide EVENT MERGE-GATE FAIL j0yen/dotfiles#7 .*G3 FAIL.*RETRACTED" "$T/bell.log" && [ ! -e "$D/gate.txt" ]; chk "finish FAIL: one bell with the reason, no gate.txt" $?

  L ok3 "${A[@]}" --head "$H" >/dev/null; D="$T/av/ok3"; rm -f "$T/bell.log"
  printf '{"is_error":false,"result":"VERDICT: %s"}' "$V" >"$D/result.json"
  out="$(FAKE_RECORD_FAIL=1 "$SELF" finish ok3 2>&1)"; rc=$?
  [ "$rc" = 7 ] && [ "$(wc -l <"$T/bell.log")" = 1 ]; chk "finish PASS but the row will not record -> bell sent, exit 7" $?

  # ---- watch ----
  L ok4 "${A[@]}" --head "$H" >/dev/null; D="$T/av/ok4"; rm -f "$T/bell.log"
  printf '{"is_error":false,"result":"VERDICT: %s"}' "$V" >"$D/result.json"
  echo "aide-verifier-ok4.service" >"$T/active"; ( sleep 2; : >"$T/active" ) & t0=$SECONDS
  out="$("$SELF" watch ok4 2>&1)"; rc=$?; wait
  [ "$rc" = 0 ] && [ $((SECONDS - t0)) -ge 1 ] && [ "$(wc -l <"$T/bell.log")" = 1 ]; chk "watch waits for the unit to go inactive, then finishes (one bell)" $?
  # ---- AIDE_VERIFIER_AGENT ----
  local V7=d-20261023-063000-r7-1b2c
  out="$(AIDE_VERIFIER_AGENT=bogus L ag0 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"must be aide, rb or r7"* ]] && [ ! -e "$T/av/ag0" ]; chk "AIDE_VERIFIER_AGENT=bogus -> exit 2, nothing written" $?
  echo "aide-verifier-other.service" >"$T/active"
  out="$(AIDE_VERIFIER_AGENT=r7 L ag1 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"one at a time"* ]]; chk "one at a time spans agents: an aide-verifier-* unit blocks an r7 launch" $?
  echo "rb-verifier-other.service" >"$T/active"
  out="$(L ag1 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"one at a time"* ]]; chk "one at a time spans agents: an rb-verifier-* unit blocks an aide launch" $?
  : >"$T/active"; rm -f "$T/bell.log" "$T/wmd.log" "$T/sdrun.log"
  out="$(AIDE_VERIFIER_AGENT=r7 L ag1 "${A[@]}" --head "$H")"; rc=$?; D="$T/av/ag1"
  [ "$rc" = 0 ] && [ "$out" = r7-verifier-ag1 ] && grep -q -- "--user --unit r7-verifier-ag1 -p MemoryMax=2G " "$T/sdrun.log"; chk "r7: unit r7-verifier-<name> (printed and passed to systemd-run)" $?
  grep -q -- "wm-decide record --agent r7 --via verifier --model sonnet --kind verdict --gates $G" "$D/prompt.md" \
    && grep -q -- "agent=verifier:r7-verifier-ag1 recorded_by=unit:r7-verifier-ag1 session=own-headless-claude-p" "$D/prompt.md" \
    && ! grep -qE -- '--agent aide|aide-verifier-' "$D/prompt.md"; chk "r7: template carries --agent r7, agent=verifier:r7-verifier-<name>, recorded_by=unit:r7-verifier-<name>, no aide unit/agent" $?
  grep -q '^agent=r7$' "$D/meta" && grep -q ' launched unit=r7-verifier-ag1 ' "$D/state"; chk "r7: meta records the agent, state names the r7 unit" $?
  printf '{"is_error":false,"result":"LOG: /x/verify/r.log\\nVERDICT: %s"}' "$V7" >"$D/result.json"
  out="$(FAKE_GATE=pass "$SELF" finish ag1 2>&1)"; rc=$?
  [ "$rc" = 0 ] && grep -q -- "record --agent r7 --kind other .*--what GATE-PASS j0yen/dotfiles#7 $V7" "$T/wmd.log" && ! grep -q -- '--agent aide' "$T/wmd.log"; chk "r7: finish PASS records the GATE-PASS row with --agent r7 (agent read from meta, env unset)" $?
  [ "$(wc -l <"$T/bell.log")" = 1 ] && grep -q "^r7|ctl r7 EVENT MERGE-OK j0yen/dotfiles#7 head $H row $V7 gates $G (own-session unit r7-verifier-ag1): " "$T/bell.log"; chk "r7: bell text starts with 'r7 EVENT MERGE-OK' (source r7)" $?
  rm -f "$T/bell.log" "$T/wmd.log"
  AIDE_VERIFIER_AGENT=r7 L ag2 "${A[@]}" --head "$H" >/dev/null; D="$T/av/ag2"
  printf '{"is_error":false,"result":"VERDICT: %s"}' "$V7" >"$D/result.json"
  out="$(FAKE_GATE=fail "$SELF" finish ag2 2>&1)"; rc=$?
  [ "$rc" = 5 ] && grep -q -- "record --agent r7 --kind correction .*--what RETRACT $V7" "$T/wmd.log" && grep -q "^r7|ctl r7 EVENT MERGE-GATE FAIL " "$T/bell.log"; chk "r7: finish FAIL records the RETRACT row with --agent r7 and belles 'r7 EVENT'" $?
  printf '{"is_error":false,"result":"VERDICT: %s"}' "$V" >"$D/result.json"; rm -f "$T/bell.log"
  out="$(FAKE_GATE=pass "$SELF" finish ag2 --again 2>&1)"; rc=$?
  [ "$rc" = 4 ] && [ ! -e "$T/bell.log" ]; chk "r7: a verdict row id of another agent (-aide-) is not accepted -> exit 4, no bell" $?
  AIDE_VERIFIER_AGENT=rb L ag3 "${A[@]}" --head "$H" >/dev/null; D="$T/av/ag3"; rm -f "$T/bell.log"
  printf '{"is_error":false,"result":"VERDICT: d-20261023-064000-rb-0a0a"}' >"$D/result.json"
  echo "rb-verifier-ag3.service" >"$T/active"; ( sleep 2; : >"$T/active" ) & t0=$SECONDS
  out="$("$SELF" watch ag3 2>&1)"; rc=$?; wait
  [ "$rc" = 0 ] && [ $((SECONDS - t0)) -ge 1 ] && grep -q "^rb|ctl rb EVENT MERGE-OK " "$T/bell.log"; chk "rb: watch polls rb-verifier-<name>, then belles 'rb EVENT'" $?
  AIDE_VERIFIER_AGENT=bogus "$SELF" finish ok1 >/dev/null 2>&1; rc=$?; [ "$rc" = 2 ]; chk "AIDE_VERIFIER_AGENT=bogus is refused by finish too (exit 2)" $?
  # default unchanged
  grep -q -- '--agent aide --via verifier' "$T/av/ok1/prompt.md" && grep -q '^agent=aide$' "$T/av/ok1/meta"; chk "default agent unchanged: the ok1 prompt carries --agent aide, meta agent=aide" $?
  ! grep -E '"\$SD_RUN"' "$SELF" | grep -qE '(bash|sh) -c'; chk "the systemd-run call in the script has no bash -c / sh -c" $?
  echo "selftest: $((n - fail))/$n passed"
  [ "$fail" = 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  launch) shift; cmd_launch "$@" ;;
  finish) shift; cmd_finish "$@" ;;
  watch) shift; cmd_watch "$@" ;;
  *) sed -n '2,22p' "$SELF" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
