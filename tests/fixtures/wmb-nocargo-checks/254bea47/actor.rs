//! ACT (0.77.78) -- operator-mutation journal rows name their actor.
//!
//! Evidence (ryzen7, 10-19 23:02Z): run 456 was paused `cause=operator` and its
//! step got an `operator-stop` eight seconds later, and nothing on either row
//! said WHO ran it -- the free-text `cause` was the only provenance. The actor
//! is now GENERATED where the row is written: [`crate::state::State::journal_at`]
//! (the one journal writer) adds `actor` to every row whose op is in
//! [`OPERATOR_OPS`] and that has no `actor` key yet (an explicit caller `actor`
//! wins). [`OPERATOR_OPS`] and [`NON_OPERATOR_OPS`] together are the closed set
//! of journal op literals in `src/`; `act_every_journal_op_is_classified`
//! fails on an op in neither list (or in both), so a new op cannot silently
//! skip the stamp.
//!
//! Every field is best effort: a failed read is `null`, nothing here panics or
//! blocks, `/proc/*/environ` is never read and no env var is dumped. `event`
//! strings are untouched (watchers grep them).
//!
//! Not covered by the drift scan: an op passed through a variable or a wrapper
//! (`journal_box`, `journal_builder`, `NetSquashOutcome::*_OP`, ...). None of
//! those is an operator mutation. Two call sites whose op is the generic
//! `update` (an alarm closed by hand, a decision closed/cordon-released by
//! hand) carry an explicit `actor` in their row instead.

use crate::env_reads::{env_read, EnvKey};
use serde_json::{json, Value};
use std::io::Read;
use std::path::Path;

/// Journal ops written by an operator mutation (CLI or daemon acting for one):
/// pause/unpause, operator-stop, redrive, release gates, run close, alarm
/// close, hand ship/hotfix/cargo-slot release, decision accept. The stamp is by
/// op alone (the table is not consulted).
pub const OPERATOR_OPS: &[&str] = &[
    "run-paused",
    "run-pause-restamped",
    "run-unpaused",
    "operator-stop",
    "unit-stopped",
    "release-ungated",
    "release-mem",
    "close",
    "alarm-close-released",
    "alarm-closed",
    "operator-redrive",
    "redrive-forced",
    "redrive-refused",
    "redrive-refused-held",
    "redrive-resume-tagged",
    "redrive-wt-reset",
    "redrive-reclaim",
    "redrive-land-row-reset",
    "redrive-live-reset",
    "hand-ship",
    "cargo-jobs-released-by-hand",
    "hand-release-commit",
    "accepted",
];

