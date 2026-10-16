# Avatars (round 789)

The avatar inventory on the server and on the wire: the five avatar slots, the moves into and out of
them, the list, the spawn and lobby blocks, the broadcasts, the stats, the devil's spirit's period,
the grant at the blacksmith and the dead avatar enchant. Labels: **READ** (seen in the binary, with
the address; `c:` sro_client.exe, `s:`/`gs:` SR_GameServer.exe), **MEASURED** (the retail tables),
**INFERRED**, **OPEN**, **OURS**. The research is `/root/opensro-pk3av789/AVATAR_RESEARCH.md` and
`AVATAR_ALCHEMY_RESEARCH.md` (lanes RA and RB, 2026-10-16), outside the repository; this file keeps
what the build uses. The bytes are pinned by `client/scripts/net/testdata/avatar_golden.json`, which
the server (`server/internal/session/avatar_golden_test.go`) and the client both encode and decode.

Code: `server/internal/avatar` (the rules), `server/internal/session/avatar.go` (the handlers),
`avatarwire.go` (the messages), `avatarstats.go` (the stats and the expiry), `avataruse.go` (the
devil's spirit's use), `pcspawn` (the spawn block).

## The storage

| | | label |
|---|---|---|
| size | 5 slots, storage index 0..4 (`s:0x4e1340` creates a type-5 storage of size 5; PC `+0x1c34`; DB `_InventoryForAvatar (CharID, Slot 0..4, ItemID)`) | READ |
| holds | 3/1/13 (avatars: TypeID4 1 hat, 2 dress, 3 attachment, 4 flag/"extra") and 3/1/14 (the devil's spirit, only TypeID4 1 exists) | READ |
| which slot | **not fixed by type.** The server keeps the client's slot when it is empty, else takes the first empty one (`s:0x523f70`). The retail client sends the first empty slot for a 13/x and always 4 for a 14/x (`c:0x6ad416..0x6ad463`) | READ |
| display | by type: window index TypeID4-1 for 13/x (hat, dress, attachment, flag), TypeID4+3 for 14/x (devil's spirit) = GDR_AVATAR_SLOT_01..05 (`c:0x6abcd0`) | READ |
| OpenSRO's store | one more inventory container (`internal/inventory`, the bag's own store) on table `avatar_inventory_slots`, the bag's columns (`slot, item_id, quantity, variance, durability, opt_level, mag_params, adv_elixir, serial`), capacity 5, keyed by `character_id`. The table creates and migrates itself at boot. In memory: `avatar.NewMem` | OURS |

The item instance (variance, plus, blue options, advanced elixir, serial) moves between the bag and
the avatar slots unchanged.

**The devil's spirit's expiry** lives where retail keeps it: the instance's Data word (`+0x38`, the
field a weapon keeps its durability in; time32, 0 = never awakened; READ `s:0x42e5c3`, `s:0x498060`).
OpenSRO keeps it in the instance's `Durability`: the unix second it expires, `0` or `-1` for never
awakened (OURS: "never" may be either). A 3/1/14 row has no durability (MEASURED: Dur 0), so nothing
else reads that field for it.

## The moves: 0x7034 -> 0xB034, types 0x23 and 0x24

READ (`s:0x50ce80` type table -> `s:0x526ed0`; parser `s:0x4d8bf0`; client `c:0x7950b0`,
`c:0x7923a0`): only these two types touch the avatar storage. There is no avatar<->avatar move, no
swap, no mall->avatar.

| type | request after the type byte | the server picks |
|---|---|---|
| `0x24` bag -> avatar | `u8 src` (bag slot + 13), `u8 dst` (avatar slot 0..4) | `dst` kept if empty, else the first empty avatar slot |
| `0x23` avatar -> bag | `u8 src` (avatar slot 0..4), `u8 dst` (bag slot + 13, the clicked one) | `dst` always replaced by the first free bag slot |

OpenSRO's decoder wants exactly the three bytes (the golden's "trailing byte" vector); a malformed
body is answered `3` (OURS).

**Reply 0xB034** (READ `s:0x4f76e0` index 21 = `0x4f804d`, client `c:0x87eb50`):

```
success: u8 1, u8 type, u8 src, u8 dst (the slot used), u16 qty (= 0), u8 n,
         n x (u8 type (the OUTER op's, 0x23), u8 src, u8 dst, u16 qty)
failure: u8 2, u16 code
```

`n` is 1 only when a dress comes off while an attachment is worn: the attachment comes off too, as
the sub-op `0x23 attachmentSlot bagSlot 0`.

### The rules, in the server's order

