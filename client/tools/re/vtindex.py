#!/usr/bin/env python3
"""Build a complete class -> vtable index for a PE, from RTTI in .rdata.

Cached as JSON so every later system costs a lookup instead of a scan.
  vtindex.py build <exe> <out.json>
"""
import sys, struct, json, collections

def sections(data):
    pe = struct.unpack_from("<I", data, 0x3c)[0]
    nsec = struct.unpack_from("<H", data, pe+6)[0]
    optsz = struct.unpack_from("<H", data, pe+20)[0]
    base = struct.unpack_from("<I", data, pe+24+28)[0]
    out=[]
    for i in range(nsec):
        o = pe+24+optsz+40*i
        vsz,va,rsz,ptr = struct.unpack_from("<IIII", data, o+8)
        out.append((data[o:o+8].rstrip(b"\0").decode("latin1"), va, vsz, ptr, rsz))
    return base, out

def build(exe, outp):
    data = open(exe,"rb").read()
    base, secs = sections(data)
    def va2off(va):
        r = va-base
        for nm,sva,vsz,ptr,rsz in secs:
            if sva <= r < sva+min(vsz if vsz else rsz, rsz): return ptr+(r-sva)
    def rd(va):
        o = va2off(va)
        return struct.unpack_from("<I", data, o)[0] if o is not None and o+4 <= len(data) else 0
    text = [s for s in secs if s[0]==".text"][0]
    tlo, thi = base+text[1], base+text[1]+text[2]
    def iscode(va): return tlo <= va < thi

    def demangle(s):
        if not s.startswith(".?A"): return None
        body = s[4:]
        if body.startswith("?$"): return None     # template instantiation
        parts = [p for p in body.split("@") if p]
        return "::".join(reversed(parts)) if parts else None

    out = collections.defaultdict(list)
    for nm,sva,vsz,ptr,rsz in secs:
        if nm != ".rdata": continue
        lo, hi = base+sva, base+sva+vsz
        for va in range(lo+4, hi-4, 4):
            col = rd(va-4)
            if not col or va2off(col) is None: continue
            td = rd(col+12)
            o = va2off(td)
            if o is None or o+8 >= len(data): continue
            raw = data[o+8:o+8+200].split(b"\0")[0].decode("latin1","replace")
            cls = demangle(raw)
            if not cls: continue
            if not iscode(rd(va)): continue
            slots=[]
            p = va
            while p < hi:
                f = rd(p)
                if not iscode(f): break
                slots.append(f); p += 4
                if len(slots) > 600: break
            if slots:
                out[cls].append({"vt": va, "slots": slots})
    js = {k: v for k, v in out.items()}
    json.dump({"base": base, "classes": js}, open(outp,"w"))
    n = sum(len(v) for v in js.values())
    tot = sum(len(t["slots"]) for v in js.values() for t in v)
    print("%s: %d classes, %d vtables, %d slots -> %s" % (exe, len(js), n, tot, outp))

if __name__ == "__main__":
    build(sys.argv[2], sys.argv[3])
