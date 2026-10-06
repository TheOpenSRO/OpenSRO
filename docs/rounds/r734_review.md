# Round 734 (+ merged 735) — independent review

Head `9d6a1a9c` against `dev`. Reviewed in a detached worktree. Labels as in the spec: READ, MEASURED,
INFERRED, OURS. No code was changed.

## Verdict

**Ship after fixing F1.** If the release cannot wait for it, ship with F1's claims corrected in
`r734.md` and `weapon_glow.md`, and park F1 as the first follow-up.

- The in-world glow matches the client binary on every point checked (§ Checked).
- Nothing found breaks play, crashes, leaks or regresses the default object path.
- F1: the character-select screen, the equipment window's avatar and the portrait draw **no glow**,
  although the round says they do. The select screen is the first screen the user sees with this
  release.
- F2 to F7 can follow in later rounds.

## Tests (this review)

| Run | Result |
|---|---|
| `go test -count=1 -p 1 ./...` | exit 0; 59 packages ok, 0 FAIL |
| `remote_godot.sh tests` (`RENDER_DIR=/opt/opensro-client-r734rev`, own lock) | 244 suites, 0 failing |
| `remote_godot.sh check` | ALL LOAD, 642 scripts and 9 scenes |
| Probe A: `PlayerPortrait._apply_materials` on a glow material (headless) | the glow is replaced (F1) |
| Probe B: `EquipFx._reselect` cost at N hosts (headless, real `system_enchant_a_01.efp`) | F3 |

No `qa_shot.sh` render was taken. The two probes answer the questions by measurement, and another
lane's Godot (r736) was running during them. Both probe scripts were deleted from the box afterwards.

## Findings, by impact on play

### F1 — BUG / WRONG-LABEL: no glow on the select screen, the equipment window or the portrait

- **Where:**
  - `client/scripts/ui/hud/player_portrait.gd:461` (`_portrait_material`), reached from:
    - `client/scripts/frontend/charselect_stage.gd:166` (`_dress`, run after `appearance.build`);
    - `client/scripts/ui/paper_doll.gd:231` (the equipment view, which `World3D.gd` turns on);
    - `World3D._refresh_player_portrait` → `set_portrait` → `_apply_materials`.
  - The claims: `r734.md:57` ("The paper doll and the portrait get the glow too") and `r734.md:60`;
    `weapon_glow.md:262` and `:359-362` ("so it glows", "OpenSRO's portrait keeps the glow"); the
    comment at `World3D.gd:9170`.
- **Evidence:** MEASURED, probe A. A `+7` type-3 glow material was put on a mesh whose plain material
  has `alpha_scissor` 0.502, and then passed through `_apply_materials`:
  - before: `is_glow=true`, the shader has `EQUIP_GLOW`;
  - after: `is_glow=false`, no glow code, `glow_texture` null, `alpha_ref=0`.
  - `_portrait_material` maps any object `ShaderMaterial` that is not an MTRL mod and does not blend
    to its own lit material. It takes `albedo_texture` and `alpha_scissor` from the glow material.
  - So the three views draw the item plain and lit. Their particles still show: EquipFx's holders
    are made after `_apply_materials` runs.
  - As a side effect, a flag-0 row's `alpha_scissor` of 0 replaces the plain material's alpha
    reference. An alpha-tested item at +3 or more on a flag-0 type then draws its cut-out texels solid,
    without the glow that retail draws with them.
- **Fix:**
  - In `_portrait_material`, when `EquipGlow.is_glow(src)`, return a copy of the glow material on a
    portrait variant of the glow shader. Copy all the uniforms, as `_mod_material` does. The variant
    is the include under a define that skips `srr_obj_present`, because the portrait's and the
    doll's SubViewports use the Linear tone map, and the global `srr_obj_tonemap` belongs to the
    world.
  - The select screen's backdrop is the world's Filmic environment, so it can keep the world glow
    shader. Keep that copy out of `_undo_tonemap`'s list.
  - Otherwise, at least use `EquipGlow.plain_of(src)`, so that the plain alpha reference survives,
    and correct the claims.

### F2 — PERF: a plus-only 0x3038 rebuilds the whole body; on a crowded arrival, hundreds of times

- **Where:** `client/scripts/World3D.gd:15675` (`_on_other_equipment_changed` → `_redress_other`
  always).
