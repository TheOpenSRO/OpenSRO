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
  2. **The particles** are an `.efp` attached to a bone of the weapon. Every row in the table runs
     from **+8** to +100.
- **The seal does not choose the effect in this client and these archives** (MEASURED, §3). Seal of
  Star, Moon, Sun and Nova items use the same glow type number, the same particle file, the same
  particle scale and the same model as the normal item of their kind and degree. Only the Egyptian
  set items' `_SWITCHnn` variants have particle files of their own
  (`system_enchant*_set_a_rare_01.efp` and `_set_b_rare_01.efp`). What the user remembers of seal
  effects is a gap for the user to settle (OPEN 1).
- Retail sends the plus of other players' gear in the equip-change broadcast `0x3038` (READ). OpenSRO
  sends no plus for other players' gear, and does not broadcast equip changes (§5).

## 1. The tables (MEASURED; the loader READ)

All three are loaded by `UI_ALCHEMYBOX::FUN_00a9f2e0` (READ) into three maps:

| Map | Key → value | Filled from |
|---|---|---|
| `DAT_0110ac80` | item RefID → type number | `Media.pk2 resinfo\itemoption.txt`: `codename<TAB>type_number`. The code name is resolved to a RefID through the item table. |
| `DAT_0110ac8c` | type number → vector of 0x4c-byte glow rows | `Media.pk2 resinfo\itemtypenumber.txt` |
| `DAT_0110ac98` | item RefID → vector of 0x4c-byte particle rows | `Media.pk2 resinfo\itemoptionefp.txt` |

All three files are ASCII with CRLF line ends. `//` lines are comments. The comment in
`itemtypenumber.txt` is EUC-KR.

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
The parser at `0xaa0622..` (inside the same loader) builds a 0x4c-byte entry:

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
  - It saves the caller's flag word and ORs in `0xe21f0000` with bit `0x1000` cleared. The meaning of
    these bits is OPEN 8.
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

**What the glow looks like (INFERRED from the stage setup):**

```
colour = op5(optionTex(uv + scroll), TFACTOR)  op6  stage1Tex
alpha  = stage1Tex.a
```

`op5` is MODULATE at +3 and MODULATE2X from +5 up. `op6` is ADD, or ADDSIGNED2X at +13. Stage 0 uses
TFACTOR instead of DIFFUSE, so the weapon is not lit while it glows. The texture on stage 1 must be the
item's own diffuse texture, because its alpha drives the alpha test of the cut-out weapon types (2 and
4). Who binds it there is OPEN 9. The flag word bits are the likely switch.

So the glowing weapon is its own texture, unlit, plus a scrolling coloured pattern, pulsing between
two colours.

## 3. Seals: what the data says (MEASURED)

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

A seal item looks different only through its own model or texture. Its glow and particles come from
the same tables, keyed by the same plus. This client has no table, string or code path that picks an
effect by rarity: `FUN_00a5f3e0`'s only inputs are the RefID and the plus (READ). The executable's
strings name only `itemoption.txt`, `itemoptionefp.txt` and the ProgEquipPow RTTI (MEASURED).

## 4. Which items, and where they show

| Question | Answer | Label |
|---|---|---|
| Weapons and shields only? | Yes. Only attachments of kind 1 reach `FUN_00a60a90`, and the tables list only weapons and shields (shield rows such as `ITEM_CH_SHIELD_11_*`, particles `enchantshield_a` on `Bone01`). | READ (gate), MEASURED (tables) |
| Other players? | Yes. The same `CObjCharacter` path runs for every character, and `0x3038` delivers others' plus. | READ |
| Character select | Retail's list carries a plus per item (`charselect.md`: u32 RefItemID, u8 plus). The preview is a `CObjCharacter`, so it glows. | INFERRED |
| Portrait / paper doll | Not checked | OPEN 10 |
| Sheathed or drawn | SRO has no sheathing. The weapon is always in the hand. | INFERRED |
| Advanced elixir | Round 732 READ that the client adds the elixir's value into the item's `+0x8c` plus. Whether the byte in `CObjCharacter+0x3c+slot*0xc` is that sum for your own character, and whether the server's `0x3038` byte includes it, are not read. | OPEN 2 |
| Avatar / switch models | `_SWITCHnn` items are separate RefIDs with their own rows. They are not chosen by plus. | MEASURED |

