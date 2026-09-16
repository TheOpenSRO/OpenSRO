#!/usr/bin/env python3
"""Recover virtual-function names and their vtable slots from SR_GameServer.exe.

The server's base classes implement most virtuals as a STUB that logs and
returns, so a derived class that forgets to override one is caught at runtime:

    CGameServer::FUN_00936640(0x2000000, "## Illegal ## IGObj::SetBodyMode TypeID: %u", ...)

Each such string names the method, in the binary's own words. Finding the stub's
address in .rdata then gives its slot, because a stub appears at the same index
in every vtable of the hierarchy.

WHY THE SLOT IS TRUSTWORTHY. The vtable base is found by walking backwards from
an entry until a dword is no longer a .text pointer -- the preceding slot is the
RTTI locator. That is a heuristic, so it is checked rather than assumed: the
SetBodyMode stub appears in 14 different vtables and this puts it at slot 198 in
all 14, matching the slot this project had already recovered independently from
the berserk activation handler. Four more slots (IsPC, GetLifeState,
GetBodyMode, GetParam) each land on a name that explains a call site the project
had been reading blind.

WHAT IT DOES NOT RECOVER: virtuals with no base-class stub. A method the base
declares pure, or that only derived classes have, leaves no string and so never
appears here. Slots 353, 372, 399 and 400 -- all four vtable calls in the
cast-requirement check -- are in that category, as is slot 224, a CGItem-family
accessor called 313 times.

A NAME AT TWO SLOTS IS NOT AMBIGUOUS, it is one of two things, and comparing the
implementations at both slots tells them apart:

  * the SAME function at both, in every vtable -- one method the layout lists
    twice, which is what multiple inheritance does. GetCurHP (66, 68) and
    GetCurMP (67, 69) are this.
  * DIFFERENT functions -- two distinct methods whose stubs share one log
    string, i.e. overloads. ExpandInventory (173, 174) and three others are
    this.

Either way both slots are real and both are reported.

Usage:
    recover_vtable_slots.py --exe /var/tmp/SR_GameServer.exe \
                            --dump /var/tmp/decomp_server
"""

import argparse
import collections
import glob
import os
import re
import struct
import sys

# Section layout, from `objdump -h SR_GameServer.exe`.
RDATA_VA, RDATA_OFF, RDATA_SZ = 0x00AD9000, 0x006D9000, 0x00188000
TEXT_LO, TEXT_HI = 0x00401000, 0x00AD9000

STUB_RE = re.compile(r"Illegal ##\s*([A-Za-z_]+::[A-Za-z_0-9]+)")
FUNC_RE = re.compile(r"===FUNC=== ([0-9a-f]+) (\S+)")


def find_stubs(dump_dir):
    """Map stub function address -> the method name its log string carries."""
    stubs = {}
    for path in sorted(glob.glob(os.path.join(dump_dir, "funcs_*.c"))):
        cur = None
        for line in open(path, errors="replace"):
            m = FUNC_RE.match(line)
            if m:
                cur = int(m.group(1), 16)
                continue
            s = STUB_RE.search(line)
            if s and cur is not None:
                stubs[cur] = s.group(1)
    return stubs


