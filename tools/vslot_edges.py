#!/usr/bin/env python3
"""Vtable-slot edges for the virtual-only sub-builders (round 479).

Round 478: 77 of the 261 sub-builders have NO direct call site -- they are
reached only through a vtable, so a direct-call graph cannot see them. This
recovers the edge the other way round:

  1. each sub-builder's slot OFFSET(S), from the dump's own comment plate
     ("table 0x... slot N (offset 0xNNN)");
  2. each SENDER's virtual calls -- `mov reg,[reg+OFF]` ... `call reg`;
  3. a sub-builder whose offset is called only by senders of ONE opcode is
     attributable to that opcode.

CONTROL: CGObjChar::PublishAvailableInteractions is slot 0x38c, reached from
FUN_0050faf0, which sends 0xb045 (round 454). If the walk does not attribute it
to 0xb045 the method is broken and nothing else it says counts.

CAVEAT (round 433): a slot offset means something only within ONE class
hierarchy. Offset 0x38c in the CGObjChar tree is not offset 0x38c elsewhere, so
an offset match across hierarchies is spurious. Reported, not solved, here.
"""
import re, json, bisect, collections, subprocess

idx = []
for line in open("/var/tmp/decomp_server/index.txt", encoding="utf-8", errors="replace"):
    p = line.rstrip("\n").split("\t")
    if len(p) < 3: continue
    try: idx.append((int(p[0], 16), int(p[2]), p[1]))
    except ValueError: pass
idx.sort(); starts = [i[0] for i in idx]
byname = {f[2]: f for f in idx}
def own(a):
    i = bisect.bisect_right(starts, a) - 1
    return idx[i] if i >= 0 and idx[i][0] <= a < idx[i][0] + idx[i][1] else None

targets = set(json.load(open("/var/tmp/unattr_fns.json")))

# direct call counts: which targets are virtual-only
callre = re.compile(r"^\s*[0-9a-f]+:\s+(?:[0-9a-f]{2} )+\s*call\s+0x([0-9a-f]+)$")
direct = collections.Counter()
for l in open("/var/tmp/srv.asm", encoding="utf-8", errors="replace"):
    m = callre.match(l)
    if m: direct[int(m.group(1), 16)] += 1
virtual_only = [fn for fn in targets if fn in byname and direct.get(byname[fn][0], 0) == 0]

# 1. slot offsets from the VTABLES themselves (vt_server.json, round 418), not
#    from the dump's comment plate. Round 479's first run read the plate, and
#    naming a function REPLACES its plate with evidence text -- so the offset
#    vanished for exactly the best-understood functions, including the control.
vt = json.load(open("/var/tmp/vt_server.json"))["classes"]
slot_of = collections.defaultdict(set)      # function address -> {offset}
holders = collections.defaultdict(set)      # function address -> {class}
for cls, tables in vt.items():
    for t in tables:
        for i, fa in enumerate(t["slots"]):
            slot_of[fa].add(i * 4)
            holders[fa].add(cls)
offsets = {}
for fn in virtual_only:
    a = byname[fn][0]
    if slot_of.get(a): offsets[fn] = slot_of[a]

# opcodes each function sends (from the shipped v4 table)
sends = collections.defaultdict(set)
for l in open("/var/tmp/payloads5.tsv"):
    if l.startswith("#") or l.startswith("opcode"): continue
    p = l.rstrip("\n").split("\t")
    if len(p) >= 2 and p[0].startswith("0x"): sends[p[1]].add(p[0])

# 2. virtual-call offsets made by each SENDER
addr_re = re.compile(r"^\s*([0-9a-f]+):\s+(?:[0-9a-f]{2} )+\s*(.*?)\s*$")
vload = re.compile(r"^mov\s+(e[a-z]+),DWORD PTR \[e[a-z]+\+(0x[0-9a-f]+)\]$")
rows = []
for l in open("/var/tmp/srv.asm", encoding="utf-8", errors="replace"):
    m = addr_re.match(l)
    if m: rows.append((int(m.group(1), 16), m.group(2)))
called_by = collections.defaultdict(set)      # offset -> sender names
for i, (a, t) in enumerate(rows):
    m = vload.match(t)
    if not m: continue
    reg, off = m.group(1), int(m.group(2), 16)
    for j in range(i + 1, min(i + 8, len(rows))):
        if re.match(r"^call\s+" + reg + r"$", rows[j][1]):
            f = own(a)
            if f and f[2] in sends: called_by[off].add(f[2])
            break
        if rows[j][1].startswith("call") or rows[j][1].startswith("ret"): break

# 3. attribute
one = many = none = 0; attributed = {}
for fn, offs in offsets.items():
    ops = set()
    for off in offs:
        for s in called_by.get(off, ()): ops |= sends[s]
    if not ops: none += 1
    elif len(ops) == 1: one += 1; attributed[fn] = next(iter(ops))
    else: many += 1

print("virtual-only sub-builders          :", len(virtual_only))
print("  found in a class vtable            :", len(offsets))
print("  offset called by senders of ONE opcode :", one)
print("  offset called by senders of SEVERAL    :", many)
print("  offset called by no sender             :", none)
ctl = "CGObjChar::PublishAvailableInteractions"
print()
print("CONTROL", ctl, "offsets", sorted(hex(o) for o in offsets.get(ctl, ())),
      "->", attributed.get(ctl, "NOT ATTRIBUTED"))
json.dump({k: v for k, v in attributed.items()}, open("/var/tmp/vslot_attr.json", "w"))
