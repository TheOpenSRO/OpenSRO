#!/usr/bin/env python3
# rtti_chains.py -- the FULL base-class chain of every RTTI class in a binary,
# read out of the COL's ClassHierarchyDescriptor. Works on BOTH binaries:
#
#     python3 rtti_chains.py                     # server (the defaults)
#     python3 rtti_chains.py /opt/sro-files/client/sro_client.exe \
#             /var/tmp/vt_client.json /var/tmp/chd_chains_client.json
#
# The client resolves 977 of 977 classes. **Do not join the two binaries' class
# names by string**: the client's CGObj is `CGObj : CObjChild : CObj` and the
# server's is `CGObj : IGObj : CBase` -- same name, unrelated hierarchies.
# RUNS ON THE RE BOX (192.168.5.78). Writes /var/tmp/chd_chains.json.
#
#     scp tools/rtti_chains.py root@192.168.5.78:/var/tmp/
#     ssh root@192.168.5.78 'cd /var/tmp && python3 rtti_chains.py'
#
# WHY IT EXISTS. The dump's own "RTTI hierarchy:" plates are TRUNCATED -- they
# routinely stop before the root. `CGObjCOS_Mercenary`'s plate reads
# `CGObjCOS_Mercenary : CGObjCOS_Summoned : CGObjCOS : CGObjNPC`, four deep;
# the real chain is nine deep and ends
# `... : CGObjChar : CGObjMobile : CGObj : IGObj : CBase`. Round 417 tried to
# validate a class-attribution rule against those plates, got 23.8 % agreement,
# and correctly refused to act on it -- the control could not tell "rule wrong"
# from "chain incomplete". This reads the chains properly and settles it.
#
# Layout walked (32-bit MSVC): vtable[-1] -> CompleteObjectLocator;
# COL+16 -> ClassHierarchyDescriptor; CHD+8 = numBaseClasses, CHD+12 ->
# BaseClassArray; each entry -> BaseClassDescriptor; BCD+0 -> TypeDescriptor;
# TD+8 = the mangled name (".?AVCGObjPC@@" -> CGObjPC, ".?AVCMsg@AI@@" ->
# AI::CMsg). Chains run derived -> base.
#
# CONTROLS, all exact: CGObj = CGObj : IGObj : CBase (matches its own plate),
# CTJ_PremiumKeeper : CTimedJob (round 409), CMsgException : CInternalException
# (round 410), and CGObjCOS_Mercenary's nine-deep chain reaching CGObj, which
# is the case the truncated plate got wrong. 1189 of 1189 classes resolve.

import struct, json, collections, re, sys

import sys
EXE = sys.argv[1] if len(sys.argv)>1 else "/var/tmp/SR_GameServer.exe"
VT  = sys.argv[2] if len(sys.argv)>2 else "/var/tmp/vt_server.json"
OUT = sys.argv[3] if len(sys.argv)>3 else "/var/tmp/chd_chains.json"
data = open(EXE, "rb").read()

# --- PE section table -> VA<->file offset ---
pe = struct.unpack_from("<I", data, 0x3c)[0]
assert data[pe:pe+4] == b"PE\0\0", "not a PE"
nsec = struct.unpack_from("<H", data, pe + 6)[0]
optsz = struct.unpack_from("<H", data, pe + 20)[0]
imgbase = struct.unpack_from("<I", data, pe + 24 + 28)[0]
secs = []
off = pe + 24 + optsz
for i in range(nsec):
    name = data[off:off+8].rstrip(b"\0").decode("latin1")
    vsz, va, rsz, rptr = struct.unpack_from("<IIII", data, off + 8)
    secs.append((va, vsz, rptr, rsz, name)); off += 40

def r(va, n=4):
    rva = va - imgbase
    for sva, vsz, rptr, rsz, _ in secs:
        if sva <= rva < sva + max(vsz, rsz):
            fo = rptr + (rva - sva)
            if fo + n <= len(data): return data[fo:fo+n]
    return None
def u32(va):
    b = r(va, 4)
    return struct.unpack("<I", b)[0] if b else None
def cstr(va, maxlen=200):
    b = r(va, maxlen)
    if not b: return None
    i = b.find(b"\0")
    return b[:i if i >= 0 else maxlen].decode("latin1", "replace")

def demangle(m):
    # ".?AVCGObjPC@@" -> CGObjPC ; ".?AVCMsg@AI@@" -> AI::CMsg
    if not m or not m.startswith(".?A"): return None
    body = m[4:].rstrip("@")
    parts = [p for p in body.split("@") if p]
    return "::".join(reversed(parts)) if parts else None

def hierarchy(vt):
    col = u32(vt - 4)
    if not col: return None
    chd = u32(col + 16)
    if not chd: return None
    n = u32(chd + 8); arr = u32(chd + 12)
    if not n or not arr or n > 64: return None
    out = []
    for i in range(n):
        bcd = u32(arr + 4 * i)
        if not bcd: continue
        td = u32(bcd + 0)
        if not td: continue
        nm = demangle(cstr(td + 8))
        if nm: out.append(nm)
    return out

IDX = json.load(open(VT)); CLS = IDX["classes"]
chain = {}
for cls, vts in CLS.items():
    for vt in vts:
        h = hierarchy(vt["vt"])
        if h and (cls not in chain or len(h) > len(chain[cls])): chain[cls] = h

print("image base %08x, %d sections; hierarchies read for %d of %d classes"
      % (imgbase, len(secs), len(chain), len(CLS)))
print()
print("=== CONTROL: chains this project already knows ===")
for c in ("CGObj", "CTJ_PremiumKeeper", "CGObjPC", "CMsgException", "CGObjCOS_Mercenary"):
    print("  %-22s %s" % (c, " : ".join(chain.get(c, ["<none>"]))[:110]))
json.dump(chain, open(OUT, "w"))
print("\nwrote", OUT)
