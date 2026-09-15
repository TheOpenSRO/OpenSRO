# RE completion ledger

**What "100%" means here.** Both binaries are already decompiled in full —
`SR_GameServer.exe` (30,385 functions) and `sro_client.exe` (39,851), 0 failures,
0 skipped, on the RE box at `/var/tmp/decomp_server` and `/var/tmp/decomp_client`
(see `client/tools/ghidra/README.md`). Dumping is done. **This ledger tracks the
part that is not: every game value this project runs on being either recovered
from real data/binary, or honestly disclosed as own design with the reason.**

A line is **GROUNDED** when a real citation exists (data file + column, or a
binary function + offset). It is **DISCLOSED** when it is ours and labelled as
such. It is **OPEN** when nobody has tried hard enough to say which.

Score = GROUNDED / (GROUNDED + OPEN). Disclosed-by-necessity does not count
against completion *if* the reason is proven (the data genuinely does not exist),
which is itself a recovery — quest objectives are the model for that.

## Grounded

| Value | Where it came from |
|---|---|
| EXP curve | `leveldata.txt` col 1 |
| EXP overflow carry, level cap 110, max-level bar | client `FUN_008a97c0` |
| Mastery level-up SP cost | `leveldata` col 2 (server `FUN_0059c4e0` sums `entry+0x10`) |
| Skill damage | skill `'att'` param: percent of weapon damage + flat min–max |
| Skill cooldown / MP cost / learn gating | `_RefSkill` ReuseDelay, Consume_MP, ReqLearn_SP, mastery reqs |
| Monster identity (CodeName, Level, Rarity, Name) | `characterdata` cols 2/57/15/5 + `textdata_object` |
| Monster MaxHP | `characterdata` col 59 (`RefObjChar::ExtractData` → `m_dwMaxHP` at +0x19c) |
| Shop prices | `itemdata` cols 26/31 |
| Item max stack | `itemdata` col 57 |
| Armour/shield defence | `itemdata` cols 63/65-66/74-75/76-77 |
| Potion restore amounts | `itemdata` Param block cols 118/120/122/124 (self-labelling) |
| **Player MaxHP / MaxMP (whole formula)** | `Str×10×1.02^(lvl−1)` / `Int×10×1.02^(lvl−1)` — `GObjPC_InitStats` graph, `.rdata 0x00b462ac`=1000, `0x00b45ea0`=1.02 |
| ParamKeeper ids 0/1/2/3/4 = Level/Str/Int/MaxHP/MaxMP | `GObjPC_InitStats` pushes `charData+0x65/+0x74/+0x76`; `GObjMob_PublishStats` pushes `refobj+0x19c`/`+0x1a0`; and `Stat_ApplyTaggedModifier` maps `'int'`→2, `'hp'`→3, `'mp'`→4 independently |
| **Monster EXP per kill** | `leveldata` col 5 at `min(killerLvl, victimLvl)` — `Formula_MonsterExpReward` (004105d0) reads levelRecord `+0x1c`, result to `GObjPC_GiveExp` (vtable 0x694); `FUN_00631050` grants `entry[0x1c]*n` directly. Column settled by elimination; identical in the ORIGINAL client |
| **Monster `characterdata` cols 75–78** | `'era'`→9, `'bri'`→10, `'hra'`→11, `'cri'`→12 from `Stat_ApplyTaggedModifier`; real data: col 76 = **0** for every monster, cols 75 = 77 = **2·level+25**, col 78 = **2** |
| Stat points per level (3) | real character window |
| Quest identity, chain, descriptions, rewards | `questdata`, `questcontentsdata` cols 3/5-12, `refquestrewarditems` |
| Quest objectives are NOT data | proven absent: no objective refdata class; `_CHARQUEST` is status+count |

## Open — the actual work queue

Ordered by value. Each line names the next concrete probe, so a cold start can
pick one up without re-deriving anything.

