#!/usr/bin/env bash
# Draft drain in summa-candidates-start.sh: drafts > 7 d are deleted (status-report bodies) or filed as
# wiki/answers/<date>-<slug>.md with status: unreviewed. Fixture vault in TMPDIR; the real vault is never touched.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
S="$here/.claude/scripts/summa-candidates-start.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/summa-drain.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail=0
chk() { if [ "$1" = 0 ]; then echo "ok - $2"; else echo "NOT OK - $2"; fail=1; fi; }
export SUMMA_VAULT="$T/vault" SUMMA_LEDGER="$T/none.jsonl" SUMMA_ANSWER_CANDIDATES_DIR="$T/drafts"
mkdir -p "$T/vault/wiki/answers" "$T/drafts"
draft() { # <sid> <question> <asked> <body> <age as a `touch -d` string>
  printf -- '---\nsumma: answer-draft\nquestion: "%s"\nasked: %s\nsession_id: %s\nreview: run /summa ask with this question, or delete this file\n---\n\n%s\n' "$2" "$3" "$1" "$4" >"$T/drafts/$1.md"
  touch -d "$5" "$T/drafts/$1.md"
}
body='The relay works by pushing each job to a queue, a worker pulls it, and the result is posted back. This is the full explanation of the relay design.'
draft d3  'How does the relay work?'                 2026-10-26T10:00:00Z "$body" "3 days ago"
draft d75 'How does the relay work?'                 2026-10-21T10:00:00Z "$body" "180 hours ago"
draft d9  'Why: the timer fired twice at 3:00 PM?'    2026-10-20T10:00:00Z "$body" "9 days ago"
draft d30 'What is the build ETA for the PRD queue?'  2026-09-29T10:00:00Z 'The build is still running; ETA unknown. I will report once the PRD queue lands.' "30 days ago"
before="$(date +%F)"
out="$(bash "$S")"; rc=$?
[ "$rc" = 0 ]; chk $? "hook exits 0"
n_old="$(find "$T/drafts" -name '*.md' -mmin +10080 | wc -l)"
[ "$n_old" = 0 ]; chk $? "no draft older than 7 d remains"
grep -qx 'drafts > 7 d: 0' <<<"$out"; chk $? "prints 'drafts > 7 d: 0'"
[ -e "$T/drafts/d3.md" ]; chk $? "the 3-day draft is kept"
[ ! -e "$T/drafts/d30.md" ] && ! ls "$T/vault/wiki/answers" | grep -q eta; chk $? "status-report draft (ETA / still running) is deleted, not filed"
[ "$(ls "$T/vault/wiki/answers" | wc -l)" = 2 ]; chk $? "the 7.5-day and 9-day drafts are filed (2 pages)"

f1="$(ls "$T/vault/wiki/answers"/*how-does-the-relay-work* | head -n1)"
head -n1 "$f1" | grep -qx -- '---' && grep -qx 'status: unreviewed' "$f1" && grep -qx 'summa: answer' "$f1"; chk $? "filed page has answer frontmatter with status: unreviewed"
grep -qxF "> Filed $before from a session draft dated $(date -d '180 hours ago' +%F)" "$f1"; chk $? "first body line is '> Filed <today> from a session draft dated <d>'"
grep -q 'The relay works by pushing' "$f1"; chk $? "draft body carried over"
f9="$(ls "$T/vault/wiki/answers"/*timer-fired* | head -n1)"
grep -qx 'question: "Why: the timer fired twice at 3:00 PM?"' "$f9"; chk $? "a question containing ': ' is quoted in frontmatter"

# never overwrite: -2, -3 ...
draft e1 'How does the relay work?' 2026-10-21T10:00:00Z "$body" "8 days ago"
draft e2 'How does the relay work?' 2026-10-21T10:00:00Z "$body" "8 days ago"
bash "$S" >/dev/null
[ "$(ls "$T/vault/wiki/answers" | grep -c 'how-does-the-relay-work')" = 3 ] && ls "$T/vault/wiki/answers" | grep -q -- '-2\.md$'; chk $? "name collisions get -2, -3 (3 relay pages, none overwritten)"
n=$(grep -l 'The relay works by pushing' "$T/vault/wiki/answers"/*.md | wc -l); [ "$n" = 4 ]; chk $? "every filed body is present (relay x3 + timer page share the fixture body)"

# vault missing: the draft stays and the count shows it
rm -rf "$T/vault"; draft f1 'How does the relay work?' 2026-10-21T10:00:00Z "$body" "9 days ago"
out="$(bash "$S")"; grep -qx 'drafts > 7 d: 1' <<<"$out" && [ -e "$T/drafts/f1.md" ]; chk $? "no vault -> draft kept, 'drafts > 7 d: 1'"
exit $fail
