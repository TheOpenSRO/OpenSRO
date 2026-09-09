# What's left

The single ordered list of open work. Each entry says what is known, what is *not*, and the next
concrete step — so picking one up does not mean re-deriving how it got here. Detail and evidence
for every item live in `docs/WORLD_ISSUES.md`; this file is the index.

Ordered by value per unit of effort, not by how interesting the problem is.

Two lanes are running in parallel: the **world** lane ([HANDOFF.md](HANDOFF.md)) has items 1-3,
the **UI** lane ([HANDOFF_UI.md](HANDOFF_UI.md)) has items 4-5. Each handoff covers its own lane —
where it stopped, the tools for it, the traps — and points back here for everything else.

## Next up

### 1. NPCs — **done, except that they are statues** (hundred-and-fifth round)
12,367 spawns and 5,423 models read from the player's own Media.pk2, each assembled from its own
`.bsr` by `SkinnedBsrAssembler`. 18 of 19 placed in Jangan town, 45 across the loaded grid.

**What is left**: they do not face anywhere, have names, or block movement. `npcpos.txt` carries no
facing, so which way they turn is an open question rather than a wiring job.

**Animation is written, measured, and deliberately off** (hundred-and-ninth round). It runs -- 49
characters, bones moving 1.0 to 12.0 units between samples -- and it looks worse than standing
still, because `.bms` has no per-vertex skinning so a humanoid's whole dress is one piece attached
to one bone. A controlled pair of renders shows the same NPC torn into a spike with it on and
correct with it off. `SRREVAMP_IDLE_ANIM=1` enables it.

**So moving NPCs is a skinning problem, not an animation one.** It needs a way to weight vertices
to bones, and `.bms` does not appear to carry one. That is the real open question here.

### 2. Monsters as real models — **the next thing to do**
The server already sends a live monster list and the client draws labelled capsules for them.
Everything else now exists: monsters are character-category `.bsr` files (`mangnyang` is 2 pieces,
26 bones, 15 animations, and renders correctly through `render_npc.gd`), and
`SkinnedBsrAssembler` builds one from its path alone. The id -> model mapping is the same
`characterdata*.txt` table the NPCs use, already parsed by `NpcTableReader`.

So this is wiring, not research: resolve the monster's model path from its id and assemble it
where the capsule goes. `MonsterAssembler`'s hand-derived per-creature bone tables are superseded
and can go.

### 3. Equipment on the character
The character renders bare. Eight real armour sets are already cached and `assemble_equipment`
works; it only runs for slots the server reports as equipped, and a fresh character has none.
**Next**: give a new character a starting set server-side, or render the default set when no
equipment is reported — decide which, then verify in a render.

### 4. A minimap (Implemented — one-hundredth round)
The live minimap is now wired through the authentic PK2 UI pipeline (`scripts/ui/hud/hud_minimap.gd`
loading `resinfo/ifminimap.txt`): displays the region's own art (`minimap\<y>x<x>.ddj`), aperture
clipping, rotating heading arrow (`mm_sign_character.ddj`), and real-time X/Y coordinate readout
derived from the ninety-seventh round's recovered coordinate math.

### 5. Break up `client/scripts/World3D.gd`
5,259 lines, against 800 for the next largest file — and now the file both lanes would edit at
once, which makes this deconfliction as well as tidying.

**The UI is the big piece and goes first**: 79 of the file's `@onready` node references and 75 of
its 162 functions are UI handlers, wired by 96 `.connect(` calls in code (the scene has only 2
`[connection]` entries). Moving them into `client/scripts/ui/` plus its own scene leaves the two
lanes touching disjoint files. Do it incrementally — one tab, run the suite, commit — since a
big-bang refactor of a file another agent is editing will not merge. See
[HANDOFF_UI.md](HANDOFF_UI.md)'s "Do not collide".

The QA harness at the bottom is a separate ~600 lines of pure diagnostics with no gameplay
coupling; it belongs to the world lane and moves out on its own. Region loading and streaming is
the next cohesive piece after that.

### The UI lane's own list is [UI_TODO.md](UI_TODO.md)
Panels, the window recipe, and the reference screenshots. The item below is the part of it that
touches this file.

### Retire the debug UI now the real HUD is in
The developer UI (chat box, Log Out, Change Zone, the corner labels, and the ten-tab `ActionTabs`)
still sits on top of the authentic HUD and overlaps the underbar. Its ten tabs are the only way to
reach inventory, skills, shop, party, guild, trade and friends, so it can't just be deleted —
each needs its authored window (`resinfo\if*.txt`, one file per panel) built the way the underbar
and minimap now are. Do it one panel at a time, and drop each tab as its real window lands.

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

### Eight objects in Jangan have no navigation mesh
Named by the build log since the hundred-and-sixth round: `cj_s` (the city wall), `cj_luxury`,
`cj_armo`, `cj_acce`, `cj_weapon`, `cj_portal`, `cj_etc`, `cj_pal_bigdoor`. An object with no
walkable mesh is one the player can stand *inside* — the graph reports the terrain beneath it and
puts them there. This is the same symptom the hundred-and-seventh round fixed for the Jangan gate,
but from missing data rather than from the ground snap, so it needs a different answer.
`SRREVAMP_QA_NAVGAP` names the culprit at any given spot.

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
