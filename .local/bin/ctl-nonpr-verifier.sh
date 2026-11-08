#!/usr/bin/env bash
# ctl-nonpr-verifier.sh issue <ask-id> | launch <ask-id> --target-check [--check-sha S] [--lease F] [--verdict-agent A] [--dry-run]   (A1284)
# A dedicated NON-PR acceptance verifier. It runs a SEPARATE headless Sonnet session (account routing = fable-launch.sh --helper, which owns the
# josephsyen/jyen.tech round-robin and the credential store; this script never reads or prints a token) whose scope is exactly the ask's
# done-check. The session EXECUTES the check read-only and records the verdict row itself (wm-decide record, kind verdict), attributed to its own
# systemd unit. The launcher re-reads that row, and on CONFIRM prints its id for ctl:
#   wm-asks asks resolve <id> --by ctl --expect-rev R --evidence ... --verdict-row <row>
# The launcher never accepts and never closes (ctl runs resolve). A CORRECT outcome is recorded as kind=other (a kind=verdict row without a
# first_verdict word passes the resolver's _verdict_ok, so a failure must never be a kind=verdict row) and no resolvable id is printed.
# Refusals (no row is written, exit nonzero):
#   2 usage | 3 ask not found / closed | 4 no real done-check | 5 incorrect target (check sha / lease ask differs) | 6 lease expired (> 30 min) or missing
#   7 self verdict (verdict agent is ctl, its owner alias, aide, hermes, or the ask owner) | 8 session left no verifiable row | 9 CORRECT outcome | 1 unit failed
# Test overrides (WMA WMD FABLE_LAUNCH SD_RUN LEASE_DIR RUN_DIR NOW) are honored only with env CTL_NONPR_TEST=1 AND the argv flag --test; elsewhere a set one,
# or --test without the env, is refused (exit 64). `launch` needs a lease from a prior `issue` (exit 6) and --check-sha (exit 2).
# Session sandbox (systemd-run): ProtectHome=read-only, ReadWritePaths = run dir + ledger state dir + account-rr dir, NoNewPrivileges, PrivateTmp,
# ~/.ssh ~/.git-credentials ~/.config/{wm-sudo,gh} inaccessible, ~/.config/fleet-token reduced to the josephsyen + jyen.tech store files,
# CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 and a private CLAUDE_CONFIG_DIR. Exit 10 = a token-shaped string was found in the session output.
set -u
ARGS=(); TESTFLAG=0
for _a in "$@"; do if [ "$_a" = --test ]; then TESTFLAG=1; else ARGS+=("$_a"); fi; done
set -- "${ARGS[@]+"${ARGS[@]}"}"
[ "$TESTFLAG" = 0 ] || [ "${CTL_NONPR_TEST:-0}" = 1 ] || { echo "ctl-nonpr-verifier: --test needs CTL_NONPR_TEST=1" >&2; exit 64; }
if [ "${CTL_NONPR_TEST:-0}" = 1 ] && [ "$TESTFLAG" = 1 ]; then
  WMA="${WMA:-wm-asks}"; WMD="${WMD:-wm-decide}"; FL="${FABLE_LAUNCH:-$HOME/.local/bin/fable-launch.sh}"; SDR="${SD_RUN:-systemd-run}"
  LEASE_DIR="${LEASE_DIR:-$HOME/.cache/ctl-nonpr/leases}"; RUN_DIR="${RUN_DIR:-$HOME/.cache/ctl-nonpr/runs}"; NOW="${NOW:-$(date +%s)}"
else
  for _v in WMA WMD FABLE_LAUNCH SD_RUN LEASE_DIR RUN_DIR NOW; do
    [ -z "${!_v:-}" ] || { echo "ctl-nonpr-verifier: $_v override refused (test-only)" >&2; exit 64; }
  done
  WMA=wm-asks; WMD=wm-decide; FL="$HOME/.local/bin/fable-launch.sh"; SDR=systemd-run
  LEASE_DIR="$HOME/.cache/ctl-nonpr/leases"; RUN_DIR="$HOME/.cache/ctl-nonpr/runs"; NOW="$(date +%s)"
