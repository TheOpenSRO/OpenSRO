"""fields.py <addr> -- read a sequential deserializer's field order.

These ExtractData functions read a record field by field from a cursor:

    mov edx,[esi+0x1c]                 ; cursor
    mov eax,[esi+0x18]                 ; buffer base
    mov <reg>,<sz> PTR [edx+eax*1]     ; load
    mov <sz> PTR [ebx+OFF],<reg>       ; store into the record
    add DWORD PTR [esi+0x1c],WIDTH     ; advance
    add DWORD PTR [esi+0x28],edi       ; FIELD COUNTER += 1

The counter is what makes this work: walking in address order and counting it
gives field index -> struct offset, which is the mapping a column layout needs.
"""
import sys, re as R
sys.path.insert(0,"/var/tmp"); import rebox as X

SZ = {"BYTE": 1, "WORD": 2, "DWORD": 4, "QWORD": 8}

def scan(lo, hi):
    """Walk the deserializer and pair each field-counter bump with its store.

    Three store shapes appear and all three are needed:

      int    mov <reg>,<sz> PTR [edx+eax*1] ; mov <sz> PTR [ebx+OFF],<reg>
      float  fld DWORD PTR [cursor] ; fstp DWORD PTR [ebx+OFF]
      float  lea edi,[ebx+B] ; (add edi,4 ; fstp DWORD PTR [edi-4]) xN

    The third is a short unrolled loop over a run of floats, and it accounts for
    most of the fields a naive scan misses.
    """
    rows = [(a, t) for a, t in X.asm() if lo <= a < hi]

    # WHICH REGISTER HOLDS THE READER IS NOT FIXED. RefObjItem::ExtractData uses
    # esi and RefObjCommon_ExtractData uses edi, so hardcoding one silently
    # reports zero fields for the other -- which is how this was found. Detect
    # it: the reader is whichever register the field counter at +0x28 is bumped
    # through, and the record is whichever register the stores are based on.
    import collections as _c
    rc = _c.Counter()
    for _a, _t in rows:
        _m = R.match(r"add\s+DWORD PTR \[(e[a-z]{2})\+0x28\],", _t.strip())
        if _m: rc[_m.group(1)] += 1
    RD = rc.most_common(1)[0][0] if rc else "esi"
    sc = _c.Counter()
    for _a, _t in rows:
        _m = R.match(r"(?:mov|fstp)\s+(?:BYTE|WORD|DWORD|QWORD) PTR \[(e[a-z]{2})[+\]]", _t.strip())
        if _m and _m.group(1) != RD: sc[_m.group(1)] += 1
    RB = sc.most_common(1)[0][0] if sc else "ebx"
    WALK = "edi" if RD != "edi" else "esi"

    # LOOP TRIP COUNTS MATTER AND A NAIVE SCAN GETS THEM WRONG. Several runs of
    # fields are short counted loops:
    #
    #     mov DWORD PTR [esp+0x14],0x2     ; trip count
    #   top:
    #     ... read one field ...
    #     add DWORD PTR [esi+0x28],ecx     ; the counter, executed EVERY pass
    #     sub DWORD PTR [esp+0x14],ecx
    #     jne top
    #
    # Counting instructions instead of executions undercounts the fields and
    # shifts every later index. Each bump is therefore multiplied by the trip
    # count of the innermost loop containing it, and a float run through `edi`
    # emits its offsets at the stride the loop advances by.
    trips = {}            # address of a bump -> trip count
    counters = {}         # esp slot -> (value, address it was set at)
    loopstart = {}        # esp slot -> where the decrement's branch goes back to
    setc = R.compile(r"^mov\s+DWORD PTR \[esp([+-]0x[0-9a-f]+)?\],(0x[0-9a-f]+)$")
    dec  = R.compile(r"^sub\s+DWORD PTR \[esp([+-]0x[0-9a-f]+)?\],ecx$")
    jne  = R.compile(r"^jne\s+0x([0-9a-f]+)$")
    pend_dec = None
    for k, (a, t) in enumerate(rows):
        t = t.strip()
        m = setc.match(t)
        if m:
            counters[m.group(1) or ""] = (int(m.group(2), 16), a); continue
        m = dec.match(t)
        if m:
            pend_dec = m.group(1) or ""; continue
        m = jne.match(t)
        if m and pend_dec is not None and pend_dec in counters:
            n, _ = counters[pend_dec]
            back = int(m.group(1), 16)
            for aa, tt in rows:
                if back <= aa < a and tt.strip().startswith("add    DWORD PTR [" + RD + "+0x28]"):
                    trips[aa] = n
            pend_dec = None
        elif m:
            pend_dec = None

    out, idx, pending = [], 0, None
    edi = None          # current ebx-relative value of edi, when known
    load  = R.compile(r"^mov\s+(\w+),(BYTE|WORD|DWORD|QWORD) PTR \[edx\+eax\*1\]$")
    fload = R.compile(r"^fld\s+DWORD PTR \[(edx\+eax|eax\+edx)\*1\]$")
    lea   = R.compile(r"^lea\s+" + WALK + r",\[" + RB + r"([+-]0x[0-9a-f]+)?\]$")
    leao  = R.compile(r"^lea\s+" + WALK + r",\[(?!" + RB + r")")
    addedi= R.compile(r"^add\s+" + WALK + r",(0x[0-9a-f]+)$")
    store = R.compile(r"^mov\s+(BYTE|WORD|DWORD|QWORD) PTR \[" + RB + r"([+-]0x[0-9a-f]+)?\],\w+$")
    fstpb = R.compile(r"^fstp\s+DWORD PTR \[" + RB + r"([+-]0x[0-9a-f]+)?\]$")
    fstpe = R.compile(r"^fstp\s+DWORD PTR \[" + WALK + r"([+-]0x[0-9a-f]+)?\]$")
    bump  = R.compile(r"^add\s+DWORD PTR \[" + RD + r"\+0x28\],")
    seen = None
    for a, t in rows:
        t = t.strip()
        m = lea.match(t)
        if m:
            o = m.group(1); edi = int(o, 16) if o else 0; continue
        if leao.match(t):
            edi = None; continue
        m = addedi.match(t)
        if m:
            if edi is not None: edi += int(m.group(1), 16)
            continue
        if load.match(t):  seen = "int";   continue
        if fload.match(t): seen = "float"; continue
        m = store.match(t)
        if m and seen:
            o = m.group(2)
            pending = (int(o, 16) if o else 0, SZ[m.group(1)], "int"); seen = None; continue
        m = fstpb.match(t)
        if m and seen:
            o = m.group(1)
            pending = (int(o, 16) if o else 0, 4, "float"); seen = None; continue
        m = fstpe.match(t)
        if m and seen and edi is not None:
            o = m.group(1)
            pending = (edi + (int(o, 16) if o else 0), 4, "float"); seen = None; continue
        if bump.match(t):
            n = trips.get(a, 1)
            for step in range(n):
                idx += 1
                if pending:
                    off, sz, kind = pending
                    out.append((idx, off + step * sz, sz, kind))
                else:
                    out.append((idx, None, None, None))
            pending = None
    return out, idx

for arg in sys.argv[1:]:
    a = int(arg, 16)
    f = X.owner(a, X.funcs())
    if not f:
        print("%s: no function" % arg); continue
    fields, total = scan(f["addr"], f["addr"] + f["size"])
    named = [x for x in fields if x[1] is not None]
    print("=== %s @%08x size=%d ===" % (f["name"], f["addr"], f["size"]))
    print("    %d fields (loop trips expanded), %d with a resolved store offset" % (total, len(named)))
    for i, off, sz, kind in fields:
        if off is None:
            print("    field %-3d  (store not matched)" % i)
        else:
            print("    field %-3d  +0x%-4x  %d byte%s  %s" % (i, off, sz, "s" if sz > 1 else " ", kind))
