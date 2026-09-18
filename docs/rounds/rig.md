## The legs the animation "ate" were inside the dragon's pedestal: the rig is fine

Round 150 measured a dressed player at Jangan local (1002, 917) rendering only
waist-up under the town idle, with the toe bone on the ground and the rest pose
rendering whole, and concluded the fault was the skinned mesh under
`apply_ban_pose`. That conclusion was wrong, and the evidence that overturns it
was already in that round's own rig report.

**What the skinning actually does under the idle -- as numbers.** The new
`tools/probe_skinning.gd` replicates the vertex shader on the CPU: for every
skinned piece it computes `sum_k w_k * (bone_global_pose_k * skin_bind_k) * v`
at rest and after `Skeleton3DBuilder.apply_ban_pose_at(standcity.ban, 0 s)` --
the exact call the world makes each frame. Every piece stays on the body:

| piece | rest y | posed y |
|---|---|---|
| `man_calf` | 0.00 .. 4.26 | 0.01 .. 4.31 |
| `man_thigh` | 3.96 .. 9.86 | 4.05 .. 9.93 |
| `man_pelvis` | 8.90 .. 11.28 | 9.00 .. 11.39 |
| `man_torso_lower` | 10.87 .. 13.42 | 11.00 .. 13.58 |
| `man_arm_lower` | 14.51 .. 15.36 | 8.15 .. 11.76 |
| `chinaman_fighter_hair` | 16.01 .. 19.23 | 16.12 .. 19.36 |

The arms drop from the T-pose to the sides (lower arm centroid 14.9 -> 9.2);
the legs move by a tenth of a unit. 37 of 43 bones have tracks (the six
without are `Spine_Base`, `L HandMid2` and four cloak bones, which keep their
rest); no track names a missing bone; every vertex's weights sum to 1. The
chain dump agrees: `Bip01 R Toe0` global rest (-2.51, 0.00, -1.12) -> posed
(-2.06, 0.01, -0.16). Nothing in the pose lowers or folds the legs.

**What hid them.** The rig report's ray from 60 above the feet, fired at
(1002, 917), had said: *first surface down from overhead at 11.45 above the
feet on `cj_jang_gate07`*, and *one walkable height in this column* (the
terrain, -51.90). That is a solid top 11.45 units over the spot the nav
landed the player on. The pelvis sits at 9.9 .. 11.4 -- so the "tiles" the
waist appeared to stand on were that object's top face, and everything below
it was inside the object. `QA_AT` teleports without collision, so it can put a
player inside a solid; a walking player cannot get there. Three offsets settle
the object's extent: (1020, 917) and (985, 917) are still under `gate07`'s top
(+11.45), (1002, 945) is clear (nearest collider 43 up). `cj_jang_gate07` is
the square's raised plaza; at (1002, 917) its top is the dragon's pedestal,
which is correctly *not* walkable. The docs' "square and dragon at local
~1002, 917" is where the dragon is, not where one stands.

**Where one does stand.** The game's own Jangan spawn is 97/168 local
(1002, **1020**) (`worldmap.go`). There the same dressed body under the same
running idle reports *first surface at -0.00 from the feet on `cj_jang_gate07`*
with two walkable heights in the column, terrain -43.92 and platform -30.12,
the player on the platform; bones -30.10 (toe) .. -14.03 (head), meshes -30.21
.. -10.88. The frame shows the whole fighter on the tiles, sword hanging,
arms at his sides. The palace courtyard (98/168 at 960, 830) gives the same:
surface at -0.00 on `CJ_pal_indoor_floor01`, legs on the floor.

**Shipped.** `tools/probe_skinning.gd` (the CPU skinning replica -- a rig
question is now numbers, headless, in 20 s); `render_dressed_character.gd
--pose=<s> [--group] [--ban]` (the world's idle applied offline, one ~40 s GL
run); and `_qa_rig_report` now says in words when the overhead surface is
above the feet: `** player is INSIDE <object>: its top is N above the feet ...
this is not the rig **` -- the line that would have stopped round 150's
misread. No change to `Skeleton3DBuilder`, the readers or the pose call site:
there was nothing to fix. The 2026-09-08 "stands correctly, arms at its
sides" note in `World3D.gd` stands, now with a mesh-level measurement behind
it rather than a bone-only one.

**Still open, other lanes.** The sword's orientation differs between the
offline posed render (pointing forward) and the world (tip-down at the leg)
at the same clip -- the item-attach lane's question, not this one.
