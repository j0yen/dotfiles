#!/usr/bin/env bash
# aide-verifier.sh: the aide's merge-gate VERIFIER unit as a mechanism (controller DECISION 0e71; was hand-written prompt.md + launch.sh per PR).
#   AGENT: AIDE_VERIFIER_AGENT (default aide; aide|rb|r7, anything else -> exit 2) is the wm-decide --agent of every row (verdict template, GATE-PASS, RETRACT),
#   the template's agent=verifier:/recorded_by=unit: fields, the bell text prefix ("<agent> EVENT ...", EVENT_SOURCE) and the unit prefix <agent>-verifier-<name>.
#   The rb/r7 seats run their own claude on carbon too, so ROOM and systemd-run are unchanged; the verdict row still comes from the headless unit's own session (G7).
#   Below, "aide" in unit/field names means <agent>; the one-at-a-time check looks at every (aide|rb|r7)-verifier-* unit.
#   launch <name> --repo O/R --pr N --head <40-hex> --gated <d-id> --token '<G3 token line>' --suite '<ONE command for wm-verify-run>'
#          [--clone-url URL] [--notes TEXT] [--expect TEXT] [--queue]
#       LINT (exit 2): name not [a-z0-9-]; head not 40 hex; --gated not d-YYYYMMDD-HHMMSS-<agent>-<4hex>; empty token (or one with " ` $ newline);
#       empty suite; the rendered verdict --what lacking COMMIT=<head> or agent=verifier:<agent>-verifier-<name>;
#       MERGE-GATE LINTS (AVL; each names the merge-gate rule, all failures printed, no bypass flag): G0 the --gated row does not exist; G6 the gated row names no
#       agent=, or the verifier id equals its agent= / author= / agent column; G3 --repo has no repo_tokens entry or --suite lacks the prefix of a required
#       `<prefix> EXIT=0` token (tokens without EXIT=0 print `lint: note:` and are checked from the log only); G1 --head != the live PR head (gh pr view;
#       a gh failure refuses); KIND (V9) the --gated row's `what` must hold `GATED <repo>#<pr>` (word-bounded) and exactly one `COMMIT=<40 hex>` equal to --head
#       (case-folded): a spawn/plan row or a stale GATED row is refused. KIND is STRICTER than merge-gate (which never reads the gated row's COMMIT=); its
#       authority is the controller ruling ctl 12:59 + 1:11, 10-23, and its grammar is the one constant pair GATED_RE_FMT/COMMIT_TOKEN_RE below
#       (`--gate-grammar`; tests/aide-verifier-gate-nodrift.test.sh checks it against the live repo_tokens keys). The merge-gate code is IMPORTED from the live tree (dirname(dirname(realpath(command -v $WMD))); AIDE_VERIFIER_GATE_ROOT
#       overrides, tests only); a missing/unusable root or helper failure = exit 2 `lint: gate-root unusable` (fail closed, no default root). The gated row
#       is read with `$WMD list --json`. G2/G4/G5/G7 are NOT linted: they read the verdict row, the log or the clock, none of which exist at launch.
#       Another *-verifier-* unit active (not counting the caller's OWN unit: the final component of the 0:: line of $AIDE_VERIFIER_CGROUP_FILE
#       (default /proc/self/cgroup, test-only override), when it ends .service; the exclusion is printed with the unit name; a launch run inside the very unit
#       it would start, <agent>-verifier-<name>.service, exits 2 `lint: launch-inside-target-unit <unit>` before any wait; the v360b hang)
#       (one at a time) unless --queue (wait, poll AIDE_VERIFIER_POLL_S=20, up to AIDE_VERIFIER_QUEUE_MAX_S=3600, then exit 6).
#       Then ROOM (carbon-room.sh 2048 --json, .ok true else exit 3), then systemd-run --user --unit <agent>-verifier-<name> -p MemoryMax=2G.
#       Writes $AIDE_VERIFIER_DIR/<name>/{prompt.md,launch.sh,meta,state}; launch.sh reads the prompt from the FILE (never bash -c); prints the unit name.
#   finish <name> [--pr N --repo O/R] [--again]  | watch <name> [...]  (watch waits for the unit to go inactive first, AIDE_VERIFIER_WATCH_MAX_S=3000 -> exit 6)
#       Reads result.json; no verdict row id in .result (or is_error) -> prints the verifier's final text, NO bell, exit 4. Else
#       `wm-decide merge-gate <verdict> --pr N --repo O/R`: PASS line -> gate.txt + GATE-PASS row + bell to ctl; anything else -> RETRACT correction row + bell, exit 5.
#       A second finish is a no-op (prints the first outcome) unless --again, so a bell is never doubled. Row-record failure on PASS: bell still sent, exit 7.
#   --selftest   fakes for systemd-run/systemctl/wm-decide/bell/room in a throwaway dir; touches no real unit, row or seat.
# Every gate-lint temp dir is removed by one EXIT trap (it also fires on a refusal or a signal); refusals leave through die()/refuse() only.
# Env: AIDE_VERIFIER_AGENT AIDE_VERIFIER_DIR (~/.local/state/aide-verifier) AIDE_VERIFIER_ROOM_CMD (carbon-room.sh) AIDE_VERIFIER_SYSTEMD_RUN AIDE_VERIFIER_SYSTEMCTL
#      AIDE_VERIFIER_WM_DECIDE AIDE_VERIFIER_BELL (seat-event.sh) AIDE_VERIFIER_TEMPLATE (a template file with {{PLACEHOLDERS}}; tests) AIDE_VERIFIER_CLAUDE
#      AIDE_VERIFIER_OAUTH_CONF AIDE_VERIFIER_UNIT_PATH (the PATH given to the unit) AIDE_VERIFIER_GATE_ROOT AIDE_VERIFIER_CGROUP_FILE (both tests only)
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
refuse() { die "$@"; }   # AVL: every launch refusal leaves through here (exit -> the EXIT trap below removes the gate-lint temp dir)
GATE_TMP=""
gate_cleanup() { trap - TERM INT HUP; [ -z "$GATE_TMP" ] || rm -rf -- "${GATE_TMP:?}"; GATE_TMP=""; }
trap gate_cleanup EXIT   # AVL-TRAP: registered before the first mktemp (gate_lint)
redact() { sed -E 's/(sk-[A-Za-z0-9_-]{16,}|[A-Za-z0-9_-]*oat[0-9]+-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|(TOKEN|KEY|SECRET)=[^[:space:]]+)/[redacted]/g'; }
iso() { date -Iseconds; }
case "$AGENT" in aide|rb|r7) ;; *) die 2 "AIDE_VERIFIER_AGENT must be aide, rb or r7 (got '$AGENT')" ;; esac
active_units() {
  "$SYSTEMCTL" --user list-units '*-verifier-*' --state=active,activating,deactivating,reloading --no-legend --plain 2>/dev/null \
    | awk '{print $1}' | grep -E '^(aide|rb|r7)-verifier-.*\.service$'
}
# own_unit: the caller's own systemd unit = the FINAL path component of the 0:: line (else the first line) of the cgroup file, only if it ends .service
# (a .scope or a sub-cgroup dir = no exclusion; never scans backward, or user@1000.service would be picked). Unreadable file = no exclusion.
own_unit() {
  local f="${AIDE_VERIFIER_CGROUP_FILE:-/proc/self/cgroup}" line seg
  [ -r "$f" ] || return 0
  line="$(grep -m1 '^0::' "$f" 2>/dev/null || head -n1 "$f" 2>/dev/null)"
  seg="${line##*/}"
  case "$seg" in *.service) printf '%s\n' "$seg" ;; esac
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

