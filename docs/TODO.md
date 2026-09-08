# What's left

The single ordered list of open work. Each entry says what is known, what is *not*, and the next
concrete step — so picking one up does not mean re-deriving how it got here. Detail and evidence
for every item live in `docs/WORLD_ISSUES.md`; this file is the index.

Ordered by value per unit of effort, not by how interesting the problem is.

New to the project? [HANDOFF.md](HANDOFF.md) covers the current task in depth — where the last
session stopped, the tools for it, and the traps — and points back here for everything else.

## Next up

### 1. NPCs
The reference server has named NPCs standing in the town (`Grocery Trader Jinjin`,
`Magic POP Guide Gori`, arena managers). This project renders none, and they are most of what
makes a town look inhabited.

**The spawn data is solved** (ninety-eighth round). A server pack's `SR_GameRefData\npcpos.txt`
gives *NPC id, region id, X, Y, Z*, with the region id in the same `(x << 8) | y` key this project
already uses; `CharacterData*.txt` maps the id to its model. Both are plain tables.

**The model loader is now solved too** (ninety-ninth round). An NPC `.bsr` is not scenery — it is
a character, and the file says so: the `uint16` at 0x40 is an authored object type (1 character,
2 building, 4 nature), and the header's offset table at 0x0C addresses a material, mesh, skeleton
and animation section, each count-prefixed. Both readers now take that path for type 1, validating
that every section ends exactly where the header says the next begins. The priest went from 1
piece / 25 vertices to **3 pieces / 665 vertices** with its skeleton and 2 animations; the
bookmaker girl to 4 / 747; `mangnyang` to 2 / 440 with 15 animations. See
[protocol/BSR_FORMAT.md](protocol/BSR_FORMAT.md), which also corrects this document's earlier
claim that the offset table was untrustworthy — it was being read one field off.

**Assembly is written too.** `client/scripts/assets/skinned_bsr_assembler.gd` takes an open
archive and a `.bsr` path and returns a `Skeleton3D` with every piece attached and materials
applied, needing nothing from outside — the `.bsr` names its own skeleton, and the piece-to-bone
mapping is computed rather than tabulated (it reproduces `MonsterAssembler`'s two hand-derived
dictionaries 10/10).

**Next**: it has never been drawn. Write `client/tools/render_npc.gd` on the model of
`render_character.gd` and render the priest, to confirm he stands up as a person rather than
scattered pieces. Then spawning, which is the easy half: the table is readable and the server
already streams a monster list the client renders. See [HANDOFF.md](HANDOFF.md) for the exact
command and what the render does and does not prove.

### 2. Monsters as real models
The server already sends a live monster list and the client draws labelled capsules for them. The
models are real `.bsr` files this project can already load, so this is wiring rather than
research: resolve a monster's own model path and assemble it the way characters are assembled.

### 3. Equipment on the character
The character renders bare. Eight real armour sets are already cached and `assemble_equipment`
works; it only runs for slots the server reports as equipped, and a fresh character has none.
**Next**: give a new character a starting set server-side, or render the default set when no
equipment is reported — decide which, then verify in a render.

### 4. A minimap
The reference has a live minimap with the region's own art, a heading arrow and an X/Y readout.
Every piece already exists: the per-region art decodes (`dump_ddj.gd`, and the minimap comparisons
in the eighty-first round), and the client's own coordinate readout is now recovered
(`server/cmd/wherecoord`, ninety-seventh round). This is UI work on solved data.

### 5. Break up `client/scripts/World3D.gd`
5,200 lines, against 800 for the next largest file. Not urgent and not worth a big-bang refactor,
but the QA harness at the bottom is ~600 lines of pure diagnostics with no gameplay coupling and
would move out safely. Region loading and streaming is the next cohesive piece after that.

## Parked, with the state written down

### Moat water
The moat is real, located exactly (96/168 local 1490, 1470 — the ninety-seventh round), and the
terrain carries its trench: **-40.00** in a narrow band against **+0.65** either side, with the
plane cell over it at level **-20**, which would fill the trench and nothing else.

**Why it is parked**: the same region sits at about **-45 across its southern third**, which that
same level would flood, and the art there is farmland. Neither the plane map (30 of 36 cells are
type 1) nor the tile map (no water tiles anywhere in the region) can separate the two.
**Cheapest next step**: a reference screenshot standing in that southern area — if it is dry in
the real game, the plane level alone cannot be the rule, and that halves the search.

### Scenery still off the ground
83 objects fell to 60 once each `.o2` entry was assigned to the region whose heightmap explains
its height (eighty-fifth round). The rule resolves small scenery reliably and **cannot** resolve a
large structure standing on its own platform, whose base has no reason to touch the terrain.

### The `cj_s` city wall's copies
Down from six to two or three. The surviving one currently lands correctly because an unauthored
band of zeroes beats the regions with real data — luck, recorded as luck in the eighty-sixth
round, not a working rule.

### Every multi-piece building loads its first mesh twice
Found while recovering the character layout (ninety-ninth round), and **measured, not suspected**:
`cj_monstad_door01.bsr` yields **17 mesh references, 16 distinct** — `..._door01_01.bms` is
returned as both `mesh_path` and `sub_mesh_paths[0]`. The cause is now understood. A building
(type 2) carries a duplicate reference to its first piece *before* the header-declared mesh
section, and the scan-based reader takes that one as the primary while also reading the whole real
section as sub-meshes. So every such building is drawn with one piece doubled.

**The fix is known and deliberately not taken yet**: type 2 uses the *same* count-prefixed
material and mesh sections as type 1, and chains exactly (door01's mesh section: count 16 at
0x154, 16 × 73 bytes from 0x158, ending at 0x5E8 = the header's animation pointer). Routing type 2
through the header table removes the duplicate. It was left out of the character change to keep a
scenery-wide regression away from the NPC work; it wants a sweep over every `.bsr` in `Data.pk2`
comparing old and new results before it lands.

**Type 4 (nature) is not pinned down** and should stay on the scanner meanwhile: its mesh entries
carry a trailing `uint32` per piece that types 1 and 2 don't, and its animation section doesn't
chain consistently — `tre_bank02`'s ends exactly at its skeleton pointer, `tre_maple01`'s ends 4
bytes short.

### `.o2` list semantics
List 2 is a region's own objects and the others are cross-references, measured at 91% against 46%
on the sector check. What the three lists *are* is still unknown.

## Established, do not re-derive

Each of these cost real time and is recorded with its evidence. Check `docs/WORLD_ISSUES.md`
before contradicting one.

- Region axes: region **y** → world X, region **x** → world Z.
- Client position readout: `X = (region_y - 135) * 192 + local_x / 10`, `Y = (region_x - 92) * 192 + local_z / 10`.
- Minimap filename is `minimap\<y>x<x>.ddj`.
- Placements resolve against **Map.pk2's** `object.ifo`, not Data.pk2's.
- `.bmt` layer flag **bit 0** marks an alpha layer.
- A `.ban` keyframe **replaces** a bone's local transform; it is not a delta.
- Navmesh plane **type 1 is not water** — it covers a quarter to all of every region.
- A bind pose is a poor test of a rig: both character bugs this project had were invisible at rest.
