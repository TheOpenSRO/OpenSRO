# Crowd scale A5: far bodies drawn as GPU instances (spec)

Round 738 wrote this. **Round 747 built it** (`client/scripts/world/crowd_gpu.gd`, `docs/rounds/r747.md`);
section 8 says what it answered and where it departs from the design below. It is lane A's fifth item in `crowd_scale.md` section 5:
draw far other players as `MultiMesh` instances skinned in the vertex shader from baked bone
matrices, and keep full skeletons for the near ones. Round 738 built A1-A4 (`docs/rounds/r738.md`).
This spec says why A5 is the next step, what in Godot 4.2.2 makes it possible, how to build it
without changing a near character, and what is still open.

Labels: **READ** (our code, or Godot 4.2.2's source at the `4.2.2-stable` tag), **MEASURED** (the
box, `QaCrowdProbe`), **COMPUTED**, **INFERRED**, **OURS**, **OPEN**.

## 1. Why: what is left after A1-A4 (MEASURED)

At 1000 other players with 988 in view (1920 x 1080, Middle; round 738's boots), with A1-A4 on, a
standing crowd still costs about 131-147 ms a frame against the 16.7 ms target. The box was loaded
by other lanes; the quietest earlier build read 131. The numbers
are in `docs/rounds/r738.md`. Most of the frame is no longer the GDScript pose:

- **The draw.** 8,553 draw calls: about 8 visible meshes a body, one call each, because Godot does
  not instance skinned meshes. Render CPU is about 22 ms. Round 736's `mesh` step put that share
  at about 20 ms.
- **The engine's skeleton update** (C++, `TIME_PROCESS`). Every posed skeleton runs
  `NOTIFICATION_UPDATE_SKELETON` once per frame. That is `force_update_all_bone_transforms`, which
  emits `bone_pose_changed` once per bone (`scene/3d/skeleton_3d.cpp:912-966`, READ), and then the
  write of every bind of every registered skin (`:245-297`).
  - Every `BoneAttachment3D` (each weapon, shield and shoulder piece) is connected to that signal.
    It receives all 49 emissions of each update and compares the bone index each time
    (`scene/3d/bone_attachment_3d.cpp:151, 316-333`, READ).
  - Round 738's `pose` step against its `anim=1i34` step attributes about 13 µs a posed body to
    it. That is a subtraction of two `process_ms` figures, so the attribution is INFERRED.
- **The pose itself**: about 9-12 ms at 1000 after A3 (MEASURED `pose_ms`), plus the clip tick's
  own loop.
- **Lane B's share**: the physics step spiral (8 steps a frame), the others' interpolation, and
  `EquipFx`. Round 736 has those figures.

The pose-off floor was 69 ms at 1000 (round 738's `pose` step on the base). A1-A4 cannot go
below it. Even a free pose leaves the draw and the per-body nodes. Reaching 16.7 ms with 1000 in
view needs the far bodies off the per-body path altogether. That is A5.

## 2. What makes it possible in Godot 4.2.2 (READ)

- **A spatial shader can read a vertex's bones.** `BONE_INDICES` (uvec4) and `BONE_WEIGHTS` (vec4)
  are built-ins of the vertex function (`servers/rendering/shader_types.cpp:80-81`). Forward+
  renames them to `bone_attrib` / `weight_attrib` behind `BONES_USED` / `WEIGHTS_USED`
  (`servers/rendering/renderer_rd/forward_clustered/scene_shader_forward_clustered.cpp:619-620,
  661-662`).
- **A draw binds a surface's bones and weights only when the shader reads them.** They come from
  the surface's skin buffer, as `R16G16B16A16_UINT` and `R16G16B16A16_UNORM`
  (`servers/rendering/renderer_rd/storage_rd/mesh_storage.cpp:1301-1316`), and are skipped unless
  the input mask asks for them (`:1318`). So a skinned mesh drawn in a `MultiMesh`, with no
  skeleton, still gives the shader its bones and weights. **Whether that holds for a
  MultiMesh-instanced draw is the first thing the A5 round measures** (OPEN 1).
- **Per-instance data.** `INSTANCE_CUSTOM` (vec4) is a built-in of the vertex function
  (`shader_types.cpp:77`). `MultiMesh.use_custom_data` gives each instance its own.
- **Round 738's A2 meshes already name skeleton bones.** Every piece skinned to a body skeleton is
  remapped at template time so that its vertex bone index is the skeleton's bone index
  (`Skeleton3DBuilder.canonical_mesh`). The 52 Figures name two skeleton files (MEASURED, round
  683), and every body of one file and bone count shares one Skin (`CharacterAppearance.
  share_template`). So one row layout of bone matrices serves every mesh of every body of that
  file.

## 3. The design

### Data

- **A bone texture per skeleton layout.** Its rows are (clip, frame) and its columns are bones.
  Each bone is 3 RGBA32F texels: the 3 x 4 skin matrix `pose_global(bone) x inverse(global rest)`.
  That is the matrix round 738's shared skin gives the GPU today
  (`Skeleton3DBuilder.canonical_skin`).
  - The frames are A3's (`CrowdAnim.Frames`, at `CrowdAnim.QUANTUM_MS`), composed into globals
    once per frame when it is baked.
  - Size, COMPUTED: round 738's probe counted 38 clips and 7,152 frames for the 52 Figures
    standing and running, about 47 bones each. That is 7,152 x 47 x 3 x 16 B, about 16 MB at
    1/120 s. Far bodies do not need 120 frames a second: at 1/30 s it is about 4 MB.
- **Volume** (`CharacterAppearance.volume_skin`). Each skin matrix becomes
  `P x scale(1, f, f) x inverse(rest)` for the bones in the Volume table (READ, round 683).
  Either:
  - bake `P` and `inverse(rest)` apart, and pass the instance's Volume level and sex in
    `INSTANCE_CUSTOM` with a uniform table of the factors (2 sexes x 5 levels x 8 groups); or
  - bake one texture per Volume variant in use.

  The first is smaller. The second is simpler to verify.
- **Height** is the instance transform's uniform scale, as it is the node's today.

### Draw

- **One `MultiMesh` per (mesh, material)** for the far bodies. Its instance transform is the
  body's skeleton global transform. Its custom data is (texture row of the clip's frame 0, the
  frame, the Volume index, the fade).
  - At 1000 the census counted 516 distinct meshes and 723 distinct materials (round 736). So the
    far crowd draws in at most a few hundred calls against 8,000, and fewer once lane B's B5
    merges a body's meshes.
- **The instance shader is the body material's shader with the skin added in `vertex()`.**
  - Fetch the four weighted bone matrices from the texture row, and sum them as Godot's skinning
    compute does.
  - Then run the material's own code. Godot's skinning is a compute pre-pass on the vertex
    buffer, so the shader math is new code (OURS). A1's check covers it: the same pose drawn both
    ways must give the same pixels.
- **Items with their own skeleton** (weapons, shields, shoulder pieces) hang on a body bone by the
  client's composition: the item's model space at the attach bone, rotated by the bone's turn from
  its rest (READ, `SkinnedBsrAssembler.attach_item_from_archive`'s doc comment).
  - Their skeletons are never posed (round 738: `_own_skins` no longer copies their skins). So an
    item vertex's skin is `pose_global(attach) x (inverse rest rotation of attach, 0)`.
  - That is one more column per attach bone in the texture, or a per-mesh constant times the
    attach bone's column.
  - Each item mesh is its own `MultiMesh`.

### Which bodies, and the switch

- **Near bodies stay on today's path**, with A1-A4.
- **A far body** has its `MeshInstance3D`s hidden and its skeleton left unposed. A1's frustum test
  already skips an unposed body's pose, and a hidden instance is neither drawn nor re-skinned. It
  becomes one instance in each of its meshes' `MultiMesh`es.
- **The switch distance is OURS, and must not be nearer than anything the far path drops:**

  | What | Where it stops (READ / OURS) | So the switch is at least |
  |---|---|---|
  | Name plates | 300 (READ, round 673) | 300 |
  | Detail shadows (B2) | the ten nearest within 300 (READ) | 300 |
  | Circle shadows (`CharacterBlobs`) | the ten nearest (READ) | none |
  | `EquipFx` particles | the 64 nearest in view within 800 (OURS, round 734) | 800, or the host reads its bone from the texture |
  | Effects that follow a bone (`EfpEffect._place`) | any distance | such a body stays near while it has one |
  | Click body | any distance | none: the `StaticBody3D` stays per body |

- **No pop at the switch.** The same mesh, the same matrices and the same material code mean the
  same pixels. The A5 round proves it by a frame difference of one body drawn both ways at the
  same pose (`client/tools/frame_ab.py`). It also holds the switch to a hysteresis band (OURS), so
  a body walking along the line does not change path every frame.
- **The per-instance pieces Godot does not instance:**
  - the 2 s appear fade (`AppearFade`, READ round 676) and a pending deletion's translucency: the
    fade goes in `INSTANCE_CUSTOM.w`;
  - `CharacterLight`'s per-level material copies: one `MultiMesh` per light level, or the light
    in the custom data (OPEN 3);
  - the weapon glow (`EquipGlow`, round 734): its shader with the skin added (OPEN 4).

## 4. Expected (INFERRED)

For the far share of the crowd:

- the pose and the skeleton update go to zero;
- the draw goes from 8 calls a body to a share of a few hundred calls in all;
- what is left is one instance transform write a frame for each far body that moves.

With lane B's B1 (the step spiral) and B6 (`EquipFx`), that is the path to the 16.7 ms target at
1000. The GPU side was about 5-6 ms at 1080p (MEASURED, rounds 736 and 738). Skinning moves from a
compute pass that runs only when a skeleton changed to every vertex of every instance every frame.
The A5 round measures that cost (OPEN 5).

## 5. Order of the A5 round

1. **The probe (OPEN 1, 2).**
   - Draw one Figure's remapped body mesh as a one-instance `MultiMesh` with a bone-texture
     shader, beside the same body as today's skinned `MeshInstance3D`, at the same pose.
   - Compare the CPU-skinned vertices (`tools/crowd_anim_probe.gd`'s sum) and the two frames
     (`frame_ab.py`). Both must agree before anything else is built.
2. Bake one skeleton layout's standing clips. Draw 1000 standing far bodies, and measure them
   with `QaCrowdProbe` at 20, 200 and 1000.
3. The switch, with hysteresis, the fade and the light levels.
4. Items, then the glow.
5. Walking bodies: clip changes are a custom-data write.
6. The perf gate, and the crowd table before and after.

## 6. OPEN

1. Whether a `MultiMesh` draw of a skinned surface binds the skin buffer for a shader that reads
   `BONE_INDICES` in 4.2.2 Forward+ (READ above says the per-surface vertex format does; the
   multimesh path is not yet traced).
2. Whether `INSTANCE_CUSTOM` and a bone texture fetch keep the vertex shader cheap enough at about
   2.5 M primitives (round 736: 2,564,060 primitives at 1000).
3. `CharacterLight`'s per-level materials on instances.
4. `EquipGlow`'s shader on instances.
5. The GPU cost of skinning every instance every frame, against today's compute pass that runs
   only when a skeleton changed.
6. The device (the user's Steam Machine, RADV NAVI33 like the box) and 4K, carried over from
   `crowd_scale.md`.

## 7. A smaller step, if A5 waits (OURS, not built)

**"A2b": the item attachments without the per-bone signal.**

- An other player's weapon, shield and shoulder piece could follow their bone from the skeleton's
  one `pose_updated` emission a frame, instead of being `BoneAttachment3D`s that receive every
  bone's `bone_pose_changed` (READ above).
- Its saving is bounded by section 1's INFERRED 13 µs a posed body, about 11-13 ms at 1000.
- It needs `EquipFx` and `EquipGlow` to find their hosts without the `BoneAttachment3D`.
  `EquipFx` reads `h.skel.get_bone_global_pose(h.bone)` (`assets/equip_fx.gd:246`).
- Measure it first: a `QaCrowdProbe` step that detaches the attachments' signal would give its
  real share.

## 8. Round 747: what was built, and the answers

The build is described in `docs/rounds/r747.md` (section 2); the measurements are there too. Against
section 6:

1. **OPEN 1, answered (MEASURED):** a `MultiMesh` draw of a skinned surface does get its bones and
   weights in a shader that reads them, under Forward+ and Compatibility. `client/tools/crowd_gpu_probe.gd`
   draws real Figures both ways at the same pose: 5 to 14 of about 30,000 body pixels differ by more
   than 2 (silhouette edges); the CPU replica of the shader's arithmetic lands within 8e-6 units of
   Godot's skin over 22,230 vertices.
2. **OPEN 2 and 5 (MEASURED):** render GPU time at 1000 is 4.18 ms with 980 far bodies skinned in
   the vertex shader every frame, against 6.68 ms for all 1000 skinned by Godot's compute pass
   (r747.md, section 5). The GPU is not the limit.
3. **OPEN 3:** a CharacterLight level is a material copy, so it gets its own twin and its own group;
   `CharacterLight.set_on` reports a change and a far body's parts are re-read.
4. **OPEN 4:** the glow's twin is EquipGlow's shader with the skin; drawn far it matches the near draw
   at a held clock. A far weapon's particles still draw: its body's meshes are hidden one by one (not
   its skeleton), and EquipFx places the holders from the weapon's GPU frame (`CrowdGpu.item_frame`).
5. **OPEN 6** is unchanged (the device, 4K).

Departures from sections 3 and 5 (all OURS):

- **No per-instance clip or fade in `INSTANCE_CUSTOM`.** The clip, its frame count, duration and the
  body's offset are 4 texels of a body texture; the instance's custom data names the body's slot, its
  Volume row and the part's centre height. A clip change is a texel write.
- **Volume as a per-layout factor texture** (`rest x variant bind` per bone and variant), the spec's
  first option in matrix form.
- **The switch is by rank, not by distance:** the 16 bodies nearest the camera, in view or not, stay
  near; a near body goes far only past the 20th. In round 736's lineup every body is within 300 of the
  player, so a distance rule from section 3's table (300 for names) would have left all 1000 near.
  The table's rows are met otherwise: names and click bodies are not part of the skeleton and stay per
  body; EquipFx's particles are placed from the GPU frame; Detail's casters, bodies with effects,
  fading and berserk bodies stay near whatever their rank. A far body within 600 of the listener
  plays its clip sounds from the CPU, advanced only at its clip's keys (after round 747's review,
  F2). What the rank still decides is who is posed on the CPU.
- **Bone pages:** the bone store is pages of 1,024 rows, the layers of a `Texture2DArray`, so a new
  clip uploads its pages, not the store (after the review, F3).
- **Not drawn far:** a body with a blended part (F8), a mirrored body (F9).
- **Fading bodies stay near** (no fade on instances); a departing body comes back to fade.
- **Items** are pre-moved meshes skinned to their attach bone with weight 1 (no extra texture column).
- **One AABB for every group**, re-measured each cycle: a group is drawn or culled as a whole.


## 9. Round 756: arriving bodies drawn far before they are built (ghosts)

`docs/rounds/r756.md`. Retail creates and draws every character of a group spawn in the one 0x3018
call (READ, r756.md section 1); this client dressed arrivals one or a few a frame (rounds 739/748),
so a crowd filled in over seconds. A far body needs no node: `CrowdGpu.add_ghost` draws an arriving
body at once from its kind's recipe (`CharacterAppearance.far_recipe`: the template meshes with the
glow and Volume `build()` would give them, the hidden body pieces left out), keyed by its holder
node; it fades in on the GPU (blended fade twins with the skin; the alpha per instance from the clock
and the fade's start in `INSTANCE_CUSTOM.w`, so one twin a material serves every fade; OURS: the
instances of a fade group are not sorted for the 2 s), is lit by CharacterLight's level as it
appears, swaps its stand/run loop as a texel write (its run baked ahead), and plays its clip sounds
within 600. After the review (`docs/rounds/r756_review.md`): the twins are never cached with a
recipe's parts (collect() may free them) and are counted per twin, not per key; a recipe keeps four
light levels; an aura or a gait change never dresses a ghost synchronously. The dressing follows in the background, nearest first, and hands
the built skeleton the ghost's clip entry in the same frame (`World3D._ghost_handover`); anything that
needs the skeleton (a one-shot, an effect, berserk, Detail) dresses it at once. `_parts_of` is now
`_part_for` per mesh, so a recipe's pieces and a built body's are read by one set of rules
(MEASURED: 300 random real kits, 0 mismatched parts).
