#!/usr/bin/env python3
"""Recover a packet's payload layout: list every MsgBuf_AppendBytes call in a
function's address range together with the AX value (the length) set before it.
MsgBuf_AppendBytes takes length in AX, source in the second argument -- the
register the decompiler drops, which is why payloads look size-less in C."""
import re, sys
lo, hi = int(sys.argv[1],16), int(sys.argv[2],16)
APPEND = sys.argv[3] if len(sys.argv) > 3 else "0x404090"
addr_re = re.compile(r"^\s*([0-9a-f]+):\s+(?:[0-9a-f]{2} )+\s*(.*)$")
rows = []
for l in open("/var/tmp/srv.asm", encoding="utf-8", errors="replace"):
    m = addr_re.match(l)
    if not m: continue
    a = int(m.group(1), 16)
    if lo <= a < hi: rows.append((a, m.group(2).strip()))
axw = re.compile(r"^mov\s+(ax|eax),(0x[0-9a-f]+|\d+)")
axo = re.compile(r"^(xor\s+eax,eax|movzx\s+eax,|mov\s+eax,DWORD|mov\s+ax,WORD|and\s+eax,|or\s+eax,|add\s+eax,|sub\s+eax,|lea\s+eax,|pop\s+eax|call)")
out = []
for i,(a,t) in enumerate(rows):
    if not (t.startswith("call") and APPEND in t): continue
    size, how = None, "?"
    for j in range(i-1, max(i-24,0), -1):
        tt = rows[j][1]
        m = axw.match(tt)
        if m:
            size = int(m.group(2), 0); how = tt; break
        if axo.match(tt):
            how = tt; break
    out.append((a, size, how))
print("appends in [%x,%x): %d" % (lo, hi, len(out)))
tot = 0
for a, s, how in out:
    if s is not None: tot += s
    print("  %08x  len=%-6s  (%s)" % (a, s if s is not None else "VAR", how[:46]))
print("fixed bytes total:", tot)