fi
TTL=1800
die() { local rc=$1; shift; echo "ctl-nonpr-verifier: $*" >&2; exit "$rc"; }
usage() { die 2 "usage: $0 issue <ask-id> | launch <ask-id> --target-check [--check-sha S] [--lease F] [--verdict-agent A] [--dry-run]"; }
sha16() { printf '%s' "$1" | sha256sum | cut -c1-16; }   # same as asks._sha

cmd="${1:-}"; ask="${2:-}"; [ -n "$cmd" ] && [ -n "$ask" ] || usage; shift 2
[[ "$ask" =~ ^[A-Za-z0-9._-]+$ ]] || die 2 "bad ask id"
lease=""; want_sha=""; vagent=""; dry=0; tc=0
while [ $# -gt 0 ]; do
  case "$1" in
    --target-check) tc=1 ;;
    --check-sha) want_sha="${2:-}"; shift ;;
    --lease) lease="${2:-}"; shift ;;
    --verdict-agent) vagent="${2:-}"; shift ;;
    --dry-run) dry=1 ;;
    *) usage ;;
  esac
  shift
done
case "$cmd" in issue) ;; launch) [ "$tc" = 1 ] || die 2 "launch needs --target-check (scope is the ask's done-check only)"; [ -n "$want_sha" ] || die 2 "launch needs --check-sha <sha of the ask's current check> (printed by issue)" ;; *) usage ;; esac

# ---- read the ask (read-only query) ----
mkdir -p "$RUN_DIR" "$LEASE_DIR" || die 70 "cannot create state dirs"
Q="$RUN_DIR/.q.$$.json"
"$WMA" asks query --ids "$ask" --status all --json > "$Q" 2>/dev/null || { rm -f "$Q"; die 3 "wm-asks query failed for $ask"; }
F="$(python3 -I - "$Q" "$ask" "$Q.chk" <<'PY'
import hashlib, json, sys
rows = [r for r in json.load(open(sys.argv[1])) if r.get("ask_id") == sys.argv[2]]
if not rows:
    sys.exit(3)
r = rows[0]
one = lambda s: " ".join(str(s or "").split())
raw = r.get("check") or ""
open(sys.argv[3], "w").write(raw)
print("\t".join([r.get("status") or "", one(r.get("owner")), one(r.get("row_id")), str(r.get("rev")), hashlib.sha256(raw.encode()).hexdigest()[:16], one(raw)]))
PY
)" || { rm -f "$Q" "$Q.chk"; die 3 "ask $ask not found"; }
RAW="$(cat "$Q.chk")"; rm -f "$Q" "$Q.chk"
IFS=$'\t' read -r status owner rowid rev sha chk <<< "$F"
[ "$status" != closed ] || die 3 "$ask is already closed"
case "$chk" in ""|"-"|none) die 4 "$ask has no real done-check (A1216): nothing to verify" ;; esac
if [ -n "$want_sha" ] && [ "$want_sha" != "$sha" ]; then die 5 "incorrect target: launch names check sha $want_sha, the ask's current check is $sha"; fi

# ---- lease: ts + ask + sha, valid 30 min ----
L="${lease:-$LEASE_DIR/$ask.lease}"
if [ "$cmd" = issue ]; then
  printf 'ts=%s\nask=%s\nsha=%s\n' "$NOW" "$ask" "$sha" > "$L.tmp" && mv -f "$L.tmp" "$L" || die 70 "cannot write lease"
  echo "lease $L ts=$NOW ask=$ask sha=$sha"; exit 0
fi
[ -f "$L" ] || die 6 "no lease from a prior issue ($L missing): run '$0 issue $ask' first"
l_ts="$(sed -n 's/^ts=//p' "$L")"; l_ask="$(sed -n 's/^ask=//p' "$L")"; l_sha="$(sed -n 's/^sha=//p' "$L")"
[[ "$l_ts" =~ ^[0-9]+$ ]] || die 6 "lease has no valid ts"
[ "$l_ask" = "$ask" ] || die 5 "incorrect target: lease is for ask '$l_ask', launch is for '$ask'"
[ "$l_sha" = "$sha" ] || die 5 "incorrect target: lease sha $l_sha, the ask's current check sha is $sha (check changed after the lease)"
age=$((NOW - l_ts)); { [ "$age" -ge 0 ] && [ "$age" -le "$TTL" ]; } || die 6 "lease expired or from the future (age ${age}s, limit ${TTL}s); run '$0 issue $ask'"

