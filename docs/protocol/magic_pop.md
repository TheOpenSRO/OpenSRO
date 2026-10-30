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

## 3a. The window's own bag pane, the card's way in and the effects (round 843, lane P; READ)

The user's report: "the magic pop doesn't show inventory pages so you can't get pop cards from other
pages". The original draws the bag inside the Magic POP window, with a tab per page.

- **Nothing opens alongside.** `c:0x79c060(1)` destroys the alchemy window if it exists, creates the
  Ghacha window (0x8c) centred and **hidden** (ShowWindow(0) at `c:0x79c0e4`), then runs the toggle
  helper `0x79a7e0` on it -- which, the window being hidden, sounds **snd_window_close** (the helper's
  rule, round 615). The select window is shown by the window's Create (`c:0x7465d0`). No inventory
  opener (`0x79af20`, `0x79b020`, the store's `0x79dbd0`) is reached (window_companions.md row 18).
- **The pane** is Create's second section, `Inventory` (`c:0x746be0`), plus controls made in code by
  the Start's build `c:0x749560`:
  - **page tabs** (`c:0x748790`): one per page of IFInventory's tab vector (`0x6af5e0`), a
    CIFSelectableArea (class `0xee96c0`) ID **500 + i** at **(475 + 62 i, 55), 60 x 24**, art
    `interface\ifcommon\com_tab_on.ddj` selected / `com_tab_off.ddj` (`0x64ce30`), font 0, centred,
    text **UIIT_CTL_BELOINGING ("Page 1") for the first and UIIT_STT_INVENTORY_EXTENSION_TEB ("Page
    2") for every other** (`c:0x748918..0x748941` name those two keys only, so a third page reads
    "Page 2" too; the bag window's own third tab reads TEB2, "Page 3"). The first is selected
    (`0x64cc30(i == 0)`). `CIFGhaCha::vslot_004` (`c:0x745950`) folds 500..500+n-1 into the message
    map's 500 entry, whose handler `c:0x747e30` finds the tab by its handle and runs `c:0x747a40` --
    **with no busy test**. A tab acts on the press (CIFSelectableArea, round 633);
  - **cells** (the loop at `c:0x7496b6..0x7499f5`): one CIFSlotWithHelp (`0xee9b18`) per control of
    IFInventory's slot vector (`0x6af620`, pages x 32), ID **200 + i**, 32 x 32 at **(494 + 36 (i %
    4), 91 + 36 ((i % 32) / 4))** -- each page's cells on the same 32 places --, index i, kind 0x8c.
    A cell at or past the bag's size (`0x6af600`) gets `interface\pet\pt_block.ddj` and is disabled
    (`0xb8f540(0)`); the others are mirrored by `c:0x749030`;
  - **showing a page** (`c:0x747a40(p)`): the old tab off, tab p on (`0x64cc30`), +0x8e5 = p, cells
    `p*32 .. p*32+31` shown and every other cell hidden. The build calls it with 0, and the window is
    destroyed at each close (`c:0x79c158` -> `0x8b59f0`), so each open starts on page 1.
- **The mirror** (`c:0x749030(i)`): the cell takes the bag slot's index (`0x6667f0`), its source kind
  0x46 (`0x666710`) and kind 0x8c, and **SetItem with the bag slot's own record** (`c:0x74928d`), so
  every per-item effect the bag draws (the seal star, the pet and spirit edges, the wash) shows on the
  cell; an empty bag slot empties the cell. IFInventory calls it for each slot it sets
  (`0x6b7770` -> `c:0x6b7c03`, while the window exists). Its tail: when the cell is the card slot's
  source, an emptied slot empties the card slot, and an item that is **not a 3/3/14/2 coupon**
  (`0x666fc0`) empties it and redraws the status line. Then the purse goes on GDR_CHACHA_STA_MONEY
  (ID 40): the popup's gold (`+0x378`/`+0x37c`) through `0x8c1d50(.., 3, 0)` -- grouped by
  thousands, the bag's own format -- with **no gold colour** (no `0x5d3df0` call here).
- **The counts** (`0x680da0` case 0x8c): drawn for a cell whose source kind is 0x46 holding a 3/3 item
  (`0x538410`) -- the bag's rule; never on a prize (source kind 0x8c, `c:0x74652c`) or the card slot
  (source kind 0x8c after the put-down, `c:0x749c4d..0x749c68`).
