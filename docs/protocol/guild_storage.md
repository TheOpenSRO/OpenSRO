# The guild storage (round 844, lane H)

The guild warehouse: one item container and one gold balance per guild, opened by one member at a
time at a guild manager. Labels: **READ** (`c:` sro_client.exe, `s:` SR_GameServer.exe, the box's
dumps `/var/tmp/decomp_client`, `/var/tmp/decomp_server` and the linear `sro_client.asm` /
`srgs.asm`), **MEASURED** (a live run or the archive), **INFERRED**, **OURS** (this project's own
choice), **OPEN**.

Code: `server/internal/guildstorage` (the rules, the gold store, the lock), `server/internal/session/
guildstorage.go` (the wire), `client/scripts/net/guild_storage_net.gd` / `guild_storage_state.gd`
(the wire, the kept list), `client/scripts/ui/hud/guild_storage_controller.gd` (the window).

## 1. Where it opens (READ)

- **The NPC.** The guild managers: the NPCs with interaction id 0x0f (`NPC_CH_GENARAL_SP` in
  Jangan, "Guild Manager Leebaek", MEASURED; `NPC_WC_GUILD`, `NPC_KT_GUILD`, ...,
  `npcspawn/interactions.go`). The storage keepers (id 3) have no guild storage.
- **The talk line.** Item 0x1d, `UIIT_CTL_GUILD_WAREHOUSE` "Use guild storage. (level 2 or
  above)", offered to every member after the member's and the master's own lines (`FUN_00700440`,
  the id-0x0f block). `FUN_006fcd60` case 0x1d draws it 0xffff4a4a (hover and press 0xffff8a00)
  when the guild block's level byte is under 2, else in the menu's 0xffefdaa4.
- **The click** (`CIF_NPCTalk::FUN_007020c0` case 0x1d, c:0x702c31..0x702c97): the talk window
  hidden by ShowWindow(0), then **0x7046 {u32 npc, u8 0x0f}**. The server's open answers 0xB046
  {1, 0x0f} and sets INTERACTMODE 6 (the default arm of `GObjPC_HandleShopMsg_046`).
