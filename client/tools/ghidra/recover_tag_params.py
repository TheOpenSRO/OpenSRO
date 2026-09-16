#!/usr/bin/env python3
"""Bind each engine stat tag to the ParamKeeper param id it writes.

The engine addresses a stat by a short ASCII string packed big-endian into a
word ('cri' is 0x637269), and `Stat_ApplyTaggedModifier` (server 0x00498690) is
a binary-search tree on that word whose leaves call
`GObjPC::ParamKeeper_SetParam`.

WHY THIS READS THE DISASSEMBLY. The param id arrives in EDI, which Ghidra does
not map to a parameter -- so the decompiled C shows every leaf as the identical
`ParamKeeper_SetParam(0, param_3, value)` and cannot tell the tags apart at all.
In the asm each leaf is `mov edi,N` immediately before the call. A whole
recovery was sitting behind one dropped register.

THE CONTROL IS THE POINT. Six of the bindings this produces were already known
from unrelated functions -- bri/cri from GObjMob_PublishStats' consecutive
publish run, evbl/evcr from Combat_ResolveDamage, str/int from the damage
pipeline's GetParam calls. All six come back right, which is what licenses the
rest. Run it and check them before believing a new binding.

WHAT IT CANNOT DO. The resist tags ('fz', 'ps', 'zb', ...) share one tail block,
each setting its own EDI before jumping in, so exploring both arms of every
branch reaches all of params 27..32 from each of them. Those are reported as
multi-valued rather than guessed. A tag reported with several params is not a
finding.

Usage:
    # extract the function first, e.g.
    #   awk '/^  498690:/,/^  4991b0:/' /var/tmp/srgs.asm > /var/tmp/satm.asm
    recover_tag_params.py            # reads /var/tmp/satm.asm
"""

import re

SETPARAM = 0x4b3510
LINE = re.compile(r"^\s*([0-9a-f]+):\t(?:[0-9a-f]{2} )+\s*\t(\S+)\s*(.*)$")
COND = ("je", "jne", "jg", "jl", "jle", "jge", "ja", "jb", "jae", "jbe", "js", "jns")

insns, order = {}, []
for raw in open("/var/tmp/satm.asm", errors="replace"):
    m = LINE.match(raw.rstrip("\n"))
    if not m:
        continue
    insns[int(m.group(1), 16)] = (m.group(2), m.group(3).strip())
    order.append(int(m.group(1), 16))
order.sort()
nxt = {a: order[i + 1] for i, a in enumerate(order[:-1])}

def imm(ops, reg):
    m = re.match(r"^" + reg + r",(0x[0-9a-f]+|\d+)$", ops)
    if not m:
        return None
    s = m.group(1)
    return int(s, 16) if s.startswith("0x") else int(s)

def target(ops):
    m = re.match(r"^(?:0x)?([0-9a-f]+)", ops)
    return int(m.group(1), 16) if m else None

def reach(start):
    """All (param_id, slot) pairs reachable from start before any non-SetParam
    call. Explores both arms of a conditional; stops at ret."""
    found = set()
    stack = [(start, None, None, frozenset())]
    while stack:
        a, edi, slot, seen = stack.pop()
        steps = 0
        while a in insns and steps < 300:
            if a in seen:
                break
            seen = seen | {a}
            steps += 1
            mn, ops = insns[a]
            if mn == "mov":
                v = imm(ops, "edi")
                if v is not None:
                    edi = v
            elif mn == "push":
                v = imm(ops, "")
                if ops in ("0x0", "0"):
                    slot = 0
                elif ops in ("0x1", "1"):
                    slot = 1
            elif mn == "call":
                if target(ops) == SETPARAM and edi is not None:
                    found.add((edi, slot))
                break
            elif mn == "jmp":
                t = target(ops)
                if t is None or t not in insns:
                    break
                a = t
                continue
            elif mn in COND:
                t = target(ops)
                if t in insns:
                    stack.append((t, edi, slot, seen))
            elif mn in ("ret", "leave"):
                break
            a = nxt.get(a)
            if a is None:
                break
    return found

def tagstr(v):
    try:
        b = v.to_bytes(4, "big").lstrip(b"\x00")
        s = b.decode("latin-1")
        return s if s and all(32 <= ord(c) < 127 for c in s) else None
    except (OverflowError, ValueError):
        return None

out, pending_cmp, pending_sub = {}, None, None
for a in order:
    mn, ops = insns[a]
    if mn == "cmp":
        pending_cmp, pending_sub = imm(ops, "eax"), None
    elif mn == "sub":
        v = imm(ops, "ecx")
        if v is not None:
            pending_sub = v if pending_sub is None else pending_sub + v
    elif mn == "je":
        t = target(ops)
        tag = tagstr(pending_cmp) if pending_cmp is not None else (tagstr(pending_sub) if pending_sub is not None else None)
        if tag and t in insns:
            for pid, slot in reach(t):
                out.setdefault(tag, set()).add(pid)
    elif mn not in COND and mn not in ("mov", "nop"):
        pending_cmp = None

single = {t: sorted(v)[0] for t, v in out.items() if len(v) == 1}
multi = {t: sorted(v) for t, v in out.items() if len(v) > 1}
print("tags resolved to ONE param: %d" % len(single))
for t in sorted(single):
    print("   %-6s %d" % (t, single[t]))
print("\ntags reaching several params: %d" % len(multi))
for t in sorted(multi):
    print("   %-6s %s" % (t, multi[t]))
print()
for t, want in (("bri", 10), ("cri", 12), ("evbl", 56), ("evcr", 57), ("str", 1), ("hra", 11)):
    got = sorted(out.get(t, []))
    print("CONTROL %-5s -> %-12s want %-3d %s" % (t, got, want, "OK" if got == [want] else "CHANGED"))
