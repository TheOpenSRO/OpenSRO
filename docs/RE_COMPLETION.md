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
5. **Monster spawn positions — the "proven absence" was WRONG (2026-09-15).**
   This line used to read *"ours by necessity (`npcpos.txt` has no monsters).
   Likely genuinely absent; prove it and it stops counting as open."* Trying to
   prove it disproved it.

   **`npcpos.txt` is overwhelmingly monster spawns.** Of its 12,367 rows:
   **12,110 `MOB_`**, 248 `NPC_`, 8 `STRUCTURE_`, 1 unresolved. The old claim
   almost certainly came from grepping the file for `"MOB_"` — which returns
   zero, because npcpos stores **numeric object ids**, not codenames. Resolving
   those ids against `characterdata` is what settles it, and `2124` →
   `MOB_KT_DESERTTRUNKZ_CLON` was the first thing that looked wrong.

   Row shape: `objectId, regionId, localX, localY, localZ`. Every one of the
   eleven species in this project's Jangan roster has real spawn points:

   ```
   MANGNYANG 1933  55 spawns      WATERGHOST_CLON 1938  20
   BIGEYEGHOST_CLON 1934  37      WATERGHOST      1939  31
   BIGEYEGHOST 1935  37           TOMBSTONE_CLON  1950  35
   GYO_CLON  1936  41             STONEGHOST      1941  36
   GYO       1937  30             YEOHA           1943  26
                                  WC_EARTHGHOST   1963  65
   ```

   Region ids 23716–25511 decode to y 92–99 / x 166–171 — the Jangan area, as
   expected. The ids also cross-check: 1933 is the `RefMonsterID` this project
   already recorded for Mangyang.

   **The region→server conversion is now derived and sanity-checked
   (2026-09-15).** npcpos rows are `(objectId, regionId, localX, localY,
   localZ)`. The region id packs the project's own `x/y` as `(x << 8) | y` —
   Jangan `97/168` is **25000**, and the ladder's regions cluster 23716–25511
   around it, which is the first confirmation. The client's transform
   (`World3D.gd`) is `worldX = y·1920 + localX`, `worldZ = x·1920 + localZ`, and
   the server's `(0,0,0)` is `ZONE_SPAWN_LOCAL["97/168"]` = local (1002, 1020)
   in that region. So:

   ```
   rx = regionId >> 8 ;  ry = regionId & 0xff
   serverX = (ry·1920 + localX) − 323562
   serverZ = (rx·1920 + localZ) − 187260
   ```

   **It sanity-checks strongly: distance from the town square rises with monster
   level.** Nearest spawn per species, in the server's own frame:

   ```
   Mangyang        lvl 1   2,342     Water Ghost      lvl 7   4,011
   Small-eyed      lvl 2   4,129     Tomb Stone Ghost lvl 8   7,103
   Big-eyed        lvl 3   3,876     Stone Ghost      lvl 9   6,873
   Old Weasel      lvl 4   3,559     Yeoha            lvl 10  6,501
   Weasel          lvl 5   4,088     Earth Ghost      lvl 27 23,246
   Water Ghost sl. lvl 6   4,290
   ```

   The level-1 monster is a short run from spawn and the level-27 one is 23k
   away in another town — exactly the shape a real ladder should have, from a
   transform that knew nothing about levels.

   **MEASURED, CORRECTED and WIRED (2026-09-15).** The derivation above has the
   **wrong sign on Z**, and the sanity check could not have found it. Measured
   on the render box at eleven columns, reading the client's own region group
   nodes (`World3D.gd`'s `_qa_columns_report`), in a world centred on Jangan's
   real region 97/168:

   ```
   worldX = (ry − 168)·1920 + (localX − 960)
   worldZ = (97 − rx)·1920 + (960 − localZ)
   ```

   Two corrections, both of which change where a monster lands:

   - **World Z is mirrored**, consistently: local z runs opposite to world Z
     *inside* a region and the region-to-region step runs opposite too, so the
     two agree and regions still tile seamlessly. The derived formula predicted
     `(130, −1560)` for the first real Mangyang row; the measurement is
     `(130, 2280)`. Shipping the prediction would have put that monster 3,840
     units away, on the far side of the town. World X has **no** such mirror —
     which is why both axes were probed in both directions (`97/169`→`(+1920,0)`,
     `97/167`→`(−1920,0)`, `98/168`→`(0,−1920)`, `96/168`→`(0,+1920)`) rather
     than one being assumed from the other.
   - **The origin is the centre region's geometric centre, not the spawn
     point.** The old constants 323562 and 187260 were built from
     `ZONE_SPAWN_LOCAL` (1002, 1020); the true origin is local (960, 960), and
     the client *moves* the player from there to the landing spot afterwards.
     That is the 42-unit X offset between the two.

   **Why the sanity check passed anyway, and this is the lesson:** the old Z is
   exactly `−(true Z) + 900`. A sign flip applied to *both* the monster and the
   reference point preserves every distance between them — it is an isometry —
   so a table of distances is mathematically **incapable** of detecting it. The
   curve looked right because it was right; it just was not evidence for the
   thing it was being read as evidence for. This is the concrete case for
   *never promote a value on a suggestive curve alone — a use-site settles it.*

   Wired for Mangyang, the one species measured so far. `npcpos` has exactly
   four rows in region 96/168 — the farmland immediately south of town — and
   all four are id 1933, which `characterdata` gives as `MOB_CH_MANGNYANG` at
   level 1 with 54 HP: the same species and the same two numbers the roster
   already carried, reached independently. All four were measured walkable
   first: one surface each, landing height equal to terrain within 0.05, no
   blocking edge within 40 units, nearest placed-object navmesh cell ≥174 units.
   The transform lives in `server/internal/worldmap` with all eleven columns as
   its tests, and the roster stores the `npcpos` rows verbatim so the grounded
   fact is what is in the source and the world coordinate is derived.

   Their authored heights disagree with the measured terrain by 11–41 units and
   are deliberately dropped: the client resolves standing height from the
   region's walkable graph and ignores the authored y.

   *Next step:* the other ten species. Their real regions are known
   (Mangyang 95–96/166–170, Water Ghosts 100/166–169, Stone Ghosts
   100–101/171–173, Yeoha 95–98/163–164, Earth Ghost 101–102/154–155), but each
   needs its own walkability pass before wiring, and most sit 2+ regions out —
   beyond the radius-2 grid the town loads, so they also need the player to
   actually travel there.

   Found while deriving it: `World3D.gd`'s comment above `ZONE_SPAWN_LOCAL` said
   the town square is local **(1002, 917)** while the constant has always been
   **(1002, 1020)**. Anything derived from the comment would have been 103 units
   out. Corrected.

6. **Quest objectives — absence RE-TESTED and CONFIRMED, now with the shape
   (2026-09-15).** Re-examined against the same evidence that overturned
   `npcpos`: the 85-table SQL refdata catalogue and `_CHARQUEST`'s
   `QuestData1`/`QuestData2`. The conclusion holds — objectives are code — and
   the re-test recovered *how*:

   **Each custom quest gets a compiled three-handler lifecycle.** The triple
   `QuestHandler_SetupQuest` / `QuestHandler_OnUpdate` / `QuestHandler_OnDead`
   (`008699a0` / `00869740` / `00869640`) all resolve **the same name id
   (0x15a)** through a virtual and log `"HandlerSetupQuest_%s(%d)"`,
   `"HandlerOnUpdate_%s()"`, `"HandlerOnDead_%s()"` — so the `%s` is the quest's
   name fetched *for the log line*, and the handler bodies are compiled C++ for
   that one quest. They call the generic helpers `CBasicQuest__SetupMissionNPC`
   and `CBasicQuest__PayQuest`.

   `_REFQUEST` exists as a DB table (`DB_Load_RefQuest`, `008341b0`) but is the
   server's copy of quest **identity and metadata** — the counterpart to
   `questdata.txt`, not a table of objectives.

   So the entry sharpens from "objectives live in server code somewhere" to
   **"each quest is a compiled SetupQuest/OnUpdate/OnDead triple over
   `CBasicQuest`"**. Any objectives srrevamp ships are own design, and now it is
   clear they always would have been — there is no table to import, in a file or
   a database.

   **The RTTI pass put a number and a name on it (2026-09-15).** Those compiled
   quests are classes, and the binary names every one: **153 `CQNO_*` objective
   classes** (201 quest classes in total), each with its own vftable — which is
   what the triple-handler lifecycle looks like from the type system's side.
   The names are the quests' own ids (`CQNO_CH_HWAN_1_1` … `CQNO_WC_SOLDIER_SO_1`),
   so a quest can now be matched to its compiled code by name rather than by
   hunting its log string. That is the *confirmation* of "objectives are code",
   not a contradiction of it: 153 hand-written classes is exactly what having no
   objective table looks like.

7. **Loot tables — absence RE-TESTED and CONFIRMED, and now actionable
   (2026-09-15).** After `npcpos` showed that a recorded absence can simply be
   wrong, this one was re-examined against evidence the original conclusion did
   not have: the **88-type refdata catalogue** and the **56 DB table schemas**.
   Neither contains anything drop-related — the only `reward` types are quest,
   event and shop. The absence holds.

   But the re-test turned a dead end into something an operator can act on. The
   drop tables are **SQL refdata**, and the binary names all four:

   ```
   _REFDROPITEMGROUP                          loader DB_Load_RefDropItemGroup
   _REFDROPITEMASSIGN                         loader DB_Load_RefDropItemAssign
   _REFMONSTER_ASSIGNEDITEMDROP               loader DB_Load_RefMonster_AssignedItemDrop
   _REFCUSTOMIZINGRESERVEDITEMDROPFORMONSTER  loader FUN_0082c100
   ```

   The structure is recovered too. `RefItemDrop.cpp` is a 28-function module, and
   `CRefDropData__AddAssignedItemDrop` walks the assignments as a **48-byte
   (0x30) stride array**, comparing a roll against a **float at record+8** — the
   drop probability. The error string names the key relation outright:
   *"Can't find ItemGroupID(%d) within _RefMonster_AssignedItemRndDrop Table"* —
   a monster maps to an item **group** id, and the group maps to items.

   So the entry is no longer "no drop table exists anywhere". It is: **drops are
   database refdata; here are the four table names, the relation between them,
   and the record shape.** An operator with a real server database can import
   them, and this project knows what to ask for.

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

**8 of those 29 were WRONG — a 28% error rate — and only a validation pass found
them.** `ValidateNames.java` now checks every bulk pass against a signal the
name did not come from, and is meant to run after each one:

| prefix | independent check | result |
|---|---|---|
| `DB_Bind_*` | calls the column-bind helper | **55/55 clean** |
| `RefParse_*` | reads ≥3 sequential tokens | **39/39 clean** |
| `MsgHandler_*` | few callers (a handler has ~2) | **8 of 29 failed** |

All eight turned out to be infrastructure the opcode-tree extractor had paired
with a nearby comparison: **seven singleton accessors** (`if (g == 0) Assert();
return g;`) and the **message buffer readers** `MsgBuf_ReadUInt8` /
`MsgBuf_ReadUInt16`. They are now named for what they are; one that could not be
identified had its name **withdrawn** rather than replaced with a guess. The
singleton shape turned out to be a small lever of its own — 34 of them in the
server, all now named.

**The original slip, and why it went unnoticed:**
`FUN_00964b60` was named `MsgHandler_7d1b`; it is the **assert helper** —
`IsDebuggerPresent` and break — with **10,357 call sites**, the most-called
function in either binary. The extractor paired an opcode comparison with the
next call, and in one branch that call was this. Renamed
`Assert_BreakIfDebugger`.

Two cheap checks would have caught it immediately, and are worth applying to any
future bulk naming:

- **Call count.** A packet handler has ~2 call sites. Every other name in the
  set does; this one had five thousand times more.
- **Address band.** Every real handler sits near the `0x41xxxx` dispatcher;
  `0x96xxxx` is infrastructure. An outlier band is a red flag on its own.

The other 28 pass both checks.

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

## The server's OTHER refdata catalogue: 85 SQL tables

The client reads 88 textdata files. The **server reads 85 `_REF*` tables out of
its database** — it references no refdata filename anywhere, which is why every
hunt for a server-side parser has come up empty. The two catalogues are the same
reference data in two forms, and the table names are all in the binary:

`_REFOBJCHAR` `_REFOBJITEM` `_REFOBJCOMMON` `_REFOBJSTRUCT` `_REFLEVEL`
`_REFSKILL` `_REFSKILLMASTERY` `_REFQUEST` `_REFCHARDEFAULT_QUEST`
**`_REFCHARGEN`** `_REFHWANLEVEL` `_REFDROPGOLD` `_REFDROPITEMGROUP`
`_REFDROPITEMASSIGN` `_REFMONSTER_ASSIGNEDITEMDROP` `_REFMONSTER_ASSIGNEDITEMRNDDROP`
`_REFDROPOPTLVLSEL` `_REFDROPCLASSSEL_*` (10) `_REFMAGICOPT*` (4) `_REFSHOP*` (8)
`_REFSIEGE*` (11) `_REFTELEPORT` `_REFTELELINK` `_REFREGION` `_REFGAME_WORLD`
`_REFGAMEWORLDNPC` `_REFINSTANCE_WORLD_START_POS` `_REFCLIMATE` `_REFALCHEMYMERIT`
… and the rest.

**This names where three open items actually live**, which is more useful than
another round of guessing they are absent:

- **`_REFCHARGEN`** — character generation. Starting Str/Int is disclosed
  own-design precisely because nothing writes those constants in the exe; this
  is the table that would hold them.
- **`_REFHWANLEVEL`** — the berserk levels. `hwanleveldata.txt` turned out to be
  a *title* table, and the gauge numbers had no string handle; this is where
  they live. **Partly closed 2026-09-15** — see below. `hwanleveldata.txt` is
  re-confirmed as titles only: 255 rows of three columns, level plus two
  `UIO_SECOND_HWAN_CH_NAME_LEVEL_n` keys, no effect columns. The per-level
  effect list is a vector inside `CRefHWANLevel` of `{uint32 tag; uint8 value}`
  pairs, built from the tags `'DABR'` and `'SPDU'`, and its magnitudes really
  are DB rows this project does not have. **But the damage multiplier itself is
  not in that table** and is now recovered — it is a constant in the formula.
- **`_REFQUEST`** — quest refdata. Worth re-testing the standing "objectives are
  not data" conclusion against it, the way `npcpos` was re-tested.

**It also weakened a shipped value, and that is recorded in the code.** The
catalogue contains `_REFLEVEL` and `_REFDROPGOLD` but **no `_REFLEVELGOLD`** —
so the server's gold table is named after *drops*, and `levelgold.txt` may be
the client's copy of something else entirely. `combat.RollGold`'s doc comment now
says so. The value stays, because the honest comparison is against the invented
`10 + level*5` it replaced, and an operator supplying `_REFDROPGOLD` supersedes
it outright.

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
  level *and* a count. **The berserk DAMAGE is recovered (2026-09-15); the
  gauge/duration numbers stay disclosed.**

  Berserk is "Hwan", which is why grepping for "berserk" found nothing for three
  sessions. With the RTTI class names in place the chain reads straight through,
  and every link is a named function:

  ```
  CGObjChar::SetBerserk   slot 198  0x004a9fc0   writes the flag at (*(this+0x30))+3
  CGObjChar::IsBerserk    slot  64  0x004aa5b0   reads that same byte
  Combat_ResolveDamage              0x0058e5f0   sets damage-flag bit 2 when the
                                                 ATTACKER IsBerserk()
  Formula_MitigatePhysicalDamage    0x0040e450   multiplier = GetParam(189) + 2.0
  Formula_MitigateMagicalDamage     0x0040e830   (in place of the usual 1.0)
  ```

  The setter and the predicate touching the **same byte** is what ties the pair
  together; neither alone would have been better than a suggestive name.
  `UpdateHwanLevel` sits next door at slot 197, writing the level to
  `CGObjChar+0x1c58` and persisting it to `_CHAR.HwanLevel` (`charData+0xf2`,
  dirty bit `0x2000`) — which also confirms the `_CHAR` schema offset. The level
  cap is the row count of the `_REFHWANLEVEL` vector.

  **×2 exactly.** The 2.0 is the double at `.rdata 0x00b45f30`, and its
  neighbours `0x00b45af0 = 100.0` / `0x00b45ac0 = 1.0` are the two already-
  confirmed constants of the `/(1 + p/100)` idiom, so the width is settled
  rather than assumed. All three read `0.0` at float width because a double's
  low word is zero — and the float reading is incoherent anyway, since it would
  make a berserk attacker deal no damage at all.

  Param 189 is a separate berserk-damage **stat** adding on top (`SetBerserk`'s
  fifth argument grants it a base of 0.3, float at `0x00b45b8c`, and clears it
  otherwise), but every call site in the binary bar one passes 0 there. 2.0 is
  the plain case, 2.3 the special one; the stat is not modelled rather than
  folded in at a guessed rate.

  The **duration** is now known to be genuinely unrecoverable from this
  function: `SetBerserk`'s signature carries a state-change slot and a float
  duration, and every call site passes `0xff`/`0` for them, so the real server
  keeps that timer elsewhere. Body mode 1 is Hwan (the `BODYMODE_HWAN` string);
  modes 0, 2 and 4 also appear at those call sites.
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

## `ItemClass` is itemdata column 61, and a shipped claim that was false (2026-09-15)

**First, a correction.** The previous entry says `TwoHanded` was exported. It was
not — the edit that was meant to map column 93 matched nothing (wrong
indentation; a silent no-op is what a non-matching string replace does), so
`fTwoHanded = 93` sat defined and unused and the equipment rule depending on it
was inert in every real deployment. The build was happy: Go objects to an unused
local, not an unused const. The round-trip test only checked the record's
*width*, and the new-column test only checked defence and block. Fixed, and
pinned by a test **verified to fail without the fix**.

**`ItemClass` is column 61** — the last placeholder in the item exporter that
anything reads. It flows through the shop listing to the client, where it had
been a constant 0.

Derived from the ORDER of the server's own deserialiser rather than from the
shape of the data. `RefObjItem::ExtractData` reads fields consecutively off the
row — `+0x198` (4 bytes), `+0x19c` (1), `+0x1a0` (4), `+0x1a4` (4), `+0x1a8` (1)
— and `+0x19c` is confirmed as `ReqGender` by
`CGPCInventoryOP::CheckEquipsetIntegrity`, which compares it against
`GetGender()`. The exporter already pinned 57/58/59/60 as MaxStack / ReqGender /
ReqStr / ReqInt, exactly those four in exactly that order, so the next field is
column 61 — a one-byte read, matching `m_btItemClass`.

Checked against the binary's own assertion rather than a curve: `ExtractData`
asserts *"ItemClass must be not zero"* / `m_btItemClass > 0`, and column 61 is
non-zero on **all 21,552** equipment rows.

**The exporter sweep is finished.** Every remaining `"0"` placeholder in either
exporter — `FlyingSpeed`, `Interruptable`, `Overlap`, `AutoAttackType`,
`Basic_Name`, `Basic_ChainCode`, `Basic_RecycleCost` — has **zero readers** in
the server, so a wrong value there reaches nothing. They stay, now for a
measured reason.

## `TwoHanded` is itemdata column 93 (2026-09-15)

The field existed in `refdata.Item`, was exported as a literal `"0"`, and
nothing read it — harmless until shields started blocking, at which point a
two-handed weapon plus a shield became free damage avoidance.

Column 93 is a clean 0/1, **constant within every weapon kind** (`TypeID4`),
never mixed, and 0 on all 511 shield rows. Diffing a one-hander against a
two-hander finds it; that alone is a suggestive column, so it was settled
against a source that knows nothing about this table — the **client's own
weapon-to-animation-group switch**, recovered from a different binary by a
different route, which names five kinds outright:

| TypeID4 | the client's own name | col 93 |
|---|---|---|
| 7 | `onehand_sword` | 0 |
| 10, 15 | `onehand_staff` | 0 |
| 8 | `twohand_sword` | 1 |
| 11 | `twohand_staff` | 1 |

Five for five. The remaining kinds fall out consistently: spear, glaive, bow,
axe, crossbow and harp read 1; blade and dagger read 0.

Shipped with `equipment.TwoHandedConflict`. Slot 7 being the shield is
confirmed independently by `CGPCInventoryOP::CheckEquipsetIntegrity`, which
tests `local_c != 7` for exactly that slot — the same index this project's
equipment package already used.

## Loot is DB-only, censused (2026-09-15)

The audit carried monster drops as "keyed by name (real tables key by
`RefMonsterID`, mapping not yet confirmed)". The mapping cannot be confirmed
because **the tables are not shipped anywhere this project can reach**, and that
is now a census rather than a failed search.

