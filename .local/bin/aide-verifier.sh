#!/usr/bin/env bash
# aide-verifier.sh: the aide's merge-gate VERIFIER unit as a mechanism (controller DECISION 0e71; was hand-written prompt.md + launch.sh per PR).
#   AGENT: AIDE_VERIFIER_AGENT (default aide; aide|rb|r7, anything else -> exit 2) is the wm-decide --agent of every row (verdict template, GATE-PASS, RETRACT),
#   the template's agent=verifier:/recorded_by=unit: fields, the bell text prefix ("<agent> EVENT ...", EVENT_SOURCE) and the unit prefix <agent>-verifier-<name>.
#   The rb/r7 seats run their own claude on carbon too, so ROOM and systemd-run are unchanged; the verdict row still comes from the headless unit's own session (G7).
#   Below, "aide" in unit/field names means <agent>; the cap looks at every (aide|rb|r7)-verifier-* unit.
#   launch <name> --repo O/R --pr N --head <40-hex> --gated <d-id> --token '<G3 token line>' --suite '<ONE command for wm-verify-run>'
#          [--clone-url URL] [--notes TEXT] [--expect TEXT] [--queue] [--prio 0|1]
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
#       counts toward the fleet gate's ceiling below (the own unit is excluded from step 3's active count and from step 4's MemoryCurrent sum, and the exclusion is printed).
#   FLEET GATE (vcap v0.3, ctl 9be3): ONE lock at the FIXED path $HOME/.local/state/verifier-cap/launch.lock for every launcher of rb, r7 and aide. Neither the lock
#       nor the numbers move with AIDE_VERIFIER_DIR or any seat env; only the selftest (AIDE_VERIFIER_SELFTEST=1) may override AIDE_VERIFIER_LOCK / AIDE_VERIFIER_SLOT_CEIL
#       / AIDE_VERIFIER_PEAK_MB (integers >= 1, else exit 9) / AIDE_VERIFIER_TOKEN_FILE / AIDE_VERIFIER_LOCK_WAIT_S / AIDE_VERIFIER_TIMEOUT_S. Inside the lock, in order:
#       1 PRIORITY  every launch takes a ticket $HOME/.local/state/verifier-cap/queue/<prio>-<epoch_ns>-<pid> (prio 0 = --repo j0yen/synthorg|mcphost|wm-build, else 1;
#         --prio 0|1 overrides) and proceeds only when its ticket sorts first among LIVE tickets (kill -0 pid and /proc/<pid>/cmdline has aide-verifier; dead ones are
#         removed by whoever sees them). Not head-of-line: exit 11 without --queue, else wait. The ticket goes in the same EXIT trap that releases fd 9.
#       2 429 BREAKER  TRIPPED iff some $ROOT/*/result.json with api_error_status 429 is newer than the token file (~/.config/environment.d/90-claude-oauth.conf) and no
#         non-429 result is newer than that newest 429. Half-open: that 429 older than 30 min and 0 active admits exactly ONE probe, recorded in
#         $HOME/.local/state/verifier-cap/breaker.state keyed by the 429's mtime (a second probe for the same key stays tripped). Tripped: exit 10 without --queue, else wait.
#         Bells (seat-event.sh) r7 (token owner) and the launching seat (WM_SEAT, else rb), once per trip id each.
#       3 CEILING  active (aide|rb|r7)-verifier-* units (own unit excluded) must be < SLOT_CEIL (4): exit 2 without --queue, else wait.
#       4 ROOM     need = max(PEAK_MB, PEAK_MB x (active+1) - SUM_cur) MB, PEAK_MB = 1024 (the per-verifier admission price), SUM_cur = sum of MemoryCurrent of the active
#         units (their current RSS is already out of MemAvailable, their remaining ramp is not); `carbon-room.sh <need> --json` must exit 0: else exit 3 without --queue, else wait.
#         MemoryMax=2G per unit stays the kill ceiling, not the price. Then systemd-run (lock fd closed for the unit).
#       --queue waits (poll AIDE_VERIFIER_POLL_S=10, up to AIDE_VERIFIER_QUEUE_MAX_S=3600, then exit 6) with the lock RELEASED. Any other gate in front of a verifier launch
#       must `exec aide-verifier.sh launch ... --queue`; verifier-cap-watch.sh bells rb + ctl when more than SLOT_CEIL units are active or a unit's MemoryPeak tops PEAK_MB.
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
# Exit: 0 ok / 1 systemd-run failed / 2 lint or usage or ceiling reached / 3 no room / 4 no verdict row / 5 merge-gate FAIL / 6 wait timeout (queue or lock) / 7 gate passed, row not recorded / 9 bad SLOT_CEIL or PEAK_MB (selftest only) / 10 429 breaker tripped / 11 not head-of-line.
# Never runs the real claude itself (only the generated launch.sh does, under the unit), never merges, never prints a token (output is redacted).
set -u
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
shopt -u patsub_replacement 2>/dev/null
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
AGENT="${AIDE_VERIFIER_AGENT:-aide}"
ROOT="${AIDE_VERIFIER_DIR:-$HOME/.local/state/aide-verifier}"
# the fleet-wide gate: fixed lock path + fixed numbers, independent of ROOT and of every seat env (vcap); the selftest alone may override
LOCK="$HOME/.local/state/verifier-cap/launch.lock"
SLOT_CEIL=4
PEAK_MB=1024
TOKEN_FILE="$HOME/.config/environment.d/90-claude-oauth.conf"
LOCK_WAIT_S=600
CMD_TIMEOUT_S=120
if [ "${AIDE_VERIFIER_SELFTEST:-}" = 1 ]; then
  LOCK="${AIDE_VERIFIER_LOCK:-$LOCK}"; LOCK_WAIT_S="${AIDE_VERIFIER_LOCK_WAIT_S:-$LOCK_WAIT_S}"; CMD_TIMEOUT_S="${AIDE_VERIFIER_TIMEOUT_S:-$CMD_TIMEOUT_S}"
  TOKEN_FILE="${AIDE_VERIFIER_TOKEN_FILE:-$TOKEN_FILE}"
  if [ -n "${AIDE_VERIFIER_SLOT_CEIL+x}" ]; then SLOT_CEIL="$AIDE_VERIFIER_SLOT_CEIL"; fi
  if [ -n "${AIDE_VERIFIER_PEAK_MB+x}" ]; then PEAK_MB="$AIDE_VERIFIER_PEAK_MB"; fi