- **The prizes' records** (`c:0x748e0c..0x748ecc`): a fresh record (`0x8bef90`) with the ref and
  count, **+0x28 set to 1**, SetItem: a seal prize (Rarity 2 or 6; this archive's two shields) shows
  the star. The prize slots are not pickable (`0xb9daf0(0)`, `c:0x746595`). The spinner (700)'s top
  page is 0 under 12 prizes, the pages less one when 12 divides the count, else the whole pages
  (`c:0x748d6b`); its change (message map entry 700 -> `c:0x749000`) drops the choice (`0x666680(0)`,
  +0x880 = 0), redraws the status line and lists the page.
- **Choosing a prize**: a left click on a kind-0x8c slot while not busy (`CIFSlotWithHelp::vslot_029`,
  `c:0x681341..0x68137c`) sets the slot's +0x596 and posts message 0xc8 to the window; `c:0x747dd0`
  takes an index 100..111 holding an item: +0x880 = the slot, `0x666680(1)` -- the counter +0x66c to
  `rand() % 9`, timer 4 at 50 ms. The overlay draw at `c:0x67ea55` draws the **pet-edge sheet**
  (`pt_edge_effect.ddj`, +0x640, u `(9 - c) * 32 / 288`) on a slot whose +0x596 is set and +0x66c > 0:
  the chosen prize's marker. `c:0x7477c0` clears +0x596 on the other prize slots.
- **The state +0x8d8** (`c:0x747940`): 0 when the chosen slot is not on the spinner's page (`c:0x7477c0`
  also keeps its GachaID, +0x7bc), 1 when the card slot holds no 3/3/14/1 card, 2 otherwise -- with
  the three lines and PLAY enabled only in 2 (`0x655ec0`).
- **The card goes in by the held icon** (round 652's engine: a click picks a slot up, the next click
  puts it down; while held, a press or release over a CIFButton or a CIFSelectableArea passes through,
  so the pages can be turned with a card held). The put-down is offered to the control under the
  cursor and its parents (`0x6523d0`); a slot hands it to its window (`0x666560`), so
  `CIFGhaCha::vslot_028(held, target)` (`c:0x749a30`) gets every put-down in the window:
  1. nothing while busy or unless the state is 1;
  2. `c:0x7478c0`: if the held slot is **one of the first 32 cells** and the target is not the card
     slot, refused; and refused while the prize list is empty. The loop stops at `0x20`
     (`c:0x7478f6`): **a card from page 2 or 3 is taken wherever in the window it is put down** (a
     cell, a prize, the background), one from page 1 only on the card slot;
  3. the held slot's kind must be 0x8c (this window's): a bag window slot (0x46) changes nothing;
  4. index inside the bag: the cell's item; none, nothing; a 3/3/14/1 card: the card slot is set
     from it -- SetItem with the same record, its index (`0x6667f0`), kinds 0x8c --; anything else,
     nothing;
  5. index 0x70 (the card slot itself, past any bag): the card slot emptied;
  6. the status line (`c:0x747940`). The answer is always 1: the put-down never reaches the world.
- **PLAY** (`c:0x7459b0`) additionally needs the card slot's bag slot to hold a record (+0x28) of a
  card, else empties the card slot. Then: busy (`DAT_00eeb9ac`); the DECO (51) shown; timer 1 at
  100 ms; **snd_gacha_move**; timer 2 at 4000 ms; timer 3 at 100 ms; **snd_gacha_turn**.
- **Timer 1** (`c:0x746cd5`): the frame +0x8dc reset to 0 past 20, `gacha_roll%04d.ddj` of it on both
  roll statics, then +2. +0x8dc starts at 0 with each window and is never reset by PLAY.
- **Timer 3** (`c:0x746f21`), the effect static (50): `ga_effect_%02d.ddj` of the counter +0x8e0 (1
  with each window); during the global tick `DAT_00eeb9d0` 7..15 and 23..35 the counter is held
  (-1, then +1); the DECO steps a frame (`0x634300`). So a run shows 01..07, 08 for ten ticks, 09..14,
  15 for fourteen, 16..19. At tick 41: `ga_effect_20.ddj` (not in the archive) then **timer 3
  killed, the counter 1, the tick 0, `ga_effect_01.ddj`, the DECO hidden**; with +0x8e4 (a win)
  the DECO takes `interface\game\ga_effect_sucess.ddj`, cells 64 x 81, 15 frames, from frame 1,
  shown, timer 4 at 100 ms. A loss falls through to the tick's increment, so **the next run starts at
  tick 1** (holds 07 and 14, ends on 19 at tick 41). The tick is a global; a new window keeps it.
