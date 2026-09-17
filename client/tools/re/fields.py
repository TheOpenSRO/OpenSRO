#!/usr/bin/env python3
"""fields.py <addr>... -- field index -> struct offset for a reference-record
deserializer.

THE MODEL, validated against RefObjCommon_ExtractData, whose 58-field count
docs/protocol/refobj_binary_format.md fixes independently:

    40  inline counter bumps outside any loop
  +  8  a 4-trip loop bumping twice per pass   (the four requirement pairs)
  +  4  RefData_ReadStringField calls outside a loop
  +  5  RefData_ReadStringField inside a 5-trip loop  (the five asset strings)
  +  1  FUN_006b1a80, the schema-driven field skipper
  ----
    58

Three things a naive scan gets wrong, each of which shifts every later index:

  * A BUMP INSIDE A LOOP executes once per iteration and appears once in the
    instruction stream.
  * HELPERS CONSUME FIELDS. RefData_ReadStringField and the schema skipper bump
    the counter in the callee, so a call is worth as many fields as the callee
    bumps.
  * THE READER REGISTER IS NOT FIXED -- esi in RefObjItem, edi in RefObjCommon.
    Hardcoding one silently reports zero fields for the other.
"""
import sys, re as R, collections
sys.path.insert(0, "/var/tmp")
import rebox as X

SZ = {"BYTE": 1, "WORD": 2, "DWORD": 4, "QWORD": 8}
BUMP = R.compile(r"^(?:add|inc)\s+DWORD PTR \[(e[a-z]{2})\+0x28\](?:,.*)?$")
JMP = R.compile(r"^(j\w+)\s+0x([0-9a-f]+)$")
CALL = R.compile(r"^call\s+0x([0-9a-f]+)$")

_bumps_in = None
def bumps_in(addr, fs):
    """How many fields a function consumes, counting its own loops."""
    global _bumps_in
    if _bumps_in is None:
        _bumps_in = {}
        for a, t in X.asm():
            if BUMP.match(t.strip()):
                f = X.owner(a, fs)
                if f:
                    _bumps_in.setdefault(f["addr"], []).append(a)
    hits = _bumps_in.get(addr, [])
    if not hits:
        return 0
    f = X.owner(addr, fs)
    trips = loop_trips(f["addr"], f["addr"] + f["size"])
    return sum(trips.get(a, 1) for a in hits)

def loop_trips(lo, hi):
    """address of an instruction -> trip count of the innermost loop over it.

    ONE FORWARD PASS, and that matters. An earlier version built the stack-slot
    counter map in a separate pass first, so a later `mov [esp+0x1c],ecx` with
    ecx=1 overwrote the `mov [esp+0x1c],eax` with eax=4 that the requirement-
    pair loop depends on -- and the loop silently counted 2 fields instead of 8.
    The value that matters is the one live AT the loop's branch.

    A trip count reaches its slot two ways and both are needed: directly as an
    immediate, or through a register.
    """
    rows = [(a, t.strip()) for a, t in X.asm() if lo <= a < hi]
    setc = R.compile(r"^mov\s+DWORD PTR \[esp([+-]0x[0-9a-f]+)?\],(0x[0-9a-f]+)$")
    setr = R.compile(r"^mov\s+DWORD PTR \[esp([+-]0x[0-9a-f]+)?\],(e[a-z]{2})$")
    imm = R.compile(r"^mov\s+(e[a-z]{2}),(0x[0-9a-f]+)$")
    dec = R.compile(r"^sub\s+DWORD PTR \[esp([+-]0x[0-9a-f]+)?\],(?:ecx|0x1)$")
    cmpn = R.compile(r"^cmp\s+(e[a-z]{2}),(0x[0-9a-f]+)$")
    clob = R.compile(r"^(?:mov|add|sub|xor|inc|dec|and|or|lea|pop|movzx|movsx)\s+(e[a-z]{2})\b")
    trips, counters, regval = {}, {}, {}
    pend = None
    for a, t in rows:
        m = imm.match(t)
        if m:
            regval[m.group(1)] = int(m.group(2), 16); continue
        m = setc.match(t)
        if m:
            counters[m.group(1) or ""] = int(m.group(2), 16); continue
        m = setr.match(t)
        if m:
            slot = m.group(1) or ""
            if m.group(2) in regval:
                counters[slot] = regval[m.group(2)]
            else:
                counters.pop(slot, None)
            continue
        m = dec.match(t)
        if m:
            pend = m.group(1) or ""; continue
        m = cmpn.match(t)
        if m:
            pend = ("cmp", int(m.group(2), 16)); continue
        m = JMP.match(t)
        if m:
            if m.group(1) in ("jne", "jl", "jb"):
                tgt = int(m.group(2), 16)
                if lo <= tgt <= a:
                    n = pend[1] if isinstance(pend, tuple) else counters.get(pend)
                    if n and 1 < n <= 64:
                        for aa, _ in rows:
                            if tgt <= aa <= a:
                                trips[aa] = n
            pend = None
            continue
        m = clob.match(t)
        if m:
            regval.pop(m.group(1), None)
    return trips