/// Every other journal op literal in `src/` (see the module docs). A new
/// op literal at a `State::journal` call belongs in exactly one of the two
/// lists; the drift test names the ones that are in neither.
pub const NON_OPERATOR_OPS: &[&str] = &[
    "abandon", "action", "active-lane-refresh-error", "add", "admission-mem", "admit-failed",
    "admit-rolled-back", "admit-skipped", "alarm-auto-closed", "alarm-classified",
    "alarm-raise-missing-subject", "already-running-process-detected", "attempt-not-counted", "attribution-trailer",
    "auth-missing", "auto-closed", "automerge-start-sweep", "base-cache-dedup",
    "base-cache-lock-timeout", "base-cache-lock-waited", "base-cache-skipped", "base-resolved",
    "base-sync-resolver-left-dirty", "belief-dedup", "binary-push-failed", "binary-pushed",
    "blocked", "box", "box-create-refused", "box-place-wait", "box-producers-killed",
    "box-tags-prune-failed", "box-tags-pruned", "box-unavailable", "branch-dead-tip-rescue-failed",
    "branch-foreign-head", "branch-foreign-head-dead", "branch-own-lane-missing",
    "branch-tip-archived", "brief-injected", "cache-evicted", "cache-sweep", "cache-sweep-refused",
    "cache-sweep-skipped", "canary-deferred", "canary-deploy-watch", "canary-error", "canary-green",
    "canary-refs-check", "canary-scheduled", "canary-skipped", "canary-start", "canary-tick-error",
    "canary-verdict", "candidate", "capacity-derived", "cargo-admission", "cargo-gate-reloaded",
    "cargo-jobs-arbitration-override", "cargo-jobs-reaped", "cargo-jobs-released",
    "cargo-jobs-step-adopted", "cargo-jobs-taken", "cargo-jobs-wait", "cargo-jobs-waiter-adopted",
    "cargo-jobs-waiter-reinserted", "cargo-jobs-waiter-starved", "cargo-rows-reaped",
    "cargo-shim-applied", "cargo-shim-failed", "cargo-slot-uncapped", "cargo-slot-wait",
    "changelog-heading-added", "changelog-sync-failed", "ci-backed-deferred", "ci-backed-disabled",
    "ci-backed-fallback", "ci-backed-no-slot", "ci-backed-shared-wait", "ci-classify-cache-hit",
    "ci-delta-pass", "ci-dispatch", "ci-draft-pr-ready", "ci-evidence-unavailable",
    "ci-failing-jobs", "ci-main-red-ended", "ci-merge-ref-ended", "ci-red-classified",
    "circuit-pending", "circuit-skip", "claim-lost", "claim-race-lost", "claim-reaped",
    "claim-release-skipped", "claim-ttl-skipped", "classify-legacy-tick-error", "closed",
    "closed-branch-kept", "code-loop", "coder-env", "coder-version-bump", "config-deprecated",
    "config-reloaded", "config-restart-required", "conflict-resolved", "continue-skipped",
    "continued", "daemon-pid-stale", "daemon-stop", "deadline-close-error",
    "decision-closed-readmit", "deferred", "delete", "delta-gate", "delta-rebased",
    "direct-build-branch", "direct-build-check-unavailable", "direct-build-policy-line",
    "direct-build-stale-claim", "direct-inner-no-box", "direct-pr-open", "direct-resumed",
    "direct-started", "down", "driver-adopted", "driver-spawned", "driver-unit-refreshed",
    "exec-precheck-refused", "expire-tick-error", "expired", "expiry-tick-error", "extend",
    "final-gate", "final-gate-before-merge", "final-gate-box", "final-gate-child-retry",
    "final-gate-cold-tree", "final-gate-inherited-receipts", "final-gate-nothing-to-rerun",
    "final-gate-receipts", "final-gate-resource", "final-gate-skipped-pr-merged",
    "final-gate-stale-receipts", "final-gate-tiers-applied", "finalize-dead-runs-error",
    "finalizer-skip", "finished", "flake-audit-baseline-flake", "flake-audit-result",
    "flake-escape", "flake-ledger-row", "flake-passes", "flake-quarantine-applied",
    "flake-quarantine-hit", "flake-quarantine-list", "flake-quarantine-stale",
    "flake-quarantine-unmatched", "fmt-sweep", "gate-aborted", "gate-admission-deferred",
    "gate-box-acquired", "gate-box-busy", "gate-cache-skip", "gate-deferred", "gate-finished",
    "gate-load-wait", "gate-prd-mirror-failed", "gate-prd-mirror-retry", "gate-prd-mirrored",
    "gate-prd-path-env-mirror-failed", "gate-prd-path-env-mirrored", "gate-prd-sync-leak-restored",
    "gate-preflight-wait", "gate-regen", "gate-regen-failed", "gate-resource", "gate-reused",
    "generated-commits-dropped", "generated-conflict-took-main", "generated-regen-moved-head",
    "git-ref-race-retry", "hand-step", "held-lane-refresh-error", "held-lane-refreshed", "hold",
    "host-cargo", "host-cargo-refused", "host-disk-reaped", "host-disk-skipped",
    "hotfix-scan-error", "infra-backoff-released", "infra-cache-dropped", "infra-loop",
    "inner-autocommit", "inner-base-sync", "inner-base-sync-conflicted", "inner-box",
    "inner-box-fallback", "inner-bump-reset", "inner-bump-reset-failed", "inner-bump-reset-skipped",
    "inner-commit-generated", "inner-final-leftovers", "inner-full-suite", "inner-lock-sync",
    "inner-profile", "inner-profile-missing", "inner-proof-env-baseline-live",
    "inner-proof-env-classified", "inner-proof-new-failures", "inner-receipt",
    "inner-receipt-discarded", "inner-refresh", "inner-refresh-baseline", "inner-regen",
    "inner-regen-failed", "inner-regen-skipped", "inner-repo-check", "inner-repo-checks",
    "inner-resume", "inner-test-nonhermetic-existing", "inner-test-quarantined", "insert",
    "intent-card-condensed", "land-admission-fenced", "land-admission-unfenced",
    "land-base-merge-linearized", "land-cargo-grant-waiting", "land-cargo-granted",
    "land-canary-tick-error", "land-ci-poll",
    "land-compile-grant-wait", "land-conflict-markers", "land-dropped-stranded-release",
    "land-enqueued", "land-generated-after-bump", "land-handed-to-driver", "land-held",
    "land-hold-capped", "land-hold-cleared", "land-hold-poll-error", "land-hold-released",
    "land-hold-resume", "land-precheck-failed", "land-precheck-ok", "land-push",
    "land-push-skipped", "land-queued", "land-ratelimit-wait", "land-refused",
    "land-required-checks", "land-rerebase-conflict", "land-squash-merge-history-failed",
    "land-squashed-merge-history", "land-stages-demoted", "land-stages-kept",
    "land-stray-extended-gates", "land-substep", "land-tag-guard-renamed", "land-tag-guard-skipped",
    "land-tag-rollback-skipped-remote", "land-tag-rolled-back", "land-tag-stale-replaced",
    "land-test-leftovers-committed", "landing-record-write-failed", "landing-record-written",
    "lane-acquired", "lane-foreign-kept", "lane-not-ours", "lane-release-deferred", "lane-released",
    "lint-rules-missing", "lint-rules-source", "live-ac-evidence-append-failed", "live-ac-none",
    "live-ac-park-failed", "live-ac-prd-defect", "live-ac-skipped", "live-ac-verdict",
    "live-chain-completed", "live-chain-ledger-unreadable", "live-chain-wait",
    "live-deferred-applied", "live-deferred-wait", "live-fail-code", "live-fail-effects-failed",
    "live-fail-health", "live-fail-health-paged", "live-fail-held", "live-fail-rollback",
    "live-fail-unarchive-failed", "live-fail-unarchived", "live-failed-cleared", "live-install",
    "live-install-deferred", "live-install-refused", "live-retry", "live-rollback",
    "live-rollback-refused", "live-step-accepted", "live-superseded", "live-verifier-exit",
    "live-verifier-silent-retry", "live_pending", "live_timeout", "load-threshold-source",
    "local-landed", "local-main-residue-reverted", "lock-autocommitted", "lock-refreshed",
    "lock-sync-failed", "lock-timeout", "lock-version-sync-failed", "lock-waited",
    "main-reconciled", "mem-wait", "merge-armed-after-gate", "merge-base-check", "merge-deferred",
    "merge-fallback-direct", "merge-rearmed-after-base-move", "merge-ref-contract-infra",
    "merge-ref-contract-red", "merge-ref-suites-green", "merge-ref-suites-none", "migrate",
    "migrated", "migration-collision-check-failed", "migration-collision-refused",
    "migration-renumbered", "nightly-skipped", "nightly-spawn", "nightly-spawn-error",
    "nightly-tick-error", "nightly-waiting", "no-receipt", "opened", "orphan-deleted",
    "orphan-released", "orphan-sweep-error", "paused", "pending", "placement-mode", "policy-loaded",
    "post-release-step-failed", "pr-dirty-detected", "pr-for-branch-ignored", "pr-head-reread",
    "pr-mergeable-unknown-wait", "pr-merged", "pr-ready-normalized", "pr-recheck-cap-reached",
    "prd-not-marked", "prd-path-conflict", "prd-path-strip", "prd-push-deferred",
    "prds-pull-failed", "pre-gate-ran", "predicate-sweep-error", "pregate-base-merge-conflict",
    "pregate-decision", "pregate-decision-held", "prev-block-injected", "probe-tick-error",
    "producer-finished", "producer-ordered", "producer-wall-budget", "producer-wall-override",
    "producer-where", "promote-tick-error", "promoted", "proof-env-cleared", "proof-env-ended",
    "proof-tmpdir", "proof-tmpdir-failed", "proof-tmpdir-reaped", "prov-write-failed", "prune-kept",
    "push-refused", "push-refused-restored", "push-refused-train-kept", "push-rejected-by-remote",
    "pushed-tip-adopted", "python-inner-on-orch", "python-on-orch-refused", "python-refresh",
    "python-route", "python-verify", "queue-dirty-recheck", "queue-merged", "queue-parked",
    "queue-poll-error", "queue-rearmed", "queue-wake", "quota-ended", "reaction",
    "reaction-exhausted", "reaction-skipped", "reactions-error", "reactions-tick-error",
    "readmit-from-land-failed", "readmit-no-gate-pass", "readmit-skipped", "reap",
    "reap-tick-error", "reaped", "rebase-abort-skipped", "rebase-at-arming", "rebase-before-push",
    "rebase-deferred", "rebase-work-lost", "receipt", "receipt-cache-restore", "receipt-cache-skip",
    "receipt-cache-store", "receipt-commit-normalized", "receipt-disagreement",
    "receipt-not-reused", "receipt-pass-done", "receipt-pass-revert", "receipt-pass-start",
    "receipt-rerun-exhausted", "receipt-rerun-skipped", "receipt-reused", "receipt-stale",
    "receipt-unreadable", "receipt-unreadable-result", "receipts-moved-aside", "recheck-main",
    "recheck-skip-cancelled", "reconcile-close-failed", "reconcile-skip", "reconcile-tick-error",
    "record-failed", "ref-auto-acquired", "refresh-proof-baseline-flake", "refused", "regen",
    "regen-commit", "regen-run", "regen-skipped", "regen-slot-wait", "release-bump-reapplied",
    "release-commit", "release-commit-drop-failed", "release-commit-dropped",
    "release-mem-reeval-error", "released", "repo-check-receipt-missing", "rereserved",
    "reservation-collides-tag", "reservation-origin-lease-lost", "reservation-origin-pruned",
    "reservation-origin-release-failed", "reservation-origin-released",
    "reservation-origin-swept-tagged", "reservation-origin-unreachable",
    "reservation-taken-on-origin", "reserve-exhausted", "reserve-retry", "resume-blocked",
    "resume-failed", "resumed-after-prose", "retry", "risk-gate-verdict", "rolled-back",
    "row-expired-no-rustc", "rowless-compile", "run-box-acquired", "run-box-fallback",
    "run-box-no-slot", "run-box-released", "run-created-by-operator", "run-ended", "run-finalized",
    "run-open", "run-reopened", "scaffold", "scaffold-error", "sccache-health", "schema",
    "scratch-reaped", "shim-rejected", "ship-checkout", "ship-refused", "skip", "squash-failed",
    "squash-for-rollback", "squash-guard-generated-exempt", "squash-reverts-main",
    "squash-reverts-main-held",
    "squash-tree-diverged-accepted", "squashed", "stage", "stage-demoted", "stage-regression",
    "stage-regression-allowed", "stale-local-tags-pruned", "stale-pregate-tag-removed",
    "stale-receipts-wiped", "stale-row", "start", "startup-phase", "step-binary-resolved",
    "superseded", "swap", "sync-blocked-disk", "sync-refused", "tag-already-at-sha",
    "tag-push-retry", "tag-pushed", "tag-same-step-skipped", "tag-sha-mismatch", "tagged", "taken",
    "test-canary-ran", "test-canary-scheduled", "test-canary-spawn-error", "test-canary-tick-error",
    "test-debt-closed", "test-debt-new", "test-ref", "tick", "tick-over-budget",
    "tmp-inodes-blocked", "tmpdir-orphan-reaped", "tmpdir-reaped", "train-dissolved-member-resumed",
    "train-final-gate", "train-final-gate-box", "train-held", "train-held-alive",
    "train-hold-error", "train-landed", "train-lead-conflict", "train-member-conflict-paths",
    "train-member-dropped", "train-member-merged-by-class", "train-member-pr-close-failed",
    "train-member-pr-closed", "train-member-pr-disarmed", "train-member-pr-error",
    "train-merge-fallback", "train-open-skipped", "train-opened", "train-reintegrated",
    "train-split", "train-target", "train-tick-error", "train-tip-abandoned", "unobservable",
    "untracked-config-ignored", "update", "verdict", "verdict-backfill", "verdict-backfill-error",
    "verdict-backfill-failed", "verdict-recorded", "verdict-write-failed", "verifier-auth-retry",
    "verifier-wrote", "verifier-wrote-ignored", "verify-prebuild", "version-commit-on-branch",
    "version-deferred-to-merge", "version-file-missing", "version-files-bumped",
    "version-files-reset", "version-files-reset-to-base", "version-floor-raised",
    "version-floor-unreadable", "version-from-manifest", "version-head-not-above-tag",
    "version-kept-across-rebase", "version-mismatch", "version-race", "version-reallocated",
    "version-rebased", "version-rebumped", "version-recomputed", "version-regression",
    "version-rereserved", "version-source", "version-stale-recomputed", "version-taken-on-main",
    "vo-sweep-error", "waiting-lane", "work-lost-merge-failed", "work-lost-merge-failed-ended",
    "work-lost-merged", "work-lost-skipped-generated", "worktree kept", "worktree-branch-kept",
    "worktree-cleaned", "worktree-dirty", "worktree-dirty-cleared", "worktree-recreated",
    "worktree-reuse", "worktree-target-link-failed", "worktree-target-linked", "wt-recreated",
];

