# The RE toolkit

Three scripts that live on the RE box at `/var/tmp/`, vendored here so they are
not lost when `/var/tmp` is cleaned. `docs/RE_LOOP.md` is the operating manual;
this is just what each file is.

| file | what |
|---|---|
| `rebox.py` | the dump/disassembly reader — classes, functions, vtable slots, strings, callers, param reads, pk2 extraction, textdata census |
| `vtindex.py` | builds the class → vtable index from a PE's RTTI, cached as JSON (1,189 classes and 38,634 slots from the server binary in half a second) |
| `vtq.py` | queries that index — one class's vtable, a base/derived diff, and `who <addr>`, which is the COMDAT-folding check to run **before** attaching any name |

## Deploying them

    for f in rebox.py vtindex.py vtq.py; do
      ssh root@192.168.5.78 "rm -f /var/tmp/$f"
      ssh root@192.168.5.78 "cat > /var/tmp/$f" < client/tools/re/$f
      ssh root@192.168.5.78 "chown ghidra:ghidra /var/tmp/$f"
    done
    ssh root@192.168.5.78 'cd /var/tmp && python3 vtindex.py build \
      /var/tmp/SR_GameServer.exe /var/tmp/vt_server.json'

`/var/tmp` on the box is owned by `ghidra` and sticky, so `scp` over an existing
file fails even as root — delete first, or pipe through `cat` as above.

**Do not rename `rebox.py` to `re.py`.** It shadows the standard library's `re`
and nothing on the box will import.

## `fields.py` — and why it is not finished

`fields.py <addr>` reads a sequential `ExtractData` deserializer and reports its
field order: **field index → struct offset**, which is what a column layout
needs. It handles the three store shapes that appear (integer, float, and float
through a walking pointer), expands short counted loops so a bump inside one is
counted per iteration rather than per instruction, and auto-detects which
register holds the reader.

**It does not yet reproduce a known answer, so nothing should be published from
it.** `docs/protocol/refobj_binary_format.md` establishes that `_RefObjCommon`
has **58** fields, the last at `+0x184`. The tool accounts for **47**:

	42  inline reads it sees directly
	 5  calls to RefData_ReadStringField, which bumps the counter inside the callee
	--
	47  of 58

**Eleven fields are unaccounted for**, and closing that gap is the whole job.
Until it closes, the tool's output for `RefObjItem::ExtractData` (62 fields, 39
offsets resolved) is a plausible field order and **not** a column mapping, and
using it would put un-validated offsets into two shipped specs.

The reason this matters: `RefObjItem::ExtractData` is the single unread function
blocking a real number in two places — the packed reinforce success rates in
`docs/protocol/alchemy.md` and the repair price basis in
`docs/protocol/durability.md`.
