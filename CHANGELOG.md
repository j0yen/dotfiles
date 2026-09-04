# Changelog

## 2026-09-04 — vibeloop-daily-digest test coverage

`tests/vibeloop-digest.test.sh` for PRD-vibeloop-daily-digest's `.local/bin/vibeloop-digest.sh`
(already committed, functionally verified end-to-end, but with no test coverage): runs the real
script against fixture ledgers under an isolated `$HOME`/`DREAM_PRD_DIR`, with `curl` and `nats`
shadowed so no real network call (hub `/healthz`, ntfy.sh, NATS) ever fires. Covers all 7 P0/P1
ACs — section presence/order with Needs-you first, STOP/MEASURE-STOP surfacing plus the
path-scoped commit, the `vibeloop-ctl digest`/`--today` wrapper, ntfy+NATS notification on
`NTFY_TOPIC`, graceful "not available" rendering when every optional input is missing, source
paths alongside every number, and the Monday weekly roll-up. Writing the day-totals fixture
surfaced a genuine bug: the Spend section's day total/breakdown always read `$0.00` because
`lines_for_date()` compared each raw `cost-ledger.jsonl` line's first 10 characters to the date,
but those lines are JSON (`{"ts": "..."`) rather than timestamp-first text — fixed by reading the
date out of the parsed `ts` field instead; 71/71 assertions now pass.

## 2026-09-04 — mcphost-measure-guards

Two guards for the deploy->measure job (PRD-mcphost-measure-guards, `.local/lib/vibeloop-measure-guards.sh`,
wired into `.local/bin/vibeloop-measure.sh`). After every run finishes (truth or proxy tier,
success or failure), `cleanup_tenants()` deletes the `panel_`/`probe-` tenants that run created
via `admin.tenant_delete_by_prefix` (dry_run=false), re-reads `/healthz`, and appends
`cleanup=<n> tenants_after=<n>` to the measure ledger line — a cleanup failure never fails the
run. Before any truth-tier spend, `run_proxy_gate()` runs `synthorg consume --tier proxy`
against the freshly redeployed endpoint; if zero segments bootstrap it writes
`proxy=0/<n> truth=skipped`, publishes a `proxy-failed` NATS event, and returns before the
harness probe or truth tier starts, so a broken bootstrap path is caught within one measure-job
tick instead of hiding for up to a day. `vibeloop-ctl measure` surfaces both: inline
`proxy=`/`cleanup=` fields on each ledger line and a separate `last proxy:` summary line.