1. **Monster combat profile — CLOSED (2026-09-15).** Every term is real now.

   | what | source | values |
   |---|---|---|
   | MaxHP | `characterdata` col 59 | Mangyang 54 … Yeoha 249 |
   | flat absorption | col 71 → param 5 | 7, 12, 22, 103 |
   | reduction % | col 73 → param 7 | = the monster's level |
   | **attack damage** | **col 83 → that skill's `'att'` param** | 17-19 … 67-79 |
   | exp per kill | `leveldata` col 5 at `min(lvl)` | 24 … 12550 |

   **Monster attack was hiding in plain sight because it is not a stat.** No
   column holds it and `GObjMob_PublishStats` never publishes a damage range —
   only `Char_PublishCombatStats` sets params 190/191, and that is the character
   path. A monster attacks with a **skill**: characterdata col 83 is its primary
   attack skill id, and the ids are named after the species itself —
   `160 = MSKILL_CH_MANGNYANG_ATTACK01`, `165 = MSKILL_CH_GYO_ATTACK02`,
   `176 = MSKILL_CH_YEOHA_ATTACK01`. That skill's `'att'` param carries the
   damage, and this project decoded `'att'` months ago for player skills. With
   no weapon to scale, the grounded skill formula collapses to `rand(min, max)`.

   The ranges rise cleanly with level across the whole Jangan ladder (17-19,
   21-23, 25-29, 30-34, 35-40, 41-47, 47-54, 60-70, 67-79), which is
   corroboration rather than the finding — the finding is the skill-id column.

   *Gold — data real, linkage inferred (2026-09-15).* `levelgold.txt` ships with
   the **original client**, shaped level → min → max (L1 = 28-59, L10 = 60-125,
   L27 = 119-250). The server's level-table manager holds a per-level gold table
   at `+0x268`, and what makes it *the gold table* rather than a lookalike is a
   use-site: `FUN_009348f0` spawns `ITEM_ETC_GOLD_03` (itemdata id 3) with an
   amount rolled straight out of it by `FUN_00724330`, which reads entries as
   `{chance, min, max}`. Three `Formulae` functions read the same table after
   `Char_GetLevel`.

   **What is not proven is that `levelgold.txt` fills `+0x268`.** The server
   references no refdata filename anywhere — it loads from its database — so no
   parser ties the file to the table. Two real things that fit perfectly, with
   the join inferred. Shipped anyway, labelled in `combat.RollGold`, because it
   is strictly better than the `10 + level*5` invention it replaces; a reader who
   disagrees can find the exact gap named in the doc comment.

2. **Death penalty — recovered, deliberately NOT shipped.** `GObjPC_OnDeath`
   (`004e6980`) pays the killer and then penalises the dead: exp loss computed as
   `levelEntry+0x1c` (the same per-level exp unit that pays for a kill) times
   **20, 100 or 300** depending on branch, applied through
   `GObjPC_GainExpAndLevel` with a **negative** amount; skill-point loss through
   `GObjPC_AddSkillPoints`, also negative and capped at what the character has;
   then a `rand` roll that can drop an inventory item via
   `CGStorage__RandomSelectNonEmptySlotForDeathPenalty`. All gated on the dead
   character's level being above 10.

   **Half the blocker is gone (2026-09-15).** `charData+0xb4` is
   **`PKPenaltyPoint`**, from `CharData_BindDBColumns`. Re-reading the penalty
   with that in hand, it is a *criminal* rule: the killer's exp **doubles** when
   the victim carries PK penalty, and the victim's own loss is **3× plus 60 skill
   points** in that case against the smaller factor otherwise.

   Still not shipped, because the other condition — `param_2[0x72d] != 5`, a byte
   state enum on the GObj rather than on charData — remains unidentified, and it
   selects between the 20×, 100× and 300× factors. *Next probe:* that state enum;
   values 2 and 5 are both used at other sites.

   This also corrected a name. `004e6980` was called `GObjPC_GrantKillReward`
   after an earlier pass read only its first half; it is the death handler, and
   `ApplyKnownNames.java` gained a `force` mode so the table can fix its own
   mistakes rather than only add to them.

