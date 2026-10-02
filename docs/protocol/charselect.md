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
- The shard DB export (EXTERNAL, a private shard's, partly modded): `/opt/sro-files/db/csv/`. The
  lobby's tables and procedures (exported 2026-10-02 with the user's approval, read in round 692)
  are in `/opt/sro-files/db/csv/charsel/`: `_RefCharGen`, `_RefCharDefault_Skill`,
  `_RefCharDefault_SkillMastery`, `_RefCharDefault_Quest`, and the text of `_AddNewChar`,
  `_DeleteCharTemporal`, `_DeleteCharPermanently`, `_ReviveChar`, `_RecoverDeletedChar` and
  `_IsExistingCharName`. A server-side READ from them means "READ (this package's procedure)".
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

**Fixed in round 682:** `character.go` (the Gender note and MaxPerAccount 4), `equipment/
starterkit.go` and an addendum under RE_COMPLETION's two 2026-09-18 entries (the kit and the
scale-byte order), and recovered_names' evidence for `SendCharacterCreateChina` (0084e610) and
`SendNameCheckRequest_858c00` (whose *name* stays until the rename is applied in Ghidra too: OPEN).
`CharacterCreate.gd`'s header says so too. The FRONTEND docs are the client lanes'.

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
- Two {group, min, max} tables, chosen by the model's vslot 0x34: 0xec6528 when it is non-zero.

| Table | Groups |
|---|---|
| 0xec64c8 (men, INFERRED) | (2, .88, 1.10) (3, .95, 1.11) (8, .92, 1.20) (19, .92, 1.20) (29, .90, 1.15) (33, .90, 1.15) (1, .90, 1.00) |
| 0xec6528 (women, INFERRED) | (2, .95, 1.10) (3, .95, 1.00) (8, .95, 1.15) (19, .95, 1.15) (29, .90, 1.15) (33, .90, 1.15) (1, .90, 1.08) (37, .80, 1.18) |

**What the group numbers are (READ, round 683; this closes the OPEN):**
- Each group goes to `CCompChar` vslot 49 (0xc2ca90; the same slot in CCompBldg, CCompSimple and
  CCompoundObj). It refuses 38 and above (38 is the tables' `&` terminator) and passes the string at
  **0xed9b68 + group x 0x1c** to 0xc2ca50.
- Those are 38 std::strings that `FUN_00d79e00` assigns at start-up, in this order: 0 `Bip01`,
  1 `Bip01 Pelvis`, 2 `Bip01 Spine`, 3 `Bip01 Spine1`, 4 `Bip01 Neck`, 5 `Bip01 Neck1`,
  6 `Bip01 Head`, 7-17 the left arm (`L Clavicle`, `L UpperArm`, `L Forearm`, `L Hand`, six
  fingers, `L HandMid`), 18-28 the same for the right, 29-32 `L Thigh`, `L Calf`, `L Foot`,
  `L Toe0`, 33-36 the same for the right, 37 `Bone01`. So the tables scale **the pelvis (1), the
  spine (2, 3), both upper arms (8, 19), both thighs (29, 33)** and, in 0xec6528 only, `Bone01` (37).
- 0xc2ca50 finds the bone by that name in the character's skeletons (0xc2c890) and 0xc4aaf0 stores
  the factor at CRTBone +0x88 and sets flag 2 in +0x84 (cleared when the factor is exactly 1.0).
- `RTSkeleton::FUN_00c4a180` (called from the bone update, `CRTBone::vslot_006` and 0xc4bcb0, when
  flag 2 is set) copies the bone's world matrix, multiplies **rows 1 and 2** (the bone's own Y and Z
  axes) by the factor, leaves row 0 (the axis along the bone), and stores inverse bind x that matrix
  at +0x8c. `CObjRendererVS::FUN_00bf0310` uses +0x8c as the bone's skinning matrix when flag 2 is
  set. Children are composed from the unscaled world matrix.
- So Volume thickens or thins what is weighted to those bones, across the bone and never along it,
  and moves no joint. Armour skinned to the body follows it; a weapon on its own skeleton does not.
- **Which table is whose (INFERRED, two supports):** only the women's skeleton has `Bone01`.
  Every one of the 52 Figure `.bsr`s names a **Europe** skeleton, China bodies included: the 26 men
  `prim\skel\char\europe\europeman_skel.bsk`, the 26 women `europewoman_skel.bsk` (MEASURED,
  round 683 review; `china\chinaman_skel.bsk` is named by one other `.bsr` only). europewoman_skel
  holds Bone01/Bone02 and europeman_skel does not (MEASURED). And the same vslot 0x34 selects the harp's `_f.bsr` model
  (`CObjCharacter::FUN_00a5f4f0`). What vslot 0x34 reads (a resource's +0x28, `CCompChar`
  0xc1f0d0 -> 0xc2bb40) was not traced further.
- `CharacterAppearance` (client/scripts/ui/character_appearance.gd) applies it as each bone's skin
  bind pre-multiplied by scale(1, f, f).

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

**Which byte is which** (READ round 682, asm 0x858b66-0x858bd4): the list record's guild byte
(character +0x1f0) is 1 for `_CONFIRM_MEMBER` and 2 for `_CONFIRM_MASTER`; the academy byte (+0x1f1)
is 1 for `_CONFIRM_STUDENT` and 2 for `_CONFIRM_GUARDIAN`; 0 on both opens the confirm (0x858950).
So guild class 0 none / 1 member / 2 master, academy 0 none / 1 student / 2 guardian.

**The confirm popup (window 20)**
- Fades in over 0.5 s, dims the screen to alpha 0x80, plays `snd_window_open`.
- Text `UIO_STT_CHAR_DEL_CONFIRM`: "...it will be reserved for 7 days... after 7 days, it will be
  permenantly deleted. Do you really want to delete the character?" Button "Delete".
