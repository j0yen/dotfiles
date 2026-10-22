# watcher-premise.spec -- ONE source of the shared lib's names, status columns, exit codes and WRITE-VERB LIST.
# Read by: lib/watcher-premise.sh (tests/lib.sh checks its WP_STATUS_COLS against [status_columns]) and by
# tests/emit-coverage.sh (the emit-coverage check is GENERATED from [write_verbs] -- edit the verb list HERE, nowhere else).
# Sections start with "[name]"; data lines are TAB-separated; "#" lines are comments. (Fable E7/E8/E9)

[names]
# function	signature	meaning
wp_arm	NAME PREMISE_CMD EXPIRES_ISO [PREMISE_TEXT]	declare the watcher's premise; NAME = the unit basename (the by= tag and the status file key off it)
wp_gate		0 = writes allowed, 1 = disarmed (GONE, past EXPIRES, or not armed); overwrites the one-line status file; logs only on a change
wp_emit_write	KIND TARGET WHAT EVIDENCE REVERSE	append the decision row to the local outbox FIRST, then wm-decide record where present; rc 1 = outbox append failed = BLOCK the write
wp_by		(none)	prints the by= tag: joe-<YYYYMMDD>+<watcher>  (limits-guard accepts any --by starting with joe-)
wp_selftest		throwaway-HOME scenarios of the lib itself; prints "selftest ok N/N"
wp_decide_record	LINE_JSON	build and run `wm-decide record` from one outbox line (used by wp_emit_write and by the outbox puller)

[status_columns]
# ONE line, tab-separated, overwritten on every wp_gate (E9). File: $WP_STATE/<NAME>.tsv
name	host	premise	verdict	expires	armed	last_write	checked_ts	unknown_since	defect	reason

[verdicts]
# PREMISE_CMD exit code -> verdict (E3). Timeout (rc 124) and any other rc are UNKNOWN.
0	HOLDS
1	GONE
other	UNKNOWN

[armed_rule]
# armed=1 iff the lib is correctly armed AND verdict != GONE AND now <= EXPIRES.  UNKNOWN stays armed (E3) until it passes EXPIRES.
# defect (status column): expired | unknown>60m | misconfigured | - (none)

[exit_codes]
# command	rc	meaning
wp_gate	0	writes allowed
wp_gate	1	disarmed: do not write
wp_emit_write	0	outbox line appended (wm-decide may or may not have recorded it; the write proceeds either way)
wp_emit_write	1	outbox append FAILED: BLOCK the write
wp_selftest	0	all scenarios passed
wp_selftest	1	a scenario failed
watcher-outbox-pull.sh	0	pass finished (an unreachable host or a held line is NOT an error; it shows in lag.tsv)
watcher-outbox-pull.sh	2	unusable configuration

[outbox]
# $WP_STATE = ~/.local/state/watcher-premise on the WRITING host (carbon included).
# File: $WP_STATE/outbox-YYYYMMDD.jsonl (writer's local date), append-only, never truncated (E5).
# Row (ev=write):    id ts epoch host watcher pid unit kind target what evidence reverse by premise verdict expires decide owner
#   decide = attempt (wm-decide was on PATH when written) | none
# Row (ev=recorded): ts epoch host watcher id   -- appended by the writer after wm-decide record succeeded
# Carbon adds ingested_ts to its inbox copy (E2); the writer's ts is the row ts.
# The puller keeps TWO cursors per host: pull (transport, always advances once a line is stored) and record
# (advances only past a line wm-decide accepted: a rejected line stays buffered, E5).

[decide]
# wm-decide record --agent <owner seat r7|rb> --via <watcher> --model none --kind <decide_kind> --what <what> --why <why>
#   --evidence <evidence> --reverse-text <reverse> --target <target> --tag by=<by> --tag wp-id=<id> --tag wp-kind=<kind> --tag host=<host>
# --agent is pattern-restricted by wm-decide (^(rb|r7|controller|joe|fable-regrader|coder:...)$), so the watcher is in --via and the by= tag.
decide_kind	guard
owner_default	r7

[write_verbs]
# THE WRITE-VERB LIST (E8). One verb per line: id<TAB>argv signature (space-separated tokens; the command word may be a path).
# The emit-coverage test (tests/emit-coverage.sh) finds each verb as a command (also behind `ssh host '...'`, `bash -c '...'`,
# `python3 -c '...'` and through shell variables holding the command) and fails unless the site sits inside a
# `wp_gate && ... && wp_emit_write` chain (or an `if wp_gate && ... wp_emit_write ...; then ... fi` block).
# Beyond E8's list (each is a write the watchers also make): run unpause, the r7-unpause-run.sh wrapper, curl -X DELETE (Hetzner API).
limits-guard-set	wm-build-limits-guard set
run-pause	wm-build run pause
run-redrive	wm-build run redrive
run-close	wm-build run close
run-unpause	wm-build run unpause
unpause-wrapper	r7-unpause-run.sh
cordon	wm-build cordon
gh-pr-merge	gh pr merge
kill	kill
pkill	pkill
killall	killall
hcloud-server-delete	hcloud server delete
curl-delete	curl -X DELETE
