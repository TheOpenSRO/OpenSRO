# Ground items: dropping and picking up

How the real server (SR_GameServer.exe) handles an item lying on the ground,
recovered by reading the pick-up path, and what srrevamp built on it.

## The object

A dropped stack is a `CGItem` (`CGItem : CGObj : IGObj : CBase`). Its fields,
from the constructor `CGItem::vslot_000` (`0x0048f8a0`) and `CGItem::Update`
(`0x0048f9b0`):

| offset | meaning |
|---|---|
| `+0x14c` | busy: a pick is in progress (refuse others with `0x1813`) |
| `+0x150` | owner id; 0 = anyone may pick it |
| `+0x158` | elapsed seconds since the drop (accumulated in `Update`) |
| `+0x160/+0x164` | the drop's world position (set in `CGItem::Create`, `0x0048f930`) |

## Picking up

`GObjPC::CheckCanPickUp` (`0x004a9050`), reached through `CGObjPC::vslot_387`,
decides a pick. In order:

1. **The object, then `IGObj::CanPick`.** The function opens with
   `*param_2 = 3` and returns false with that **3** still standing when the id
   resolves to no object (`FUN_00485d90`) or `IGObj::IsItem` (slot 18) says no
   -- a drop that has already been picked up or has decayed. Then
   `IGObj::CanPick` -- vtable **slot 53**, named by the engine's own
   `"## Illegal ##  IGObj::CanPick Entered! TypeID: %u"` stub (`0x0057df40`);
   a zero is refused **`0x1839`** `UIIT_MSG_STRGERR_CANNOT_BE_PICKED`
   (`error_emitters.tsv`, the `0x004a9050` row). All seven `CGItem*` vtables
   (`0xae9384` .. `0xaeb824`, the ones holding `CGItem::Update` at slot 211)
   hold `CGObj::CanPick` (`0x00483e50`) there: `IsItem`, then the ref row's
   flags word `+0x8c >> 5 & 1`. So it is a **per-row bit, not "is this a
   ground item"**: bit 5 is **itemdata column 21**, whose byte
   `RefObjCommon_ExtractData` stores at `0x6a3464` (`mov [esp+0x23],dl`, after
   the column bump at `0x6a3455`) and folds in at `0x6a3590` (`and eax,0x20`)
   -- see `item_capability_flags.md`, round 460's table. Over
   `/var/tmp/tables/itemdata_all.utf8.txt` the column is 0/1 only and **0 on
   309 of 21,552 rows** (210 of 15,333 ids): all 54 starter `_DEF` ids, 34
   fortress `ITEM_FORT_*` ids, `_RARE_ACTIVE_STARTER` and `_SUPER` gear, guard
   COS items and a scatter of mall and event items. Gold (`ITEM_ETC_GOLD_01..03`)
   and the HP/MP potions read 1.
   Next, for an item whose slot 46 (`IGObj::IsQuest_n_EventItem`) says yes,
   the picker's quest state is queried -- `vcall +0x144` with `(0xf, 0, item)`,
   then the dword at the picker's `+0x13c`; for a pet (slot 14, `IsPet`) the
   pet's owner at `+0x1cd8` stands in -- and a zero there is refused
   **`0x1874`** `UIIT_MSG_STRGERR_CANNOT_BE_PICKED_AT_QUEST_ACHIEVE_CONDITION`.
2. **Range**: the caller passes a limit -- the player path
   `.rdata 0xb45b44 = 10.0` (`CGObjPC::vslot_387`), the pet path
   `0xb462b4 = 2000.0`. The distance is the plain 3-D
   `sqrt(x²+y²+z²)` of `FUN_00405270`; beyond it, result **4**. After the
   range, a life state (vtable `+0xf8`) other than 2 answers **3**, and a busy
   item (`+0x14c` non-zero, a pick in progress) **`0x1813`**.
