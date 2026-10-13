# Plus glows and seal effects on equipment (round 786)

The user (2026-10-13), wearing the Test Items NPC's gear (Seal of Nova, +12, full blue): "I don't see
any Seal effects or + glows".

This file is the reading behind round 786's answer. The mechanism itself was read and built in rounds
733-746 and 764; `weapon_glow.md` holds that reading in full (the tables' columns, the glow pass's
render states, the particle attach, the crowd path). This file adds what round 786 READ and MEASURED
about **which items get them**, and why the Test Items gear got none.

Labels: **READ** (`sro_client.exe`, the decomp dump `/var/tmp/decomp_client` on the render box,
address given), **MEASURED** (the box's archives in `/opt/sro-files/client/`, counted there),
**INFERRED**, **OURS**, **OPEN**. No game data is in this file or the repository.

## 0. The answer in brief

- **The user's gear was the LOCKED Seal of Nova rows, and the original draws nothing for them.**
  Until the Test Items lane's change (below), the NPC sold the plain `ITEM_(CH|EU)_*_11_A_RARE`
  rows (round 783, `test_items_npc.md`). In this archive every one of them carries the
  description `SN_ITEM_LOCKED_TT_DESC`, "Locked Item". Not one of them has a row in any of the
  three tables the glow and the effects come from (MEASURED, §2). So the original client, given a
  +12 locked sword, draws a plain sword: no glow and no seal effect. OpenSRO did the same.
- **The UNLOCKED twins (`..._11_A_RARE_ACTIVE`, "Unlocked Item") carry both** (MEASURED, §2):
  - a glow type, so a coloured glow from +3 up (+12: yellow to gold, `option_texture20.ddj`);
  - three Nova effect files from `itemrare.txt`, at every plus, +0 included;
  - the +8..+100 sparkle from `itemoptionefp.txt`.

  OpenSRO draws all of it already, for the player and for other players (rounds 734-746), and on
  the crowd's ghosts (round 764). Round 786 checked this live (§5).
- **Armour never glows and has no seal effect** (READ, §3). Only the weapon and the shield do. No
  armour piece, locked or unlocked, is in any of the three tables (MEASURED).
- **"Is this piece sealed?" is not asked.** The draw's only inputs are the item's RefID and its
  plus (READ, `FUN_00a5f3e0`). A piece shows a seal effect when its own code name has
  `itemrare.txt` rows. Each piece counts on its own: no Rarity, ItemClass, set or piece count is
  read on this path.
- **Nothing is changed in the server.** The plus of other players' gear is in the spawn and in
  every equip change, and your own gear's plus is in the equipment list (§4).

**The goods, since the Test Items lane's change.** That lane switched the NPC to the
`_A_RARE_ACTIVE` rows ("Make all the items level 101, not 111", merged to `dev` as 9ec9f3a7,
`test_items_npc.md`). This lane did not touch the goods list. A piece bought from now on is an
unlocked row and glows at +12 with its Nova effects, as §5's runs show for the same ids. A piece
bought before stays a locked row and stays plain: it is a different item id, and the original
draws nothing for it.

## 1. The mechanism, in one paragraph (READ; `weapon_glow.md` §2)

`CObjCharacter::FUN_00a60a90(slot)` (0xa60a90) acts only on attachments of kind 1, the weapon and
the shield (`if (iStack_40 == 1)`, then two `FUN_00a5f3e0` calls). `FUN_00a5f3e0(attach, refId,
part, plus)` (0xa5f3e0) does two things:
- If `plus != 0`, it asks `FUN_00a93900(refId, plus)` (0xa93900) for the glow row. That function
  returns the row with the highest threshold ≤ plus, of the item's type in
  `DAT_0110ac80`/`DAT_0110ac8c`. The row goes to the compound's vtable +0xc8 (`CCompChar::FUN_00c350a0`).
  That makes a `CRTModProgEquipPow` on the item's own draw.
- Whatever the plus, it walks the item's particle list `FUN_00a93a80(refId)` (`DAT_0110ac98`). It
  attaches each row with min ≤ plus ≤ max through vtable +0xcc (`CCompChar::FUN_00c30c20`), at the
  row's bone and scale.

The maps are filled at start-up by `Client_LoadAllRefData` (0x844cd0). It calls `FUN_00a9f2e0`
(`resinfo\itemoption.txt` and `itemtypenumber.txt`), then `FUN_00aa0270` twice:
`resinfo\itemrare.txt` (0xdd30f8), then `resinfo\itemoptionefp.txt` (0xdd30dc).

Round 786 re-checked in the dump that nothing else makes the glow:
- The mod is kind `0x70000`. `FxModManager::FUN_00c797f0` builds a mod by kind (`switch (kind >>
  16)`), and its case 7 calls `FUN_00c793b0`, the one caller of the `CRTModProgEquipPow`
  constructor `FUN_00c847f0`.
- The only call that asks for a new kind-`0x70000` mod is `FUN_00c0b460(0x70000)` in
  `CCompChar::FUN_00c350a0` (0xc350a0). Its only direct caller is `CCompChar::FUN_00c2b260`, which
  calls it after a `FUN_00c1f720(part)` check. `weapon_glow.md` §2.1 names the vtable +0xc8 slot
  `FUN_00c350a0`; the slot may hold the wrapper instead (INFERRED). Either way, the glow is made
  only on this path.

## 2. Which items: the Test Items NPC's 94 Seal of Nova goods against their twins (MEASURED)

The box's `Media.pk2`: the 63 `itemdata_*.txt` parts, Service 1 rows; the four `resinfo` tables
(byte-identical to round 740's extract, `cmp`). `/var/tmp/glow/keep/census.py` on the box reads
them. Run it there; its output is not committed.

| Goods (ItemClass 31, Rarity 2) | Count | Glow type (`itemoption.txt`) | Seal rows (`itemrare.txt`) | +8 rows (`itemoptionefp.txt`) |
|---|---|---|---|---|
| locked weapons and shields `*_11_A_RARE` | 16 | none | none | none |
| their `*_11_A_RARE_ACTIVE` twins | 16 | 1, 2, 3 or 4 each | 3 each (Nova) | 1 each, +8..+100 |
| locked accessories | 6 | none | none | none |
| locked armour (`(CH\|EU)_(M\|W)_(HEAVY\|LIGHT\|CLOTHES)_11_xx_A_RARE`) | 72 | none | none | none |
| their `_ACTIVE` twins (accessories, armour) | 78 | none | none | none |

Over the 94 pairs, the two rows differ only in these columns (MEASURED, compared as numbers, so
`127` and `127.0` count as the same):
- the id;
- the code name;
- the OrgObjCodeName: the armour's opposite-gender twin, in its own form;
- the description key;
- the required levels: 111 locked against 101 unlocked, in col 34 and, for 24 European armour
  pieces, cols 36/38/40;
- and the rounding of four stat cells.

Model, textures, Rarity and ItemClass are the same. For example:

| | Locked (`ITEM_CH_SWORD_11_A_RARE`, 4044) | Unlocked (`ITEM_CH_SWORD_11_A_RARE_ACTIVE`, 62605) |
|---|---|---|
| Description key (col 7) | `SN_ITEM_LOCKED_TT_DESC`: "Locked Item", "Model: Default (11D)", "Glow: Default" | `SN_ITEM_UNLOCKED_TT_DESC`: "Unlocked Item", "Model: Default", "Glow: Default" |
| ReqLevel1 (col 34) | 111 | 101 |
| Model (col 53), texture (col 55), Rarity, ItemClass | `item\china\weapon\sword_11.bsr`, `sword_11.ddj`, 2, 31 | the same |

The `_ACTIVE` rows and the locked/unlocked descriptions look like the operator's own addition, not
retail iSRO's (INFERRED). The archive is the authority either way: this client and this archive draw no glow on
a locked row. The tooltip's "Glow: Default" on a locked row disagrees with the tables. Only the
tables decide what is drawn (READ, §1).

The unlocked weapons and shields (MEASURED; scale is col 3, read as /100):

| Item (`_11_A_RARE_ACTIVE`) | Glow type | Seal files (`itemrare.txt`), scale, bone | +8 file (`itemoptionefp.txt`), scale, bone |
|---|---|---|---|
| CH sword, spear | 3 | `eternity_11_nova_01/02/03.efp`, 175 / 230, `ai_end` | `system_enchant_a_01.efp`, same, `ai_end` |
| CH blade, glaive (tblade) | 1 | `eternity_11_nova_01/02/03`, 250 / 310, `ai_end` | `system_enchant_b_01.efp`, `ai_start` |
| CH bow | 1 | `eternity_11_nova_bow_01/02/03`, 190, `Bone01` | `system_enchantbow_a_01.efp`, `Bone01` |
| CH shield | 1 | `eternity_11_nova_shield_01/02/03`, 143, `Bone01` | `system_enchantshield_a_01.efp`, `Bone01` |
| EU sword, dagger | 1 | `eternity_11_nova_01/02/03`, 185 / 90, `ai_end` | `system_enchant_a_01`, 180 / 90, `ai_end` |
| EU two-hand sword, two-hand staff (tsword, tstaff) | 4 | `eternity_11_nova_01/02/03`, 230 / 200, `ai_end` | `system_enchant_b_01`, 230 / 190, `ai_start` |
| EU axe | 1 | `eternity_11_nova_bow_01/02/03`, 95, `Bone03` | `system_enchantbow_a_01`, `Bone03` |
| EU crossbow | 2 | `eternity_11_nova_bow_01/02/03`, 105, `ai_end` | `system_enchantbow_a_01`, `ai_end` |
| EU dark staff, staff (darkstaff, staff) | 4 | `eternity_11_nova_01/02/03`, 75 / 90, `Bone03` | `system_enchantstaff_a_01`, `Bone03` |
| EU harp | 4 | `eternity_11_nova_shield_01/02/03`, 90, `Bone03` | `system_enchantharp_a_01`, 100, `Bone03` |
| EU shield | 3 | `eternity_11_nova_shield_01/02/03`, 135, `Bone01` | `system_enchantshield_a_01`, `Bone01` |

The weapon and shield `ITEM_EVENT_*_11_A_RARE` copies take their Org item's type and list (READ,
`weapon_glow.md` §1.4). Their Org is the locked row (MEASURED, e.g. `ITEM_EVENT_CH_SWORD_11_A_RARE`
and `ITEM_EVENT_CH_SHIELD_11_A_RARE`), so they get nothing either.

## 3. Which parts glow (READ)

- **The weapon and the shield only.** The gate is `FUN_00a60a90`'s `iStack_40 == 1`, the attachment
  kind of a held item (above, READ). Armour pieces are dressed as the body's own parts, not as
  attachments of kind 1, so they never reach `FUN_00a5f3e0` (INFERRED: the armour's install path
  was not traced here).
- Both loaders' OrgObjCodeName walk passes only weapons (TypeID3 6) and shields (TypeID3 4,
  TypeID4 1 or 2) (READ, `weapon_glow.md` §1.4).
