#!/usr/bin/env python3
"""Opcode -> payload sweep, v2 (round 466).

Fixes two defects measured in round 465:
  * appends are attributed to the NEAREST PRECEDING OPEN, not to the enclosing
    function, because one function can write to two different messages;
  * BOTH open idioms are detected --
        A:  mov reg,[this+0x278] ; push <opcode> ; call reg
        B:  mov reg,[buf+0x1050] ; mov WORD PTR [reg],<opcode>
An append with no open before it in the same function is reported as
UNATTRIBUTED rather than guessed -- that is the FUN_005bf7d0 case, where the
message was opened inside a helper.

Attribution is by ADDRESS ORDER, which is a heuristic: an append on a branch can
textually follow an open it does not belong to. Strictly better than the v1
function-level rule, not exact.
"""
import re, sys, collections

ASM = "/var/tmp/srv.asm"; IDX = "/var/tmp/decomp_server/index.txt"; APPEND = "0x404090"
funcs = []
for line in open(IDX, encoding="utf-8", errors="replace"):
    p = line.rstrip("\n").split("\t")
    if len(p) < 3: continue
    try: funcs.append((int(p[0],16), int(p[2]), p[1]))
    except ValueError: continue
funcs.sort()
starts = [f[0] for f in funcs]
import bisect
def owner(a):
    i = bisect.bisect_right(starts, a) - 1
    if i >= 0 and funcs[i][0] <= a < funcs[i][0] + funcs[i][1]: return funcs[i]
    return None

addr_re = re.compile(r"^\s*([0-9a-f]+):\s+(?:[0-9a-f]{2} )+\s*(.*?)\s*$")
rows = []
for l in open(ASM, encoding="utf-8", errors="replace"):
    m = addr_re.match(l)
    if m: rows.append((int(m.group(1),16), m.group(2)))

openA = re.compile(r"^mov\s+e[a-z]+,DWORD PTR \[e[a-z]+\+0x278\]")
openB = re.compile(r"^mov\s+(e[a-z]+),DWORD PTR \[e[a-z]+\+0x1050\]")
wstore = re.compile(r"^mov\s+WORD PTR \[(e[a-z]+)\],(0x[0-9a-f]+)$")
push = re.compile(r"^push\s+(0x[0-9a-f]+)$")
axw = re.compile(r"^mov\s+(?:ax|eax),(0x[0-9a-f]+|\d+)$")
clob = re.compile(r"^(call|xor\s+eax|movzx\s+eax|mov\s+eax,DWORD|mov\s+ax,WORD|pop\s+eax|lea\s+eax|add\s+eax|sub\s+eax|and\s+eax|or\s+eax)")

pay = collections.defaultdict(list)     # (opcode, fn) -> [sizes]
unattr = collections.Counter()
helper = {}   # (opcode, fn) -> [1,2] for messages sent through Msg_SendTwoFieldReply
cur_fn = None; cur_op = None
for i, (a, t) in enumerate(rows):
    f = owner(a)
    fn = f[2] if f else None
    if fn != cur_fn:
        cur_fn, cur_op = fn, None
    if openA.match(t):
        for j in range(i+1, min(i+6, len(rows))):
            pm = push.match(rows[j][1])
            if pm: cur_op = int(pm.group(1),16); break
            if rows[j][1].startswith("call"): break
        continue
    mb = openB.match(t)
    if mb:
        reg = mb.group(1)
        for j in range(i+1, min(i+5, len(rows))):
            wm = wstore.match(rows[j][1])
            if wm and wm.group(1) == reg: cur_op = int(wm.group(2),16); break
        continue
    if t.startswith("call") and "0x4e7250" in t:
        # THIRD IDIOM: Msg_SendTwoFieldReply opens the message ITSELF, with the
        # opcode in ECX, so its caller sends without ever opening one -- which is
        # why a sweep keyed on opens alone misses it. Payload is the grounded
        # {u8, u16} of round 443.
        #
        # Kept in a SEPARATE dict on purpose. Writing into `pay` clobbered rich
        # rows and, because `pay` is a defaultdict(list), let later appends push
        # onto the [1,2] -- 0xb045 went from 1,4,1,VAR,2 to 1,2 and 0xb04b from
        # 1 to 1,2,1 before the controls caught it.
        for j in range(i-1, max(i-10, 0), -1):
            m2 = re.match(r"^mov\s+ecx,(0x[0-9a-f]{3,4})$", rows[j][1])
            if m2:
                helper[(int(m2.group(1), 16), fn)] = [1, 2]
                break
            if rows[j][1].startswith("call"):
                break
        continue
    if t.startswith("call") and APPEND in t:
        size = None
        for j in range(i-1, max(i-24,0), -1):
            tt = rows[j][1]
            m = axw.match(tt)
            if m: size = int(m.group(1),0); break
            if clob.match(tt): break
        if cur_op is None:
            unattr[fn or "?"] += 1
        else:
            pay[(cur_op, fn)].append(size)

print("opcode\tsender\tfields\tlayout")
for (op, fn), sizes in sorted(pay.items(), key=lambda kv: (kv[0][0], kv[0][1] or "")):
    lay = ",".join("VAR" if s is None else str(s) for s in sizes)
    print("0x%04x\t%s\t%d\t%s" % (op, fn, len(sizes), lay))
for k, v in sorted(helper.items(), key=lambda kv: (kv[0][0], kv[0][1] or "")):
    if k in pay: continue
    print("0x%04x\t%s\t%d\t%s" % (k[0][0] if isinstance(k[0], tuple) else k[0], k[1], len(v), ",".join(map(str, v))))
ops = {op for op, _ in pay} | {op for op, _ in helper}
print("# distinct opcodes: %d   sender rows: %d   unattributed appends: %d in %d functions"
      % (len(ops), len(pay), sum(unattr.values()), len(unattr)), file=sys.stderr)
