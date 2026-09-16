#!/usr/bin/env python3
"""Attribute unnamed server functions to a game domain by the error codes they return.

The server refuses an action by returning a 16-bit code, and
`docs/protocol/error_codes.md` maps 605 of those to the client's own message
name. A function that returns `UIIT_MSG_GUILDERR_*` codes is guild code, whatever
Ghidra called it. This joins the two and reports the attribution.

THE 0x100 FLOOR IS THE WHOLE TRICK, and leaving it out makes this tool lie.
Error codes start at 1, and `mov eax,0x2` is overwhelmingly "return 2" rather
than "return PARTYERR_UNKNOWN_ERROR". Without a floor:

    unnamed functions "returning an error code"   704
    ...of which return ONLY codes below 0x100     587
    0x0002 alone attributed to                    381 functions

which produced a first run claiming 329 unnamed functions were party code. With
the floor the same join gives 117 unnamed functions and 87 single-domain
attributions, which is a believable shape for a game server. A collision between
a small enum and a small return value is invisible unless you look for it.

WHAT THIS PRODUCES IS AN ATTRIBUTION, NOT A NAME. "This function returns guild
errors" says which part of the game it belongs to; it does not say what it does.
The dump already carries call-graph attributions phrased the same careful way.

Usage:
    label_by_error_code.py --codes /var/tmp/errcodes.tsv \
                           --index /var/tmp/decomp_server/index.txt \
                           --asm   /var/tmp/srgs.asm
"""

import argparse
import bisect
import collections
import re
import sys

# Below this, a "code" is far more likely an ordinary small return value.
CODE_FLOOR = 0x100

RETURN_RE = re.compile(r"^\s+([0-9a-f]+):\t[0-9a-f ]+\tmov\s+(?:ax|eax),0x([0-9a-f]+)$")

# UIIT_MSG_<DOMAIN>ERR_..., UIIT_STT_<DOMAIN>..., UIIT_MGS_... (the engine's typo)
PREFIXES = ("UIIT_MSG_", "UIIT_MGS_", "UIIT_STT_", "UIIT_CTL_", "UIIT_")
DOMAIN_RE = re.compile(r"([A-Z0-9]+?)_?ERR(?:OR)?_")
KNOWN = ("SKILL", "QUEST", "PARTY", "GUILDWAR", "GUILD", "ARENA", "FORT", "TRADE",
         "ALCHEMY", "COSPET", "COS", "EXCHANGE", "ACADEMY", "FLEAMARKET",
         "MAGICOPTION", "STORAGE", "INTERACTION", "SPECIALTY", "SOCKET")


def domain(name):
    n = name
    for p in PREFIXES:
        if n.startswith(p):
            n = n[len(p):]
            break
    m = DOMAIN_RE.match(n)
    if m:
        return m.group(1)
    for k in KNOWN:
        if n.startswith(k):
            return k
    return None


def load_codes(path):
    out = {}
    for line in open(path):
        c, n = line.rstrip("\n").split("\t")
        v = int(c, 16)
        if v >= CODE_FLOOR:
            out[v] = n
    return out


def load_funcs(path):
    funcs = []
    for line in open(path):
        p = line.rstrip("\n").split("\t")
        if len(p) >= 3:
            funcs.append((int(p[0], 16), p[1], int(p[2])))
    funcs.sort()
    return funcs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--codes", default="/var/tmp/errcodes.tsv")
    ap.add_argument("--index", default="/var/tmp/decomp_server/index.txt")
    ap.add_argument("--asm", default="/var/tmp/srgs.asm")
    ap.add_argument("--out", help="write the attributions as TSV here")
    args = ap.parse_args()

    codes = load_codes(args.codes)
    funcs = load_funcs(args.index)
    starts = [a for a, _, _ in funcs]

    def owner(addr):
        i = bisect.bisect_right(starts, addr) - 1
        if i < 0:
            return None
        a, n, sz = funcs[i]
        return (a, n) if addr < a + sz else None

    byfunc = collections.defaultdict(set)
    for line in open(args.asm, errors="replace"):
        m = RETURN_RE.match(line)
        if not m:
            continue
        v = int(m.group(2), 16)
        if v not in codes:
            continue
        o = owner(int(m.group(1), 16))
        if o:
            byfunc[o].add(v)

    unnamed = {k: v for k, v in byfunc.items() if "FUN_" in k[1]}
    print(f"functions returning a code >= {CODE_FLOOR:#x}: {len(byfunc)}")
    print(f"  already named: {len(byfunc) - len(unnamed)}   still FUN_: {len(unnamed)}")

    attributed, mixed, none = {}, 0, 0
    for k, cs in unnamed.items():
        ds = {domain(codes[c]) for c in cs}
        ds.discard(None)
        if len(ds) == 1:
            attributed[k] = (ds.pop(), sorted(codes[c] for c in cs))
        elif ds:
            mixed += 1
        else:
            none += 1

    print(f"  attributable to one domain: {len(attributed)}")
    print(f"  mixed domains: {mixed}   no domain derivable: {none}")

    bydom = collections.Counter(d for d, _ in attributed.values())
    print("\ndomain            functions")
    for d, n in bydom.most_common():
        print(f"  {d:<16} {n}")

    if args.out:
        with open(args.out, "w") as fh:
            for (a, n), (d, names) in sorted(attributed.items()):
                fh.write(f"{a:08x}\t{n}\t{d}\t{';'.join(names)}\n")
        print(f"\nwrote {args.out} ({len(attributed)} attributions)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
