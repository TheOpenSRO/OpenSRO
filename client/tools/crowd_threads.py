#!/usr/bin/env python3
"""Round 757: where the CPU and the GPU go while a crowd probe runs (box-side).

Two modes:

  crowd_threads.py sample <client dir> <out> [period_s]
      Waits for the Godot process whose command line has `--path <client dir> `, then every
      period (0.5 s) appends one line to <out>:
        S <unix> <wall_s> tid:name:ticks,... | cpu:busy,total ...
      the cumulative CPU ticks of each of the process's threads (/proc/<pid>/task/*/stat
      utime+stime) and each core's busy and total ticks (/proc/stat). Ends when the process
      does. Python only: the box has no mpstat or perf (MEASURED 2026-10-07).

  crowd_threads.py report <crowd log> <sample file> [gpu file]
      For every `QA CROWD step ... unix=<t0>,<t1>` line of the crowd log, the samples inside
      that window give:
        main      the main thread's share of one core (the thread whose tid is the pid)
        others    the other threads' shares summed, in cores, and the three busiest
        box       the whole box's busy cores (of nproc), every process
      and the gpu file (`gpu_sample`'s `HH:MM:SS gfx=N% ...` lines, same day) the GFX
      busy share averaged over the window.
"""
import os
import re
import sys
import time

HZ = os.sysconf("SC_CLK_TCK")


def find_pid(client_dir):
    needle = "--path " + client_dir + " "
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            cmd = open("/proc/%s/cmdline" % d, "rb").read().replace(b"\0", b" ").decode("utf-8", "replace")
        except OSError:
            continue
        # The rendering client, not a headless suite or check on the same directory.
        if "godot" in cmd.split(" ")[0].lower() and needle in cmd + " " and "--headless" not in cmd:
            return int(d)
    return 0


def threads(pid):
    out = []
    base = "/proc/%d/task" % pid
    for t in os.listdir(base):
        try:
            st = open("%s/%s/stat" % (base, t)).read()
        except OSError:
            continue
        r = st.rfind(")")
        name = st[st.find("(") + 1:r].replace(" ", "_").replace(":", "_").replace(",", "_")
        f = st[r + 2:].split()
        out.append("%s:%s:%d" % (t, name, int(f[11]) + int(f[12])))
    return out


def cores():
    out = []
    for line in open("/proc/stat"):
        if line.startswith("cpu") and line[3].isdigit():
            v = [int(x) for x in line.split()[1:]]
            idle = v[3] + v[4]
            tot = sum(v[:8])
            out.append("%d,%d" % (tot - idle, tot))
    return out


def sample(client_dir, path, period):
    pid = 0
    for _ in range(3600):
        pid = find_pid(client_dir)
        if pid:
            break
        time.sleep(0.5)
    if not pid:
        return
    with open(path, "a") as f:
        f.write("PID %d HZ %d\n" % (pid, HZ))
        while os.path.exists("/proc/%d" % pid):
            try:
                th = threads(pid)
            except OSError:
                break
            f.write("S %.3f %s | %s\n" % (time.time(), ",".join(th), " ".join(cores())))
            f.flush()
            time.sleep(period)


def parse_samples(path):
    pid = 0
    rows = []
    for line in open(path):
        if line.startswith("PID"):
            pid = int(line.split()[1])
            continue
        if not line.startswith("S "):
            continue
        head, _, cpu = line.partition(" | ")
        parts = head.split(" ", 2)
        t = float(parts[1])
        th = {}
        for item in parts[2].split(","):
            tid, name, ticks = item.split(":")
            th[int(tid)] = (name, int(ticks))
        cs = [tuple(int(x) for x in c.split(",")) for c in cpu.split()]
        rows.append((t, th, cs))
    return pid, rows


def parse_gpu(path):
    out = []
    if not path or not os.path.exists(path):
        return out
    day = time.strftime("%Y-%m-%d")
    for line in open(path):
        m = re.match(r"(\d\d:\d\d:\d\d) gfx=(\d+)%", line)
        if m:
            t = time.mktime(time.strptime(day + " " + m.group(1), "%Y-%m-%d %H:%M:%S"))
            out.append((t, int(m.group(2))))
    return out


def report(log, samples, gpu):
    pid, rows = parse_samples(samples)
    g = parse_gpu(gpu)
    for line in open(log, errors="replace"):
        m = re.search(r"QA CROWD step (\S+)\s.*unix=([\d.]+),([\d.]+)", line)
        if not m:
            continue
        step, t0, t1 = m.group(1), float(m.group(2)), float(m.group(3))
        inside = [r for r in rows if t0 <= r[0] <= t1]
        if len(inside) < 2:
            print("QA THREADS step %-8s (too few samples)" % step)
            continue
        a, b = inside[0], inside[-1]
        dt = b[0] - a[0]
        per = []
        main = 0.0
        for tid, (name, ticks) in b[1].items():
            if tid not in a[1]:
                continue
            share = (ticks - a[1][tid][1]) / HZ / dt
            if tid == pid:
                main = share
            else:
                per.append((share, name, tid))
        per.sort(reverse=True)
        others = sum(p[0] for p in per)
        busy = sum((cb[0] - ca[0]) for ca, cb in zip(a[2], b[2]))
        tot = sum((cb[1] - ca[1]) for ca, cb in zip(a[2], b[2]))
        ncores = len(b[2])
        box = busy / tot * ncores if tot else 0.0
        gs = [v for (t, v) in g if t0 <= t <= t1]
        gline = "gpu_gfx=%.0f%%" % (sum(gs) / len(gs)) if gs else "gpu_gfx=-"
        top = " ".join("%s/%d=%.2f" % (n, tid, s) for s, n, tid in per[:4])
        print("QA THREADS step %-8s main=%.2f others=%.2f threads>5%%=%d box_busy=%.1f/%d %s top: %s" % (
            step, main, others, sum(1 for p in per if p[0] > 0.05), box, ncores, gline, top))


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "sample":
        sample(sys.argv[2], sys.argv[3], float(sys.argv[4]) if len(sys.argv) > 4 else 0.5)
    elif len(sys.argv) >= 4 and sys.argv[1] == "report":
        report(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else "")
    else:
        print(__doc__)
        sys.exit(2)
