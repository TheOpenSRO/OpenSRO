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
      Restart = login screen, Exit = quit. Option opens the retail Option window since round 615
      (CNIFOption from `res_ui\optionwnd.2dt`, the window the button really opens -- not the
      `ifoption*.txt` family); its Audio tab works. Still open: its Video, Input and Game tabs
      (our UI scale / chat font / name range / camera views stay on the Ctrl+F3 debug panel).
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
      - **mob-player-dead-state -- BOTH halves are BUILT**: the client half in round 548 (the die
        clip held, movement and attack input locked, a Revive button sending `OpRevive 0x0028`,
        `OpReviveResult 0x0029` decoded, `SRREVAMP_QA_REVIVE_AFTER`), the server half in round 549
        behind `-player-dead-state` (off by default; `docs/protocol/monster_ai.md`, "The player's
        dead state: the server half"): a monster's kill leaves life state 2 at HP 0 in the result
        and the push (no `RespawnHP`), the potion queue emptied as `FUN_004e67b0` does and
        `potionQueueTick` landing nothing on life state 2 (`0x4a87e8`), moves neither stored nor
        relayed, attacks, casts, items (`0x1889`), pick-ups, duel blows, trade requests (`0x181d`),
        zone changes and GM `/tp`/`/goto` refused, AI targets dead-invalid (`AITactics_IsValidTarget`),
        `ReviveHandler` in place at `character.RespawnFraction` with an MP refill and a stats push,
        the 30 s auto-revive fallback (own design) and revive on entry for a character logged out
        dead (the load path's fraction). **What is left, in order**: (1) tag the client release that
        carries round 548 and confirm its `Release client` run is green BEFORE the flag is ever
        flipped; (2) the render-box live check (`SRREVAMP_PLAYER_DEAD_STATE=1`, `/spawn` a killer,
        `--attack`, assert HP 0 then "Revived." after the button or `SRREVAMP_QA_REVIVE_AFTER`);
        (3) the flag's flip (`deploy/README.md`, "Player dead state (off by default)"). Stand-ins,
        each disclosed at its line: reviving in place above max level 10 (retail returns the
        character to `_CHAR.AppointedTeleport`, `CGObjPC::ResolveRevivePoint` -- srrevamp has no
        appointed teleport; its town gates, round 576, move a player but record no return point), the empty request against retail 0x7053's u8
        option, the fallback and its 30 s, the refusal wording, the pick-up / duel / zone-change / GM
        refusals (their retail handlers not read for a life-state test), the item kind usable while
        dead (`(tid & 0xf800) == 0x3000` in `Item_HandleUseItem`), the duel's own death path (still
        `ResetHP`, alive: which death kind a duel is remains unread), and revive at entry rather than
        staying dead across sessions. Not modelled: the siege countdown gate, the cause-2 branch.
      - **mob-acquire** -- BUILT in round 552 behind `-monster-aggro` (default off; forced off
        unless `-monster-battle` is in effect and `-player-dead-state` is on): target acquisition
        (round 257: radius = BCRadius + `_RefTactics.+0x14`, the nearest player, no level term) with
        the cadence, the aggression roll and the truncations read for it (`monster_ai.md`, "Target
        acquisition: the runtime (round 552)"). The per-species distance is in no archive this
        project holds (the tactics table is shard-DB only), so it is ONE disclosed stand-in for
        every species, 100 (`ai.TacticsDetectionDistance`), with every species aggressive
        (`ai.TacticsAggressionMode` 0) -- both user decisions; a per-species table is the open
        follow-up if one is ever wanted. Left: the flag's flip (`deploy/README.md`, "Monster aggro
        (off by default)"), after its live check's result in that section.
      - **mob-aggro-link** -- BUILT in round 553, riding `-monster-battle` (no flag of its own):
        a party member's first hit on a monster not yet fighting pulls in as many of the ten
        nearest other monsters (within its detection radius scaled by the level gap, chopped to an
        int) as the party has members within 1000 units (inclusive), nearest first, no cascade; a
        solo hit links nothing (`monster_ai.md`, "The aggro link: the runtime (round 553)"). The
        forwarded hate -- 100/50/25 % of the record's **hate**, floored at 1, the victim booking
        1.15f x it (round 537's correction of round 258's "damage": the link zeroes the record's
        damage (+4) at `0x547797`; `CreditAttacker` `0x5473c0`, `OnAttacked` `0x558ebd..0x558ecc`)
        -- is not carried: srrevamp's blows have no hate value, and the magnitudes wait on
        mob-threat-retarget. Live check not feasible with one driven client.
      - Then the threat table's retarget rules (round 259, `ai.ThreatTable`, mob-threat-retarget),
        the AI-skill triggers (round 260, mob-ai-skill-triggers; the second attack skill is built,
        round 554), the HOMING wobble, and the server-side blocked probe that stops legs
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
      Round 637 read that conversion: the heading is the wire angle plus pi/2 (`FUN_009c40b0`), and
      heading `h` faces `(sin h, 0, -cos h)` region-local, which is `rotation.y = h` on a +Z-front
      node (`RemoteFacing`). Whether `wInitialDir` goes through the same `+pi/2` is not read.
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
- [x] **Self-cast and ground-cast skills (client) -- round 617.** Grass Walk, the imbues and every
      Target_Required 0 row cast with nothing selected (OpUseSkill targetType 0); Ghost Walk picks a
      ground point (targetType 2; right click / Escape cancels); OpBuffStart/End/OpSkillMove are
      decoded (`NetClient.buff_started` / `buff_ended` / `skill_moved`, `send_buff_cancel`), the
      buff's `runSpeed` sets the run speed and OpSkillMove snaps the player. Still open:
      the server half (round 616) was not live-tested with it; the Ghost Walk move is a snap
      (duration OPEN, `tele` value[0] = 500 unread); retail's ground-pick cursor and decal (the
      cross is ours); the retail answer for a Target_Required 1 heal with nothing selected
      (READ in round 622: refused, 0x3011); the targetType echo, ownerKind and OpSelfId 0x00F9 (review
      follow-up) need round 616's server to send them -- until then the client falls back to the
      request queue and learns its own id from its own casts' answers;
      an old server's keep-up ends on any cast, a self-cast included (`keepUp.Cancel` in
      `useSkillHandler`) -- whether retail's auto-attack survives a buff cast is not read.
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

**Round 626 (a full Degree-11 set drew bare-chested with a see-through spear) left these open:**
- **The full-set model switch.** 88 Degree-11 SET_A/SET_B rows list two models; the client draws
  the second (`*_fullset.bsr`, the same mesh plus e.g. `heavy_11_set_b_fly.bms`) only while the
  whole refsetitemgroup set is worn, and plays `ITEM_SETITEM_ACTIVE` (ITEM_FORMAT.md has the
  addresses). We draw the first always. Building it needs the item's set id (record+0x1d4) and
  refsetitemgroup's slot count; the full-set layers (`heavy_11_set_b_fly` 59.6% transparent,
  `*_ef_alpha`) are authored translucent, so their draw state (any MTRL mod in the fullset
  `.bsr`) has to be read first.
- **Enhanced-gear glow.** `CRTModProgEquipPow` (BMT_FORMAT.md) is attached only to a +N item
  with a matching glow row; it overrides the material state entirely. Not modelled.
- **Object-space skin entry.** An empty skin slot lands on the client's palette entry 0, drawn
  here in the model's own space (BMS_FORMAT.md). That entry 0 is the object transform is
  INFERRED, not read from the vertex shader's constant upload.
- **Object brightness against the client** (material review follow-up). The client draws
  texture × lit diffuse × 2. Our flag-word path is tuned by eye (light energy 0.3, round 43).
  Before any global change, read c10's upload, the env record → D3DLIGHT9 mapping and the object
  colour, then compare numerically in Jangan. The decision is the user's.
- **MTRL blend pairs drawn OURS** (BMT_FORMAT.md): 7 pairs drop a term. BLENDFACTOR's live
  value for objects is OPEN. TFACTOR is drawn white, although the mod's own colour is available.
- **The 355 bit-9 item layers with no ENVMAP mod** are cut at 128 by the READ rule. That is right
  for the 1-bit hats. `light_02_ha` (91% graded alpha) is cut the same way; a render of it
  against the original would confirm it.
- **The body under armour.** The body's own pieces are still drawn beneath every worn piece.
  Whether the client hides any body piece under armour was not looked at.
- **The faint translucent shape beside the tester's character** (v0.1.457 screenshot) is not
  from the equipment chain: no worn piece's mesh reaches there, and the one translucent-authored
  item mesh found (`heavy_11_set_b_fly`) belongs to a `_fullset` model v0.1.457 could not load.
  Likely a buff's effect (the efp lane); unmeasured.

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

Round 630 rebuilt it on `CIFMinimap`'s own draw ([protocol/minimap.md](protocol/minimap.md)): the
3x3 region tiles with image rows north to south (the map was mirrored north-south in each region),
160 px a region with the client's eleven zoom levels, the arrow turned as the client turns it (and
the world map's marker, which never turned), 8x8 signs culled at 44.5 px, the 140x184 window flush
with the screen's top-right corner, and the dungeon-floor ring hidden. Still open:

- [ ] Unique, animal, party and quest-NPC signs, and the party/quest arrows at 47.0 -- `HudMinimap`
      draws only monster, NPC and other-player signs (no data for the rest yet). A unique's sign is
      `+0x3b0` when the monster's `+0x7ac` is 3 or 8.
