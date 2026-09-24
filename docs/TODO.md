# What's left

The single ordered list of open work. Each entry says what is known, what is *not*, and the next
concrete step — so picking one up does not mean re-deriving how it got here. Detail and evidence
for every item live in `docs/WORLD_ISSUES.md`; this file is the index.

Ordered by value per unit of effort, not by how interesting the problem is.

Two lanes are running in parallel: the **world** lane ([HANDOFF.md](HANDOFF.md)) has items 1-3,
the **UI** lane ([HANDOFF_UI.md](HANDOFF_UI.md)) has items 4-5. Each handoff covers its own lane —
where it stopped, the tools for it, the traps — and points back here for everything else.

## The playtest list (2026-09-11, from the first two evenings on the public server)

In order. Each is checked off here when it ships in a release, with its round in
`docs/WORLD_ISSUES.md`.

- [x] Old release against new server; monsters by code name; English column first; name plates in
      range; remembered server; debug panel (v0.1.87, round 134)
- [x] Animations on the `.ban` files' own clock; camera keeps its orbit; click targets the ground;
      town buttons (v0.1.88, round 135)
- [x] Alexandria's black houses (v0.1.89, round 136); text whole at fractional UI scales (v0.1.90)
- [x] Camera on its own pivot with the three views; sword hangs tip-down; gear for a character that
      has none (round 137)
- [x] **Monsters out of town** (v0.1.92). Mangyang and the Weasel moved from the fountain (62/44,
      -55/58) to measured flat farmland at world (0,-840) and (340,-340), south of the walls.
- [x] **ESC -> System window** (`ifsystemwnd`: Option / Help / Restart / Exit) -- round 138.
      Restart = login screen, Exit = quit, Option = the F3 settings panel. Still open: the
      **authored Option window** (`ifoption` + `ifoption_video`, its View radios and our UI scale /
      chat font / name range as its Setting tab) in place of the F3 panel.
- [x] **NPC talk.** A click on an NPC opens `if_npctalk` titled with its name -- round 139. The
      greeting's service lines are now clickable; Buy opens the shop and the storage line the
      warehouse (both below). The guild NPC's lines follow the player's guild (round 521): a
      guildless player gets the archive's "Create a new guild" (`UIIT_CTL_GUILD_CREATE`), which asks
      for a name and founds the guild, and a member gets "Leave guild." (`UIIT_CTL_GUILD_SECESSION`),
      which asks Leave / Cancel before it sends (our own prompt; the real client opens an unread
      window of kind 0x14 there). Typing in the name prompt no longer walks the character.
      Still open: the other guild lines -- the master's items 0x17, 0x14, 0x18 and 0x1b (a master
      keeps the "Guild" placeholder), and 0x19/0x1a, 0x1d and 0x43, which member and master both
      get -- and honour rank, each its own backend. A guildless player gets no "Buy" at a guild
      NPC, as in the real client, where the same `FUN_009870e0` test gates item 1 (round 524); a
      member keeps it. See `docs/protocol/character_state.md`, "The guild NPC's lines
      (round 521)". Still open for the guild store itself (round 530, record): the real server
      does not refuse the store to anyone. It refuses the goods, all of which have a guild-point
      price (PaymentDevice 8). A buyer with no guild, or who is not the master, gets `0x18c4`, and
      a guild short of points gets `0x18c5`, after the gold flag. srrevamp charges only the gold,
      so a guildless player who sends the buy is served. Needed: import the goods' device-8
      amounts, add the two refusals, and spend the points (its own item below, "The guild stores'
      guild-point price"; `character_state.md`, "What the server checks at a guild store (round
      530)"). Also open: the guild state behind the menu can go stale, because the server
      sends no guild broadcasts (`session/guild.go` answers only the requester). When the master
      leaves, `guild.Store.Leave` hands leadership to the longest-standing member, whose client
      keeps `_guild_master` false and still offers "Leave guild." until its next `guild_info`
      reply (world entry, or opening the guild window); only a refused leave asks again
      (disclosed in round 523). The job-guild NPCs (the 14 codenames the server gives ids
      0x14/0x16/0x15, e.g. `NPC_CH_DOCTOR`) show the archive's join line, such as "Join merchant
      guild", to a jobless player (round 526). Still open there: choosing it only says it is not
      available yet, and the client does not track the player's job, so a player with a job
      would see it too.
      - [x] **Storage (warehouse) -- items AND gold.** The talk menu's storage line (its text is
        the archive's own "Deposit into storage.", `UIIT_STT_NPC_CHATTING_WND_STOREHOUSE`, since
        round 513) opens the authored warehouse window (`ifstorageroom`) with the bag beside it:
        click to deposit/withdraw items (each a quantity dialog), and the money button opens a
        gold deposit/withdraw dialog -- rounds 168-169 / releases v0.1.139-140. The warehouse is a second inventory container
        (`storage_slots` table, `storage.Service`) plus a per-character `storage_gold` balance,
        reachable in real play from the grounded warehouse NPCs (`NPC_CH_WAREHOUSE_M`/`_W`). **Scope
        settled (round 215, v0.1.390)**: the warehouse and its gold are the ACCOUNT's, as the game's
        `_CHEST WHERE UserJID` / `_UPDATE_USER_N_CHAR_GOLD` say; every character on an account shares
        them, and the old per-character rows were moved over losslessly at boot. The capacity MODEL is
        read too (round 216, v0.1.391: per-user `_ChestInfo.ChestSize`, no in-binary default, paged
        by 30 in the client -- the authored page spinner now works; the ceiling is 210, round 270 --
        the 112 once recorded here is the quest-reward INVENTORY path); its DEFAULT is
        DISCLOSED as 50 (`storage.DefaultCapacity`) because the game writes it from the database's
        user-creation procedure, which no archive here holds. The warehouse expansion item is wired
        (round 498): +30 a use to `accounts.chest_size`, up to 200, then refused with 0x18fe. Still
        open: the linked storage and a growable bag (the bag expansion item is refused).
      - [x] **Merchant shop -- buy AND sell.** Talk -> Buy opens the authored store window
        (`ifstore`) with the NPC's real goods, tabs, real prices, quantity buying, and selling
        from the bag -- rounds 165-167 / releases v0.1.134-138. Per-NPC goods come from the real
        shop chain (`ShopReader`: refshopgroup -> ... -> refscrapofpackageitem -> item), so a
        smith sells weapons, not the whole catalogue. **Prices are REAL** (itemdata `_RefObjCommon`
        Price col 26 / SellPrice col 31; the old stat formula is now a fallback -- see round 166
        and GROUNDING_AUDIT.md). Stackables stack to their real MaxStack (col 57). The in-memory
        server loads items via `-items-csv` (qa_shot feeds `items.csv` beside the pk2s); PostgreSQL
        imports them via `import-refdata` (regenerate/re-import to pick up price + stack columns).
        Repair **done** (round 212, v0.1.386): per-item durability exists now and the authored
        Repair / Repair All buttons charge itemdata's own repair price. Still open: paging past 30 goods (no current NPC needs it).
        **Which stores show the repair buttons: done (round 514, `docs/RE_COMPLETION.md`).** The
        client's NPC-select reply handler (`FUN_0088b200`, `0x88b8c5`) hides Repair / Repair All at
        every selected NPC (the class test at `0x88b78b` is IsKindOf `CICNPC`). It shows them again
        only for an NPC with interaction 4, and vtable `+0x5c` is show/hide. The server gives id 4 to
        22 codename literals: the town `SMITH`/`ARMOR` NPCs and the fortress smiths
        (`CGObjNPCNPC::Create`, `0x4c677f` / `0x4c736f`). srrevamp derives it from the codename
        (`NpcServiceReader.offers_repair`) and hides both buttons at every other store. A headless
        test drives `_show_repair_buttons` on a synthetic store window (check (j) of
        `npc_service_reader_test.gd`). Not yet seen in a running client: a `SRREVAMP_QA_SHOP` run
        reading the `STORE` log line.
