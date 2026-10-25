#!/usr/bin/env bash
# disk-health.sh - per-node disk health collector. Writes ~/.cache/fleet-dash/disk-health.json on the host it runs on.
#
# WHY: Joe 10-22 11:40 PM "rb and r7 need to check the disks" (RedBaron froze 3x; unsafe_shutdowns 295 is the freeze history).
#   fleet-dash collect.sh reads this file per host over its existing one-ssh-per-host pull (`cat ~/.cache/fleet-dash/disk-health.json`)
#   and raises the `disk-health` alarm (fleet-dash disk_health.py). The alarm is on the DELTA of unsafe_shutdowns, not the level.
#
# USAGE
#   disk-health.sh              collect, write the file, print the --summary line
#   disk-health.sh --json       collect, write the file, print it
#   disk-health.sh --summary    one line from the EXISTING file (no collect, no sudo); for seats
#   disk-health.sh --sudoers    print a ready-to-install sudoers file for THIS host (explicit device paths, no globs); no collect, no sudo
#   disk-health.sh --selftest   fake smartctl/nvme/lsblk/df/journalctl/sudo on a sandbox PATH; exits 1 on any failure
#
# FILE  {host, ts, ts_iso, devices:[{dev, kind:nvme|sata|usb, smart_health:PASSED|FAILED|unavailable, media_errors,
#        unsafe_shutdowns, percentage_used, reallocated, pending, source}], kernel_io_errors_since_boot (info only),
#        kernel_io_errors_6h / kernel_io_errors_24h (block-device error lines timestamped inside the window; null + kernel_window_unfiltered
#        true when the log has untimestamped lines), kernel_io_last_error_age_s, kernel_io_last, missing_devices:[{uuid, mount}] (fstab UUID= non-noauto
#        entries absent from /dev/disk/by-uuid), usb_resets_since_boot (informational), max_inode_pct:{mount,pct}, max_bytes_pct:{mount,pct},
#        mounts:[{mount, fs, bytes_pct, inode_pct, bytes_level: ok|yellow|red}] (every real filesystem + tmpfs /tmp),
#        max_bytes_level: ok|yellow|red (the worst mount), errors:[...]}
#   bytes_level: yellow at BYTES_YELLOW_PCT (85), red at BYTES_RED_PCT (92); fleet-dash disk_health.py raises the same thresholds as alarms.
#   source: smartctl | smartctl:<dtype> | nvme-cli | nvme-cli+smartctl[:<dtype>] | needs-sudo | no-smartctl | error
#           <dtype> = the smartctl `-d` type that answered for a USB bridge (sntasmedia | sntrealtek | sat | sntjmicron)
#   USB bridges (the SSDs are NVMe behind a bridge; `-d sat` fails on them): smartctl is tried plain, then -d sntasmedia, sntrealtek, sat,
#   sntjmicron, and stops at the first that yields a health verdict.
#
# PRIVILEGE: smartctl and nvme smart-log need root. This script never prompts and never fails the file for a missing tool:
#   root -> direct; else `sudo -n true` or `sudo -n -l <full smartctl/nvme command line>` must succeed once, otherwise every device is
#   smart_health "unavailable" with source "needs-sudo" (errors gets "needs-sudo"). Kernel log, df and the device list need no sudo.
#   Sudoers: exactly the forms this script runs, one Cmnd each (read-only flags; each -d type is spelled out). Render it per host, then check and install:
#     disk-health.sh --sudoers > /tmp/disk-health.sudoers && visudo -cf /tmp/disk-health.sudoers && sudo install -m 0440 /tmp/disk-health.sudoers /etc/sudoers.d/disk-health
#   WHY per host: Ubuntu's sudo-rs (0.2.13) does not support wildcards INSIDE command arguments (`/dev/sd[a-z]` lists as allowed under `sudo -n -l` but the
#   real run asks for a password), so the rule spells out every device path. Re-render when a disk is added. A sudo'd run that still says
#   "interactive authentication is required" is classified needs-sudo, not error.
#
# ENV  DISK_HEALTH_JOURNAL_FILE / DISK_HEALTH_NOW / DISK_HEALTH_FSTAB / DISK_HEALTH_BYUUID_DIR (test seams), DISK_HEALTH_OUT (file), DISK_HEALTH_HOST (host label), DISK_HEALTH_EXTRA_PATH (appended to PATH; default /usr/sbin:/sbin:/usr/local/sbin)
set -u

OUT=${DISK_HEALTH_OUT:-$HOME/.cache/fleet-dash/disk-health.json}
export PATH="$PATH:${DISK_HEALTH_EXTRA_PATH-/usr/sbin:/sbin:/usr/local/sbin}"

read -r -d '' PY <<'PY_EOF'
import datetime, json, os, re, shutil, socket, subprocess, sys, time

# block-device trouble only. A USB device resetting (carbon: usb 1-9 flapping) is counted apart in usb_resets_since_boot and never alarms;
# "ata1: hard resetting link" is normal at every boot, so only a failed command / failed reset counts.
BLKDEV = r"(?:sd[a-z]+\d*|nvme\d+(?:n\d+)?(?:p\d+)?|dm-\d+|md\d+|vd[a-z]+\d*|xvd[a-z]+\d*|mmcblk\d+(?:p\d+)?)"
KERNEL_RE = re.compile(r"I/O error\b.*\b" + BLKDEV + r"\b|\b" + BLKDEV + r"\b.*I/O error|blk_update_request|EXT4-fs error"
                       r"|XFS \([^)]*\):.*(?:error|corruption)|remounting filesystem read-only"
                       r"|\bata\d+(?:\.\d+)?: (?:failed command|exception Emask|COMRESET failed|reset failed)", re.I)
USB_DTYPES = ("sntasmedia", "sntrealtek", "sat", "sntjmicron")   # tried after the plain call; the order is the coordinator's (RedBaron 0781:55af: sat fails, snt* pass)
USB_RESET_RE = re.compile(r"\busb [\d.-]+: reset (?:low|full|high|super)-?speed\+? USB", re.I)
REAL_FS = {"ext2", "ext3", "ext4", "xfs", "btrfs", "f2fs", "vfat", "exfat", "ntfs", "ntfs3", "fuseblk", "zfs", "jfs", "reiserfs"}
# controller ruling f8b9: the 85 % hand-targets prune line must be a mechanism, not prose. Drift-guarded against fleet-dash disk_health.py by tests/disk-health-thresholds-drift.test.sh.
BYTES_YELLOW_PCT = 85
BYTES_RED_PCT = 92
SKIP_DEV = re.compile(r"^(loop|zram|ram|sr|fd|md|dm-)")
NEEDS_SUDO = re.compile(r"password is required|interactive authentication is required|not allowed|may not run|a terminal is required|no tty")