# ---- merge-gate launch lints (AVL) ----
# Names the helper imports from the live merge-gate tree; `aide-verifier.sh --gate-names` prints them so tests/aide-verifier-gate-nodrift.test.sh checks the SAME list.
GATE_NAMES="wm_decide.mergegate._agent_token wm_decide.mergegate.AGENT_RE wm_decide.mergegate.AUTHOR_RE wm_decide.mergegate.g3_missing wm_decide.mergegate.strip_attachments wm_decide.mergegate.contract.canon_agent"
# L-KIND grammar (V9/W2/W4): ONE constant pair, passed to the helper and printed by `--gate-grammar` for the no-drift test. %s %s = re.escape(<repo>), <pr>;
# <repo> is the exact owner/name string L-G3 looks up in repo_tokens. merge-gate has no GATED grammar, so there is nothing to import.
GATED_RE_FMT='(^|\s)GATED %s#%s(\s|$)'
COMMIT_TOKEN_RE='(?:^|\s)COMMIT=(\S*)'
read -r -d '' GATE_PY <<'PY'
import importlib, json, re, sys
root, rows_f, gated_id, vid, repo, head, suite = sys.argv[1:8]
names = sys.argv[8].split()
pr, gated_fmt, commit_tok = sys.argv[9:12]
sys.dont_write_bytecode = True
sys.path.insert(0, root)
out = []
def refuse(rule, msg): out.append("REFUSE %s %s" % (rule, msg))
def note(msg): out.append("NOTE " + msg)
def lint_g6(mg, row):
    ga = mg._agent_token(row, mg.AGENT_RE)
    author = mg._agent_token(row, mg.AUTHOR_RE)
    if ga is None:
        refuse("G6", "gated row %s names no agent=<coder id> (merge-gate G6 needs it in what/evidence/why outside ATTACH blocks)" % gated_id)
        return
    canon = mg.contract.canon_agent
    for lbl, other in (("its agent=", ga), ("its author=", author), ("its agent column", row.get("agent"))):
        if other and canon(other) == canon(vid):
            refuse("G6", "verifier id %s equals the gated row's %s %s: the verifier must be independent" % (vid, lbl, other))
            return
KIND_HELP = " (stricter than merge-gate, which never reads the gated row's COMMIT=: controller ruling ctl 12:59 + 1:11, 10-23; write a fresh `GATED %s#%s COMMIT=%s` row)" % (repo, pr, head)
def lint_kind(mg, row):  # AVL-KIND: the --gated row's `what` (ATTACH stripped; any kind) must be a GATED row for this repo#pr at this head
    what = mg.strip_attachments(row.get("what") or "")
    why = None
    if not re.search(gated_fmt % (re.escape(repo), re.escape(pr)), what):
        why = "no GATED token for %s#%s" % (repo, pr)
    else:
        cs = re.findall(commit_tok, what)
        if not cs:
            why = "no COMMIT"
        elif len(cs) > 1:
            why = "ambiguous COMMIT (%d tokens), write a fresh GATED row" % len(cs)
        elif not re.fullmatch(r"[0-9a-fA-F]{40}", cs[0]):
            why = "COMMIT=%s is not a full 40-hex sha" % cs[0][:44]
        elif cs[0].lower() != head.lower():
            why = "COMMIT=%s is stale (head is %s)" % (cs[0][:12].lower(), head[:12])
    if why:
        refuse("KIND", "gated row %s is not a GATED row for %s#%s at %s: %s%s" % (gated_id, repo, pr, head[:12], why, KIND_HELP))
def lint_g3(mg, tokens):
    if tokens is None:
        refuse("G3", "no required-check entry for repo %s (gen/merge-gate.json repo_tokens)" % repo)
        return
    att = {"trailer": {"HEAD": head, "CMD": suite, "EXIT": "0", "DIRTY": "0"}, "body": [], "tail": [], "lines": 0}  # AVL-CMD
    missing, problem = mg.g3_missing(list(tokens), [att], head)
    if problem:
        refuse("G3", problem)
    bad = [t for t in missing if t.endswith(" EXIT=0")]
    if bad:
        refuse("G3", "--suite does not show the required token prefix(es) %s (the CMD of the log must contain each prefix)" % " | ".join(t[: -len(" EXIT=0")] for t in bad))
    for t in missing:
        if not t.endswith(" EXIT=0"):
            note("%s is checked from the log only" % t)