The pserver's `SR_GameRefData` directory holds **238 refdata tables** — every
one this project has ever used and many it has not: `LevelData`, `SkillData`,
`CharacterData`, `npcpos`, `shopdata`, `QuestData`, `levelgold`,
`hwanleveldata`, `MagicOption`, `teleportdata`, `siegefortress*`,
`refquestrewarditems`, `collectionbook_*`, `gacha*`. **None of them is a drop
table.** A `find` for `*drop*` across the entire server package returns only
drop *models and icons* (`.bsr`, `.bmt`), and the ORIGINAL client's `Media.pk2`
contains exactly one match for "drop" — `etc_waterdrop_yellow.ddj`.

So `_RefDropItemGroup`, `_RefMonster_AssignedItemRndDrop`, `CRefDropItemAssign`
and the ten `CRefDropClassSel_*` classes exist in the binary's RTTI and as DB
tables, and nowhere else. srrevamp's placeholder loot is own design for a
reason that is now stated rather than assumed, and an operator with the database
supersedes it.

## Blocking: a blocked hit deals nothing (2026-09-15)

Recovered in `Combat_ResolveDamage`. The chance is the engine's standard opposed
idiom:

```
block = GetParam(10)                       the defender's 'bri'
      + a bonus when (refobj+0x230) != 0   (FUN_00410c20)
      / (1 + GetParam(56)/100)             opposed by the attacker's 'evbl'
```

stored in the damage record at `+0xe`, where the critical chance sits at `+0xc`.

**The roll is the same one the critical uses, and the disassembly shows how the
engine keeps them apart** — they differ only in a key byte placed in the high
bits of ECX:

```
0058f0c8  MOVZX EAX,byte ptr [EBX + 0xe]   ; the BLOCK chance
0058f0d2  OR ECX,0x42000000                ; 'B'
0058f0de  CALL FUN_005a1a20

0058ed8c  MOVZX EAX,byte ptr [ESP + 0x2f]  ; the CRITICAL chance
0058ed97  OR ECX,0x43000000                ; 'C'
0058eda3  CALL FUN_005a1a20
```

That key is what `FUN_00599cc0` stores its bad-luck accumulator under, so blocks
and criticals have **independent streak protection** per actor. It also settles,
rather than assumes, that the block roll really takes the block chance — the
`MOVZX EAX,[EBX+0xe]` is the field the `'bri'`/`'evbl'` computation wrote.

**A blocked hit deals nothing**, and the control flow proves it rather than a
comment claiming it. On success the roll falls through to `JZ 0x005905fb`, and
that target is **past all four** `Formula_Mitigate*` call pairs — at `0x58f15d`,
`0x58f2fb`, `0x58f7ea` and `0x58f9b2`. No damage is ever computed, so the
record's `+0x28` (physical), `+0x24` (magical) and `+0x20` (total) keep the zero
they were initialised with. A *failed* block instead jumps to `0x58f739`, which
is before the third pair, and resolves normally. (One secondary path, guarded by
an ability pointer at defender+0xD2C, explicitly zeroes those fields and re-runs
the formulas; that is a special case this project does not model.)

**SHIPPED 2026-09-15 (v0.1.168).** The blocker was the input, not the mechanic:
a player's block chance is a shield's own block ratio — itemdata cols 74–75,
10~20, on exactly the 500 shield rows — and the curated item export carried no
such column. Added as an appended optional column, the pattern every earlier
addition used, so an export made at any older width still loads and blocks
nothing.

**And it uncovered a live bug next to it.** `cmd/export-refdata` was emitting a
literal `"0"` for *both armour defences*, under a note reading "armour, not
verified" — a note that stopped being true when `ITEM_FORMAT.md` grounded those
columns three ways and was never revisited. Every deployment importing through
that tool gave armour **no defence at all**, while `defenderArmor` read the
zeroes. Physical (65/66) and magical (76/77) are now exported from their
verified columns.

The monster side of blocking still never fires: every species on the Jangan
ladder reads 0 for col 76, though 938 other monsters carry 20.

## Criticals, and the dice behind them (2026-09-15)

The standing "crit/block/hit rolls — values recovered, dice not" item closes on
the dice side. `FUN_00599cc0`, reached through `FUN_005a1a20` from
`Combat_ResolveDamage`, is the game's chance roll for criticals **and** blocks:

```
chance == 0     -> fail, no roll taken
chance >= 100   -> succeed, no roll taken
otherwise       -> succeed when chance >= rand() % 101
```

Inclusive at both ends — the modulus is `0x65`, not 100.

**A critical doubles.** `Formula_MitigatePhysicalDamage` builds a multiplier
(1.0 normally, `GetParam(189)+2.0` for a berserk attacker) and does
`if (flags & 2) multiplier += multiplier` before multiplying the already-
mitigated damage. Bit 1 is set on a successful critical roll, so an ordinary
critical turns 1.0 into 2.0 — and a berserk critical is 4.6×, since it doubles
whatever the multiplier already is.

**The monster's chance is characterdata col 78**, settled by disassembling
`GObjMob_PublishStats`, which publishes the ref-object's fields into params in a
consecutive 4-byte run:

| offset | param | column | |
|---|---|---|---|
| +0x230 | 5 | 71 | flat phys absorb — **already proven** |
| +0x234 | 6 | 72 | flat mag absorb |
| +0x238 | 7 | 73 | phys reduction % — **already proven** |
| +0x23c | 8 | 74 | mag reduction % |
| +0x240 | 9 | 75 | `'era'` parry |
| +0x244 | 10 | 76 | `'bri'` block |
| +0x248 | 11 | 77 | `'hra'` attack rate |
| +0x24c | 12 | **78** | **`'cri'` critical** |

Two known offsets anchor the run onto columns 71–78, and the data then agrees
four ways: cols 73 and 74 equal the level exactly on every row; 75 and 77 are
identical (`25 + 2*level`); 76 is 0 for every Jangan monster, which is right
because blocking is a shield mechanic (938 monsters elsewhere do carry 20); and
78 reads **2 on 7,493 of 7,495** rows. The two that differ are what prove it is
a column rather than a shared default.

**Not modelled, disclosed:** the real roll keeps a per-actor accumulator, raised
by `chance` on a miss and dropped by 100 on a hit, and compares *that* on later
rolls — bad-luck protection. srrevamp rolls memorylessly, so its criticals are
streakier, never more or less frequent. **The player never crits:** param 12 is
not among the fifteen `Char_PublishCombatStats` publishes; it comes from the
item stat-tag path this project does not model — the same wall as the player's
mitigation percentage.

**Blocking is recovered but not shipped**, for the same reason: col 76 is the
chance and the roll is the same function, but every monster on the Jangan ladder
reads 0, so there is nothing to see until the roster reaches the 938 species
that carry 20.

## Unarmed damage: the game does not define one (2026-09-15)

`unarmedDamage = 5` was the last value in the grounding audit carrying no reason
at all — just "Own [design]." It has one now, and it is an absence established
by enumeration.

Damage reaches the engine as params 190/191, published from the equipment
aggregate; the numbers themselves live in a skill's `'att'` parameter, which is
how a monster's attack was recovered. So an unarmed player would need a base
attack skill with **no weapon type** — and the skill table has none. Every
`_BASE_01` attack skill in the game is weapon-typed, all twelve of them:

```
CH   SWORD(2)        SPEAR(40)        BOW(70)
EU   SWORD(8419)     TSWORD(8420)     AXE(8421)      CROSSBOW(9354)
     DAGGER(9355)    STAFF(9944)      WAND_WARLOCK(10625)
     HARP(11162)     WAND_CLERIC(11526)
```

The state exists *visually* — the client's recovered animation-group table has
index 0 `default` for an empty hand — but nothing in the data gives it a damage
value. So 5 is a number this project must invent to have a fight at all, not one
it failed to find.

**A trap caught on the way, worth recording because it nearly shipped.**
Player rows in `characterdata` read `[83]=1 [84]=2 [85]=40 [86]=70`, and
`[85]/[86]` looks exactly like a tidy 40~70 unarmed damage range — a monster row
has 0 in both. It is not a range. Those columns are **base-attack skill ids**:
2 / 40 / 70 resolve to precisely the three Chinese base skills, and a European
row reads 8419 / 8420 / 8421 (sword / tsword / axe), consecutive ids in the
thousands that no one would mistake for damage. The census across both races is
what refuted it; the single-race reading was entirely plausible.

**Also closed this tick, as exhausted rather than open:** the `__FILE__`
source-path lever. 164 distinct source paths in the client and 50 in the server,
and `NamespaceFromSourceFile` reports **444 of 446** client functions and
**166 of 166** server functions already namespaced. There is nothing left in it;
a future tick should not re-run it hoping for yield.

## GParamKeeper's combination rules, and what `ctx` was for (2026-09-15)

The previous entry left one question in the way of using reinforce: does a
derived bind **overwrite** its target's slot or **accumulate** into it? Param 13's
slot 0 is written twice — directly from the aggregate's `+0x1b8` (the weapon's
own range) and by propagation from 17 (Str-derived, scaled by reinforce) — and
which survives decides whether a player's damage is the weapon alone or the
weapon plus a Str term.

**It accumulates, and the answer is slot-dependent.** `ParamKeeper_StoreSlot`
(`004b3000`) shows a slot is not a float: it is a container, allocated on first
use, and `FUN_004b2d60(container, ctx, value)` stores into it **keyed by `ctx`**.
That is what the long-unexplained third argument to
`ParamKeeper_SetParam(slot, ctx, value)` has been all along — the identity of the
contributor, so two sources writing the same slot each keep their own entry.

`FUN_004b2e60` then reduces a slot's container to one float, and how it combines
them depends on which slot it is:

```
acc = (slot == 3) ? 100.0 : 0
for each entry:
    slot 3  ->  acc = entry * acc / 100     percentages compound
    slot 2  ->  acc = (entry/100 + 1) * acc multipliers compound
    slot 0  ->  acc = entry + acc           SUM
    slot 1  ->  acc = entry + acc           SUM
```

So the four slots are **base (summed)**, **additive % (summed)**, **multiplier
(compounding)** and **percent scale (compounding from 100)**, and
`ParamKeeper_EvaluateParam` combines them exactly as recorded:
`slot0 * (slot1+100)/100 * slot2 * slot3/100`, with a clamp that asserts in
`GParamKeeper.cpp:301`.

> **AMENDED 2026-09-15 — the formula above is right but incomplete, and the
> missing piece invalidates an inference this project used repeatedly.**
> `ParamKeeper_EvaluateParam` has two fallbacks to a per-param **default** held
> at `+0x28`:
>
> ```c
> if (!anySlotHasEntries) { value = *(float *)(param + 0x28); return; }
> if (*(int *)(param + 8) == 0)  local[0] = *(float *)(param + 0x28);  // slot 0 empty -> base = default
> ```
>
> and slot 2 *replaces* rather than multiplies when the base product is zero.
> So **an unwritten param does not evaluate to zero — it evaluates to its
> default.** The read path makes this unavoidable: `FUN_004b3740` calls
> `ParamKeeper_EnsureParam` *first*, which lazily creates the param via
> `FUN_004b2f40(min, max, default, ?)` from a descriptor record fetched out of a
> map keyed by param id (sentinel `0xcd3110`, root `0xcd3114`), asserting if the
> id is absent. The four values arrive as `fild [ecx+4/8/0xc/0x10]` — integers
> from a record built at **runtime**, not immediates in the code.
>
> **Consequence**: "nothing writes param N, therefore N is zero" is not a valid
> recovery, and three places in this codebase used it. They now read as "param N
> is unmodified for an ordinary character", which is what the write census
> actually proves. The defaults themselves are not in `SR_GameServer.exe` and
> cannot be decompiled out of it. Corrected in `leveldata.DeathPenaltyReduction-
> Percent` and `berserk`'s damage-completeness note; `combat.MitigateDamage`'s
> params 9/11 argument is unaffected because it is a READ-side census (a param
> nothing reads cannot matter whatever its default).

**The consequence for damage**: param 13's slot 0 holds the weapon's own range
*and* the Str-derived contribution from 17, and they **add**. A player's physical
damage in the real game is the weapon's range plus a term of roughly
`Str x reinforce%`, and srrevamp's damage ignores Str entirely.

**Still not shipped, and the remaining gap is now exact.** The magnitude needs
one more fact: whether an item's reinforce *replaces* the innate base in param 34
or adds to it. Both are plausible and the container's `ctx` keying decides it —
same key replaces, different keys sum. `GObjPC_InitStats` writes ctx 0 while
`Char_PublishCombatStats` passes the stat-source pointer as ctx, which would make
them different keys and therefore additive — giving a Copper Sword user 61.2%
reinforce rather than 30.6%. That reads wrong, which is exactly why it is written
down as a question rather than shipped as a formula.

## The player stat graph, read off GObjPC_InitStats (2026-09-15)

`GObjPC_InitStats` (`004e3200`) declares the whole graph in one function, and
`ResolveRegArg`'s annotations make the edges readable directly:
`/* BindDerived source->target: EBX 0x3a (58), EDI 0x32 (50) */`.

**The three roots are confirmed against the `_CHAR` schema**, which is the check
on everything built from them:

```
param 0 = Level      SetParam(0, charData+0x65)   _CHAR.CurLevel
param 1 = Str        SetParam(1, charData+0x74)   _CHAR.Strength
param 2 = Int        SetParam(2, charData+0x76)   _CHAR.Intellect
```

**The Str/Int split is the graph's shape**, not an inference about it:

```
1 (Str) -> 17, 18 -> 13, 14   physical damage min/max
1 (Str) -> 21     -> 5        physical flat absorb
2 (Int) -> 19, 20 -> 15, 16   magical damage min/max
2 (Int) -> 22     -> 6        magical flat absorb
```

**This places the six fields the publication map had left unnamed:**

| field | param | where it goes |
|---|---|---|
| +0x1b0 | 58 | → 50 → 21 → **5**, physical flat absorb |
| +0x1b4 | 59 | → 51 → 22 → **6**, magical flat absorb |
| +0x1c8 | 34 | → 17 → **13**, physical damage min |
| +0x1cc | 36 | → 18 → **14**, physical damage max |
| +0x1d0 | 35 | → 19 → **15**, magical damage min |
| +0x1d4 | 37 | → 20 → **16**, magical damage max |

**Which REFUTES the previous entry's guess.** 58 and 59 were recorded as the
obvious candidates for the item table's phys/mag *reinforce*, on the strength of
sitting between the defence and damage blocks. They feed **flat absorb**, a
defence stat; reinforce is a weapon stat. The candidates are wrong, and the
graph says so without needing a second opinion.

**Two base values fall out, both real constants:** a character's innate attack
rate (param 11) and parry (param 9) are each **10.0** (`.rdata 0x00b45b44`),
each with a level-derived binding (`0 → 11`, `0 → 9`). srrevamp models neither
stat, so there is nothing to wire.

### Params 34–37 are the REINFORCE quad (settled 2026-09-15)

The previous pass recorded this as a lead and declined to promote it on one
numeric coincidence. It is settled now, five ways, and the objection that held it
back dissolved once the right question was asked.

| param | base | is |
|---|---|---|
| 34 | 30.6 | physical reinforce **min** |
| 36 | 34.2 | physical reinforce **max** |
| 35 | 49.0 | magical reinforce **min** |
| 37 | 54.8 | magical reinforce **max** |

1. **The slot says "percentage".** Every edge in the graph binds at slot 0
   (base) *except six*, and four of them are these: `34 → 17`, `36 → 18`,
   `35 → 19`, `37 → 20`, all at **slot 3**, which
   `ParamKeeper_EvaluateParam` divides by 100. The engine treats them as
   percentages, which is what a reinforce *is*.
2. **The targets split physical and magical** exactly as the client's two
   labels do: 34/36 scale the physical damage chain (17,18 → 13,14) and 35/37
   the magical (19,20 → 15,16).
3. **They are min/max pairs**, matching the client's `"%s ~ %s"` rendering.
4. **The values are real item values.** `306 / 342` is precisely
   `ITEM_CH_SWORD_01_A`'s physical reinforce and `490 / 548` precisely
   `ITEM_CH_BLADE_01_A`'s magical.
5. **Both are the FLOOR of their column.** No weapon in the table has physical
   reinforce below 306 or magical below 490 — which is exactly what an innate
   baseline should be, and is what dissolves the earlier objection. The bases
   are not "one weapon's stats"; they are the minimum of each column
   independently, which is why the physical matched a sword and the magical a
   blade.

This answers the question two entries back: *the only combat stat the client
reads that the server never exports is reinforce — where does it land?* It lands
on the Str/Int-derived damage, as a percentage.

**Not exported and not wired, deliberately.** Using it means knowing whether a
derived bind OVERWRITES its target's slot or accumulates into it: param 13's
slot 0 is written both directly (from the aggregate's `+0x1b8`, the weapon's own
range) and by propagation from 17. Which of those survives decides whether a
player's damage is the weapon's range alone or the weapon's range plus a
Str-derived term — a formula change, not a constant. `Param_PropagateToDependents`
is the function that settles it, and until it is read, exporting the columns
would only add a field nothing consumes, which is the exact pattern the last
four entries have been correcting.

Also in the tail: a six-iteration loop binding `(phys, mag)` pairs from a static
table at `.rdata 0x00c640d0` — 0.032/0.052, 0.027/0.043, 0.042/0.067,
0.034/0.055, 0.025/0.039, 0.030/0.049, each ×100 — into params 50/51, the same
defence chain. Six is the armour-slot count *and* the European mastery count,
and the loop's param id is computed rather than literal, so which of those it is
stays open.

## Where a player's combat stats come from (2026-09-15)

`Char_PublishCombatStats` (`00497830`) publishes fifteen ParamKeeper params from
fifteen consecutive float fields. Every call decompiles identically —
`ParamKeeper_SetParam(0, piVar1, param_1)` — because both the id and the value
are register-passed, so this is read off the disassembly:

| field | param(s) | what |
|---|---|---|
| +0x198 | 5 | physical flat absorb |
| +0x19c | 9 | `'era'` **parry rate** |
| +0x1a0 | **7** | **physical reduction %** |
| +0x1a4 | 10 | `'bri'` **blocking rate** |
| +0x1a8 | 6 | magical flat absorb |
| +0x1ac | 8 | magical reduction % |
| +0x1b8 | 13 **and** 191 | physical damage **min** |
| +0x1bc | 14 **and** 190 | physical damage **max** |
| +0x1c0 | 15 **and** 193 | magical damage min |
| +0x1c4 | 16 **and** 192 | magical damage max |
| +0x1b0 | 58 | not identified |
| +0x1b4 | 23, 59 | not identified |
| +0x1c8 | 34 | not identified |
| +0x1cc | 36 | not identified |
| +0x1d0 | 35 | not identified |
| +0x1d4 | 37 | not identified |
| +0x1d8 | 11 | `'hra'` **attack rate** |
| **+0x1dc** | **12** | `'cri'` **critical** |

**Extended and CORRECTED 2026-09-15 (same day).** The table above is eighteen
fields, not the eleven this entry first recorded. The earlier pass cut its
disassembly at 220 instructions, and six of the writes are past that — the last
of them, `+0x1dc → param 12`, at `0x00497ef0`, three hundred instructions
beyond where the reading stopped.

