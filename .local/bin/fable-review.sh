#!/usr/bin/env bash
# fable-review.sh <page> - L7 judgment launcher (claude-operated-procedures-to-code A241).
# One-turn `claude -p` unit: Fable, xhigh, the page inline, no tools. The last `VERDICT:` line of the
# reply is parsed and written as one wm-decide row (kind design, tag fable-review). Unparseable reply:
# exit 3, no row, reply kept in $FABLE_REVIEW_OUT. Exit 0 = row written, 2 = usage/page error, 4 = row refused.
# Env: FABLE_REVIEW_CLAUDE (claude), FABLE_REVIEW_MODEL (claude-fable-5-1), FABLE_REVIEW_EFFORT (xhigh),
#      FABLE_REVIEW_LAUNCH (default systemd-run --user transient unit; tests set `env`),
#      WM_DECIDE_BIN (wm-decide), FABLE_REVIEW_AGENT (aide), FABLE_REVIEW_OUT, FABLE_REVIEW_TIMEOUT (3600 s).
set -u
page="${1:-}"
[ -n "$page" ] && [ -f "$page" ] || { echo "usage: fable-review.sh <page>" >&2; exit 2; }
claude_bin="${FABLE_REVIEW_CLAUDE:-claude}"
model="${FABLE_REVIEW_MODEL:-claude-fable-5-1}"
effort="${FABLE_REVIEW_EFFORT:-xhigh}"
decide="${WM_DECIDE_BIN:-wm-decide}"
agent="${FABLE_REVIEW_AGENT:-aide}"
stamp=$(date +%Y%m%d-%H%M%S)
out="${FABLE_REVIEW_OUT:-${TMPDIR:-/tmp}/fable-review-$stamp-$$.txt}"
if [ -n "${FABLE_REVIEW_LAUNCH+x}" ]; then launch="$FABLE_REVIEW_LAUNCH"
else launch="systemd-run --user --quiet --wait --pipe --collect --unit=fable-review-$stamp-$$"; fi

prompt="You are reviewing one page before action. One turn, no tools. Read the page below and judge it.
Reply with at most 5 findings, each an edit to make. The last line of the reply is exactly one of:
VERDICT: APPROVE
VERDICT: APPROVE-WITH-EDITS
VERDICT: REJECT
VERDICT: NEEDS-READ <the one missing fact>

PAGE ($(basename "$page")):
$(cat "$page")"

# shellcheck disable=SC2086
timeout "${FABLE_REVIEW_TIMEOUT:-3600}" $launch "$claude_bin" -p --model "$model" --effort "$effort" \
  --tools "" --no-session-persistence --permission-mode default > "$out" 2> "$out.err" <<< "$prompt"
rc=$?
verdict=$(grep -E '^VERDICT: (APPROVE|APPROVE-WITH-EDITS|REJECT|NEEDS-READ)( .*)?$' "$out" | tail -1)
if [ -z "$verdict" ]; then
  echo "fable-review: no parseable VERDICT line (claude rc=$rc); reply kept in $out" >&2
  exit 3
fi
sha=$(sha256sum "$page" | cut -c1-12)
row=$("$decide" record --agent "$agent" --via fable-review --model "$model" --kind design \
  --tag fable-review --target "page=$page" \
  --what "fable-review $(basename "$page") sha=$sha ${verdict}" \
  --why "one-turn $model at $effort effort, page inline, no tools (fable-review.sh)" \
  --evidence "reply: $out" --reverse-text "none (review row)") || { echo "fable-review: wm-decide record refused (rc=$?)" >&2; exit 4; }
echo "$row ${verdict}"
