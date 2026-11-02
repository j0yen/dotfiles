#!/usr/bin/env python3
"""caps-drift.py: host-side read of every enforced_at value in the caps registry (P28 mechanism 3).

Stage 1 (amendment 5): REPORTS AND ALARMS ONLY. It never rewrites a host file.

For each registry row whose host column names this host, each enforced_at entry
(path[:line], optional host tag) is read from the host:
  live row (KEEP/CHECK/CHANGE): the numeric tokens of `value` must appear on the
      named line (any token; whole file when no line). Missing or unreadable file,
      missing line, or a value with no numeric token = UNKNOWN, never ok.
  retired row (VOID/DROP/DEAD): a file under a `.d/` drop-in directory that still
      exists = DRIFT; a named line that still carries a value token = DRIFT.
Rows whose enforced_at is not a host path (docs, "none", fleet/mcphost hosts) are not read.

Usage: caps-drift.sh [--registry caps.tsv] [--root DIR] [--home DIR] [--host NAME] [--status-json PATH] [--regen]
--regen (stage 2, A323): after the read, rewrite every file the generator manifest owns (caps-gen.py --write) instead of only reporting,
  then print `caps.regen rc=<n>`; the drift lines above still show what differed before the rewrite.
Output: DRIFT/UNKNOWN lines, then `caps.drift count=<n> first=<id>`.
--status-json merges {"caps":{"drift":{count,first,unknown,ts}}} into PATH atomically (tmp + rename).
"""
import datetime, importlib.util, json, os, re, socket, subprocess, sys

sys.dont_write_bytecode = True  # the loader below must not leave __pycache__ beside the script

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("caps_lint", os.path.join(HERE, "caps-lint.py"))
caps_lint = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(caps_lint)

LIVE = caps_lint.LIVE
RETIRED = {"VOID", "DROP", "DEAD"}
ALIAS = {"rb": "redbaron", "r7": "ryzen7"}
MACHINES = {"carbon", "redbaron", "ryzen7", "orch"}
DEFAULT_DIR = {"config.toml": "~/.config/wm-build", "limits.lock": "~/.config/wm-build"}
PATHLIKE = re.compile(r"^(~/|/|\.claude/|\.config/|\.local/|[\w@.\-]+\.(toml|lock|json|conf|timer|service|sh|tsv|py)\b|[\w\-]+(:\d|$))")


def norm_host(h):
    h = h.strip().lower()
    return ALIAS.get(h, h)


def row_hosts(hostcol):
    """Ordered machine hosts of a registry host column; 'all hosts' = every machine."""
    h = re.sub(r"\(.*?\)", "", hostcol).strip().lower()
    if h == "all hosts":
        return sorted(MACHINES)
    return [norm_host(x) for x in h.split(",") if norm_host(x) in MACHINES]


def parse_entries(row, hosts):
    """Yield (path_tmpl, {host: [lines]} or None for every host, host_filter or None)."""
    out, prev_dir, prev_base = [], None, None
    for seg in [s.strip() for s in row.get("enforced_at", "").split(" ; ") if s.strip()]:
        hostlines = {}
        m = re.match(r"^(\S+?)\s*\(((?:\s*\w+\s*:\d+\s*,?)+)\)\s*$", seg)  # limits.lock (r7 :6, orch :4)
        if m:
            seg = m.group(1)
            for hm in re.finditer(r"(\w+)\s*:(\d+)", m.group(2)):
                hostlines[norm_host(hm.group(1))] = [int(hm.group(2))]
        tag = None
        m = re.match(r"^(.*?)\s*\((\w+)\)\s*$", seg)  # path:95 (r7)
        if m:
            seg, tag = m.group(1), norm_host(m.group(2))
        path, loc = seg, ""
        m = re.match(r"^(.*?):([\d,/\-]+)$", seg)
        if m:
            path, loc = m.group(1), m.group(2)
        path = re.sub(r"\s*§.*$", "", path).strip()
        if not path:  # ":95 (r7)" inherits the previous file
            if prev_base is None:
                continue
            path = prev_base
        elif path.startswith("."):  # ".service:8" swaps the previous file's extension
            if prev_base is None:
                continue
            path = os.path.splitext(prev_base)[0] + path
        elif not PATHLIKE.match(path):
            continue
        if "/" not in path:  # bare file name
            base = prev_dir or DEFAULT_DIR.get(path)
            if base is None:
                out.append((path, None, tag, False))
                continue
            path = base + "/" + path
        elif not path.startswith(("~", "/")):
            path = "~/" + path
        prev_dir, prev_base = os.path.dirname(path), path
        if not hostlines and loc:
            parts = loc.split("/")
            if len(parts) > 1 and len(parts) == len(hosts) and all(re.fullmatch(r"\d+", p) for p in parts):
                hostlines = {h: [int(p)] for h, p in zip(hosts, parts)}
            else:
                lines = []
                for p in loc.split(","):
                    if "-" in p:
                        a, b = p.split("-", 1)
                        if a.isdigit() and b.isdigit():
                            lines += list(range(int(a), int(b) + 1))
                    elif p.isdigit():
                        lines.append(int(p))
                hostlines = {"*": lines} if lines else {}
        out.append((path, hostlines or None, tag, True))
    return out


