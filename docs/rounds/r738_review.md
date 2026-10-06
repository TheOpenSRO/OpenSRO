# Round 738 review — crowd scale, lane A (animation and skinning)

An independent, adversarial review of `c2479f4d` (branch `worktree-agent-a3ef0cfcc8318a498`, base
`3fc71af2`). It covers A1 (pose only in view), A2 (one skin per body), the indexed pose, A3 (baked
poses) and A4 (far LOD). The A5 spec (`docs/protocol/crowd_gpu.md`) was read for labels only.

I fixed no code. The measurements below are mine, taken on the render box (`192.168.10.78`) with
`RENDER_DIR=/opt/opensro-client-r738rev` and my own lane lock. The renders and the perf gate ran
under the shared lock, only on a quiet box. My probe is a review-only script, not in the repo; its
method is described with each result.

Labels: READ, MEASURED, COMPUTED, INFERRED, OURS, OPEN.

## Verdict

**Ship after finding 1 is fixed.** Finding 1 is an audio regression: other players' footsteps and
other clip sounds go silent, or turn on wrongly, depending on which body last looked up a shared
clip. The round's own "INFERRED harmless" note says the opposite, and the probe measures it on the
real archives.

The look is unchanged where it matters:

- A2 holds over 2,860 more builds, including every job suit and avatar: 0 units.
- One-shots end on their exact last frame.
- The perf gate is SAME.

Findings 2-7 are small and can follow.

## Findings, most severe first

### 1. REGRESSION (audio): the shared clip cache shares each clip's sound tag across bodies

- **Where:**
  - `client/scripts/ui/character_appearance.gd:429` (`t.animation_cache = clips` in `share_template`);
  - the tag is written on every lookup at `client/scripts/assets/skinned_bsr_assembler.gd:569/576`;
  - it is read every frame at `client/scripts/audio_anim/anim_sounds.gd:200`;
  - the round's own note is `docs/rounds/r738.md:318-321`.
- **What happens.** A clip carries the entry it was found as (`BsrReader.CLIP_META`, `[type, group]`).
  `AnimSounds` reads that tag every frame and looks the sound set up in the *drawing* body's own
  `.bsr` (`owner.parsed.sound_set_for(type, group)`).
  - Before the round each body template had its own clip objects. Only that body's lookups set the
    tag.
  - Now one clip object per file is shared by every Figure. Whichever body looked the file up last
    sets the tag for all of them.
  - That includes the local player, whose tick calls `_body_animation_for` on every physics frame
    (`World3D.gd` ~15268): `_body_assets_or_default` returns `_appearance.template_for(ref)`, so the
    player reads the same shared cache.
- **Evidence (MEASURED, review probe, `--only=tags`).**
  - **What was counted.** Every entry of every animation group of the 52 Figures' `.bsr` files, as
    the client's map keeps it (`_clip_entry_in`: 588 clip paths). For each path, every
    (body, tag-from-another-body) pair whose `sound_set_for` answer differs from the body's own:
    - **169 pairs**;
    - **155** of them flip between a sound set and none (sound against silence);
    - 14 shift a footstep by at most 5 ms.
  - The paths:

    | Clip | Tags across bodies | Pairs that differ |
    |---|---|---|
    | `chinawoman_kangsi_runforward.ban` | `7:avatar_wing, 7:spear, 7:bow, 7:sword, 7:default` | **100** |
    | `chinawoman_merchant_walkforward.ban` | `1:default, 1:avatar_nasrun1..3, 1:onehand_staff` | 19 |
    | `chinaman_merchant_walkforward.ban` | `1:default, 1:onehand_staff` | 18 |
    | `skill_eu_fortresshammer.ban` | `187:onehand_sword, 187:cart` | 12 |
    | `skill_eu_throw.ban` | `189:default, 189:cart` | 12 |
    | `chinaman_fighter_walkforward.ban` | `1:default, 1:avatar_nasrun1..3` | 8 |

  - **An example.** `chinaman_merchant_walkforward.ban` is the Chinese bodies' `1:default` walk, with
    `347:snd_walk1, 899:snd_walk1`. It is also the European staff bodies' `1:onehand_staff` walk,
    which has no sound set.
    - After a European staff wielder's lookup, every Chinese body walking on that file is silent.
    - After a Chinese body's lookup, the European ones get footsteps their file does not give them.
    - The first row of the table is the Chinese women's run, which a crowd plays all the time.
- **Fix.** Keep A3's sharing and drop the shared tag. Either:
  - keep a clip cache per body template, and share only the baked `Frames` by file path. For
    example, key `CrowdAnim`'s frames by `"<path>|<layout>"` in a static dictionary, not on the clip
    object; or
  - make the tag per body: store `CLIP_META` as `{bsr path -> [type, group]}` and have `AnimSounds`
    read `tag[owner.bsr]`.

  Then turn the probe's count into a test: no body hears another body's tag.