try:
    mg = importlib.import_module("wm_decide.mergegate")
    for n in names:
        o = mg
        for part in n.split(".")[2:]:
            o = getattr(o, part)
    rows = json.load(open(rows_f))
    row = next((r for r in rows if r.get("id") == gated_id), None)
    cfg = json.load(open(root + "/gen/merge-gate.json"))
    tokens = cfg["repo_tokens"].get(repo)
    if row is None:
        refuse("G0", "gated row %s does not exist (wm-decide list --json)" % gated_id)
    else:
        lint_kind(mg, row)  # AVL-KIND
        lint_g6(mg, row)  # AVL-G6
    lint_g3(mg, tokens)
except Exception as e:
    print("ERROR %s: %s" % (type(e).__name__, str(e).splitlines()[0] if str(e) else ""))
    sys.exit(3)
print("\n".join(out))
PY

# gate_lint: sets GATE_ERR (newline-joined `lint:` lines) and returns 1 on any refusal; notes go to stderr.
gate_lint() {
  GATE_ERR=""
  local root w gt rows out line live
  if [ -n "${AIDE_VERIFIER_GATE_ROOT:-}" ]; then root="$AIDE_VERIFIER_GATE_ROOT"
  else
    w="$(command -v "$WMD")" || { GATE_ERR="lint: gate-root unusable: $WMD is not on PATH"; return 1; }
    root="$(dirname "$(dirname "$(readlink -f "$w")")")"
  fi
  if [ ! -f "$root/wm_decide/mergegate.py" ] || [ ! -f "$root/gen/merge-gate.json" ]; then  # AVL-ROOT
    GATE_ERR="lint: gate-root unusable: $root has no wm_decide/mergegate.py + gen/merge-gate.json"; return 1
  fi
  command -v python3 >/dev/null 2>&1 || { GATE_ERR="lint: gate-root unusable: python3 is not on PATH"; return 1; }
  GATE_TMP="$(mktemp -d)" || { GATE_TMP=""; GATE_ERR="lint: gate-root unusable: mktemp failed"; return 1; }
  gt="$GATE_TMP"
  trap 'exit 143' TERM INT HUP   # only while the temp dir exists (the gate_cleanup resets them): a signal then runs the EXIT trap
  if ! "$WMD" list --json >"$gt/rows.json" 2>"$gt/rows.err"; then
    GATE_ERR="lint: G0 cannot read the gated row: $WMD list --json failed: $(head -n1 "$gt/rows.err" | cut -c1-200)"; gate_cleanup; return 1
  fi
  out="$(python3 -I -B -c "$GATE_PY" "$root" "$gt/rows.json" "$GATED" "verifier:$AGENT-verifier-$NAME" "$REPO" "$HEAD" "$SUITE" "$GATE_NAMES" "$PR" "$GATED_RE_FMT" "$COMMIT_TOKEN_RE" 2>&1)"
  local prc=$?
  gate_cleanup
  if [ "$prc" != 0 ]; then
    GATE_ERR="lint: gate-root unusable: $(printf '%s\n' "$out" | head -n1 | sed 's/^ERROR //' | cut -c1-300)"; return 1  # AVL-FAILCLOSED
  fi
  while IFS= read -r line; do
    case "$line" in
      REFUSE\ KIND\ *) GATE_ERR+="${GATE_ERR:+$'\n'}lint: ${line#REFUSE KIND }" ;;
      REFUSE\ *) line="${line#REFUSE }"; GATE_ERR+="${GATE_ERR:+$'\n'}lint: ${line%% *}: ${line#* }" ;;
      NOTE\ *) echo "aide-verifier: lint: note: ${line#NOTE }" >&2 ;;
    esac
  done <<<"$out"
  # G1 (merge-gate compares the verdict COMMIT with the LIVE head): --head must be the live PR head
  if live="$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid 2>&1)"; then
    [ "$live" = "$HEAD" ] || GATE_ERR+="${GATE_ERR:+$'\n'}lint: G1: --head ${HEAD:0:12} != the live head ${live:0:12} of $REPO#$PR (gh pr view headRefOid)"
  else
    GATE_ERR+="${GATE_ERR:+$'\n'}lint: G1: cannot read the live head of $REPO#$PR (gh pr view failed: $(printf '%s' "$live" | head -n1 | cut -c1-160))"
  fi
  [ -z "$GATE_ERR" ]
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
  # ---- self-unit (AVL C3/X1): a launch run inside the unit it would start can never succeed; the own unit is not "another" verifier ----
  local own own_noted=0 target="$AGENT-verifier-$NAME.service" raw
  own="$(own_unit)"   # AVL-OWN
  if [ -n "$own" ] && [ "$own" = "$target" ]; then   # AVL-SELF
    refuse 2 "lint: launch-inside-target-unit $own (own unit read from ${AIDE_VERIFIER_CGROUP_FILE:-/proc/self/cgroup}); run launch outside the unit it would start"
  fi
  # ---- merge-gate lints (AVL): before the queue, the room check, the verifier dir and systemd-run ----
  gate_lint || refuse 2 "$GATE_ERR"
  # ---- one at a time ----
  mkdir -p "$ROOT" || die 2 "cannot create $ROOT"
  exec 9>"$ROOT/.launch.lock"
  local waited=0 maxw="${AIDE_VERIFIER_QUEUE_MAX_S:-3600}" act
  while :; do
    flock -x 9
    raw="$(active_units)"
    act="$(printf '%s\n' "$raw" | grep -vxF -- "$own" | tr '\n' ' ')"   # AVL-DROPOWN
    if [ -n "$own" ] && [ "$own_noted" != 1 ] && printf '%s\n' "$raw" | grep -qxF -- "$own"; then
      own_noted=1; echo "aide-verifier: own unit $own excluded from the one-at-a-time wait (cgroup ${AIDE_VERIFIER_CGROUP_FILE:-/proc/self/cgroup})" >&2
    fi
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
  [ "$own_noted" != 1 ] || echo "$(iso) own-unit-excluded unit=$own" >>"$DIR/state"
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
  list) [ -z "${FAKE_WMD_TERM:-}" ] || { kill -TERM "$PPID"; sleep 1; }; [ "$2" = --json ] && cat "$FAKE_DIR/rows.json" ;;
  merge-gate) if [ "${FAKE_GATE:-pass}" = pass ]; then echo "PASS verdict=$2 pr=7 oid=0123456789ab"; else echo "G3 FAIL token 'tests/x EXIT=0' missing from the log"; exit 1; fi ;;
  record) [ -z "${FAKE_RECORD_FAIL:-}" ] || { echo "refused" >&2; exit 2; }; echo "d-20261023-070000-aide-0001" ;;