**StorageOperation's framing** (`s:0x50f5c0`), before the type's rules:

1. dead (`vslot 0xf8 == 2`) -> **2**;
2. INTERACTMODE 4, or 2/7 -> **0x1834** STORAGE_OPERATION_BLOCKED. OpenSRO: an established trade is
   mode 2 (OURS: the mapping; OpenSRO has no stall (4) and no mode 7). A pending trade invitation
   does not block (retail's mode 1 does not).

`[pc+0x30]+0x13 != 0 -> 0x180e` is not modelled (what the byte is was not read, OPEN).

**0x24, bag -> avatar** (`s:0x525950`):

| # | rule | code |
|---|---|---|
| 1 | `src` outside 13..0x6f | `3` |
| 2 | the bag slot empty | `0x1809` |
| 3 | the item's serial 0 (every OpenSRO row has one) | `3` |
| 4 | `CanBeEquipedAt(pc, dst)` (`s:0x497070`): dst past 12 `0x1806`; (an expired rental `0x183c`: OpenSRO has no rentals); ReqGender != the character's and != 2 `0x1816`; (razed `0x1837`: not modelled); the four requirement pairs `0x186c` (the character level; masteries carried, not enforced, as for equipment); ReqStr `0x1830`; ReqInt `0x1831`; Country != the character's and != 3 `0x182f` | as listed |
| 5 | not 3/1/13 and not 3/1/14 | `0x180e` |
| 6 | an item of the same TypeID1..4 already worn (`s:0x4ba130`; cash/bionic bits ignored) -- **no swap** | `0x180e` |
| 7 | an attachment (13/3) without a worn dress whose `ChildItemCount` (itemdata col 159, ref `+0x53d`) is non-zero | `0x180e` |
| 8 | a devil's spirit not awake (expiry unset or past; `s:0x498610`) | `0x18f9` NASRUN_NOT_AWAKE_WEAR_ERROR |
| 9 | `s:0x523f70`: the source past the bag's size, or `dst >= 5` | `3` |
| 10 | `dst` occupied and no avatar slot empty | `0x1807` |

**0x23, avatar -> bag** (`s:0x525ac0`, `s:0x525c50`): the avatar slot empty `0x1809`; not 13/14
`0x180e`; no free bag slot `0x1807`; a dress worn with an attachment needs two free bag slots, else
`0x1807` -- the attachment goes to the first free slot that is not the dress's. No gender or level
check on removal.

The retail client checks a little itself (`c:0x6ad180`): the same kind already shown ->
`UIIT_MSG_STRGERR_EQUIPITEM`, an attachment without a dress -> `UIIT_STT_AVATAR_MAIL_ONLY_WEAR`,
nothing sent. The server does not rely on it.

**An avatar never goes into an equipment slot** (`CheckEquipsetIntegrity` fails on "Equiped Avatar
Item!!", `s:0x4bb020`): OpenSRO's equip refuses 13/14 (`equipment.SlotFor` has no slot for them).

### On the way out (READ `s:0x50f1f0`, `s:0x4e9c40`)

In this order, after the move:

1. **0x3039** for the sub-op (the attachment), then **0x3038** (0x24) or **0x3039** (0x23) for the
   move, to everyone in view **including the mover** (the region send `FUN_00484d90`);
2. the stats: the param entries of the items that left are removed and those that arrived published
   (`PublishEquipItemParams`), then the stat refresh to the client (`vslot 0x538`);
3. **0xB034**.

| msg | bytes | slot byte |
|---|---|---|
| 0x3038 | `u32 uid, u8 slot, u32 RefItemID, u8 plus` | the avatar slot it went to (`op+4`) |
| 0x3039 | `u32 uid, u8 slot, u32 RefItemID` | the avatar slot it left (`op+3`) |

The client ignores the slot byte for 13/14 and attaches/detaches by RefItemID (`c:0x8a9260`,
`c:0x8a9560`). The plus is OptLevel + the advanced elixir. OpenSRO's stat refresh is its stats
result (`OpCharacterStatsResult`, the same push buffs use, `pushOwnerStats`).

## The avatar list: OURS 0x0044 -> 0x0045

OpenSRO has no 0x3013 (the character data). The client asks for its avatar inventory as it asks for
the bag and the worn list:

- **0x0044** (client -> server, OURS): the bag list's request -- the character name
  (`CharacterNameRequest`: u16 length + bytes) -- or an empty body for the session's character in the
  world. A request naming no character of the session's is not answered (OURS: an empty section
  would read as "wears none").
- **0x0045** (server -> client, OURS carrier): exactly **0x3013's avatar section** (READ
  `c:0x9d9c39..0x9d9cfe`, `s:0x4ba720` mode 1):