- **Evidence:** READ in the tree.
  - The 0x3038 handler rebuilds the skeleton, the items, the animation entry and the sounds even when
    `worn[slot]` already equals `ref_id`, that is, only the plus changed.
  - The server's `sendPlusesAsBroadcasts` (`world.go:1535`, `:1663`) sends one 0x3038 per plused
    worn item of every other player when the arrival list overflows a frame (about 255 others or
    more). Each one then rebuilds a body that was drawn moments before, up to two per player.
  - GM `/item worn` takes the same path. That one is harmless.
  - The cheap path already exists: `CharacterAppearance.reglow`.
- **Fix:** when the slot's item is unchanged, update `_other_pluses`, call
  `_appearance.reglow(skel, pluses)` and set the `glow_pluses` meta. Do not call `_redress_other`.

### F3 — PERF: EquipFx's re-selection is O(hosts) with a sort, as a spike every 10th frame

- **Where:** `client/scripts/assets/equip_fx.gd:201-247`.
- **Evidence:** MEASURED, probe B. These are upper bounds, because r736's Godot was running at the
  same time.

  | Hosts | `_reselect` median | Per-frame placement (64 shown) |
  |---|---|---|
  | 64 | 0.18 ms (first call 4.5 ms: 64 holders built) | 0.05 ms |
  | 400 | 1.15 ms | 0.05 ms |
  | 1000 | 2.82 ms | 0.05 ms |
  | 2000 | 5.82 ms | 0.05 ms |

  - That is about 2.9 µs per host, paid at once every 10 frames. The frame-averaged `driver` figure
    in r734's profile hides it.
  - At today's player counts it is negligible. At the 1000-player target it becomes a 6 Hz stutter.
  - Also, every host (with a holder) runs an empty `EfpEffect._process`.
- **Fix:**
  - Skip the sort when no more than `VISIBLE_BUDGET` candidates are finite, and leave INF entries
    out of the sort.
  - Spread the scan over the 10 frames, or use a grid.
  - Call `set_process(false)` on each holder.

### F4 — DEPARTURE (unlabelled): EquipFx drops the host's scale

- **Where:** `client/scripts/assets/equip_fx.gd:195`.
- **Evidence:** READ in the tree.
  - The holder's basis is `scale × I`.
  - The per-weapon path it replaced anchored at `scale_basis(placed.basis) × effect_scale`. That
    includes the body's height factor (0.94 to 1.06, `CharacterAppearance.HEIGHT_FACTORS`), so
    particles now ignore the character's height.
  - The `CEFEffect::vslot_010` global factor (`*(+4)+0x264`, weapon_glow.md §8 item 5) is applied by
    neither path, and no label says so.
  - The "always shown within 30 units" rule (`:214`) is unlabelled as well.
- **Fix:** multiply by `EfpEffect.scale_basis(h.skel.global_transform.basis)`. Label the global
  factor OPEN and the 30-unit rule OURS.

### F5 — MINOR: the equipment window's particles simulate while it is closed

- **Where:** `equip_fx.gd:209` with `paper_doll.gd:159`.
- **Evidence:** READ in the tree.
  - The doll is a SubViewport that keeps its nodes and camera when it is set to `UPDATE_DISABLED`.
  - `is_visible_in_tree()` stays true there, so its driver keeps the master simulating every frame
    for a local player at +8 or more, unseen.
- **Fix:** treat hosts in a viewport whose `render_target_update_mode` is `UPDATE_DISABLED` as INF.

### F6 — MINOR: reglow during a fade-in, and reglow without re-lighting

- **Where:** `equip_glow.gd:194` and `World3D.gd:15500`.
- **Evidence:** READ in the tree.
  - Mid-fade, `material_override` is AppearFade's twin, so `plain_of(twin)` makes the twin the glow's
    "plain". A later `clear` restores the translucent twin, and a fade-out finds no fadable material.
  - Also, `reglow` back to +0 restores the base material, at object colour 0.6. CharacterLight is not
    re-run, unlike in `_redress_other`. So a weapon in shadow is drawn too bright until the light
    value changes.
- **Fix:**
  - Take the base from `AppearFade.original_material(mi)` in `apply`.
  - After `reglow`, `remove_meta(CharacterLight.META_VALUE)` and `_light_character(node)`.

### F7 — WRONG-LABEL (it can be upgraded): OPEN 9 and the flag-0 rule are READ through the call chain