/// True when a journal row with this op gets an `actor`.
pub fn stamps_actor(op: &str) -> bool {
    OPERATOR_OPS.contains(&op)
}

const ARGV_MAX_CHARS: usize = 200;
const PROC_READ_MAX: u64 = 16 * 1024;
const REDACTED: &str = "<redacted>";
/// A `--flag` whose name contains one of these has its value redacted.
const SENSITIVE_FLAG_PARTS: &[&str] = &["set", "token", "key", "secret", "pass", "auth", "env"];

/// The actor of the calling process, read from the real `/proc` and env.
pub fn actor_json() -> Value {
    actor_json_at(Path::new("/proc"), &env_read)
}

/// [`actor_json`] with the `/proc` root and the env lookup injected: reads
/// `<root>/self/{stat,cgroup,cmdline}` and `<root>/<ppid>/cmdline`.
pub fn actor_json_at(proc_root: &Path, env: &dyn Fn(EnvKey) -> Option<String>) -> Value {
    let stat = read_capped(&proc_root.join("self/stat")).and_then(|t| parse_stat(&t));
    let (pid, ppid) = match stat {
        Some((p, pp)) => (Some(p), Some(pp)),
        None => (None, None),
    };
    let unit = read_capped(&proc_root.join("self/cgroup")).and_then(|t| cgroup_unit(&t));
    let own = read_capped(&proc_root.join("self/cmdline")).map(|t| redacted_argv(&t));
    let parent = ppid.and_then(|p| read_capped(&proc_root.join(p.to_string()).join("cmdline")));
    let by = own.as_ref().and_then(|(tokens, _)| by_flag(tokens));
    json!({
        "pid": pid,
        "ppid": ppid,
        "unit": unit,
        "argv": own.map(|(_, line)| line),
        "parent_argv": parent.map(|t| redacted_argv(&t).1),
        "ssh_client": env(EnvKey::SshConnection).and_then(|v| ssh_client(&v)),
        "tmux_pane": env(EnvKey::TmuxPane).filter(|v| !v.is_empty()),
        "by": by,
    })
}