```
u8 size (5; the client reads it and discards it), u8 count,
count x (u8 slot (the storage index 0..4), the item record)
```

The item record is the round-732 record (`server/internal/session/iteminfo.go`): `u32 rent (0), u32
RefItemID, u8 OptLevel, u64 Variance, u32 word, u8 MagParamNum, n x u64, binding blocks 1 and 2`.
The word is the durability for a 3/1/13 (0 on every retail avatar) and **the period word** for a
3/1/14: `bit31 = expiry set`, `low 31 = seconds left (0 once past)` (READ `s:0x42e5c3..0x42e63f`).
The bag, warehouse and worn lists carry the same period word for a devil's spirit since this round.

0x0044/0x0045 were free in `server/` and `client/scripts` (grep, 2026-10-16).

## The spawn and the lobby

**0x3015 / 0x3017-0x3019** (READ `s:0x4ba720` mode 2, client `c:0x9de3e2`): after the equipment
list, `u8 size (5), u8 count, count x (u32 RefItemID, u8 plus)` -- no slot byte, storage order. The
client reads the plus **only for a 3/1/13 or 3/1/14 ref** (any other is read as 4 bytes), so only
those are written; an id the server's item table does not know is left out (OURS).
`pcspawn.Record.Avatars`, `pcspawn.AppendAvatarBlock` / `ReadAvatarBlock`.

**Lobby 0xB007** (READ, charselect.md:833-853): `u8 count (<= 5), count x (u32 RefItemID, u8)`. The
client discards the u8. OpenSRO writes the OptLevel there (**INFERRED**: what the ShardManager writes
is not read, AVATAR_RESEARCH.md 4.2 OPEN). Storage order.

## Stats

READ: an avatar's and a devil's spirit's blue options are published by **the same path as
equipment's** -- `CGAvatarInventoryOP::RefreshEquipParamEntryForPC` (`s:0x4bbcd0`) ->
`PublishEquipItemParams` (`s:0x4e3760`) -> `CAlchemyMagicOptionOP::SetParamKeeperForMagicOpt`
(`s:0x66b180`) -> `Stat_ApplyTaggedModifier` (`s:0x498690`): one ParamKeeper entry per item. **No
set bonus.** The tags' params and entry slots, READ from `Stat_ApplyTaggedModifier`'s disassembly
this round (each leaf's `mov edi,N` and the slot it pushes before `ParamKeeper_SetParam 0x4b3510`;
slot 0 flat, 1 percent, 2 multiplier):

| tag | MATTR | param | slot | leaf |
|---|---|---|---|---|
| stra / strv | AVATAR_STR / STR_AVATAR | 1 (Str) | 0 | 0x499123 / 0x49919c |
| inta / intv | AVATAR_INT / INT_AVATAR | 2 (Int) | 0 | 0x498dd0 / 0x498e0b |
| hpa | AVATAR_HP | 3 (max HP) | 0 | 0x4989a6 |
| mpa | AVATAR_MP | 4 (max MP) | 0 | 0x498a12 |
| era | AVATAR_ER | 9 (parry) | 1 | 0x49890f |
| hra | AVATAR_HR | 11 (hit rate) | 1 | 0x498a8e |
| hprg / mprg | AVATAR_HPRG / MPRG | 25 / 26 (regen) | 1 | 0x498d90 / 0x498f32 |
| hpna / mpna | NASRUN_HPNA / MPNA | 52 / 53 | 1 | 0x498cec / 0x498ef4 |
| drua | AVATAR_DRUA | 128..131 (damage dealt %) | 0 | 0x498bfb.. |
| dara | AVATAR_DARA | 174..177 (damage taken x), the value negated (`fchs` 0x498b2e) | 2 | 0x498b35.. |
| luca | AVATAR_LUCK | 173 | 0 | 0x498e8f |
| mdia | AVATAR_MDIA | 188 | 0 | 0x498e42 |
| umdu | NASRUN_UMDU | 259 | 0 | 0x499192 |

`brna` (NASRUN_BLOCKRATE, param 10) branches on the item's `+0x190` first, as `bri` does; its leaf
was not followed (**OPEN**, not applied).

OpenSRO adds these entries to the character's param totals beside its buffs' and passives'
(`charTotals`), so every stat read through them counts them: Str and Int, max HP and MP, parry, hit
rate, damage dealt %, and -- this round -- the regeneration tick (`regen.go` now evaluates params
25/26 with their entries, as `EvaluateParam` does). **Not read by OpenSRO's combat yet (OPEN):** 52,
53, 173, 188, 259, and 174..177 on a player. Recomputed on every move, grant and expiry; the stats
result is pushed after a move.

