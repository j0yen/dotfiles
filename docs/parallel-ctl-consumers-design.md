# Parallel ctl consumers: design (parent A1296, extends A1299 director-event-consumer.py)

Base: dotfiles branch director-event-consumer (PR 316, local head e9917c1). New branch parallel-ctl-consumers. No new queue, framework or gateway: the same script, run by N consumer identities against one shared state dir and the canonical ledger (wm-asks).

## Current state (inspected)
- One global flock on `$STATE/lock` serializes every command, so two consumers cannot work at once.
- Claim worker name is `director-<event_id>` (same for every consumer), so two consumers racing one event both "win" the claim.
- `claim` carries no expected revision; event id for ready rows is `ready-<ask>-<rev>` but the rev is never rechecked at claim time.
- recover relaunches only when the unit is inactive (no timeout stealing already); provider outage counts as a launch failure and goes stuck after 2 attempts.
- No scope locks. Workers running now: ctl sessions only; no consumer installed or enabled (PR 316 unmerged).

## Changes
1. Consumer identity: `DIRECTOR_CONSUMER` (default `c0`). Worker name = `director-<eid>.<consumer>`; the ledger claim is the single source of ownership.
2. Atomic task+revision claim: read row (rev R) -> `asks claim <ask> --worker W --by hermes --expect-rev R`. Failure or a read-back whose claim is not W = `claim-conflict`, nothing launched. For `ready-<ask>-<rev>` events, a row whose current rev differs from the event rev = `revision-mismatch` (no claim, no launch; the new rev will arrive as its own ready event). Local pre-claim: `runs/<eid>.json` created with O_EXCL-style `runs/<eid>.owner` (consumer id) so two consumers never both enter the claim step for one event; loser records `duplicate`.
3. Parallelism: drop the global lock for work. Per-event flock `runs/<eid>.lock` around process/launch/recover of that event; a short `offset.lock` only around reading and advancing the log offset. Consumers on distinct events run concurrently. No cap on consumer count, runtime or turns.
4. Worker-liveness reconciliation (no timeouts): a claimed/launched run is touched by recover only when its unit is inactive AND no receipt AND no effect. If a non-empty `runs/<eid>.effect` exists (crash after effect, before receipt) recover writes the receipt (complete) and does not relaunch -> no duplicate effect. Crash before effect: relaunch under the same event id and claim (idempotent envelope). A healthy long worker (unit active) is never touched whatever its age.
5. Provider outage: launcher exit 75 (EX_TEMPFAIL) = `provider-outage`: claim kept, attempt not counted, state is a retry state, retried by recover; the owned task stays durable. Other launcher failures keep the 2-attempt stuck path.
6. Scoped locks: ask rows may carry `scope` (comma list, e.g. `live-settings`, `migration`, `promote:<target>`). Before launch the consumer takes `locks/<scope>.json` by exclusive create, content = owner eid. Held by another live event = state `scope-wait` (retry state), no claim made yet, independent tasks proceed. Lock released on complete or stuck. A lock whose owner run is terminal, missing, or whose unit is inactive with no live claim is reclaimed on the next pass (liveness, not timeout). Reads, code and reviews carry no scope and never wait.
7. Replay: all of the above is idempotent; unchanged state writes nothing, calls no model, writes no ledger rows.

## Out of scope
No install/enable, no HOLD.json, no accounts/model/spend caps, no TSV ledger, no Discord gateway. Account/model per executor is a launcher property (fable-launch.sh), recorded in the run record `consumer`/`launcher` fields only.

## Tests (fixtures only, stubs for wm-asks/launcher/hold/active)
two concurrent consumers on distinct tasks; same-task race = one owner and one launch; crash before effect = one relaunch, after effect = receipt without relaunch; outage keeps claim, no stuck, recovers; replay stable (no writes); healthy long worker untouched; revision mismatch; scope serialization while an independent task launches; scope reclaim after owner finishes.

## Fable xhigh review: APPROVE-WITH-EDITS (review.txt), amendments applied
1. Event read: write run record state `seen` + `.owner` (O_EXCL) BEFORE advancing the offset; recover reconciles `seen`. Test: crash after seen, crash after offset.
2. Worker name W persisted in the run record from the owner file; any holder of `runs/<eid>.lock` (flock dies with the process, so it is the consumer-liveness probe) continues any step under that W. Separate consumer-liveness locks dropped as redundant.
3. Exclusion unit is the ask: `asks/<ask>.lock` flock across read->claim->launch, plus a sibling-run scan; a newer event for an ask with a live sibling run or director-* claimant is retry state `ask-busy`, not terminal.
4. Rev event is a wake-up: re-read; still ready+unclaimed -> claim at current rev (`--expect-rev`), record rev; `revision-mismatch` terminal only when the row is no longer ready.
5. Scopes: sorted, all-or-nothing under one `locks/scope.flock`; content {eid, consumer}; reclaim only from a missing or terminal owner run (stricter than the review's liveness rule: an owned non-terminal task keeps its scope); released on complete and stuck.
6. Wake: complete/stuck/release run a retry sweep of waiter states; the timer cadence is a liveness poll, never a deadline.
7. Effect is a step ledger `runs/<eid>.effect` (append+fsync); recover auto-completes only when the terminal line `DONE` is present, else relaunch resumes past recorded steps. Worker outage: unit exits 75 or writes `runs/<eid>.outage` -> `provider-outage`, no attempt counted.
8. Units named `director-run-<eid>-a<N>`, `reset-failed` before relaunch, liveness by `systemctl show -p ActiveState` (active/activating/deactivating/reloading = live), checked only under the event lock.
