#!/usr/bin/env bash
# fake-alert-deliver.sh — stand-in for the build loop's alert-deliver.sh in
# tests/liveness_ac08_alert_dedupe.test.sh (PRD-grand-loop-liveness-contract
# Requirement 6). Records every invocation's arguments, one line per call,
# to $FAKE_ALERT_DELIVER_CALLS — mirrors the fake-agorabus convention — so a
# test can assert how many times an alert was actually delivered without a
# real alert-deliver.sh on PATH.
set -uo pipefail

calls_file="${FAKE_ALERT_DELIVER_CALLS:-/dev/null}"
printf '%s\n' "$*" >> "$calls_file"
exit 0
