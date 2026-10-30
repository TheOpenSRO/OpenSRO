# Guild census (round 844)

Every guild opcode, guild window and guild-manager NPC line the original has, and what OpenSRO
has of each. It is the round's checklist: the coordinator reads it to see that nothing was missed.

**Sources.** `sro_client.exe` (c:) and `SR_GameServer.exe` (s:) on the render box. The
decompiled dumps are `/var/tmp/decomp_client` and `/var/tmp/decomp_server`. The layouts are
Media.pk2's `res_ui\guild*.2dt` and `resinfo\ifguild*.txt` / `ginterface.txt`.

**Labels.** READ means taken from the binary or the archive. INFERRED means reasoned from what was
read. OURS means OpenSRO's own choice. OPEN means not settled.

**Status.**
- built: as the original.
- partial: what is missing is said.
- missing: not built.
- out of scope (fortress war): the fortress siege, not this round.
- out of scope (academy): the training camp, not this round.

**Owners (round 844).**
- **G**: this lane. The guild window's member and info tabs, the notice, the permissions, the
  hand-over, the guild manager's lines, GP, the highlight.
- **H**: guild storage.
- **U**: unions.
- **V**: guild war.
- Earlier rounds: their number.

Error replies are `{u8 2, u16 code}`, shown through category 0x10 unless a row says otherwise.
A code with no row in category 0x10 shows nothing. Those codes are 0x4c08-0b, 0x4c0d, 0x4c0e-11,
0x4c14/15, 0x4c20, 0x4c2c-30, 0x4c33-35, 0x4c37, 0x4c40, 0x4c45, 0x4c47, 0x4c49, 0x4c4e-51,
0x4c5f, 0x4c61-6f, 0x4c79, and the codes 2 and 3.

## 1. Requests (client -> server)

| op | what | the original's UI | server | status | owner |
|---|---|---|---|---|---|
| 0x70F0 | create {u32 NPC, str name} | NPC line 0x12, box 0x12 | s:0x514ce0 | built | 822 |
| 0x70F1 | disband {u32 NPC} | master's line 0x14, box 0x13 | s:0x515340 | built | 822 |
| 0x70F2 | leave {u32 NPC} | member's line 0x1c, box 0x14 | s:0x515070 | built | 822 |
| 0x70F3 | invite {u32 player} | window button 37 | s:0x514f10 | built | 822 |
| 0x70F4 | expel {str name} | window button 39 and the ban question | s:0x5151d0 | built | 822 |
| 0x3080 | the invitation's answer | box 0x0F | s:0x514f10 path | built | 822 |
| 0x70F6 | old "GP subscription" | none: the sender c:0x81fce0 has no caller, and the GS slot 0x0f6 is never set (READ) | -- | dead in the original; not built | G |
| 0x70F9 | notice {str title, str body} | the write window CIFGuildNotifyWrite | s:0x516ea0 -> 0x5c6480 | **built** | G |
| 0x70FA | level-up {u32 NPC} | master's line 0x17, CIFGuildLevelUp | s:0x516da0 | **built** (OURS 0x009A kept for tools) | G |
| 0x70FB | union invite {u32 player} | relations pane | s:0x5170b0 | missing | U |
| 0x70FC | leave the union {} | relations pane | s:0x5171d0 | missing | U |
| 0x70FD | expel a guild from the union {u32 guild} | relations pane | s:0x517250 | missing | U |
| 0x70FF | fortress position {u32 member, u8 role} | button 41, CIFGuildPositionGrant | s:0x517e30 -> 0x5c7bb0 | out of scope (fortress war) | -- |
| 0x7103 | master hand-over {u32 NPC, u32 new master} | master's line 0x18, CIFGuildMasterLeave | s:0x517300 -> 0x5c6900 | **built** | G |
| 0x7104 | permissions {u8 n, n x {u32 id, u32 mask}} | button 38's pane CNIFGuildGrantPow | s:0x5173e0 -> 0x5c69f0 | **built** | G |
| 0x7105 | ask for a master-release vote {u32 NPC} | line 0x19 UIIT_CTL_MASTERRELEASE, box type 2 | s:0x517600 -> 0x5c6ac0 | missing (OPEN below) | G |
| 0x7106 | open the vote {u32 NPC} | line 0x1a UIIT_CTL_MRELEASE_VOTE | CVoteManager s:0x5e7f00 | missing | G |
| 0x7107 | vote {u32 NPC, u32 candidate, u8 choice} | CIFGuildMasterElection | s:0x517730 -> 0x5e7ea0 | missing | G |
| 0x7110 | war declaration {str, u8, u32, u8, u32} | CIFGuildWar | s:0x518820 | missing | V |
| 0x7112 | hostile-guild action {u32} | NIFHostileGuild | s:0x518930 | missing | V |
| 0x7113 | war NPC {u32 NPC} | box type 3 | s:0x518a80 | missing | V |
| 0x7114 | war compensation {u32 NPC} | master's line 0x1b UIIT_CTL_GUILD_COMPENSATION | s:0x5189a0 -> 0x5c72a0 | missing | V |
| 0x7250 / 0x7251 / 0x7252 | storage open / close / move | line 0x1d, CIFStorageRoom | s:0x5178b0 / 0x517980 / 0x517a50 | missing | H |
| 0x7256 | grant name {u32 member, str name} | button 40 | s:0x517b70 -> 0x5c7560 | built (OURS: each member names themselves, round 814) | 814 |
| 0x7258 | SP -> GP donation {u32 SP} | donation button 250, CIFGuildPointUp | s:0x517cc0 -> 0x5c7880 | **built** | G |
| 0x7259 | guild soldier ability {u32 NPC, u8 bit} | the mercenary NPC | s:0x517d60 -> 0x5c7900 | out of scope (fortress war) | -- |
| 0x725A | dismiss the hired mercenaries {} | c:0x7a0980 | s:0x517d20 | out of scope (fortress war) | -- |
| 0x7031 | answer the guild recall {u32, u32, u8} | CIFGuildSummonReq, after 0x7030 | s:0x4ee1d0 | missing (OPEN below) | G |
| 0x704C + option 0xC6 | crest register / delete | the crest scrolls | s:0x5c7600..0x5c77d0 | built (OURS bytes channel 0x0130) | 824 |
| 0x7202 / 0x7203 | not guild: skill and mastery withdrawal | -- | -- | -- | -- |

