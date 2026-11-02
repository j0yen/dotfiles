"""Parser half of merge-verdict-grammar.sh: the patterns come from the environment that file exports (MVG_*), never from a copy here.
parse_ex(what) -> (reason, data): reason "" and data (owner, name, pr, commit, agent_token) on success; otherwise reason is
  prefix  - not the canonical machine prefix (no word, no owner/name#pr)           -> rb-merge pre-gate-error
  commit  - prefix ok but the COMMIT token is not one full lowercase 40-hex sha     -> rb-merge head-mismatch
  agent   - no single agent=verifier:<agent>-verifier-<name>                        -> rb-merge suite-unknown
CLI: `python3 -I merge_verdict_grammar.py parse` reads `what` on stdin."""
import os
import re
import sys


def _env(k):
    v = os.environ.get(k)
    if not v:
        raise RuntimeError("merge-verdict-grammar.sh not sourced: %s unset" % k)
    return v


def parse_ex(what):
    word, ref, full = _env("MVG_WORD"), _env("MVG_REF_RE"), _env("MVG_RE")
    if not re.match("^" + re.escape(word) + " " + ref + " ", what):
        return "prefix", "no `%s <owner>/<name>#<pr> ` prefix at byte 0 of line 1" % word
    n = len(re.findall(_env("MVG_COMMIT_COUNT_RE"), what, re.M))
    m = re.match(full, what)
    if n != 1 or not m:
        return "commit", "the row's what must hold exactly one COMMIT=<40 lowercase hex> right after the ref (found %d)" % n
    agents = [x.group(2) for x in re.finditer(_env("MVG_AGENT_RE"), what, re.M)]
    if len(agents) != 1 or len(re.findall(_env("MVG_AGENT_COUNT_RE"), what, re.M)) != 1:
        return "agent", "the row's what names no single agent=verifier:<agent>-verifier-<name> (found %d)" % len(agents)
    return "", (m.group(1), m.group(2), m.group(3), m.group(4), agents[0])


def parse(what):
    """(owner, name, pr, commit, agent_token) or None."""
    r, d = parse_ex(what if isinstance(what, str) else "")
    return None if r else d


if __name__ == "__main__":
    if sys.argv[1:] != ["parse"]:
        sys.exit("usage: merge_verdict_grammar.py parse < what")
    r, d = parse_ex(sys.stdin.read())
    if r:
        sys.stderr.write("REFUSE %s %s\n" % (r, d))
        sys.exit(1)
    print(" ".join(d))
