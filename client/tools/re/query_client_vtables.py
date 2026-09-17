import json, collections, re, glob
idx = json.load(open("/var/tmp/vt_client.json"))["classes"]
names = {}
for l in open("/var/tmp/decomp_client/index.txt"):
    f = l.rstrip("\n").split("\t")
    if len(f) >= 2:
        try: names[int(f[0], 16)] = f[1]
        except ValueError: pass
hier = {}
for path in sorted(glob.glob("/var/tmp/decomp_client/funcs_*.c")):
    for line in open(path, errors="replace"):
        m = re.search(r"RTTI hierarchy: ([A-Za-z0-9_:]+(?: : [A-Za-z0-9_:]+)+)", line)
        if m:
            parts = [p.strip() for p in m.group(1).split(" : ")]
            hier.setdefault(parts[0], parts)
WND = {"CGWndBase", "CGWnd", "CIFWnd", "CNIFWnd"}
multi = sum(1 for c, t in idx.items() if len(t) > 1)
print("classes with more than one vtable: %d of %d" % (multi, len(idx)))
# every (class, table) pair that has a slot 10
pairs = []
for cls, tables in idx.items():
    for t in tables:
        if len(t["slots"]) > 10:
            pairs.append((cls, t["slots"][10]))
print("class/table pairs with a slot 10: %d" % len(pairs))
win = [(c, a) for c, a in pairs if WND & set(hier.get(c, []))]
print("  of window classes: %d" % len(win))
# how many of those point at a function the dump named after THAT class
ownfn = [(c, a) for c, a in win if names.get(a, "").startswith(c + "::")]
print("  whose slot 10 is a function the dump attributes to that same class: %d" % len(ownfn))
withcreate = 0
bodies = {}
cur = None
want = {a for _, a in ownfn}
for path in sorted(glob.glob("/var/tmp/decomp_client/funcs_*.c")):
    for line in open(path, errors="replace"):
        if line.startswith("===FUNC=== "):
            cur = int(line.split()[1], 16); continue
        if cur in want and '"Create"' in line:
            bodies[cur] = True
print("  of those, bodies containing the literal \"Create\": %d" % len(bodies))
json.dump({c: a for c, a in ownfn}, open("/var/tmp/slot10_window_own.json", "w"))
