#!/usr/bin/env python3
"""vtq.py -- query the cached vtable index. See docs/RE_LOOP.md.

  vtq.py vt <Class>              one class's vtable, slot by slot
  vtq.py diff <Base> <D1> [D2..] which slots the derived classes override
  vtq.py who <addr>              which classes/slots point at this function
  vtq.py family <regex>          every matching class with its slot count
  vtq.py bases <regex>           guess base/derived by shared slot prefixes
"""
import sys, json, collections
sys.path.insert(0,"/var/tmp"); import rebox as X

IDX = json.load(open("/var/tmp/vt_server.json"))
CLS = IDX["classes"]
_fs = None
def fs():
    global _fs
    if _fs is None: _fs = X.funcs()
    return _fs
def fname(a):
    f = X.owner(a, fs())
    return f["name"] if f else "?"
def fsize(a):
    f = X.owner(a, fs())
    return f["size"] if f else 0
def pick(name):
    if name in CLS: return name, CLS[name][0]
    hits = [k for k in CLS if k.lower() == name.lower()]
    if hits: return hits[0], CLS[hits[0]][0]
    hits = [k for k in CLS if name.lower() in k.lower()]
    if len(hits) == 1: return hits[0], CLS[hits[0]][0]
    print("ambiguous or unknown: %s" % (hits[:12] or "no match")); sys.exit(1)

def cmd_vt(name):
    n, t = pick(name)
    print("=== %s  vtable %08x  %d slots ===" % (n, t["vt"], len(t["slots"])))
    for i, a in enumerate(t["slots"]):
        print("   slot %-4d %08x size=%-6d %s" % (i, a, fsize(a), fname(a)))

def cmd_diff(basename, *derived):
    bn, bt = pick(basename)
    b = bt["slots"]
    ds = [pick(d) for d in derived]
    print("=== %s (%d slots) vs %d derived ===" % (bn, len(b), len(ds)))
    for i, a in enumerate(b):
        ov = [n for n, t in ds if i < len(t["slots"]) and t["slots"][i] != a]
        if ov or i < 6:
            print("   slot %-4d %08x %-46s %s" % (i, a, fname(a)[:46],
                  ", ".join(x.replace(bn+"_","") for x in ov)))

def cmd_who(addr):
    a = int(addr, 16)
    hits = []
    for cls, ts in CLS.items():
        for t in ts:
            for i, s in enumerate(t["slots"]):
                if s == a: hits.append((cls, i, t["vt"]))
    print("%08x appears in %d vtable slot(s)%s" % (a, len(hits),
          "   <-- FOLDED, do not name after one class" if len(hits) > 4 else ""))
    for cls, i, vt in sorted(hits)[:40]:
        print("   %-46s slot %-4d (vtable %08x)" % (cls, i, vt))

def cmd_family(pat):
    import re
    r = re.compile(pat, re.I)
    hits = sorted((k for k in CLS if r.search(k)), key=lambda k: -len(CLS[k][0]["slots"]))
    print("%d classes matching %r" % (len(hits), pat))
    for k in hits[:60]:
        t = CLS[k][0]
        named = sum(1 for a in t["slots"] if not X.unnamed(fname(a)))
        print("   %-52s %4d slots  %3d named  vt=%08x" % (k, len(t["slots"]), named, t["vt"]))

def cmd_bases(pat):
    import re
    r = re.compile(pat, re.I)
    hits = [k for k in CLS if r.search(k)]
    pref = {}
    for k in hits:
        pref[k] = CLS[k][0]["slots"]
    print("=== shared-prefix clustering over %d classes ===" % len(hits))
    for a in sorted(hits):
        best, bn = 0, None
        for b in hits:
            if a == b: continue
            n = 0
            for x, y in zip(pref[a], pref[b]):
                if x != y: break
                n += 1
            if n > best: best, bn = n, b
        print("   %-46s %4d slots, shares %3d with %s" % (a, len(pref[a]), best, bn))

if __name__ == "__main__":
    if len(sys.argv) < 2: sys.exit(__doc__)
    globals()["cmd_" + sys.argv[1]](*sys.argv[2:])