That one matters, because this entry went on to say param 12 was **not**
published here, and a later tick used that to argue the player's critical
arrives by the item-modifier path (`Stat_ApplyTaggedModifier`'s `'cri'` tag)
instead. It does not: it arrives by the same route as every other combat stat,
published from `+0x1dc` immediately after `'hra'` attack rate at `+0x1d8` —
exactly where a reader would expect the pair. The shipped value (the weapon's
own Critical column, itemdata 116) was right throughout; only the citation
improves. *A disassembly window is a measurement boundary, and an absence found
inside one is not an absence.*

**Two standing questions close.** First, params 13/14 and 190/191 are *the same
two floats* — so `Formula_RollWeaponDamage`'s uniform roll (190/191) and the
centre-biased roll in `FUN_0040dce0` (13/14) read an identical range. The two
rolls differ in distribution, not in input, which is what the previous tick
could not tell.

Second, the defence block runs PD, ER, PAR, BR, MD, MAR at consecutive floats —
**exactly the `_RefObjItem` column order `refdata_schema.md` records** — and two
of those land on params the client itself names: ER on 9 (`PARAM_ER` = "Parry
rate") and BR on 10 (`PARAM_BLOCKING`). Those two anchors bracket PAR, placing
it on param 7, the physical reduction percentage, and MAR on param 8. That
decodes two of the three columns the schema explicitly records as *not decoded*.
It is an ordering argument with named anchors on both sides, **not** a use-site
on PAR itself, and is recorded at that strength.

### SETTLED: a player's percentage mitigation is ZERO, and that is recovered

The previous pass left this open because a census of item columns is only
*suggestive*. It is closed now by enumerating the writers instead: param 7 has
exactly **three**, and none of them can make it non-zero for a player.

| writer | reaches a player? |
|---|---|
| `GObjMob_PublishStats` (`004c3730`) | no — mobs only (characterdata col 73 = the monster's level) |
| `Char_PublishCombatStats` (`00497830`) | from the `_RefObjItem` defence block — and **no percentage-reduction column is populated on any of the 21,560 item rows** |
| the skill-effect applier (`00594ac0`) | only through the skill param code **`'ar'`** — which appears on **zero of 29,342 skill rows** |

`'ar'` is `SkillGlobal::RefSkill_ParseParams` (`00587630`) writing `skill+0x268`
as a 3-word run, which the applier publishes into params **7 and 8 at slot 0**.
The single numeric hit for it in the skill table is a skill's **own id column**,
not a param code. The mechanism exists; nothing shipped uses it.

**The two defensive skill codes that ARE live go somewhere else entirely**, and
that is what makes the negative result convincing rather than merely absent:

| code | writes | published as | real skills |
|---|---|---|---|
| `'defp'` | `skill+0x25c`, 4-word run | params 5/6 at **slot 0** — the FLAT absorb | **273** |
| `'defr'` | `skill+0x260`, 2 words | params 5/6 at **slot 1** — a % boost to that flat term | 4 |
| `'ar'` | `skill+0x268`, 3-word run | params 7/8 at slot 0 — the reduction % | **0** |

So defensive buffs in this game raise your **flat absorb**, never your
percentage. The asymmetry srrevamp already had — monsters carry a percentage,
players do not — is the game's own. `session.playerMitigationPercent` now states
it as an explicit cited `0` routed through the same `combat.MitigateDamage` the
monster side uses, so the zero carries its evidence instead of being a bare
subtraction that happens to compute the same number.

**A methodological note worth keeping.** The first census of these codes said
`'defr'`, `'defp'` and `'heal'` appeared on **zero** rows — because the
multi-char constants had been worked out by hand and were wrong (`'defr'` is
1684366962, not 1684366450). Recomputed properly, `'defp'` is on 273 skills.
A second slip in the same pass: the code list was harvested with
`grep '== 0x'`, which misses every branch the compiler emits as `!=` — and
`'ar'`, the one code this whole question turned on, is exactly such a branch.
Both mistakes produce *false negatives*, which are the dangerous kind here: an
absent value looks like a settled question.

**Now genuinely open:** the class of `Char_PublishCombatStats`'s first argument
(it answers a virtual at slot 33, `+0x84`, and is *not* `CRefObjChar` — that has
`uint8 Lvl` at 0x198, read here as a float). Not needed for the above, but it is
the handle on where gear aggregates.

## The death penalty, and half of `pc[0x72d]` (2026-09-15)

srrevamp had no death penalty at all. The real one is recovered and shipped
(v0.1.164). `GObjPC_OnDeath` (`004e6980`) gates everything on
**`10 < Char_GetLevel(victim)`** — levels 1–10 die free — then multiplies the
level's EXP unit by one of four constants:

| killed by | ordinary | PK-flagged |
|---|---|---|
| a monster | `unit * 100`, no SP loss | `unit * 300`, **60** SP |
| a player | `unit * 20`, no SP loss | `unit * 100`, **20** SP |

The loss is clamped (the block's own CLAMP assert gives the minimum as `1.0`
and names the source file — `D:\WORK2005\Source\SilkroadOnline\Server\
SR_GameServer\GObjPC.cpp` line 6168), reduced by an unresolved stat, and
applied through `GainExpAndLevel` (vtable slot `0x170` = 92, the same function
that grants experience) with a **negative** 64-bit amount. Nothing in the block
touches `CurLevel`: a death never costs a level. The SP loss is capped at
`charData+0x80` = `RemainSkillPoint`.

**The EXP unit is the same field a kill is paid from**, and that is measured,
not assumed: `Formula_MonsterExpReward`'s disassembly reads the identical
`levelTable[lvl]+0x1c` and, in the same few instructions, shows the
minimum-level rule (`CMP EBX,EAX / JLE / MOV EBX,EAX` over two `Char_GetLevel`
calls) that `leveldata.KillExp` already implements. One function confirmed both
the field and a rule this project had recovered by another route.

**Half of the `pc[0x72d]` open item falls out.** That byte (victim `+0x1CB4`)
is compared against **5**, and gates the harsh branches together with
`charData+0xb4` = `PKPenaltyPoint` from the recovered `_CHAR` schema. What the
state enum *means* is still unrecovered, so the branches are labelled by the
condition that can be named rather than by a guess at the enum.

Checked against the **ORIGINAL client's** `leveldata.txt`, identical to the
pserver's at every level sampled (only level 110's exp-to-next differs, a
pserver cap edit), the cost is steeply regressive: **74.2% of a level at 11,
16.7% at 20, 6.1% at 30, 1.9% at 50, ~0% at 110.** Brutal the moment the
level-10 grace period ends, shrugged off at cap.

Only the monster branch is reachable — srrevamp has no PK system — so the other
three are implemented, tested and disclosed as unreachable. The reduction stat
is left out rather than guessed, which makes srrevamp's penalty a strict upper
bound on the real one.

*Also re-confirmed on the way:* `hwanleveldata.txt` aside, the **inventory**
item is DB-side like starting Str/Int. `CGObjPC::ExpandInventory` caps the main
inventory at **77** slots normally and **99** under a predicate (hard-capped
below 100), and `CGObjPC::FindEmptySlotNum` calls
`CGStorage::FindTotalEmptySlot(0xd)` — so the general inventory begins at index
**13**, after 13 equipment slots. The starting size is a `_CHAR.InventorySize`
row, not a constant in the exe, so `inventory.SlotsPerCharacter = 50` stays
own design.

## The base class names the slot (2026-09-15)

The berserk lever, generalised into a pass. `IGObj::UpdateHwanLevel`'s base
implementation is a stub that does nothing but log its own name —
`"## Illegal ##  IGObj::UpdateHwanLevel TypeID: %u"` — and RTTI says that stub
is slot 197. Those two facts do not name one function: they name **slot 197 in
every class that inherits it**.

248 such `(class, slot, method)` triples are sitting in the server's strings, in
the game's own spelling. **Validated against three facts the pass did not
produce**: `IGObj slot 65 GetParam` (this project derived vtable offset
`0x104` = GetParam by hand, and 0x104/4 = 65), `IGObj slot 197 UpdateHwanLevel`
(last tick's berserk work), and `IGObj slot 74 GetMaxLevel` landing immediately
after the hand-derived slot 73 `Char_GetLevel` — the adjacency a declaration
pair would have.

Two guards earned their place:

- **The string's class is the authority.** The seed is `(class named in the
  string, slot)`, propagating only to vtables whose class is that class or has
  it in its base chain. Slot numbers mean nothing across unrelated hierarchies.
- **`Class::member` is not a method.** The client's
  `"CObjChild::m_pGfxDevice is null"` would have seeded slot 15 of the root of
  the whole UI hierarchy; that one string accounted for **477 of the client's
  484** candidates before the filter. Only 7 client names survive it, and that
  is the correct number.

**481 functions named** (474 server, 7 client). Coverage after re-running the
chain: **server 64.1%** (was 56.3%), **client 46.0%** (44.5%) — combined
identified **38,555 → 41,844**. The gain is mostly downstream: 474 real names
seeded +2,417 new attributions, which is the compounding effect again.

A counting trap worth recording: nameable functions must be counted as
**distinct entries**, not `(seed, class)` pairs. An inherited implementation is
one function reached through every derived class's table, so the pair count read
6,325 against an apply that named 474 — a thirteenfold overstatement in a
report that would have been quoted as a result.

**What the 248 names open up.** They are the game's own vocabulary for things
this project has open items on: `CountEmptyInventory`, `ExpandInventory`,
`FindEmptySlotNum`, `GetLatestAvailableSlot` (inventory size);
`RandomSelectNonEmptySlotForDeathPenalty`, `CanRevive`, `GetLifeState`,
`SetLifeState` (the death penalty); `OffsetGold`, `OffsetExpPoint`,
`OffsetSkillPoint` (the economy); plus `GetCurHP`/`GetCurMP`, `GetBodyMode`/
`SetBodyMode`, `IsWeapon`/`IsShield`/`IsArmor` and the rest of the type
predicates.

## What "attack rate" actually does, and the damage dice (2026-09-15)

The standing item was "crit/block/hit rolls — values recovered, dice not". The
dice are recovered, and **attack rate turns out not to be a hit/miss roll at
all**.

`Formula_MitigatePhysicalDamage` opens by calling `FUN_0040dce0`, which is where
a blow's size is decided:

```
lo, hi  = GetParam(13), GetParam(14)     each scaled by (1 + bonus%/100)
centre% = clamp( ((hra/era) * 0.5 + levelTerm) * 100 , 10 , 90 )
p       = min(u1, u2, u3)                ui = rand()/32767 * 100
damage% = centre% ± p                    fair coin, then clamped to [0, 100]
damage  = lo + damage%/100 * (hi - lo)
```

`hra` is param 11 (**attack rate**, on the attacker) and `era` param 9 (**parry
rate**, on the defender) — the two the client's own `textuisystem.txt` named.
So attack-rate-versus-parry sets **where in the damage range the blow lands**,
never below 10% nor above 90% of it. The excursion `p` is the **minimum of
three uniform samples**, heavily biased toward zero, so blows cluster near the
centre: the distribution is not uniform.

`_DAT_00b45af8 = 32767.0` is `RAND_MAX`, and that is the check on the whole
reading — `rand()/32767 * 100` is only a uniform percentage if every other
constant in the expression was read at the right width. Clamps are floats 10.0
/ 90.0; the `hra/era` scale is the double 0.5; the level factor is the double
0.03 at `0x00b45dc8`.

**Crit and block** use the engine's opposed-stat idiom, computed in
`Combat_ResolveDamage` and stored into a struct at `+0xc` / `+0xe`:

```
effective crit  = attacker 'cri' (12) / (1 + defender 'evcr' (57)/100)
effective block = attacker block     / (1 + defender 'evbl' (56)/100)
```

**Nothing was rewired from the distribution, deliberately.** It is a *second*
roll, on params 13/14, distinct from `Formula_RollWeaponDamage` (uniform,
`rand() % (max-min+1) + min`, params 190/191) which `combat.RollDamage` already
implements correctly and which `Combat_ResolveDamage` also calls. srrevamp has
no attack-rate or parry-rate stat, so porting the centre would mean inventing
its only input.

**One piece was wireable and is now shipped (v0.1.163).** The same formula ends
with `if defLvl < atkLvl { damage = (levelTerm + 1.0) * damage }` where
`levelTerm = clamp((level(ECX) - level(EDI)) * 0.03, 0, 0.3)` — so out-levelling
the target is worth **+3% a level, capped at +30%**. Which object is the
attacker was settled on the disassembly (`SUB ESI,EAX` after two
`Char_GetLevel` calls) *plus* an independent fact: the other object supplies
defence params 5 and 7, which this project already established are the
*target's* (cols 71/73 via `GObjMob_PublishStats`). Applied last — after
mitigation and after the berserk multiplier — and in both directions, since a
monster is the attacker in its own counterattack. Guarded on both levels being
non-zero, because a zero means "not set", not "level zero".

**The tag → ParamKeeper-id map, harvested wholesale (2026-09-15).** The tags
above are names; this is where each one *writes*. Extracted by grepping the 21
tag dispatchers for `in_EAX == 0x…` beside `ResolveRegArg.java`'s own
`/* ParamKeeper param id: EDI … */` annotations, so both halves come out of the
dump rather than being paired by eye:

| tag | params | tag | params |
|---|---|---|---|
| `'int'` | 2 | `'rals'` | 27,28,29,30,31,32 |
| `'hp'`/`'hpa'` | 3 | `'hpna'` | 52 |
| `'mp'`/`'mpa'` | 4 | `'mpna'` | 53 |
| `'era'` | 9 | `'evbl'` | 56 |
| `'bri'` | 10 | `'evcr'` | 57 |
| `'hra'` | 11 | `'drua'` | 128,129,130 |
| `'cri'` | 12 | `'dara'` | 174,175,176,177 |
| `'hprg'` | 25 | `'DABR'` | 174,175,176,177 *(negated)* |
| `'mprg'` | 26 | `'SPDU'` | 23,24 |
| `'hpmp'` | 25,26 | | |

Two corrections to what was recorded: `'rals'` writes **six** params (27–32),
not 27 alone, and `'hpmp'` is a single tag touching both regen params. `'DABR'`
and `'SPDU'` are the two tags a `CRefHWANLevel` row's effect list is built from
— each entry is a `{uint32 tag; uint8 value}` pair, and `'DABR'` applies its
value *negated* to the same four params `'dara'` writes.

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

**The big attribution passes were validated too, and they hold.**
`ValidateAttribution.java` checks interpolated modules against the **call
graph** — an independent signal, since interpolation used address adjacency
alone:

| | server | client |
|---|---|---|
| interpolated functions | 671 | 2,493 |
| call graph **agrees** | **79.6%** | **72.9%** |
| isolated (no signal either way) | 17.6% | 15.4% |
| one dissenting neighbour (weak) | 2.1% | 8.4% |
| several dissenting, none agreeing | **0.7%** (5) | **3.3%** (82) |

So roughly three quarters are positively corroborated by evidence the heuristic
never saw, and genuine suspects are under 1% on the server and about 3% on the
client. That is a very different picture from the opcode-tree pass, which was
**28% wrong** — and the difference is instructive: the attribution passes encode
a structural fact about the compiler (a translation unit is contiguous; a callee
shares its caller's module), while the opcode pass encoded a *textual* pattern
that infrastructure calls happened to match.

**This validates `maxGap = 3` specifically.** Raising it — 8 would take 3,027
functions instead of 1,286 — invalidates the measurement, so re-run this after
any change to the gap.

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
- **RTTI class recovery** — ~~impossible, not merely hard. 1,871 type descriptors
  survive and **zero** are referenced, so the COL/vftable chain was stripped.~~
  **WRONG, reopened and harvested 2026-09-15.** Nothing was stripped. The probe
  was fired 8 bytes off. An MSVC `TypeDescriptor` is
  `{ void *pVFTable; void *spare; char name[]; }`, so the `.?AVCGObjPC@@`
  string sits at **+8 inside** the descriptor and the COMPLETE OBJECT LOCATOR
  points at the descriptor's **start**. Asking for references to the *string's*
  address returns zero however intact the chain is. Walking
  `vftable[-1] → COL → TypeDescriptor` instead:

  | | descriptors | pointed at | COLs | vftables | **classes** | slots |
  |---|---|---|---|---|---|---|
  | client | 1,223 | 1,223 | 1,751 | 1,680 | **1,211** | 34,840 |
  | server | 2,003 | 2,003 | 2,029 | 1,972 | **1,939** | 40,513 |

  Two things had to be fixed before the numbers meant anything, and both were
  *artefacts of Ghidra's coverage rather than facts about the binary*:

  - **Enumerate descriptors from raw bytes, not defined data.** Ghidra had
    typed only 1,088 of the client's 1,223 as strings. Every missed descriptor
    costs its class, its vftable and every slot in it — and one of the
    casualties was the `CGObjPC` table this project has been hand-naming from
    for sessions.
  - **Walk slots while the word points into executable memory**, not while
    Ghidra happens to have defined a function there. Using `getFunctionAt` as
    the loop condition stopped at the first undefined entry and cut the average
    table to 1.4 slots. Two vftables are always separated by their COL pointer,
    which is `.rdata` and not executable, so the walk still terminates by
    itself in the right place.

  **Validated against four facts it did not produce.** Probing the one server
  vftable whose slots this project derived by hand, `0x00af59fc`:
  slot 73 → `Char_GetLevel`, 92 → `GObjPC_GainExpAndLevel`,
  93 → `GObjPC_AddSkillPoints`, 421 → `GObjPC_GiveExp` — all four exact, and
  the table ends at **427 slots**, just past 421. The walk neither over-runs
  nor mis-numbers. And the table's class comes back as **`CGObjPC`**: the
  naming convention this project adopted by hand is the binary's own.

  **Applied conservatively.** A base class's implementation appears in *every*
  derived class's table, so "first table wins" would file a base method under
  an arbitrary subclass. A function is only *named* where exactly one class
  claims it (5,313 client / 5,953 server targets) and only over a blank `FUN_`;
  everything else gets a comment listing every class and slot that reaches it,
  which is pure fact. Result: **5,362 functions named** (1,992 + 3,370) and
  6,113 commented.

  **Coverage after re-running the compounding chain: client 35.0%, server
  39.2%** — combined identified **14,064 → 26,072**.

- **RTTI, second half: the inheritance graph and 6,799 new functions
  (2026-09-15).** Both items the first pass left on the table are done.

  The COL's *other* pointer is the hierarchy: `COL+0x10` →
  `ClassHierarchyDescriptor`, whose `+0x08` is the base count and `+0x0C` the
  base-class array; each `BaseClassDescriptor` points at a `TypeDescriptor`
  from offset **0**, which is why those pointer sites had been rejected as
  "bad COL signature". They were never noise — they were the other half of the
  answer.

  | | COLs | hierarchies read | classes with a chain | edges | roots | deepest |
  |---|---|---|---|---|---|---|
  | client | 1,751 | 1,680 | 1,211 | 7,266 | 276 | 10 |
  | server | 2,029 | 1,970 | 1,939 | 2,595 | 552 | 8 |

  ```
  CGObjMob  : CGObjNPC : CGObjChar : CGObjMobile : CGObj : IGObj : CBase
  CGObjCOS  : CGObjNPC : CGObjChar : CGObjMobile : CGObj : IGObj : CBase
  CICPlayer : CICUser : CICharactor : CIGIDObject : CIObject : CIEntity : CObjChild : CObj : …
  CIF<any>  : CIFMainFrame : CIFFrame : CIFTileWnd : CIFWnd : CGWnd : CGWndBase : CObjChild : CObj
  ```

  **It confirms two hard-won findings structurally.** `CGObjMob` **is a**
  `CGObjNPC` — which is exactly why `npcpos` carries monsters, the correction
  that overturned a recorded absence and had until now rested on resolving one
  id by hand. And PC and mob share `CGObjChar`, which is why the GParamKeeper
  sits at `charObj+0x1EC` for both; that was an observation, and is now a
  consequence of the type system.

  **6,799 functions created at vftable slot targets** (3,191 server, 3,608
  client). A slot target *is* a function entry — the binary says so by putting
  it in a vftable — and Ghidra had simply never reached them, because it finds
  functions by following calls and a virtual has no direct caller. That is the
  same blind spot `VtableAttribute` was written for, and this is the stronger
  fix: a *defined* function gets decompiled into the dumps every later grep
  reads. Done only where safe — 227 targets already inside another function
  were left alone rather than splitting a correct body, and 8 that would not
  disassemble were skipped rather than forced.

  **Coverage after re-running the chain over them: server 56.3%, client
  44.5%** — combined identified **26,072 → 38,555**. Across the two ticks that
  opened this lever: **14,064 → 38,555**.

- **The 128 `CRef*` refdata classes** (server), recovered from the same
  descriptor scan and readable straight out of the binary with `strings`. This
  is the join from the 85 SQL `_REF*` tables to the C++ that parses them, and
  it names several open ledger items outright: `CRefHWANLevel` (berserk),
  `CRefCharGen`/`CRefCharGenData` (starting Str/Int), `CRefDropGold`,
  `CRefDropItemGroup`, `CRefDropItemAssign`, `CRefDropOptLevelSel` and ten
  `CRefDropClassSel_*` (the loot tables, previously "right but
  under-specified").

- **The 291 `CIF*` UI window classes** (client) — the complete catalogue of
  every window the game has, each now tied to its own vftable and therefore to
  its code. This is the UI lane's index: `CIFAlchemyBox`, `CIFAutoPotion`,
  `CIFApprenticeShipHonorRanking` and 288 more. It supersedes
  `LabelFromUIStrings`' guess-by-authored-id for anything it covers, because a
  class name is the binary naming the window itself rather than an inference
  from the text it happens to display. Counts: 879 plain classes on the client,
  809 on the server (the rest of each total is templates).

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

## Strength reaches damage: the reinforce chain, settled (2026-09-15)

The previous entry left the reinforce quad recovered but deliberately unwired,
behind one question: *does a derived bind overwrite its target's slot or
accumulate into it?* Both halves of that are now read out of the binary, and
they have **opposite answers for different params** — which is why a single
answer never fit.

### A slot is keyed, and `SetParam` and the graph share one keyspace

`ParamKeeper_SetParam(slot, ctx, value)` forwards straight to
`ParamKeeper_StoreSlot(slot, ctx, value)`, and so does the graph:
`Param_PropagateToDependents` calls `StoreSlot(*(iVar2+0x10), unaff_EBX, value)`
where `unaff_EBX` is **the source param's own object pointer**. One keyspace,
two kinds of writer. `FUN_004b2e60` then reduces a slot, and for slots 0 and 1
the reduce is `acc = entry + acc` — a SUM over entries with distinct keys.

So "replace or accumulate" is decided per call site, by whether two writers
happen to use the same `ctx`. Reading the ctx off every call site in
`Char_PublishCombatStats` gives a clean partition, not noise:

| params | slot | ctx |
|---|---|---|
| 5,6,7,8,9,0xa,0xb,0xc,0xd,0xe,0xf,0x10, 0xbe–0xc1 | 0 | **EBP** |
| 0x21–0x25, 0x3a, 0x3b, 0x8d | 0 | **0** |
| 0x17, 0x18 (four pairs) | **2** | 0 |

**And EBP is the equipped item, not the character.** The function takes the
object in `arg0` (`MOV EBP,[ESP+0x10]`) and the character in `arg1`
(`MOV ESI,[ESP+0x1c]; ADD ESI,0x1ec` — the keeper offset). `CGItemEquip::vslot_000`
zeroes exactly `+0x19c/+0x1c8/+0x1cc/+0x1d0/+0x1d4`, the fields this function
reads. That **closes the standing question about the class of arg0** (asked
because it answers a virtual at slot 33, `+0x84`, and is not `CRefObjChar`), and
it explains the ctx choice: an equipment contribution is keyed by the item, so
two equipped items each keep their own entry in slot 0 and re-equipping replaces
only that item's.

### The two answers

- **Param 34 REPLACES.** `GObjPC_InitStats` writes the innate default with
  `SetParam(0, 0, …)` and `Char_PublishCombatStats` republishes the weapon's own
  with `SetParam(0, 0, …)`. Same key, so the weapon's reinforce overwrites 30.6
  rather than adding to it. This is what the last entry declined to assume, on
  the grounds that summing would give a Copper Sword user 61.2% — that objection
  was right, and the binary agrees with it.
- **Param 13 ACCUMULATES.** Its slot 0 gets the weapon's flat minimum under
  `ctx = the item` and the Str-derived term under `ctx = param 17's object`.
  Different keys, so both live and the reduce sums them.

### The use-site, and a false negative it corrected

An intermediate reading of this said the opposite and would have shipped
nothing: `Formula_RollWeaponDamage` reads params **190/191**, not 13/14, and
nothing binds into 190–193 (checked two ways — no `BindDerived` mentions them on
either side, and their only writers are in `Char_PublishCombatStats`). On that
evidence the Str term never reaches damage.

The evidence was real; the conclusion was wrong, because a second reader exists.
`FUN_0040db50` — the helper `FUN_0040dce0` calls once per bound — reads

	iVar4 = (unaff_EDI != 0) + 0xd;                 // 13 or 14
	fVar5 = (**(code **)(*in_EAX + 0x104))(iVar4);  // GetParam(13/14)

**a computed id**, so a census of literal `GetParam(0x…)` arguments finds no
reader for params 13–16 and finding none proves nothing. Worse, the census was
wrong twice over: Ghidra prints small integers in **decimal**, so the regex
`\(0x[0-9a-f]+\)` silently dropped every id below 11 as well. *That is the third
time a too-narrow probe has produced a confident false absence in this project*
(after the 220-instruction disassembly window and the `== 0x` grep that missed
every `!=` branch). The rule already in this file — check the probe before
believing a negative — earned its place again.

So both rolls are real and they differ in **input as well as distribution**:
190/191 carry the weapon's flat range alone and are rolled uniformly; 13/14
carry that range plus the Str term plus every buff and skill modifier, and are
rolled centre-biased. **This corrects the earlier entry above**, which recorded
that the two "read an identical range" — true of the floats at publish time,
false at evaluation time, which is the only time that matters.

### The columns, pinned by four floors

`FUN_00495d60` computes an item's actual stat from a `(lo, hi, inc)` triple as
`lo + t*(hi-lo) + inc*plus`, asserting `lo < hi`. srrevamp models neither
per-instance variance nor plus level, so it takes `lo` — and `lo` is the end the
engine's own innate defaults correspond to:

| param | `.rdata` default | itemdata column | column floor (1,568 weapon rows) |
|---|---|---|---|
| 34 | 30.6 (`0x00b462a8`) | **105** | 306 |
| 36 | 34.2 (`0x00b462a0`) | **107** | 342 |
| 35 | 49.0 (`0x00b462a4`) | **109** | 490 |
| 37 | 54.8 (`0x00b4629c`) | **111** | 548 |

Four constants against four independent column minima. The `(n, n+2)` spacing
matches the already-verified attack pair (`fPhysAttackMin = 95`, max at 97), and
99/104 are the per-plus `inc` values. Read out of the PE's own `.rdata`, not
inferred: `0x00b45af0` really is `100.0`, and the slot-3 accumulator base
(`0x00b45e10`) really is `100.0`, so param 17 evaluates to `Str*reinforce/100`.

The six-row table at `0x00c640d0` reads back byte-for-byte as this file already
recorded it (3.2/5.2, 2.7/4.3, 4.2/6.7, 3.4/5.5, 2.5/3.9, 3.0/4.9), which is an
independent check on that entry rather than a new finding.

### Shipped

`combat.ReinforceDamage` and the reinforce quad through export → CSV → SQL →
`attackerDamage`, so a player's blow is `weapon range + Str*reinforce%` at both
ends. A Copper Sword (306/342) at 20 Str adds 6 and 7. Exports predating the
columns leave them zero and behave exactly as before — pinned by its own test.

### Open

- **The distribution is still uniform.** `FUN_0040dce0` rolls 13/14 with a
  three-sample minimum centre-biased about a midpoint; srrevamp rolls uniformly.
  That is a known, deliberate difference, not an unrecovered one.
- **Which roll the live melee path takes.** Both `Formula_RollWeaponDamage`
  (190/191, via `FUN_0040f990`'s attack-type switch) and `FUN_0040dce0` (13/14)
  exist; this entry establishes that 13/14 are read for damage bounds, not that
  190/191 are dead. Tracing `FUN_0040f990`'s callers is the next probe.
- Unarmed keeps the innate 30.6/34.2 in the real engine; srrevamp takes 0 there,
  since `unarmedDamage` is own design anyway.
- Still open from before: itemdata columns 114 and 117; `pc[0x72d]`'s state enum;
  blocking's monster side.

## The physical damage pipeline, register by register (2026-09-15)

The previous entry's open item was *which roll the live melee path takes*. Both:
`Combat_ResolveDamage` (`0058e5f0`) calls `Formula_MitigatePhysicalDamage` four
times **and** `FUN_0040f990` twice. They are different stages, not rivals — and
the one that produces the blow is the first.

**A better tool, recorded because it changes what is cheap.** `objdump -d
--start-address=… -M intel /var/tmp/SR_GameServer.exe` disassembles the PE
directly. It needs no Ghidra, takes no `flock`, and answers in under a second,
where a `Disasm.java` run costs ~25s and contends with the cron. Every register
fact below came from it. Use it whenever the decompiled C is ambiguous — and
here it was worse than ambiguous, reading `fStack_8` before assignment and
applying `>> 0x20` to a float.

### Who is who

	esi = eax          the attack context   (+0x230 descriptor, +0x524 bonus)
	bl  = cl           the flag byte
	ebp = [esp+0x1c]   the ATTACKER
	edi = edx          the DEFENDER

The attacker/defender assignment is proven, not assumed: `FUN_0040dce0` is
entered with `ecx = ebp`, moves it to `esi`, and calls `FUN_0040db50` with
`eax = esi`; `FUN_0040db50` then does `GetParam((edi != 0) + 0xd)` on **eax**.
So the object whose damage params 13/14 are rolled is `ebp`. The mitigation
block reads params 5 and 7 off `edi`, the other one. **That settles whose params
5 and 7 are — the defender's** — which this project had recorded as "the same
object" without saying which.

### The order

	raw   = centre-biased roll of ATTACKER params 13/14        FUN_0040dce0
	        + descriptor[+8] / [+0xc] folded into the bound     40db86 / 40db8b
	raw  += context[+0x524] bonus                   if flags & 0x08
	mit   = raw / (1 + defender_p7/100) - defender_p5          40e52a-40e542
	        ... skipped entirely                    if flags & 0x20
	mit   = max(mit, 0)                                        40e54a
	mit  *= descriptor[+4] / 100                               40e56e-40e588
	mit  *= 1 + GetParam(0x80 | 0x81)/100                 by flags bit0/bit1
	mit  += GetParam(0x103)/100 * mit      if defender vf[0x12c] == 3
	mit  *= GetParam(0xbd) + 2.0                    if flags & 0x04
	mit  *= 2                                       if flags & 0x02
	mit  *= 1 + LevelAdvantage()                    if atkLevel > defLevel

The struct at `+0x230` is the **attack descriptor**, and its three numeric
fields are exactly the three this project already reads out of skilldata's
`'att'` parameter: the percentage at `+4`, a flat minimum at `+8` and a flat
maximum at `+0xc`. **The two halves land on opposite sides of mitigation** —
the flat pair is added to the rolled bound inside `FUN_0040db50`, the percentage
multiplies only after the division, the subtraction and the clamp.

### What moved

- **Shipped:** `combat.ApplySkillPercent`, and `skillDamageBonus` now returns
  `(flat, percent)` so `performAttack` can put them on the right sides. srrevamp
  had folded the percentage into the raw roll, which scales the defence away:
  a 200% skill against 10 flat armour paid 180 instead of 160. Pinned end to end
  through the network harness by a test verified to report 50 under the old
  order. This is the same mistake, and the same fix, as the berserk multiplier's
  ordering two entries ago — worth noting that it recurred in a second place
  after being fixed in the first.
- **Fixed in passing:** the old `skillDamageBonus(ref, weaponDamage)` rolled the
  weapon a *second* time to compute its percentage, then handed the result to
  `performAttack`, which rolled the weapon again for `base`. Two independent
  rolls were being mixed into one blow. The percentage now scales the actual
  blow, so there is one roll.
- **Citation upgraded, no code change:** `playerMitigationPercent = 0` and
  `LevelAdvantage` 0.03/0.30 both re-derived independently here — the level
  constants read out of `.rdata` as `fmul QWORD 0x00b45dc8` = 0.03 and
  `fld DWORD 0x00b45b8c` = 0.30, with the operand sizes confirming which is
  which. Both already carried the right values and the right citations.
- **v0.1.174 validated:** the params the live path rolls for its damage bounds
  are 13/14, the ones carrying the Str-derived reinforce term.

### Open

- `GetParam(0x80)` / `GetParam(0x81)` off the attacker, selected by descriptor
  bits 0 and 1 — a percentage bonus against some target class.
- `GetParam(0x103)` off the attacker, live only when the defender's `vf[0x12c]`
  returns 3.
- Descriptor flag `0x20` skips mitigation outright; which attacks set it.
- `FUN_0040f990`'s switch (2..N) scales `Formula_RollWeaponDamage`'s uniform
  190/191 roll by `.rdata` constants. Since 190/191 carry no Str term and no
  buffs, this is a *second*, simpler damage path; what selects it is unknown.
- Still open from before: itemdata columns 114 and 117; `pc[0x72d]`'s state
  enum; blocking's monster side.

## The kill-EXP formula, and a correction (2026-09-15)

### First, two open items closed cheaply

**Which damage path is the ordinary attack.** `Combat_ResolveDamage` wraps its
damage step in `switch (*(byte *)(iStack_e0 + 5))` — a damage-KIND selector:

| case | path | params |
|---|---|---|
| **0** | `Formula_MitigatePhysicalDamage` + the magical twin | **13/14** |
| 1 | `Formula_RollLevelDamage` | level-based |
| 2 | `GObjPC::FUN_00615a20` | — |
| 3 | `FUN_0040f990` → `Formula_RollWeaponDamage` | 190/191 |

Case 0 is the ordinary attack, so the Str-carrying params 13/14 are the live
path and `FUN_0040f990`'s simpler 190/191 roll is a special damage kind. That
confirms v0.1.174 and v0.1.175 sit on the right branch.

**The berserk constant.** `_DAT_00b45f30` reads 2.0 as a double and 0.0 as a
float, so the operand size decides a shipped value. It is
`40e672  FADD QWORD PTR ds:0xb45f30` — a double. Berserk is `GetParam(189) +
2.0`, and srrevamp's flat ×2 is that at the default rate. No change; the
citation is now operand-checked.

### The exp reward, register by register

`Formula_MonsterExpReward` (`004105d0`), disassembled:

	ebx = MIN(level(esi), level(edi))            the anti-powerlevelling rule
	A   = (float)(uint32) RefLevel_GetEntry(ebx)[+0x1c]
	B   = Formula_ExpScaleByLevelWindow(edi)
	C   = FLD DWORD PTR [edi + 0x1cd8]
	D   = Formula_ExpScaleByLevelDiff(esi, edi)
	exp = B * A * C * D, floored at 1

**Correction: `+0x1cd8` is the KILLER's field, not the victim's.** This file
recorded it as `victim[0x1cd8]`. `GObjPC_OnDeath` (`004e6980`) is `__thiscall`
with the dead party as its stack argument, and its prologue is unambiguous:

	4e69bf  MOV EBP,[ESP + 0x11f4]     <- the stack arg, the DEAD
	4e69d2  MOV EDI,ECX                <- `this`, the KILLER
	4e69c6  MOV EAX,[EBP + 0x34]       <- the dead's charData (+0xb4 below)
	4e6a07  MOV EAX,EBP ; CALL 0x4105d0

so inside the formula `esi` is the dead and `edi` the killer, and `C` is read
off the killer. It is a float, and on `CGObjMob` the same offset is a packed
byte (`CGObjMob::GetMonsterClass` is `MOV AL,BYTE PTR [ECX+0x1cd8] ; AND AL,0xF`)
— different classes, which is what made the original reading look plausible.
A per-character exp rate, presumably premium or event; not modelled.

**There is no per-species exp column anywhere in this formula.** The monster
contributes only its LEVEL, through the minimum and through the gap scaler.
That retires the standing note in `combat.ExpFor` that "the real value is in the
client's mob data (RefObjChar's ExpToGive)" — no such field is read.

### Formula_ExpScaleByLevelDiff: RECOVERED and shipped

	40108f  LEA EAX,[EDI + 0x3] ; CMP EAX,EBX ; JG     <- victim+3 > killer?
	4100a0  FLD1 ; RET                                 <- else exactly 1.0
	4100a8  SUB EDI,EBX ; ADD EDI,0x3                  <- victim - killer + 3
	4100ad  CMP EDI,0xD ; MOV [ESP+0xC],0xD            <- capped at 13 steps
	4100c2  FMUL qword [0x00b45dc8]                    <- * 0.03
	4100c8  FADD [ESP + 0x8]                           <- + bonus + 1.0
	4100f1  FLD  dword [0x00b45dc0]                    <- clamped to 4.0

`EDI` is the victim's level and `EBX` the killer's, from the caller's
`MOV EAX,ESI ; MOV ESI,EDI` at `0x410666` plus the prologue above. Operand sizes
give the constants: `FMUL qword` makes `0x00b45dc8` a double, **0.03** — the
same constant the level-advantage damage term uses — and `FLD dword` makes
`0x00b45dc0` a float, **4.0**.

So: out-level the target by three or more and the bonus is exactly 1.0;
otherwise `1 + 0.03 * min(victim - killer + 3, 13)`, spanning 1.03 to 1.39.

**Not modelled, deliberately.** The same function can add a further
0.15/0.3/0.45 (or 0.3/0.6/0.9 under a flag at the killer's ref object `+0x88`)
for gaps above 4, 6 and 8 — but only behind a state gate, `killer[0x72e]`
non-null with bit 0 of its `+0x10` set, which is not identified. A bonus whose
precondition is unknown would be applied always, which is worse than omitting
it. The cap is therefore unreachable in srrevamp.

`Formula_ExpScaleByLevelWindow` (`0040fed0`) stays at 1.0: it branches on a mode
from `FUN_0040fe60` and asserts on two of its three paths, and neither the mode
nor what selects it is identified.

**What moved:** `leveldata.ExpDiffScale`, applied inside `KillExp`. The base and
the minimum-level rule were already real and already wired into the kill path;
this replaces the last "treated as 1.0" simplification in the kill reward with
the recovered curve. A level-1 character killing a level-20 monster now earns
33 rather than 24 — still paid at the level-1 unit, but with the gap bonus. The
reverse direction is unchanged at 24, so the economy only opens upward.

### Noted in passing

`pc[0x72d]` — an open item — appears here as `CMP BYTE PTR [EBP+0x1cb4],0x5`
(`0x72d * 4 = 0x1cb4`). `!= 5` is what gates both the doubled exp reward and
the death-penalty branch, so whatever state 5 is, it suppresses both. Still not
identified, but the use-site is now a pair rather than a single.

## The death handler, read to the bottom (2026-09-15)

`GObjPC_OnDeath` (`004e6980`) had three things recorded against it as not
understood. All three are now read.

### pc[0x72d] is a DEATH-KIND code

An open item since the death penalty was first recovered. It is written one
instruction before it is dispatched on, by `GObjPC::FUN_004e6ec0` (`004e6ec0`):

	uVar1 = FUN_004e6590();            <- classify the death
	pc[0x1cb4] = uVar1;                <- 0x72d * 4
	switch (uVar1) {
	  case 1:            FUN_004e6820(); return;
	  case 3: case 4: case 5: GObjPC_OnDeath(); return;
	  case 6:            FUN_004e6d60(); return;
	}

So it is not a general state enum: it is the KIND of the death that just
happened, and only kinds 3, 4 and 5 reach the penalty handler at all. The
classifier `FUN_004e6590` ends with

	iVar2 = FUN_004eb390(in_EAX);
	return (-(uint)(iVar2 != 1) & 0xfffffffe) + 5;     <- ==1 -> 5, else -> 3

and `FUN_004eb390` returns 1 only when the killer passes the `vf[0x1c]`
predicate, BOTH parties have a non-null `[0x72f]`, and a further comparison
matches. Two parties sharing a membership object, in a death that suppresses the
PK treatment — the shape of a duel or a match — but `[0x72f]` is not identified,
so the kind is described, not named.

### The 20/100/300 branch conditions

Previously "NOT understood". The selector is `killer->vf[0x1c]()`:

	vf[0x1c]() == 0  ->  100 / 300,  SP loss 60
	vf[0x1c]() != 0  ->   20 / 100,  SP loss 20

and that same predicate gates the exp grant at the top of the function — the
killer is paid only when it is non-zero. A predicate that decides whether the
killer receives experience identifies a PC, so `!= 0` is **killed by a player**
and `== 0` **killed by a monster**. That confirms, rather than changes,
srrevamp's existing `DeathPenaltyKilledByMonster` 100 / `Flagged` 300 and
`KilledByPlayer` 20 / `Flagged` 100 — names that were a reasonable hypothesis
and are now the recovered mapping.

The second condition, the one the names call "Flagged", is
`deathKind != 5 && victim.PKPenaltyPoint >= 1` — and the SP loss is non-zero
only on that branch, which is why srrevamp's two skill-point constants exist
only in flagged form. The identical condition doubles the KILLER's experience,
so a flagged victim is worth twice as much and loses three times as much.

### The reduction stat: param 257, and a proven zero

Recorded as "read through a register-passed ParamKeeper id this code has not
resolved, so it is left out rather than guessed at". The id is in EAX:

	4e6b78  LEA  EDI,[EBP + 0x1ec]      <- the VICTIM's own GParamKeeper
	4e6b7e  MOV  EAX,0x101              <- param 257
	4e6b83  CALL 0x4b3740               <- EvaluateParam
	4e6b88  FDIV qword [0x00b45af0]     <- / 100
	4e6b8e  FIMUL dword [ESP + 0x14]    <- * the loss
	4e6b9b  SUB  ESI,EAX                <- loss -= that

so it is a PERCENTAGE of the loss rather than a flat term. **Exactly one
function in the binary writes param 257**, and it names itself:
`CTJ_PremiumKeeper::vslot_012` (`006524b0`), which sets 256, 257 and 258
together out of one premium-benefit record (`+0x300`, `+0x2c0`, `+0x320`). The
death-penalty reduction is a PREMIUM ACCOUNT benefit; an ordinary character has
no writer for the param and evaluates it at zero.

**What moved:** `leveldata.DeathPenaltyReductionPercent` and
`ApplyDeathPenaltyReduction`, wired into `DeathPenaltyExp`. The value is zero, so
no death costs a different amount — but it is now a *cited* zero with the
engine's shape around it, the same status as `playerMitigationPercent`, instead
of an unmodelled gap. The test pins the percentage shape so a premium system
later lands in the right arithmetic.

### Three stale claims corrected

- `combat.ExpFor` told the reader the real value was "RefObjChar's ExpToGive".
  There is no such field in the formula — the previous entry established that a
  monster contributes only its level — so the note sent future work looking for
  a column that is never read. Same claim removed from `Monster.ExpReward`.
- `Monster.SPReward` carried the same claim, but there the honest statement is
  different and now says so: the exp formula has been read end to end and pays
  no skill points at all, so whatever grants them is a path not yet found.
- `duel.go` justified charging no death penalty with "same as PvE", which
  stopped being true when PvE began applying the real 100x. The divergence is
  now stated as own design, together with what is and is not established: a PC
  killer does take the 20x branch, but whether a duel death reaches
  `GObjPC_OnDeath` at all depends on its death kind, and kinds 1, 2 and 6 go
  elsewhere. Charging 20x without reading that would be a guess dressed as
  recovery, so the behaviour is unchanged.

### Open

- `[0x72f]` and `[0x72e]` — adjacent pointer fields on a PC, gating death kind 5
  and the exp-reward tier bonus respectively. Naming either would name both a
  death kind and a shipped-adjacent bonus.
- `vf[0x3b4]` on the killer overrides the loss outright in the monster branch.
- Death kinds 1, 2 and 6, and their handlers `FUN_004e6820` / `FUN_004e6d60`.
- Params 256 and 258, the other two premium benefits.
- Still open from before: `GetParam(0x80/0x81)` and `GetParam(0x103)` in the
  damage pipeline; the mitigation-skipping descriptor flag `0x20`;
  `Formula_ExpScaleByLevelWindow`'s mode; itemdata columns 114 and 117.

## [0x72e] and [0x72f] are PARTY and GUILD — and the exp formula closes (2026-09-15)

The previous entry named these two adjacent PC pointer fields as the best next
lever, on the grounds that either one would settle both a death kind and a
shipped-adjacent bonus. Both are named now, and from the binary's own asserts
rather than by inference:

	CGObjPC::GetPartyInfo  (IGObj vtable slot 76)  reads pc+0x1cb8  -> [0x72e] = PARTY
	CGObjPC::GetGuildName  (IGObj vtable slot 94)  reads pc+0x1cbc  -> [0x72f] = GUILD

Each override is a two-line function whose only field access is the one in
question, and each was already named by the base class's `__FILE__` assert. That
retires two open items at once:

- **The exp-reward tier bonus is a PARTY bonus.** Its gate is `killer[0x72e]`
  non-null with bit 0 of the party's `+0x10` set. Still not shipped — what bit 0
  selects is unread, and srrevamp's parties are own design with no such flag —
  but the reason is now "a party-conditional bonus whose party flag is unread"
  rather than "an unidentified state".
- **Death kind 5 needs BOTH parties in guilds.** `FUN_004eb390` requires the
  killer to pass the PC predicate, the victim's `+0x1cbc` to be non-null, and
  the killer's `[0x72f]` likewise, before a further guild-to-guild comparison.
  A player kill where both sides are guilded, which suppresses the PK penalty
  and the doubled reward, is a guild-war or siege death. Described, not yet
  named: the comparison itself (`FUN_005e4390`, a two-hop accessor into the
  guild object) has not been followed to a war table.

### Formula_ExpScaleByLevelWindow: RECOVERED, and the exp formula is now whole

The last "treated as 1.0" term. Its mode comes from `FUN_0040fe60`, which turns
out not to be a mode at all but three comparisons on the level gap:

	gap = victimLevel - killerLevel
	gap <  -3 -> 2      gap < 11 -> 0      otherwise -> 1

and **mode 0 jumps straight past every arithmetic path** (`40ff03 SUB EAX,0 ;
JE 0x40ff8c`), leaving the 1.0 the result was initialised to. So inside a
-3..+10 band the scale is exactly 1.0 — which is most kills, and means the old
placeholder was accidentally right for the common case and wrong only at the
extremes.

The two outer arms:

	mode 1, 40ff5d:  SUB EDX,EBX ; SUB EDX,0xA
	                 FMUL qword [0x00b45ec8]      <- * 0.02
	                 FLD1 ; FSUBRP                <- 1.0 - that
	mode 2, 40ff1f:  SUB ECX,EBX ; CMP ECX,-7 ; JG
	         40ff55:   FLD dword [0x00b45ddc]     <- 0.9 flat
	         40ff38:   SUB EBX,EDX ; SUB EBX,3
	                   FMUL qword [0x00b45ed0]    <- * 0.15
	                   FLD1 ; FSUBRP
	clamp,  40ff94:  FCOM qword [0x00b45ec0]      <- below 0.1 -> 0.1
	        40ffb6:  FLD1 ; FCOM                  <- at or above 1.0 -> 1.0

`EBX` is the killer's level and `EDX` the victim's, from
`Formula_MonsterExpReward`'s `MOV ECX,EDI` (EDI being the killer) with ESI still
holding the victim.

**Operand size mattered more than usual here.** Both `0x00b45ec8` and
`0x00b45ed0` read as `2` when taken as a float and as `0.02` and `0.15` as
doubles — and the instruction is `FMUL qword` in both cases, so they are the
doubles. Taking the float would have made every extreme-gap kill pay a negative
scale clamped to the floor.

So the scaler is, clamped to [0.1, 1.0]:

| gap (victim − killer) | scale |
|---|---|
| ≥ 11 | 1 − (gap − 10) × 0.02 |
| −3 … 10 | **1.0** |
| −4 … −6 | 0.9 |
| ≤ −7 | 1 − (−gap − 3) × 0.15 |

**What moved:** `leveldata.ExpWindowScale`, applied in `KillExp` alongside
`ExpDiffScale`. With both scalers in, a kill's experience is the game's own
formula at the base rate — only the killer's premium/event multiplier
(`killer+0x1cd8`) is left out, and a character without one evaluates it at its
default.

The visible change is at the extremes, and it is the real anti-powerlevelling
rule: a level-20 killing a level-1 drops from 24 to **2** (the minimum-level
rule still pays the level-1 unit, but the window floor takes 90% of it), and a
level-10 killing a level-3 from 71 to 28. Kills inside the band are unchanged —
a level-3 on a level-10 stays 92.

### Open

- Bit 0 of a party's `+0x10`, which arms the exp tier bonus.
- `FUN_005e4390` and the guild-to-guild comparison behind death kind 5.
- `vf[0x3b4]` on the killer, which overrides the death loss outright.
- Death kinds 1, 2 and 6 and their handlers.
- Premium params 256 and 258, and `killer+0x1cd8`, the exp rate.
- Still open from before: `GetParam(0x80/0x81)` and `GetParam(0x103)` in the
  damage pipeline; the mitigation-skipping descriptor flag `0x20`; itemdata
  columns 114 and 117.

## The stat-tag vocabulary, extracted mechanically (2026-09-15)

`Stat_ApplyTaggedModifier` (`00498690`) is the id→name table this binary has as
code rather than data, and it had been read by hand, fourteen tags at a time.
Extracting it mechanically instead — walk the function body, remember the most
recent `in_EAX == 0x…` equality (never a range test, which is the binary-search
trap this file already records), and attribute the `ParamKeeper param id`
comments that follow it — gives nineteen:

| tag | constant | params |
|---|---|---|
| `int` | 0x00696e74 | 2 |
| `hp` / `hpa` | 0x00006870 / 0x00687061 | 3 |
| `mp` / `mpa` | 0x00006d70 / 0x006d7061 | 4 |
| `era` | 0x00657261 | 9 |
| `bri` | 0x00627269 | 10 |
| `hra` | 0x00687261 | 11 |
| `cri` | 0x00637269 | 12 |
| `hprg` | 0x68707267 | 25 |
| `mprg` | 0x6d707267 | 26 |
| `hpmp` | 0x68706d70 | 25, 26 |
| `rals` | 0x72616c73 | 27–32 |
| `hpna` | 0x68706e61 | 52 |
| `mpna` | 0x6d706e61 | 53 |
| `evbl` | 0x6576626c | 56 |
| `evcr` | 0x65766372 | 57 |
| **`drua`** | 0x64727561 | **128, 129, 130** |
| **`dara`** | 0x64617261 | **174, 175, 176, 177** |

**Seventeen of the nineteen reproduce the map this project had already read by
hand, value for value.** That is what licenses the other two: the extraction is
not a new method whose output has to be taken on trust, it is a method checked
against seventeen known answers before being asked a new question.

`drua` matters because params 128 and 129 are read in the damage pipeline —
`Formula_MitigatePhysicalDamage` multiplies the mitigated blow by
`1 + GetParam(0x80 | 0x81)/100`, choosing between them on bits 0 and 1 of the
attack descriptor. So it is a conditional damage bonus, and the tag that grants
it is now named even though what the two bits select is not.

**Encoding, since this has been got wrong before.** The tables store the tag as
a multi-char literal, so the bytes come out reversed from a little-endian read:
`0x00617474` unpacks to `tta` and is `att`. A census of the real skilldata Params
block confirms it independently — the codes that fall out are `tta`, `pfed`,
`laeh`, `arud`, `msnc`, which reversed are `att`, `defp`, `heal`, `dura`, `cnsm`.
Hand-computing these constants has cost this project a wrong result twice; both
times the fix was to let the machine do the arithmetic, and that is what this
entry does.

### A negative that does not hold, recorded so it is not re-derived

`drua` and `dara` appear on **zero** rows of skilldata's Params block and zero
rows of itemdata. That is NOT evidence they are dead, and the control run in the
same probe proves why: **`cri` also appears zero times**, and `cri` is a real,
shipped stat — a weapon's Critical reaches param 12 from itemdata **column 116**,
a dedicated column, not from a Params tag. A tag's absence from the Params block
therefore says nothing about whether the stat is live.

The probe was too narrow, and only the control caught it. This is the fourth
false negative in this project from a probe that could not have found what it was
looking for; the rule it keeps re-teaching is to run a known-positive through
every new probe before believing its zeros.

### Naming coverage, measured

Off the dump indexes directly, needing no Ghidra run: server **64.6%** (22,033 of
34,113), client **46.1%** (20,038 of 43,460). The client's unnamed set is mostly
small — 17,245 of its 23,422 are under 128 bytes — leaving roughly 6,200
substantial functions genuinely unnamed.

Both binaries already carry the source-file attribution pass (12,954 module
comments in the client dump, 14,328 in the server), so that lever is spent. An
earlier count here suggesting otherwise was an artifact of comparing *files*
containing the comment across dumps with 22 and 2,133 shards respectively.

**No srrevamp value changed this tick.** The vocabulary is knowledge, and the
one code-adjacent edit is a correction: `docs/GROUNDING_AUDIT.md` asserted in a
single sentence both that `Char_PublishCombatStats` publishes param 12 and that
it "indeed does not". It does — `0x00497ef0`, `MOV EDI,0xc`, from the stat
source's `+0x1dc` — and the tag route simply coexists with it.

## Skill points are a CURRENCY, not a per-kill grant (2026-09-15)

`combat.SPFor` -- a tenth of a monster's max HP -- was the last wholly invented
value in a monster's profile. Every other field is real: level (col 57), rarity
(15), max HP (59), flat absorb (71), reduction (73), the attack range (col 83's
skill `'att'`), gold (levelgold.txt), critical (78), block (76), spawns
(npcpos), and since two entries ago the experience. Skill points were the
holdout, and the previous entry had recorded that "the exp formula has been read
end to end and pays no skill points, so whatever grants them is a separate path
this project has not found."

It is not a separate path. It is the same call, one argument over.

### The mechanism

`GObjPC_GainExpAndLevel` (`004e5250`) takes SIX arguments, and the skill
experience is the **fourth and fifth** -- a 64-bit pair distinct from the
experience in the second and third. Every ordinary exp grant passes zero there
(`GObjPC_GiveExp` calls it `(src, expLo, expHi, 0, 0, 0)`), which is why reading
the exp path end to end found no skill points. The block that consumes it:

	acc = charData[0x70] + amount          <- _CHAR.SExpOffset, the carried total
	if acc >= 400 {
	    sp  = __alldiv(acc, 400)           <- whole points
	    acc = acc - sp*400                 <- the remainder STAYS on the character
	    this->AddSkillPoints(sp, 0)        <- vtable slot 93
	}
	charData[0x70] = acc                   <- persisted, dirty bit 4 set

`charData + 0x70` is `SExpOffset` in the recovered `_CHAR` schema, and the name
says it: skill experience, offset-encoded like `ExpOffset` beside it.

**So skill points are bought, at 400 skill-experience each, out of a running
total the character carries between kills.** Granting whole points per kill --
what srrevamp did -- cannot reproduce that at any rate, because it rounds every
kill to a whole point.

The same block confirms last entry's guild naming from a completely different
function: it only touches its guild-contribution accumulator (`pc[0x861]`,
flushed to the guild at 10) when `pc[0x72f]` is non-null, and `[0x72f]` was
named GUILD from `CGObjPC::GetGuildName`.

### What is NOT recovered, and is disclosed instead

How much skill experience a KILL is worth. The amount reaches the function as
`levelTable[lvl]+0x1c * M` (`FUN_00631050`), the same per-level unit that pays a
kill's exp and a death's penalty -- but `M` comes from a struct that has not been
identified, and the one caller that spells the expression out is a quest reward
rather than a kill. srrevamp takes **M = 1**: a kill is worth its own experience
in skill experience. That is a disclosed choice and the single knob to turn if
`M` is ever read.

It also corrects a claim in `ExpUnit`'s own comment, which said `FUN_00631050`
hands that product to `GainExpAndLevel` "as an exp amount". It goes in as the
skill experience. The same per-level unit feeding a kill's exp, a death's
penalty and a skill-point award is what makes it the table's unit of account
rather than one system's constant.

### What moved, and the balance consequence stated plainly

`leveldata.SkillExpPerPoint = 400`, `skill.Store.AddSkillExp` (both stores, with
a `skill_exp` column added beside `points` so existing characters keep what they
earned), and the kill path now credits skill experience instead of points. The
whole-point path survives only as the fallback for a deployment with no level
table, where there is no experience to convert.

**SP income drops sharply, and that is the point rather than a side effect.** A
level-1 character killing a Mangyang earned 5 points a kill (a tenth of its 54
max HP); it now earns 26 skill experience, so a point arrives about every 15
kills, and the first mastery level costs 1. At level 20 a same-level kill is
worth ~512, so roughly a point a kill against a mastery cost of 53. That curve
-- tight early, roughly one point per kill by mid level -- is the shape the
400:1 conversion produces on its own, from numbers that were already grounded.

### Also corrected

Two field comments in `combat.Monster` that had gone stale: `Defense` was
labelled "still the disclosed curve" when it has been characterdata col 71 since
2026-09-15 (`cmd/server`'s own `monsterSpec` says so), and `Level` still claimed
MaxHP and the attack range were disclosed defaults when both are real.

## No kill feeds the skill-point currency (2026-09-15)

The previous entry shipped the 400:1 skill-experience conversion and disclosed
one unknown: how much skill experience a KILL is worth, taken as `M = 1`. The
justification was thin — "the one caller that spells it out is a quest reward
rather than a kill" — and it sat under a large balance change, so it was worth
settling. It is settled, in the negative, and the probe is closed rather than
merely unlucky.

**Every route into the currency, enumerated:**

1. **The carried total has one writer.** `_CHAR.SExpOffset` (`charData+0x70`) is
   written in exactly one place: the 400:1 conversion inside
   `GObjPC_GainExpAndLevel`. The only other function that touches the field,
   `GObjPC::FUN_0049efc0`, reads it (with `+0x74`, Strength) into a packet.
   Checked two ways — the `[0xd] + 0x70` form and a broad `+ 0x70) =` scan whose
   other hits are offset collisions on unrelated structs.
2. **Only four of forty-two `GainExpAndLevel` call sites pass skill
   experience.** It is the FOURTH argument, a 64-bit pair distinct from the
   experience in the second and third, and every ordinary exp grant passes zero
   there — `GObjPC_GiveExp` calls it `(src, expLo, expHi, 0, 0, 0)`. The four
   that do not are a quest reward (`FUN_00631050`), its party distribution
   (`FUN_00631630`), and two others off the same path. The first census of this
   missed the argument lists because the decompiler wraps them across lines; the
   second joins the call before matching, and finds the same four.
3. **Every positive `AddSkillPoints` caller is the conversion or a refund.**

So **no kill path in this binary feeds the skill-point currency**, and there is
no `M` to read for a kill. That does not change what srrevamp ships; it replaces
a thin reason for the disclosure with an exhaustive one, which is the difference
between "not found yet" and "searched and absent".

### Recovered in passing: the skill-reset refund is 80%

`FUN_00410ea0` walks a chain (`+0x59c` is the next link), sums the skill points
invested at each node (`+0xc0`), optionally stopping at a level threshold
(`+0x64`), and then:

	iVar1 = iVar1 + (iVar1 * -0x14) / 100      <- minus 20%, i.e. 80% back

Its caller `FUN_0059f8b0` hands the result to `AddSkillPoints(n, 1)`, and the
client ships the window it belongs to — `IFSkillWithdrawal.cpp` and
`IFSkillRemovalBox.cpp` are both in the client's own source-path strings. So
un-learning a skill chain refunds **80%** of the points spent on it.

**Not shipped, deliberately:** srrevamp has no skill withdrawal, so exporting an
80% constant would add a value nothing consumes — the pattern this file has
corrected repeatedly. It is recorded here for whoever builds that window.

### Open

- Whether a mob's death runs through a handler this project has not found. All
  three death handlers reached from `FUN_004e6ec0`'s dispatch (`FUN_004e6820`
  kind 1, `GObjPC_OnDeath` kinds 3–5, `FUN_004e6d60` kind 6) are PC-death
  variants in `GObjPC.cpp`, all gated on the victim's level exceeding 10 and all
  applying an exp penalty. If a mob-side death handler exists, it is the one
  place a kill-side skill-exp source could still hide.
- `M` itself, for the quest path: `*(int *)(iVar2 + 0x10)` from an unidentified
  struct.
- Still open from before: bit 0 of a party's `+0x10`; `FUN_005e4390`'s guild
  comparison; `vf[0x3b4]`; premium params 256/258 and `killer+0x1cd8`;
  `GetParam(0x80/0x81)` and `GetParam(0x103)`; descriptor flag `0x20`; itemdata
  columns 114 and 117.

## Death dispatch is vtable slot 311 — and a foundational claim weakens (2026-09-15)

The previous entry's recorded next thread was "whether a mob's death runs
through a handler this project has not found". It does, it is found, and what it
does not do is the finding.

### The dispatch, by vtable slot

Death entry is **slot 311** (`offset 0x4dc`), and reading that slot straight out
of each class's vtable in the PE names all three implementations without opening
Ghidra:

| class | vtable | slot 311 |
|---|---|---|
| `CGObjPC` | 0x00af59fc | `0x004e67e0` → `FUN_004e6ec0`, the kind classifier |
| `CGObjMob` / `CGObjNPC` | 0x00aee43c, 0x00aef674 | **`0x004c42f0`** |
| `CGObjCOS` (pets) | 0x00af0c1c, 0x00af127c | `0x004d2cd0` |

`0x004c42f0`'s RTTI confirms it: *CGObjMob slot 311, CGObjNPC slot 311,
CGObjSiegeObject slot 311…*. **It grants no experience.** It runs a PK decay
(`FUN_004eb6b0`, gated on the killer's `PKPenaltyPoint > 0`, scaling by a
level-gap classifier) and dispatches slot 398, which for `CGObjMob` is a death
broadcast building opcode `0x7808`.

### Every exp grant in the binary, enumerated

All 42 `GObjPC_GainExpAndLevel` (slot `0x170`) call sites, with argument lists
joined across the decompiler's line wrapping first. The ones granting positive
experience are:

- **Quest completions** — eight `CQNO_*::vslot_103`.
- **`GObjPC_GiveExp`** — and its only three callers are `GObjPC_OnDeath`,
  `FUN_004e6d60` and `FUN_004e1f60`, all reached from the PC death-kind
  dispatch.
- **`FUN_004fcda0`** — `GiveExp`'s own party share.
- **`FUN_0049ff20`** — a premium/item grant; it reads `+0x2c0` off the same
  record `CTJ_PremiumKeeper::vslot_012` uses for param 257.
- **`trs_*`** — GM and training-camp paths, one of which hands out a flat
  2,000,000.

### The consequence: the name overstated the case

`Formula_MonsterExpReward` is **this project's** name. Its only two callers are
reached when a **PLAYER** dies — `GObjPC_OnDeath`'s victim is always a PC, which
is settled rather than assumed: the function reads `param_2[0x72d]`, the
death-kind byte, and that byte is written only by `FUN_004e6ec0`, which is
reached only from `CGObjPC::vslot_311`.

So every use-site of the formula in this binary is a PvP kill. Nothing *in* the
formula is PvP-specific — it takes the two levels and the level table and
nothing else — so applying it to a monster kill remains the best grounded model
available, and `KillExp` is unchanged. But this file called it "PROVEN by its
use-site", and that was true of the function's **identity** (its result goes to
`GObjPC_GiveExp`) and not of its **application**. The comment in
`leveldata.ExpUnit` now carries the caveat.

**What is NOT concluded:** that monsters grant no experience. That would
contradict the game, and the honest reading is that a PvE reward path exists
which this enumeration has not reached — most likely deeper in `FUN_004c42f0`'s
slot-398 chain, which was read two levels down, or in the AI/tactics module. The
enumeration above is of `GainExpAndLevel` call sites; a path that reaches the
character's exp another way would not appear in it. Recording the boundary of
the probe rather than treating its edge as the world's.

### Also named

`FUN_004e1f60` — a per-death-kind social handler. For kind 1 it pays the killer
`levelTable[min(levels)]+0x1c * 3` and branches on `param_1[0x72e]`, the party
pointer, routing through `FUN_005bd7f0` when the killer is partied and
`FUN_004e2830` when solo. A third, independent use of the party field named two
entries ago.

`FUN_00410ea0`'s neighbourhood is confirmed as the skill-reset path rather than
a reward: `FUN_0059f8b0` hands its 80% refund to `AddSkillPoints`.

**No srrevamp value changed.**

## The PvE exp question, closed (2026-09-15)

The previous entry stopped at a boundary rather than a conclusion: the exp
enumeration covered `GainExpAndLevel` call sites, so a PvE path reaching a
character's experience *another way* would not have appeared in it. That hole is
now closed from the other end.

**Both experience fields have exactly one writer.**

| field | what | writers |
|---|---|---|
| `charData+0x68` | `ExpOffset` | **`GObjPC_GainExpAndLevel`**, and nothing else |
| `charData+0x70` | `SExpOffset` | the same function, and nothing else |

The only other function touching either is a reader in both cases:
`GObjPC::FUN_0049efc0` puts `SExpOffset` into a packet, and
`GObjPC::FUN_004909f0` formats `ExpOffset` into `" ^^%d^^"` for what is plainly
a GM stat dump. So **every** grant of experience or skill experience in the
binary must pass through `GainExpAndLevel`, whose 42 call sites the previous
entry enumerated in full.

Combined with this tick's vtable reads, the mob side is covered three ways:
`CGObjMob`'s death handler (slot 311, `0x004c42f0`), its slot-398 override
(`0x004c1c80`, a death broadcast) and its slot-322 override (`0x004c1c30`, which
only sets `[0x738] = 20000` behind the `vf[0x3b4]`/`vf[0x3bc]` predicates) grant
no experience between them.

**So this binary contains no PvE experience reward.** Not "none found" — none
reachable, because the field it would have to write has a single writer and that
writer's every caller is accounted for.

### Why that strengthens srrevamp rather than undermining it

The previous entry left `KillExp` resting on an extrapolation and flagged it as
one. The extrapolation is now the *only* option rather than a choice: there is no
PvE formula in the binary that srrevamp declined to use. It models a monster kill
with the single reward formula the artifact contains, whose inputs -- the two
levels and the level table -- carry nothing PvP-specific. `leveldata.ExpUnit`'s
caveat now says so.

The likeliest explanation for the absence is the artifact itself: this is a
private-server build (y0gi "Easy" VSRO), and a PvE reward that was configured
out, moved to a module outside this executable, or driven from data would leave
exactly this signature. That is a hypothesis about *why*, not a hedge on the
*what* -- the enumeration stands on its own.

### Named this tick

- **Slot 322** is a per-class "killed by" hook: `CGObjPC::vslot_322`
  (`0x004e27c0`) routes to `FUN_004e1f60`, the per-death-kind social handler;
  `CGObjMob::vslot_322` (`0x004c1c30`) is the only other override, everything
  else sharing a stub at `0x00934da0`.
- `GObjPC::FUN_004909f0` is a GM stat dump, and it carries a **second tag
  dispatcher** -- `0x687261` `hra`, `0x68707267` `hprg`, `0x6870` `hp`,
  `0x6872` `hr` are all visible in it. A cheap place to extend the param-code
  vocabulary next, since the extraction method is already written and validated.

**No srrevamp value changed.**

## The skill parameter vocabulary, all 102 codes (2026-09-15)

The previous entry's recorded next lever was a second tag dispatcher, to be
extracted with the method already validated on `Stat_ApplyTaggedModifier`. A
census first — every function in the server binary holding three or more
multi-char-literal equality tests — found eleven, and the largest is not the one
that was flagged:

| function | tags |
|---|---|
| `SkillGlobal::RefSkill_ParseParams` | **105** |
| `CGameServer::FUN_0072fd40` | 51 |
| `Stat_ApplyTaggedModifier` | 46 |
| `GObjPC::FUN_004909f0` | 33 |
| `FUN_00491bd0` | 29 |

`RefSkill_ParseParams` is the skill `Params` decoder, and this project had read
exactly four of its codes. All 102 that resolve are now in
**`docs/protocol/skill_params.md`**, each with the skill-struct field it fills
and how far the cursor moves.

**Validated before it was asked anything new**, the same discipline that licensed
the `Stat_ApplyTaggedModifier` extraction: `att` → field `0x230`, 6 words;
`defp` → `0x25c`, 4; `defr` → `0x260`, 3. Three of three against independently
recovered answers. The run length **includes the code word**, which is what makes
`att`'s six-word run carry the five values already in use —
`(type, percent, min, max, percent)`.

### A fabricated structural claim, caught before publishing

The first extraction reported fifteen codes as "run 1, 0 values". That is
self-contradictory: the parser points a field at values a one-word run cannot
contain. They take a different branch shape —

	cursor = cursor + 1;      // skip only the code word
	skill[field] = cursor;    // values follow, count NOT encoded

— so the "1" was the cursor advance past the code, not a run length. The three
controls all use the other shape, so they passed while fifteen rows were wrong;
a control set only proves the shape it exercises. They are now listed separately
with no length claimed.

### Deliberately not shipped

`hwit` (field `0x588`) is read by the skill-effect applier `FUN_00594ac0` and
written to ParamKeeper param **195**, which given the client's own
`PARAM_HWAN_TIME_INCREASE` is most likely the berserk-duration bonus —
`berserk.Duration` being srrevamp's one explicitly unrecovered value. It is not
the base duration, though: it is a modifier srrevamp has no consumer for, and
the identification's last step is an inference from a name rather than a
use-site. Recorded, not wired.

**No srrevamp value changed.** The artifact is a decoder: srrevamp reads one of
these 102 codes today, and the next skill system that needs a second one no
longer has to re-derive the format.

## The Param decoder, tested against 36,389 real rows (2026-09-15)

The previous entry recovered the skill Param schema but never ran it against
data. Doing so tests the format and the shipped parser at once.

**The block starts at column 69**, measured: the `att` code appears there in
30,677 rows and never earlier. Walking from 69 with the recovered run lengths,
**19,839 of 36,389 rows consume their Param block exactly to the end** — and
that is a real test of the schema, because one wrong run length derails the rest
of a row. 19,839 clean traversals are 19,839 independent confirmations of every
length they touched. The rest stop at a variable-length code, as expected; the
commonest is `efr`, on 9,534 skills.

The true code frequencies, counted only at verified code positions, are now in
`docs/protocol/skill_params.md`. `att` leads on 31,266 skills and `mc` (field
`0x288`, run 3) is second on 28,142 — structural rather than incidental, and
still unidentified.

### The shipped parser: a defect looked for, and disproved

`cmd/export-refdata`'s `attackParam` scans the WHOLE ROW for the literal
`6386804` rather than walking the block. That is a textbook way to read another
parameter's VALUE as a code, and this file already records the stat-tag literals
colliding with the opcode range once before. Tested three ways:

- the lowest column the literal ever occupies is 69, so **0 of 31,605** rows
  carry it before the block;
- **no row carries it twice**, so "first match" cannot pick the wrong one;
- on the 19,839 cleanly-walked rows the walk's `att` position and the scan's
  first match **agree 19,839 times and differ 0 times**.

So the scan is correct, and it is also the more version-robust of the two — a
client whose skilldata shifted the block would break a hard-coded column 69 and
would not break this. The comment now carries the measurement instead of an
assumption.

### Two more of my own probes were wrong, and only impossible output caught them

Worth recording because it is a pattern rather than an incident.

1. To find the block's start I scored candidate columns by "clean walks". The
   scorer treated a walk that stopped immediately on an empty cell as clean, so
   it reported column **68** with 2,475/4,000 — almost all of them empty-at-68.
   The census built on it returned **zero rows**, which is what exposed it.
2. The real start is 69, one column over, found by simply asking where the
   literal occurs.

The general shape: a metric that cannot distinguish success from
immediate-failure will report failure as success. Both this and the previous
entry's "run 1, 0 values" were caught by an output that was obviously impossible
— an empty census, a run that cannot hold the values it points at — rather than
by the controls, which passed in both cases.

**No srrevamp value changed.** A shipped one is now measured rather than assumed.

## `mc` is a skill's HIT COUNT — and a shipped defect it uncovered (2026-09-15)

The previous entry left `mc` as the most-used unknown in the skill format: field
`0x288`, a three-word run, on 28,142 of 36,389 skills. It is the number of times
one cast strikes.

**Settled by a use-site, not by the name.** `Combat_ResolveDamage` (`0058e5f0`):

	*(record + 5) = 1;                        // default
	piVar12 = *(int **)(skill + 0x288);       // the 'mc' values
	if (piVar12 && *piVar12 == 2)
	    *(record + 5) = (char)piVar12[1];     // mc overrides it
	if (*(record + 5) == '\0') Assert();      // 0 is a bug state
	...
	*(record + 6) = 0;                        // the iteration counter
	do { ... *(record + 6) += 1; ... }
	while (i < *(byte *)(record + 5));        // line 1162

A loop bound, a counter, and an assert against zero. The loop body spans lines
317–1162 and **contains the damage-kind switch and the mitigation calls**, so
each iteration is an independent blow — its own damage roll, its own critical
and block rolls. That is why it is a count and not a multiplier: multiplying one
blow would give a different distribution.

The real table: 24,368 skills strike once, 3,855 twice, 265 three times, 59 four
and 6 five. 35 carry `(2, 0)`, which would trip the engine's own assert.

**A wrong turn worth recording.** The byte `mc` writes is at `+5` of its record,
and the damage-kind switch reads `+5` of *another* record. I briefly had `mc`
selecting the damage kind — wrong, and it would have contradicted the earlier
finding that case 0 is the ordinary attack. `FUN_005a9f20`, which allocates the
switch's record, explicitly sets its `+5 = 0`, so the two are different objects
and **case 0 really is the default damage kind**. A claim I had started to doubt
came back stronger. Three distinct records in this one function carry a
meaningful `+5`; conflating them is the trap.

### The defect: SQL deployments were silently dropping skill damage

Wiring the hit count through exposed something worse. The exporter emitted a
skill's real `AttackPercent`/`DamageMin`/`DamageMax` and the CSV loader parsed
them — but the **skills table had no columns for them**, `ImportSkills` never
wrote them and `GetSkill` never read them back.

So on any SQL deployment — the production path, `-in-memory` being the option —
every skill silently lost its recovered damage and fell back to the disclosed
per-level stand-in. Nothing errored; the numbers were quietly wrong. This is the
same shape as the `TwoHanded` column that shipped as a false claim, and the same
lesson: a value is not shipped until something reads it back out of the store it
will actually live in.

### What moved

- `refdata.Skill.HitCount` and `HitsFor()`, exported from the `'mc'` parameter.
- `attack_percent`, `damage_min`, `damage_max`, `hit_count` added to the skills
  schema, the upsert and both selects.
- `performAttack` takes a hit count and resolves that many independent blows.
- A round-trip test that fails against the old schema, and boundary tests for
  `HitsFor`.

A two-hit skill now does roughly twice the damage it did, which is the
correction rather than a buff: it was doing one hit's worth all along.

## Auditing for the silent-drop defect, systematically (2026-09-15)

The previous entry found a skill's real damage being dropped by the SQL store —
exported, parsed out of the CSV, then discarded because the table had no column
for it. Nothing errored. It was found **by accident**, while editing nearby
code, which is the worst way to find a whole class of defect.

So this tick audited the class instead of the instance: a reflective
field-by-field round trip that fills every field of `refdata.Item` and
`refdata.Skill` with a distinct non-zero value, imports it, reads it back, and
names every field that changed.

**It found four more, and they were worse.** `RestoreHP`, `RestoreHPPct`,
`RestoreMP` and `RestoreMPPct` — the potion restore amounts, real since the item
table's self-labelling Param block was decoded — had no columns either. And
unlike the skill damage, which degraded quietly to a disclosed stand-in, this
one breaks a feature outright: `session/useitem.go` guards with

	if it.RestoreHP <= 0 && it.RestoreMP <= 0 && it.RestoreHPPct <= 0 && it.RestoreMPPct <= 0 {
	    return fail("that cannot be used")
	}

so on any SQL deployment — the production path, `-in-memory` being the option —
**every potion answered "that cannot be used"**. A player-visible break that no
test covered, because every test that exercised potions used the in-memory
store, which keeps the struct whole by construction.

### What the audit is, and why distinct values matter

Filling every field with `1` would pass while two adjacent columns were swapped.
The audit gives each field a distinct value, and floats a fractional one so a
column typed `INTEGER` where `DOUBLE PRECISION` was meant truncates and fails
rather than passing by luck.

A second guard covers the step before the database: `Item` has 40 fields and
exactly 40 CSV columns, `Skill` 28 and 28, and the parsers index positionally,
so a field added without a column is dropped between the exporter and the
importer just as silently. The counts are now asserted equal.

### What moved

- `restore_hp`, `restore_hp_pct`, `restore_mp`, `restore_mp_pct` added to the
  items schema, the upsert and both selects. Potions work again on SQL.
- `roundtrip_test.go`: the field-by-field audit for both types, plus the CSV
  column-count guard. Both fail against the old schema.

### The lesson, stated so it is not re-learned

A value is not shipped when it is recovered, nor when it is exported. It is
shipped when something reads it back out of the store it will actually live in.
Three values had passed the first two gates and failed the third; two of them
for long enough to reach a tagged release.

## itemdata 114 and 117 are the variance ceilings — a withdrawal reversed (2026-09-15)

First, the audit from the previous entry was finished: `MonsterDrop` and
`DropGroupEntry` round-trip cleanly, and the character store's SELECT covers all
twelve `Character` fields. `Item` and `Skill` were the only leaks, and both are
fixed. The class is closed.

Then the open item this file has carried longest: columns 114 and 117, which
`export-refdata` emitted as literal `"0"` under a note saying they were
"something else, not yet identified".

**They are attack rate's and critical's per-instance variance ceilings**, and the
argument that withdrew them was wrong in its premise rather than its care.

That argument ran: a real max would display as a range the way physical attack
does (`"27 ~ 28"`), but the verified Copper Sword tooltip shows "Attack rate 24"
and "Critical 3" — single values. True, and it does not follow. Physical attack
displays as a range because its min and max are **two different stats**, at cols
95 and 97, each with its own `(lo, hi)` pair beside it. Attack rate is **one
stat**, and the column beside it is that stat's variance — so an instance has a
single value and shows a single number. The tooltip never discriminated between
the two readings.

**The engine settles it.** `FUN_00495d60` computes every item stat as
`lo + t*(hi-lo) + inc*plus` from a `(lo, hi, inc)` triple at consecutive
ref-object dwords. Two of those triples are

	(0x288, 0x28c, 0x290) -> item +0x1d8
	(0x294, 0x298, 0x29c) -> item +0x1dc

and `Char_PublishCombatStats` publishes item `+0x1d8` as ParamKeeper param 11
(`'hra'`, attack rate) and `+0x1dc` as param 12 (`'cri'`, critical). So each of
them *is* a lo/hi pair, and the tooltip value is the lo — which is what the
project already reads from cols 113 and 116.

**The data confirms the engine's own precondition.** `FUN_00495d60` asserts that
`lo > hi` cannot happen. Across all 1,568 rows carrying the block:

| pair | inversions | equal |
|---|---|---|
| col 113 vs 114 | **0** | 0 |
| col 116 vs 117 | **0** | 448 |

Zero inversions in either. Equality is permitted by the assert, which fires only
on `lo > hi`. Two unrelated stats sitting side by side would invert somewhere in
1,568 rows.

### What moved

`HitRateMax` and `CriticalMax` are exported again, from cols 114 and 117, and
`fMax` rises to 117 to match the highest column now read. The test that pinned
the zeros now pins the real values and asserts the floor never exceeds the
ceiling. `refdata.Item`'s "which end does srrevamp use" note carried the same
false claim — that the Max field "is not the same stat" — and is corrected.

Nothing changes how a blow is rolled: `attackerCritical` still takes
`CriticalMin`, and that is now visibly a **choice of end** rather than a
consequence of the other end being a different stat.

## Joining the two skill vocabularies: code → the stat it modifies (2026-09-15)

`docs/protocol/skill_params.md` had 102 codes and where each files its values,
but nothing about meaning — and the spec said so explicitly, warning that the
names are suggestive and a name is not a use-site. This closes half of that gap
mechanically rather than one code at a time.

`FUN_00594ac0`, the skill-effect applier, reads the same skill-struct fields the
parser fills and publishes ParamKeeper params from them. Extracting
field → `param@slot` and joining on the field gives **code → the stat it
modifies**, for 22 of the 102.

**Validated before the join was read**, against three pairs recovered
independently and long before:

| control | expected | extracted |
|---|---|---|
| `defp` | params 5/6 at slot 0, the flat absorb | `5@0, 6@0` |
| `defr` | params 5/6 at slot 1, a percentage on it | `5@1, 6@1` |
| `hwit` | param 195 | `195@0` |

Three of three, and the `defp`/`defr` slot difference is exactly the distinction
this file recorded when `playerMitigationPercent` was settled as a real zero —
one writes the flat term, the other a percentage boost to it.

The four that matter most, because they touch params already modelled:

- **`apau`** adds a flat amount to params 13–16, **`apru`** a percentage to the
  same four. Those are the physical and magical damage min/max — the params a
  weapon's range and the Strength-derived reinforce term already land in. A buff
  of either kind stacks into the same slot-0 sum or slot-1 percentage the damage
  pipeline reads, so the buff design is already determined by shipped work.
- **`stri`** publishes param 1, Strength itself.
- **`irgc`** publishes 25/26 at slot 1 — `'hprg'`/`'mprg'`, health and mana
  regeneration.

Only 22 codes publish a param. The other 80 act elsewhere — teleports, summons,
cures, state flags — and each needs its own field followed into whatever
consumes it. The join is not a shortcut around that; it is the subset where the
shortcut exists.

**Nothing wired, deliberately.** srrevamp has no buff system, and a value with
no consumer is the pattern this file keeps correcting. The table is recorded so
that a buff system, when it exists, starts from the game's own vocabulary.

**No srrevamp value changed.**

### A process note, because it is the second occurrence

The commit that added the spec section went out without this entry: the heredoc
writing it ran from `server/`, where `docs/RE_COMPLETION.md` does not exist, so
the redirect failed while the `git commit` in the same command list succeeded.
That is exactly the failure from two entries ago, repeated. `&&` between a
redirect and a commit does not couple them — the redirect's failure is reported
by the shell and the commit runs anyway. Write the ledger from the repo root, or
check `git show --stat` before pushing.

## Attack rate and parry are DEAD params (2026-09-15)

`combat.MitigateDamage` floors a blow at 1 rather than the game's 0, and the
note explaining why said: a zero-damage hit is a miss in the real game, and
srrevamp "has no hit/evade roll yet (the `'hra'`/`'era'` params exist and are
unimplemented)". That reads as a gap waiting to be filled, and it is the kind of
claim this file exists to check.

**There is no roll to implement.** Params 9 (`'era'`, parry rate) and 11
(`'hra'`, attack rate) are published from four different places —
`Char_PublishCombatStats` from the equipped item's aggregate,
`GObjMob_PublishStats` from characterdata, `GObjPC_InitStats` with a base of
10.0 (`.rdata 0x00b45b44`), and the skill codes `er`/`terd`/`thrd` — and then
read by **nothing**.

### How the negative was made safe

A literal-argument census is exactly the probe that has produced four false
negatives in this project, so it was not trusted on its own. Every `GetParam`
call site in the binary was enumerated, literal and computed:

- **Literal ids present:** 1–8, 10, 12, 23, 24, 27–32, 56, 57, 140–150, 169,
  172, 173, 178–181, 184, 187–193, 259. Neither 9 nor 11.
- **Computed ids**, each resolved rather than waved at: `FUN_0040db50` reads
  `(edi != 0) + 0xd` → 13/14; `FUN_0040dc10` reads `(edi != 0) + 0xf` → 15/16;
  `Formula_MitigatePhysicalDamage` and its twin read 0x80/0x81; `FUN_0040ebe0`
  and `FUN_0040eef0` read 0x80/0x81 and 0x82/0x83. None is 9 or 11.
- The remaining ~100 non-literal hits are a three-argument call on a
  **different class's** vtable slot `0x104`, in quest code — not GetParam.

That 13/14 are also absent from the literal list is what makes the census
trustworthy here: the probe demonstrably misses computed reads, which is why
every computed read was resolved before the absence was believed.

### What the engine rolls instead

`Combat_ResolveDamage` reads exactly four combat params through GetParam: 12
(`'cri'`) and 10 (`'bri'`) off the attacker and defender, opposed by 57
(`'evcr'`) and 56 (`'evbl'`). Blocking and critical — and nothing else. **A
swing is resolved as blocked or not, never as a miss.**

Both are already modelled here, and both are correctly unopposed against
monsters: `GObjMob_PublishStats` publishes params 0, 3–12, 23, 24, 27–33 and
140, so neither 56 nor 57 exists on a monster. That was already recorded for
`'evcr'` when criticals were shipped; it holds for `'evbl'` for the same reason.

### What moved

Nothing numeric. The floor stays 1 and stays own design — but its justification
changes from "a mechanic we have not built yet" to "a mechanic the game does not
have", which is the difference between a gap and a decision. `MitigateDamage`'s
comment carries the enumeration.

This also closes the last open question about the `'hra'`/`'era'` pair, which
this file has carried since the tag vocabulary was first read: they are real
columns, really published, and vestigial in this build.

## The damage pipeline is complete for an unbuffed character (2026-09-15)

The previous entry's enumeration of every `GetParam` call produced a by-product
worth acting on: the exact set of params the engine reads. Intersecting that
with what srrevamp models leaves the terms the damage pipeline applies and this
project omits — params **128–131, 178, 180, 187, 188, 189 and 259**, each a
multiplier or addend on every blow. If any is non-zero by default, srrevamp's
damage is wrong.

**None of them is written by any baseline publisher.** The three functions that
establish a character's stats write only these ids:

| function | params written |
|---|---|
| `Char_PublishCombatStats` | 0x5–0x10, 0x17/0x18, 0x21–0x25, 0x3a, 0x8d, 0xbe–0xc1 |
| `GObjMob_PublishStats` | 0x0, 0x3–0xc, 0x17/0x18, 0x1b–0x21, 0x8c |
| `GObjPC_InitStats` | 0x0–0x2, 0x9, 0xb, 0x17/0x18, 0x21–0x25, 0x34–0x3c, 0x8c/0x8d, 0xc2–0xc8 |

Not one of 0x80–0x83, 0xb2, 0xb4, 0xbb, 0xbc or 0x103 appears. Their writers are
`Stat_ApplyTaggedModifier` (the item/skill tag path), `FUN_00594ac0` (the
skill-effect applier) and `FUN_005830b0` — all modifier paths. 180 and 259 have
**no writer at all**.

So for a character with no buffs and no tagged item modifiers — which is every
character srrevamp has — all of those terms evaluate to zero, and **the damage
pipeline here is complete rather than approximate**. That is a closure, not a
new value: nothing changes, and now it is known that nothing should.

### An error caught mid-tick, and the trap that caused it

Param 189 (the berserk bonus) is the exception, and I nearly filed it wrongly.
The census showed its only writer is `CGObjCOS_Summoned::SetBodyMode`, which
reads as "a summon's function, so a player's 189 is always zero, so berserk is
exactly x2". That is wrong.

`0x004a9fc0` is **vtable slot 198 across seventeen classes**, `CGObjChar` among
them, and the binary's own base-class assert names it **`IGObj::SetBodyMode`**.
The dump indexes a shared implementation under a single derived class — whichever
the RTTI walk reached — and reading that label as the owner is a mistake that
will recur, because most of this binary's shared virtuals are indexed the same
way. **The RTTI line, not the function name, says which classes reach it.**

A player therefore can carry param 189, and the existing account was already
right: `SetBodyMode`'s fifth argument grants a base of 0.3, every call site bar
one passes 0, so 2.0 is the plain multiplier and 2.3 the special case.

### Also corrected

`berserk.go` called `0x004a9fc0` "CGObjChar::SetBerserk". That name was this
project's invention; the binary calls it `SetBodyMode`, and berserk is one body
mode rather than the whole function. Renamed in the citation, with the reason.

**No srrevamp value changed.**

## A naming defect measured, not just noticed (2026-09-15)

The previous entry caught one mislabel by accident: `0x004a9fc0` is indexed as
`CGObjCOS_Summoned::SetBodyMode`, but it is vtable slot 198 shared by seventeen
classes including `CGObjChar`, so reading the label as the owner made a player's
param 189 look unreachable. The question that leaves is how many more there are.

**48 in the server, 69 in the client.** Measured by
`client/tools/ghidra/mislabelled_owners.py`, which needs no Ghidra — the dump's
own headers carry both `RTTI: reached as A slot N, B slot N, …` and
`RTTI hierarchy: Derived : … : Base`, so a name that credits a class deriving
from another class in the same list is provably crediting a descendant of the
real owner.

The two populations differ in how much they matter:

- The server's **48 of 331** include real names —
  `CGObjCOS_Summoned::EnterWorld`, `::ConsumeHpMp`, `::GetCharName`,
  `::GetGender` are all shared `CGObjChar` implementations. Those are exactly
  the functions a dig into player logic would want, and its author would grep
  past them.
- The client's **69 of 93** are a worse *rate* but a milder defect: nearly all
  are a run of unnamed `CCompChar::FUN_*` methods that belong to
  `CCompoundObj`. A wrong namespace on an unnamed function costs attribution,
  not identity.

### Why this is not a rename

The most ancestral class in the RTTI list is a **lower bound** on the owner, not
the answer. `SetBodyMode` reaches `CGObjChar` in its list, while its own assert
names `IGObj` as the declaring class — so renaming to `CGObjChar::` would swap
one inaccuracy for a smaller one. The detector says "this name is wrong"; only
an assert string says what the name should be. Renaming 48 functions on that
basis, in a write pass that would take the project lock and could not be
validated in the same tick, is not worth it.

What ships is the measurement and the rule, so the next naming pass can apply it
and any reader can re-run it.

### The parsing traps, recorded because they cost the first two attempts

The first run reported **906**. Two flaws, both of which inflate:

1. The class is the component **before the method**. `std::bad_alloc::vslot_000`
   is class `bad_alloc`; taking the first `::` component makes it `std`, which
   then "derives" from everything.
2. A function whose RTTI lists **one** class cannot have this defect, and those
   rows are pure noise.

48 against 906 is a nineteen-fold difference between a measurement and an
artifact, and the only thing that exposed it was the output being obviously
wrong — `std::bad_alloc` is not a mislabelled game function. That is the same
shape as the last three probe failures in this file: the control passes, the
scale is absurd, and the absurdity is what catches it.

**No srrevamp value changed.**

## The drop path: wrong blocker, real gap (2026-09-15)

`combat.LootTables` is own design, and its note said why: the real drop tables
key by a numeric RefMonsterID "this project doesn't have a confirmed name->ID
mapping to". Chasing that mapping is what this tick set out to do, and it took
one lookup — **characterdata col 1 is the RefObjChar id and col 2 the code
name**, exactly the id/code-name pair this project already reads out of
itemdata. `MOB_CH_MANGNYANG` is **1933**.

So the stated blocker was never the blocker.

**The real one:** the drop tables are server-side DATABASE tables and are not in
the client archives at all. Media.pk2's `server_dep\silkroad\textdata` listing
carries characterdata, leveldata, levelgold, hwanleveldata, the
refabilitybyitemopt family and the rest — and no drop or rnd-drop table of any
kind. `_RefMonster_AssignedItemRndDrop` and `_RefDropItemGroup` live in the
server package's SQL, which this project does not have. Own design stays, for a
reason that is now the true one.

### The real gap, found while checking: the importer had no way in

`refdata` has had `LoadMonsterDropsCSV`, `LoadDropGroupEntriesCSV`,
`ImportMonsterDrops` and `ImportDropGroupEntries` since the schemas were
curated. **`cmd/import-refdata` exposed none of them.** An operator holding the
real tables — the exact situation the "bring your own data" model exists for —
had no way to load them.

Every piece had its own test and passed. The chain had a missing link in the one
place nothing tested, which is the same shape as the SQL columns that silently
dropped a skill's damage and every potion's restore amount. **A capability is not
shipped until something exercises it end to end.**

**What moved:** `-drops-csv` and `-drop-groups-csv` on `import-refdata`, and a
test that walks CSV text -> loader -> store -> read-back for both tables, keyed
on 1933 so the mapping above is exercised rather than just asserted.

### A dead end, recorded so it is not re-walked

`hwanleveldata.txt` looked like the place to ground `berserk.Duration`, which is
srrevamp's one openly unrecovered value, and to settle param 189 (the berserk
damage bonus — the only term the game applies to a blow that this project omits
and cannot prove is zero). It is neither. 257 rows of four columns, and the
columns are display keys: `UIO_SECOND_HWAN_CH_NAME_LEVEL_1` and so on. It names
hwan levels for the UI and carries no duration, no bonus, no number at all.

