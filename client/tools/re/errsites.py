#!/usr/bin/env python3
"""errsites.py -- attribute error codes to the server functions that raise them.

docs/protocol/error_codes.md recorded that its server-side scan matched only
`mov ax,0xNNNN` / `mov eax,0xNNNN` -- the shape of `return ERRORCODE` -- and so
missed every code that never passes through ax. This is the widened scan it
asked for. Measured 2026-09-17:

    (function, code) pairs   narrow 391   union 924
    functions reached        narrow 157   union 362

so 205 functions carrying a named refusal were invisible to the narrow pattern.
The shapes it missed, in order of yield:

    mov WORD PTR [reg],CODE     an out-parameter, the biggest single group
    mov DWORD PTR [esp+N],CODE  a stack local, which is how Mastery_LevelUp
                                raises 0x3804 and 0x3802
    push CODE                   passed to a sender rather than returned
    mov ebx,CODE / mov edi,CODE a callee-saved register
    cmp ax,CODE                 a caller TESTING for a code, which attributes
                                the handler as well as the raiser

TWO TRAPS, both of which produced wrong numbers before being fixed:

 1. **Displacements are not constants.** `mov ecx,DWORD PTR [esp+0x3003]` is a
    stack access, not the weapon-gate refusal. Bracketed expressions are blanked
    before the immediate scan; without that the function count came out 414
    instead of 362, i.e. 52 functions were pure noise.

 2. **Some codes are computed, not written.** The skill-use gate spells one
    refusal as `(-(ushort)(x != 0) & 0xfff1) + 0x3018`, which yields 0x3018 or
    0x3009 with neither appearing as an immediate. No pattern over immediates
    finds those, and this tool does not claim to.

Usage:  python3 errsites.py <codes.tsv> [--narrow]
where codes.tsv is `0xNNNN<space>NAME` per line, as extracted from
docs/protocol/error_codes.md's table.
"""
import sys, re, bisect, collections

sys.path.insert(0, "/var/tmp")
import rebox as X

BRACKETS = re.compile(r"\[[^\]]*\]")
# a constant is a source operand after a comma, or the operand of a push --
# never a displacement, which the blanking above has already removed.
IMMEDIATE = re.compile(r",\s*0x([0-9a-f]{3,8})\b|^push\s+0x([0-9a-f]{3,8})\b")
NARROW = re.compile(r"^mov\s+e?ax\s*,\s*0x")


def load_codes(path):
    codes = {}
    for line in open(path):
        parts = line.split()
        if len(parts) >= 2:
            codes[int(parts[0], 16)] = parts[1]
    return codes


def main(argv):
    if len(argv) < 2:
        return print(__doc__.strip())
    codes = load_codes(argv[1])
    narrow_only = "--narrow" in argv

    fns = sorted(X.funcs(), key=lambda f: f["addr"])
    starts = [f["addr"] for f in fns]

    def owner(a):
        i = bisect.bisect_right(starts, a) - 1
        if i < 0:
            return None
        f = fns[i]
        return f if a < f["addr"] + f["size"] else None

    per = collections.defaultdict(set)
    for addr, text in X.asm():
        text = text.strip()
        if not text.startswith(("mov", "push", "cmp")):
            continue
        clean = BRACKETS.sub("[]", text)
        if narrow_only and not NARROW.match(clean):
            continue
        for m in IMMEDIATE.finditer(clean):
            value = int(m.group(1) or m.group(2), 16)
            if value not in codes:
                continue
            f = owner(addr)
            if f:
                per[f["addr"]].add(value)

    print("functions carrying a named refusal: %d" % len(per))
    print("(function, code) pairs            : %d" % sum(len(v) for v in per.values()))
    print()
    by_addr = {f["addr"]: f for f in fns}
    for addr, values in sorted(per.items(), key=lambda kv: -len(kv[1])):
        f = by_addr[addr]
        names = [codes[v] for v in sorted(values)]
        print("%08x  %-46s %2d  %s" % (addr, f["name"][:46], len(values), ", ".join(names)))


if __name__ == "__main__":
    main(sys.argv)