## 2. Server -> client

| op | what | status | owner |
|---|---|---|---|
| 0x34B3 / 0x3101 / 0x34B4 | the guild block. Its trailing `u8 n x {u32, u8, u32}` is the master-release vote list (FUN_0099d7e0, the same reader as 0x3908) | built; the vote list is sent empty | 821 |
| 0x3100 | drop a player's guild line | built | 822 |
| 0x3102 | the union block | built | 842 |
| 0x3103 | fortress role notice | out of scope (fortress war) | -- |
| 0x3109 | hostile-guild data (guild-line colours) | missing | V |
| 0x3253 / 0x3254 / 0x3255 | a buffered stream, INFERRED to be the storage | missing | H |
| 0x3256 | grant name | built | 814 |
| 0x3257 | crest revision | built | 824 |
| 0x3908 | master-release vote: kind 1 a vote record, kind 3 the result (`UIIT_MSG_MRELEASE_BEELETED` / `_BROKEN`) | missing | G |
| 0x7030 | guild recall prompt {u32, u32, u32} | missing | G |
| B0F0..B0F4, B0F8 | membership replies | built | 822 |
| B0F9 | notice: {1} shows `_COMMON_KNOW_REMIND_UPDATE` | **built** | G |
| B0FA | level-up | **built** | G |
| B0FB / B0FC / B0FD | union replies | missing | U |
| B0FF | position grant | out of scope (fortress war) | -- |
| B103 | hand-over: {1} closes the talk and shows `UIIT_MSG_MLEAVE_SUCCESS` | **built** | G |
| B104 | permissions: {1}, no text | **built** | G |
| B105 / B106 / B107 | the vote's replies (category 0x15 for B106 / B107) | missing | G |
| B110..B114 | war replies | missing | V |
| B250..B252 | storage replies | missing | H |
| B256 | grant name | built | 814 |
| B258 | donation: {1, u32} shows `UIIT_MSG_GUILD_GP_SUBSCRIPION_RESULT` | **built** | G |
| B259 / B25A | soldier ability / mercenaries | out of scope (fortress war) | -- |

### 0x38F5, the guild update (c:0x887330, the table at c:0x888b00 / 0x888ab4)

