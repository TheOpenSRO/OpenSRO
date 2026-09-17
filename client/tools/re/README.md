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

## `fields.py` — validated 2026-09-17

`fields.py <addr>` reads a sequential `ExtractData` deserializer and reports its
**field index → struct offset**, which is what a column layout needs.

**It reproduces a known answer.** `docs/protocol/refobj_binary_format.md` fixes
`_RefObjCommon` at 58 fields independently; the scanner returns exactly 58, and
three of that document's own anchors land under one consistent convention
(field N, 1-based = text column N−1):

	fields 33..40  the four requirement pairs   (doc: columns 32..39)
	fields 53..57  the five asset strings       (doc: columns 52..56)
	field  58      +0x184, the last common field  (doc: "the 58th and last")

The arithmetic that closes:

	40  inline counter bumps outside any loop
	 8  a 4-trip loop bumping twice per pass    -- the requirement pairs
	 4  RefData_ReadStringField calls outside a loop
	 5  RefData_ReadStringField inside a 5-trip loop -- the asset strings
	 1  FUN_006b1a80, the schema-driven field skipper
	--
	58

### Three bugs it had, each of which shifted every later index

Worth listing because each produced a *plausible* wrong answer rather than an
obvious failure:

1. **Loop trip counts.** A bump inside a loop executes once per iteration and
   appears once in the instruction stream. Counting instructions gave 43.
2. **Register-sourced trip counts.** The requirement loop sets its count with
   `mov eax,0x4` … `mov [esp+0x1c],eax`, not an immediate store. Missing that
   form cost exactly six fields — 52 instead of 58.
3. **Pass ordering.** Building the stack-slot counter map in a separate pass let
   a later `mov [esp+0x1c],ecx` (ecx = 1) overwrite the 4 the loop depends on.
   The value that matters is the one live *at the loop's branch*, so it is one
   forward pass now.

### What it does and does not give you

`RefObjItem::ExtractData` returns **153 fields, 79 offsets resolved**. The
**count** is what the validation covers. The **offsets** are only as good as the
register tracking, and two things are known to be unresolved:

- Resolved offsets run to `+0x298` and resume at `+0x524`. The gap contains
  exactly the offsets two specs want — the packed reinforce rates at
  `+0x2c0/0x2e0/0x300` and the repair price basis at `+0xa4` — because that
  region is written through walking pointers the tracker loses.
- **`+0xa4` and `+0xa8` are written by BOTH `RefObjItem::ExtractData` and
  `RefObjCommon_ExtractData`.** Until it is settled which record the pointer in
  `item->[0x34]->[0x18]` actually is, a column index taken from either would be
  a coin flip dressed as a recovery.

So: no column mapping is published yet, and the next probe is narrow — resolve
the walking-pointer stores in `0x2a0..0x520`, and settle which record `+0xa4`
belongs to.
