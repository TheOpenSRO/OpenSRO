#!/usr/bin/env python3
"""Check every address in docs/protocol/recovered_names.tsv against the dumps.

`server/internal/refdata/recovered_names_test.go` guards the file's shape but
says in its own header that it "cannot check the addresses -- those live on the
RE box". This is the part it cannot do, and it runs where the dumps are.

Four outcomes per row, and the distinction between the last three is the point:

  start         the address is a function START in the claimed binary -- fine
  interior      it lands INSIDE a known function but not at its head, so the
                name is attached to a jump target or a mid-function offset
  wrong-binary  the address is not a function in the binary the row claims, but
                IS one in the other -- the mislabelling the Go test's header
                records having happened twice before
  outside       no function there in either dump

`outside` is NOT automatically a defect. The dumps have gaps: Ghidra never
defined some real functions, and `0x587260` (`SkillAction_Stance`) is the one
this project has already recorded. A new `outside` is worth reading before it
is called wrong -- check for a prologue at that address first.

Usage, on the RE box:

    python3 verify_recovered_addresses.py /path/to/recovered_names.tsv \\
        [--dumps /var/tmp]

Exit status is 1 if any row is `interior` or `wrong-binary`, which are always
defects; `outside` rows are reported and do not fail the run.
"""

import argparse
import sys
from pathlib import Path

# A name is attached to a function head; anything further in than this is not a
# plausible "the decompiler split the function" case, it is a different function.
INTERIOR_WINDOW = 4096

# Recorded gaps: addresses known to be real functions the dump never defined.
# Keep the reason with the address, so an entry can be retired when the dump is
# rebuilt rather than living on as folklore.
KNOWN_DUMP_GAPS = {
    ("server", 0x587260): "SkillAction_Stance -- real code Ghidra never defined (AGENTS.md)",
}


def load_index(path: Path) -> dict[int, int]:
    """address -> size, from a dump's index.txt."""
    starts: dict[int, int] = {}
    with path.open() as fh:
        for line in fh:
            fields = line.split("\t")
            if len(fields) < 3:
                continue
            try:
                addr = int(fields[0], 16)
                size = int(fields[2])
            except ValueError:
                continue
            starts[addr] = size
    return starts


def classify(addr: int, binary: str, indexes: dict[str, dict[int, int]]) -> str:
    table = indexes.get(binary)
    if table is None:
        return "unknown-binary"
    if addr in table:
        return "start"
    other = "client" if binary == "server" else "server"
    if addr in indexes.get(other, {}):
        return "wrong-binary"
    for start, size in table.items():
        if size and start <= addr < start + size and addr - start < INTERIOR_WINDOW:
            return "interior"
    return "outside"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("tsv", type=Path, help="docs/protocol/recovered_names.tsv")
    ap.add_argument("--dumps", type=Path, default=Path("/var/tmp"))
    args = ap.parse_args()

    indexes = {}
    for binary in ("server", "client"):
        index = args.dumps / f"decomp_{binary}" / "index.txt"
        if not index.exists():
            print(f"no dump index at {index}", file=sys.stderr)
            return 2
        indexes[binary] = load_index(index)

    counts: dict[str, int] = {}
    defects: list[tuple[str, str, str, str]] = []
    gaps: list[tuple[str, str, str]] = []
    rows = 0
    for line in args.tsv.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) < 3:
            continue
        rows += 1
        addr_text, binary, name = fields[0], fields[1], fields[2]
        try:
            addr = int(addr_text, 16)
        except ValueError:
            defects.append(("bad-address", addr_text, binary, name))
            continue
        verdict = classify(addr, binary, indexes)
        counts[verdict] = counts.get(verdict, 0) + 1
        if verdict in ("interior", "wrong-binary"):
            defects.append((verdict, addr_text, binary, name))
        elif verdict == "outside":
            reason = KNOWN_DUMP_GAPS.get((binary, addr))
            if reason:
                counts["outside-known-gap"] = counts.get("outside-known-gap", 0) + 1
                counts["outside"] -= 1
            else:
                gaps.append((addr_text, binary, name))

    print(f"{rows} rows checked against {len(indexes['server'])} server "
          f"and {len(indexes['client'])} client functions")
    for verdict in sorted(counts):
        print(f"  {verdict:20s} {counts[verdict]}")
    for verdict, addr_text, binary, name in defects:
        print(f"  DEFECT {verdict}: {addr_text} {binary} {name}")
    for addr_text, binary, name in gaps:
        print(f"  outside (unrecorded -- read it before calling it wrong): "
              f"{addr_text} {binary} {name}")
    return 1 if defects else 0


if __name__ == "__main__":
    raise SystemExit(main())