def tokens(value):
    v = value.replace(",", "")
    return set(re.findall(r"\d+(?:\.\d+)?", v))


def has_token(text, toks):
    return any(re.search(r"(?<![\d.])" + re.escape(t) + r"(?![\d])", text) for t in toks)


def resolve(path, root, home):
    if path.startswith("~/"):
        return os.path.join(home, path[2:])
    return os.path.join(root, path.lstrip("/")) if root != "/" else path


def read_lines(p):
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            return f.read().split("\n"), None
    except OSError as e:
        return None, e.strerror or str(e)


def check(rows, host, root, home):
    drift, unknown = [], []
    for r in rows:
        hosts = row_hosts(r.get("host", ""))
        if host not in hosts:
            continue
        vd, rid, toks = r.get("verdict", ""), r.get("id", "?"), tokens(r.get("value", ""))
        for path, hostlines, tag, resolvable in parse_entries(r, hosts):
            if tag and tag != host:
                continue
            if not resolvable:
                unknown.append(f"UNKNOWN {rid} {host} {path} no directory known for this bare file name")
                continue
            full = resolve(path, root, home)
            lines = None
            if hostlines:
                lines = hostlines.get(host, hostlines.get("*"))
            where = path + (":" + ",".join(map(str, lines)) if lines else "")
            exists = os.path.exists(full)
            if vd in RETIRED:
                if not exists:
                    continue
                if "/" in path and ".d/" in path:
                    drift.append(f"DRIFT {rid} {host} {where} retired ({vd}) drop-in file is still present")
                    continue
                if not toks or not lines:
                    continue
                body, err = read_lines(full)
                if body is None:
                    unknown.append(f"UNKNOWN {rid} {host} {where} unreadable: {err}")
                    continue
                hit = [n for n in lines if 0 < n <= len(body) and has_token(body[n - 1], toks)]
                if hit:
                    drift.append(f"DRIFT {rid} {host} {where} retired ({vd}) value still on line {hit[0]}")
            elif vd in LIVE:
                body, err = read_lines(full)
                if body is None:
                    unknown.append(f"UNKNOWN {rid} {host} {where} unreadable: {err}")
                    continue
                if not toks:
                    unknown.append(f"UNKNOWN {rid} {host} {where} value '{r.get('value','')[:40]}' has no numeric token to compare")
                    continue
                if lines:
                    cand = [body[n - 1] for n in lines if 0 < n <= len(body)]
                    if not cand:
                        unknown.append(f"UNKNOWN {rid} {host} {where} line is past the end of the file ({len(body)} lines)")
                        continue
                    text = "\n".join(cand)
                else:
                    text = "\n".join(body)
                if not has_token(text, toks):
                    drift.append(f"DRIFT {rid} {host} {where} registry value '{r.get('value','')[:40]}' not found on the host")
    return drift, unknown


def merge_status(path, count, first, unknown):
    data = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            data = json.load(f)  # a corrupt file raises: never overwritten
        if not isinstance(data, dict):
            raise SystemExit(f"caps-drift: {path} is not a JSON object")
    caps = data.get("caps")
    if not isinstance(caps, dict):
        caps = data["caps"] = {}
    caps["drift"] = {"count": count, "first": first, "unknown": unknown,
                     "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1)
        f.write("\n")
    os.replace(tmp, path)


def main(argv):
    opt = {"--registry": None, "--root": "/", "--home": None, "--host": None, "--status-json": None}
    regen = "--regen" in argv
    argv = [a for a in argv if a != "--regen"]
    i = 0
    while i < len(argv):
        if argv[i] not in opt or i + 1 >= len(argv):
            print(__doc__.split("Usage:")[1].split("Output:")[0].strip(), file=sys.stderr)
            return 64
        opt[argv[i]] = argv[i + 1]
        i += 2
    root = opt["--root"]
    home = opt["--home"] or (os.path.expanduser("~") if root == "/" else os.path.join(root, os.path.expanduser("~").lstrip("/")))
    host = norm_host(opt["--host"] or socket.gethostname().split(".")[0])
    reg = opt["--registry"] or os.path.join(os.path.dirname(os.path.dirname(HERE)), ".config/fleet/caps.tsv")
    if not os.path.exists(reg):
        reg = os.path.expanduser("~/dotfiles/.config/fleet/caps.tsv")
    _, rows = caps_lint.parse(reg)
    drift, unknown = check(rows, host, root, home)
    for line in drift + unknown:
        print(line)
    first = drift[0].split()[1] if drift else "-"
    print(f"caps.unknown count={len(unknown)}")
    print(f"caps.drift count={len(drift)} first={first}")
    if opt["--status-json"]:
        merge_status(opt["--status-json"], len(drift), first, len(unknown))
    if regen:
        gen = os.path.join(HERE, "caps-gen.py")
        cmd = [sys.executable, "-I", gen, "--write", "--registry", reg, "--home", home, "--host", host]
        man = os.path.join(os.path.dirname(reg), "caps-gen.tsv")
        if os.path.exists(man):
            cmd += ["--manifest", man]
        rc = subprocess.run(cmd).returncode
        print(f"caps.regen rc={rc}")
        return rc
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
