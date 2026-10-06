# Weapon and shield glows (round 733, spec)

The user (2026-10-05): "Let's add weapon glows. Basically there different glows for item +3, +5, +7,
etc and also different particle effects for seal of star, moon, sun, nova, and maybe others. The only
applies to weapons and shields of course. Check client and server code / db and let's fully support
it."

Labels: **READ** (sro_client.exe, address given), **MEASURED** (the retail archives in
`/opt/sro-files/client/`, counted on the render box), **INFERRED**, **OPEN**, **OURS**. No game data
is in this file. The numbers below are findings that name what the archives hold; the client reads the
tables at runtime.

## 0. The answer in brief

- There are **two effects**, both chosen by the item's plus (OptLevel), not by its seal:
  1. **The glow** is a render mod, `CRTModProgEquipPow`. It adds a scrolling option texture, tinted
     by a colour that pulses between two colours, to the weapon's own draw. It starts at **+3**.
     The tiers are +3, +5, +6, +7, +8, +9, +10, +11, +12, +13 and +14. +4 keeps the +3 look, and
     anything above +14 keeps the +14 look.
  2. **The particles** are an `.efp` attached to a bone of the weapon. Every row in
     `itemoptionefp.txt` runs from **+8** to +100.
- **Round 740 corrects round 733 here: the seal does choose particles.** The particle map is filled
  twice, first from **`resinfo\itemrare.txt`** and then from `itemoptionefp.txt` (READ, §1.5).
  `itemrare.txt` gives the seal items (`_A_RARE`, `_B_RARE`, `_C_RARE`, Nova `_A_RARE_ACTIVE`, the
  Egyptian sets) their own particle files, such as `system_raretype_a_step1/2/3.efp` and
  `eternity_11_nova_01..03.efp`. Its rows have no plus range, so they show **at every plus, +0
  included**. The glow type still goes with the kind and degree (§1.1). Round 733 measured only
  `itemoptionefp.txt` and missed `itemrare.txt`, whose name is not near the other two in the
  executable (0xdd30f8).
- **An item can inherit its glow type and particles from its OrgObjCodeName item** (READ, §1.4).
  On the box's archive this gives 480 `ITEM_EVENT_*` weapons and shields the type and the particle
  list of the item they copy (MEASURED, round 740).
- Retail sends the plus of other players' gear in the equip-change broadcast `0x3038` (READ). OpenSRO
  sends no plus for other players' gear, and does not broadcast equip changes (§5).

## 1. The tables (MEASURED; the loader READ)

`Client_LoadAllRefData` (0x844cd0) calls two loaders after the item table is loaded (READ, asm
0x84674b..0x84676e): `UI_ALCHEMYBOX::FUN_00a9f2e0()`, then `UI_ALCHEMYBOX::FUN_00aa0270(path)` twice,
with `"resinfo\itemrare.txt"` (0xdd30f8) and then `"resinfo\itemoptionefp.txt"` (0xdd30dc). They
fill three maps:

| Map | Key → value | Filled from |
|---|---|---|
| `DAT_0110ac80` | item RefID → type number | `FUN_00a9f2e0`: `Media.pk2 resinfo\itemoption.txt`, `codename<TAB>type_number`. The code name is resolved to a RefID through the item table. Then the OrgObjCodeName inheritance (§1.4). |
| `DAT_0110ac8c` | type number → vector of 0x4c-byte glow rows | `FUN_00a9f2e0`: `Media.pk2 resinfo\itemtypenumber.txt` |
| `DAT_0110ac98` | item RefID → pointer to a vector of 0x4c-byte particle rows | `FUN_00aa0270`, twice: `resinfo\itemrare.txt`, then `resinfo\itemoptionefp.txt` (§1.5); each call ends with the inheritance (§1.4) |

All four files are ASCII with CRLF line ends. `//` lines are comments. The comments in
`itemtypenumber.txt` and `itemoptionefp.txt` are EUC-KR.

### 1.1 `itemoption.txt`: which glow type an item uses (MEASURED)

There are 2,677 data lines. Type 1 has 1,029 items, type 2 has 448, type 3 has 518 and type 4 has
472. The file lists weapons and shields of every degree. Its section comments are `//_HONOR`,
`//ETERNITY - MODELSWITCH PLUS GLOW`, `NORMAL / NOVA / EGY A / EGY B` per race, then per weapon kind
(`CH - SHIELD/BOW/SWORD/BLADE/SPEAR/GLAIVE - 11`,
`EU - SHIELD/ONEHAND/TWOHAND/AXE/CROSSBOW/DAGGER/WIZSTAFF/CLERICROD/WARLOCKROD/HARP - 11`).

The type number goes with the item's kind and degree, not with its seal. For example:

| Base | Normal A/B/C | Seal `_A_RARE[_ACTIVE]` / `_B_RARE` / `_C_RARE` (and `_HONOR`) | `_SET_A_RARE` | `_SET_B_RARE` |
|---|---|---|---|---|
| CH_SWORD_11 | 3 | 3 | 1 | 1 |
| CH_SWORD_08 | 4 | 4 | — | — |
| CH_SHIELD_11 | 1 | 1 | 1 | 1 |
| CH_BOW_11 | 1 | 1 | 3 | 1 |
| EU_TSWORD_11 | 4 | 4 (`_LEGEND` 3) | 1 | 1 |

### 1.2 `itemtypenumber.txt`: the glow rows (MEASURED; the columns READ)

There are 44 rows: types 1 to 4, each with the tiers +3, +5, +6, +7, +8, +9, +10, +11, +12, +13 and
+14. The columns, as parsed at `0xa9f2e0` and stored in the row, are:

| Col | Field | Row offset | Read as |
|---|---|---|---|
| 1 | type number | (map key) | `atol` |
| 2 | plus threshold | +0x00 (byte) | `atol` |
| 3 | UV scroll `u,v` | +0x04 (vec2) | `FUN_00a76c50` |
| 4 | texture path | +0x0c (string) | |
| 5 | stage-0 colour op | +0x28 (byte) | `atol` |
| 6 | stage-1 colour op | +0x29 (byte) | `atol` |
| 7 | colour 1 `r,g,b` | +0x2c (vec3) | `FUN_00a76cf0` |
| 8 | colour 2 `r,g,b` | +0x38 (vec3) | `FUN_00a76cf0` |
| 9 | pulse period (ms) | +0x44 (u32) | `atol` |
| 10 | alpha-test flag | +0x48 (bool) | `atol != 0` |

The tiers. Every type has the same colours, ops and period at each tier.

