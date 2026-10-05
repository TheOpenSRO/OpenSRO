# Round 721 review: the Alexandria gate portals' rings

Independent adversarial review of `dev..61e0d153` (3 commits). No code was changed.

Labels: READ (decompile `/var/tmp/decomp_client` and objdump of `/root/sro_client.exe` on the
render box), MEASURED (headless probes on the box, `RENDER_DIR=/opt/opensro-client-r721rev`,
GDScript readers), INFERRED.

## Verdict

**The ring fix is right.** For `alex_portal` the shipped skin is the original's skin exactly.

**The rule is a heuristic, not the original's.**
- **The original's rule (READ).** Every map object skins with `P = InvBind_file x W`, at
  skeleton scale 1.0 and with no condition.
- **Where the heuristic matches it (MEASURED).** On 132 of the 140 animated map `.bsr`, the
  heuristic gives the same skin as the original. The other 4 of the 144 models are not `.bsr`
  files, and the probe below does not cover them.
- **Where it does not (MEASURED).** It departs on 8 models: `tre_willow03`, `tre_tree01_big`,
  `tre_bamboo04`, `oas_hot_tree_stone` and the four `demon_wall_deco*`.
- **The lane's reason for those 8 is refuted.** The skeleton scale cannot be what "undoes" the
  willow's scaled binds:
  - the map path never sets the scale, so it stays 1.0 (READ);
  - a first-bone scale could not undo a scaled bind chain anyway (arithmetic, finding 1).

No BUG and no REGRESSION was found:
- **Characters, monsters and items** are untouched;
- **Tests:** 232 suites, 0 failing;
- **Check:** 606 scripts and 9 scenes, ALL LOAD.

## Findings, most severe first

### 1. WRONG-LABEL: "the client undoes such a scale with the skeleton scale; its map caller is not read"

**Where:**
- `docs/rounds/r721.md:125-127` and `:146`;
- `docs/protocol/BSK_FORMAT.md:156-157` ("its default is not read") and `:199-205`;
- `client/scripts/assets/skeleton3d_builder.gd:328-334`;
- `client/scripts/assets/skeleton3d_builder_test.gd:237`;
- `docs/TODO.md:3021`, `:3028-3030`.

**Evidence (READ).**
- **The skeleton's default.** `RTSkeleton::FUN_00c513c0` is the RTSkeleton constructor. It sets
  `+0x98 = 1`, the bone vector at `+0x24..+0x2c`, and `fld1` at `0xc5144d` → `fstp [esi+0xa4]` at
  `0xc51461`. So the skeleton scale defaults to **1.0**.
- **The compound's default.** The `CCompoundObj` constructor (`ResourceMgr::FUN_00c32e50`) runs
  `fld1` at `0xc33105` and `fldz` at `0xc33117`, then `fxch` at `0xc33164`. The `fstp [esi+0x1b0]`
  at `0xc33178` therefore stores **1.0**.
- **What writes `+0xa4`.** The only other writer of skeleton `+0xa4` in the binary is slot 9
  (`FUN_00c25460`, `0xc25481`). The other `[reg+0xa4]` stores belong to other structs: compound
  `+0xa4` at `0xc252d4`, and `CCompChar` slots 3 and 12.
- **The map's object build calls no slot 9.**
  - `Map::FUN_00a38f60` (called by `Map::FUN_00a34140`, `FUN_00a342b0` and `FUN_00a34a90`, the
    paths that start `"default"`) creates the compound through `Map::FUN_009fe760`.
  - It then calls compound slots 12 (`+0x30`), 10 (`+0x28`, twice) and 4 (`+0x10`). It never
    calls slot 9 (`+0x24`).
- **The scan of every slot-9 call.** There are 251 virtual call sites through `+0x24` in the
  binary. Those that push a float are:
  - UI gauges;
  - `IDecoSkill` effects;
  - `FUN_009c4510`, which passes the game object's `+0xc4`;
  - `GlobalDataManager::FUN_009d1d60`, which passes `+0x72c`.

  None is in the map's object path.
- **Conclusion.** A map object skins at scale 1. This is INFERRED from the absence of a call, but
  both the constructor default and the creation chain are READ.

**Arithmetic.** `FUN_00c4bcb0` multiplies the first bone's whole 3x4 by `s`.
- So every `W` becomes `W(1) x S`, and `P = IB x W(1) x S`. That scales the skinned mesh by `s`
  about the object's origin.
- For `tre_willow03`, a vertex `d` away from Bone03 lands about `1.793 d` away from it. A scale
  cannot turn a 1.793-scaled bind chain into the identity at rest.

**Measured (`tre_willow03`).** The keys equal the stored locals: Bone02's local is
(80.68, 0, 0), and so is its first key. The stored second and third pairs agree with each other:
Bone03 at (24.45, 426.52, -38.41) against (14.33, 238.20, -20.73) composed. So by our readers
the original draws the willow with `P = IB3 x W(1)`, and that is **58.4** off its mesh at the
first key.

