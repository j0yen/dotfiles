# Changelog

## 2026-09-06 — grand-loop-scaffold

The outer loop around `mcphost-deploy measure` (PRD-grand-loop-scaffold, depends on
PRD-grand-loop-measure): `.local/bin/grand-loop-tick.sh` runs PREFLIGHT (probes the hub's
`/healthz`, requires `db_ok`), MEASURE (`mcphost-deploy measure --host hub`, harness-prefix
exclusions from `grand-loop.env`), and DIGEST (one ledger line appended to
`~/Documents/PRDs/grand-loop/ledger.md`, plus the newest-dated `## Loop notes` line rewritten in
`~/Documents/PRDs/projects/grand-loop.md` for vibeloop's dream to read) every six hours via
`grand-loop.timer` (`OnCalendar=*-*-* 00,06,12,18:00 UTC`, `RandomizedDelaySec=300`,
`Persistent=true`) driving the oneshot `grand-loop.service`. A `state.lock` flock makes a second
concurrent tick exit 0 with `skip: tick running`; a `~/Documents/PRDs/grand-loop/STOP` file exits
0 with `skip: STOP` (a companion `MEASURE-OK` touch file still forces the measure through and is
consumed); `GRAND_LOOP_MAX_TICKS_PER_DAY` (default 4) caps ticks that reach MEASURE. Each cycle
resolves to exactly one failure family — `instrument`, `distribution`, `activation`,
`monetization`, `retention`, `discovery`, `growing`, or `flat` — evaluated against the ledger's own
history, and the loop note carries that family's standing instruction from `grand-loop.env`
verbatim. `grand-loop-status` prints the last tick's family, the last live `paid_mrr_usd` and
`real_tenants`, ticks today against the cap, STOP state, and the timer's next fire. P1 folds a
`## grand-loop` section (today's ledger lines + open needs) into vibeloop's daily digest page when
one exists for today, else a standalone `grand-loop/daily/<date>.md`. The offline
`tests/loop_ac{1..13}_*.test.sh` suite (13 files, fake `mcphost-deploy` on `PATH`) covers all P0/P1
ACs — basic tick, flock, STOP/MEASURE-OK, unvalidated measure, every family, the daily cap, the
tenant-accounting mismatch, loop-note replace-not-append, and the daily section — green offline in
~12s. AC12's live half (enabling `grand-loop.timer` and reading a real `systemctl --user
list-timers` next-fire time) is the PRD's own declared manual step, not a build side effect —
`deferred_acs: [12]`; the offline-testable half (status output shape, unit-file directives checked
statically) is covered by `tests/loop_ac12_status.test.sh`.

## 2026-09-06 — build-path-unit-overlap-exit0

`.local/bin/claude-build-headless.sh` (PRD-build-path-unit-overlap-exit0) no longer exits 1 for any
state it can reason about: `paused` file present, the work unit `active`/`activating`, `loaded`+`dead`
(freed via `stop`+`reset-failed`, or reported pinned by cgroup pids when freeing doesn't clear the
name), or a `systemd-run` failure of any other kind are now all exit 0 with one logged reason —
closing the `unit-start-limit-hit` five-strikes trap that needed three hand resets on 2026-09-05.
`claude-build.path` and `claude-build.service` both carry `StartLimitIntervalUSec=0` (service via
its existing pacing drop-in, path via new `claude-build.path.d/nolimit.conf`) so the limit can never
trip again even on a future launcher regression; the 300s `ExecStartPost` pacing and 400s
`TimeoutStartSec` are unchanged. P1 adds `.local/bin/claude-build-status` (path/work-unit states,
last 5 launcher log lines, pinned pids + comm names) and a bus `agent.activity` publish when the
launcher finds a pinned cgroup. All units, drop-ins, and the launcher are tracked here and installed
by `install.sh`; the offline `tests/buildpath_ac*.test.sh` suite (10 files) covers every state
transition against a faked `systemctl`/`systemd-run`, green in under 1s. P2 (retire
`claude-build.timer` once the path unit has run a clean week) stays open per the PRD's own gate.

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
