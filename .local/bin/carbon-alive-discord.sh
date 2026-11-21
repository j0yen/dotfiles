#!/usr/bin/env bash
# carbon-alive-discord.sh — Discord webhook deliverer for carbon-alive.sh (A1446). Default deliverer when
# ~/.config/carbon-alive/deliver is absent and the webhook file exists.
#
# Usage: carbon-alive-discord.sh <kind> < alert.json   (the alert JSON line carbon-alive.sh writes)
# Webhook file: ${CARBON_ALIVE_WEBHOOK_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/carbon-alive/webhook.url}, same contract
# as the cloud watchdog's Discord delivery (orch/hub /opt/cloud-watchdog/cloudwatchdog/delivery.py): a regular file
# (not a symlink), mode exactly 0600, owned by the running uid, non-empty, at most 4096 bytes, URL starts with https://.
# Posts {"content": "<at> [REPLAY <replay_at>] <one-line summary + readings>", "allowed_mentions": {"parse": []}} (content
# at most 2000 chars, truncated; the empty parse list means @everyone, @here and <@id> in the text ping nobody) with
# curl: the text starts with the alert's `at` time (UTC ISO) and, when carbon-alive.sh replays an entry an earlier run
# queued (`replay_at` set), the word REPLAY and the replay time, so an alert sent after a delivery outage never reads as
# current. The URL goes to curl in a 0600 temp config file (-K), never on an argv, and is never printed: curl's own
# stderr is discarded. The temp config is ${TMPDIR:-/tmp}/carbon-alive-discord.XXXXXXXXXX, removed on exit; since a
# SIGKILL (carbon-alive.sh's timeout -k) skips the EXIT trap, each start first removes files with that prefix owned by
# the running user in the same dir and older than 10 minutes.
# Exit 0 only on HTTP 2xx (204 included); 3 = HTTP 4xx other than 429 (rejected permanently: carbon-alive.sh moves the
# entry to outbox.dead.jsonl); 2 = webhook file rejected or bad input; 1 = post failed (retry).
set -u
kind="${1:-alert}"
wf="${CARBON_ALIVE_WEBHOOK_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/carbon-alive/webhook.url}"
alert="$(cat)"

umask 077
td="${TMPDIR:-/tmp}"
find "$td" -maxdepth 1 -type f -name 'carbon-alive-discord.*' -user "$(id -u)" -mmin +10 -delete 2>/dev/null
kf="$(mktemp "$td/carbon-alive-discord.XXXXXXXXXX")" || exit 1
trap 'rm -f "$kf"' EXIT

# Validate the webhook file and write the curl config; the URL stays inside this python process and $kf.
CA_WF="$wf" CA_KF="$kf" python3 -I - <<'PY' || exit 2
import os, re, stat, sys
wf, kf = os.environ["CA_WF"], os.environ["CA_KF"]
def no(why):
    print(f"carbon-alive-discord: webhook file rejected: {why}", file=sys.stderr); sys.exit(2)
try: s = os.lstat(wf)
except OSError: no("missing")
if not stat.S_ISREG(s.st_mode): no("not a regular file")
if stat.S_IMODE(s.st_mode) != 0o600: no(f"mode {stat.S_IMODE(s.st_mode):o}, want 600")
if s.st_uid != os.getuid(): no("not owned by the running user")
if s.st_size == 0 or s.st_size > 4096: no(f"size {s.st_size}, want 1..4096")
url = open(wf, encoding="utf-8", errors="replace").read().strip()
if not url.startswith("https://"): no("scheme is not https")
if not re.fullmatch(r"https://[!-~]+", url) or '"' in url or "\\" in url: no("unexpected characters")
with open(kf, "w") as f: f.write(f'url = "{url}"\n')
PY

payload="$(CA_ALERT="$alert" CA_KIND="$kind" python3 -I - <<'PY'
import json, os, sys, time
try: a = json.loads(os.environ["CA_ALERT"])
except ValueError: sys.exit(2)
kind = os.environ["CA_KIND"]
rd = a.get("readings") or {}
def iso(t):
    try: return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(t)))
    except (TypeError, ValueError, OverflowError, OSError): return "at=unknown"
head = iso(a.get("at")) + (f" REPLAY {iso(a['replay_at'])}" if a.get("replay_at") is not None else "")
text = (f"{head} carbon-alive[{a.get('host', '?')}] {kind}: state={a.get('state', '?')} "
        f"executor={a.get('executor', 'unknown')} "
        f"outage_since={a.get('outage_since')} states={','.join(a.get('states') or [])} | "
        + " ".join(f"{k}={v}" for k, v in rd.items())
        + ("" if not isinstance(a.get("previous"), dict)
           else " | previous: " + " ".join(f"{k}={v}" for k, v in a["previous"].items())))
text = " ".join(text.split())
if len(text) > 2000: text = text[:1999] + "…"
print(json.dumps({"content": text, "allowed_mentions": {"parse": []}}))
PY
)" || exit 2

code="$(printf '%s' "$payload" | curl -sS --max-time 10 --proto =https -H 'Content-Type: application/json' \
  --data-binary @- -o /dev/null -w '%{http_code}' -K "$kf" 2>/dev/null)"; rc=$?
case "$code" in
  2??) [ "$rc" = 0 ] && exit 0 ;;
  429) ;;
  4??) if [ "$rc" = 0 ]; then echo "carbon-alive-discord: post rejected permanently (http=$code)" >&2; exit 3; fi ;;
esac
echo "carbon-alive-discord: post failed (curl rc=$rc, http=${code:-none})" >&2
exit 1