## A survey of what the client actually ships (2026-09-15)

The previous entry established that the drop tables are not in the client at
all. That raised the obvious question: what IS there, and how much of it is this
project leaving on the floor?

**The client's `server_dep\silkroad\textdata` holds 136 distinct tables. The
code opens 22 of them.**

	characterdata  itemdata  skilldata  leveldata  levelgold  npcpos  npcchat
	refshopgoods  refshopgroup  refshoptab  refmappingshopgroup
	refmappingshopwithtab  refscrapofpackageitem  regioninfo  skilleffect
	skillgroup  skillmasterydata  textdata_object  textquest_speechname
	textuisystem  worldmap_mapinfo  worldmapguidedata

The 114 untouched ones are the grounding roadmap. The substantial ones, by what
they would ground: `questdata` and `questcontentsdata` (quest.Catalog is own
design), `magicoption` and `magicoptionassign` (item blues, unmodelled),
`teleportdata`/`teleportlink`/`teleportbuilding`, `refsetitemgroup`,
`learnableskill`/`learnablemastery`, `erasableskill`/`erasablemastery` (the
skill-reset path whose 80% refund was recovered two entries ago),
`refpricepolicyofitem`, and the siege family.

**How the count was got right.** The first pass grepped each table's basename
across `.go`, `.gd` and `.md` and reported 96 of 136 "used" — nonsense, because
`refdata_schema.md` *lists* table names and because "aaa" matches almost any
file. Matching `[a-z_0-9&]+\.txt` literals in code only gives 22, which is
checkable by eye against what the readers actually open.