| Plus | Texture (`prim\mtrl\itemoption\`) | Col 5 / 6 | Colour 1 → colour 2 | Period |
|---|---|---|---|---|
| +3 | `option_texture13.ddj` | 4 / 7 | (1.000, 1.000, 1.000) → (0.988, 1.000, 0.690): white to pale yellow | 1000 |
| +5 | `option_texture13.ddj` | 5 / 7 | (0.996, 0.173, 0.510) → (0.902, 0.122, 0.761): pink to magenta | 1000 |
| +6 | `option_texture14.ddj` | 5 / 7 | (0.992, 0.996, 0.510) → (0.831, 0.231, 0.000): yellow to orange | 1000 |
| +7 | `option_texture20.ddj` | 5 / 7 | (0.388, 0.502, 0.890) → (0.094, 0.580, 0.380): blue to teal | 1000 |
| +8 | `option_texture13.ddj` | 5 / 7 | (0.200, 1.000, 0.000) → (0.200, 0.700, 0): green | 1000 |
| +9 | `option_texture20.ddj` (type 1), `option_texture14.ddj` (types 2–4) | 5 / 7 | (0, 0.200, 1.000) → (0.300, 0.200, 0.800): blue to violet | 1000 |
| +10 | `option_texture20.ddj` | 5 / 7 | (0.471, 0.745, 0.129) → (0.000, 1.000, 1.000): lime to cyan | 1000 |
| +11 | `option_texture20.ddj` | 5 / 7 | (1.000, 0.000, 0.000) → (0.000, 0.000, 1.000): red to blue | 1000 |
| +12 | `option_texture20.ddj` | 5 / 7 | (1.000, 1.000, 0.000) → (1.000, 0.800, 0.000): yellow to gold | 1000 |
| +13 | `option_texture20.ddj` | 5 / **9** | (0.960, 0.300, 0.100) → (0.920, 0.800, 0.376): orange to sand | 1000 |
| +14 | `eternity99.ddj` | 5 / 7 | (1.000, 1.000, 0.000) → (0.306, 0.165, 0.518): yellow to purple | **700** |

The UV scroll and the alpha-test flag depend on the type number:

| Type | +3…+8 | +9…+12 | +13 | +14 | Flag |
|---|---|---|---|---|---|
| 1 | (0.005, −0.005) | (0, −0.005) | (0, −0.010) | (0.001, −0.009) | 0 |
| 2 | (0.005, −0.005) | (0, −0.005) | (0, −0.010) | (0.001, −0.009) | 1 |
| 3 | (0, 0.005) | (0, 0.005) | (0, 0.010) | (0.001, 0.009) | 0 |
| 4 | (0, 0.005) | (0, 0.005) | (0, 0.010) | (0.001, 0.009) | 1 |

There are no rows for +1, +2 or +4. All the textures are in `Data.pk2 Prim\Mtrl\itemoption\`
(MEASURED, 21 files). The folder also holds `option_texture.ddj`, `5`, `10`, `15`, `21`, `22`, `25`,
`42`, `100`, `111`, `200`, `christmas_texture9/10/11`, `halloween_texture11/910` and
`eternity98.ddj`, which no row names. They are unused by this table (MEASURED).

### 1.3 `itemoptionefp.txt`: the particle rows (MEASURED; the columns READ)

There are 2,546 lines. The columns are `codename, efp, scale, bone, offset, min_plus, max_plus, col8`.
The parser at `0xaa0622..` (in `FUN_00aa0270`, the particle loader; round 734 placed it inside
`FUN_00a9f2e0`, corrected in round 740) builds a 0x4c-byte entry:

| Col | Field | Entry offset | Read as |
|---|---|---|---|
| 1 | item code name | (map key, via RefID) | |
| 2 | efp path (`system\…efp`, in `Particles.pk2`) | string, INFERRED +0x10 (assigned first) | |
| 3 | scale | +0x00 float = `col3 / 100.0` | READ (`_DAT_00e1b7d8` = 100.0, MEASURED in `.rdata`) |
| 4 | bone name | string, INFERRED +0x2c | |
| 5 | offset `x,y,z` (`none` in every row) | +0x04 vec3, zero first | READ (`FUN_00a76cf0`) |
| 6 | min plus | +0x48 byte, 0 when the column is missing | READ |
| 7 | max plus | +0x49 byte, 0xFF when the column is missing | READ |
| 8 | values such as 80, 100, 130, 135 and 150 (header "1.3 100%") | **not read**: the loop takes seven tokens | READ |

Every row has min 8 and max 100. All 2,468 data rows say so. The bones are `ai_end` (833 rows),
`Bone03` (603), `ai_start` (573), `Bone01` (456) and `Bone02` (3). Scales run from 40 to 310. No code
name appears twice (MEASURED).

The particle files are counted below by category. Seal items are split by their code suffix, and the
tooltip lane's mapping (`item_tooltip.md` §2) names them: ItemClass ≥ 31 tier 0 is Nova, then Moon
and Sun; lower degrees are Star, Moon and Sun.

| Category | `enchant_a` | `enchant_b` | `enchantbow_a` | `enchantshield_a` | `enchantstaff_a` | `enchantharp_a` | `*_set_a_rare` / `*_set_b_rare` |
|---|---|---|---|---|---|---|---|
| normal (A/B/C) | 158 | 122 | 102 | 68 | 68 | 34 | — |
| `_A_RARE*` (Star / Nova) | 56 | 40 | 36 | 24 | 24 | 12 | — |
| `_B_RARE` (Moon) | 56 | 40 | 36 | 24 | 24 | 12 | — |
| `_C_RARE` (Sun) | 56 | 40 | 36 | 24 | 24 | 12 | — |
| `_SET_A_RARE` / `_SET_B_RARE` (Egy A/B) | 5 / 5 | 3 / 3 | 3 / 3 | 2 / 2 | 2 / 2 | 1 / 1 | — |
| `_SWITCHnn` (model switch) | 144 | 288 | 108 | 72 | 72 | 36 | 72+54+36+36+18 each for A and B |

The particle file goes with the weapon kind. Swords, blades, one-handers and the like use
`enchant_a`, which sits on `ai_end`. Spears, glaives and two-handers use `enchant_b`, on `ai_start`.
Bows and crossbows use `enchantbow_a`. Staves and rods use `enchantstaff_a`, on `Bone03`. Harps use
`enchantharp_a`, on `Bone03`. Shields use `enchantshield_a`, on `Bone01`.

Here is one degree's rows as an example (MEASURED). `ITEM_CH_SWORD_11_A`, `_B`, `_A_RARE_ACTIVE`,
`_B_RARE` and `_C_RARE` all have `system_enchant_a_01.efp`, scale 175, `ai_end`, +8..+100.
`_SET_A_RARE` has the same file at 185, and `_SET_B_RARE` at 215.

### 1.4 Inheritance through OrgObjCodeName (READ, round 740)

Round 734 implemented only the direct mapping: code name → RefID → value. Both loaders do more. Each
one begins by walking the item table (`FUN_00a9f2e0` 0xa9f388..0xa9f65a; `FUN_00aa0270` the same code
from 0xaa031f). `FUN_008cb810` returns `mgr+600`, a `std::map`; a node holds the RefID at +0xc and the
record at +0x10, and `FUN_00973420` returns the record's RefObjCommon block (+0x10, the block of
`characterdata.md`). For every item:

1. Its CodeName (+0x08) goes into a local map, code name → RefID (`FUN_004f1840`, an insert).
2. The type word (+0x00) is tested (asm 0xa9f45b..0xa9f4d7): `!(w & 2)` (not Bionic),
   `(b & 0x1c) == 0xc` (TypeID1 3), `(b & 0x60) == 0x20` (TypeID2 1), and either
   `(w & 0x780) == 0x300` (TypeID3 6, a weapon, any TypeID4) or `(w & 0x780) == 0x200` with
   `w >> 11` equal to 1 or 2 (TypeID3 4 with TypeID4 1 or 2, a shield).
3. If it passes and its OrgObjCodeName (+0x40) has a non-zero length (+0x54, `cmp [eax+0x14],ebx` at
   0xa9f4e7), the RefID is pushed onto a vector in a second local map, OrgObjCodeName → vector of
   RefIDs (`FUN_00a8f7b0` finds, `FUN_00a9f070` inserts an empty vector, `FUN_00451bd0` pushes). The
   wide reader stores `xxx` as "" (`characterdata.md`), so an Org of `xxx` joins no group.

Then the file is parsed (§1.1, §1.5). After it, the second map is walked in key order (a `std::map`
keyed by the wide string). Each key is looked up as a code name (`FUN_004f19f0`) to get a RefID, and
that RefID in the output map (`FUN_004522f0` on `DAT_0110ac80` at 0xa9f9d3; `FUN_00a8f680` on
`DAT_0110ac98`). If it has a value, every RefID of the vector that has none yet is inserted with that
value (`FUN_00452230` at 0xa9fb04; `FUN_00a8f5c0` at 0xaa0cf1). For the particles the value is the
base's **vector pointer**, so the member shares the base's list (see §1.5 for what that does).

What follows from it:
- A member that has a value of its own keeps it.
- A group whose name item has no value gives nothing.
- A group sees the values earlier groups gave out, so a chain (A's Org is B, B's Org is C) works only
  when B's group key sorts after C's. The archive has no chain (MEASURED below).

**Measured on the box's archive** (`/root/pk2/Media.pk2`, round 740; a replay of the loaders over the
extracted tables, and the client's own `ItemGlowTables.inherit` through `client/tools/glow_inherit_probe.gd`):

| What | Count |
|---|---|
| Item rows (the 63 parts `itemdata.txt` names, last definition of an id wins) | 15,338 |
| Code names shared by two rows (exactly, or ignoring case) | 0 |
| Weapons and shields in a group (Org not empty, the gate passed) | 496, in 496 groups |
| `itemoption.txt` rows, and those whose code name is not in the item table | 2,467, 194 (e.g. `ITEM_CH_SWORD_11_B`) |
| Items typed directly | 2,273 |
| **Items that gain a type through inheritance** | **480**: type 1 204, type 2 105, type 3 93, type 4 78 |
| … of them `ITEM_EVENT_*` | all 480 |
| Groups whose name item itself inherits (chains) | 0 |
| Items that gain a particle list (all at the `itemrare.txt` call) | 480, the same items |
| Service 0 rows' effect on any count | none (the counts are the same with Service 1 rows only) |

The examples the brief asked about:
- `ITEM_CH_SPEAR_11_A_RARE` (4116, Org `xxx`): no type, no group.
- `ITEM_CH_SPEAR_11_A_RARE_ACTIVE` (62607): type 3, directly.
- The 22 `ITEM_EVENT_*_11_A_RARE` rows are all rings, earrings and necklaces with Org `xxx`: none is a
  weapon or a shield, and none inherits.
- `ITEM_EVENT_CH_BOW_10_C_RARE` (25181, Org `ITEM_CH_BOW_10_C_RARE`): type 2 from its Org item; the
  same for `ITEM_EVENT_CH_SWORD_08_A_RARE` (25186, type 4), and so on.

### 1.5 `itemrare.txt`: the seal particles (READ; MEASURED)

`FUN_00aa0270` is called with `resinfo\itemrare.txt` before `itemoptionefp.txt` (READ, above). The two
files have the same parser and the same columns, but `itemrare.txt` has only five:
`code name, efp, scale, bone, offset` (header `//Item Code Name Particle Scale Bone Offset`). The min
and max plus are then 0 and 0xFF (READ, §1.3), so **its rows show at every plus**. `FUN_00a5f3e0`
runs the particle loop whatever the plus (READ: only the glow call is inside `if (plus != 0)`).

The archive's file (MEASURED, round 740): 3,445 data rows, 228 of them naming a code not in the item
table; every row has five columns and offset `none`. 1,458 items have rows of their own, and 480
more share them through §1.4 (1,938). Bones: `ai_end` 1,841, `Bone03` 812, `Bone01` 627, `ai_start` 165. There are 58 different
effect files, all of them in `Particles.pk2`, for example:

| Items | Effect files (`system\…`) |
|---|---|
| Star / Moon / Sun (`_A_RARE`, `_B_RARE`, `_C_RARE`) | `system_raretype_a_step1/2/3`, `system_raretype_b_step…` (and `_add`), `system_rarebow_a/b/c`, `system_rareshield_a/b/c`, … |
| Nova (`_A_RARE_ACTIVE`) | `eternity_11_nova_01/02/03` (three rows), `eternity_11_nova_bow_…`, `eternity_11_nova_shield_…` |
| Egyptian sets | `eternity_11_egya_glowset1/2_purple`, `_sealhusk_purple`; `eternity_11_egyb_coreglow/defsun/sealhusk_green` (and `_bow`, `_shield`) |

For example `ITEM_CH_SWORD_11_A_RARE_ACTIVE` has the three Nova rows at scale 175 on `ai_end` from
`itemrare.txt`, then `system_enchant_a_01.efp` (+8..+100) from `itemoptionefp.txt`. Every one of the 1,458 items with `itemrare.txt` rows of its own also has
`itemoptionefp.txt` rows of its own; 816 items have only the latter.

**The shared list.** In the second call a row goes to the list the item already holds (asm 0xaa090f
reads the map's value; the append at 0xaa0ae0 is made through it). An item that inherited the base's
list at the first call therefore adds its own `itemoptionefp.txt` rows to the base's list, and the
base's later rows reach it too. On this archive no `itemoptionefp.txt` row names such an item
(MEASURED: 0), so here it only means that the 480 members see their base's rows from both files.
OpenSRO replays both calls in order with one shared `Array` per base (`ItemGlowTables.inherit`).

## 2. The mechanism (READ)

### 2.1 Choosing and attaching

`CObjCharacter::FUN_00a60a90(slot)` is called from `CObjCharacter::FUN_00a611e0` at `0xa61405`. It
acts only on attachments of kind 1, the weapon and shield attachments. It calls
`CObjCharacter::FUN_00a5f3e0(attachObj, refId, part, plus)` twice, once for each of two compound
parts. The two parts are OPEN 4. The RefID comes from `CObjCharacter+0x38+slot*0xc`, and the plus
byte from `+0x3c+slot*0xc`.

`FUN_00a5f3e0` then does three things:
1. If `plus != 0`, it calls `FUN_00a93900(refId, plus)`. That function looks the RefID up in
   `0110ac80` to get the type number, looks the type up in `0110ac8c` to get its rows, and **returns
   the row with the highest threshold ≤ plus** (`0xa93900`: the loop keeps `row[0] <= plus &&
   row[0] > best`). It returns null if the item has no type or no row is low enough.
2. If it got a row, it makes the compound's vtable +0xc8 call (slot 50,
   `CCompChar::FUN_00c350a0`). The arguments are the part, the UV vec2, the texture path, col 5, col 6,
   colour 1, colour 2, the period and the flag. `FUN_00c350a0` builds the mod data. It loads the
   texture through `FUN_00c5d550` and attaches the mod as kind `0x70000` with
   `FUN_00c2b200(part, 0x70000, mod)`, replacing any mod already held at `+0xc4`.
3. It looks the RefID up in `0110ac98` to get the particle entries. For each entry with
   `entry[+0x48] <= plus <= entry[+0x49]`, it makes the vtable +0xcc call (slot 51,
   `CCompChar::FUN_00c30c20`) with `(part, entry+0x10, entry+0x2c, entry+4, 1, *(float*)entry, 0)`:
   the part, the efp, the bone, the offset, a 1, the scale and a 0. `FUN_00c30c20` finds or creates
   the part's effect holder at `+0x1a4` and calls `FUN_00c77ca0` with the same arguments. What the
   `1` and the `0` mean is OPEN 5.

### 2.2 The glow pass (`CRTModProgEquipPow`, vtable `0x00e0eacc`)

The mod works on the item's own draw call (`vslot_004` begins it and `vslot_005` ends it). It does
not add a separate draw. All of the following is READ:

- **Gate.** The mod acts only when `FUN_00c43780()` holds, that is when
  `mod+0x3c >= *(owner+8)+0x7c` (what these two floats are is OPEN 6), **and** the owner's colour
  word `*(owner+8)+0x4c == 0xFF000000`. So the glow is not drawn while the character is fading or
  translucent.
- **The update** (`vslot_002`, called with the frame's milliseconds):
  - `acc += ms`. While `acc < period`, `t = acc / period`, and `t = 1 − t` when `dir < 0`. When
    `acc ≥ period`, `t` snaps to 1 (or to 0 when `dir < 0`), `acc` goes back to 0 and `dir` flips.
    This is a triangle wave: colour 1 to colour 2 in `period` ms, then back again. A full cycle takes
    2 × period: 2 s at most tiers, 1.4 s at +14. The starting direction is OPEN 7; it decides only
    the phase.
  - The TEXTUREFACTOR is `0xFF000000 | round(lerp(c1, c2, t) × 255)` per channel. The 255 is
    `_DAT_00d83108` = 255.0 (MEASURED).
  - The UV offset grows by `ms × uv / 20.0` every frame. The 20.0 is `_DAT_00e1b830` (MEASURED,
    double in `.rdata`), so the speed is `uv × 50` texture units a second: 0.25/s for 0.005 and 0.5/s
    for 0.010. The offset is never wrapped; the texture's wrap mode wraps it. It is written into two
    matrices, the translation row at `+0x78/+0x7c` and at `+0xa8/+0xac`.
- **Begin** (`vslot_004`). The D3D9 names come from the standard enums.
  - It saves the caller's flag word and ORs in `0xe21f0000` with bit `0x1000` cleared. Three of
    these bits are READ (round 734's review, F7; `CObjRendererVS::FUN_00bf0e20` and `FUN_00c42a60`):
    - `0x20000000` turns off the item's own alpha test. `FUN_00bf0e20` runs the mods' `vslot_004`
      first (`FUN_00c451e0` → `FUN_00c7b540`, vtable +0x10, with the flag word's address) and only
      then `FUN_00c42a60(flags)`, which enables the material's test (`0x200`: RS 15 = 1, RS 24 =
      0x80) only when `!(flags & 0x20000000)`. So a flag-0 row draws with no alpha test at all.
    - The cleared `0x1000` keeps `FUN_00c42a60` from setting stage 0 back to MODULATE2X (its `0x1000`
      branch sets stage 0's op to 5).
    - `0x80000000` binds the item's own texture to **stage 1**: `SetTexture(1, FUN_00c39f70(i))`
      (device vtable +0x104) at `0xbf10ce`, where a plain draw binds it to stage 0.
    - The other bits (`0x40000000`, `0x02000000`, `0x001f0000`) are still OPEN 8.
  - Flag 0: `ALPHATESTENABLE` (RS 15) = 0 and `ALPHAREF` (RS 24) = 0x80. Flag 1: `ALPHATESTENABLE`
    = 1, `ALPHAFUNC` (RS 25) = 7 (GREATEREQUAL) and `ALPHAREF` = 1.
  - `TEXTUREFACTOR` (RS 60) is set to the animated colour.
  - Stage 0: `COLOROP` = col 5 (4 MODULATE or 5 MODULATE2X), `COLORARG1` = TEXTURE,
    `COLORARG2` = TFACTOR and `ALPHAOP` = DISABLE. The option texture is bound to stage 0
    (`SetTexture(0, …)`, cached in `DAT_01112830`).
  - Stage 1: `COLOROP` = col 6 (7 ADD, or 9 ADDSIGNED2X at +13), `COLORARG1` = TEXTURE,
    `COLORARG2` = CURRENT, `ALPHAOP` = SELECTARG1 and `ALPHAARG1` = TEXTURE.
  - The texture matrix goes to `SetVertexShaderConstantF(17, …, 4)` (device vtable +0x178, after
    `thunk_FUN_00aa3ac5`, INFERRED to be a transpose) and to `SetTransform(D3DTS_TEXTURE0, mod+0x88)`
    (+0xb0).
- **End** (`vslot_005`) restores the flag word and returns the stages to the plain item state:
  - alpha test off, `ALPHAREF` 0x80, stage-0 texture unbound;
  - stage 0 is MODULATE2X(TEXTURE, DIFFUSE) with alpha SELECTARG1(TEXTURE);
  - stage 1 is off.

**What the glow looks like (READ: the stage setup above, and stage 1's texture from the `0x80000000`
bit, round 734's review):**

```
colour = op5(optionTex(uv + scroll), TFACTOR)  op6  stage1Tex
alpha  = stage1Tex.a
```

`op5` is MODULATE at +3 and MODULATE2X from +5 up. `op6` is ADD, or ADDSIGNED2X at +13. Stage 0 uses
TFACTOR instead of DIFFUSE, so the weapon is not lit while it glows. The texture on stage 1 must be the
item's own diffuse texture, because its alpha drives the alpha test of the cut-out weapon types (2 and
4). The mod's `0x80000000` bit binds it there (READ, round 734's review: OPEN 9 closed).

So the glowing weapon is its own texture, unlit, plus a scrolling coloured pattern, pulsing between
two colours.

## 3. Seals: what the data says (MEASURED)

**Round 740: this section was written from `itemoption.txt` and `itemoptionefp.txt` only.** The seal
items have particle rows of their own in `itemrare.txt` (§1.5), at every plus, ahead of the
`itemoptionefp.txt` rows below. For the degree-11 sword (MEASURED): `_A_RARE_ACTIVE` (Nova)
`eternity_11_nova_01/02/03.efp`; `_B_RARE` (Moon) `system_raretype_a_step2.efp`; `_C_RARE` (Sun)
`system_raretype_a_step3.efp`; `_SET_A_RARE` `eternity_11_egya_glowset1/glowset2/sealhusk_purple.efp`
at 185; `_SET_B_RARE` `eternity_11_egyb_coreglow/sealhusk/defsun_green.efp` at 215; the `_HONOR`
items `system_raretype_a_step1/2/3_honor.efp`; all on `ai_end` at the item's own scale (175 for the
plain degree-11 sword). Degree 8 has `_A_RARE` (Star) `step1`, `_B_RARE` `step2`, `_C_RARE` `step3`, at
165. The table below is still right about the glow type and the `itemoptionefp.txt` row.

| Seal | Code suffix (degree 11 example) | ItemClass | Glow type | Particle file / scale / bone | Model |
|---|---|---|---|---|---|
| none (normal) | `_A`, `_B`, `_C` | 31 | 3 | `enchant_a_01`, 175, `ai_end` | `sword_11.bsr` |
| Nova (Star tier at degree ≥ 11) | `_A_RARE_ACTIVE` | 31, rarity 2 | 3 | same | same |
| Moon | `_B_RARE` | 32, rarity 2 | 3 | same | same |
| Sun | `_C_RARE` | 33, rarity 2 | 3 | same | same |
| Honor seal | `_*_RARE*_HONOR` | | 3 | same (`_A_RARE_ACTIVE_HONOR`: 175, `ai_end`) | |
| Egy A set | `_SET_A_RARE` | rarity 6 | 1 | `enchant_a_01`, **185** | not checked |
| Egy B set | `_SET_B_RARE` | rarity 6 | 1 | `enchant_a_01`, **215** | not checked |
| Egy set switches | `_SET_A/B_RARE_SWITCHnn` | | per row | **`enchant*_set_a_rare_01` / `_set_b_rare_01`** | `sword_01..22.bsr` |

ItemClass and rarity are columns of the itemdata rows, counted in the archive. Lower degrees follow
the same pattern: Star (`_A_RARE`), Moon and Sun share the normal item's type and particle row (for
example CH_SWORD_08 is type 4 throughout).

~~A seal item looks different only through its own model or texture.~~ (Wrong, round 740.) A seal
item's glow comes from the same type as the normal item's, but its particles do not: `itemrare.txt`
lists the seal items by code name. No code path picks an effect by rarity as such:
`FUN_00a5f3e0`'s only inputs are the RefID and the plus (READ); the seal effect is chosen because the
seal item is a different RefID with its own rows. Round 733's string search ("the executable names only
`itemoption.txt`, `itemoptionefp.txt`") missed `resinfo\itemrare.txt` at 0xdd30f8, which the
particle loader is called with first (READ, §1).

## 4. Which items, and where they show

| Question | Answer | Label |
|---|---|---|
| Weapons and shields only? | Yes. Only attachments of kind 1 reach `FUN_00a60a90`, and the tables list only weapons and shields (shield rows such as `ITEM_CH_SHIELD_11_*`, particles `enchantshield_a` on `Bone01`). | READ (gate), MEASURED (tables) |
| Other players? | Yes. The same `CObjCharacter` path runs for every character, and `0x3038` delivers others' plus. | READ |
| Character select | Retail's list carries a plus per item (`charselect.md`: u32 RefItemID, u8 plus), and the screen installs each item with it (`PSCharacterSelect::FUN_0085a580` -> `InstallEquipVisual(slot, id, plus, 0)`), so it glows. | READ (round 734) |
| Portrait / paper doll | Glows, INFERRED (OPEN 10, below). OpenSRO draws the glow in both on a Linear-view variant of the glow shader (round 734's review, F1) | INFERRED |
| Sheathed or drawn | SRO has no sheathing. The weapon is always in the hand. | INFERRED |
| Advanced elixir | Round 732 READ that the client adds the elixir's value into the item's `+0x8c` plus. **Round 735 READ: the server's `0x3038` and `0x3015` byte includes it.** `CInstanceItem::vslot_010` (`s:0x42e230`) mode 2 writes, for equipment, `(u8)(FUN_00846200's elixir sum + OptLevel at +0x2c)` (`s:0x846200` adds each attached elixir's `+0x2c`). Your own character's `CObjCharacter+0x3c+slot*0xc` byte is that sum too (round 735's review, §8 item 2). | READ (round 735) |
| Avatar / switch models | `_SWITCHnn` items are separate RefIDs with their own rows. They are not chosen by plus. | MEASURED |

## 5. The data path

### Retail (READ)

- **Equip changes** (`0x3038`, handler `FUN_008a9260`): u32 unique id, u8 slot, u32 RefItemID, then
  **u8 plus**, the effective one: OptLevel + the advanced elixir (round 735, READ in the server:
  `0x4e9de2` writes the uid at `[ebp+8]`, the move's destination slot `[edi+4]`, then the item's
  vslot 294 at mode 2 -> `CInstanceItem::vslot_010` `0x42e230`: `FUN_004958c0(+0x28)` the RefItemID,
  then the plus byte). The client reads its slot byte into a variable the RefItemID overwrites, and
  redresses by `ResolveVisualSlotForItem`. The server sends it only for an item
  `FUN_00490390` passes (READ, round 735's review: the item is equipment, `CGObj::IsEquip`, and
  its equip slot is 8 or less, or it is an avatar, TypeID3 13, or a devil's spirit, TypeID3 14),
  through `FUN_00484d90`, a region-scoped send that reaches the mover too (both client handlers
  have an own-uid branch updating the character window and preview). The OptLevel is present only for equipment, that is when the type word has
  `!(w & 2) && (b & 0x1c) == 0xc && (b & 0x60) == 0x20`. The handler calls the equip setter
  `FUN_009daf70(…, refId, plus, 0)` and plays `ITEM_SETITEM_ACTIVE` / `_DEACTIVE` with
  `snd_setitem_active`.
- **Unequip** (`0x3039`) goes to `FUN_008a9560`: u32 unique id, u8 slot, u32 RefItemID, no plus
  (round 735, READ; the server writes it at `0x4e9f98`, gated by `FUN_00490390`, and at
  `0x4e9d03`, the move-type-7 path, not gated, slots 0..12: uid, the move's source slot `[edi+3]`,
  the item's RefItemID from its vslot 1). Unlike `0x3038`'s handler it uses its slot byte:
  `FUN_009daf70(slot, 0, 0, 0)` clears that slot.
- **Spawning another player** (`0x3015`, round 735 READ, closes OPEN 3): the PC body reader
  `GlobalDataManager::FUN_009de2f0` (CICUser vslot 25, table `0xde2e7c`) reads u8 inventory size,
  u8 item count, then per item u32 RefItemID and, for equipment by the same type-word test, **u8
  plus**; the avatar block follows. The server writes it with `CGObjPC::vslot_294` (`0x4e5a10`) mode 2
  -> `GStorage::FUN_004b8ad0` -> each item's `CInstanceItem::vslot_010` mode 2, the same effective plus
  as `0x3038`.
- **Your own gear**: the item record (round 732) carries OptLevel at `+0x8c`.

### OpenSRO today (MEASURED in the tree)

| Path | What it carries | File |
|---|---|---|
| `OP_ENTITY_ENTERED 0x0023` and the snapshot in the enter-world/zone lists | per worn slot: u8 slot + s64 item id; **since round 735 each worn item's effective plus in a trailing pluses tail** (u8 count, then u8 slot + u8 plus per item with a plus; OURS framing, retail content), after `EncodeEntered`'s model and after the results' models tail | `server/internal/session/world.go` (`encodePlusesList`, `appendPluses`); `client/scripts/net/world.gd` (`_decode_pluses`, `EntitySnapshot.pluses`) |
| Equip changes seen by others | **Round 735: retail `0x3038` / `0x3039`** to the other characters in the zone on every equip and unequip, and a `0x3038` on the GM's `/item worn <slot> plus N` (OURS: retail changes no worn item's plus) | `server/internal/session/equip_broadcast.go`; `client/scripts/net/equipment.gd` (`decode_broadcast`), `net_client.gd` (`other_player_equipment_changed`), `World3D.gd` (`_on_other_equipment_changed`, `_redress_other`, `_other_pluses`) |
| Own equipment list `0x0040–0x0043` (OURS) | the item record with OptLevel and the advanced elixir (round 732) | `equipment.go`; `client/scripts/net/equipment.go` |
| Char select list | plus per item | `charselect.md` |
| Test plus values | `/give <id> [qty] [plus]` and `/item <slot> plus N` (GM, OURS, round 732); `/item worn <equip slot> plus N` / `adv N` on a worn item (round 735) | `server/internal/gm/gm.go` |
| QA dress | `OPENSRO_QA_EQUIP="slot=item_id,…"`, no plus | `World3D.gd` `_parse_qa_equip` |

## 6. Options and gating

- No Option-window setting is consulted anywhere on the attach path (`FUN_00a60a90`, `FUN_00a5f3e0`)
  or in the mod (`vslot_002/004/005`) (READ). The mod's only gates are the full-alpha test and
  `FUN_00c43780`, whose meaning is OPEN 6.
- Whether "Effect" quality or the particle system's own limits drop the `.efp` is OPEN 11. They
  would act inside `FUN_00c77ca0` and the efp manager, not here.
- OURS (proposed): have the glow follow the existing effects switches, if the Video tab has one that
  retail's effects obey. Otherwise always draw it, as retail's attach path does.

## 7. Performance

- The glow costs one changed material on at most two meshes per character (weapon and shield), with
  no extra draw (READ: it is a state change around the item's own draw). In Godot this is one
  `ShaderMaterial` per glowing item. One clock does the pulse and the scroll for every glow (built:
  `srr_glow_clock`, a global uniform that `EquipGlow` advances once a frame and wraps at 25200 s, not
  `TIME`, whose 3600 s rollover cut +14's 1.4 s cycle; round 734's review, F8), so there is no
  per-material script work. A material is shared per (type, tier, item texture).
- Particles start at +8, one `.efp` per item, through the existing `EfpEffect`. In a crowded town, N
  players at +8 or more add N to 2N emitters. Lane A measures them in the gate and may share an
  instance, but must not cap them (OPEN 11: we do not know whether retail drops them).
- This is a world-drawing round, so `perf_gate.sh` runs, and the table goes in the round entry.

## 8. Gaps (OPEN), with round 734's answers

1. **Seal-specific effects.** USER DECISION (2026-10-05): follow the data; no seal effects are
   invented. Three user reference pictures (Seal of Sun bow +10, an Egyptian-set glaive, a Nova
   glaive at +5) were compared qualitatively in `docs/rounds/r734.md`. **Round 740: the data has
   them** (`itemrare.txt`, §1.5), and OpenSRO now loads it: seal weapons and shields carry their
   seal particles at every plus. Not yet compared against the user's pictures on a render (OPEN).
2. **The effective plus: READ (round 734).** Your own gear: `CICPlayer::vslot_025` (0x9d9a80) ->
   `FUN_008ba570` hands `InstallEquipVisual` (0xa61010) the item's `+0x8c` byte, which the record
   reader fills with OptLevel + the advanced elixir (c:0x8bb070), a u8. Others: `0x3038`'s byte. The
   server's `0x3038` value is lane B's.
3. **`0x3015` per-item OptLevel**: closed in round 735 (§5): u32 RefItemID + u8 effective plus per equipment item, `0x9de2f0`.
4. **The two compound parts** that `FUN_00a60a90` passes: still OPEN. OpenSRO glows every mesh of the
   item (both `_l`/`_r` models of a dual weapon) and puts each particle row on the first item skeleton
   carrying its bone.
5. **The particle attach: READ (round 734).** `CRTModParticle::FUN_00c816c0`: the first string
   (+0x10) is the efp (assigned with `FUN_00425bf0`), the second (+0x2c) the bone, compared with
   "none"; an unknown bone returns 0 and the mod is freed. The `1` goes to +0xb4 and becomes
   IEasyFxEffect slot 4 with 1 (kept, looping) in `FUN_00c81350`; the trailing `0` is +0xc4, a start
   delay in ms counted down by `FUN_00c81410`. The scale goes to +0xc0 and is handed to
   `CEFEffect::vslot_010` (the effect's uniform scale, times a factor at `*(this+4)+0x264`) on
   every placement (`FUN_00c81190`). What `*(this+4)+0x264` holds (a global setting or the effect
   file's own value) is OPEN, and OpenSRO does not apply it. OpenSRO's particles take the row's
   scale times the host's uniform scale, the body's height factor (round 734's review, F4: as the
   per-weapon path's anchor did), never a mirror (OURS: the shared simulation's billboards face the
   camera in world axes). A weapon within 30 units of the camera shows its effect even outside the
   view (OURS, `EquipFx.ALWAYS_NEAR`).
6. **`FUN_00c43780`**: `mod+0x3c >= *(owner+8)+0x7c`, the latter a 0..1 value clamped by
   `CCompChar::FUN_00c25620` (a virtual). Still OPEN; OpenSRO does not gate on it.
7. **The starting direction: READ (round 734).** The constructor (`FxModManager::FUN_00c847f0`) sets
   +0xd8 = 1, +0xd4 = 0, and `vslot_001` sets the colour to colour 1: the pulse starts at colour 1
   going to colour 2. The update runs only while the gate holds, so the pulse pauses while a character
   fades (OURS: OpenSRO's runs on one clock, `srr_glow_clock`, all glows in step).
8. **The flag-word bits**: three READ (round 734's review, §2.2): `0x20000000` skips the item's
   own alpha test (`FUN_00c42a60` runs after the mod's `vslot_004` in `FUN_00bf0e20`), so a flag-0
   row draws with no test; the cleared `0x1000` keeps stage 0 from being reset to MODULATE2X;
   `0x80000000` is item 9. `0x40000000`, `0x02000000` and `0x001f0000` are still OPEN.
9. **The stage-1 texture: READ (round 734's review).** The mod's `0x80000000` makes `FUN_00bf0e20`
   bind the item's own texture to stage 1, `SetTexture(1, FUN_00c39f70(i))` at `0xbf10ce`. OpenSRO
   uses the item's own texture there.
10. **The portrait and paper doll**: the character select is READ (`PSCharacterSelect::FUN_0085a580`
    calls `InstallEquipVisual(slot, id, plus, 0)`), so it glows. The equipment window's avatar (and
    the portrait that borrows it) is INFERRED to glow: the client's copy of one character's dress
    onto another (`UI_SILKMALL::FUN_00a617d0`) carries each slot's plus. The character-creation
    screen installs plus 0 (`FUN_0080b440`). In OpenSRO all three keep the glow (round 734's review,
    F1: before it, `PlayerPortrait._apply_materials` replaced the glow material with a plain lit one).
    The equipment window and the portrait draw it on the glow shader's Linear-view variant
    (`OBJECT_NO_PRESENT`: their SubViewports tone-map Linear), the select screen on the world's. The
    plain layer behind it keeps its own alpha reference. The portrait drops the particle effects (a
    picture rendered once, OURS); the equipment window keeps them, paused while it is closed.
11. **Particle quality gating** inside the efp manager: OPEN; nothing is capped.
12. **Item bones: MEASURED (round 734).** The item `.bsk` files carry `ai_end`, `ai_start`,
    `Bone01`..`03`; OpenSRO's item skeleton keeps them.

Note on §1.3 (round 734, MEASURED): spears use `enchant_a_01` on `ai_end` (e.g. `CH_SPEAR_11_*`, 230),
and only the `_SET_A/B_RARE_SWITCHnn` variants name `*_set_a_rare_01` / `_set_b_rare_01`; the plain
`_SET_A_RARE` rows name the ordinary file at their own scale (`CH_TBLADE_11_SET_A_RARE`: `enchant_a_01`,
320, `ai_end`, where `CH_TBLADE_11_A` has `enchant_b_01`, 310, `ai_start`).

**Built (round 734, lane A):** `ItemGlowTables` (client/scripts/items/item_glow_tables.gd), `EquipGlow`
(client/scripts/assets/equip_glow.gd) and the `EQUIP_GLOW` path of `object.gdshaderinc`, applied by
`CharacterAppearance.build` to slots 6 and 7; the particles go through `EquipFx` (client/scripts/assets/equip_fx.gd), one shared simulation per (efp, scale), drawn at each bone, nearest 64 in view within 800 units (OURS, r734.md). `OPENSRO_QA_EQUIP` takes `slot=item_id+plus`;
`OPENSRO_QA_LINEUP_KITS` draws bodies side by side with given pluses; `OPENSRO_QA_FAKECHARS_PLUS`
gives the select screen's QA characters a weapon plus; `client/tools/measure_equip_glow.gd` measures
the drawn glow against the arithmetic. The lobby list the server sends carries plus 0
(`server/internal/session/lobbyhandler.go`, the `LobbyItem` without `Plus`): lane B's to fill.

**Built (round 740):** `ItemGlowTables.for_archive` loads `itemrare.txt` before `itemoptionefp.txt`
(§1.5), and `ItemGlowTables.inherit(items)` replays §1.4 over item rows: `inherits_glow` is the
type-word gate, the groups are kept by OrgObjCodeName, and the types and particle lists are rebuilt in
group-name order, call by call, with members sharing their base's `Array`. `ItemTableReader.Item`
carries `org_code_name` (column 4, `xxx` → ""; the native reader's `org_code_names` too).
`CharacterAppearance` hands the tables every item table it is given or parses (`add_item_rows`,
`_item_info`'s full load); a later, larger table adds only its new members. On the box's archive the
world's seven parts already hold all 496 members: 480 types and 480 particle lists inherited, in
18.7 ms (MEASURED, `client/tools/glow_inherit_probe.gd`).

## Implementation lanes

**Lane A (client): tables, the glow material, the particles, and every view of the character.**

Files:
- new: `client/scripts/items/item_glow_tables.gd` (the three readers and the lookup);
  `client/scripts/assets/equip_glow.gd` (applies the glow and particles to an attached item);
  `client/scripts/assets/equip_glow.gdshader`; their `_test.gd` files.
- edits: `client/scripts/assets/skinned_bsr_assembler.gd` (`attach_item_from_archive` takes a plus,
  or returns what `equip_glow` needs); `client/scripts/ui/character_appearance.gd` and
  `character_preview.gd` (char select and create); in `World3D.gd`, only `_build_assembled_character`,
  `_spawn_or_update_other`, `_refresh_player_portrait` (for OPEN 10) and `_parse_qa_equip` (accept
  `slot=item_id+plus`).

Steps:
1. Settle OPEN 12, then 5, 9 and 7, cheaply. Read the decompile, not the screen.
2. Readers: parse the three tables as `0xa9f2e0` does: ASCII, `//` comments, columns as §1. Resolve
   code names to RefIDs through the existing item table. Lookup: the highest threshold ≤ plus, and
   every particle row with min ≤ plus ≤ max.
3. Shader. Use `render_mode unshaded` while glowing.
   - Colour: `op5(optionTex(UV + uv*50*TIME), TF)` then `op6` with `itemTex`.
     - TF is the triangle wave of period P ms between c1 and c2.
     - `op5` is MODULATE (×1) or MODULATE2X (×2).
     - `op6` is ADD or ADDSIGNED2X (`2*(a+b) − 1`, i.e. `(a + b − 0.5) × 2`).
     - Clamp to [0, 1] after each stage, as D3D9 fixed function does.
   - Alpha: from `itemTex`, with alpha scissor at 1/255 when the flag is 1. When it is 0, use the
     item's existing alpha handling.
   - Hide the glow while the character is translucent (the full-alpha gate).
4. Particles: attach `EfpEffect` at the item's bone, scaled by col3/100, offset (0,0,0).
5. Apply both wherever a character is dressed:
   - your own character;
   - other players, from lane B's field;
   - char select, from the list's plus;
   - the portrait, if OPEN 10 says so.
6. Re-apply on every equip change and on every plus change (`/item <slot> plus N`).

Acceptance:
- GD tests:
  - row selection: +0, +2 and +4 fall back correctly; +15 and +255 give +14;
  - the triangle wave at t = 0, P/2, P, 3P/2 and 2P;
  - the UV speed is `uv×50`;
  - colour packing round(c×255);
  - an item with no type number has no glow;
  - particles appear only from +8.
- Live renders on the box, all in one `--shots` run, of a CH_SWORD_11_A (type 3), a bow (type 1) and
  a CH_SHIELD_11_A (type 1) at +0, +3, +5, +7, +9 and +13/+14. Each tier is **measured**:
  - the mean hue and luma of the weapon's pixels at the two ends of the pulse, compared with c1 and
    c2 through the stage maths (the frame time is fixed by the movie writer);
  - the scroll measured as the shift of the pattern between frames, against `uv×50`.
- The same sword as `_A_RARE_ACTIVE`, `_B_RARE`, `_C_RARE` and `_SET_A_RARE` at +9. This measures that
  Nova, Moon and Sun match normal, and that the set differs only in particle scale.
- Char select shows the glow for a stored +7 weapon.
- `perf_gate.sh` (all three views), with a +13 sword-and-shield character standing at the Jangan spawn
  in the head build, and its table in the round entry.

**Lane B (server + client net): the plus of other players' gear.**

Files: `server/internal/session/equipment.go` (`EquippedSnapshot`, the broadcast), `world.go`
(encode and decode), new `server/internal/session/equip_broadcast*.go` and its tests,
`client/scripts/net/world.gd` and `client/scripts/net/equipment.gd`.

Steps:
1. Read OPEN 2 and OPEN 3 first: the effective plus, and the `0x3015` per-item layout.
2. Add the plus to every snapshot. The per-item list sits mid-payload, so add **a trailing block** (u8
   count, then u8 slot + u8 plus), the way round 637 added the heading. Older decoders ignore it.
   OURS container, retail value.
3. Broadcast equip and unequip to the observers in range. Use **retail `0x3038`/`0x3039`** with the
   READ layout (u32 uid, u8 slot, u32 RefItemID, u8 OptLevel for equipment), per the standing "retail
   opcodes" decision, if OpenSRO's unique id maps to the retail uid. Otherwise use an OURS message
   labelled as such.
4. Send a plus change (an enhancement, or the GM `/item plus`) as the same broadcast.
5. Client: store the plus beside the item id in `snap.equipped` and hand it to lane A's
   `_spawn_or_update_other`.

Acceptance:
- Go tests: encode/decode round trips, an old decoder on the new payload, the `0x3038` byte layout
  against the READ handler, and that the broadcast reaches only observers.
- A GD test of the client decoder.
- Live: two clients. B gives itself a +9 sword with `/give`, equips it, then changes it with
  `/item … plus 13`. Observer A's log and render show the +9, then the +13 glow, without
  re-entering.
- No perf gate (no drawing change).

Lane B can run in parallel with lane A. Until B lands, A uses the QA hook and your own character.

**Lane B as built (round 735, `docs/rounds/r735.md`).** What lane A consumes:
- `WorldNet.EntitySnapshot.pluses` (slot -> effective plus; `plus_in(slot)`), filled from the pluses
  tail of `OpEntityEntered`, `OpEnterWorldResult` and `OpChangeZoneResult`.
- `World3D._other_pluses[character_id]` (slot -> plus), kept from every snapshot and every `0x3038`.
- `NetClient.other_player_equipment_changed(uid, slot, ref_id, plus)`: `uid` is the u32 (the low 32
  bits of the character id; `World3D._other_by_uid` resolves it), `plus` -1 on an unequip.
- `World3D._redress_other(character_id)` rebuilds the body with `_build_assembled_character(equipped,
  body, scale)`; when lane A gives that builder the pluses, this is the one other caller to pass
  `_other_pluses[character_id]` from (and `_spawn_or_update_other`'s callers, from `snapshot.pluses`).
