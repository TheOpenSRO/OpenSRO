#!/usr/bin/env python3
"""Client-side payload sweep.

The client reads each field with MsgStreamBuffer::Read(dest, size) -- and unlike
the server's MsgBuf_AppendBytes, whose length lives in AX, the size here is an
explicit argument, so the client side is readable from the decompiled C.

Emits: client function -> ordered read sizes.
"""
import re, sys, glob, collections
DIR = "/var/tmp/decomp_client"
call = re.compile(r"FUN_004f7220\(([^;]*?)\)\s*;")
size = re.compile(r",\s*(\d+)\s*$")
out = collections.OrderedDict()
for f in sorted(glob.glob(DIR + "/funcs_*.c")):
    cur = None
    for line in open(f, encoding="utf-8", errors="replace"):
        if line.startswith("===FUNC=== "):
            p = line.split()
            cur = p[2] if len(p) > 2 else None
            continue
        if cur is None: continue
        m = call.search(line)
        if not m: continue
        sm = size.search(m.group(1))
        out.setdefault(cur, []).append(int(sm.group(1)) if sm else None)
for fn, sizes in out.items():
    lay = ",".join("VAR" if s is None else str(s) for s in sizes)
    print("%s\t%d\t%s" % (fn, len(sizes), lay))
