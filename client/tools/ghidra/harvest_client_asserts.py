#!/usr/bin/env python3
"""Harvest the client's assert calls: source file, line, and expression text.

The server's naming lever is its `## Illegal ##` virtual stubs. **The client has
none** — zero such strings — which left an open question about what it does have.
This is the answer: `sro_client.exe` ships with asserts intact, and each one
carries three useful things.

    FUN_0049e490(0x765, "D:\\vss-od\\Silkroad\\Client\\client\\CObjCharacter.cpp",
                 "dwSlotPos < EQUIP_VISUAL_COUNT");

- the **source file**, which attributes the enclosing function to a translation
  unit (123 distinct files)
- the **line number**, which orders functions within that file
- the **expression text**, which names variables, members and constants in the
  original source

READ THE EXPRESSION, NOT JUST THE GUARD. The guard above an assert gives the
numeric bound, but the operator in the expression decides the off-by-one:

    dwSlotPos < EQUIP_VISUAL_COUNT      guard `8 < p`    => 9
    m_btMagicParamNum <= MAX_MAGPARAM   guard `0xc < v`  => 12, NOT 13

Both shapes occur. Taking "one past the guard" as a rule would have made the
second constant wrong.

WHY THE OBVIOUS REGEX FAILS. Ghidra breaks the call across two lines, so a
line-oriented `grep` finds the file but loses the expression — a first pass
reported 34 distinct expressions where there are 307. This reads whole files.

Usage:
    harvest_client_asserts.py --dump /var/tmp/decomp_client --out asserts.tsv
"""

import argparse
import bisect
import collections
import glob
import os
import re
import sys

# CGame's assert reporter. Signature: (line, __FILE__, expression).
ASSERT_FN = "FUN_0049e490"

CALL = re.compile(
    ASSERT_FN + r'\(\s*(0x[0-9a-f]+|\d+)\s*,\s*"([^"]*\.cpp)"\s*,\s*"([^"]*)"', re.S)
FUNC = re.compile(r"===FUNC=== ([0-9a-f]+) (\S+)")


def harvest(dump):
    rows = []
    for path in sorted(glob.glob(os.path.join(dump, "funcs_*.c"))):
        text = open(path, errors="replace").read()
        bounds = [(m.start(), int(m.group(1), 16), m.group(2)) for m in FUNC.finditer(text)]
        starts = [b[0] for b in bounds]
        for m in CALL.finditer(text):
            i = bisect.bisect_right(starts, m.start()) - 1
            addr, name = bounds[i][1:] if i >= 0 else (0, "?")
            raw = m.group(1)
            line = int(raw, 16) if raw.startswith("0x") else int(raw)
            rows.append((addr, name, m.group(2).rsplit("\\", 1)[-1], line, m.group(3)))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump", default="/var/tmp/decomp_client")
    ap.add_argument("--out", help="write the rows as TSV here")
    args = ap.parse_args()

    rows = harvest(args.dump)
    if not rows:
        sys.exit(f"no assert calls found in {args.dump}")

    funcs = {r[0] for r in rows}
    unnamed = {r[0] for r in rows if "FUN_" in r[1]}
    print(f"assert sites:            {len(rows)}")
    print(f"distinct source files:   {len({r[2] for r in rows})}")
    print(f"distinct expressions:    {len({r[4] for r in rows})}")
    print(f"functions carrying one:  {len(funcs)}  (still FUN_: {len(unnamed)})")

    byfile = collections.Counter(r[2] for r in rows)
    print("\nsource files by assert count:")
    for f, n in byfile.most_common(15):
        print(f"   {f:<34} {n}")

    consts = collections.Counter()
    for _, _, _, _, e in rows:
        for c in re.findall(r"\b[A-Z][A-Z0-9_]{3,}\b", e):
            if c not in ("NULL", "TRUE", "FALSE", "DWORD", "WHAT", "MINUS"):
                consts[c] += 1
    print(f"\nnamed constants in expressions: {len(consts)}")
    for c, n in consts.most_common(20):
        print(f"   {c:<34} {n}")

    if args.out:
        with open(args.out, "w") as fh:
            for a, n, src, line, e in sorted(rows):
                fh.write(f"{a:08x}\t{n}\t{src}\t{line}\t{e}\n")
        print(f"\nwrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