- **Where:** `weapon_glow.md:229` and §8 items 8 and 9; the `object.gdshaderinc` comment ("INFERRED
  (OPEN 9)").
- **Evidence:** READ, this review.
  - `CObjRendererVS::FUN_00bf0e20` runs the mods' `vslot_004` first (`FUN_00c451e0` →
    `FUN_00c7b540`, vtable +0x10, with the flag-word pointer), and only then `FUN_00c42a60(flags)`.
  - `FUN_00c42a60` turns on the material's own alpha test (0x200) only when `!(flags & 0x20000000)`.
    The mod's `0xe21f0000` sets that bit, so a flag-0 row really draws without the test. This is a
    stronger proof than r734's, which used `vslot_004` alone and missed that the 0x200 test runs
    after it.
  - The mod also clears `0x1000`, so `FUN_00c42a60` does not reset stage 0 to MODULATE2X.
  - `0x80000000` makes the draw bind the item's own texture to **stage 1**:
    `SetTexture(1, FUN_00c39f70(i))` at `0xbf10ce`. That settles OPEN 9 as READ.
- **Fix:** relabel. No code change.

### F8 — MINOR

- `TIME` wraps at Godot's 3600 s rollover. The 2 s pulse and every scroll speed fit a whole number
  of cycles into 3600 s. +14's 1.4 s pulse does not, so it jumps once an hour.
- `World3D._on_entity_left` erases `_other_pluses` twice.
- Holders made after the select screen's 1 s fade-in started show at full alpha straight away.

## Checked and found correct

- **Tier selection** (`FUN_00a93900`, READ): the highest threshold ≤ plus, the first on a tie; the
  plus is a u8; none at +0 (`FUN_00a5f3e0`). `glow_row` matches. +15…+255 fall back to +14 because
  it is the top row.
- **Pulse** (`vslot_001`, `vslot_002`, the constructor `FUN_00c847f0`: `+0xd8 = 1`): it starts at
  colour 1. The triangle wave flips at the period, and `ROUND(x·255)` is used. The shader matches,
  phase aside (OURS, labelled).
- **Scroll:** `ms·uv / 20.0`, that is 50·uv a second, written to both matrices' translation. The
  shader's `fract` is equivalent under repeat.
- **Stages** (`vslot_004` and `vslot_005`): stage 0 is `op(option, TFACTOR)` with alpha off. Stage 1
  is `op(TEXTURE, CURRENT)` with alpha `SELECTARG1(TEXTURE)`. Flag 1 tests ≥ 1/255. The draw is unlit:
  no DIFFUSE argument anywhere. ADDSIGNED2X is `(a + b − 0.5)·2`. All match the shader.
- **The fade gate:** `vslot_002`, `004` and `005` all require `FUN_00c43780` and the colour word
  `0xFF000000`. `AppearFade._make_twin` and `_fade_pair` take `plain_of`.
- **Particles:** a row applies when min ≤ plus ≤ max, with `(efp, bone, offset, 1, scale, 0)`. An
  unknown bone attaches nothing. Nothing in the tree picks an effect by seal or rarity: the inputs are
  the code name and the plus only, as `FUN_00a5f3e0`'s are the RefID and the plus. The seal
  comparison in r734 follows the data, as the user decided.
- **The default object path:** `object.gdshaderinc` changes only inside `#ifdef EQUIP_GLOW`.
  - The glow shader carries neither `OBJECT_SHADER_KIND_META` nor `MOD_SHADER_KEY_META`, so
    CharacterLight leaves it alone.
  - BerserkLook's tint lands on `object_tint`, which the glow ignores. This is right: retail's stage 0
    uses TFACTOR, not DIFFUSE.
- **EquipFx lifetimes:**
  - A Marker's `_exit_tree` drops its skeleton's hosts and their holders. That covers unequip,
    despawn, a redress (the old skeleton's `queue_free`) and a zone change.
  - `strip_particles`' immediate frees are safe against the queued free.
  - `_shown` entries left stale are skipped by `is_instance_valid`.
  - There is one driver per viewport: the root, the doll and the select screen each get their own.
  - The portrait's copy is stripped before it enters a tree.
  - Masters are freed after 600 idle frames once no host uses them.
  - Every difference from retail in the header is labelled OURS, except F4's.
- **The others' pluses path:**
  - The spawn and the enter or zone lists feed `_spawn_or_update_other`'s `pluses`, and a new body is
    built with them.
  - A drawn body re-glows only when its `glow_pluses` meta differs (Godot 4 compares Dictionaries by
    content).
  - 0x3038 and 0x3039 are kept while the arrival list is pending and replayed after it.
  - The own uid is skipped, and the mover gets its 0x0041 first.
- **Your own plus:** `effective_plus() & 0xFF` from `last_equipment_instances`, which is set before
  `equipment_result` is emitted. Worn instances always fit one frame (`iteminfomore.go`). A plus
  change alone re-dresses the body. The server's `EffectivePlus` is a u8 sum, so it wraps as retail's
  does.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
