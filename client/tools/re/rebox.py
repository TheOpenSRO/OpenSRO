#!/usr/bin/env python3
"""re.py -- the RE box's own toolkit. Written 2026-09-17 so each system costs
less than the last. Everything here was a throwaway script in some earlier tick.

  re.py classes <regex>        RTTI classes matching regex
  re.py fns <regex>            functions whose name matches
  re.py read <addr>            one function's body
  re.py slots <Class>          vtable slots of a class, who overrides what
  re.py strings <regex>        string literals matching, with owning function
  re.py callers <addr>         who calls this
  re.py params <addr>          param reads inside a function (both paths)
  re.py walk <addr> [depth]    transitive callees + params, the depth-N census
  re.py pk2 <substr>           list Media.pk2 by substring
  re.py table <name>           extract + summarise a textdata table
"""
import sys, re, os, glob, subprocess, collections

SRV = "/var/tmp/decomp_server"
CLI = "/var/tmp/decomp_client"
ASM = "/var/tmp/srgs.asm"
EXE = "/var/tmp/SR_GameServer.exe"
PK2 = "/opt/sro-files/client/Media.pk2"

_cache = {}
def funcs(dump=SRV):
    """All functions in a dump.

    REFUSES A DUMP WITHOUT ITS `DONE` MARKER. re_tick.sh rebuilds by `rm -rf`ing
    the directory and writing shards as it goes, so a probe that runs during a
    rebuild sees a partial dump -- or an empty one -- and returns nothing at
    all. That looks exactly like a real negative result, and on 2026-09-17 four
    probes in a row came back silently empty for that reason. An empty grep is
    a fact about the grep; this makes it a fact about the dump instead.
    """
    if dump in _cache: return _cache[dump]
    if not os.path.exists(os.path.join(dump, "DONE")):
        raise RuntimeError(
            "%s has no DONE marker: a dump rebuild is in progress, so any result "
            "from it would be partial. Wait for `cat %s/DONE` to print a "
            "functions= line." % (dump, dump))
    out = []
    for p in sorted(glob.glob(dump + "/funcs_*.c")):
        txt = open(p, errors="replace").read()
        for part in re.split(r"(?m)^===FUNC=== ", txt)[1:]:
            head = part.split("\n", 1)[0]
            h = head.split()
            if len(h) < 2: continue
            try: addr = int(h[0], 16)
            except ValueError: continue
            sz = [x for x in h if x.startswith("size=")]
            body = part.split("\n", 1)[1] if "\n" in part else ""
            out.append({"addr": addr, "name": h[1], "size": int(sz[0][5:]) if sz else 0,
                        "body": body, "head": head})
    out.sort(key=lambda f: f["addr"])
    _cache[dump] = out
    return out

def clean(b): return re.sub(r"/\*.*?\*/", "", b, flags=re.S)
def leaf(n): return n.rsplit("::", 1)[-1]
def unnamed(n): return leaf(n).startswith(("FUN_", "vslot_", "thunk_FUN_"))

def rtti_classes():
    out = subprocess.run(["strings", "-a", EXE], capture_output=True, text=True,
                         errors="replace").stdout
    names = set()
    for line in out.splitlines():
        if not (line.startswith(".?AV") or line.startswith(".?AU")): continue
        body = line[4:]
        if body.startswith("?$"): continue
        parts = [p for p in body.split("@") if p]
        if parts: names.add("::".join(reversed(parts)))
    return sorted(names)

def owner(addr, fs=None):
    fs = fs or funcs()
    lo, hi = 0, len(fs) - 1
    while lo <= hi:
        mid = (lo + hi) // 2
        f = fs[mid]
        if f["addr"] <= addr < f["addr"] + max(f["size"], 1): return f
        if f["addr"] < addr: lo = mid + 1
        else: hi = mid - 1
    return None

_asm = None
def asm():
    global _asm
    if _asm is None:
        _asm = []
        for raw in open(ASM, errors="replace"):
            m = re.match(r"^\s*([0-9a-f]+):\t(?:[0-9a-f]{2} )+\s*\t(.*)$", raw.rstrip())
            if m: _asm.append((int(m.group(1), 16), m.group(2)))
        _asm.sort()
    return _asm

def cmd_classes(pat):
    r = re.compile(pat, re.I)
    hits = [c for c in rtti_classes() if r.search(c)]
    print("%d classes matching %r" % (len(hits), pat))
    for c in hits[:80]: print("   " + c)

def cmd_fns(pat):
    r = re.compile(pat, re.I)
    hits = [f for f in funcs() if r.search(f["name"])]
    print("%d functions matching %r" % (len(hits), pat))
    for f in sorted(hits, key=lambda x: -x["size"])[:60]:
        print("   %08x size=%-6d %s" % (f["addr"], f["size"], f["name"]))

def cmd_read(addr):
    a = int(addr, 16)
    f = owner(a)
    if not f: return print("no function at %s" % addr)
    print("=== %s" % f["head"])
    print(clean(f["body"])[:4000])