/// Reads at most `PROC_READ_MAX` bytes (lossy UTF-8); `None` on any failure.
fn read_capped(path: &Path) -> Option<String> {
    let mut buf = Vec::new();
    std::fs::File::open(path).ok()?.take(PROC_READ_MAX).read_to_end(&mut buf).ok()?;
    Some(String::from_utf8_lossy(&buf).into_owned())
}

/// `(pid, ppid)` of a `/proc/<pid>/stat` body. The comm field may hold spaces
/// and `)`, so pid is the text before the FIRST ` (` and the rest is parsed
/// after the LAST `)`: `<state> <ppid> ...`.
fn parse_stat(stat: &str) -> Option<(i64, i64)> {
    let pid = stat.split(" (").next()?.trim().parse().ok()?;
    let after = &stat[stat.rfind(')')? + 1..];
    let ppid = after.split_whitespace().nth(1)?.parse().ok()?;
    Some((pid, ppid))
}

/// The last `*.service|*.scope|*.timer` component of the cgroup-v2 (`0::`)
/// line. (`daemon::pressure::driver_cgroup_path` only accepts a
/// `wm-build-inner*` leaf and returns the whole path, so it does not fit.)
fn cgroup_unit(cgroup: &str) -> Option<String> {
    let path = cgroup.lines().find_map(|l| l.strip_prefix("0::"))?.trim();
    path.rsplit('/')
        .find(|c| [".service", ".scope", ".timer"].iter().any(|s| c.ends_with(s)))
        .map(str::to_string)
}

