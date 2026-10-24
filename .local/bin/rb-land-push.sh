#!/usr/bin/env bash
# rb-land-push.sh --confirm <d-id> --repo <git dir> --branch <branch> [--host <h>] [--check] | --selftest
#   the ONLY way an rb-marked process pushes a wm-build land/run branch (.claude/hooks/land-push-gate.sh blocks a bare `git push` to wm-build/*).
#   Pushes the HEAD sha of <git dir> to origin/<branch> only if a LIVE controller CONFIRM row names what is pushed; else exit 2 + ONE `REFUSED <reason>` line, nothing pushed.
#   (ctl d-20261024-091807-controller-6985: the second push-before-confirm; rb row d-20261024-121515-rb-7178.)
#   --host <h>: <git dir> lives on host <h> (every rb land worktree is on RedBaron; the decisions db is on carbon). Checks 0-3 stay on carbon; every git op runs over
#     `ssh -o BatchMode=yes <h> ...` in TWO round trips: (i) rev-parse HEAD + tree + current branch, `fetch origin refs/heads/<branch>`, `merge-base --is-ancestor FETCH_HEAD <sha>`;
#     (ii) the push. <h> must match ^[a-z0-9][a-z0-9-]*$ [bad-host] and be in RB_LAND_PUSH_HOSTS (space-separated, default `redbaron`) [host-not-allowed]; the repo must match
#     ^/[A-Za-z0-9._/-]+$ [bad-repo]; both values are printf %q quoted for the remote shell; the remote command first sources ~/.config/environment.d/*.conf (non-login ssh has no token).
#   --check: run checks 0-4 plus `git ls-remote origin refs/heads/<branch>` (remote in --host mode), print `CHECK-OK sha=<8> host=<h|local>` or the refusal; NEVER pushes, never logs.
# Checks, in order (reason in brackets):
#   0 branch is not main/master [branch-protected] and does not start with `-` / has only [A-Za-z0-9._/-] [bad-branch]; the d-id is well formed [bad-confirm-id]; the db opens read-only [db-unreadable];
#     HEAD resolves [not-a-repo]; ssh answers [ssh-failed rc=N]
#   1 row <d-id> exists [no-row], agent = controller [wrong-agent], kind = verdict [kind-not-verdict], `what` starts with CONFIRM, case-sensitive [not-confirm]
#   2 `what` names HEAD: the first 8 hex of the COMMIT or of the TREE sha as a WHOLE token [sha-not-named] (git am changes the commit sha; the tree is the stable name)
#   2b row-to-branch binding: <branch> == `symbolic-ref --short HEAD` of the repo, unless `what` names <branch> as a whole word; a detached HEAD must be named too [branch-mismatch]
#   3 not withdrawn/overridden: a LATER controller row naming the d-id (full, or its 4-hex suffix as a whole token) with WITHDRAWN|CORRECT|"Do NOT push" [withdrawn];
#     a later controller "Do NOT push" naming an 8-hex of HEAD [do-not-push]; a later controller verdict CONFIRM naming <branch> but neither 8-hex of HEAD [superseded];
#     the row's own `regrade` JSON verdict CORRECT or DISAGREE [regrade-correct|regrade-disagree]
#   4 fast-forward only: `git fetch origin refs/heads/<branch>` then origin tip is an ancestor of the sha captured once at the top [fetch-failed|non-ff]
# Success: log `pushing` BEFORE the push, plain `git push origin <sha>:refs/heads/<branch>` (the sha captured once; never HEAD, never --force, never another refspec), then log `pushed` | `push-failed rc=N`.
# env: WM_DECISIONS_DB (default ~/.local/state/swarm-decide/decisions.sqlite, opened -readonly, never written); RB_LAND_PUSH_LOG (default ~/.local/state/rb-seat/land-push.log); RB_LAND_PUSH_HOSTS.
set -uo pipefail
DB="${WM_DECISIONS_DB:-$HOME/.local/state/swarm-decide/decisions.sqlite}"
LOG="${RB_LAND_PUSH_LOG:-$HOME/.local/state/rb-seat/land-push.log}"
refuse() { echo "REFUSED $*"; exit 2; }
sq() { sqlite3 -readonly -batch -noheader "$DB" "$1"; }   # read-only; the only interpolated values are the regex-validated d-id and a ts read from the db (quote-doubled)
sqs() { printf '%s' "${1//\'/\'\'}"; }
# tok <text> <hex>: <hex> is a WHOLE token in <text> (non-hex or edge on both sides), so `<8hex>9` does not name <8hex>
tok() { printf '%s\n' "$1" | grep -Eq "(^|[^0-9a-f])$2([^0-9a-f]|\$)"; }
# word <text> <branch>: <branch> appears delimited by a char outside [A-Za-z0-9._/-]
word() { local b; b=$(printf '%s' "$2" | sed 's/[][\.*^$+?(){}|/]/\\&/g'); printf '%s\n' "$1" | grep -Eq "(^|[^A-Za-z0-9._/-])$b([^A-Za-z0-9._/-]|\$)"; }