esac
F
  printf '#!/bin/bash\nprintf "%%s|%%s\\n" "${EVENT_SOURCE:-}" "$*" >>"$FAKE_DIR/bell.log"\n' >"$T/bin/fake-bell"
  printf '#!/bin/bash\nif [ "${FAKE_ROOM:-ok}" = ok ]; then echo "{\\"ok\\":true,\\"room_mb\\":9000}"; else echo "{\\"ok\\":false,\\"room_mb\\":-5}"; exit 1; fi\n' >"$T/bin/fake-room"
  # gh: a fake on PATH (G1 reads the live head); FAKE_GH_HEAD overrides, FAKE_GH_FAIL fails
  printf '#!/bin/bash\n[ -z "${FAKE_GH_FAIL:-}" ] || { echo "gh: HTTP 502" >&2; exit 1; }\nprintf "%%s\\n" "${FAKE_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}"\n' >"$T/bin/gh"
  # the fake merge-gate tree: a package stub exposing the names the lint imports (tests/aide-verifier-gate-nodrift.test.sh checks the REAL tree has them)
  mkgate() {  # mkgate <root> <repo_tokens json> [renamed]
    mkdir -p "$1/wm_decide" "$1/gen"; : >"$1/wm_decide/__init__.py"
    printf '%s\n' "{\"repo_tokens\": $2}" >"$1/gen/merge-gate.json"
    cat >"$1/wm_decide/contract.py" <<'F'
def canon_agent(a):
    return {"coder:aide": "aide"}.get(a, a)
F
    cat >"$1/wm_decide/mergegate.py" <<'F'
import re
from . import contract
AGENT_RE = re.compile(r"\bagent=([A-Za-z0-9:._-]+)")
AUTHOR_RE = re.compile(r"\bauthor=([A-Za-z0-9:._-]+)")
COMMIT_RE = re.compile(r"\bCOMMIT=([0-9A-Fa-f]{12,40})\b")
def strip_attachments(evidence):
    out, skip = [], False
    for ln in (evidence or "").splitlines():
        if ln.startswith("ATTACH sha256="): skip = True
        elif skip and ln == "ATTACH-END": skip = False
        elif not skip: out.append(ln)
    return "\n".join(out)
def _agent_token(row, rx=AGENT_RE):
    for k in ("what", "evidence", "why"):
        m = rx.search(strip_attachments(row.get(k) or ""))
        if m: return m.group(1)
    return None
def g3_missing(tokens, atts, commit):
    missing = []
    for tok in tokens:
        if tok.endswith(" EXIT=0"):
            ok = any(a["trailer"].get("EXIT") == "0" and tok[:-7] in (a["trailer"].get("CMD") or "") for a in atts)
        else:
            ok = any(tok in ln for a in atts for ln in a["body"])
        if not ok: missing.append(tok)
    return missing, None
F
    [ -z "${3:-}" ] || sed -i 's/^def _agent_token/def _agent_token_renamed/' "$1/wm_decide/mergegate.py"
  }
  local TOK='{"j0yen/dotfiles": ["tests/*.test.sh EXIT=0"], "j0yen/synthorg": ["pytest EXIT=0"], "j0yen/mcphost": ["-D warnings EXIT=0", "clippy delta=0", "cargo test EXIT=0"]}'
  mkgate "$T/gate" "$TOK"
  export AIDE_VERIFIER_GATE_ROOT="$T/gate"
  mkdir -p "$T/home/wintermute/swarm-decide"; cp -r "$T/gate/." "$T/home/wintermute/swarm-decide/"; mkgate "$T" "$TOK"   # decoys: the old default root and the tree next to fake-wmd must never be used
  local G0=d-20261023-055215-aide-0001 GB=d-20261023-055216-aide-0002 GC=d-20261023-055217-aide-0003 GD=d-20261023-055218-aide-0004 GE=d-20261023-055219-aide-0005 GF=d-20261023-055220-aide-0006 GN=d-20261023-055221-aide-0007
  local GS=d-20261023-055222-aide-0008 GM=d-20261023-055223-aide-0009 GU=d-20261023-055224-aide-000a GV=d-20261023-055225-aide-000b
  local K1=d-20261023-055231-aide-0101 K2=d-20261023-055232-aide-0102 K4=d-20261023-055234-aide-0104 K6=d-20261023-055236-aide-0106 K7=d-20261023-055237-aide-0107
  local K8=d-20261023-055238-aide-0108 K9=d-20261023-055239-aide-0109 K10=d-20261023-055240-aide-010a K11=d-20261023-055241-aide-010b K12=d-20261023-055242-aide-010c
  local OLD=1111111111111111111111111111111111111111
  # C1/X4 replay fixtures: the `what` field ONLY of three real ledger rows that the old launch accepted as --gated (full ids; no test needs the rows to still exist)
  local RE2F0=d-20261023-122449-rb-e2f0 R0A48=d-20261023-124514-rb-0a48 R864D=d-20261023-125130-rb-864d GR=d-20261023-055250-aide-0201
  # copies the `what` of row d-20261023-122449-rb-e2f0 (kind=plan, rb, the rrd coder spawn)
  local WE2F0='rrd coder SPAWN rb-launch-rrd (sonnet, --no-cargo) on spec v0.2 with Fable R1-R6 (positive control, absolute-path grep, .bak cmp list, mutation only under fakes, observable hermetic default, name the test runner)'
  # copies the `what` of row d-20261023-124514-rb-0a48 (kind=other, rb, the etx coder spawn)
  local W0A48='etx coder spawn (--no-cargo, own mktemp clone of j0yen/dotfiles): rb-etx-watch.sh per coders/etx.spec.md v0.2 (Fable AGREE-WITH-EDITS G1-G11 folded)'
  # copies the `what` of row d-20261023-125130-rb-864d (kind=other, rb, the shu respawn)
  local W864D='shu RESPAWN on spec v0.3: stopped the v0.2 coder at STEP 0 (nothing pushed) and respawned with ctl 12:27 G10-G12 (rb-run-coder refuses any hold rc other than 0/76; the engine crash at rb-spawn-hold.sh:238 holds non-exempt spawns) plus Fable H1-H7, so it stays ONE PR as ctl asked'
  # every gated row is a GATED row for its repo#7 at $H unless the case says otherwise (L-KIND); GF's agent= sits only inside an ATTACH block
  cat >"$T/rows.json" <<F
