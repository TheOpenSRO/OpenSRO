#!/usr/bin/env python3
# vt_owner.py -- which class DECLARES a function that many vtables share.
# RUNS ON THE RE BOX (192.168.10.78): reads /var/tmp/vt_server.json (the cached
# vtable index vtq.py uses) and /var/tmp/decomp_server/index.txt.
#
#     scp tools/vt_owner.py root@192.168.10.78:/var/tmp/
#     ssh root@192.168.10.78 'cd /var/tmp && python3 vt_owner.py'
#
# WHY IT EXISTS. docs/RE_LOOP.md instructs "`vtq.py owner <addr>` decides
# between the two" when a name sits on a folded or inherited function.
# **That command does not exist** -- vtq.py has vt, diff, who, family and bases
# and never had owner (round 417). This implements the rule the doc describes:
# among the classes whose vtable holds the address, the declaring class is the
# most base-like (the shortest vtable), provided the function sits at the same
# slot index in all of them.
#
# THE RULE IS NOT VALIDATED, AND THIS TOOL MUST NOT BE USED TO RENAME IN BULK
# UNTIL IT IS. Round 417 tried to control it against the dump's own
# "RTTI hierarchy:" plates and got 23.8 % agreement -- which is NOT a refutation,
# because those chains are truncated: they routinely stop before the root
# (`CGObjCOS_Mercenary : CGObjCOS_Summoned : CGObjCOS : CGObjNPC` never reaches
# CGObj/IGObj/CBase). A control that cannot distinguish "rule wrong" from
# "chain incomplete" is evidence for neither. A real control needs the full
# hierarchy read out of the COL's ClassHierarchyDescriptor.
#
# What it is good for meanwhile: ONE address at a time, where the answer can be
# checked against something independent. Round 417 used it that way on
# 0x484a20, where the rule's answer (CGObj) matches that function's own plate.
#
# Census as of round 417: 444 class-qualified names sit on functions shared by
# >= 10 vtables; the rule agrees with 131 prefixes, calls 291 wrong, and cannot
# decide 22. RE_LOOP.md's figure of "240" is a different, smaller population.

import json, collections
IDX = json.load(open("/var/tmp/vt_server.json"))
CLS = IDX["classes"]
addr2 = collections.defaultdict(list)   # addr -> [(cls, slot, vtlen)]
for cls, vts in CLS.items():
    for vt in vts:
        sl = vt["slots"]
        for i, a in enumerate(sl):
            addr2[a].append((cls, i, len(sl)))
names = {}; sizes = {}
for line in open("/var/tmp/decomp_server/index.txt"):
    p = line.rstrip("\n").split("\t")
    if len(p) >= 3:
        names[int(p[0], 16)] = p[1]; sizes[int(p[0], 16)] = int(p[2])

def owner(a):
    ent = addr2.get(a, [])
    if not ent: return None, "not in any vtable", ent
    slots = {s for _, s, _ in ent}
    if len(slots) != 1: return None, "slot disagrees (%s)" % sorted(slots)[:5], ent
    cls = min(ent, key=lambda e: e[2])[0]
    return cls, "shortest of %d vtables, slot %d" % (len(ent), next(iter(slots))), ent

print("=== the two functions this thread stumbled over ===")
for probe in (0x4aa590, 0x484a20):
    c, why, ent = owner(probe)
    print("%08x size=%-5s %-46s -> declaring=%-16s [%s]" %
          (probe, sizes.get(probe, "?"), names.get(probe, "?")[:46], c, why))

print()
print("=== CENSUS: class-qualified names on functions in >=10 vtables ===")
tot = 0; bad = []; agree = 0; nodecide = 0
for a, ent in addr2.items():
    if len(ent) < 10: continue
    n = names.get(a)
    if not n or "::" not in n: continue
    tot += 1
    c, why, _ = owner(a)
    if c is None: nodecide += 1; continue
    if c == n.split("::")[0]: agree += 1
    else: bad.append((len(ent), a, n, c, sizes.get(a, 0)))
print("class-qualified names shared by >=10 vtables : %d" % tot)
print("   the rule AGREES with the current prefix   : %d" % agree)
print("   the rule cannot decide (slot disagrees)   : %d" % nodecide)
print("   the rule says the prefix is WRONG         : %d" % len(bad))
bad.sort(reverse=True)
print()
print("%-10s %5s %6s  %-44s %s" % ("addr", "vts", "size", "current", "declaring"))
for n_, a, cur, decl, sz in bad[:20]:
    print("%08x %5d %6d  %-44s %s" % (a, n_, sz, cur[:44], decl))
