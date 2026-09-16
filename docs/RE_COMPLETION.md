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

> **SUPERSEDED — read the amendment below together with the registry recovery
> that followed it the same day (`docs/protocol/param_registry.md`). The
> mechanism described here is correct; the closing claim that the defaults are
> "not in the binary" is WRONG. They are a static table at VA `0x00c64110`, and
> reading it restored every inference this amendment had retracted.**
>
> **AMENDED 2026-09-15 — the formula above is right but incomplete, and the
> missing piece changes how an unwritten param must be reasoned about.**
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
> **Consequence**: "nothing writes param N, therefore N is zero" is not valid on
> its own — the default has to be read before the conclusion follows. It now
> has been, for all 120 params, and the conclusion does follow for every id this
> project relies on. `combat.MitigateDamage`'s params 9/11 argument never
> depended on it either way, being a READ-side census (a param nothing reads
> cannot matter whatever its default).

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

## The ParamKeeper registry, recovered whole — and yesterday's correction corrected (2026-09-15)

Last tick I retracted the inference "nothing writes param N, therefore N is
zero", on the grounds that an unwritten param falls back to a descriptor default
and that those defaults were runtime data, not in the binary. The mechanism was
right. **The claim that the defaults are unrecoverable was wrong, and this tick
found them.**

**The find.** There is exactly **one** `CParam` allocation site in the whole
binary, inside `ParamKeeper_EnsureParam`, and it runs only when the param id is
present in a global map. So if that map were empty the entire stat system would
be dead — which is what my own probe appeared to show, because grepping for the
map's address literals found a constructor, a clear and three lookups but no
insert. The insert exists; it reaches the map through registers and touches only
the size word, so an address-literal grep could not see it. `0xcd3118` found it
in one line: `add DWORD PTR ds:0xcd3118,0x1`.

From there it unwound: the insert's sole caller is `map::operator[]`, whose sole
caller is `CMainProcess::ParamRegistry_Register` (`0x004b3960`) — a plain loop
over a **static table at VA `0x00c64110`**, 20-byte records terminated by id
`0xFFFF`:

```c
struct ParamDesc { uint16 id; uint16 pad; int32 min, max, default, flag; };
```

**120 params, ids 0-259 with gaps.** Read out of the PE and written up in full at
`docs/protocol/param_registry.md`.

**Two checks that the layout is right**, neither of them tuned for: param 0 comes
out `min=1, max=140` — the level cap, matching `leveldata`'s own 140 — and the
magnitudes sort by kind on their own, HP/MP capping at ~INT_MAX, the percentage
stats (`bri`, `cri`, `hprg`, `mprg`, `evbl`, `evcr`) at 100, the rate stats
(`era`, `hra`) at 65535.

**What it settles.** Only **7 of 120** params have a non-zero default, every one
of them `100`: ids 34, 35, 36, 37, 50, 51, 140. Everything else defaults to **0**
— including every id this project reasons about. So the retracted inferences are
restored, this time on data:

- `leveldata.DeathPenaltyReductionPercent` — param 257 defaults to 0, so a
  non-premium character takes the full penalty. **Recovered, not chosen.**
- `berserk`'s damage-completeness note — 128-131, 178, 180, 187, 188 and 259 all
  default to 0, so an unbuffed character's damage pipeline really is complete.
- `mana` — `'hprg'`/`'mprg'` default to 0, so the engine's resting regeneration
  rate is zero. That agrees with yesterday's independent result that no pool
  writer is timer-driven: both halves say the same thing.

**A validation lever, which is the durable part.** The registry is the
authoritative list of param ids that can exist — an id absent from it asserts in
`EnsureParam`, creates nothing, and then faults in `Param_GetValue`, which has no
null check. Ids **61-127, 142, 151-168, 201, 203-255** are unregistered, so any
future "recovered" param id landing there is wrong by construction. Every param
id this project has previously recovered — 2, 3, 4, 9-17, 25-32, 52, 53, 56, 57,
128-131, 140, 141, 143, 144, 174-177, 178-189, 190-193, 256-259 — validates
against the registered set.

**Three probe failures in one tick**, all the same shape and all caught before
they became claims: a caller list that missed three callers, an "empty map" that
was an incomplete grep, and yesterday's "unrecoverable" that was an unfinished
search. The rule earned its place again — when a negative comes back, check the
probe, and prefer a probe that would fail loudly over one that returns nothing.

**Naming.** `ParamRegistry_Register`, `Param_Init`, `ParamKeeper_EnsureParam`,
`ParamKeeper_ReadParam` and `Param_GetValue` added to `ApplyKnownNames.java`.

**What moved:** nothing numeric — `DeathPenaltyReductionPercent` was already 0.
What changed is its standing: three constants went from *disclosed own design*
back to *recovered with a citation*, which is the direction this project is
supposed to move in.

## The stat-tag vocabulary, extracted in full (2026-09-15)

With the param registry recovered last tick (120 ids, each with min/max/default)
the obvious next lever was the other half of the vocabulary: which *tag* writes
which id. `Stat_ApplyTaggedModifier` (`0x00498690`) is the id→name table the
binary lacks as data — each branch pushes into a specific param and slot — and
this project had ~19 entries off it, read by hand.

Extracted systematically instead: **53 tags, 31 resolved, 7 proven dead**, in
`docs/protocol/param_tags.md`.

**Why two passes were needed.** The annotation pass that seeds
`/* ParamKeeper param id: EDI .. */` comments only resolves ids at a direct
`SetParam` call. **34 of the 53 tags** reach their param through a shared tail
(`LAB_00498adf`) with the id left in `EDI` — invisible to it, and rendered as a
bare `goto` in the decompiled C. Disassembly dataflow over each branch, tracking
`mov edi, imm`, resolves 12 more.

**The control ran first**, against the 19 known tags: 17 reproduced exactly. Both
discrepancies were informative rather than fatal, which is the point of running
a control at all:

- **`drua` came back as 128, 129, 130, 131** against a recorded 128, 129, 130.
  The use-site settles it — after three `SetParam`s the branch does
  `mov edi,0x83; jmp 0x498adf`, and the tail performs a fourth write. **The
  recorded entry was incomplete**, hidden behind exactly the `goto` this pass
  exists to see through. `berserk`'s note already said "128-131", so nothing
  shipped was wrong; the memory was.
- **`hp` came back empty** — it returns immediately after its single write and
  the walker lost it. Already known and confirmed in the decompiled C.

**What it newly settles:**

- **Param 1 is Strength.** Four tags write it (`str`, `stra`, `strj`, `strv`) and
  the dispatcher's own fall-through tail is `mov edi,0x1`. Independent
  corroboration of the stat graph, where health runs `Str(1) -> 52 -> 54 -> MaxHP(3)`.
- **Params 27-32 are the six status-effect resistances**: `fz` 27, *(28)*, `es`
  29, `bu` 30, `ps` 31, `zb` 32, with `rals` writing all six at once. Id 28 is
  only ever written as half of a pair (`mov edi,0x1b` beside
  `mov [esp+0x24],0x1c`), so its own tag was not isolated. The client names three
  of them: `PARAM_FZ` "Freezing", `PARAM_PS` "Poisoning", `PARAM_ZB` "Zombie".
- **`umdu` writes 259** — one of the damage-pipeline params established as
  unwritten for an ordinary character. Consistent rather than contradictory:
  `umdu` is a buff tag, so only a buffed character carries it.
- **Seven tags are DEAD** — recognised by the dispatcher, returning without
  touching a param: `er`, `atha`, `rep`, `astr`, `dura`, `luck`, `soli`. Since
  the dispatcher *is* the modifier path, a tag it ignores has no effect on
  stats. Note `luck` is dead even though the client ships `PARAM_LUCK` = "Lucky"
  and displays it — but the separate tag `luca` is live, so this is a statement
  about the tag, not about the stat.

**Cross-validation, which is the part worth keeping.** Every one of the 31
resolved ids is present in the param registry recovered last tick. Those two
artifacts came from completely different evidence — a static data table read out
of the PE at `0x00c64110`, versus dataflow through a dispatcher's branches — so
their agreement is a real check rather than a restatement.

Also named `AvatarBless_TagList` (`0x00508170`), which builds the 12 tags an
avatar item's blessing can carry and pairs with the `AVT <tag> +%d%%` strings.

**15 tags remain unresolved**: `ape`, `duru`, `hr`, `inta`, `intj`, `luca`,
`mdia`, `nrep`, `rcsi`, `rdii`, `rein`, `reis`, `rfei`, `rsli`, `rsti`. They
reach a param through read-modify-write paths this pass does not follow. Do not
guess them from the abbreviation — the client's `PARAM_*` keys have already
corrected this project twice.

**What moved:** nothing numeric; srrevamp models neither luck nor status
resistances, and `berserk`'s 128-131 was already right. The vocabulary went from
19 hand-read entries to 31 resolved plus 7 proven-dead, with a registry
cross-check behind it.

## The stat-write surface is 28 functions, and last tick's "dead tags" was too strong (2026-09-15)

Started by joining the skill param codes to the tag vocabulary recovered last
tick, on the theory that the two are partly the same language. They barely
overlap — but the first overlap found was `dura`, which last tick's table listed
as a **dead tag** and which `skill_params.md` shows on **1,979 skills**. A tag
carried by two thousand skills is not dead, so the claim needed checking rather
than extending.

**What the check established.** Enumerating every `ParamKeeper_SetParam` caller
gives **28 functions**, and exactly **one** of them is dispatched on a tag:
`Stat_ApplyTaggedModifier`. The other 27 are structural — `GObjPC_InitStats`,
`Char_PublishCombatStats`, `GObjMob_PublishStats`, `GObjPC_SetLevel`,
`GObjPC_SpendStatPoints`, `CTJ_PremiumKeeper::vslot_008`/`012`,
`CTJ_CharParamKeeper`, the mob, siege and mercenary paths, and the effect
apply/expire pair. **So a tag that the dispatcher ignores does not become a param
anywhere.** That half of last tick's claim survives, and is now enumerated rather
than asserted.

**What was wrong.** The published wording was that the dispatcher "**is** the
modifier path, so a tag it ignores has no effect on a character's stats", and it
called the seven tags DEAD. All seven are in fact recognised in five other
files — the description builders (`CGameServer::FUN_0072e2d0` and neighbours,
working in `LPCSTR`/`PCNZCH`, which produce the `AVT <tag> +%d%%` strings), the
enchant system (`CEnchant_EnchantAttrStone`), and `CGItemEquip`. **None of those
files contains a single `SetParam` call**, which is why they sit comfortably
beside the enumeration — but it means the tags are live code, not dead strings.

Corrected in `docs/protocol/param_tags.md` to the narrow claim the evidence
supports: **these seven are not character-stat modifiers.** What they are
instead is left unrecovered. `dura` reads like a duration and `rep` like a
repeat, but nothing in this pass settles either, and guessing a tag from its
abbreviation has already cost this project two wrong answers (`era` is parry,
not evasion; `hra` is attack rate, not hit rate).

**Recovered on the way**, from reading the unnamed half of those 28 writers:

- **`COS_ApplyHalfCombatScale`** (`0x004d60a0`) — sets slot 3, the percent scale
  that compounds from 100, to **50.0** across the entire combat block at once
  (params 5, 6, 9, 11, 13, 14, 15, 16) and flushes the keeper. The constant is
  `fld DWORD ds:0xb4603c` — a float32, checked for operand size — so it halves
  damage bounds, defence, parry rate and attack rate. Reached only from
  `CGObjCOS_GoldPet::vslot_215` and `vslot_211` (one call, one tail-`jmp`, no
  address-taken references), so it is **the gold pet's combat penalty**, not a
  general scale. srrevamp has no pet system, so this is recorded rather than
  wired.
- **`Effect_NegateDaraFamily`** (`0x004aaf80`) — dispatches on the four-character
  code `0x44414252` (`DABR` big-endian) and negates the value into params
  174-177 at slot 2, the same family the `dara` tag writes; `FUN_004ab060`
  removes the four again. The mechanics are recovered; what the code denotes is
  not, and is not guessed.

**What moved:** nothing numeric — srrevamp models neither pets nor the `dara`
family. One published claim narrowed from "these tags are dead" to "these tags
are not stat modifiers", with a 28-function enumeration behind the half that
held. The skill-code/stat-tag join that prompted all this turned out to be
nearly empty, which is itself worth recording so it is not retried.

## Naming coverage measured, and the item type-id widths recovered (2026-09-15)

**Coverage, computed from the dump index rather than by running Ghidra** (instant,
and it does not contend with the 15-minute cron): of the server's **34,113**
functions, **7,386 are named (21.7%)** and 26,727 are still `FUN_`. Of the
unnamed, 54% at least carry a class attribution (`Class::FUN_...`); 12,244 are
bare with no class at all, and those are mostly CRT and template code.

Biggest unnamed clusters by bytes: `CGameServer` (3,674 fns), `GObjPC` (2,906),
`CMainProcess` (1,376), `CGameWorldLayer` (545), `MapLoader` (260), `CNetEngine`
(273), `ReferenceData` (114).

**`ReferenceData` was the right target**, being small, bounded, and the layer
srrevamp actually ships against. Harvesting **assert strings across the whole
namespace in one pass** found 32 unnamed functions carrying string anchors, and
the anchors are the game's own error text, variable names and `ReferenceData.cpp`
line numbers — so the names can say what the code demonstrably does instead of
guessing an original identifier. Nine named this tick, covering the magic-option
validators, the item package checks, the shop price/sellable path and the
teleport loader.