[{"id":"$G","agent":"aide","what":"GATED j0yen/dotfiles#7 COMMIT=$H agent=coder:avl done","why":"","evidence":""},
 {"id":"$G0","agent":"aide","what":"GATED j0yen/dotfiles#7 COMMIT=$H no coder named","why":"x","evidence":""},
 {"id":"$GB","agent":"aide","what":"GATED j0yen/dotfiles#7 COMMIT=$H agent=verifier:aide-verifier-gl-b","why":"","evidence":""},
 {"id":"$GC","agent":"aide","what":"GATED j0yen/dotfiles#7 COMMIT=$H agent=coder:x author=verifier:aide-verifier-gl-c","why":"","evidence":""},
 {"id":"$GD","agent":"verifier:aide-verifier-gl-d","what":"GATED j0yen/dotfiles#7 COMMIT=$H agent=coder:x","why":"","evidence":""},
 {"id":"$GE","agent":"aide","what":"GATED j0yen/dotfiles#7 COMMIT=$OLD agent=coder:x","why":"","evidence":""},
 {"id":"$GF","agent":"aide","what":"GATED j0yen/dotfiles#7 COMMIT=$H no coder here","why":"","evidence":"ATTACH sha256=$(printf 'a%.0s' {1..64}) lines=1 file=/x.log\nagent=coder:only-in-attach\nATTACH-END"},
 {"id":"$GN","agent":"aide","what":"GATED j0yen/dotfiles#7 COMMIT=$H agent=coder:n","why":"","evidence":""},
 {"id":"$GS","agent":"aide","what":"GATED j0yen/synthorg#7 COMMIT=$H agent=coder:s","why":"","evidence":""},
 {"id":"$GM","agent":"aide","what":"GATED j0yen/mcphost#7 COMMIT=$H agent=coder:m","why":"","evidence":""},
 {"id":"$GU","agent":"aide","what":"GATED j0yen/unknown#7 COMMIT=$H agent=coder:u","why":"","evidence":""},
 {"id":"$GV","agent":"aide","what":"GATED j0yen/live2only#7 COMMIT=$H agent=coder:l","why":"","evidence":""},
 {"id":"$K1","agent":"aide","kind":"plan","what":"PLAN j0yen/dotfiles#7 COMMIT=$H agent=coder:x","why":"","evidence":""},
 {"id":"$K2","agent":"aide","what":"GATED j0yen/dotfiles#8 COMMIT=$H agent=coder:x","why":"","evidence":""},
 {"id":"$K4","agent":"aide","what":"GATED j0yen/dotfiles#7 COMMIT=${H:0:12} agent=coder:x","why":"","evidence":""},
 {"id":"$K6","agent":"aide","kind":"other","what":"SPAWN coder:x j0yen/dotfiles#7 COMMIT=$H agent=coder:x","why":"","evidence":""},
 {"id":"$K7","agent":"aide","what":"GATED j0yen/dotfiles#53 COMMIT=$H agent=coder:x","why":"","evidence":""},
 {"id":"$K8","agent":"aide","what":"GATED j0yen/dotfiles#7 COMMIT=${H}a agent=coder:x","why":"","evidence":""},
 {"id":"$K9","agent":"aide","what":"GATED j0yen/dotfiles#7 COMMIT=${H^^} agent=coder:x","why":"","evidence":""},
 {"id":"$K10","agent":"aide","what":"GATED j0yen/dotfiles#7 COMMIT=$H and COMMIT=$OLD agent=coder:x","why":"","evidence":""},
 {"id":"$K11","agent":"aide","what":"GATED j0yen/dotfiles#7 agent=coder:x","why":"","evidence":""},
 {"id":"$K12","agent":"aide","what":"xGATED j0yen/dotfiles#7 COMMIT=$H agent=coder:x","why":"","evidence":""},
 {"id":"$GR","agent":"aide","what":"GATED j0yen/dotfiles#7 agent=coder:x COMMIT=$H","why":"","evidence":""},
 {"id":"$RE2F0","agent":"rb","kind":"plan","what":"$WE2F0","why":"","evidence":""},
 {"id":"$R0A48","agent":"rb","kind":"other","what":"$W0A48","why":"","evidence":""},
 {"id":"$R864D","agent":"rb","kind":"other","what":"$W864D","why":"","evidence":""}]