fi
ROOM_CMD="${AIDE_VERIFIER_ROOM_CMD:-carbon-room.sh}"
SD_RUN="${AIDE_VERIFIER_SYSTEMD_RUN:-systemd-run}"
SYSTEMCTL="${AIDE_VERIFIER_SYSTEMCTL:-systemctl}"
WMD="${AIDE_VERIFIER_WM_DECIDE:-wm-decide}"
BELL="${AIDE_VERIFIER_BELL:-seat-event.sh}"
POLL="${AIDE_VERIFIER_POLL_S:-10}"
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
# lock_holder: best effort "pid=N cmd=..." of whoever holds $LOCK (fuser, then /proc), for the exit-6 message
lock_holder() {
  local p out="" cmd
  for p in $(fuser "$LOCK" 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    cmd="$(cat "/proc/$p/cmdline" 2>/dev/null | tr '\0' ' ' | cut -c1-120)"
    out="$out pid=$p cmd=${cmd:-?}"
  done
  printf '%s' "${out:- holder unknown}"
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

# ---- the fleet gate helpers (vcap v0.3); all run INSIDE the lock except where noted ----
RESULT_429_RE='"api_error_status" *: *429([^0-9]|$)'
# ticket_live <path>: the ticket's pid is alive AND is an aide-verifier process (a recycled pid is not)
ticket_live() {
  local pid="${1##*-}"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q 'aide-verifier'
}
# head_of_line: removes dead tickets, then succeeds iff my ticket sorts first among the live ones
head_of_line() {
  local t first=""
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if ticket_live "$t"; then [ -n "$first" ] || first="$t"; else rm -f -- "${QDIR:?}/$t"; fi
  done < <(ls -1 "$QDIR" 2>/dev/null | LC_ALL=C sort)
  [ "$first" = "$(basename "$TICKET")" ]
}
# breaker_scan: sets B_TRIP (1 = tripped), B_KEY (mtime epoch of the newest 429), B_AGE (seconds since it)
breaker_scan() {
  local f newest=""
  B_TRIP=0; B_KEY=""; B_AGE=0
  for f in "$ROOT"/*/result.json; do
    [ -e "$f" ] || continue
    grep -qE "$RESULT_429_RE" "$f" 2>/dev/null || continue
    if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest="$f"; fi
  done
  [ -n "$newest" ] || return 0
  [ "$newest" -nt "$TOKEN_FILE" ] || return 0   # the token was re-minted after the 429
  for f in "$ROOT"/*/result.json; do
    [ -e "$f" ] && [ "$f" -nt "$newest" ] || continue
    grep -qE "$RESULT_429_RE" "$f" 2>/dev/null || return 0   # a newer non-429 result: the account answers again
  done
  B_KEY="$(stat -c %Y "$newest")"; B_AGE=$(( $(date +%s) - B_KEY )); B_TRIP=1
}
# bell_once <target> <key> <text>: ring <target> once per trip id (breaker.state "bell:<target> <key>")
bell_once() {
  grep -qxF "bell:$1 $2" "$BSTATE" 2>/dev/null && return 0
  EVENT_SOURCE=aide-verifier "$BELL" "$1" "$3" >/dev/null 2>&1
  echo "bell:$1 $2" >>"$BSTATE"
}
# sum_current_mb <unit...>: sum of MemoryCurrent in MB ("[not set]", empty or the 2^64-1 sentinel = 0)
sum_current_mb() {
  local u v sum=0
  for u in "$@"; do
    v="$("$SYSTEMCTL" --user show -p MemoryCurrent --value "$u" 2>/dev/null | head -n1)"
    if [[ "$v" =~ ^[0-9]+$ ]] && [ "${#v}" -le 15 ]; then sum=$((sum + v / 1048576)); fi
  done
  echo "$sum"
}

default_template() {
  cat <<'TPL'
You are a merge-gate VERIFIER running as your own headless claude session (systemd unit {{AGENT}}-verifier-{{NAME}} on carbon). Target: {{REPO}} PR {{PR}}, head {{HEAD}}{{NOTES}}. Scratch dir: {{DIR}}/ — everything you create goes there. GATED row to gate: {{GATED}}.

STEPS
1. Refuse if `gh pr view {{PR}} --repo {{REPO}} --json headRefOid -q .headRefOid` != {{HEAD}} (report the real head, record no row).
2. d=$(mktemp -d -p {{DIR}}); `git clone -q {{CLONE_URL}} $d/repo && git -C $d/repo checkout -q {{HEAD}}`; confirm `git rev-parse HEAD` equals {{HEAD}}.
3. Attribution: `gh api repos/{{REPO}}/pulls/{{PR}}/commits --paginate -q '.[].commit.message'` and `gh pr view {{PR}} --repo {{REPO}} --json body -q .body`; grep each with the anchored case-insensitive regex `^[[:space:]]*(co-authored-by:|generated with)`; both counts must be 0.
4. Suite under the LIVE wrapper from inside the clone as ONE quoted string. The wrapper ~/.local/bin/wm-verify-run has NO --help flag: read its header first; it runs `bash -c` on its single argument and appends WM-VERIFY HEAD/CMD/DIRTY/EXIT lines; the log lands in ~/.local/state/swarm-decide/verify/. Shape:
   cd $d/repo && ~/.local/bin/wm-verify-run {{SUITE_Q}}
   The G3 token is `{{TOKEN}}`. How merge-gate G3 reads it (wm_decide/mergegate.py g3_missing): a token ending in ` EXIT=0` passes when the log's `WM-VERIFY EXIT=0` trailer is present AND the `WM-VERIFY CMD=` trailer contains the text before ` EXIT=0`, so it does NOT have to appear as a literal body line; any other token must appear in a body line. The wrapper's EXIT must be 0, and no FAIL line may appear.{{EXPECT}} If anything fails: STOP, report the failing names, record NO verdict.
5. EVIDENCE BUNDLE (write-time checks V1-V3 read it; the grader sees only its sha256, the last 20 lines and your quoted lines, so evidence missing from the attached file does not exist):
   a. ONE artifact must contain ALL the evidence you cite: full per-test output, result.json content, mutation runs. Never `tail -N` or `grep` evidence down to a summary. Put extra evidence FIRST and the wm-verify-run log LAST so its WM-VERIFY trailer stays in the final lines: `cat <extra evidence files> <log path> > {{DIR}}/bundle.log` (just <log path> when there is no extra evidence). Attach the bundle, not the bare log.
   b. QUOTE: copy 1 to 3 lines VERBATIM from the bundle (for example the suite's `ALL PASS files=N` line) and pass each as `--quote "<line>"`. Prove each with `grep -cF -- "<line>" {{DIR}}/bundle.log` (must print 1 or more) BEFORE recording. A quote is an exact substring of the WHOLE bundle, never a regex and never reworded.
   c. SCOPE: if you ran a subset (`-k`, one file, one test, a path filter), say so in the what line (`scope=-k <expr>`); an undisclosed subset is a correction. No subset: write `scope=full`.
   d. NEVER attach an artifact (same sha256) that is on a FAIL/BLOCK row to a PASS row: re-run and attach the new log. If the bundle shows a real step failure (`EXIT=<n>` with n>0, FAILED), do not record a PASS unless you also pass `--reconciles "<why it is right>"`.
   e. FOLLOW-UPS: if the controller named required follow-up rows or checks in your launch notes, cite their ids in the what line (`follow-up=<id>`); never claim one you did not see.
6. ONE verdict row:
   wm-decide record --agent {{AGENT}} --via verifier --model sonnet --kind verdict --gates {{GATED}} --attach {{DIR}}/bundle.log --quote "<verbatim line 1>" [--quote "<verbatim line 2>"] --target carbon --what "MERGE-OK {{REPO}}#{{PR}} COMMIT={{HEAD}} agent=verifier:{{AGENT}}-verifier-{{NAME}} recorded_by=unit:{{AGENT}}-verifier-{{NAME}} session=own-headless-claude-p: scope=<full|the -k/subset you ran>; fresh clone == head; <a count copied from one log line: write it as N passed (or ran=N pass=N) ONLY with an N that a log line shows as 'N passed', 'pass=N' or 'Ran N tests'; merge-gate G4 refuses any count claim it cannot find in the log, so if the log has no such line write 'all pass, 0 FAIL' and no number> via wm-verify-run ({{TOKEN}}); attribution 0/0" --why "aide-verifier.sh (DECISION 0e71): the verifier is its own session" --evidence "<log path>" --reverse-text "none (verdict row)"
   The 'ungradable:' line is informational; report any refusal verbatim.

HARD CONSTRAINTS: never kill by pattern: no pkill, no killall, no `kill` with a -f or name/pattern argument, no `pgrep|xargs kill` (a pkill -f 'wm-verify-run' hit every seat's suite on carbon, 10-24 11:05 PM); you may kill only PIDs you started yourself, or stop your own unit with `systemctl --user stop {{AGENT}}-verifier-{{NAME}}`; never merge or push; never run the real interactive claude; no ssh; no systemd changes; never write outside your scratch dir except the wm-decide row and the wrapper's own log; never touch /home/jsy/dotfiles, ~/.claude/state, ~/.cache/fleet-dash; never delete anything outside your own mktemp dirs; tool output > 2 KB to a file in the scratch dir; never print key material or a token.

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
  [ $# -ge 1 ] || die 2 "usage: launch <name> --repo O/R --pr N --head <40-hex> --gated <d-id> --token '<line>' --suite '<cmd>' [--clone-url URL] [--notes T] [--expect T] [--queue] [--prio 0|1] [--timeout 60..7200]"
  NAME="$1"; shift
  REPO=""; PR=""; HEAD=""; GATED=""; TOKEN=""; SUITE=""; CLONE_URL=""; NOTES=""; EXPECT=""; QUEUE=0; PRIO=""; VTIMEOUT=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --queue) QUEUE=1; shift; continue ;;
      --repo|--pr|--head|--gated|--token|--suite|--clone-url|--notes|--expect|--prio|--timeout)
        [ $# -ge 2 ] || die 2 "$1 needs a value" ;;
      *) die 2 "unknown argument: $1" ;;
    esac
    case "$1" in
      --repo) REPO="$2" ;; --pr) PR="$2" ;; --head) HEAD="$2" ;; --gated) GATED="$2" ;; --token) TOKEN="$2" ;;
      --suite) SUITE="$2" ;; --clone-url) CLONE_URL="$2" ;; --notes) NOTES="$2" ;; --expect) EXPECT="$2" ;; --prio) PRIO="$2" ;; --timeout) VTIMEOUT="$2" ;;
    esac
    shift 2
  done
  # ---- LINT ----
  # unit timeout: --timeout, else AIDE_VERIFIER_TIMEOUT_S (outside the selftest, where that name is the command timeout), else 2400
  if [ -z "$VTIMEOUT" ] && [ "${AIDE_VERIFIER_SELFTEST:-}" != 1 ]; then VTIMEOUT="${AIDE_VERIFIER_TIMEOUT_S:-}"; fi
  [ -n "$VTIMEOUT" ] || VTIMEOUT=2400
  [[ "$VTIMEOUT" =~ ^[0-9]{1,4}$ ]] && [ "$VTIMEOUT" -ge 60 ] && [ "$VTIMEOUT" -le 7200 ] || die 2 "lint: --timeout must be an integer from 60 to 7200 seconds (got '$VTIMEOUT')"
  [[ "$NAME" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die 2 "lint: name must match [a-z0-9][a-z0-9-]{0,30}: '$NAME'"
  [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die 2 "lint: --repo must be OWNER/NAME"
  [[ "$PR" =~ ^[0-9]+$ ]] || die 2 "lint: --pr must be a number"
  [[ "$HEAD" =~ ^[0-9a-f]{40}$ ]] || die 2 "lint: --head must be 40 lowercase hex chars (got ${#HEAD} chars)"
  [[ "$GATED" =~ ^d-[0-9]{8}-[0-9]{6}-[a-z0-9]+-[0-9a-f]{4}$ ]] || die 2 "lint: --gated must look like d-YYYYMMDD-HHMMSS-<agent>-<4hex>"
  [ -n "${TOKEN//[[:space:]]/}" ] || die 2 "lint: --token (the G3 token line) is empty"
  case "$TOKEN" in *'"'*|*'`'*|*'$'*|*$'\n'*) die 2 "lint: --token must not contain \" \` \$ or a newline" ;; esac
  [ -n "${SUITE//[[:space:]]/}" ] || die 2 "lint: --suite is empty"
  [ -z "$PRIO" ] || [[ "$PRIO" =~ ^[01]$ ]] || die 2 "lint: --prio must be 0 or 1"
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
  # ---- the fleet gate (one fixed lock; ticket -> breaker -> ceiling -> room) ----
  [[ "$SLOT_CEIL" =~ ^[0-9]+$ ]] && [ "$SLOT_CEIL" -ge 1 ] || die 9 "SLOT_CEIL must be an integer >= 1 (got '$SLOT_CEIL')"
  [[ "$PEAK_MB" =~ ^[0-9]+$ ]] && [ "$PEAK_MB" -ge 1 ] || die 9 "PEAK_MB must be an integer >= 1 (got '$PEAK_MB')"
  local capdir qprio; capdir="$(dirname "$LOCK")"
  QDIR="$capdir/queue"; BSTATE="$capdir/breaker.state"
  mkdir -p "$QDIR" || die 2 "cannot create $QDIR"
  mkdir -p "$ROOT" || die 2 "cannot create $ROOT"
  qprio="$PRIO"
  if [ -z "$qprio" ]; then case "$REPO" in j0yen/synthorg|j0yen/mcphost|j0yen/wm-build) qprio=0 ;; *) qprio=1 ;; esac; fi
  TICKET="$QDIR/$qprio-$(date +%s%N)-$$"
  : >"$TICKET" || die 2 "cannot create the ticket $TICKET"
  trap 'rm -f -- "${TICKET:?}"; exec 9>&-; gate_cleanup' EXIT   # the ticket + fd 9 (vcap) AND the gate-lint temp dir (AVL-TRAP) in one EXIT trap
  trap 'exit 143' TERM HUP; trap 'exit 130' INT
  exec 9>"$LOCK"
  local waited=0 maxw="${AIDE_VERIFIER_QUEUE_MAX_S:-3600}" act nact u sum need room rrc wrc wmsg seat probe_key
  while :; do
    flock -x -w "$LOCK_WAIT_S" 9 || die 6 "could not take $LOCK in ${LOCK_WAIT_S}s; held by:$(lock_holder)"
    wrc=""; wmsg=""; probe_key=""
    raw="$(active_units)"
    act="$(printf '%s\n' "$raw" | grep -vxF -- "$own" | tr '\n' ' ')"   # AVL-DROPOWN
    if [ -n "$own" ] && [ "$own_noted" != 1 ] && printf '%s\n' "$raw" | grep -qxF -- "$own"; then
      own_noted=1; echo "aide-verifier: own unit $own excluded from the fleet cap count (cgroup ${AIDE_VERIFIER_CGROUP_FILE:-/proc/self/cgroup})" >&2
    fi
    nact="$(printf '%s' "$act" | wc -w)"
    # 1 priority: only the head of the live ticket line may go
    if ! head_of_line; then wrc=11; wmsg="not head-of-line: a higher-priority or earlier verifier launch is waiting ($QDIR)"; fi
    # 2 the 429 breaker
    if [ -z "$wrc" ]; then
      breaker_scan
      if [ "$B_TRIP" = 1 ]; then
        seat="${WM_SEAT:-rb}"
        [ "$seat" = aide ] && [ -n "${WM_AIDE_LANE:-}" ] && [ "$WM_AIDE_LANE" != main ] && seat="aide:$WM_AIDE_LANE"   # a lane-launched verifier bells its lane (aide-lanes 10-27)
        local btxt="aide-verifier: 429 breaker TRIPPED (trip id $B_KEY = mtime of the newest result.json under $ROOT with api_error_status 429, newer than $TOKEN_FILE, no later non-429 result): verifier launches refuse (exit 10) until the token file is re-touched, a non-429 result lands, or the half-open probe (429 older than 30 min, 0 active) passes"
        bell_once r7 "$B_KEY" "$btxt"
        [ "$seat" = r7 ] || bell_once "$seat" "$B_KEY" "$btxt"
        if [ "$B_AGE" -gt 1800 ] && [ "$nact" -eq 0 ] && ! grep -qxF "probe $B_KEY" "$BSTATE" 2>/dev/null; then
          probe_key="$B_KEY"   # half-open: exactly one probe per trip id, recorded just before systemd-run
        else
          wrc=10; wmsg="429 breaker tripped (trip id $B_KEY, age ${B_AGE}s, $nact active)"
        fi
      fi
    fi
    # 3 the hard ceiling
    if [ -z "$wrc" ] && [ "$nact" -ge "$SLOT_CEIL" ]; then wrc=2; wmsg="verifier cap reached: $nact of $SLOT_CEIL active (${act% })"; fi
    # 4 room: running units' remaining ramp to PEAK_MB is priced, their current RSS is already out of MemAvailable
    if [ -z "$wrc" ]; then
      # shellcheck disable=SC2086
      sum="$(sum_current_mb $act)"
      need=$((PEAK_MB * (nact + 1) - sum)); [ "$need" -ge "$PEAK_MB" ] || need="$PEAK_MB"
      # shellcheck disable=SC2086
      room="$(timeout "$CMD_TIMEOUT_S" $ROOM_CMD "$need" --json 2>/dev/null)"; rrc=$?
      if [ "$rrc" != 0 ] || [ "$(printf '%s' "$room" | jq -r '.ok' 2>/dev/null)" = false ]; then
        wrc=3; wmsg="no room for ${need} MB ($nact active, Σ MemoryCurrent ${sum} MB, PEAK_MB $PEAK_MB): $(printf '%s' "$room" | tr -d '\n' | cut -c1-200)"
      fi
    fi
    [ -n "$wrc" ] || break
    if [ "$QUEUE" != 1 ]; then die "$wrc" "$wmsg; use --queue to wait"; fi
    flock -u 9
    [ "$waited" -lt "$maxw" ] || die 6 "queue wait exceeded ${maxw}s ($wmsg)"
    sleep "$POLL"; waited=$((waited + POLL))
  done
  [ -z "$probe_key" ] || echo "probe $probe_key" >>"$BSTATE"
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
    printf 'exec timeout "${AIDE_VERIFIER_TIMEOUT_S:-%s}" %q -p --dangerously-skip-permissions --disallowedTools %q --settings "$D/settings.json" --model claude-sonnet-5-5 --output-format json "$(cat "$D/prompt.md")" > "$D/result.json" 2> "$D/stderr.log"\n' "$VTIMEOUT" "$claude" 'Bash(pkill:*) Bash(killall:*)'
  } >"$DIR/launch.sh"
  chmod 755 "$DIR/launch.sh"
  # mechanical guard: a PreToolUse Bash hook scoped to this unit only (settings file passed by launch.sh), plus the deny rules above
  jq -n --arg h "$(dirname "$SELF")/verifier-kill-guard.sh" '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:$h}]}]}}' >"$DIR/settings.json" || die 2 "cannot write $DIR/settings.json"
  printf 'repo=%s\npr=%s\nhead=%s\ngated=%s\ntoken=%s\nagent=%s\ntimeout_s=%s\n' "$REPO" "$PR" "$HEAD" "$GATED" "$TOKEN" "$AGENT" "$VTIMEOUT" >"$DIR/meta"
  # ---- start ----
  if ! timeout "$CMD_TIMEOUT_S" "$SD_RUN" --user --unit "$unit" -p MemoryMax=2G -p CPUWeight=20 -p Nice=10 -p IOWeight=20 --setenv=HOME="$HOME" --setenv=PATH="$UNIT_PATH" "$DIR/launch.sh" >"$DIR/run.out" 2>&1 9>&-; then
    echo "$(iso) launch-failed unit=$unit: $(head -c 300 "$DIR/run.out" | tr '\n' ' ')" >>"$DIR/state"
    die 1 "systemd-run failed: $(head -c 300 "$DIR/run.out" | tr '\n' ' ' | redact)"
  fi
  exec 9>&-   # the lock covers count + room + systemd-run only; the 9>&- above already kept it out of the unit
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
  local head gated tmo; head="$(meta_get "$d" head)"; gated="$(meta_get "$d" gated)"
  tmo="timeout_s=$(meta_get "$d" timeout_s)"; [ "$tmo" != "timeout_s=" ] || tmo="timeout_s=2400(default,unrecorded)"   # reported on every finish path
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
    echo "aide-verifier: NO verdict row id in the verifier's result (is_error=$iserr, $tmo); NOT belling. Final text:" >&2
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
    "$BELL" ctl "$agent EVENT MERGE-OK $repo#$pr head $head row $verdict gates $gated (own-session unit $unit): $pass; log $log; $tmo" >/dev/null 2>&1
    if [ "$recrc" != 0 ]; then
      echo "$(iso) PASS rc=7 $verdict $tmo" >"$d/finished"
      echo "aide-verifier: gate PASSED and ctl belled, but the GATE-PASS row failed to record (rc=$recrc): $(head -c 200 "$d/record.err" | redact)" >&2
      echo "$pass"; exit 7
    fi
    echo "$(iso) PASS rc=0 $verdict $tmo" >"$d/finished"
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
  "$BELL" ctl "$agent EVENT MERGE-GATE FAIL $repo#$pr head $head row $verdict gates $gated (unit $unit): $reason; MERGE-OK RETRACTED; log $log; $tmo" >/dev/null 2>&1
  echo "$(iso) FAIL rc=5 $verdict $tmo" >"$d/finished"
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
[ -z "${FAKE_SDRUN_HANG:-}" ] || exec sleep 30
[ -z "${FAKE_SDRUN_DELAY:-}" ] || sleep "$FAKE_SDRUN_DELAY"
[ -z "${FAKE_SDRUN_BG:-}" ] || { sleep 20 >/dev/null 2>&1 </dev/null & echo $! >>"$FAKE_DIR/bgpids"; }
if [ -n "${FAKE_SDRUN_APPEND:-}" ]; then
  args=("$@"); for i in "${!args[@]}"; do [ "${args[$i]}" = --unit ] && { echo "${args[$((i + 1))]}.service" >>"$FAKE_DIR/active"; break; }; done