def run(cmd, timeout=40):
    """-> (rc, stdout, stderr); a missing tool is rc 127, a hang is rc 124. Never raises."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        return p.returncode, p.stdout, p.stderr
    except FileNotFoundError:
        return 127, "", "%s: not found" % cmd[0]
    except subprocess.TimeoutExpired:
        return 124, "", "%s: timeout" % cmd[0]
    except Exception as e:
        return 126, "", "%s: %s" % (cmd[0], e)


def to_int(s):
    try:
        return int(str(s).replace(",", "").strip().split()[0])
    except Exception:
        return None


def parse_smartctl(text):
    """smartctl -H -A text -> {health, reallocated, pending, media_errors, unsafe_shutdowns, percentage_used}."""
    r = {"health": None, "reallocated": None, "pending": None, "media_errors": None, "unsafe_shutdowns": None, "percentage_used": None}
    m = re.search(r"overall-health self-assessment test result:\s*(\S+)", text)
    if m:
        r["health"] = "PASSED" if m.group(1).upper().startswith("PASSED") else "FAILED"
    else:
        m = re.search(r"SMART Health Status:\s*(\S+)", text)
        if m:
            r["health"] = "PASSED" if m.group(1).upper() == "OK" else "FAILED"
    for ln in text.splitlines():
        p = ln.split()
        if len(p) >= 10 and p[0].isdigit() and p[2].startswith("0x"):
            if p[0] == "5":
                r["reallocated"] = to_int(p[9])
            elif p[0] == "197":
                r["pending"] = to_int(p[9])
        m = re.match(r"\s*Percentage Used:\s*(\d+)%", ln)
        if m:
            r["percentage_used"] = int(m.group(1))
        m = re.match(r"\s*Unsafe Shutdowns:\s*([\d,]+)", ln)
        if m:
            r["unsafe_shutdowns"] = to_int(m.group(1))
        m = re.match(r"\s*Media and Data Integrity Errors:\s*([\d,]+)", ln)
        if m:
            r["media_errors"] = to_int(m.group(1))
    return r


def parse_nvme_smartlog(text):
    """nvme smart-log text -> {critical_warning, media_errors, unsafe_shutdowns, percentage_used}."""
    kv = {}
    for ln in text.splitlines():
        m = re.match(r"^\s*([A-Za-z][\w ]*?)\s*:\s*(.+?)\s*$", ln)
        if m:
            kv[m.group(1).strip().lower().replace(" ", "_")] = m.group(2)
    pu = re.match(r"(\d+)", kv.get("percentage_used", "") or "")
    cw = kv.get("critical_warning")
    cwi = int(cw, 16) if cw and cw.lower().startswith("0x") else to_int(cw) if cw is not None else None
    return {"critical_warning": cwi,
            "media_errors": to_int(kv.get("media_errors", kv.get("media_and_data_integrity_errors", ""))),
            "unsafe_shutdowns": to_int(kv.get("unsafe_shutdowns", "")),
            "percentage_used": int(pu.group(1)) if pu else None}


def list_devices(errors):
    rc, out, err = run(["lsblk", "-dn", "-P", "-o", "NAME,TRAN,TYPE"])
    if rc != 0:
        errors.append("lsblk-failed" if rc != 127 else "lsblk-missing")
        return []
    devs = []
    for ln in out.splitlines():
        kv = dict(re.findall(r'(\w+)="([^"]*)"', ln))
        name = kv.get("NAME", "")
        if not name or kv.get("TYPE") != "disk" or SKIP_DEV.match(name):
            continue
        kind = "nvme" if name.startswith("nvme") else "usb" if kv.get("TRAN") == "usb" else "sata"
        devs.append({"dev": "/dev/" + name, "kind": kind})
    return devs


def sudo_prefix(devs):
    """-> (prefix list, ok). Never prompts: sudo -n only. The `-l` probe names a FULL command line (tool + flags + a real device): a sudoers rule with
    fixed arguments does not match a bare `sudo -l /usr/sbin/smartctl`."""
    if os.getuid() == 0:
        return [], True
    if shutil.which("sudo") is None:
        return None, False
    if run(["sudo", "-n", "true"], 15)[0] == 0:
        return ["sudo", "-n"], True
    smartctl, nvme = shutil.which("smartctl"), shutil.which("nvme")
    for d in devs:
        probes = [[smartctl, "-H", "-A", d["dev"]]] if smartctl else []
        if d["kind"] == "nvme" and nvme:
            probes.append([nvme, "smart-log", d["dev"]])
        for cmd in probes:
            if run(["sudo", "-n", "-l"] + cmd, 15)[0] == 0:
                return ["sudo", "-n"], True
    return None, False


def smart_device(d, prefix, have_sudo, errors):
    dev = d["dev"]
    row = {"dev": dev, "kind": d["kind"], "smart_health": "unavailable", "media_errors": None, "unsafe_shutdowns": None,
           "percentage_used": None, "reallocated": None, "pending": None, "source": "error"}
    smartctl, nvme = shutil.which("smartctl"), shutil.which("nvme")
    if not smartctl:
        errors.append("smartctl-missing")
    if d["kind"] == "nvme" and not nvme:
        errors.append("nvme-missing")
    if not have_sudo:
        row["source"] = "needs-sudo"
        return row
    used = []
    health = None
    stats = {}

    def call(args):
        rc, out, err = run(prefix + args)
        if NEEDS_SUDO.search(err) and not out.strip():
            return None
        return out + "\n" + err if not out.strip() else out

    if d["kind"] == "nvme" and nvme:
        out = call(["nvme", "smart-log", dev])
        if out is None:
            errors.append("needs-sudo")
            row["source"] = "needs-sudo"
            return row
        p = parse_nvme_smartlog(out)
        if p["media_errors"] is not None or p["unsafe_shutdowns"] is not None or p["critical_warning"] is not None:
            used.append("nvme-cli")
            stats = p
            if p["critical_warning"] is not None:
                health = "PASSED" if p["critical_warning"] == 0 else "FAILED"
    if smartctl:
        out = call(["smartctl", "-H", "-A", dev])
        if out is None:
            errors.append("needs-sudo")
            row["source"] = "needs-sudo"
            return row
        p = parse_smartctl(out)
        dtype = None
        if p["health"] is None and d["kind"] == "usb":   # NVMe/SATA behind a USB bridge: first -d type that yields a verdict wins
            for dt in USB_DTYPES:
                out2 = call(["smartctl", "-H", "-A", "-d", dt, dev])
                if out2 is None:
                    errors.append("needs-sudo")
                    row["source"] = "needs-sudo"
                    return row
                p2 = parse_smartctl(out2)
                if p2["health"] is not None:
                    p, dtype = p2, dt
                    break
        if p["health"] is not None:
            used.append("smartctl" + (":" + dtype if dtype else ""))
            health = p["health"]
            for k in ("media_errors", "unsafe_shutdowns", "percentage_used"):
                if stats.get(k) is None:
                    stats[k] = p[k]
            stats["reallocated"], stats["pending"] = p["reallocated"], p["pending"]
    elif not used:
        row["source"] = "no-smartctl"
        return row
    if not used:
        row["source"] = "error"
        errors.append("smart-unreadable:" + dev)
        return row
    row.update(smart_health=health or "unavailable", source="+".join(used))
    for k in ("media_errors", "unsafe_shutdowns", "percentage_used", "reallocated", "pending"):
        row[k] = stats.get(k)
    return row


WINDOW_6H_S = 6 * 3600
WINDOW_24H_S = 24 * 3600
DMESG_ISO_RE = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:[.,]\d+)?(?:[+-]\d\d:?\d\d|Z))\s")


def _line_ts(line, source):
    """epoch seconds of one kernel log line, or None. journalctl -o short-unix: '1792903707.123456 host kernel: ...'; dmesg --time-format=iso: '2026-10-24T21:41:26,123456-07:00 ...'."""
    if source == "journal":
        m = re.match(r"^(\d{9,11})(?:\.\d+)?\s", line)
        return float(line.split(None, 1)[0]) if m else None
    m = DMESG_ISO_RE.match(line)
    if not m:
        return None
    try:
        return datetime.datetime.fromisoformat(m.group(1).replace(",", ".").replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def kernel_io(errors):
    """-> dict {since_boot, h6, h24, last_age_s, last, usb_resets, unfiltered} or None when no kernel log is readable.
    since_boot = block-device error lines in the whole boot (info only). h6/h24 = those lines timestamped within the last 6 h / 24 h; filtered HERE
    by line timestamp (journalctl -k -b -o short-unix, else dmesg --time-format=iso). When any line carries no parseable timestamp the window cannot
    be trusted: h6/h24 are None and unfiltered is True (never the since-boot number). DISK_HEALTH_JOURNAL_FILE (a short-unix text file) replaces journalctl for tests."""
    now = float(os.environ.get("DISK_HEALTH_NOW") or time.time())
    jf = os.environ.get("DISK_HEALTH_JOURNAL_FILE")
    cmds = [("journal", ["journalctl", "-k", "-b", "-o", "short-unix", "--no-pager", "-q"]), ("dmesg", ["dmesg", "--time-format=iso"]), ("dmesg", ["dmesg"])]
    for source, cmd in cmds:
        if jf and source == "journal":
            try:
                rc, out = 0, open(jf).read()
            except OSError:
                rc, out = 1, ""
        else:
            rc, out, err = run(cmd)
        lines = [l for l in out.splitlines() if l.strip()]
        if rc != 0 or not lines:
            continue
        hits = [l for l in lines if KERNEL_RE.search(l)]
        usb = sum(1 for l in lines if USB_RESET_RE.search(l))
        stamped = [(l, _line_ts(l, source)) for l in hits]
        unfiltered = any(_line_ts(l, source) is None for l in lines)
        res = {"since_boot": len(hits), "last": [h.strip()[:200] for h in hits[-3:]], "usb_resets": usb, "unfiltered": unfiltered,
               "h6": None, "h24": None, "last_age_s": None}
        if not unfiltered:
            ages = [now - t for _, t in stamped]
            res["h6"] = sum(1 for a in ages if a <= WINDOW_6H_S)
            res["h24"] = sum(1 for a in ages if a <= WINDOW_24H_S)
            res["last_age_s"] = int(min(ages)) if ages else None
        return res
    errors.append("kernel-log-unreadable")
    return None


def missing_devices(errors):
    """-> [{uuid, mount}] for /etc/fstab UUID= entries (noauto excluded) with no /dev/disk/by-uuid link: an expected drive that is gone.
    DISK_HEALTH_FSTAB / DISK_HEALTH_BYUUID_DIR are the test seams. An unreadable fstab or by-uuid dir adds 'fstab-unreadable' and yields []."""
    fstab = os.environ.get("DISK_HEALTH_FSTAB") or "/etc/fstab"
    byuuid = os.environ.get("DISK_HEALTH_BYUUID_DIR") or "/dev/disk/by-uuid"
    try:
        lines = open(fstab).read().splitlines()
        present = {n.lower() for n in os.listdir(byuuid)}
    except OSError:
        errors.append("fstab-unreadable")
        return []
    out = []
    for ln in lines:
        p = ln.split("#", 1)[0].split()
        if len(p) < 2 or not p[0].upper().startswith("UUID="):
            continue
        if "noauto" in (p[3].split(",") if len(p) > 3 else []):
            continue
        u = p[0][5:].strip("\"'")
        if u.lower() not in present:
            out.append({"uuid": u, "mount": p[1]})
    return out


def pct(s):
    m = re.match(r"(\d+)%", s or "")
    return int(m.group(1)) if m else None


def bytes_level(v):
    return "ok" if v is None or v < BYTES_YELLOW_PCT else "yellow" if v < BYTES_RED_PCT else "red"


def df_max(errors):
    """-> (max_inode_pct, max_bytes_pct, mounts) over real filesystems + tmpfs /tmp.
    mounts = [{mount, fs, bytes_pct, inode_pct, bytes_level}], sorted by mount, only mounts with a bytes reading; a mount df lists twice keeps its higher figure."""
    best = {}
    per = {}
    for key, flags, col in (("inode", ["-PTi"], 5), ("bytes", ["-PT"], 5)):
        rc, out, err = run(["df"] + flags)
        if rc != 0 and not out:
            errors.append("df-failed")
            best[key] = None
            continue
        top = None
        for ln in out.splitlines()[1:]:
            p = ln.split(None, 6)
            if len(p) < 7:
                continue
            fstype, mount = p[1], p[6].strip()
            if not (fstype in REAL_FS or (fstype == "tmpfs" and mount == "/tmp")):
                continue
            v = pct(p[col])
            m = per.setdefault(mount, {"mount": mount, "fs": fstype, "bytes_pct": None, "inode_pct": None})
            if v is not None and (m[key + "_pct"] is None or v > m[key + "_pct"]):
                m[key + "_pct"] = v
            if v is not None and (top is None or v > top["pct"]):
                top = {"mount": mount, "pct": v}
        best[key] = top
    mounts = sorted((m for m in per.values() if m["bytes_pct"] is not None), key=lambda m: m["mount"])   # a mount with no bytes reading is not a bytes row
    for m in mounts:
        m["bytes_level"] = bytes_level(m["bytes_pct"])
    return best["inode"], best["bytes"], mounts


def collect():
    errors = []
    now = int(time.time())
    devs = list_devices(errors)
    prefix, ok = (None, False)
    if devs:
        prefix, ok = sudo_prefix(devs)
        if not ok:
            errors.append("needs-sudo")
    rows = [smart_device(d, prefix, ok, errors) for d in devs]
    k = kernel_io(errors) or {"since_boot": None, "last": [], "usb_resets": None, "unfiltered": False, "h6": None, "h24": None, "last_age_s": None}
    missing = missing_devices(errors)
    inode, byts, mounts = df_max(errors)
    errors = list(dict.fromkeys(errors))
    return {"host": os.environ.get("DISK_HEALTH_HOST") or socket.gethostname().split(".")[0],
            "ts": now, "ts_iso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
            "devices": rows, "kernel_io_errors_since_boot": k["since_boot"], "kernel_io_errors_6h": k["h6"], "kernel_io_errors_24h": k["h24"],
            "kernel_io_last_error_age_s": k["last_age_s"], "kernel_window_unfiltered": k["unfiltered"], "kernel_io_last": k["last"],
            "usb_resets_since_boot": k["usb_resets"], "missing_devices": missing,
            "max_inode_pct": inode, "max_bytes_pct": byts,
            "mounts": mounts, "max_bytes_level": bytes_level(byts["pct"]) if byts else "ok", "errors": errors}


def write(doc, path):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump(doc, f)
        f.write("\n")
    os.replace(tmp, path)


def summary(doc):
    devs = doc.get("devices") or []
    hs = [d.get("smart_health") for d in devs]
    worst = "FAILED" if "FAILED" in hs else "unavailable" if "unavailable" in hs else "PASSED" if hs else "no-devices"
    me = sum(d.get("media_errors") or 0 for d in devs)
    us = sum(d.get("unsafe_shutdowns") or 0 for d in devs)
    age = int(time.time()) - int(doc.get("ts") or 0)
    inode, byts = doc.get("max_inode_pct"), doc.get("max_bytes_pct")
    return "disk-health %s age %dm: smart %s x%d | media_errors %d | unsafe_shutdowns %d | kernel_io %s | usb_resets %s | io_6h %s | missing %d | inode max %s | bytes max %s | errors %s" % (
        doc.get("host"), age // 60, worst, len(devs), me, us,
        "n/a" if doc.get("kernel_io_errors_since_boot") is None else doc["kernel_io_errors_since_boot"],
        "n/a" if doc.get("usb_resets_since_boot") is None else doc["usb_resets_since_boot"],
        "n/a" if doc.get("kernel_io_errors_6h") is None else doc["kernel_io_errors_6h"],
        len(doc.get("missing_devices") or []),
        "%s%% %s" % (inode["pct"], inode["mount"]) if inode else "n/a",
        "%s%% %s (%s)" % (byts["pct"], byts["mount"], doc.get("max_bytes_level") or bytes_level(byts["pct"])) if byts else "n/a",
        ",".join(doc.get("errors") or []) or "none")


def main(argv):
    out = argv[0]
    mode = argv[1] if len(argv) > 1 else ""
    if mode == "--summary":
        try:
            with open(out) as f:
                print(summary(json.load(f)))
        except Exception:
            print("disk-health: no data (%s unreadable)" % out)
        return 0
    doc = collect()
    write(doc, out)
    if mode == "--json":
        print(json.dumps(doc, indent=1))
    else:
        print(summary(doc))
    return 0


sys.exit(main(sys.argv[1:]))
PY_EOF

# ---------------------------------------------------------------- selftest
selftest() {
  local d bin fx n=0 fails=0 py self
  self=$(readlink -f "${BASH_SOURCE[0]}")
  d=$(mktemp -d "${TMPDIR:-/tmp}/disk-health-selftest.XXXXXX") || { echo "selftest: mktemp failed" >&2; exit 1; }
  # shellcheck disable=SC2064
  trap "rm -rf '$d'" EXIT
  bin=$d/bin fx=$d/fx
  mkdir -p "$bin" "$fx"
  py=$(readlink -f "$(command -v python3)") || { echo "selftest: no python3" >&2; exit 1; }
  ln -s "$py" "$bin/python3"
  for t in true cat basename sed; do ln -s "$(type -P "$t")" "$bin/$t"; done   # what the fakes themselves call

  # fakes read fixtures from $FAKE_DIR; sandbox PATH = $bin only, so no real smartctl/nvme can leak in
  cat >"$bin/lsblk" <<'F'
#!/bin/bash
case "$*" in *-P*) cat "$FAKE_DIR/lsblk" ;; *) sed -n 's/^NAME="\([^"]*\)".*/\1/p' "$FAKE_DIR/lsblk" ;; esac   # -P = the collector; otherwise `lsblk -dno NAME` for --sudoers
F
  cat >"$bin/smartctl" <<'F'
#!/bin/bash
dt=""; prev=""; for a in "$@"; do last=$a; [ "$prev" = -d ] && dt=.$a; prev=$a; done
echo "$(basename "$last")${dt:- plain}" >>"$FAKE_DIR/calls.log"
f="$FAKE_DIR/smartctl.$(basename "$last")$dt"
[ -f "$f" ] || { echo "Smartctl open device: $last failed: No such device"; exit 2; }
cat "$f"; exit "$(cat "$f.rc" 2>/dev/null || echo 0)"
F
  cat >"$bin/nvme" <<'F'
#!/bin/bash
f="$FAKE_DIR/nvme.$(basename "${@: -1}")"
[ -f "$f" ] || { echo "no such device" >&2; exit 1; }
cat "$f"
F
  cat >"$bin/df" <<'F'
#!/bin/bash
case "$*" in *i*) cat "$FAKE_DIR/df.i" ;; *) cat "$FAKE_DIR/df.b" ;; esac
F
  cat >"$bin/journalctl" <<'F'
#!/bin/bash
[ -f "$FAKE_DIR/journal" ] || exit 1
cat "$FAKE_DIR/journal"
F
  cat >"$bin/dmesg" <<'F'
#!/bin/bash
[ -f "$FAKE_DIR/dmesg" ] || { echo "dmesg: read kernel buffer failed: Operation not permitted" >&2; exit 1; }
cat "$FAKE_DIR/dmesg"
F
  cat >"$bin/sudo" <<'F'
#!/bin/bash
# FAKE_SUDO=ok runs the command; narrow = like a sudoers file with fixed-argument smartctl/nvme rules only (`sudo -n true` fails, a full-line `-l` and the
# commands work); rs-wildcard = sudo-rs with a glob rule: `-l` succeeds but the real run says "interactive authentication is required" (exit 1);
# anything else fails like a password-required sudo
[ "${FAKE_SUDO:-ok}" = ok ] || [ "${FAKE_SUDO:-}" = narrow ] || [ "${FAKE_SUDO:-}" = rs-wildcard ] || { echo "sudo: a password is required" >&2; exit 1; }
[ "$1" = -n ] && shift
[ "${FAKE_SUDO:-ok}" = narrow ] && [ "$1" = true ] && { echo "sudo: a password is required" >&2; exit 1; }
if [ "$1" = -l ]; then   # a fixed-argument sudoers rule only matches a full command line (tool + args)
  case "$2" in */smartctl|*/nvme) [ $# -ge 4 ] && exit 0 ;; esac
  exit 1
fi
[ "${FAKE_SUDO:-ok}" = rs-wildcard ] && { echo "sudo: interactive authentication is required" >&2; exit 1; }
exec "$@"
F
  chmod +x "$bin"/lsblk "$bin"/smartctl "$bin"/nvme "$bin"/df "$bin"/journalctl "$bin"/dmesg "$bin"/sudo

  # ---- fixtures: nvme0n1 + sda (sata) + sdb (usb bridge, only -d sntasmedia answers) ----
  printf 'NAME="nvme0n1" TRAN="nvme" TYPE="disk"\nNAME="sda" TRAN="sata" TYPE="disk"\nNAME="sdb" TRAN="usb" TYPE="disk"\nNAME="loop0" TRAN="" TYPE="loop"\nNAME="zram0" TRAN="" TYPE="disk"\n' >"$fx/lsblk"
  nvme_log() { # nvme_log <media_errors> <unsafe> <critical_warning>
    printf 'Smart Log for NVME device:nvme0n1 namespace-id:ffffffff\ncritical_warning\t\t\t: %s\ntemperature\t\t\t\t: 35 °C (308 K)\navailable_spare\t\t\t\t: 100%%\npercentage_used\t\t\t\t: 3%%\nunsafe_shutdowns\t\t\t: %s\nmedia_errors\t\t\t\t: %s\nnum_err_log_entries\t\t\t: 0\n' "$3" "$2" "$1"
  }
  sata_log() { # sata_log <health> <realloc> <pending>
    printf 'smartctl 7.4 2023-08-01 r5530 [x86_64-linux] (local build)\n=== START OF READ SMART DATA SECTION ===\nSMART overall-health self-assessment test result: %s\nSMART Attributes Data Structure revision number: 16\nID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE\n  5 Reallocated_Sector_Ct   0x0033   100   100   010    Pre-fail  Always       -       %s\n  9 Power_On_Hours          0x0032   097   097   000    Old_age   Always       -       12345\n197 Current_Pending_Sector  0x0032   100   100   000    Old_age   Always       -       %s\n' "$1" "$2" "$3"
  }
  df_i() { # df_i <tmp-iuse%>
    printf 'Filesystem     Type     Inodes  IUsed   IFree IUse%% Mounted on\ntmpfs          tmpfs    819200   2001  817199    1%% /run\n/dev/nvme0n1p2 ext4   31195136 2751321 28443815    9%% /\ntmpfs          tmpfs   1933446 800000 1133446   %s%% /tmp\n/dev/sda1      vfat          0      0       0     - /boot/efi\noverlay        overlay 9999999 9999999 0 100%% /var/lib/docker/x\n' "$1"
  }
  df_b() { # df_b [/mnt/data bytes%, default 87]
    printf 'Filesystem     Type     1024-blocks      Used Available Capacity Mounted on\n/dev/nvme0n1p2 ext4       490048472 133106972 331974896      29%% /\ntmpfs          tmpfs        7733784      7444   7726340       1%% /tmp\n/dev/sda1      ext4       1000000    870000    130000      %s%% /mnt/data\noverlay        overlay 100 100 0 100%% /var/lib/docker/x\n' "${1:-87}"
  }
  printf 'Oct 22 kernel: Linux version\nOct 22 kernel: EXT4-fs (sda1): mounted\nOct 22 kernel: nvme0n1: ok\n' >"$fx/journal.clean"

  stamp() { # stamp <file> <age_s>: rewrite the 'Oct NN ... kernel: ' prefixes into journalctl -o short-unix lines <age_s> old (the real window filter reads these)
    local t=$(( $(date +%s) - $2 ))
    sed -E "s/^Oct [0-9]+( [0-9:]+)?( [a-z0-9]+)? kernel: /$t.000000 fx kernel: /" "$1" >"$1.s" && mv "$1.s" "$1"
  }
  mkdir -p "$fx/byuuid"; : >"$fx/fstab"
  stamp "$fx/journal.clean" 60

  jq_() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
  check() { # check <name> <file> <python expr that must be True>
    n=$((n + 1))
    if [ "$(jq_ "$2" "$3" 2>&1)" = True ]; then echo "  ok   $1"; else echo "  FAIL $1 :: $3"; fails=$((fails + 1)); fi
  }
  go() { # go <outfile> [VAR=val ...]  (sandbox PATH, fixtures in $fx)
    local o=$1; shift
    env -i HOME="$d" PATH="$bin" FAKE_DIR="$fx" DISK_HEALTH_OUT="$o" DISK_HEALTH_HOST=fx DISK_HEALTH_EXTRA_PATH= DISK_HEALTH_FSTAB="$fx/fstab" DISK_HEALTH_BYUUID_DIR="$fx/byuuid" "$@" "$BASH" "$self" >"$o.stdout" 2>"$o.stderr"
    echo $? >"$o.rc"
  }

  # ---- case 1: healthy (RedBaron-shaped: PASSED x3, media 0, unsafe 295, /tmp inodes 42 %)
  nvme_log 0 295 0 >"$fx/nvme.nvme0n1"
  sata_log PASSED 0 0 >"$fx/smartctl.sda"
  printf 'smartctl 7.4\nUnknown USB bridge [0x1234:0x5678 (0x100)]\nPlease specify device type with the -d option.\n' >"$fx/smartctl.sdb"; echo 1 >"$fx/smartctl.sdb.rc"
  sata_log PASSED 0 0 >"$fx/smartctl.sdb.sntasmedia"
  printf 'smartctl 7.4\nRead Device Identity failed: scsi error unsupported scsi opcode\n' >"$fx/smartctl.sdb.sat"; echo 1 >"$fx/smartctl.sdb.sat.rc"
  printf 'smartctl 7.4\nSMART overall-health self-assessment test result: PASSED\nSMART/Health Information (NVMe Log 0x02)\nPercentage Used:                    3%%\nUnsafe Shutdowns:                   295\nMedia and Data Integrity Errors:    0\n' >"$fx/smartctl.nvme0n1"
  df_i 42 >"$fx/df.i"; df_b >"$fx/df.b"; cp "$fx/journal.clean" "$fx/journal"
  go "$d/c1.json"
  [ "$(cat "$d/c1.json.rc")" = 0 ] || { echo "  FAIL healthy exit rc=$(cat "$d/c1.json.rc")"; fails=$((fails + 1)); }
  check "healthy: 3 devices, loop/zram skipped" "$d/c1.json" "[x['dev'] for x in d['devices']]==['/dev/nvme0n1','/dev/sda','/dev/sdb']"
  check "healthy: kinds nvme/sata/usb" "$d/c1.json" "[x['kind'] for x in d['devices']]==['nvme','sata','usb']"
  check "healthy: all PASSED" "$d/c1.json" "all(x['smart_health']=='PASSED' for x in d['devices'])"
  check "healthy: nvme media 0 unsafe 295 used 3" "$d/c1.json" "d['devices'][0]['media_errors']==0 and d['devices'][0]['unsafe_shutdowns']==295 and d['devices'][0]['percentage_used']==3 and d['devices'][0]['source']=='nvme-cli+smartctl'"
  check "healthy: sata reallocated/pending 0" "$d/c1.json" "d['devices'][1]['reallocated']==0 and d['devices'][1]['pending']==0 and d['devices'][1]['source']=='smartctl'"
  check "healthy: usb answered by -d sntasmedia only, recorded in source" "$d/c1.json" "d['devices'][2]['smart_health']=='PASSED' and d['devices'][2]['source']=='smartctl:sntasmedia'"
  n=$((n + 1)); got=$(grep '^sdb' "$fx/calls.log" | tr '\n' ','); if [ "$got" = "sdb plain,sdb.sntasmedia," ]; then echo "  ok   usb order: plain then sntasmedia, stops at the first verdict"; else echo "  FAIL usb order: $got"; fails=$((fails + 1)); fi
  check "healthy: kernel io 0" "$d/c1.json" "d['kernel_io_errors_since_boot']==0 and d['kernel_io_last']==[] and d['usb_resets_since_boot']==0"
  check "healthy: window fields 0/0, age null, filtered, no missing devices" "$d/c1.json" "d['kernel_io_errors_6h']==0 and d['kernel_io_errors_24h']==0 and d['kernel_io_last_error_age_s'] is None and d['kernel_window_unfiltered'] is False and d['missing_devices']==[]"
  check "healthy: max inode /tmp 42 (overlay + vfat dash ignored)" "$d/c1.json" "d['max_inode_pct']=={'mount':'/tmp','pct':42}"
  check "healthy: max bytes /mnt/data 87 (overlay ignored)" "$d/c1.json" "d['max_bytes_pct']=={'mount':'/mnt/data','pct':87}"
  check "healthy: no errors" "$d/c1.json" "d['errors']==[] and d['host']=='fx' and isinstance(d['ts'],int)"
  check "mounts: every real fs + tmpfs /tmp, overlay and dash-inode vfat handled" "$d/c1.json" "[(m['mount'],m['fs'],m['bytes_pct'],m['inode_pct']) for m in d['mounts']]==[('/','ext4',29,9),('/mnt/data','ext4',87,None),('/tmp','tmpfs',1,42)]"
  check "mounts: bytes_level ok/yellow/ok, max_bytes_level yellow (87 %)" "$d/c1.json" "[m['bytes_level'] for m in d['mounts']]==['ok','yellow','ok'] and d['max_bytes_level']=='yellow'"

  # ---- case 1b: bytes thresholds (controller ruling f8b9): 84 ok, 85 yellow, 92 red on the same mount
  for lv in 84:ok 85:yellow 91:yellow 92:red; do
    df_b "${lv%%:*}" >"$fx/df.b"; go "$d/c1b${lv%%:*}.json"
    check "bytes ${lv%%:*} % -> ${lv##*:}" "$d/c1b${lv%%:*}.json" "[m['bytes_level'] for m in d['mounts'] if m['mount']=='/mnt/data']==['${lv##*:}'] and d['max_bytes_level']=='${lv##*:}'"
  done
  env -i HOME="$d" PATH="$bin" DISK_HEALTH_OUT="$d/c1b92.json" "$BASH" "$self" --summary >"$d/c1b.sum" 2>&1
  n=$((n + 1)); if grep -q 'bytes max 92% /mnt/data (red)' "$d/c1b.sum"; then echo "  ok   summary names the worst mount and its level"; else echo "  FAIL summary worst mount: $(cat "$d/c1b.sum")"; fails=$((fails + 1)); fi
  df_b >"$fx/df.b"

  # ---- case 1c: USB bridges, one answer type each: sat only, sntjmicron only, none, and two answering (sntasmedia wins by order)
  cp "$fx/lsblk" "$fx/lsblk.orig"
  printf 'NAME="sdc" TRAN="usb" TYPE="disk"\nNAME="sdd" TRAN="usb" TYPE="disk"\nNAME="sde" TRAN="usb" TYPE="disk"\nNAME="sdf" TRAN="usb" TYPE="disk"\n' >"$fx/lsblk"
  sata_log PASSED 0 0 >"$fx/smartctl.sdc.sat"
  sata_log PASSED 0 0 >"$fx/smartctl.sdd.sntjmicron"
  sata_log PASSED 0 0 >"$fx/smartctl.sdf.sntasmedia"; sata_log PASSED 0 0 >"$fx/smartctl.sdf.sat"
  : >"$fx/calls.log"
  go "$d/c1c.json"
  check "usb sat-only: source smartctl:sat" "$d/c1c.json" "d['devices'][0]['smart_health']=='PASSED' and d['devices'][0]['source']=='smartctl:sat'"
  check "usb jmicron-only: source smartctl:sntjmicron" "$d/c1c.json" "d['devices'][1]['smart_health']=='PASSED' and d['devices'][1]['source']=='smartctl:sntjmicron'"
  check "usb nobody answers: unavailable + error names the device" "$d/c1c.json" "d['devices'][2]['smart_health']=='unavailable' and d['devices'][2]['source']=='error' and 'smart-unreadable:/dev/sde' in d['errors']"
  check "usb two answer: first in order (sntasmedia) wins" "$d/c1c.json" "d['devices'][3]['source']=='smartctl:sntasmedia'"
  n=$((n + 1)); got=$(grep '^sde' "$fx/calls.log" | tr '\n' ','); if [ "$got" = "sde plain,sde.sntasmedia,sde.sntrealtek,sde.sat,sde.sntjmicron," ]; then echo "  ok   usb retry order: plain, sntasmedia, sntrealtek, sat, sntjmicron"; else echo "  FAIL usb retry order: $got"; fails=$((fails + 1)); fi
  cp "$fx/lsblk.orig" "$fx/lsblk"

  # ---- case 2: FAILED sata (realloc 12, pending 3) + nvme media_errors 5 + 100 % /tmp inodes + 2 kernel I/O lines
  sata_log 'FAILED!' 12 3 >"$fx/smartctl.sda"; echo 4 >"$fx/smartctl.sda.rc"
  nvme_log 5 296 0 >"$fx/nvme.nvme0n1"
  df_i 100 >"$fx/df.i"
  printf '%s\n' 'Oct 22 kernel: blk_update_request: I/O error, dev sda, sector 123' 'Oct 22 kernel: Buffer I/O error on dev sda1, logical block 1' \
    'Oct 22 kernel: EXT4-fs error (device sda1): ext4_find_entry' 'Oct 22 kernel: ata1.00: failed command: READ DMA' 'Oct 22 kernel: ata1: hard resetting link' \
    'Oct 22 kernel: usb 2-1: reset high-speed USB device number 3 using xhci_hcd' 'Oct 22 kernel: usb 1-9: reset full-speed USB device number 5 using xhci_hcd' \
    'Oct 22 kernel: usb 2-2: device descriptor read/64, error -71' 'Oct 22 kernel: normal line' >"$fx/journal"
  stamp "$fx/journal" 300
  go "$d/c2.json"
  check "failed: sda FAILED" "$d/c2.json" "d['devices'][1]['smart_health']=='FAILED' and d['devices'][1]['reallocated']==12 and d['devices'][1]['pending']==3"
  check "failed: nvme media_errors 5 unsafe 296" "$d/c2.json" "d['devices'][0]['media_errors']==5 and d['devices'][0]['unsafe_shutdowns']==296"
  check "failed: kernel io 4 block lines (blk_update, Buffer I/O, EXT4-fs, ata failed command); ata hard reset + usb lines excluded" "$d/c2.json" "d['kernel_io_errors_since_boot']==4 and len(d['kernel_io_last'])==3"
  check "failed: all 4 lines are 5 min old -> 6h 4, 24h 4, last age ~300 s" "$d/c2.json" "d['kernel_io_errors_6h']==4 and d['kernel_io_errors_24h']==4 and 295<=d['kernel_io_last_error_age_s']<=330 and d['kernel_window_unfiltered'] is False"
  check "failed: usb resets counted apart (2), not in the io count" "$d/c2.json" "d['usb_resets_since_boot']==2"
  check "failed: /tmp inodes 100" "$d/c2.json" "d['max_inode_pct']=={'mount':'/tmp','pct':100}"
  env -i HOME="$d" PATH="$bin" DISK_HEALTH_OUT="$d/c2.json" "$BASH" "$self" --summary >"$d/c2.sum" 2>&1
  n=$((n + 1)); if grep -q 'smart FAILED x3' "$d/c2.sum" && grep -q 'media_errors 5' "$d/c2.sum" && grep -q 'kernel_io 4 | usb_resets 2' "$d/c2.sum" && grep -q 'inode max 100% /tmp' "$d/c2.sum"; then echo "  ok   summary one-liner"; else echo "  FAIL summary one-liner: $(cat "$d/c2.sum")"; fails=$((fails + 1)); fi

  # ---- case 2b: carbon shape -- only a USB device flapping: no disk I/O error, so nothing for the alarm; resets still counted
  printf '%s\n' 'Oct 22 23:48 carbon kernel: usb 1-9: reset full-speed USB device number 5 using xhci_hcd' 'Oct 22 23:54 carbon kernel: usb 1-9: reset full-speed USB device number 5 using xhci_hcd' \
    'Oct 23 00:00 carbon kernel: usb 1-9: reset full-speed USB device number 5 using xhci_hcd' 'Oct 23 kernel: usb 3-1: reset SuperSpeed USB device number 2 using xhci_hcd' >"$fx/journal"
  stamp "$fx/journal" 120
  go "$d/c2b.json"
  check "usb-only flapping: kernel_io 0, usb_resets 4" "$d/c2b.json" "d['kernel_io_errors_since_boot']==0 and d['kernel_io_last']==[] and d['usb_resets_since_boot']==4"

  # ---- case 2c: the 6 h window -- an I/O error 8 h old counts for since-boot and 24h but NOT 6h; one 2 h old counts for 6h
  old=$(( $(date +%s) - 8 * 3600 )); new=$(( $(date +%s) - 2 * 3600 ))
  printf '%s.000000 fx kernel: blk_update_request: I/O error, dev sdb, sector 9\n%s.000000 fx kernel: normal line\n' "$old" "$new" >"$fx/journal"
  go "$d/c2c.json"
  check "window: old error (8 h) -> since_boot 1, 6h 0, 24h 1, age ~8 h" "$d/c2c.json" "d['kernel_io_errors_since_boot']==1 and d['kernel_io_errors_6h']==0 and d['kernel_io_errors_24h']==1 and 28790<=d['kernel_io_last_error_age_s']<=28830"
  printf '%s.000000 fx kernel: blk_update_request: I/O error, dev sdb, sector 9\n%s.000000 fx kernel: blk_update_request: I/O error, dev sdb, sector 10\n' "$old" "$new" >"$fx/journal"
  go "$d/c2d.json"
  check "window: plus a 2 h old error -> since_boot 2, 6h 1, 24h 2" "$d/c2d.json" "d['kernel_io_errors_since_boot']==2 and d['kernel_io_errors_6h']==1 and d['kernel_io_errors_24h']==2"
  printf 'Oct 22 kernel: blk_update_request: I/O error, dev sdb, sector 9\n' >"$fx/journal"
  go "$d/c2e.json"
  check "window: an untimestamped journal line -> 6h null + unfiltered true" "$d/c2e.json" "d['kernel_io_errors_since_boot']==1 and d['kernel_io_errors_6h'] is None and d['kernel_window_unfiltered'] is True"
  # journal empty -> dmesg --time-format=iso fallback; its lines carry ISO stamps and are filtered like the journal's
  : >"$fx/journal"; printf '2026-10-24T21:41:26,123456-07:00 blk_update_request: I/O error, dev sdb, sector 9\n' >"$fx/dmesg"
  go "$d/c2f.json" DISK_HEALTH_NOW=1792903000
  check "dmesg ISO fallback is filtered by timestamp (line at 1792903286, NOW 1792903000 -> inside 6 h)" "$d/c2f.json" "d['kernel_io_errors_6h']==1 and d['kernel_window_unfiltered'] is False"
  go "$d/c2g.json" DISK_HEALTH_NOW=1793000000
  check "dmesg ISO fallback: NOW a day+ later -> 6h 0, 24h 0, since_boot 1" "$d/c2g.json" "d['kernel_io_errors_6h']==0 and d['kernel_io_errors_24h']==0 and d['kernel_io_errors_since_boot']==1"
  rm -f "$fx/dmesg"

  # ---- case 2h: missing_devices -- fstab UUID entries (noauto excluded) absent from /dev/disk/by-uuid
  cp "$fx/journal.clean" "$fx/journal"
  printf '%s\n' '# comment' 'UUID=AAAA-1111 /mnt/data ext4 defaults,nofail 0 2' 'UUID=bbbb-2222 /mnt/usb ext4 defaults 0 2' 'UUID=cccc-3333 /mnt/off ext4 noauto,user 0 0' '/dev/sda1 /boot/efi vfat defaults 0 1' >"$fx/fstab"
  : >"$fx/byuuid/aaaa-1111"
  go "$d/c2h.json"
  check "missing_devices: only the absent non-noauto UUID (case-insensitive match for the present one)" "$d/c2h.json" "d['missing_devices']==[{'uuid':'bbbb-2222','mount':'/mnt/usb'}]"
  : >"$fx/byuuid/bbbb-2222"
  go "$d/c2i.json"
  check "missing_devices: all present -> []" "$d/c2i.json" "d['missing_devices']==[]"
  go "$d/c2j.json" DISK_HEALTH_FSTAB="$fx/nonexistent"
  check "missing_devices: unreadable fstab -> [] + fstab-unreadable in errors" "$d/c2j.json" "d['missing_devices']==[] and 'fstab-unreadable' in d['errors']"
  : >"$fx/fstab"; rm -f "$fx/byuuid"/*

  # ---- case 3: needs-sudo (sudo -n fails) + journal empty -> dmesg fallback; the file is still written whole
  df_i 42 >"$fx/df.i"; : >"$fx/journal"; printf 'kernel: EXT4-fs error (device sda1): ext4_find_entry\n' >"$fx/dmesg"
  go "$d/c3.json" FAKE_SUDO=deny
  check "needs-sudo: every device unavailable + source needs-sudo" "$d/c3.json" "len(d['devices'])==3 and all(x['smart_health']=='unavailable' and x['source']=='needs-sudo' and x['media_errors'] is None for x in d['devices'])"
  check "needs-sudo: errors names it, file still has kernel + df" "$d/c3.json" "'needs-sudo' in d['errors'] and d['max_inode_pct']['pct']==42 and d['max_bytes_pct']['pct']==87"
  check "needs-sudo: dmesg fallback counted EXT4-fs error" "$d/c3.json" "d['kernel_io_errors_since_boot']==1 and d['usb_resets_since_boot']==0"
  check "dmesg fallback without timestamps: 6h/24h null + kernel_window_unfiltered true, never the since-boot number" "$d/c3.json" "d['kernel_io_errors_6h'] is None and d['kernel_io_errors_24h'] is None and d['kernel_window_unfiltered'] is True"
  [ "$(cat "$d/c3.json.rc")" = 0 ] || { echo "  FAIL needs-sudo exit rc=$(cat "$d/c3.json.rc")"; fails=$((fails + 1)); }

  # ---- case 3b: narrow sudoers (no `sudo -n true`, only the fixed command lines): the full-line `-l` probe must find the grant
  : >"$fx/journal"; rm -f "$fx/dmesg"; cp "$fx/journal.clean" "$fx/journal"
  go "$d/c3b.json" FAKE_SUDO=narrow
  check "narrow sudoers: SMART read, not needs-sudo" "$d/c3b.json" "d['devices'][0]['smart_health']=='PASSED' and 'needs-sudo' not in d['errors'] and d['devices'][2]['source']=='smartctl:sntasmedia'"

  # ---- case 3c: sudo-rs wildcard rule: `sudo -n -l <line>` succeeds, the real run prints "interactive authentication is required" -> needs-sudo, not error
  go "$d/c3c.json" FAKE_SUDO=rs-wildcard
  check "sudo-rs interactive auth: every device source needs-sudo (not error)" "$d/c3c.json" "len(d['devices'])==3 and all(x['source']=='needs-sudo' and x['smart_health']=='unavailable' for x in d['devices'])"
  check "sudo-rs interactive auth: errors has needs-sudo exactly once, no smart-unreadable" "$d/c3c.json" "d['errors'].count('needs-sudo')==1 and not any(e.startswith('smart-unreadable') for e in d['errors'])"

  # ---- case 3d: --sudoers renders explicit device paths (fake lsblk: nvme0n1 sda sdb + loop0 zram0), no globs, every rule line is user + ALL=(root) NOPASSWD:
  env -i HOME="$d" PATH="$bin" FAKE_DIR="$fx" DISK_HEALTH_HOST=fx DISK_HEALTH_EXTRA_PATH= SUDO_RULE_USER=tester "$BASH" "$self" --sudoers >"$d/c3d.out" 2>"$d/c3d.err"; rc=$?
  n=$((n + 1)); if [ $rc = 0 ] && [ ! -s "$d/c3d.err" ] && grep -q '/dev/nvme0n1' "$d/c3d.out" && grep -q '/dev/sda' "$d/c3d.out" && grep -q '/dev/sdb' "$d/c3d.out" \
    && ! grep -q 'loop0\|zram0' "$d/c3d.out" && ! grep -q '[][*]' "$d/c3d.out"; then echo "  ok   --sudoers: each fake device path, no [ ] or * characters, nothing on stderr"; else echo "  FAIL --sudoers devices/globs rc=$rc: $(cat "$d/c3d.out" "$d/c3d.err")"; fails=$((fails + 1)); fi
  n=$((n + 1)); if [ "$(grep -vc '^#' "$d/c3d.out")" = 3 ] && ! grep -v '^#' "$d/c3d.out" | grep -qv '^tester ALL=(root) NOPASSWD: ' && [ "$(grep -c '^#' "$d/c3d.out")" = 1 ] \
    && [ "$(grep -o 'smartctl -H -A -d [a-z]* /dev/sdb' "$d/c3d.out" | wc -l)" = 4 ] && grep -q 'nvme smart-log /dev/nvme0n1' "$d/c3d.out"; then echo "  ok   --sudoers: one comment line, one rule per disk (user ALL=(root) NOPASSWD:), 4 -d forms for sd*, nvme smart-log for nvme*"; else echo "  FAIL --sudoers shape: $(cat "$d/c3d.out")"; fails=$((fails + 1)); fi

  # ---- case 4a: nvme-cli missing only: the nvme disk is read through smartctl, errors names the tool
  rm -f "$bin/nvme"
  df_i 42 >"$fx/df.i"; cp "$fx/journal.clean" "$fx/journal"; sata_log PASSED 0 0 >"$fx/smartctl.sda"; rm -f "$fx/smartctl.sda.rc"
  go "$d/c4a.json"
  check "nvme-cli missing: nvme via smartctl, errors has nvme-missing only" "$d/c4a.json" "d['devices'][0]['source']=='smartctl' and d['devices'][0]['smart_health']=='PASSED' and d['errors']==['nvme-missing']"

  # ---- case 4: smartctl + nvme missing, journal + dmesg unreadable -> degraded file, never a failure
  rm -f "$bin/smartctl" "$bin/nvme" "$bin/dmesg" "$fx/journal"
  go "$d/c4.json"
  check "no tools: devices listed, source no-smartctl" "$d/c4.json" "len(d['devices'])==3 and all(x['smart_health']=='unavailable' and x['source']=='no-smartctl' for x in d['devices'])"
  check "no tools: errors smartctl-missing + kernel-log-unreadable, kernel null" "$d/c4.json" "'smartctl-missing' in d['errors'] and 'nvme-missing' in d['errors'] and 'kernel-log-unreadable' in d['errors'] and d['kernel_io_errors_since_boot'] is None and d['usb_resets_since_boot'] is None"
  [ "$(cat "$d/c4.json.rc")" = 0 ] || { echo "  FAIL no-tools exit rc=$(cat "$d/c4.json.rc")"; fails=$((fails + 1)); }

  # ---- case 5: --summary on a missing file, --json prints the doc
  env -i HOME="$d" PATH="$bin" DISK_HEALTH_OUT="$d/none.json" "$BASH" "$self" --summary >"$d/c5.sum" 2>&1
  n=$((n + 1)); if grep -q '^disk-health: no data' "$d/c5.sum"; then echo "  ok   summary with no file"; else echo "  FAIL summary with no file: $(cat "$d/c5.sum")"; fails=$((fails + 1)); fi
  env -i HOME="$d" PATH="$bin" FAKE_DIR="$fx" DISK_HEALTH_OUT="$d/c6.json" DISK_HEALTH_HOST=fx DISK_HEALTH_EXTRA_PATH= "$BASH" "$self" --json >"$d/c6.out" 2>&1
  n=$((n + 1)); if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["host"]=="fx" and "devices" in d else 1)' "$d/c6.out"; then echo "  ok   --json prints the document"; else echo "  FAIL --json output"; fails=$((fails + 1)); fi

  echo "selftest: $((n - fails))/$n passed"
  [ $fails -eq 0 ]
}

# --sudoers: the exact fixed-argument command lines the collector runs, one rule line per whole disk, explicit device paths and NO glob characters
# (sudo-rs does not support wildcards inside command arguments). Nothing but the file on stdout.
sudoers() {
  local user=${SUDO_RULE_USER:-${USER:-$(id -un 2>/dev/null)}} sc nv name dev line host=${DISK_HEALTH_HOST:-${HOSTNAME:-$(uname -n)}} today t
  sc=$(command -v smartctl) || sc=/usr/sbin/smartctl
  nv=$(command -v nvme) || nv=/usr/sbin/nvme
  printf -v today '%(%F)T' -1
  echo "# rendered by disk-health.sh --sudoers on $host $today: sudo-rs does not support wildcards inside command arguments, so every device path is explicit; re-render when a disk is added"
  while IFS= read -r name; do
    [[ $name =~ ^(sd[a-z]+|nvme[0-9]+n[0-9]+)$ ]] || continue
    dev=/dev/$name
    if [[ $name == nvme* ]]; then
      line="$sc -H -A $dev, $nv smart-log $dev"
    else
      line="$sc -H -A $dev"
      for t in sntasmedia sntrealtek sat sntjmicron; do line+=", $sc -H -A -d $t $dev"; done
    fi
    echo "$user ALL=(root) NOPASSWD: $line"
  done < <(lsblk -dno NAME 2>/dev/null)
  return 0
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  --sudoers) sudoers; exit 0 ;;
  ""|--json|--summary) ;;
  *) echo "usage: disk-health.sh [--json|--summary|--sudoers|--selftest]" >&2; exit 64 ;;
esac

command -v python3 >/dev/null 2>&1 || { echo "disk-health: python3 missing" >&2; exit 1; }
exec python3 -I -c "$PY" "$OUT" "${1:-}"