# rsh <host|""> <POSIX sh text>: run the text locally (bash -c) or over ssh. Remote text first sources ~/.config/environment.d/*.conf (a non-login ssh carries no token).
# Real ssh joins its args for the remote shell, so every interpolated value in <text> is printf %q'd (and regex-validated) by the caller.
ENVSRC='set -a; for f in ~/.config/environment.d/*.conf; do [ -f "$f" ] && . "$f"; done >/dev/null 2>&1; set +a'
rsh() { if [ -n "$1" ]; then ssh -o BatchMode=yes "$1" "$ENVSRC; $2" </dev/null; else bash -c "$2" </dev/null; fi; }

USAGE="usage: rb-land-push.sh --confirm <d-id> --repo <git dir> --branch <branch> [--host <h>] [--check] | --selftest"
run_push() {
  local id="" repo="" branch="" host="" hostset=0 check=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --confirm) id="${2:-}"; shift 2 || shift ;;
      --repo) repo="${2:-}"; shift 2 || shift ;;
      --branch) branch="${2:-}"; shift 2 || shift ;;
      --host) [ $# -ge 2 ] || { echo "$USAGE" >&2; return 64; }; host="$2"; hostset=1; shift 2 ;;
      --check) check=1; shift ;;
      *) echo "$USAGE" >&2; return 64 ;;
    esac
  done
  [ -n "$id" ] && [ -n "$repo" ] && [ -n "$branch" ] || { echo "$USAGE" >&2; return 64; }
  if [ $hostset = 1 ]; then
    printf '%s' "$host" | grep -Eq '^[a-z0-9][a-z0-9-]*$' || refuse bad-host "$host"
    case " ${RB_LAND_PUSH_HOSTS:-redbaron} " in *" $host "*) ;; *) refuse host-not-allowed "$host" ;; esac
  fi
  case "$branch" in main|master|refs/heads/main|refs/heads/master) refuse branch-protected "$branch" ;; esac
  branch="${branch#refs/heads/}"
  printf '%s' "$branch" | grep -Eq '^[A-Za-z0-9._/][A-Za-z0-9._/-]*$' || refuse bad-branch "$branch"
  if [ -n "$host" ]; then printf '%s' "$repo" | grep -Eq '^/[A-Za-z0-9._/-]+$' || refuse bad-repo "$repo"; fi
  printf '%s' "$id" | grep -Eq '^d-[0-9]{8}-[0-9]{6}-[a-z0-9]+-[0-9a-f]{4}$' || refuse bad-confirm-id "$id"
  [ -r "$DB" ] && sq 'select 1' >/dev/null 2>&1 || refuse db-unreadable "$DB"
  # one round trip: HEAD sha + tree + current branch, then fetch origin's tip and the ancestor test, all on the sha captured here (TOCTOU: nothing below re-reads HEAD)
  local qr qb ic out irc
  qr=$(printf '%q' "$repo"); qb=$(printf '%q' "$branch")
  ic="repo=$qr; branch=$qb; "'cd "$repo" 2>/dev/null || exit 0; sha=$(git rev-parse --verify HEAD 2>/dev/null) || exit 0; tree=$(git rev-parse --verify "HEAD^{tree}" 2>/dev/null) || exit 0;