**Conditions** (READ): no rental expired (OpenSRO has none); a devil's spirit only while awake;
`PublishEquipItemParams` also runs, for a 3/1/14, its opt-level ability step `FUN_00498020(2)`
(`RefMagicOptByItemOptLevel` / `RefAbilityByItemOptLevel` by RefItemID + OptLevel). **OpenSRO loads
neither table: the devil's spirit's opt-level abilities are not applied (OPEN); its own blue options
are, while awake (OURS: the missing tables are not read as the step failing).**

## The devil's spirit

| | | label |
|---|---|---|
| awakening | `CGItemEquip::vslot_325` (`s:0x498060`): an expiry already set -> 2; else expiry = now + itemdata Param1 seconds (MEASURED 2,419,200 = 28 d on 22 rows, 604,800 on 4) | READ |
| what calls it | OPEN in retail. OURS: using the devil's spirit in the bag (`OpUseItem`, `avataruse.go`); the item is not spent. CanUse (col 24) is 1 on all 3/1/14 rows (MEASURED) | OURS |
| wearing it | refused 0x18f9 unless awake | READ |
| expiry while worn | `DetachAbilityByItemOptLevel` (`s:0x4bbd60`, run on every storage op): its params removed, owner told **`0x3078: u8 3, u8 avatarSlot`**; the item stays | READ |
| OpenSRO's expiry | a timer at the expiry (armed at the move, the list request and the world entry) does the same: stats recomputed, `0x3078 {3, slot}` to the owner, the stats pushed. OURS: retail's check rides the storage operations | OURS |
| Nasrun extension 3/3/13/16 | `UseByKind` case 0x10 (`s:0x49c2b0`): target slot outside 13..111 `0x1882`; no item or not 14 `3`; never awakened `0x18f8`; else the expiry moves by its Param1 (from the old expiry while ahead, from now once past: INFERRED); one extension spent | READ / INFERRED |
| extension on OpenSRO's wire | `OpUseItem` with the target's wire slot (bag + 13) in the option byte after the item's slot (OURS). The `0x3078` retail sends after it (three fields) is **OPEN, not sent** | OURS / OPEN |
| reinforce | FUN_00507fe0: a devil's spirit whose itemdata Param2 (col 120) is not 1 -> 0x540f (MEASURED: the two 7-day event rows); OpenSRO's alchemy makes this test now | READ |

## Integrity at the world entry (OURS choice)