def scan(lo, hi, fs):
    """Field index -> record offset for one ExtractData body.

    THE RECORD POINTER LIVES IN MORE THAN ONE REGISTER. RefObjCommon_ExtractData
    spills it to [esp+0x14] at entry and reloads it into esi and into ebx at
    different points, and also builds short-lived walking pointers off it with
    `lea ebx,[esi+0xb8]`. Picking the single busiest store register -- which an
    earlier version did -- resolved the ebx stores (0xd8..0x184) and silently
    dropped the esi ones (0x80..0xd8), which is the range holding +0xa4.

    So identity is propagated instead: the incoming `this` (ecx, thiscall) is
    the record; a stack slot written from a record register is the record; a
    register loaded from such a slot is the record; `lea R,[record+N]` makes R a
    walking pointer at a known displacement.
    """
    rows = [(a, t.strip()) for a, t in X.asm() if lo <= a < hi]
    rc = collections.Counter(BUMP.match(t).group(1) for _, t in rows if BUMP.match(t))
    RD = rc.most_common(1)[0][0] if rc else "esi"
    trips = loop_trips(lo, hi)

    base = {"ecx": 0}          # register -> displacement from the record
    slots = {}                 # esp slot -> displacement from the record
    out, idx, pending = [], 0, None

    spill = R.compile(r"^mov\s+DWORD PTR \[esp([+-]0x[0-9a-f]+)?\],(e[a-z]{2})$")
    fill = R.compile(r"^mov\s+(e[a-z]{2}),DWORD PTR \[esp([+-]0x[0-9a-f]+)?\]$")
    leab = R.compile(r"^lea\s+(e[a-z]{2}),\[(e[a-z]{2})([+-]0x[0-9a-f]+)?\]$")
    movr = R.compile(r"^mov\s+(e[a-z]{2}),(e[a-z]{2})$")
    adv = R.compile(r"^add\s+(e[a-z]{2}),(0x[0-9a-f]+)$")
    store = R.compile(r"^(?:mov|fstp)\s+(BYTE|WORD|DWORD|QWORD) PTR \[(e[a-z]{2})([+-]0x[0-9a-f]+)?\]")
    clob = R.compile(r"^(?:mov|movzx|movsx|xor|pop|sub|and|or|imul|inc|dec)\s+(e[a-z]{2})\b")

    for a, t in rows:
        m = spill.match(t)
        if m:
            slot = m.group(1) or ""
            if m.group(2) in base: slots[slot] = base[m.group(2)]
            else: slots.pop(slot, None)
            continue
        m = fill.match(t)
        if m:
            slot = m.group(2) or ""
            if slot in slots: base[m.group(1)] = slots[slot]
            else: base.pop(m.group(1), None)
            continue
        m = leab.match(t)
        if m:
            src = m.group(2); o = m.group(3)
            if src in base: base[m.group(1)] = base[src] + (int(o, 16) if o else 0)
            else: base.pop(m.group(1), None)
            continue
        m = movr.match(t)
        if m:
            if m.group(2) in base: base[m.group(1)] = base[m.group(2)]
            else: base.pop(m.group(1), None)
            continue
        m = adv.match(t)
        if m and m.group(1) in base:
            base[m.group(1)] += int(m.group(2), 16); continue
        m = store.match(t)
        if m and m.group(2) in base:
            o = m.group(3)
            pending = (base[m.group(2)] + (int(o, 16) if o else 0), SZ[m.group(1)]); continue
        m = CALL.match(t)
        if m:
            n = bumps_in(int(m.group(1), 16), fs)
            if n:
                for _ in range(n * trips.get(a, 1)):
                    idx += 1
                    out.append((idx, None, None, "helper"))
                pending = None
            # a call clobbers the volatile registers
            for r in ("eax", "ecx", "edx"): base.pop(r, None)
            continue
        if BUMP.match(t):
            n = trips.get(a, 1)
            for step in range(n):
                idx += 1
                if pending:
                    off, sz = pending
                    out.append((idx, off + step * sz, sz, "read"))
                else:
                    out.append((idx, None, None, "read"))
            pending = None
            continue
        m = clob.match(t)
        if m and not (movr.match(t) or fill.match(t) or leab.match(t)):
            base.pop(m.group(1), None)
    return out, idx, RD, "record"

if __name__ == "__main__":
    fs = X.funcs()
    for arg in sys.argv[1:]:
        f = X.owner(int(arg, 16), fs)
        if not f:
            print("%s: no function" % arg); continue
        fields, total, RD, REC = scan(f["addr"], f["addr"] + f["size"], fs)
        res = sum(1 for x in fields if x[1] is not None)
        print("=== %s @%08x  reader=%s record=%s ===" % (f["name"], f["addr"], RD, REC))
        print("    %d fields, %d offsets resolved" % (total, res))
        for i, off, sz, kind in fields:
            print("    field %-3d %s %s" % (
                i, ("+0x%-4x %d byte%s" % (off, sz, "s" if sz > 1 else " ")) if off is not None
                   else "  (offset unresolved)", kind))