Either retail really draws these 8 models off their meshes, or one of our readers is wrong for
them. That question is OPEN. The skeleton scale is not the answer.

**Fix.**
- Replace the scale explanation everywhere listed above with the READ facts: the scale defaults
  to 1.0, and the map path never calls slot 9.
- Change BSK_FORMAT.md:157 ("its default is not read") to the same.
- Say plainly that the 8 models are unexplained.
- Settle them with a retail look at a placed `tre_willow03` or `tre_tree01_big`. If retail draws
  them pulled down, the rule can apply unconditionally.

### 2. DEPARTURE: the condition in `consistent_stored_binds` is OURS, and it departs on 8 models

**Where:**
- `client/scripts/assets/skeleton3d_builder.gd:335-363`;
- `client/scripts/world/map_animation.gd:159`;
- `docs/protocol/BSK_FORMAT.md:179-185`.

**Evidence (MEASURED, a reviewer probe over every animated `.bsr` in Map.pk2's `object.ifo`, at
t = 0).** For each model the probe computes the mean vertex distance from the mesh three ways:
- **composed:** the bind before this round;
- **shipped:** `m.skin`, as built now;
- **original:** every bone's third pair, at scale 1.

Results:

| model | composed | shipped | original | shipped vs original |
|---|---|---|---|---|
| `tre_willow03` | 0.000 | 0.000 | 58.431 | 58.431 |
| `tre_tree01_big` | 0.001 | 0.001 | 32.587 | 32.587 |
| `tre_bamboo04` | 0.000 | 0.000 | 0.569 | 0.569 |
| `demon_wall_deco` (and `_fire`, `_death`, `_poison`) | 0.002 | 0.002 | 0.543 | 0.541 |
| `oas_hot_tree_stone` | 0.000 | 0.000 | 0.477 | 0.477 |
| the 14 models the heuristic takes (the 9 that move, and 5 that move ≤ 0.001) | | | | 0.000 |
| `chinaetc_islamman` / `chinaetc_kisaeng1` | | | | 0.013 / 0.004 |
| every other `.bsr` | | | | 0.000 |

So where the heuristic takes the stored binds, it is exactly the original's skin. It departs only
on these 8.

`r721.md:141` already labels the condition OURS. However:
- **`BSK_FORMAT.md:183`** reads as if the rule is the client's;
- **`map_animation.gd:145-147`** says "Each skin binds to the `.bsk`'s stored world binds (round
  721, READ…)" with no condition.

**Fix.**
- Label the condition OURS at `map_animation.gd:145-147` and at `BSK_FORMAT.md:183`.
- Keep the 8-model table where the TODO entry can reach it.

### 3. MINOR: the 35 monster skeletons are the portal's own case, and the TODO undercounts the rest

**Where:** `docs/TODO.md:3032`, `docs/rounds/r721.md:148`.

**Census (MEASURED, `census_bsk_bind.gd`).** It reproduces 35 `mob` skeletons whose sane root
disagrees, by more than 0.05, with where its children put it. The same census also finds:
- **313** `Item` skeletons;
- **14** `Bldg`;
- **3** `COS`;
- **3** `Artifact`;
- **2** `Dun`, **2** `Nature`, **2** `etc` and **1** `quest`.

The TODO names only the monsters.

**Monster clips (MEASURED, a reviewer probe over every `res\mob` `.bsr`).** It reads each clip's
root key at time 0.
- **Most monsters are the portal's case.** On every `.bsr` with a finite root except
  `reflection_shield` and `ivy`, every clip keys the root where the file's binds put it, not at
  the stored local.
- **So the composed bind displaces them.** On the character path today, these monsters are drawn
  off where the original draws them, by the root shift. This is measured on the skeleton, not
  rendered. The largest shifts:

| skeleton | root shift |
|---|---|
| `mustafa` | 50.17 |
| `event_winter_whiteknight` | 48.16 |
| `baal_weapon` | 32.62 |
| `haroeris_t2` | 14.76 |
| `ghost_undine` | 11.36 |
| `jupiter` | 6.71 |

- **Pre-existing.** This is not a regression of this round.
- **The same condition would take 52 of the 61 affected `.bsr`.** It would not take:
  - `mustafa` / `mustafa_dark`: the largest shift, with every clip keyed at the binds' root;
  - `reflection_shield`: 3 of its clips key the root at the stored local;
  - the NaN-rooted `venefica` and `flame_spirit` family, which round 648 already handles.
- **`ivy`** keys at its stored local (0.19), so taking its binds would move it 0.19, as the
  original does.

**Fix.** Extend the TODO entry with these counts and with the list of monsters keyed at the
binds' root.

### 4. MINOR (latent): a bone without a usable third pair mixes two bind spaces

