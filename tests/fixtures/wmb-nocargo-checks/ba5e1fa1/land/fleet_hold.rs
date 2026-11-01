//! M2 of the run-1071 five-whys -- the fleet land hold, read by the daemon.
//!
//! Under hold #108 a run reserved a version, armed auto-merge and pushed a
//! tag because no land code read the fleet's hold flag. While
//! `[land] hold_file` exists, a run whose slug starts with one of
//! `[land] hold_prefixes` (the same `starts_with` match
//! `[daemon] max_runs_by_prefix` uses) does no land work at all:
//!
//!  * [`at_entry`] -- THE choke point. `land::run` / `land::run_train` call
//!    it before anything else (no squash, rebase, push or `gh` call runs
//!    while held), and `demote_stale_stages_on_resume` skips its fetch.
//!  * [`check`] / [`refuse`] -- the same test immediately before every
//!    irreversible substep (version reserve / re-reserve / backfill, every
//!    `gh pr merge`, every tag push), for a hold that appears mid-step.
//!  * [`tick`] -- the daemon's poll, before the resume pass.
//!
//! The land step exits `Verdict::Held` (step outcome `held`, cause
//! [`CAUSE`]), the shape `ci_main_red` already uses: the run stays open at
//! stage `land`, branch, worktree and PR kept, and the land row carries the
//! substep marker [`HELD`] (`land.pending`, detail = [`HeldRecord`], which
//! keeps whatever marker and detail the row had). `tick::resumable_runs`,
//! the slot counts, the train and the dead-unit finalizer skip a marked run
//! exactly as they skip `held-ci-main-red`; [`tick`] refreshes its `Lane:`
//! claim and, once the file is gone (or the prefix list no longer names
//! it), gives the row back as it was so the next resume continues where the
//! land stopped. An auto-merge armed before the hold appeared is journaled
//! here (`land-held-armed`) and disarmed by the step's own SA2 disarm in
//! `main.rs` (`land-step:held`), the one disarm path.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::stage::{self, Stage};
use super::{automerge, LandArgs, Verdict};
use crate::config::Config;
use crate::queue::Entry;
use crate::state::State;

/// `Verdict::Held.check` of a fleet-hold wait.
pub const CHECK: &str = "fleet-land-hold";
/// The step envelope's cause for it (and the daemon's reaction label).
pub const CAUSE: &str = "held-fleet-hold";
/// `land.pending` while the run waits on the hold file.
pub const HELD: &str = "held-fleet-hold";
/// One `land-held` journal row per run per substep per this many seconds.
const JOURNAL_EVERY_SECS: u64 = 3600;
/// A hold file older than this journals `land-held-stale` (and still holds).
const STALE_SECS: u64 = 24 * 3600;

/// `[land] hold_file` / `hold_prefixes`. `Default` is no file and no prefix:
/// the hold applies to no run (hermetic fixtures, the canary).
#[derive(Debug, Clone, Default)]
pub struct FleetHoldCfg {
    pub file: PathBuf,
    pub prefixes: Vec<String>,
}

pub fn from_config(cfg: &Config) -> FleetHoldCfg {
    FleetHoldCfg {
        file: cfg.land_hold_file.value.clone(),
        prefixes: cfg.land_hold_prefixes.value.clone(),
    }
}

/// Whether the hold applies to a run with this slug right now: the file
/// exists and the slug starts with one of the (non-empty) prefixes.
/// An existence check that errors for any reason but `NotFound` counts as
/// present (fails closed); [`hold`] journals `land-held-unreadable`.
pub fn applies(cfg: &FleetHoldCfg, slug: &str) -> bool {
    !cfg.file.as_os_str().is_empty()
        && cfg.prefixes.iter().any(|p| !p.is_empty() && slug.starts_with(p.as_str()))
        && probe(&cfg.file) != Ok(false)
}

/// `Ok(present)`; `Err(kind)` when the check itself failed (not `NotFound`).
fn probe(file: &Path) -> Result<bool, std::io::ErrorKind> {
    match std::fs::metadata(file) {
        Ok(_) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e.kind()),
    }
}

/// The marker's record (`land.detail` while `land.pending == HELD`).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct HeldRecord {
    pub file: String,
    pub since: String,
    #[serde(default)]
    pub last_claim_refresh: String,
    /// No land row existed when the hold marked the run: the release deletes
    /// the row it created instead of restoring one.
    #[serde(default)]
    pub created_row: bool,
    /// The row's `pending` / `detail` before the hold (an intent marker such
    /// as `tagged`, a `Prepared` JSON detail): put back on release.
    #[serde(default)]
    pub prior_pending: Option<String>,
    #[serde(default)]
    pub prior_detail: Option<String>,
}

