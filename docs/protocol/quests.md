# Quests (round 785)

The quest system end to end: where each piece of a quest lives in the
operator's own data, how the retail server runs it, the messages the retail
client speaks, and what OpenSRO does. Labels: **READ** (from a binary, with
the address), **MEASURED** (counted in the data), **INFERRED**, **OURS**
(OpenSRO's own choice), **OPEN**.

`quest_scripting.md` is the older reverse-engineering trail (rounds 427-434);
its conclusion that the classless quests are Lua is confirmed here with the
scripts themselves.

## 1. Where the data is

| piece | source | label |
|---|---|---|
| id, code name, required level, text ids | `questdata.txt` (Media.pk2): 0 Service, 1 ID, 2 CodeName, 3 level, 4 Korean title, 5 `SN_<Q>`, 6 `SN_PAY_<Q>`, 7 xxx, 8 `SN_PAYCON_<Q>`, 9 `SN_NN_<Q>`, 10 `SN_NC_<Q>` | READ (client `GlobalDataManager::FUN_0097e470`), MEASURED 696 rows in service |
| rewards | `refqusetreward.txt` (the client's copy of `_RefQuestReward`, 709 rows; spelled so): 0 QuestID, 1 CodeName, 2 IsView, 3 basic-reward flag, 4 item-reward flag, 5-9 item-block bytes, **10 gold, 11 EXP, 12 skill EXP, 13 SP, 14 AP** | READ (client 0x97f2e0, labels in `UI_QUESTREWARD::FUN_00605250`); 10/11/12 MEASURED against every `SN_PAYCON_` text checked ("Exp 270 / GOLD 205") |
| reward items | `refquestrewarditems.txt` (`_RefQuestRewardItems`): 0 QuestID, 1 CodeName, 3 item code, 7 count | count INFERRED |
| race, prerequisite list, objective texts | `questcontentsdata.txt`: col 2 (0-based) country 0 China / 1 Europe / 3 both; 3 prerequisites; 5-12 `SN_CON_*` | READ (client `FUN_0097e890`) |
| **everything a quest does** for 529 quests | the game server's `Script/VIETNAM/Quest.sct`, Lua 5.1 bytecode | READ, section 2 |
| the same for 149 of the 154 compiled quests | `CQNO_<Q>::DeclareQuestContent` in `SR_GameServer.exe` | READ, section 3 |
| texts | `textquest_queststring.txt`, `textquest_otherstring.txt`, `textquest_speech&name.txt` (Media.pk2) | the client resolves the ids itself |

**The server reward table wins.** The retail server builds a quest's reward
from `_RefQuestReward` (`FUN_009287c0`, "Can not find QuestRewardData :
QuestID [%d]", READ), which is the table the client shows; the scripts also
call `LuaSetAchievedItem(n, exp, spexp, gold, ...)` (0x86c2e0: +0x8c4,
+0x8c8, +0x8c0, READ). The two differ in gold, EXP or skill EXP on 8 quests only
(MEASURED by the exporter, which lists them): this private server's
own `QNO_AA_*` quests (script EXP 7200, table 1337 -- a private-server
modification) and QNO_CA_HUNTER_1, whose script has gold and skill EXP the
other way round (table 6000 gold / 2700 skill EXP, script 2700 / 6000).
OpenSRO pays the table row and falls back to the script's values only when a
quest has no row (OURS).

## 2. The Lua quest scripts

`Script/VIETNAM/` holds five Lua 5.1 chunks (`file`: "Lua bytecode, version
5.1"; MEASURED): `define.sct` (constants: `QSC_*`, `QUEST_STATUS_*`,
`MISSION_TYPE_*`, `MONSTER_CLASS_*`, `TALK_RESPONSE_LIST_BASE = 5`, ...),
`QuestList.sct` (`QUEST_LIST()`: 533 `LuaInsertQuest(TYPE_ID, "SN_<Q>.lua",
"<Q>")`), `Quest.sct` (a global function `<Q>()` per quest), `EventList.sct`
and `Event.sct`.

A quest's function is a straight sequence of host-function calls. The host
functions are registered at 0x8706b0..0x870d2a as `mov eax,<fn>; mov
edi,<name>; call` (READ); each body takes its arguments in stack order. The
ones the catalogue reads:

| call | arguments (READ from the body) | meaning |
|---|---|---|
| `LuaSetStartCodition` 0x869f90 | n, n x QSC mask, level (+0x86c), x (+0x820) | the condition flags; the required level (= questdata col 3 on 515 of 531, MEASURED); x is OPEN |
| `LuaSetRaceStartCodition` 0x869ef0 | mask, race byte (+0x870) | a race gate (4 quests) |
| `LuaSetStartMethod` 0x86a1c0 | method, n, n x NPC | the NPCs that offer it |
| `LuaQuestInsertNpc` 0x86c430 | n, n x NPC | the NPCs involved |
| `LuaInsertMissionOrCompleteNpc` 0x86a280 | NPC | the NPC that pays (INFERRED from the name and the dialogues) |
| `LuaInsertDependancyQuests[OneClear]` 0x86a500 | n, n x code | prerequisites (all / one) |
| `LuaSetAchievementLimit` 0x86a180 | byte (+0x825) | times it can be done; 0 when not called (INFERRED: no limit) |
| `LuaSetMissionData` 0x86c0f0 | QUESTID, i, type, text, n, mob, ?, class, **count** (+0x1f48), ? | a kill mission (one mob read) |
| `LuaSetMissionData_EX` 0x86b710 | QUESTID, i, type, text, n, n x mob, m, m x ?, **count**, ?, ? | a kill mission, several mobs |
| `LuaSetCollectionItemMissionData` 0x86bf20 | QUESTID, i, type, text, n, NPC, (dropped), **count** (+0x3678), item (+0x3698), n x (mob, rate float) | gather from monsters; rates 0.5..100, INFERRED percent |
| `LuaSetDeliverMissionData[_EX]` 0x86ab00 / 0x86acb0 | QUESTID, i, type, text, NPC, n x (count, item), n x talk, [n x (count, item) handed over, ...] | a delivery |
| `LuaSetDialLogMissionData` 0x86bb80 | QUESTID, i, type, text, n x talk | a talk |
| `InsertQuestMenuStringList` 0x86c4b0 | NPC, n, n x (key, text id) | the dialogue text per NPC and `BASIC_MENUSTRING_*` key |

`cmd/export-refdata -mode quests` runs the scripts with `internal/quest/luabc`
(a Lua 5.1 bytecode reader and a small interpreter, OURS) against recorders in
place of the host functions, and keeps every call's arguments. On the user's
server files: 533 listed, 529 in questdata (4 are not), every setup ran
(MEASURED). Calls not modelled, with their counts, are printed by the
exporter: `LuaSetDivideType` 125, `LuaSetRealTime` 58, `LuaSetDifferentString`
40, `LuaSetJobTypeStartCondition` 33, `LuaSetAchievedPoint` 30, and nine
rarer ones (OPEN).

Note: this server pack is a private server's (`y0gi_Easy_vPLUS`): it carries
custom quests (`QNO_AA_*`, `NPC_QUESTS`, `ITEM_MALL_GLOBAL_CHATTING` rewards)
beside the retail ones (MEASURED).

## 3. The compiled quests

154 quests are classes (`.?AVCQNO_<Q>@@`, MEASURED by RTTI); their vtable slot
55, `DeclareQuestContent`, stores literals into the quest object. The
exporter reads them from the project's decompilation (`-decomp-dir`,
`funcs_*.c`):

| store | meaning |
|---|---|
| `param_1[0xc2] \|= m`, `+0x23`, `+4` | condition flags, level, the second value (as the Lua builder's +0x86c/+0x820 are copied there, 0x929660 READ) |
| `param_1[0xc4] + 8 + 4i` | the quest NPCs |
| `FUN_00401fc0("NPC_...")` x2 | the complete NPC, then the start NPC (INFERRED: CONS_2 pushes MERCHANT then POTION, and the scripted CONS_3 after it starts at MERCHANT) |
| `FUN_00401fc0("QNO_...")`, `param_1[0x150]` | prerequisites, how many of them are needed |
| `param_1[0x126+i]` | quest NPC i's greeting |
| `param_1[0x130+k]` | the menu text of key k, in the builder's per-NPC block order READ in 0x86c4b0 (and its tail by disassembly, 0x86c820..0x86c978): REQUEST_ACCEPT_QUEST, AT_ACCEPT, AT_DENY, NOT_ACHIEVED, ACHIEVED, NOT_ACHIEVED2, INVENTORY_FULL, CONTENT_STRING, GREETING (0x138: every single-NPC class stores `SN_NPC_*_QS` there), ACHIEVED_NOW, ABORT_BY_LEVELUP, COUNT_LIMIT, TIME_LIMIT_AUTO_ABORT, MIDDLE_ACHIEVED, ACCEPT_AFTER_ONE_CLEAR, NOT_PARTY |
| `FUN_009dd2bc(size)` .. `FUN_009173b0()` | one mission object, its class by size: 0x152 kill (+0x15 n, +0x19 mobs, +0x149 count), 0x25a gather (+0x15 NPC, +0x19 n, +0x1d mobs, +0x14d rate constants, +0x23d count, +0x241 item), 0xa7 dialogue (+0x15 NPC, +0x1e talk), 0x121 delivery (+0x15 NPC, +0x1a count, +0x42 item, +0xc0 talk) -- MEASURED across the Europe chain against the objective texts |

149 of the 154 classes have a DeclareQuestContent in the dump (MEASURED). A
mission class outside the four (0x26, a change-item mission, in
QNO_EU_EASTEU_1) leaves its quest unplayable (OPEN).

## 4. Coverage (the user's data, MEASURED by the exporter's `-quest-report`)

| | quests |
|---|---:|
| in questdata (service 1) | 696 |
| scripted (Lua) | 529 |
| compiled, setup read | 149 of 154 |
| questdata only (tutorials, event guide) | 13 |
| **playable** (every mission modelled, a start NPC) | **618** (520 scripted, 98 compiled) |
| **reachable** (playable and every prerequisite chain playable) | **564** (497 scripted, 67 compiled) |

The early game: China's Jangan quests (QNO_CH_SMITH_1, CHEF_1, SOLDIER_EA1_1,
POTION_1/2/3/4, SOLDIER_EA2_1, PRIEST_1, SHAMAN_1/2, GENARAL_BO_1/2,
GENARAL_SP_1, SPECIAL_1/2/3, HORSE_1, EUROPE_1/2, SMITH_2, FERRY2_1) are all
reachable. QNO_CH_GENARAL_1 is defined in Quest.sct but not listed in
QuestList.sct, so this server never sets it up (MEASURED; QNO_AA_BAGHDAD
likewise), which blocks GENARAL_2/3. Europe's Constantinople chain
QNO_EU_CONS_1..12 is reachable end to end; EASTEU_1 (a change-item mission)
blocks EASTEU_2/3, EASTEU_5 and the `_1` variants of 11/14/17 use mission
classes not modelled; the rest of EASTEU to 18 is reachable. Every quest at
level 30 or below that is not reachable: QEVENT_GUIDE, QTUTORIAL_CH/EU/EU_2,
QNO_EU_TUTORIAL_1..7, QSP_ALL_POTION_1/3, QNO_CH_GENARAL_1/2/3,
QNO_WC_WAREHOUSE_W_2/3, QNO_EU_EASTEU_1/2/3/5/11_1/14_1/17_1,
QNO_EU_GENERAL_2/3, QNO_EU_WITCH_1/1_1, QNO_CA_WAREHOUSE_1/2, QNO_EU_IVY_2/3
(MEASURED, `-quest-report`). `QTUTORIAL_CH`, `QTUTORIAL_EU`, `QTUTORIAL_EU_2`
and `QNO_EU_TUTORIAL_1..7` have neither a script nor a class (OPEN: the
client-side tutorial).

## 5. Messages

Strings are a u16 length and the bytes (`FUN_004f7a70`). All READ from
`sro_client.exe` unless marked.

| opcode | dir | layout | where |
|---|---|---|---|
| 0x30D5 | S->C | u8 kind (1 add, 2 change, 3 remove, 4 remove), u32 quest, body for 1/2 | `FUN_008812b0`; body `FUN_008b94d0` |
| body | | u8 counter (+8), u8 state (+9), u8 flags; flags&4 u32 time; flags&8 u8 status; flags&0x10 u8 n x (u8 index, u8 open flag, string text, u8 m, m x u32 value); flags&0x40 u8 n x u32 NPC RefObjID | |
| (log) | S->C | u16 n x u32 completed; u8 n x (u32 quest, body); u8 n marks | `ICPlayer::FUN_009d9830`, inside retail's character data; OpenSRO sends it as **0x00B1 (OURS)** after the world entry |
| 0x30D4 | S->C | u8 type, string text; type 4/5: u8 n x string; type 5: string, u32 | `FUN_00889d90` -> `FUN_006fc1c0`: type 1 one CONFIRM line (response 1), 3 YES (2) / NO (3), 4 a numbered list (response 5+i) |
| 0x70D4 | C->S | u8 response | built with 0x30D4 at 0x7026be; the server handler is index 0x0d4 (`GObjPC_HandleTalkMenuSelectMsg_0d4`); OpenSRO accepts both |
| 0x30D6 | S->C | u32 object, u8 flags, u8 mark (1 start, 2 going, 3 end, 4 r), u16, 12 bytes; u32 if flags&2 | `FUN_008811e0`; the u16 and 12 bytes INFERRED region and position |
| 0x30D7 | S->C | u32 object | removes the mark |
| 0x3514 | S->C | u32 quest, u8 n, string text | opens `CNIFQuestReward` |
| 0x7515 | C->S | u32 quest, u8 n x u32 chosen | `FUN_008252d0` |
| 0xB515 | S->C | u8 1, or u8 2 + u8 err (2 `UIIT_STT_QUESTREWARD_ERROR`) | `FUN_00881570` |
| 0x70D9 / 0xB0D9 | | u32 quest / u8 1 + u32, or u8 2 + u8 err (4 not allowed, 5 GIVEUP_1) | give up |
| 0x70D8 / 0xB0D8 | | u32 quest / u8 1 + u32, or u8 2 + u16 | the quest window's reward button on a status-2 quest |

The talk flow (the client's page types and the scripts' keys):

1. `0x7046 {npc, 2}` -> `0xB046` ok -> 0x30D4 type 4: the NPC's greeting
   (`BASIC_MENUSTRING_GREETING`, e.g. `SN_NPC_CH_SMITH_QS`) and one line per
   quest (`SN_<Q>`): the ones under way here first, then the offers.
2. An offer -> type 3 with `REQUEST_ACCEPT_QUEST`; yes -> 0x30D5 add, the
   delivery items handed over, type 1 with `AT_ACCEPT`; no -> `AT_DENY`.
3. A quest under way here -> its deliveries and dialogues at this NPC settle
   (the mission's own talk line); done and this its complete NPC -> 0x3514
   with `ACHIEVED`; otherwise `MIDDLE_ACHIEVED` (done, paid elsewhere) or
   `NOT_ACHIEVED`.
4. 0x7515 -> the reward (gold, EXP and skill EXP with a level-up, SP, items),
   the gathered quest items taken back, 0x30D5 kind 4, 0xB515 {1}. A bag
   without room for the items refuses with `INVENTORY_FULL` and {2, 2}.

Which NPC selects show "Talk" (id 2) is per player (0x4c9310's filter,
`npcspawn/questtalk.go`): with the catalogue loaded, an NPC offers it exactly
when it has quest business with the character.

## 6. What OpenSRO decides (OURS)

- **Kill credit goes to the killer** (`announceKill`); whether party members
  share it is OPEN (`LuaSetDivideType`, 125 quests, is unread).
- **Gather drops** go straight into the bag at the mission's rate; a full bag
  neither drops nor counts. The drop is given first, and the mission is stepped
  against the log as it is then (`quest.KillCredits` / `quest.Credit`, round 785
  review). A drop whose quest was given up or finished meanwhile is taken back.
- **Saving**: a character's quest writes are serialised, and each writes the
  state as it is at its turn. The reward is paid only after the paid state is
  saved; a failed save refuses with {2, 2} and the quest stays unpaid.
- **The talk** is bound to its character and to the NPC's reach (the select's
  300, `npcTarget`). It ends on 0x704B, except at the reward window, which
  OpenSRO's client keeps open. It also ends on a teleport and on a character's
  entry. Retail (READ, round 785 review): 0x70D4 (0x516670) and 0x7515
  (0x51b370) test no distance themselves. They need the PC's selection of the
  NPC (`FUN_005165f0`), which breaks beyond 320 on a cell change (0x433270).
  0x7515 also needs talk mode 5 and always ends the interaction. 0x70D8
  (0x516780) involves no NPC.
- **Deliveries**: the items a delivery names are handed over at acceptance and
  taken at the target NPC (the script's two item lists are not told apart).
- **Dialogues** complete at the quest's complete NPC.
- **Reward items**: all of a quest's reward items, or the chosen subset when
  the client names some (the choice block, refqusetreward cols 5-9, is OPEN).
- **Marks**: an NPC with a quest to hand in carries 3 (end), else one with an
  offer 1 (start), else one with a quest under way 2 (going); sent at entry and
  after every change.
- **0x30D5 counter (+8)**: achievement count in the low nibble, the limit in
  the high one (the window draws them "%s (%d/%d)"); state (+9) 1.
- **0x70D8** opens the reward window only for a quest that names no complete
  NPC; otherwise {2, 1}.
- **Repeatable quests** (limit 0) can be taken again after being paid.
- **Abandoning** forgets an unfinished first run, keeps the count of an earlier
  completion, and takes the quest's items back.

## 7. OPEN

- The second level value (`LuaSetStartCodition`'s last argument, +0x820).
- Party credit and `LuaSetDivideType`; `LuaSetRealTime` and the time limits;
  `LuaSetJobTypeStartCondition` (job quests); `LuaSetAchievedPoint`.
- The 13 questdata-only quests, the change-item mission class, and 5 compiled
  classes absent from the dump.
- The talk answer's wire opcode (0x30D4 built, 0x70D4 handled: both accepted).
- The default quests a new character is given (round 692) are still recorded,
  not opened: none of them (`QTUTORIAL_*`, `QEVENT_GUIDE`) has a setup.