### The type-id widths, and a value grounded

`ReferenceData::RefItem_ReadTypeIDs` (`0x006a8090`) deserialises an item's five
type bytes and bounds-checks each against a named constant, asserting with the
game's own file and line:

| assert | fires when | constant | width |
|---|---|---|---|
| `btCash < MAX_CASHITEM_TID_COUNT` | `1 < btCash` | **2** | 1 bit |
| `btType1 < MAX_TID1_COUNT` | `7 < btType1` | **8** | 3 bits |
| `btType2 < MAX_TID2_COUNT` | `3 < btType2` | **4** | 2 bits |
| `btType3 < MAX_TID3_COUNT` | `0xf < btType3` | **16** | 4 bits |
| `btType4 < MAX_TID4_COUNT` | `0x1f < btType4` | **32** | 5 bits |

`ReferenceData.cpp:2466-2470`. Each assert fires on `limit-1 < value`, so the
constant is one past the largest legal value.

**Wired into `internal/equipment`** as `MaxCashItemTID`, `MaxTID1..MaxTID4`, with
`TestTypeIDsAreWithinRecoveredBounds` holding every declared family and piece
constant inside them. Every value this project already used validates — the
largest family is `FamilyEuropeHeavy` 11 against a 16 ceiling, the largest piece
`PieceBoots` 6 against 32 — so nothing changed numerically. What the bounds add
is a guard: TypeID3 being four bits wide means a family id of 30 is a typo rather
than an undiscovered armour set, and such a constant would otherwise silently
match no item at all. The test also checks each bound is a power of two, since
each is one past a fixed-width field's maximum.

The engine's own check is an assert, not a rejection, so these are not used to
gate anything at runtime; that is recorded in the constant's comment so a later
reader does not turn them into validation the game never performed.

**What moved:** nothing numeric. Five recovered constants gained citations,
srrevamp's existing type-id constants gained a bounds test, nine `ReferenceData`
functions gained evidence-backed names, and naming coverage is now a measured
21.7% rather than an impression.

## The kill-reward path: damage share, and a 3%-per-member party exp bonus (2026-09-15)

Followed the source-path lever from last tick. Binary-wide it is nearly spent —
only 156 functions carry a `WORK2005` path and 68 of those are still `FUN_` — but
two of the files it names sit on srrevamp's critical path: **`Formulae.cpp`** (3
functions, 2 unnamed) and **`RefItemDrop.cpp`**. Took `Formulae` first.

Both unnamed functions are kill-reward formulas, and following their callers
opened the whole path:

	COS_DistributeKillReward (004d68c0)
	  pass 1: accumulate each contributor's damage into entry+0x18
	  pass 2: for each PC contributor -> vtable slot 420, with
	          (accumulated damage, party multiplier)
	GObjPC_ReceiveKillReward (004ea6a0, slot 420)
	  -> Formula_ExpRewardForContributor (00410110)
	  -> Formula_ExpShareByDamage        (004106b0)
	  -> GObjPC_DistributePartyExp       (004fcb00)

**The share is by accumulated damage, and the use-site settled it.** The obvious
misreading was that the share is the *last blow* — which would cut a solo
killer's exp by whatever fraction the final hit was, a tenfold difference. It is
not: `add DWORD PTR [eax+0x18],edx` in the first pass is an accumulator, and the
second pass passes `entry[6]` (that same field) per contributor. So
`share = clamp(accumulatedDamage / victimMaxHP, 1e-6, 1.0)`, and a solo killer's
share is exactly 1.0. The lower bound is an epsilon (`fld DWORD ds:0xb45c84` =
1e-06f), not a minimum-contribution rule. `vf[0x110]` being MaxHP came free from
the pool work two ticks ago.

### VALUE SHIPPED: the party exp bonus

`COS_DistributeKillReward` builds the multiplier immediately before each award:

	4d6bb9  FLD1                          <- starts at 1.0
	4d6bcd  CMP  DWORD [EDI+0x1cb8],0     <- pc[0x72e], the party field
	4d6bd4  JE   ...                      <- no party: stays 1.0
	4d6bd9  CALL 0x4ea230                 <- member count
	4d6bde  SUB  EAX,1                    <- members - 1
	4d6be9  FMUL QWORD ds:0xb45dc8        <- * 0.03
	4d6bef  FADD QWORD ds:0xb45ac0        <- + 1.0

**Party exp bonus = 1.0 + (members - 1) x 0.03** — 3% per extra member.

Both constants are `QWORD`, so **doubles**: 0.03 and 1.0. Read as float32 the
first is -3.7e19. The operand-size rule earned its keep again, and Ghidra had in
fact rendered both as `(float)` in the decompiled C, which would have produced
garbage.

Wired through as `leveldata.PartyExpBonusPerMember` / `PartyExpBonus(members)`,
applied in `session.applyPartyExpBonus` on the kill-reward path, with `parties`
threaded into `CombatHandler`, `UseSkillHandler` and `performAttack`. Two tests:
`leveldata.TestPartyExpBonus` pins the multiplier (and that it is monotonic and
never a penalty), `session.TestApplyPartyExpBonus` covers the wiring and the
three "no bonus" shapes — no hub, no party, party of one — which are all the
engine's own `FLD1` default.

**SCOPE, stated because the engine does more than srrevamp now does.** The real
server scales each contributor by its damage share *and* distributes to party
members through `GObjPC_DistributePartyExp`. srrevamp awards the whole unit to
the killer. For the killer that is exactly right — a solo contributor's share
clamps to 1.0, so the bonus alone reproduces the engine's number for that
character. What srrevamp still does not do is give the other members anything;
that is a separate missing feature, recorded in the constant's comment rather
than papered over.

**Also opened:** `killer+0x1cdc` is the multiplier `Formula_ExpShareByDamage`
applies (`unaff_EBX[0x737]` is the same field), which sits beside the long-open
`killer+0x1cd8`. Both are per-killer exp multipliers; neither is written by
anything srrevamp models, so they stay open rather than guessed.

**What moved:** a real value, shipped. Party kills now pay what the engine pays.

## How the engine actually rolls a drop (2026-09-15)

`RefItemDrop.cpp` was the other file the source-path lever named on srrevamp's
critical path. Drop *tables* are still server-side database tables absent from
every client archive — that closure stands — but the **drop ALGORITHM is in the
binary**, and it turns out srrevamp's imported `MonsterDrop`/`DropGroupEntry`
rows were being interpreted wrongly in two ways. Neither field had a use-site
behind it; both were named from the column and left at that.

### The assigned-drop roll

`CRefDropData__AddAssignedItemDrop` (`0x00724a00`, named from its own assert)
walks the monster ref object's assigned-drop vector — 0x30-byte records at
`refObj+0x28c` — and for each record with a non-zero group id at +0:

```c
count = rand() % (max - min + 1) + min       // BYTES at record+6, +7
for (i = 0; i < count; i++) {                // `} while (uVar5 < local_4)`
    if (resultList full) break;
    roll = (rand()<<15 | rand()) % 1000000;  // mov ecx,0xf4240
    if (roll <= dropRatio * 1000000.0)       // fld DWORD [rec+8] ; fmul QWORD 0xb45bc0
        produce one item from the group;
}
```

**Two corrections fall out, and both change behaviour rather than wording:**

1. **`DropAmountMin/Max` is an ATTEMPT COUNT, not a stack size.** The engine
   picks a count in that range and then rolls `DropRatio` **independently for
   each attempt**. A row of 1..3 at 10% yields nothing most kills and three items
   rarely — a binomial, not "roll once then choose a quantity". The two models
   agree only when `DropRatio` is 1.0.
2. **`DropRatio` is a probability FRACTION in [0, 1]**, compared against a
   per-million roll. Two `rand()` calls are combined because MSVC's `rand()`
   yields 15 bits. The scale `0xb45bc0` is `QWORD` — a **double**, 1000000.0 —
   while the ratio itself is `fld DWORD`, a float32; the usual operand-size
   split, in one expression.

### The group pick

`RefItemDrop_RollGroupDrop` (`0x00724e30`) selects within a group by
**cumulative** weight on the identical per-million scale: it accumulates
`round(selectRatio * 1000000)` (a float32 at entry+0x24) and takes the first
entry whose running total reaches the roll. That the same scale drives both is
what establishes the two ratios as fractions on one common scale rather than two
differently-encoded numbers. A group whose ratios do not sum to 1 genuinely
selects nothing sometimes — a real outcome, not an error.

### What shipped

`refdata.RollAssignedDrop` and `refdata.SelectFromGroup` implement the above
exactly, with `DropRollScale = 1000000` as a named recovered constant, and the
struct comments now carry the semantics instead of the column names. The tests
are written to separate the two mechanics rather than merely exercise one:
`TestRollAssignedDropIsPerAttempt` runs 3 attempts at ratio 0.5 and asserts a
zero-yield rate near **0.125**, because a roll-once model would give **0.5** —
so a regression to the wrong mechanic fails loudly instead of drifting.

**What did NOT move, stated plainly.** `combat.LootTables` is still own design
and still what a kill actually rolls. Two things block the real path and neither
is a value to recover: an operator must bring the tables, and `combat.Monster`
carries `CodeName` but no numeric `RefObjID`, which is the key those tables use.
What changed is that the machinery to consume that data faithfully now exists
and is tested, so the remaining gap is data and plumbing rather than
understanding.

**What moved:** no shipped number, but two field semantics went from unexamined
to recovered — and one of them (`DropAmountMin/Max`) was being read in a way
that would have produced visibly wrong drop rates the moment real data arrived.

## Monster rank scales SPEED, not experience — and offset 0x1cd8 is three fields (2026-09-15)

Went after the long-open `killer+0x1cd8` / `+0x1cdc` pair, which last tick's
exp-share work had put back in view. The tick nearly produced a wrong shipped
value, and the thing that stopped it was insisting on the consuming use-site.

**The near-miss.** `CGObjMob::FUN_004c1550` is a clean four-way table:

| rank (`mob[0x1cd8] & 0xf`) | multiplier |
|---|---|
| 1 | **1.5** |
| 4 | **3.0** |
| 6 | **1.7** |
| 0, 3, 5, 7, 8 | 1.0 |

and the rank byte is copied from `refObj+0x50`. The domain 0-8 matches
characterdata column 15's rarity values exactly (0 normal, 1 champion, 3/8
unique, 4 giant, 5 titan, 6 elite), and the obvious next sentence writes itself:
*champions give 1.5x experience, giants 3x*. srrevamp already carries `Rarity`,
so it would have shipped.

**It is not an experience multiplier.** `CGObjMob::vslot_215` is what consumes
it, and it multiplies the mob's two movement fields (`+0x16c`, `+0x170`) and
publishes both into the ParamKeeper — `mov edi,0x17` then `mov edi,0x18`, i.e.
params **23 and 24**, which `Char_PublishCombatStats` had already established as
the MOVEMENT pair. So the rank multiplier is a **movement-speed scale**:
champions and giants move faster. Nothing about experience. srrevamp does not
model monster movement speed at all, so there is nothing to ship — which is a
far better outcome than shipping a 3x exp bonus that the game does not give.

**Offset 0x1cd8 means three different things by receiver class**, which is what
made the exp reading tempting in the first place:

- `CGObjMob` — the rank BYTE (with the float multiplier at +0x1cdc)
- `CGObjSiegeStruct` / COS — an integer timer (the writes are `0x1d4c0` = 120000
  and `0x124f80` = 1200000, i.e. 2 and 20 minutes)
- `CGObjPC` — a **float**, and this is the one `Formula_MonsterExpReward` reads
  (`fld DWORD PTR [edi+0x1cd8]`)

That is the fourth time this project has been caught by a per-class offset, and
the first time the check was run *before* the claim rather than after.

### What the PC's term actually is

`GObjPC_RecalcLevelDiffExpScale` (`0x004e30d0`) is its only float writer:

```c
ref = FUN_0059e870(pc + 0xa30);                 // a byte, from a list walk
if (ref > 0x78) { pc[0x1cd8] = pc[0x1cdc] = 1.0f; return; }
pc[0x1cd8] = clamp(1 - (charLevel - ref) * 0.1, 0.1, 1.9);
pc[0x1cdc] =        1 - (ref - charLevel) * 0.1;
```

K is `fmul QWORD ds:0xb45ec0` = **0.1, a double**; the clamp bounds are 0.1 and
1.9. It is recomputed on exactly three events — `CGObjPC::vslot_212` (PC load),
`GObjPC_SetLevel`, and `Mastery_LevelUp`.

**What the reference byte denotes is NOT recovered, and is deliberately not
guessed.** Recomputation on mastery level-up, and `0x78` being exactly 120 — the
mastery cap this project already recovered — both fit the reference being the
character's highest mastery level, which would make this the familiar "mastery
lagging your level costs you experience" rule. That is two coincidences and no
use-site, which is precisely the shape of reasoning that produced the wrong
answer for characterdata column 79 twice. It stays a hypothesis, written down as
one in `leveldata.go` beside the formula.

**What moved:** no shipped number. A live multiplier on a shipped formula went
from an unexamined field to a bounded, characterised term with its recompute
triggers known, and a tempting 3x experience bonus was correctly *not* shipped.

## The mastery-lag experience penalty, settled by a use-site (2026-09-16)

Last tick characterised the float at `pc+0x1cd8` that `Formula_MonsterExpReward`
multiplies every kill by, and **explicitly refused to name its reference byte**:
two coincidences pointed at "highest mastery level" — recomputation on
`Mastery_LevelUp`, and `0x78` being exactly the recovered single-mastery cap of
120 — but that is the shape of reasoning that got characterdata column 79 wrong
twice, so it was written down as a hypothesis. This tick settled it properly.