## 5. The data path

### Retail (READ)

- **Equip changes** (`0x3038`, handler `FUN_008a9260`): u32 unique id, u8 slot, u32 RefItemID, then
  **u8 OptLevel**. The OptLevel is present only for equipment, that is when the type word has
  `!(w & 2) && (b & 0x1c) == 0xc && (b & 0x60) == 0x20`. The handler calls the equip setter
  `FUN_009daf70(…, refId, plus, 0)` and plays `ITEM_SETITEM_ACTIVE` / `_DEACTIVE` with
  `snd_setitem_active`.
- **Unequip** (`0x3039`) goes to `FUN_008a9560`.
- **Spawning another player** (`0x3015`): the per-item plus is OPEN 3 (not read this round).
- **Your own gear**: the item record (round 732) carries OptLevel at `+0x8c`.

### OpenSRO today (MEASURED in the tree)

| Path | What it carries | File |
|---|---|---|
| `OP_ENTITY_ENTERED 0x0023` and the snapshot in the enter-world/zone lists | per worn slot: u8 slot + s64 item id, **no plus**. The list sits *before* the gender, so a per-item field cannot be added in place without breaking older decoders. | `server/internal/session/equipment.go` `EquippedSnapshot`, `world.go` `EncodeEntered`; `client/scripts/net/world.gd` ~l.205 |
| Equip changes seen by others | **None found**: `equipment.go` sends no broadcast, and only enter-world and region crossing send `OpEntityEntered` | `server/internal/session/equipment.go`, `world.go` 1383/1504 |
| Own equipment list `0x0040–0x0043` (OURS) | the item record with OptLevel and the advanced elixir (round 732) | `equipment.go`; `client/scripts/net/equipment.go` |
| Char select list | plus per item | `charselect.md` |
| Test plus values | `/give <id> [qty] [plus]` and `/item <slot> plus N` (GM, OURS, round 732) | `server/internal/gm/gm.go` |
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
  `ShaderMaterial` per glowing item. `TIME` in the shader does the pulse and the scroll, so there is
  no per-frame script work. A material is shared per (type, tier, item texture).
- Particles start at +8, one `.efp` per item, through the existing `EfpEffect`. In a crowded town, N
  players at +8 or more add N to 2N emitters. Lane A measures them in the gate and may share an
  instance, but must not cap them (OPEN 11: we do not know whether retail drops them).
- This is a world-drawing round, so `perf_gate.sh` runs, and the table goes in the round entry.

## 8. Gaps (OPEN)

1. **Seal-specific effects.** The user expects distinct effects for Star, Moon, Sun and Nova. These
   archives and this client have none (§3). Either the memory is of the item models and textures, or
   of another client version, or of a private-server mod. The user decides. Until then we draw only
   what the tables say.
2. **The effective plus.** Does the glow use plus + advanced elixir? Read the code that fills
   `CObjCharacter+0x3c+slot*0xc` for your own character, and the server's `0x3038` writer.
3. **`0x3015` per-item OptLevel** for spawned players: read the spawn parser.
4. **The two compound parts** that `FUN_00a60a90` passes. They might be the weapon and its trail
   holder, or two mesh groups.
5. **The particle attach** `FUN_00c77ca0`: what its `1` and trailing `0` arguments mean, and which of
   the two strings (+0x10 or +0x2c) is the efp path and which the bone (INFERRED: in file order).
6. **`FUN_00c43780`**: `mod+0x3c` against `owner+8 → +0x7c`. It could be distance or LOD, or a time.
7. **The starting direction of the triangle wave**: the mod constructor's value at `+0xd8`.
8. **The flag-word bits** `0xe21f0000` and `~0x1000`.
9. **The stage-1 texture**: who binds the item's diffuse texture to stage 1 during the mod.
10. **The portrait and paper doll**: is the glow drawn there?
11. **Particle quality gating** inside the efp manager.
12. **Item bones**: whether OpenSRO's item `.bsr`/`.bms` load keeps `ai_end`, `ai_start` and
    `Bone01`–`03` as attach points. Lane A checks this first.

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