fi
d="$(dirname "${@: -1}")"
printf '%s' "${FAKE_RESULT_JSON:-{\"is_error\":false,\"result\":\"ok\"\}}" >"$d/result.json"
F
  cat >"$T/bin/fake-systemctl" <<'F'
#!/bin/bash
case "$2" in
  list-units) cat "$FAKE_DIR/active" 2>/dev/null ;;
  is-active) if grep -qx "$3.service" "$FAKE_DIR/active" 2>/dev/null; then echo active; else echo inactive; exit 3; fi ;;
  show) f="$FAKE_DIR/mem/$6"; if [ -r "$f" ]; then cat "$f"; else echo "[not set]"; fi ;;   # --user show -p MemoryCurrent --value <unit>
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
  printf '#!/bin/bash\necho "$1" >>"$FAKE_DIR/room.log"\n[ -z "${FAKE_ROOM_HANG:-}" ] || exec sleep 30\nif [ "${FAKE_ROOM:-ok}" = ok ]; then echo "{\\"ok\\":true,\\"room_mb\\":9000}"; else echo "{\\"ok\\":false,\\"room_mb\\":-5}"; exit 1; fi\n' >"$T/bin/fake-room"
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
  unset AIDE_VERIFIER_TEMPLATE AIDE_VERIFIER_AGENT AIDE_VERIFIER_SLOT_CEIL AIDE_VERIFIER_PEAK_MB AIDE_VERIFIER_TOKEN_FILE AIDE_VERIFIER_LOCK WM_SEAT
  export AIDE_VERIFIER_SELFTEST=1 AIDE_VERIFIER_SLOT_CEIL=2 AIDE_VERIFIER_QUEUE_MAX_S=30 AIDE_VERIFIER_LOCK_WAIT_S=20   # the selftest bounds every --queue / flock wait (a mutation that lets a case through must FAIL it, never hang); cases that need a different bound set their own; the v0.2 cases below assume a 2-slot ceiling; the v0.3 cases override it per call
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

  printf 'aide-verifier-other.service\nrb-verifier-other.service\n' >"$T/active"
  out="$(L act1 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"verifier cap reached: 2 of 2"* ]] && [ ! -e "$T/sdrun.log" ]; chk "(b) 2 active, no --queue -> exit 2, nothing started" $?
  ( sleep 2; echo "aide-verifier-other.service" >"$T/active" ) & local t0=$SECONDS
  out="$(L act2 "${A[@]}" --head "$H" --queue)"; rc=$?; wait
  [ "$rc" = 0 ] && [ $((SECONDS - t0)) -ge 1 ] && [ "$out" = aide-verifier-act2 ]; chk "(b) 2 active, --queue waits until one is gone, then launches ($out, $((SECONDS - t0)) s)" $?
  printf 'aide-verifier-other.service\nrb-verifier-other.service\n' >"$T/active"
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
  out="$(AIDE_VERIFIER_SLOT_CEIL=1 AIDE_VERIFIER_CGROUP_FILE="$T/cg-own" AIDE_VERIFIER_QUEUE_MAX_S=2 L s1 "${A[@]}" --head "$H" --queue)"; rc=$?
  [ "$rc" = 0 ] && [[ "$out" == *"own unit aide-verifier-s1own.service excluded"* ]] && grep -q 'own-unit-excluded unit=aide-verifier-s1own.service' "$T/av/s1/state"; chk "gate lint (s1): the own unit is the only active unit (ceiling 1), --queue -> launches (rc 0, not 6), the exclusion names the unit on stderr and in the launch state" $?
  printf 'aide-verifier-s1own.service\naide-verifier-other.service\nrb-verifier-other.service\n' >"$T/active"; rm -f "$T/sdrun.log"   # the ceiling is 2 here: own + 2 foreign units = 2 counted
  out="$(AIDE_VERIFIER_CGROUP_FILE="$T/cg-own" L s2 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"verifier cap reached: 2 of 2"* ]] && [[ "$out" == *"aide-verifier-other.service"* ]] && [ ! -e "$T/sdrun.log" ]; chk "gate lint (s2): own unit + two foreign verifier units active, no --queue -> exit 2, the cap counts only the 2 foreign units (own excluded)" $?
  printf 'aide-verifier-other.service\nrb-verifier-other.service\n' >"$T/active"
  out="$(L s3 "${A[@]}" --head "$H")"; rc=$?   # AIDE_VERIFIER_CGROUP_FILE points at an absent file here
  [ "$rc" = 2 ] && [[ "$out" == *"verifier cap reached: 2 of 2"* ]] && [ ! -e "$T/sdrun.log" ]; chk "gate lint (s3): cgroup file absent + only foreign units active (2 of the ceiling 2) -> exit 2 as before" $?
  printf '0::/user.slice/user-1000.slice/user@1000.service/app.slice/aide-verifier-s5own.service/sub\n' >"$T/cg-sub"
  printf 'aide-verifier-s5own.service\nrb-verifier-other.service\n' >"$T/active"
  out="$(AIDE_VERIFIER_CGROUP_FILE="$T/cg-sub" L s5 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"verifier cap reached: 2 of 2"* ]] && [[ "$out" != *"excluded"* ]]; chk "gate lint (s5/X2): a cgroup line whose final component is a sub-cgroup dir (not .service) excludes nothing (no backward scan)" $?
  printf '0::/user.slice/user-1000.slice/user@1000.service/app.slice/aide-verifier-s4.service\n' >"$T/cg-tgt"
  : >"$T/active"; t0=$SECONDS; rm -f "$T/sdrun.log"
  out="$(AIDE_VERIFIER_CGROUP_FILE="$T/cg-tgt" L s4 "${A[@]}" --head "$H" --queue)"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"lint: launch-inside-target-unit aide-verifier-s4.service"* ]] && [ $((SECONDS - t0)) -lt 2 ] && [ ! -e "$T/sdrun.log" ] && none s4; chk "gate lint (s4/X1): own unit == the unit this launch would start, --queue -> exit 2 launch-inside-target-unit, no wait, names the unit" $?
  : >"$T/active"

  # ---- vcap: the fleet-wide cap at ONE fixed lock (SLOT_CEIL overridden to 2 for the v0.2 cases) ----
  rm -f "$T/sdrun.log" "$T/room.log"
  echo "rb-verifier-other.service" >"$T/active"
  out="$(L cap1 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 0 ] && [ "$out" = aide-verifier-cap1 ] && [ "$(wc -l <"$T/sdrun.log")" = 1 ]; chk "(a) 1 active of 2 -> launches ($out)" $?
  grep -q -- "-p CPUWeight=20 -p Nice=10 -p IOWeight=20" "$T/sdrun.log"; chk "(a) the unit launch carries CPUWeight=20 Nice=10 IOWeight=20" $?
  ask="$(cat "$T/room.log")"; [ "$ask" = 2048 ]; chk "(a) room asked for PEAK_MB 1024 x (1 active + 1) - Σ MemoryCurrent 0 ([not set]) = $ask MB" $?
  : >"$T/active"; rm -f "$T/room.log"; L cap0 "${A[@]}" --head "$H" >/dev/null
  ask="$(cat "$T/room.log")"; [ "$ask" = 1024 ]; chk "(a) 0 active -> room asked for PEAK_MB 1024 ($ask)" $?
  # (c) RACE: 1 active, two --queue launches started together -> exactly one systemd-run until a unit is removed, then the second
  rm -f "$T/sdrun.log"; echo "aide-verifier-pre1.service" >"$T/active"
  FAKE_SDRUN_APPEND=1 FAKE_SDRUN_DELAY=1 L race1 "${A[@]}" --head "$H" --queue >"$T/race1.out" 2>&1 & local p1=$!
  FAKE_SDRUN_APPEND=1 FAKE_SDRUN_DELAY=1 L race2 "${A[@]}" --head "$H" --queue >"$T/race2.out" 2>&1 & local p2=$!
  sleep 4
  calls="$(wc -l <"$T/sdrun.log")"; [ "$calls" = 1 ] && [ "$(grep -c . "$T/active")" = 2 ]; chk "(c) RACE: two --queue launches with 1 active -> exactly one systemd-run call while 2 are active ($calls call)" $?
  grep -v 'pre1' "$T/active" >"$T/active.tmp"; mv "$T/active.tmp" "$T/active"   # the pre-existing unit leaves; the first launcher's own unit stays
  wait "$p1" "$p2"
  calls="$(wc -l <"$T/sdrun.log")"; [ "$calls" = 2 ]; chk "(c) RACE: once a unit is gone the second launcher goes ($calls calls)" $?
  : >"$T/active"
  # (d) SLOT_CEIL / PEAK_MB 0 or "x" under the selftest -> exit 9 (distinct from busy = 2), nothing started
  rm -f "$T/sdrun.log"
  out="$(AIDE_VERIFIER_SLOT_CEIL=0 L capd0 "${A[@]}" --head "$H")"; rc=$?; [ "$rc" = 9 ] && [ ! -e "$T/sdrun.log" ]; chk "(d) AIDE_VERIFIER_SLOT_CEIL=0 under the selftest -> exit 9" $?
  out="$(AIDE_VERIFIER_SLOT_CEIL=x L capdx "${A[@]}" --head "$H")"; rc=$?; [ "$rc" = 9 ] && [ ! -e "$T/sdrun.log" ]; chk "(d) AIDE_VERIFIER_SLOT_CEIL=x under the selftest -> exit 9" $?
  out="$(AIDE_VERIFIER_PEAK_MB=0 L capp0 "${A[@]}" --head "$H")"; rc=$?; [ "$rc" = 9 ] && [ ! -e "$T/sdrun.log" ]; chk "(1) AIDE_VERIFIER_PEAK_MB=0 under the selftest -> exit 9" $?
  out="$(AIDE_VERIFIER_PEAK_MB=x L cappx "${A[@]}" --head "$H")"; rc=$?; [ "$rc" = 9 ] && [ ! -e "$T/sdrun.log" ]; chk "(1) AIDE_VERIFIER_PEAK_MB=x under the selftest -> exit 9" $?
  printf 'rb-verifier-a.service\nrb-verifier-b.service\n' >"$T/active"
  out="$(AIDE_VERIFIER_SLOT_CEIL=3 L capd3 "${A[@]}" --head "$H")"; rc=$?; [ "$rc" = 0 ]; chk "(d) selftest override SLOT_CEIL=3 with 2 active -> launches" $?
  printf 'rb-verifier-a.service\nrb-verifier-b.service\nr7-verifier-c.service\naide-verifier-d.service\n' >"$T/active"
  out="$(AIDE_VERIFIER_SELFTEST=0 AIDE_VERIFIER_SLOT_CEIL=9 AIDE_VERIFIER_PEAK_MB=1 L capd9 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"4 of 4"* ]]; chk "(d) without AIDE_VERIFIER_SELFTEST=1 a seat env AIDE_VERIFIER_SLOT_CEIL=9 is ignored: ceiling stays 4 -> exit 2 ($out)" $?
  : >"$T/active"
  # (e) the lock is closed right after the launch: a unit-lingering child of systemd-run must not hold it
  LK="$HOME/.local/state/verifier-cap/launch.lock"
  FAKE_SDRUN_BG=1 L cape "${A[@]}" --head "$H" >/dev/null
  [ -s "$T/bgpids" ] && kill -0 "$(head -n1 "$T/bgpids")" 2>/dev/null && timeout 2 flock -n "$LK" true; chk "(e) after a launch whose systemd-run left a child running, flock -n on the lock path succeeds within 2 s" $?
  while read -r bp; do kill "$bp" 2>/dev/null; done <"$T/bgpids"
  # (f)+(h) different AIDE_VERIFIER_DIR values contend on ONE fixed lock; a held lock -> exit 6 naming the holder
  [ -e "$LK" ] && [ ! -e "$T/av/.launch.lock" ]; chk "(f) the lock lives at \$HOME/.local/state/verifier-cap/launch.lock, not under AIDE_VERIFIER_DIR" $?
  flock -x "$LK" sleep 8 & local hp=$!
  sleep 0.5
  rm -f "$T/sdrun.log"
  out="$(AIDE_VERIFIER_DIR="$T/avA" AIDE_VERIFIER_LOCK_WAIT_S=1 L lka "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 6 ] && [ ! -e "$T/sdrun.log" ]; chk "(f) AIDE_VERIFIER_DIR=avA blocked by the held lock -> exit 6" $?
  out2="$(AIDE_VERIFIER_DIR="$T/avB" AIDE_VERIFIER_LOCK_WAIT_S=1 L lkb "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 6 ] && [ ! -e "$T/sdrun.log" ] && [ ! -e "$T/avA/.launch.lock" ] && [ ! -e "$T/avB/.launch.lock" ]; chk "(f) AIDE_VERIFIER_DIR=avB blocked by the SAME lock -> exit 6" $?
  [[ "$out" == *"could not take $LK"* ]] && [[ "$out" == *"pid="* ]]; chk "(h) lock timeout names the lock path and a holder pid (best effort): ${out:0:150}" $?
  kill "$hp" 2>/dev/null; wait "$hp" 2>/dev/null
  # (i) timeouts: a hung room command -> exit 3, a hung systemd-run -> exit 1 (both under AIDE_VERIFIER_TIMEOUT_S, default 120)
  out="$(FAKE_ROOM_HANG=1 AIDE_VERIFIER_TIMEOUT_S=1 L tmo1 "${A[@]}" --head "$H")"; rc=$?; [ "$rc" = 3 ]; chk "(i) a hung carbon-room.sh is cut by timeout -> exit 3" $?
  rm -f "$T/sdrun.log"
  out="$(FAKE_SDRUN_HANG=1 AIDE_VERIFIER_TIMEOUT_S=1 L tmo2 "${A[@]}" --head "$H")"; rc=$?; [ "$rc" = 1 ] && grep -q launch-failed "$T/av/tmo2/state"; chk "(i) a hung systemd-run is cut by timeout -> exit 1, state records it" $?
  grep -qE 'timeout "\$CMD_TIMEOUT_S" "\$SD_RUN"' "$SELF" && grep -q 'timeout "\$CMD_TIMEOUT_S" \$ROOM_CMD' "$SELF" && grep -q '^SLOT_CEIL=4$' "$SELF" && grep -q '^PEAK_MB=1024$' "$SELF"; chk "the script hard-codes SLOT_CEIL=4 and PEAK_MB=1024 and wraps room + systemd-run in timeout" $?

  # ---- vcap v0.3: room-sized admission (2), 429 breaker (3), priority (4), ceiling 4 ----
  local RR="$(dirname "$SELF")/carbon-room.sh" TK="$HOME/.config/environment.d/90-claude-oauth.conf" QD="$HOME/.local/state/verifier-cap/queue" BS="$HOME/.local/state/verifier-cap/breaker.state"
  printf '#!/bin/bash\necho "$1" >>"$FAKE_DIR/room.log"\nexec %q "$@"\n' "$RR" >"$T/bin/fake-room-real"; chmod +x "$T/bin/fake-room-real"
  mi() { printf 'MemTotal:       15467572 kB\nMemFree:         1000000 kB\nMemAvailable:   %d kB\nSwapFree:       2097152 kB\n' $(($1 * 1024)) >"$T/meminfo"; }
  # R3 <ceiling> cmd...: run cmd with the REAL carbon-room.sh (fake meminfo, via a wrapper that logs the asked need) and SLOT_CEIL=<ceiling>
  R3() { local ce="$1"; shift; ( export AIDE_VERIFIER_SLOT_CEIL="$ce" AIDE_VERIFIER_ROOM_CMD="$T/bin/fake-room-real" CARBON_ROOM_HOST=carbon CARBON_ROOM_MEMINFO="$T/meminfo" CARBON_ROOM_STATE="$T/rs.json" CARBON_ROOM_LEDGER="$T/rl.jsonl"; "$@" ); }
  mem3() { mkdir -p "$T/mem"; local u; for u in a b c; do echo $(($1 * 1048576)) >"$T/mem/$2-verifier-$u.service"; done; }
  r429() { mkdir -p "$1/$2"; printf '{"is_error":true,"api_error_status":429,"result":"rate limited"}' >"$1/$2/result.json"; touch -d "$3" "$1/$2/result.json"; }
  rok() { mkdir -p "$1/$2"; printf '{"is_error":false,"api_error_status":null,"result":"ok"}' >"$1/$2/result.json"; touch -d "$3" "$1/$2/result.json"; }
  # (a) MemAvailable 7540, 0 active -> launch, need 1024
  : >"$T/active"; rm -f "$T/sdrun.log" "$T/room.log"; mi 7540
  out="$(R3 2 L v3a "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 0 ] && [ "$out" = aide-verifier-v3a ] && [ "$(cat "$T/room.log")" = 1024 ]; chk "(7a) MemAvailable 7540, 0 active -> launches, carbon-room asked for need 1024 ($(cat "$T/room.log" 2>/dev/null))" $?
  # (b) 3 active at 200 MB each, MemAvailable 7540 -> need 3496, 7540-3496-3072 >= 0 -> launch
  printf 'rb-verifier-a.service\nr7-verifier-b.service\naide-verifier-c.service\n' >"$T/active"; mem3 200 rb; echo $((200 * 1048576)) >"$T/mem/r7-verifier-b.service"; echo $((200 * 1048576)) >"$T/mem/aide-verifier-c.service"
  : >"$T/room.log"; rm -f "$T/sdrun.log"; mi 7540
  out="$(R3 4 L v3b "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 0 ] && [ "$out" = aide-verifier-v3b ] && [ "$(cat "$T/room.log")" = 3496 ] && [ "$(wc -l <"$T/sdrun.log")" = 1 ]; chk "(7b) 3 active at 200 MB, MemAvailable 7540 -> need 1024 x 4 - 600 = $(cat "$T/room.log"), room 7540-3496-3072 >= 0 -> launches" $?
  # (c) same units, MemAvailable 6500 -> exit 3 without --queue, systemd-run untouched; with --queue it waits until memory returns
  : >"$T/room.log"; rm -f "$T/sdrun.log"; mi 6500
  out="$(R3 4 L v3c "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 3 ] && [ ! -e "$T/sdrun.log" ] && [ "$(cat "$T/room.log")" = 3496 ] && [[ "$out" == *"Σ MemoryCurrent 600 MB"* ]]; chk "(7c) same units, MemAvailable 6500 -> exit 3, nothing started ($out)" $?
  ( sleep 2; mi 7540 ) & local t1=$SECONDS
  out="$(R3 4 L v3c2 "${A[@]}" --head "$H" --queue)"; rc=$?; wait
  [ "$rc" = 0 ] && [ $((SECONDS - t1)) -ge 1 ] && [ "$(wc -l <"$T/sdrun.log")" = 1 ]; chk "(7c) --queue waits for room (lock released), launches once MemAvailable is back ($((SECONDS - t1)) s)" $?
  # the units' MemoryCurrent "[not set]" counts 0: 2 active, no mem files -> need 1024 x 3
  printf 'rb-verifier-x.service\nrb-verifier-y.service\n' >"$T/active"; rm -rf "$T/mem"; : >"$T/room.log"; mi 7540
  R3 4 L v3n "${A[@]}" --head "$H" >/dev/null; [ "$(cat "$T/room.log")" = 3072 ]; chk "(2) MemoryCurrent '[not set]' = 0: 2 active -> need 3072 ($(cat "$T/room.log"))" $?
  # a unit above PEAK_MB: Σ larger than the running ramp -> need floors at PEAK_MB
  mkdir -p "$T/mem"; echo $((5000 * 1048576)) >"$T/mem/rb-verifier-x.service"; : >"$T/room.log"
  R3 4 L v3f "${A[@]}" --head "$H" >/dev/null; [ "$(cat "$T/room.log")" = 1024 ]; chk "(2) need = max(PEAK_MB, ...): one unit at 5000 MB -> floor 1024 ($(cat "$T/room.log"))" $?
  rm -rf "$T/mem"
  # (d) 4 active -> wait regardless of memory (ceiling)
  printf 'rb-verifier-a.service\nrb-verifier-b.service\nr7-verifier-c.service\naide-verifier-d.service\n' >"$T/active"; rm -f "$T/room.log" "$T/sdrun.log"; mi 64000
  out="$(R3 4 L v3d "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"verifier cap reached: 4 of 4"* ]] && [ ! -e "$T/sdrun.log" ] && [ ! -e "$T/room.log" ]; chk "(7d) 4 active, MemAvailable 64000 -> exit 2, ceiling reached, room never asked ($out)" $?
  out="$(R3 4 env AIDE_VERIFIER_QUEUE_MAX_S=2 "$SELF" launch v3d2 "${A[@]}" --head "$H" --queue)"; rc=$?; [ "$rc" = 6 ] && [ ! -e "$T/sdrun.log" ]; chk "(7d) 4 active + --queue waits, gives up after QUEUE_MAX_S -> exit 6" $?
  : >"$T/active"
  [ "$(ls -A "$QD" 2>/dev/null | wc -l)" = 0 ]; chk "(4) every exit path removed its ticket: queue dir empty" $?

  # (e) breaker: ROOT is its own dir per case so the launches' own result.json never clear it
  touch -d '2 hours ago' "$TK"; rm -f "$BS" "$T/bell.log" "$T/sdrun.log"
  r429 "$T/avb1" old429 '2 minutes ago'
  out="$(AIDE_VERIFIER_DIR="$T/avb1" L v3e1 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 10 ] && [ ! -e "$T/sdrun.log" ] && [[ "$out" == *"429 breaker tripped"* ]]; chk "(7e) a 429 result newer than the token file -> exit 10, nothing started ($out)" $?
  [ "$(wc -l <"$T/bell.log")" = 2 ] && grep -q '^aide-verifier|r7 aide-verifier: 429 breaker TRIPPED' "$T/bell.log" && grep -q '^aide-verifier|rb aide-verifier: 429 breaker TRIPPED' "$T/bell.log"; chk "(3) bells: r7 (token owner) and the launching seat rb (WM_SEAT unset), one line each" $?
  out="$(AIDE_VERIFIER_DIR="$T/avb1" L v3e1b "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 10 ] && [ "$(wc -l <"$T/bell.log")" = 2 ]; chk "(3) the same trip id again: exit 10 and NO second bell" $?
  rm -f "$T/bell.log"; out="$(WM_SEAT=aide AIDE_VERIFIER_DIR="$T/avb1" L v3e1c "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 10 ] && [ "$(wc -l <"$T/bell.log")" = 1 ] && grep -q '^aide-verifier|aide aide-verifier: 429 breaker TRIPPED' "$T/bell.log"; chk "(3) a different launching seat (WM_SEAT=aide) is belled once for the same trip id (r7 already was)" $?
  rm -f "$T/bell.log"; out="$(WM_SEAT=aide WM_AIDE_LANE=build AIDE_VERIFIER_DIR="$T/avb1" L v3e1d "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 10 ] && [ "$(wc -l <"$T/bell.log")" = 1 ] && grep -q '^aide-verifier|aide:build aide-verifier: 429 breaker TRIPPED' "$T/bell.log"; chk "(3) lane launch (WM_SEAT=aide WM_AIDE_LANE=build) bells aide:build once, never main aide" $?
  rm -f "$T/bell.log" "$BS"; out="$(WM_SEAT=aide WM_AIDE_LANE=main AIDE_VERIFIER_DIR="$T/avb1" L v3e1e "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 10 ] && [ "$(wc -l <"$T/bell.log")" = 2 ] && ! grep -q 'aide:main' "$T/bell.log" && grep -q '^aide-verifier|aide aide-verifier: 429 breaker TRIPPED' "$T/bell.log"; chk "(3) WM_AIDE_LANE=main bells aide exactly as before" $?
  touch "$TK"   # the token is re-minted AFTER the 429
  out="$(AIDE_VERIFIER_DIR="$T/avb1" L v3e2 "${A[@]}" --head "$H")"; rc=$?; [ "$rc" = 0 ]; chk "(7e) token file re-touched after the 429 -> launches" $?
  touch -d '2 hours ago' "$TK"; r429 "$T/avb2" old429 '3 minutes ago'; rok "$T/avb2" newer-ok '1 minute ago'
  out="$(AIDE_VERIFIER_DIR="$T/avb2" L v3e3 "${A[@]}" --head "$H")"; rc=$?; [ "$rc" = 0 ]; chk "(7e) a non-429 result newer than the 429 -> launches" $?
  r429 "$T/avb3" a429 '5 minutes ago'; rok "$T/avb3" older-ok '10 minutes ago'; r429 "$T/avb3" b429 '2 minutes ago'
  out="$(AIDE_VERIFIER_DIR="$T/avb3" L v3e4 "${A[@]}" --head "$H")"; rc=$?; [ "$rc" = 10 ]; chk "(3) ANY 429 counts (scans every result.json): a non-429 older than the newest 429 does not clear it -> exit 10" $?
  rm -f "$T/bell.log" "$T/sdrun.log"; r429 "$T/avb4" old429 '2 minutes ago'
  ( sleep 2; touch "$TK" ) & t1=$SECONDS
  out="$(AIDE_VERIFIER_DIR="$T/avb4" L v3e5 "${A[@]}" --head "$H" --queue)"; rc=$?; wait
  [ "$rc" = 0 ] && [ $((SECONDS - t1)) -ge 1 ]; chk "(3) tripped + --queue waits with the lock released, launches once the token is re-touched ($((SECONDS - t1)) s)" $?
  # (f) half-open: 429 31 min old, 0 active -> exactly one probe, the second attempt for the same key stays tripped
  touch -d '3 hours ago' "$TK"; rm -f "$BS" "$T/bell.log" "$T/sdrun.log"; : >"$T/active"; r429 "$T/avb5" old429 '31 minutes ago'
  out="$(AIDE_VERIFIER_DIR="$T/avb5" L v3f1 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 0 ] && [ "$(wc -l <"$T/sdrun.log")" = 1 ] && grep -qE '^probe [0-9]+$' "$BS"; chk "(7f) 429 31 min old, 0 active -> ONE probe launches and breaker.state records 'probe <429 mtime>' ($(grep '^probe' "$BS" | head -n1))" $?
  rm -f "$T/avb5/v3f1/result.json"   # the probe died without an answer: the 429 is still the newest word
  out="$(AIDE_VERIFIER_DIR="$T/avb5" L v3f2 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 10 ] && [ "$(wc -l <"$T/sdrun.log")" = 1 ]; chk "(7f) a second probe for the same 429 key -> exit 10, no second systemd-run" $?
  rm -f "$BS" "$T/sdrun.log"; echo "rb-verifier-x.service" >"$T/active"; r429 "$T/avb6" old429 '31 minutes ago'
  out="$(AIDE_VERIFIER_DIR="$T/avb6" L v3f3 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 10 ] && [ ! -e "$T/sdrun.log" ] && ! grep -q '^probe' "$BS"; chk "(7f) 429 31 min old but 1 active -> no probe, exit 10" $?
  rm -f "$BS" "$T/sdrun.log"; : >"$T/active"; r429 "$T/avb7" old429 '10 minutes ago'
  out="$(AIDE_VERIFIER_DIR="$T/avb7" L v3f4 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 10 ] && [ ! -e "$T/sdrun.log" ]; chk "(7f) 429 only 10 min old, 0 active -> not half-open yet, exit 10" $?
  touch "$TK"; rm -f "$BS"

  # (g) priority: SLOT_CEIL 1 with 1 active; a prio-1 waiter starts first, a prio-0 (j0yen/synthorg) waiter second -> prio-0 launches first
  rm -f "$T/sdrun.log"; echo "rb-verifier-busy.service" >"$T/active"; mi 64000
  FAKE_SDRUN_APPEND=1 AIDE_VERIFIER_SLOT_CEIL=1 L v3g1 "${A[@]}" --head "$H" --queue >"$T/g1.out" 2>&1 & local g1=$!
  sleep 0.4
  FAKE_SDRUN_APPEND=1 AIDE_VERIFIER_SLOT_CEIL=1 L v3g0 --repo j0yen/synthorg --pr 7 --gated "$GS" --token 'pytest EXIT=0' --suite 'uv run pytest' --head "$H" --queue >"$T/g0.out" 2>&1 & local g0=$!
  sleep 2; ls "$QD" | cut -d- -f1 | sort | tr '\n' ' ' >"$T/g.prios"
  [ "$(cat "$T/g.prios")" = "0 1 " ]; chk "(4) two live tickets queued: prio 0 and prio 1 ($(cat "$T/g.prios"))" $?
  # free the slot while I hold the fleet lock: both waiters then block on flock in start order and wake together when I release it (the prio-1 one first)
  flock -x "$LK" sleep 3 & local hl=$!; sleep 0.3; : >"$T/active"; wait "$hl"; sleep 3
  [ "$(wc -l <"$T/sdrun.log")" = 1 ] && grep -q -- '--unit aide-verifier-v3g0 ' "$T/sdrun.log"; chk "(7g) the slot frees: the prio-0 waiter (started second) launched, the prio-1 one did not ($(cut -c1-60 "$T/sdrun.log" | tr '\n' '|'))" $?
  : >"$T/active"; wait "$g0"; sleep 2; wait "$g1"; rc=$?
  [ "$(wc -l <"$T/sdrun.log")" = 2 ] && [ "$(sed -n 2p "$T/sdrun.log" | grep -c -- '--unit aide-verifier-v3g1 ')" = 1 ]; chk "(7g) then the prio-1 waiter launches second ($(cut -c1-60 "$T/sdrun.log" | tr '\n' '|'))" $?
  : >"$T/active"; rm -f "$T/sdrun.log"
  out="$(L v3p "${A[@]}" --head "$H" --prio 0)"; rc=$?; [ "$rc" = 0 ]; chk "(4) --prio 0 accepted" $?
  out="$(L v3px "${A[@]}" --head "$H" --prio 2)"; rc=$?; [ "$rc" = 2 ] && [[ "$out" == *"--prio must be 0 or 1"* ]]; chk "(4) --prio 2 -> exit 2" $?
  # (h) dead-pid ticket reaped; non-queue launch behind a live ticket -> exit 11
  mkdir -p "$QD"; : >"$QD/0-1-99999999"; rm -f "$T/sdrun.log"
  out="$(L v3h1 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 0 ] && [ ! -e "$QD/0-1-99999999" ]; chk "(7h) a dead-pid ticket ahead of mine is reaped, the launch goes" $?
  ( exec -a aide-verifier-fakeholder sleep 30 ) & local hp2=$!
  : >"$QD/0-1-$hp2"; rm -f "$T/sdrun.log"
  out="$(L v3h2 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 11 ] && [ ! -e "$T/sdrun.log" ] && [ -e "$QD/0-1-$hp2" ] && [[ "$out" == *"not head-of-line"* ]]; chk "(7h) non-queue launch behind a LIVE aide-verifier ticket -> exit 11, nothing started, the other ticket stays ($out)" $?
  kill "$hp2" 2>/dev/null; wait "$hp2" 2>/dev/null; rm -f "$QD/0-1-$hp2"
  ( exec -a some-other-proc sleep 30 ) & hp2=$!
  : >"$QD/0-1-$hp2"
  out="$(L v3h3 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 0 ] && [ ! -e "$QD/0-1-$hp2" ]; chk "(7h) a ticket whose pid is alive but not an aide-verifier process (recycled pid) is reaped" $?
  kill "$hp2" 2>/dev/null; wait "$hp2" 2>/dev/null
  [ "$(ls -A "$QD" 2>/dev/null | wc -l)" = 0 ]; chk "(4) queue dir empty after every launch (ticket removed in the EXIT trap)" $?
  : >"$T/active"

  rm -f "$T/sdrun.log"
  out="$(FAKE_ROOM=no L room1 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 3 ] && [ ! -e "$T/sdrun.log" ]; chk "room not ok -> exit 3, systemd-run not called" $?

  out="$(L ok1 "${A[@]}" --head "$H" --notes 'a "quoted" note; $(not run)' --expect '663 tests')"; rc=$?
  local D="$T/av/ok1"
  [ "$rc" = 0 ] && [ "$out" = aide-verifier-ok1 ]; chk "launch ok: exit 0, prints the unit name" $?
  grep -q -- "--user --unit aide-verifier-ok1 -p MemoryMax=2G -p CPUWeight=20 -p Nice=10 -p IOWeight=20 --setenv=HOME=$T/home --setenv=PATH=.*/.local/bin.*:/usr/bin:/bin $D/launch.sh\$" "$T/sdrun.log"; chk "systemd-run argv: unit, MemoryMax=2G, CPUWeight, Nice, IOWeight, HOME, PATH, launch.sh" $?
  grep -q "$H" "$D/prompt.md" && grep -q "$G" "$D/prompt.md" && grep -qF 'tests/*.test.sh EXIT=0' "$D/prompt.md" && grep -q 'HARD CONSTRAINTS' "$D/prompt.md" \
    && grep -qF '^[[:space:]]*(co-authored-by:|generated with)' "$D/prompt.md" && grep -q 'wm-verify-run' "$D/prompt.md" && grep -qF '$(not run)' "$D/prompt.md" \
    && grep -q -- "--what \"MERGE-OK j0yen/dotfiles#7 COMMIT=$H agent=verifier:aide-verifier-ok1 recorded_by=unit:aide-verifier-ok1 session=own-headless-claude-p" "$D/prompt.md" \
    && grep -qF "wm-verify-run 'bash tests/run.sh; echo \"tests/*.test.sh EXIT=\$?\"'" "$D/prompt.md"; chk "prompt.md: head, gated id, token line, HARD CONSTRAINTS, anchored attribution regex, one quoted suite, verdict --what" $?
  [ -x "$D/launch.sh" ] && grep -q 'aide-verifier-ok1' "$D/launch.sh" && bash -n "$D/launch.sh"; chk "launch.sh is executable, names the unit, parses" $?
  grep -q '"$(cat "$D/prompt.md")"' "$D/launch.sh" && ! grep -qE 'bash -c|sh -c' "$D/launch.sh" && ! grep -qE ' -c ' "$T/sdrun.log"; chk "the prompt is read from the file by launch.sh, never passed through bash -c" $?
  grep -q ' launched unit=aide-verifier-ok1 ' "$D/state"; chk "state has a launched line" $?
  # ---- unit timeout + kill guard (TKG) ----
  grep -q '^exec timeout "${AIDE_VERIFIER_TIMEOUT_S:-2400}" ' "$D/launch.sh" && grep -q '^timeout_s=2400$' "$D/meta"; chk "TKG timeout: default launch.sh runs timeout with AIDE_VERIFIER_TIMEOUT_S default 2400, meta timeout_s=2400" $?
  out="$(L tkg5 "${A[@]}" --head "$H" --timeout 5400)"; rc=$?
  grep -q '^exec timeout "${AIDE_VERIFIER_TIMEOUT_S:-5400}" ' "$T/av/tkg5/launch.sh" && grep -q '^timeout_s=5400$' "$T/av/tkg5/meta" && [ "$rc" = 0 ]; chk "TKG timeout: --timeout 5400 reaches the timeout command and meta" $?
  rm -f "$T/sdrun.log"; out="$(L tkg6 "${A[@]}" --head "$H" --timeout 99999)"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"60 to 7200"* ]] && [ ! -e "$T/sdrun.log" ] && [ ! -e "$T/av/tkg6" ]; chk "TKG timeout: --timeout 99999 -> exit 2, nothing started" $?
  out="$(L tkg7 "${A[@]}" --head "$H" --timeout 59)"; rc=$?; [ "$rc" = 2 ]; chk "TKG timeout: --timeout 59 -> exit 2" $?
  out="$(L tkg8 "${A[@]}" --head "$H" --timeout abc)"; rc=$?; [ "$rc" = 2 ]; chk "TKG timeout: --timeout abc -> exit 2" $?
  printf '{"is_error":false,"result":"no id"}' >"$T/av/tkg5/result.json"; out="$("$SELF" finish tkg5 2>&1)"
  [[ "$out" == *"timeout_s=5400"* ]]; chk "TKG timeout: finish reports the recorded timeout_s (exit-4 message)" $?
  grep -qF -- '--disallowedTools Bash\(pkill:\*\)\ Bash\(killall:\*\) --settings "$D/settings.json"' "$D/launch.sh" && grep -q 'verifier-kill-guard.sh' "$D/settings.json" && jq -e '.hooks.PreToolUse[0].matcher == "Bash"' "$D/settings.json" >/dev/null; chk "TKG guard: launch.sh denies Bash(pkill:*) and Bash(killall:*) and loads the unit-scoped settings.json hook" $?
  grep -q 'never kill by pattern' "$D/prompt.md" && grep -q 'systemctl --user stop aide-verifier-ok1' "$D/prompt.md"; chk "TKG guard: prompt forbids pkill/killall/kill by pattern, allows own PIDs and own unit stop" $?
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
  grep -q "PASS rc=0 $V timeout_s=2400\$" "$D/finished" && grep -q "; timeout_s=2400\$" "$T/bell.log"; chk "TKG timeout: a PASS finish records timeout_s in the finished file and the bell" $?

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
  printf 'aide-verifier-other.service\nr7-verifier-other.service\n' >"$T/active"
  out="$(AIDE_VERIFIER_AGENT=r7 L ag1 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"verifier cap reached"* ]]; chk "the cap spans agents: an aide- and an r7-verifier-* unit block an r7 launch" $?
  printf 'rb-verifier-other.service\naide-verifier-other.service\n' >"$T/active"
  out="$(L ag1 "${A[@]}" --head "$H")"; rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"verifier cap reached"* ]]; chk "the cap spans agents: an rb- and an aide-verifier-* unit block an aide launch" $?
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
  *) sed -n '2,51p' "$SELF" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