**The use-site that settled it.** `FUN_0059e870` walks a list under `pc+0xa30`
and returns the **maximum** byte at `entry[0x10][8]+0x20`, skipping entries whose
`[0x10]+0xc` is 3. Its neighbour `FUN_0059e7c0` walks the **identical** list with
the identical skip rule and identical value path, but **sums** instead — and
`Mastery_LevelUp` calls it and compares `that sum + the levels requested`
against its total-mastery cap:

```asm
59c569  CALL 0x59e7c0            <- the sum
59c570  MOVZX EAX,BYTE [EBP+0xc] <- levels requested
59c574  ADD  ECX,EAX
59c57e  FCOMP QWORD ds:0xb46130  <- against 240.0
```

A function whose result is the quantity a *mastery cap* is checked against is
summing mastery levels. Its twin over the same list is therefore the highest
mastery level. Named `Mastery_SumLevels` and `Mastery_MaxLevel`.

A third, independent corroboration: `CMainProcess_RollByEffectiveLevel`
(`0x0060c4b0`) takes `max(characterLevel, Mastery_MaxLevel())`, which only makes
sense if the two are on the same scale.

### VALUE SHIPPED: the mastery penalty

```
expScale = clamp(1 - (charLevel - maxMasteryLevel) * 0.1, 0.1, 1.9)
         = 1.0 when maxMasteryLevel > 120
```

K is `fmul QWORD ds:0xb45ec0` = **0.1, a double**; the clamp bounds are the
floats at `0xb45eb8` (0.1) and `0xb45f18` (1.9). Shipped as
`leveldata.MasteryExpScale`, applied in `session.applyMasteryExpScale` on the
kill-reward path ahead of the party bonus.

**SCOPE, and it is a sharp one.** The engine does **not** special-case a
character with no mastery — the only escape is a reference above 120, which no
real character reaches. So a level-10 character who has never raised a mastery
really does fall to the 0.1 floor, and that is the mechanic rather than an
oversight. srrevamp now reproduces it. The one place this implementation
deliberately departs from the engine is a lookup FAILURE: the engine always has
the number to hand, so a store error here returns the award unscaled rather than
charging the player 90% of a kill for srrevamp's own problem.

**Also found, and NOT promoted.** `Mastery_LevelUp` carries **two** total-cap
shapes: the flat `0x14b` (331) this project already recorded, and a second
branch comparing against the double **240.0** at `0xb46130` alongside a term
involving twice the character level. Which branch runs depends on a selector
this pass did not identify, and the `2 x level` term's operand was not pinned
down, so `session.MasteryTotalCapPerLevel` is left at its sourced 3 rather than
changed on a half-read branch. Recorded as open.

**What moved:** a real mechanic, shipped — and a hypothesis that was correctly
refused last tick became a citation this tick by finding the use-site rather
than by growing more confident about the coincidences.

## The mastery cap is three rules, not one (2026-09-16)

Closing out the open item left by the mastery-penalty tick: `Mastery_LevelUp`
was recorded as enforcing "a FLAT total of 330", and a second branch comparing
against 240.0 had been spotted but not read. It is neither one rule nor two —
there are **three**, selected by a byte at `(charData+0x18)+0x88`:

| selector | total-mastery rule |
|---|---|
| **0** | refuses when `sum + requested >= 0x14b` — a flat **330**, with no level term at all |
| **1** | allows only when `total <= 240.0` **and** `total <= level + level` |
| **2** | no total cap whatsoever |
| other | error `0x3801` |

240.0 is the double at `0xb46130`, compared with `FCOMP QWORD`; the level term is
literally `level + level`, i.e. **2 x** the character level, not 3.

**And a rule srrevamp already had, now cited rather than assumed.** Past the cap
branch, `Mastery_LevelUp` applies a per-mastery check and refuses with error
`0x3804` when `characterLevel < currentMasteryLevel + levelsRequested`. So a
single mastery may never exceed the character's level — which is exactly the
`levelCap := owned.Level` bound `session` already enforced on the strength of a
plain assertion. That comment now carries the citation.

The full error vocabulary: `0x3801` bad mastery or selector, `0x3802`
insufficient skill points, `0x3803`, `0x3804` exceeds character level, `0x3805`
total cap.

**`MasteryTotalCapPerLevel` stays at its sourced 3.** None of the three branches
is `3 * characterLevel`, so the sourced retail rule and this binary's rules are
still genuinely different shapes — but the note in `skill.go` now records all
three instead of one, which is materially better information for whoever revisits
the decision. Worth flagging one coincidence for that future reader: selector 1
saturates at **240**, which is exactly the level-80 total the retail account
reports, reached by a different route (`min(240, 2 x 80)` is 160, so the two do
NOT agree at level 80 — the 240 matches only as a ceiling, not as the binding
constraint there).

**The selector is NOT identified, and deliberately so.** It is read from the same
field that a skill's own `+0xc4` is compared against (`funcs_550.c:309`) and that
indexes a small table at `DAT_00c8262c` (`funcs_550.c:372`), both of which fit it
being the character's race/country — China/Europe being exactly the kind of split
that would carry different mastery rules. That is a shape argument with no
use-site behind it, which is the reasoning that was wrong twice on characterdata
column 79 and was correctly refused two ticks ago on this very field's neighbour.
It stays open.

**What moved:** no value. One shipped rule gained a citation, one recorded rule
turned out to be a third of the real rule, and the remaining unknown is now a
single named byte rather than a vague branch.

## 28 skill codes joined to what they actually do (2026-09-16)

The largest item on the open list was "80 of 102 skill codes unidentified". The
codes' *field offsets* were recovered long ago; what was missing is what the
engine does with each field. A code's meaning is settled by whoever READS it, so
the lever is a reader census rather than reading codes one at a time.

**The census.** Grepping every function in the server dump for reads of the 87
known skill-field offsets, and ranking by how many DISTINCT code fields each
touches, puts one function far ahead of everything except the parser:

	RefSkill_ParseParams          87   (the parser, by construction)
	Skill_ApplyEffectsToParams    34   <- the lever
	Combat_ResolveDamage          28
	FUN_00589d20                  24
	FUN_00589f10                  16
	FUN_00593f50                  12   (cura, curt, heal, rcur, resu, rmut, tran)

`Skill_ApplyEffectsToParams` (`0x00594ac0`, now named) reads a skill's parsed
fields and pushes them into the target's ParamKeeper — the applier whose teardown
is the already-named `GObjPC_OnEffectExpired`. Because the dump annotates each
`SetParam` with its param id, pairing each skill-field read with the ids written
within the next 14 lines produces a **code → param** join for 28 codes. The full
table is in `docs/protocol/skill_params.md`.

**The controls ran first, and this is the part that makes the join trustworthy.**
Six rows were already established by entirely independent means and all six
reproduce exactly: `irgc` → 25, 26; `er` → 9; `hr` → 11; `stri` → 1; `mpi` → 4;
and `dru` → 128, 129, 130, **131**.

Two rows are worth singling out because each confirms an earlier *correction*
rather than merely agreeing with a fact:

- **`dru` → four params.** When the tag vocabulary was extracted, a by-hand read
  of the decompiled C had recorded `drua` as writing three params and missed the
  fourth behind a `goto`; the disassembly caught it. This join, built from a
  completely different function by a completely different method, independently
  lands on four.
- **`luck` → 173.** `luck` is one of the seven tags `Stat_ApplyTaggedModifier`
  recognises and ignores. An earlier version of `param_tags.md` called those
  tags DEAD and said a tag the dispatcher ignores "has no effect on a
  character's stats"; that had to be narrowed to "not a character-stat
  modifier". Here is the skill code `luck` writing param 173 — the narrowing was
  necessary, and the original wording would now be provably wrong.

**Readable straight off the param registry**: `apau`/`apru`/`tpad` move the damage
bounds (13-16), `defr`/`pmdp` the defences (5, 6, 7), `hst3`/`hste` the movement
pair (23, 24), `er`/`terd` parry and `hr`/`thrd` attack rate, `reat` the block
145-150.

**Limits, written into the doc rather than left implied.** This is a proximity
join: six rows are controlled, the rest rest on the same mechanism and the same
14-line window. A row is good evidence about which params a code touches and is
NOT a claim about the code's full semantics — duration, stacking and targeting
are not in it. It also covers only the codes this one function handles; the
combat-side and cure/resurrect codes are untouched.

**What moved:** no value. srrevamp models skill damage but no stat buffs, so none
of this is wired — it is the vocabulary for when that changes, and it took the
unidentified-code count from 80 down to 52.

## The combat-side skill codes, and a correction to last tick's census (2026-09-16)

Continued last tick's reader census into `Combat_ResolveDamage`, which had come
second at 28 distinct skill-field offsets. **The headline number turned out to be
an artefact of the method, and that is the more useful finding.**

Twenty of those 28 codes appear exactly once each, all inside one
`== 0 && ... == 0` chain spanning about twenty lines: a single composite guard
asking whether the skill carries any effect field at all before taking the
plain-attack path. A code named in that guard is tested for presence, not acted
on. **Ranking functions by distinct offsets read therefore over-counts anything
carrying a large null-guard**, and the fix is to weight by reads per code. By
that measure the function really acts on `att` (15 reads), `da` (12), `tant` and
`tnt2` (5), `ck` and `dtnt` (4), `kb`, `lfst`, `pdmg` (3).

This does not undermine last tick's join: `Skill_ApplyEffectsToParams` was
validated by six independent controls, not by its offset count. But the count is
what selected it, and the same count would have pointed somewhere useless if the
guard had been bigger.

**Two codes identified.**

- **`da` is a conditional damage percentage.** When the skill carries `da` and
  the target's `vf[0xfc]()` is 8, both damage fields are scaled by
  `da[0] / 100`. It scales BOTH (`+0x24` and `+0x28`), not one. What kind 8
  denotes is not recovered — `vf[0xfc]` is compared across the whole binary
  against only 0, 8 and 11 — so this is "a bonus against one specific target
  kind" and deliberately no more than that.
- **`kb` is knockback.** Gated on four conditions simultaneously (the skill
  carries `kb`; the attacker's ref object has bit 1 at `+0x258`; the result byte
  is not already 4; and `GObjPC::FUN_005a1a20()` passes), it sets the hit-result
  byte to **5** and does position arithmetic from `kb[1]`, copying both
  coordinate triples.

**A near-miss, recorded because it is the same class of error as the guard
chain.** Five instructions before the `kb` branch sits `x / 1000.0 + 0.5` — both
constants `QWORD`, so doubles — which reads exactly like a knockback duration in
seconds and would have been a tidy result. It belongs to the preceding block, not
to `kb`, and is left unattributed. Proximity inside one function is no more
evidence than proximity inside one expression.

**What moved:** no value — srrevamp has neither a target-kind concept for `da`
nor a knockback result for `kb`. Two more codes identified (52 -> 50 unknown),
and the census tool gained a documented failure mode before it could mislead a
later pass.

## VALUE SHIPPED: chance rolls are not memoryless (2026-09-16)

`combat.RollChance` carried a disclosure saying the engine "also keeps a
per-actor accumulator... reproducing it needs per-actor state this project does
not carry". That blocker stopped being true a while ago — the package grew
`berserk.Tracker` and `mana.Tracker` — so the note was describing an obstacle
that had dissolved. This tick implemented it.

**The mechanism**, from `Chance_RollWithBadLuckProtection` (`0x00599cc0`),
reached from `Combat_ResolveDamage` through `GObjPC_RollChanceForActor`:

```c
if (chance == 0)   return false;      // no roll, no state touched
if (chance >= 100) return true;       // likewise
roll = rand() % 101;
entry = find(container, key);
if (entry) {
    if (entry.acc < roll) { entry.acc += chance;       return false; }
                            entry.acc += chance - 100; return true;
}
if (chance < roll) { insert(key, chance*2);       return false; }
                     insert(key, chance*2 - 100); return true;
```

The two seeds look like special cases and are not: `chance*2` and
`chance*2 - 100` are exactly what the update rule produces from a starting value
of `chance`, so the whole function is **one** rule:

	succeed when acc >= rand()%101, acc starting at chance
	then acc += chance        on failure
	     acc += chance - 100  on success

That is bad-luck protection. Each failure raises the effective chance by the
base chance; each success spends 100 of it. **The long-run rate is unchanged** —
the accumulator gains exactly `chance` per roll and loses exactly 100 per
success — while long dry streaks get progressively more likely to break.

**Scoping, and what is grounded versus what is not.** The accumulator lives in a
map keyed by `(objectId & 0xFFFFFF) | tag<<24`, built at the call site as
`and ecx,0xffffff` then `or ecx,<tag>000000`. Seven distinct tags appear, six of
them ASCII: `B`, `C`, `D`, `E`, `H`, `M`. So the engine keeps separate
accumulators **per actor and per kind of roll** — that separation is recovered,
and srrevamp now reproduces it. Only one tag has a use-site: the `0x43` ('C')
call inside `Combat_ResolveDamage`. The other letters are NOT identified, so the
Go constants are named for what they gate (`ChanceCritical`, `ChanceBlock`)
rather than for letters this project cannot pin, and `ChanceBlock` says so.

**Shipped** as `combat.ChanceTracker` / `RollChanceTracked` / `ChanceMemory`,
threaded through `ResolveBlow` and its four call sites. The block roll is the
DEFENDER's and the critical roll the ATTACKER's, so a blow draws on two
different actors' streaks. A nil memory falls back to the memoryless
`RollChance` exactly, which is what every test asserting an exact blow relies
on. A monster's streak is dropped when it dies, since the engine's accumulator
lives on the object and cannot outlive one.