echo "sha=$sha"; echo "tree=$tree"; echo "sbr=$(git symbolic-ref --short -q HEAD 2>/dev/null)";
if git fetch -q origin "refs/heads/$branch" >/dev/null 2>&1; then echo "old=$(git rev-parse --verify FETCH_HEAD 2>/dev/null)"; if git merge-base --is-ancestor FETCH_HEAD "$sha" 2>/dev/null; then echo anc=yes; else echo anc=no; fi; else echo "old="; fi;'
  [ $check = 1 ] && ic="$ic"'lsr=$(git ls-remote origin "refs/heads/$branch" 2>/dev/null); echo "lsrc=$?"; echo "lsr=$(printf %s "$lsr" | cut -f1)";'
  out=$(rsh "$host" "$ic" 2>/dev/null); irc=$?
  [ $irc = 0 ] || refuse "ssh-failed rc=$irc" "${host:-local}"
  local head="" tree="" sbr="" old="" anc="" lsrc="" lsr="" k v
  while IFS== read -r k v; do
    case "$k" in sha) head=$v ;; tree) tree=$v ;; sbr) sbr=$v ;; old) old=$v ;; anc) anc=$v ;; lsrc) lsrc=$v ;; lsr) lsr=$v ;; esac
  done <<<"$out"
  [[ "$head" =~ ^[0-9a-f]{40,64}$ ]] && [[ "$tree" =~ ^[0-9a-f]{40,64}$ ]] || refuse not-a-repo "$repo"
  local h8=${head:0:8} t8=${tree:0:8}

  # 1. the row
  local n agent kind what cts regrade
  n=$(sq "select count(*) from decisions where id='$id'") || refuse db-unreadable "$DB"
  [ "$n" = 1 ] || refuse no-row "$id"
  agent=$(sq "select agent from decisions where id='$id'"); kind=$(sq "select kind from decisions where id='$id'")
  what=$(sq "select what from decisions where id='$id'"); cts=$(sq "select ts from decisions where id='$id'")
  [ "$agent" = controller ] || refuse wrong-agent "$id agent=$agent"
  [ "$kind" = verdict ] || refuse kind-not-verdict "$id kind=$kind"
  case "$what" in CONFIRM*) ;; *) refuse not-confirm "$id" ;; esac
  # 2. the row names what is pushed
  tok "$what" "$h8" || tok "$what" "$t8" || refuse sha-not-named "$id names neither commit $h8 nor tree $t8"
  # 2b. row-to-branch binding: the repo is ON <branch>, unless the row's `what` names <branch> as a whole word (a detached HEAD must be named too)
  [ "$sbr" = "$branch" ] || word "$what" "$branch" || refuse branch-mismatch "$id HEAD is on '${sbr:-detached}', not $branch, and the row does not name $branch"
  # 3. not withdrawn / overridden
  local suffix=${id##*-} q lid lwhat
  q="agent='controller' and (julianday(ts) > julianday('$(sqs "$cts")') or (julianday(ts) is null and ts > '$(sqs "$cts")')) and id<>'$id'"
  while IFS= read -r lid; do
    [ -n "$lid" ] || continue
    lwhat=$(sq "select what from decisions where id='$(sqs "$lid")'")
    if { case "$lwhat" in *"$id"*) true ;; *) tok "$lwhat" "$suffix" ;; esac; } && printf '%s\n' "$lwhat" | grep -Eq 'WITHDRAWN|CORRECT|Do NOT push'; then refuse withdrawn "$id by $lid"; fi
    if printf '%s\n' "$lwhat" | grep -q 'Do NOT push' && { tok "$lwhat" "$h8" || tok "$lwhat" "$t8"; }; then refuse do-not-push "$lid names $h8/$t8"; fi
    if [ "$(sq "select kind from decisions where id='$(sqs "$lid")'")" = verdict ]; then
      case "$lwhat" in CONFIRM*) if word "$lwhat" "$branch" && ! tok "$lwhat" "$h8" && ! tok "$lwhat" "$t8"; then refuse superseded "$lid confirms a different sha for $branch"; fi ;; esac
    fi
  done < <(sq "select id from decisions where $q order by ts")
  regrade=$(sq "select coalesce(regrade,'') from decisions where id='$id'")
  if [ -n "$regrade" ]; then
    rv=$(printf '%s' "$regrade" | python3 -I -c 'import json,sys
try: d=json.load(sys.stdin); v=d.get("verdict","") if isinstance(d,dict) else ""
except Exception: v=""
print(str(v).upper())' 2>/dev/null)
    case "$rv" in CORRECT) refuse regrade-correct "$id" ;; DISAGREE) refuse regrade-disagree "$id" ;; esac
  fi
  # 4. fast-forward only (fetched + tested in the round trip above, against the sha captured there)
  [[ "$old" =~ ^[0-9a-f]{40,64}$ ]] || refuse fetch-failed "origin $branch"
  [ "$anc" = yes ] || refuse non-ff "origin/$branch ${old:0:8} is not an ancestor of HEAD $h8"
  if [ $check = 1 ]; then
    [ "$lsrc" = 0 ] || refuse ls-remote-failed "origin $branch"
    echo "CHECK-OK sha=$h8 host=${host:-local}"; return 0
  fi
  # 5. log, push, log
  mkdir -p "$(dirname "$LOG")" || refuse log-unwritable "$LOG"
  local line hostf=""; [ -n "$host" ] && hostf=" host=$host"
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) pushing $id confirm_ts=$cts agent=${CLAUDE_AGENT_ID:-${WM_SEAT:-unknown}} $branch ${old:0:8}..${h8}$hostf"
  printf '%s\n' "$line" >> "$LOG" || refuse log-unwritable "$LOG"
  rsh "$host" "git -C $qr push -q origin $head:refs/heads/$qb"; local prc=$?
  if [ $prc = 0 ]; then line="${line/ pushing / pushed }"; else line="${line/ pushing / push-failed rc=$prc }"; fi
  printf '%s\n' "$line" >> "$LOG"; printf '%s\n' "$line"
  return $prc
}

