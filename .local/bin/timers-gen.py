#!/usr/bin/env python3
"""timers-gen: generate .config/fleet/timers.tsv, the registry of fleet user units (hermes-handover 2.5).

One row per .service/.timer file in .config/systemd/user (template units listed once, by file name).
Columns: unit class owner hold_gated enabled
  class      alarm | launching | mechanical  (explicit table below; ExecStart that starts `claude` also = launching)
  owner      hermes for launching, fleet otherwise
  hold_gated yes  = a 99-joe-quota-conservation.conf drop-in exists for the unit in the repo, or its ExecStart script holds hold-gate.sh
             exempt = launching unit that must keep running under the quota hold (HOLD_EXEMPT, with the reason)
             no   = neither
  enabled    yes when the unit file has an [Install] section

  timers-gen.py            write the TSV
  timers-gen.py --stdout   print the generated TSV
  timers-gen.py --check    exit 1 with a diff when the committed TSV differs from the generated one
Env: TIMERS_ROOT (repo root, default = parent of .local/bin; tests point it at a copy).
"""
import difflib, fnmatch, os, re, sys

# basename (no .service/.timer) -> class; first match wins, patterns are fnmatch
LAUNCHING = ["seat-tick@", "aide-wake", "fleet-merge", "hand-pr-land-driver", "grand-loop-demand",
             "aide-account-follow", "swarm-decide-regrade", "rb-manual-train", "seat-floor-probe", "ctl-dispatch"]
ALARM = ["fleet-dash*", "fleet-token-429-watch", "swarm-decide-merge-audit", "seat-ask-due", "premise-check", "*-alarm*"]
# units whose script only mentions `claude` in text (failure notifier), never launches it
MECHANICAL = ["seat-tick-failed@"]
# launching units the quota hold must not stop: the aide answers Joe and keeps the books under the hold
HOLD_EXEMPT = {"aide-wake": "aide runs under the hold (books + Joe answers)",
               "aide-account-follow": "aide account switch must follow the fleet account under the hold"}
DROPIN = "99-joe-quota-conservation.conf"
HEADER = "unit\tclass\towner\thold_gated\tenabled\n"
CLAUDE_RE = re.compile(r"(^|[\s;&|(])(exec\s+)?claude\s+(-p\b|--print|--model|--resume|--settings)", re.M)

root = os.environ.get("TIMERS_ROOT") or os.path.abspath(os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", ".."))
udir = os.path.join(root, ".config", "systemd", "user")


def base(unit):
    return unit.rsplit(".", 1)[0]


def exec_script(text):
    m = re.search(r"^ExecStart=[-@:+!]*(\S+)", text, re.M)
    if not m:
        return None
    p = m.group(1).replace("%h/", "").replace("$HOME/", "").replace("~/", "")
    if p.startswith("/"):
        return None
    f = os.path.join(root, p)
    return f if os.path.isfile(f) else None


def read(p):
    try:
        return open(p, errors="replace").read()
    except OSError:
        return ""


def row(unit):
    text = read(os.path.join(udir, unit))
    b = base(unit)
    script = exec_script(text)
    stext = read(script) if script else ""
    if b in LAUNCHING or any(fnmatch.fnmatch(b, g) for g in LAUNCHING if "*" in g):
        cls = "launching"
    elif b in MECHANICAL:
        cls = "mechanical"
    elif any(fnmatch.fnmatch(b, g) for g in ALARM):
        cls = "alarm"
    elif CLAUDE_RE.search(stext):
        cls = "launching"
    else:
        cls = "mechanical"
    owner = "hermes" if cls == "launching" else "fleet"
    if os.path.isfile(os.path.join(udir, unit + ".d", DROPIN)) or "hold-gate.sh" in stext:
        gated = "yes"
    elif cls == "launching" and b in HOLD_EXEMPT:
        gated = "exempt"
    else:
        gated = "no"
    enabled = "yes" if re.search(r"^\[Install\]", text, re.M) else "no"
    return "\t".join([unit, cls, owner, gated, enabled]) + "\n"


def generate():
    units = sorted(u for u in os.listdir(udir) if u.endswith((".service", ".timer")) and os.path.isfile(os.path.join(udir, u)))
    return HEADER + "".join(row(u) for u in units)


def main():
    out = os.path.join(root, ".config", "fleet", "timers.tsv")
    new = generate()
    if "--stdout" in sys.argv[1:]:
        sys.stdout.write(new)
        return 0
    if "--check" in sys.argv[1:]:
        old = read(out)
        if old == new:
            return 0
        sys.stdout.writelines(difflib.unified_diff(old.splitlines(True), new.splitlines(True), "timers.tsv (committed)", "timers.tsv (generated)"))
        print("timers.tsv drifted; regenerate: python3 -I %s" % os.path.realpath(__file__))
        return 1
    os.makedirs(os.path.dirname(out), exist_ok=True)
    open(out, "w").write(new)
    print("wrote %s (%d rows)" % (out, new.count("\n") - 1))
    return 0


sys.exit(main())
