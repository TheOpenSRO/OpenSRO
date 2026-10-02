# Character select, race select and character create

Recovered 2026-10-02 to drive the select/create implementation rounds. The user (2026-10-01):
"After we do the login intro that will be next and we'll implement it fully including name, race,
gender, model, armor, weapon, rotation, name check, height, and volume." And (2026-10-02): "all of
those features ... that matches the original game as much as possible."

**Sources.**
- The client: `sro_client.exe` on the render box, decompile `/var/tmp/decomp_client`, asm
  `/var/tmp/sro_client.asm`, constants read out of the exe.
- The server side: `SR_ShardManager.exe` from the server package on the box
  (`/opt/sro-files/server/y0gi_Easy_vPLUS/Blitzkrieq_Bin_Data/`), read with strings, objdump and a
  throwaway Ghidra import. **It is a private-server distribution's build.** Nothing modded was seen
  in its lobby code, but every server-side READ below means "READ (this package's ShardManager)",
  not "retail".
- The archives: the box's vSRO `Media.pk2` / `Data.pk2` / `Music.pk2` in `/opt/sro-files/client`,
  read with `server/cmd/pk2list`.
- The shard DB export (EXTERNAL, a private shard's, partly modded): `/opt/sro-files/db/csv/`.
- The reference screenshots `fe_ref1..4` (a private server's reskin). They show the flow, not
  retail art.

**Labels.**
- **READ**: from the exe, a layout or a data file, with its address or file.
- **MEASURED**: counted or decoded from the archives.
- **INFERRED**: reasoned, not observed.
- **OPEN**: not known.
- **EXTERNAL**: from the user's shard DB.
- **OURS**: this project's choice.

No game data is in this file; ids, codes and text keys are references, as in the other protocol
docs. The English strings quoted are from the archive's `textuisystem` English column, abridged.

## Corrections this reading makes to existing records

| Record | Says | What is true |
|---|---|---|
| `docs/FRONTEND.md` "What is authored" | the front-end has no layout file except `ifregionview.txt` | `resinfo\pscharacterselect.txt`, `pscharactercreatechina.txt` and `pscharactercreate_europe.txt` are the select and create layouts (READ, MEASURED). `ifregionview.txt` is the in-game region banner (round 678). |
| `docs/FRONTEND_CHECKLIST.md` section 4, `character.go` Gender comment, `CharacterCreate.gd` header | "there are no European body assets" | `Data.pk2` holds all 26 `Res\Char\Europe\europe(wo)man_*.bsr` bodies and `Prim\Ani\Char\Europe\` clips (MEASURED, `pk2list`). |
| `equipment/starterkit.go`, RE_COMPLETION 2026-09-18 | the original's starting-kit rule is not recoverable | The kit is what the customize screen sends: one of 3 armour sets and one weapon. The server checks race and sex and adds a shield or ammo itself (READ, below). |
| RE_COMPLETION 2026-09-18, recovered_names `SendCharacterCreateChina` | "five dwords then a byte" | The order is u32 model, **u8 scale**, then u32 chest, legs, feet, weapon (READ in both the client writer and the server parser). |
| recovered_names `SendNameCheckRequest_858c00` | a name check | the delete/restore confirm sender (0x7007 action 3 or 5) |
| round 678 (`intro_script.md`) | slot k at k/5 of the dock line; Start zooms to the slot | k/5 holds only for a full page. The zoom happens when a character is **clicked**, not on Start. |
| `character.MaxPerAccount = 3` | 3 characters | Retail allows 4 (READ, client and server). |

## 1. The flow

```
CPSTitle --login--> CPSCharacterSelect (list) --Create--> [same process] race select
   ^                    |  ^                                   | idol click
   |                    |  +----- Cancel / create OK ----------+--> CPSCharacterCreateChina  (98/168)
   +------- Back -------+                                      +--> CPSCharacterCreateEurope (105/79)
                        +--Start (0x7001 -> 0xB001 ok)--> CPSMission (loading, world)
```

| Screen | Process class | Region | Camera | Animated | Music |
|---|---|---|---|---|---|
| Select (list) | `CPSCharacterSelect` (OnCreate 0x85eb10, per frame 0x85ce30) | 0x6951 = 105/81, Constantinople harbour | key path (below) | characters' idles / sit | none pushed (READ). INFERRED: the title's IntroBGM keeps playing. |
| Race select | the same process | the same | 4-key fly to the table | lizard (clip 1) | the same |
| Create China | `CPSCharacterCreateChina` (0x84fbc0, per frame 0x850500) | 0x62a8 = 98/168, Jangan palace forecourt | turning on the spot | preview model; calligraphy still | none pushed (READ; only `snd_error`) |
| Create Europe | `CPSCharacterCreateEurope` (0x853990, per frame 0x8542d0) | 0x694f = 105/79, Constantinople plaza | the same turn | preview model | none pushed |

- **Time of day (READ):** none of these screens calls `SWorld::vslot_020`, so the title's random
  hour carries over (round 678, INFERRED).
- **The select screen's black fade** (READ, window 21): from alpha 0x80 to 0 over 0.5 s on open.
  `FUN_00bbda70(1)` runs before the region is set; what it does is OPEN.
- **The create screens** fade in from black over 0.5 s, then windows 3 (title) and 5 (China's
  calligraphy) fade in over 0.5 s (READ).
- **Back** (select id 13): the black fade goes 0 -> 255 over 0.5 s while the camera dollies out over
  2 s, then the process switches to `CPSTitle`. A failed network check, or closing the window, goes to
  `CPSQuit` (READ).
- **Create success:** fade to black over 0.5 s, then `CPSCharacterSelect` (class object 0xeed914 via
  0x860800). It writes `*(gfx+0x28)+0xe8 = 0` on success and `0xa` on Cancel (READ). The select
  screen runs its list intro only when the previous-process id is 0 or 10. What re-entry from create
  looks like otherwise is OPEN.

## 2. Character select

### Placement and paging (READ, FUN_0085e900, FUN_0085def0)

- The list is sorted **descending by level, then EXP** (sort key `"%03d %020I64d"`). The highest
  level is slot 0.
- **4 characters a page**; pages = (n-1)/4 + 1. Prev/next arrows (layout ids 45/46) change page.
  Only the current page is drawn and pickable.
- The dock line runs from **(95, -27.6, 654) yaw 3.20** to **(29, -27.6, 644) yaw 3.35** (region-local).
  Position and yaw are interpolated together.
  - A full page puts slot k (1..4) at k/5 along the line.
  - A last page with r characters puts them at k/(r+1): one at the midpoint, two at thirds, three at
    quarters.
- **4 per account** (READ): Create is refused at 4 with "A maximum of 4 characters can be created per
  account." (0x85de50). The server refuses a fifth with 0x405. So there is only ever one page in
  practice. INFERRED: the paging is for other services.
- **Empty slots:** none are drawn. With no characters only Create and Back show.

### Poses and the scale byte (READ)

Action types: 0 stand, 0xd sit down, 0xe sit, 0xf stand up.

| State | Pose | Opacity |
|---|---|---|
| normal | standing idle | full |
| pending deletion | SIT | 0xcc (80 %) |
| just deleted | SIT_DOWN, then seated | 0xcc |
| just restored | STAND_UP, then standing | full |

There is no other "selected" motion.

**The scale byte** (FUN_00a5b960; the create screen writes the same byte, section 4):
- The **low nibble** is Height, 0..4 (higher becomes 0). It scales the whole model uniformly by
  **{0.94, 0.97, 1.00, 1.03, 1.06}** (table 0xec64b0).
- The **high nibble** is Volume, 0..4 (READ: higher than 7 becomes 0, then clamped to 4; 2 is
  neutral). It scales bone groups:
  - for v < 2: `min + (1 - min) * v / 2`; for v >= 2: `1 + (max - 1) * (v - 2) / 2` (0xa5b7e0);
  - so at 2 every group is 1.0.
- Two {group, min, max} tables, chosen by the model's vslot 0x34 (INFERRED: the sex):

| Table | Groups |
|---|---|
| 0xec64c8 | (2, .88, 1.10) (3, .95, 1.11) (8, .92, 1.20) (19, .92, 1.20) (29, .90, 1.15) (33, .90, 1.15) (1, .90, 1.00) |
| 0xec6528 | (2, .95, 1.10) (3, .95, 1.00) (8, .95, 1.15) (19, .95, 1.15) (29, .90, 1.15) (33, .90, 1.15) (1, .90, 1.08) (37, .80, 1.18) |

- **OPEN:** what the group numbers index (bone indices of the .bsk? a named group table?). The world
  lane needs this to apply Volume; Height alone is fully READ.

### Picking and highlight (READ)

- Each frame the cursor is ray-picked against the current page's models.
- Hovering fades in that character's **name label** over 0.5 s; leaving fades it out.
  - The label is the name only, font 4.
  - It floats at the model's height factor x 20 above it (x 19 when the model flag is set).
- A left click selects. **There is no ring and no glow.**

### Camera (READ; pose = target, then pitch, yaw, roll, distance)

| When | Keys | Duration |
|---|---|---|
| List intro | (60, -15, 700) -> (60, -15, 660), both pitch 0.1, yaw 3.0, roll 0, distance 30 | 2.0 s |
| Character clicked (FUN_0085b680) | target (slotX + 2, Y, slotZ + 2); pitch 0, yaw 0.3925 - slot yaw, roll 0, distance 8 | 2.0 s (1.0 s when re-selecting after a list refresh) |
| Deselect (Cancel, id 16) | back to (60, -15, 660) | 2.0 s |
| Back (id 13) | dolly out with the 0.5 s black fade | 2.0 s |

- **Y of the clicked target** (h is the model's height factor, INFERRED):
  - standing: h x 16 - 28.779 (h x 15 - 28.779 with the model flag);
  - seated (pending deletion): h x 9 - 29 (h x 8.5 - 30 with the flag).
- During the list intro the title fades in over 0.5 s and Create/Back appear. When the path ends
  the arrows are placed and the screen becomes interactive.
- The camera math (eye = target - (0,0,distance) x Rz Rx Ry) is round 678's, `intro_script.md`, and
  the path is the same Catmull-Rom `IntroCameraPath` already implements.

### The layout: `resinfo\pscharacterselect.txt` (MEASURED; rects in the 1600x1200 design space)

**Frame and titles**
- Windows 1/2: top and bottom bars, 1600x172 (`blackbar_up/down`, `_europe` variants).
- Window 3: "CHARACTER SELECT" title, `text-characterselect.ddj` at 47,110,368,36.
- Window 4: "REGION" title, `text-region.ddj` at 47,110,292,36.

**Buttons** (92x41, `button(_europe).ddj`): right-aligned in the bottom bar, in three columns (READ,
approximate):

| x | Buttons |
|---|---|
| W-313 | 14 Start |
| W-209 | 12 Create, 15 Delete, 25 Restore |
| W-105 | 13 Back ("Cancel"), 16 Cancel (deselect), 17 Cancel (race select) |

**Panels**
- 18: the character info panel, 228x140 (`info(_europe).ddj`).
- 26: the deletion countdown, 328x92.
- 20: the delete-confirm popup, 344x192.
- 9 China, 10 Islam, 11 Europe: the idol tooltip panels, 440x152. Islam is never loaded.
- 500: the message line (all status and error text).
- Out of scope: 22-28 loading windows; 47-51, 900, 920, 940 the unity-server rename; 501.

**The info panel** (READ, FUN_0085b680):
- 31 Name.
- 32 HP gauge = HP / (Str x 10).
- 33 MP gauge = MP / (Int x 10). Both READ (0x85a7d0..0x85a834); the client approximates the maximum
  from the stat.
- 34 EXP: `"%.2f%%"` of EXP x 100 / leveldata's EXP for that level, capped at 99.99.
- 35 Stat points (label "Stat").
- 36 Level.
- **No job, Hwan, guild or gold field**: the list record carries none of them.

### Deletion and restore (READ)

**Delete button refusals** (0x858b40). Each shows a message and opens no confirm:

| Who | Message key | Text |
|---|---|---|
| guild member | `..._CONFIRM_MEMBER` | says you will leave the guild, yet the code refuses |
| guild master | `..._CONFIRM_MASTER` | |
| academy student | `..._CONFIRM_STUDENT` | "...first leave the Academy" |
| academy guardian | `..._CONFIRM_GUARDIAN` | "...first disband the Academy" |

**The confirm popup (window 20)**
- Fades in over 0.5 s, dims the screen to alpha 0x80, plays `snd_window_open`.
- Text `UIO_STT_CHAR_DEL_CONFIRM`: "...it will be reserved for 7 days... after 7 days, it will be
  permenantly deleted. Do you really want to delete the character?" Button "Delete".
- For a pending character: `UIO_STT_CHAR_RECOVERY_CONFIRM` and "Restore".
- Accept (0x858c00) sends 0x7007 action 3 (delete) or 5 (restore) with the name.

**A pending character, selected**
- Start and Delete hide; Restore (25) and the countdown (26) show.
- The message line reads `UIO_STT_CHAR_DEL_WAITING`: "The character's deletion is reserved. To
  restore it, click 'Restore'...".
- **The countdown:** the list carries the **minutes remaining** (u32). The client subtracts one per
  60 s of its own clock.
  - Text `UIO_MSG_CHAR_DEL_TIME`: "Complete deletion of the selected character in %d days %d hours %d
    minuites left."
  - The gauge is 1 - remaining / **10080** (7 days in minutes). The header reads "Character deletion
    is being processed ...".
- **Server side** (READ ShardManager): delete runs `_DeleteCharTemporal(JID, CharID)` and replies
  at once. Removal is later, by `_DeleteCharPermanently(CharID)`. Restore runs `_ReviveChar(CharID)`.
  - The remaining minutes = (stored date - now) seconds / 60, at least 1.
  - **The delay itself is in the procedure, OPEN.** The client's text and gauge both say 7 days
    (READ), so 7 days is what the client expects.

### Equipment on the select models (READ, FUN_0085a580)

- Each of the up to 9 equipped items in the list record is resolved to a visual slot and installed
  with its plus value, the weapon included.
- Avatar items (type 3/1/13) are installed too.
- INFERRED: plus drives the weapon glow, as in the world.

### Start (READ, 0x858770)

- Sends **0x7001**: u16 length + ASCII name, no action byte. Before sending it stores a global from
  the character's data +0x9c (0 or 1; INFERRED: the race).
- The reply **0xB001**: u8 result. 1 switches to `CPSMission` (loading, then the world); anything
  else is a u16 error shown through the table in section 5.
- The server (READ ShardManager FUN_0040e2c0) refuses:
  - an empty name: 0x402;
  - no user: 0x407;
  - a forbidden word or quote: 0x402;
  - not on the account: 0x40b;
  - **a character pending deletion: 0x402**;
  - a pending operation: 0x40e.
- On OK the server hands the player to the game server (internal 0x7802). INFERRED: 0xB001 [1] is
  sent once the game server accepts (SR_GameServer `CMainProcess::EnterGame`, payload_layouts.tsv:298).
  Then 0x3013 character data (client FUN_008a8c00), 0x34a5, 0x34a6.

## 3. Race select (the same process; READ)

**The scene** (region 105/81, region-local):

| Object | Position | Yaw |
|---|---|---|
| `res\interface\box.bsr` (box, compass, brush case, letter, parchment map) | (155, -20, 652) | 3.0 |
| `interface_idol_europe.bsr` | (157, -20, 654.4) | 3.31 |
| `interface_idol_china.bsr` | (156.2, -20, 651.6) | 3.03 |
| `interface_lizard.bsr` | (155.6, -20, 651.6) | 3.0 |

- `interface_idol_islam.bsr` and `interface_sparrow.bsr` exist in Data.pk2 but the exe never names
  them (MEASURED).
- **The "white horse"** in fe_ref2 is the Europe idol itself: one mesh, `interface_idol_europe.bms`,
  with its own bump map (MEASURED; INFERRED that it is the horse, not rendered). The dark lion is the
  China idol. This closes round 678's "no horse mesh" OPEN.

**Pressing Create**
- "CHARACTER SELECT" fades out and "REGION" fades in over 5.0 s. Create, Back and the arrows fade
  out over 0.5 s; Cancel 17 fades in.
- The camera flies 4 keys at t = 0, 1.667, 3.333, 5.0 s, all at distance 30:

| t | Target | Pitch | Yaw |
|---|---|---|---|
| 0 | (60, -15, 660) | 0.1 | 3.0 |
| 1.667 | (100, 0, 625) | -0.1 | 2.2 |
| 3.333 | (150, -10, 642) | -0.01 | 1.8 |
| 5.0 | (165.2, -33.9, 640.3) | 0.62 | 2.53 |

**On arrival**
- The two idol panels are placed above their idols on screen and shown.
- **The lizard** is shown only now (never in the list view) and switches from clip index 0 to 1.
  - Its clips, in .bsr order, are `interface_lizard_stand`, `_move`, `_run` (MEASURED); index 1 is
    `_move` (INFERRED).
  - The code never moves it. Whether `_move` carries root motion is OPEN.

**Hover:** each idol is ray-picked. The hovered idol's panel fades in over 1/3 s and the other's
fades out at the same rate. No glow, no idol animation.

**Tooltips** (in the select layout, not `ifregionview.txt`):
- Europe (window 11): title "European", body `UIO_NEWCHAR_CTL_EUROPEAN_TT` ("...classified into 6
  classes: Warrior, Lord, Wizard, Warlock, Bard, Cleric...").
- China (window 9): title "Chinese", body `UIO_NEWCHAR_CTL_CHINESE_TT` ("...mysterious energy of the
  martial Force... Sword, Blade, Spear, Glaive, and Bow...").

**Click**
- Anything but an idol gives "Out of service area." (key `UIO_MSG_ERROR_ REGION_SUPPORT`, with the
  stray space).
- On an idol: fade to black over 1.0 s, the panels fade out over 0.5 s, and the camera moves over
  1.0 s at the same rotation and distance 30 to:
  - Europe (168.5, -34.9, 639.1), then `CPSCharacterCreateEurope`;
  - China (165.8, -35.1, 636.7), then `CPSCharacterCreateChina`.
- The race picked is stored in `DAT_00ec2d68` (copied at 0x85ca47), which the create screen reads.

**Cancel (17):** the titles swap back, Create and Back return, the panels hide, the camera returns,
the lizard hides. `FUN_0085cbc0` (fly back from an idol) has no references: dead code.

## 4. Character create / customize (READ unless marked)

### State (`CCustomInfoManager` at this+0x11c; ctor 0x80bd00, loader 0x80b980)

| Offset | Holds |
|---|---|
| +0x124 | sex: 0 female, 1 male |
| +0x128 .. +0x13c | the chosen ids for slots 0..5: model, chest, legs, feet, weapon, shield |
| +0x140 .. +0x154 | the matching 1-based slider indices |
| +0x218 | the scale byte |
| this+0x21c | the preview window, a `CIFCharacterWnd` |

### The controls (`pscharactercreatechina.txt` / `pscharactercreate_europe.txt`; the ids are the same in both)

| ID | Control | Art / English text | Handler China / Europe |
|---|---|---|---|
| 41 | name edit, max 12 characters | | |
| 42 | name check | `overlap.ddj`, "Name Check" | 0x84ed90 / 0x852830 |
| 43 / 44 | Male / Female | `man_on` / `woman_off.ddj` | 0x84f630, 0x84f540 / 0x8530e0, 0x852ff0 |
| 45 | Figure | | 0x84de60 / 0x851a50 |
| 46 | Height | | 0x84d040 / 0x850bc0 |
| 47 | Volume | label "Weight" | 0x84d070 / 0x850bf0 |
| 48 | Protector | label "Cloth" | 0x84de90 / 0x8531e0 |
| 49 | Weapon | | 0x84dee0 / 0x853400 |
| 21 / 23 / 22 | rotate left / zoom / rotate right | `rotate_left`, `zoomin`, `rotate_right.ddj` | 0x84cfb0, 0x84fa90, 0x84cfd0 / 0x850b30, 0x853850, 0x850b50 |
| 10 / 11 | OK / Cancel | "Confirm" / "Cancel" | 0x84ed50, 0x84d300 / 0x8527e0, 0x850de0 |
| 13 | confirm box | `warning_create.ddj`, "Create a new character?", Create 32 / Cancel 33 | |
| 61 / 62 | tooltip title / text | | 0x84d470 / 0x850f50 |
| 5 | `GDR_STA_BACKIMAGE` | `back_image.ddj` (China only) | |

- Message maps: 0xec2770 (China), 0xec2a80 (Europe).
- **The middle button is zoom, not reset.** It toggles and swaps its art between `zoomin` and
  `zoomout` (0x84fa90). fe_ref3's "reset" reading of that button was wrong.
- **Slider order** (the same ids; only the y positions differ):
  - China: Figure, Height, Volume, **Protector, Weapon**.
  - Europe: Figure, Height, Volume, **Weapon, Protector**.

**Placement** (READ, screen pixels; "mid" is halfway between the two bands):

| Window | Position |
|---|---|
| OK | (W-209, bottom band top + 27) |
| Cancel | (W-105, bottom band top + 27) |
| customize panel | (75, mid - 155) |
| rotate buttons | (W-165, bottom band top - 69) |
| tooltip | (rotate.x - 59, rotate.y - 219) |
| confirm box | centred |

### Name

- **Client checks** (READ):
  - 0x84eac0: length 2..12, else `UIO_MSG_ERROR_CHARACTER_NAME_STRING` ("A minimum of 2 ... up to 12
    English alphanumerals").
  - 0x8c3cb0: a forbidden-character bitmap and two filter lists, else
    `UIO_MSG_ERROR_CHARACTER_WRONGSTRING` ("An invalid symbol, character, or letter has been used!").
  - **Which characters the bitmap allows is OPEN.** The message says English alphanumerals.
- **Server checks** (READ ShardManager FUN_0040f300 / FUN_0040f200 / FUN_00527390; the same for
  action 4 and for create):
  - 2..12 bytes by `lstrlenA`, else 0x40c;
  - 0x40d if it contains a space, `'` or `"`, a word from the loaded forbidden-word list, or fails a
    further filter (FUN_006df4c0, not read);
  - 0x410 if `_IsExistingCharName` finds it.
- **The name check button** sends 0x7007 action 4. On success it shows "This character name is valid
  and usable. You may proceed!" (`UIO_MSG_ERROR_ADMISSON`).

### Sex and Figure

- Sex switches between the male and female lists. A figure change reloads the model, re-applies the
  armour and weapon by their stored indices for the new sex, and re-applies the scale.
- **How the choices are listed** (READ, 0x80b980):
  - The screen walks a global list of object ids at 0xeedf08: +0x2b0 when `DAT_00ec2d68 == 0`, +0x288
    otherwise (the race from race select).
  - Each id is sorted by type: a character to slot 0, chest/legs/feet to 1..3, a weapon to 4, a
    shield to 5.
  - Each goes into the male or female list (or both) by the item's ReqGender: refobj +0x1c4, itemdata
    column 59, 0 female, 1 male, 2 both.
- **OPEN: where that global list is loaded from.** It is not a hard-coded table and no textdata file
  the exe names holds it.
  - MEASURED: the archive ids that fit the rule number **104** (26 China and 26 Europe characters, 24
    China and 28 Europe items).
  - EXTERNAL: the shard DB's `_RefCharGen` has exactly 104 rows and 2 columns, and ShardManager loads
    it ("There is no Refobj like this or Service is 0 (ObjID : %d)").
  - INFERRED: `_RefCharGen` is the list, and it reaches the client by a path not yet found (an
    opcode? a file the patcher writes?). Closing this needs the table exported (section 6).
- **The Figure slider runs 1..13 and starts at 1** (READ). The ids (MEASURED, characterdata; EXTERNAL
  `_RefObjCommon` agrees, all Service = 1):

| Race / sex | Ids | Codes (`CHAR_<race>_<sex>_*`), in id order |
|---|---|---|
| China man | 1907-1919 | ADVENTURER, BOGY, FIGHTER, MERCHANT, MONK, MONKEY, NECROMANCER, NOBLEBOY, PERFORMER, PRIEST, SCHOLAR, TATTOO, WARRIOR |
| China woman | 1920-1932 | ADVENTURER, ASSASSIN, BOGY, FIGHTER, FOX, KANGSI, KISAENG, MERCHANT, NECROMENCERB, NECROMENCERW, NOBLEGIRL, SCHOLAR, WARRIOR |
| Europe man | 14875-14887 | NOBLE, EXORCIST, NECROMENCER, MERCHANT, PRIEST, KNIGHT, WARRIOR, GLADIATOR, BARBARIAN, ADVENTURER, ANGEL, DEVIL, WEREWOLF |
| Europe woman | 14888-14900 | NOBLE, WITCH, SUMMONER, MERCHANT, ORACLE, CRUSADER, AMAZONESS, KNIGHT, ADVENTURER, GLADIATOR, ANGEL, DEVIL, SUCCUBUS |

- The bodies are `Res\Char\China\china(wo)man_*.bsr` and `Res\Char\Europe\europe(wo)man_*.bsr`
  (MEASURED).
- China rows 1908-1932 appear in two characterdata files (MEASURED); a reader must take each id once.
- **Order:** the tooltip order (`UIO_NEWCHAR_[EU_](MAN|FEMALE)_<n>` and `_EXPLANATION`) follows the
  ids, except Europe women 12/13, which the tooltips name SUCCUBUS then DEVIL. Which of the two is out
  of order in retail is OPEN. **OURS until settled:** id order, with the tooltip taken by the code
  name, not the index.

### Height and Volume

- Both sliders run **0..4, step 1, start at 2** (READ).
- **scale = (volume << 4) | height**, default **0x22** (READ: Height writes the low nibble, 0x84d040;
  Volume the high nibble, 0x84d070).
- The preview applies them as section 2's scale byte (the same function).
- Tooltips: Height "one of 5 levels", Volume "one of 5 types".

### Weapon and Protector (ids MEASURED from itemdata `_A_DEF` rows; order READ from the tooltips)

**China** (no weapon/armour restriction):

| Index | Weapon | Id |
|---|---|---|
| 1 | Copper Sword | 3632 |
| 2 | Copper Blade | 3633 |
| 3 | Crescent (spear) | 3634 |
| 4 | Glaive | 3635 |
| 5 | Copper Bow | 3636 |

- The Weapon slider runs 0..5. 0 is "none" (tooltip `_ARMY_SELECT`), and Confirm refuses it.
- Protector index i sets chest, legs and feet together:

| Index | Set | Man (chest / legs / feet) | Woman |
|---|---|---|---|
| 1 | Heavy (Copper Armor / Hose / Footgear) | 3637 / 3638 / 3639 | 3646 / 3647 / 3648 |
| 2 | Light (Cloth Lamellar / Tasset / Boots) | 3640 / 3641 / 3642 | 3649 / 3650 / 3651 |
| 3 | Clothes (Cotton Suit / Trousers / Shoes) | 3643 / 3644 / 3645 | 3652 / 3653 / 3654 |

- **The Protector minimum is 0 or 1 by a per-server flag** (READ: 0x8688f0 sets `CGame+0x129` to the
  inverse of a byte from the selected shard's entry). INFERRED: that is `server_list.md`'s "flag
  byte at +0x28". Its meaning is OPEN.

**Europe**

| Weapon | Id | Protector sets allowed (READ, 0x853400 / 0x8531e0) |
|---|---|---|
| Dagger (Sagittarius Dirk) | 10887 | light |
| 1H Sword (Long Sword) | 10888 | heavy, light |
| 2H Sword (War Sword) | 10889 | heavy, light |
| Dual Axe (Small Axe) | 10890 | heavy, light |
| Crossbow | 10891 | light |
| Warlock Rod (Short Staff, Warlock) | 10892 | robe |
| Staff (Long Staff) | 10893 | robe |
| Harp (TetraCalled) | 10894 | robe |
| Cleric Rod (Short Staff) | 10895 | light, robe |

| Set | Man (chest / legs / feet) | Woman |
|---|---|---|
| Heavy (Lorica Armor / Poleyn / Greave) | 11617 / 11618 / 11619 | 11626 / 11627 / 11628 |
| Light (Savage Mail / Tasset / Boots) | 11620 / 11621 / 11622 | 11629 / 11630 / 11631 |
| Robe (Cotton Robe / Under Robe / Weave) | 11623 / 11624 / 11625 | 11632 / 11633 / 11634 |

- The weapon slider order is the table's order as the tooltips give it (READ).
- Changing the weapon resets Protector to 0. With no weapon the Protector slider is dimmed.
- Confirm checks the chest first ("You must select a valid set type to proceed.",
  `UIO_MSG_ERROR_CHARACTER_SELECTARMOR`), then the weapon.

**Shields** (China 10886 Copper Shield, Europe 10896 Sagittarius Copper Shield) are slot 5.
- The preview fits the shield next to a weapon whose refitem +0x250 == 0 (INFERRED: one-handed).
- **The shield is not in the create packet**; the server adds it (section 5).

**The weapon tooltips' English explanations are empty** in this archive (MEASURED). fe_ref3/4's
"You can choose the type of weapon for your character." is the slider's own tooltip,
`_ARMY_SELECT`.

### Confirm

- China: a weapon id of 0 shows "You must select a valid weapon type to proceed."
  (`UIO_MSG_ERROR_CHARACTER_SELECTWEAPON`) and plays `snd_error`.
- Then the name checks. If they pass, box 13 fades in over 0.5 s showing the name, and the screen
  dims to 128.
- Create (32) fades the box out, and the packet is sent when that fade ends (0x84e610 / 0x8520a0).

### The preview (`CIFCharacterWnd`)

**Rotation** (READ):
- Each rotate button adds -50 or +50 to a spin velocity v.
- Each frame: `d = dt * v * 0.5`; the angle advances by `(2v - d) * dt * 0.5`; `v -= d`; v snaps to 0
  below 30.
- yaw (radians) = `angle / 180 * 3.14` (the constant is 3.14, not pi).
- Worked out from the formulas, not measured: one click turns about 40 degrees, easing out over about
  1 s, and clicks stack.
- **No mouse-drag rotation** was found (INFERRED: none).

**The model and camera** (READ):
- The model stands at (3.0, 0.5, 0), yaw 0. Pitch is always 0.2. Zoom tweens over 1.0 s.

| Zoom | Target | Distance |
|---|---|---|
| out (start) | (0.5, 9.8, 0) | 28.5 |
| in | (2.0, height factor x 15 for men / x 14 for women, 0) | 11.0 |

- Which animation the preview plays is OPEN.

**The backdrop:**
- Each frame the world camera has pitch 0, roll 0, distance 0.1 and yaw = `clock / 30000.0 +
  0.390955` (READ). INFERRED: clock in ms, so about 1.9 degrees a second, a full turn in about 188 s.
- China: target (960.4189, 50, 458.2598) in 98/168, with `vslot_038` at (920, 0, 920).
- Europe: target (335, 140, 1460) in 105/79.

**The China calligraphy** is window 5, `interface\outer\back_image.ddj`, a 408x556 still of cursive
calligraphy with alpha (MEASURED, decoded and deleted). It fades in once and nothing moves it (READ;
INFERRED: it does not drift). Europe's window 5 has no art. This closes round 678's OPEN.

## 5. The protocol (retail)

Framing, the security bytes and the opcode header are `opcodes/handshake.md` and `PACKET_FORMAT.md`.
Names are u16 length + narrow (ASCII) bytes.

**Who handles it** (READ): `SR_ShardManager.exe` registers 0x7001 -> 0x40e2c0 and 0x7007 -> 0x40f010
(0x40d248..0x40d2b3) and builds 0xB007 and 0xB001.
- INFERRED: AgentServer only relays; its code has no 0x7007/0xB007/0x7001/0xB001 constant.
- INFERRED: the relay puts a u32 (the session) in front; both ShardManager handlers read one before
  the client's fields. The client never sends it.
- SR_GameServer has no dispatch entry for 0x7007 (RE_COMPLETION 2026-09-18).

### 0x7007 (client -> server): u8 action, then

| Action | Name | Payload after the action | Client sender | Server handler |
|---|---|---|---|---|
| 1 | create | name, **u32 model RefObjID, u8 scale, u32 chest, u32 legs, u32 feet, u32 weapon** | 0x84e610 (writer 0x84e2e0), 0x8520a0 | 0x40f3e0 (parser 0x41a470) |
| 2 | list | nothing | select OnCreate, 0x8560e0, `CPSQuickStart` | 0x40f110 |
| 3 | delete | name | 0x858c00 | 0x40f8e0 |
| 4 | name check | name | 0x84ed90, 0x852830 (and the unity rename, 0x857b40) | 0x40fbc0 |
| 5 | restore | name | 0x858c00 | 0x40fd00 |

Any other action is ignored (jump table 0x40f0f8).

### 0xB007 (server -> client): u8 action, u8 result

- result 1 = OK; result 2 = a **u16** error code follows (READ, the client's 0x84df10 / select
  vslot_006 and the server's FUN_0040ef80).
- **The exception is restore's asynchronous error, `[5][2][u8 code]`** (READ server). The client
  reads a u16 there (READ client), so the two disagree. OPEN which is right; send the u16 (OURS).

| Action | OK payload | Client then |
|---|---|---|
| 1 create | none | fades out, returns to select |
| 2 list | the list (below) | builds the page |
| 3 delete | none | re-requests the list |
| 4 name check | none | shows `UIO_MSG_ERROR_ADMISSON` |
| 5 restore | none | re-requests the list |
| 6 | a string (OPEN) | rebuilds the list, deselects |

**The list (action 2 OK)** (READ: server asm, and the client's `SCharacterInfo` reader 0x85e620):

```
u8  count
per character:
  u32 RefObjID
  str Name
  u8  Scale                    (height low nibble, volume high nibble)
  u8  CurLevel
  u64 ExpOffset
  u16 Strength
  u16 Intellect
  u16 RemainStatPoint
  u32 HP
  u32 MP
  u8  IsDeleting
  [u32 minutes remaining]      only when IsDeleting
  u8  GuildMemberClass         0/1/2
  u8  guild rename flag
  [str guild name]             only when the flag is set
  u8  AcademyMemberClass       0/1/2 (exact meaning OPEN)
  u8  itemCount  (<= 9)        per item: u32 RefItemID, u8 plus
  u8  avatarCount (<= 5)       per avatar: u32 RefItemID, u8 (discarded)
```

- Column names are INFERRED from the struct offsets lining up with `_CHAR`'s bind order
  (`db_bind_columns.tsv`).
- A name or guild name containing `@` marks the unity-server rename case (out of scope).

### Error codes (READ codes; meanings from where each is raised and the message shown)

| Code | Server raises it for | Client shows |
|---|---|---|
| 0x401 | OK | nothing |
| 0x402 | refused / generic (start on a pending character, delete guild check, restore worker) | "Failed to connect to server." (S) |
| 0x403 | bad model or items (create) | `INVALID_CHARGEN_INFO` "Failed to create a character..." (S) |
| 0x404 | no weapon | `CHARACTER_SELECTWEAPON` |
| 0x405 | account full (4) | `CHARACTER_OVER_3` "A maximum of %d characters..." |
| 0x406 | `_AddNewChar` failed | `FAILED_TO_CREATE_CHARACTER` (S) |
| 0x407 | no user / bad session | "Failed to connect to server." (S) |
| 0x408 | delete: name refused | "Failed to connect to server." (S) |
| 0x409 | | `CANT_FIND_GAMESERVER` (S) |
| 0x40a | | "Failed to connect to server." (S) |
| 0x40b | no character of that name on the account | "Failed to connect to server." (S) |
| 0x40c | name length | `CHARACTER_NAME_STRING` |
| 0x40d | name invalid | `NOT_ALLOWED_CHARNAME` |
| 0x40e | an operation is pending | "Failed to connect to server." (S) |
| 0x40f | | `CANT_ACCESS_PARENT_SERVER` (S) |
| 0x410 | name exists | `ERROR_ID` "This character name already exists in the server!" |
| 0x411 | | `ERROR_OVERLAP` (account connected) |
| 0x412 | | `FAILED_TO_CREATE_NEW_USER` (S) |
| 0x413, 0x416-0x418 | | "Failed to connect to server." (S) |
| 0x414 | | `MAX_USER_EXCEEDED` |
| 0x415 | | `FAILED_TO_ENTERLOBBY` (S) |
| 0x419 | restore: nothing to restore | (restore's u8 path, see above) |

"(S)" means the client appends "(S<decimal code>)". The decode is through the byte index table at
0x861b84 (select) and 0x861a40 (create).

### Create on the server (READ ShardManager)

**Checks, in order:**
1. The user exists (else 0x407) and nothing is pending (else 0x40e).
2. The account has fewer than 4 characters (else 0x405).
3. FUN_0048d8d0 (else 0x403):
   - the model is a player character (TypeID1 = 1, TypeID2 = 1);
   - each non-zero item exists and is equipment;
   - its Country equals the character's, or is 3;
   - its ReqGender equals the character's sex, or is 2.
4. The weapon is non-zero (else 0x404).
5. The name rules above.

**No whitelist** of default items is checked in this code. The procedure may enforce one (OPEN).

**What runs** (FUN_00429c80):
- Internal 0x620e (shard id, JID, name) goes to the manager.
- Then `_AddNewChar`, synchronously; a failure gives 0x406.
- **It adds** (READ):
  - the three armour pieces must share one armour class;
  - each item gets a durability byte from its refobj;
  - a bow gets `ITEM_ETC_AMMO_ARROW_01_DEF`, a crossbow `ITEM_ETC_AMMO_BOLT_01_DEF`;
  - otherwise a one-handed weapon gets the race's shield, `ITEM_CH_SHIELD_01_A_DEF` or
    `ITEM_EU_SHIELD_01_A_DEF`.

**The start position** (FUN_0042bb20): `rand() % 3` picks one of three spawns per race (table
0x781b88), and the return point is the race's `STORE_CH_GATE` / `STORE_EU_GATE` refobj.

| Race | Spawns (region hi/lo, local x, y, z) |
|---|---|
| China | 98/168 (960, 20, 420); 98/168 (958, 60, 1087); 97/168 (951, 20, 170) |
| Europe | 107/79 (1205, 80, 396); 105/77 (1466, 79, 1488), listed twice |

**`_AddNewChar`'s 20 parameters** (format string 0x783880, called at 0x42a238; order READ from the
pushes):
1. JID
2. RefObjID
3. Name
4. Scale
5. start Region (u16)
6-8. PosX, PosY, PosZ
9. the gate refobj id (INFERRED: the return point)
10-13. chest, legs, feet, weapon
14. shield id
15-18. the four items' durability
19. the shield's durability
20. ammo id

**The other lobby procedures:** `_DeleteCharTemporal(JID, CharID)`, `_DeleteCharPermanently(CharID)`,
`_ReviveChar(CharID)`, `_IsExistingCharName('%s')`. Also present: `_RenameCharNameByID`,
`_ForceDeleteCharacter`, `_KeepDelCharName`, `_QueryUserCharBy*`, `_GETCHARIDBYNAME`.

**Default skills and quests** come from `_RefCharDefault_Skill` (13 rows), `_RefCharDefault_
SkillMastery` (13) and `_RefCharDefault_Quest` (15) (EXTERNAL counts). INFERRED: applied in
`_AddNewChar`.

### What we have, and what is missing

Our wire today is our own (`PROTOCOL_DECISION.md`).

| Retail | Ours today | Gap |
|---|---|---|
| 0x7007 action 2 / 0xB007 list | `OpCharacterList` 0x0010 -> 0x0011: error string, u16 count, per character name, gender string, u16 level, u16 HP, u16 MaxHP | no RefObjID, scale, EXP, Str/Int, stat points, MP, deletion state, guild/academy, equipment |
| action 1 create | 0x0012: name, gender string -> 0x0013 ok + reason string | no model, scale or items. The kit is `equipment.StartingKitFor` (Cotton + Copper Sword). No race, no shield/ammo rule, no Country/ReqGender check, no armour-class check, no weapon check. |
| action 4 name check | none | missing |
| action 3 delete | 0x0014 -> 0x0015, **hard** `DELETE` | no 7-day soft delete, no guild/academy refusal |
| action 5 restore | none | missing |
| error codes | free-text reasons | no codes; the client cannot show retail's messages |
| 0x7001 / 0xB001 | `OpEnterWorld` 0x0020 (name) -> 0x0021 (ok, zone, position, **gender**, HP, others, frame region) | a pending-deletion character must be refused; the body must come from RefObjID + scale |
| name rules | none in session; uniqueness by the DB constraint | 2..12, the forbidden characters and words |
| account limit | `character.MaxPerAccount = 3` | retail 4 |
| `_CHAR.RefObjID`, `Scale`, `Deleted` | `EngineOnlyColumns` (`character/schema.go`): not modelled; `Gender` stands in | add them |
| start position | the fixed Jangan `spawnPos` | the READ per-race spawns |

**Client side today:**
- `CharacterSelect.gd`: a 2D list over `loading_constantinople.ddj`, a stat panel (name, level, HP),
  and Start/Create/Delete/Cancel.
- `CharacterCreate.gd`: name plus Man/Woman, with `CharacterPreview` (`ui/character_preview.gd`)
  wearing `StartingKitFor`'s ids.
- `NetClient`: `list_characters`, `create_character(name, gender)`, `delete_character`,
  `enter_world`.
- The world: bodies are chosen by a gender string. `World3D.GENDER_BODY_CODE` maps `china_man` to
  `CHAR_CH_MAN_FIGHTER` (1909) and `china_woman` to `CHAR_CH_WOMAN_FIGHTER` (1923).
  `EntitySnapshot.Gender` carries the same for other players.

## 6. Data and where it comes from

| Need | Source | State |
|---|---|---|
| Figure ids, codes, bodies | `Media.pk2 server_dep\silkroad\textdata\characterdata_*.txt` (via `characterdata.txt`) -> `Res\Char\{China,Europe}\*.bsr` in Data.pk2 | MEASURED: 52 ids (section 4) |
| Weapon / armour / shield ids | `itemdata_*.txt` rows whose code ends `_A_DEF`, plus ReqGender (col 59) and Country | MEASURED: 24 China + 28 Europe |
| The list of creatable ids (`_RefCharGen`) | shard DB (EXTERNAL), 104 rows x 2 columns, **not exported** | the MEASURED rule reproduces 104 ids. Export it to confirm. |
| Item and character names | `textdata_equip&skill.txt` (`SN_ITEM_*`), `textdata_object.txt` | MEASURED |
| UI text (buttons, tooltips, errors, deletion) | `textuisystem` keys named above | READ keys, MEASURED English |
| Layouts and art | `resinfo\pscharacterselect.txt`, `pscharactercreatechina.txt`, `pscharactercreate_europe.txt`; `interface\...` ddj | MEASURED |
| Race-select meshes | `Res\interface\box.bsr`, `interface_idol_europe/china.bsr`, `interface_lizard.bsr` | MEASURED |
| EXP % on the panel | `leveldata.txt` (already imported, `internal/leveldata`) | READ |
| Deletion delay | `_DeleteCharTemporal` body | OPEN; the client says 7 days |
| Default skills / masteries / quests | `_RefCharDefault_*` (EXTERNAL, not exported) | OPEN |
| Start spawns, gate | ShardManager table 0x781b88 (READ, this package) | READ |
| Music | none pushed by select or create | READ; the intro's track carries over |

**To close the EXTERNAL OPENs** (one session, nothing enters the repo):
1. `pct start 104` (the stopped `mssql-temp`, deploy/README.md "External shard DB").
2. Export `_RefCharGen`, `_RefCharDefault_Skill`, `_RefCharDefault_SkillMastery` and
   `_RefCharDefault_Quest` to `/opt/sro-files/db/csv/`.
3. Read `SELECT OBJECT_DEFINITION(OBJECT_ID('<proc>'))` for `_AddNewChar`, `_DeleteCharTemporal`,
   `_DeleteCharPermanently`, `_ReviveChar` and `_IsExistingCharName`.
4. `pct stop 104`.

Starting a container is the user's call; this reading did not.

## 7. The implementation, in rounds

Four lanes after one shared contract round. None edits another lane's files. The contract is the
packet fields and three small client classes.

### Round 0 (server/protocol lane, first, small): the contract

**The wire.** Payloads **byte-for-byte the retail layouts of section 5**, so that they move unchanged
into the retail codec `PROTOCOL_DECISION.md`'s addendum describes:
- 0x7007 (actions 1-5) / 0xB007;
- 0x7001 / 0xB001, whose OK continues into today's `OpEnterWorldResult` until the world handoff is
  retail too.

Which opcode numbers carry them on our current framing is **USER DECISION 1**.

**Errors** are retail's u16 codes. The client maps them to retail's text keys from the archive. Our
free-text reasons go.

**Codec and catalogue:**
- Both codecs and their golden-byte tests: `server/internal/session/lobby.go` and
  `client/scripts/net/lobby.gd`, held to the same bytes as round 681 did.
- The catalogue: `server/internal/refdata` (`CreatableSet`: the 104 ids by the MEASURED rule from
  characterdata + itemdata) and its client twin `client/scripts/frontend/char_catalog.gd`. The same
  rule is applied to the player's own archive; nothing is shipped.

**Tests:**
- encode/decode of every action, with golden bytes from this doc's layouts;
- the list with and without a deletion and a guild string;
- the catalogue rule on synthetic rows (sex 0/1/2, country, the `_A_DEF` suffix, duplicate rows).

### Lane S, server (rounds S1-S3)

**Files:** `server/internal/session/character.go` (or the new `lobby.go`), `server/internal/
character/{character,sqlstore,memstore,schema}.go`, `server/internal/equipment/starterkit.go`,
`server/internal/session/world.go` (enter only), `server/cmd/server` wiring, migrations.

**S1 create**
- Columns `ref_obj_id`, `scale`, `deleted_at`. Migrate existing rows: `china_man` -> 1909,
  `china_woman` -> 1923, scale 0x22 (OURS: what the world draws today).
- `Gender` is derived from the model (kept for the world wire until lane W lands).
- The checks in section 5's order:
  - the account limit 4 (USER DECISION 2);
  - the model in the catalogue;
  - every item in the catalogue, matching Country and ReqGender;
  - the three armour pieces of one class;
  - the weapon non-zero;
  - the name rules.
- Add the shield or ammo as READ.
- The start spawn per race (READ, this package; USER DECISION 5).
- Replace `StartingKitFor` with the chosen items.

**S2 the list and name check**
- The full list record: EXP, Str/Int, stat points, HP, MP, the equipped items with plus, guild and
  academy class.
- Action 4.

**S3 delete and restore**
- Soft delete with `deleted_at + delay` (USER DECISION 3), and the refusals for guild and academy.
- Restore.
- A purge job that hard-deletes expired rows.
- Start refuses a pending character (0x402).
- Tests: a fake clock for the minutes remaining (at least 1), restore and purge.

### Lane A, client select (rounds A1-A3)

**Files:** `client/scripts/CharacterSelect.gd`, `scenes/CharacterSelect.tscn`, new
`client/scripts/frontend/charselect_*.gd`. It consumes `net/lobby.gd`'s signals and
`CharacterAppearance` (lane B's round B1). Until B1 lands it uses `CharacterPreview` by sex.

**A1:** the 105/81 backdrop (`FrontEndBackdrop`), the `pscharacterselect.txt` frame and buttons,
the list intro camera, the dock placement and paging, picking, the name label, the select zoom, the
info panel (EXP % from leveldata), Start.

**A2:** delete and restore: the refusals, popup 20, the sitting pose and 0xcc opacity, countdown 26
and its text, Restore.

**A3:** race select. It is part of this process in retail, so it lives in this lane:
- the table, idols and lizard;
- the 4-key camera, hover panels 9/11, the click fly and fade;
- emitting `race_chosen(race)` to open lane B's create scene.

**Tests:** headless math tests (placement k/(r+1) and k/5, the camera keys, the countdown text and
gauge, the sort order). `SRREVAMP_QA_FAKECHARS` is extended with model, scale, items and a pending
deletion. Renders on the box, batched in one `--shots` run. `perf_gate.sh` (it draws the world).

### Lane B, client customize (rounds B1-B3)

**Files:** `client/scripts/CharacterCreate.gd`, `scenes/CharacterCreate.tscn`, new
`client/scripts/frontend/charcreate_*.gd`, and **`client/scripts/ui/character_appearance.gd`** (new;
`CharacterPreview` becomes a thin user of it).

**B1: `CharacterAppearance`**
- `build(ref_obj_id, scale, items: Array[{id, plus}]) -> Node3D`: the body from characterdata, the
  items in their slots, Height's uniform scale (READ).
- Volume's bone groups wait on the group-number OPEN; until then they are 1.0, said in the code.
- Used by lanes A and W.

**B2:** the China and Europe screens from their layouts:
- name and the name check (action 4);
- sex, Figure 1..13, Height and Volume 0..4 (scale nibbles), Protector and Weapon with Europe's
  restrictions, the tooltips 61/62 by text key;
- Confirm, box 13, create (action 1), the error texts, return to select.

**B3:** the 3D backdrop (98/168 and 105/79, the turning camera), the preview window with READ
rotation physics and zoom, China's `back_image.ddj`.

**Tests:** the scale nibbles, the rotation integrator (one click ~40 degrees), the Europe weapon to
armour table, the slider-to-id mapping on synthetic catalogue rows, the name rule. Renders on the
box. `perf_gate.sh` for B3.

### Lane W, world (round W1, after S1)

**Files:** `client/scripts/World3D.gd`, `client/scripts/net/world.gd`, the server's
`EntitySnapshot` / `EnterWorldResult` fields (a server change this lane owns, coordinated with S).
- Bodies from RefObjID + scale for the player and others, through `CharacterAppearance`, replacing
  `GENDER_BODY_CODE`.
- The wire adds `ref_obj_id` (u32) and `scale` (u8) to both messages, trailing, so that an older
  client stops before them (the `FrameRegion` precedent).
- Europe bodies' speed and sound rows (the code looks up by the gender's body code today).
- `perf_gate.sh` required.

### Order and collisions

- Round 0 first.
- Then S1, A1 and B1 in parallel. A1 renders with a sex-only body until B1 merges.
- Then S2/S3, A2/A3 and B2/B3 in parallel.
- W1 after S1 and B1.
- The only shared files are the round-0 codec and catalogue, which later lanes only read.
- **Scene architecture is OURS and must be settled in A1** (USER DECISION 6): whether the 3D
  backdrop survives Login -> Select -> Create as one long-lived `FrontEndBackdrop` (an autoload or a
  root front-end scene), or each scene builds its own. Each screen's region differs (title intro,
  105/81, 98/168 or 105/79), so the cost is regions loaded per transition. Measure it, then choose.

## 8. Decisions for the user

1. **Opcodes:** carry the retail payloads on retail's opcode numbers (0x7007/0xB007/0x7001/0xB001)
   on our framing now, or keep our 0x0010-0x0015 numbers with retail-shaped payloads until the
   retail framing lands. Recommended: retail numbers. The superset addendum wants them, and they
   cannot collide with ours.
2. **Characters per account:** retail 4 (READ) against our 3.
3. **The deletion delay on the test server:** retail's client says and gauges **7 days** (READ). A
   shorter delay still shows the countdown correctly (the server sends minutes), but the confirm
   text will still say 7 days.
4. **Existing characters:** migrate `china_man`/`china_woman` to 1909/1923 at scale 0x22 (what they
   look like today)? And keep names that break the new 2..12 / alphanumeric rule (grandfathered), or
   force a rename?
5. **Europe:** a Europe character starts in Constantinople or the Europe spawn region (READ spawns).
   Our server spawns everyone at Jangan today, and Europe towns' NPCs and shops have never been
   exercised. Offer Europe from the first release, or show the idol and refuse it ("Out of service
   area." is the retail text for a region not offered)?
6. **The front-end scene architecture** (section 7): one long-lived backdrop or one per screen.
7. **Starting items:** retail's server checks only race, sex, equipment type and armour class, not
   that items are the `_A_DEF` defaults (READ; the procedure is OPEN). Recommended (OURS): accept
   only the 104-id catalogue, so a modified client cannot create a character in endgame gear.
8. **Running the shard DB container** (CT 104) once to export `_RefCharGen` and the
   `_RefCharDefault_*` tables and to read the five procedures (section 6).
9. **China's Protector minimum** (a per-server flag, meaning OPEN): require a set (Europe's rule),
   or allow "none" (Protector 0) as a server may?

## 9. Still OPEN

- Where the client's creatable-id list (0xeedf08) comes from (INFERRED `_RefCharGen`).
- Volume's bone group numbers (0xec64c8 / 0xec6528).
- The name bitmap at 0x8c3cb0, and the forbidden-word lists' source.
- The deletion delay in `_DeleteCharTemporal`.
- Restore's u8 vs u16 error code.
- 0xB007 action 6.
- The academy byte in the list.
- The preview's and the select idle's animation.
- The lizard's root motion.
- `FUN_00bbda70(1)` on select open.
- Re-entering select after create when the previous-process id is neither 0 nor 10.
- The per-server flag behind China's Protector minimum.
- Europe women 12/13's order.
