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
    trips, _, _ = loop_trips(f["addr"], f["addr"] + f["size"])
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
    strides, loops = {}, []
    adv = R.compile(r"^add\s+(e[a-z]{2}),(0x[0-9a-f]+)$")
    st = R.compile(r"^(?:mov|fstp)\s+(?:BYTE|WORD|DWORD|QWORD) PTR \[(e[a-z]{2})")
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
                        body = [(x, y) for x, y in rows if tgt <= x <= a]
                        # THE STRIDE IS THE LOOP'S OWN ADVANCE, not the field
                        # size. The requirement-pair loop walks ebx by 8 and
                        # stores a dword at [ebx-4] and a byte at [ebx]; using
                        # the field size reports 0xb4,0xb8,0xbc,0xc0 where the
                        # real stores are 0xb4,0xbc,0xc4,0xcc. So: find the
                        # register the body stores through, and the `add` it
                        # takes inside the body.
                        bases = collections.Counter(
                            st.match(y).group(1) for _, y in body
                            if st.match(y) and st.match(y).group(1) != "esp")
                        stride = None
                        if bases:
                            base_reg = bases.most_common(1)[0][0]
                            for _, y in body:
                                m2 = adv.match(y)
                                if m2 and m2.group(1) == base_reg:
                                    stride = int(m2.group(2), 16); break
                        loops.append((tgt, a, n, stride))
                        for aa, _ in rows:
                            if tgt <= aa <= a:
                                trips[aa] = n
                                if stride: strides[aa] = stride
            pend = None
            continue
        m = clob.match(t)
        if m:
            regval.pop(m.group(1), None)
    return trips, strides, loops

def scan(lo, hi, fs):
    """Field index -> record offset for one ExtractData body.

    ONE FORWARD PASS. Three things have to be right together, and each was got
    wrong on its own first:

    * THE RECORD POINTER LIVES IN MORE THAN ONE REGISTER. It is spilled to a
      stack slot at entry and reloaded into esi and ebx at different points, and
      short-lived walking pointers are built off it with `lea`. Identity is
      propagated rather than guessing one busiest register.
    * A LOOP'S STRIDE IS ITS OWN ADVANCE, not the field size. The requirement
      loop walks by 8 and stores a dword at [ebx-4] and a byte at [ebx].
    * A MULTI-BUMP LOOP BODY INTERLEAVES. That loop consumes dword, byte, dword,
      byte ... Emitting every iteration of the first store and then every
      iteration of the second gives the right offsets in the wrong ORDER, and
      the order is the column map. So a loop body is buffered and replayed.
    """
    rows = [(a, t.strip()) for a, t in X.asm() if lo <= a < hi]
    rc = collections.Counter(BUMP.match(t).group(1) for _, t in rows if BUMP.match(t))
    RD = rc.most_common(1)[0][0] if rc else "esi"
    trips, strides, loops = loop_trips(lo, hi)
    loop_at = {}
    for tgt, end, n, stride in loops:
        for a, _ in rows:
            if tgt <= a <= end:
                loop_at[a] = (tgt, end, n, stride)

    base = {"ecx": 0}
    slots = {}
    out, idx, pending = [], 0, None
    body, cur_loop = [], None

    spill = R.compile(r"^mov\s+DWORD PTR \[esp([+-]0x[0-9a-f]+)?\],(e[a-z]{2})$")
    fill = R.compile(r"^mov\s+(e[a-z]{2}),DWORD PTR \[esp([+-]0x[0-9a-f]+)?\]$")
    leab = R.compile(r"^lea\s+(e[a-z]{2}),\[(e[a-z]{2})([+-]0x[0-9a-f]+)?\]$")
    movr = R.compile(r"^mov\s+(e[a-z]{2}),(e[a-z]{2})$")
    advr = R.compile(r"^add\s+(e[a-z]{2}),(0x[0-9a-f]+)$")
    store = R.compile(r"^(?:mov|fstp)\s+(BYTE|WORD|DWORD|QWORD) PTR \[(e[a-z]{2})([+-]0x[0-9a-f]+)?\]")
    clob = R.compile(r"^(?:mov|movzx|movsx|xor|pop|sub|and|or|imul|inc|dec)\s+(e[a-z]{2})\b")

    def emit(pr, step, stride, kind="read"):
        nonlocal idx
        idx += 1
        if pr:
            off, sz = pr
            out.append((idx, off + step * (stride or sz), sz, kind))
        else:
            out.append((idx, None, None, kind))

    def flush():
        nonlocal body, cur_loop
        if cur_loop is None:
            return
        _, _, n, stride = cur_loop
        for step in range(n):
            for pr, kind in body:
                emit(pr, step, stride, kind)
        body, cur_loop = [], None

    for a, t in rows:
        L = loop_at.get(a)
        if cur_loop and (L is None or L[:2] != cur_loop[:2]):
            flush()
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
            src, o = m.group(2), m.group(3)
            if src in base: base[m.group(1)] = base[src] + (int(o, 16) if o else 0)
            else: base.pop(m.group(1), None)
            continue
        m = movr.match(t)
        if m:
            if m.group(2) in base: base[m.group(1)] = base[m.group(2)]
            else: base.pop(m.group(1), None)
            continue
        m = advr.match(t)
        if m and m.group(1) in base:
            # inside a loop the advance is the stride, already accounted for by
            # the replay -- applying it here as well would double-count
            if L is None:
                base[m.group(1)] += int(m.group(2), 16)
            continue
        m = store.match(t)
        if m and m.group(2) in base:
            o = m.group(3)
            pending = (base[m.group(2)] + (int(o, 16) if o else 0), SZ[m.group(1)])
            continue
        m = CALL.match(t)
        if m:
            n = bumps_in(int(m.group(1), 16), fs)
            if n:
                if L is not None:
                    cur_loop = L
                    for _ in range(n):
                        body.append((None, "helper"))
                else:
                    for _ in range(n):
                        idx += 1
                        out.append((idx, None, None, "helper"))
                pending = None
            for r in ("eax", "ecx", "edx"):
                base.pop(r, None)
            continue
        if BUMP.match(t):
            if L is not None:
                cur_loop = L
                body.append((pending, "read"))
            else:
                emit(pending, 0, None)
            pending = None
            continue
        m = clob.match(t)
        if m and not (movr.match(t) or fill.match(t) or leab.match(t)):
            base.pop(m.group(1), None)
    flush()
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