### 2. VISUAL (minor): A4 can show a stale pose for 1-3 frames on a body's first frame in view

- **Where:** `client/scripts/World3D.gd:6324-6327`.
- **What happens.** A1 poses a body in the same tick it enters the frustum, which was checked: the
  tick runs in the first physics step of the frame, after input has turned the camera pivot. But
  A4's `pose_due` test is applied to that first frame too.
  - A body more than 900 from the camera, in a tick of at least 100 characters, that is not on its
    slot this frame, is drawn with whatever pose it last had: for up to 1 frame (900-1800) or 3
    frames (past 1800).
  - A body that spawned out of view and was never posed has the bind pose, arms out. That is the
    T-pose `_spawn_or_update_other`'s own comment says no character in the game shows.
  - At 900 units a body is about 18 px tall (COMPUTED: 1080 lines, 60 degrees, about 1 px a unit).
    It is a small flash, but it is a departure the round did not list: retail never skips a
    player's pose (READ, crowd_scale.md).
- **Evidence:** code reading. Not rendered: the review's lineup had no body past 900. INFERRED
  from the order of the two tests in the loop.
- **Fix.** Bypass `pose_due` on a body's first in-view tick. A player's CullCache entry has two
  unused fields ([2] and [4]), so one can carry "was in view last tick". Or pose every
  newly-spawned body once at spawn.

### 3. MINOR (leak): Volume variants and their base skin form a reference cycle

- **Where:** `client/scripts/ui/character_appearance.gd:470` and `:474`.
- **What happens.** `base` keeps the dictionary of variants in its meta, and each variant keeps
  `base` in its own meta. Both are RefCounted, so neither is freed when the `CharacterAppearance`
  dies.
  - Every select or create screen visit that builds a non-neutral Volume, and every world entry
    with such a body, leaks the layout's base skin and its variants: a few KB each.
  - The round avoided exactly this cycle for `Frames`, which keeps no reference to its clip.
- **Also:** `free_templates()` (`:736`) does not clear `_canonical_by_layout` or `_clip_cache`. Its
  doc (`:85`, "free_templates() releases the cache") now overstates what it does. The clip cache
  holds every baked frame.
- **Fix.** Key the variants in a dictionary on the `CharacterAppearance` (`_canonical_by_layout`'s
  sibling) and mark a variant with a non-owning id or a `WeakRef`. Clear both dictionaries in
  `free_templates()` and in `NOTIFICATION_PREDELETE`.

### 4. WRONG-LABEL: the doll is not "posed by its own unchanged call"

- **Where:**
  - `docs/rounds/r738.md:104-107`;
  - `client/scripts/world/monster_crowd.gd:170` ("A skeleton without META_LAYOUT (the player,
    NPCs)");
  - `client/scripts/ui/character_appearance.gd:621`.
- **What happens.** `CharacterAppearance.build` now puts `META_LAYOUT` on every body it builds. The
  character window's doll is in `_animated` (`World3D.gd:9173`), so it now goes through
  `MonsterCrowd.pose_at`'s indexed path, not `apply_ban_pose_at`. It is not an other player, so it
  gets no `META_CACHED`. That path writes the same values but skips the forced bone update.
  - The doll's SubViewport draws after the skeleton's end-of-frame update, so it looks the same
    (INFERRED, not rendered).
  - The local player is also now tagged with `META_LAYOUT`. It is still posed by
    `apply_ban_pose_at`, so the comment's "the player ... takes the old path" is true only because
    it never reaches `pose_at`.
- **Fix:** correct the two sentences. Or set `META_LAYOUT` only where other players are spawned,
  if the doll is meant to keep the forced update.

### 5. WRONG-LABEL (minor): the quantum's offset is not "the same at every pose"

- **Where:** `client/scripts/world/crowd_anim.gd:28-35`; `docs/rounds/r738.md:63-67, 249`.
- **What happens.** The offset from the exact time is fixed only within one cycle of a loop. At
  each wrap, `fposmod(t, duration)` re-rounds to the quantum grid unless the duration is a multiple
  of 1000/120 ms.
- **Evidence (MEASURED, review probe).**
  - 50 of the 75 loop clips the 52 Figures play (stand, run, walk, sitting, battle stand) have
    such a duration.
  - The worst one-frame error in the shown clip-time step, over three cycles at phase 0.37 x 7,
    is **0.667 ms** against 16.667 (`chinaman_fighter_walkforward`, 1,166 ms).
  - So it is a tiny jitter once a cycle, not none. Visually negligible: it is under 0.2 of the
    0.44-unit worst offset.
- **Fix:** say "fixed within a cycle; at most 0.67 ms of step error at a loop's wrap (MEASURED)".