- **0xB046 {1, 0x0f}** (c:0x888fc8, the reply handler's case 4: index byte 0x889096) sends
  **0x7250 {u32 npc}** (`FUN_00820840(npc, 1)`).

## 2. The rules (READ unless marked)

| rule | value | where |
|---|---|---|
| who | the master, or a member whose permission has bit **0x08** | `FUN_005c7440` / `FUN_005c74d0`: `CGuild::IsGuildMaster`, else `HasPermission(8)` (s:0x5c7497) -> **0x4c1e** `GUILDERR_PERMISSION_DENIED` ("You are not authorized.", MEASURED) |
| no guild | **0x4c0d** | s:0x5c7459 |
| guild level | **2** or more, else **0x4c4a** `UIIT_MSG_GUILD_WAREHOUSE_LIMIT` "Guild level must be 2 or higher to use guild storage." | s:0x5c7468 `cmp al,0x2 ; jae` |
| size by level | **0, 0, 30, 60, 90, 120** (levels 0-5) | the dword table s:0xc6b5f0, read only by `GObjPC::FUN_005c4ba0` (s:0x5c4ba8); the chest built with it, container type 4, ceiling 0xd2 (`FUN_004e1ad0`, s:0x4e1b2d) |
| one at a time | the guild's holder record (guild +0xc): set by the ShardManager's job **0x24 type 1** (the open), cleared by **type 2** (the close, `CMainProcess::FUN_005c5510`: the holder's chest unloaded, its gold zeroed) | s:0x5c74af / 0x5c753f |
| busy | **0x4c48** followed by the holder's name (guild +0xc, +0x20) | s:0x5ccec3..0x5ccf37; the client shows it as `UIIT_MSG_GUILD_WAREHOUSE_USE` "At the moment guild member %s is using guild storage, so it cannot be opened." (c:0x88f68d) |
| the list | the holder only, else **0x4c49** (no client text) | s:0x517b35 |
| the leave, the expel | refused **0x4c48** for the member holding it | `FUN_005c60b0` (s:0x5c60e6) |
| the disband | refused **0x4c48** while anyone holds it | `FUN_005c6870` (s:0x5c68b6) |
| a permission change | refused **0x4c4c** `UIIT_MSG_GUILD_WAREHOUSE_USE_ING` when it takes bit 0x08 from the holder | `FUN_005c69f0` (s:0x5c6a48) -- lane G's request; `session.GuildStorageHolder` answers who holds it |
| the disband's items | "All the items in the warehouse and guild points(GP) will be gone if your guild is disbanded." | `UIIT_MSG_GUILD_BREAK_ANOTHER_EXPLAIN` (READ text); the gold goes too (**INFERRED**: the ShardManager's disband job is not in this binary) |
| a member leaving | nothing happens to the items: they are the guild's (`_GUILDCHEST WHERE GuildID=%d`, s:0x43d2c0) | READ |
| the gold | the guild's own balance (`{CALL _GET_GUILD_GOLD (%d, ?)}` s:0x43d980; `_UPDATE_GUILD_N_CHAR_GOLD` s:0x45af70), loaded with the chest into the PC at +0x2000 | READ |

## 3. The messages (READ)

| message | body | sender / reader |
|---|---|---|
| 0x7250 open | u32 npc | c:0x82086d; s:`Guild_HandleWarehouseUse` 0x5178b0 |
| 0xB250 | {1} / {2, u16 code} (0x4c48: + u16-length name) | s:0x5c96aa (job reply), 0x5ccea2; c:`Guild_OnWarehouseUseResult` 0x88f630 |
| 0x7251 close | u32 npc | c:0x8208e5; s:0x517980 |
| 0xB251 | {1} / {2, u16 code} | s:0x5c96b6; c:0x88d160 (sends 0x704B, sounds) |
| 0x7252 list | u32 npc | c:0x820980 (on 0xB250 {1}); s:0x517a50 |
| 0xB252 | {2, u16 code} on a refusal | s:0x517b4c; c:0x88d390 reads it and does nothing |
| 0x3253 | u64 gold (the buffer reset) | s:0x4e1cd4; c:0x88d1d0 -> the window's gold (0x6cc470) |
| 0x3255 | bytes (appended) | s:0x4e1d8c; c:0x88eb10 |
| 0x3254 | {} -- parse: u8 size, u8 n, n x {u8 slot, item record} | s:0x4e1dcb; c:0x88d240 (slot / 0x1e the page) |

The moves are the item operation **0x7034 / 0xB034** (the serializer c:0x7923a0, the parser
c:0x87eb50, the server's table filled at s:0x50ce80):

| type | what | request | reply (0xB034 {1, type, ...}) | server |
|---|---|---|---|---|
| 0x1d | inside the storage | u8 src, u8 dst, u16 count, u32 npc | u8 src, u8 dst, u16 count | s:0x5248a0 -> `FUN_004b2450` |
| 0x1e | bag -> storage | u8 bag slot + 13, u8 dst, u32 npc | u8 src, u8 dst (the slot used) | s:0x524510 -> `FUN_00523f70` |
| 0x1f | storage -> bag | u8 src, u8 bag slot + 13, u32 npc | u8 src, u8 dst + 13 | s:0x5247d0 -> `FUN_00523f70` |
| 0x20 | gold in | u64 amount | u64 amount | s:0x5243d0 |
| 0x21 | gold out | u64 amount | u64 amount | s:0x5243d0 |

The client applies each to its own copy (c:0x87ba20: the window's gold +/- the amount, c:0x87cb1d
and c:0x87d5ed).

**The deposit (0x1e, s:0x524510)**, in its order: the chest loaded (3); the source not an
equipment slot (`< 0xd`, 5); the NPC in reach with id 0x0f (3); an item there (0x1809); the item
test -- vslot 0x488 (ref +0x8c **bit 13**), not vslot 0xb8 (`CGObj::IsQuest_n_EventItem`, TypeID
3/3/9) and vslot 0xc4 (`CGObj::CanTrade`) -- else **0x1843** `STRGERR_INVALID_TARGET_STORAGE`; the
count overwritten with the **whole stack**; the fee (below) against the purse (0x180f); then
`FUN_00523f70`: both slots in range (3), a pet that is out (0x18b2), the destination taken -> the
first empty slot (`FindFirstEmptySlot`, **no merge**; none: 0x1807); the fee taken after the move
(`OffsetGold`, reason 0x1d).

**The fee** (s:0x52464f..0x5246fd): `KeepingFee x count` (32-bit `imul`), read unsigned (`fild`, plus
2^32 when negative), **x 0.5** (`fmul` of the double at s:0xb45c50 = 0.5), truncated (`_ftol2`
s:0x9fbb76), then 0 or less -> 1, 10,000,000 or more -> 10,000,000. **Half the personal
warehouse's.** The client's box shows the same half (c:0x6b111a..0x6b11ec: `(fee * count) / 2`, at
least 1). MEASURED: a Copper Sword's deposit box read 10 and the purse went down by 10.

**The withdraw (0x1f, s:0x5247d0)**: the chest loaded (3), the bag slot not equipment (5), the NPC
(3), then `FUN_00523f70` (the bag's first empty slot from 13 when the named one is taken). Free.

**Inside (0x1d, `FUN_004b2450`)**: src == dst or out of range 0x1806; nothing at src 0x1809; count
< 1 0x1829; an empty dst: a stack that does not stack moves; a count equal to the stack moves; above
it 0x1814; below it is a split, and the chest (container type 4, `+0x18 != 0`) refuses it **5**; an
occupied dst: `CountCanBeMerged` > 0 merges that much (the reply's count), else the two swap.

**Gold (0x20 / 0x21, s:0x5243d0)**: the chest loaded (3); **INTERACTMODE 6** (0x1834); a positive
amount (0x1829); 0x20 against the purse, 0x21 against the storage's gold (0x180f); `OffsetGold`
reasons 0x1d (in) and 0x27 (out).

## 4. The window (READ)

- **GDR_GUILDSTORAGEROOM** (`ginterface.txt`'s `GuildStorageRoom` section): `CIFStorageRoom`, ID
  145 (0x91), 254x317, `mframe_wnd_`, titled `UIIT_STT_GUILD_WAREHOUSE` "Guild storage". The class
  is the personal storage's: `ifstorageroom.txt`, 30 slot controls (`CIFStorageRoom::Create`
  c:0x6cc780), the page spinner, the gold static and its button.
- **Shown** (0xB250 {1}, `0x79bf40(1)`): created, positioned, shown, the helper's snd_window_open
  (0x79a7e0); the inventory pane told (0x6aefa0) and the main popup shown on the inventory tab
  (0x79af20); the NPC kept at +0x7c8; then 0x7252 (0x820980) and the talk's sound.
- **A refusal** (0xB250 {2, code}): 0x4c48 worded with the name, any other code through the
  guild's error box (`0x778190(0x10, code)`); then 0x704B (`UI_SILKMALL::FUN_0078fc20`).
- **The X** (`CIFStorageRoom::vslot_043` for 0x91, c:0x6cc0c6): `0x79bf40(0)` -- hidden, its
  position kept, 0x7251 {npc} -- and snd_window_close. **Escape** closes it after the storage
  (`0x79d620`, c:0x79d871).
- **Drops** (`CIFStorageRoom::vslot_028` c:0x6cd350): a bag item -> the item test at the client
  (ref +0xa7 bit 7, `FUN_006cc190`; else the 0x1843 message) -> the deposit box (`UI_UNITY::
  FUN_006b0e90`, mode 6, purpose **0x10**) -> type 0x1e naming the cell; a storage item onto another
  cell -> type 0x1d with its stack, no box (c:0x7950b0). A storage item put down on the bag -> the
  withdraw box (`FUN_006b15b0`, purpose **0x11**) -> type 0x1f naming the bag cell.
- **Gold**: the window's money button -> the take box (`FUN_006b29f0`, purpose **0x13**); the bag's
  money button while the guild storage is up -> the deposit box (`FUN_006b2800`, purpose **0x12**;
  `je` on 0x799640). Amounts 0 to the balance, at most 1,000,000,000.

## 5. What OpenSRO does

- **Server** (`guildstorage`): the items are an ordinary inventory container keyed by guild id
  (table `guild_storage_slots`, owner `guild_id`; OURS names), sized by the level table; the gold its
  own table `guild_storage_gold` (both `CREATE TABLE IF NOT EXISTS`, no migration). Every move and
  every gold move is **one transaction** over the bag, the storage, the purse and the gold
  (`internal/txn`): two members' racing requests move an item once, a dropped connection or a failed
  fee leaves nothing half-done (`guildstorage_test.go`: `TestRacedWithdrawsOnce`,
  `TestRacedGoldWithdrawsOnce`, `TestDisconnectMidMoveLosesNothing`, `TestDepositUnpaidFeeRollsBack`,
  `TestPersistsAcrossRestart`, on both stores).
- **The lock** (OURS: the ShardManager's job is a map in this process, `guildstorage.Locks`): taken
  at 0x7250, released at 0x7251 and when the holder leaves the world (**INFERRED**: the
  ShardManager's own release on logout is not in this binary). A close the server refuses (the NPC
  out of reach) still releases it (OURS: the window is gone on the client).
- **0xB252 {1}** after a list (OURS: the original's success path for the AQ load is not traced; the
  client ignores the message).
- **/guildperm <member> <mask>** (GM, OURS, a test tool): the master's own grant window is lane
  G's.

## 6. OPEN

- **Bit 13** (itemdata column 19 `& 0x40`): refdata does not carry it, so the server's item test is
  `CanTrade` and not 3/3/9; the two agree on all but 73 of the 14,529 tradeable rows (MEASURED,
  round 844: magic cubes, Nasrun stones, tokens, teleport holes). The client's own test (column 19
  `& 0x80`, c:0x6cc190) is not made either: those items reach the server and are refused there or
  stored.
- Right-click moves between the bag and the storage (`CIFSlotWithHelp::vslot_029`'s 0x91 arms): not
  built.
- The 0x4c49 refusal has no client text (the guild's error box shows nothing for it).
- What the ShardManager does with a holder who disconnects or changes server.