- **Timer 4** (`c:0x74710c`): at frame 14 the timer is killed, the DECO hidden and set back to the
  prepare sheet (64 x 64, 16 frames, frame 0); else the next frame.
- **The DECO** (`c:0x7496c5..0x749773`): GDR_GHACHA_DECO, a CIFDecoratedStatic over the card slot
  (183, 168, 128 x 128), `interface\alchemy\alcm_effect_prepare.ddj` in 64 x 64 cells, 16 frames,
  +0x388 = 1 (additive), hidden. A frame's cell is `(f % (width / cell w), f / (width / cell w))`
  (`0x633ca0`), drawn on the control's quad. MEASURED: the prepare sheet 256 x 256, the win sheet
  256 x 512 (four 64 x 81 cells a row).
- **The result** (`c:0x748270`): the status line redrawn (`c:0x747940`), the card slot set from its
  bag slot's record (the coupon by now), then the win line **with snd_gacha_win** or the loss line
  **with snd_gacha_end**, busy cleared. The win line is formatted with the coupon's prize name and
  count, but UIIT_MSG_GACHA_WIN's text has no placeholder (MEASURED).
- **The coupon's arrival** (0x3040 mask 1 on the card's bag slot, `c:0x88c1b2..0x88c1ed`): the bag
  slot's flash (`0x6b44d0`) and, while the window exists, the cell's (`c:0x747890` -> `0x6665f0`,
  `icon_mall_transgender.ddj`).
- **Sounds** (MEASURED, effectsound.txt's UI rows): SND_GACHA_MOVE `gacha_move.wav`, SND_GACHA_TURN
  `gacha_turn.wav`, SND_GACHA_END `gacha_end.wav`, SND_GACHA_WIN `gacha_win.wav`. SND_GACHA_CHANGE
  (`gacha_change.wav`) is in the table but its name is not in the client (MEASURED: no string).
- **Closing**: `CIFGhaCha::vslot_043` (`c:0x7481f0`) refuses while busy, else `c:0x79c060(0)`:
  snd_window_close, hidden, destroyed. The select window's close (`c:0x749d60`) destroys itself and
  runs the Ghacha window's close.

## 4. OpenSRO (OURS where it differs)

- No 0x3040 is sent: the client re-lists its bag after 0xB118 and right after sending 0x7119 (the
  server handles a session's messages in order, so that list carries the exchange), and writes the
  UIIT_MSG_GACHA_EXCHANGE line for each coupon slot that now holds something else. No opcode of
  OpenSRO's own is used.
- The coupon's {prize, count} live in the bag instance's MagParams (the same per-item u64 list).
- An exchanged prize gets a fresh instance; the [BIIV] free params of the flag rows are not applied
  (OPEN). Rental expiry (0x183d) is not modelled. A stack of more than one card is refused 5.
- The client (round 838): the combos are OptionButtons, Type starts at "All" and Degree offers only
  "All" (OPEN: how retail fills it); a refusal clears busy (retail stays busy, showing nothing); the
  coupon's "Can be changed to" tooltip is not built.
- Round 843 (lane P) built §3a: the page tabs and every page's cells, the locked cells, the purse,
  the card put in by the held icon with the original's rules (page-1 cards only on the card slot,
  page-2/3 cards anywhere in the window), the card slot following its bag slot, the chosen prize's
  pet-edge marker, no counts on the prizes, the effect's timing with its holds and the loss quirk,
  the DECO's prepare and win sheets, the five sounds, the close refused while busy. Gone from round
  838's OURS: the left click that registered a card, the 32-slot pane, the yellow tint on the chosen
  prize, the ga_effect_sucess_01/_02 alternation, the counts on the prizes, the silent window.
- Still OURS: OpenSRO's server sends no 0x3040 for the card, so the cell's (and the bag's) flash is
  played when the bag list that follows the result shows the card's slot turned coupon; PLAY stays
  disabled from the result until the status line is redrawn (what the original's button shows in
  between is OPEN); a card held from the pane is let go when the window closes (the original destroys
  the window); the purse is written at each open and bag list (the original writes it at each mirror,
  which every bag change runs).
