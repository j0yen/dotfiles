# PRD: grand-loop-liveness-contract — a revenue loop that has not written a fresh success row is red, and red is shown at session start

- Status: queued
- Lane: orch 2026-09-22T15:43:05.866389060+00:00 run=88
- build_target: shell
- build_into: /home/jsy/dotfiles
- build_priority: high
- publish: j0yen/private
- Vision: visions/grand-loop.md
- Loop: grand-loop: instrument family (reached_measure)
- PM: Joe
- Drafted: 2026-09-18
- Grounding: failure-derived — visions/grand-loop.md addendum 2026-09-18 (why-chain level 5 + rhyme whys 6-8): no unit schedules the tick, `state.json` frozen at PREFLIGHT since 09-15, demand alarms journaled as `ok`
- Engineering target: dotfiles `.local/bin/grand-loop-tick.sh`, `.local/bin/grand-loop-demand.sh`, `.local/lib/grand-loop-lib.sh`, user units under `.config/systemd/user/`
- test_prefix: liveness
- deferred_acs: [1, 9]
- deferred_ac_reasons: {"1": "the unit rename to grand-loop-tick.timer/.service (daily cadence, ExecCondition) is implemented and statically tested (tests/liveness_ac1_timer_shape.test.sh), but enabling it on RedBaron and observing a real systemctl --user list-timers next-fire requires an operational step on that host outside a single build dispatch, same posture as PRD-grand-loop-scaffold's own AC12 timer-enablement deferral.", "9": "requires the renamed timer actually enabled on RedBaron (AC1) AND waiting for its next scheduled fire against the real hub the following morning; cannot be produced synchronously within one build dispatch, proof is the row not a fixture per the AC's own text."}
- iter_log: 2026-09-18T06:09:42Z carbon — implemented bl_liveness/bl_success_stamp, stderr_tail capture, grand-loop-demand.sh exit-1-on-alarm, grand-loop-banner.sh (SessionStart), grand-loop-status verdict-first, grand-loop-tick.timer rename+ExecCondition, daily-note Open needs; tests/liveness_ac{1,2,3,4,5,6,7,8,10}_*.test.sh green offline. Landing to dotfiles main blocked this tick: `worktree-extend.sh land` exited 4 (pre-existing untracked .bak-20260911 files in dotfiles' working tree, unrelated to this PRD) — work sits on branch autobuilder/grand-loop-liveness-contract in the worktree, retry land next tick once main is clean.

## TL;DR

The grand loop is the only reader of `paid_mrr_usd`, the goal metric. It has written no
row since 2026-09-15T05:03Z because nothing schedules it, its one hand run stopped at
preflight with the cause in a log nobody opened, and the daily demand read has alarmed
two nights running while its service journaled `ok`. This PRD gives the loop a timer, a
maximum age for its last success row, an outcome banner at SessionStart on every node,
and the rule that a missing fresh row is a failure.

## Problem statement

Joe runs a loop whose one number is real paid monthly revenue. He cannot tell from any
banner, status line, or daily note whether that number was read today. Evidence
(visions/grand-loop.md, 2026-09-18 chain): `state.json` frozen at `PREFLIGHT: running`
since 09-15; `ledger.md` last row `family=instrument reason="preflight: probe command
failed"`; `demand/ledger.jsonl` rows for 09-16 and 09-17 with `alarm:true, exit_code:1`
beside service journal lines `ok: demand row appended`; `daily/2026-09-15.md` reads
`Open needs: none`; no user unit references `grand-loop-tick.sh`. Consequence: three days
without the goal metric, unnoticed, during the week the first real tenant exists.

## Goals

- The tick runs on a timer and its outcome is a state artifact with a declared max age.
- Any node's SessionStart shows the loop's last success age, its family, and any demand
  alarm streak.
- The failing probe's stderr is in the ledger row, not only in a log.

## Non-goals

- Fixing the `KeyError: 'namespace'` itself (PRD-mcphost-deploy-measure-tenant-shape).
- Changing the metric, the exclusions, or the digest format.
- Editing `/buildloop-factory` laws (open question, Joe).

## User stories

- As the operator (Joe), I open a session and see `grand-loop: last measure 31 h ago
  (max 26 h) — RED, family=instrument` before I type anything.
- As the loop, I run daily at a fixed time and refuse to overlap a running tick.
- As the on-call reader of `ledger.md`, I see why preflight failed in the row.
- As the demand service, I exit non-zero when I wrote an alarm row so `systemctl`
  and the journal agree with the ledger.

## Requirements

P0
1. A user timer `grand-loop-tick.timer` runs `grand-loop-tick.sh` once a day at
   `GRAND_LOOP_TICK_TIME` (default 06:30 local) with `ExecCondition` reusing the
   node-placement check the demand unit already uses; unit files live in dotfiles and
   install with the existing dotfiles apply path.
2. `grand-loop-lib.sh` gains `bl_success_stamp` (writes `state/last-success.json` with
   `ts`, `phase`, `version`) and `bl_liveness` (prints `ok|stale|never` given
   `GRAND_LOOP_MAX_AGE`, default `26h`); a `PREFLIGHT: running` older than
   `GRAND_LOOP_PHASE_MAX_WALL` (default `30m`) is reported as `stuck`.
3. A banner script `grand-loop-banner.sh` prints one line at SessionStart on every
   node (via the fleet's shared hooks path): last success age vs max, family and
   reason of the last row, demand alarm streak count; RED when stale, stuck, or a
   streak ≥ 2.
4. `finish_instrument` stores the last 20 lines of the failing command's stderr in
   the ledger row (`stderr_tail=` field, newlines escaped) and in
   `state/last-failure.txt`.
5. `grand-loop-demand.sh` exits 1 whenever it wrote an alarm row; the journal line
   reads `alarm: … (see ledger)` not `ok`.

P1
6. A stale or stuck state also delivers through the build loop's existing
   `alert-deliver.sh` once per UTC day (idempotent by date).
7. `grand-loop-status` (existing) prints the liveness verdict first.

P2
8. The daily note lists `Open needs: instrument stale since <ts>` when RED.

## Success metrics

| metric | baseline | target | method | timeframe |
|---|---|---|---|---|
| days with a measure row | 0 of last 3 | 7 of 7 | `ledger.md` rows per day | first week after ship |
| time from stale to operator-visible | unbounded (3 d observed) | ≤ 1 session start | banner line present | first stale event |
| demand alarm with journal `ok` | 2 of 2 | 0 | journal vs ledger | ongoing |

## Technical considerations

- Reuse `gates-banner.sh` (build-skill) shape for the line; do not depend on
  build-skill at runtime — the banner reads only `~/Documents/PRDs/grand-loop/`.
- Timer and tick must not overlap `grand-loop-demand.timer` (23:20 local) or the
  hourly `claude-vibeloop-measure`; a `flock` on `state.lock` already exists — use it.
- No secrets; the banner reads files only.

## Migration / compatibility

Existing `state.json` without `last-success.json` reads as `never` (RED) until the
first successful tick; document in the banner text.

## Open questions

| question | owner | due |
|---|---|---|
| Max age 26 h vs 2 × period | Joe | at build (26 h assumed) |
| Factory law for "absence is failure" | Joe | before next scaffold |

## Acceptance criteria

1. P0 — Given the unit files installed on RedBaron, When `systemctl --user list-timers` runs, Then `grand-loop-tick.timer` is listed with a next run inside 24 h.
2. P0 — Given a `last-success.json` stamped 27 h ago and `GRAND_LOOP_MAX_AGE=26h`, When `bl_liveness` runs, Then it prints `stale` and exits 2.
3. P0 — Given `state.json` with `PREFLIGHT: running` stamped 40 min ago, When `bl_liveness` runs, Then it prints `stuck` and exits 2.
4. P0 — Given a stale state, When a new session starts on carbon, Then the SessionStart output contains one line starting `grand-loop:` with `RED` and the age.
5. P0 — Given `mcphost-deploy probe` exits 1 with two stderr lines, When the tick finishes, Then the ledger row contains `stderr_tail=` with both lines escaped and `state/last-failure.txt` holds them verbatim.
6. P0 — Given a demand read that writes an alarm row, When the service exits, Then its exit code is 1 and the journal line begins `alarm:`.
7. P0 — Given a successful tick, When it reaches DIGEST ok, Then `last-success.json` is written and the banner prints `OK` with age under 1 h.
8. P1 — Given a stale state on two consecutive banner reads in one UTC day, When the second read runs, Then exactly one alert is delivered (dedupe by date).
9. P1 — Given the fixed tick lands on RedBaron, When the next scheduled timer fires against prod, Then the ledger gains a row with `reached_measure=1` and the banner reads OK the following morning (proof: the row, not a fixture).
10. P2 — Given a RED state, When the daily note renders, Then `Open needs:` lists the stale instrument with its timestamp.
- iter_log: 2026-09-22T08:01:45.938406398+00:00 decision 21 answered: infra loop was the old binary + the systemd-run driver EACCES (both fixed/reverted 0.8.18); re-admit
