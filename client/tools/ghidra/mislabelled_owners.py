#!/usr/bin/env python3
"""Find functions whose name credits the wrong class.

A vtable slot implemented once and shared by a whole hierarchy appears in many
classes' vtables. The RTTI walk that names it reaches one of those classes first
and labels the function with it -- and when that happens to be a DERIVED class,
the name actively misleads: `CGObjCOS_Summoned::EnterWorld` is not a summon's
function, it is the CGObjChar implementation every character shares.

That is worse than leaving it `FUN_`, because a reader greps past it.

The test is precise and uses only what the dump already records. A function's
header carries both

    RTTI: reached as A slot N, B slot N, ...
    RTTI hierarchy: Derived : ... : Base

so if the class in the NAME derives from another class that also reaches the
function, the name credits a descendant of the real owner.

What it cannot tell you: which class DECLARES the slot. The most ancestral class
in the RTTI list is a lower bound -- the declaring class may be further up still
and only an assert string will say. For CGObjChar::SetBodyMode the assert names
IGObj. So treat the output as "this name is wrong", not as "this is the name".

Usage: mislabelled_owners.py [/var/tmp/decomp_server]
"""
import glob
import os
import re
import sys

RTTI = re.compile(r"RTTI: reached as (.+?)Recovered by walking", re.S)
HIER = re.compile(r"RTTI hierarchy: ([^\n]+)")
SLOT = re.compile(r"(\w+) slot \d+")


def main() -> int:
    root = sys.argv[1] if len(sys.argv) > 1 else "/var/tmp/decomp_server"
    shards = sorted(glob.glob(os.path.join(root, "funcs_*.c")))
    if not shards:
        print("no dump at %s" % root, file=sys.stderr)
        return 2

    considered = 0
    bad = []
    for path in shards:
        text = open(path, encoding="utf-8", errors="replace").read()
        for block in text.split("===FUNC=== ")[1:]:
            head = block.split("\n")[0].split()
            if len(head) < 2:
                continue
            addr, name = head[0], head[1]
            parts = name.split("::")
            if len(parts) < 2:
                continue
            # The class is the component before the method, not the leading
            # namespace: "std::bad_alloc::vslot_000" is class bad_alloc, and
            # reading "std" as the class produced a 20x overcount once.
            owner = parts[-2]
            header = block[:3000]
            m, h = RTTI.search(header), HIER.search(header)
            if not m or not h:
                continue
            classes = set(SLOT.findall(m.group(1)))
            if len(classes) < 2:
                continue
            chain = [c.strip() for c in h.group(1).split(":")]
            if owner not in chain:
                continue
            considered += 1
            ancestors = [c for c in chain[chain.index(owner) + 1:] if c in classes]
            if ancestors:
                bad.append((addr, name, ancestors[-1], len(classes)))

    print("multi-class functions with a resolvable owner: %d" % considered)
    print("named after a class that DERIVES from another in the same list: %d" % len(bad))
    for addr, name, anc, n in sorted(bad):
        print("  %s  %-52s credits a descendant of %-18s (%d classes)" % (addr, name, anc, n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
