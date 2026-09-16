#!/usr/bin/env python3
"""Find the executable code the decompilation dump CANNOT see.

WHY THIS EXISTS. Every RE census in this project greps
/var/tmp/decomp_server -- "who calls X", "who writes offset Y", "how many call
sites are there". Those greps are a census over *what Ghidra recovered*, not
over the binary. On 2026-09-16 that difference produced a wrong, committed
conclusion: an enumeration found eleven SetBodyMode call sites, none of which
gave berserk a duration, and concluded berserk had no timer. The berserk
activation handler sits in a region Ghidra never turned into a function, so it
was absent from the dump entirely. It was the twelfth call site, and berserk
lasts 60 seconds.

WHAT IT MEASURES. .text minus every (start, size) in the dump's index.txt, with
padding filtered out by an int3/zero-density heuristic.

  server dump, 2026-09-16:
    .text                    7,176,192 bytes
    indexed                  5,936,050 (82.7%)
    uncovered                1,242,362 (17.3%) in 31,578 gaps
    game-logic band          6.1% invisible, 145 real-code gaps, ~30 KB

HOW TO USE IT. Before publishing any conclusion that rests on an enumeration,
run --calls with the addresses that enumeration depends on. If a gap calls one
of them, the enumeration is incomplete and objdump is the only way to finish it.

    python3 dump_gaps.py                      # the gap map
    python3 dump_gaps.py --calls 4a9fc0,4b3510  # do gaps call these?
"""
import argparse
import collections
import re
import struct
import subprocess

EXE = "/var/tmp/SR_GameServer.exe"
INDEX = "/var/tmp/decomp_server/index.txt"

# The band where game logic lives. Above this is CRT, template and network
# infrastructure, where a gap is uninteresting.
BAND_LO, BAND_HI = 0x401000, 0x700000


def text_section(data):
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    nsec = struct.unpack_from("<H", data, pe + 6)[0]
    optsz = struct.unpack_from("<H", data, pe + 20)[0]
    base = struct.unpack_from("<I", data, pe + 24 + 28)[0]
    off = pe + 24 + optsz
    for _ in range(nsec):
        name = data[off:off + 8].rstrip(b"\x00").decode("latin1")
        vsz = struct.unpack_from("<I", data, off + 8)[0]
        va, _rsz, ptr = struct.unpack_from("<III", data, off + 12)
        if name == ".text":
            return base + va, vsz, ptr
        off += 40
    raise SystemExit("no .text section")


def gaps(data, tstart, tvsz, tptr):
    fns = []
    for line in open(INDEX):
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 3:
            try:
                fns.append((int(parts[0], 16), int(parts[2])))
            except ValueError:
                pass
    fns.sort()
    out, cur = [], tstart
    for addr, size in fns:
        if addr > cur:
            out.append((cur, addr - cur))
        cur = max(cur, addr + size)
    if cur < tstart + tvsz:
        out.append((cur, tstart + tvsz - cur))
    return fns, out


def looks_like_code(data, tstart, tptr, addr, size):
    """Padding is mostly int3 or zero; real code is neither."""
    blob = data[tptr + (addr - tstart):tptr + (addr - tstart) + size]
    if not blob:
        return False
    return blob.count(b"\xcc") / len(blob) < 0.30 and blob.count(b"\x00") / len(blob) < 0.35


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--calls", help="comma-separated hex addresses to look for")
    ap.add_argument("--min-size", type=int, default=64)
    args = ap.parse_args()

    data = open(EXE, "rb").read()
    tstart, tvsz, tptr = text_section(data)
    fns, allgaps = gaps(data, tstart, tvsz, tptr)

    real = [(a, s) for a, s in allgaps
            if BAND_LO <= a < BAND_HI and s >= args.min_size
            and looks_like_code(data, tstart, tptr, a, s)]

    if not args.calls:
        covered = sum(s for _, s in fns)
        unc = sum(s for _, s in allgaps)
        print(".text 0x%08x-0x%08x  %d bytes" % (tstart, tstart + tvsz, tvsz))
        print("  indexed    %d (%.1f%%)" % (covered, 100 * covered / tvsz))
        print("  uncovered  %d (%.1f%%) in %d gaps" % (unc, 100 * unc / tvsz, len(allgaps)))
        print()
        print("real-code gaps in the game-logic band: %d, %d bytes" %
              (len(real), sum(s for _, s in real)))
        for a, s in sorted(real, key=lambda g: -g[1])[:20]:
            print("  0x%08x  %6d bytes" % (a, s))
        return

    watch = {int(x, 16) for x in args.calls.split(",")}
    hits = collections.defaultdict(list)
    for a, s in real:
        out = subprocess.run(
            ["objdump", "-d", "--start-address=%d" % a, "--stop-address=%d" % (a + s),
             "-M", "intel", EXE], capture_output=True, text=True).stdout
        for m in re.finditer(r"call   0x([0-9a-f]+)", out):
            t = int(m.group(1), 16)
            if t in watch:
                hits[t].append(a)
    if not hits:
        print("No gap calls any of those addresses -- the enumeration is safe.")
        return
    print("INCOMPLETE: code the dump cannot see calls these. Finish with objdump.")
    for t in sorted(hits):
        where = sorted(set(hits[t]))
        print("  0x%06x  in %d gap(s): %s" % (t, len(where), ", ".join("0x%x" % w for w in where)))


if __name__ == "__main__":
    main()
