#!/usr/bin/env python3
# core_reach.py -- measure the GAME-LOGIC CORE of SR_GameServer.exe, with and
# without virtual dispatch. RUNS ON THE RE BOX (192.168.5.78), where the dump
# lives; it reads /var/tmp/decomp_server and /var/tmp/roots408.txt (the 163
# handler addresses, column 2 of docs/protocol/server_handlers.tsv).
#
#     scp tools/core_reach.py root@192.168.5.78:/var/tmp/
#     cut -f2 docs/protocol/server_handlers.tsv | grep -E "^[0-9a-f]{8}$" \
#       | ssh root@192.168.5.78 "cat > /var/tmp/roots408.txt"
#     ssh root@192.168.5.78 "cd /var/tmp && python3 core_reach.py"
#
# It lives in the repo rather than only in /var/tmp because /var/tmp on that box
# has been cleared before (the full-disk trap in AGENTS.md), and round 408's
# result is the kind that gets re-measured.
#
# WHY IT EXISTS. Round 336b measured the core by walking a call graph built from
# call-BY-NAME edges, and recorded its own blind spot: "SLOTTED is 0 in the
# reachable set ... a name-based call graph cannot see virtual dispatch, and this
# engine dispatches through vtables constantly." Round 408 closed it by adding
# slot edges: a call through `*(code **)(*x + 0xNN)` links to every function the
# dump names `vslot_<NN/4>`.
#
# TWO CAVEATS THE OUTPUT DEPENDS ON:
#   * The slot model is an OVER-APPROXIMATION -- it ignores the receiver's static
#     type, so it links to every class's override. The virtual figure is an UPPER
#     bound and the name-only figure a LOWER bound; the core is bracketed.
#   * `vslot_NNN` is NOT a name. isname() excludes it, as this project requires.
#     Counting it as named inflates the virtual variant badly, since virtual
#     edges reach precisely those functions.
#
# The `bare-name fallback` variant resolves an unqualified callee when its bare
# name is unique. It is an UNSOUND widening -- it also matches Ghidra pseudo-ops
# and CRT helpers -- and is printed only as a sensitivity bound. The recorded
# method is `full-name edges only`, which is the row that reproduces round 336b.

import re,glob,collections
D='/var/tmp/decomp_server'
addr2name={}; name2addr=collections.defaultdict(list); bare2addr=collections.defaultdict(list)
slot2impl=collections.defaultdict(list)
VSLOT=re.compile(r'vslot_(\d+)$')
for line in open(D+'/index.txt'):
    p=line.rstrip('\n').split('\t')
    if len(p)<2: continue
    a=int(p[0],16); n=p[1]; addr2name[a]=n
    name2addr[n].append(a); bare2addr[n.split('::')[-1]].append(a)
    m=VSLOT.search(n.split('::')[-1])
    if m: slot2impl[int(m.group(1))].append(a)
CALL=re.compile(r'\b((?:[A-Za-z_][A-Za-z0-9_]*::)*[A-Za-z_][A-Za-z0-9_]*)\s*\(')
VIRT=re.compile(r'\*\(code \*\*\)\(\*[^)]{0,40}?\+ (0x[0-9a-f]+)\)')
dfull=collections.defaultdict(set); dbare=collections.defaultdict(set); virt=collections.defaultdict(set)
cur=None
for fn in sorted(glob.glob(D+'/funcs_*.c')):
    for line in open(fn,errors='ignore'):
        if line.startswith('===FUNC=== '): cur=int(line.split()[1],16); continue
        if cur is None: continue
        for m in VIRT.finditer(line):
            off=int(m.group(1),16)
            if off%4==0: virt[cur].add(off//4)
        for m in CALL.finditer(line):
            t=m.group(1)
            if t in name2addr:
                for a in name2addr[t]: dfull[cur].add(a)
            elif t in bare2addr and len(bare2addr[t])==1: dbare[cur].add(bare2addr[t][0])
roots=[int(l.strip(),16) for l in open('/var/tmp/roots408.txt') if l.strip()]
roots=[r for r in roots if r in addr2name]
def walk(bare,uv):
    seen=set(roots); q=list(roots)
    while q:
        f=q.pop(); nxt=set(dfull.get(f,()))
        if bare: nxt|=set(dbare.get(f,()))
        if uv:
            for s in virt.get(f,()): nxt.update(slot2impl.get(s,()))
        for a in nxt:
            if a not in seen: seen.add(a); q.append(a)
    return seen
def isname(a):
    b=addr2name[a].split('::')[-1]
    return not b.startswith('FUN_') and not b.startswith('vslot_')
def slotted(s): return sum(1 for a in s if addr2name[a].split('::')[-1].startswith('vslot_'))
CRT=0x009d0000
print('%-34s %6s %7s %8s %9s' % ('variant','reached','named%','belowCRT','named%'))
for lbl,bare,uv in (('full-name edges only',False,False),('+ bare-name fallback',True,False),
                    ('+ VIRTUAL (full only)',False,True),('+ VIRTUAL + bare',True,True)):
    s=walk(bare,uv); b={a for a in s if a<CRT}
    print('%-34s %6d %6.1f%% %8d %8.1f%%   SLOTTED reached %d' %
          (lbl,len(s),100.0*sum(1 for a in s if isname(a))/len(s),len(b),
           100.0*sum(1 for a in b if isname(a))/len(b),slotted(s)))

base=walk(False,False); ext=walk(False,True)
new={a for a in ext-base if a<CRT}
print()
print('NEWLY REACHED below CRT via virtual dispatch: %d' % len(new))
ns=collections.Counter(); nsu=collections.Counter()
for a in new:
    n=addr2name[a]; c=n.split('::')[0] if '::' in n else '<global>'
    ns[c]+=1
    if not isname(a): nsu[c]+=1
print('%-34s %6s %8s' % ('namespace','new','unnamed'))
for c,k in ns.most_common(16): print('%-34s %6d %8d' % (c[:34],k,nsu[c]))
print()
print('of the new, SLOTTED (vtable-slot-only) : %d' % sum(1 for a in new if addr2name[a].split('::')[-1].startswith('vslot_')))
print('of the new, plain FUN_                 : %d' % sum(1 for a in new if addr2name[a].split('::')[-1].startswith('FUN_')))
print('of the new, genuinely named            : %d' % sum(1 for a in new if isname(a)))