/// A guard with no `Verdict` channel (`anyhow::Result<T>`) returns this;
/// `run_with_train` turns it back into the `Held` verdict.
#[derive(Debug)]
pub struct HeldError {
    pub substep: String,
    pub file: String,
}

impl std::fmt::Display for HeldError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "fleet land hold: {} not performed while {} exists", self.substep, self.file)
    }
}

impl std::error::Error for HeldError {}

/// The `Held` verdict a [`HeldError`] anywhere in `e`'s chain stands for.
pub fn verdict_of(e: &anyhow::Error) -> Option<Verdict> {
    e.chain()
        .find_map(|c| c.downcast_ref::<HeldError>())
        .map(|h| Verdict::Held { check: CHECK.to_string(), main_sha: h.file.clone() })
}

fn now() -> String {
    chrono::Utc::now().to_rfc3339()
}

fn ts_age_secs(ts: &str) -> i64 {
    chrono::DateTime::parse_from_rfc3339(ts)
        .map(|t| (chrono::Utc::now() - t.with_timezone(&chrono::Utc)).num_seconds())
        .unwrap_or(i64::MAX)
}

fn age_secs(file: &Path) -> Option<u64> {
    std::fs::metadata(file).and_then(|m| m.modified()).ok()?.elapsed().ok().map(|d| d.as_secs())
}

/// Open run ids whose land row carries the [`HELD`] marker (resume pass,
/// slot counts, train, finalizer).
pub fn marked_run_ids(state: &State) -> HashSet<i64> {
    let mut out = HashSet::new();
    let Ok(mut stmt) = state.conn().prepare(
        "SELECT r.id FROM runs r JOIN land l ON l.run_id = CAST(r.id AS TEXT) AND l.slug = r.slug \
         WHERE r.outcome IS NULL AND l.pending = ?1",
    ) else {
        return out;
    };
    if let Ok(rows) = stmt.query_map([HELD], |r| r.get::<_, i64>(0)) {
        out.extend(rows.filter_map(|r| r.ok()));
    }
    out
}

/// True while `run_id` (an open run) carries the [`HELD`] marker.
pub fn is_marked(state: &State, run_id: i64) -> bool {
    state
        .conn()
        .query_row(
            "SELECT 1 FROM land WHERE run_id = ?1 AND pending = ?2",
            rusqlite::params![run_id.to_string(), HELD],
            |_| Ok(()),
        )
        .is_ok()
}

/// The status field `land_held`: open runs carrying the marker, plus open
/// runs at stage `land` the hold applies to right now (not yet ticked).
pub fn held_run_ids(cfg: &FleetHoldCfg, state: &State) -> Vec<i64> {
    let mut out: Vec<i64> = marked_run_ids(state).into_iter().collect();
    if !cfg.prefixes.is_empty() && probe(&cfg.file) != Ok(false) {
        if let Ok(mut stmt) = state
            .conn()
            .prepare("SELECT id, slug FROM runs WHERE outcome IS NULL AND stage = 'land' ORDER BY id")
        {
            if let Ok(rows) = stmt.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))) {
                for (id, slug) in rows.filter_map(|r| r.ok()) {
                    if applies(cfg, &slug) && !out.contains(&id) {
                        out.push(id);
                    }
                }
            }
        }
    }
    out.sort_unstable();
    out
}

/// True when this run's `name` stamp file was written less than
/// `JOURNAL_EVERY_SECS` ago; when it was not, rewrites it (so the caller
/// journals).
fn recently_journaled(state: &State, run_id: &str, name: &str) -> bool {
    let dir = state.state_dir().join("fleet-land-hold");
    let stamp = dir.join(format!("{run_id}-{name}"));
    let fresh = std::fs::metadata(&stamp)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.elapsed().ok())
        .is_some_and(|age| age.as_secs() < JOURNAL_EVERY_SECS);
    if !fresh {
        let _ = std::fs::create_dir_all(&dir);
        let _ = std::fs::write(&stamp, "");
    }
    fresh
}

/// `land-held-stale`, at most once per run per hour, while the hold file is
/// older than 24 h. The hold keeps holding.
fn journal_if_stale(state: &State, slug: &str, run_id: &str, file: &Path) {
    if age_secs(file).is_some_and(|s| s > STALE_SECS) && !recently_journaled(state, run_id, "stale") {
        let file = file.display().to_string();
        let _ = state.journal(
            "land",
            "land-held-stale",
            &serde_json::json!({
                "slug": slug, "run_id": run_id, "file": file,
                "event": format!("land-held-stale run={run_id} file={file} older than 24h, still holding"),
            }),
        );
    }
}

