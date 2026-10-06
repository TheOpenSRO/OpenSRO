# Review of rounds 740 and 741 (weapon glow inheritance, itemrare.txt, all itemdata parts, turned holders)

Independent adversarial review. Branch `worktree-agent-abc8157a0b452cb25`, head `23580b2e`, diff
against its merge-base with dev, `cf268f33` (dev's rounds 744 and 745 are unrelated). Reviewed in a
detached worktree. Godot ran only on the render box (`RENDER_DIR=/opt/opensro-client-r741rev`, own
lock). Labels as in the rounds: **READ** (decompile or disassembly, address given), **MEASURED**
(the retail archives on the box), **INFERRED**.

## Verdict

**Ship.** There is no BUG and no REGRESSION that breaks play. The READ claims of both rounds hold
against the disassembly. The item-table change is thread-safe and fixes real invisible items. The
shared-turn shaders leave every other `EfpEffect` (skills, buffs, teleport gates, monsters, NPCs)
on its old path. Findings 1 and 2 are departures to label or to put to the user, not blockers.

## Gates

- `remote_godot.sh check`: `checked 648 scripts and 9 scenes` / `ALL LOAD`.
- `remote_godot.sh tests`: **`ran 247 suite(s), 0 failing`**, 0 `SCRIPT ERROR` lines.
- `perf_gate.sh --base cf268f33 --sites jangan --frames 40000`: SAME on all four numbers (table at the end).

## Findings, most severe first

### 1. DEPARTURE (and WRONG-LABEL on its scope): world-axis commands now turn with the bone

**Where:** `client/scripts/efp/efp_effect.gd` `use_shared_turn` (~l. 933);
`client/scripts/assets/equip_fx.gd` `holder_transform` (~l. 278); `docs/rounds/r741.md` l. 214
("a velocity that retail keeps in the world turns with the holder (`u4 = 0` nodes with `Force` in the
seal files). This differs only while the weapon turns during a particle's short life").

**Evidence (MEASURED, `efpcensus -dumpone` over the 74 files of `itemrare.txt` and
`itemoptionefp.txt`):**

- These commands have space 0, meaning "rotate the value by nothing" (EFP_FORMAT.md, "What the
  space selects"):
  - `SetConeVel` space 0: 56 commands in 8 files: `eternity_11_nova_01`, `nova_bow_02/03`,
    `nova_shield_02/03`, `egya_sealhusk_purple`, `egyb_coreglow_green` and `egyb_sealhusk_green`;
  - `SetPosition` space 0: 2 commands in `egyb_coreglow_green_shield`;
  - `SetRVelocity` space 0: 2 commands in `system_rarestaff_a`.
- Retail simulates in world space, with the bone's frame only as the effect's placement
  (EFP_FORMAT.md: "space-0 commands point along world axes, and the host's facing arrives as the
  effect's rotation"). Its space-0 vectors are therefore world vectors.
- Here, the master simulates at identity and the holder turns everything it draws. A space-0
  vector therefore becomes a bone-frame vector **at every moment**, not only while the weapon turns.
- Example, `nova_01` (the Nova spear 62607's first row): seven `plan_twist.bms` mesh nodes (`F 0 0 1 1
  0 0 1 1`) take a cone velocity of 0.007 to 0.03 per step:
  - the vector is `(0, v, 0)`, turned up to 360° about Z;
  - retail: the meshes drift in the world's vertical XY plane;
  - here: they drift in the plane of `ai_end`'s X and Y.
- Every other command in the 74 files is parent-relative (spaces 1, 2 and 7). Every node follows its
  parent in position and velocity: 1,818 of 1,818 `F` lines have u2 > 0 and u6 > 0 (MEASURED). So
  the rigid, turned motion is otherwise retail's. These 10 files are the exception.

**Fix:**
- Either: correct the OURS line in r741.md and in the `EquipFx` header (space-0 vectors in 10 seal
  files point along the bone, not the world, all the time);
- or: give a kind whose template has a space-0 vector command one simulation per holder, placed at
  its bone's world frame. That is the per-weapon path, for 10 rarely-seen files under the budget.

The first is enough to ship. The difference is small (a drift of about 1 to 4 units at row scale
2.3, INFERRED from the values and the 60-frame life).

### 2. DEPARTURE / PERF: the budget counts (bone, effect) hosts, so seal weapons share 64 slots by 2 to 4

**Where:** `client/scripts/assets/equip_fx.gd` l. 46 (`VISIBLE_BUDGET := 64`), `_scan_slice` l. 432,
`_finish_cycle` l. 455.

**Evidence:**
- Since the host key became (bone, effect), a weapon takes one budget slot per row:
  - Sun spear 4118 at +9: 2 slots (`raretype_a_step3` from `itemrare.txt`, `enchant_a_01` +8..100
    from `itemoptionefp.txt`, MEASURED in the box's tables);
  - Nova 62607 at +9: 4 slots (nova_01/02/03 and enchant).
- So at most 32 Sun spears or 16 Nova weapons show their effects in a crowd.
- Every host of a weapon has the same distance, the skeleton's position (l. 432). `_finish_cycle`
  stops at the 64th host in candidate order (l. 455). So the weapon at the cut can show some of its
  effects and not others.

**Is the round's +1.7 ms for 200 Sun spears the right cost, or a bug?** It is the right cost. No
holder is duplicated:
- the key is `skel id | bone | efp | scale`;
- `remove_skel` drops by the `skel id|` prefix;
- `Marker._enter_tree` re-adding is a no-op through `_hosts.has(id)`;
- the Sun spear has exactly two rows at +9 (above).

The extra cost is `enchant_a_01`'s 20 plate MultiMeshes per shown holder: 32 × (9 + 20) draws
against 64 × 9 before.

**Fix:** a user decision, already put by the round. If the budget stays per host, rank and cut by
skeleton (all of a weapon's hosts in or out together), so no weapon shows half its effects.

### 3. MINOR: the inheritance resolves a group's name against the tables, not the item table

**Where:** `client/scripts/items/item_glow_tables.gd` `_rebuild_types` l. 310 and
`_rebuild_particles` l. 334 (`_types.has(base)`, `_particles.has(base)`).

**Evidence (READ):**
- Both loaders look the group's key up as a code name in the item-walk map first: `FUN_004f19f0`,
  `getfn.sh 00aa0270` output l. 349; `FUN_00a9f2e0` the same.
- A rows' code that is not an item never enters `DAT_0110ac80` or `DAT_0110ac98`: the RefID lookup
  fails and the row is dropped.
- OpenSRO keys both maps by code name and keeps rows for codes that are not items:
  - 194 `itemoption.txt` rows (round 740's own count);
  - 228 `itemrare.txt` rows.
- An OrgObjCodeName naming such a code would give its members a type or a list here and nothing in
  retail.
- Both of round 740's probes found 480 on this archive, so nothing differs here today.

**Fix:** in `inherit`, collect the code names of the rows given. In both rebuilds, skip a group
whose upper-cased name is not among them. Optionally also drop table rows whose code is not an item.

### 4. MINOR, WRONG-LABEL: "after a real login … the world waits 0 ms"

**Where:** `docs/rounds/r741.md` l. 78.

**Evidence (READ, the code):** the select screen does not always fill the shared rows.
- The select screen's appearance (`charselect_stage.gd` l. 107, `from_archives` with no rows) loads
  the item table only on a miss in `_item_info`.
- Its catalogue holds only `_A_DEF` items (`CharCatalog._is_item`).
- So the shared rows are filled before the world only when a listed character wears a non-default
  item.
- Otherwise the world's preload does the work, and the world waits for it (0.42 to 0.45 s,
  MEASURED by the round).
- The sentence was not measured.

**Also:**
- The select screen's full load stays synchronous on the main thread: about 1.7 s in GDScript on
  the first non-default item.
- That is not a regression. Before this round `_item_info` parsed the same 63 parts there, and now
  the world reuses them.
- The HUD (inventory, shop, tooltips) exists only in the world. Its `_load_items` either finds the
  shared rows or waits for the same preload task. No path parses twice.

**Fix:** reword it: "when a character on the select screen wears an item outside the catalogue,
the select screen has already filled the shared rows…".

### 5. MINOR: a preload that is never waited for

**Where:** `client/scripts/npc/item_table_reader.gd` l. 101-105 (`preload_async`), `load_all`.

**Evidence (READ, the code):**
- `World3D._ready` starts the task. Only `load_all` with the same key waits for it.
- A world that leaves the tree before `_load_character_assets` (a QA boot that quits early, a
  disconnect during loading) leaves `_pending_task` set.
- Any later `preload_async` is then a no-op, and only a `load_all` for the same path waits for it.
- Rows parsed from another path are not affected.
- No crash path: `Pk2Reader` locks its file and directory cache, and the native reader is
  stateless per call.

**Fix:** none needed to ship. Optionally wait for (or drop) the task in `World3D._exit_tree`.

### 6. MINOR: the boot log line's parse time can be stale

**Where:** `client/scripts/World3D.gd` l. 8706.

**Evidence:** `last_load_usec` and `last_load_parts` are those of the last fresh parse. When the
rows were already shared (the select screen's), the line prints that earlier parse's time as this
boot's.

**Fix:** print `ItemTableReader.last_wait_usec` and "shared" when no parse ran.

## What was checked and holds

### Round 740's READ

All read against `/var/tmp/sro_client.asm` and the decompile.

- **The two calls.** `Client_LoadAllRefData`: `call 0xa9f2e0` at 0x846750, then `push 0xdd30f8;
  call 0xaa0270` at 0x846755..0x84675f, then `push 0xdd30dc; call 0xaa0270` at 0x846764..0x84676e.
  The PE's bytes at 0xdd30f8 are `resinfo\itemrare.txt`, and at 0xdd30dc `resinfo\itemoptionefp.txt`.
  Confirmed.
- **`FUN_00a9f2e0`.**
  - The gate: `(w&2)==0`, `(b&0x1c)==0xc`, `(b&0x60)==0x20`, `(w&0x780)==0x300`, or `==0x200` with
    `w>>0xb` equal to 1 or 2 (`getfn.sh 00a9f2e0` output, l. 171 and 240-241).
  - The `+0x54` length test (l. 174).
  - `FUN_004522f0` finds in `DAT_0110ac80`, and `FUN_00452230` inserts.
  - Confirmed. `inherits_glow` packs the word and runs these tests as written.
- **`FUN_00aa0270`.**
  - The same walk and gate (`getfn.sh 00aa0270` output, l. 126-160 and 512-516).
  - A row's list is allocated on the item's first row and inserted in both maps (l. 265-282). An
    existing list is reused through the map's value (l. 286).
  - The group step inserts the base's vector pointer for each member without a list (l. 361-390).
  - Columns: code, efp, scale (`atol` ÷ the constant), bone, offset (`FUN_00a76cf0`), min, max.
- **The defaults.** At 0xaa0acc, `mov byte [esp+0x195],0xff` when the max token is missing or
  empty, and min 0 likewise. The append is at 0xaa0ae0 through `[esp+0x38]`, the existing list.
  Confirmed.
- **The rows.** `itemrare.txt` has 3,446 five-column lines (one is the header) and 57 one-column
  lines (MEASURED). So its rows get 0..0xFF and show at +0, as the round says.
- **The shared vector.** Implemented as one shared `Array` per base. On this archive no
  `itemoptionefp.txt` row lands in a shared list (the round's measurement). The replay order (each
  call's rows, then the groups in key order) matches the decompile.

### Round 741's READ (`CRTModParticle::FUN_00c81190`)

- **The bone branch.** At 0xc811c5..0xc811de it loads `esi = [[+0x50]+0x80]+0x40`, gets the owner's
  matrix through `[[+0x5c]]+0x18`, and calls `0x55ebd0` with `ecx = bone matrix` and the arguments
  (out, world). That is bone × world in the row-vector convention: `skel.global_transform *
  bone_global_pose` in Godot's. Confirmed.
- **The `+8` flag.**
  - The constructor (`0xc815b0`, vtable 0xe0e6f0, which has a destructor only) clears `+8` and sets
    `+0xc` to identity.
  - `+8` is set to 1 only at `0xc77bff`, in the resource-list path (from a list entry's byte +0x53).
  - The seven-argument creator `0xc77ca0` (`ret 0x1c`, which creates the mod and calls `0xc81350(1)`)
    never sets it.
  - INFERRED: `0xc77ca0` is the `+0xcc` slot that `FUN_00a5f3e0` calls with seven arguments.
  - So an equipment row gets no extra mod matrix. Leaving it out is right.
- **The scale.**
  - Retail hands the effect `bone × world`, which carries the world matrix's scale (the body's
    height). Then `vslot_010(+0xc0)` gives the row scale.
  - `holder_transform` uses `orthonormalized(bone frame) × col3/100 × cbrt|det(skel.global)|`.
  - They agree when the item's bone poses carry no scale. Their rotation is the same.
  - The further `*(this+4)+0x264` is still OPEN, as the round says.
- **Billboard facing.**
  - `TURN_VERTEX` builds each plate in world space from `INV_VIEW_MATRIX`'s right, up (world up
    for YBillboard, READ `CEFSystem::FUN_00cb0ee0`) and −back.
  - It applies the old order: scale, then shape (quaternion), then view.
  - So a plate faces the drawing camera under any holder rotation and any mirror.
  - Instance custom data was the UV rectangle. It can now hold the quaternion, because `p.uv` is
    written only by `K_SLIDE` (`efp_sim.gd` l. 1022), and `_slides` keeps those nodes on the old path.
- **Pipes.**
  - `PIPE_TURN_VERTEX`'s side matches `pipe_ribbon`'s: right·d.y − up·d.x, normalised, × w × the
    holder scale. The CPU path's `inv * cb.x` carries 1/s, and its normalisation cancels it.
  - The stitching copies a vertex's custom data with its position, so the joining triangles stay
    degenerate.
- **What sharing the simulation loses.** Finding 1 (space-0 vectors). Every other node's local
  transform is parent-relative and survives.

### The mirror (character select, equipment window)

Both hang the body under a `(1, 1, -1)` node, and holders now keep it.

- All 106 LinkPipe nodes and 365 RenderMesh nodes in the 74 files have D3DCULL 1 (none): the `R`
  line's first field (MEASURED).
- Billboards are `cull_disabled` (`material_for`, `billboard or …`).
- ViewNone plates with cull 3 go through Godot's own mirrored-instance face flip.
- So no face is lost under the mirror.

### The item table (round 741)

- **Thread safety.**
  - `Pk2Reader` locks its file seek and read and its directory cache (`_lock`).
  - The native reader reads positionally.
  - `NativeAssets.table_rows` makes a new `SrNativeTables` per call.
  - `ParseProfile` is locked.
  - No consumer writes to the shared dictionary or its `Item`s (grep of every `_items[...] =` and
    item-field assignment outside the reader).
  - Nothing closes `_media_pk2` while the worker runs.
- **The native library.**
  - `native/src/core/tables.rs` and `gd_tables.rs` expose `org_code_names`.
  - `native_tables_test.gd` compares the field both ways, with `XXX` and with the column missing.
  - `release.yml` l. 83-89 builds the Linux `.so` and the Windows `.dll` from source for every tag,
    so the user's Linux build carries the column.
  - `NATIVE_API` stays 5. A stale library gives `""`, and nothing inherits. That is graceful.
- **Coverage.** No hard-coded itemdata list is left in `client/scripts` (one stale comment remains in
  `client/tools/glow_inherit_probe.gd` l. 6). `CharacterPreview` has no caller.

### Regressions in other `EfpEffect` uses

`EfpEffect` builds `_draws` entries as `[tpl, mmi, view]`, 3 elements, and only `use_shared_turn`
appends `d[3]`. `EfpLinks.Out.turn` is false unless `use_shared_turn` set it, so
`format_flags()` is 0 and `pipe_ribbon` runs as before.

- `use_shared_turn` assigns duplicated materials to the master's nodes. It never edits the cached
  `_materials` that skills, buffs, teleport gates, ambient effects, monsters and NPCs share.
- Its static `_turn_materials` is cleared with the other caches.
- `use_shared_turn` is called only from `EquipFx.add_host`.

## Performance

`perf_gate.sh --base cf268f33 --sites jangan`, Forward+ on the RX 7600:

`--frames 40000`. The default run ended before the gate's 35 per-second samples at about 560 fps,
and the first attempt gave "missing numbers". One base run was repeated because another lane's
render overlapped it. Medians of 3, native readers OFF on both sides:

| Site | frame ms | entry ms | freeze ms | hitches |
|---|---|---|---|---|
| jangan | 1.60 -> 1.55 SAME | 10342 -> 10115 SAME | 3653 -> 3573 SAME | 5 -> 5 SAME |

The round's own runs: Jangan SAME on all four numbers. 200 Sun spears +1.7 ms, the cost of the
second effect (finding 2).
