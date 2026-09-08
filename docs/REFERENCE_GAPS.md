# Gaps against a live server

Reference screenshots from a running Silkroad private server, compared against what this project
renders. These are *observed* differences, not guesses about what might be missing, and each one
names the evidence.

Status is kept honest: **done** means verified in a render, not merely implemented.

## Done

- **The character has no head.** The body was seven `man_*`/`woman_*` meshes and stopped at the
  arms. A real face and hair are separate meshes named for the character's *style*
  (`chinaman_fighter_face.bms`, `chinaman_fighter_hair.bms`) rather than with the body's own
  prefix, and both hang off `Bip01 Head`. Now loaded and attached — the character renders with a
  face and hair. `fighter` is the same real style this project's animations already use.

## Open, in the order worth doing

1. **Water in the moat beside the city wall.** The reference clearly shows a narrow blue channel
   running along the outside of Jangan's wall. This project renders nothing there. Already
   measured (see `docs/WORLD_ISSUES.md`'s eighty-seventh round): real 96/168 carries **30 water
   plane cells with no water-classified tile under any of them**, and drawing water wherever the
   ground lies below a cell's level would flood 65% of that region and 94.7% of the town. So the
   shape comes from somewhere this project has not found yet, and the reference proves it exists.

2. **Wall and roof colour.** The reference palace is vivid **red** with gold-tan tiled roofs. This
   project renders the same buildings grey and desaturated. Worth checking whether the right
   texture is being selected at all, and whether per-layer material colour is being applied —
   `build_godot_material` sets `albedo_color` from the layer's diffuse, and a wrong or ignored
   diffuse would look exactly like this.

3. **NPCs.** The reference has named NPCs standing in the town (`Grocery Trader Jinjin`,
   `Magic POP Guide Gori`, the arena managers). This project renders none.

4. **Monsters as real models.** The reference shows `Mangyang` mobs in the grassland. This project
   has a live monster list from its own server but draws placeholder capsules.

5. **Equipment on the character.** The reference character wears armour. This project caches 8
   real armour sets and assembles them only when the server says a slot is equipped, so a fresh
   character renders bare.

6. **A minimap.** The reference has a live minimap with the region's own art, the player's
   heading, and an X/Y readout. This project has a zone label. The authored per-region minimap art
   is already decoded (`client/tools/dump_ddj.gd`, and the region minimaps this project already
   compares terrain against), so the art side is solved.

## Reading the reference

Two cautions. It is a *private* server, so some content is custom (a Ducky Dungeon, Santa NPCs,
event decorations) and must not be treated as the base game. And its client is the real one, so
anything **structural** it shows — where water is, what colour a wall is, that a gate is open —
is exactly the ground truth this project wants.