**Where:** `client/scripts/assets/skeleton3d_builder.gd:311-315`, `:344-351` and `:278-281`.

**The gap.** `stored_world_binds` drops a bone whose third pair is unusable, and
`consistent_stored_binds` then neither compares it nor rejects the skeleton. `build_skin` binds
that bone to the unshifted composed rest while its siblings take the shifted stored binds. Its
vertices would land a root shift away from the rest of the mesh.

**No live case (MEASURED).** All 14 skeletons the heuristic takes have 0 unusable third pairs. The
3 that have one (the reeds `w_cd_reeds_m` and `fw_cd_reeds_l`, and `oas_tarim_rob_b_brid_01`) are
not taken.

**Fix.** Return `{}` when any non-root bone of the skeleton is missing from `binds`.

### 5. MINOR: the probe's column says "stored bind" but prints the bind as built

**Where:** `client/tools/probe_map_bind.gd:4`, `:14` and `:65`.

**Evidence.** The "stored bind" column is `m.skin`'s bind, which is the heuristic's. For 135
models it is the composed bind, not the stored one. The pass-1 and pass-2 numbers in
`r721.md:114-128` came from edited versions of the tool that are not in the tree.

**Fix.** Rename the column "new bind" or "as built", and say in the header that passes 1 and 2
need a code edit.

## What was verified

- **The transform composition (READ).**
  - `RTSkeleton::FUN_00c49f20` and `FUN_00c4bcb0`: `L` comes from the keys when `+0x98` ≠ 0,
    otherwise from the prim's local. `W = L x W_parent` (`thunk_FUN_00aa37e4`, the D3DX multiply
    through the table at `0xec7720`), and `P = (prim+0x20)+0x80 x W`.
  - `PrimSkeleton::FUN_00bf9e60` fills prim matrix `+0x80` from record `+0x74`, the third
    (quaternion, vector) pair. So the palette uses the file's inverse bind.
  - `FUN_00c4bff0` passes skeleton `+0xa4` as `param_3`.
  - `CCompChar` slot 9 `FUN_00c25460` writes compound `+0x1b0` and skeleton `+0xa4`.
  - The defaults and the map path are as in finding 1.
- **The lane's tables (MEASURED).**
  - `probe_map_bind.gd` reproduces all 144 models: 9 move (alex_portal 19.754 → 0.000,
    quest\teleport01 31.714 → 0, the demon altars 54.758 → 0.001, the fortress doors
    89.483 / 44.606 → 0, arabianf_bujok03 481.339 → 8.699), and 135 move 0.000.
  - The stored third pair inverts to the second pair to 0.01 on the models checked (the willow's
    Bone02 and Bone03).
- **The rings over time (MEASURED).** `probe_map_anim_pose.gd` on `alex_portal` at
  t = 0, 1, 2, 4 and 7 s puts every ring piece's posed centre within 0.4 of (0, 169.1, 0). Each
  bone's posed origin equals its stored bind at every time.
- **The frames (MEASURED, ImageMagick on the box).**
  - **South gate.** The lane's silhouette metric reproduces exactly: frames 41 and 69 are centred
    at 623.0 / 621.5 on dev and 643.0 / 643.5 on this branch.
  - **The pedestal.** Its two dark pillars sit at x ≈ 566 and ≈ 724 in both builds, so its axis
    is at ≈ 645. The rings sit 2 px from it on this branch and 22-24 px left of it on dev.
  - **Only the rings changed.** The base/head difference in frame 41 is confined to
    198x137+534+96, the rings.
  - **North gate.** Frame 13 differs only in 208x158+423+44. Frames 41 and 69 are byte-identical:
    they do not frame the portal.
  - **The 20.5 px prediction** assumes a depth of 600. That is only roughly the camera-to-portal
    depth, so the 21 px match is approximate.
- **Character paths untouched (READ, code).** `build_skin`'s new `world_binds` argument defaults
  to `{}`. Only `MapAnimation.commit` passes it; `SkinnedBsrAssembler` (`:188`, `:511`) and the
  tests do not.
- **Tests (box, run once).**
  - `remote_godot.sh tests`: 232 suites, 0 failing.
  - `check`: 606 scripts and 9 scenes, ALL LOAD.
  - `skeleton3d_builder_test.gd` alone: ALL PASS, including the 8 new checks.
- **The commits.**
  - Three commits touch 8 text files, all described in the notes: the builder and its test,
    `map_animation.gd`, the two probes, TODO, BSK_FORMAT and the notes.
  - None contains a binary or game data. Grepping the diff for credentials, keys and URLs finds
    nothing; the only URL is the session trailer.
  - The merge base is dev's head, `9996ff3c`.
- **Not re-run: the perf gate.** The brief forbids renders while lane 720 may be rendering. The
  change adds one dictionary pass per animated model template at commit time and no per-frame
  code.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Y12ecfRLgyrW8rPt8BVTF9
