# Changelog

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
