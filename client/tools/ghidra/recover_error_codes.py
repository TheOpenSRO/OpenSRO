#!/usr/bin/env python3
"""Recover the server error code -> client message-name table from sro_client.exe.

The server refuses an action by returning a 16-bit code (0x300d "wrong weapon",
0x18fe "container full", …). Those numbers mean nothing on their own; the client
turns each into a message, and `UI_SILKMALL::FUN_007b8b40` is where it happens —
one 10 KB function of nested switches over the code.

WHY THE DECOMPILED C IS NOT ENOUGH. Every case ends in a call to a helper that
takes the message name as a wide string, but the argument arrives in a register
and Ghidra renders the call with no arguments at all:

    case 0x180f:
      RefData_worldmapguidedata::FUN_0046e3d0();

so reading the dump suggests the mapping is data-driven and unrecoverable. It is
not. In the disassembly the string is right there:

    7b8ca6:  push 0xdc7ea0          <- pointer to a UTF-16 message name
    7b8cab:  lea  ecx,[esp+0x3c]
    7b8caf:  call 0x46e3d0

MSVC compiles these as sparse switches, so a case value is recovered through two
tables:

    sub   eax, <base>
    cmp   eax, <count>          ; ja -> default
    movzx ecx, BYTE PTR [eax + <index table>]
    jmp   DWORD PTR [ecx*4 + <jump table>]

giving `case base+i -> jumptable[indextable[i]]`. This walks that, then reads the
string each target pushes.

Usage:
    recover_error_codes.py --exe /opt/sro-files/client/sro_client.exe
"""

import argparse
import collections
import re
import struct
import subprocess
import sys

# From `objdump -h sro_client.exe`.
SECTIONS = [
    (0x00401000, 0x00001000, 0x0097F000),  # .text
    (0x00D80000, 0x00980000, 0x0012E000),  # .rdata
    (0x00EAE000, 0x00AAE000, 0x0003A000),  # .data
]

DISPATCHER = (0x007B8B40, 0x007BB380)
HELPER = 0x0046E3D0

INSN = re.compile(r"\s+([0-9a-f]+):\t[0-9a-f ]+\t(\S+)\s*(.*)")


def load(exe):
    return open(exe, "rb").read()


def off(va):
    for base, foff, size in SECTIONS:
        if base <= va < base + size:
            return foff + (va - base)
    return None


def u8(img, va):
    o = off(va)
    return img[o] if o is not None else None


def u32(img, va):
    o = off(va)
    return struct.unpack_from("<I", img, o)[0] if o is not None else None


def wstr(img, va, limit=128):
    """Read a NUL-terminated UTF-16LE string."""
    o = off(va)
    if o is None:
        return None
    out = []
    for i in range(limit):
        ch = struct.unpack_from("<H", img, o + 2 * i)[0]
        if ch == 0:
            break
        if ch < 32 or ch > 126:
            return None  # not the ASCII-ish identifier we are after
        out.append(chr(ch))
    return "".join(out) or None


def disassemble(exe, lo, hi):
    out = subprocess.run(
        ["objdump", "-d", f"--start-address={lo:#x}", f"--stop-address={hi:#x}",
         "-M", "intel", exe],
        capture_output=True, text=True).stdout
    ins = []
    for line in out.splitlines():
        m = INSN.match(line)
        if m:
            ins.append((int(m.group(1), 16), m.group(2), m.group(3).strip()))
    return ins


