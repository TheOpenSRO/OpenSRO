"""Name derived overrides from a base class that already named the slot.

The rule, and its guards:
  * the slot must carry a real name on an ANCESTOR (not FUN_/vslot_/thunk_, not a
    destructor -- that is boilerplate already handled);
  * the derived function must differ from the ancestor's (else it is inherited and
    naming it would put a derived name on base code);
  * the dump must attribute the function to THIS class, which rejects functions
    folded across several classes;
  * the function must still be an unnamed vslot_NNN placeholder.
"""
import json, re, sys, glob, collections

dump, vtpath, binary = sys.argv[1], sys.argv[2], sys.argv[3]
idx = json.load(open(vtpath))["classes"]
names = {}
for l in open(dump + "/index.txt"):
    f = l.rstrip("\n").split("\t")
    if len(f) >= 2:
        try: names[int(f[0], 16)] = f[1]
        except ValueError: pass
hier = {}
for path in sorted(glob.glob(dump + "/funcs_*.c")):
    for line in open(path, errors="replace"):
        m = re.search(r"RTTI hierarchy: ([A-Za-z0-9_:]+(?: : [A-Za-z0-9_:]+)+)", line)
        if m:
            parts = [p.strip() for p in m.group(1).split(" : ")]
            hier.setdefault(parts[0], parts)

def real_name(addr, cls=None):
    n = names.get(addr, "")
    leaf = n.split("::")[-1]
    if not n or leaf.startswith(("FUN_", "vslot_", "thunk_", "LAB_")): return None
    if leaf == "ScalarDeletingDestructor": return None
    if cls and not n.startswith(cls + "::"): return None
    return leaf

# how many distinct classes list a given function (folding detector)
inclasses = collections.Counter()
for cls, tables in idx.items():
    seen = set()
    for t in tables:
        for a in t["slots"]:
            if a not in seen: seen.add(a); inclasses[a] += 1

rows, stats = [], collections.Counter()
for cls, chain in hier.items():
    if cls not in idx or len(chain) < 2: continue
    for t in idx[cls]:
        for i, addr in enumerate(t["slots"]):
            cur = names.get(addr, "")
            if not re.search(r"::vslot_\d+$", cur): continue
            if cur.split("::")[0] != cls: stats["attributed elsewhere"] += 1; continue
            if inclasses[addr] > 1: stats["shared across classes"] += 1; continue
            # find the nearest ancestor naming this slot
            got = None
            for anc in chain[1:]:
                for at in idx.get(anc, []):
                    if len(at["slots"]) > i and at["slots"][i] != addr:
                        nm = real_name(at["slots"][i], anc)
                        if nm: got = (anc, nm); break
                if got: break
            if not got: stats["no ancestor name"] += 1; continue
            anc, nm = got
            rows.append((addr, cls, nm, i, anc))
        break
print("%s: %d nameable overrides   %s" % (binary, len(rows), dict(stats)))
by = collections.Counter(r[4] for r in rows)
for anc, c in by.most_common(10):
    print("   from %-34s %d" % (anc[:34], c))
with open("/var/tmp/prop_%s.tsv" % binary, "w") as f:
    for addr, cls, nm, i, anc in rows:
        ev = ("vtable slot %d, named from the ancestor that already names it: %s::%s. This class "
              "derives %s, so the slot is one virtual across the hierarchy, and this function is "
              "THIS class's own override -- it differs from the ancestor's implementation, the dump "
              "attributes it to %s, and no other class's vtable points at it (so it is not a folded "
              "function shared between classes). Slots still holding the ancestor's own function were "
              "left alone, since naming those would put a derived class's name on base code."
              % (i, anc, nm, anc, cls))
        f.write("\t".join(["%08x" % addr, binary, "%s::%s" % (cls, nm), "reading", ev]) + "\n")