def cmd_slots(cls):
    pat = re.compile(r"RTTI: reached as (\S+) slot (\d+)")
    byslot = collections.defaultdict(list)
    for f in funcs():
        m = pat.search(f["body"])
        if not m: continue
        if m.group(1) != cls and not m.group(1).startswith(cls): continue
        byslot[int(m.group(2))].append((m.group(1), f))
    print("%s: %d distinct slots" % (cls, len(byslot)))
    for s in sorted(byslot):
        v = byslot[s]
        names = {leaf(x[1]["name"]) for x in v if not unnamed(x[1]["name"])}
        sizes = sorted(x[1]["size"] for x in v)
        print("   slot %-4d x%-4d median=%-6d %s" % (s, len(v), sizes[len(sizes)//2],
                                                     ", ".join(sorted(names))[:60]))

def cmd_strings(pat):
    r = re.compile(pat)
    lit = re.compile(r'"((?:[^"\\]|\\.)*)"')
    n = 0
    for f in funcs():
        for s in lit.findall(f["body"]):
            if r.search(s):
                print("   %08x %-42s %r" % (f["addr"], f["name"][:42], s[:90])); n += 1
                if n > 60: return
    print("(%d shown)" % n)

def cmd_callers(addr):
    tgt = "call   0x%x" % int(addr, 16)
    fs = funcs()
    hits = []
    for a, t in asm():
        if t.strip() == tgt:
            o = owner(a, fs)
            hits.append((a, o["name"] if o else "(unindexed)"))
    print("%d call sites of %s" % (len(hits), addr))
    for a, n in hits[:40]: print("   %08x in %s" % (a, n))

def param_reads(f):
    """both paths: GetParam (vtable 0x104, id pushed) and EvaluateParam (id in EAX)."""
    out = []
    lo, hi = f["addr"], f["addr"] + max(f["size"], 1)
    rows = asm()
    idx = {a: i for i, (a, t) in enumerate(rows)}
    for a, t in rows:
        if not (lo <= a < hi): continue
        if "+0x104]" in t:
            for j in range(idx[a] + 1, min(len(rows), idx[a] + 5)):
                m = re.match(r"push\s+(0x[0-9a-f]+|\d+)$", rows[j][1])
                if m:
                    v = m.group(1)
                    out.append(("get", int(v, 16) if v.startswith("0x") else int(v), a)); break
                if rows[j][1].startswith("call"): break
        if t.strip() == "call   0x4b3740":
            for j in range(idx[a] - 1, max(0, idx[a] - 8), -1):
                m = re.match(r"mov\s+eax,(0x[0-9a-f]+)$", rows[j][1])
                if m: out.append(("eval", int(m.group(1), 16), a)); break
                if rows[j][1].startswith("call"): break
    return out

def cmd_params(addr):
    f = owner(int(addr, 16))
    if not f: return print("no function")
    print("=== %s" % f["head"])
    for kind, pid, a in param_reads(f):
        print("   %08x  %-5s param %d" % (a, kind, pid))

def cmd_walk(addr, depth="3"):
    root = int(addr, 16); maxd = int(depth)
    fs = funcs()
    callees = collections.defaultdict(set)
    for a, t in asm():
        m = re.match(r"call\s+0x([0-9a-f]+)$", t)
        if not m: continue
        o = owner(a, fs)
        if o: callees[o["addr"]].add(int(m.group(1), 16))
    seen = {}
    q = collections.deque([(root, 0)])
    while q:
        fn, d = q.popleft()
        if fn in seen and seen[fn] <= d: continue
        seen[fn] = d
        if d >= maxd: continue
        for c in callees.get(fn, ()):
            if owner(c, fs): q.append((c, d + 1))
    byparam = collections.defaultdict(list)
    for fn, d in seen.items():
        o = owner(fn, fs)
        if not o: continue
        for kind, pid, _ in param_reads(o):
            byparam[pid].append((d, kind, o["name"]))
    print("reachable within depth %d: %d functions; %d distinct params" % (maxd, len(seen), len(byparam)))
    for pid in sorted(byparam):
        d, kind, nm = sorted(byparam[pid])[0]
        print("   param %-4d depth %d via %-5s in %s" % (pid, d, kind, nm))

def cmd_pk2(sub):
    subprocess.run(["/var/tmp/pk2list", "-pk2", PK2, "-filter", sub])

def cmd_table(name):
    path = "/var/tmp/%s.txt" % name
    if not os.path.exists(path):
        subprocess.run(["/var/tmp/pk2list", "-pk2", PK2,
                        "-extract", "server_dep\\silkroad\\textdata\\%s.txt" % name,
                        "-out", path], capture_output=True)
    if not os.path.exists(path): return print("could not extract %s" % name)
    raw = open(path, "rb").read()
    enc = "utf-16" if raw[:2] == b"\xff\xfe" else "cp949"
    rows = [l.split("\t") for l in raw.decode(enc, errors="replace").splitlines() if l.strip()]
    rows = [r for r in rows if not r[0].lstrip().startswith("//")]
    print("%s: %d rows, columns %s" % (name, len(rows),
          collections.Counter(len(r) for r in rows).most_common(2)))
    for r in rows[:4]:
        print("   " + " | ".join("%d:%s" % (i, c[:16]) for i, c in enumerate(r[:16])))
    n = max(len(r) for r in rows)
    for c in range(min(n, 30)):
        vals = collections.Counter(r[c] for r in rows if len(r) > c)
        print("   col %-2d %4d distinct  %s" % (c, len(vals),
              ", ".join("%r x%d" % (k[:16], v) for k, v in vals.most_common(3))[:96]))

if __name__ == "__main__":
    if len(sys.argv) < 2: sys.exit(__doc__)
    globals()["cmd_" + sys.argv[1]](*sys.argv[2:])
