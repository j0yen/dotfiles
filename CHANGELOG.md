# Changelog

## 2026-09-12 — grand-loop-demand-cadence

`mcphost-deploy measure` (the command computing the grand loop's own metric,
`paid_mrr_usd`, plus `real_tenants`/`paying_tenants`/`real_wow_rate`/
`gross_churn`) shipped 2026-09-06 and had never been run unattended: the
five-hand-label validation gate deadlocks with itself while zero confirmed
real tenants exist to label. `grand-loop-demand.sh` (`.local/bin/`,
`.local/lib/grand-loop-demand-lib.sh`,
`.config/systemd/user/grand-loop-demand.{service,timer}`, installed by
`install.sh` like every other tool here, `grand-loop-demand.timer` firing
daily at 06:20 UTC) reads it once a day with `--allow-unvalidated` (every
number stamped `validated:false`) into a JSONL ledger inside a DEDICATED
clone of the PRDs repo (self-healing: absent → clone, diverged → fetch +
reset — never the operator's live `~/Documents/PRDs` checkout, which other
tools rebase/autostash mid-write). A failed read is an alarm row + a
journal line the same day, never a silent gap; two consecutive alarms
publish an `agorabus` event; a `real_tenants` movement from the previous
row's value publishes its own event carrying both values. One run per day
(a second same-day invocation exits 0, `skip: already ran`, no new row); a
push failure leaves the row local with a `push:"failed"` warning and the
next successful run's push carries it through. `mcphost-deploy` is resolved
once (PATH lookup, cached as an absolute path, `uv run` fallback against
the source repo) rather than trusted to a systemd unit's stripped PATH —
the recorded trap: `~/.local/bin` shadows `~/.cargo/bin` in units here.
Covered by `tests/demandcadence_ac{1..9}.test.sh` (test_prefix
`demandcadence`): the basic row + all named fields, alarm-row + 2-in-a-row
streak event, real_tenants 0→1 event + row marking, same-day skip, clone
self-heal (absent and diverged), push-failure-then-recovery, install's
directory creation + one live fire, the `demand` block present/absent, and
`status`'s one-screenful summary.

## 2026-09-12 — token-ledger-day-buckets

`token-ledger` moves into dotfiles (`.local/bin/token-ledger`,
`.config/systemd/user/token-ledger.{service,timer}`, installed by `install.sh`
like every other tool here) and its aggregation is rewritten around UTC-day
buckets instead of "everything since yesterday, labeled with today's date" —
the bug that made 09-12's status line read 81.0M (a 34-hour window) against a
true ~26.5M. Every record is bucketed by `date -u` of its OWN `timestamp`
(never run time); `message.id` dedup keeps the record with the latest
timestamp (its final cumulative usage); `ledger.tsv` is one row per day,
upserted atomically, columns `date per_model weighted status complete hosts
missing generated`. `today-summary.txt` (what the `token-ledger-banner.sh`
SessionStart hook cats verbatim) now reports yesterday, today-so-far, and a
linear forecast as three separate fields, plus which fleet hosts contributed
and which were unreachable (`hosts=carbon,redbaron missing=ryzen7`, never a
silent omission; a host that fails over ssh doesn't fail the run). `--day
YYYY-MM-DD` recomputes one day; `--check` validates the ledger against an
internal `message-index.tsv` companion file and catches a message
double-counted across two days. `--emit-local-records` is the same binary's
own remote-fetch mode — the orchestrator runs it over ssh on every other
fleet host instead of duplicating the extraction pipeline. Covered by
`tests/ledgerday_ac{1..8}.test.sh` (test_prefix `ledgerday`): day-boundary
isolation, rerun idempotency, dedup-keeps-final-usage, the summary format's
exact contract string, a fake-ssh-unreachable-host fixture, install.sh
symlink wiring, `--check` corruption detection, and a meta-test that the
whole ledgerday suite is green. `TOKEN_BUDGET_WEIGHTED` unset/0 (the
2026-09-12 default, daily cap removed) prints `budget off` instead of
OVER/UNDER.

## 2026-09-11 — vibeloop-measure-deploy-last-pass

`vibeloop-measure.sh`'s deploy-target selection now comes from `mcphost-deploy doctor`
(main/last_pass/deployed-sha/drift) instead of the script's own git-tag/HEAD heuristic and its
hand-rolled extend-gate/autobuilder gate check — the same canonical reckoning
`mcphost-deploy-refuse-ungated`'s `redeploy --sha ... --skip-if-ungated` already enforces at the
deploy boundary, now the single source of truth here too. When `last_pass` is ahead of `deployed`
the script builds and ships it (`redeploy --sha <last_pass> --skip-if-ungated`, journaling
`redeploy  target=last_pass sha=<sha>`); when they're equal, a red HEAD produces one clean
`redeploy  skipped  (cause=ungated sha=<head> deployed=<sha>)` line and the measurement phase still
runs — the old "GATE RED … not redeploying" branch (which never itself deployed anything, so ten
hours of a red main meant ten hours of skipped redeploys instead of the newest gated release ever
reaching prod) is gone. Every measure-cycle ledger line now carries `deploy_drift=<n|unknown>`
(`doctor`'s own drift count); `vibeloop-digest.sh` reads the ledger's own drift history and adds one
warning line when drift has been > 0 for 3+ consecutive cycles. New pure decision-logic functions
in `.local/lib/vibeloop-measure-guards.sh` — `doctor_parse`, `lastpass_target`,
`deploy_drift_field`, `drift_sustained` — are covered offline by `tests/lastpass_guards.test.sh`
(test_prefix `lastpass`) against fixture `doctor` output, no network/ssh/live mcphost-deploy
needed. Also fixed in the same change: `vibeloop-digest.sh` sourcing `vibeloop-measure-guards.sh`
via `$HOME/.local/lib/...` broke under any fixture `$HOME` (tests/vibeloop-digest.test.sh's own
isolated-HOME convention) — switched to a script-relative path, matching every other sourced lib in
this family.

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
