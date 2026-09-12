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
- [x] **Optimize the world load itself** — **done (v0.1.113): 65s → 18s.** Deeper profiling showed
  it was not terrain mesh/collision at all but the pk2 archives being re-opened per region (~1s to
  read the 2GB index each time). Holding the handles open (`_data_pk2` / `_map_pk2` / `_media_pk2`)
  removed ~47s. Further gains if wanted later: defer objects to stream after entry, or a smaller
  initial radius — but the load is now tolerable and the crossing smooth.
- [x] **Per-chunk freeze crossing into a new region** — root cause found and fixed (v0.1.113, round
  160): the pk2 archives were re-opened per region (~1s to read a 2GB index each time). Holding the
  handles open cut the per-cell cost from ~2.2s to ~0.5s and the whole region load from 65s to 18s.
  Streaming still queues cells one per frame (v0.1.107). **Confirm in-game it's now smooth.**
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
- [x] **Character runs backwards on click-to-move** — fixed: the body's visual front is local -Z
  while the player node points +Z at the movement dir, so the skeleton is turned 180°
  (`skeleton.rotation.y = PI`) to align them. Verified by a `--walk 45` render (v0.1.128): the
  body runs forward in the travel direction, in both the WASD and click-to-move branches.
- [~] **Target window like the reference** (pic 2): the authored frame now shows the monster's name,
  its REAL level (grounded from characterdata _RefObjChar col 57, carried in the snapshot), the HP
  bar and HP % (v0.1.129). Still omitted: the rank gem ("General") — the rank column isn't
  identified in characterdata yet, so inventing it is against the rules.
- [?] **Storage-keeper (and NPCs) face the wrong way in Jangan** — BLOCKED: the client's
  `npcpos.txt` is position-only (5 cols: id, region, X, Y, Z — confirmed against the real 12,367-row
  table), so the NPC heading is NOT in the client. Like damage/exp, NPC spawn heading is
  server-authoritative (retail server spawn tables). Needs our server to define/send an NPC
  heading, or a retail server DB — not fixable client-side without inventing headings.
- [ ] **NPC talk dialogue with options** (pic 1): the talk box lists the NPC's services
  (e.g. "1. Deposit into storage / 2. Honor Rank / 3. End conversation"). Needs per-NPC service
  data (which NPC offers storage/shop/etc.); today we only show greeting text.
- [x] **EXP curve recovered + server leveling** — `leveldata.txt` col 1 is exp-to-next-level (139
  levels; level 9 = 17978, matches the screenshot), stat points **3/level** (Stat Point 24 at level
  9). Curve imported at runtime (`cmd/export-leveldata` → CSV → `internal/leveldata`); the kill path
  grants exp, runs `Table.Advance`, grants stat points, refills HP on a level-up, and sends
  `OpLevelUp` (`0x0067`). See `docs/LEVELING.md`.
- [x] **Level-up animation** (pic 3): golden burst + "You have advanced to level [N]" on the
  level-up broadcast. Built (`client/scripts/effects/level_up_effect.gd`): the **real** `levelup01–04`
  meshes + their paired textures from `system_levelup.efp` (Particles.pk2), loaded at runtime, with
  the **real** `UIIT_MSG_STRGERR_LEVEL` message; animation is a disclosed designed grow→fade (the
  .efp's graph curves are not reliably recovered — see WORLD_ISSUES round 163). Verified in a render.
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
- [x] **MENU popup** — now a dark, gold-edged menu with each item's real authored icon
  (`interface\underbar\ub_new_icon_*`) and gold text (v0.1.114, round 161), matching the original's
  structure. Inventory/Character/Skill have no menu icon in this archive, so they are text-only
  rather than a mismatched icon. The ornate authored frame is a later polish.

## 7c. Auto error reporting (dumped 2026-09-11)
- [ ] **Client auto-reports errors to the server** and shows a chat line: "Your client experienced
  an error, this has been auto reported. Please let an admin know." Needs: a client error hook (or
  watch the log for ERROR lines) → send the recent log to the server over a new opcode → server
  stores it (a file per session) → the chat notice. Scope carefully: GDScript runtime errors have
  no clean catchable hook, so likely watch the log file / the missing-asset + `push_error` paths.

## 8. World / collision bugs (dumped 2026-09-11)
- [~] **Stuck/barriered inside a building** — **diagnosed (round 162).** `QA_COLUMNS` at the spot
  (90/48 local 769,205) shows a raised building-floor surface (868.5) above terrain (863), and a
  teleport lands the player on it, inside the walls. The trap is the object mesh collision:
  `ObjectLoader` puts a concave `create_trimesh_shape` building collider on layer 1, the player's
  mask includes layer 1, and a concave collider can't push a penetrating capsule back out. **Fix
  (deferred for a live movement test):** move object colliders to a scenery layer the camera sees
  but the player doesn't, leaving the navmesh walls (the intended blocker) to block the player.
  Risk: a building the navmesh doesn't fully enclose becoming walk-through — not headless-verifiable.
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