- For a pending character: `UIO_STT_CHAR_RECOVERY_CONFIRM` and "Restore".
- Accept (0x858c00) sends 0x7007 action 3 (delete) or 5 (restore) with the name. Which one is
  the window's +0x11d flag (READ round 682: `cmp BYTE [esi+0x11d]` at 0x858c93, then action byte 3
  at 0x858ce9 or 5 at 0x858d87), set by 0x858950 from the character's pending byte +0x1e8.

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
  - **The delay** (READ round 692, this package's procedures). `_DeleteCharTemporal` refuses char
    id 0 (-2) and a character already deleted (-3); otherwise it inserts `_DeletedChar (CharID,
    UserJID, GetDate())` and sets `_Char.Deleted = 1`. It checks no guild and no time: those are the
    callers'. `_DeleteCharPermanently` refuses a character not in `_DeletedChar` (-1), one deleted
    **less than 6 days 23 hours** ago (-2; its comment: "is it roughly 7 days since the delete --
    in case the shard has a bug -- an hour's error is allowed"), one whose `Deleted` is not 1 (-3)
    and one not on the account (-5), then calls `_DeleteCharPermanently_NoTX` (not exported). So
    the 7 days are the ShardManager's timer and the procedure is a guard an hour short of them;
    the client's text and gauge say 7 days (READ). srrevamp purges at 7 days (the user's choice,
    `character.DeleteDelay`): the same.
  - **Restore** (READ, `_ReviveChar`): refused when the character is not in `_DeletedChar` (-1) or
    its `Deleted` is not 1 (-2); otherwise the `_DeletedChar` row goes and `Deleted` returns to 0.
    No time check: a purged character simply is no longer there. srrevamp's restore is the same
    (0x419 when not pending). `_RecoverDeletedChar` is an old operator tool, disabled in this
    package (its body only selects an error string, "do not use, it changed").

### Equipment on the select models (READ, FUN_0085a580)

- Each of the up to 9 equipped items in the list record is resolved to a visual slot and installed
  with its plus value, the weapon included.
  - The slot (READ, `GlobalDataManager::ResolveVisualSlotForItem` 0x9db5e0): an armour piece
    (TypeID3 1/2/3/9/10/11) by TypeID4 1 head 0, 2 shoulder 2, 3 chest 1, 4 legs 4, 5 hands 3,
    6 feet 5; a weapon (TypeID3 6) 6; a shield 7; TypeID3 7 8; earring 9, necklace 10, ring 11,
    else -1. `InstallEquipVisual` draws a mesh for 0..8 only and keeps one visual per slot.
- Avatar items (TypeID3 13, the 0x680 test) go through `FUN_00a60ef0`, which attaches the avatar's
  resource (and a second one when +0x34 is set) without removing a slot's visual. Whether an
  avatar hides the armour under it is OPEN.
- **Weapon models (READ, `CObjCharacter::FUN_00a5f4f0`):** TypeID4 9 (dual axe) and 13 (dagger)
  are drawn from the model path's `_l.bsr` and `_r.bsr` (the plain `axe_01.bsr` does not exist,
  MEASURED); TypeID4 14 (harp) on a body whose vslot 0x34 is set from `_f.bsr`. The create screen's
  loader (0x80b980) preloads the `_r.bsr` of the same two weapons.
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

### Round 684's reading (what `CharacterSelect.gd` follows; READ unless marked)

- **The race index is 0 for Europe, 1 for China.** `DAT_00ec2d64` indexes the idol objects in
  OnCreate's load order (Europe, China, then the lizard) and the panels at +0x228 (window 11) and
  +0x22c (window 9). Index 0 flies to (168.5, -34.9, 639.1) (0xdd7cfc) and switches to the process at
  `DAT_00eed8d4`. `CharSelectHandoff` translates it to `CharCatalog`'s race (section 7).
- **A click on nothing does nothing.** `vslot_017` (0x85ddb0) calls `FUN_0085ca10` only while an
  idol is hovered (`DAT_00ec2d64 != -1`) in state 8, and selects only while a character is hovered in
  state 2. "Out of service area." is shown for an index other than 0 or 1, which two idols never give.
  This corrects section 3's "Anything but an idol".
- **Cancel 17 is 0x85c7e0**, a function the decompile's list lacks (found by its `mov [esi+0xe4], 0xb`
  at 0x85c9f5): window 3 to 255 and 4 to 0 over 5.0 s (0xe1b86c), 12/13 in and 17 out over 0.5 s, both
  panels out, and the race keys added **reversed** (key 3 at 0 ... key 0 at 5.0 s). State 0xb ends with
  the lizard hidden (+0x220 = 0) and the page re-placed.
- **Back (13) is 0x85b560**: window 21 from 0 to 255 over 0.5 s and the two list keys reversed,
  (60, -15, 660) at 0 to (60, -15, 700) at 2.0 s -- the "dolly out". State 0xd switches to the title
  when the path ends.
- **Cancel 16 is `FUN_0085c1d0`**: Create and Back in; Start, Delete, Restore, 16, 26 and the info
  panel out; the message cleared; the camera from where it is to the list's second key over 2.0 s.
- **Create (12) is `FUN_0085c4a0`**: 3 out and 4 in over 5.0 s, 12/13 out, 17 in, the arrows and
  labels out, the race keys at t = k x 5.0 / 3.0.
- **The models fade in on every list.** `FUN_0085f840` zeroes each new model's alpha; `FUN_0085def0`
  then fades it over 1.0 s to 0xff, or 0xcc when pending. A model is drawn only while its alpha is
  non-zero (vslot_013). After a delete or restore the whole list fades in again, and the character
  re-selected sits down (0xd, then 0xe) or stands up (0xf, then 0).
- **The order among equal keys:** `FUN_00859e70` inserts with no equality test and an equal key goes
  right, and the walk is backwards, so the later record comes first.
- **Picking:** each model of the page, in order, is tested with a ray against its own bounding box
  (`FUN_00a5b2c0` -> `FUN_00a5b000` with vslot 0x10's local box and vslot 0x18's matrix); the first
  hit wins, not the nearest.
- **The name label** fades at 0.5 s per whole fade (`FUN_00855400`'s duration is 0.5 x the bytes left
  / 255), in font 4 (`FUN_00ba5460(4)` in `FUN_0085a580`). Its colour and alignment were not read
  (INFERRED: white, centred).
- **The idol panels** (vslot_012 case 7): top-left = the projection of the idol's bounding-box
  centre, turned by its yaw and moved to its position, less half the panel's width; x held at 5 or
  more. The lizard switches to clip 1 there (`(1, 0, 200, 0, 1.0, 1.0)`).
- **Window placement (OnCreate 0x85ee33..0x85f04c), screen pixels, unscaled:** 12/15/25 at
  (W - 0xd1, band2 + 0x1b), 13/16/17 at (W - 0x69, ...), 14 at (W - 0x139, ...), the info panel 18 at
  (W - 0x10f, band1 + 0x29), the countdown 26 at ((W - its width) >> 1, band2 - 0x66), the message
  line 500 at (0x1a, band2 + 0x1d) sized (W - 0x1a) x 100; the popups 20, 900, 920 centred. band1 is
  window 1's bottom and band2 window 2's top, both as scaled (`FUN_00849c70` over 1, 2, 3, 4 and 21).