# ---- verdict identity: independent of the closer (ctl) and the owner ----
ts="$(date -d "@$NOW" +%Y%m%d%H%M%S)"
label="ctl-nonpr-$ask-$ts"; unit="$label"; [ -n "$vagent" ] || vagent="coder:$label"
[[ "$vagent" =~ ^(coder:[A-Za-z0-9._-]+|aide:[A-Za-z0-9._-]+|explore:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+)$ ]] || die 7 "verdict agent '$vagent' is not a ledger agent id"
low="$(printf '%s' "${vagent#*:}" | tr 'A-Z' 'a-z')"; olow="$(printf '%s' "$owner" | tr 'A-Z' 'a-z')"
for bad in ctl controller aide hermes "$olow"; do
  [ -z "$bad" ] || { [ "$low" != "$bad" ] && [ "${vagent,,}" != "$bad" ] && [ "${vagent,,}" != "coder:$bad" ] && [ "${vagent,,}" != "verifier:$bad" ]; } || die 7 "self verdict refused: verdict agent '$vagent' is the closer or the ask owner ('$bad')"
done

DIR="$RUN_DIR/$label"; mkdir -p "$DIR" || die 70 "cannot create $DIR"
R="$DIR/result.txt"; rm -f "$R"
cat > "$DIR/prompt.txt" <<P
You are an independent, read-only acceptance verifier for ask $ask (owner $owner; ledger row $rowid). You are not the owner and not ctl.
SCOPE (exact): the ask's done-check below, and the artifact, check command and head/sha it names. Nothing else.
DONE-CHECK: $RAW
CHECK SHA: $sha
STEPS
1. Identify the artifact, command and head/commit the done-check names. Do not widen the scope.
2. EXECUTE the check for real now (read-only: no edits, no writes outside $DIR, no git push/merge, no systemctl changes, no network writes, no ssh, no cargo, no test suites, never print a token or key). Save raw output to $DIR/check.out (tail it, do not paste >2 KB). If the check names a commit or artifact, verify its sha with git rev-parse or sha256sum and keep it.
3. Decide: CONFIRM only if the check output shows the done-check holds at the named head/artifact. Otherwise CORRECT. If you cannot run it, CORRECT with the reason.
4. Record exactly ONE row. CONFIRM:
   $WMD record --agent $vagent --via ctl-nonpr-verifier --model sonnet --kind verdict --gates $rowid --target carbon --what "CONFIRM $ask check-sha=$sha COMMIT=<head or artifact sha you verified> agent=verifier:$label recorded_by=unit:$unit scope=non-pr done-check executed read-only: <one line of what you saw>" --why "independent non-PR acceptance (A1284)" --evidence "$DIR/check.out" --reverse-text "none (verdict row)"
   CORRECT: the same command with --kind other and the what starting "CORRECT $ask" (never --kind verdict for a failure).
   Run that command WITHOUT any pipe, sed, head or semicolon after it (use R=\$(...) && ...). Take the printed d-... id.
5. Write one line to $R: VERDICT=<CONFIRM|CORRECT> ROW=<d-id>. Then stop.
P
echo "label=$label unit=$unit agent=$vagent owner=$owner row=$rowid sha=$sha lease_age=${age}s"
if [ "$dry" = 1 ]; then echo "DRY-RUN prompt: $DIR/prompt.txt"; exit 0; fi
prompt="$(cat "$DIR/prompt.txt")"
mkdir -p "$DIR/claude-home" "$HOME/.cache/aide/account-rr" || die 70 "cannot create session dirs"
SB=(-p ProtectHome=read-only -p "ReadWritePaths=$DIR $HOME/.local/state/swarm-decide $HOME/.cache/aide/account-rr" -p NoNewPrivileges=yes -p PrivateTmp=yes
    -p "InaccessiblePaths=-$HOME/.ssh -$HOME/.git-credentials -$HOME/.config/wm-sudo -$HOME/.config/gh"
    -p "TemporaryFileSystem=$HOME/.config/fleet-token:ro" -p "BindReadOnlyPaths=$HOME/.config/fleet-token/store/josephsyen $HOME/.config/fleet-token/store/jyen.tech"
    -E CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 -E "CLAUDE_CONFIG_DIR=$DIR/claude-home")
"$SDR" --user --wait --collect --unit="$unit" -p MemoryMax=2G -p RuntimeMaxSec=1800 "${SB[@]}" -p "StandardOutput=file:$DIR/session.log" -p "StandardError=append:$DIR/session.log" \
  "$FL" --helper --model sonnet --effort medium -p "$prompt" --allowedTools "Bash Read Grep Glob" --disallowedTools "Edit Write NotebookEdit" > "$DIR/run.out" 2>&1 \
  || die 1 "verifier unit $unit failed (see $DIR/session.log)"
# a token-shaped string anywhere in the session output: drop the output and refuse
if grep -rqE 'sk-ant-[A-Za-z0-9_-]{8,}|CLAUDE_CODE_OAUTH_TOKEN=[^ ]{8,}' "$DIR" 2>/dev/null; then rm -f "$DIR/session.log" "$DIR/run.out" "$DIR/check.out"; die 10 "token-shaped string found in session output; outputs removed, no verdict taken"; fi

# ---- re-read the row the session wrote ----
[ -s "$R" ] || die 8 "session wrote no $R"
word="$(sed -n 's/^VERDICT=\([A-Z]*\) ROW=.*/\1/p' "$R" | head -1)"; row="$(sed -n 's/^VERDICT=[A-Z]* ROW=\(d-[A-Za-z0-9._-]*\).*/\1/p' "$R" | head -1)"
[ -n "$word" ] && [ -n "$row" ] || die 8 "result line malformed"
LJ="$DIR/rows.json"
"$WMD" list --agent "$vagent" --json > "$LJ" 2>/dev/null || die 8 "cannot list rows for $vagent"
chk_out="$(python3 -I - "$LJ" "$row" "$vagent" "$label" "$unit" "$ask" "$sha" "$word" <<'PY'
import json, re, sys
f, row, agent, label, unit, ask, sha, word = sys.argv[1:9]
rows = [r for r in json.load(open(f)) if r.get("id") == row]
if not rows: print("row not in ledger"); sys.exit(1)
r = rows[0]; w = r.get("what") or ""
errs = []
if r.get("agent") != agent: errs.append("agent")
if ("agent=verifier:%s" % label) not in w: errs.append("agent label")
if ("recorded_by=unit:%s" % unit) not in w: errs.append("recorded_by unit")
if ("check-sha=%s" % sha) not in w: errs.append("check-sha")
if not re.search(r"(COMMIT|ARTIFACT)=[0-9a-f]{7,64}\b", w): errs.append("no COMMIT=/ARTIFACT= sha")
if (r.get("via") or "") in ("verifier", "aide-verifier"): errs.append("forged via")
if not w.startswith(word + " "): errs.append("what does not start with %s" % word)
if word == "CONFIRM" and r.get("kind") != "verdict": errs.append("CONFIRM must be kind verdict")
if word != "CONFIRM" and r.get("kind") == "verdict": errs.append("failure must not be kind verdict")
if (r.get("first_verdict") or {}).get("verdict") in ("CORRECT", "ESCALATE"): errs.append("first_verdict not confirming")
print(",".join(errs)); sys.exit(1 if errs else 0)
PY
)" || die 8 "row $row failed re-read: $chk_out"
if [ "$word" = CONFIRM ]; then
  echo "VERDICT-ROW $row"
  echo "next (ctl): $WMA asks resolve $ask --by ctl --expect-rev $rev --evidence \"<what you checked>\" --verdict-row $row   # needs a PASS 'asks accept' of sha $sha first"
  exit 0
fi
echo "CORRECT row $row (kind other, not resolvable): $ask stays open" >&2
exit 9