- [x] **Item tooltips** with the real stats -- round 140 (weapon attack, pinned against the Copper
      Sword +5 the user sent) and round 170 (armour/shield defence at columns 65-77, grounded from
      the DB column order + the cloth=magic / heavy=physical relationship). See ITEM_FORMAT.md.
- [x] **Paper doll** -- round 141: the equipment window (`O`) renders the dressed character live.
- [x] **Equipment slot icons** -- round 142: the worn slots show the equipped icons, slot i in
      GDR_EQUIPMENT_SLOT_(100+i), anchored to the user's screenshot. (Armour defence block now
      grounded -- round 170, above.)
- [x] **Skill window** -- round 143: the real China masteries (icons + names from
      `skillmasterydata` / the UI text table) at Lv 0, with the authored skill-point and
      mastery-total labels. **Now complete**: the per-mastery skill grid (the client-drawn
      `CIFSkillBoard`) is filled from `skilldata`, and the server tracks mastery levels and skill
      points (`OpSkillState`/`OpRaiseMastery`), so learning a skill and raising a mastery both
      work from the window. What is still own-design is the *mastery cost* (`masteryUpCost`).
- [x] ~~A new character spawns with placeholder 200/200 HP~~ -- **not a bug, checked 2026-09-19**:
      `MaxHPFor(StartingStr 20, level 1) = 200` exactly, and a respawn at 80 is the binary's
      `RespawnFraction 0.4` x 200. The two grounded numbers coincide with the old placeholder.
- [x] ~~Two `internal/session` full-flow tests race under host load~~ -- **not a race in the code**
      (2026-09-19): eleven packages' tests share the local `srrevamp_test` PostgreSQL database, and
      two `go test` processes on one host clobbered each other's rows (the trade test's 0x00DE was
      the system cancel from mismatched state). `internal/testdb.Lock` now serialises processes via
      an advisory file lock held in each such package's `TestMain`; two concurrent runs both pass.
- [x] ~~A non-gold drop's name plate shows the Korean column~~ -- round 210: the plate resolver used
      `textuisystem.txt` (zero `SN_ITEM_` keys) instead of `textdata_object.txt`; the potion's column 3
      is literally `HP ?? ??` in the archive. Every item-name site now resolves like the tooltips;
      a name the archive lacks shows nothing.
