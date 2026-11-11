#!/usr/bin/env bash
# fake curl for tests/carbon-alive-discord.test.sh (no network). Appends one line per call to $CA_CURL_LOG/calls,
# writes argv (one per line) to $CA_CURL_LOG/argv and stdin to $CA_CURL_LOG/stdin, records whether the -K config
# file holds a url line (cfg=url|cfg=none, the URL itself is not copied); stdin is also appended to $CA_CURL_LOG/all.
# Prints $CA_FAKE_HTTP (default 204) as the -w http_code, or with CA_FAKE_HTTP_SEQ="400 204 ..." the Nth code for the
# Nth call (the last one repeats); exits $CA_FAKE_CURL_RC (default 0).
log="${CA_CURL_LOG:?}"
echo call >> "$log/calls"
printf '%s\n' "$@" > "$log/argv"
cat > "$log/stdin"
{ cat "$log/stdin"; echo; } >> "$log/all"
k=""; prev=""
for a in "$@"; do [ "$prev" = -K ] && k="$a"; prev="$a"; done
if [ -n "$k" ] && grep -q '^url = "https://' "$k" 2>/dev/null; then echo cfg=url > "$log/cfg"; else echo cfg=none > "$log/cfg"; fi
code="${CA_FAKE_HTTP:-204}"
if [ -n "${CA_FAKE_HTTP_SEQ:-}" ]; then
  set -- $CA_FAKE_HTTP_SEQ; nth="$(wc -l < "$log/calls")"; [ "$nth" -gt "$#" ] && nth="$#"; eval "code=\${$nth}"
fi
printf '%s' "$code"
exit "${CA_FAKE_CURL_RC:-0}"
