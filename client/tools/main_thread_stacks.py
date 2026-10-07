#!/usr/bin/env python3
"""Round 757: where the Godot main thread is, sampled natively (box-side).

The box's container cannot run `perf` (kernel.perf_event_paranoid 4 on the host, MEASURED
2026-10-07), so this samples the main thread's stack with `eu-stack` (elfutils) a few times a
second -- a poor man's profiler. Run it against a Godot built with symbols (round 757 built
4.2.2-stable `template_release production=yes lto=none debug_symbols=yes` from the official
source; the official binary is stripped and gives addresses only).

  main_thread_stacks.py sample <client dir> <out> <seconds> [period_s]
      waits for the Godot process running `--path <client dir>`, then writes each sample of its
      main thread (tid = pid) as `SAMPLE <unix>` and the frames, innermost first.

  main_thread_stacks.py report <out> [<t0> <t1>] [depth]
      over the samples inside [t0, t1] (all when omitted): each function's share of samples
      inclusive (anywhere on the stack) and exclusive (innermost named frame), the 40 largest.
"""
import os
import re
import subprocess
import sys
import time


def find_pid(client_dir):
    needle = "--path " + client_dir + " "
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            cmd = open("/proc/%s/cmdline" % d, "rb").read().replace(b"\0", b" ").decode("utf-8", "replace")
            exe = os.path.basename(os.readlink("/proc/%s/exe" % d))
        except OSError:
            continue
        if needle in cmd + " " and ("godot" in exe.lower()):
            return int(d)
    return 0


def sample(client_dir, out, secs, period):
    pid = 0
    for _ in range(7200):
        pid = find_pid(client_dir)
        if pid:
            break
        time.sleep(0.5)
    if not pid:
        return
    end = time.time() + secs
    with open(out, "w") as f:
        while time.time() < end and os.path.exists("/proc/%d" % pid):
            t = time.time()
            r = subprocess.run(["eu-stack", "-p", str(pid), "-n", "48"], capture_output=True, text=True)
            f.write("SAMPLE %.3f\n" % t)
            on = False
            for line in r.stdout.splitlines():
                if line.startswith("TID "):
                    on = line.split()[1].rstrip(":") == str(pid)
                    continue
                if on:
                    f.write(line + "\n")
            f.flush()
            time.sleep(period)


FRAME = re.compile(r"^#\d+\s+0x[0-9a-f]+\s*(.*)$")


def report(path, t0=None, t1=None):
    samples = []
    cur = None
    for line in open(path, errors="replace"):
        if line.startswith("SAMPLE "):
            t = float(line.split()[1])
            cur = [] if (t0 is None or t0 <= t <= t1) else None
            if cur is not None:
                samples.append(cur)
            continue
        if cur is None:
            continue
        m = FRAME.match(line.strip())
        if m:
            name = m.group(1).strip() or "?"
            name = re.sub(r"\(.*$", "", name)
            cur.append(name)
    n = len(samples)
    if n == 0:
        print("no samples")
        return
    incl = {}
    excl = {}
    for s in samples:
        seen = set()
        named = [x for x in s if x != "?"]
        if named:
            excl[named[0]] = excl.get(named[0], 0) + 1
        for x in named:
            if x not in seen:
                seen.add(x)
                incl[x] = incl.get(x, 0) + 1
    print("samples %d" % n)
    print("-- inclusive")
    for k, v in sorted(incl.items(), key=lambda kv: -kv[1])[:40]:
        print("%5.1f%%  %s" % (100.0 * v / n, k))
    print("-- exclusive (innermost named frame)")
    for k, v in sorted(excl.items(), key=lambda kv: -kv[1])[:25]:
        print("%5.1f%%  %s" % (100.0 * v / n, k))


if __name__ == "__main__":
    if len(sys.argv) >= 5 and sys.argv[1] == "sample":
        sample(sys.argv[2], sys.argv[3], float(sys.argv[4]), float(sys.argv[5]) if len(sys.argv) > 5 else 0.25)
    elif len(sys.argv) >= 3 and sys.argv[1] == "report":
        if len(sys.argv) >= 5:
            report(sys.argv[2], float(sys.argv[3]), float(sys.argv[4]))
        else:
            report(sys.argv[2])
    else:
        print(__doc__)
        sys.exit(2)