/// Sets the [`HELD`] marker on the run's land row, keeping whatever marker
/// and detail it had in the record. A row already marked is left alone.
fn mark(state: &State, a: &LandArgs) -> anyhow::Result<()> {
    let row = stage::load(state, &a.slug, &a.run_id)?;
    if row.as_ref().and_then(|r| r.pending.as_deref()) == Some(HELD) {
        return Ok(());
    }
    let record = HeldRecord {
        file: a.fleet_hold.file.display().to_string(),
        since: now(),
        last_claim_refresh: now(),
        created_row: row.is_none(),
        prior_pending: row.as_ref().and_then(|r| r.pending.clone()),
        prior_detail: row.as_ref().and_then(|r| r.detail.clone()),
    };
    stage::mark_pending(state, &a.slug, &a.run_id, HELD, &serde_json::to_string(&record)?)
}

/// Gives the land row back as the hold found it (marker and detail
/// restored; a row the hold created is deleted) and journals
/// `land-hold-released reason=<reason>`. `Ok(false)` = the row carried no
/// [`HELD`] marker.
pub fn release(state: &State, slug: &str, run_id: &str, reason: &str) -> anyhow::Result<bool> {
    let Some(row) = stage::load(state, slug, run_id)? else {
        return Ok(false);
    };
    if row.pending.as_deref() != Some(HELD) {
        return Ok(false);
    }
    let record: HeldRecord = row.detail.as_deref().and_then(|d| serde_json::from_str(d).ok()).unwrap_or_default();
    if record.created_row && row.stage.is_empty() {
        state.conn().execute(
            "DELETE FROM land WHERE slug = ?1 AND run_id = ?2 AND pending = ?3",
            rusqlite::params![slug, run_id, HELD],
        )?;
    } else {
        state.conn().execute(
            "UPDATE land SET pending = ?1, detail = ?2, updated = ?3 WHERE slug = ?4 AND run_id = ?5 AND pending = ?6",
            rusqlite::params![record.prior_pending, record.prior_detail, now(), slug, run_id, HELD],
        )?;
    }
    state.journal(
        "land",
        "land-hold-released",
        &serde_json::json!({
            "slug": slug, "run_id": run_id, "reason": reason, "file": record.file,
            "since": record.since, "prior_pending": record.prior_pending,
            "event": format!("land-hold-released reason={reason}"),
        }),
    )?;
    Ok(true)
}

/// The test every guard shares. `None` = proceed. `Some(verdict)` = the
/// substep must NOT run: the run is marked [`HELD`] and the caller returns
/// the verdict, so the run waits in its current stage.
///
/// `substep` names what was not performed (`version-reserve`, `merge-arm`,
/// `tag`, ...); `at` is `land-entry` for the choke point, `substep`
/// otherwise; `pr_merged` / `armed` describe the PR so the journal says why
/// a hold at the tag point (PR already merged) or with an armed auto-merge
/// matters.
fn hold(state: &State, a: &LandArgs, substep: &str, at: &str, pr_merged: bool, armed: bool) -> Option<Verdict> {
    if !applies(&a.fleet_hold, &a.slug) {
        return None;
    }
    let file = a.fleet_hold.file.display().to_string();
    if armed {
        // Armed before the hold appeared and still unmerged. Journal only:
        // the land step's SA2 disarm (`main.rs`, `land-step:held`) takes the
        // arm back once this step returns `Held`.
        let _ = state.journal(
            "land",
            "land-held-armed",
            &serde_json::json!({
                "slug": a.slug, "run_id": a.run_id, "substep": substep, "file": file,
                "event": format!("land-held-armed run={} substep={substep} file={file}", a.run_id),
            }),
        );
    }
    if !recently_journaled(state, &a.run_id, substep) {
        let note = if pr_merged {
            "PR already merged; the tag waits for the hold file to go away"
        } else {
            "substep not performed; the land waits for the hold file to go away"
        };
        let _ = state.journal(
            "land",
            "land-held",
            &serde_json::json!({
                "slug": a.slug, "run_id": a.run_id, "reason": CAUSE, "substep": substep, "at": at,
                "file": file, "pr_merged": pr_merged, "note": note,
                "event": format!("land-held reason={CAUSE} substep={substep} at={at} file={file} pr_merged={pr_merged}"),
            }),
        );
    }
    if let Err(kind) = probe(&a.fleet_hold.file) {
        if !recently_journaled(state, &a.run_id, "unreadable") {
            let _ = state.journal(
                "land",
                "land-held-unreadable",
                &serde_json::json!({
                    "slug": a.slug, "run_id": a.run_id, "substep": substep, "file": file,
                    "error_kind": format!("{kind:?}"),
                    "event": format!("land-held-unreadable run={} substep={substep} file={file} kind={kind:?}, holding", a.run_id),
                }),
            );
        }
    }
    journal_if_stale(state, &a.slug, &a.run_id, &a.fleet_hold.file);
    if let Err(e) = mark(state, a) {
        let _ = state.journal(
            "land",
            "land-hold-mark-failed",
            &serde_json::json!({"slug": a.slug, "run_id": a.run_id, "error": e.to_string()}),
        );
    }
    Some(Verdict::Held { check: CHECK.to_string(), main_sha: file })
}