### The mastery table confirms a measured column map

`skillmasterydata.txt` is unusual: it **ships a header row naming every
column**. That is worth knowing because this project already derived its layout
by measurement on 2026-09-11, and the header agrees on all six constants —
`Mastery ID`→0, `MasteryNameCode`→2, `Tab Name Code`→5, `Type (TabID)`→6,
`Weapon Type 1`→8, `Mastery Icon`→11. An independent confirmation of shipped
work, at no cost.

Its 13 real masteries, for the record — the id, the UI name code, the tab, and
the weapon `TypeID4`s each trains:

| id | name code | tab | weapons |
|---|---|---|---|
| 257 | `UIIT_STT_MASTERY_VI` | Weapon | 2, 3 (sword, blade) |
| 258 | `UIIT_STT_MASTERY_HEUK` | Weapon | 4, 5 (spear, glaive) |
| 259 | `UIIT_STT_MASTERY_PA` | Weapon | 6 (bow) |
| 273–276 | `HAN`, `PUNG`, `HWA`, `GI` | Force | — |
| 513, 515 | `WARRIOR`, `ROG` | EU physical | 7/8/9, 11/12 |
| 514, 516 | `WIZARD`, `WARLOCK` | EU magical | 11, 10 |
| 517, 518 | `BARD`, `CLERIC` | EU assist | 14, 10 |