3. **Combat damage model — the mitigation formula is RECOVERED; the model is
   not yet shipped.** srrevamp still runs `base + bonus - defence, floor 1`, own
   design. The real one is now partly in hand.

   **The unlock was the read side.** Two ticks were lost hunting inlined keeper
   reads (`obj[0x7c+N]`) that collide with every other struct at byte 0x204.
   That was the wrong shape entirely: stats are read through a **virtual at
   vtable offset 0x104 that takes the param id as a literal argument** —
   `(**(code **)(*obj + 0x104))(0xbf)`. So every param read in the binary is
   greppable, with its id visible. 141 read sites. This is the single most
   useful handle found for the stat system and it should be the first thing
   reached for next time.

   **What it produced:**

   - `Formula_RollWeaponDamage` (`0040f8d0`) — the damage roll:
     `rand() % (max-min+1) + min`, with **min = param 191, max = param 190**,
     returning 0 when `max <= min`. `Char_PublishCombatStats` sets 190/191 and
     192/193 as the two types' min/max pairs.
   - `Formula_MitigatePhysicalDamage` (`0040e450`) and
     `Formula_MitigateMagicalDamage` (`0040e830`) — twins, gated on bits 4 and 8
     of the flags at `+0x230`, structurally identical:

     ```
     damage = X / (1 + reduction% / 100) - flatAbsorb        (floored at 0)
     ```

     with **param 7** the reduction percentage on one side and **param 8** on the
     other (`0x00b45ac0` = 1.0, `0x00b45af0` = 100.0). So mitigation is
     *percentage-based with a flat term*, not the flat subtraction srrevamp
     currently uses.

   That also half-answers open item 1: params 5/7 are one damage type and 6/8
   the other, and **param 7/8 is a percentage reduction**. Joined to the column
   map, a monster's cols 73/74 → params 7/8 hold *exactly its level*, so a
   level-10 monster mitigates 10%. Physical-vs-magical rests on the player stat
   graph feeding param 5 from Strength and param 6 from Intellect.

   *Not settled, and why nothing shipped:* which object the formula reads from.
   Both params are read off the same pointer (`param_2`), and until the call
   site in `Combat_ResolveDamage` is resolved it is not proven whether that is
   the attacker or the defender — which decides whether params 5/6 are attack or
   defence. *Next probe:* resolve `Combat_ResolveDamage`'s arguments at its four
   calls to each twin (register-passed — use `ResolveRegArg.java`).

4. **Berserk numbers** (fill 8/hit, 20 s, +50 %) — ours. The mechanic and the
   five orbs are real.
   **The recorded next probe was WRONG and is withdrawn (2026-09-15).** It said
   to chase the `'zb'` tag; the client's own text says `PARAM_ZB` = **"Zombie"**,
   a status effect, nothing to do with berserk. Berserk is **"Hwan"** internally
   (`PARAM_HWAN_TIME_INCREASE` = *"Berserker time %d sec. increased"*,
   `UIIT_CTL_TC_ACQUISITION_WHAN` = *"Chance of Obtaining Berserk Gage"*).
   `hwanleveldata.txt` was checked and is **not** it either — 255 rows of
   *titles* ("Ambassador", "Champion", "Conqueror"), not gauge values. The
   numbers look genuinely server-side; *next probe:* the `HWAN`/`WHAN` naming in
   the server binary, not the client's data.
5. **Monster spawn positions** — ours by necessity (`npcpos.txt` has no
   monsters). Likely genuinely absent; prove it and it stops counting as open.
6. **Quest objectives** — proven not to exist as data; any objectives shipped
   must be own design. Closed as a *recovery*, not a gap.
7. **Loot tables** — **CLOSED as a proven absence (2026-09-15).** The mapping
   question was a non-issue: `RefMonsterID` *is* characterdata col 1 (Mangyang
   = 1933), which we already carry. The blocker is the data. The drop classes
   are real in the binary (`CRefMonster_AssignedItemRndDrop`,
   `CRefDropItemGroup`, `CRefDropItemAssign`) but **no drop table exists in any
   artifact this project has** — not in Media.pk2, not in the server's
   `SR_GameRefData/`, nowhere in the y0gi bundle (the only files matching
   "drop" are meshes for the falling-loot visuals). It lives in the server's
   SQL database. So per-monster drops stay own design *by necessity*, and
   become real the moment an operator brings that table — the schema and the
   key are both already in place.
8. **Inventory size (50)** — ours, and now known **not** to be a constant in the
   real game: `InventorySize` is a persisted per-character `_CHAR` column
   (charData `+0xac`), so inventory is expandable per character. The starting
   size is set on the database side, the same wall as starting Str/Int, so it
   stays disclosed — but as "a per-character value we fix at 50", not "a number
   nobody has found". **Unarmed damage (5)** — still ours.

## The client's refdata catalogue: 88 type ids

`Client_LoadAllRefData` pushes a **type id** alongside each `%stextdata\<file>`
name, and `Client_LoadRefDataFile` switches on that id. Pairing the two recovers
the complete enum — every reference-data file the client loads, with its id:

```
    1 skilldata_virtual                     2 itemdata                          
    3 worldmap_mapinfo                      4 worldmap_localinfo                
    5 characterdata                         6 gameguidedata                     
    7 usableresobjiddata                    8 leveldata                         
    9 actionwnddata                        12 erasableskill                     
   13 erasablemastery                      18 teleportdata                      
   19 teleportlink                         20 teleportbuilding                  
   21 npcchat                              23 skillgroup                        
   24 magicoption                          25 questdata                         
   26 questcontentsdata                    28 dg                                
   29 npcpos                               30 gachaitemset                      
   31 gachanpcmap                          32 levelgold                         
   33 fmncategorytreedata                  34 fmntidgroupmapdata                
   35 refshop                              36 refshoptabgroup                   
   37 refshoptab                           38 refmappingshopwithtab             
   39 refpackageitem                       40 refshopgoods                      
   41 refscrapofpackageitem                42 refpricepolicyofitem              
   43 refaccesspermissionofshop            44 reftreatitemofshop                
   45 refrewardpolicytobuyscrapitem        46 refrewardpolicytosellpackageitem  
   47 refrewardpolicytosellscrapitem       48 refconditiontosellpackageitem     
   49 refconditiontobuyscrapitem           50 refconditiontosellscrapitem       
   51 shopitemstockquantity                52 refshopgroup                      
   53 refmappingshopgroup                  54 siegefortress                     
   55 eventzonedata                        56 gameworlddata                     
   57 atstructeffect                       58 siegefortressitemforge            
   59 siegefortressbattlerank              60 siegestructupgradedata            
   61 force_addobject                      66 magicoptionassign                 
   67 refgachatreeforclientuidata          68 hwanleveldata                     
   69 eventdata                            71 worldmap_instanceinfo             
   72 event_npc_look                       74 refabilitybyitemoptleveldata      
   75 refskillbyitemoptleveldata           76 refmagicoptbyitemoptleveldata     
   77 itemeffect                           78 refoptionalteleport               
   79 eventguidedata                       80 item_grouping                     
   81 refsetitemgroup                      82 specialnpcdata                    
   83 maxtradescaledata                    85 mallitemmenulistdata              
   86 refshopitemstockperiod               87 gameworldconfigdata               
   89 worldmapguidedata                    90 eventword                         
   91 refmagicoptgroup                     93 worldmapguidedata_region          
   94 refquestrewarditems                  95 refqusetreward                    
   97 collectionbook_theme                 98 collectionbook_item               
   99 refrentitem                         100 refeventrewarditems               
  101 refeventreward                      102 siegefortressreward               
  103 refsiegeblessbuff                   104 refsiegedungeon                   
  106 groupworld_config_forclient       
```

This is the map for any future column work: it says which switch case parses
which file, so a column question starts at a known case instead of a 155KB
function. 421 functions appear in **exactly one** case, making them that file's
parsing code; 71 were still unattributed and are now in `RefData_<file>`
namespaces (the other 350 had already been swept into modules by the chain, and
an existing namespace is never overwritten).

Incidentally it re-confirms **type 32 = `levelgold`** — the client really does
load that file, which supports (without proving) the gold linkage recorded
above. And the client's own parser for it reads exactly **three** sequential
tokens — a byte then two dwords — which grounds `levelgold`'s
`(level, min, max)` shape in code rather than in eyeballed values.

### 39 refdata files now have a readable column map

A function that appears in **exactly one** switch case *and* reads many
sequential tokens is that file's record parser — and therefore its exact
column→offset map, straight from code. 59 such parsers exist; **39 are matched
to a named refdata type** and now carry `RefParse_<type>` names. Among them the
whole shop chain this project already depends on — `refshop`, `refshopgoods`,
`refshopgroup`, `refpricepolicyofitem`, `reftreatitemofshop`,
`refscrapofpackageitem`, `refpackageitem` — plus `teleportdata`/`teleportlink`,
`magicoption`, `worldmap_mapinfo`/`localinfo`, `gameworlddata`, `siegefortress`,
`leveldata` and `levelgold`.

**So a column question about any of those is now a two-minute read instead of a
dig.** That is the practical payoff of the catalogue.

**`characterdata` is NOT among them, and that is now confirmed rather than
suspected.** Case 5 calls fourteen functions and *none* of them reads a token
directly — the per-column parse really does hide behind virtual dispatch, as
this project found the hard way when it first tried the client. The
characterdata column map stays what it is: derived from the server's
`RefObjChar_ExtractData` store order, anchored on two independently-known
fields.

### Column order is NOT offset order — a correction to how this was reasoned

Reading the client's **leveldata** parser (case 8) settles something that had
been assumed rather than checked. It stores the nine columns like this:

```
col 0 → +0x08    col 3 → +0x1c    col 6 → +0x24
col 1 → +0x10    col 4 → +0x20    col 7 → +0x28
col 2 → +0x18    col 5 → +0x30    col 8 → +0x2c
```

**Column 5 is stored out of sequence.** So "the next column is at the next
offset" is false for these records, and that assumption appears verbatim in the
grounding of the monster exp unit: *"cols 3/4 are zero ints at +0x14/+0x18, so
col 5 is at +0x1c"*.

**The shipped value (v0.1.155) survives, but on different evidence than stated:**

- The alternative readings are impossible by value. If the server mirrored the
  client's layout, `+0x1c` would be **column 6 = 15,000,000**, and
  `FUN_00631050` hands `entry[0x1c] × multiplier` *straight* to
  `GObjPC_GainExpAndLevel` — a level-1 kill worth fifteen million experience.
  Column 7 is 15,000,000 too. Only column 5 (23.5·level) is a possible per-kill
  reward.
- The offsets the server actually reads are `+0x0c`, `+0x10`, `+0x1c` — under
  packing exactly columns 1, 2 and 5: the exp requirement, the mastery cost and
  the exp unit. Precisely the three fields the game needs, and nothing spare.

So the grounding rests on **elimination plus coherence**, not on packing. Any
future column↔offset inference in this codebase must not assume packing — the
client proves it does not hold.

`ApplyNamespaceTable.java` exists for this shape of result: attribution derived
by reasoning over the decompiled C, which a Ghidra script cannot redo, arriving
as a `address<TAB>namespace` table.

## The message dispatcher, and 29 packet handlers

`FUN_00414260` reads a **uint16 opcode** out of the message buffer at `+0x1050`
and branches into a handler per opcode — a compiler-built binary-search tree,
which is why it never looked like a table. 33 distinct opcodes have handlers
across the dispatcher family, in the expected shapes: **0x3xxx requests, 0xBxxx
responses**, plus some 0x7xxx and one 0x5xxx.

The 29 handler functions are named `MsgHandler_<opcode>` — **by their opcode,
because that is what is proven**. The number is a fact the dispatcher states;
what the handler *does* is not claimed, and a handler serving several opcodes
carries the first two in its name.

This is the **inter-server / gateway** protocol layer, not the main client one
(only 7 of the 33 are 0x7xxx).

**The client-facing protocol does not dispatch this way, and that is the
finding (2026-09-15).** Four routes were tried and none produced an
opcode→handler map:

- *More opcode switches.* Ranking functions by 0x70xx-0x75xx constants is a
  **false signal**: the stat tag literals collide with the opcode range —
  `'ps'` is 0x7073, `'zb'` is 0x7a62 — so the top hits are
  `Stat_ApplyTaggedModifier` and its family, not dispatchers.
- *`On*` handler names.* Only **10** exist in the whole server, all already
  recovered by the assert lever (`COpenMarketMgr__On*Req` is the nice family).
- *A masked opcode index.* **Zero** call sites of the form
  `(**(code **)(table + idx * 4))()` anywhere in the binary.
- *The one known handler's caller.* `FUN_0050d0c0` calls a
  `GObjPC_MsgHandler_SpecialCommand` function but contains no opcode comparison
  at all.

What it does instead: `FUN_004054d0` reads the opcode and then **walks a
registration table of subscribers** (`(id + 0x200) * 0x10 + base`), routing each
message to whoever registered. So there is no static opcode→handler table to
recover — the mapping is built at runtime, and recovering it would mean finding
every registration call site rather than reading one tree.

*Levers checked and found exhausted this pass, so nobody re-walks them:*
high-fan-in helpers (the top ten are all infrastructure — assert, `std::string`
assign, buffer write, allocator, list clear), and `__FILE__` attribution
(**zero** headroom: 153 server functions cite a path, all already namespaced,
and only one function anywhere cites two files).

## The real game's persisted data model

One helper binds every database column to its struct offset, and **60 functions
call it** — one per table. `NameDBBinders.java` names them all `DB_Bind_<TABLE>`
and writes each table's columns into its plate comment, so the schema lives in
the program. **55 named in a single pass**, which is the largest naming return
from one lever since the attribution chain.

It is self-validating, which is rare here: the `_CHAR` binder reproduces four
offsets this project had already derived by entirely unrelated routes —
`Strength` 0x74, `Intellect` 0x76, `CurLevel` 0x65, `RemainSkillPoint` 0x80, all
exact. A map that gets four known answers right is worth trusting for the rest.

