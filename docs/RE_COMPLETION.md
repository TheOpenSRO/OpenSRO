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
  they live.
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

  *Still on the table:* 43,060 slot targets point at code Ghidra never defined
  as a function (20,411 client / 22,649 server). Defining functions there and
  re-dumping would extend this substantially, and is the obvious next pull.
  Also unexploited: the 2,014 + 1,207 pointer sites *rejected* for a bad COL
  signature are `BaseClassDescriptor`s, which point at TypeDescriptors too —
  i.e. the **inheritance graph** is sitting there unread.

- **The 128 `CRef*` refdata classes** (server), recovered from the same
  descriptor scan and readable straight out of the binary with `strings`. This
  is the join from the 85 SQL `_REF*` tables to the C++ that parses them, and
  it names several open ledger items outright: `CRefHWANLevel` (berserk),
  `CRefCharGen`/`CRefCharGenData` (starting Str/Int), `CRefDropGold`,
  `CRefDropItemGroup`, `CRefDropItemAssign`, `CRefDropOptLevelSel` and ten
  `CRefDropClassSel_*` (the loot tables, previously "right but
  under-specified").

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
