# Player stalls (round 839, lane S)

What the original game does when a player opens a stall, lists items, others see the booth and the
stall's name, enter, buy, and the owner closes it -- and what OpenSRO builds of it. The Stall Network
(remote search and buy, `CIFStallNetwork`, `ifstallnetwork*.txt`, 0x3c41..0x3c53, the ware-network
kind of 0x30B7) is out of scope.

**Labels.** READ: read in the code -- `s:` SR_GameServer.exe (`/var/tmp/decomp_server`, `srv.asm`),
`c:` sro_client.exe (`/var/tmp/decomp_client`, `sro_client.asm`) on the render box -- or in the
archive (Media.pk2, read on the box; nothing copied into the repo). MEASURED: counted or measured on the
box. INFERRED: concluded, with the reason. OURS: OpenSRO's own choice. OPEN: not settled.

Code: `server/internal/stall` (the hub, the sale store), `server/internal/session/stall.go` (the
handlers), `client/scripts/net/stall_net.gd`, `client/scripts/world/stall_world.gd`,
`client/scripts/ui/hud/stall_controller.gd`, `stall_window_view.gd`.

## 1. The objects (READ)

- The stall object S is pooled; a manager at `[0xd6a954]` maps the owner's uid to it (mgr+0x5c).
  S+8 the owner's uid, S+0xc the owner, S+0x10 the name, S+0x2c the greeting, S+0x48 the open flag
  (0 modifying -- the start, s:0x471b70 -- 1 open), S+0x49 the "type 4" byte (0..2, meaning OPEN),
  S+0x50 + i*0x20 the ten slots (u64 item DBID, u8 bag slot -- 0xff empty --, u16 count, u64 price,
  the item, a u32 the client sends), S+0x194 the participant vector (the owner first, s:0x471e57),
  S+0x1a0.. an embedded trade session for the sale in progress (+0x1a4 = 5 while one is pending).
- On the character: pc+0x1cc4 points at the stall it is in; chardata+6 (INTERACTMODE) is **4 for the
  owner and 2 for a visitor** (FUN_00515e90 s:0x515e90).
- The client: CICUser +0x471 (the interaction byte, 4 while stalling), +0x798 the title "[name]",
  +0x790 the decoration, +0x78c the booth object, +0x474 the plate item the title is drawn in.

## 2. The wire

Strings are a u16 length and the bytes (client: c:0x4fc870 / 0x53d880 write, c:0x4f7a70 / 0x4fc700
read, CP_ACP). A refusal is `{u8 2, u16 code}` (s:Msg_SendTwoFieldReply 0x4e7250); success `{u8 1, ...}`.

| Opcode | Dir | Body | Server | Client |
|---|---|---|---|---|
| 0x70B1 | C->S | `str name` | s:0x515f10 | c:0x81df20 |
| 0xB0B1 | S->C | `{1}` | | c:0x872040 |
| 0x30B8 | S->view | `u32 owner, str name, u32 decoration` | s:0x4723c0 (0x472410..0x472476) | c:0x873c10 |
| 0x70B2 | C->S | empty (the owner) | s:0x516130 | c:0x81e0d0 |
| 0xB0B2 | S->C | `{1}` | | c:0x8720f0 |
| 0x30B9 | S->view | `u32 owner, u16 reason` | s:0x472cf0 (0x472d5a..0x472d98) | c:0x8721b0 |
| 0x70B3 | C->S | `u32 owner` | s:0x516270 | c:0x81e170 |
| 0xB0B3 | S->C | `{1, u32 owner, str greeting, u8 open, u8 value4, list, u8 n, n x u32 uid}` | s:0x516497, 0x473560 | c:0x873ff0 |
| 0x70B4 | C->S | `u8 slot` | s:0x516560 | c:0x81e2f0 |
| 0xB0B4 | S->C | `{1, u8 slot}` | s:0x4735a0 | c:0x872500 |
| 0x70B5 | C->S | empty (a visitor) | s:0x5164c0 | c:0x81e250 |
| 0xB0B5 | S->C | `{1}` | | c:0x872450 |
| 0x70B6 | C->S | skipped (index 0x0b6, s:0x516250) | | no sender |
| 0x70BA | C->S | `u8 type, ...` (below) | s:0x5161b0 -> 0x472e20 | c:0x81e3b0 (jump table c:0x81e674) |
| 0xB0BA | S->participants | `{1, u8 type, ...}`; a refusal to the owner only | s:0x516217 | c:0x878230 (c:0x878720) |
| 0x30B7 | S->participants | `{1, u32 uid}` left, `{2, u32 uid}` came, `{3, u8 slot, str buyer, list}` sold | s:0x472490, 0x4725d0, 0x47375a | c:0x87a260 |
| 0x30BB | S->view | `u32 owner, str name` | s:0x472eb7 | c:0x873d60 |
| 0x7160 | C->S | `u32 key, u32 decoration` (the avatar stall's Yes) | s:0x511730 -> 0x654790 | c:0x803e00 -> 0x821850 |

**A list** (s:FUN_00471f90, c:0x872290): for each occupied slot `u8 slot, item record (the item's
vslot 0x498 mode 1; client SOItem::FUN_008be4f0(stream, 1), the record 0x3013 and the exchange read),
u8 bag slot (+13), u16 count, u64 price`; then `u8 0xFF`.

**0x70BA's types** (request after the type byte; the success reply after `{1, type}`):

| Type | Request | Reply |
|---|---|---|
| 1 price | `u8 slot, u16 count, u64 price, u16 net` | `u8 slot, u16 count, u64 price, u16 0` |
| 2 add | `u8 slot, u8 bag slot + 13, u16 count, u64 price, u32 group, u16 net` | `u16 0, list` |
| 3 remove | `u8 slot, u16 net` | `u16 0, list` |
| 4 | `u8 v` (no client sender, OPEN) | `u8 v` |
| 5 open / modify | `u8 open, u16 net` | `u8 open, u16 0` |
| 6 greeting | `str` | `str` |
| 7 rename | `str` | nothing more (and 0x30BB to view) |

`net` is the Stall Network's (4 / 2 / 5 / 3 while +0x864 is set); 0 for a plain stall (READ c:0x6b9940,
c:0x6b4b8b). `group` is the item's TidGroupID (below).

