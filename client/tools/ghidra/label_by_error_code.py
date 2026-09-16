import re, collections, bisect

codes = {}
for line in open('/var/tmp/errcodes.tsv'):
    c, n = line.rstrip('\n').split('\t')
    codes[int(c, 16)] = n

funcs = []
for line in open('/var/tmp/decomp_server/index.txt'):
    p = line.rstrip('\n').split('\t')
    if len(p) >= 3:
        funcs.append((int(p[0], 16), p[1], int(p[2])))
funcs.sort()
starts = [a for a, _, _ in funcs]

def owner(addr):
    i = bisect.bisect_right(starts, addr) - 1
    if i < 0:
        return None
    a, n, sz = funcs[i]
    return (a, n) if addr < a + sz else None

pat = re.compile(r'^\s+([0-9a-f]+):\t[0-9a-f ]+\tmov\s+(ax|eax),0x([0-9a-f]+)$')
byfunc = collections.defaultdict(set)
for line in open('/var/tmp/srgs.asm', errors='replace'):
    m = pat.match(line)
    if not m:
        continue
    v = int(m.group(3), 16)
    if v not in codes:
        continue
    o = owner(int(m.group(1), 16))
    if o:
        byfunc[o].add(v)

named   = {k: v for k, v in byfunc.items() if 'FUN_' not in k[1]}
unnamed = {k: v for k, v in byfunc.items() if 'FUN_' in k[1]}
print(f"functions returning a known error code: {len(byfunc)}")
print(f"   already named: {len(named)}   still FUN_: {len(unnamed)}")

print("\n=== unnamed functions whose codes say what they do (most codes first) ===")
for (a, n), cs in sorted(unnamed.items(), key=lambda kv: -len(kv[1]))[:18]:
    names = sorted(codes[c] for c in cs)
    print(f"  {a:08x} {n}")
    for x in names[:5]:
        print(f"        {x}")
    if len(names) > 5:
        print(f"        ... +{len(names)-5}")
