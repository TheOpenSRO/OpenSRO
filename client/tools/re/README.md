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

| deserializer | binary fields | real text columns |
|---|---:|---:|
| `RefObjCommon_ExtractData` | **58** (validated) | — (a prefix) |
| `RefObjItem::ExtractData` | 153 | 160 |
| `ReferenceData::RefObjChar_ExtractData` | 80 | 104 |

**The count is what the validation covers.** Two more bugs were found and fixed
on 2026-09-17, both of which produced right-looking wrong output:

4. **Loop stride.** A loop's walking pointer advances by its own `add`, not by
   the field size. The requirement loop walks `ebx` by 8 and stores a dword at
   `[ebx-4]` and a byte at `[ebx]`; using the field size reported
   `0xb4,0xb8,0xbc,0xc0` where the real stores are `0xb4,0xbc,0xc4,0xcc`.
5. **Multi-bump loop bodies interleave.** That loop consumes dword, byte, dword,
   byte … Emitting every iteration of the first store and then every iteration
   of the second gives the right offsets in the **wrong order** — and the order
   *is* the column map. Loop bodies are buffered and replayed now, and the
   requirement pairs land as four `(dword, byte)` pairs.

**Counting does not give a text column past the common prefix.** Both
type-specific tables consume fewer binary fields than their text has columns, so
the agreement the common prefix enjoys does not extend. A type-specific column
index lives in the stream's own per-column schema — the `(index, width)` records
at `+0xe4`/`+0xe8`, stride `0x54`, that `FUN_006b1a80` walks — not in a count of
reads.

### The limitation that remains

**It is a linear scan with no control flow.** Registers are tracked in address
order, so a value set on a branch that is not taken is still attributed
afterwards. That is why the `+0x184` anchor cannot be recovered: field 58's
store through `ebx` is real, but a `mov ebx,esi` earlier in the listing — on a
different path — drops the tracker's identity for `ebx`, and a linear walk has
no way to know the two never execute together.

Any offset it reports should be treated as a lead until an anchor brackets it.
