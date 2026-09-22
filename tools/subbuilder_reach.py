#!/usr/bin/env python3
"""The 1,055 appends with no open in their own function: are they SUB-BUILDERS,
functions handed an already-open message by a caller?

Round 454 proved one -- FUN_0050faf0 opens 0xb045 and passes the message to slot
0x38c (CGObjChar::PublishAvailableInteractions), which appends to it. This asks
how far that generalises: for each such function, which opcodes do its callers
send? One opcode means attributable; several means the sub-builder serves
several messages and has no single opcode.
"""
import re, json, bisect, collections
idx=[]
for line in open("/var/tmp/decomp_server/index.txt", encoding="utf-8", errors="replace"):
    p=line.rstrip("\n").split("\t")
    if len(p)<3: continue
    try: idx.append((int(p[0],16), int(p[2]), p[1]))
    except ValueError: pass
idx.sort(); starts=[i[0] for i in idx]
byname={f[2]: f for f in idx}
def own(a):
    i=bisect.bisect_right(starts,a)-1
    return idx[i] if i>=0 and idx[i][0]<=a<idx[i][0]+idx[i][1] else None

# opcode(s) each function sends, from the shipped sweep
sends=collections.defaultdict(set)
for l in open("/var/tmp/payloads5.tsv"):
    if l.startswith("#") or l.startswith("opcode"): continue
    p=l.rstrip("\n").split("\t")
    if len(p)<2 or not p[0].startswith("0x"): continue
    sends[p[1]].add(p[0])

targets=set(json.load(open("/var/tmp/unattr_fns.json")))

# direct-call edges: caller name -> set of callee names
addr_re=re.compile(r"^\s*([0-9a-f]+):\s+(?:[0-9a-f]{2} )+\s*(.*?)\s*$")
callre=re.compile(r"^call\s+0x([0-9a-f]+)$")
callers=collections.defaultdict(set)
for l in open("/var/tmp/srv.asm", encoding="utf-8", errors="replace"):
    m=addr_re.match(l)
    if not m: continue
    cm=callre.match(m.group(2))
    if not cm: continue
    src=own(int(m.group(1),16)); dst=byname.get("")
    t=int(cm.group(1),16)
    d=own(t)
    if src and d and d[0]==t and d[2] in targets:
        callers[d[2]].add(src[2])

one=0; many=0; none=0; rows=[]
for fn in sorted(targets):
    ops=set()
    for c in callers.get(fn,()):
        ops |= sends.get(c,set())
    if not ops: none+=1
    elif len(ops)==1: one+=1; rows.append((fn, next(iter(ops)), len(callers.get(fn,()))))
    else: many+=1
print("sub-builder candidates (append, never open):", len(targets))
print("  callers send exactly ONE opcode  :", one, " <- attributable")
print("  callers send SEVERAL opcodes     :", many)
print("  no direct caller sends anything  :", none)
print()
for r in rows[:12]: print("   %-46s %s  (%d callers)" % r)