selftest() {
  local T; T=$(mktemp -d "${TMPDIR:-/tmp}/rblp-selftest.XXXXXX"); trap 'rm -rf "$T"' RETURN
  local self; self=$(readlink -f "${BASH_SOURCE[0]}")
  local pass=0 total=0 g=(git -c user.name=t -c user.email=t@t)
  export HOME="$T/home"; mkdir -p "$HOME"; export WM_DECISIONS_DB="$T/d.sqlite" RB_LAND_PUSH_LOG="$T/land-push.log" WM_SEAT=selftest
  sqlite3 "$WM_DECISIONS_DB" "create table decisions (id TEXT PRIMARY KEY, ts TEXT NOT NULL, agent TEXT NOT NULL, kind TEXT NOT NULL, what TEXT NOT NULL, regrade TEXT);"
  # fake ssh (no real ssh, ever): strips `-o BatchMode=yes <h>`, runs the remainder through bash -c "$*" exactly as a remote shell would (so %q quoting is exercised); FAKE_SSH_RC forces a failure
  mkdir -p "$T/bin"; : > "$T/ssh.log"; export FAKE_SSH_LOG="$T/ssh.log"
  cat > "$T/bin/ssh" <<'EOS'
#!/usr/bin/env bash
[ -n "${FAKE_SSH_RC:-}" ] && exit "$FAKE_SSH_RC"
[ "${1:-}" = -o ] && [ "${2:-}" = BatchMode=yes ] || exit 97
echo call >> "$FAKE_SSH_LOG"; shift 3
exec bash -c "$*"
EOS
  chmod +x "$T/bin/ssh"; export PATH="$T/bin:$PATH"; [ "$(command -v ssh)" = "$T/bin/ssh" ] || { echo "selftest: fake ssh not first on PATH"; return 1; }
  git init -q --bare -b main "$T/origin.git"; git clone -q "$T/origin.git" "$T/wt" 2>/dev/null
  ( cd "$T/wt" && echo a > f && "${g[@]}" add f && "${g[@]}" commit -qm a && git push -q origin HEAD:refs/heads/main && git push -q origin HEAD:refs/heads/wm-build/x && git checkout -q -b wm-build/x && echo b >> f && "${g[@]}" commit -qam b )
  local h8 t8; h8=$(git -C "$T/wt" rev-parse HEAD); h8=${h8:0:8}; t8=$(git -C "$T/wt" rev-parse 'HEAD^{tree}'); t8=${t8:0:8}
  local B=wm-build/x ok=d-20261024-100000-controller-abcd
  row() { sqlite3 "$WM_DECISIONS_DB" "insert into decisions values ('$1','$2','$3','$4','$5',${6:-NULL});"; }
  clear() { sqlite3 "$WM_DECISIONS_DB" "delete from decisions;"; }
  # case <name> <want-reason|PUSHED> <id> [branch]  (rows already inserted; XA = extra args, REPO = the --repo value)
  local -a XA=(); local REPO="$T/wt"
  case_() {
    local name=$1 want=$2 id=$3 br=${4:-$B} before after out rc
    total=$((total+1)); before=$(git -C "$T/origin.git" rev-parse "refs/heads/${br#refs/heads/}" 2>/dev/null || echo none)
    out=$(bash "$self" --confirm "$id" --repo "$REPO" --branch "$br" ${XA[@]+"${XA[@]}"} 2>&1); rc=$?
    after=$(git -C "$T/origin.git" rev-parse "refs/heads/${br#refs/heads/}" 2>/dev/null || echo none)
    if [ "$want" = PUSHED ]; then
      if [ $rc = 0 ] && [ "$after" = "$(git -C "$REPO" rev-parse HEAD)" ] && grep -q " pushing $id " "$RB_LAND_PUSH_LOG" && grep -q " pushed $id " "$RB_LAND_PUSH_LOG"; then pass=$((pass+1)); echo "ok - $name"; else echo "NOT OK - $name: rc=$rc out=$out"; fi
    else
      if [ $rc = 2 ] && [ "$(printf '%s\n' "$out" | wc -l)" = 1 ] && [[ "$out" == "REFUSED $want"* ]] && [ "$before" = "$after" ]; then pass=$((pass+1)); echo "ok - $name"; else echo "NOT OK - $name: rc=$rc out=$out ref $before -> $after"; fi
    fi
  }
  clear;                                                                                        case_ no-row no-row "$ok"
  row "$ok" 2026-10-24T10:00:00-07:00 rb verdict "CONFIRM tree $t8";                            case_ wrong-agent wrong-agent "$ok"; clear
  row "$ok" 2026-10-24T10:00:00-07:00 controller note "CONFIRM tree $t8";                       case_ kind-not-verdict kind-not-verdict "$ok"; clear
  row "$ok" 2026-10-24T10:00:00-07:00 controller verdict "confirm tree $t8";                    case_ not-confirm not-confirm "$ok"; clear
  row "$ok" 2026-10-24T10:00:00-07:00 controller verdict "CONFIRM tree deadbeef";               case_ sha-not-named sha-not-named "$ok"; clear
  row "$ok" 2026-10-24T10:00:00-07:00 controller verdict "CONFIRM tree ${t8}9 only";            case_ prefix-false-positive sha-not-named "$ok"; clear
  row "$ok" 2026-10-24T10:00:00-07:00 controller verdict "CONFIRM tree $t8"
  row d-20261024-101000-controller-1111 2026-10-24T10:10:00-07:00 controller verdict "WITHDRAWN: confirm abcd"; case_ withdrawn-by-suffix withdrawn "$ok"; clear
  row "$ok" 2026-10-24T10:00:00-07:00 controller verdict "CONFIRM tree $t8"
  row d-20261024-101000-controller-1111 2026-10-24T10:10:00-07:00 controller verdict "Do NOT push $t8";  case_ do-not-push do-not-push "$ok"; clear
  row "$ok" 2026-10-24T10:00:00-07:00 controller verdict "CONFIRM tree $t8"
  row d-20261024-101000-controller-1111 2026-10-24T10:10:00-07:00 controller verdict "CONFIRM $B tree 0badc0de"; case_ superseded superseded "$ok"; clear
  row "$ok" 2026-10-24T10:00:00-07:00 controller verdict "CONFIRM tree $t8" "'{\"verdict\":\"CORRECT\"}'"; case_ regrade-correct regrade-correct "$ok"; clear
  row "$ok" 2026-10-24T10:00:00-07:00 controller verdict "CONFIRM tree $t8";                     case_ branch-main branch-protected "$ok" main
  case_ bad-id bad-confirm-id "d-1"
  # non-ff: origin gets a commit HEAD does not have
  ( cd "$T" && git clone -q origin.git other 2>/dev/null && cd other && git checkout -q wm-build/x 2>/dev/null; echo z > z && "${g[@]}" add z && "${g[@]}" commit -qm z && git push -q origin HEAD:refs/heads/wm-build/x )
  case_ non-ff non-ff "$ok"
  git -C "$T/origin.git" update-ref refs/heads/wm-build/x "$(git -C "$T/wt" rev-parse HEAD~1)"   # test origin only: put the tip back at HEAD~1
  case_ pushed-by-tree PUSHED "$ok"; clear
  # --- branch binding (local mode): the wt is ON wm-build/x
  local H; H=$(git -C "$T/wt" rev-parse HEAD); git -C "$T/wt" worktree add -q --detach "$T/wtd" HEAD
  git -C "$T/origin.git" update-ref refs/heads/wm-build/y "$(git -C "$T/wt" rev-parse HEAD~1)"
  row "$ok" 2026-10-24T10:00:00-07:00 controller verdict "CONFIRM tree $t8";                    case_ branch-mismatch branch-mismatch "$ok" wm-build/y
  REPO="$T/wtd";                                                                                case_ detached-head-unnamed branch-mismatch "$ok"; REPO="$T/wt"; clear
  row "$ok" 2026-10-24T10:00:00-07:00 controller verdict "CONFIRM wm-build/y tree $t8";         case_ what-names-branch PUSHED "$ok" wm-build/y; clear
  git -C "$T/origin.git" update-ref refs/heads/wm-build/x "$(git -C "$T/wt" rev-parse HEAD~1)"
  # --- remote mode over the fake ssh
  row "$ok" 2026-10-24T10:00:00-07:00 controller verdict "CONFIRM tree $t8"
  XA=(--host redbaron); : > "$T/ssh.log"
  case_ remote-pushed PUSHED "$ok"
  total=$((total+1)); if [ "$(wc -l < "$T/ssh.log")" = 2 ] && grep -q " pushed $ok .* host=redbaron\$" "$RB_LAND_PUSH_LOG"; then pass=$((pass+1)); echo "ok - remote-two-roundtrips-and-host-logged"; else echo "NOT OK - remote-two-roundtrips-and-host-logged: calls=$(wc -l < "$T/ssh.log")"; fi
  XA=(--host 'x;y');                                                                            case_ bad-host bad-host "$ok"
  XA=(--host evil);                                                                             case_ host-not-allowed host-not-allowed "$ok"
  XA=(--host redbaron); REPO="$T/w t";                                                          case_ bad-repo-space bad-repo "$ok"
  REPO="$T/w;t";                                                                                case_ bad-repo-semicolon bad-repo "$ok"; REPO="$T/wt"
  git -C "$T/origin.git" update-ref refs/heads/wm-build/x "$(git -C "$T/other" rev-parse HEAD)"; case_ remote-non-ff non-ff "$ok"
  git -C "$T/origin.git" update-ref refs/heads/wm-build/x "$(git -C "$T/wt" rev-parse HEAD~1)"
  total=$((total+1)); local ob oa oo; ob=$(git ls-remote "$T/origin.git"); oo=$(FAKE_SSH_RC=255 bash "$self" --confirm "$ok" --repo "$T/wt" --branch "$B" --host redbaron 2>&1); oa=$(git ls-remote "$T/origin.git")
  if [ "$oo" = "REFUSED ssh-failed rc=255 redbaron" ] && [ "$ob" = "$oa" ]; then pass=$((pass+1)); echo "ok - ssh-failed rc=255, ls-remote unchanged"; else echo "NOT OK - ssh-failed: out=$oo"; fi
  total=$((total+1)); : > "$RB_LAND_PUSH_LOG"; ob=$(git ls-remote "$T/origin.git"); oo=$(bash "$self" --confirm "$ok" --repo "$T/wt" --branch "$B" --host redbaron --check 2>&1); oa=$(git ls-remote "$T/origin.git")
  if [ "$oo" = "CHECK-OK sha=${H:0:8} host=redbaron" ] && [ "$ob" = "$oa" ] && [ ! -s "$RB_LAND_PUSH_LOG" ]; then pass=$((pass+1)); echo "ok - --check prints CHECK-OK, pushes nothing, logs nothing"; else echo "NOT OK - --check: out=$oo"; fi
  XA=(--host redbaron --check);                                                                 case_ check-refuses-branch-mismatch branch-mismatch "$ok" wm-build/y
  XA=(); clear
  echo "selftest ok $pass/$total"; [ "$pass" = "$total" ]
}

if [ "${1:-}" = --selftest ]; then selftest; exit $?; fi
run_push "$@"
