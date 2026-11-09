#!/usr/bin/env bash
# carbon-alive-discord.sh — Discord webhook deliverer for carbon-alive.sh (A1446). Default deliverer when
# ~/.config/carbon-alive/deliver is absent and the webhook file exists.
#
# Usage: carbon-alive-discord.sh <kind> < alert.json   (the alert JSON line carbon-alive.sh writes)
# Webhook file: ${CARBON_ALIVE_WEBHOOK_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/carbon-alive/webhook.url}, same contract
# as the cloud watchdog's Discord delivery (orch/hub /opt/cloud-watchdog/cloudwatchdog/delivery.py): a regular file
# (not a symlink), mode exactly 0600, owned by the running uid, non-empty, at most 4096 bytes, URL starts with https://.
# Posts {"content": "<one-line summary + readings>"} (at most 2000 chars, truncated) with curl; the URL goes to curl in
# a 0600 temp config file (-K), never on an argv, and is never printed: curl's own stderr is discarded.
# Exit 0 only on HTTP 2xx (204 included); 2 = webhook file rejected or bad input; 1 = post failed.
set -u
kind="${1:-alert}"
wf="${CARBON_ALIVE_WEBHOOK_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/carbon-alive/webhook.url}"
alert="$(cat)"

umask 077
kf="$(mktemp)" || exit 1
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
import json, os, sys
try: a = json.loads(os.environ["CA_ALERT"])
except ValueError: sys.exit(2)
kind = os.environ["CA_KIND"]
rd = a.get("readings") or {}
text = (f"carbon-alive[{a.get('host', '?')}] {kind}: state={a.get('state', '?')} "
        f"outage_since={a.get('outage_since')} states={','.join(a.get('states') or [])} | "
        + " ".join(f"{k}={v}" for k, v in rd.items()))
text = " ".join(text.split())
if len(text) > 2000: text = text[:1999] + "…"
print(json.dumps({"content": text}))
PY
)" || exit 2

code="$(printf '%s' "$payload" | curl -sS --max-time 10 --proto =https -H 'Content-Type: application/json' \
  --data-binary @- -o /dev/null -w '%{http_code}' -K "$kf" 2>/dev/null)"; rc=$?
case "$code" in
  2??) [ "$rc" = 0 ] && exit 0 ;;
esac
echo "carbon-alive-discord: post failed (curl rc=$rc, http=${code:-none})" >&2
exit 1
