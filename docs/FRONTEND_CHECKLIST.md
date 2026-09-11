# Front-end + in-game — running checklist

The live to-do for the front-end flow **and** the in-game HUD/gameplay feedback the user keeps
dumping. I own this file and keep it current as work lands and as new requests come in. Design
rationale and the real art paths live in `docs/FRONTEND.md`; this is just the checklist. Newest
dumps go under "Inbox" until triaged.

Legend: `[ ]` todo · `[~]` in progress · `[x]` done (with the round/tag) · `[?]` needs a decision or data.

## 1. Connect / login screen
- [x] Reskin `Login.tscn` with the real `login_window.ddj` frame: ID / PW / Server / Connect / Exit (v0.1.103, round 150)
- [~] Backdrop behind it — pass 1 done (real `loading_login_01_2011.ddj` still); pass 2 = 3D flowing town camera
- [ ] Server dropdown / channel list (`login_chanel_window`), even if it is a single server for now
- [x] Keep every existing `NetClient` login/register wiring working (v0.1.103)
- [x] Plain-panel fallback when no Media.pk2 is present, so login always works (v0.1.103)
- [ ] "MaxiGuard verification success"-style status line area (cosmetic)

## 2. Loading screens + world-entry speed  ← **HIGH PRIORITY (user: 60-90s, no feedback)**
- [x] **Loading screen with feedback during world entry** (v0.1.108, round 155) — a "NOW LOADING"
  screen (real `loading_default.ddj` art + a gold gauge that fills as region cells stream in) is up
  over the region load; the initial neighbourhood is now queued and pumped a batch a frame behind
  it. QA renders keep the synchronous load (verified). Real entry now has feedback instead of a
  black freeze.
- [~] **Optimize the world load itself** — profiled per phase across 24 cells: **terrain ~37s,
  objects ~17s, NPCs ~2.4s**. So NPCs were NOT the cost (though caching+duplicating repeated NPC
  models still helped, v0.1.109). The real bottleneck is **terrain**, and within it
  `terrain_mesh.create_trimesh_shape()` — a concave BVH built from the full-region mesh per cell.
  **Next (the real speed-up):** replace terrain collision with a `HeightMapShape3D` built from the
  region's height grid (terrain is a heightfield, no overhangs), which is far cheaper to build and
  collide — needs careful alignment with the visual mesh's rotation/offset/scale and a render
  confirming click-to-move + camera still hit terrain. Then defer objects (~17s) to stream after
  entry. Both are focused, verified follow-ups, not to be rushed.
- [~] **Per-chunk freeze crossing into a new region** — streaming now queues the new leading-edge
  cells and builds one per frame instead of the whole row at once (v0.1.107, round 154), turning
  the ~1s freeze into brief per-frame hitches. **Needs in-game confirmation**; if still felt, next
  step is threading the region build off the main thread. (No low-processor setting found, so the
  "refocus to render" was likely the freeze itself.)
- [ ] Gold-dragon + class-silhouettes default screen (`loading_default.ddj`)
- [ ] Shown on the other transitions too (login→select, select→customize)
- [ ] Pick the region-appropriate loading image where known

## 3. Character select
- [x] Reskin `CharacterSelect.tscn`: list the account's characters (v0.1.104, round 151)
- [x] Stat panel: name, Level, real HP bar (v0.1.104) — MP / EXP / Stat are not tracked server-side, so honestly omitted, not faked
- [x] Buttons: Start, Delete, Create, Cancel (v0.1.104)
- [x] Extend the char-list protocol to carry gender/level/HP so the panel is real (v0.1.104)
- [ ] 3D character standing on the dock backdrop (pass 2)
- [ ] Full-bleed backdrop (Constantinople loading art is letterboxed; fine for now, 3D dock replaces it)
- [ ] Add MP / EXP / stat-point systems, then show them here
- [?] PIN / security — not in our data; omitted (screenshot shows Clear PIN, but we have no PIN system)

## 4. Character create — race / region select
- [?] **Deferred by design:** the server supports only the Chinese race (man/woman) — there are
  no European body assets — so a two-statue race pick would offer an uncreatable choice. Create
  goes straight to customize (Chinese) for now. Revisit if/when a European race is added.
- [ ] (If revisited) build from authored `resinfo\ifregionview.txt`: the two statues, tooltips, lizard

## 5. Character customize / create — **done** (v0.1.105, round 152)
- [x] Panel: Name + Sex (Man / Woman) — the two bodies the server supports
- [x] Live 3D character preview reflecting the sex choice, with the body's own idle animation
- [x] Confirm → creates the character (`NetClient.create_character`) and returns to select
- [x] Cancel → back to select
- [x] `Create` on the select screen opens this screen (temporary inline popup removed)
- [ ] Appearance sliders (figure/height/weapon/cloth) — omitted until there is a system behind them
- [ ] Unique-check button — no name-availability RPC yet; name is validated on create
- [ ] Dress the preview in the starting outfit (currently the bare base body)
- [ ] Rotatable / per-race backdrop polish (using the gold-dragon `loading_charactercustom` for now)