**The spawn record** (s:CGObjPC::vslot_293 0x4e5ee6..0x4e5f4f; c:CICUser vslot 23 0x9ddc40, the
interaction byte at c:0x9ddee9, the block at c:0x9de103..0x9de1bd): when the interaction byte is 4,
`str name, u32 decoration` follow the guild block and come before the timer and team bytes. A visitor
(mode 2) carries no block.

## 3. The codes

The client shows category 10 (`FUN_00778190(10, code, 0xffdbc99b, 0, 1)` -> c:0x7b8b40 case 10); codes
it does not list show nothing. English: the archive's first row; this client draws the stock row of the
joined textuisystem (round 725's user decision) where the two differ.

| Code | When (server) | Text key | English (first row) |
|---|---|---|---|
| 0 | 0x70B3: the target not found / not seen and not in the party (IsWithinInteractionRange s:0x4a8e10) | -- | -- |
| 2 | 0x70B4: a sale already pending; the owner's state broken (both disconnected); DealIt's COS check | -- | -- |
| 3 | 0x70B3: not a player | UIIT_STT_ERR_COMMON_INVALID_TARGET | Invalid object |
| 4 | 0x70B3: past 600.0 (.rdata 0xb46198) or 100.0 (0xb45af0, s:0x5163c1) | UIIT_STT_ERR_COMMON_TOO_FAR | The object is too far. |
| 5 | 0x70B4 the owner buying; 0x70BA a sale pending or a type outside 1..7 | UIIT_STT_ERR_COMMON_INVALID_OPERATION | Invalid command |
| 0x3c06 | 0x70BA 2: a worn slot (< 13) or no item there | -- | -- |
| 0x3c07 | 0x70BA 1/2: not the whole stack, or past MaxStack | -- | -- |
| 0x3c08 | 0x70BA 1/2: price < 0 or > 9,999,999,999 | UIIT_MSG_FLEAMARKET_ERR_INVALID_PRICE | Can set the value only from 1 to 1 billion gold. |
| 0x3c09 | 0x70B1 / type 7: name 0 or > 64 bytes | -- | -- |
| 0x3c0a | type 6: greeting > 64 bytes | -- | -- |
| 0x3c0e | close reason: the owner died (s:0x529ca4, 0x52cf05) | UIIT_MSG_FLEAMARKET_ERR_MARKET_CLOSED | Closed the shop. |
| 0x3c0f | 0x70B4 outside a stall or not a participant; 0x70B5 outside a stall (then disconnected) | -- | -- |
| 0x3c10 | 0x70B4 / 0x70BA 1/2/3: slot >= 10 or empty | -- | -- |
| 0x3c11 | 0x70B4: buyer's gold < price (s:0x472883) | UIIT_MSG_FLEAMARKET_ERR_NOT_ENOUGH_GOLD | Cannot buy due to insufficient gold |
| 0x3c12 | 0x70B4: no empty bag slot (s:0x4728b3) | UIIT_MSG_FLEAMARKET_ERR_INVENTORY_FULL | Cannot buy due to insufficient space in your inventory. |
| 0x3c13 | type 2: the bag slot already listed | -- | -- |
| 0x3c14 | 0x70B1: the owner already has a stall (s:0x474267) | -- | -- |
| 0x3c15 | close reason: warp, logout, disconnect (s:0x4def5a) | UIIT_MSG_FLEAMARKET_ERR_HOST_LEFT | The shop is closed. |
| 0x3c16 | 0x70B1 / 0x70B3: the world check (s:0x515d10 -> 0x529880) | UIIT_MSG_FLEAMARKET_ERR_IM_BUSY | You are in the status of being unable to open a new shop. |
| 0x3c17 | close reason: the owner's 0x70B2 | UIIT_MSG_FLEAMARKET_ERR_CLOSED_BY_HOST | The shop is closed. |
| 0x3c18 / 0x3c19 | CheckHasRoom: full (8) / already inside -- **sent as 0x3c2a** | (MARKET_FULL) | (The member limit(8) has been reached.) |
| 0x3c2a | 0x70B3 no stall / full / inside; 0x70B2, 0x70BA not the owner | -- | -- |
| 0x3c2b | 0x70BA 1/2/3/7 while open; type 4 value >= 3 | UIIT_MSG_FLEAMARKET_ERR_INVALID_HOST_STATE | The shop is under construction. |
| 0x3c2d | type 2: not tradable (CanTrade) or a trade good (3/3/8) | -- | -- |
| 0x3c2e | 0x70B4: not open (s:0x472782) | -- | -- |
| 0x3c2f | close reason / 0x70B4: the DB job failed (both logged out) | -- | -- |
| 0x3c30 | type 2: all ten slots taken | -- | -- |
| 0x3c31 | type 5: open >= 2 | -- | -- |
| 0x3c32 / 0x3c33 | the quest block 0x200: 0x3c32 on 0x70B1 (s:0x515f4c..0x515f6a), 0x3c33 on 0x70B3 (s:0x5162a9..0x5162c8); no quest sets the bit (section 11) | -- | -- |
| 0x3c34 | 0x70B1: riding | UIIT_MSG_FLEAMARKET_ERR_CANT_OPEN_MARKET_IN_RIDESTATE | Cannot open the shop while boarding the vehicle to move or transport. |
| 0x3c38 | client: the title's word filter (c:0x8c3f10, the abuse filter's fourth flag; section 11); OURS from the server too | UIIT_MSG_FLEAMARKET_ERR_NOT_ALLOWED_FMARKETNAME | Invalid letters are included. Invalid name for the shop. |
| 0x3c39 | 0x70B1: murderer (PvP state 2) | UIIT_MSG_FLEAMARKET_ERR_CANT_OPEN_MARKET_MURDERER | Cannot open a new shop during murderer status. |
| 0x3c3a | type 2: a summoned COS's summon item | -- | -- |
| 0x3c3b | 0x70B1 (and the client's Stall action): a job suit | UIIT_MSG_FREEMARKET_NOTUSE_JOB | Cannot open a stall under job status. |
| 0x3c3c | type 2: group 0 | -- | -- |
| 0x3c42 | client: the item's group not in the table (c:0x938370) | UIIT_MSG_WARENETWORK_ERROR_FAIL | Registraion of item on stall network has failed. |
| 0x3c55 | type 2: an awake devil's spirit | UIIT_CTL_NASRUN_NOT_TRADE | You can't trade Devil's Spirit during awaken period. ... |
| 0x3405 | the trade ban `{1, time}` (restriction slot 3) at 0x70B1 and 0x70B3, no reply after it; the chat ban `{0, time}` (slot 4) at 0x70B1 renames the stall (section 11) | UIIT_MSG_GM_PUNISHMENT_TRADE_BLOCK / _CHAT_BLOCK (c:0x86e5b0) | Trading / Chat restricted by GM. Can ... from %dyear %dmonth %ddate %s %dhour %dminute(s). |
| cat 0x12 0x5416 / 0x5417 | client: the alchemy window open at Stall / at a stall click | UIIT_MSG_REINFORCERR_CANNOT_OPEN_FLEAMARKET / ..._CANNOT_JOIN_FLEAMARKET (INFERRED by name) | Cannot open a shop while conducting alchemy. |

## 4. The rules (READ unless marked)

- **Where:** no region, town, safe-zone or distance-to-anything test on the open path (absence READ on
  the traced path s:0x515f10 -> 0x4f0a00, 0x4ddd30, 0x515d10/0x529880, 0x474210, 0x4723c0, 0x471d90,
  0x484d90). The world controller refuses in the battle arena and the flag world (PC slot 0x670/0x660
  -> s:0x559c70 returns 0: 0x3c16).
- **0x70B1's order:** trade ban 0x3405 (no B0B1); quest block 0x3c32; the world check 0x3c16 (not in a
  stall, alive, INTERACTMODE 0, GROUPMODE neither 1 nor 3); riding 0x3c34; murderer 0x3c39; a job suit
  0x3c3b; then a sitter stands (FUN_004b1480(4)), the mover halts (vslot 0x6a8), one stall an owner
  0x3c14, the name 1..64 bytes 0x3c09 (a chat-banned owner's name is replaced by CharName and one of
  eleven suffixes, 0xae6840..0xae68a4), 0x30B8 to view, INTERACTMODE 4, the owner's items protected
  from the death drop (CGStorage::ProtectItemsFromPenaltyDrop(1)), 0xB0B1 {1}. Not tested: level,
  battle state, berserk, being in a party.
