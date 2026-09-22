#!/usr/bin/env python3
"""Sweep the whole server for opcode -> payload layout.

A message is opened with   mov reg,[this+0x278] ; push <opcode> ; call reg
and each field appended with MsgBuf_AppendBytes, whose LENGTH IS IN AX -- a
register Ghidra drops, which is why payloads cannot be read from the C.

Emits: opcode, sender function, and the append lengths in address order.
Flags a function that opens more than one opcode (attribution ambiguous) and
marks VAR where an intervening call clobbers eax.
"""
import re, sys, collections

ASM = "/var/tmp/srv.asm"
IDX = "/var/tmp/decomp_server/index.txt"
APPEND = "0x404090"

funcs = []
for line in open(IDX, encoding="utf-8", errors="replace"):
    p = line.rstrip("\n").split("\t")
    if len(p) < 3: continue
    try: funcs.append((int(p[0],16), int(p[2]), p[1]))
    except ValueError: continue
funcs.sort()
def owner(a):
    lo, hi, best = 0, len(funcs)-1, None
    while lo <= hi:
        m = (lo+hi)//2
        if funcs[m][0] <= a: best = funcs[m]; lo = m+1
        else: hi = m-1
    return best[2] if best and best[0] <= a < best[0]+best[1] else None

addr_re = re.compile(r"^\s*([0-9a-f]+):\s+(?:[0-9a-f]{2} )+\s*(.*?)\s*$")
rows = []
for l in open(ASM, encoding="utf-8", errors="replace"):
    m = addr_re.match(l)
    if m: rows.append((int(m.group(1),16), m.group(2)))

open_re  = re.compile(r"^mov\s+e[a-z]+,DWORD PTR \[e[a-z]+\+0x278\]")
push_re  = re.compile(r"^push\s+(0x[0-9a-f]+)$")
axw_re   = re.compile(r"^mov\s+(?:ax|eax),(0x[0-9a-f]+|\d+)$")
clob_re  = re.compile(r"^(call|xor\s+eax|movzx\s+eax|mov\s+eax,DWORD|mov\s+ax,WORD|pop\s+eax|lea\s+eax|add\s+eax|sub\s+eax|and\s+eax|or\s+eax)")

opens  = collections.defaultdict(list)
appends = collections.defaultdict(list)
for i,(a,t) in enumerate(rows):
    fn = None
    if open_re.match(t):
        for j in range(i+1, min(i+6, len(rows))):
            pm = push_re.match(rows[j][1])
            if pm:
                fn = owner(a)
                if fn: opens[fn].append(int(pm.group(1),16))
                break
            if rows[j][1].startswith("call"): break
    elif t.startswith("call") and APPEND in t:
        size = None
        for j in range(i-1, max(i-24,0), -1):
            tt = rows[j][1]
            m = axw_re.match(tt)
            if m: size = int(m.group(1),0); break
            if clob_re.match(tt): break
        fn = owner(a)
        if fn: appends[fn].append(size)

print("opcode\tsender\tfields\tlayout")
n_ok = n_amb = 0
for fn in sorted(set(opens) | set(appends)):
    ops = sorted(set(opens.get(fn, [])))
    ap  = appends.get(fn, [])
    layout = ",".join("VAR" if s is None else str(s) for s in ap) or "-"
    if len(ops) == 1:
        n_ok += 1
        print("0x%04x\t%s\t%d\t%s" % (ops[0], fn, len(ap), layout))
    elif len(ops) > 1:
        n_amb += 1
        print("%s\t%s\t%d\t%s" % ("+".join("0x%04x"%o for o in ops), fn, len(ap), layout))
print("\n# single-opcode senders: %d   multi-opcode (ambiguous): %d" % (n_ok, n_amb), file=sys.stderr)