3. **Ownership**: the item's `+0x150` (`-1` there answers result 3). An owner
   of 0, or the picker's own id, may pick. Anyone else goes through, in order
   (player path from `0x4a93bf`; the pet path from `0x4a9249` joins it at the
   exclusion):
   - **the owner must be in the world.** The owner id is resolved to an object
     (`FUN_00485dc0`, `0x4a93d1`; the pet path's is `0x4a92ec`). When none is
     found the result is **1** and the function returns false (`0x4a93e1`,
     `0x4a92fc`). What the caller does with that pair was not read.
   - **the picker must be a PC** (vtable slot 7, `IGObj::IsPC`, `0x4a93f4`),
     else **0x1812**.
   - **the TypeID 3/3/9 exclusion** (`0x4a930d`-`0x4a9350`). The item's TID
     (`CGObj::GetTID`, `0x00485c90`: the ref row's `+0x80` word) goes to
     `FUN_0042fdc0` (`0x4a931b`), which answers 1 only for bit 1 clear,
     `& 0x1c == 0xc`, `& 0x60 == 0x60` and `& 0x780 == 0x480`: **TypeID
     3/3/9** in the layout `damage_pipeline.md` records ("The TID layout").
     For such an item the codename (vtable `+0xe8`) is compared with
     `CompareStringA(0x400, 0, codename, 0x13, "ITEM_QNO_RM_ARCHEMY", 0x13)`
     (string at `.rdata 0xaebf58`, import `0xad90b8`, call at `0x4a9342`);
     unless that answers `CSTR_EQUAL` the result is **0x1812** (`0x4a934d`)
     and the party test is never reached.
   - **the party test** (`0x4a9360`): picker and owner both in a party
     (`+0x1cb8`), the same `PartyID` (`0x4ea280`), and the party's flags
     (`GetPartyFlags`, `0x4ea200`) `& 2`, item sharing. Pass: allowed; fail:
     **0x1812**.

   So while an item is owned, a non-owner, party member or not, is refused
   every TypeID 3/3/9 item except `ITEM_QNO_RM_ARCHEMY*`. Measured over
   `/var/tmp/tables/itemdata_all.utf8.txt` on the RE box, with its ten glued
   lines split (round 495; recounted in round 501, which found one 3/3/9 row,
   `ITEM_QNO_SD_NO_053_1`, hidden in a glued line): 914 rows are 3/3/9 (bit 1
   clear on all), 755 of them `ITEM_QNO_` rows (549 of the 608 ids) and 159
   other event and quest-type items (`ITEM_ETC_E...`, `ITEM_QCX_...`). All 18
   tradeable `ITEM_QNO_` rows are 3/3/9: the 16 `ITEM_QNO_RM_ARCHEMY_1..8` rows
   pass the name compare, the 2 `ITEM_QNO_RM_MEETROC_6_01` rows do not.

   **So the exclusion is not a quest-item rule; it keys on the TypeIDs.** By
   distinct id the 690 3/3/9 ids are 549 `ITEM_QNO_`, 113 `ITEM_ETC_` event
   items (102 of them `ITEM_ETC_E...`, 11 Halloween, Japan and Taiwan event
   items), 17 `ITEM_QCX_`, 10 `ITEM_QSP_` and 1 `ITEM_EVENT_`. Who it
   affects -- the 682 not named `ITEM_QNO_RM_ARCHEMY*`:
   - **594 bound ids** (`CanTrade` 0: 540 `ITEM_QNO_`, 17 `ITEM_QCX_`, 16
     `ITEM_ETC_E...`, 10 `ITEM_QSP_`, 10 other `ITEM_ETC_`, 1 `ITEM_EVENT_`)
     are owner-only for their whole DecayTime;
   - **88 tradeable ids** -- 86 `ITEM_ETC_E...` event items (such as
     `ITEM_ETC_E100401_GOLDEN_B`), `ITEM_QNO_RM_MEETROC_6_01` and
     `ITEM_ETC_JAPAN_EVENT_GIFTBOX` -- are owner-only for their 30 s window
     and anyone's after it.

   **srrevamp's `PickCheck` models the owner, the TypeID 3/3/9 exclusion and
   the party test (round 497).** `grounditem.OwnerOnlyPick(TypeID1, TypeID2,
   TypeID3, CodeName)` is the exclusion: true for TypeID 3/3/9 unless the
   codename begins `ITEM_QNO_RM_ARCHEMY`, compared case-sensitively (the
   `CompareStringA` flags are 0, which is common in this binary. Recounted in
   round 501: `srv.asm` has 157 DIRECT `call DWORD PTR ds:0xad90b8`, of which
   113 push `0x10001` (`NORM_IGNORECASE|NORM_IGNOREKANATYPE`), 38 including
   this one push 0, 5 push `ebx` and 1 pushes a caller's argument
   (`[ebp+0xc]`, `0x9f4fbf`). Each `ebx` site follows an `xor ebx,ebx` in its
   function with no other write on the straight line read, so by that linear
   read they pass 0 as well. A further 34 sites load the import into a
   register first (14 `ebp`, 8 `ebx`, 7 `edi`, 5 `esi`) and call through it;
   their flags were not counted. **Lead:** two of the `ebx` sites are
   themselves `ITEM_QNO_RM_ARCHEMY` compares behind the same `FUN_0042fdc0`
   3/3/9 test -- `0x4d557c` in `GObjPC::FUN_004d5510` and `0x525f50` in
   `FUN_00525dc0`, the second followed by a party test on `+0x1cb8` and flags
   `& 2` -- so the exclusion has at least two more users; neither function
   was read.) `strings.HasPrefix` compares bytes;
   the engine's compare is linguistic (`LOCALE_USER_DEFAULT`), which can pass
   over characters that carry no sort weight (the review named NUL and the
   soft hyphen `0xAD`). The two can only differ on characters outside `A-Z`,
   `0-9` and `_`, and all 914 3/3/9 rows have codenames made of those alone,
   so they agree on every retail codename. Bit 1 of the TID is itemdata
   column 8, 0 on every item row, so it is not carried. `Drop` resolves the
   answer once into the unexported `Item.ownerOnly`, and `PickCheck` refuses a
   non-owner of an owned `ownerOnly` item `0x1812` before it asks the party
   rule. Like the engine's, the rule applies only while the item is owned: an
   owner of 0 is let through (`0x4a93c8`) before `0x4a930d` is reached, so a
   tradeable 3/3/9 item (`ITEM_QNO_RM_MEETROC_6_01`) is anyone's once its 30 s
   window has released it. The codename is new reference data:
   `refdata.Item.CodeName`, itemdata column 2 (`RefObjCommon_ExtractData`'s
   first string read, `0x6a3130`/`0x6a3139`, into `ref+0x10`, which
   `CGObj::GetCodeName` (`0x004824c0`, slot 58) returns), exported as CSV
   column 70 and stored in `items.code_name`. **An empty codename -- an export
   that predates the column -- answers not owner-only**, srrevamp's own rule:
   without the name the eight `ITEM_QNO_RM_ARCHEMY_1..8` ids cannot be told
   from the other 682 3/3/9 ids (690 distinct over the combined itemdata), so
   such a deployment keeps the party rule for every item until it re-exports.

   It does not model the absent owner: the party rule
   (`session.samePartyFunc`) asks party membership, not whether the owner is in
   the world. That is a **known, unmodelled divergence**.

**srrevamp's `PickCheck` follows that order (round 493):** a gone id answers
`ErrNotThere` (3); an item whose row clears `CanPick` answers `ErrCannotPick`
(`0x1839`) to everyone, its owner included, before the range, the busy flag and
the owner are looked at; then the range (4), the busy flag (`0x1813`, moved
after the range to match the engine) and the ownership rule. The `CanPick`
answer is taken once, at `Drop`, from the hub's rules lookup
(`Hub.SetRulesLookup`, `DropRules.NoPick`; `cmd/server` wires it to
`refdata.Item.CanPick` through `groundDropRules`; no lookup, an unknown item or
a failed lookup means pickable). Since round 497 that one lookup answers
everything a drop needs -- DecayTime, CanTrade, CanPick and the owner-only
exclusion -- from a single `GetItem`, called before `Drop` takes the hub's
lock; before it, `Drop` made three reference-data lookups while holding it.
The quest-condition refusal (`0x1874`) is not modelled: srrevamp has no
quest-achieve condition to ask. The life-state test has nothing to act on,
since every item in the hub is on the ground.

## The ownership window

`CGItem::Update` (`0x0048f9b0`) adds the frame delta to `+0x158` and compares it
against `.rdata 0xb45e58 = 30.0` seconds; past it, `GObjPC::FUN_004901c0`
(`0x004901c0`, called at `48fa0b mov eax,esi; call 0x4901c0`) clears the owner
and sends `0x304D [u32 id]` to the zone. So a tradeable drop is the killer's for
30 s, then anyone's.

**The release is gated on `CanTrade` (round 492).** `FUN_004901c0` opens with a
virtual call and returns without touching the item when it answers zero:

```
4901c5  mov edx,[eax+0xc4]     ; vtable slot 49
4901cd  call edx
4901cf  test eax,eax
4901d1  je 0x49020c            ; 0: return -- owner kept, no 0x304D
4901d3  cmp dword [esi+0x150],0
4901da  je 0x49020c
4901e2  mov dword [esi+0x150],0 ; clear the owner, then send 0x304D
```

`+0xc4` is slot 49. All seven vtables that hold `CGItem::Update` at slot 211
(`0xae9384`, `0xae9934`, `0xae9e5c`, `0xaea394`, `0xaea9ec`, `0xaeb2b4`,
`0xaeb824`) hold `CGObj::CanTrade` (`0x00483d50`) there: `CGObj::IsItem`
(slot 18, `0x00482d80`), then the reference row's flags word `+0x8c & 1`, which
is itemdata column 16 (`item_capability_flags.md`). An item whose `CanTrade` is
0 is therefore never released: `Update` calls the release on every tick once
past 30 s, and every call returns at `4901d1`. It stays reserved to its owner
until `CGObj::Update` removes it at its DecayTime. A same-party member does not
share that reservation for most of these items: 737 of the 834 untradeable
`ITEM_QNO_` rows below (540 of the 599 ids) are TypeID 3/3/9, which
`CheckCanPickUp` refuses every non-owner before its party test ("Picking up",
step 3, `0x4a930d`-`0x4a9350`). Only the other 97 rows (59 ids; TypeID3 13, 1,
2 or 3) reach the party rule.

Which items that is: in the combined itemdata on the RE box
(`/var/tmp/tables/itemdata_all.utf8.txt`, which repeats ids across its source
files; its ten glued lines split, round 501's recount), the `ITEM_QNO_` quest
items are 852 rows and 608 distinct ids. 599 of the ids (834 of the rows) carry
`CanTrade = 0`; the other 9 ids (18 rows:
`ITEM_QNO_RM_ARCHEMY_1..8` and `ITEM_QNO_RM_MEETROC_6_01`) carry 1. Every one
carries DecayTime 180000 (three minutes). Gold (`ITEM_ETC_GOLD_01..03`) and the
HP/MP potions carry `CanTrade = 1` and DecayTime 10000, so they are unaffected
-- and they vanish before the 30 s window ends anyway.

The release has a second caller, `0x4e98b7`, in a job handler that asserts the
item's `+0x150` is `-1` and chooses between it and `FUN_004901b0` on
`[ebp+0x118]`; srrevamp models no such reservation, so only the 30 s path is
wired.

srrevamp: `grounditem.Item.Bound`, set at `Drop` from the hub's rules lookup
(`DropRules.Bound`; `cmd/server` wires it to `refdata.Item.CanTrade` through
`groundDropRules`). A bound item's `OwnerAt` keeps its owner and
`ReleaseOwnerships` skips it, so the zone is never sent
`OpGroundItemOwnerReleased` for it. With no lookup, or for an item the
reference data does not know, nothing is bound. A bound 3/3/9 item is also
owner-only ("Picking up", step 3, modelled since round 497), so for its whole
DecayTime only its owner may pick it, party or not -- as in the engine.

## Not recovered

- ~~**How long an unclaimed item lies there before it vanishes.**~~ **Read in
  round 227** (`refobj_binary_format.md`, "Field 14 of the common prefix is
  DecayTime"): the item's own `DecayTime`, itemdata column 13, in ms, counted by
  `CGObj::Update` (`0x484d10`). The 3 minutes srrevamp used before is now only
  `grounditem.FallbackLifetime`, for an export without the column.
- **The drop's scatter around the corpse.** Set in the spawn path, not in
  `CGItem`; srrevamp uses a 2-unit disc, own design.

## srrevamp's protocol (own, additive)

Server `internal/session/grounditem.go`, client `scripts/net/ground_items.gd`:

| op | dir | payload |
|---|---|---|
| `OpGroundItemList 0x006a` | c→s | (empty) -- what lies in my zone |
| `OpGroundItemListResult 0x006b` | s→c | u16 count, then snapshots |
| `OpGroundItemSpawned 0x006c` | s→zone | one snapshot |
| `OpGroundItemRemoved 0x006d` | s→zone | s64 id, s64 reason (0 picked / 1 expired), s64 picker |
| `OpGroundItemOwnerReleased 0x006e` | s→zone | s64 id (the real 0x304D) |
| `OpPickUp 0x006f` | c→s | name string, s64 ground id |
| `OpPickUpResult 0x0079` | s→c | s64 code (0 or an Err*), s64 ground id, s64 item id, u32 qty, u8 gold |

A snapshot is: s64 id, s64 item id, u32 quantity, u8 gold, f32 x/y/z, s64 owner
(0 = free). The refusal codes are the engine's (`3`, `4`, `0x1812`, `0x1813`,
`0x1839`); the handler also answers `0x1839` for its own failures the engine has
no code for (an undecodable request, an unknown character, a bag or purse that
will not take the stack). Until round 493 a gone drop answered `0x1839` too; it
now answers `3`, and the client's refusal line tells the two apart. Since round
515 the refusal line for `0x1812` and `0x1839` is the game's own text, read from
the player's `textuisystem.txt` (`UIIT_MSG_STRGERR_LOCKED_BY_OTHER_ONE`,
`UIIT_MSG_STRGERR_CANNOT_BE_PICKED`, `client/scripts/net/error_text.gd`). `3`,
`4` and `0x1813` keep srrevamp's own wording: the client's storage switch has no
case for `4` or `0x1813`, and `3` is category-dependent. The drop
CONTENT (`combat.LootTables`) stays placeholder own design; the real per-monster
drop tables are DB-only and unavailable.