The tables, by size: `_CHAR` (39), `_ITEMS` (19), `_OpenMarket` (16),
`_GUILDMEMBER` (15), `_TIMEDJOB`/`_TIMEDJOBFORPET` (14), `_TRAININGCAMPMEMBER`,
`_GUILDWAR`, `_LOGEVENTITEM` (11), `_ITEMQUOTATION`, `_GUILD`,
`_CharInstanceWorldData`, `_SiegeFortress`, `_RentItemInfo` (10), `_CHARCOS`,
`_CHARQUEST`, `_BindingOptionWithItem` (9), … plus `_USER`, `_INVENTORY`,
`_INVENTORYFORAVATAR`, `_INVENTORYFORLINKEDSTORAGE`, `_CHEST`, `_INVCOS`,
`_CHARSKILL`, `_CHARSKILLMASTERY`, `_Friend`, `_Memo`, and the siege/log family.

The ones srrevamp already implements something for:

```
_ITEMS      RefItemID, OptLevel, Variance, CreaterName,
            MagParamNum, MagParam x12, Serial64
_CHARQUEST  CharID, QuestID, Status, AchievementCount,
            StartTime, EndTime, QuestData1, QuestData2
_CHARSKILL          CharID, SkillID, Enable
_CHARSKILLMASTERY   CharID, MasteryID, Level
_Friend     CharID, FriendCharID, FriendCharName, RefObjID
_Memo       FromCharName, Message, Status, RefObjID
_CHARCOS    OwnerCharID, RefCharID, KeeperNPC, State, CharName,
            ExpOffset, PetOption, RentEndTime
_USER       UserJID, CharID
```

Two of those refine recorded conclusions rather than merely adding facts:

- **`_ITEMS` persists `Variance`** alongside `OptLevel` — so the real game rolls
  a per-instance stat variance, which is why two identical weapons differ. This
  project ships fixed itemdata values; that is a disclosed simplification nobody
  had named before.
