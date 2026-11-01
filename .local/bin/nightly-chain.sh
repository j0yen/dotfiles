#!/bin/bash
# nightly-chain.sh — PRD-synthorg-one-runner Requirement 8 [P1]: a thin
# caller of `synthorg chain run`, which now owns the link order, the
# per-link env, and the theme-from-ranking wiring `nightly-chain.sh` used to
# hand-wire itself (see git history for the pre-PRD 90-line version this
# replaces). This is the reference version this repo ships; the operator
# installs it over `~/.local/bin/nightly-chain.sh` by hand (that file lives
# outside this repo/version control, so pybuild does not overwrite it for
# you) — same install-by-hand posture as the `deploy/*.service`/`*.timer`
# units beside this file.
#
# The wm-build live reruns and the wait-slug gate stay here (Technical
# considerations: they need the fleet OAuth token / systemd unit env, and
# are not part of the discovery chain itself).
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
for slug in ${NIGHTLY_WAIT_FOR_SLUGS:-}; do
  if [ ! -f "$HOME/Documents/PRDs/built-prds/PRD-$slug.md" ]; then
    echo "== chain deferred: $slug not built yet $(date -u +%FT%TZ)"; exit 0
  fi
done
cd "$HOME/repos/synthorg" || exit 2

DISCOVER_FLAG=""
GOLD_DRIFT_FLAG=""
COMPETITOR_WATCH_FLAG=""
ONCE="$HOME/.config/synthorg/discover-once"
if [ "$(TZ=America/Los_Angeles date +%u)" = "6" ] || [ "${NIGHTLY_FORCE_DISCOVER:-0}" = "1" ] || [ -f "$ONCE" ]; then
  [ -f "$ONCE" ] && { echo "== discover-once flag consumed ($(cat "$ONCE"))"; rm -f "$ONCE"; }
  # PRD-synthorg-discover-brief-generated R5: BRIEF_GEN_START..END writes a
  # fresh host-grounded brief first; NIGHTLY_DISCOVER_BRIEF is the briefs DIR
  # (`chain run --brief <dir>` resolves the newest file). A brief-gen failure
  # is one WARNING and the chain runs on the newest existing brief.
  # PRD-synthorg-gold-drift-link: weekly, same Saturday rule; `gold-drift` runs
  # before discover and only marks (the operator reviews the corpora diff).
  GOLD_DRIFT_FLAG="--gold-drift"
  # PRD-synthorg-discover-competitor-watch: weekly, same Saturday rule; the link
  # snapshots five competitor pages before discover merges their evidence rows.
  COMPETITOR_WATCH_FLAG="--competitor-watch"
  # BRIEF_GEN_START
  if [ -n "${SYNTHORG_PROD_ENDPOINT:-}" ]; then
    uv run synthorg chain brief --host "$SYNTHORG_PROD_ENDPOINT" \
      || echo "WARNING: chain brief --host failed rc=$? — using the newest existing brief"
  else
    echo "WARNING: SYNTHORG_PROD_ENDPOINT unset — skipping chain brief --host"
  fi
  # BRIEF_GEN_END
  DISCOVER_FLAG="--discover --brief ${NIGHTLY_DISCOVER_BRIEF:?set NIGHTLY_DISCOVER_BRIEF (the briefs dir)}"
fi

# PRD-synthorg-mcphost-market-test-live-proof Requirement 8 [P1]: the
# mtproof link is weekly by default (Sundays) or on demand
# ($NIGHTLY_FORCE_MTPROOF=1) -- same lever as $NIGHTLY_FORCE_DISCOVER above.
# The wave rehearsal has no flag at all here; it is never run by the chain.
MTPROOF_FLAG=""
if [ "$(TZ=America/Los_Angeles date +%u)" = "7" ] || [ "${NIGHTLY_FORCE_MTPROOF:-0}" = "1" ]; then
  MTPROOF_FLAG="--mtproof"
fi

# PRD-synthorg-ci-chain-link: the `ci` link (day-keyed competitor fetch -> diff -> dashboard)
# runs every night after the paid links. NIGHTLY_CI=0 turns it off without a deploy -- the
# lever the PRD's falsifier turns (fewer than 4 of the first 14 days with a capability row:
# daily is noise, drop it and let `competitor-watch` run on the Saturday week key only).
CI_FLAG=""
if [ "${NIGHTLY_CI:-1}" = "1" ]; then
  CI_FLAG="--ci"
fi

uv run synthorg chain run --trigger timer $DISCOVER_FLAG $GOLD_DRIFT_FLAG $COMPETITOR_WATCH_FLAG $MTPROOF_FLAG $CI_FLAG
rc=$?

# PRD-synthorg-chain-quota-brake: `chain run` above is a child process --
# an env var it sets on itself never reaches this shell. This file (sourced
# here, right after it returns) is the actual handoff: present only when a
# link got deferred for quota tonight, absent (so the block below never
# triggers) on an ordinary night.
QUOTA_ENV_FILE="${SYNTHORG_CHAIN_QUOTA_ENV_FILE:-$HOME/.config/synthorg/chain-quota.env}"
[ -f "$QUOTA_ENV_FILE" ] && . "$QUOTA_ENV_FILE"

# LIVE_RERUN_START -- PRD-synthorg-chain-quota-brake Requirement 4/AC-5:
# `SYNTHORG_QUOTA_RESET` (an ISO timestamp) set and still in the future
# defers the live rerun with a line instead of calling `wm-build live`
# into the same refusal the chain just hit.
# A systemd EnvironmentFile line `VAR=  # set me` keeps the inline comment as
# the VALUE (10-20: `wm-build live` ran for "#", "set", "me"), so the script
# never trusts the file: strip a trailing comment, split without globbing, and
# run a token only if it is a run id or a PRD slug that exists on disk.
live_tokens=()
for v in "${NIGHTLY_LIVE_AFTER_TRUTH:-}" "${NIGHTLY_LIVE_AFTER_EXPLORE:-}"; do
  read -r -a toks <<< "${v%%#*}"
  for t in ${toks[@]+"${toks[@]}"}; do
    if [[ "$t" =~ ^[0-9]+$ ]] \
      || { [[ "$t" =~ ^[A-Za-z0-9_-]+$ ]] \
        && { [ -f "$HOME/Documents/PRDs/built-prds/PRD-$t.md" ] || [ -f "$HOME/Documents/PRDs/PRD-$t.md" ]; }; }; then
      live_tokens+=("$t")
    else
      echo "== live skip $t: not a slug or run id"
    fi
  done
done
for r in ${live_tokens[@]+"${live_tokens[@]}"}; do
  if [ -n "${SYNTHORG_QUOTA_RESET:-}" ] \
    && [ "$(date -u +%s)" -lt "$(date -u -d "$SYNTHORG_QUOTA_RESET" +%s 2>/dev/null || echo 0)" ]; then
    echo "== live $r deferred: quota until $SYNTHORG_QUOTA_RESET"
  else
    echo "== live $r"; wm-build live "$r"
  fi
done
# LIVE_RERUN_END

echo "== chain done rc=$rc $(date -u +%FT%TZ)"
exit "$rc"