- [ ] The tiles' colour modulation (a colour from `0x9edd60`'s object, times 400, capped at 255).
- [ ] Dungeon regions (`minimap_d\`, and showing the floor ring there).
- [x] `UiBuilder` hides a Style-`0x40` control at creation (`0x8b5710`), every window (round 630
      review); a window that shows one sets it visible itself.
- [ ] Decode a crossing's new tiles off the main thread (2.4 ms measured): the archive reader's
      thread safety beside world streaming was not checked.
- [ ] ifmessagebox's MsgBoxStore* sections (their NAME / PRICE fields have ClientRects) are not
      built by any window yet.
- [ ] Measure a text label's cap top against the retail screenshot with **Tahoma**: the box has
      only the archive's Arial fallback, whose smaller ascent puts caps 1 px higher (round 630).

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

### The keyboard — **the retail key table since round 608; what it cannot do yet**
Every key is `client/scripts/ui/keymap.gd` (`KeyMap.SLOTS`, the 33 retail slots, plus
`OTHER_KEYS`), run by `KeyInput` and, for the windows, `HudPanels`. No key walks the character
(the user's choice of "original only": WASD is gone; S, A and W are skill, action and pet switch).
Bound but doing nothing yet, each logging a `KEYMAP ... no-op` line:
- **Pets and COS**: Ins (info), Home (ride), PgUp (unsummon), Del (follow), End (attack), PgDn
  (AI), W (switch). Nothing in this client draws or commands a pet.
- **Ctrl+1 / Ctrl+2..8**: select yourself / a party member (`0x77f230`). The target window shows
  monsters only; no player can be targeted.
- **Retail's arrow-key walk** (Up, and Left/Right with an unread turn-or-strafe) sends
  `0x7023/0x7024/0x70c5` requests this server does not have; not bound.

Also open: **F10 is ours** (Hide UI; retail's F10 is the item mall, which does not exist here);
**the item mall** itself; the **rebinding window** ([UI_TODO.md](UI_TODO.md) item 7); **G's
client-side refusals** that retail makes before sending (`+0x258 == -1`, client state 10, a UI
lock) — the server makes the owner one; **V and the minimap** (whether retail's minimap hides
what V hides was not read; ours keeps the dots); **H** toggles this client's Help window inside
the authored `GDR_GAMEGUIDE` frame, but retail's second step (focusing the system window `0x62`
when it hides the guide) is not built; **R**'s retail line is built from `L"$"` and the name by
`0x5412c0`, whose join was not read, so ours opens the chat line with `/w <name> `.

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
Variant is checked with `is_instance_valid` before the typed assignment; (7) **reconnect hygiene
(rounds 558-560)**: nothing of one login reaches the next in the same client process any more —
`World3D.gd`'s five caches are instance state, `_exit_tree` frees the scenery and NPC templates,
clears the caches and resets the viewport's `debug_draw`, the scene's `Environment` is
`resource_local_to_scene`, Restart changes scene once, and a socket drop mid-load no longer builds
a batch into a dead world (round 558's one `SCRIPT ERROR` per drop is 0). **What this did not
settle**: the tester's white ground after a reconnect was not reproduced on the render box (round
558, Mesa/VirtualGL: pass 2 textured to the fourth decimal of pass 1's frame mean, on both routes
and both timings); the tester's `user://logs/srrevamp.log` from a reconnect — the second
`character/item/NPC tables loaded` block's `ground textures for 97\168.m -- N ids, N resolved`
line, any `pk2: could not open`, any `SCRIPT ERROR`, and whether buildings and water were white too
— decides it. `qa_shot.sh --reconnect <tick|drain>` is the run to re-measure with. Still open, and
now carried by the next section: the tester reported it again on 2026-09-26 with a screenshot, and
round 579 reproduced the mechanism on the box and gave them `/groundprobe`.

### White ground after a reconnect — **the mechanism measured on the box is fixed (round 580: bases drawn first by render priority); the tester's `/groundprobe` file to say whether it was theirs**

**The report.** 2026-09-25 and again 2026-09-26, with a screenshot: after a disconnect and a
reconnect without closing the client, the terrain draws near-white with soft green/brown gradients
that follow the terrain mesh's quads, while buildings, walls, trees, bushes, the sky and the HUD
are textured. The tester plays a tagged Windows release; which tag is not known yet.

**What round 579 measured** (`docs/RE_COMPLETION.md`, round 579, has the numbers):

- **The base surface is drawn over textured passes after a reconnect.** Each region's terrain is a
  flat base (`UNKNOWN_TILE_COLOR` 0.5 grey times the baked light) plus one opaque pass per tile ID,
  coplanar, drawn in material-RID order. On a second world in one process the new materials take
  the freed RID slots, and the base lands ABOVE some or all of its opaque passes (entry 2, Login
  route: 8 of 9 regions inverted, 4-7 of 22 passes in 97/168; entry 1: none). The box then draws
  those quads flat grey (161, 161, 162) with the overlays' gradients on top; the probe's `tint`
  shows the bases (magenta) there, and `base_first` (base `render_priority` -1) and
  `opaque_as_alpha` put the ground back. `fresh_materials` in entry 2 turns the whole view that
  flat base grey on demand (neutral p50 161, bright_neutral 0.000 -- below the probe's own 180
  "white" cut). That is the tester's pattern, flat quads under the overlays' gradients, not their
  brightness (205-227); their `/groundprobe` decides whether it is their white. At round 558's
  square viewpoint the probe's `tint` turned none of its box red: that view
  frames the square's paving objects, so its frame measurement could not see this.
- **A plain launch runs Forward+ (Vulkan), not GL Compatibility** -- and so, read but not
  measured on an export, does a release. `client/project.godot`'s `#` comment lines are not
  comments to Godot 4.2's parser (only `;` is): `rendering_method`, `enable_file_logging` and
  `use_oversampling` never took effect. A plain launch prints `Vulkan API ... - Forward+`; every
  box render passes `--rendering-driver opengl3`. The RID-ordered opaque sort exists in Forward+
  too (source reading). A Forward+ calculation puts the grey base at about 217 on screen, inside
  the 205-227 the investigators measured on the tester's JPEG (a calculation, not a measurement)
  -- so on a Forward+ file the probe's `bright_neutral` (cut 180, set for GL) cannot tell the base
  from a white sampler, while `tint` can; and its `gl=` / `glnames` values are VkImage handles
  there, not GL names (`handle_kind`).

**Next, in order.**

1. ~~**The fix**~~ **Done (round 580, "The terrain's flat base is always drawn before its
   textured passes").** `MapmTerrainBuilder` gives every base material `render_priority` -1
   (`BASE_RENDER_PRIORITY`) against the passes' 0; priority is the most significant field of
   Godot 4.2.2's opaque sort key in GL Compatibility and (by reading) Forward+, so the RID order no
   longer matters. Measured on the same Login-route reconnect run: entry 2's whole-frame baseline
   0.032/36 (pre-fix 0.079/161), `tint` magenta 0.000 (0.049), `fresh_materials` 0.002/0.032/36
   (0.416/0.430/161) with the inversion still present (8 of 9 regions). `/groundprobe` now has
   `unfix_inverted` / `unfix_inverted_tint`, which undo the fix on purpose (bases at 0, each base's
   RID above its passes'): on the box they flatten the view (0.496/0.431/161, magenta 0.448), so a
   tester's file shows whether the mechanism flattens THEIR ground and that the fix holds there.
2. ~~**Decide the renderer.**~~ **Done (round 581, "The client runs the Compatibility renderer it
   was meant to"):** the user decided on 2026-09-26 for GL Compatibility; the `#` comments in
   `project.godot` now start with `;`, and the other two settings come with it ("The renderer",
   below).
3. **Ask the tester** (round 579 built the tools): the release tag (F3's first line); a log from a
   build with round 579 -- every world entry prints `World3D: entry <n> (...) -- running=...
   adapter=... api=...` (the driver version only in the probe's `gpu` line: on Windows it costs a
   WMI query on the main thread); and, when the ground is white, **`/groundprobe`** (or F3 ->
   **Ground probe**), holding still until chat says it is done, then the
   `groundprobe-e<entry>-r<run>-<time>.txt` it saves beside the log (`/log` opens the folder). If
   they can: whether water is white too, and one launch with `--verbose` (GLES3 then logs `GL
   ERROR:` lines, drivers/gles3/rasterizer_gles3.cpp, 4.2.2-stable). An `override.cfg` beside the
   exe is read by an exported build (core/config/project_settings.cpp, `ProjectSettings::_setup`;
   the ProjectSettings class reference, "Overriding", 4.2.2-stable), so `[rendering]`
   `renderer/rendering_method="gl_compatibility"` there is a no-rebuild A/B of the renderer
   question, and `shader_compiler/shader_cache/enabled=false` one of the shader-cache hypothesis.

### The renderer — **decided 2026-09-26: GL Compatibility, in effect from round 581**

The user decided on 2026-09-26 that players run the Compatibility renderer, which `project.godot`
had meant since 2026-08-26 but never got: its `#` comment lines were folded into the next key by
Godot 4.2's parser (only `;` is a comment there), so `rendering_method`, `enable_file_logging` and
`use_oversampling` did not apply and every release ran Forward+ on Vulkan (round 579, the
`/groundprobe` round, measured it). Round 581 rewrote the comments; `client/scripts/project_settings_test.gd`
fails if a setting stops applying, and an exported pack's `project.binary` now carries
`rendering_method="gl_compatibility"` (measured before and after, `docs/RE_COMPLETION.md` round
581). What a player sees change, read in the 4.2.2 source: the world's SSAO and glow stop (the
Compatibility renderer has neither); sky, tonemap, fog and the sun's shadows stay. Every box render
was already Compatibility, so the look this project has verified is the one players now get.
Still open: a Windows GPU without OpenGL 3.3 gets Godot's "Unable to initialize OpenGL video
driver" alert unless the export template carries ANGLE, which was not checked; and every tester
report so far (the white ground included) came from a Forward+ build, so the first report from a
Compatibility release is the one to read against the box.

### Loading freezes: what the off-thread rounds left (map/loading epic, 2026-09-25)

Rounds 565-566 prepare a streamed cell's terrain and objects on a `WorkerThreadPool` task and
commit them on the main thread, and round 567 makes the terrain's collision a heightfield
(`client/tools/README.md`, "Load benchmark", has the benchmark and the rules;
`docs/RE_COMPLETION.md`, rounds 565-568, the measurements and the review notes).

- [ ] **A zone change or reconnect in the middle of loading blocks the main thread for up to
      about 0.5 s** (a regression of round 566, measured, not fixed). `World3D._drop_cell_jobs`
      waits for every cell still preparing before it drops it -- a reconnect frees the world, and
      a task still running would call into it -- and since round 566 a cell's task prepares its
      objects after its terrain, so the wait covers both. Round 558's `qa_shot.sh --reconnect
      drain` run printed `2 cell(s) still preparing dropped (the world left the tree) -- waited
      497.2 ms for their tasks` on the FIRST write of round 566's code, whose pump still
      dispatched the next cell before committing the finished one (`/var/tmp/r566/drain.log` on
      the render box, 15:48, before the review fix; it has no `prepared again` line), against
      18.8 ms on round 565's. The shipped finish-first order's wait was never re-measured: it
      should be close, since the wait follows the length of the prepare, not the pump's order
      (round 566's second review; said so since round 568). Proposed fix: a cancel check between models in
      `World3D._objects_prepare` (and between the terrain and the objects in `_cell_prepare`) --
      `_drop_cell_jobs` sets a cancel flag on each job before it waits, and a cancelled prepare
      returns at the next model boundary, marked so the commit side never sees it. The flag has to
      be one the main thread may write while the task reads it: which Godot 4.2 primitive gives
      that (a `Mutex`-guarded value, or a key present from the job's build so the write never
      reshapes the Dictionary) is to be read from the engine, not assumed. Test: a task over a
      synthetic job with many models, cancelled mid-prepare, returns before the whole prepare
      would have; re-measure with the same `--reconnect drain` run.
- [ ] **The heightfield under the `move_and_slide` fallback, in game** (round 567, kept on the list
      by its review). `World3D._physics_process` falls back to `move_and_slide` where no walkable
      graph covers the player; the heightfield is two-sided to shape queries (4.2.2's `cull`), so
      the player's capsule now collides with the terrain there, where the old mirrored one-sided
      trimesh let it sink (0 of 1,600 `body_test_motion` columns touched it). Measured only in the
      suite, inside one region. Not probed: a region without a `.nvm` in game; a region SEAM,
      where two heightfield bodies meet edge to edge (the sixty-third round found a two-sided
      surface pinning a capsule at a seam); the camera arm's sphere meeting the terrain from below
      (round 567's sweeps start 30 above the ground); and the 4 slanted rays both shapes miss in
      98/170 and 99/170. A `--walk` across a seam on a region with no navmesh, with
      `SRREVAMP_QA_GROUND_RAYS`, is the check.
- [x] **Round 567's heightfield has no answer on its own grid lines** (found and fixed in round
      572). A vertical ray exactly on a grid line of a `HeightMapShape3D` tests one cell with
      closed barycentric bounds and misses about as often as not (the synthetic grid probe: 6,909
      of 9,409 vertices of the region at the frame origin; 50,391 of a radius-2 grid's 235,225); on
      Jangan's real ground the plain ray missed at 7 of the 9 monsters standing on 97/168's grid
      vertices (the trimesh answered at all 23 monster columns, 19 of them on grid lines). Every
      vertical terrain ray now goes through `TerrainCollision.vertical_ray` (0.01 off the lines,
      disclosed at `RAY_GRID_EPSILON`); the grid probe is in `terrain_collision_test.gd`; all 23
      resolve on the heightfield.
- [x] **The scene's placeholder ground answers the height ray** (round 572's review; fixed in
      round 572). `_terrain_hit_height` passes through `Ground` and `VoidCatchFloor`
      (`_stand_in_floor_rids`); `height_retry_test.gd` keeps them on their layer and lists bodies
      over them.
- [ ] **Two entry drains at once** (round 565's review; predates round 565, found by reading, not
      reproduced). A zone change that starts a second `_drain_initial_load` while the first is
      still suspended leaves both pumping the one queue; the second reuses the first's loading
      screen (`_show_loading_screen` makes none while one is up). Both test the same queue as they
      resume, so they usually leave the pump loop in the SAME frame, and the likelier failure is
      then that whichever resumes second after their last awaited frame calls
      `_loading_screen.queue_free()` on the screen the other has just freed and nulled -- a
      `SCRIPT ERROR` on null (round 568's review, re-read in round 574). Only when the first
      leaves the loop a frame earlier does `_drain_pumping` go false while the other still pumps,
      letting `_process_stream_queue` pump beside it, and the other then calls `set_progress` on
      the nulled screen. A drain generation (or one drain at a time) would close both; a scripted
      double zone change is the test.
- [ ] **The `prepared again` line prints for every committed streamed cell in a player's build**
      (round 566's follow-up). A playtest diagnostic; it could sit behind a QA variable like the
      rest of the load instrumentation.

### Town teleporters (rounds 576-578, 603) and teleport NPCs (round 642)

Round 642 made all 32 NPCs with teleportdata points work: the ferries, boats, airships (Roc
Mountain), tunnels, Jangan's gate soldiers, Constantinople's guides and the two Thief Town NPCs
(`docs/protocol/teleport_network.md`, "Teleport NPCs (round 642)"). Still open:

- [ ] **Which objects offer id 8 is stood in for.** Retail registers id 8 ("Select teleport area") on
      a link source's object when a byte of the point's record (`+0x34`, the last
      `RefTeleport_ExtractData` reads, `0x6a7f45`) is 1. The client's teleportdata.txt has no column
      for it. srrevamp offers the line on every point with an outgoing link, server and client. The
      server's database column is the source, and this project has no copy of it.
- [ ] **Walk-in portals are not served.** 69 retail links leave a point with no associated object:
      64 in and out of the Qin-Shi tomb (`GATE_JINSI_*`), two for the Donwhang cave
      (`GATE_DUNGEON_DH_*`), the two desert temples' exits, and the Roc gate's return. Retail
      moves a player through them from a region event, not a talk: `CGObjPC::vslot_309` (`0x4ef480`) compares its event's string with `"TELEPORT"` and takes the
      link from `GObjPC::FUN_004f88d0`. The server refuses such a point with code 2, and the client
      offers nothing there. MEASURED over the export: 68 of the 69 start or end in a dungeon (a negative
      region), which srrevamp cannot place, and the 69th is the Roc gate's return from world 40.
- [ ] **Instanced destinations are refused** (OURS; code 0, nothing charged): every destination
      whose teleportdata column 12 (`WorldID`) is not 1. That covers the fortress gates (worlds 2,
      4, 7), the Roc gate (40), the Pharaoh tombs (57-59), the desert temples (60) and the survival,
      arena and garden maps. Retail enters the world (`GameWorldMgr_FindByID`, `0x5137ac`);
      srrevamp has one world.
- [ ] **Open-world gate structures beyond the seven town gates are served but not clickable.** The
      server now serves any point with an associated object. The client still binds only the
      id-7 buildings (round 577's rule). That leaves the Delta, Storm Desert and King's Valley gates
      (`STORE_DELTA_GATE_E/W`, `STORE_STORMDESERT_GATE`, `STORE_KINGSVALLEY_GATE`: 4 links, world
      1, free) and the Roc Mountain gate (`STORE_RC_TAHOMET_GATE`: needs the Roc quest item) with
      nothing to click. Binding them needs the placed object each one is, which is unread (round
      577's nearest-object stand-in was withdrawn for them).
- [x] **A charged NPC teleport under real input** -- closed by round 642's review, which ran a
      paid non-GM ferry (gold 1000 -> 500) and the level-95 refusal at the harbour with real input.
- [x] **The server serves any OpTeleportUse whose gate id it knows, wherever the player stands**
      (round 603's review) -- closed by round 642's review. The engine's range test is read
      (`GObjPC::IsWithinInteractionRange`, 0x4a8e10) and applied (`session.reach`,
      `teleport.Reach`), so a stale second request from the old gate is refused 3 with nothing
      charged (`TestTeleportInteractionRange`). OURS within it: the height term is dropped, and an
      NPC the server has no npcpos row for is not measured.
- [ ] **The engine's "already teleporting" state** (0x1c14, `IGObj::GetTeleportState`, the first
      test in `HandleTeleportUse`) is still not modelled: a srrevamp teleport completes inside one
      request. With the range in place it no longer lets a second request through from the old
      gate; its lifetime is unread.
- [ ] **The talk range of other NPCs.** Round 642's review closes a gate's or teleport NPC's talk
      box beyond the READ range (300 NPC, 800 structure). Whether retail's talk box for a shop or a
      warehouse closes by the same range is not read, so those talk boxes still stay open.

### Saved position (map/travel epic, round 573)

`-persist-position` (default off) puts a character back where it left off, and round 573's client
keeps a restored entry's position (`docs/RE_COMPLETION.md`, round 573; `deploy/README.md`, "Saved
position (off by default)").

- [ ] **A restored position far from its zone's centre** (read in round 573, not measured). The
      entry builds its grid around the LABEL's centre region, radius 2; a character saved more
      than two regions out -- by walking there, e.g. from Jangan toward Donwhang under
      `-single-frame`, where the label stays "jangan" -- is placed outside it, and the stream then
      builds around the player as after a far GM `/tp`; until its cell commits the player may fall
      and the void recovery returns it to its last grounded position. Building the entry's grid
      around the region the restored point lies in (inside the server's frame, round 570's
      `_load_region_neighborhood` already takes a centre and a frame apart) would close it; a
      `--region ''` reconnect run after a long `--walk` is the check. `/unstuck` has the same
      edge (round 573's review, read): after a restored entry `World3D._unstuck_player` takes
      the landing of `NetClient.current_zone`, which under `-single-frame` is still "jangan" after
      a walk to Donwhang, so it sends the player to Jangan's landing -- and if 97/168's walkable
      graph has streamed out, `_place_at_zone_landing` fails and it falls back to the restored
      entry point, which may be as far away.
- [ ] **The position save runs before the broadcast** (round 573's review, read). In
      `WorldDisconnectHandler` the save (`savePosition`, a synchronous write bounded by
      `positionSaveTimeout`, 5 s) runs before the others in the zone are sent `OpEntityLeft`, and
      `handleMove`'s save every 30 s (`savePositionEvery`) before `OpEntityMoved` is relayed: a
      stalled store delays those notices by up to 5 s. With a healthy database nothing changes.
      Saving after the broadcast, or off the handler goroutine, would close it.
- [ ] **A duplicate entity's save can win** (round 573's review, read). `SaveAllPositions` walks
      `hub.AllEntities()`, a map, so when one character is in the hub twice -- a ghost session
      from a reconnect whose old socket's close has not been noticed -- whichever entity comes
      last is saved, possibly the ghost's older point; and a ghost's late `OnDisconnect` save can
      overwrite a newer periodic one. Only the stop window and the fast-reconnect race (disclosed
      in round 573) reach it, and the duplicate entity predates round 573.

### One world frame (map/travel epic, round 571)

`-single-frame` (default off) puts every town in Jangan's frame and one bucket
(`docs/RE_COMPLETION.md`, round 571; `deploy/README.md`, "Single world frame (off by default)",
whose flip conditions these items feed).

- [ ] **A hard guard on the monster list before the flip** (round 571's review). The list is one
      packet, capped at 32,767 payload bytes; under the flag the one bucket's 413 roster monsters
      are 28,189 bytes, so 72 more Mangyang-sized GM spawns (four `/spawn 20`s) push it over, and
      then EVERY player's list fails in `proto.Write` and the gateway closes each session on its
      next request. A cap, or a split over several packets in `handleMonsterList`, closes it; a
      test that lists more monsters than one packet holds is the check.
- [ ] **Round 571's height gate, to be accepted explicitly before the flip** (round 571's review).
      The item asked for every town whose radius-2 regions leave +-1000 / -500 under the one frame
      to be gated; round 571 gated none, because Jangan's own 99/170 (1075.41) breaks that
      envelope with the flag off, and checked instead where the client places something at a
      server-given height. The review re-measured the numbers and found the reasoning sound, and
      asked for the decision to be accepted, not just recorded; no note of rounds 571-573 records
      that. Samarkand's 108/105 and 108/106 (1052.1 and 1108.7) are the only regions the flag
      newly takes out of the envelope.
- [ ] **Another player who warps to a far town is drawn at the server's y 0** (round 571's review,
      read). `World3D._spawn_or_update_other` places the body at the snapshot's height with no
      snap to the ground, 104.07 above Donwhang's drawn landing and 86.23 to 246.32 below the
      others' under the one frame, until the mover's own client lifts or drops it and sends an
      `OpMove`. Snapping another player's body the way a monster's is snapped would close it.

### Other bodies' facing (round 637 and its review follow-up) — **built: every body, this player's too, turns to face where it goes at 3 pi rad/s, and an arrival faces the way it last walked; these are left**

READ and measured in `docs/WORLD_ISSUES.md`'s 637th round; the rule is `RemoteFacing`.
`SRREVAMP_QA_FACING_LOG=1` plus `client/tools/facing_measure.py` is the measurement.

- [x] ~~The local player still snaps its own facing~~ -- **done in round 637's review follow-up**:
      it turns at 3 pi rad/s (READ: the echoed `0xB021` -> `FUN_008a5750` -> `FUN_009e0550`), with
      `FUN_009eb2a0`'s snap exception and its 5-unit idle filter (`RemoteFacing.click_rule`).
- [x] ~~A player coming into view faces heading 0~~ -- **done in the review follow-up for
      `OpEntityEntered`**. The server keeps a heading per character (`world.Entity.Heading`, from
      each walk) and carries it through a zone change. The arrival snaps to it (`FUN_009d17e0` ->
      `FUN_009c4260`). Left:
  - [x] ~~The lists carry no heading~~ -- **done ("headings in the arrival lists")**: a tail
        after `Seated`, with `Seated` always written.
  - [x] ~~A fresh world entry faces heading 0~~ -- **done under `-persist-position`**: the heading
        is saved with the position (`character.HeadingStore`, OURS: `_CHAR` has no such column)
        and restored with it. With the flag off, an entry still faces 0.
- [ ] **The retail re-aim guard is not applied.** `0xB021` aims only when the order is in effect
      (mover `+0xac`, `obj+0x714`) or the destination is more than 5 units (squared 25.0) from the
      mover's current POSITION (`+0x54/+0x58`). srrevamp streams positions about 2.5 units apart
      and has no stop message, so the guard would only drop the first sample of each walk after a
      spawn or placement. Revisit if the move packet becomes a destination (`0x7021`/`0xB021`).
- [ ] **The cast start's and a standing monster's turns toward a target are OURS snaps.** They
      leave a turn in progress running, as the skill action reader's bare `FUN_009c4260` does
      (`FUN_00a54be0`, READ). Two things are INFERRED: that they are that path, and the angle (ours
      points at the target; retail's comes in the message). The monster spawn heading is a snap
      that ends the turn (a new object, READ). A monster's stop snaps to its turn's target and ends
      it: `FUN_009e00f0`'s snap to the server's angle, with the turn's target standing in for the
      angle (INFERRED).
- [ ] **The relocation rule is OURS.** An `OpMove` is flagged relocated when:
      - the sender knows it is one (a gap recovery, a region-local placement); or
      - its displacement exceeds the walk since the last send by `RELOCATE_MARGIN` (1.0).

      The server keeps the heading on a relocated move and relays the flag, and the other clients
      place the body without turning it.
- [ ] **A monster the list moves mid-leg keeps its leg's facing.** Seen once at world entry: 7.4
      degrees off for 0.6 s. The client's facing changes only on a message, so this may be right;
      not established.

### The buff bar — **built (round 618); these are left**
`HudBuffBoard` is retail's `CIFMagicStateBoard`. It has the icons, the draining time bar, the end
burst and sound, right-click cancel and the tooltip. The record is in
`docs/protocol/magic_state_board.md`. Left open:
- [x] **The client's own id** -- done in round 618's review: OpSelfId (round 617), so a buff is
      this player's when its ownerKind is 0 and its owner id is `World3D._sync_own_id`'s. No id
      means no buff is shown.
- [x] **Round 617's signals** -- wired to `buff_started(SkillNet.BuffStart)` /
      `buff_ended(SkillNet.BuffEnd)` and `send_buff_cancel`.
- [ ] **The plain skilldata twins.** The catalog reads `skilldata_<n>.txt`, not the ENC files retail
      loads. It matches the decrypted ENC set on every id retail knows (measured on the box's
      archive). An archive whose plain twins are stale would need the ENC files decrypted, and
      that needs the key tables from the player's own `sro_client.exe` (0xeae758 / 0xeae948). The
      scheme is in the protocol doc.
- [ ] **The `cbuf` box's text** (retail passes an empty string) and what its OK does (INFERRED:
      the cancel). The box is this client's own confirm style.
- [ ] **Not drawn:**
  - the `lnks` frame (window_all.ddj UVs at 0xdd07a0..0xdd07b0, corner order unread);
  - the red "Not affected" line and the admittance sprites (`s_admittance_back.ddj` /
    `s_admittance_icon.ddj`) that go with it (slot `+0x36c`, its setter unread);
  - the "Target :" line;
  - kind 2 abnormal states (`s_*_icon.ddj`, a 1000 ms refresh);
  - kind 3 item-time entries and their second gauge.
- [ ] **0x93f5d0**, the lookup a right-click also requires, is unread and not modelled.
- [x] **Authentic icons** -- round 624: the skill window's own 32x32 file, point-sampled to 20x20
      once and drawn nearest (`HudBuffBoard.AUTHENTIC_ICONS`; the magic_state_board.md section
      "The icon's texture and sampling" has the reading). Left open:
  - [x] **The board's draw predecessor** -- READ in the review: the board draws right after
        `GDR_PLAYER_MINI_INFO`'s subtree, whose labels leave POINT. Four assumptions stay open:
        no bring-to-front reorder, no other text-scale writer, state blocks and D3DX effects not
        audited, and the labels having on-screen text. A D3D9 frame capture of retail would close
        them.
  - [ ] **A "high-res icons" option.** The user may want one later. `AUTHENTIC_ICONS` is a
        static var, so a setting can flip it; icons already on the board keep their look until
        rebuilt. No UI was added.

### The target window's buffs and race emblem (round 638) — **built; these are left**
`HudTargetBuffs` is retail's `CIFBuffViewer` under the target's name bar: 20x20 icons, 8 a row at a
23 px pitch, `bbuf` skills in a second list, refreshed every 1000 ms from every owner's
OpBuffStart/End, with the viewer's own tooltip. The player piece shows the race emblem. The record
is in `docs/protocol/target_window_buffs.md`. Left open:
- [ ] **The tooltip's parameter lines** (0x96e480(7), the skill window's damage/range text). They
      are not built, so the viewer's tooltip is the name, level and description only.
- [ ] **Monster buffs.** The viewer shows a monster's buffs, but the server starts none
      (`OwnerKind` is always `OwnerCharacter`), so a monster's row is always empty.
- [ ] **Abnormal states** (the target's `+0x2c4` bits go in the second list). srrevamp sends no
      one's abnormal states to the client.
- [ ] **0xB0BE**, the type-3 buff that carries a name (the tooltip's "Target :" line). What it is
      in retail is unread, and srrevamp sends nothing like it.
- [ ] **The byte behind `+0x36c`** (the "Not affected" state; now known to come from 0x9d25e0's
      comparison of two 32-entry arrays, 0x9c7830 / 0x9cdf00). What the arrays are is unread.
- [ ] **A rarity-2 monster's viewer position.** Retail never writes it; ours hides the viewer.
      No monster in the archive has rarity 2.
- [x] **The target window after a zone change or a target leaving view** -- done in the
      review follow-up: CIFTargetWindow::vslot_012's per-frame lookup is mirrored
      (`HudTarget.check_target`), so a target that is gone hides the window and is deselected.
      Another player's death is not reported to this client, so that case is OPEN.
- [x] **The premium on a target** -- done in the review follow-up. The premium is a USU1 skill
      buff and shows like any buff; the server now starts it (`session/composite.go`). Left
      open on the server:
  - the skill gate 0x58d8f0 that 0x650d40 runs;
  - the buff's params (dru, odar, hr, luck, alcu, inti, stri): the book models only run speed;
  - the premium's other entries are skipped (OURS, logged): the UIU1 premium time (3/3/13/4,
    a type-3 CTJ_PremiumKeeper job), BFI1 and UQL1.
- [ ] **What `+0x21c == -1` means** for an owner whose 0xB0BD object is destroyed, not attached
      (0x8a5d58).
- [ ] **Pets** (the CICCos branch shows the viewer too). srrevamp's pets cannot be targeted yet.

### Store and warehouse confirm boxes — **crash fixed (round 631); next: the retail CIFMessageBox**
Round 631 fixed the crash the user hit on v0.1.458 (a box freed from its own button: SIGSEGV).
It also made the store's goods and the warehouse's items clickable again: their authored
`*_SLOT_100..129` controls had been covering the lattice cells.

The review follow-up fixed three more things:
- the same free-while-emitting on the world map's name plates, whose click also walked the
  player;
- a box left open behind a closed window. It now closes with its window, which is OURS; what
  retail does on close is OPEN (see message_box.md);
- the gold dialog now closes on OK, as retail's box does, so a double click moves the amount
  once.

Evidence for all of it is in WORLD_ISSUES.md's six-hundred-and-thirty-first round and its
review follow-up.

Every box below is still **this client's own** gold-edged `PanelContainer`. None of them is a
Godot `Window`. The next round replaces them with the retail windows.

Retail equivalents were READ from the client dump and the `resinfo` layouts (round 631). Every
store and warehouse box is a **CIFMessageBox** built from `resinfo\ifmessagebox.txt`
(`CIFMessageBox::Create` 0x63e380). Two numbers configure it:
- the **layout mode**, via `0x643c20`, which picks the section of that file;
- the **purpose**, via `0x63ea80`, jump table 0x63ff38, which sets the title and button labels.

The inventory owns the box (`FUN_006af530`, 308x148). Its OK press (`FUN_006b4627`) reads the
count or gold at box+0x8b8 and sends the move.

- [ ] **Buy**, `hud_panels.gd` `_confirm_buy`.
  - Retail (READ): drag a store good onto the bag. `CIFInventory::vslot_028` 0x6b5b80 →
    `0x6b24c0(1)` opens `ifinventory.txt` "ConfirmBuy" = `CItemMallConfirmBuy` (ID 400,
    `ifitemmallconfirmbuy.txt`).
  - Its RENEWAL-branch controls (the live build's; INFERRED from the code): title
    `UIIT_STT_CONFIRM_BOX` ("Confirmation window"), icon, name, a "Quantity" edit (id 42) with
    spins 50/51, and background 4 at 16,40,295,106.
  - `FUN_007c3f70` adds one 22-tall price row per price-type flag, then places Buy (61) at
    (X+82, Y+H-40) and Cancel (62) at (X+170, Y+H-40).
  - Price/Total (44/45) and the silk rows are `#else`-only, so they are not in the live build.
  - Ctrl+click on a store slot buys at once, with no box (`CIFSlotWithHelp::vslot_029` 0x680fa0).
- [ ] **Sell**, `_confirm_sell`.
  - Retail (READ): drag a bag item onto the store. `CIFStore::vslot_028` 0x6d1400 → `0x6b07d0`:
    mode 6 **MsgBoxStoreConfirm**, purpose 2 (OK `UIIT_STT_SELL`).
  - Its controls: icon (72/73), name (79), "Quantity" (78) with count edit 80 and spins 81/82,
    Price (85/86), Gold (87), Sell (83), Cancel (84).
  - Ctrl+click sells at once. The exception is an item that cannot be bought back: it gets the
    generic Yes/No box with `UIIT_MSG_CANNOT_BUYBACK_ITEM_SELL`.
- [ ] **Deposit / Withdraw an item**, `_confirm_deposit` / `_confirm_withdraw` →
  `_quantity_move_confirm`.
  - Retail (READ): the same MsgBoxStoreConfirm layout, count edit id 80. Deposit is purpose 5
    (OK `UIIT_STT_DEPOSIT` "Deposit"), from `CIFStorageRoom::vslot_028` 0x6cd350 → `0x6b0e90`.
    Withdraw is purpose 6 (OK `UIIT_STT_WITHDRAW` "Take"), via `0x6b15b0`.
  - Guild storage uses purposes 0x10 / 0x11.
  - The deposit box fills its price field with a fee (INFERRED from `price*n/2`, not traced).
- [ ] **Warehouse gold**, `_open_gold_dialog` (ours: one box with Deposit, Withdraw and Close;
  it closes on Deposit or Withdraw since the round 631 review, as retail's does on OK).
  - Retail (READ): two separate boxes, both mode 3 **MsgBoxStoreMoney**. Purpose 3 deposits
    (`0x6b2800`, caption `UIIT_STT_DEPOSITMONEY`); purpose 4 withdraws (`0x6b29f0`, "Take").
  - Both show `interface\icon\moneyicon.ddj`, with the amount edit (id 3) resized to 121x24.
    The captions go to NAME1 (control 1); the title is `UIIT_STT_CONFIRM_BOX`. OK is id 215,
    Cancel id 216, and the OK sends via `0x825f50` with a 64-bit amount.
- [ ] **Buff cancel**, `hud_buff_board.gd` `_open_confirm`. Already titled `UIIT_STT_CONFIRM_BOX`.
  - Retail's generic box (READ): `GInterface::0x788270` → CIFMessageBox mode 9 **MsgBoxSimple**.
    It is created 280x144 and then resized to 360x151 by `0x643e50`. Text id 251, buttons
    252/253.
  - Its style byte +0x908 picks the buttons: 0 = Confirm, 1 = Yes/No, 2 = Cancel.
  - Already closes with `queue_free` (safe).
- [ ] **Guild name / leave prompts** (`open_guild_name_prompt`, `open_guild_leave_prompt`) and the
  **revive prompt** (`show_revive_prompt`). All ours, all close with `queue_free` (safe).
  - Retail windows not read: `ifguild*.txt` has candidates. The revive box is OPEN.
- [ ] **The only Godot-native dialog**: `Boot.gd` `_on_update_available`, a `ConfirmationDialog`
  for the auto-updater. It is embedded (the project keeps the default
  `display/window/subwindows/embed_subwindows=true`), is not in the game, and has no retail
  equivalent. It can stay.
- [ ] OPEN from the reading:
  - which mouse event `vslot_029` is;
  - which store class is live under `#ifdef RENEWAL_SHOP_SYSTEM`;
  - the four 64-bit amount fields (partly traced);
  - `0x643e50`'s geometry for MsgBoxSimple;
  - MsgBoxDivideCount (mode 5, Shift+click a stack): retail's stack split, which this client
    does not have.

### The player block (round 629) — **berserk orbs, stat panel, race emblem done; these are left**
Round 629 rebuilt the top-left block from `CIFPlayerMiniInfo` (`docs/protocol/player_mini_info.md`):
the orbs fill bottom-up and an empty one is hidden, the ready circle shows at five and a click on it
is the berserk key, activation lights the flames/face/glow and drains one orb per 12 s, the "E"
button toggles the stat panel (live from the stats packet, balances by the client's own formula),
the race emblem follows characterdata's Country, the "+" opens the character window, and the HP/MP
bars use `pmi_hp.ddj` / `pmi_mp.ddj`. Left:
- [x] **The portrait** (round 635 and its review follow-up): the player's own dressed body, posed
      with ANI_POSE, from the READ camera (the head + 1.0, a 0.2 rad yaw, 6.5 away, 30 degree
      vertical FOV; the avatar at 0.1 rad), lit by the ZONE's light as retail's vertex-shader
      renderer does. The light comes from above and the +x side (normalize(1,1,0)), with diffuse =
      channel 2 × 0.6 and ambient = channel 3 × the object's own 0.6, through MODULATE2X. It
      renders once per dress and per zone load into 128x128, and is shown through
      `pmi_face.ddj`'s alpha (`player_portrait.gd`). The face gets the ambient only: in Jangan
      `0.81 × texel`, in the darkest environment (58) `0.33 × texel`. Still OPEN:
      - the world flags +0x2e54 (diffuse 0.8), +0x26bb (halved) and +0x2eb4 (constant targets);
      - the renderer's +0x120 bit (raw object colour);
      - whether anything changes the avatar's object colour from 0.6;
      - the time of day (World3D's fixed reference time);
      - the game camera's near/far;
      - the party and academy slots' portraits (same constants, not drawn);
      - the device-reset re-render (Godot keeps the buffer).
- [ ] **The world's directional light has a READ direction** (round 635's review): World3D.gd's
      comment at `_apply_real_environment_lighting` says its angle "has no confirmed real
      source". It is DAT_01109510 = normalize(−1, −1, 0) in the file's (D3D) coordinates:
      `Map::FUN_00a2f370`, 0x00a300c2..0x00a301c4, handed to the renderer by
      `Map::FUN_00a19160` / `vslot_025`. The diffuse is channel 2 clamped × 0.6, not channel 2 as
      it is. NOT changed yet: it changes the whole world's look, and the user sees it first.
- [x] **Hit rate / Parry ratio** -- round 629's review: the stats packet's fifth and sixth tails,
      the rates combat already uses, in both windows. Since the 629-632 integration review each
      item's OWN value: the weapon's HitRateMin..Max by its variance group 3, the body armour's
      ParryRatioMin..Max by group 5 (READ, `Char_BuildAggregateStats` -> `Char_PublishCombatStats`
      params 11 / 9), combat's centre roll included; a broken weapon adds nothing. Still OPEN:
      retail adds buffs, masteries and the per-plus increments (columns 115 / 70); ours does not.
- [ ] **Buffs do not change the panel's numbers** because the server's buff book only records the
      run-speed contributions (`internal/buff`); the panel already re-asks on OpBuffStart/End.
- [ ] **Hwan-level art** (`pmi_jahwan_02*`, blue) needs a Hwan level (`player+0x764`, INFERRED
      `_CHAR.HwanLevel`); the Hwan socket stones' extra display seconds (`FUN_006ac0a0`) likewise
      (the Energy of life bonus, `player+0x20f8`, is fed since the 629-632 integration review). The
      "+" button's blink (`FUN_00655ec0(1)`) is not drawn.
- [x] **The berserk end** -- round 629's review: the server pushes 0x30BF kind 4 (body mode) on
      at activation and off when it runs out; the display ends on its own timer 2, and on death and
      zone reset (`FUN_007b5300`). Since the 629-632 integration review a revive (READ,
      `GObjPC::Revive`'s `SetBodyMode(2, ...)`) and a zone change (world entry READ, teleport as
      re-entry INFERRED) end the server's berserk too, and a second activation is refused (error 3,
      READ). The value-1 extra byte (chardata+5) is READ: `SetBodyMode`'s fifth argument, 0 on the
      activation. OPEN: body mode 2 (the revive / entry invincibility and its berserk error 4);
      other players' body modes are not drawn.

### Chat (round 634) -- **the retail window, channels, globals and notices built; these are left**

docs/protocol/chat.md has every address. Built: the five tabs with their filters and lamps, the
per-type colours and captions, the hanging wrap indent, the left scroll bar (arrows, thumb, wheel,
drag), the channel marks `# @ % & $`, R's `$name ` reply, the sender's echo and the 0xB025
refusals, the global chatting item's "Chat to all" window, the GM notice's line and banner, and
`/notice`.

- **Union and academy chat have no audience**: srrevamp forms no alliances and has no academy, so
  the server refuses both (the client shows the game's own refusal lines).
- **Built in the review follow-up**: the size modes and button, bottom-stacked lines, grey idle
  tabs, the hover bar, the client-side group refusals, first-row-wins for the text table.
- **Not built**: the whisper list pop-up (`GDR_WHISPERLIST`, 0x7acfd0), the chat-mode button and
  viewer (IDs 41/42), the hide button, the "*" name prefix (0x877810/0x877340, the sender's vslot
  0xac state not identified), speech balloons over heads (0x9c77c0), the flood block
  (0x7a9bb0), the global window's text filter (0x8c4020). The system message window is built
  (round 639; its own list is below).
- **Open questions**: whether the client strips CSV quote marks from a text row (24 first rows on
  the box's archive keep them since first-row-wins); whether retail's server strips the channel mark from the text; the
  range of ordinary chat (srrevamp: the zone bucket); the wheel
  step. The user's screenshot (a private server) draws notices cyan (0, 174, 195) without the
  "(Notice):" prefix; the binary says pink `0xffffaec3` with the prefix -- srrevamp follows the
  binary; the private client's source for the cyan is not known.
- "Remaining turns" in the global window overruns into its count (the authored static is 55 px
  wide; our font draws the caption wider).

### The system message window and the saved quick slots (round 639) — **built; these are left**

What round 639 read and built is in `docs/protocol/system_message.md`.

- **The filter board** (GDR_SYETEM_MESSAGE_OPTBOARD, CIFChatOptionBoard, `ifchatoptionboard.txt`):
  its five checkboxes, their art (set in code, not read) and `Setting\chop.dat`. The filter button
  does nothing yet; the filters stay at the no-file defaults (FIGHT off, the rest on).
- **The frame's hover-only option** (`0x4f9d00`+7, `0x77b385..0x77b3db`): which option it is and its
  default. The frame always shows here.
- **Guide lines and unique notices.** The window shows retail's type-6 "[Guide]" tips
  (`0x789e53`) and the uniques' appearance and death lines (`0x874ea0`) when they arrive; srrevamp's
  server sends neither.
- **Retail's messages for srrevamp's refusals.** The server sends English text; retail sends a code
  that `0x7b8b40` turns into the UIIT_ message.
- **Quest EXP** writes no line (only a kill's result carries the EXP).
- **GDR_WARNING_WND's position** (the level-up line): the CIFNotify class's +0x7d4, read as 0 for
  GDR_NOTICE; no writer for this instance was looked for.
- **The quick slots on the server.** Retail saves them with 0x7158 and loads them from the character
  data (`0x8a7c50`); srrevamp keeps them client-side at the user's request (OURS,
  `user://quickslots.cfg`). A new character's default slots (`0x786f30`) and dragging a slot off the
  bar to clear it (vslot 26 `0x60c1b0`) are still not wired, as before.
- **The paper doll's step** is 36 degrees a click at the user's request (OURS); a held arrow repeats
  it after 1000 ms and then every 250 ms (144 degrees a second, OURS). Retail's step is a frame's
  worth, frame_ms * 0.0015 rad, repeated every 50 ms.
- **Skill withdrawal** has no server side here; the bar's withdrawal rebind (`0x60c230` with 0) is
  built and tested but reached by nothing.
- **The EXP line at the level cap** reports what was added (0 once full); what retail's server
  sends there was not read.

### The inventory window (round 633) — **pages, purse colours, slot art, avatar view, preview built; these are left**

What round 633 read and built is in `docs/protocol/inventory_window.md`.

- **Carrying an item across pages the way the client does.** Round 633's review read the two
  IFInventory handlers that name DraggedTab/DraggedPage: `0x6b4610` is a confirm box's answer and
  `0x6b62d0` is the split box's. Neither turns a page. Ours turns the page when a drag passes over a
  tab (OURS).
- **The selected tab's text flag 2** (`0x64cc30` → `0x8b44b0(0,2)` → the glyph mode in
  `0x8b39e0`). What it draws is not read, so nothing is drawn for it.
- **The preview's pose advances while hidden.** It no longer renders while hidden (round 633's
  review), but the idle is still stepped by World3D. Retail steps it only while shown
  (`vslot_012` `0x6ab6b0` tests `0xb8f530`).
- **The academy's rank and leader marks.** Their show code is read (`0x6e9de3..0x6e9e6f`, the rank
  byte's art) but not built: this client keeps no academy data. The party's are built.
- **The party race mark always shows China's art**, because the server does not send the leader's
  race.
- **The avatar skill strip** (`GDR_AVATAR_SKILL_WND`, ID 500) needs avatar items with its type
  bit. This server has none.
- **The retail starting inventory size** is a `_CHAR.InventorySize` database default that neither
  executable carries. `-inventory-size` 96 is ours. The engine's growth caps (77, or 99 with the
  quest, counting 13 equipment slots) mean retail never fills the third page by its own means.
- **The exchange window's gold boxes** are coloured and filled from the trade events. The
  exchange window itself is still not opened by a trade (World3D's debug trade labels do that
  work).

### Seasonal event decorations — **hidden by default (round 583)**
The user decided on 2026-09-26 that early testing gets no seasonal decorations. Christmas,
Halloween, the China open-beta (OBT) event set and the summer festival set are left out of every
region's objects before any model is read (`SeasonalObjects`; `World3D._objects_prepare`). Each set
comes back on its own with `SRREVAMP_SEASONAL=christmas,halloween,obt,summer` (any subset), or with
`seasonal="christmas,halloween"` under `[world]` in `user://settings.cfg`. The value must be
quoted: unquoted, the whole file fails to parse, every setting reads as its default, and the next
save keeps only the keys above the bad line. The two sources are added together. They are read
once per world scene, when it builds its first region's objects, so a change shows after the
next login or restart. The choice is ours: no switch was found in the client's `.o2` loader
(`docs/RE_COMPLETION.md`, round 583, which also has the `UIIT_MSG_XMAS_EVENT_*` strings and the
layer-key lead). Left open:
- **No window writes the setting.** The authored Option window, when it replaces the F3 panel, is
  the natural place for a toggle. The hidden set is built once per world, so a live toggle would
  also need that set rebuilt and the loaded regions' objects reloaded.
- **The other event pieces are drawn.** The user chose four sets. `layerobjdef.txt`'s layer 11,
  구정 (Lunar New Year, `res\etc\newyearday\`), the season door (`res\etc\seasonevent_door.bsr`)
  and `alex_burner` stay unless the user asks. `alex_burner` matches no layer row by position.
- **The `.o2` skip bit** (below, "`.o2` list semantics"): 240 list-2 records that retail does not
  build are drawn. None of them is seasonal.

### Buffs on the server (skills epic, round 616) — **started: the book, Grass Walk's speed, cancel, Ghost Walk**
The server starts an action-kind-3 cast as a record in the caster's book, ends it at its time or
on cancel, and moves the caster for a Ghost Walk; the wire and every rule's source are in
`docs/protocol/skill_buffs.md`. srrevamp-01 needs the skills CSV re-exported and re-imported
(`deploy/README.md`, "ROUND 616"). Left open, each with what is already read:
- [ ] **The other publishing params.** Only `hste`/`hst3` (run speed) reach anything. `defr`,
      `defp`, `apau`/`apru`, `hpi`/`mpi`, `irgc`, `er`/`terd`/`thrd` are read in `0x594ac0` (the
      protocol doc lists their param/slot writes) but damage, defence and HP/MP are computed
      without ParamKeeper slots, so each needs its own hook into `combat`/`stats.go`.
- [ ] **The imbues' `att`** on the caster's later blows (Ice River Force & co.): the buff starts,
      the extra damage is not dealt.
- [x] **Toggles -- round 640.** `onff`'s MP drain (onff[1] every onff[0] ms, strictly after), its
      end when the MP is short, and the recast that switches a toggle off (Tick_UseSkill's phase 0),
      for all 116 `onff` rows (the walls and the Bard songs and dances). Left open: the `BDMD`
      drain reduction (needs the passive entries of the book map at `+0x244`).
- [ ] **Summons** (kind 3 without `dura`, `summ`): the lifetime. Today they run until cancelled, a
      death or a logout.
- [ ] **Debuffs on a hostile target** (Target_Required 1 with only enemy groups -- Water Cancel,
      the Warlock DOTs): not started; they keep the old path. Monsters would need books.
- [x] **Whom a friendly TR-1 buff or heal lands on -- round 622.** READ: with nothing selected the
      retail client refuses it itself (0x3011 "The target is not selected.", `FUN_0081ba10`); at a
      monster the server refuses it (0x3006 "Invalid target", `FUN_0058d7a0`); at a player it is
      cast there (targetType 3). The buff starts on the target's book; Heal A/B/C restore their
      `heal` value[0] (columns 62/63). A cast is announced to the zone (OpSkillCast 0x00FA, start
      and act). Still open:
      - selecting oneself: done in the review (the player block's left press, Shift-click on the
        body); still open, the type-3 box FUN_00780ee0 opens when a dead player selects itself;
      - the client's CICUser checks (PK/job flags, the guild compare, vslot 0xa8): no states here;
      - resurrections (SelectDeadBody, `resu`) and the other 249 `heal` rows (heal.md);
      - monster casts in OpSkillCast (casterKind 1 is carried; the monster AI's strikes do not
        announce a skill);
      - the retail 0xB070/0xB071 payload past their headers (the target/damage block
        `FUN_00a54be0`), and the act's timing for a chain or a multi-hit skill (ours: prep + cast
        once);
      - another player's cast clip is picked as the player's own, and their body is turned toward
        the target at the start (OURS; retail's turn not read).
- [x] **The Ghost Walk navmesh test** (round 616-618 integration): read (`CRegionManagerBody::vslot_012`
      0x98b300: a blocked path stops at the obstacle, it is not refused) and run on the client
      (`GhostWalk.resolve`: 3-D clamp, NavGraph walk without slide, ground height; footing settled on
      `OpSkillMove`). The review follow-up read the terrain-wall stop (0.2 toward the cell centre,
      the cell's objects check) and the record's integer landing, both mirrored. Still open: the
      refusal cases (region span, six hand-overs, cell check) are not modelled; the server trusts the
      client's walked point within its clamp; what retail does when truncation carries the landing
      over the edge it stopped at (ours keeps the walked stop); which packet tells the clients of the
      move; `tele` value[0] (500) is unread; the move's duration (a snap).
- [ ] **Skill body animations from skillaniset2 for targeted casts** (round 616-618 integration found
      the link, `docs/protocol/BSR_FORMAT.md`): self/ground casts use it; targeted casts still use the
      clip-name route and the swing. Needs the READY/SHOT phase timing (`FUN_00a54f00`'s later
      phases) and the per-deco pick among several entries (`+0xe4` byte).
- [x] **The recast rule's other branches** (round 636): all of FUN_0059d870 read and built -- the
      `dttp` and `efr` kind-2 (`+0x290`) branches, and the book's state bit set that Action_Overlap
      and `ovl2` fill (`SkillBook::SetGroupBits` 0x59dc00 / `FUN_0059db10`). Fire Protection no longer
      stacks; a second Grass Walk variant is refused 0x300c while one runs, as retail refuses it. The
      whole table is driven by `TestRecastRuleCensus` (`SRREVAMP_SKILLS_CSV`). Still open:
      - the `lnks` path `FUN_0059dc80` is built (round 636's review and its follow-up: the gate's
        call for the 32 trap rows, the target test's for the 276 Target_Required 1 rows, through
        the caster's link entries). Still open there: retail's link record ending the target's
        record when it ends (a caster's death or logout leaves the target's buff running here);
        whether a trap's record ends with its object;
      - row 16's `hide` rule (the caster's vslot 0x100 state 4: which state is not read);
      - the running-action half of `FUN_0059db10` (a buff between its cast and its engage; srrevamp
        engages at the cast);
      - the buff restore through `CTJ_SkillKeeper` slot 12 (`FUN_00650e70`, a SetGroupBits caller);
      - the category end's other callers: movement (mask 1) and berserk (mask 4) end nothing by the
        data (no `skc` carries them) and are not wired; `GObjPC::FUN_004d2200`'s mask (8,
        `SKILL_FORT_REPAIR_KIT`) was not traced.
- [x] **The wall skills -- round 640.** Fire Wall / Crystal Wall: `pw` read (mask, HP, flat
      defence, defence percent), the wall takes the monster blows of the type it covers until its HP
      runs out, the MP drain, the recast switch-off, the right-click cancel, SKILL_PROTECTIONWALL for
      the gate / sit / regen, the kind-7 number and the DefenseEfp on the client. **The user's
      "they don't let you move / attack within a radius" was NOT found in either binary** (the
      movement handler never tests 0x11; the client's move gates read neither `pw` nor `onff`;
      `pc+0xc44` is the `stns` stun holder). **The user then chose "Root while walled", built as
      OURS** (the server drops a walled caster's moves and refuses Ghost Walk; the client sends no
      move while its own wall stands; attacks and skills go out where the player stands; a move it
      dropped is answered with the held position). Ghost Walk is refused while walled (READ,
      0x3009). Left open:
      - summons, mercenary scrolls and mounting while walled (retail refuses them; srrevamp has
        none), and knockback/knockdown skipped on a walled target (srrevamp's blows have none);
      - the attacker's-imbue term of the absorb test;
      - player-versus-player blows on a wall (srrevamp has none);
      - which sounds retail plays for a kind-7 entry (the monster's blow sound is kept).
- [ ] **The duration extension** (`ctx+0x24`): `RPBU`/`STDU`/`DTDR` through `FUN_005a0330`'s map at
      book `+0x244` -- needs whatever files entries there (passive skills, INFERRED).
- [ ] **Retail's death and teleport rules for buffs** (ours: a death clears, a zone change keeps),
      buffs restored at login (ctx+0xc bits 4|8), and whether retail re-sends buffs on entering view
      (ours: yes). (The `skc` category end on a skill use is built, round 636.)

### Berserk potions and Energy of life (round 632 and its review) -- **built**

Done: every TypeID 3/3/1/8 bag item fills the five orbs; the Energy of life scroll (23944-23947)
grants one fill for an hour (a buff-bar icon -> the CompositeItem window -> the fill) and +5..14 s
of berserk (param 60); COOLTIME keys are per item for key 0; a GM account skips the reuse delays
(OURS). GMs test with `/give 23944 5`. Left:

- **The jobs are in memory.** A server restart loses a granted fill and the berserk-time bonus
  (retail keeps timed jobs with `__time32_t` stamps across relogs; ours survive a relog only).
  Their timers end them on real time (OpCompositeEnd), and logout forgets a character's turn,
  charges and expired entries.
- **FUN_004a0600's movement stop.** `CGObjPC::vslot_300` (`0x4ef340` -> `FUN_004a9430`) runs before
  AddHwanCount -- INFERRED a movement stop (it may send `0xB023`); no srrevamp item use stops
  movement. Read what `0xB023` carries and what `+0x4c0` tests before mirroring it.
- **Other composite kinds** (UIU1 of a TypeID4-4 item, BCS1, BFI1, PSU1, UQL1, USL1, USU1) are
  refused; only the Energy of life's UIL1 + 0x706874 UIU1 is modelled. UIL1's "P" flag and the
  0x3161 refill (`0x653a40`) are read but unused by any modelled row.
- **CIFCompositeItemWnd's resize** for several buttons and a zero-count button's look
  (`UI_SILKMALL::FUN_00655ec0`) are not recovered; ours disables it.
- **Quest items 5921/10491**: the use path's quest gates are item-agnostic -- `0x185f` is
  `CGObjPC::QB_IsBlocked(8)` over a quest-script block mask (`pc+0x217c`), and the event-0xc
  listener list (`FUN_0063d4a0`/`FUN_0063d190`) can veto -- srrevamp has neither state, so
  nothing stops their fill. Who registers event-0xc listeners is not traced.

### Particle effects (`.efp`): **decoder done (round 619), renderer and skill effects (round 620), Link modes (round 621)**
Both readers decode 4,103 of the 4,170 files in the retail Particles.pk2
(`docs/protocol/EFP_FORMAT.md`). Round 620 plays them:
- `EfpSim` runs the client's particle rules;
- `EfpEffect` draws them;
- `SkillEffects` plays each skilleffectset row's effect at the moments SkillAudio plays its sound,
  and keeps ACT_L auras by buff token.

The `--build` census (MEASURED, round 621): all 4,103 decoded files build into an effect; 4,100
draw at least one node, and **4,013 (96.2 %) draw every node they mean to draw** (3,062, 73.4 %,
in round 620). Round 621 draws the three Link modes (`EfpLinks`) and the D3DFMT_A16B16G16R16F
textures.

**Kept auras: DONE (round 623).** A kept (AT_LOOP / AT_STOP) effect revives its root particles at
age 0 instead of dying, as retail's `CEFEffect::vslot_000` does, so Grass Walk's ring and the
imbues' hand glow stay on for the whole buff. Aura census (`scripts/efp/efp_aura_census.gd`, every
kept ACT_L file, 30 s): 306 of 315 never draw an empty frame (2 before); READY loops 28 of 30 (0),
WAIT loops 20 of 20 (0). The rest are gaps in the files' own timing under the READ rules (a
100-frame status root with a 25-frame child, a 50-frame circle root with 20-frame children).
Still open there: whether retail's draw really shows those gaps (the READ rules say so; not seen
on a retail client), and the ACT_L played once when no buff token will come (`SkillEffects.act`
with `with_aura`), which is OURS. One-shots that never finish (`mad_general_at03`) end after 30 s
(OURS guard). Retail keeps them on the body's leftover list until the body goes, or until an
update with its third argument 0 (`CCompChar::FUN_00c33230`). What that argument means is OPEN.

Still open, by the files each would add:
- **Nodes with no texture** (75 files; EFP_FORMAT.md "Assets that do not load"). Retail binds a
  NULL texture and draws them. 20 texture paths are absent from every archive, 4 more exist only
  elsewhere, and in 46 files a node names no texture. What D3D9's fixed-function stage gives for
  D3DTA_TEXTURE with nothing bound was not established. Next: read what the driver/D3D9 runtime
  returns, or find a retail capture of one of these nodes.
- **Meshes** (16 files). Not a gap: `hwan01/02.bms` are `JMXVBMS 0109`, which the retail client
  refuses too (READ, Prim.cpp and PrimGeometry.cpp accept only 0110), and 4 mesh paths are absent
  from every archive.
- **Follow levels: DONE (round 621).** The effect now simulates in world space over its host, as
  retail does, and 924 of the 975 Link files make a trail on a moving host (781 on a still one).
  - Still OURS: the effect turning with the body, not with its bone.
  - Checked only on renders, not against retail.
- **Link details**: the LinkMode controller (none of the three Link routines reads it), and
  whether the reversed-winding inference that decides which face of a Link strip is culled
  (cull 3: 17 LinkObj and 4 LinkPipe nodes) matches a retail render.
- **The flight of AT_MOV_\* rows** (projectiles). They play at the caster for now. MovType and
  the Act Option columns are unread.
- **The skill phase clips.** Retail advances READY → WAIT → SHOT on each phase clip's end, and
  fires StartEvent ≥ 1 on the clip's animation events (IDecoSkill `FUN_00a534d0` and
  `FUN_00a59970`). The client has no per-phase clips. `SkillEffects.cast` times the phases from
  skilldata's Action_PreparingTime and Action_CastingTime (INFERRED) for targeted casts. Self and
  ground casts (616-620 integration) take their timing from the skillaniset2 body plan instead
  (`SelfCast.effect_timings`): no body clip advances at once (READ), and Ghost Walk's WAIT holds
  for OpSkillMove, with the WAIT clip's length as the fallback end (OURS). Still open: a READY
  clip's length where a skillaniset2 row names one, and the per-phase clip events.
- **What another player's cast shows.** Only its buff aura (OpBuffStart) reaches this client; its
  READY/SHOT/ACT_S effects need the server to tell the zone about the cast, which it does not.
- **Where the hit effect sits.** characterInfo's DamageBone and DamagePos place it in retail; the
  client uses mid-height.
- **Unread details:**
  - which option sets the emitter globals (`DAT_01114d54`, `DAT_01114d58`) and its retail
    default; the renderer assumes full quality;
  - the parent-rotation part of "follow the parent";
  - what SetSpherePos space 0's stack vector holds when no earlier command set it (zero here);
  - which BlendScaleGraph SetGraphRandomScale names;
  - FrameTextureSlide's head;
  - `StartBone` `*` and `#…`;
  - the effect's alpha byte `DAT_00edbd40`.
- **The 58 `F8FILE` containers** (`system\arksolid_*`) and **the 7 `0000` files**.

### Trees and materials (round 625 and its review): leaves load, and the material rule is the client's (flag word, env map, MTRL mod, two passes). These are left:

- **Tree sway:** swaying trees now expose their `.bsk` and `.ban`, but pieces are still placed
  rigid and skinned leaves draw in bind pose.
- **MTRL mod details:**
  - its animated colour (the keyframes) replaces the layer's in retail, and that is not drawn;
  - the TEXTUREFACTOR argument is taken as white;
  - D3DBLEND pairs other than mix, add and multiply are drawn as mix.
- **Env-map reflection:** the mod's own texture stages are not drawn; only its alpha rule is.
- **Unread flag bits:** `0x40`, `0x100` and `0x2000` are not read. `0x4` (specular) and `0x8`
  (lighting off) are read but not drawn.
- **Mod sets:** only the always-on `ambient` set is applied; clip-bound sets are not.

## Parked, with the state written down

### Moat water — **resolved by the `.m` (round 627)**
Retail draws water from each `.m` block's PlaneType/PlaneHeight, not from the `.nvm` plane map. In
96/168, only block row 4, the moat band, is PlaneType 0 at -20. Rows 0-3, the farmland at -43 to
-80, are -1, so they stay dry, although the `.nvm` marks them water. The moat draws since round
627.

### Water — what round 627 left (WORLD_ISSUES.md's six-hundred-and-twenty-seventh round)
- **The region flag at region+0x2475.** `FUN_00a35c50` forces PlaneType -1 on a whole region when
  it is set.
  - READ in the review follow-up: `FUN_00a361b0` copies it from byte 0 of the region's entry in
    the world's runtime map at world+0x7b64. Only `SWorld::vslot_046(1, regionId)` sets that
    byte; `SWorld::vslot_045` (a named object added to a region at run time) creates the entry
    with it at 0.
  - It is game state set at run time, not map data. Nothing that calls slot 46 was found through
    the world pointer's vtable, so which regions it hides, and when, is OPEN.
- **The shoreline alpha format.** `DAT_0110f728 < 3` picks A8R8G8B8, where deep water's alpha is at
  most 240/255; the other branch is A4R4G4B4, where it is 1.0. This build uses the second. What
  sets the value is not found.
- **The Water Reflection option (world option 6) is drawn since round 628** (`WaterReflection`,
  default ON as the shipped SROptionSet.dat has it). What is left of it:
  - **The scenery objects in the mirror are unclipped.** The terrain clips (a mirror-only
    `MirrorTerrain` copy with `WaterReflection.clip_material`, round 628 review). The objects'
    materials are ObjectLoader's.
  - **The target is screen-aspect**, not retail's stretched 512x512.
  - **The callbacks the reflection skips** (`LAB_0084c700` stages 1 and 2) are INFERRED to be
    the characters and the effects. The mirror leaves them out.
  - **Retail's bump time base** `*(float*)(DAT_0110f7d0 + 0xa0)` is assumed to be seconds.
  - **The option's default with no file** is still not found.
  - **The saved file:** the option is SROptionSet.dat tag 5 in retail, and a player sets it here in
    `user://settings.cfg` `[world] water_reflection`.
- **`wave1..3.ddj`** are used by neither water pass; only `SWorld::vslot_027` hands them out.
- **The per-object water branch** (`+0x237e & 0x8000`, dungeon region ids) is mirrored by skipping
  block water there. No `.m` region has that bit, since x tops out at 127. The dungeon object water
  itself (a `.dof` world) and the `wave1..3.ddj` textures are not traced.
- **WaterColor's timing.** It is sampled at the fixed environment reference time, and the special
  modes (+0x2eb4, +0x2e5c) are not applied.
- **Walking under water is authentic** (the user, 2026-09-28): it happens in the original game too.
  Leave movement alone.

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

Round 583 read three record fields in the loader (`FUN_00a361b0`;
[protocol/MAPO2_FORMAT.md](protocol/MAPO2_FORMAT.md), "Corrected (round 583)"). Bytes 22-23 are
the object's uid and bytes 28-29 its owner region, and together they are the key the loader files
the object under. Byte 27 bit 0 is a skip bit: in `lists[1]` and `lists[2]` a record with the bit
set is not built. **Open**: `World3D` does not test that bit, so it draws 240 `lists[2]` records
(in 41 regions, none of them Jangan's) that retail does not build from the file. They are
Baghdad's `bagh_masin_lightwall` (120), guild barricades (48), Baghdad's event barricades (46),
Petra's fires (24) and `res\dun\jupiter\piety\piety_golddoor.bsr` (2). What does put
them in the world (a siege, an event) is not traced. Next step: trace who creates an object
filed with the bit set. Only after that, decide whether to skip the bit.

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
- Water is the `.m` block's **PlaneType 0** at its PlaneHeight, shoreline alpha `clamp(trunc((plane - h) * 0.5), 0, 15) / 15`, drawn two-sided at 10 fps (round 627).
- A bind pose is a poor test of a rig: both character bugs this project had were invisible at rest.