fn ssh_client(conn: &str) -> Option<String> {
    let mut it = conn.split_whitespace();
    let (ip, port) = (it.next()?, it.next()?);
    Some(format!("{ip} {port}"))
}

fn is_sensitive_flag(name: &str) -> bool {
    let n = name.to_ascii_lowercase();
    SENSITIVE_FLAG_PARTS.iter().any(|p| n.contains(p))
}

/// `NAME=VALUE` with an identifier-shaped NAME (an env-style assignment).
fn is_bare_assignment(tok: &str) -> bool {
    match tok.split_once('=') {
        Some((name, _)) => {
            !name.is_empty()
                && !name.starts_with('-')
                && name.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'))
        }
        None => false,
    }
}

/// Tokens of a NUL-separated cmdline body (an element holding spaces, such as
/// the script of `bash -c '...'`, is split too, so what it carries is redacted
/// the same way) with secrets replaced by `<redacted>`.
fn redact_tokens(cmdline: &str) -> Vec<String> {
    let raw: Vec<&str> = cmdline.split('\0').flat_map(|a| a.split_whitespace()).collect();
    let mut out = Vec::with_capacity(raw.len());
    let mut redact_next = false;
    for tok in raw {
        if redact_next {
            redact_next = false;
            out.push(REDACTED.to_string());
        } else if let Some(flag) = tok.strip_prefix("--") {
            match flag.split_once('=') {
                Some((name, _)) if is_sensitive_flag(name) => out.push(format!("--{name}={REDACTED}")),
                Some(_) => out.push(tok.to_string()),
                None => {
                    redact_next = is_sensitive_flag(flag);
                    out.push(tok.to_string());
                }
            }
        } else if is_bare_assignment(tok) {
            out.push(REDACTED.to_string());
        } else {
            out.push(tok.to_string());
        }
    }
    out
}

