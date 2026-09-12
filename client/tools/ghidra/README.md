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