- [x] ~~Two ground-item drop models do not resolve~~ -- log noise, not a miss (2026-09-19): itemdata's
      drop paths are relative to `res\` (`Res\Item\Etc\drop_ch_money_large.bsr` exists, measured with
      pk2list); the client tried the bare path first and logged every miss before the `res\` retry drew
      the pile. It now tries `res\` first, so only a real miss is logged.
- [ ] **Drop content is the placeholder table only when an operator has no drop data.** Narrowed in
      round 332 (2026-09-20): a kill now rolls the REAL `_RefMonster_AssignedItemRndDrop` /
      `_RefDropItemGroup` tables through the engine's own arithmetic whenever rows exist for that
      monster, and falls back to the placeholder otherwise. The wiring was one field —
      `combat.Monster.RefObjID` — which `cmd/server`'s `monsterSpec` had carried since 2026-09-19
      without passing it down; the loaders, the store and the recovered roll had all existed since
      2026-09-15. What is left is DATA, not code: the per-monster tables are DB-only and in no
      archive we have (`smc.bak` is the manager DB), so an operator with the shard DB supplies them
      via `import-refdata -drops-csv/-drop-groups-csv`.
- [x] **Guild points and levels -- v0.1.434.** Points shipped in v0.1.433 (round 525); levels ship
      in the next tag, v0.1.434, with rounds 527-531. Read in round 272: a guild's points are the
      skill points its members earn (1:1, batched at 10 per member, credited to the guild total and
      the member's GP_Donation); the level-up costs are already in `guild.LevelUpCost`. **Points:
      done (round 525)** -- `Guild.GatheredSP` and `Member.GPDonation` are stored,
      `session.NewGuildPointSkills` credits them from the kill paths' skill-exp conversions through
      `guild.PointAccumulator`, and the Guild tab shows them (placeholder `OpGuildPoints`, refreshed
      on each guild reply, not live). The pending accumulator is in memory, as the engine's is:
      pc+0x2184 starts at zero on every new PC (CGObjPC::vslot_000, 0x4dea77) and FUN_004def90
      (0x4def90, its call to RequestAddGuildPoints at 0x4defbd) flushes any count above zero when
      the PC leaves the world;
      srrevamp flushes it on disconnect (`session.GuildPointsDisconnectHandler`) and at a clean stop
      (`FlushAllPending`, its own handling). That stop flush does not wait for the gateway's
      connection goroutines or the keep-up swings, so points booked after it passes a character are
      lost at exit (round 527, disclosed in `guildpoints.go` and `guild.md`). **Levels: done (round
      528)** -- `Guild.Level` is stored (`lvl`, DEFAULT 1), the master levels the guild up with
      `guild.Store.LevelUp` through the placeholder `OpGuildLevel` (the Guild tab's "Level Up Guild"
      button), refused in `CGuild::HandleLevelUp`'s order with its codes, the gold taken at the
      checked amount (as `FUN_005c8fd0`, the job's reply, takes it) and Join's cap following the
      level. A level-up that a server stop interrupts after the gold is taken refunds it on a
      context the stop does not cancel (round 531). **Still open:** the guild-point spend is a
      disclosed stand-in (the checked cost): the ShardManager decides it and is not in
      `SR_GameServer.exe` (`guild.md`, "What a level-up spends (round 528)"); the master's guild NPC
      line 0x17 (`UIIT_MSG_GUILD_LEVEL_UP`) still shows the placeholder; and other members learn
      the new level only on their next guild reply.
- [ ] **The guild stores' guild-point price (filed by round 530, a record round).** The engine
      refuses guild-store goods at payment, not at the store: every good the five
      `STORE_*_GUILD` stores sell has a PaymentDevice 8 row in `refpricepolicyofitem`, which the
      server loads as payment flag 8 with its amount at `+0x20` (`ReferenceData::FUN_006a99c0` ->
      `0x4b2bd0`, round 531). srrevamp charges only the itemdata gold, so a guildless player who
      sends the buy gets the crest. To build: (1) import each good's device-8 amount
      (`refpricepolicyofitem` joined through `refscrapofpackageitem`); (2) in `shop.Service.Buy`,
      after the gold test, as `GObjPC::CheckCurrencyRequirement` (`0x617360`) orders them, refuse
      `0x18c4` `UIIT_MSG_GUILD_STORE_BUY_LIMIT` to a buyer with no guild or who is not the master
      and `0x18c5` `UIIT_MSG_GUILD_LACK_GP` when `Guild.GatheredSP` is below the amount; (3) spend
      the points. Where the engine spends them is NOT followed yet: `0x618930`'s flag-8 arm copies
      the amount into the purchase record (`+0xa8`), and the reduction of the guild's total after
      that was not traced. `OpShopBuy` names only the item, which is all a price-keyed check needs.
      See `character_state.md`, "What the server checks at a guild store (round 530)".
- [ ] **Monsters move only with `-monster-ai` on, and do not chase or notice anyone yet.** They
      strike only when struck (round 254's cadence cap; the counter is still a synchronous reply in
      the player's attack handler). **Round 537 built the monster AI tick** (`session.RunMonsterAI`,
      `server/internal/session/monsterai.go`) behind cmd/server's `-monster-ai` flag
      (`SRREVAMP_MONSTER_AI`), which is **off by default**: SPAWN -> IDLE -> the 76-in-100 WANDER
      roll, legs at the walk speed pushed to the zone as `OpMonsterMoved 0x007C`, IDLE never
      stopping a leg under way (`0x559c80`), HOMING at the run speed past a 200-unit roam radius
      (own design), one `OpMonsterMotionList 0x007F` after each monster list, and an interim hold
      that stops a struck monster at the blow and keeps it in BATTLE while a keep-up of any player in
      its zone is on it, released only after two ticks in a row without one (round 539). It stands on round 536's core (the roster's real speeds, `combat.MoverStep` with both
      of the engine's clamps, the hub motion API, the pure rules) and round 533's client, first
      released in v0.1.435. Every stand-in is in `docs/protocol/monster_ai.md`, "srrevamp's
      runtime". What is left, in order:
      - **Turn it on for the public server**: once v0.1.435 or later is published with green CI,
        per `deploy/README.md`, "Monster AI (off by default)". The two render-box live checks in
        that section have passed: Run 1 in round 538, and Run 2 in round 539 with the
        fresh-snapshot QA GOTO.
      - **The strike and spawn pushes' server half**: round 540 built the client half
        (`OpMonsterAttacked 0x007D`, `OpMonsterSpawned 0x007E`, `docs/protocol/monster_ai.md`,
        "The strike and spawn pushes"). **Round 541 built the strike push's server half**
        (`session/monsterstrike.go`) behind `-monster-strike-push`, which is off by default
        (`deploy/README.md`, "Monster strike push (off by default)"). Its render-box live check
        passed in round 543 (`monster_ai.md`, "The strike push's server half (round 541)", under
        "Measured (round 543)"), and v0.1.436 (round 542) carries round 540 with a green release
        run, so what is left for it is the operator turning it on. **Round 542 built the spawn push's server half**
        (`session.BroadcastMonsterSpawned`: every roster respawn and GM `/spawn`, with the hatch
        heading rolled at the spawn) behind `-monster-spawn-push`, also off by default
        (`deploy/README.md`, "Monster spawn push (off by default)"). What is left for it is the
        same: its live check (`monster_ai.md`, "The spawn push's server half (round 542)"), then
        turning it on with that client release.
      - **mob-battle-chase -- BUILT in round 546, behind `-monster-battle` (off by default; forced
        off unless `-monster-ai` and `-monster-strike-push` are on).** The chase to the round-247
        band at the run speed (`MoveTowardObject` to `round(stop)`, the run clip) and the monster's
        own swing -- immediate on entering BATTLE, then every ReuseDelay through the action
        machine, round 545's timer read -- with the engine's `0x23`, `0x27` and `0x2a` exits, each
        blow the counter's own `monsterStrike` run off the tick and pushed as `OpMonsterAttacked`
        (`session/monsterai.go` `battleTick`; `docs/protocol/monster_ai.md`, "BATTLE's chase and
        the monster's own swing (round 546)"). With the flag on `performAttack` makes no counter;
        with it off the interim hold and the counter are unchanged, so the flag-off tests stand.
        What is left: **mob-counter-retire** (delete the counter branch, `CounterattackReady` and
        `lastBlow` once the flag is on for good, and rewrite the six counter-driven tests to the
        push), the flag's flip after a client release carrying round 546 and the live check
        (`deploy/README.md`, "Monster battle (off by default)"), and **the client's own id**: the
        client is not told its character id when it enters the world (`OpEnterWorldResult` carries
        none, and the round-546 rule kept every layout as it was), so a blow on itself with no
        counter result to pair with is recognised by elimination -- its target drawn as no other
        player in the zone, and not one who left inside `MonsterStrikes.LEFT_GRACE_MS`
        (`MonsterStrikes.is_own_unpaired`). The retail client is told its id at spawn; a message
        carrying it (a protocol addition, a user decision under `PROTOCOL_DECISION.md`) would make
        the pairing exact. Disclosed in the runtime: under retarget rule 0 a second attacker is
        never answered (the first attacker is the target until it leaves, dies or is out of reach).
      - **mob-acquire**: target acquisition (round 257: radius = BCRadius + `_RefTactics.+0x14`,
        the nearest player, no level term). The per-species distance is in no archive this project
        holds (the tactics table is shard-DB only), so it is disclosed per species when built.
      - **mob-aggro-link** (round 258): a party member's hit pulls in as many of the ten nearest
        monsters as the party has members within 1000 units, credited 100/50/25 % of the attack
        record's **hate**, and the struck monster books 1.15x that hate. *Corrected in round 537*:
        this line said "credit" of the blow. The link zeroes the record's damage (+4) before it
        forwards (`0x547797`), and both factors act on the hate (+8) (`CreditAttacker` `0x5473c0`,
        `OnAttacked` `0x558ebd..0x558ecc`). A solo hit links nothing.
      - Then the threat table's retarget rules (round 259, `ai.ThreatTable`, mob-threat-retarget),
        the second attack skill and the AI-skill triggers (round 260, mob-second-skill and
        mob-ai-skill-triggers), the HOMING wobble, and the server-side blocked probe that stops legs
        crossing walls (mob-server-geometry-probe; whether to turn the flag on before it exists is
        a user decision).
      Background, still true: a monster moves in retail by issuing the client's own movement
      request `0x7021` (`FUN_00540f70`; payload in `docs/protocol/opcodes/movement.md`, round 364),
      the retail shape srrevamp's placeholder push will eventually give way to
      (`PROTOCOL_DECISION.md`); the server's unprompted pushes are the 0x3NNN group of
      `docs/protocol/server_senders.tsv` (round 368).
- [ ] **Four roster species are drawn as capsules: their characterdata rows name no model (round
      533).** `MOB_CH_BIGEYEGHOST_CLON` (Small-eyed Ghost), `MOB_CH_GYO_CLON` (Old Weasel),
      `MOB_CH_WATERGHOST_CLON` (Water Ghost slave) and `MOB_CH_TOMBSTONE_CLON` (Tomb Stone Ghost)
      carry `xxx` in cols 52-56 of `characterdata_5000.txt`, and their display names resolve to no
      row that has a model (`probe_monster_front.gd`, round 533). Their base species
      (`MOB_CH_BIGEYEGHOST` ...) have models, but reusing one would be a guess until the retail
      client's handling of a `_CLON` row is read: find where the client resolves a character's
      `.bsr` and what it does with `xxx`.
- [ ] **NPC facing is a stand-in until `Tab_RefNest` is imported.** Round 510: the game faces each
      NPC by its nest row's `wInitialDir` (u16 at +0x1c, read by `Nest_Hatch` `0x5607b0`; radians =
      `wInitialDir / 65535 * 360 * pi/180`), which lives only in the server database -- no shipped
      file carries it (`npcpos.txt` is id/region/x/y/z). `NpcFacing` faces NPCs toward open space on
      the navigation graph instead, disclosed as own design. Next step: get a `Tab_RefNest` export
      (NestID, RegionDBID, LocalPosX/Y/Z, InitialDir) from a VSRO shard database, match rows to
      `npcpos` by region and position, and turn each NPC by the real angle -- through the same
      engine-to-Godot conversion as map objects (`NavGraph.godot_yaw`), after confirming the
      character-facing convention (the spawn packet's angle -> the body's front) in the client.
- [ ] **Exact fixed-function lighting**: a spatial shader whose `light()` scales the sun by the
      material's diffuse and the ambient by its ambient (round 136's stated approximation).
- [x] ~~Real spawn points for every roster species~~ -- **done, v0.1.403 (round 253)**: `export-refdata
      -mode npcpos` writes the game's 12,367 placements as a CSV and the server's `-npcpos-csv` gives
      every roster species with rows all of them (Yeoha's 26, Mangyang's 55 ...), replacing the town
      anchors; the public server runs with it. The anchors remain only as the fallback when no file
      is configured or a species has no rows.
- [x] **Auto-attack (keep-up) -- v0.1.406 (round 256).** One click fights to the death: the
      server repeats the plain swing every base-attack ReuseDelay (`session/keepup.go`), a skill
      with `AutoAttackType` 1 hands back to plain swings after CastingTime + ActionDuration, and
      a cast, a move, a zone change, death or a disconnect cancels. Read off
      `CGCharAutoCommandActor` (`docs/protocol/auto_command.md`). Left: the server does not walk
      the player, so a repeat out of reach ends the run (the original walks back in) -- this is
      the "attack distance" item below; and chain skills re-enter link by link in the original.
      **Correction (round 502): the skill hand-off never fired before round 502.** The exporter
      wrote `AutoAttackType` (skilldata col 19) as a literal 0. It now exports col 19 and
      `Basic_ChainCode` (col 9). The wait is PreparingTime + CastingTime + ActionDuration, since
      the engine folds PreparingTime into CastingTime at load. A row with a non-zero
      `Basic_ChainCode` does not hand off. A zero-damage row does not hand off either: the cast
      handler returns before the hand-off, although the engine's test ignores damage. That is a disclosed departure and affects the
      five `SKILL_EU_WARRIOR_DUALA_STUN_A_01..05` rows (ids 9245-9249). Of the 1,039 type-1
      player rows with no chain, 1,034 pass: 571 standalone castable rows and 463 final links
      of a chain, which the engine plays as the last step of their heads' chains (round 507).
      Needs a re-export of the skill CSV to take effect.
- [ ] **Chain skills, link by link.** The skill tick (`0x4ae590`) plays a row with a non-zero
      `Basic_ChainCode` (col 9, `+0x68`, exported since round 502) as a sequence. Phase 2 makes it
      the current link with its ActionDuration as the remaining time, less what is left of
      `+0x28`. The action's release (`FUN_004ac920`, `sAutoCommand::ReleaseAndClear` `0x4ac980`)
      seeds `+0x28 = 500` and zeroes `+0x2c`. On the link where `+0x28` runs out, the remainder
      moves into `+0x2c`, and phase 3 adds `+0x2c` to the final link's wait, so the final link
      waits up to 500 ms longer (`docs/protocol/auto_command.md`, phase 2). Phase 3 re-enters
      phase 2 with the next link's row, and only the LAST link's `AutoAttackType` decides the
      hand-off. srrevamp resolves only the row the player cast, so a row with a non-zero
      `Basic_ChainCode` resolves one row's blow and does not hand off (round 502's disclosed
      departure). Counted in round 507 on the player rows: 1,246 carry one, 582 true heads that no
      other row names (e.g. `SKILL_CH_SWORD_SMASH_D_01` -> 7140 `..._D2_01`) and 664 intermediate
      links. A head's `AutoAttackType` always equals its final link's (463 type 1, 49 type 2, 70
      type 0), so the departure costs the hand-off on the 463 type-1 true heads. (Round 502's "1,012 chain heads"
      was the type-1 rows with a non-zero column 9: 463 heads and 549 intermediate links.) Next:
      resolve each link's blow on its own timing, then apply the last link's hand-off rule.
- [ ] **Duel swings are not the base attack skill.** Round 505 made a plain PvE swing a cast of
      the weapon's base attack row (`session.plainSwingOf`: its `att` percent, `mc` hit count and
      mask). `session/duel.go`'s `handleDuelAttack` still deals one skill-less physical blow. Next:
      give it the same `plainSwingOf` terms, with a duel test that pins them.
- [ ] **A blocked hit with a skill percentage deals 1, not 0 (latent).** `combat.ResolveBlow`
      returns Damage 0 for a block, and `performAttack` passes it through
      `combat.ApplySkillPercent`, which floors the result at 1 for any positive percentage other
      than 100. The engine's blocked hit (state 2, `0x58f0ef`) jumps to the next hit (`0x58f0fe`)
      past the damage switch and its floor of 1, when the defender's `+0xd2c` (not identified) is
      0. Casts have had this since their percentages arrived, and round 505 gave plain swings a
      percentage too. No spawned monster blocks today (`combatSpeciesOf` never sets `Species.Block`), so
      nothing reaches it. Next: skip `ApplySkillPercent` for a blocked blow, with a test, before
      monster block is wired.
- [ ] **Mastery on the real rows: export `getv MAAT`.** Stage 1 of the damage pipeline scales
      the roll by the caster's mastery level, but `Skill_GetRequiredMasteryLevel` (`0x59e770`)
      returns 0 unless the row's `CRefSkill+0x574` is non-zero, and the only writer of `+0x574`
      is the row's own `getv MAAT` parameter (`SkillGlobal::RefSkill_ParseParams` `0x587630`).
      Measured on the retail rows (`/var/tmp/allskills.txt`): of the rows carrying `att`, 2,027
      of 2,028 `SKILL_CH_` rows carry MAAT but only 24 of 1,502 `SKILL_EU_` rows do (the EU staff
      and both wand base attacks among them). refdata exports no MAAT flag, so srrevamp gets it
      wrong both ways:
      - plain swings pass mastery 0 (round 505), where the engine scales the CH, staff and wand
        swings;
      - the cast path (`useSkillHandler`, `session/skill.go`, the `ref.Mastery1 != 0` block)
        scales every skill with a mastery slot, so it also scales EU attack rows the engine
        leaves alone (1,478 of the 1,502 EU rows carrying `att` lack MAAT).
      Next: export a MAAT flag in the skill CSV (a new trailing column, the round-504 pattern),
      then gate both paths on it (`combat.MasteryDamagePercent`'s `hasSkill` becomes "has a row
      with MAAT"), and give the plain swing the caster's level in the base row's mastery.
- [x] **Attack distance -- v0.1.431 (round 519); v0.1.432 (round 522: a cast ends the walk, a hotbar click no longer replaces it).** BUILT for the player: the server refuses a first swing or
      cast out of reach ("too far away", `session.firstSwingInReach`/`skillInReach`), and the client
      walks into reach before it sends (`World3D._attack_monster`, below). The monster's own approach
      in BATTLE is the "Monsters move only with `-monster-ai` on" item above (mob-battle-chase). The history: read in round 232: the SERVER
      never refuses on distance -- `0x3007 UIIT_SKILL_USE_FAIL_WRONGDISTANCE` occurs nowhere in its
      dump while its neighbours 0x3003-0x3009 all do (`Skill_CheckUseConditions`, `CanBeAttackedBy`);
      the original's CLIENT walks into range before it sends. Basic attacks (`SKILL_*_BASE_01`,
      `SKILL_PUNCH_01`) carry skilldata `Range` 0 = melee, so their reach is the WEAPON's range
      column; other skills carry 6..200 (150 for 6,889 rows). Next probe: the itemdata `Range` column
      (the tooltip's "0.6 m" on a sword) and the client's comparison that turns skill/weapon range
      plus the target's `BCRadius` (column 50) into world units -- then a client-side approach step.
      Round 233 read the TABLE unit: every distance param the client prints goes through
      `value / 10.0` with `%.1fm` (`ICPlayer::FUN_00960b50`, divisor at `0xe1b840`), so skill/weapon
      ranges are in tenths of a metre (melee 6/10/17 = 0.6/1.0/1.7 m). Still unread: metres to world
      units. Five readings agree with 1 unit = 0.1 m (walk/run 16/50 = 1.6/5.0 m/s, region 1920 =
      192 m, fog 1250..2250 = 125..225 m, character 14.3 = 1.43 m, lamp 19.9 = 2 m) -- corroboration,
      not a use-site; do not wire a range on it until the approach comparison is read.
      Round 234: the weapon's own reach is `PARAM_RANGE`, the client item record's field at `+0x254`
      (tooltip `UI_SILKMALL::FUN_0066c5b0`, printed /10 in metres); offset greps for its consumer hit
      only tooltips. PARKED after three ticks. Route left: the client's attack send site (the action
      packet's `GInterfaceSend` caller) walked back to the distance test that precedes it.
      **Round 247: THE RULE IS READ, and it is the SERVER's, not the client's** -- round 232's "the
      client walks into range before it sends" was wrong; the client sends at once and the server
      walks the attacker. `CGCharAutoCommandActor::Tick_Attack` (`0x4ad8e0`; round 247 called it
      `GObjPC::ActionTick_UseSkill`, corrected in round 256): reach = casterBCRadius +
      targetBCRadius + range, stop = the same base + f(range) (f = r for r <= 4, r - 2 for 4 < r < 10,
      0.7 r for r > 10; at exactly 10 neither stop nor reach gets the range -- round 488), range =
      the skill's Range or the weapon's Range column (itemdata 94 = param 33: sword 6, spear 18,
      bow 180, dagger 3), in reach when `int(dist) <= reach + 2`, else
      `MoveTowardObject(target, stop)`. Table units ARE world units (1 = 0.1 m) -- the comparison
      has no conversion. `combat.ApproachBand`/`InReach`/`EffectiveRange` carry it, `refdata.Item.Range`
      and `combat.Species.BCRadius` the data (v0.1.400). Round 256: the tick is
      the plain-ATTACK tick of `CGCharAutoCommandActor` (the skill tick 0x4ae590 computes the same
      band, but only for a skill that needs a target -- see round 519 below); the keep-up's REPEATS are gated by the reach test (`session.keepUpInReach`) -- a
      repeat out of reach ends the run -- and since the 2026-09-20 playtest the first click and a
      cast are too. **Round 519 built the walk on the client** (srrevamp's server does not drive
      player movement): `CombatNet.approach_band`/`in_reach`/`approach_point` mirror `combat/reach.go`,
      the BCRadius comes from characterdata col 50 by code name, the weapon's Range from itemdata
      col 94 (0 while broken), a skill's from its level's own skilldata col 21; an out-of-reach
      click walks toward the stop distance, re-tests reach every frame (phase 1 re-tests every tick;
      its in-reach branch drops the MoveTowardObject target via `FUN_004b0450`) and sends on the
      first frame in reach, after flushing the position -- a later OpMove would cancel the keep-up.
      A cast of a skill with `Target_Required` 0 (skilldata col 22) or a land target (col 22 = 1
      and `TargetType_Land` col 24 = 1) goes out at once with no walk: `Tick_UseSkill` phase 0
      jumps straight to phase 2 for both (`0x4ae743`, `0x4ae753`; `CombatNet.skill_tick_approaches`)
      -- 115 of the 264 level-1 China board rows, the self heals and shields among them. Measured
      live: a Yeoha clicked from 40 units is approached and struck ("in reach at 23.3 (reach 21.0
      +2)"), where the same run before the change logged "attack refused: too far away". Still
      open:
      - a keep-up repeat that finds the target out of reach ends the run (the engine walks again);
      - **a filed server departure**: srrevamp's server reach-gates the `Target_Required` 0 rows
        that deal damage (the exporter's `ZeroDamage` 0, run over the box's skilldata tables):
        147 China board rows, every level of the
        15 `SKILL_CH_COLD/FIRE/LIGHTNING_GIGONGTA_A..E` skills, all `Basic_Activity` 1. The engine's
        skill tick computes no band for them: an Activity other than 2 returns at `0x4ae6ea`
        without leaving phase 0, before the `Target_Required` test at `0x4ae743` is reached (that
        test would skip the band too, since all 147 carry 0; re-worded in round 527). But `session/skill.go`
        resolves them as a blow on the selected monster behind `skillInReach`, so a cast with a
        distant monster selected is refused "too far away" -- as it was before round 519. The
        client sends them at once. Next: read what the engine does with an Activity-1 row
        (`0x4ae9dc` returns 1 without a phase change; not followed) before touching the server;
      - the in-reach send trusts the displayed monster, which is exact only while monsters stand
        still server-side. **Round 533** made the aim follow the drawn body (`_step_monster_bodies`
        writes its x/z into the snapshot), but the drawing lags the server by one-way latency x
        speed, and the server measures a round trip after the client did. The error at the server is
        therefore v x RTT, plus up to one AI tick of v (the server's position moves in tick-sized
        steps). The margin it meets is NOT the +2 slack: released on the first frame in reach, the
        walk sends from the slack's outer edge, about 0-0.7 units inside it at a 42 u/s closing
        speed (a 50 u/s run against an 8 u/s walk, at 60 frames a second). So a monster walking away
        at 8 u/s was refused at any round trip above about 90 ms (1.2 units at 150 ms). Two changes
        answer it (round 533): while `_monster_motion` says the target is walking, or after a
        refusal, the walk releases only inside the stop distance (`CombatNet.approach_releases`), a
        margin of at least 3 units (`int(d) <= reach + 2` holds for every d below reach + 3, plus
        whatever the reach exceeds the stop by); and a "too far away" refusal of an attack the walk
        released walks again, up to `CombatNet.APPROACH_RETRY_CAP` (3, srrevamp's own) times -- a
        plain swing only since round 534: a refused SKILL is not sent again, since the client plays
        the cast when the request goes out, and the server now charges nothing for a cast refused as
        too far away (`session/skill.go` tests the reach before it spends HP/MP or arms the cooldown,
        as `Tick_UseSkill` walks before its phase-2 post), so the player's own retry pays once. That
        holds while v x RTT stays under the margin: 8 u/s up to about 375 ms. A RUNNING monster
        outruns the 50 u/s player and is never reached: 9 of the 11 roster species run at 55 u/s or
        more (Earth Ghost 75, 11 units of error at 150 ms), and only Mangyang (22) and Yeoha (20)
        run slower (`monster_ai.md`, "The roster's real walk and run speeds").
        Measured in a headless simulation (`monster_motion_test.gd`, 150 ms), not against a live
        moving monster: no server moves monsters yet, and a render-box check on localhost has a
        round trip near 0, so before the server's monster AI is switched on publicly, check the
        approach at the band edge against a moving monster with real latency;
      - a walk that geometry blocks never reaches the band and nothing times it out, the same as a
        plain click-to-move: the attack waits until WASD, typing or another click;
      - the debug panel's Skills-tab "Use" button (`World3D._on_skill_use_pressed`, a developer
        panel, not the HUD) still sends `use_skill` at once with no approach walk, so a DAMAGING
        cast out of reach earns "too far away" (and, since round 534, costs nothing). A non-damaging
        one is accepted at any distance: `session/skill.go` skips `skillInReach` for a `noCombat ||
        zeroDmg` row (NoCombatParam / ZeroDamage; round 527). Its reply no longer counts as the reply
        to an attack the approach walk released (round 534 clears `_released_attack` there). The
        hotbar's casts go through `_cast_skill` -> `_attack_monster`.
- [x] **Four HUD surfaces let clicks through to the world -- done (round 529).** Round 522's
      review measured a click on the player-info block, the minimap's map, the target window or the
      hotbar's body away from its slots reaching `World3D._unhandled_input`, where it counts as a
      click on the world. Each of the four roots is now `MOUSE_FILTER_STOP`, as HudWindow and the
      chat are. Each root's rect is exactly its drawn body (the frame, or the hotbar's 800x52
      `BarBackground` rect), and Godot 4.2.2 returns a control for a click only inside its own
      rect, so the empty space above the hotbar still reaches the world. The hotbar's body fires the
      middle-button quickslot itself, as its slots do. The camera orbit's motion is now read in
      `World3D._input` (`orbit_motion_applies`), so a right drag keeps turning over any STOP
      control and is applied once over the world. `npc_service_reader_test.gd` check (o) drives
      real events through the live viewport. **Not driven:** a real click in a running client, and
      the surfaces built from Media.pk2. **Behaviour that changed with it:** a right press on any of
      the four starts no orbit, as over a window. A middle press on the minimap, the player-info
      block or the target window fired no quickslot, and the developer Hide UI button, then under
      the minimap's corner, could no longer be clicked; both fixed in round 531 (the three share
      the hotbar body's relay, `HudUnderbar.relay_middle_button`, and the button is `UI/Control`'s
      later sibling, left of the minimap; `hud_click_routing_test.gd`).
- [ ] **`HudMinimap` and `HudUnderbar` are built twice (read from the code in round 529, not
      measured).** `World3D._try_initialize_pk2_ui` adds each to the tree, and each one's `_ready`
      runs `setup()` because it has no children yet. Then World3D calls `setup()` again, and the
      second call builds a second frame and layout on top of the first. For the hotbar,
      `_slot_nodes` then indexes only the second set of slots, so a page flip hides and shows only
      those. Fix: call `setup()` before `add_child`, or guard the second call. Then check it with
      the built tree (`tools/dump_window_tree.gd`-style) before and after.
- [ ] **Linear fog between the real planes.** Read in round 229: the client's fog is D3D linear fog
      from `channel 10 x view distance` to `channel 11 x view distance` (2500 by default) -- zero
      until the near plane (Jangan: 1250), complete at the far one (2250). `FOG_DENSITY` is an
      exponential-from-the-camera stand-in because Godot 4.2 has no depth-range fog; the honest
      fix is a full-screen depth pass (a quad with `hint_depth_texture`) or per-material fog code
      applying `(d - near) / (far - near)` with the zone's real FogColor. The planes are already
      computed and logged (`World3D: environment fog planes`, and in QA_LOOK).
- [x] ~~Day/night cycle~~ -- **not a gap** (round 226, `docs/protocol/game_clock.md`): the retail
      client renders the environment at a FIXED phase of 0.5 (SWorld's constructor sets it; the
      per-frame advance is gated by a flag nothing sets; the graphs are sampled at the raw phase), and
      the server clock (`0x34be`) feeds nothing in the sky. `ENVIRONMENT_REFERENCE_TIME = 0.5` is now
      read, not disclosed. The engine's dormant machinery (0.0005/s = a 2000 s day, sun angle
      `(phase-0.25)*2pi`) is recorded should a live cycle ever be wanted as our own design.
- [x] **"Stuck in a building"** (round 213): the cause was `NavGraph`'s own rule -- footing inferred
      from height let a terrain mover walk through a shop wall whose floor sat 5 units up, get
      lifted onto the floor, then be held by the same walls from inside. Replaced by the client's
      actual walk (`docs/protocol/NAVMESH_MOVEMENT.md`: on the terrain or on exactly one object;
      entry only through an outline edge with bit 0 clear; on an object only its own edges apply,
      directionally; `0x10` = underpass; push 0.01). `nav_graph_test` 55 checks; `tools/walk_probe.gd`
      traces it on real Jangan in ~10 s. "Floating things in Alexandria": the measured sweep found
      0 floats > 12 in Alexandria, Hotan, Constantinople, Samarkand and the three Jangan regions.
- [ ] Movement follow-ups from round 213: `_avoid_spawning_under_roof` relocates a QA start
      without consulting the graph (once onto a shop floor); linked edges (`0x08`, the hand-over
      between objects) and event gates (fortress/dungeon doors, `0xc0` bits) are documented but
      not implemented -- no town object uses either.
- [x] Battle stance (round 132, hold duration read in round 218 / v0.1.392): the player HOLDS
      the real STAND_BATTLE clip while recently in combat; the hold is now the server's own
      rule -- BattleState (SetCharacterState type 8) is entered with a 20-tick countdown in the
      PC's periodic update (`CGObjPC::vslot_415`) and reverts to peace at zero. What is still
      **read** in round 223: that update is the PC's 1.0-second timer job (`CGObjChar::Create`
      registers it with `fld1`; the timer vector is ticked by `CGObjChar::Update` with the main
      loop's seconds delta), so the stance lasts 20 s -- and berserk's 60 s and regen's 4 s are
      read in the same pass (`docs/protocol/character_state.md`). Left: srrevamp's server carries
      no battle-state byte, so other players do not see the stance.

## Next up

### 0. Monster HP bars, click-to-attack, target window, damage numbers — **done** (rounds 146-149)
Monsters show a name plate and a billboarded red HP bar that shrinks on each hit, a left click
on a monster attacks it (NPC->talk, monster->attack, ground->move), the current target shows at
the top of the screen, and every blow floats a damage number that rises and fades -- white for
damage the player deals, red for damage taken (round 149). Combat behind it is still the
placeholder damage until the round-145 refdata is imported (operator's call, `deploy/README.md`).

**The combat loop — done** (rounds 171-173, releases v0.1.142-144). The world has the real Jangan
monster ladder (Mangyang through Yeoha, 23 monsters across two hunting grounds; grounded
identity, one disclosed level-scaled stat curve). Leveling pays off: max HP grows with level, and
the level label, HP-bar maximum, underbar EXP gauge and SP are fed live from the stats packet
(the EXP curve itself, leveldata.txt, is real). And the berserk gauge fills through combat on the
authored five orbs, unleashing a damage burst on **R**.

Since then: **monster max HP is REAL** (characterdata col 59, recovered from the server binary --
round 175, v0.1.147), **mana exists and is spent** (skills pay their real `Consume_MP`;
v0.1.149-150, with the level curve's *growth* recovered and its base disclosed), and **potions
work** with the item table's own restore amounts (v0.1.151). Still disclosed own design: monster
defence/attack/gold, HP-per-level, the berserk numbers, and skill damage.

### 1. NPCs — **done, except that they are statues** (hundred-and-fifth round)
12,367 spawns and 5,423 models read from the player's own Media.pk2, each assembled from its own
`.bsr` by `SkinnedBsrAssembler`. 18 of 19 placed in Jangan town, 45 across the loaded grid.

**Names are done** (hundred-and-twenty-first round): 13,169 resolve from `characterdata*.txt`'s
`SN_` key through `textdata_object.txt`, and every placed NPC carries one. The plates are drawn
screen-space, which is why they are visible at all — and why the monster labels became visible at
the same time.

**Facing is settled as a negative**: `npcpos.txt` is 12,367 rows of exactly five columns (id,
region, x, y, z) and the archive has no other NPC table, so there is no authored facing anywhere.
Any direction this project turns an NPC would be invented. Not an open question.

**Blocking is done** (hundred-and-twenty-second round): each NPC carries a capsule sized from its
own geometry, on the layer the player masks and the camera does not. `SRREVAMP_QA_NPCBODY=1`
reports the capsule and whether a ray is actually stopped — 5 of 5 in Jangan town.

**What is left**: nothing on this item. NPCs stand, animate, are named, and are solid.

**Animated, and properly skinned** (hundred-and-tenth round). `.bms` does carry per-vertex
skinning after all -- a bone palette and two weighted influences per vertex, in their own section
pointed at by header word `0x10`, which is why an audit of the 44-byte vertex record found none.
NPCs now deform correctly and animate; `SRREVAMP_NO_IDLE_ANIM=1` turns animation off.

### 2. Monsters as real models — **done** (hundred-and-fourteenth round)
Verified against a live server rather than asserted: `Mangyang -> mob\china\mangnyang.bsr` and
`Weasel -> mob\china\gyo.bsr`, both assembling a real skeleton, both standing in Jangan beside
the player. The client logs what it resolved for each, so the three ways this can go wrong —
species not in the tables, model not assembling, model placed out of reach — tell themselves
apart in a playtest log. They used to be the third: 292 and 461 units from spawn.

### 3. Equipment on the character — **done, and now drawn from the game's own data** (hundred-and-thirty-first round)
A new character is dressed by the server and the client renders it. Two bugs were in the way and
neither was on the client: the starting kit could not be given at all (an item with no reference
row could not be *held*), and ten request handlers were rejecting the client's listings as
malformed. Both are fixed and tested end to end.

**What each item looks like is no longer chosen by the client.** The item table's column 52 names
the model every item is worn as, the model's own `.bsr` says how it hangs on the body, and the
body is a `characterdata` row like any NPC's -- see `docs/protocol/ITEM_FORMAT.md`. The wearing
rules (slot, race, gender, level) are the table's too, enforced by `equipment.Refusal`.

**Open on this**: requirements by mastery level and by stat are read but not enforced (nothing
tracks them); characters have a level but no way to gain one; accessories (slots 9-16) are not
modelled; the item `.bsr`'s effect attachments (`.efp` on `Bone04`/`Bone06` of a shoulder piece)
are not drawn.

### Rendering against a real server
`qa_shot.sh --server` starts the server in memory on a spare port and signs the client in
(`SRREVAMP_QA_SERVER`, `--say` to send a chat message). Every render before this was of a client
with no server, which is why the character was bare, the health bar blank and the panels empty in
all of them. Use it for anything the server owns.

### 4. A minimap (Implemented — one-hundredth round)
The live minimap is now wired through the authentic PK2 UI pipeline (`scripts/ui/hud/hud_minimap.gd`
loading `resinfo/ifminimap.txt`): displays the region's own art (`minimap\<y>x<x>.ddj`), aperture
clipping, rotating heading arrow (`mm_sign_character.ddj`), and real-time X/Y coordinate readout
derived from the ninety-seventh round's recovered coordinate math.

### 5. Break up `client/scripts/World3D.gd`
5,259 lines, against 800 for the next largest file — and now the file both lanes would edit at
once, which makes this deconfliction as well as tidying.

**The UI is the big piece and goes first**: 79 of the file's `@onready` node references and 75 of
its 162 functions are UI handlers, wired by 96 `.connect(` calls in code (the scene has only 2
`[connection]` entries). Moving them into `client/scripts/ui/` plus its own scene leaves the two
lanes touching disjoint files. Do it incrementally — one tab, run the suite, commit — since a
big-bang refactor of a file another agent is editing will not merge. See
[HANDOFF_UI.md](HANDOFF_UI.md)'s "Do not collide".

The QA harness at the bottom is a separate ~600 lines of pure diagnostics with no gameplay
coupling; it belongs to the world lane and moves out on its own. Region loading and streaming is
the next cohesive piece after that.

### The UI lane's own list is [UI_TODO.md](UI_TODO.md)
Panels, the window recipe, and the reference screenshots. The item below is the part of it that
touches this file.

### Retire the debug UI now the real HUD is in — **nearly done**
Gone: the ten-tab `ActionTabs`, the corner labels, and (hundred-and-sixteenth round) the chat
panel, which `HudChat` replaces with `ifchatviewer.txt`'s own window. Thirteen authored panels
are built and reachable from the underbar's MENU and from hotkeys.

**What is left**: the Change Zone box and the Log Out button. The zone box has to stay until
there is another way to travel — it is the only one — so this finishes with a real travel
mechanism rather than with a deletion.

### Tester tools: the chat console, GM commands, the Help window — **done, with these left**
`docs/DEBUG_TOOLS.md` and `docs/rounds/debug.md`. Left out of that lane: (1) the original's help
dialogs / web panel were not recovered — the Help window's interior is ours inside the authored
`ifgameguide` frame; (2) `/give` by item *code* is client-side only (the server's item table has no
code column), so a code the client has not loaded is refused; (3) a GM `/spawn` reaches other
clients only on their next monster list **on the public server today**: round 542 built the push
(`OpMonsterSpawned 0x007E`, behind `-monster-spawn-push`), but the flag is off by default and its
live check is still to run, so this closes when the operator turns it on (`deploy/README.md`,
"Monster spawn push (off by default)"); (4) ~~`client/docs/RELEASE_NOTES.md`
is a committed snapshot~~ — done at merge: the release workflow fetches tags and runs
`bundle_docs.sh` before the export, and `internal/systems/bundled_docs_test.go` keeps the committed
copies equal to `docs/`; (5) the GM run's `SRREVAMP_QA_COMMANDS` verification used frame ticks
because a `SceneTreeTimer` did not fire inside a movie-writer run — worth understanding; (6) ~~**a real bug
the tools surfaced**: every zone change prints `Trying to assign invalid previously freed instance` from
`_tick_idle_animations` (World3D.gd:3406) ~125 times~~ — fixed at merge (round 214): the raw
Variant is checked with `is_instance_valid` before the typed assignment.

## Parked, with the state written down

### Moat water
The moat is real, located exactly (96/168 local 1490, 1470 — the ninety-seventh round), and the
terrain carries its trench: **-40.00** in a narrow band against **+0.65** either side, with the
plane cell over it at level **-20**, which would fill the trench and nothing else.

**Why it is parked**: the same region sits at about **-45 across its southern third**, which that
same level would flood, and the art there is farmland. Neither the plane map (30 of 36 cells are
type 1) nor the tile map (no water tiles anywhere in the region) can separate the two.
**Cheapest next step**: a reference screenshot standing in that southern area — if it is dry in
the real game, the plane level alone cannot be the rule, and that halves the search.

### Scenery still off the ground
83 objects fell to 60 once each `.o2` entry was assigned to the region whose heightmap explains
its height (eighty-fifth round). The rule resolves small scenery reliably and **cannot** resolve a
large structure standing on its own platform, whose base has no reason to touch the terrain.

### The `cj_s` city wall's copies
Down from six to two or three. The surviving one currently lands correctly because an unauthored
band of zeroes beats the regions with real data — luck, recorded as luck in the eighty-sixth
round, not a working rule.

### Objects you could walk inside — **fixed** (hundred-and-twenty-third round)
It was 232 objects world-wide, not the eight Jangan ones the count named. The graph resolved an
object by its **first** mesh only, and a building's walkable surface is one piece among many in
alphabetical order — `cj_luxu_floor.bms` is the fourth of twelve. All of an object's meshes are
read and merged now. Every region around Jangan places 100% of its objects, and `SRREVAMP_QA_SCAN`
finds none of the eight among the spots that put a player under solid geometry; what it still
finds is tree canopies and balloons, which is what walking under a canopy looks like.

### Two `.bms` header sections nobody reads
**`hdr[2]` is decoded** (hundred-and-twenty-fifth round): one 8-byte record per vertex — a
`float32` on a 0.05 ladder and a `uint32` that is 1 in exactly the records whose float is zero.
801 of all 24,984 meshes carry it, and they are garments, banners and cobwebs. `BmsReader` reads
it into `vertex_motion` / `vertex_pinned`; what it is *for* is an inference, recorded as one.
**`hdr[3]` is decoded too**: a count and that many 12-byte links, each two vertex indices and a
distance — verified across 58,433 records with every index inside the mesh and every distance
positive. What is *still* open is the trailer after those records, small integers all below the
link count, in every one of the 801 files.
`hdr[5]` was checked at the same time and is empty in all 1,200, so nothing is missed there.
What the two carry is unknown, and the meshes render correctly without them.
`client/tools/audit_unused_header_words.gd` reproduces it. See
[protocol/BMS_FORMAT.md](protocol/BMS_FORMAT.md).

This audit exists because of a pattern worth reusing: **three settled conclusions in this project
were overturned by re-reading data, and the tell in every one was a header word parsed and never
used** — the `.bsr` offset table, the `UV_*` fields, and `.bms` skinning. Grepping the other
readers for the same shape found none, so this is the last of it for now.

### `.o2` list semantics
List 2 is a region's own objects and the others are cross-references, measured at 91% against 46%
on the sector check. What the three lists *are* is still unknown.

## Established, do not re-derive

Each of these cost real time and is recorded with its evidence. Check `docs/WORLD_ISSUES.md`
before contradicting one.

- Region axes: region **y** → world X, region **x** → world Z.
- Client position readout: `X = (region_y - 135) * 192 + local_x / 10`, `Y = (region_x - 92) * 192 + local_z / 10`.
- Minimap filename is `minimap\<y>x<x>.ddj`.
- Placements resolve against **Map.pk2's** `object.ifo`, not Data.pk2's.
- `.bmt` layer flag **bit 0** marks an alpha layer.
- A `.ban` keyframe **replaces** a bone's local transform; it is not a delta.
- Navmesh plane **type 1 is not water** — it covers a quarter to all of every region.
- A bind pose is a poor test of a rig: both character bugs this project had were invisible at rest.