- **Size:** ten slots; eight participants -- the owner and seven visitors.
- **Price:** u64 0..9,999,999,999 on the server; the client's price box takes 1..9,999,999,999
  (c:0x634f20(0x2540BE3FF)); the code's text says "1 to 1 billion".
- **Count:** the whole stack only (vslot 0x4e8: an expendable's itemdata+0x38, equipment 1) and not
  above MaxStack (ref+0x198).
- **Refused items:** worn (bag slot < 13), not tradable, trade goods, a summoned COS's item, an awake
  devil's spirit, a bag slot listed twice; the client also refuses CanTrade (category 1 0x183a) and the
  spirit (0x18fa) before the box (SOItem c:0x8baf10), and an item its group table does not name
  (0x3c42).
- **The group** (c:0x938370): `textdata\fmntidgroupmapdata.txt` (RefParse c:0x6d5570: Service,
  TidGroupID, TypeID1..4), keyed by the ref's packed TID with the low two bits cleared; the server only
  refuses 0 (0x3c3c). MEASURED: 137 rows on the box's archive.
- **Name and greeting:** each at most 64 bytes on the server; the client's boxes take 40 and 64
  characters (c:0x634f80). A greeting may be empty.
- **Modify vs open:** add, remove, price and rename only while modifying (0x3c2b); greeting, type 4
  and the toggle at any time; buying only while open (0x3c2e). A modifying stall can be visited.
- **Nobody moves:** the move handler (s:0x4b0ea0) drops a move at INTERACTMODE other than 0 and 1; the
  client refuses walks, target clicks, attacks, action commands and hotkey skills while a stall window
  is shown (c:0x77c8e0), and sit while a booth stands (c:0x9d4a20). StorageOperation refuses every item
  operation at 4 and all but the exchange's at 2 with 0x1834 (s:0x50f7c0).
- **Chat:** type 9 (GObjPC::FUN_004b1750 case 9): no stall answers 5; else 0x3026 `{9, name, text}` to
  every participant, the sender included (FUN_00473bf0 -> BroadcastToParticipants).

## 5. The sale (READ)

0x70B4 (s:0x516560 -> CFleaMarket::SellFMarketItem s:0x472700), in order: owner and buyer present (2);
not the owner (5); the owner's state (else both disconnected, 2); open (0x3c2e); the owner's
MSG_PROCSTATE or a sale pending (2); a participant (0x3c0f); the slot (0x3c10); gold (0x3c11); a free
bag slot (0x3c12). Then both are backed up, the trade session filled -- the buyer -price, the owner
+price, **no tax or fee** (s:0x4729e7..0x472a0e) -- the stack to the buyer's first empty bag slot
(FindFirstEmptySlot(0xd), s:0x472a59), DealIt (s:0x4802a0) in memory: OffsetGold for each side (0x304E
kind 1, no cap -- clamped at 0 only, s:0x4e4b60), the item popped and set. The slot is cleared (the
whole stack sold). The DB job (AQ_ItemXChanger::DoWork s:0x43fb20 kind 1): `_STRG_MOVEITEM_NEW(0x26, 0,
giver, receiver, from, to, 0, count, 0)` and each side's `UPDATE _Char SET RemainGold`. On success
(s:0x4735a0): 0xB0B4 `{1, slot}` to the buyer, 0x30B7 `{3, slot, buyer, list}` to every participant
(the buyer's job alias while a suit is worn). **No 0xB034 is sent**: the clients move the stack in their
own copies (buyer c:0x6bc0c0; owner c:0x6bbff0). On a DB failure the stall closes 0x3c2f and both are
logged out.

## 6. The lifecycle (READ)

- **Close** (FUN_00472cf0): every participant's pc+0x1cc4 = 0 and INTERACTMODE 0; the owner's
  protection off; the BFI1 override cleared (pc+0x21d4 = 0, s:0x472d55); **0x30B9 {owner, reason} to
  view** -- visitors get no packet of their own; a pending sale (or 0x3c2f / 0x3c48) logs both out.
- **Reasons:** 0x3c17 the owner's 0x70B2; 0x3c15 warp, logout, disconnect (FUN_004def00 s:0x4def5a);
  0x3c0e death (CGObjPC::vslot_306 s:0x529ca4, vslot_307 s:0x52cf05); 0x3c2f / 0x3c48 the DB.
- **A visitor's** death, warp, logout or disconnect is the leave path (0x30B7 {1, uid} to the rest) with
  no 0xB0B5 (s:0x4def68, 0x529cb2, 0x52cf13).
- **Attacked:** nothing closes a stall (the four callers above are all). An owner can be attacked as
  any player can (round 840, section 11): its death closes the stall 0x3c0e.
- **The owner's client** sends 0x70B2 itself when a sale leaves no slot (c:0x87a6f0..) and when the
  title fails its name filter (a quirk: the filter fails before 0x70B1 was ever sent).

## 7. The decoration (READ)

FUN_004f0f00 (s:0x4f0f00): the BFI1 override pc+0x21d4 when set, else _STATICAVATAR.Param1 (the last
3/3/3/4 decoration item used; round 838 lane 5). Read at the open (0x30B8) and in the spawn record. The
override is set only by 0x7160 (s:0x511730 -> FUN_00654790, a 3/3/3/4 under a running BFI1 job) and
cleared by every close. The client asks "Establish as an avatar stall?" (UIIT_MSG_PREMIUM_AVATAR_SHOP_USE,
MsgBoxSimple, c:0x793fac..0x794029) when it holds a BFI1 decoration; Yes sends 0x7160 for each
(c:0x788ae0 -> 0x803e00); both answers go on to the title box. The booth (c:0x9dd040): the decoration
ref's AssocFileObj128 (`item\Avatar\booth_*.bsr`, ItemData 3847..3850), else by race 0
`res\item\china\item\cj_store.bsr`, 1 `res\item\europe\item\euro_streetstall01.bsr`.

## 8. The client's windows (READ, the archive and c:)

- **One window, CIFStall** (`GDR_STALL`, ID 33, ginterface's IFStall section, 467x490,
  `mframe_wnd_`, UIIT_STT_STALL), `resinfo\ifstall.txt`; loaded on demand, centred and moved (0, -60)
  (c:0x79be20(1), 0x79be96), created hidden, shown by 0xB0B1 {1} or 0xB0B3 {1}. Owner when +0x7fc is
  this player (c:0x6b97e0).
- **Controls:** OWNERSTATE_ICON (354, 88, 20x20; `stl_condition_icon_01/_02` by state), OWNERSTATE_MSG
  (350, 85; `stl_slot_04`), DISPLAY (CIFScrollManager 22, 108, 423x216), GREETING (48, 327;
  `stl_slot_03`), STALLTITLE (48, 50; `stl_slot_01`), BTN_OWNERMSG (22, 328), BTN_CHANGETITLE (22, 51),
  BTN_TRADINGSTATE (369, 51, 76x24, `com_button`), STALL_CHAT (CIFChatModule 22, 357, 423x110),
  INTERNAL_FRAME and four tiles.
- **The tab** "Items to sell" (UIIT_STT_SELL_GOODS), built in code at (28, 86) 80x24 on
  `com_long_tab_on.ddj` (MEASURED 72x24); "Items to buy" is coded but never built (loop bound 1).
- **The slots:** ten CIFStallSlots (`resinfo\ifstallslot.txt`, 208x44 on `stl_slot_02.ddj`; empty
  `stl_slot_05`) in the manager at (6 + 206 c, 6 + 41 r): the icon (3, 3), the name (46, 6, centred),
  "%d Unit" (42, 26, right), the price with ',' every three digits and " Gold" (86, 26, right; coloured
  by amount, c:0x5d3df0), the modify button (183, 0).
- **State** (c:0x6bab20): open -- icon `_01`, UIIT_STT_TRADING_NOW, button UIIT_STT_END_STALL, title
  button off, modify buttons off; modifying -- `_02`, UIIT_STT_STALL_MODIFYING, UIIT_STT_START_STALL,
  the owner's title and modify buttons on, a visitor's icons at alpha 0x80. The 0xB0BA type 5 reply
  prints UIIT_STT_STALL_CONDITION_START / _END in the window's chat (0xffdbc99b).
- **Boxes:** the title and greeting boxes (MsgBoxInsertMsg, 280x144 and 420x144, prefilled with the
  old title or UIIT_STT_STALL_DEFAULT_TITLE "[%s]'s stall.", and the saved greeting or
  UIIT_STT_STALL_DEFAULT_OWNERMSG "Welcome to [%s]'s stall."); OK on the title before the window is
  shown sends 0x70B1 and type 6 at once. The register and price boxes (MsgBoxStoreMoney purpose 10,
  "Register"), the buy box (purpose 11, "Agreement window", "Buy").
- **Moves:** a bag item put on an empty slot (owner, modifying) -> the register box -> type 2; an own
  slot put on the bag -> type 3; a visitor's slot put on the bag -> the buy box -> 0x70B4; X: the owner
  0x70B2, a visitor 0x70B5.
- **The world:** the title "[name]" in the plate item +0x474 in 0xFFFEB5FF, drawn boxed over the head
  (c:0x9c89a0, 0x9d0d3c..0x9d0d86), 37 px over the name's point (round 840, section 11); round 842: the box is the title item's own
  (c:0x9c89c2 colour, c:0x9c89ca FUN_008b3bd0 text + the 0x40000000 box), so it is drawn where the
  title is; OpenSRO had fitted it once at the name's line, where it widened the name's box. The
  default name is the archive's UIIT_STT_STALL_DEFAULT_TITLE "[%s]'s stall." formatted with the own
  name (c:0x641f40 purpose 0, +0x114), and the plate wraps it again (c:0x9dc3a0), so the original
  shows "[[Tobi]'s stall.]" too; a rename's box is prefilled with the stored title less its first
  and last character (FUN_004779f0(1, len - 2)); the booth drawn with the character's world matrix every frame
  (CICUser::vslot_010 c:0x9dd350); state 0xF, animation type 80 (`chinaman_vendor01.ban`,
  `chinawoman_vendor01.ban`); the cursor 0xa3; a click within 100.0 sends 0x70B3, farther walks there
  first (c:0x7938d5).

## 9. OURS (disclosed)

- The sale is **one database transaction** (`txn.For(chars, inv, sales).Run` with a ledger claim): the
  stack, both golds and a `stall_sales` row (the package's own idempotent DDL, plus a memory store) --
  the item log's place. A failed transaction moves nothing and closes the stall 0x3c2f; nobody is
  disconnected. A sale whose owner leaves meanwhile completes; the stall is gone after it.
- The listing is checked again inside the transaction (the bag slot must hold the listed item, count
  and instance; 0x3c10 and the listing dropped otherwise).
- A seller whose gold would pass the int64 range is refused 2.
- Not made (no OpenSRO state): the murderer state (0x3c39) and the arena / flag world refusal
  (0x3c16) -- one hook each, `session.stallMurderer` and `session.stallWorldRefuses`, answering no
  (round 840) --, and the owner's death-drop protection (OpenSRO drops nothing on death).
- Round 840: the title's word filter runs on the server too (0x3c38 to 0x70B1 and type 7), with the
  operator's `-abuse-filter`; the original runs it in the client only. A trade ban's 0x3405 while
  the window is not shown frees OpenSRO's client for another try.
- A visitor out of the owner's view when the stall closes is sent 0x30B9 too.
- The client asks for its bag list after a sale instead of moving the stack in its own copy; a stalling
  owner is never a GPU ghost (its vendor loop and booth are the full path's).

## 10. OPEN

1. ~~S+0x49 (0x70BA type 4)~~ -- round 840: no meaning anywhere (section 11).
2. `_STRG_MOVEITEM_NEW`'s parameter names (its body is not on the box).
3. ~~Whether a stall owner can be attacked~~ -- round 840: yes, as any player (section 11).
4. ~~How the title stacks against the name and guild lines~~ -- round 840: 37 px over the name's
   point, 17 over the guild line (section 11). The title's box is the plate item's (round 817).
5. The hidden slot ID 210 (+0x850); the slot name's red (c:0x8bd0e0's test).
6. The creator of the type-1001 box (0x8077: an open with net 1).
7. 0x5417's text key (INFERRED UIIT_MSG_REINFORCERR_CANNOT_JOIN_FLEAMARKET).
8. ~~The decoration booths' own animation~~ -- round 840: played (section 11).
9. ~~The owner's summoned pet~~ -- round 840: the own player's COS with a type-80 clip take the vendor
   loop (section 11).
10. The murderer refusal (0x3c39) and the battle arena / flag world refusal (0x3c16) wait for OpenSRO's
    open-world PvP and those worlds; their one hook each is `session.stallMurderer` /
    `session.stallWorldRefuses` (restriction.go).
11. Whether a monster's target choice skips a stalling owner (the INTERACTMODE readers are all trade,
    stall, item and world-entry code; the AI's own acquire was not read).
12. Retail's chat and trade ban flags are cleared by the account side; that it does so at the end is
    INFERRED (OpenSRO treats a slot past its end as clear).

## 11. Round 840 (lane B): the booths, the owner's pets, the refusals

**The booth's animation (READ, MEASURED).** FUN_009dd040 makes the booth a CCObjAnimation, loads the
`.bsr` (c:0x9dd0e0 / 0x9dd13d, `CCObjAnimation::FUN_00a5b4b0`) and plays it at once through its slot 3
(c:0x9dd14f..0x9dd16a: `(0, 0, 0, 0, 1.0, 1.0)` -> `FUN_00a5b550(groups[0] = "default", type 0, A 0, B
0, C 0, speed 1.0, weight 1.0)`): the `default` group's type-0 clip, no fade, speed 1.0, looping or not
as its `.ban`'s IsCyclic says -- the map objects' rule (`MapAnimation.clip_entry`). CICUser::vslot_009
ticks it with the character; vslot_010 puts it at the character's world matrix. MEASURED on the box's
Data.pk2 (11 booth `.bsr`s, two copies of each decoration): `booth_mob_bigeyeghost` (3 bones, 5000 ms),
`booth_mob_earthghost` (9, 5000), `booth_mob_mangyang` (3, 3333), `booth_special_monster_01` (15, 5000),
every one cyclic, 30 fps authored; `cj_store` and `euro_streetstall01` have no skeleton. OpenSRO:
`StallWorld.start_booth` plays ObjectLoader's own `MapAnimation` player on the booth (OURS: Godot's
AnimationPlayer, linear keys, as the map objects).

**The owner's pets (READ, MEASURED).** FUN_009dd040 after the booth (c:0x9dd16c..0x9dd226): state 0xF on
the owner (the vendor loop, type 80), the title; then, only when the owner IsKindOf CICPlayer (the
client's own player, c:0x9dd189 on 0xef1b44), for each entry of the player's COSDataMgr (CICPlayer
+0x20d4, built at c:0x9da91d; `FUN_009d4c70`) with a value, the COS found by uid (FindObjectByID
c:0x9dd1e0) whose animation set has a type-80 entry in group 0 (`FUN_00a5a900(0xec6280, 0x50, 1)` on its
+0x9c, c:0x9dd1fd) enters state 0xF. The close (c:0x9dd29a..0x9dd320) puts every such COS in state 3
(stand), with no clip test. Other players' pets are never touched, in any client. MEASURED (8,539
`.bsr`s in Data.pk2, 18 not parsed, none under `res\cos`): the COS models with a type-80 entry are
`cos\p_jinn.bsr` and `cos\p_jinn_02.bsr` only (`p_jinn_cart_stand01.ban`; the COS_P_JINN growth pets,
140 rows, ITEM_COS_P_JINN_SCROLL); the wolves, foxes, bears, ravens and rides have none and keep their
pose. OpenSRO: World3D `_stall_own_pets` over `NetClient.cos_own`.

**S+0x49, type 4 (READ).** Written only by type 4 (s:0x473341, 0..2, else 0x3c2b) and echoed in 0xB0B3
and 0xB0BA; no other server code reads it (every `+0x49` in s:0x471000..0x475fff). The client reads it in
0xB0B3 into a local it overwrites with the list's first byte before any use (c:0x873ff0), and type 4's
reply (c:0x878230 case 4) reads the byte and breaks. INFERRED a vestige -- perhaps of the "Items to buy"
tab the window codes and never builds. OpenSRO stores and echoes it, as before.

**An owner under attack (READ, INFERRED).** The INTERACTMODE readers (chardata+6, 81 sites in 58
functions) are trade, shop, storage, stall, party, item and world-entry code; no attack, skill or target
function among them, and FUN_00515d40 (the owner test) has 11 callers, all stall, close and spawn code.
The owner's two death paths close the stall (0x3c0e, s:0x529ca4, 0x52cf05) and the open protects its
items from the death drop. INFERRED: an owner can be attacked and killed like any player; the client's
click on a stalling player enters the stall rather than attacking (c:0x7938d5). OpenSRO's monsters may
attack an owner, whose death closes the stall 0x3c0e: as retail. Whether the monsters' acquire skips
one is OPEN 11.

**The title's height (READ).** The title item is drawn at the name's point less half its height (+0x4e)
plus 10 px (c:0x9d0d4d..0x9d0d78); before it, the name pass's event 4 (GlobalDataManager::FUN_009dea30)
has moved that point up 20 px in place (`fld [+0x4f4]; fsub [0xe1b830]; fstp [+0x4f4]`,
c:0x9df0b2..0x9df0cd) for a character in job state 4 (no suit) with the guild-name option on, whether or
not it has a guild. A stall owner is never in a suit (0x3c3b). With the plate item's 14 rows (round 817),
the title stands 20 + 7 + 10 = 37 px over the name's point, 17 over the guild line. OpenSRO:
`StallWorld.TITLE_RAISE_PX` (round 839 had an OURS 22, which put the title on the guild line).

**The bans (READ).** The restriction slots, their setter and the twelve FUN_004f0a00 callers:
`server/internal/session/restriction.go`. The open's order: the trade ban (0x3405 {1}, no 0xB0B1), the
quest block (0x3c32), the world check (0x3c16), riding (0x3c34), murderer (0x3c39), a job suit (0x3c3b),
..., one stall (0x3c14), the name's length (0x3c09), then FUN_00471d90's chat-ban test (s:0x471db6:
0x3405 {0} to the owner, the name replaced by CharName and one of the eleven suffixes at
s:0xae6840..0xae68a4 -- " ^_^;", "'s Shop", " :-p", " -_-v", " ~m^o^m~", " -,.-a", " :-D", "...", " Best
Price, Best Goods !!!", " @_@", " :->" -- picked by `rand()` over the vector at s:0xccecb4). The enter:
the trade ban (0x3405, no 0xB0B3), the quest block (0x3c33), then as before. Type 7 does not test the
chat ban (no FUN_004f0a00 on its path). The client (c:0x86e5b0) shows the 0x3405 line in
GDR_WARNING_WND and the system window (type 5). MEASURED: the box's textuisystem.txt has the chat row and
spells the trade row `UIIT_MSG_GM_PUNISHMENT_TRADE _BLOCK`; the client's lookup misses and gets its empty
string (c:0xec3b70), so with that archive a trade ban shows an empty text. OpenSRO's client shows nothing
for a missing key. GM side (OURS): `/chatban`, `/tradeban`, `/unchatban`, `/untradeban` on round 788's
punishment records (types 4 and 3).

**The quest block (READ).** CGObjPC +0x217c: QB_ForceBlockOperation (slot 143, s:0x4ddd10) ORs,
QB_ReleaseBlockedJob (144) clears, QB_IsBlocked (145) tests; 0 at creation (s:0x4dea6b). The masks the
server tests: 0x200 the stall (open and enter), 0x100 the exchange request (0x185f), 0x1000 party
creation, 0x10000 a COS summon, 0x20000 some teleports and the guild summon, 0x40000 two more, and
0x1..0x10 in the storage operations. The only setters, every call through slot 143's +0x23c, OR 0x60000:
CQuestAType slot 36 (s:0x921ce0, shared by 167 quest classes) and CQNO_WC_PRIEST3_1 (s:0x899370). So no
quest of this server sets 0x200: the stall's two refusals cannot happen in retail. OpenSRO keeps the mask
per character (`session.QuestBlockSet`), tests 0x200 in retail's order, and sets it only from the GM's
`/questblock` (OURS, a test tool); no OpenSRO quest sets any bit.

**The title's word filter (READ, MEASURED).** The abuse filter's four flags per word (f1 names, f2 chat,
f3 guild names, f4 the stall): the client's loader (c:0x8c4a10) and the server's (s:0x987cb0) put a
flag-1 word in a set and a flag-2 word in a list -- f4 at +0x20c0 and +0x203c. The client's title box OK
(c:0x6bb0d0 kind 1, at c:0x6bb159) calls c:0x8c3f10 on the title: lower-cased (A-Z), no f4 list word
found in it (c:0x8c3200, `wstring::find`), no space-separated token in the f4 set (c:0x8c3ae0); no
character table. A refusal shows category 10's 0x3c38, then the window's own X (slot 43, c:0x6b96a0, at
c:0x6bb18e) sends 0x70B2 before the window goes (c:0x79be20(0)); for the first title that is a 0x70B2
before any 0x70B1, for a rename it closes the stall. SR_GameServer loads f4's lists too but no test reads
them (+0x20c0 / +0x203c appear only in its constructor, destructor and loader). MEASURED with the box's
archive file (group 4, English): 82 f4 substring words, 0 f4 whole words (the server's boot log).