def string_at_target(img, ins, idx_by_addr, target, span=24, pending=None, depth=0):
    """From a case target, the message name it pushes before calling the helper.

    THE JUMP MUST BE FOLLOWED WITH THE PUSH STILL IN HAND. Most cases do not call
    the helper themselves -- they push the string and jump to a shared tail that
    does the `lea ecx,[buf]; call`:

        7b90c7:  push 0xdc6ca8
        7b90cc:  jmp  0x7b966d      <- the tail makes the call

    An earlier version of this walker treated a `jmp` as the end of the block
    whenever a push was outstanding, and so threw away precisely the cases that
    use the shared tail -- which is most of them, and all of the 0x30xx family.
    """
    i = idx_by_addr.get(target)
    if i is None or depth > 6:
        return None
    for addr, mn, op in ins[i:i + span]:
        m = re.fullmatch(r"0x([0-9a-f]+)", op)
        if mn == "push" and m:
            pending = int(m.group(1), 16)
        elif mn == "call" and pending is not None:
            t = int(op.split()[-1], 16)
            if t == HELPER:
                return wstr(img, pending)
            pending = None
        elif mn == "jmp":
            t = int(op.split()[-1], 16) if op.startswith("0x") else None
            if t is None:
                break
            return string_at_target(img, ins, idx_by_addr, t, span, pending, depth + 1)
        elif mn == "ret":
            break
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", default="/opt/sro-files/client/sro_client.exe")
    ap.add_argument("--out", help="write the table as TSV here")
    args = ap.parse_args()

    img = load(args.exe)
    ins = disassemble(args.exe, *DISPATCHER)
    idx_by_addr = {a: i for i, (a, _, _) in enumerate(ins)}

    mapping = {}
    for i, (addr, mn, op) in enumerate(ins):
        m = re.fullmatch(r"(e[a-z]x)\*4\+0x([0-9a-f]+)", op.replace("DWORD PTR [", "").rstrip("]"))
        if mn != "jmp" or not m:
            continue
        jmptab = int(m.group(2), 16)
        # Walk back for the index table and the case base.
        idxtab = base = count = None
        for a2, mn2, op2 in reversed(ins[max(0, i - 12):i]):
            mm = re.search(r"BYTE PTR \[e[a-z]x\+0x([0-9a-f]+)\]", op2)
            if mn2 == "movzx" and mm and idxtab is None:
                idxtab = int(mm.group(1), 16)
            ms = re.fullmatch(r"e[a-z]x,0x([0-9a-f]+)", op2)
            if ms and base is None:
                v = int(ms.group(1), 16)
                if mn2 == "sub":
                    base = v
                elif mn2 == "add" and v >= 0x80000000:
                    # MSVC normalises the case base with an ADD of a negative
                    # immediate as often as with a SUB: `add eax,0xffffcffd` is
                    # `eax -= 0x3003`. Missing this shape cost the entire 0x30xx
                    # family, 70 cases including 0x300d.
                    base = (1 << 32) - v
            if mn2 == "cmp" and ms and count is None:
                count = int(ms.group(1), 16)
        if base is None or count is None:
            continue
        for k in range(count + 1):
            if idxtab is not None:
                # Sparse switch: an extra byte table selects the jump slot.
                sel = u8(img, idxtab + k)
                if sel is None:
                    break
                target = u32(img, jmptab + 4 * sel)
            else:
                # Dense switch: the jump table is indexed by the case directly.
                target = u32(img, jmptab + 4 * k)
            if target is None or not (DISPATCHER[0] <= target < DISPATCHER[1]):
                continue
            s = string_at_target(img, ins, idx_by_addr, target)
            if s and s.startswith("UIIT_"):
                # Keyed by (switch table, code): the dispatcher selects a
                # CATEGORY first and only then the code, so the same 16-bit
                # value means different things in different categories. Merging
                # them into one code->name dict silently invents mappings.
                mapping.setdefault((jmptab, base + k), s)

    # Collapse to code -> {names}. A code with one name is unambiguous; a code
    # with several is category-dependent and must not be used to label anything
    # without knowing which category the caller is in.
    by_code = collections.defaultdict(set)
    for (_, code), name in mapping.items():
        by_code[code].add(name)
    solo = {c: next(iter(v)) for c, v in by_code.items() if len(v) == 1}
    multi = {c: sorted(v) for c, v in by_code.items() if len(v) > 1}

    print(f"(category, code) pairs resolved: {len(mapping)}")
    print(f"distinct codes:                  {len(by_code)}")
    print(f"  unambiguous (one name):        {len(solo)}")
    print(f"  category-dependent:            {len(multi)}")
    for code, names in sorted(multi.items())[:6]:
        print(f"     0x{code:04x}  {' | '.join(names[:3])}{' ...' if len(names) > 3 else ''}")
    if args.out:
        with open(args.out, "w") as fh:
            for code, name in sorted(solo.items()):
                fh.write(f"0x{code:04x}\t{name}\n")
        print(f"wrote {args.out} ({len(solo)} unambiguous codes)")
        amb = args.out.replace(".tsv", "_ambiguous.tsv")
        with open(amb, "w") as fh:
            for code, names in sorted(multi.items()):
                fh.write(f"0x{code:04x}\t{';'.join(names)}\n")
        print(f"wrote {amb} ({len(multi)} category-dependent codes)")
    return 0 if mapping else 1


if __name__ == "__main__":
    sys.exit(main())
