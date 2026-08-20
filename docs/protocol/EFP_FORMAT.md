# EFP particle effect format (JMXVEFF)

`.efp` is the particle-effect definition format (found in `Particles.pk2`'s `battle/` and other
folders). Unlike every other format in this project, it's not a fixed-layout record structure —
it's a **self-describing, nested, tagged property system**: named string keys (`"NormalTimeLife"`,
`"StaticEmit"`, `"LinkMode"`, `"Program"`, `"ProgramUpdate"`, `"ViewNone"`, `"RenderNone"`, ...)
each followed by parameter data whose length isn't declared anywhere in the byte stream, recursively
nested (an effect contains multiple named sub-components, each of which has its own named
sub-parameters, to unknown depth).

A real loader function was located in `sro_client.exe` (`FUN_00cb9120`, found via the same "JMXV"
+ extension-suffix immediate-constant search used for every other format here) but was too
obfuscated by stack/register reuse to read field types off directly, and no callers were found
even after a full Ghidra auto-analysis pass — so this format is confirmed **entirely
empirically**, the same brute-force byte-analysis approach that cracked `.bsk`/`.mapo`/`.mapm`:
scanning every valid length-prefixed identifier-shaped string across 30 real files (extracted from
`Particles.pk2` via this project's own `server/internal/pk2`), then checking how far a
value-boundary-agnostic "read a name, then scan forward for the next one" walk gets through each
file. No decompiler output is stored in this repo regardless — only the resulting facts about the
container format.

## What this reader does and doesn't recover

**Recovers a flat sequence of `(name, raw value bytes)` pairs — not the true nested tree.** Every
property's value boundary is found by scanning forward from where its raw bytes start for the
next byte offset where a *plausible* name token appears (1-40 ASCII letters/digits/underscores,
starting with a letter — deliberately strict, since a lenient rule risks false positives inside
binary value data). This can't distinguish "a leaf property's raw parameter bytes" from "a
container property's own list of nested named children" — both just look like "bytes, then
another name" to this technique. In practice this doesn't matter for *recovering the data*: a
container's nested names get discovered as their own top-level-looking `Entry` records in the
flat list anyway, in file order, which preserves everything the file actually contains — it just
flattens away the parent/child relationships between them. Building a proper recursive tree would
need either a per-key schema table (this project doesn't have) or actually finishing the
decompile of `FUN_00cb9120`.

**Verified to work well despite this simplification**: applied to 30 real files, this
flat-boundary-finding walk successfully parsed **all 30 without error**, and separately measured
(before building the actual reader) as consuming **94-100% of every file's bytes** this way — the
small unconsumed tail in most files is presumably a trailer, not a sign the technique is
unreliable.

## Structure

| Field | Encoding |
|---|---|
| Magic | `"JMXVEFF"` (7 bytes) + `" "` (1 byte) + version (4 bytes, ASCII) |
| Header (version-dependent) | see below |
| Effect name | `uint32` length + ASCII bytes (e.g. `"counterattack"`, `"fireball_hit"` — not always the same as the containing file's name; several different files share the same internal effect name, plausibly reused templates) |
| Top-level count | `uint32` — plausibly a top-level section count, not cross-checked against the number of entries this reader recovers (which includes every nesting level flattened together, not just top-level ones) |
| Entries | flat sequence of `(name, value)` pairs, see below, until the file's trailer or truncation |

Two header versions confirmed real (both correctly handled by both readers):

- **`"0011"`** (24 of 30 real files checked): one `uint32` (unconfirmed) before the effect name.
- **`"0013"`** (6 of 30 real files checked): one `float32` (unconfirmed — observed values `0.5`,
  `0.4`, `1.0`, so plausibly a scale or intensity parameter, though this is a guess) + 12
  reserved bytes (observed all-zero) + one `uint32` (unconfirmed) before the effect name. Same
  structure after that point as `"0011"`.

## Entry (flat, one per recovered name)

- `uint32` length + name (ASCII letters/digits/underscore, must start with a letter).
- Raw value bytes, from right after the name to the byte offset where the next valid name token
  is found (bounded scan, 100,000 bytes) — kept entirely opaque (`Entry.Value` /
  `entry.value`), since the true per-key type/length rules aren't known. See "What this reader
  does and doesn't recover" above.

### What was checked before settling on this approach

An earlier pass tried to find a **fixed per-key schema** by measuring how many bytes separate
each occurrence of a given key name from the next name token, across all 30 real files, hoping
for a consistent length per key (the same way `.bsk`'s two record shapes were confirmed). Some
keys really are consistent this way — e.g. `"ProgramUpdate"` is always followed by exactly 35
bytes before the next name, `"NormalTimeLife"` always by 0 bytes (immediately followed by another
name — a pure marker/container key with no leaf value of its own) — but many others
(`"SetGraphDiffuse"`, `"RenderMesh"`, `"SetRotation"`, ...) show highly variable gaps, consistent
with being containers whose *nested* content varies per effect. Building a full schema table this
way would mean hand-classifying dozens of keys with no way to verify the boundary was found
correctly for the container ones — versus the flat scan, which doesn't need to know in advance
which keys are containers at all. Recorded here since a future, more thorough pass (ideally after
finishing the `FUN_00cb9120` decompile) might still want the per-key gap data as a starting point.

## Verification

`server/internal/efp` and `client/scripts/efp/efp_reader.gd` implement the flat reader above and
parse all 30 real files without error, matching between Go and GDScript.

## What's still not confirmed

- The true nested tree structure (see above).
- Every per-key value type/layout (only the outer `name` + opaque `value` shape is confirmed).
- The two unconfirmed `"0011"`-header `uint32` and the three unconfirmed `"0013"`-header fields.
- The top-level `count` field's exact meaning.

## Real samples available for future verification

`Particles.pk2` → `battle/*.efp` and other folders (211 files total in the archive available in
this environment; 30 extracted and checked so far). Extracted via this project's own
`server/internal/pk2` reader, not any external tool.