### Corrected

`client/scripts/npc/mastery_reader.gd` said the project has neither a mastery's
trained level nor a skill point total, "so the skill window shows the masteries
at level 0 and says so". Both are tracked now — `skill.Store.MasteryLevels` and
`SkillPoints`, carried by `OpSkillState`, raised through `OpRaiseMastery` — and
`hud_panels.gd` already renders the real SP and the mastery total against the
3-per-level cap. The comment described a window that no longer exists.

**No srrevamp value changed.**

## What the quest epic actually faces (2026-09-15)

`quest.Catalog` is own design and is the largest invented surface left with real
data present in the client, so the roadmap from the previous entry points here
first. This is reconnaissance, not a value: what follows is the shape of the
problem, measured.

### The tables

- **`questdata.txt` — 696 quests.** The registry: a numeric id, a code name
  (`QNO_CH_SMITH_1`), and the `SN_*` string codes for the quest's name, its
  reward text and its conditions. **No objectives, no rewards.**
- **`questcontentsdata.txt` — 989 rows × 17.** Descriptions and `SN_CON_` string
  codes. Also no objectives; most columns are the literal `xxx` placeholder.
- **`refqusetreward.txt` — 709 rows × 26** (the game's own filename carries the
  typo). Keyed by the same quest code name, with numeric columns at 10 and 11
  carrying values like 205/270, 475/375, 1000/2752.
