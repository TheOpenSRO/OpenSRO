# Magic POP (the gacha): the machine, the draw and Gori's exchange

Round 838, lane 5. Read from SR_GameServer.exe (`s:`) and sro_client.exe (`c:`) on the render box;
labels: READ (an address), MEASURED (the archive's data), INFERRED, OURS, OPEN. The feature is the
stock client's and server's; nothing in it comes from the vPlus add-on. Code:
`server/internal/gacha`, `server/internal/session/gacha.go`, `client/scripts/net/gacha_net.gd`,
`client/scripts/ui/hud/gacha_*.gd`.

## 1. Data (MEASURED)

**gachaitemset.txt** (`_RefGachaItemSet`), 14 live rows: Service, Set_ID, RefItemID, Ratio, Count,
GachaID, Visible, four (int, Desc128) free-param pairs. Server rows (`s:0x6bca80`): +4 Set_ID, +8
RefItemID, +0xc Ratio u16, +0xe Count u16, +0x10 GachaID, +0x14 Visible. Set 1 is the prize set
(10 rows: the title, the two Seal shields, luck stones, four dragon flags, the elixir booster), set 2
the consolation set (four B recipes, ratios 1200/2400/1800/2100 of 7500). Every Count is 1 and every
Visible 0.

**gachanpcmap.txt**: `1 9251 1 2` -- NPC_CH_GACHA_MACHINE ("Magic POP"), prize set 1, consolation
set 2. Which `_RefGachaCode` row names set 1 "WIN" and 2 "LOSE" is INFERRED (the code table is not
in the archive). The machines stand in six towns (npcpos 9251; Jangan 25000 local 1612.97,
1193.0); Gori, NPC_CH_GACHA_OPERATOR (9252), beside each (Jangan 977.28, 727.63).

**refgachatreeforclientuidata.txt**: six kinds under class 700 "Others" -- 701 Avatar Flag
(3/1/13/4), 702 LMP (3/3/10/2), 703 Scrolls (3/3/13/1), 704 Titles (3/3/13/14), 705 CH shield
(3/1/4/1), 706 EU shield (3/1/4/2).

**The card and coupons**: ITEM_MALL_GACHA_CARD 9238, 3/3/14/1, Param1 1 / Desc
ITEM_MALL_GACHA_CARD_LOSE, Param2 1 / Desc ITEM_MALL_GACHA_CARD_WIN; the coupons 9239 (_WIN) and
9240 (_LOSE), 3/3/14/2, "Item Exchange Coupon".

## 2. The server (READ)

- **0x11** on a machine: NPC Create (`s:0x4c6350`) adds it at `s:0x4c77c2` for an NPC in the gacha
  map (refmgr+0x110) while the world-config byte +0x42404 is 0; **0x12** for a code name holding
  NPC_CH_GACHA_OPERATOR (`s:0x4c77f9`). Opening is the generic 0x7046 {npc, 0x11} -> 0xB046
  {1, 0x11}, INTERACTMODE 6.
- **The draw, 0x7118** `{u32 npc uid, u32 GachaID, u8 bag slot + 13}` (`s:0x511570` -> `s:0x4c7e20`):
  the interaction range, then in order -- the NPC has 0x11 (0x1c0f); the slot is inside the bag
  (0x1806); the NPC's map entry (0x1c0f); an item in the slot (0x1809); a 3/3/14/1 (0x1806); not
  expired (0x183d); roll = rand() % 10000, the GachaID's row in the WIN set (missing 2), **a win
  when roll < Ratio**; else roll2 = rand() % 10000 and the LOSE set's cumulative map by
  `lower_bound` (`s:0x4cc5d0`; each share ratio / sum x 10000 -- the rounding of an uneven set is
  INFERRED; this archive's divides exactly, 1600/4800/7200/10000).
- **The card becomes its coupon in place** (`s:0x4edd20`): Param2's descriptor on a win, Param1's on
  a loss; the coupon's param0 = the prize RefItemID, param1 = Count, then the row's free params.
  **No bag-space check.** Then 0x3040 (the slot's item update) and **0xB118** `{u8 1, u8 win}` (the
  coupon's Param1), or `{u8 2, u16 code}`. A win of a Visible row also sends **0x3120**
  `{u32 ref, u16 count}` (`s:0x5f8620`; to all, INFERRED).
- **Gori, 0x7119** `{u32 npc uid}` (`s:0x5115e0` -> `s:0x4c8130`): 0x12 (else 0x1c0f); every
  unexpired coupon in the bag becomes param0 -- count param1 for a 3/3 prize --, more than two params
  becoming the item's stats ('V' variance, 'M' option, 'O' plus, 'D' durability), each slot's 0x3040.
  No 0xB119 on success; a failure `{u8 2, u16 5}`.

## 3. The client (READ)

- Talk line 0x27 "Participate in the game." sends 0x7046 {uid, 0x11}; line 0x28 "Exchange Item
  Exchange Coupon to Item" sends 0x7119 when the bag holds a 3/3/14/2 (`c:0x745ab0`), else Gori's
  talk says SN_TALK_CH_GACHA_OPERATOR_3 (`c:0x7020c0`).
- 0xB046 {1, 0x11} -> `c:0x79c060`: window 0x8c "Ghacha" (CIFGhaCha, ginterface GDR_GHACHA ID 140,
  673 x 428, mgame_wnd_, "Magic POP"), resinfo\ifghacha.txt Create + Inventory, which opens
  **GhachaSelect** first (319 x 257, resinfo\ifghachaselectwnd.txt: Class / Type / Degree combos,
  "Start the game").
- The prizes: the machine's prize set filtered by the chosen kind, 12 a page in SLOT_100..111; a
  click keeps the GachaID. The status line (static 36): "Choose item of desire." / "Register Magic
  POP card." / "Click PLAY button." (`c:0x747940`). The card goes onto CARD_SLOT 112 from the
  window's inventory pane (`c:0x749a30`).
- PLAY (`c:0x7459b0`): 100 ms frames of gacha_roll0000..0020 (by 2) on both roll statics; at
  4000 ms 0x7118 is sent and gacha_roll_original put back (`c:0x746df8`); then ga_effect_%02d for 41
  ticks, a win ending on ga_effect_sucess. 0xB118 (`c:0x88d690` -> `c:0x748270`): the coupon in the
  card slot, UIIT_MSG_GACHA_WIN / _LOSE (Korean text only in the archive), busy cleared. Closing is
  refused while busy (`c:0x7481f0`).
- 0x3040 on a slot that held a coupon writes "Has been changed to [%s][%d]."
  (UIIT_MSG_GACHA_EXCHANGE, `c:0x88bf30`); 0x3120 "[%s][%d]has been won from Magic POP.".

## 4. OpenSRO (OURS where it differs)

- No 0x3040 is sent: the client re-lists its bag after 0xB118 and right after sending 0x7119 (the
  server handles a session's messages in order, so that list carries the exchange), and writes the
  UIIT_MSG_GACHA_EXCHANGE line for each coupon slot that now holds something else. No opcode of
  OpenSRO's own is used.
- The coupon's {prize, count} live in the bag instance's MagParams (the same per-item u64 list).
- An exchanged prize gets a fresh instance; the [BIIV] free params of the flag rows are not applied
  (OPEN). Rental expiry (0x183d) is not modelled. A stack of more than one card is refused 5.
- The client: the card is registered by a left click in the pane (not a drag); the combos are
  OptionButtons, Type starts at "All" and Degree offers only "All" (OPEN: how retail fills it); the
  effect cycles ga_effect_01..19 and a win ends on ga_effect_sucess_01/_02; a refusal clears busy
  (retail stays busy, showing nothing); the pane shows the bag's first 32 slots without page tabs;
  no sounds; the coupon's "Can be changed to" tooltip is not built.
