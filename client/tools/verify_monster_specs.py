#!/usr/bin/env python3
"""Check cmd/server's hardcoded monsterSpecs against the real client tables.

WHY. Those specs carry numbers this project calls GROUNDED -- each monster's
level, max HP, flat defence, critical chance and attack range, all said to come
from the client's own characterdata. "Grounded" is a claim about provenance, and
provenance rots: a transcription slip, a column that shifts between table
versions, or a species renamed upstream all leave the comment saying "real"
while the number drifts. This re-derives every one of them from the tables.

It also exercises the one genuinely DERIVED value. Level, MaxHP, Defense and
Critical are copied straight out of a characterdata column, but the attack range
is two hops: characterdata column 83 names a SKILL, and that skill's `att`
parameter carries the range. A two-hop chain is where an error would actually
hide.

RESULT, 2026-09-16 (first run): 44 direct fields and 11 attack ranges, 0
mismatches. The skill code names corroborate the chain independently --
MOB_CH_MANGNYANG's column 83 resolves to MSKILL_CH_MANGNYANG_ATTACK01.

RESULT, 2026-09-24 (round 536, the walk and run speeds, cols 46/47, added):
    specs without the speeds    55 verified, 0 mismatched, 0 unresolved
    specs with the speeds       77 verified, 0 mismatched, 0 unresolved
    control, Mangyang walk 9    76 verified, 1 mismatched (WalkSpeed spec=9 table=8)
so the 22 new fields are compared, not skipped. The specs carried Level,
MaxHP, Defense, Critical, AttackMin/AttackMax, WalkSpeed and RunSpeed for all
11 roster species, generated from cmd/server's monsterSpecs.

TRAPS, both of which cost a probe attempt each:
  * the tables are UTF-16 (BOM \\xff\\xfe), not ASCII
  * this project's characterdata column numbers are 0-INDEXED

Run it on the RE box, where the extracted tables live:
    python3 verify_monster_specs.py --specs specs.txt --tables /var/tmp/tables
"""
import argparse
import glob
import os

# 0-indexed field positions. See reference_characterdata_columns.
# WalkSpeed/RunSpeed are Speed1/Speed2 (cols 46/47, world units per second;
# round 362's table in docs/protocol/monster_ai.md). The table stores them as
# integers, so int() compares them without skipping a row.
COL = {"Level": 57, "Rarity": 15, "MaxHP": 59, "Defense": 71, "Block": 76, "Critical": 78,
       "WalkSpeed": 46, "RunSpeed": 47}
COL_ATTACK_SKILL = 83
ATT_CODE = "6386804"  # 0x617474, the 'att' multi-char literal as a decimal field


def load_rows(tables, prefix):
    out = {}
    for path in sorted(glob.glob(os.path.join(tables, prefix + "*.txt"))):
        try:
            text = open(path, encoding="utf-16").read()
        except (UnicodeError, OSError):
            continue
        for line in text.splitlines():
            parts = line.split("\t")
            if len(parts) < 20:
                continue
            key = parts[2] if prefix.startswith("character") else parts[1]
            out.setdefault(key, parts)
    return out


def att_range(row):
    """The (min, max) of a skill row's `att` parameter run."""
    for i, v in enumerate(row):
        if v == ATT_CODE:
            run = row[i + 1:i + 7]
            if len(run) >= 4:
                return run[2], run[3]
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--specs", required=True, help="code<TAB>name<TAB>K=V,K=V")
    ap.add_argument("--tables", default="/var/tmp/tables")
    args = ap.parse_args()

    chars = load_rows(args.tables, "characterdata_")
    skills = load_rows(args.tables, "skilldata_")

    ok = bad = unresolved = 0
    for line in open(args.specs):
        if not line.strip():
            continue
        code, _name, fields = line.rstrip("\n").split("\t")
        row = chars.get(code)
        if row is None:
            print("%-26s NOT IN characterdata" % code)
            unresolved += 1
            continue

        spec = dict(kv.split("=") for kv in fields.split(","))
        for key, idx in COL.items():
            if key not in spec:
                continue
            try:
                real = int(row[idx])
            except (ValueError, IndexError):
                continue
            if int(spec[key]) == real:
                ok += 1
            else:
                bad += 1
                print("%-26s %-9s spec=%-8s table=%s" % (code, key, spec[key], real))

        if "AttackMin" in spec and "AttackMax" in spec:
            srow = skills.get(row[COL_ATTACK_SKILL])
            rng = att_range(srow) if srow else None
            if rng is None:
                print("%-26s attack skill %s unresolved" % (code, row[COL_ATTACK_SKILL]))
                unresolved += 1
            elif (spec["AttackMin"], spec["AttackMax"]) == rng:
                ok += 1
            else:
                bad += 1
                print("%-26s attack    spec=%s-%s table=%s-%s" %
                      (code, spec["AttackMin"], spec["AttackMax"], rng[0], rng[1]))

    print("\n%d verified, %d mismatched, %d unresolved" % (ok, bad, unresolved))
    raise SystemExit(1 if bad else 0)


if __name__ == "__main__":
    main()