- **`refquestrewarditems.txt` — 366 rows.** Quest code name → item code name and
  a quantity, several rows per quest where a choice is offered.

So **quest rewards are fully available as client data**; quest objectives are
not in any client table.

**Deliberately not named:** which of columns 10 and 11 is experience and which is
gold. The magnitudes are suggestive and that is exactly the evidence this file
does not accept — characterdata col 79 was wrong twice on a suggestive curve.
A use-site settles it, and none has been read.

### "Quests are compiled code" is false, and worth measuring before believing

The server carries 177 bespoke quest classes — `CQNO_*`, `CQSP_*`,
`CQTUTORIAL*`, `CQEVENT_*` — which invites the conclusion that quest logic is
hand-written C++ and therefore ungroundable. Matching them against the registry
(after stripping the leading `C`, which the class names carry and the table's
code names do not) gives:

| | count |
|---|---|
| quests in `questdata.txt` | 696 |
| bespoke quest classes | 177 |
| registry names WITH a class | **154** |
| registry names WITHOUT one | **542** |

**78% of quests have no bespoke class**, so they run on the generic engine this
file already has anchors for — `CRefQuest`, `CBasicQuest`, and the `sQuestContents`
objective struct. The blocker is locating that engine's objective source, not
transcribing 700 C++ classes.

### Where this leaves srrevamp

Its quests are own design with invented names, so nothing keys to the real
tables today. Adopting the real code names is the step that unlocks rewards
wholesale — 709 reward rows and 366 reward-item rows arrive keyed by a name the
registry already supplies. That is an epic, not a tick, and it now starts from
measurements rather than from the assumption that quests are code.

**No srrevamp value changed.**

## Quest rewards: structure found, the column question still refused (2026-09-15)

The previous entry left one bounded question: which of `refqusetreward`'s columns
10 and 11 is experience and which is gold. It is still unanswered, and this
records the path so the next attempt does not restart from the table.

**What was established:**

- `CRefQuestReward : CDBRecStream : CDBRecord : CBase`. It is a DB-record class,
  and `FUN_0083a640` registers `_RefQuestReward` as its SQL table name.
- **The `_CHAR` lever does not apply here.** `CharData_BindDBColumns` named 38
  character columns because it binds each one by name (`FUN_00401fc0(name,len)`
  then an offset). `FUN_0083a640` calls that once — for the table name — and
  binds no columns at all. The text row reaches the struct positionally through
  `CDBRecStream`, so the name→offset trick that worked for `_CHAR` has nothing
  to read.
