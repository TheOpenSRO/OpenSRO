#!/usr/bin/env python3
"""Check docs/protocol/skill_params.md against a real client's skilldata.

The recovered parameter table is a set of claims about run lengths: each code
says how many words it consumes. This walks every real skilldata row's Param
block using those lengths and reports how each walk ends.

WHY THIS IS A REAL TEST AND NOT A TALLY. A wrong run length leaves the cursor on
a *value* instead of the next code, and everything after it in that row is
garbage -- so a bad entry shows up as FEWER cleanly-walked rows. It cannot pass
quietly. That is what makes "adding this code raised the clean count" evidence
rather than a coincidence.

WHAT IT DOES NOT TEST: field offsets. No walk ever reads a field, so a code
filed under the wrong offset walks exactly as well as a correct one. Three codes
(`pw`, `skc`, `br`) were mis-filed that way and none of them was caught here;
they were caught by reading the disassembly. Do not quote a clean-walk number as
though it validated a row whole.

Usage:
    verify_skill_params.py --doc docs/protocol/skill_params.md \
                           --skilldata '/path/to/skilldata_*.txt'

    # try a code that is not in the table yet, or override one that is
    verify_skill_params.py ... --try reqi=3 --try ssou=4

Exit status is 1 if any row ends on a code the table does not contain, so this
can gate a change to the table.
"""

import argparse
import collections
import glob
import re
import sys

# The Param block begins at column 69 of a skilldata row. Measured, not assumed:
# across every real row the `att` code appears at column 69 and never earlier.
PARAM_BLOCK_START = 69

# A row's Param block is 50 slots wide and padded with zeros, so a zero code
# terminates the stream rather than being an unknown code.
TERMINATOR = 0


def load_table(path):
    """Parse the fixed-run and variable-length tables out of the markdown.

    A fixed-run row is `| `tag` | 0xCONST | `field` | run | values |`; a
    variable-length row has no run column. The field cell is not required to be
    an address -- `setv` consumes a fixed run and stores nothing -- so the field
    is not parsed here at all. Only the run matters to a walk.
    """
    fixed, varlen, section = {}, set(), None
    for line in open(path, encoding="utf-8"):
        if line.startswith("## "):
            section = "var" if "Variable-length" in line else "fixed"
        m = re.match(r"\| `([^`]+)` \| (0x[0-9a-fA-F]{8}) \| `[^`]*` \|(?: *(\d+) \|)?", line)
        if not m:
            continue
        tag, run = int(m.group(2), 16), m.group(3)
        if run and section != "var":
            fixed.setdefault(tag, int(run))
        else:
            varlen.add(tag)
    return fixed, varlen


def load_rows(pattern):
    """Read skilldata rows as integer lists. Client tables are UTF-16 with a BOM."""
    rows = []
    for path in sorted(glob.glob(pattern)):
        if "hdr" in path:
            continue
        raw = open(path, "rb").read()
        enc = "utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "latin-1"
        for line in raw.decode(enc).splitlines():
            f = line.split("\t")
            if len(f) <= PARAM_BLOCK_START:
                continue
            while f and f[-1].strip() == "":
                f.pop()
            vals = []
            for x in f:
                try:
                    vals.append(int(x))
                except ValueError:
                    vals.append(None)
            rows.append(vals)
    return rows


def walk(vals, fixed, varlen):
    """Return how this row's Param block ends, and the code it ended on."""
    c = PARAM_BLOCK_START
    while c < len(vals):
        code = vals[c]
        if code is None:
            return "unknown", code
        if code == TERMINATOR:
            return "clean", None
        if code in varlen:
            return "varlen", code
        if code in fixed:
            c += fixed[code]
            continue
        return "unknown", code
    return "clean", None


def tagstr(code):
    b = code.to_bytes(4, "big").lstrip(b"\x00")
    return b.decode("latin-1") if all(32 <= c < 127 for c in b) else hex(code)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--doc", default="docs/protocol/skill_params.md")
    ap.add_argument("--skilldata", required=True, help="glob for skilldata_*.txt")
    ap.add_argument("--try", dest="extra", action="append", default=[],
                    help="tag=run to add or override, e.g. reqi=3")
    ap.add_argument("--show", type=int, default=12, help="how many stopping codes to list")
    args = ap.parse_args()

    fixed, varlen = load_table(args.doc)
    for spec in args.extra:
        tag, _, run = spec.partition("=")
        code = 0
        for ch in tag:
            code = (code << 8) | ord(ch)
        fixed[code] = int(run)
        varlen.discard(code)

    rows = load_rows(args.skilldata)
    if not rows:
        sys.exit(f"no skilldata rows matched {args.skilldata!r}")

    ends = collections.Counter()
    stopped_on = collections.Counter()
    for v in rows:
        how, code = walk(v, fixed, varlen)
        ends[how] += 1
        if how == "unknown" and code is not None:
            stopped_on[code] += 1

    total = len(rows)
    print(f"table: {len(fixed)} fixed-run + {len(varlen)} variable-length "
          f"= {len(fixed) + len(varlen)} codes")
    print(f"rows:  {total}")
    print(f"  clean       {ends['clean']:>6}  ({100.0 * ends['clean'] / total:.1f}%)")
    print(f"  varlen-stop {ends['varlen']:>6}   (expected: no length is stated)")
    print(f"  UNKNOWN     {ends['unknown']:>6}   (a code the table does not have)")

    if stopped_on:
        print(f"\ncodes the table is missing ({len(stopped_on)} distinct):")
        for code, n in stopped_on.most_common(args.show):
            print(f"   {tagstr(code):<8} 0x{code:08x}  {n:>6} rows")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