def resolve_slots(img, stubs):
    """For each stub, the vtable slot(s) it occupies."""

    def dw(va):
        return struct.unpack_from("<I", img, RDATA_OFF + (va - RDATA_VA))[0]

    def is_code(v):
        return TEXT_LO <= v < TEXT_HI

    where = collections.defaultdict(list)
    for i in range(0, RDATA_SZ - 4, 4):
        v = struct.unpack_from("<I", img, RDATA_OFF + i)[0]
        if v in stubs:
            where[v].append(RDATA_VA + i)

    slots = collections.defaultdict(set)
    tables = collections.defaultdict(set)
    bases = collections.defaultdict(set)
    for addr, entries in where.items():
        for e in entries:
            va = e
            while is_code(dw(va - 4)):
                va -= 4
            slots[stubs[addr]].add((e - va) // 4)
            tables[stubs[addr]].add(va)
            bases[stubs[addr]].add(va)
    return slots, tables, bases


def classify_multi(img, name, slot_list, vtables):
    """One method listed twice, or two overloads sharing a log string?

    Reads both slots in every vtable that CONTAINS THIS METHOD'S STUB. Scoping
    matters: slot 66 means something different in each of the ~274 vtables in
    this binary, so comparing it across all of them answers nothing. Only the
    tables in this method's own hierarchy are evidence about it.

    If those always hold the same function it is one method the layout lists
    twice; if they hold different ones they are distinct methods.
    """

    def dw(va):
        return struct.unpack_from("<I", img, RDATA_OFF + (va - RDATA_VA))[0]

    same = differ = 0
    for base, length in vtables:
        if length <= max(slot_list):
            continue
        vals = {dw(base + 4 * s) for s in slot_list}
        if len(vals) == 1:
            same += 1
        else:
            differ += 1
    if same and not differ:
        return "one method, duplicated slot (multiple inheritance)"
    if differ and not same:
        return "two distinct methods sharing a log string (overloads)"
    return f"mixed: same in {same} vtables, different in {differ}"


def find_vtables(img, min_len=40):
    """Runs of at least min_len consecutive .text pointers in .rdata."""

    def dwat(i):
        return struct.unpack_from("<I", img, RDATA_OFF + i)[0]

    out, start = [], None
    for i in range(0, RDATA_SZ - 4, 4):
        if TEXT_LO <= dwat(i) < TEXT_HI:
            if start is None:
                start = i
        else:
            if start is not None and (i - start) // 4 >= min_len:
                out.append((RDATA_VA + start, (i - start) // 4))
            start = None
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", default="/var/tmp/SR_GameServer.exe")
    ap.add_argument("--dump", default="/var/tmp/decomp_server")
    ap.add_argument("--check-slot", action="append",
                    help="Method=slot assertions; the tool exits 1 if one fails. "
                         "Defaults to the two slots this project recovered independently.")
    args = ap.parse_args()
    if not args.check_slot:
        # Both were recovered independently of this tool -- SetBodyMode from the
        # berserk activation handler, GetParam from the damage pipeline -- so a
        # failure here means the slot arithmetic is wrong, not the data.
        args.check_slot = ["IGObj::SetBodyMode=198", "IGObj::GetParam=65"]

    img = open(args.exe, "rb").read()
    stubs = find_stubs(args.dump)
    slots, tables, bases = resolve_slots(img, stubs)
    lengths = dict(find_vtables(img))

    single = {n: next(iter(s)) for n, s in slots.items() if len(s) == 1}
    ambiguous = {n: sorted(s) for n, s in slots.items() if len(s) > 1}

    print(f"stub methods found:      {len(stubs)}")
    print(f"resolved to one slot:    {len(single)}")
    print(f"ambiguous (two slots):   {len(ambiguous)}")

    rc = 0
    for spec in args.check_slot:
        name, _, want = spec.partition("=")
        got = single.get(name)
        ok = got == int(want)
        print(f"check {name} == slot {want}: "
              f"{'OK' if ok else f'FAILED (got {got})'} "
              f"across {len(tables.get(name, ()))} vtables")
        if not ok:
            rc = 1

    if ambiguous:
        print("\nnames at more than one slot -- both slots are real; which kind:")
        for n, ss in sorted(ambiguous.items()):
            own = [(b, lengths.get(b, 0)) for b in sorted(bases[n])]
            print(f"   {n:<44} {ss}  {classify_multi(img, n, ss, own)}"
                  f"  [{len(own)} vtables]")

    by_class = collections.defaultdict(list)
    for n, s in single.items():
        by_class[n.split("::")[0]].append((s, n.split("::", 1)[1]))
    # A name at two slots occupies both; emit both rather than dropping it.
    for n, ss in ambiguous.items():
        for s in ss:
            by_class[n.split("::")[0]].append((s, n.split("::", 1)[1]))
    print()
    for cls in sorted(by_class, key=lambda c: -len(by_class[c])):
        rows = sorted(by_class[cls])
        print(f"=== {cls} ({len(rows)} slots) ===")
        for s, m in rows:
            print(f"| {s} | `{cls}::{m}` |")
        print()
    return rc


if __name__ == "__main__":
    sys.exit(main())