### 6. PERF (minor): A1 poses bodies that Character Sight Range has hidden

- **Where:** `client/scripts/World3D.gd:6318-6323`.
- **What happens.** At Character Sight Range 0 or 1, the meshes of other players stop at
  `visibility_range_end` 600 or 1,200 (`VideoOptions.CHARACTER_RANGE`; `_apply_character_range_to`).
  A1 tests only the frustum, so a body past that range but inside the frustum is still posed,
  though nothing of it is drawn. The READ rule A1 cites is "poses only what was drawn".
- **Fix:** add `dist > _character_range` (when the range is above 0) to the cull test.

### 7. MINOR (QA only): `META_LAST` is not cleared when another path poses the skeleton

- **Where:** `client/scripts/world/crowd_anim.gd:288` and `client/scripts/world/monster_crowd.gd:182-189`.
- **What happens.** `pose_cached` writes a clip's static channels only when `META_LAST` names
  another `Frames`. Two other paths pose the skeleton and leave `META_LAST` stale: the indexed path
  (a clip with `duration_ms == 0`, or `cache_poses` off) and `apply_ban_pose_at` (`QaLineup._pose_current`).
  After a different clip on one of those, a return to the clip in `META_LAST` keeps that clip's
  static channels.
  - In play no clip of 2+ frames has duration 0 (INFERRED), so this reaches only QA steps that flip
    switches, such as `anim=-` then `anim=1i3` in one boot.
  - Measured channels show it can matter little: about 39.8 of 39.8 positions "move".
- **Fix:** `skeleton.remove_meta(CrowdAnim.META_LAST)` on the non-baked paths in `pose_at`.

## Checked, no finding

### A1

- **Stale pose on entering view (within 900).**
  - The tick runs in World3D's first physics step of the frame (`World3D.gd:15243-15251`), after
    input. `get_frustum()` is the camera's live global transform, so a mouse orbit is already in
    it.
  - A body turning into view is posed in the tick before the frame that draws it.
  - `crowd_anim_test` covers this.
  - The only lag is the spring arm's own length update, one physics step. It is covered by the x1.5
    margin.
- **Shadows of off-screen bodies.**
  - At Shadow Detail "Detail" (High preset) the sun's shadow map is on and characters cast
    (`World3D.gd:483`). Middle uses Circle blobs, which are not posed.
  - The sun is fixed at 45 degrees elevation (`World3D.tscn:88`: basis z = (0.5, 0.707, 0.5), READ).
    So a body's shadow lies within its own height of its feet.
  - The cull sphere is about the feet with radius 1.5 x the bind reach (`CrowdAnim.player_radius`).
    So the whole shadow is inside the sphere: a shadow in view means a posed body (COMPUTED).
  - Water reflection does not draw characters (`water_reflection.gd:327`).
- **Sounds, hand-backs, hit timing.** A player's entry keeps `audible = true`, so the loop never
  takes the "neither posed nor heard" exit. `_anim_sounds.advance` and the one-shot hand-back run
  for unposed bodies exactly as before.
- **Selection.** Picking uses the click collider (`_other_player_collider`), not the pose. No other
  viewport looks at the world's bodies: the doll, portrait and create preview have `own_world_3d`.
- **Late registration.** `_animated` gets the entry before the holder's `character_id` meta is set,
  but the CullCache sees it only in the next physics tick, by which time the body is in the tree
  with its meta.

### A2

- **Parity beyond the catalogue kit (MEASURED, review probe).** One Figure per race and sex, at
  Volume 0x02 and 0x44, built both ways:
  - every job suit (slot 8) and avatar (100) the item table has;
  - every ninth armour row of the race (slots 0-5).
  - Result: **2,860 builds** (head 288, chest 304, shoulder 300, hands 276, legs 300, feet 312,
    suit 520, avatar 560), **3,729,270 vertices** CPU-skinned both ways.
    - Worst distance: **0 units**.
    - No out-of-range vertex bone index.
    - **0** builds with more than one skin on the body skeleton.
- **The layouts.** The Figures' 52 `.bsr` files name exactly two skeleton files,
  `europeman_skel.bsk` and `europewoman_skel.bsk`; the Chinese bodies use them too (MEASURED).
  That confirms crowd_gpu.md's "two skeleton files".
- **Re-dress and reglow.**
  - `_redress_other` builds a new body through the same `build`. Its old skeleton is freed and its
    CullCache entry is pruned within 600 ticks.
  - `reglow` touches only materials and particles.
- **Bodies leaving.** Skins are shared, so there is no per-body skin to free. `META_LAST` goes with
  the skeleton. Apart from finding 3, nothing is kept per body.

### A3