The test that matters asserts **both halves at once**: over 400k rolls at 20%,
the tracked long-run rate must match the memoryless rate to within 1%, and the
longest dry streak must be strictly shorter. Checking only the rate would pass
an accumulator that did nothing; checking only the streaks would pass one that
inflated the chance.

**Two things caught before they shipped.** A comment claimed `Hub.Despawn` calls
`Forget` — there is no `Despawn`; the claim was written from expectation rather
than from the code, and was replaced with the real cleanup point (monster death)
plus an honest note that monster and character ids share the key space and can
collide harmlessly.

**What moved:** a real mechanic, shipped, and a disclosure that had outlived its
own blocker.

## VALUE SHIPPED: the server's own gain-rate knobs (2026-09-16)

Set out to recover `berserk.Duration`, whose disclosure said the timer "is
genuinely not recovered" because every caller of the body-mode setter passes
0/0xff. Searching the *clear* side instead led to the Hwan reference table
(`_REFHWANLEVEL`, loaded into a vector at `DAT_00d6aa14 + 0x8d0`) and, via the
string `HwanGainFactor` sitting in `.rdata`, to something better: a block of
**server configuration knobs** with their defaults and ceilings.

`CMainProcess_LoadGainRates` (`0x00427050`) reads them at startup. Every knob has
the same three-step shape:

```c
value = atol(setting) / 100.0;   // the setting is a PERCENTAGE
if (value <  1.0) value = 1.0;   // the branch that logs "<knob>: system default"
if (value >= cap) value = cap;   // a per-knob ceiling
```

| knob | global | cap | source of the cap |
|---|---|---|---|
| `ExpRatio` | `0xc82518` | **2.5** | `0xb45b90` |
| `ExpRatioParty` | `0xc8251c` | **2.5** | `0xb45b90` |
| `DropItemRatio` | `0xc82520` | **3.0** | `0xb45b84` |
| `DropGoldAmountCoef` | `0xc82524` | **2.5** | `0xb45b90` |
| `HwanGainFactor` | `0xc82528` | **10.0** | `0xb45b44` |

All caps are `fld DWORD`, so float32.

**Two findings inside that are worth stating on their own.**

1. **A rate below 1x cannot be expressed.** The `< 1.0` branch is not input
   validation, it is the branch that logs "system default" — so the engine has
   no way to configure a server slower than retail, and neither does srrevamp
   now.
2. **The default is 1x, confirmed twice.** The `< 1.0` fallback sets it, and
   independently the globals are statically initialised to `0x3f800000` (1.0f)
   before any setting is read.

**The exp knobs are alternatives, not factors.** `GObjPC_ReceiveKillReward` does
`fVar1 = ExpRatio; if (pc[0x72e] != 0) fVar1 = ExpRatioParty;` — `pc[0x72e]`
being the party field recovered earlier — so a partied character takes the party
knob *instead of*, not *as well as*, the solo one. Multiplying them would have
been the natural implementation and would have been wrong; there is a test that
fails if anyone does.

**Shipped** as `internal/rates`, read from the environment under the game's own
knob names, applied to a kill's experience (choosing by party membership) and to
its gold. `DropItemRatio` and `HwanGainFactor` are carried with their caps but
applied to nothing, because srrevamp's loot table and berserk gauge are still own
design — recorded rather than quietly hooked to the wrong thing.

**What did NOT move.** `berserk.Duration` is still own design; the Hwan table is
real and `hwanleveldata.txt` is in Media.pk2's server_dep listing, so the
duration is plausibly a column in it, but no gameplay reader of the table's
entry fields was found and no column layout was recovered. The disclosure is
updated from "genuinely not recovered" to name the table that probably holds it.

**What moved:** four real constants and a parse rule, shipped, from a search that
set out after something else entirely.

## Berserk has no timer, and that is now proven rather than unfound (2026-09-16)

Last tick left this as "blocked on one more read". The read is done, and the
answer is a negative with a mechanism behind it — which is the difference
between a closure and a failed search.

The old disclosure said the duration was "genuinely not recovered" because every
caller of the body-mode setter passes `0xff/0`. **That was not even accurate:**
two of the eleven call sites pass a real state-change slot and a real float. The
earlier pass had generalised from a sample.

**The mechanism.** `IGObj::SetBodyMode` can carry a duration:

```c
if (param_3 != 0xff && 0.0 < param_4)
    *(float *)(state + 0x10) = param_4;
```

so a body mode gets a timed life only when the state-change slot is real and the
float is positive.

**Berserk is body mode 1.** `Combat_ResolveDamage` reads `IGObj_GetBodyMode`
(vtable slot 64, now named) and sets the berserk damage flag on `== 1` — the same
byte at `(*(this+0x30))+3` that `SetBodyMode` writes. That ties the mode number
to berserk through the damage path rather than by assumption.

**The enumeration.** All eleven call sites were read, including the two whose
arguments Ghidra lost — one copies another object's mode and passes `0xff,0,0`;
the other sets up `local_74 = {.., 2, 0xff}`, mode 2 with no timer. Exactly two
carry a duration, and **both pass body mode 2, not 1**. Every mode-1 and every
variable-mode site passes `0xff`, the value that skips the timer branch.

So the engine has a body-mode timer, uses it for another mode, and does not use
it for berserk. How a real berserk ends is therefore not a duration this project
failed to find — it is a different shape. `_CHAR.RemainHwanCount`, the persisted
charge count already recovered beside `Orbs`, is the obvious candidate: a berserk
spends a charge rather than running a clock. **Not promoted** — no use-site.

`berserk.Duration` stays 20 seconds and stays own design, now with the same kind
of proven reason `mana`'s regeneration rate carries.

**A dead end worth recording so nobody repeats it.** The Hwan reference table
`_REFHWANLEVEL` / `CRefHWANLevel` is real, its record is 0x30 bytes, and
`hwanleveldata.txt` ships in Media.pk2's server_dep — all of which made it look
like the place a duration would live. It is not: the server loads the table and
uses only its SIZE, to bounds-check the level `IGObj::UpdateHwanLevel` will
accept. No gameplay path reads its entries at all.

**What moved:** no value. One disclosure went from "not recovered" to a proven
negative, one inaccurate claim in it was corrected, and a promising-looking table
is now marked as a dead end for this question.

## CORRECTION: berserk DOES have a timer, and it is 60 (2026-09-16)

**The previous entry in this ledger is wrong and is retracted.** It concluded
"berserk has no timer, and that is now proven rather than unfound", with a
mechanism and an enumeration behind it. The mechanism was right. The enumeration
was not, and the way it failed is the one this project keeps relearning.

**How it failed.** The enumeration grepped the DECOMPILED dump for call sites of
`SetBodyMode` and found eleven, none of which passed body mode 1 with a
duration. But the berserk activation handler lives at about `0x00515bfd`, in a
region **Ghidra never recovered as a function** — so it is absent from the dump
entirely. "All eleven call sites" was all eleven *decompiled* call sites. The
disassembly has a twelfth, and it is the only one that mattered.

That is the same lesson as the caller list that missed three callers and the map
that looked empty: **a census over the dump is a census over what Ghidra
recovered**, not over the binary. The dump's 34,113 functions are not all of it.

### What the activation handler actually does

```
if (GetBodyMode() == 1)        -> error 3        // already berserk
if (charData[0x86] < 5)        -> error 1        // not enough charges
GObjPC_AdjustHwanCount(-5)                       // SPEND ALL FIVE
dur = GetParam(60) + GetParam(195)
SetBodyMode(mode = 1, stateSlot = 0, dur, 0)
```

The slot is **0, not 0xff**, so `SetBodyMode` takes exactly the timer branch the
previous entry described and hands `dur` to **`AJStateChanger`**, whose per-tick
update is a float countdown (`*(float *)(this+0x10) -= elapsed`).

### The value

`GObjPC_InitStats` sets param 60 with `ParamKeeper_SetParam(0, 0, _DAT_00b461bc)`
and `fld DWORD ds:0xb461bc` = **60.0f**. Param 195 is `hwit` — the client's
`PARAM_HWAN_TIME_INCREASE`, and the same id last week's skill-code join mapped —
and InitStats sets it to 0, its registry default. So an unbuffed berserk lasts
exactly **60**, and `hwit` extends it.

**The UNIT is inferred, not read.** What is recovered is the number and that it
counts down as a float against elapsed time; no conversion appears anywhere in
the `AJStateChanger` module, so the tick's delta unit was never actually read.
Seconds is the only reading that makes sense of a float countdown from 60.0 with
a buff term capped at 100 — but that is an inference and is labelled one in the
constant's comment.

### The charge model, recovered

Berserk **requires all five charges and spends all five at once**. That grounds
`Orbs = 5` for a third independent time: `CUsedItemLimit` refuses an item at 5,
`GObjPC_AdjustHwanCount` clamps to [0, 5], and activation both demands and
spends 5. The adjuster also refuses a positive delta while body mode is 1 — you
cannot bank charges mid-berserk — which confirms mode 1 is berserk from a third
direction.

srrevamp's 0..100 gauge filling to full is the same shape as "five charges, spend
all five" by luck rather than design; `Max` and `FillPerHit` stay own design.

**What moved:** `berserk.Duration` 20s -> 60s, shipped with a test that also
guards against drifting back to the placeholder. And a confidently-worded wrong
conclusion, committed and pushed one tick ago, is retracted with its cause named.

## Measuring the dump's blind spot, and re-checking what rested on it (2026-09-16)

Last tick's retraction was caused by a census over the decompilation dump being
mistaken for a census over the binary. Rather than move on to another value, this
tick measures that gap and re-checks the conclusions standing on it.

**The measurement.** `.text` is 7,176,192 bytes; the dump's 34,113 functions
cover 5,936,050 of them. **17.3% of the executable section is invisible to every
grep this project runs** — 1.24 MB in 31,578 gaps. Most is CRT and template code,
but filtering to the game-logic band (`0x401000-0x700000`) and discarding padding
by int3/zero density still leaves **145 real-code gaps, about 30 KB, 6.1% of the
band**.

The map finds its own precedent: `0x00515a52` (702 bytes) is exactly the region
holding the berserk activation handler that broke last tick's claim.

**The re-check, which is the point.** For each gap, disassemble it and ask which
functions it calls. Against the thirteen functions this project's enumerations
depend on — the pool setters, the generic adjust, `GainExpAndLevel`, the chance
roll, `EnsureParam`, both mastery walks, `SetBodyMode`, `RecalcLevelDiffExpScale`
and the param accessors — **only two gaps call any of them**:

- `0x515a52` — the berserk handler, already found and already corrected.
- `0x4a4561` — calls both `ParamKeeper_SetParam` and `ParamKeeper_ReadParam`.

Everything else is clean. **The pool-writer enumeration behind `mana`'s
no-regeneration closure, the exp-grant enumeration, the mastery work and the
chance-roll work are all safe**: no invisible code calls any of those functions.
That is a real validation of four earlier conclusions against the exact failure
mode that broke a fifth.

**The one gap that mattered.** `0x004a4570` is a 4.3 KB function Ghidra never
recovered. It writes params 23, 24, 5, 6, 9, 11, 140, 169, 183 and — the
interesting part — **178, 179, 180, 181**, which are on `berserk`'s "proven zero
for an unbuffed character" list.

It does not overturn that claim, and the reason is specific rather than
hopeful: it writes them with `SetParam(slot 2, ctx 5, ...)` and calls the REMOVE
function for the same ids at the same ctx. Slot 2 keyed by a ctx, applied and
removed as a pair, is a temporary modifier — an unbuffed character has no ctx-5
entry, so the params sit at the registry default of 0.

What it did change is the claim's **reasoning**. It was written as "none of the
three baseline functions writes them"; there is now a demonstrable fourth writer,
so that phrasing was load-bearing on a census that cannot be complete. Restated,
it rests on the param registry's defaults plus the observation that every writer
found — visible or not — is a keyed modifier. That form does not require having
seen every writer.

**Shipped** as `client/tools/ghidra/dump_gaps.py`, with `--calls` for exactly the
publish-time question: *does code I cannot see call the functions my enumeration
depends on?* It answers "safe" or names the gap.

**What moved:** no value. A tool that makes the dump's blind spot measurable, a
17.3%/6.1% number for how big it is, four enumerations re-validated against it,
and one claim restated so it no longer depends on a census that cannot be
complete.

## The server's own SQL, and a storage divergence found by reading it (2026-09-16)

Surveying what the 145 invisible gaps actually contain (using the tool shipped
last tick) turned up something better than the gaps themselves. One gap at
`0x0043d6b0` is full of raw SQL, which pointed at a lever this project had never
used: **the binary states its own database schema, in its own words.**

Extracted: **67 distinct SQL statements naming 25 tables**, now in
`docs/protocol/server_sql.md` verbatim. This is the least ambiguous evidence
available here — the server spells out its column names, its join conditions and
which id each table is keyed by, with nothing inferred.

The gap survey is worth recording on its own, since it says what Ghidra missed:
the invisible regions in `0x515xxx-0x51bxxx` are **command and packet handlers**
(one calls `Mastery_LevelUp`, several call `COpenMarketMgr` handlers, several
read from `MsgBuf`), `0x0043d6b0` is DB loading, and 78 of the 145 gaps carry no
identifying evidence at all.

### The finding: the warehouse is per ACCOUNT, not per character