F
  chmod +x "$T"/bin/*
  export PATH="$T/bin:$PATH"
  export HOME="$T/home" FAKE_DIR="$T" AIDE_VERIFIER_DIR="$T/av" AIDE_VERIFIER_ROOM_CMD="$T/bin/fake-room" AIDE_VERIFIER_SYSTEMD_RUN="$T/bin/fake-sdrun" \
    AIDE_VERIFIER_SYSTEMCTL="$T/bin/fake-systemctl" AIDE_VERIFIER_WM_DECIDE="$T/bin/fake-wmd" AIDE_VERIFIER_BELL="$T/bin/fake-bell" AIDE_VERIFIER_POLL_S=1 \
    AIDE_VERIFIER_CGROUP_FILE="$T/cgroup-absent"   # the selftest never reads the real /proc/self/cgroup (it may itself run inside a *-verifier-* unit)
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

  # ---- merge-gate lints (AVL): every case must stop before the queue, the room check, the verifier dir and systemd-run ----
  rm -f "$T/sdrun.log"; : >"$T/active"
  GL() { local nm="$1"; shift; L "$nm" --repo j0yen/dotfiles --pr 7 --head "$H" --gated "$G" --token 'tests/*.test.sh EXIT=0' --suite 'bash tests/run.sh; echo "tests/*.test.sh EXIT=$?"' "$@"; }
  none() { [ ! -e "$T/sdrun.log" ] && [ ! -e "$T/av/$1" ]; }
  out="$(GL gl-a --gated "$G0")"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"lint: G6"* ]] && none gl-a; chk "gate lint (a): a gated row with no agent= -> exit 2, G6" $?
  out="$(GL gl-b --gated "$GB")"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"lint: G6"* ]] && [[ "$out" == *"equals"* ]] && none gl-b; chk "gate lint (b): the gated row's agent= equals the verifier id -> exit 2, G6" $?
  out="$(GL gl-c --gated "$GC")"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"lint: G6"* ]] && [[ "$out" == *"author="* ]] && none gl-c; chk "gate lint (V1): the gated row's author= equals the verifier id -> exit 2, G6" $?
  out="$(GL gl-d --gated "$GD")"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"lint: G6"* ]] && [[ "$out" == *"agent column"* ]] && none gl-d; chk "gate lint (V1): the gated row's agent column equals the verifier id -> exit 2, G6" $?
  out="$(GL gl-f --gated "$GF")"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"lint: G6"* ]] && [[ "$out" == *"names no agent="* ]] && none gl-f; chk "gate lint (V2): an agent= only inside an ATTACH block does not count -> exit 2, G6" $?
  out="$(GL gl-0 --gated d-20261023-055299-aide-ffff)"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"lint: G0"* ]] && none gl-0; chk "gate lint: a missing gated row -> exit 2, G0" $?
  out="$(L gl-c1 --repo j0yen/synthorg --pr 7 --head "$H" --gated "$GS" --token 'pytest EXIT=0' --suite 'uv run --frozen synthorg contracts check')"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"lint: G3"* ]] && [[ "$out" == *"pytest"* ]] && none gl-c1; chk "gate lint (c): a synthorg suite without pytest -> exit 2, G3" $?
  out="$(GL gl-d1 --suite 'bash tests/x.test.sh')"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"lint: G3"* ]] && none gl-d1; chk "gate lint (d): the dotfiles single-file suite (the 7f76 case) -> exit 2, G3" $?
  out="$(L gl-e --repo j0yen/unknown --pr 7 --head "$H" --gated "$GU" --token t --suite s)"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"lint: G3"* ]] && [[ "$out" == *"no required-check entry"* ]] && none gl-e; chk "gate lint (e): an unknown repo -> exit 2, G3" $?
  out="$(AIDE_VERIFIER_GATE_ROOT="$T/nonexistent" GL gl-f1)"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"gate-root unusable"* ]] && none gl-f1; chk "gate lint (f): a missing gate root -> exit 2, gate-root unusable (decoys at \$HOME/wintermute/swarm-decide and next to wm-decide are not used)" $?
  mkgate "$T/gate-renamed" "$TOK" renamed
  out="$(AIDE_VERIFIER_GATE_ROOT="$T/gate-renamed" GL gl-v4)"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"gate-root unusable: AttributeError"* ]] && none gl-v4; chk "gate lint (V4): a stub without _agent_token -> exit 2, gate-root unusable (never falls through)" $?
  out="$(FAKE_GH_HEAD=ffffffffffffffffffffffffffffffffffffffff GL gl-g1)"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"lint: G1"* ]] && none gl-g1; chk "gate lint (V6): --head != the live PR head -> exit 2, G1" $?
  out="$(FAKE_GH_FAIL=1 GL gl-g2)"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"lint: G1: cannot read the live head"* ]] && none gl-g2; chk "gate lint (V6): a gh failure -> exit 2, G1 (fail closed)" $?
  # L-KIND (V9 + W1-W6): the --gated row must be a GATED row for this repo#pr whose single COMMIT= is the full --head. kc <case> <FAKE head-less args...>
  kref() {  # kref <label> <row id> <expect substring> [extra GL args]  (refused: exit 2, a KIND line naming the part, nothing started)
    local lbl="$1" id="$2" want="$3"; shift 3
    out="$(GL "gl-$lbl" --gated "$id" "$@")"; rc=$?
    [ "$rc" = 2 ] && [[ "$out" == *"lint: gated row $id is not a GATED row for j0yen/dotfiles#"* ]] && [[ "$out" == *": $want"* ]] && [[ "$out" == *"ctl 12:59 + 1:11"* ]] && none "gl-$lbl"
  }
  kref k1 "$K1" "no GATED token for j0yen/dotfiles#7";                    chk "gate lint (k1): a kind=plan row with no GATED token -> exit 2, names the missing GATED token and the ctl ruling" $?
  kref k2 "$K2" "no GATED token for j0yen/dotfiles#7";                    chk "gate lint (k2): GATED for a different pr number (#8 vs #7) -> exit 2" $?
  kref k3 "$GE" "COMMIT=111111111111 is stale (head is ${H:0:12})";       chk "gate lint (k3): GATED at an older COMMIT than --head -> exit 2 (stale), even though --head is the live PR head" $?
  kref k4 "$K4" "COMMIT=${H:0:12} is not a full 40-hex sha";              chk "gate lint (k4): a 12-hex COMMIT prefix -> exit 2" $?
  out="$(FAKE_ROOM=no GL gl-k5 --gated "$G")"; rc=$?
  [ "$rc" = 3 ] && [[ "$out" != *"lint:"* ]] && [ ! -e "$T/sdrun.log" ]; chk "gate lint (k5): a correct GATED row passes L-KIND (reaches the room check, exit 3, no lint line)" $?
  kref k6 "$K6" "no GATED token for j0yen/dotfiles#7";                    chk "gate lint (k6/W1): a kind=other SPAWN row (today's class) -> exit 2, no GATED token" $?
  out="$(L gl-k7 --repo j0yen/dotfiles --pr 5 --head "$H" --gated "$K7" --token 'tests/*.test.sh EXIT=0' --suite 'bash tests/run.sh; echo "tests/*.test.sh EXIT=$?"')"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"lint: gated row $K7 is not a GATED row for j0yen/dotfiles#5 at"* ]] && [[ "$out" == *"no GATED token"* ]] && none gl-k7; chk "gate lint (k7/W2): a row for #53 launched as #5 -> exit 2 (word boundary)" $?
  kref k8 "$K8" "COMMIT=${H}a is not a full 40-hex sha";                            chk "gate lint (k8/W2): a 41-hex COMMIT -> exit 2" $?
  out="$(FAKE_ROOM=no GL gl-k9 --gated "$K9")"; rc=$?
  [ "$rc" = 3 ] && [[ "$out" != *"lint:"* ]] && [ ! -e "$T/sdrun.log" ]; chk "gate lint (k9/W3): an uppercase full COMMIT equal to --head passes L-KIND" $?
  kref k10 "$K10" "ambiguous COMMIT (2 tokens), write a fresh GATED row"; chk "gate lint (k10/W5): two COMMIT tokens -> exit 2 ambiguous" $?
  kref k11 "$K11" "no COMMIT";                                            chk "gate lint (k11/W5): zero COMMIT tokens -> exit 2" $?
  kref k12 "$K12" "no GATED token for j0yen/dotfiles#7";                  chk "gate lint (k12/W2): xGATED (no leading boundary) -> exit 2" $?
  out="$(FAKE_ROOM=no GL gl-g)"; rc=$?
  [ "$rc" = 3 ] && [[ "$out" != *"lint:"* ]] && [ ! -e "$T/sdrun.log" ]; chk "gate lint (g): a correct launch passes every gate lint and reaches the room stage (exit 3, no lint line)" $?
  out="$(FAKE_ROOM=no L gl-h --repo j0yen/mcphost --pr 7 --head "$H" --gated "$GM" --token 't' --suite 'cargo test -D warnings; echo clippy delta=0')"; rc=$?
  [ "$rc" = 3 ] && [[ "$out" == *"lint: note: clippy delta=0 is checked from the log only"* ]] && [[ "$out" != *"lint: G3"* ]] && [ ! -e "$T/sdrun.log" ]; chk "gate lint (h): a non-EXIT token prints the note and does not refuse" $?
  # C1: negative controls replaying the real misses (each gated row's `what` is copied verbatim from the ledger row named at its definition)
  kref c1-e2f0 "$RE2F0" "no GATED token for j0yen/dotfiles#7";            chk "gate lint (C1/e2f0): the real kind=plan row e2f0 as --gated -> exit 2, no GATED token" $?
  kref c1-0a48 "$R0A48" "no GATED token for j0yen/dotfiles#7";            chk "gate lint (C1/0a48): the real coder-spawn row 0a48 as --gated -> exit 2, no GATED token" $?
  kref c1-864d "$R864D" "no GATED token for j0yen/dotfiles#7";            chk "gate lint (C1/864d): the real shu respawn row 864d as --gated -> exit 2, no GATED token" $?
  out="$(FAKE_ROOM=no GL gl-c1-pos --gated "$GR")"; rc=$?
  [ "$rc" = 3 ] && [[ "$out" != *"lint:"* ]] && [ ! -e "$T/sdrun.log" ]; chk "gate lint (C1/pos): a row 'GATED <repo>#<pr> agent=coder:x COMMIT=<head>' passes every lint (reaches the room stage)" $?
  out="$(GL gl-c1-rr --suite 'bash tests/rb-redrive.test.sh')"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"lint: G3"* ]] && [[ "$out" == *"tests/*.test.sh"* ]] && none gl-c1-rr; chk "gate lint (C1/rr): a single-file --suite 'bash tests/rb-redrive.test.sh' for j0yen/dotfiles -> exit 2, G3" $?
  # C2/X5: the gate-lint temp dir lives under TMPDIR; it must be gone after a refusal (rc 2), a signal inside the lint window (rc 143) and (below) rc 6 and rc 0
  local td; td="$(mktemp -d)"
  out="$(TMPDIR="$td" GL gl-c2-rc2 --gated "$G0")"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"lint: G6"* ]] && [ -z "$(ls -A "$td")" ]; chk "gate lint (C2/rc2): a refused launch (rc 2) leaves the TMPDIR root empty" $?
  out="$(TMPDIR="$td" FAKE_WMD_TERM=1 GL gl-c2-term)"; rc=$?
  [ "$rc" = 143 ] && none gl-c2-term && [ -z "$(ls -A "$td")" ]; chk "gate lint (C2/term): a SIGTERM during the gate lint (rc 143) leaves the TMPDIR root empty (the EXIT trap, not the inline cleanup)" $?
  # V8: the override is not honoured when the variable is unset: the root comes from realpath(command -v wm-decide), two dirs up
  mkgate "$T/live2" '{"j0yen/live2only": ["pytest EXIT=0"]}'; mkdir -p "$T/live2/bin" "$T/pathbin"
  cp "$T/bin/fake-wmd" "$T/live2/bin/wm-decide"; ln -s "$T/live2/bin/wm-decide" "$T/pathbin/wm-decide"
  out="$(env -u AIDE_VERIFIER_GATE_ROOT AIDE_VERIFIER_WM_DECIDE=wm-decide PATH="$T/pathbin:$PATH" FAKE_ROOM=no "$SELF" launch gl-v8 --repo j0yen/live2only --pr 7 --head "$H" --gated "$GV" --token 'pytest EXIT=0' --suite 'uv run pytest' 2>&1)"; rc=$?
  [ "$rc" = 3 ] && [[ "$out" != *"lint:"* ]]; chk "gate lint (V8): AIDE_VERIFIER_GATE_ROOT unset -> the root is dirname(dirname(realpath(command -v wm-decide))) (a repo only in that tree passes)" $?
  out="$(env -u AIDE_VERIFIER_GATE_ROOT AIDE_VERIFIER_WM_DECIDE=wm-decide PATH="$T/pathbin:$PATH" FAKE_ROOM=no "$SELF" launch gl-v8b --repo j0yen/dotfiles --pr 7 --head "$H" --gated "$G" --token 'tests/*.test.sh EXIT=0' --suite 'bash tests/x.test.sh' 2>&1)"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"lint: G3"* ]] && [[ "$out" == *"no required-check entry"* ]]; chk "gate lint (V8): unset override does not fall back to the AIDE_VERIFIER_GATE_ROOT tree or the decoy" $?
  rm -rf -- "${T:?}/home/wintermute" "${T:?}/live2" "${T:?}/pathbin" "${T:?}/wm_decide" "${T:?}/gen"
  none gl-v8; chk "gate lints never create the verifier dir" $?

  echo "aide-verifier-other.service" >"$T/active"
  out="$(L act1 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"one at a time"* ]] && [ ! -e "$T/sdrun.log" ]; chk "another unit active, no --queue -> exit 2, nothing started" $?
  ( sleep 2; : >"$T/active" ) & local t0=$SECONDS
  out="$(L act2 "${A[@]}" --head "$H" --queue)"; rc=$?; wait
  [ "$rc" = 0 ] && [ $((SECONDS - t0)) -ge 1 ] && [ "$out" = aide-verifier-act2 ]; chk "--queue waits until the other unit is gone, then launches ($out, $((SECONDS - t0)) s)" $?
  echo "aide-verifier-other.service" >"$T/active"
  out="$(AIDE_VERIFIER_QUEUE_MAX_S=2 L act3 "${A[@]}" --head "$H" --queue)"; rc=$?
  [ "$rc" = 6 ]; chk "--queue gives up after AIDE_VERIFIER_QUEUE_MAX_S -> exit 6" $?
  out="$(TMPDIR="$td" AIDE_VERIFIER_QUEUE_MAX_S=2 L c2rc6 "${A[@]}" --head "$H" --queue)"; rc=$?
  [ "$rc" = 6 ] && [ -z "$(ls -A "$td")" ]; chk "gate lint (C2/rc6): a queue timeout (rc 6) leaves the TMPDIR root empty" $?
  : >"$T/active"
  out="$(TMPDIR="$td" L c2rc0 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 0 ] && [ -z "$(ls -A "$td")" ]; chk "gate lint (C2/rc0): a successful launch (rc 0) leaves the TMPDIR root empty" $?
  rm -rf -- "${td:?}"
  # C3 (ctl 1:14 + X1-X3): the caller's own unit is not "another" verifier unit
  printf '0::/user.slice/user-1000.slice/user@1000.service/app.slice/aide-verifier-s1own.service\n' >"$T/cg-own"
  echo "aide-verifier-s1own.service" >"$T/active"
  out="$(AIDE_VERIFIER_CGROUP_FILE="$T/cg-own" AIDE_VERIFIER_QUEUE_MAX_S=2 L s1 "${A[@]}" --head "$H" --queue)"; rc=$?
  [ "$rc" = 0 ] && [[ "$out" == *"own unit aide-verifier-s1own.service excluded"* ]] && grep -q 'own-unit-excluded unit=aide-verifier-s1own.service' "$T/av/s1/state"; chk "gate lint (s1): the own unit is the only active unit, --queue -> launches (rc 0, not 6), the exclusion names the unit on stderr and in the launch state" $?
  echo "aide-verifier-s1own.service" >"$T/active"; echo "aide-verifier-other.service" >>"$T/active"; rm -f "$T/sdrun.log"
  out="$(AIDE_VERIFIER_CGROUP_FILE="$T/cg-own" L s2 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"one at a time"* ]] && [[ "$out" == *"aide-verifier-other.service"* ]] && [ ! -e "$T/sdrun.log" ]; chk "gate lint (s2): own unit + another verifier unit active, no --queue -> still exit 2 one at a time" $?
  echo "aide-verifier-other.service" >"$T/active"
  out="$(L s3 "${A[@]}" --head "$H")"; rc=$?   # AIDE_VERIFIER_CGROUP_FILE points at an absent file here
  [ "$rc" = 2 ] && [[ "$out" == *"one at a time"* ]] && [ ! -e "$T/sdrun.log" ]; chk "gate lint (s3): cgroup file absent + only a foreign unit active -> exit 2 as before" $?
  printf '0::/user.slice/user-1000.slice/user@1000.service/app.slice/aide-verifier-s5own.service/sub\n' >"$T/cg-sub"
  echo "aide-verifier-s5own.service" >"$T/active"
  out="$(AIDE_VERIFIER_CGROUP_FILE="$T/cg-sub" L s5 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"one at a time"* ]] && [[ "$out" != *"excluded"* ]]; chk "gate lint (s5/X2): a cgroup line whose final component is a sub-cgroup dir (not .service) excludes nothing (no backward scan)" $?
  printf '0::/user.slice/user-1000.slice/user@1000.service/app.slice/aide-verifier-s4.service\n' >"$T/cg-tgt"
  : >"$T/active"; t0=$SECONDS; rm -f "$T/sdrun.log"
  out="$(AIDE_VERIFIER_CGROUP_FILE="$T/cg-tgt" L s4 "${A[@]}" --head "$H" --queue)"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"lint: launch-inside-target-unit aide-verifier-s4.service"* ]] && [ $((SECONDS - t0)) -lt 2 ] && [ ! -e "$T/sdrun.log" ] && none s4; chk "gate lint (s4/X1): own unit == the unit this launch would start, --queue -> exit 2 launch-inside-target-unit, no wait, names the unit" $?
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
  --gate-names) echo "$GATE_NAMES"; exit 0 ;;
  --gate-grammar) printf '%s\n%s\n' "$GATED_RE_FMT" "$COMMIT_TOKEN_RE"; exit 0 ;;
  --selftest) selftest; exit $? ;;
  launch) shift; cmd_launch "$@" ;;
  finish) shift; cmd_finish "$@" ;;
  watch) shift; cmd_watch "$@" ;;
  *) sed -n '2,29p' "$SELF" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