- **The page arrows** (case 0): 45 at (10, (H - h) >> 1), 46 at (W - w - 10, ...); "[ %d / %d ]" in
  window 50 with more than 4 characters (`FUN_00858e50`).
- **The delete refusals'** keys are `UIO_MSG_CHAR_DEL_WANNING_CONFIRM_MEMBER` / `_MASTER` /
  `_STUDENT` / `_GUARDIAN` (the strings at 0xdd7b58, 0xdd7ba8, 0xdd7aa8, 0xdd7b00).
- **The countdown text** is CIFPML markup in the archive (`<sml2>` and `<font color="a,r,g,b">`
  around each %d, MEASURED); this client draws it as BBCode with the colours kept and `<sml2>` dropped
  (INFERRED: the PML renderer was not read).
- **EXP** is capped at 99.99 once the percentage reaches it (0xd986f8); the level's EXP is the level
  record's +8, leveldata column 1.
- **No version line**: it is CPSTitle's window (0x86bc1d); select creates none.
- **Round 684's review:** the buttons take a click in any state they are shown in (no state check in
  0x85c4a0, 0x85b560, 0x85c1d0 beyond closing the confirm, 0x85de50 beyond the count); the re-select
  after a delete or restore keeps the camera's x/z/angles and sets y from the character's state
  (LAB_0085c06b), 1.0 s; the idol pick keeps the last hit. The Europe bodies' `.bsr`s list only
  China stand and sit clips (MEASURED), so a Europe woman idles in `chinawoman_merchant_standcity`.

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
| tooltip | China (rotate.x - 59, rotate.y - 219); Europe, whose window is 212x250, (rotate.x - 69, rotate.y - 270) (round 685: 0x853ea2..0x853eca, -0x45 / -0x10e) |
| confirm box | centred |
| message line (500) | (26, bottom band top + 29), W - 26 by 100 (round 685: 0x850157..0x8501ac) |

**Round 685 additions (READ, OnCreate 0x84fbc0 / 0x853990 unless marked):**
- **Only windows 1, 2 and 14 are scaled to the screen** (FUN_00849c70 at 0x84ff8d..0x84ffb7). The
  title (3) and China's calligraphy (5) stay at their layout rects in screen pixels; the code above
  places the rest. MEASURED against fe_ref3/4 (2546 px wide): the title at 47,111 and the model's
  centre where the formula below puts it.
- **The sliders** are built from the layout's `Slider` section -- prev 71 `arrow_left.ddj` at
  (0, 2), next 72 `arrow_right.ddj` at (120, 2), thumb 73 `slider.ddj` 16x24 at (20, 0), each with
  `_focus` / `_press` art (MEASURED) -- by FUN_00659620, and given a track of 0x54 = 84 (FUN_00659840).
  Height and Volume get FUN_006599e0(0, 4, 1, 1) and FUN_006598a0(2, 1) (0x8503c4..0x8503db).
  INFERRED: the thumb runs from x 20 to 104.
