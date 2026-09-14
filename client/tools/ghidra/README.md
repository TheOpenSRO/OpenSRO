# Ghidra decompile helpers

Headless GhidraScripts for reading the retail SRO client (`sro_client.exe`) on the
RE box. They exist because, on that box's Ghidra 12.1.3, the GhidraMCP plugin is
broken (incompatible `.jar`, no `:8080` server), so decompilation goes through
`analyzeHeadless` instead of the MCP bridge. **They read a binary you supply; the
repo ships no game data.**

## Running (on the RE box, as the `ghidra` user)

```
scp client/tools/ghidra/DecompDump.java root@<rebox>:/var/tmp/
ssh root@<rebox> "su ghidra -s /bin/bash -c '\
  /opt/ghidra_12.1.3_PUBLIC/support/analyzeHeadless \
    /home/ghidra/re_client sro_client_re \
    -process sro_client.exe -readOnly -noanalysis \
    -scriptPath /var/tmp -postScript DecompDump.java <args> > /var/tmp/hl.log 2>&1'"
```

`println` output is line-prefixed `INFO  <Script>.java> ...` in the log — strip it
with `sed 's/.*<Script>.java> //'` before grepping.

## DecompDump.java `<needle> <max> <mode>`

- `mode=name` — decompile functions whose qualified name contains `<needle>`.
- `mode=addr` — decompile the function(s) containing a comma-separated address list
  (e.g. `0069d380,006a15f0`).
- `mode=list` — just print matching qualified names (fast locate).

The `sro_client_re` project has **no applied symbol names** (every function is
`FUN_00xxxxxx`), so `name`/`list` rarely match. Use `StrXref.java` to find code by
the strings it references, then `DecompDump ... addr` on the addresses it prints.

## StrXref.java `<needle> <maxStrings> [decomp] [maxDecomp]`

Finds defined strings containing `<needle>` and prints the functions referencing
each. The client keeps its source paths and control names as strings
(`"D:\vss-od\Silkroad\Client\client\IFSkillBoard.cpp"`, `"resinfo\ifskillboard.txt"`,
`"CIFSkillBoard"`), so this is the reliable way in. Pass `decomp` to also decompile
the top referencing functions.

## FindOffsetRefs.java `<offsets> [max] [mode]`

Finds the code that touches a struct field at a given offset — for when you know
*where* a field lives but not *what it means*. A C++ member access compiles to a
memory operand with a displacement (`MOV EAX, dword ptr [ECX + 0x24c]`), so this
walks the listing and reports operands carrying both a register and that scalar;
requiring the register is what keeps plain immediates out.

- `<offsets>` — one, or a comma-separated list, hex (`0x24c`) or decimal. All of
  them are matched in a **single** pass over the listing, so asking about a whole
  struct at once is cheap; asking one at a time is not.
- `[mode]` — `all` (default) lists every site; `funcs` prints only the
  per-function summary, ordered by hit count, which is usually what you want first.

Each site is marked `W`/`R` for whether the field was written or read (`CMP`/
`TEST`/`FLD` on the destination operand count as reads, not stores).

**Its best trick is mapping a whole parser.** A `…::ExtractData` deserialises a
row field-by-field, one column per store, so listing its stores *in address order*
gives the column→offset map — anchor it on any field you can identify
independently and the rest fall out. That is how `_RefObjChar` col 59 = MaxHP was
confirmed and an off-by-one in col 79 was caught: `0x19c` was pinned by the
`m_dwMaxHP > 0` assertion, `0x25c` by the code defaulting it to `0xbb8` (3000),
and counting between them fixed every field in the run. Small offsets (`0x4`,
`0x8`) appear in nearly every function and will drown you — this is a tool for
distinctive ones.
