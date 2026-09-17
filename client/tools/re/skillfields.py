#!/usr/bin/env python3
"""skillfields.py -- recover CRefSkill's field offsets from the param parser.

`SkillGlobal::RefSkill_ParseParams` (0x00587630, 7,509 bytes) walks a skill's
Param stream as (code, values...) runs and stores each value into a field of the
CRefSkill record. That makes it a complete code -> offset map, which is what
turns a blind `skill+0x4a4` in the combat code into a named field.

THE TRAP THIS TOOL EXISTS TO AVOID, and which the first version walked straight
into. MSVC compiles a large switch on sparse values as a BINARY SEARCH TREE of
comparisons, not an if-else chain. So the nearest preceding `cmp reg,CODE` before
a store is NOT the code that matched -- it is whichever tree node was visited
last on the way down. Pairing stores with the nearest preceding comparison
produces a map that is plausible, monotonic, and wrong: it gave `pdm2 -> 0x234`
where Combat_ResolveDamage's own comment says 0x234 is `pdmg`, and `resu ->
0x3a0` where docs/protocol/skill_params.md says 0x3a0 is `reqi`.

The fix is to follow control flow rather than proximity: a case body is the
target of a `je` from the comparison that MATCHED. `ja`/`jb` are tree
navigation and must be ignored. This tool collects `cmp reg,IMM ; je TARGET`
pairs and attributes the block at TARGET to IMM.

VERIFICATION. Three independent anchors, none of them used to build the map:

  * `pdmg -> 0x234` matches the existing Ghidra comment on Combat_ResolveDamage,
    "the skill's damage params (skill+0x234 'pdmg', +0x238)".
  * `da -> 0x240` matches docs/protocol/skill_params.md's section on `da`, "a
    conditional damage percentage", and Combat_ResolveDamage tests
    `[ebx+0x240] != 0` immediately after the magical mitigation call.
  * `pw -> 0x2b4` matches that page's "Where `pw` is read".

COVERAGE, stated rather than implied. The parser compares 188 distinct printable
codes; 120 case bodies are reached by a `je`; 119 of those contain a direct
field store, and this tool reports those.

It does NOT report codes whose values go into a LIST rather than a field --
`reqi` fills a five-slot array and `att` is six words, per the function's own
header comment -- because those are written in a loop whose body sits past a
conditional branch. Their absence from the output is a limit of the tool, NOT
evidence that the code has no field. Do not read this map as complete.

Usage:  python3 skillfields.py
"""
import sys, re, struct, collections

sys.path.insert(0, "/var/tmp")
import rebox as X

PARSER, SIZE = 0x587630, 7509

CMP = re.compile(r"^cmp\s+([a-z0-9]+)\s*,\s*0x([0-9a-f]+)$")
JE = re.compile(r"^je\s+0x([0-9a-f]+)$")
STORE = re.compile(
    r"^mov\s+(?:BYTE |WORD |DWORD )?PTR \[e(?!sp)([a-z][a-z])(?:\+e[a-z][a-z](?:\*[0-9])?)?\+0x([0-9a-f]{2,4})\]"
)


def as_code(v):
    """A param code is a C multi-char literal, stored big-endian."""
    try:
        raw = struct.pack(">I", v)
    except struct.error:
        return None
    s = raw.decode("latin-1").replace("\0", "")
    return s if re.fullmatch(r"[A-Za-z0-9_]{1,4}", s or "") else None


def main():
    ins = [(a, t.strip()) for a, t in X.asm() if PARSER <= a < PARSER + SIZE]
    at = {a: i for i, (a, _) in enumerate(ins)}

    # cmp reg,CODE ; je TARGET  -- the equality test, not the tree navigation.
    cases = collections.defaultdict(set)
    for i, (_, text) in enumerate(ins):
        m = CMP.match(text)
        if not m:
            continue
        code = as_code(int(m.group(2), 16))
        if not code:
            continue
        for j in range(i + 1, min(i + 3, len(ins))):
            mj = JE.match(ins[j][1])
            if mj:
                cases[int(mj.group(1), 16)].add(code)
                break

    fields = collections.defaultdict(set)
    for target, codes in cases.items():
        if target not in at:
            continue
        for j in range(at[target], min(at[target] + 40, len(ins))):
            text = ins[j][1]
            m = STORE.match(text)
            if m:
                off = int(m.group(2), 16)
                if off >= 0x20:
                    for c in codes:
                        fields[c].add(off)
            if re.match(r"^(jmp|ret)\b", text):
                break

    print("case bodies reached by a je: %d" % len(cases))
    print("codes with a direct field store: %d" % len(fields))
    print()
    for code in sorted(fields, key=lambda c: min(fields[c])):
        print("%-6s %s" % (code, ", ".join("0x%x" % o for o in sorted(fields[code]))))


if __name__ == "__main__":
    main()