- **The ranges** (the sex setter 0x84f350): Figure (1, the sex's body count); China Protector
  (1 unless `CGame+0x129` is set, then 0; up to the chest count); Weapon (0, the weapon count).
  Europe's weapon handler 0x853400 sets the Protector range by the weapon's TypeID4 -- (0, 2) for
  7, 8, 9, 15; (0, 1) for 10..14; (0, 0) with none -- and puts it at 0 (FUN_006598a0(0, 1));
  0x8531e0 draws the Protector slider at alpha 100 with no weapon, 255 otherwise.
- **The windows' first state:** 3, 5, 13 and 12 hidden; 12 and 14 coloured 0xff000000; window 14
  fades 255 -> 0 over 0.5 s (FUN_006526e0(0xff, 0, 0.5)); when it ends the title and the
  calligraphy fade 0 -> 255 over 0.5 s (0x84e610's fade-end branch).
- **The tooltip** (61 title, 62 text; 0x84d470 China, 0x850f50 Europe) shows the keys of the
  control in `this+0x350` at its current choice: a Figure's `UIO_NEWCHAR_[EU_](MAN|FEMALE)_<name>`
  and `_EXPLANATION`; `UIO_NEWCHAR_STT_HEIGHT` / `_EXPLANATION_HEIGHT` and the same for Volume;
  Weapon 0 `STT_WEAPON` / `EXPLANATION_ARMY_SELECT`, then China SWORD, BLADE, SPEAR, TBLADE, BOW,
  Europe `STT_EU_` DAGGER, ONEHANDSWORD, TWOHANDSWORD, DUELAXE, CROSSBOW, DARKSTAFF, TWOHANDSTAFF,
  HARP, ONEHANDSTAFF with `EXPLANATION_<same>`; Protector 0 `STT_PROTECTOR` /
  `EXPLANATION_ARMOR_SELECT`, then by the chest's list place China HEAVY_ARMOR, LIGHT_ARMOR,
  CLOTHES, Europe `EU_` HEAVY_ARMOR, LIGHT_ARMOR, ROBE. A slider handler sets +0x350 to its control;
  each frame the slider under the cursor does too, when it is not already the subject
  (0x850573..0x8505d5). Nothing is shown before the first (+0x350 starts at -1).
- **Messages** (FUN_00861850 -> 0x8613b0) go to window 500, the message line, while it exists; the
  NetError message box is the fallback. Confirm's own refusals also play `snd_error`.
- **The confirm box** (0x84ec00): 13 fades 0 -> 255 over 0.5 s with the name in 31; 12 dims
  0 -> 0x80 over 0.5 s. The create OK (0x84cff0) fades 14 to 255 over 0.5 s, then select.
- **Cancel** (11, 0x84d300) switches to select at once and writes 0xa as the previous process.
- **A Europe sex change clears the armour** (round 685's review): 0x852e00 re-sets Figure, then
  the Protector, then the Weapon through 0x6599e0 with its notification, and 0x6598a0 sends 0x2806b
  at once, so the weapon handler 0x853400 runs last and puts the Protector at 0 (0x8531e0 takes
  slots 1-3 off). China's weapon handler resets nothing, so China keeps its set.
- **Default wear** (round 685's review; `client/scripts/ui/default_wear.gd` has the addresses): an
  empty chest or legs shows `charactervisualchange.txt`'s ConditionID 6 garment -- Europe
  `clothes_01_ba/_la` (worn armour light or heavy: `light_01_*`), China `clothes_00_*` /
  `light_00_*` -- unless `CGame+0x129` is set; nothing for the feet. So Europe at opening, after a
  weapon change and at Cloth 0 wears the red tunic the reference shows.
- **The sex buttons** (0x84f630 male, 0x84f540 female) swap their art: male man_on / woman_off,
  female man_off / woman_on, with `_press` art (strings 0xdd5f20.., 0xdd5e9c..). Their ClientRects
  (male "20,0,0,0", female "0,0,20,0") keep the text clear of the radio mark (INFERRED).

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
    it ("There is no Refobj like this or Service is 0 (ObjID : %d)"). **Round 692 (MEASURED):** its
    104 RefObjIDs (all Service 1) are exactly the rule's 104, on the server's and the client's
    implementation alike.
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

- **The animation (READ round 685, `CCustomInfoManager` 0x80b440):** a model change (slot 0) re-dresses
  every slot, re-applies the scale (`CIFCharacterWnd::FUN_0080c250`) and calls vt+0xc(0, 0, 0, 0,
  1.0, 1.0) -- animation 0, ANI_STAND1 (`SkillEffectReader.ANI_TYPES`), from its start; a weapon
  change (slot 4) installs the weapon, the shield beside a weapon whose refitem +0x250 is 0
  (`FUN_0093f5f0`), and plays animation 0 again; an armour change only re-dresses (vt+0x20).
  INFERRED: the clip is looked up in the held weapon's group, as the world's is.
- **The window's camera** is a CGFXVideo3d at CIFCharacterWnd +0x57c (the constructor 0x80c090 runs
  0xbae0a0 there): OnCreate's +0x58c.. is its target, +0x5b0.. its pitch, yaw, roll, distance, and
  **+0x5cc = 45.0 its vertical field of view** (camera +0x50; 0xdd5f74). MEASURED against fe_ref3:
  the model's centre 0.13 of the half-width right of the screen's middle, as the target's 2.5-unit
  offset at 28.5 with 45 degrees and a 16:10 screen puts it.
- **The rotation formula above, re-read (round 685, 0x850804..0x8508a4):** also `d = v` when
  `|v| < |d|`; the snap is `v = 0` once `|v - d| < 30` (`fcomp` with 0xdd6018). The zoom targets were
  re-read: 2.0 (0xd86ecc), 15.0 man / 14.0 woman (0xdd5e2c / 0xdd5e30), 11.0 (0xd8acf8). The move is a
  two-key path (FUN_0084f9e0 -> 0x4e67b0), the title's Catmull-Rom curves.

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

### What srrevamp sends (round 682)

The lobby rides **our framing on retail's opcode numbers** (USER DECISION 1): 0x7007 / 0xB007 /
0x7001 / 0xB001 in a `proto.Packet`, payloads byte for byte the layouts above. Codec:
`server/internal/session/lobby.go` and `client/scripts/net/lobby.gd`; golden bytes, written by
hand from the layouts: `client/scripts/net/testdata/lobby_golden.json` (both sides run it).
Our 0x0010-0x0015 are gone. Start's OK is followed by today's `OpEnterWorldResult`; the old
`OpEnterWorld` (0x0020) still works and refuses a pending character too.

| Code | srrevamp raises it for (OURS where marked) |
|---|---|
| 0x402 | Start: an empty name, a character pending deletion (READ). Delete: a guild member or master (READ), a guild lookup that fails (OURS, fails closed), a character already pending (OURS). Any action: a store error or a payload too short to read (OURS). Retail also refuses a quote in a Start name with 0x402: **not applied** (round 682's review), so a grandfathered name with one still starts. |
| 0x403 | Create: no catalogue loaded; a body or item outside it (OURS, on top of READ); a body not TypeID 1/1; an item not equipment, of the other race (not 3), of the other sex (not 2) (READ); an item in the wrong field (OURS); a missing chest, legs or feet (OURS: China's Protector "none" is not offered); a Height or Volume nibble above 4 (OURS). |
| 0x404 | Create: weapon 0 (READ). |
| 0x405 | Create: 4 characters already, pending ones included (READ). |
| 0x406 | Create: armour pieces of two classes (READ check, INFERRED code); the store failed. |
| 0x407 | Any action or Start before login (READ). |
| 0x408 | Delete: an empty name (READ "name refused"; retail's quote refusal is not applied, as for Start). |
| 0x40b | Delete, restore, Start: no character of that name on the account (READ). |
| 0x40c | Create, name check: not 2..12 bytes (READ). |
| 0x40d | Create, name check: a space, `'` or `"` (READ); a byte outside printable ASCII (OURS: the client's bitmap is OPEN). |
| 0x410 | Create, name check: the name exists, pending deletion or not (READ, `_IsExistingCharName` round 692: `_CharNameList`, which keeps a pending character's name, and `_CharNickNameList`, by `=`); compared without case (OURS: the `=`'s case rule is the DB collation's, not exported; INFERRED case-insensitive). srrevamp has no nicknames. |
| 0x419 | Restore: the character is not pending deletion (READ), sent as a u16 (OURS, see above). |
| 0x40e | Any 0x7007 action from a session already in the world (OURS choice of code: "an operation is pending" is the nearest READ meaning; what the ShardManager answers there was not read). |

Not raised: 0x409, 0x40a, 0x40f, 0x411-0x418.

**Older clients and servers** (round 682's review, OURS): the server answers the removed
0x0010 / 0x0012 / 0x0014 in their old reply formats with "this server uses the new character lobby
-- update the client", which the old screens show; a new client that has no list answer within 5 s
says "The server did not answer the character list -- the client or server may need updating."
(no retail text key fits: the nearest, `UIO_MSG_ERROR_SEVER_CONNECT`, would be false).

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

**No whitelist** of default items is checked in this code, nor in this package's `_AddNewChar`
(READ round 692: it maps the 12 `_A_DEF` chests, 2 shields and 14 weapons it knows to the shard's
own `_A_RARE` sets and passes any other id through unchanged).

**What runs** (FUN_00429c80):
- Internal 0x620e (shard id, JID, name) goes to the manager.
- Then `_AddNewChar`, synchronously; a failure gives 0x406.
- **It adds** (READ):
  - the three armour pieces must share one armour class (round 682: the loop at 0x429d42 over the
    item slots compares each non-weapon item's type bits 7..10 -- TypeID3 -- with the first one's,
    0x429dc2-0x429dd7, and a Country unequal to the model's, 0x429d84; either failure calls the
    error routine and returns 0 from the worker, 0x429cca. Which code the client then sees is
    INFERRED to be 0x406, the worker's failure path);
  - each item gets a durability byte from its refobj;
  - a bow gets `ITEM_ETC_AMMO_ARROW_01_DEF`, a crossbow `ITEM_ETC_AMMO_BOLT_01_DEF`;
  - otherwise a one-handed weapon gets the race's shield, `ITEM_CH_SHIELD_01_A_DEF` or
    `ITEM_EU_SHIELD_01_A_DEF`. One-handed is itemdata column 93 (0-based) = 0 (INFERRED to be what
    the server reads; MEASURED on the 14 weapons: China sword and blade, Europe 1H sword, warlock rod
    and cleric rod are 0, the rest 1 -- the dagger included).

**The start position** (FUN_0042bb20): `rand() % 3` picks one of three spawns per race (table
0x781b88), and the return point is the race's `STORE_CH_GATE` / `STORE_EU_GATE` refobj.

> **Whose values these are.** The spawn table, the ammunition and shield rule and the code names
> above are READ from a **private-server package's** SR_ShardManager.exe, not from a retail
> binary. Nothing modded was seen in its lobby code, but these are exactly the kind of values a
> server operator edits (where a new character starts, what it is given), so they may be that
> package's rather than retail's. srrevamp uses them (round 682) labelled so; the shard DB
> procedures (section 6) are where a retail-shaped confirmation would come from. Round 692 read
> them: `_AddNewChar` **ignores** the start position and gate the ShardManager passes and writes
> region 25000 (97/168, Jangan) at (993, 0, 130) and `AppointedTeleport` 2094 (`STORE_CH_GATE`,
> MEASURED in characterdata) for every race, so on this shard Europe characters start in Jangan
> too -- a shard edit or a shard choice, either way not the ShardManager's table, which srrevamp
> keeps (the user's decision 5). The ammunition quantity is 250 (below).

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

### `_AddNewChar`, read (round 692; READ, this package's procedure, EXTERNAL)

Its 20 parameters are the list above, in that order (`@DefaultTeleport` is the 9th: the gate, as
INFERRED). It has been **edited by the shard's operator** (blocks marked "Initial Equip Edit by
LemoniscooL", calls into an `ANTHEIA` database, a commented-out level-110 variant of its INSERT),
so each value below says whether srrevamp takes it.

| Step | What it does | srrevamp |
|---|---|---|
| Shard edit | Swaps the 12 `_A_DEF` chests for the matching `*_01_*_A_RARE` set and adds its hands, hat, shoulders, earring, necklace and two rings; swaps the 2 shields and 14 weapons for their `_A_RARE` ids; each item's durability is its `_RefObjItem.Dur_L`. | **Not taken** (the shard's edit). The chosen `_A_DEF` items, as round 682. |
| Refusals | 4 characters already (`_User` count >= 4) -2; scale > 68 (0x44) -3; `_IsExistingCharName` -4. | Same 4 (0x405) and name rule (0x410). The scale: srrevamp refuses either nibble above 4 (OURS, stricter than `> 68`). |
| `_Char` row | RefObjID, name, scale, **Strength 20, Intellect 20**, region 25000 (993, 0, 130), AppointedTeleport 2094, **InventorySize 109**, **CurLevel 1**, MaxLevel 1, **RemainGold 2,000,000**, RemainStatPoint 0, **RemainSkillPoint 5,000,000**, **HP 200, MP 200**, job levels 1/1/1, WorldID 1. The position and gate parameters are not used. | Str/Int 20 and HP/MP 200 **now READ** (`character.StartingStr`, was OWN DESIGN; the level-110 variant's 129 = 20 + 109, StatGrowthPerLevel 1, agrees). 109 = 96 + 13, srrevamp's default bag of 96 (`-inventory-size`). Level 1. **Gold and SP not taken** (INFERRED the shard's: that INSERT is the one its operator edited; decision 10). Position: the ShardManager's per-race spawns, as before. |
| Inventory | `_Inventory` slots 0..108 empty, `_InventoryForAvatar` 0..4 empty. | n/a |
| Equipment | Each item into its slot (`_FN_ADD_INITIAL_EQUIP`: chest 1, hands 3, hat 0, shoulder 2, legs 4, feet 5, weapon 6, shield 7); **the arrows or bolts into slot 7 with 250**, where every other item gets its durability (INFERRED: the stack's count). | **250 arrows or bolts** (`session.AmmoStartQuantity`, was one full stack, 2,500, OURS), into the bag as before (the slot has no quantity). |
| **Masteries** | `_CharSkillMastery`: every `_RefCharDefault_SkillMastery` row whose Race is `_GetObjCountry(RefObjID)` or 3, **at Level 0**. | Done (round 692): level-0 rows. |
| **Skills** | `_CharSkill`: every `_RefCharDefault_Skill` row of that Race or 3, Enable 1. | Done: learned. |
| **Quests** | `_CharQuest`: the `_RefQuest` id of every `_RefCharDefault_Quest` CodeName of that Race or 3 with **RequiredLevel 1 and Service 1**, Status 1, AchievementCount 0. The higher-level rows are not given here. | Recorded by code name (`character_default_quests`); not quests yet (see below). |
| Other rows | `_StaticAvatar`, `_CharTrijob (0, 1, 0, 0, 0)`, `_CharNameList`, `_AddNewClientConfig` (the quick slots). | n/a (srrevamp has no such rows) |
| Shard edit | `_RoyalAddItems`: nine item grants (stacks of 5,000 and 20, a sex-specific item); `ANTHEIA.._AutoEquipment`; a silk row; beta-test silk rewards. | **Not taken.** |

Race 0 is China and 1 Europe (INFERRED: `_GetObjCountry`'s body was not exported; Race 0's
masteries are China's and Race 1's Europe's by `skillmasterydata.txt`, MEASURED).

**The default tables** (EXTERNAL, 13 + 13 + 15 rows; the rows are the shard's and are not
reproduced here or anywhere in the repo -- the tests use a synthetic set, and
`refdata.TestCharDefaultsRealExport` checks the export when `SRREVAMP_TEST_CHARDEFAULTS_DIR` points
at it). What the rule gives, MEASURED on the export:

| | China (Race 0, and 3) | Europe (Race 1, and 3) |
|---|---|---|
| Masteries, level 0 | 7: all seven China masteries, 257-259 and 273-276 (`skillmasterydata.txt`) | 6: all six Europe masteries, 513-518 |
| Skills | 4: the bare-hand attack (the one Race 3 row) and one basic attack per China weapon family | 10: the same bare-hand attack and one basic attack per Europe weapon family (nine) |
| Quests at create (RequiredLevel 1, Service 1) | 3: two Race 3 rows and one Race 0 row (China's tutorial) | 2: the two Race 3 rows only |
| Quest rows not given at create | 12 Race 3 rows at RequiredLevel 5..60: when they are given is not in these procedures (OPEN; INFERRED the game server, at those levels) | the same |

No row has a Race other than 0, 1 or 3 and no id repeats for a race (MEASURED: `Warnings()` is
empty on the export). The server would log either at boot, give a repeated id once (OURS: the
procedure's insert would fail on its key and roll the create back, INFERRED) and match no
character to another Race.

**Europe's quests.** The table has **no Race 1 row**: a Europe character gets only the two Race 3
quests. The archive does hold a Europe tutorial -- `QTUTORIAL_EU` (questdata id 210) and
`QTUTORIAL_EU_2` (225), both category 1 in `questcontentsdata.txt` -- and `QTUTORIAL2_EU_1..7`.
Whether retail gave Europe `QTUTORIAL_EU` at create (a row this shard's table lacks) or some other
way is OPEN; srrevamp follows the table (READ). `questcontentsdata.txt`'s third column is the same
0 / 1 / 3 as Race (MEASURED on the archive's tutorial and newcomer quests).

**The `_RefQuest` join.** The procedure inserts `_RefQuest` ids `WHERE CodeName in (...)`, so a code
with no `_RefQuest` row gives nothing (READ). `_RefQuest` was not exported, and some of the
export's codes are absent from the archive's `questdata.txt` (MEASURED; that file is the client's
copy, 697 rows), so whether every code would pass the join is OPEN. srrevamp records every code
that passes the READ filters (INFERRED to pass the join too).

**Why the quests are recorded, not given.** srrevamp's quest package is an invented catalogue whose
ids 1 and 2 are real quests' ids in `questdata.txt` (`quest/quest.go`); accepting a default by id
would start "Mangyang Cull". No real quest's steps are modelled. So each grant is stored as (character,
code, status 1) in `character_default_quests`, which nothing else reads yet: the record for when
the quest graph is imported.

**Delivery** (OURS): the three tables are read as exported, from a directory named by
`-chardefaults-dir` (env `SRREVAMP_CHARDEFAULTS_DIR`); a `_RefCharGen.csv` beside them is compared
with the catalogue at boot. Without the flag the server warns that new characters get no defaults,
and creates as before. deploy/README.md, "Character defaults".

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
| The list of creatable ids (`_RefCharGen`) | shard DB (EXTERNAL), 104 rows (Service, RefObjID), all Service 1 | **Confirmed (round 692, MEASURED):** the rule's 104 ids -- the server's (`chargen.csv` from `cmd/export-refdata`) and the client's (`CharCatalog.from_archive` on the box's Media.pk2) -- are exactly `_RefCharGen`'s 104, no id missing or extra on either side. The server compares them at boot when `_RefCharGen.csv` is in `-chardefaults-dir`. |
| Item and character names | `textdata_equip&skill.txt` (`SN_ITEM_*`), `textdata_object.txt` | MEASURED |
| UI text (buttons, tooltips, errors, deletion) | `textuisystem` keys named above | READ keys, MEASURED English |
| Layouts and art | `resinfo\pscharacterselect.txt`, `pscharactercreatechina.txt`, `pscharactercreate_europe.txt`; `interface\...` ddj | MEASURED |
| Race-select meshes | `Res\interface\box.bsr`, `interface_idol_europe/china.bsr`, `interface_lizard.bsr` | MEASURED |
| EXP % on the panel | `leveldata.txt` (already imported, `internal/leveldata`) | READ |
| Deletion delay | `_DeleteCharTemporal`, `_DeleteCharPermanently` (READ round 692) | 7 days: the temporal delete only stamps the date; the permanent one refuses before 6 days 23 hours (section 2). The client says 7 days. |
| Default skills / masteries / quests | `_RefCharDefault_*` (EXTERNAL, 13 + 13 + 15 rows), applied by `_AddNewChar` (READ round 692) | **Applied** at create from `-chardefaults-dir` (section 5, "`_AddNewChar`, read"): masteries at level 0, skills learned; the level-1 quests recorded by code (the quest system cannot hold them yet). |
| Starting Str / Int / HP / MP, bag size | `_AddNewChar`'s INSERT (READ round 692) | 20 / 20 / 200 / 200, 109 = 96 + 13: what srrevamp already used (Str/Int were OWN DESIGN until now). Its gold 2,000,000 and SP 5,000,000 are not taken (decision 10). |
| Start spawns, gate | ShardManager table 0x781b88 (READ, this package) | READ |
| Music | none pushed by select or create | READ; the intro's track carries over |

### The creatable catalogue: the one definition (round 682)

Round 682's server (`refdata.CreatableExtractor`, `cmd/export-refdata -mode chargen`) and round
683's client (`frontend/char_catalog.gd`) implement **this** rule and nothing else. Columns are
0-based indices into a tab-split textdata row; column 0 is the Service flag.

**Input.** Every `characterdata_*.txt` part named by `characterdata.txt` and every
`itemdata_*.txt` part named by `itemdata.txt` (Media.pk2 `server_dep\silkroad\textdata\`), each
in its index file's order. Rows are UTF-16; blank lines and lines starting `//` are skipped; a row
whose column 1 is not an integer is skipped. **The last definition of an id wins** (the China bodies
1908-1932 appear in two parts, MEASURED).

**A body** is a characterdata row with
- column 0 (Service) = 1,
- column 9 (TypeID1) = 1 and column 10 (TypeID2) = 1 (a player character: the same test the
  ShardManager's create makes on the model).

Its race is column 14 (Country: 0 China, 1 Europe) and its sex column 58 (1 man, 0 woman;
MEASURED: 1 on all 26 `_MAN_` rows, 0 on all 26 `_WOMAN_`). Do not read the sex from the code name.

**An item** is an itemdata row with
- column 0 (Service) = 1,
- column 9 (TypeID1) = 3 and column 10 (TypeID2) = 1 (equipment),
- column 2 (CodeName) ending `_A_DEF`.

Its race is column 14 (0 China, 1 Europe, 3 either), its sex column 58 (ReqGender: 1 man, 0 woman,
2 either). Its piece: TypeID3 (column 11) 6 a weapon, 4 a shield; otherwise TypeID4 (column 12) 3
chest, 4 legs, 6 feet. Its armour class is TypeID3 (China 1 garment / 2 protector / 3 armour,
Europe 9 robe / 10 light / 11 heavy). A weapon is a bow when TypeID4 = 6 (China) and a crossbow
when TypeID4 = 12 (Europe); one-handed when column 93 (TwoHanded) = 0.

**Not in the catalogue, but in the server's CSV:** the two ammunition rows by code name,
`ITEM_ETC_AMMO_ARROW_01_DEF` and `ITEM_ETC_AMMO_BOLT_01_DEF` (READ, ShardManager strings), with
their MaxStack (column 57). The client does not need them.

**MEASURED 2026-10-02 on the box's vSRO archive:** 52 bodies (26 China, 26 Europe) and 52 items
(24 China: 5 weapons, 18 armour, 1 shield; 28 Europe: 9 weapons, 18 armour, 1 shield) = **104**,
plus the 2 ammunition rows (3655 arrows, 10885 bolts, MaxStack 2500 each). The ids are section 4's.

**The server's CSV** (`-chargen-csv`): header `ID,Code,Kind,Country,Sex,TypeID1,TypeID2,TypeID3,
TypeID4,TwoHanded,MaxStack`, Kind `model` / `item` / `ammo`, catalogue rows by id then the
ammunition. The client never reads it: it applies the rule to its own archive.

**The EXTERNAL OPENs are closed** (round 692). The user approved the export (2026-10-02, "yes ct
104"); the four tables and six procedures are in `/opt/sro-files/db/csv/charsel/` on the render
box (nothing entered the repo), and CT 104 is stopped again.

## 7. The implementation, in rounds

Four lanes after one shared contract round. None edits another lane's files. The contract is the
packet fields and three small client classes.

### Round 0 (server/protocol lane, first, small): the contract

**Done in round 682** together with S1-S3 (lane `lobby682`): the codecs, the golden file, the
catalogue rule above (server half), the schema (`ref_obj_id`, `scale`, `deleted_at`, `start_zone`,
`start_x/y/z`; existing rows to 1909/1923 at 0x22), create / list / name check / delete / restore /
purge / Start, and today's two screens moved onto it. See WORLD_ISSUES round 682.

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

**Lane A <-> lane B handoff (round 684, OURS; the one contract between select and customize).**
Kept minimal. `client/scripts/frontend/charselect_handoff.gd`, class `CharSelectHandoff`, holds
static state that survives the scene change, as retail's `DAT_00ec2d68` global does:

| Static | Meaning |
|---|---|
| `race: int` | `CharCatalog.RACE_CHINA` (0) or `RACE_EUROPE` (1); -1 when none was chosen (create opened directly: create picks its own default). |
| `day_phase: float` | the title's random hour, carried (no front-end screen picks its own, READ); -1 unknown. |
| `theme: FrontEndTheme` | the branding Login resolved; null when none. |
| `came_from: int` | `FROM_CREATE_OK` (0) / `FROM_CREATE_CANCEL` (10), READ: the previous-process ids the create screens write; `FROM_OTHER` (-1) otherwise. |

- **Select -> create.** An idol click emits `CharacterSelect.race_chosen(race)` (the same race
  values), plays the READ fly and 1.0 s fade to black, then calls
  `CharSelectHandoff.go_create(get_tree(), race)`: it sets `race` and changes scene to
  `res://scenes/CharacterCreate.tscn`.
- **Create reads** `CharSelectHandoff.race` in `_ready`. Retail's own index is NOT this value:
  `DAT_00ec2d68` is 0 for the Europe idol and 1 for China (READ 0x85ca10 and vslot_012 case 9: index
  0 flies to Europe's (168.5, -34.9, 639.1) and switches to the process at `DAT_00eed8d4`).
  `race_from_idol_index` translates; nothing else needs the retail index.
- **Create -> select.** Create leaves with `CharSelectHandoff.back_to_select(get_tree(), created)`,
  true after the server's OK, false on Cancel. Select runs its list intro either way (READ: previous
  id 0 or 10).
- Nothing else is shared: create builds its own backdrop (98/168 or 105/79) and its own
  `CharacterAppearance`.

**Tests:** headless math tests (placement k/(r+1) and k/5, the camera keys, the countdown text and
gauge, the sort order). `SRREVAMP_QA_FAKECHARS` is extended with model, scale, items and a pending
deletion. Renders on the box, batched in one `--shots` run. `perf_gate.sh` (it draws the world).

### Lane B, client customize (rounds B1-B3)

**Files:** `client/scripts/CharacterCreate.gd`, `scenes/CharacterCreate.tscn`, new
`client/scripts/frontend/charcreate_*.gd`, and **`client/scripts/ui/character_appearance.gd`** (new;
`CharacterPreview` becomes a thin user of it).

**B1: `CharacterAppearance`** (done, round 683)
- `build(ref_obj_id, scale, items: Array[{id, plus}]) -> Node3D`: the body from characterdata, the
  items in their slots, Height's uniform scale (READ).
- Volume's bone groups are READ (section 2) and applied.
- Used by lanes A and W.

**B2:** the China and Europe screens from their layouts:
- name and the name check (action 4);
- sex, Figure 1..13, Height and Volume 0..4 (scale nibbles), Protector and Weapon with Europe's
  restrictions, the tooltips 61/62 by text key;
- Confirm, box 13, create (action 1), the error texts, return to select.

**Round 685 built B2 and B3** (`CharacterCreate.gd` with `frontend/charcreate_model.gd`,
`charcreate_view.gd`, `charcreate_preview.gd`, `charcreate_slider.gd`; WORLD_ISSUES round 685). It
reads `CharSelectHandoff.race` and leaves through `CharSelectHandoff.back_to_select` (the contract
above); `SRREVAMP_QA_CREATE_RACE` stands in for the race select until lane A's merges.

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
   that items are the `_A_DEF` defaults (READ; this package's `_AddNewChar` checks none either,
   READ round 692). The user's default (round 682): accept only the 104-id catalogue, which
   `_RefCharGen` now confirms id for id.
8. ~~**Running the shard DB container** (CT 104) once to export the tables and read the
   procedures~~ -- **done** (the user: "yes ct 104", 2026-10-02; read in round 692).
9. **China's Protector minimum** (a per-server flag, meaning OPEN): require a set (Europe's rule),
   or allow "none" (Protector 0) as a server may?
10. **The procedure's gold and skill points** (round 692): this shard's `_AddNewChar` starts a
    character with 2,000,000 gold and 5,000,000 SP. srrevamp keeps its own 1,000 gold and 0 SP
    (OURS) because that INSERT is the one the shard's operator edited (a level-110 variant sits
    commented out beside it), so these read as the shard's generosity, not retail's. Take them,
    keep ours, or pick another?
11. **The shard's starting kit edit** (round 692): this `_AddNewChar` upgrades the chosen `_A_DEF`
    set to an `_A_RARE` set with hands, hat, shoulders and jewellery, and grants nine more items
    (`_RoyalAddItems`). srrevamp gives the chosen `_A_DEF` items, as the ShardManager passes them
    (READ). Recommended (OURS): keep it so; the edit is marked as the operator's.
12. **Europe's tutorial quest at create** (round 692): the shard's table gives Europe no Race 1
    quest, though the archive has `QTUTORIAL_EU` (id 210). srrevamp follows the table (Europe gets
    the two Race 3 quests only). Add `QTUTORIAL_EU` for Europe as China's tutorial is given to
    China (OURS, by symmetry), or keep the table?

## 9. Still OPEN

- Where the client's creatable-id list (0xeedf08) comes from (INFERRED `_RefCharGen`, which the
  ShardManager loads; its 104 ids are exactly the MEASURED rule's, round 692).
- What vslot 0x34 reads (INFERRED: a woman), which picks the Volume table and the harp's `_f`.
- Whether an avatar hides the armour under it (`FUN_00a60ef0`). What is READ (round 683 review):
  `textdata\charactervisualchange.txt` gives each visual a Slot bit mask (helm 0x0801, mail 0x0002,
  shoulder 0x0004, gauntlet 0x0008, pants 0x0010, boots 0x0020, weapon 0x0040, hair 0x0800), an
  OverlapSlot, a group and a Priority (armour 250, avatars 60-110); `CObjCharacter::FUN_00a5fe00`
  ORs `Slot & ~OverlapSlot` into +0x174 and `FUN_00a5da10` / `FUN_00a611e0` arbitrate the visuals
  by it. The arbitration itself is not modelled.
- ~~What keeps the body's own pieces from showing through worn ones, if anything does.~~
  **READ in round 687** (the round 683 review looked at the visual-change masks and found nothing;
  the rule is in the `.bsr` files instead): every body and item `.bsr` ends with an attachable
  block (BSR_FORMAT.md, "The attachable block"). The body's block maps each piece key (0 hair,
  1 face, 2/3 torso, 5/6 arms, 11 pelvis, 12 thigh, 13 calf, MEASURED) to one of its meshes; an
  item's block lists the keys it covers, and with flag 1 the client switches those body meshes off
  when it attaches the item (`CCompChar::FUN_00c1f790`) and re-derives them when a part comes off
  (`FUN_00c1f890`). `CharacterAppearance`, the create preview (`CharacterPreview`) and the world now do the same: the worst show-through went from
  21.30 % to 5.58 % of an armour's pixels (WORLD_ISSUES round 687). What is left is body pieces no
  worn item lists, which the client draws too.
- The weight half of the missing-palette-bone rule (`ResObject::FUN_00be2f80` leaves a missing
  bone's weight out of the sum; this client models only the entry, round 683).
- The name bitmap at 0x8c3cb0: **its source is READ (round 685)** -- 0x8c4a10 builds it from
  `textdata\abusefilter.txt` (Media.pk2 `server_dep\silkroad\textdata\`, named at 0x845f9c's
  caller), whose `#ALLOW_ID_TABLE <from> <to>` rows give the allowed ranges of one of six language
  columns (MEASURED: column 5, offsets 24..26, allows 0-9, A-Z, `_`, a-z; column 6 adds Latin-1);
  the rest of the 65,536 bits is the refused set, and the same file feeds the two word lists
  (+0x2018, +0x2048). **Which column the English client reads is OPEN** (the filter's +0x14, from
  its constructor 0x8c46a0's argument, GlobalDataManager +0x858). The server's forbidden-word list
  (session.LobbyNameCode: "no such list was found in the archives") may be this file: OPEN.
- ~~The deletion delay in `_DeleteCharTemporal`.~~ READ round 692: 7 days, the ShardManager's
  timer, guarded at 6 days 23 hours by `_DeleteCharPermanently` (section 2).
- (round 692) `_DeleteCharPermanently_NoTX`, `_KeepDelCharName`, `_FN_ADD_INITIAL_EQUIP` and
  `_GetObjCountry` were not exported: whether a purged character's name is freed or kept, what
  the ammunition's 250 is (INFERRED the count), and the Race mapping (INFERRED 0 China, 1 Europe).
- (round 692) The DB collation, so whether `_IsExistingCharName`'s `=` ignores case (INFERRED yes).
- (round 692) When the higher-level default quests (RequiredLevel 5..60) are given, and Europe's
  `QTUTORIAL_EU` (decision 12); whether every default code is in the shard's `_RefQuest` (some are
  not in `questdata.txt`).
- (round 692's review) **Two sources for the race masteries.** Round 692 seeds each new character's
  level-0 mastery rows from `_RefCharDefault_SkillMastery` (the export, through
  `-chardefaults-dir`); lane euroskill691's `skill/race.go` (uncommitted when 692 was reviewed)
  hard-codes the same 13 ids and derives which masteries a character holds from its Country. They
  agree today (MEASURED: the same ids). **The seeded rows are the authority** -- they are what
  `_AddNewChar` writes and what the game server's mastery map is loaded from -- and the hard-coded
  list must stay equal to the export until 691's code reads the seeded rows instead (recommended,
  once characters made before round 692 have been backfilled or are gone).
- (round 692) What `_CharQuest.Status` 1 means (INFERRED: in progress).
- Restore's u8 vs u16 error code.
- 0xB007 action 6.
- The academy byte in the list.
- The select idle's animation (the preview's is READ, round 685).
- The lizard's root motion.
- `FUN_00bbda70(1)` on select open.
- Re-entering select after create when the previous-process id is neither 0 nor 10.
- The per-server flag behind China's Protector minimum.
- Europe women 12/13's order.
