#!/usr/bin/env python3
"""Walk a code-dispatch function branch by branch, scoped correctly.

WHY THIS EXISTS. This binary dispatches on four-character codes in several
places -- Stat_ApplyTaggedModifier on stat tags, the item-use handlers on item
effect codes -- and the useful question is always "what does the branch for code
X do". The obvious approach is to read N instructions after the comparison. It
does not work, and the way it fails is the dangerous kind.

On 2026-09-16 a fixed 80-instruction window run over the item-use dispatcher
reported that BCS1, BFI1, PSU1 and UIU1 all resolve to INC_INVENTORY_SIZE. Four
codes do not share one meaning; the window had simply run past the end of each
branch into the same neighbouring helper. The output looked like a result --
a tidy table, plausible entries, a method that had worked elsewhere -- and the
only tell was the uniformity.

THE FIX is to scope the walk to the branch: enter at the comparison's `je`
target (or the fall-through for `jne`), follow jumps, and STOP on reaching any
other code's comparison site or a `ret`. Re-run that way, exactly one code
resolves to INC_INVENTORY_SIZE -- the one independently verified by a direct
string reference inside its branch.

That is the control this tool is built around: if a walk attributes the same
answer to several codes, distrust the walk before believing the answer.

    python3 dispatch_walk.py --start 0x49f090 --end 0x4a0000 \
        --codes BCS1,BFI1,PSU1,UIL1,UIU1,UQL1,USL1,USU1
"""
import argparse
import re
import struct
import subprocess

EXE = "/var/tmp/SR_GameServer.exe"


def sections(data):
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    nsec = struct.unpack_from("<H", data, pe + 6)[0]
    optsz = struct.unpack_from("<H", data, pe + 20)[0]
    base = struct.unpack_from("<I", data, pe + 24 + 28)[0]
    off, out = pe + 24 + optsz, []
    for _ in range(nsec):
        vsz = struct.unpack_from("<I", data, off + 8)[0]
        va, rsz, ptr = struct.unpack_from("<III", data, off + 12)
        out.append((base + va, vsz, ptr, rsz))
        off += 40
    return out


def disasm(start, end):
    out = subprocess.run(
        ["objdump", "-d", "--start-address=%d" % start, "--stop-address=%d" % end,
         "-M", "intel", EXE], capture_output=True, text=True).stdout
    line = re.compile(r"^\s*([0-9a-f]+):\s+((?:[0-9a-f]{2} )+)\s*(\S+)\s*(.*)$")
    ins = {}
    for ln in out.splitlines():
        m = line.match(ln)
        if m:
            ins[int(m.group(1), 16)] = (m.group(3), m.group(4).split("#")[0].strip())
    order = sorted(ins)
    return ins, order, {order[i]: order[i + 1] for i in range(len(order) - 1)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--start", required=True)
    ap.add_argument("--end", required=True)
    ap.add_argument("--codes", required=True, help="comma-separated 4-char codes")
    ap.add_argument("--limit", type=int, default=250)
    args = ap.parse_args()

    data = open(EXE, "rb").read()
    secs = sections(data)

    def getstr(va):
        for sva, vsz, ptr, rsz in secs:
            if sva <= va < sva + max(vsz, rsz):
                sb = data[ptr + (va - sva):ptr + (va - sva) + 70].split(b"\x00")[0]
                if len(sb) >= 5 and all(32 <= c < 127 for c in sb):
                    return sb.decode("latin1")
        return None

    seen_callees = {}

    def callee_strings(fn):
        """Uppercase strings a called function references, one level deep."""
        if fn in seen_callees:
            return seen_callees[fn]
        out = subprocess.run(
            ["objdump", "-d", "--start-address=%d" % fn, "--stop-address=%d" % (fn + 0x140),
             "-M", "intel", EXE], capture_output=True, text=True).stdout
        res = []
        for mm in re.finditer(r"(?:push +|mov +\w+,)0x([0-9a-f]{6,8})", out):
            s = getstr(int(mm.group(1), 16))
            if s and s.replace("_", "").isalnum() and s.isupper() and len(s) > 6 and s not in res:
                res.append(s)
        seen_callees[fn] = res
        return res

    codes = {}
    for c in args.codes.split(","):
        codes[int.from_bytes(c.encode(), "big")] = c

    ins, order, nxt = disasm(int(args.start, 0), int(args.end, 0))

    cmpsites, starts = set(), []
    for a in order:
        mn, ops = ins[a]
        if mn != "cmp":
            continue
        m = re.search(r",0x([0-9a-f]{8})$", ops)
        if not m or int(m.group(1), 16) not in codes:
            continue
        cmpsites.add(a)
        b = nxt.get(a)
        if b and ins[b][0] == "je":
            starts.append((codes[int(m.group(1), 16)], int(ins[b][1].split()[0], 16)))
        elif b and ins[b][0] == "jne":
            starts.append((codes[int(m.group(1), 16)], nxt.get(b)))

    found = {}
    for code, st in starts:
        if st is None or code in found:
            continue
        seen, stack, strs, steps = set(), [st], [], 0
        while stack and steps < args.limit:
            a = stack.pop()
            steps += 1
            while a is not None and a in ins and a not in seen:
                seen.add(a)
                mn, ops = ins[a]
                if a in cmpsites and a != st:
                    break                      # another code's test: stop
                for mm in re.finditer(r"0x([0-9a-f]{6,8})", ops):
                    s = getstr(int(mm.group(1), 16))
                    if s and s.replace("_", "").isalnum() and s.isupper() and len(s) > 6 and s not in strs:
                        strs.append(s)
                # A branch often names itself only INSIDE a helper it calls --
                # BCS1's INC_INVENTORY_SIZE lives in GObjPC::FUN_00864aa0, not
                # in the branch. Follow calls one level; going deeper starts
                # picking up shared infrastructure and reintroduces exactly the
                # over-attribution this tool exists to avoid.
                if mn == "call":
                    m = re.match(r"^0x([0-9a-f]+)", ops)
                    if m:
                        for s in callee_strings(int(m.group(1), 16)):
                            if s not in strs:
                                strs.append(s)
                if mn == "ret":
                    break
                if mn == "jmp":
                    m = re.match(r"^0x([0-9a-f]+)", ops)
                    a = int(m.group(1), 16) if m else None
                    continue
                if mn.startswith("j"):
                    m = re.match(r"^0x([0-9a-f]+)", ops)
                    if m:
                        stack.append(int(m.group(1), 16))
                a = nxt.get(a)
        found[code] = strs

    for code in sorted(codes.values()):
        v = found.get(code, [])
        print("  %-6s %s" % (code, ", ".join(v[:3]) if v else "(no naming string in branch)"))

    hits = [c for c, v in found.items() if v]
    shared = len(hits) > 1 and len({tuple(found[c]) for c in hits}) == 1
    if shared:
        print("\nWARNING: every resolved code got the SAME answer. That is the signature of "
              "a walk escaping its branch, not of codes sharing a meaning. Distrust it.")


if __name__ == "__main__":
    main()