- **`FUN_009287c0` is the reward payer.** It looks the record up by quest id
  (`FUN_0051cd30`), asserts `"Can not find QuestRewardData : QuestID [%d]"` when
  it is missing, and copies the record's `+8`, `+0xc`, `+0x10`, `+0x14`, `+0x18`
  dwords and `+4`, `+5`, `+0x38`, `+0x39` bytes into a queued reward object. The
  field from record `+0x14` is later accumulated across entries.
- The reward is **queued rather than paid inline**, so the experience and gold
  calls are in a different function, and following them is where the next
  attempt should start.

**What was not established, and is therefore not written down:** the identity of
columns 10 and 11. The magnitudes (205/270, 475/375, 1000/2752) read like exp
and gold, and two independent structures now sit either side of the gap — the
CSV columns on one side, the struct offsets on the other — without a mapping
between them. Guessing the join is exactly the move that made characterdata col
79 wrong twice.

A thin tick, honestly. The structure is worth having; the answer is not in it
yet.

**No srrevamp value changed.**

## Correcting my own exp enumeration (2026-09-15)

The previous entry said the reward is queued and the exp call is elsewhere, and
pointed at eight `CQNO_*::vslot_103` functions that an earlier entry had listed
among the binary's positive experience grants. Following them shows that list
was wrong.

**All eight are `IQuest` virtuals, not experience grants.** Each is
`__thiscall Foo::vslot_103(Foo *param_1, …)` calling
`(**(code **)(*param_1 + 0x170))(…)` — a call on `this`, and `this` is a quest:
`CQNO_RM_OLDWOMAN_6 : CBasicQuest : CQuestBase : IQuest`. Slot `0x170` is
`GObjPC_GainExpAndLevel` on a **character**; on a quest it is something else
entirely. The earlier census matched the offset across the dump without checking
what the receiver was.

**The load-bearing conclusion survives, because it never rested on that census.**
"No PvE experience reward exists in this binary" was established from
`charData+0x68` having exactly one writer — `GObjPC_GainExpAndLevel` — with the
only other function touching the field being a GM stat dump that formats it into
a string. That probe is independent of the call-site list and is unaffected. What
was wrong is the supporting enumeration's quest entries, not the finding.

**A sharper open question falls out of it.** Quests demonstrably pay experience —
`refqusetreward` carries 709 rows of reward values. If quest classes do not call
`GainExpAndLevel`, and `GObjPC_GiveExp`'s only three callers are the PC-death
handlers, then quest rewards reach the character through the queued-reward object
`FUN_009287c0` builds, and a central payer drains that queue. Finding that payer
answers both this and the column question the previous two entries left open.

### The rule, now written down where it will be read

Three separate wrong results in this project have the same cause: a vtable-slot
census that did not resolve the receiver's class.

| slot | on a character | elsewhere |
|---|---|---|
| `0x104` | `GetParam` | a three-argument virtual on quest classes |
| `0x318` | `SetBodyMode`, shared by 17 classes | indexed under one derived class |
| `0x170` | `GObjPC_GainExpAndLevel` | an `IQuest` virtual |

`client/tools/ghidra/README.md` now carries the check, strongest evidence first:
the receiver expression (a `__thiscall` on `param_1` is `this`), then the dump's
own `RTTI hierarchy:` line, and only last the enclosing namespace — which is
weak, because a `GObjPC` function may call a slot on a char it was handed, and a
shared virtual is indexed under just one of its classes.

**No srrevamp value changed.**

## Respawn is 40%, not full (2026-09-15)

Three ticks had gone into the quest-reward column question without converging,
on a table srrevamp does not read. Dropped it and audited the thing the tick
brief actually asks for instead: every value srrevamp uses, grounded or disclosed
with a proven reason. 263 constants, mostly opcodes and schema strings; the
gameplay numbers are a much shorter list, and `mana`'s comment pointed at a real
gap — "the real game has an `'mprg'` parameter … but its value has not been
recovered".

**Half of that is now settled, negatively.** Params 25/26 (`'hprg'`/`'mprg'`) are
written by no baseline publisher — not `GObjPC_InitStats`, not
`Char_PublishCombatStats`, not `GObjMob_PublishStats` — so they are zero without
a buff, exactly like the damage-pipeline terms. Baseline regeneration is not
param-driven, and looking for an `'mprg'` default is looking for something that
does not exist.

Following the HP/MP pair to its other readers found something better.

### The recovery

`CGObjPC::vslot_212` — the PC create/load path, identifiable by its own error
string `"CheckEquipsetIntegrity() failed while Creating PC (CharID : %d)"` —
calls `GObjPC::FUN_004e1120`, which restores a character whose **stored** pool is
zero, which is the state a death leaves it in:

	if (charData->vf[0x38]() == 0) {       // stored HP is zero
	    hp = GetParam(3) * _DAT_00b460f0;   // MaxHP * 0.4
	    charData->vf[0x40](hp);
	}
	if (charData->vf[0x3c]() == 0) {       // and the same for MP
	    mp = GetParam(4) * _DAT_00b460f0;
	    charData->vf[0x44](mp);
	}

**`FMUL QWORD PTR ds:0xb460f0`** at `0x004e1141` and `0x004e1190` — a QWORD, so
the double **0.4**. At float width that address reads `-1.08e-19`, which would
bring every character back on a negative sliver of health; only the double is
coherent. Operand size has now decided four constants in this project.

**It does not apply to a level-up.** Nothing in the level path zeroes the stored
pool, so the branch never fires there and a level-up heals to full. That is why
the two are separate calls rather than one shared helper.

### What moved

`character.RespawnFraction = 0.4`, `Store.RespawnHP` on both stores, and
`character.RespawnMP`. The death path in `session/combat.go` uses them; the
level-up path still calls `ResetHP` for the full heal. Dying now costs 60% of
the pool on the way back, where it used to cost nothing.

Tests pin the fraction, pin that a level-up still heals fully, and pin that the
SQL and in-memory stores agree — the same recovered rule, so a deployment
swapping one for the other must not change what a death costs.

## The mastery caps, and a number that was never this binary's (2026-09-15)

Continuing the constant audit that found the 40% respawn. `MasteryTotalCapPerLevel`
stood out because its citation was an account of retail rather than the binary,
and mastery raising is a shipped feature. `Mastery_LevelUp` (`0059c4e0`) carries
three rules, and only one of them was already in this project.

**Per-mastery, the character's own level — now grounded.** The function compares
`Char_GetLevel()` against the mastery's current level plus the levels requested
and answers error `0x3804` when the character is lower. srrevamp already
enforced this; it was asserted, and now it is cited.

**Per-mastery, a hard 120.** The cost loop refuses to go past it:

	do {
	    if (0x78 < uVar4) break;          // 0x78 = 120
	    entry = RefLevel_GetEntry();
	    cost += entry[0x10];              // leveldata column 2, already grounded
	    uVar4++;
	} while (uVar4 < current + requested);

srrevamp had no such ceiling. leveldata runs to **140**, so a character can
outgrow 120 and the cap binds rather than being theoretical. Shipped as
`MasteryLevelCap`, applied as the lower of it and the character's level.

**The total cap is a FLAT 330, not a per-level rule.** On the branch where the
ref object's `+0x88` is zero, it refuses when `current + requested >= 0x14b`,
with no reference to the character's level at all.

### Why that did not change anything

srrevamp caps the total at 3 x the character's level. The binary caps it at 330
flat. Those are different shapes, and it is worth being explicit about why the
sourced rule survives the encounter:

- **A tempting reconciliation was checked and failed.** 330 = 3 x 110, which
  would make the flat cap "3 per level evaluated at the level cap" and confirm
  srrevamp's rule outright. But leveldata runs to 140, not 110, and no level cap
  this project can find is 110. The neat story does not hold, so it is not told.
- This is a **modded private-server binary**; the per-level rule comes from an
  account of **retail**. Adopting a flat 330 on that basis would trade a sourced
  rule for a modded constant.

**A number was also dropped.** The comment said "the pserver's 440 is a mod".
Whatever 440 was, it is not what this binary enforces — 330 is — and a wrong
number in a citation is worse than no number, so it is gone.

### What moved

`session.MasteryLevelCap = 120`, wired into the raise handler and tested at the
boundary (level 120 binds at 120, level 121 and level 140 both bind at 120).
`MasteryTotalCapPerLevel` is unchanged, with the shape difference recorded
against it rather than silently reconciled.

## Five orbs are five real charges (2026-09-15)

Third pass of the constant audit. The berserk gauge was the largest remaining
cluster of own-design numbers with a live consumer — the HUD orbs and the R key —
and one of the four turns out to be the game's.

**`Orbs = 5` is recovered.** `_CHAR.RemainHwanCount` is a persisted count at
`charData+0x86`, from the schema `CharData_BindDBColumns` spells out, and
`CUsedItemLimit::FUN_004a05b0` refuses an item when it has reached five:

	return (-(uint)(*(char *)(charData + 0x86) != '\x05') & 0xffffe7c3) + 0x183e;

A branchless ternary, and worth evaluating rather than eyeballing: not-5 gives
**1** (allowed), 5 gives **0x183e** (refused). A use-limit that refuses at
exactly five is a cap of five, so the five pips the client draws are five real
charges rather than a display choice.

**The shape around it is still ours, and the engine's is different.** The game
persists a COUNT that an item can raise and a berserk presumably spends; this
project fills a 0..100 gauge from combat. Those are different mechanics that
agree on the number five. Nothing found so far says how the real count is
earned, so `FillPerHit` stays own design rather than being dressed up as a fill
rate for a gauge the game does not have — and the test deliberately pins only
`Orbs`, because asserting an invented number makes it harder to replace later.

### Two audited and closed as unrecoverable

- **`inventory.SlotsPerCharacter`.** `_CHAR.InventorySize` is real and
  per-character, but nothing in the binary writes `charData+0xac` — the eight
  apparent hits are offset collisions on unrelated structs. Character creation
  is DB-side here, the same finding this project already reached for starting
  Str/Int, so a new character's default slot count is a database default and not
  in this executable.
- **`mana`'s regeneration rate**, half-settled. Its comment hoped for an
  `'mprg'` default; params 25 and 26 are written by no baseline publisher
  (`InitStats`, `Char_PublishCombatStats`, `GObjMob_PublishStats` write none of
  them), so they are zero without a buff and baseline regeneration is not
  param-driven at all. What ticks it is still unfound; the number stays own
  design, but the search for an `'mprg'` default can stop.

**What moved:** `berserk.Orbs`'s citation, from a display assumption to the cap
the engine enforces, with the shape difference recorded beside it.

## Two constants closed as unrecoverable, and one coincidence declined (2026-09-15)

Fourth pass of the constant audit. Both candidates this time end as disclosures
rather than groundings — which is the honest result, and in one case only
because a very plausible number was turned down.

### `party.MaxSize`: the 8 is in the wrong module

Party membership is a **linked list with no fixed bound** —
`CGObjPC::FUN_005bdd70` walks it to fill the party-info packet — so the cap is
enforced at join time and is not visible in the structure.

The party module's neighbourhood does contain two loops bounded at **8**, over
an array at `[x+4] + 0x1c + i*4`: one a membership test, one a broadcast. Eight
is exactly the party size Silkroad is usually said to have, and taking it would
have been easy.

It is declined. Both loops sit in `CMainProcess` functions that call
**`CGuild__BroadcastToLocalMember`**, in a shard ending at `0x5b9370` — *before*
the `CParty` code, which starts at `0x5bb300`. A Silkroad guild alliance holds
eight guilds, and an eight-slot array in guild-broadcast code is far more likely
that than a party roster. **A loop bound that lands on the expected number in
the wrong module is a coincidence, not a citation** — this is the same shape as
characterdata col 79, which was wrong twice for looking right.

### `character.MaxPerAccount`: not in this binary, and neither is its category

`SR_GameServer.exe` has no character-creation path at all — no limit string, no
count check. It cannot have one: creation happens on the AgentServer and in the
database.

That closes a **category** rather than a value, and the category is already
half-documented in this file:

| value | why it is not here |
|---|---|
| starting Str/Int | nothing writes `charData+0x74`/`+0x76` anywhere |
| default `InventorySize` | nothing writes `charData+0xac` (the hits are offset collisions) |
| `MaxPerAccount` | no creation path, no limit string |

Anything decided when a character is first made is outside this executable. Worth
stating once so the next audit does not spend a tick rediscovering it per value.

**What moved:** nothing numeric. Both constants keep their values and gain the
reason they cannot be grounded, which is what the brief asks for when a value
cannot be cited.

## The HP/MP write pipeline, and why potions need no modifier (2026-09-15)

Chasing `mana`'s still-ungrounded regeneration rate from the other end: instead
of looking for a tick, enumerate everything in the binary that can change a
character's pool. `charData`'s setters are virtuals at `vf[0x40]` (HP) and
`vf[0x44]` (MP), and they have **two callers each**, which makes the whole
pipeline small enough to map:

	GObjChar::FUN_004a66f0 / FUN_004a6790   the setters themselves
	GObjPC::FUN_004a87d0                   the generic adjust -- reads current
	                                       via vf[0x108]/[0x10c] and max via
	                                       vf[0x110]/[0x114], then writes
	GObjPC::FUN_004a86a0                   the RECOVERY path, scaling first
	CGObjChar::vslot_317 / vslot_318       effect application
	GObjPC::FUN_004e1120                   the load/respawn restore (the 40%)

**Passive regeneration is not on this list**, so it is still unlocated — but the
recovery path yielded something better than the number I went looking for.

### Potions: an unmodified heal, confirmed

`FUN_004a86a0` does not hand a recovery straight to the pool. It scales the HP
amount by ParamKeeper param **143** and the MP amount by **144** — `MOV EAX,0x8f`
and `MOV EAX,0x90` into `EvaluateParam`, both against the character's own keeper
at `+0x1ec` — before passing them on.

**Both params are structurally zero.** Neither has a `SetParam` site anywhere in
the binary, and neither is the target of a derived bind. So a
recovery-effectiveness stat exists in the engine and nothing in this build ever
grants one, which means the raw restore amount is what lands — exactly what
`session/useitem.go` already does.

That is a confirmation of a shipped value rather than a change, and it is the
third time this session that enumerating a param's writers has turned "srrevamp
omits a term" into "the term is provably zero" (after the damage-pipeline
multipliers and the death-penalty reduction).

**The probe was controlled.** A "no writers" result from the same search that
produced four false negatives earlier in this project is worth nothing on its
own, so it was run against param `0x22` — the weapon reinforce, known to be
written — and found it in two shards. The absence for 143/144 is a result, not a
broken search.

**What moved:** nothing numeric. `useitem.go`'s heal gains the citation that it
is unmodified because the modifier is always zero, not because the modifier was
overlooked.

## Passive regeneration does not exist, and "unwritten means zero" was wrong (2026-09-15)

Two results, the second of which matters more than the one I set out to get.

**1. There is no passive HP/MP regeneration in the server binary.** Closed as a
negative, and this time by an enumeration rather than a search that gave up.

A character's pool is written through exactly two clamped setters, and they name
their own source file: `GObjChar_SetCurHP` (`0x004a66f0`) and
`GObjChar_SetCurMP` (`0x004a6790`) assert with
`d:\work2005\source\silkroadonline\server\sr_gameserver\GObjChar.h` line `0x16c`
and the format `"CLAMP() ==> min(%.3f) exceeded max(%.3f) value)"`. Disassembling
the whole PE (`objdump -d -M intel`, 2.5M lines in 2s) and counting gives **4**
calls to the HP setter, **2** to the MP setter, **4** to the generic
`GObjPC_AdjustHpMp` they funnel through, and — the part that makes it an
enumeration rather than a sample — **zero address-taken references** to any of
the three, so none is ever reached through a vtable or a function pointer. Every
writer is on the list, and every one has now been read:

| Writer | What it is |
|---|---|
| `GObjPC_AdjustHpMp` `004a87d0` | the generic adjust: HP in EAX, MP in arg 2, notify mask OR'd into `pc+0xa0e` |
| `GObjPC_RecoverHpMp` `004a86a0` | potions and heal skills (params 143/144) |
| `CGObjCOS_Summoned::ConsumeHpMp` | summon upkeep |
| `CGObjChar::vslot_317` / `vslot_318` | effect application — 318 passes HP=0, so it is MP-only |
| `CGObjPC_PublishHpMp` `004e6330` | clamp, then send the update packet (bit 0 HP, bit 1 MP, bit 2 defers) |
| `GObjPC_OnEffectExpired` `005829d0` | re-clamp when an expiring buff takes MaxHP/MaxMP away |
| `FUN_00634020` | siege-structure removal |
| `GObjPC_RestorePoolOnLoad` `004e1120` | login/respawn seed at `GetParam(3)*0.4` — writes charData directly, because at load there is no current value to clamp against |

Not one is driven by a clock. Healing in this game is an **event** — a potion, a
skill, a respawn — never a tick. `'hprg'`/`'mprg'` (params 25/26) are real but
are not a resting rate: all seven writes of them come from skill effects and
every one targets slot 1 (additive percent) or slot 3, never slot 0. They modify
a regeneration the server itself never performs.

`mana.RegenPercentPerTick`/`RegenInterval` therefore stay own design, and the
comment now says so with the enumeration rather than with a hope that `'mprg'`
was still out there to be read.

**2. The correction, which came out of checking the probe.** I nearly shipped
the argument "slot 0 is never written for 25/26, and the formula multiplies by
slot 0, so the result is zero." Reading `ParamKeeper_EvaluateParam` instead of
assuming it killed that: when slot 0 holds no entries the base falls back to a
per-param **default** at `+0x28`, and when no slot has entries the result *is*
the default. The read path forces it — `FUN_004b3740` calls
`ParamKeeper_EnsureParam` first, which creates the param from a descriptor
record `(min, max, default)` fetched from a map keyed by param id and asserts if
the id is missing; the values arrive as `fild [ecx+4/8/0xc/0x10]`, integers from
a record built at runtime.

So **"nothing writes param N, therefore N is zero" is not a valid recovery**, and
this codebase used it three times. Fixed:

- `leveldata.DeathPenaltyReductionPercent` — still 0, but now disclosed as
  srrevamp's own choice for a server with no premium accounts, not as a value
  read out of the binary. What the binary proves is that param 257 is
  premium-only (`CTJ_PremiumKeeper::vslot_012` is its sole writer).
- `berserk`'s damage-completeness note — params 128-131, 178, 180, 187, 188, 259
  are proven **unmodified** for an unbuffed character, not proven zero.
- `combat.MitigateDamage`'s params 9/11 argument is **unaffected**: it is a
  read-side census, and a param nothing reads cannot matter whatever its default.

The defaults themselves are runtime data and are not recoverable from
`SR_GameServer.exe` — a new entry on the unrecoverable list, alongside drop
tables and character-creation defaults.

**Naming.** Seven functions and six vtable slots gained real names in
`ApplyKnownNames.java`, so they survive the next dump rebuild:
`GObjChar_SetCurHP`, `GObjChar_SetCurMP`, `GObjPC_AdjustHpMp`,
`GObjPC_RecoverHpMp`, `CGObjPC_PublishHpMp`, `GObjPC_OnEffectExpired`,
`GObjPC_RestorePoolOnLoad`; and by use, `vf[0x104]` = `GetParam`,
`vf[0x108]` = GetCurHP, `vf[0x10c]` = GetCurMP, `vf[0x110]` = GetMaxHP,
`vf[0x114]` = GetMaxMP, charData `vf[0x40]`/`vf[0x44]` = the HP/MP stores.

**A probe note worth keeping.** The param-id annotation pass covers **writes
only** — 278 annotated `SetParam` sites, **zero** reads. Any census of "who uses
param N" built on those comments is a write census wearing a use census's
clothes, which is how the slot-0 argument looked convincing. The read side goes
through `vf[0x104]`, and a literal-argument grep there finds real sites but must
not be trusted as complete either: of 113 apparent "computed id" sites, most are
three-argument calls to a *different* method at the same offset on another
receiver class. Slot meaning depends on the receiver — again.

**What moved:** nothing numeric. Two overreaching claims became accurate ones, a
long-open question closed as a proven negative, and thirteen names landed.