/// The guard immediately before an irreversible substep.
pub fn check(state: &State, a: &LandArgs, substep: &str, pr_merged: bool, armed: bool) -> Option<Verdict> {
    hold(state, a, substep, "substep", pr_merged, armed)
}

/// [`check`] for a caller whose only exit is `anyhow::Result`: `Err` carries
/// a [`HeldError`] that `run_with_train` turns into the `Held` verdict.
pub fn refuse(state: &State, a: &LandArgs, substep: &str) -> anyhow::Result<()> {
    match check(state, a, substep, false, false) {
        Some(_) => Err(HeldError { substep: substep.to_string(), file: a.fleet_hold.file.display().to_string() }.into()),
        None => Ok(()),
    }
}

/// The first irreversible substep a land row at this stage would reach.
fn next_substep(row: &Option<stage::LandRow>) -> &'static str {
    if !stage::reached(row, Stage::Versioned) {
        "version-reserve"
    } else if !stage::reached(row, Stage::Merged) {
        "merge-arm"
    } else {
        "tag"
    }
}

/// THE choke point, called by `land::run` / `land::run_train` before any
/// squash, rebase, push or `gh` call. Held: `Some(Held)`, nothing else runs
/// (an armed auto-merge is read from `armed.json`, no `gh`). Not held: a
/// marker a held tick left on the row is given back (an operator drive
/// after the file went away) and the land proceeds.
pub fn at_entry(state: &State, a: &LandArgs) -> Option<Verdict> {
    if !applies(&a.fleet_hold, &a.slug) {
        if let Err(e) = release(state, &a.slug, &a.run_id, "land-entry") {
            let _ = state.journal(
                "land",
                "land-hold-release-failed",
                &serde_json::json!({"slug": a.slug, "run_id": a.run_id, "error": e.to_string()}),
            );
        }
        return None;
    }
    let row = stage::load(state, &a.slug, &a.run_id).ok().flatten();
    let pr_merged = stage::reached(&row, Stage::Merged);
    let armed = !pr_merged && automerge::read_armed(state.state_dir(), &a.run_id).is_some();
    hold(state, a, next_substep(&row), "land-entry", pr_merged, armed)
}

/// The daemon's poll (one call per tick, before the resume pass): for every
/// open run carrying the [`HELD`] marker -- the hold no longer applies ->
/// [`release`] (the run is resumable this same tick); still held -> keep
/// the PRD's `Lane:` claim fresh and journal `land-held-stale` hourly.
pub fn tick(cfg: &Config, state: &State, entries: &[Entry]) {
    let fh = from_config(cfg);
    let rows: Vec<(String, i64, Option<String>)> = {
        let Ok(mut stmt) = state.conn().prepare(
            "SELECT r.slug, r.id, l.detail FROM runs r \
             JOIN land l ON l.run_id = CAST(r.id AS TEXT) AND l.slug = r.slug \
             WHERE r.outcome IS NULL AND l.pending = ?1 ORDER BY r.id",
        ) else {
            return;
        };
        let Ok(rows) = stmt.query_map([HELD], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))) else {
            return;
        };
        rows.filter_map(|r| r.ok()).collect()
    };
    for (slug, run_id, detail) in rows {
        let run_id_s = run_id.to_string();
        if !applies(&fh, &slug) {
            if let Err(e) = release(state, &slug, &run_id_s, "fleet-hold-cleared") {
                let _ = state.journal(
                    "land",
                    "land-hold-poll-error",
                    &serde_json::json!({"slug": slug, "run_id": run_id, "error": e.to_string()}),
                );
            }
            continue;
        }
        let mut record: HeldRecord = detail.as_deref().and_then(|d| serde_json::from_str(d).ok()).unwrap_or_default();
        if ts_age_secs(&record.last_claim_refresh) >= super::ci_main_red::CLAIM_REFRESH_SECS {
            if let Some(entry) = entries.iter().find(|e| e.slug == slug) {
                let _ = crate::daemon::claim::refresh(
                    state,
                    cfg,
                    &cfg.prd_dir.value,
                    &entry.path,
                    &slug,
                    run_id,
                    &crate::daemon::host_name(cfg),
                );
                record.last_claim_refresh = now();
                if let Ok(d) = serde_json::to_string(&record) {
                    let _ = state.conn().execute(
                        "UPDATE land SET detail = ?1, updated = ?2 WHERE slug = ?3 AND run_id = ?4 AND pending = ?5",
                        rusqlite::params![d, now(), slug, run_id_s, HELD],
                    );
                }
            }
        }
        journal_if_stale(state, &slug, &run_id_s, &fh.file);
    }
}
