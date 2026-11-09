#!/usr/bin/env bash
# fake curl for tests/carbon-alive-discord.test.sh (no network). Appends one line per call to $CA_CURL_LOG/calls,
# writes argv (one per line) to $CA_CURL_LOG/argv and stdin to $CA_CURL_LOG/stdin, records whether the -K config
# file holds a url line (cfg=url|cfg=none, the URL itself is not copied). Prints $CA_FAKE_HTTP (default 204) as the
# -w http_code; exits $CA_FAKE_CURL_RC (default 0).
log="${CA_CURL_LOG:?}"
echo call >> "$log/calls"
printf '%s\n' "$@" > "$log/argv"
cat > "$log/stdin"
k=""; prev=""
for a in "$@"; do [ "$prev" = -K ] && k="$a"; prev="$a"; done
if [ -n "$k" ] && grep -q '^url = "https://' "$k" 2>/dev/null; then echo cfg=url > "$log/cfg"; else echo cfg=none > "$log/cfg"; fi
printf '%s' "${CA_FAKE_HTTP:-204}"
exit "${CA_FAKE_CURL_RC:-0}"
