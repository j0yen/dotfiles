// witness: verbatim journal call prefixes (regex match text) from wm-build ba5e1fa1 src/, one per OPERATOR_OPS entry
// src/daemon/pause.rs
fn w() { s.journal( "runs", "run-paused", x); }
// src/daemon/pause.rs
fn w() { s.journal( "runs", "run-pause-restamped", x); }
// src/daemon/pause.rs
fn w() { s.journal( "runs", "run-unpaused", x); }
// src/daemon/run_redrive.rs
fn w() { s.journal( "runs", "operator-stop", x); }
// src/daemon/run_redrive.rs
fn w() { s.journal( "runs", "unit-stopped", x); }
// src/daemon/run_redrive.rs
fn w() { s.journal("runs", "release-ungated", x); }
// src/daemon/run_redrive.rs
fn w() { s.journal("runs", "release-mem", x); }
// src/test_debt.rs
fn w() { s.journal("test_debt", "close", x); }
// src/daemon/run_close.rs
fn w() { s.journal( "runs", "alarm-close-released", x); }
// src/daemon/alarms.rs
fn w() { s.journal( "alarms", "alarm-closed", x); }
// src/daemon/run_redrive.rs
fn w() { s.journal( "runs", "operator-redrive", x); }
// src/daemon/run_redrive.rs
fn w() { s.journal( "runs", "redrive-forced", x); }
// src/daemon/run_redrive.rs
fn w() { s.journal( "runs", "redrive-refused", x); }
// src/daemon/run_redrive.rs
fn w() { s.journal( "runs", "redrive-refused-held", x); }
// src/daemon/run_redrive.rs
fn w() { s.journal( "runs", "redrive-resume-tagged", x); }
// src/daemon/run_redrive.rs
fn w() { s.journal( "runs", "redrive-wt-reset", x); }
// src/daemon/run_redrive.rs
fn w() { s.journal( "claims", "redrive-reclaim", x); }
// src/daemon/run_redrive.rs
fn w() { s.journal( "land", "redrive-land-row-reset", x); }
// src/daemon/run_redrive.rs
fn w() { s.journal( "land", "redrive-live-reset", x); }
// src/daemon/run_ship.rs
fn w() { s.journal( "runs", "hand-ship", x); }
// src/gate/cargo_jobs.rs
fn w() { s.journal( "builder", "cargo-jobs-released-by-hand", x); }
// src/daemon/hotfix.rs
fn w() { s.journal( "daemon", "hand-release-commit", x); }
// src/daemon/decision.rs
fn w() { s.journal( "decisions", "accepted", x); }