The item containers are keyed by four different owners, and the binary is
unanimous about which:

| table | keyed by |
|---|---|
| `_Inventory` | `CharID` |
| `_InventoryForAvatar` | `CharID` |
| **`_Chest`** | **`UserJID`** |
| `_InvCOS` | `COSID` |
| `_GuildChest` | `GuildID` |

Four separate `_Chest` statements all filter on `C.UserJID` and none mentions a
character id, and the server's own error text is `failed to load user's chest
size [UserJID: %d]` — so the warehouse's **capacity** is an account property
too. Every character on an account opens the same warehouse.

**srrevamp keys its warehouse and its `storage_gold` by character**, so each
character gets a private warehouse. That is a real divergence from the game.

### Why it is recorded and not fixed

Correcting it is a data migration rather than a code change: every existing
account's per-character warehouses have to be merged into one, and a merge that
overflows the slot limit **destroys items belonging to live testers**. The gold
column moves too. That is a supervised change with a backup behind it, not
something to slip into an unattended pass — so it goes on the open list, with
the citation, rather than being half-done tonight.

The alternative — shipping the key change and letting the merge happen
implicitly — would have looked like progress and lost player items.

Two smaller facts came free from the same queries: `_ITEMS.ID64` is the item
INSTANCE id that every container references (bindings and rentals hang off it
via `nItemDBID`), and an empty slot is a real row with `ItemID = 0 or NULL`
rather than a missing one.

**What moved:** no value. A new evidence class opened (the binary's own SQL, 67
statements), a real divergence found and cited in `internal/storage`, and it is
on the open list as a migration to do deliberately.

## The client's 163 param names, joined to the server vocabulary (2026-09-16)

The client dump carries **163 `PARAM_*` localisation keys** — the game's own
English wording for its stat vocabulary. This project has been corrected by them
twice before (`'era'` is parry, not evasion; `'hra'` is attack rate, not hit
rate), so joining the whole set to the server-side vocabulary was overdue.

Written up in `docs/protocol/param_names.md`, **in two tiers on purpose**. A
client key whose suffix *equals* a server tag or code is the game naming that
thing; a key that merely *resembles* one is an abbreviation argument, which is
precisely the reasoning that got characterdata column 79 wrong twice. Twenty
joins are exact; the rest are listed as candidates for a later use-site, not as
answers.

### Two independent confirmations of SHIPPED values

Both arrived by routes that never touched the client, which is what makes the
agreement worth something:

- **`PARAM_MC_COUNT` ↔ `mc`.** `refdata.HitCount`/`HitsFor()` was recovered from
  the `mc` param's `(2, N)` shape with N in 1..5. The client calls it a COUNT.
  The citation is now in `refdata.Skill`.
- **`PARAM_HWAN_TIME_INCREASE` ↔ `hwit` ↔ param 195.** Last tick's berserk
  duration is `GetParam(60) + GetParam(195)` with a base of 60, read out of the
  activation handler's disassembly; `hwit → 195` came from the skill-code join
  over `Skill_ApplyEffectsToParams`. The client names param 195 "Hwan time
  increase". Three derivations from three different places meeting on one id is
  the strongest confirmation this project can get.

### The seven ignored tags, explained

All seven tags the stat dispatcher recognises-and-ignores have client display
names, which settles the narrowing made earlier: they are live game concepts,
not dead strings.

	astr -> PARAM_ASTRAL     atha -> PARAM_ATHANASIA   dura -> PARAM_DURA
	er   -> PARAM_ER         luck -> PARAM_LUCK        rep  -> PARAM_REPAIRING_CHARGES
	soli -> (no key)

`rep` and `dura` now have a *reason* rather than just an observation:
**repairing charges and durability are item condition fields, not character
stats**, so a stat dispatcher skipping them is correct behaviour rather than a
gap. Note the evidence for that is the two keys sitting together in the key set,
which holds regardless of whether `rep` is literally short for "repairing" —
the tier-2 caveat on the name does not weaken the explanation.

Eighteen client names still have no server-side match (`PARAM_ABSORB`,
`PARAM_AGGRO`, `PARAM_REFLECT`, `PARAM_STUN`, `PARAM_SLEEP`, `PARAM_STEALTH`
and the rest) — each is a game concept whose server id is unjoined, and they are
listed as the next thing to mine.

**What moved:** no value. A third evidence class joined to the other two, twenty
exact names for the vocabulary, two shipped values independently confirmed, and
a reason found for why seven tags are ignored.

## Auditing a shipped value that rested on four rows (2026-09-16)

`combat.Monster.DefensePercent` is marked REAL, and `Hub.Spawn` passes the
monster's LEVEL for it, on the grounds that characterdata columns 73 and 74
"equal the monster's level on every row of the ORIGINAL client's table" — with
four examples named. Four rows is the sample size that has misread a
characterdata column **twice** on this project, and the columns feed
`MitigateDamage`, so every blow against every monster depends on it. It was
worth measuring rather than trusting.

**The measurement**, over the extracted tables (which are UTF-16, and the
project's column numbers turn out to be 0-indexed — two probe corrections before
a single number came out):

	12,963 rows with a level        -> 98.34% have both columns == level
	 7,495 MOB_ rows with a level   -> 99.45% have both columns == level, 41 diverge

So the rule is real rather than a coincidence of four rows. **It is not
universal**, and the exceptions are exactly the population a designer would
hand-tune: bosses, uniques and quest clones. `MOB_EU_KERBEROS` is level 110 with
24. `MOB_TQ_WHITESNAKE` is level 110 with 105. The `MOB_QT_*_CLON` quest spawns
give the two columns *different* values — `MOB_QT_01_ARCHER_CLON` is level 29
with 29 and 54 — which the current code cannot express at all, since it passes
one number for both.

**All 11 species this server spawns were checked individually** and every one
holds the equality, so passing the level is correct today. The comment now says
that, with the failure set named, instead of implying the rule is universal.

**What moved:** no value — the number is right for srrevamp's roster. What
changed is its standing: a claim resting on four observations is now a
measurement over 7,495, with the 41 rows that break it identified and the
condition under which the shortcut stops working written down (add a boss or a
quest clone and the real columns have to be carried on `Species`).

Worth recording separately: **the probe was wrong twice before it was right** —
the tables are UTF-16 rather than ASCII, and this project's characterdata column
numbers are 0-indexed rather than 1-indexed. Both failures returned a confident
"0 rows match", which is the shape that gets mistaken for a finding.

## Verifying 55 "grounded" numbers instead of trusting the word (2026-09-16)

Last tick found a shipped value whose GROUNDED label rested on four hand-checked
rows. That is a category of risk rather than one bug: `cmd/server`'s
`monsterSpecs` carries ~55 numbers all labelled real, and a label is a claim
about provenance. Provenance rots — a transcription slip, a column that shifts
between table versions, a species renamed upstream — and every one of those
leaves the comment saying "real" while the number drifts.

So this tick re-derived all of them from the client's own tables.

**The direct columns** — Level (57), MaxHP (59), Defense (71), Critical (78),
for all 11 species: **44 fields, 0 mismatches.**

**The derived one** is where an error would actually hide. `AttackMin/AttackMax`
is not copied from a column; it is two hops — characterdata column 83 names a
SKILL, and that skill's `att` parameter carries the range. Extracting
`skilldata_*.txt` from Media.pk2 and walking the chain:

	MOB_CH_MANGNYANG  col83=160 -> MSKILL_CH_MANGNYANG_ATTACK01  att run (5,200,17,19,100,28003)  spec 17-19
	MOB_CH_GYO        col83=165 -> MSKILL_CH_GYO_ATTACK02                                          spec 35-40
	MOB_WC_EARTHGHOST col83=210 -> MSKILL_WC_EARTHGHOST_ATTACK02                                   spec 219-261

**11 of 11 matched**, and the skill code names corroborate the chain
independently: column 83 for `MOB_CH_MANGNYANG` resolves to a skill literally
called `MSKILL_CH_MANGNYANG_ATTACK01`. The `att` run's third and fourth words
are the min and max, exactly as `skill_params.md` documents.

**Total: 55 verified, 0 mismatched, 0 unresolved.**

**Shipped** as `client/tools/verify_monster_specs.py`, so this is repeatable
rather than a one-off assertion, with both table-reading traps written into its
docstring — the tables are UTF-16, and this project's characterdata column
numbers are 0-indexed. Each of those cost a probe attempt last tick, and both
failed by returning a confident "0 rows matched".

**What moved:** no value, and that is the result. Every grounded number in the
monster table is now verified rather than asserted, the one two-hop derivation
is confirmed end to end, and there is a tool to re-run after anyone edits the
table.

## The client's itemdata shards overlap, and the exporter did not notice (2026-09-16)

Last tick verified the hardcoded monster numbers. The same provenance question
applies to a far bigger surface — the ~15,000 items `export-refdata` reads out of
the client's own tables — except there the risk is not a mistyped constant but a
wrong column index or a bad assumption about the input files.

**The column map checks out.** Verified against independent anchors this project
already records: `ITEM_CH_SWORD_01_A` reads Price **890** and SellPrice **427**
at `fPrice`/`fSellPrice` — exactly the "Copper Sword 890 buy, 427 sell" in
`shop.go` — and `ITEM_ETC_HP_POTION_01` reads MaxStack **5000**, matching the
test fixture. The indices are right.

**The input files are not what the exporter assumes.** Two measurements:

- **itemdata rows come in two widths**, 161 fields (15,338 rows) and 160 (6,224).
  That one is harmless: the 161st is a trailing empty field, so no index shifts.
  characterdata (105) and skilldata (119) are uniform.
- **The shards OVERLAP.** Of 15,338 distinct item ids, **6,224 appear in more
  than one shard**. Comparing numbers as numbers rather than as text, 5,616 of
  those are the same row written differently (`0` against `0.0`) — but **608
  genuinely disagree**. `itemdata_1000.txt` and `itemdata_5000.txt` give
  `ITEM_CH_SHIELD_01_A` a defence of 1.3 and 1.25 respectively; the shields drift
  by a few hundredths across a whole block of ids. One is an older copy of the
  table sitting beside a newer one.

The shards are supposed to be disjoint id ranges. They are not.

**What that meant in practice.** `export-refdata` streamed every row from every
file with no duplicate detection, so a shell glob put both copies in the CSV and
left which one reached the database to the importer's upsert order — that is, to
the order the operator's shell happened to expand `itemdata_*.txt`. The outcome
was correct only by accident, and silently wrong if the glob order changed.

**Fixed**: rows are now collected keyed by id with the LAST occurrence winning —
the same rule the upsert already followed, made explicit instead of accidental —
and the exporter reports how many ids collided and how many of those actually
conflicted. `sameRecord` compares numbers as numbers, because reporting 5,616
formatting differences would bury the 608 that matter.

**What moved:** no shipped number changed. An unnoticed dependency on shell glob
order became a deterministic rule with a diagnostic behind it, and the 608 real
conflicts are now visible to whoever runs the import instead of being resolved
silently.

## skilldata is clean, and a previous validation had run on a partial table (2026-09-16)

Last tick found the client's **itemdata** shards overlap — 6,224 duplicate ids,
608 of them conflicting — and made the exporter deterministic about it. The
obvious next question is whether skills have the same problem, since skill
values drive combat. They do not, and finding that out turned up something else.

**skilldata is clean.** All seven shards pulled from Media.pk2:

	33,632 rows, uniformly 119 fields
	33,632 distinct skill ids
	0 ids appearing in more than one shard

So the overlap problem is specific to itemdata. That is worth stating as a bound:
the fix shipped last tick does not need a twin on the skill side, and a future
reader should not go looking for one.

**The skill column map is confirmed** against an anchor this project already
records independently. `SKILL_CH_SWORD_SMASH_A_01` (id 3) carries the `att` run
`(5, 143, 15, 18, 143, …)`, and `session`'s own test fixture asserts
AttackPercent **143**, DamageMin **15**, DamageMax **18**. The exporter reads run
positions 1, 2 and 3 — exactly those three.

### The find: a validation measured on a partial extraction

`attackParam` scans the whole row for the `att` literal rather than walking the
Param block, and its comment justifies that with a measurement: the literal never
appears before column 69 and never twice, "0 of **31,605** rows". That is a
careful, well-made argument — and it ran on however many skilldata shards
happened to be on disk at the time. Only `skilldata_5000.txt` was extracted when
this tick started.

Pulling all seven and re-running it:

	rows scanned              33,632   (was 31,605 -- 2,027 rows unmeasured)
	rows carrying 'att'       30,064
	rows with 'att' before 69      0
	rows carrying 'att' twice      0
	lowest column it appears at   69

**Both claims hold exactly on the complete table**, so the conclusion was right —
but it was right on 94% of the data and stated as though it were all of it. The
comment now says 33,632 and records why the figure moved.

This is the same failure shape as the dump-gap work two ticks ago: a census is
only as complete as the corpus it ran over, and the corpus is easy to assume.
There the missing 17% was code Ghidra never recovered; here it was 6% of a table
nobody had extracted.

**What moved:** no value. skilldata proven free of the overlap that afflicts
itemdata, the skill column map confirmed against an independent anchor, and a
previous validation re-run on the full corpus with its numbers corrected.

## "114 untouched client tables" surveyed, and a quest disclosure corrected (2026-09-16)

The open list has carried "114 untouched client data tables" as a bare count for
a long time. Turning it into something actionable: list what Media.pk2's
`textdata` actually holds and cross-reference against the subsystems srrevamp
still calls own design.

That immediately contradicted one of them.

**`internal/quest` said** its invented catalog existed because "no real
_RefQuest-equivalent data has been catalogued yet to import from". Media.pk2
carries two quest tables, and the claim had evidently never been checked:

| table | rows | what it holds |
|---|---|---|
| `questdata.txt` | 697 | quest id, code name (`QNO_*`), and the `SN_*` localisation keys for name, payment, conditions and NPC |
| `questcontentsdata.txt` | 989 | quest code, display name, a category (0/1/3), a **prerequisite quest code** on 373 rows, up to eight `SN_CON_*` step keys, and a numeric field on 442 rows |

So the quest **graph** is real and importable — ids, code names, prerequisites
(`QNO_CH_PRIEST_1` requires `QNO_WC_PRIEST2_1`), and step counts
(`QNO_CH_PRIEST_1` has eight). The `SN_*` keys resolve to real text through the
same textdata mechanism the NPC chat already uses.

**What is genuinely missing** is the part that would let the catalog be replaced
wholesale: machine-readable objective TARGETS. A step is a localisation key
pointing at human text, not a `(monster id, count)` pair, so "kill N of monster
X" still cannot be imported. That much of the original disclosure was right — it
was the blanket "no data" that was wrong.

**One thing deliberately not claimed.** The numeric field on 442 rows runs
**5..110**, exactly this client's character level range, clustering at 101-110.
A level requirement is the obvious reading. It is recorded as a range argument
with no use-site behind it and left unasserted — that is the shape that produced
the wrong answer for characterdata column 79 twice.

**What moved:** no value; srrevamp's two invented quests stay, because the piece
needed to replace them genuinely is absent. What changed is that the reason is
now accurate and points at the 697 real quests that ARE importable, instead of
claiming nothing exists.

## A real bug found by finishing the table survey: the catalog shadowed two real skills (2026-09-16)

Finishing last tick's cross-reference of srrevamp's own-design subsystems against
the client's tables. `learnableskill.txt` turns out to be small and unrelated
(205 rows of NPC-to-skill teaching pairs), but checking it raised a sharper
question about `skill.Catalog`, whose disclosure said to "extend once real
_RefSkill data informs what should exist" — and real skill data IS now imported,
33,632 rows of it.

**The collision.** `skill.Catalog` occupies ids **1 and 2**. In the client's own
skilldata:

	id 1  SKILL_PUNCH_01           the unarmed attack
	id 2  SKILL_CH_SWORD_BASE_01   the basic sword swing
	id 3  SKILL_CH_SWORD_SMASH_A_01

so the two invented entries sit exactly on top of two of the most-used skills in
the game.

**The bug.** The LEARN path already preferred refdata and fell back to the
catalog. The USE path had the order reversed — catalog first. So on a server with
real refdata loaded, a player learned the real skill 2 and then **used an
invented "Whirlwind" with a flat +10 bonus instead of the real 60%-of-weapon
swing**. The two paths disagreed about what skill 2 even was.

This project already knew skill 2 is the basic swing: `skilldamage_test.go` has
asserted "SKILL_CH_SWORD_BASE_01: 60% and no flat damage" for a while. The fact
and the bug sat next to each other without meeting.

**Fixed** by making both paths try refdata first and fall back to the catalog,
which is the rule the rest of the project already follows — `shop.Price` states
it outright: "The real number is what a player pays, so it wins."

The catalog's ids are deliberately NOT renumbered out of the real range:
renumbering would orphan every character that has already learned 1 or 2, and
the ordering fix makes the collision harmless.

`TestRealSkillsWinOverTheOwnDesignCatalog` pins the two facts that make this a
bug rather than a preference — the catalog really does occupy the colliding ids,
and the real basic swing really is a sub-100 percentage with no flat damage, so
the shadowing changed damage rather than just naming.

**What moved:** a behavioural fix. Skills 1 and 2 now resolve to the game's own
skills on any server with refdata loaded, instead of to invented ones.

## Closing the bug class: every real-vs-fallback precedence audited (2026-09-16)

Last tick's bug was not really about skills. It was a **precedence inversion**:
invented data consulted before real data. That is a class, not an incident, so
this tick audits every place srrevamp makes that choice.

**Result: the skill path was the only inversion.** Every other decision prefers
real data, verified in the code rather than from the comment claiming it:

| decision | order | correct |
|---|---|---|
| `shop.Price` | real `item.Price` first, formula second | yes |
| `shop.SellValue` | real `SellPrice` first, fraction second | yes |
| kill experience | `levelTable.KillExp` overrides `monster.ExpReward` | yes |
| `combat.RollGold` | falls back to the flat only when the range is absent (`max <= 0 \|\| max < min`) | yes |
| monster attack | `raw := monster.Attack`, overridden whenever `AttackMax > 0` | yes |
| mastery cost | level table's column 2 first, disclosed cost second | yes |
| skill damage | real `att` params first, disclosed per-level second | yes |
| **skill resolution** | **catalog first** — fixed last tick | was NO |

That bounds the damage: one inversion, found and fixed, and nothing else of the
same shape.

### A latent instance of the same collision, recorded before it bites

`quest.Catalog` uses ids **1 and 2**. The client's `questdata.txt` gives those to
real quests — id 1 is `QEVENT_GUIDE`, id 2 is `QTUTORIAL_CH`, the Chinese
tutorial — and real quest ids run **1..1051 with no gap at the bottom**, so any
small invented id collides.

It is **not** a bug today, and the reason is specific rather than lucky: nothing
imports real quests, because the objective TARGETS are not in the client tables
(established last tick). There is no real quest data to shadow. It becomes a bug
the moment the quest graph is imported — which last tick showed is possible.

Written into `internal/quest` with the real quest names and the instruction that
matters: when real quests are wired in, fix it the way the skill path was fixed —
**try the real table first and fall back to the catalog** — rather than
renumbering, which would orphan existing progress.

**What moved:** no value. A bug class opened last tick is now bounded by an audit,
and the one remaining instance of it is documented at the site with the fix
prescribed in advance.

## The stat-tag vocabulary is complete: magicoption.txt names every tag (2026-09-16)

Fifteen tags were left explicitly unresolved by the dispatcher passes, with the
instruction not to guess them from their abbreviations. The client's
**`magicoption.txt`** names all fifteen outright — it stores each item
magic-option's stat tag as a big-endian multi-char literal in the same row as its
`MATTR_*` code name, so the mapping is stated rather than inferred.

	rsli -> MATTR_RESIST_SLEEP        rsti -> MATTR_RESIST_STUN
	rfei -> MATTR_RESIST_FEAR         rdii -> MATTR_RESIST_DISEASE
	rcsi -> MATTR_RESIST_CSMP         nrep -> MATTR_NOT_REPARABLE
	rein -> MATTR_REINFORCE_ITEM      reis -> MATTR_REINFORCE_ITEM_SET
	duru -> MATTR_DUR                 hr   -> MATTR_HR
	ape  -> MATTR_APE                 intj -> MATTR_INT_3JOB
	inta -> MATTR_AVATAR_INT          luca -> MATTR_AVATAR_LUCK
	mdia -> MATTR_AVATAR_MDIA

Five of them are resistances, which is why they never surfaced in the damage
paths the earlier passes walked. **56 tags in total** appear in the table; the
full map is in `param_tags.md`.

### It settles an argument, and corrects a guess this project floated

The seven tags `Stat_ApplyTaggedModifier` recognises and ignores were explained
as **item condition fields rather than character stats**. That explanation rested
on `PARAM_REPAIRING_CHARGES` sitting beside `PARAM_DURA` in the client's key set
— suggestive, and labelled tier-2 at the time. The table settles it with the
game's own naming:

	dura -> MATTR_DEC_MAXDUR    rep  -> MATTR_REPAIR    nrep -> MATTR_NOT_REPARABLE
	soli -> MATTR_SOLID         astr -> MATTR_ASTRAL    atha -> MATTR_ATHANASIA
	luck -> MATTR_LUCK

Decrease-max-durability, repair and not-repairable are unambiguously item
properties. A stat dispatcher skipping them is correct behaviour, now on data
rather than on an abbreviation argument.

**And it corrects one guess.** The superseded paragraph in `param_tags.md`
floated "`dura` for a duration, say" while warning against exactly that kind of
reading. `dura` is **durability**. The warning was right and the parenthetical
was wrong; both are now marked.

`PARAM_REPAIRING_CHARGES` → `rep` is promoted out of tier 2 in
`param_names.md`, since MATTR_REPAIR names it directly.

**What moved:** no value. The tag vocabulary went from 31 resolved + 15 unknown +
7 argued to **56 named from the game's own data**, one floated guess is corrected
in place, and a tier-2 caveat is retired.

## An item-effect code vocabulary, and a naming probe that had to be thrown away (2026-09-16)

Last tick's win came from a client table naming a code vocabulary. Trying the
same for **item effects**, after `BCS1` turned up in the item-use dispatcher two
ticks ago with nothing behind it.

**Two clean negatives first**, both worth recording so they are not retried:

- `itemeffect.txt` is not the vocabulary. It is 46 rows mapping item code names
  to *visual* skill-effect code names, nothing to do with mechanical effects.
- **itemdata has no param block** of the kind skilldata has. Censusing every
  2-4 character multi-char literal across all 15,338 item rows from column 100
  on yields 7 strings, all low-count decoding artefacts (`dddP`, `u0`, `lppu`).
  The skill vocabulary's technique does not transfer to items.
- The codes are not in **any** extracted client table. Like drop tables and quest
  objectives, item-effect codes are server-side.

**The vocabulary, from the binary itself.** Censusing the four-byte comparisons
in the two item-use dispatchers (`GObjPC::FUN_0049f090` and `FUN_0049f590`) and
decoding them big-endian gives **eight item-effect codes**:

	BCS1  BFI1  PSU1  UIL1  UIU1  UQL1  USL1  USU1

These are solid — they are literal `cmp` operands in the dispatch, the same shape
that yielded the stat-tag vocabulary.

**One is named.** `BCS1` gates `INC_INVENTORY_SIZE`: its branch calls
`GObjPC::FUN_00864aa0`, which compares against that string via
`mov ecx, 0xae57d4`. That is a direct reference inside the branch, not a
proximity guess.

### The probe I threw away

Trying to name the other seven the same way — walk each code's branch, follow its
calls, report the first string those functions reference — returned
`INC_INVENTORY_SIZE` for **four different codes**. That is not a finding; four
codes do not share one meaning. The 80-instruction window was bleeding across
branch boundaries into the same neighbouring helper.

It is recorded because the output looked exactly like a result: a tidy table with
plausible entries, produced by a method that had just worked elsewhere. The tell
was the uniformity, not anything in the individual rows. Seven codes stay
unnamed.

**What moved:** no value. An eight-entry item-effect vocabulary recovered from
the dispatcher, one entry named with a direct citation, three negatives bounded,
and a false naming pass discarded before it reached a doc.

## The discarded naming pass, redone correctly — and shipped as a tool (2026-09-16)

Last tick recovered eight item-effect codes (`BCS1`, `BFI1`, `PSU1`, `UIL1`,
`UIU1`, `UQL1`, `USL1`, `USU1`) and threw away the pass that tried to name them,
because a fixed 80-instruction window gave four of them the same answer. This
tick redoes it with the method that works, and ships it.

**The fix** is the one the tag-dispatcher work already used: scope the walk to
the branch. Enter at the comparison's `je` target, follow jumps, stop on reaching
any other code's comparison site or a `ret`. Follow calls exactly one level,
because a branch often names itself only inside a helper.

**The control passes.** Scoped correctly, exactly **one** code resolves —
`BCS1 -> INC_INVENTORY_SIZE`, the one independently verified by a direct string
reference — against four last tick. The other seven return nothing, which is the
honest answer rather than a borrowed one.

**Three further avenues closed**, so nobody retries them:

- the codes appear in **no** extracted client table;
- the server's own SQL has no effect table naming them;
- the `.rdata` strings that look like the codes (`PSUVW`…) are x86 instruction
  bytes, not data.

Characterising the seven by their **calls** instead of their strings does not
help either: the branches reach only `Assert_BreakIfDebugger`,
`__security_check_cookie` and a singleton getter, delegating the actual work to
unnamed helpers. Two of them (`PSU1`, `UIU1`) also touch a time function, which
hints at a timed effect and is **not** recorded as a finding — it is proximity
again, and proximity is what produced the discarded table.

**Shipped** as `client/tools/ghidra/dispatch_walk.py`, with the failure it exists
to prevent written into its docstring and a built-in warning: if every resolved
code returns the same answer, that is the signature of a walk escaping its
branch, not of codes sharing a meaning.

A first version of the tool **failed its own control** — it read only strings
referenced directly in the branch and so missed `BCS1`, whose name lives in a
helper. Caught by running the control before committing; the call-following fix
is in.

**What moved:** no value. Seven codes stay unnamed on purpose, one is confirmed,
and the method that keeps getting this wrong is now a tool that checks itself.

## The skill-code census was 58% noise, and two consumers are pure guards (2026-09-16)

Reading `FUN_00593f50` to name the cure/heal codes turned up a false positive
that matters more than the codes did: line 52's `(**(code **)(iVar3 + 0x254))(…)`
is a **vtable call at offset 0x254**, not a read of the `kb` field. The census
that selected this project's skill-code lever counts those as evidence.

**Measured dump-wide over every skill-field offset:**

	any occurrence      2,851
	VTABLE calls        1,670   (58.6%)
	typed FIELD reads     664   (23.3%)

`er` (0x27c) is the extreme — **407 vtable calls against 4 real reads**. More
than half of what the census treated as evidence was a virtual call unrelated to
skills.

**Applying both corrections** — typed reads only, then weighting by codes read
more than once (the guard-chain fix found earlier) — gives the first honest
consumer ranking. Two results stand out:

- **`FUN_00589d20` (24 codes) and `FUN_00589f10` (16) drop off entirely.** Every
  one of their codes is read exactly once: they are pure guard functions. The
  naive ranking put them at the top, and a future tick would have been spent
  reading functions that do nothing with those codes.
- **`Skill_ApplyEffectsToParams` falls from 34 distinct codes to 23**, tying
  rather than leading. The right lever was picked partly by luck.

**What survives.** The code → param join is unaffected: it was validated by six
independent controls that reproduced exactly, and its mechanism — pairing a field
read with the `SetParam` annotation that follows — cannot be produced by a vtable
call. The *selection* was contaminated, not the join.

**What was not claimed.** Three functions are each dominated by a single code —
`FUN_0091f330` by `lfst` (8 reads), `FUN_00593f50` by `heal`/`resu`,
`FUN_00586700` by `tel2`/`tele` — which reads like life-steal, healing and
teleport handlers. Neither of the first two carries a confirming string, and
`FUN_0091f330` is a vtable slot in the quest band. Naming a function from its
dominant code's abbreviation is exactly the reasoning this project keeps
rejecting, so all three stay unnamed.

**What moved:** no value. A census method leaned on for several findings is now
measured rather than assumed, two apparent top consumers are exposed as guards,
and the one conclusion built on it is shown to rest on controls rather than on
the contaminated ranking.

## Two more skill codes: mechanic recovered, name withheld (2026-09-16)

Using last tick's corrected consumer ranking — typed reads only, weighted by
codes read more than once — to read what `Combat_ResolveDamage` genuinely acts
on. `tant` (293 skill rows) and `tnt2` (550) each get 4 real reads.

**The mechanic, from the use-site:**

```c
acc = state[0x1c] + src[0x20];
acc = round(acc * (code[1] / 100.0 + 1.0));
state[0x1c] = code[0] + acc;
```

Each code carries a **(flat, percent) pair** — scale by `1 + percent/100`, then
add the flat amount. Both have run length 3 (code plus two words), so every word
is accounted for and none is spare, which is a decent internal check on the
reading.

**They are alternatives.** `if (tant == 0) { if (tnt2 != 0) … } else …` — `tant`
takes precedence and `tnt2` applies only in its absence, with both arms computing
the identical formula. The codes differ in *when*, not in *what*.

**The name is withheld deliberately.** The field they scale, `state[0x1c]`,
belongs to an object built a few lines earlier in the damage path (fields
0x24-0x48 filled, including the float 2.0 at +0x48) — the shape of a timed
status-effect record, not the blow's damage, which lives in the separate fields
`da` scales. Which quantity `+0x1c` holds is not settled, and the client's
`PARAM_TIME_BOMB` is a tempting match for `tant`/`tnt2` that is pure
abbreviation reasoning. Recorded with the mechanic and no name.

**What moved:** no value. Two codes go from unidentified to
mechanic-known-semantic-unknown, which is a real step and an honest stopping
point — and the corrected ranking is what pointed at them rather than at the two
guard functions the old ranking ranked first.

## The damage floor of 1 is the game's own, not this project's (2026-09-16)

Chasing what `state[0x1c]` holds — the field `tant`/`tnt2` scale, left open last
tick — ran into something more valuable a few lines away.

`combat.MitigateDamage` floors a blow at 1, and its comment said: *"The floor
stays at 1 here rather than the game's 0. That is own design and disclosed."*
**That is wrong about the game**, and wrong in the direction that makes srrevamp
look less faithful than it is.

The zero in the old reading is real but is not the end of the pipeline.
`Formula_MitigatePhysicalDamage` clamps its result at 0; then
`Combat_ResolveDamage` floors the finished blow:

```c
if (damage == 0) {
    if (local_d0 == 0) { damage = 1; }
    else { /* a different path for skills with no attack parameter */ }
}
```

**`local_d0` decides which**, and it is set to 1 only when the skill carries
NEITHER `att` (0x230) nor `ck` (0x248) — a buff or utility skill. So
`local_d0 == 0` is exactly the case of a blow that HAS an attack parameter,
which includes every ordinary swing (`SKILL_CH_SWORD_BASE_01` carries `att` at
60%). For those the engine guarantees at least 1 damage.

So srrevamp's floor is **recovered, not invented**. The earlier note read the
mitigation clamp and stopped there, missing a floor applied one stage later —
which is why the comment now says where in the pipeline each clamp lives, rather
than just naming a number.

`TestDamageFloorIsTheGamesOwn` pins it, including a sweep asserting no
combination of raw damage and absorption can drive the result below 1.

**A note on how this was found.** It came out of a question deliberately left
open — "what is `state[0x1c]`?" — rather than from a search for it. That
question is still open: `+0x1c` accumulates, is floored at 1 under a *different*
condition, and belongs to an object whose class is not identified. The floor
finding sat four lines above it.

**What moved:** no number. A value shipped as own design turns out to be the
game's, which is the direction this project wants corrections to run, and the
comment now carries the pipeline position that made the earlier reading wrong.

## Magical weapons dealt 1 damage: srrevamp models one of the engine's two damage halves (2026-09-16)

Last tick's floor correction came from reading one stage of the damage pipeline
and stopping. That suggested a systematic question — **is srrevamp's damage
ORDER also incomplete?** — so this tick traced every touch of the damage field
in `Combat_ResolveDamage`.

**The engine computes TWO damage halves and sums them:**

```c
dmg[0x28] = Formula_MitigatePhysicalDamage(...)    // physical
dmg[0x24] = Formula_MitigateMagicalDamage(...)     // magical
...
damage    = dmg[0x28] + dmg[0x24]
```

srrevamp reads only `PhysAttackMin/Max`. `MagAttackMin/Max` is imported into
`refdata.Item` and **never used**.

**Measured over a real client's itemdata**, of 2,927 items carrying any attack
value:

	physical only   1,049
	magical only      828
	both            1,050

So **828 items — every staff and magic weapon — have no physical damage at
all.** Reading only the physical columns gives them min = max = 0, the blow
lands on `MitigateDamage`'s floor, and the weapon does **1 damage**.

### What shipped, and what deliberately did not

Fixed: when a weapon has no physical damage, the magical columns are used.
Items that carry physical damage are untouched.

**Not fixed: the sum.** Three sites zero one half or the other — a skill flag,
and bits 4 and 8 of the ref object's `+0x2b4`. How often a blow really carries
both is a question about flags this project has not read. Summing them for the
1,050 items that carry both would roughly double their damage — including the
Copper Sword, whose magical 25-28 exceeds its physical 15-16 — on an unread
condition. That is a balance change dressed as a fix, on a server with live
testers.

What is unambiguous regardless of those flags is that a weapon with no physical
damage should not deal 1. That much is shipped; the rest is written down with
exactly what has to be read before anyone acts on it.

**What moved:** magical-only weapons now deal their real damage instead of 1.
The larger question — whether a blow sums both halves — is recorded as open with
the deciding flags named, rather than guessed.

## 2026-09-16 — the damage-half question, settled; and two wrong rows in the skill-param table

The previous entry named exactly what had to be read before the damage sum could
be acted on: *"a skill flag, and bits 4 and 8 of the ref object's `+0x2b4`"*.
Both have been read. The answer closes the question, and it also **corrects the
framing of the previous entry**, which was aimed at the wrong object.

### `+0x2b4` is a skill param, not a "ref object" field

Grepping writers of `+0x2b4` landed inside `SkillGlobal::RefSkill_ParseParams`,
the skill parameter parser. So `+0x2b4` is a *skill* field, filed there by the
param code `pw` (`0x00007077` — a two-character tag; Ghidra renders the compare
as a 16-bit value and `005879c1` shows it is a full `cmp edx,0x7077`).

### The bits mean physical and magical, and two sources say so

`Combat_ResolveDamage` computes two halves and sums them:

	rec[0x28] = Formula_MitigatePhysicalDamage(...)
	rec[0x24] = Formula_MitigateMagicalDamage(...)
	rec[0x20] = rec[0x28] + rec[0x24]

and each formula returns 0 unless its bit is set in **`att` value[0]** — bit 4
for physical (`0040e450`), bit 8 for magical (`0040e830`). Independently, their
raw-damage builders read different stats: `0040db50` reads param
`(max ? 1 : 0) + 13`, `0040dc10` reads `+ 15`, and the recovered param registry
already named 13/14 "phys damage low/high" and 15/16 "mag damage low/high"
without reference to any of this.

`att` value[0] is the word this project had been reading *past* for a year while
consuming the three numbers behind it.

### The sum was never the risk

Measured over the real table — 36,389 skilldata rows, 31,605 carrying `att`:

	 5 {1,4} 17,075 physical      10 {2,8}  6,971 magical
	 6 {2,4}  4,055 physical       9 {1,8}  2,528 magical
	                               8 {8}      966 magical
	 0/1/2       10 neither

**Zero rows of 31,605 set both bit 4 and bit 8.** The two halves are mutually
exclusive by authoring, so the engine's sum always has exactly one live term.

The previous entry's worry — "summing them for the 1,050 **items** that carry
both would roughly double their damage" — counted items, and the gate is on the
**skill**. The caution was right; the reason given for it was not.

### `pw` inverts the same mask, and only two skill families use it

`pw`'s bits *suppress* rather than enable: bit 4 zeroes the physical half, bit 8
the magical one, applied to the base blow and to a second damage record. All 61
`pw` runs in the real table belong to Cold or Fire "Wall" skills —
`SKILL_CH_COLD_BINGBYEOK_*` carries 7 (kills physical),
`SKILL_CH_FIRE_HWABYEOK_*` carries 11 (kills magical). Whether the holder hangs
off the attacker or the target is **not settled** and is left open rather than
asserted.

A third code shares the vocabulary: `skc` (field `0x490`) is AND-ed against the
mask as a filter — `(*att_v0 & *skc_v0) != 0` — so `att` writes it, `skc` tests
it, and `pw` inverts it. One encoding, three consumers.

### Two rows of the recovered param table were wrong

Chasing `pw` found it already in `docs/protocol/skill_params.md` with field
`0x434` — which belongs to the *next* tag, `rt`. A second walker was written
that follows each `je` to its target instead of reading the fall-through. It
agrees with the table on **88 of 90** fixed-run codes and disagrees on two:

	pw   0x434 -> 0x2b4      (0x434 is rt's,  which was missing)
	skc  0x584 -> 0x490      (0x584 is spi's, which was missing)

Both corrected, both missing tags added, both hand-verified in the disassembly.
The two errors share a cause: `pw` and `skc` are the only codes whose handler
*rewrites the value it points at*, and that shape defeated the extractor's
handler detection. The failure had a signature and the signature is exhausted.

The walker also finds ~55 further tag comparisons in neither table. That is
recorded in `skill_params.md` as a **lead, not a finding** — it has already
over-reported once (it read the in-handler `cmp edx,0x4` value tests as tags
until constrained), so the vocabulary size stays open.

### What shipped

- `refdata.Skill.AttackType` — `att` value[0], exported as a strict-suffix CSV
  column 28 and persisted in SQL. An export predating it reads 0.
- `combat.AttackType` with `IsPhysical`/`IsMagical`/`Known` and the whole
  recovery written where it is used, plus tests pinned to the measured row
  counts so a later edit that swaps the bits fails loudly.
- The mask threaded through `performAttack`; a magical skill now draws on the
  weapon's magical attack columns.

### What deliberately did not ship

Routing a magical skill to the magical columns **unconditionally**. Of 1,582
real items carrying any attack value, **574 have physical damage and no magical
at all**, so an unconditional reroute drops every caster holding one of those to
the floor of 1. Whether that is the engine's behaviour turns on whether
Intellect feeds params 15/16 the way Strength feeds 13/14 — which has **not**
been read.

So the magical columns are used only where they exist: the 560 items carrying
both now answer a magical skill correctly, the 574 physical-only ones are
untouched. Strict improvement, nothing to regress.

**What moved:** the damage-half question is closed with a measurement instead of
a guess, one of the three "unrecoverable" param codes turned out to be two
*wrong* rows rather than missing ones, and the skill-param table gained two
codes and lost two errors.

**Still open:** whether Intellect feeds params 15/16; whether `pw`'s holder is
the attacker or the target; the ~55 unverified tag comparisons.

## 2026-09-16 (later) — Intellect feeds the magical half, and a real bug it exposed

The previous entry left one named blocker: *"whether Intellect feeds params
15/16 the way Strength feeds 13/14"*. It does, and reading it found a bug in the
code that entry had just shipped.

### The parameter graph, read edge by edge

`GObjPC_InitStats` (`004e3200`) declares the chain explicitly — these are the
binder's own annotated calls, not an inference from symmetry:

	 1 (str) -> 17 -> 13     phys low      34 -> 17 at slot 3
	 1 (str) -> 18 -> 14     phys high     36 -> 18 at slot 3
	 2 (int) -> 19 -> 15     mag low       35 -> 19 at slot 3
	 2 (int) -> 20 -> 16     mag high      37 -> 20 at slot 3

Param 2 carries the game's own tag `int` in the recovered registry, so Intellect
is named by the binary rather than by its position in the pair. Slot 3 is the
percent scale, so each derived term is `stat * reinforce / 100`.

### The bug

`session.attackerDamage` passed **Strength** into the magical columns. It had
done so since the magical-weapon fallback shipped, and the previous tick
propagated it into the new mask-driven path. Fixed: the magical half scales with
Intellect.

Worth stating plainly — **symmetry alone would not have justified this fix**.
"Str feeds physical, so Int must feed magical" is precisely the suggestive curve
this project has been wrong on before. The edge list is a use-site; that is why
it was read.

### The selection now lives in one place

The rule was inline in `session.attackerDamage` with a **copy of itself in the
test**, and the copy was already stale: it lacked the damage-type branch added
the tick before, so the test went on asserting the old rule after the rule
changed. Both are replaced by `combat.WeaponRange`, which the test now calls
directly. The Intellect guard was checked by reintroducing the bug — it fails
with `got 110-110, want 50` and passes when restored.

### The unconditional reroute: now fully grounded, still not shipped

The previous entry deferred this on an unread step. That step is read, and it
says the reroute would be **faithful**:

`Char_PublishCombatStats` (`00497830`) writes params 34-37 **unconditionally** —
the only branch substitutes `0.0`, it never skips the write. So a physical-only
weapon writes param 35 = **0** rather than leaving it at the registry default of
**100**, slot 3 scales Intellect to nothing, and the magical half really is 0.
(The default mattered: a param nothing writes falls back to its default, and 100
would have meant a 1.0 scale and Intellect flowing through. It is written, so it
does not.) Measured: all 574 physical-only items carry no magical reinforce and
all 448 magical-only carry no physical reinforce — no exceptions either way.

It is still not shipped, for a different and better reason than last time. The
engine can afford to give 1 damage there because **it refuses the cast first**:
skills carry `ReqCast_Weapon1/2` (skilldata columns 50/51), and srrevamp does not
model them — `refdata/skill.go` says so outright. Shipping the penalty without
the prevention would hand a tester holding a sword 1 damage from a skill the
real game would not have let them cast.

**What moved:** the magical half now scales with the right stat, one grounded in
the engine's parameter graph; the selection rule and its test are no longer two
copies; and the reroute's blocker changed from "a fact nobody has read" to "a
feature that has to be built first".

**Next step, now unblocked and named:** export `ReqCast_Weapon1/2` and gate skill
use on the equipped weapon. That is the last thing between here and the faithful
magical damage path.

## 2026-09-16 (third) — the weapon gate, and a retraction of the previous entry

The previous entry named its own next step: *"export `ReqCast_Weapon1/2` and gate
skill use on the equipped weapon"*, and justified deferring the magical reroute
on the claim that **the engine refuses the cast first**. Reading the gate
disproved the justification. Both reasons that entry gave were wrong, and the
reroute has now shipped.

### The gate, named by the binary

The skilldata row loader `SkillGlobal::FUN_005893e0` validates every row and
names the field in its own error string:

	if (skill[199] == '\0' || skill[200] == '\0')
	    FUN_00936640(0x2000000, "ReqWeapon Error [RefSkill ID: %d]", skill[4]);

So `CRefSkill+199/+200` are the two required-weapon bytes, and **0 is invalid** —
the loader refuses it. The check is `FUN_0058d480`: the equipped weapon's code is
`TID >> 11`, `0xff` is an unused slot, both `0xff` means no requirement, an empty
hand reads as **1**, and a mismatch returns error **0x300d**.

Columns 50/51 carry them. The memory note listed those columns from a schema
listing; they are now confirmed by the data confirming itself — grouping 36,389
real rows by the family in their `Basic_Code` puts every one of 24 families on
the code its own name says it should have (`SKILL_EU_AXE` → 9, `SKILL_EU_STAFF` →
11, `SKILL_CH_SPEAR` → 4 and 5, …). Full table in
`docs/protocol/skill_params.md`.

### The retraction

**"The engine refuses the cast first."** It has the gate, but **4,144 of the
10,465 magical attack skills require no weapon at all** — both bytes `0xff`,
including every CH elemental nuke. For 40% of exactly the skills in question the
engine does not refuse, so the justification did not hold.

**"It would drop a caster holding a sword to 1 damage."** Also wrong. The
skill's own flat `att` damage is added to the bound inside the builder
regardless of the weapon (`0040dc10` reads the descriptor's `+0xc`), and across
those 4,144 rows the median flat is **2,068** against a median percent of
**263**. The weapon's contribution is the small term, not the blow. srrevamp
already adds that flat separately as `damageBonus`, so the shape matched all
along.

What survives from that entry is the part that was actually read: the magical
half draws params 15/16, `Char_PublishCombatStats` writes params 34-37
unconditionally (the only branch substitutes 0.0, it never skips the write), so
a physical-only weapon writes param 35 = 0 rather than inheriting the registry
default of 100. The weapon's share of a magical blow really is zero. That was
right; the two conclusions drawn around it were not.

### What shipped

`combat.WeaponRange` now routes a magical blow to the magical columns
**unconditionally** — the weapon contributes nothing when it has no magical
attack, which is the engine's behaviour. The old `item.MagAttackMax > 0`
condition remains only for a blow with **no known mask**, and is now labelled a
stand-in rather than a rule: the engine has no maskless blow, because a plain
swing runs the weapon's own basic-attack skill and that skill carries the
matching mask. srrevamp's `OpAttack` passes `AttackPhysical` for every weapon, so
the fallback stands in for picking the right basic skill, and disappears when
`OpAttack` resolves one.

### Method note

This is the third tick in a row where the *previous* tick's deferral reasoning
turned out to be wrong while its measurements held. The pattern is consistent:
the numbers read out of the binary survived, and the sentences about what they
implied for srrevamp did not. Deferrals deserve the same "what would show this is
wrong" treatment as findings — all three would have been caught in one tick by
asking "how many real rows does this claim actually cover?" before writing it
down.

**What moved:** the magical damage path is complete and faithful; the weapon gate
is fully recovered with its vocabulary confirmed 24 ways.

**Next step:** export item TIDs so the gate can be wired -- `refdata.Item` carries
none today, which is the only thing between here and enforcing ReqCast_Weapon.

## 2026-09-16 (fourth) — the weapon gate, wired

The previous entry named its next step as "export item TIDs, the only thing
between here and enforcing ReqCast_Weapon". **That premise was wrong in the
cheapest possible way: the TIDs were already exported.** `refdata.Item` has
carried `TypeID1..4` at CSV columns 20-23 with SQL columns to match for as long
as `ITEM_FORMAT.md` has existed. The compiler said so within a minute of trying
to add them ("TypeID1 redeclared"), which is the good version of this mistake --
but it is the fourth consecutive tick whose stated next step contained a claim
nobody checked. Checking took one grep.

### TID4 is the weapon code, and itemdata confirms the vocabulary

The engine's item tests use paired masks all over the binary -- `& 0x780` for
bits 7-10 and `& 0xf800` for bits 11-15 -- which fixes the packing: **TID3 at
bits 7-10, TID4 at bits 11-15**. So `FUN_0058d480`'s `equippedTID >> 11` reads
**TypeID4**, not a flat weapon enum as the previous entry's table implied.

Every weapon row in real itemdata is `(TypeID1, TypeID2, TypeID3) = (3, 1, 6)`,
and under that category each family occupies exactly one TypeID4 -- 112 rows
apiece, no family split:

| 2 CH sword | 3 CH blade | 4 CH spear | 5 CH tblade | 6 CH bow | 7 EU sword | 8 EU tsword |
| 9 EU axe | 10 EU darkstaff | 11 EU tstaff | 12 EU crossbow | 13 EU dagger | 14 EU harp | 15 EU staff |

plus **16 = `ITEM_FORT_FORTRESS_HAMMER`/`_AXE`**, which matches
`SKILL_*_FORTRESSWEAPON` -> 16 from the other table and is the code the engine
special-cases into `GObjPC::FUN_004f1130`.

**This corrects three names the previous entry invented.** It read the weapon
names off the *skill* families that require them, and got: 10 "wand" (really
`DARKSTAFF`), 11 "staff" (really `TSTAFF`), 15 "cleric rod" (really `STAFF`).
The skill family that requires a code is not the item's name for it -- exactly
the "a name is not a use-site" rule, applied one table too early.

Code 1 is confirmed from a third direction: **`SKILL_PUNCH_01` requires exactly
code 1**, and the engine's `if (code == 0) code = 1` makes an empty hand satisfy
it. (TypeID4 1 under the weapon category holds fireworks, 10 rows -- so 1 is not
a weapon family, it is the "nothing wielded" slot.)

### What shipped

- `refdata.Skill.ReqCastWeapon1/2` -- skilldata columns 50/51, exported as
  strict-suffix CSV columns 29/30 and persisted in SQL.
- `combat.SkillAllowsWeapon` reproducing `FUN_0058d480`, with the 16 codes named
  from **itemdata's** own families, and a table test walking each branch.
- The gate enforced in the skill-use path: a mismatch answers "wrong weapon for
  this skill" instead of casting.

### Two compatibility rules, both load-bearing rather than defensive

**Zero requirement bytes permit the cast.** Zero is *invalid* in the real table
-- the row loader refuses it with "ReqWeapon Error" -- so a zero here can only
mean an export predating the columns. Refusing on it would lock every skill on
every existing deployment.

**An unreadable weapon permits the cast, but an empty hand does not.** These look
identical by value: an item row imported before the `type_id` columns existed
carries `TypeID3 = TypeID4 = 0`, which is exactly what an empty hand looks like.
Treating that as bare hand would refuse every weapon-requiring skill to a
character holding a perfectly good sword, on a deployment whose only fault is an
old import. `equippedWeaponType` returns a `known` flag so the two cases stay
distinct.

**What moved:** the weapon gate is recovered, confirmed three ways, and enforced;
the TID packing is read off the binary's own masks rather than inferred from
field widths; three invented weapon names are corrected.

**Next step:** the gate covers `skill[0x3a0] == 0`, the ordinary path.
`FUN_0058d480`'s other branch walks a list at `+0x3a0` with a `switch` on its
first word -- an override that some skills carry. Nothing reads it yet, and what
it overrides is unrecovered.

## 2026-09-16 (fifth) — the skill-param vocabulary closes: 148 codes, zero unknowns

Two ticks ago this project recorded an open lead: a second walker over
`RefSkill_ParseParams` found "roughly 55 further tag comparisons in neither
table", unverified, with the question *"whether the vocabulary is really ~105 or
~145 is open"*. **Closed: it is 148, and 44 codes were added.**

It was closed by a structural test rather than by reading more disassembly,
which matters because the disassembly is what was unreliable.

### The test, and why it fails loudly

Walk every real skilldata row's Param block from column 69 using a table's run
lengths. A wrong run lands the cursor on a *value* instead of the next code and
derails the rest of the row, so a bad entry shows up as **fewer** clean walks,
not as a silent pass.

| table | fixed | varlen | clean | varlen-stop | unknown |
|---|---|---|---|---|---|
| doc table as it stood | 89 | 15 | 19,155 | 1,609 | 15,625 |
| + 30 fixed-run codes | 119 | 15 | 19,990 | 1,845 | 14,554 |
| + 14 stoppers | 119 | 29 | 19,990 | 16,399 | **0** |

**Zero of 36,389 rows hit an unrecognised code.** Each of the 30 was also added
alone against the unmodified table: 24 raise the clean count by themselves, 4 are
neutral (their rows stop later on a different code), and none lower it.

### The walker was a good finder and a bad measurer

Walking with the walker's whole 145-tag table scores **910** clean — far worse
than the 89-code doc table. Its run lengths are unreliable: it accumulates
`add ecx,N` over a fixed instruction window and under-counts any handler that
adds more inside a branch. So only the entries real data actually exercises,
where the walk confirms the run, were published.

That is the `pw`/`skc` lesson arriving from the other side. That correction came
from a walker disagreeing with the table; this one comes from **real data
disagreeing with the walker**. Neither artefact is authoritative on its own.

### One class of code explains every remaining gap

Nine of the fourteen stoppers have no recovered field, and `efr` — the single
most common stopper, 9,538 rows — shows why. It is dispatched by an ordinary
`cmp edx,0x656672`, but its handler reads `mov edx,[eax+0x4]` and **branches on
its own first value** before storing anything, so its field and run depend on
that value. A scanner looking for the next `mov [esi+N],eax` finds the wrong one
or none.

That is the same shape that mis-filed `pw` and `skc`, so the two failures the
last three ticks turned up are one failure: **value-dispatched handlers**. They
are recorded as operationally variable-length, with the mechanism named rather
than smoothed over.

### A justification that was quietly conditional

`export-refdata`'s whole-row scan for the `att` literal was defended by "on the
19,839 rows that walk cleanly, the walk and the scan agree 19,839 times and
differ 0". Under a 104-code table, 15,625 rows stopped at an unrecovered code --
so "the rows that walk" was doing unexamined work in that sentence.

Re-run on the complete vocabulary: 19,990 rows walk end to end, walk and scan
agree on 18,727 and differ on 0, and the `att` literal appears as some other
code's VALUE **exactly 0 times** across every walked run. That last number is
the scan's actual failure mode, now measured directly instead of argued from the
schema.

**What moved:** the skill-param vocabulary went from 104 codes with 15,625
unexplained rows to 148 codes with none; a load-bearing justification in the
exporter is no longer conditional on the part of the table nobody had read.

**Next step:** the nine value-dispatched stoppers (`bu`, `cr`, `curl`, `efr`,
`es`, `fz`, `ko`, `setv`, `sl`). Their handlers branch on value[0], so each needs
reading individually -- `efr` first, at 9,538 rows by far the most used.