- **`_CHARQUEST` has `QuestData1`/`QuestData2`**, not just status and a count.
  The standing conclusion ("objectives are not data; `_CHARQUEST` persists only
  status+count") is *narrowed*: objectives still live in server code, but
  per-quest progress state is richer than a counter, and those two slots are
  where it goes.

## The character struct, in the game's own column names

`CharData_BindDBColumns` (`0083e6b0`) binds every persisted `_CHAR` column to its
offset in charData — `FUN_00401fc0(name, nameLen)` then `local_150 = offset` —
for **38 columns**. It is the single best artifact in the binary for that struct,
and it **validates against four offsets this project had derived independently**:
`Strength` 0x74, `Intellect` 0x76, `CurLevel` 0x65, `RemainSkillPoint` 0x80, all
exact.

```
+0x020 CharID          +0x086 RemainHwanCount   +0x0b4 PKPenaltyPoint
+0x024 Deleted         +0x088 GatheredExpPoint  +0x0b8 GuildID
+0x028 RefObjID        +0x094 LatestRegion      +0x0bc LastLogout
+0x02c CharName16      +0x0a4 AppointedTeleport +0x0cc TelRegion
+0x048 NickName16      +0x0a8 AutoInvestExp     +0x0d0 TelPosX/Y/Z
+0x064 Scale           +0x0ac InventorySize     +0x0dc DiedRegion
+0x065 CurLevel        +0x0b0 DailyPK           +0x0e0 DiedPosX/Y/Z
+0x066 MaxLevel        +0x0b2 TotalPK           +0x0ec WorldID
+0x068 ExpOffset       +0x074 Strength          +0x0ee TelWorldID
+0x070 SExpOffset      +0x076 Intellect         +0x0f0 DiedWorldID
+0x078 RemainGold      +0x080 RemainSkillPoint  +0x0f2 HwanLevel
                       +0x084 RemainStatPoint
```

**What it settled immediately:**

- **`+0xb4` is `PKPenaltyPoint`** — one of the two unknown branch conditions in
  the death penalty (see below). Half that blocker is gone.
- **`InventorySize` is a per-character column**, so the real game's inventory is
  expandable per character rather than the fixed 50 this project ships. That
  changes the *nature* of that open item: it is not "a constant nobody has
  found", it is "a per-character value whose starting size is set on the database
  side", which is the same wall as starting Str/Int.
- **`HwanLevel` and `RemainHwanCount` are both persisted**, so berserk has a
  level *and* a count. The gauge numbers still have no string handle anywhere in
  the server — that open item stays disclosed.
- `DiedRegion`/`DiedPos` are persisted: the game remembers where you died.

## The stat vocabulary, in the game's own words

The server tags stats with C multi-char literals (`Stat_ApplyTaggedModifier`,
52 of them); the client names the same stats with `PARAM_*` localisation keys
whose English text ships in `textuisystem.txt`. The two were recovered
independently, from different binaries and different evidence, and the
abbreviations line up exactly — eight of them, which is past coincidence:

| tag | `PARAM_` key | the game's own English |
|---|---|---|
| `'hr'`/`'hra'` | `PARAM_HR` | **Attack rate** |
| `'er'`/`'era'` | `PARAM_ER` | **Parry rate** |
| `'cri'` | `PARAM_CRITICAL` | Critical |
| `'bri'` | `PARAM_BLOCKING` | Blocking rate |
| `'str'` | `PARAM_STR` | Str |
| `'int'` | `PARAM_INT` | Int |
| `'luck'` | `PARAM_LUCK` | Lucky |
| `'ps'` | `PARAM_PS` | Poisoning |
| `'fz'` | `PARAM_FZ` | Freezing |
| `'zb'` | `PARAM_ZB` | **Zombie** |

Also named, with no tag counterpart found yet: `PARAM_PA` "Phy. atk. pwr.",
`PARAM_PD` "Phy. def. pwr.", `PARAM_MA` "Mag. atk. pwr.", `PARAM_MD`
"Mag. def. pwr.", `PARAM_ABSORB` "Absorption".

**Three of this project's readings were wrong and are corrected by this.**
`'era'` was read as "evasion" and is *parry*; `'hra'` was read as "hit rate" and
is *attack rate*; and `'zb'` was recorded as the next probe for the berserk
numbers when it is a zombie status effect. The lesson is narrow: an abbreviation
that looks obvious in English is still a guess until the game's own text says
it, and the client ships that text.

## Naming coverage, and the denominator

Measured by `SymbolReport.java` (three states: **NAMED** — a real name, from
FID, an assert spelling out `Class::Method`, or applied by hand with evidence;
**ATTRIBUTED** — still `FUN_xxxxxxxx`, but in a namespace derived from a fact the
binary states about itself; **UNKNOWN**) and by `CodeCensus.java`, which
separates game logic from library code.

| | game-logic fns | % of binary | named | attributed | identified | of game logic |
|---|---|---|---|---|---|---|
| `SR_GameServer.exe` | 29,554 | 95.6% | 730 | 3,168 | **3,898** | **13.2%** |
| `sro_client.exe` | 36,457 | 91.5% | 681 | 9,485 | **10,166** | **27.9%** |
| **combined** | **66,011** | **93.3%** | 1,411 | 12,653 | **14,064** | **21.3%** |

**The "most of it is CRT and STL" assumption was wrong, and it was measured
rather than argued.** An earlier note in this file said the real denominator
must be far smaller than the 70,773 total because a stripped MSVC binary is
mostly library code. It is not. Across both binaries only **1,368 + 3,394**
functions are clearly not game logic — 368 thunks, 3,461 tiny (<16 bytes), 933
named as CRT/STL by Ghidra's own signature database. Everything else is the
game. So "a full decomp with named functions" is a **~66,000-function problem**,
not the ~6,000-function one that assumption implied.

Two honest caveats on that number, in both directions:

- **Upper bound.** Unnamed STL template instantiations cannot be told from game
  code by any signal here, so some of the 66,011 is library. The `tiny` bucket
  (3,461) is probably mostly STL accessors, and there will be more above 16
  bytes that FID never named.
- **Virtual functions are IN the count, deliberately.** 18,522 game functions
  have no direct caller. An earlier version of the census excluded those as
  dead, which was wrong: a virtual is reached only through a vtable slot and
  Ghidra does not resolve those, so that bucket holds some of the most important
  code in the binary — `GObjPC_GainExpAndLevel`, the exp-gain entry point, is in
  it. It does also hold genuinely dead code, and nothing here separates the two.

Levers used so far, by what they returned: call-graph attribution
(`PropagateModules.java`, +3,131), authored UI string ids
(`LabelFromUIStrings.java`, +140 namespaced and 597 commented), `__FILE__`
asserts (`NamespaceFromSourceFile.java`, 760 seeds), vtable slots
(`VtableAttribute.java`, +68 namespaced and **5,225 annotated**), Ghidra FID
(~930, mostly library), and hand-proven names with citations (~30). The server
is the weaker side at 4.4% and it is where the gameplay lives.

**Levers now exhausted, measured rather than assumed:**

- **Log/assert strings naming `Class::Method`** — 517 server functions reference
  exactly one such string and **13** are still unnamed; the client, 18 and 2. The
  earlier assert-string pass took essentially all of it.
- **Log strings naming a bare `Method()`** — counted 77 unnamed, **worth about
  6**. Reading them rather than trusting the count showed why: the overwhelming
  majority are `"CLAMP() ==> min(%.3f) exceeded max(%.3f) value), File: %s,
  Line: %d"`, a shared assertion macro that says nothing about the function
  containing it — naming those `CLAMP` would be actively wrong. The genuinely
  self-naming remainder is applied (`InitializeGame`,
  `CLobby_RemoveStalePlayers`, `AQ_COSManipulator_DoWork`,
  `RemoveParamKeeperItemEntry`, `AutoReloadMagazine`, `DelItem_EXT`,
  `PC_ReleaseCOS`). Several more were rejected as ambiguous, because the message
  names a function the code *called* rather than itself
  (`"... call DelItem_EXT() returned fail"`); the rule that survives is **take
  the first identifier in the string, and only when nothing precedes it**.
  Lever closed.
- **RTTI class recovery** — impossible, not merely hard. 1,871 type descriptors
  survive and **zero** are referenced, so the COL/vftable chain was stripped.

**The population nothing reaches:** 18,522 game-logic functions have no direct
caller. They are virtuals, and every call-graph lever steps past them.
`VtableAttribute.java` is the answer to that and annotates 5,225 of them with
their table and slot — the fact this project has re-derived by hand four times
(slots 92 exp-gain, 93 SP-adder, 73 GetLevel, 421 GiveExp).

**The levers compound, and that is the main finding of 2026-09-15.** Run once
each they returned little; run as an ordered chain they returned a lot, because
each one's output is the next one's seed. On the server: interpolating 218 gaps
let `PropagateModules` find **175 more** by call-graph unanimity, and the richer
namespace set then let the vtables vote for **149** where they had managed 13
before. Combined identified went 5,055 → **7,822** (7.6% → 11.8%) in a single
chained pass. The order is in `client/tools/ghidra/README.md`; `VtableAttribute`
belongs last and wants re-running after every other lever.

**A second chained pass confirmed it compounds rather than saturating**:
7,822 → **10,710** (11.8% → 16.2%), with the vtable vote rising again from 149
to 228 on the server and 55 to 786 on the client.

**A third pass, after adding 84 hand names (55 DB binders + 29 packet
handlers), returned 10,710 → 14,064 (16.2% → 21.3%)** — and the server's
interpolation nearly doubled, 158 → 295, precisely because those 84 names were
scattered through previously unattributed stretches. That is the mechanism in
one line: **a handful of well-placed names is worth thousands of attributions**,
because each one anchors an interpolation that anchors a propagation that
anchors a vtable vote. The rule is to re-run the whole chain whenever names are
added, not once.

## How to work this file## How to work this file

Pick the top open item, run its next probe against the dumps (grep, don't
re-decompile — see `feedback_re_decomp_first`), and then do one of three things:
move the line to Grounded with its citation, prove the data does not exist and
say so, or record what the probe ruled out and leave the line with a sharper
next probe. **Never** move a line to Grounded on a suggestive curve alone — that
mistake was made twice on characterdata col 79. A use-site is what settles
meaning.

## The trap this file exists to catch

Item 2 (player MaxHP/MaxMP) sat open for three sessions behind a *wrong shape*.
The note here said "find the `FUN_004b3510(0, …)` push that targets them" — and
no such push exists. The base was never pushed at all; it arrives over an edge
of a dependency graph, from Str. Worse, the parameter's identity was invisible
in every one of the 297 decompiled call sites, because it travels in DI, which
Ghidra had not assigned to an argument, and because the callers materialise the
id through chains of LEAs rather than a MOV of a constant — so grep found
nothing and the C read as `SetParam(0, 0, value)` everywhere, complete and
useless.

The lesson is narrow and worth keeping: **when the decompiled C reads cleanly
but says nothing, suspect the calling convention before suspecting the code.**
The fix (`client/tools/ghidra/ResolveRegArg.java`) resolves register arguments
by abstract interpretation and writes them back as comments, so the next dump
carries them. That tool generalises — any callee whose real arguments live in
registers can be recovered the same way.