## 5b. Look-better pass (user asked)
- [x] Vignette over login / select / create backdrops so panels pop and letterboxing frames well (v0.1.107)
- [x] Login register link picks up the gold (v0.1.107)
- [ ] Load the client's own UI font for the front-end (authenticity)
- [ ] Char-select: fill the empty centre with the 3D character (pass 2)

## 6. 3D backdrops (pass 2, the expensive one)
- [ ] Shared town backdrop streamed behind the screens (reuse the world loader)
- [ ] Slow flowing camera path through town
- [ ] Swap the pass-1 2D backdrops for it without touching the UI layer

## 7. In-game HUD & gameplay (dumped 2026-09-11, with reference screenshots)
Ordered roughly quick-fix → needs-a-server-system.
- [x] **Left-click drag must not orbit the camera** — only right-drag orbits; a held left button now
  steers the character toward the cursor (v0.1.106; input isn't headless-verifiable, needs in-game
  confirmation).
- [ ] **Character runs backwards on click-to-move** — the body faces away from the movement
  direction. Both move branches set `rotation.y = atan2(dir.x, dir.z)`; diagnose with a `QA_WALK`
  render (body facing vs. heading) — likely a 180° model-forward offset in the click path.
- [ ] **Target window like the reference** (pic 2): the authored frame with the monster's name, HP
  bar, level and rank ("General") and HP %, not the plain bar we draw now. (client-only)
- [ ] **Storage-keeper (and NPCs) face the wrong way in Jangan** — use the placement heading so NPCs
  face as they should. (needs the .ifo placement yaw)
- [ ] **NPC talk dialogue with options** (pic 1): the talk box lists the NPC's services
  (e.g. "1. Deposit into storage / 2. Honor Rank / 3. End conversation"). Needs per-NPC service
  data (which NPC offers storage/shop/etc.); today we only show greeting text.
- [~] **EXP curve recovered** — `leveldata.txt` col 1 is exp-to-next-level (139 levels; level 9 =
  17978, matches the screenshot), and stat points are **3/level** (Stat Point 24 at level 9). See
  `docs/LEVELING.md`. **Next:** import the curve (game data, like refdata) + server exp/level/stat
  tracking + a level-up broadcast.
- [ ] **Level-up animation** (pic 3): golden burst + "You have advanced to level [N]" on the level-up
  broadcast (needs the EXP/leveling above).
- [ ] **Skills menu redone** (pic 4): Weapon / Force tabs, mastery tabs (Bicheon / Heuksal /
  Pacheon), Max Mastery / Max Skill, LEVEL UP, the skill grid with per-skill level arrows, Mastery
  level total. **Recover from `skilldata` / `skillmasterydata` / the Ghidra server** (not designed).
- [ ] **Character menu redone** (pic 5): Current/Next Exp, Stat Point, Honor Point, Str/Int with
  "+" buttons (3/level), HP/MP, derived stats, job alias/level/exp. Layout + the derived-stat
  formulas **recovered from the client** (Ghidra) per the answer.

**The big three (level-up, skills, character stats) are RE-and-build tasks now, grounded in real
data:** the EXP curve is recovered (leveldata.txt); the stat and skill formulas come from the client
/ the Ghidra server next; then the server systems, then the UIs become real.

## 7b. HUD styling (dumped 2026-09-11)
- [ ] **MENU popup** (the underbar MENU button) is a plain text list; the original is an authored
  framed menu with a per-item icon, dividers, and "System (Esc)" at the bottom. Build it from the
  authored menu art / `resinfo` if there is one, or at least add icons + the frame. (The user's
  reference has slightly different items/wording — likely a different client version; match the
  structure, use our own item set.)

## 8. World / collision bugs (dumped 2026-09-11)
- [ ] **Stuck/barriered inside a building** after teleporting into its corner. Repro (F3 on
  client v0.1.104): zone Alexandria, region node `RealTerrain_90_48`, local ~`769.9, 205.1`
  (world `-190.1, 754.9`, ground `-80.5`), near the palace/building corner by the potion stall.
  The player can circle the building but on touching it gets trapped inside. Likely a concave/
  inside-out object collider. Investigate with `QA_SCAN` / `QA_COLUMNS` / `QA_FLOAT` at that spot.
- [ ] Missing model in that session's log: `res\bldg\china\dunhuang\buildings\w_cd_stab_buil03_wal.bsr
  not found in archive` — a Dunhuang wall; check whether a collider is left without its mesh.

## Tooling
- [x] `qa_shot.sh --scene <res://...>` to render an arbitrary front-end scene for verification (v0.1.103)

## Inbox (untriaged dumps)
- JellyBitz's SilkroadLauncher (https://github.com/JellyBitz/SilkroadLauncher) as the outer
  launcher reference — worth a look for the patcher/launch step distinct from the in-client flow.

## Notes / open questions
- Reference is "duckroad" (a private-server reskin): match the flow, not the exact branding.
- Everything here is our design except `ifregionview.txt`; disclose invented constants.