/// `(redacted tokens, the joined line truncated to 200 chars)`.
fn redacted_argv(cmdline: &str) -> (Vec<String>, String) {
    let tokens = redact_tokens(cmdline);
    let line: String = tokens.join(" ").chars().take(ARGV_MAX_CHARS).collect();
    (tokens, line)
}

/// The value of an existing `--by <who>` / `--by=<who>` flag.
fn by_flag(tokens: &[String]) -> Option<String> {
    let mut it = tokens.iter();
    while let Some(t) = it.next() {
        if t == "--by" {
            return it.next().cloned();
        }
        if let Some(v) = t.strip_prefix("--by=") {
            return Some(v.to_string());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{CliOverrides, Config};
    use crate::state::State;

    fn dir(tag: &str) -> std::path::PathBuf {
        crate::testtmp::unique(&format!("wm-build-act-{tag}"))
    }

    fn rows(state: &State, op: &str) -> Vec<Value> {
        state
            .journal_lines()
            .unwrap()
            .iter()
            .filter_map(|l| serde_json::from_str::<Value>(l).ok())
            .filter(|v| v["op"] == op)
            .collect()
    }

    fn cfg(state_dir: &Path) -> Config {
        Config::load(None, &CliOverrides { state_dir: Some(state_dir.to_path_buf()), ..Default::default() }, &[])
            .unwrap()
    }

    /// An open run (id 1) with no driver, so `pause` has nothing to stop.
    fn fixture(tag: &str) -> (Config, State) {
        let d = dir(tag);
        let state = State::open(&d).unwrap();
        state
            .conn()
            .execute(
                "INSERT INTO runs (id, slug, started, stage, attempt) VALUES (1, 'act-slug', ?1, 'inner', 1)",
                [crate::daemon::now_iso()],
            )
            .unwrap();
        (cfg(&d), state)
    }

    /// (a) `pause()` stamps the `run-paused` row with this process.
    #[test]
    fn act_pause_row_names_this_process() {
        let (cfg, state) = fixture("pause");
        crate::daemon::pause::pause(&cfg, &state, 1, "operator").unwrap();
        let r = rows(&state, "run-paused");
        assert_eq!(r.len(), 1, "{r:?}");
        let actor = &r[0]["row"]["actor"];
        assert_eq!(actor["pid"], u64::from(std::process::id()));
        assert!(actor["argv"].is_string(), "{actor}");
        assert_eq!(r[0]["row"]["event"], "run-paused run=1 slug=act-slug cause=operator");
    }

    /// (b) `mark_operator_stop` stamps the `operator-stop` row.
    #[test]
    fn act_operator_stop_row_has_actor() {
        let (_cfg, state) = fixture("stop");
        state
            .conn()
            .execute("INSERT INTO steps (run_id, kind, started) VALUES (1, 'inner', ?1)", [crate::daemon::now_iso()])
            .unwrap();
        assert_eq!(crate::daemon::run_redrive::mark_operator_stop(&state, 1, "wm-build-inner1-a").unwrap(), 1);
        let r = rows(&state, "operator-stop");
        assert_eq!(r.len(), 1, "{r:?}");
        assert!(r[0]["row"]["actor"]["pid"].is_u64(), "{r:?}");
    }

    /// Every two-string-literal journal call in `src/`, as `(op, file)`.
    /// Mirrors the one-line regex `\bjournal\s*\(\s*"[^"]*"\s*,\s*"([^"]*)"`.
    fn journal_op_literals() -> Vec<(String, String)> {
        fn walk(d: &Path, out: &mut Vec<std::path::PathBuf>) {
            for e in std::fs::read_dir(d).unwrap().flatten() {
                let p = e.path();
                if p.is_dir() {
                    walk(&p, out);
                } else if p.extension().is_some_and(|x| x == "rs") {
                    out.push(p);
                }
            }
        }
        fn quoted(s: &str) -> Option<(&str, &str)> {
            let s = s.trim_start().strip_prefix('"')?;
            let end = s.find('"')?;
            Some((&s[..end], &s[end + 1..]))
        }
        let mut files = Vec::new();
        walk(&Path::new(env!("CARGO_MANIFEST_DIR")).join("src"), &mut files);
        let mut found = Vec::new();
        for f in files {
            let text = std::fs::read_to_string(&f).unwrap();
            for (at, _) in text.match_indices("journal") {
                let word_before = text[..at].chars().next_back().is_some_and(|c| c.is_alphanumeric() || c == '_');
                if word_before {
                    continue;
                }
                let Some(rest) = text[at + "journal".len()..].trim_start().strip_prefix('(') else { continue };
                let Some((_table, rest)) = quoted(rest) else { continue };
                let Some(rest) = rest.trim_start().strip_prefix(',') else { continue };
                if let Some((op, _)) = quoted(rest) {
                    found.push((op.to_string(), f.display().to_string()));
                }
            }
        }
        found
    }

    /// (c) Drift: every journal op literal in `src/` is in exactly one list.
    #[test]
    fn act_every_journal_op_is_classified() {
        for op in OPERATOR_OPS {
            assert!(!NON_OPERATOR_OPS.contains(op), "`{op}` is in BOTH op lists");
        }
        let mut seen = std::collections::HashSet::new();
        for op in OPERATOR_OPS.iter().chain(NON_OPERATOR_OPS) {
            assert!(seen.insert(*op), "`{op}` is listed twice");
        }
        let found = journal_op_literals();
        assert!(found.len() > 500, "the scan found only {} literals", found.len());
        let unclassified: std::collections::BTreeSet<String> = found
            .iter()
            .filter(|(op, _)| !seen.contains(op.as_str()))
            .map(|(op, f)| format!("{op} ({f})"))
            .collect();
        assert!(
            unclassified.is_empty(),
            "journal ops in neither OPERATOR_OPS nor NON_OPERATOR_OPS (src/actor.rs): {unclassified:?}"
        );
        // An operator op that no source writes any more is a stale entry.
        for op in OPERATOR_OPS {
            assert!(found.iter().any(|(o, _)| o == op), "OPERATOR_OPS `{op}` has no journal literal in src/");
        }
    }

    /// (d) A non-operator op (a tick) gets no `actor` key.
    #[test]
    fn act_non_operator_op_gets_no_actor() {
        let state = State::open(&dir("tick")).unwrap();
        state.journal("daemon", "tick", &json!({"n": 1})).unwrap();
        let r = rows(&state, "tick");
        assert_eq!(r.len(), 1);
        assert!(r[0]["row"].get("actor").is_none(), "{r:?}");
    }

    /// (e) Nothing readable gives all-null fields; fake /proc files parse.
    #[test]
    fn act_actor_json_at_nulls_and_fake_proc() {
        let empty = dir("proc-empty");
        let v = actor_json_at(&empty, &|_| None);
        for k in ["pid", "ppid", "unit", "argv", "parent_argv", "ssh_client", "tmux_pane", "by"] {
            assert!(v[k].is_null(), "{k} in {v}");
        }
        let root = dir("proc-fake");
        std::fs::create_dir_all(root.join("self")).unwrap();
        std::fs::create_dir_all(root.join("77")).unwrap();
        // comm with a space and `)`; ppid is field 4.
        std::fs::write(root.join("self/stat"), "4242 (wm (build) x) S 77 4242 4242 0 -1 4194304\n").unwrap();
        std::fs::write(
            root.join("self/cgroup"),
            "0::/user.slice/user-1000.slice/user@1000.service/app.slice/r7-untagged-pause.service\n",
        )
        .unwrap();
        std::fs::write(root.join("self/cmdline"), b"wm-build\0run\0pause\x00456\0--by\0r7\0").unwrap();
        std::fs::write(root.join("77/cmdline"), b"/bin/bash\0/home/jsy/bin/r7-untagged-pause.sh\0").unwrap();
        let env = |k: EnvKey| match k {
            EnvKey::SshConnection => Some("10.0.0.5 51234 10.0.0.9 22".to_string()),
            EnvKey::TmuxPane => Some("%3".to_string()),
            _ => None,
        };
        let v = actor_json_at(&root, &env);
        assert_eq!(v["pid"], 4242);
        assert_eq!(v["ppid"], 77);
        assert_eq!(v["unit"], "r7-untagged-pause.service");
        assert_eq!(v["argv"], "wm-build run pause 456 --by r7");
        assert_eq!(v["parent_argv"], "/bin/bash /home/jsy/bin/r7-untagged-pause.sh");
        assert_eq!(v["ssh_client"], "10.0.0.5 51234");
        assert_eq!(v["tmux_pane"], "%3");
        assert_eq!(v["by"], "r7");
        // An empty TMUX_PANE is filtered; a malformed SSH_CONNECTION is None.
        let v = actor_json_at(&root, &|k| match k {
            EnvKey::TmuxPane => Some(String::new()),
            EnvKey::SshConnection => Some("onlyone".to_string()),
            _ => None,
        });
        assert!(v["tmux_pane"].is_null() && v["ssh_client"].is_null(), "{v}");
        // A session scope is the unit when no service sits below it.
        assert_eq!(cgroup_unit("0::/user.slice/user-1000.slice/session-5.scope\n").as_deref(), Some("session-5.scope"));
        assert_eq!(cgroup_unit("0::/init.scope\n").as_deref(), Some("init.scope"));
        assert_eq!(cgroup_unit("0::/\n"), None);
    }

    /// (f) Secret-bearing argv is redacted structurally; `--by` survives.
    #[test]
    fn act_argv_is_redacted() {
        let cmd = "wm-build\0run\0pause\x005\0--set\0gh_token=abc\0--by\0joe\0";
        let (tokens, line) = redacted_argv(cmd);
        assert!(line.contains(REDACTED) && !line.contains("abc"), "{line}");
        assert_eq!(by_flag(&tokens).as_deref(), Some("joe"));
        let (_, line) = redacted_argv("x\0--api-key=zzz\0--client-secret\0yyy\0TOKEN=www\0--cause\0fine\0");
        assert!(!line.contains("zzz") && !line.contains("yyy") && !line.contains("www"), "{line}");
        assert!(line.contains("--cause fine"), "{line}");
        // A script handed to `bash -c` is one argv element: still redacted.
        let (_, line) = redacted_argv("bash\0-c\0wm-build run pause 5 --set k=sekrit --by joe\0");
        assert!(!line.contains("sekrit") && line.contains("--by joe"), "{line}");
        // Truncated to 200 chars on a char boundary.
        let long = format!("wm-build\0{}", "é".repeat(500));
        assert_eq!(redacted_argv(&long).1.chars().count(), ARGV_MAX_CHARS);
        assert_eq!(by_flag(&redact_tokens("a\0--by=me\0")).as_deref(), Some("me"));
    }

    /// (g) A row with its own `actor` keeps it.
    #[test]
    fn act_explicit_actor_wins() {
        let state = State::open(&dir("explicit")).unwrap();
        state.journal("runs", "run-paused", &json!({"run_id": 9, "actor": {"by": "caller"}})).unwrap();
        let r = rows(&state, "run-paused");
        assert_eq!(r[0]["row"]["actor"], json!({"by": "caller"}));
    }

    /// The two by-hand `update` closes carry an explicit actor.
    #[test]
    fn act_alarm_and_decision_closes_carry_actor() {
        let (cfg, mut state) = fixture("closes");
        let did = crate::daemon::decision::open(&state, "q", None).unwrap();
        crate::daemon::decision::close(&cfg, &mut state, did, "a").unwrap();
        state
            .conn()
            .execute("INSERT INTO alarms (id, channel, opened) VALUES (5, 'canary', ?1)", [crate::daemon::now_iso()])
            .unwrap();
        crate::daemon::alarms::close(&cfg, &state, 5).unwrap();
        let updates = rows(&state, "update");
        let closed_decision = updates.iter().find(|r| r["table"] == "decisions" && r["row"]["closed"] == true);
        assert!(closed_decision.is_some_and(|r| r["row"]["actor"]["pid"].is_u64()), "{updates:?}");
        let closed_alarm = updates.iter().find(|r| r["table"] == "alarms" && r["row"]["id"] == 5);
        assert!(closed_alarm.is_some_and(|r| r["row"]["actor"]["pid"].is_u64()), "{updates:?}");
    }
}