- No armour code is in any of the three tables (MEASURED: 0 rows naming `HEAVY`, `LIGHT`,
  `CLOTHES`, `RING`, `EARRING` or `NECKLACE`).
- The **set effect** is a different thing: `ITEM_SETITEM_ACTIVE` / `_DEACTIVE` with
  `snd_setitem_active` in the 0x3038 handler `FUN_008a9260` (0x8a9260, flags at `+0x1a1`/`+0x1a2` of
  the character's record). By its name it is for set items, not for Seal of Nova (INFERRED). Not
  traced here (OPEN, §6).

**How it is attached** (READ, `weapon_glow.md` §2):
- The glow is a render mod on the item's own draw: no extra mesh and no extra draw call. It is an
  option texture scrolled at `uv × 50` units a second, tinted by a colour pulsing between the row's
  two colours, added to the item's own texture, unlit.
- The effects are `.efp` files placed in the frame of the named item bone (`ai_end`, `ai_start`,
  `Bone01`, `Bone03`), rotation included, at the row's scale.

**The art** (MEASURED on the box; listed, never committed):

| File | Archive | Size | Format | Used by |
|---|---|---|---|---|
| `Prim\Mtrl\itemoption\option_texture13.ddj` | Data.pk2 | 65,684 B | JMXVDDJ 1, 256 × 256 DXT3, no mips | +3, +5, +8 |
| `option_texture14.ddj` | Data.pk2 | 65,684 B | 256 × 256 DXT3, no mips | +6, +9 (types 2-4) |
| `option_texture20.ddj` | Data.pk2 | 65,684 B | 256 × 256 DXT3, no mips | +7, +9 (type 1), +10 … **+12**, +13 |
| `eternity99.ddj` | Data.pk2 | 1,398,276 B | 1024 × 1024 DXT3, 11 mips | +14 |
| `system\eternity_11_nova_01/02/03.efp` | Particles.pk2 | 32,339 / 23,863 / 33,246 B | EFP | Nova melee and staves |
| `system\eternity_11_nova_bow_01/02/03.efp` | Particles.pk2 | 25,144 / 46,378 / 251,877 B | EFP | Nova bow, crossbow, axe |
| `system\eternity_11_nova_shield_01/02/03.efp` | Particles.pk2 | 24,757 / 35,883 / 148,258 B | EFP | Nova shield, harp |
| `system\system_enchant_a_01.efp`, `_b_01` | Particles.pk2 | 36,387 B each | EFP | the +8 sparkle |
| `system\system_enchantbow_a_01`, `shield_a_01`, `staff_a_01`, `harp_a_01` | Particles.pk2 | 36,518 / 58,142 / 95,072 / 58,058 B | EFP | the +8 sparkle |

`eternity_11_nova_04.efp` (13,598 B) is in the archive but no table row names it (MEASURED).

**The +12 row** (`itemtypenumber.txt`, the same for types 1-4 except the scroll's sign and the
alpha-test flag; MEASURED): `option_texture20.ddj`, MODULATE2X then ADD, (1.000, 1.000, 0.000) to
(1.000, 0.800, 0.000) over 1,000 ms each way, scroll (0, ∓0.005) a step.

## 4. The plus on the wire (READ; OpenSRO checked)

| Whose | Retail (READ) | OpenSRO (checked this round) |
|---|---|---|
| Another player on spawn, `0x3015` | `GlobalDataManager::FUN_009de2f0` (0x9de2f0): u8 inventory size, u8 count, then per item u32 RefItemID and, when the type word passes `!(w & 2) && (b & 0x1c) == 0xc && (b & 0x60) == 0x20` (equipment), **u8 plus**. The server writes OptLevel + the advanced elixir (`CInstanceItem::vslot_010` 0x42e230 mode 2). | The entity snapshot's pluses tail (round 735, OURS framing): `session/world.go` `appendPluses`, from `equippedItems` → `equipment.Equipped.EffectivePlus()` (OptLevel + AdvElixir). `TestEntityEnteredPlusesTail`, `TestResultsPlusesTail`, `TestEquippedItemsCarryEffectivePlus`. |
| Another player's equip change, `0x3038` / `0x3039` | `FUN_008a9260` (0x8a9260): u32 uid, u8 slot, u32 RefItemID, u8 plus for equipment; `0x3039` (`FUN_008a9560`) has no plus. | Retail `0x3038`/`0x3039` to the observers (round 735, `session/equip_broadcast.go`). |
| Your own gear | The item record's `+0x8c` byte, OptLevel + elixir (round 734, `CICPlayer::vslot_025` 0x9d9a80 → `FUN_008ba570`). | The equipment list's instance block (round 732), `ItemInstance.effective_plus()`, `World3D._player_pluses`. |

A Test Items good bought +12 (round 786's `session/testshopgear.go`) is an ordinary instance with
OptLevel 12. Equipped, it travels on the same paths. The live run (§5) shows the plus arriving for both
characters. **No server change was needed.**

## 5. What round 786 checked live (MEASURED)

The render box, `/var/tmp/glow/live.sh` (the in-memory server from this tree; two clients):
- **Main client (rendered):** a china_man at the Test Items spot (Jangan, 1070, 950). He gives
  himself the unlocked Nova set at +12 with the GM's `/give <id> 1 12` and puts it on through the
  real equip messages (`OPENSRO_QA_EQUIP_BAG`, new, OURS, QA only).
- **Second client (headless):** another player beside him, in an unlocked blade +12 with the
  locked shield and armour +12.

What the runs showed (MEASURED, the logs and frames on the box):
- **Your own gear.** Each `/give <id> 1 12` made an instance at OptLevel 12, and each equip came
  back as a `0x3038 ... plus 12`. The body was rebuilt with
  `glow: ITEM_CH_SWORD_11_A_RARE_ACTIVE +12 (row +12, 4 effect(s)), ITEM_CH_SHIELD_11_A_RARE_ACTIVE
  +12 (row +12, 4 effect(s))`. Four effects means three Nova files and the +8 sparkle. The frames
  show the yellow-gold +12 glow on the sword and the shield and the blue-white Nova effects around
  them.
- **Leaving and entering the world again** (`--reconnect`, the login path): the body was built
  from the equipment list at entry with the same glow and effects.
- **Another player.** GlowTwo dressed before QaTester arrived beside him (both by GM `/tp`), so his
  gear and its +12 reached QaTester in the arrival list's pluses tail, not in a `0x3038`.
  QaTester's frames show GlowTwo's unlocked blade with the +12 glow and the Nova effects. His
  locked shield and armour are plain.
- **The locked row, in the second client's own build:** `CharacterAppearance:
  ITEM_CH_SHIELD_11_A_RARE +12: no glow (no glow type in itemoption.txt) and no particle row
  (itemrare.txt, itemoptionefp.txt) -- the original draws nothing for it` (the log line round 786
  adds).
- **The locked shield and armour need level 111 to wear** (the second client was refused them at
  level 110 and took them at 120). The unlocked rows need 101 (§2).

**A bug found on the way (MEASURED, fixed).** The offline render of the same +12 set showed the
glow but no particle. `EquipFx.driver_for` makes the particle driver with `vp.add_child(nd)`:
- A QA run boots World3D as the main scene and dresses the player in World3D's own `_ready`. The
  root viewport is then still readying its children, so the call failed ("Parent node is busy
  setting up children").
- The driver was kept in the viewport's meta anyway and never entered the tree. No weapon or
  shield particle showed for the rest of the run, the lineup's other-player bodies included.

Real play goes Boot → Login → select → world through scene changes, so the root is ready long
before. A server run dresses after its equipment reply, which is after `_ready`. INFERRED: real
play did not hit this. Every offline QA render that dressed the player with particle rows did: for
example `OPENSRO_QA_EQUIP` with a seal or +8 weapon, and possibly perf runs that used such an
`--env` (round 746's "player's own Nova spear" row). Those runs measured no particles.

A viewport in the tree that is not yet ready now takes the driver deferred.
`item_glow_seal786_test.gd` fails on the old code. The offline render after the fix shows the Nova
effects (§5's keep files).

Kept on the box in `/var/tmp/glow/keep/`, with the run scripts (`live.sh`, `live_rc.sh`,
`offline.sh`, `offline2.sh`, `census.py`):

| File | What |
|---|---|
| `offline_unlocked_nova_plus12_f590.png` | Offline, at the Test Items spot (97/168, 1070, 950): the player in the unlocked set +12, with glow and Nova effects. Two other-player bodies to the right: one in the unlocked set at +0 (Nova effects, no glow), one in the locked set at +12 (neither). |
| `offline_before_driver_fix_f590.png` | The same scene before the driver fix: glow, no particle. |
| `live_two_players_f640.png`, `_f690.png` | Live, two clients: GlowTwo (left: unlocked blade +12, locked shield and armour +12) and QaTester (right: unlocked set +12). |
| `live_before_reentry_f540.png`, `live_after_reentry_f1290.png` | Live, QaTester before leaving the world and after entering it again. |

The results and the gates are in `docs/WORLD_ISSUES.md`, "Round 786 (part): plus glows and seal
effects on equipment".

## 6. OPEN

- **Locked gear already bought.** The user's earlier purchases are locked rows (ids such as
  4044), and they stay plain. Nothing in this archive turns a locked row into its unlocked twin.
  The operator's own unlock step, if there is one, is not in `sro_client.exe` or the tables. Buying
  the piece again from the NPC (now the unlocked rows) gives the glowing one.
- **`vsroplus_lib.dll`.** The client folder holds this 13 MB DLL beside `sro_client.exe`. It names
  none of `itemoption`, `itemrare`, `glow`, `_ACTIVE`, `LOCKED` or `nova` in plain ASCII or UTF-16
  (MEASURED, `strings`), so it may be packed. Whether it changes how locked items are drawn on the
  operator's own client is not READ. OpenSRO follows `sro_client.exe` and the archive.
- **The set effect** (`ITEM_SETITEM_ACTIVE`, §3): what sets `+0x1a1`/`+0x1a2` and which effect file
  plays are not traced. OpenSRO does not play it.
- Still open from `weapon_glow.md` §8: the two compound parts `FUN_00a60a90` passes (OPEN 4), the
  glow gate `FUN_00c43780` (OPEN 6), three flag-word bits (OPEN 8), and the Options window's
  "Effect quality" (OPEN 11).