| type | payload | status | owner |
|---|---|---|---|
| 0 | refresh | built | 822 |
| 1 | disbanded | built | 822 |
| 2 | member added (the block's 13 fields) | built | 822 |
| 3 | {u32 id, u8 1 left / 2 expelled} | built | 822 |
| 5 | guild fields by mask: 0x02 name, 0x04 level, 0x08 GP, 0x10 notice, 0x40 soldier flags | built. Notice mask 0x10 since 844, INFERRED from the ShardManager relay s:0x5c3c90 | 822 / G |
| 6 | member fields by mask: 0x01 level, 0x02 offline, 0x04 class, 0x08 GP, 0x10 permission, 0x20 name, 0x40 siege role | built | 822 / G |
| 0x0d | a union guild joined | built | 842 |
| 0x0e | a union guild's fields | missing | U |
| 0x12 | union: 1 left, 2 expelled, 3 dissolved | built | 842 |
| **0x14** | {u8 n, n x {u32 id, u32 mask}}: permissions, silent | **built** | G |
| **0x16** | {u8 n, u8 mask, n x {u32 id, fields}}: several members (the hand-over 0x54, the permission list 0x10, a fortress loss 0x40) | **built** | G |
| 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1f, 0x32 | war and hostile updates | missing | V |
| 0x23 | {u32, str}, INFERRED a guild rename in the union or hostile lists | missing | U / V |

## 3. The guild window (`res_ui\guild.2dt`, CNIFGuildWnd 621 x 434)

The info pane, 47:

| control | what (READ) | status |
|---|---|---|
| 66 / 115 / 124 / 150 / 126 / 116 / 121 / 120 | name, "Level %d", master, master's race mark, members n / cap, GP n / next, %, gauge | built (821) |
| 130 | gil_mark01 beside the name | built (2DT art) |
| 250 | donation button (tooltip `UIIT_MSG_GUILD_SP_GP_TOOLTIP`), opens CIFGuildPointUp | **built** (G) |
| 222 / 117 / 81 | the notice bar: the title. A press toggles the body's view 1200 (art gil_windo02_on / _off). The pencil 81 needs bit 0x10 and opens the write window | **built** (G) |
| 1200 (155, 153) | CNIFGuildNotifyView: the body (0x400 characters), Confirm closes it | **built** (G). OURS: the body sits in a wrapping label |
| 400-403 | headers; sort by name ascending, level descending, class (master first), GP descending (c:0x5ba310) | **built** (G). The comparators are INFERRED std::less; the walk directions are READ |
| 23 | the name mode: name / grant name / fortress position, retitling 400 (c:0x5ba970) | **built** (G) |
| 21 | the member list's scroll | **built** (G) |
| rows 28..260 (CNIFGuildUserSlot) | lamp, race, name, level, rank, GP. **A left press selects the row: its bar art becomes com_bar01select_, a (255, 178, 82) frame** (c:0x5b7090) | **built** (G; the highlight was hidden before) |
| 37 Invite | bit 0x01 | built (822) |
| 38 | "Give authority" (master) / "Check authority" (member): opens the permission pane 1000 | **built** (G) |
| 39 Ban | bit 0x02 | built (822) |
| 40 Grant name | READ: bit 0x04, then disabled for a member and enabled for the master at level 4 or higher | OURS (814): any member names themselves |
| 41 Position allocating | fortress positions, CIFGuildPositionGrant | out of scope (fortress war); kept disabled |
| 1000 CNIFGuildGrantPow | the permission pane: members but the master, by name. Checks 105..109 are bits 0x01 / 0x02 / 0x04 union chat / 0x08 storage / 0x10 notice. Header 93's tooltip counts union chat holders + 1 of 12. Confirm 151 sends 0x7104, Cancel 152. Read-only for a member | **built** (G) |
| right-click / double-click on a row | none: CNIFGuildUserSlot handles 0x201 only (vslot_017 c:0x5b8790), and the window's message map has no other row entries (READ) | the original has no whisper or party invite from the guild list; nothing to build |

The relations pane 164 (`guild_r.2dt`: ally 87 / hostile 88 tabs, CNIFAllianceSlot rows, the
alliance window 2000 with its buttons 52 / 53 / 60) belongs to lane **U** (allies) and lane **V**
(hostile). The war pane 548 (`guild_w.2dt`, CNIFGuildWar, CNIFGuildWarSlot,
CNIFContributionSlot) belongs to lane **V**.

The community view 177 (friends, blocking, letters) is built (595, 834). Letters are not built
(not guild).

## 4. The other guild windows

| window | layout | opened by | status |
|---|---|---|---|
| GuildMsgBox 0x0F / 0x12 / 0x13 / 0x14, the ban question | ifmessagebox | membership | built (822) |
| crest boxes 0x15..0x1b | -- | crest items | built (824) |
| CIFGuildNotifyWrite (439 x 307) | ifguildnotifywrite.txt | pencil 81 | **built** (G) |
| CIFGuildNotifyContents | ifguildnotifycontents.txt | the academy's notice (mode 2) | out of scope (academy) |
| CIFGuildLevelUp (360 x 220) | ifguildlevelup.txt | line 0x17 | **built** (G) |
| CIFGuildPointUp (360 x 240) | ifguildpointup.txt | button 250 | **built** (G) |
| (ifguilddonategp.txt) | an older donation layout | no reference in the client code found | -- |
| CIFGuildMasterLeave (249 x 315) + slot | ifguildmasterleave*.txt | line 0x18 | **built** (G) |
| CIFGuildMasterElection (274 x 315) + slot | ifguildmasterelection*.txt | line 0x1a | missing (G) |
| CIFGuildPositionGrant (286 x 310) | ifguildpositiongrant.txt | button 41 | out of scope (fortress war) |
| CIFGuildWar / WarRequest / WarAgree / WarConfirm | ifguildwar*.txt | war | missing (V) |
| CIFStorageRoom (254 x 317) | -- | line 0x1d | missing (H) |
| CIFGuildSummonReq (360 x 160) | -- | 0x7030 | missing (G) |
| ifguildrelation(s).txt | -- | the old relations window | U / V |

## 5. The guild manager's talk lines (interaction 0x0f, FUN_00700440 c:0x70105e..0x701170)

| item | text key | who | status |
|---|---|---|---|
| 0x12 | UIIT_CTL_GUILD_CREATE | no guild | built (521 / 822) |
| 0x17 | UIIT_MSG_GUILD_LEVEL_UP "Promote the guild." | master | **built** (G) |
| 0x14 | UIIT_CTL_GUILD_BREAK | master | built (822) |
| 0x18 | UIIT_CTL_MASTERLEAVE "Transfer leadership" | master | **built** (G) |
| 0x1b | UIIT_CTL_GUILD_COMPENSATION "War reward gold received" (0x7114) | master | missing (V) |
| 0x1c | UIIT_CTL_GUILD_SECESSION | member | built (822) |
| 0x19 or 0x1a (by 0x99da70) | UIIT_CTL_MASTERRELEASE / UIIT_CTL_MRELEASE_VOTE | in a guild | missing (G, OPEN) |
| 0x1d | UIIT_CTL_GUILD_WAREHOUSE | in a guild | missing (H) |
| 0x43 | UIIT_STT_GUILD_GP_HISTORY "GP Usage History" | in a guild | missing (G; its window and request are not traced, OPEN) |
| store lines | the guild store's goods (the STORE_*_GUILD tabs, PaymentDevice 8 = GP, c:0x617360) | in a guild | partial: the store opens; buying with GP (master only, 0x18c4 / 0x18c5) is not modelled |

## 6. GP: earned and spent

| | READ | status |
|---|---|---|
| earned | a member's skill points 1:1, in batches of 10 (round 272) | built (525) |
| donated | SP -> GP, 0x7258. The rate is OPEN; OpenSRO uses 1:1, INFERRED | **built** (G) |
| level-up | 5400 / 50400 / 135000 / 378000 GP plus 3M / 9M / 15M / 21M gold | built (528), the NPC window (G) |
| guild store goods | PaymentDevice 8 prices, the master only | missing (G, OPEN: the store's GP lane) |
| soldier abilities | 10,000 GP reset / 50,000 GP buy, plus 500,000 gold | out of scope (fortress war) |
| mercenary attribute | FUN_005c7900 / job 0x2b | out of scope (fortress war) |

## 7. Fortress war, as the guild sees it (all out of scope)

The member's siege role (the block's u8, 0x38F5 type 6 mask 0x40, the name mode 2's text) is kept
and shown. Also out of scope:
- button 41 / CIFGuildPositionGrant / 0x70FF;
- 0x3103;
- the soldier abilities 0x7259 and the mercenaries 0x725A;
- the hand-over's siege-period refusal 0x4c5d and FORT_POSITION_GRANT_FAIL_07.

There is no fortress tab in the guild window: its three tabs are info, relations and war.

## 8. OPEN

- **The master-release vote** (0x7105-0x7107, 0x3908, CIFGuildMasterElection).
  - The GameServer's checks are read: a vote already running 0x4c37; the master online 0x4c33;
    then `_Guild_Master_Election_Available(master, 45)`, where 45 is INFERRED to be days absent.
  - The vote's rules live in the database procedures and CVoteManager, which were not read
    through.
- **GP Usage History (line 0x43)**: its window and request were not traced.
- **The guild recall (0x7030 / 0x7031)**: the fields' meanings are not read.
- **The notice filter's configured word list** (s:0x7312f0 beyond the two quotes): not read.
- **The guild store's GP purchases**: not modelled.