- **One-shots end on the exact last frame (MEASURED).** 38 one-shot clips (die, sit down, stand
  up, attack, hit, including the casts they fall back to) were posed at every 1/60 s from 0 to past
  the end, baked against `apply_ban_pose_at`.
  - Worst bone difference: **0.000004 units**.
  - At or past the end: **0**.
  - The reason: a one-shot's clock is a whole number of physics steps, so it lands on a baked
    frame exactly.
- **The 0.44-unit offset.**
  - It applies only to loops, through their OURS phase (0.37 s x index).
  - It is a phase shift, not a shape error (finding 5 is the only caveat), so it cannot be seen.
  - The probe's "4.59 px at 90 units" is the distance to the exact pose at the same time, not a
    visible error.
- **Blending and speed.**
  - Neither path has crossfades: base and head both cut between clips.
  - Neither scales clip speed for other players: the clock is `_idle_anim_time + phase`.
  - So there is nothing to break.
  - A clip change while culled is handled: `META_LAST` differs, so every channel is written.
- **Memory.** About 2.2 KB a frame (the round's figure; Variant arrays of about 40 quaternions and
  40 vectors, COMPUTED to the same size).
  - It is bounded by the clips players use, and it is kept until the appearance dies (see
    finding 3).
  - Cast clips are parsed per cast and their `Frames` die with them.

### A4

- No pop at the bands: each pose is exact at its own time, and only the posing rate changes.
- The 100 count is `_animated.size()`, which also counts NPCs, monsters and the doll. Retail's
  `DAT_00ec4ce8` is the live CICharactor count (READ, crowd_scale.md), so that matches.
- That players are skipped at all is a departure, labelled OURS. See finding 2.

### Regressions

- **The local player** is still posed by `apply_ban_pose_at` (`World3D.gd:15287-15303`).
- **NPCs and monsters** are unchanged: `canonical` is off and their cull entries have five fields.
- **The select, create and portrait screens** pose through `apply_ban_pose_at` on their own
  bodies.
- The perf gate's Jangan view (no other players) holds the base.

## Gates

**Box `check`** (`RENDER_DIR=/opt/opensro-client-r738rev`): `checked 647 scripts and 9 scenes`, **ALL LOAD**.

**Box `tests`:** **`ran 246 suite(s), 0 failing`**.

**Perf gate** (`PERF_LANE=r738rev client/tools/perf_gate.sh --base 3fc71af2 --sites jangan --frames 40000`):
the shared lock, a quiet box, and overlapped runs repeated by the gate. Exit 0.

```
jangan  frame ms   base 1.59  head 1.57  (-0.0)  SAME
jangan  entry ms   base 10115  head 10136  (+21.0)  SAME
jangan  freeze ms  base 3566  head 3517  (-49.0)  SAME
jangan  hitches    base 5  head 4  (-1.0)  SAME
```

**The look, base against head** (`qa_shot.sh`, shared lock; Forward+ on the RX 7600, banner checked;
1280x720). Each build ran one boot of the same lineup:

- Bodies: `OPENSRO_QA_LINEUP=all`, `_COUNT=104` (105 animated with the player, so A4's
  100-character rule is live), `_COLUMNS=26`, `_SPACING=8,10`.
- Phases: `_ACTIONS=stand,run`, `_PHASE=4`, `_SHOTS`.
- Camera: the Jangan spawn, pitch -15, distance 90.

| | base `3fc71af2` | head `c2479f4d` |
|---|---|---|
| stand: TPOSE, feet range | 0 of 105, -0.150 .. +0.761 | 0 of 105, -0.150 .. +0.761 |
| run: TPOSE, feet range | 0 of 105, -0.148 .. +0.976 | 0 of 105, -0.148 .. +0.976 |

`frame_ab.py` on the two lineup shots:

- **Crowd box** (`130,250,1040,150`): `dmean 0.14, d8 0.002, d32 0.000` in both stand and run.
- **Whole frame:** stand `d32 0.001`, run `d32 0.004`.
  - These differences are outside the crowd: the gate's portal effect and foliage. That is INFERRED
    from the crowd box being clean, not measured.

I looked at both frames as well: no visible difference. No body was past 900, so A4 did not skip
any pose here. Finding 2 is not covered by this render.

## Review probe (not committed)

`r738rev_probe.gd` was a SceneTree script run headless on the box against
`/opt/sro-files/client/{Data,Media}.pk2`, built from the round's own `crowd_anim_probe.gd`. Its
sections:

- **A2 extra parity:** the item table's suits, avatars and sampled armour, both builds, CPU-skinned.
- **Tags:** the cross-body `CLIP_META` census and sound-set comparison.
- **Loops:** the quantum remainder and the wrap step.
- **One-shots:** baked against exact at every 1/60 s.

`REVIEW RESULT: 0 failing` (its only failure test was the one-shot check). The tag census is a
count, not a pass/fail.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
