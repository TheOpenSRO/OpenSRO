"""Build a client vtable index from the dump's own RTTI comments.

The server has /var/tmp/vt_server.json; the client had none, which is why the
who/family probes that worked on the server could not be run against it. The
comments DecompAll already writes carry the same facts, e.g.

    RTTI: reached as CNIFEdit slot 10, CNIFStatic slot 10,
    ... and 108 more.

THE TRUNCATION IS THE POINT: 544 comments in the client dump end in "and N
more", so any index built from them is PARTIAL. The first version of this
script reported zero truncations because it matched line by line and the tail
sits on its own line. The output records both what was recovered and how much
is known to be missing, so nothing downstream reads it as complete.
"""
import re, glob, json, collections

ENTRY = re.compile(r"([A-Za-z_][A-Za-z0-9_:]*) slot (\d+)")
MORE = re.compile(r"and (\d+) more")

classes = collections.defaultdict(dict)
truncated_comments = 0
missing_entries = 0
cur = None
block = []

def flush(addr, lines):
    global truncated_comments, missing_entries
    if not addr:
        return
    txt = " ".join(lines)
    if "RTTI: reached as" not in txt:
        return
    seg = txt.split("RTTI: reached as", 1)[1]
    seg = seg.split("Recovered by walking")[0]
    for cls, slot in ENTRY.findall(seg):
        classes[cls][int(slot)] = addr
    m = MORE.search(seg)
    if m:
        truncated_comments += 1
        missing_entries += int(m.group(1))

for path in sorted(glob.glob("/var/tmp/decomp_client/funcs_*.c")):
    for line in open(path, errors="replace"):
        if line.startswith("===FUNC=== "):
            flush(cur, block)
            cur = line.split()[1]
            block = []
            continue
        s = line.strip()
        if s.startswith(("/*", "*", "...")) or "slot" in s or "RTTI" in s:
            block.append(s)
flush(cur, block)

out = {"classes": {c: {str(k): v for k, v in sorted(s.items())} for c, s in classes.items()},
       "truncated_comments": truncated_comments,
       "entries_known_missing": missing_entries}
json.dump(out, open("/var/tmp/vt_client.json", "w"))
print("classes: %d" % len(classes))
print("class/slot pairs recovered: %d" % sum(len(s) for s in classes.values()))
print("comments truncated with 'and N more': %d, hiding %d further entries"
      % (truncated_comments, missing_entries))