`CGAvatarInventoryOP::CheckAvatarsetIntegrity` (`s:0x4bb8a0`), per slot in order: not an avatar
item; the other gender (ReqGender != the character's and != 2); a TID already seen; OptLevel >= 251.
A Country mismatch does **not** fail it. Retail runs it at `CGObjPC::Create` and refuses the login
(`s:0x4e0dc0` -> `FUN_004df050(4)`).

**OURS:** OpenSRO moves each failing item to the bag at the world entry and logs it; it refuses the
entry only when the bag has no room (the reply's reason names it). Why: every failing state is
reached only from outside the game -- an operator's item table changing a row, a database edit, a
bug -- and retail's answer locks the character out until an operator repairs the database. Moving
the item keeps it and restores what retail checks.

## Housekeeping

- **Death:** the penalty draws only from the PC inventory (READ `s:0x4e6c22`); OpenSRO's takes
  experience only. Avatars are never dropped.
- **Durability:** nothing in the avatar storage loses durability (OpenSRO's loss walks the equipment
  store; `SetBrokenFlag` exempts `+0x454` items, READ).
- **Drop, sell, trade, store:** no move type takes the avatar storage anywhere but the bag (READ
  `c:0x7950b0`, `c:0x871940`); from the bag the item's own flags apply, as for any item.
- **The Test Items NPC** sells avatars plain: +0, no options, a devil's spirit not awakened (OURS),
  so the grant and the awakening have something to do. docs/protocol/test_items_npc.md.

## The grant at the blacksmith: 0x34A9 -> 0x34AA

READ (AVATAR_ALCHEMY_RESEARCH.md section 1): seven blacksmiths offer interaction **0x20**
(`gs:0x4c6793..0x4c6879`, codename substrings `NPC_CH_SMITH`, `NPC_WC_SMITH`, `NPC_KT_SMITH`,
`NPC_EU_SMITH`, `NPC_CA_SMITH`, `NPC_SD_M_AREA_SMITH`, `NPC_SD_T_AREA_SMITH`) -- already in OpenSRO's
interaction rules (`npcspawn/interactions.go`). The talk line sends `0x7046 {u32 npc, u8 0x20}`;
OpenSRO's open answers `0xB046 {1, 0x20}` and sets INTERACTMODE 6 (`npctalk.go`, the default arm),
which opens `CIFGrantMagicAttributeWnd` in the client.

```
0x34A9  u8 slot (bag index + 13), u16 n, n x ASCII (the MATTR_ code)
0x34AA  success: u8 1, u8 flag (1), u8 slot, the item record
        refusal: u8 2, u16 code
```

The rule (`gs:0x5079c0`, `CBless_AvatarItemWithNPC::_BlessItem gs:0x505810`), in order:

| # | rule | code |
|---|---|---|
| 1 | slot outside 13..111 | 9 |
| 2 | no item there (or an expired rental) | 3 |
| 3 | not a non-bionic 3/1/13 (any TypeID4; the window refuses 13/4 and 14 itself) | 8 |
| 4 | the roll: rate 100, never lost (would be 7) | -- |
| 5 | MagParamNum over the cap (MaxMagicOptCount col 158 + one per `dura`/`nrep` option, max 12) | 6 |
| 6 | empty name or no MATTR group of that name (case-insensitive) | 0xa |
| 7 | no record at the degree `(ItemClass-1)/3+1`, or the record not allowed on the item's kind | 0xa |
| 8 | an option with the record's tag AND id: re-rolled in place (the value can go down; the bless tags atha/luck/soli/astr count up, refused 6 past 6; `rep` past 7, INFERRED); else appended while under the cap, at the cap **2** | 2 / 6 |
| 9 | value = the record's generator, 0 -> 1, over 1699 -> 1700 | -- |

Nothing is spent. The item record of the reply carries the new options; the item is saved in the
bag. The event log (0x94) is not modelled. **OURS:** like retail, no NPC, distance or talk state is
required for 0x34A9 (READ: retail checks none) -- the grant is free, so a request without the window
gains nothing a walk to the blacksmith would not. A body whose name is shorter than its length is
answered 0xa (OURS: retail's reader clamps the length, and the clamped name is not found). The
option table (`-magic-options-csv`) is what the grant reads; without it every grant answers 0xa.

The retail client lists, for the item's kind, the `magicoptionassign` names it does not carry yet
(MEASURED: hat 6, dress 20, attachment 2) and shows column 9 as the value; the server does not
consult the assign table (READ), so an operator's extra MATTR rows are grantable by name.

## The avatar enchant: alchemy op 7 is dead

READ (AVATAR_ALCHEMY_RESEARCH.md section 2): `CEnchant_EnchantAvatarItem` exists, but its
`_BlessItem` (`gs:0x504170`) reads the option name from a string only its vtable slot 13 sets, and
nothing calls slot 13: it always ends in **2**, nothing spent. The retail client has no sender of
0x34A7 and its alchemy window refuses an avatar (`UIIT_MSG_ENCHANT_LOAD_EQUIP_FIRST`). OpenSRO
answers op 7 the same way, on retail's 0x34A7 (`u8 action`; 2 = start, `u8 n, n x slot`) with
`0x34A8 {2, u16 code}`, and on OpenSRO's alchemy request (op 7 on 0x0113) with the stone reply: the
request's own checks first (slot 0x5414, empty 3, first not equipment 0x5408, the magic stone's
loader 0x5410 / 0x5412), then **2**. OURS: answered at once rather than after the operation's wait.

## GM

`/give <id>` gives any avatar or devil's spirit into the bag. `/avatar` lists the avatar slots;
`/avatar spirit <bag slot> <seconds|0>` sets a devil's spirit's expiry (docs/DEBUG_TOOLS.md).

## OPEN

- Which use path calls `vslot_325` in retail; the `0x3078` layout after a Nasrun extension; when
  `UIIT_MSG_NASRUN_WEAR_EXTENSION_ITEM_NOT_USE` fires.
- The devil's spirit's opt-level abilities (`RefMagicOptByItemOptLevel`, `RefAbilityByItemOptLevel`,
  `RefSkillByItemOptLevel`): no loader in OpenSRO.
- `brna`'s leaf; params 52, 53, 173, 188, 259 and a player's 174..177 have no reader in OpenSRO.
- The lobby u8 (OptLevel assumed).
- `[pc+0x30]+0x13` in StorageOperation's framing; INTERACTMODE 7.
- The client names of 0x1806, 0x1809, 2; what category 0x20 shows for the grant's 2, 3, 9 and 0xb.
- `_STATICAVATAR` / `CInstanceStaticAvatar`.
