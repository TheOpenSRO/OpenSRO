# What's left

The single ordered list of open work. Each entry says what is known, what is *not*, and the next
concrete step — so picking one up does not mean re-deriving how it got here. Detail and evidence
for every item live in `docs/WORLD_ISSUES.md`; this file is the index.

Ordered by value per unit of effort, not by how interesting the problem is.

Two lanes are running in parallel: the **world** lane ([HANDOFF.md](HANDOFF.md)) has items 1-3,
the **UI** lane ([HANDOFF_UI.md](HANDOFF_UI.md)) has items 4-5. Each handoff covers its own lane —
where it stopped, the tools for it, the traps — and points back here for everything else.

## Round 788 lane R follow-ups (the original client logs in to OpenSRO; opcodes/gateway.md)

- [x] **The original client (vSRO 1.188) logs in to OpenSRO's server and shows its character
      list** -- the retail gateway and agent listeners (`-retail-gateway-addr`), MEASURED under
      Wine on the render box. Start is refused (0xB001 0x40F, then the list again).
- [ ] **The world for the original client.** Start is refused: the in-world protocol (0x3013 and
      everything after, `charselect.md` "Start") is not spoken on the retail agent. The next
      concrete step is 0xB001 [1] followed by the character data 0x3013 (client FUN_008a8c00).
- [ ] **IBUV (the image code) is skipped** on the retail gateway: 0xA102 goes straight after the
      password. Needs the 0x2322 blob's format (another round-788 lane decodes it) to send one.
- [ ] **No idle limit on the retail listeners.** Retail sweeps every 10 s and closes past 60 s idle
      (the 60 s INFERRED: no override of the default found). The client's keep-alive (5 s of
      silence) would keep a live one open.
- [ ] **"Already connected" between gateway and agent:** the gateway decides with no session and
      the agent admits with `LoginService.AdmitSession`; whatever registry the login-rules lane
      keeps must be kept there too, and a login admitted but not yet at the agent (up to 10 s) is
      not "connected" yet (retail registers it at the GlobalManager's admit).
- [ ] **0x2005 / 0x6005 after the identity** are not sent (the client has no handler for either);
      the u16 in 0x2005 is INFERRED to be the server's id. Revisit if a client version needs them.
- [ ] **The retail lobby from the real client's create screen** was not driven (the characters
      in the MEASURED run were made on OpenSRO's own wire); the 0x7007 create and name check from
      sro_client itself are untested live.

## Round 720 follow-ups (the teleport structures' effects)

- [x] ~~The gates' animated textures and material mods~~ -- **round 722**: TEXANI read and drawn
      for every placed object (359 files carry one); the MTRL mods were already drawn (round 625).
      Left: TEXANI on characters and items (SkinnedBsrAssembler). ~~The mode 0/1 draw-flag
      difference~~ -- **round 786**: mode 1 moves stage 1, the MULTITEX mod's second texture, both
      READ and drawn ("Fountains, waterfalls and their splashes are animated").
- [ ] **Display-value blending for every EFP** (round 722): the objects' ambient effects now blend
      in display values under Forward+ (`EfpEffect.display_shader`, a screen read), as Direct3D 9
      does; skills and auras still blend linearly. One switch (`use_display_blend`) would extend it.
      A user decision: every skill's look changes, and a screen copy is taken while one draws.
- [x] ~~**Every placed object's `ambient` set**~~ -- **round 786** (`WorldAmbientFx`): every placed
      object plays its set, at the original's ranges (READ: 2020 for `.o2` lists[1], 480 and the 9
      nearest sectors for lists[2]), stepping only what is seen. Round 720's review had measured
      play-everywhere at Jangan, every effect stepped, as +1.44 ms; this round's gates are in
      WORLD_ISSUES ("Fountains, waterfalls and their splashes are animated").

## Round 788 follow-ups (lane S: the server's login rules and bans; docs/rounds/r788s.md)

- [x] ~~One place decides a login~~ -- **round 788**: `session.LoginService` for 0x0001 and 0x6102
      (wrong passwords per name with the automatic block, punishments, already connected, the
      per-IP limit, inspection, full), typed punishments in `account` (Mem and SQL), `/ban` (retail's
      kick) and the OURS `/block`, `/unblock`, `/blockinfo`. docs/protocol/opcodes/login.md, "The
      login reply, READ (round 788)".
- [x] ~~**The retail listener's front door**~~ -- **round 788** (lanes R and S merged): the retail
      gateway decides through `Login` with no session, the agent enters the account in
      `AdmitSession`. Left: the up-to-10 s window between the two, where retail's GlobalManager
      already holds the account and OpenSRO does not (a second login then fails at the agent with
      `[2,2]` instead of at the gateway with `[2,3]`).
- [ ] **Chat and trade blocks (types 4 and 3)** are stored, not enforced: the game server's
      `{u8 active, 16-byte end}` per type and 0x3405 `{u8 0 chat / 1 trade, u32 packed time}`
      (RESEARCH section 2; client 0x86e5b0). The Social round.
- [ ] **OPEN, retail:** how `_CertifyTB_User` treats a type-2 punishment (the account database is
      not on the box; OpenSRO blocks as type 1); whether the wrong-password count expires (OURS: an
      hour); which row `_QueryBlockGuide` returns when several blocks are active (OURS: the one
      ending last); whether the procedure checks the password before the block (OURS: it does).
- [ ] **The image code (IBUV)** is not built: retail asks it after every right password and clears
      the wrong-password count only on its success; OpenSRO clears it on the login's success.
- [ ] **The SMC's other punishment fields** (shard, character name and info, position, sentenced
      time, e-mail template) are not kept; nothing reads them yet.
- [ ] **The wrong-password counts are in memory**: a restart forgets them (where retail keeps them,
      GlobalManager's memory or the database, is not traced).

## Round 785 follow-ups (the skills, server side; docs/protocol/skill_census.md)

- [ ] **Ammunition (`cnsm`, 386 player rows)**: READ (skill_attack.md "Ammunition"): the worn
      slot-7 item's TypeID3/4 and count, 0x300e, spent `cnsm[2] x mc[1]` after the blow, 0x3201.
      OpenSRO keeps no count on a worn item (the kit puts arrows in the bag). Needs a quantity on
      the worn ammo slot, then the gate and the spend.
- [ ] **Hate retarget**: the threat table is credited (`session/skillhate.go`, `tant`/`tnt2`/
      p187), but the monster AI faces its first attacker; wiring `ai.ThreatTable.Resolve` into the
      BATTLE tick is the AI lane's `mob-threat-retarget`.
- [ ] **Monster skills on players**: an AI-cast row's `efr` area, `ko`/`kb` on a player and the
      action block on `OpMonsterAttacked` (the AI lane's `monsterStrike`); READ shapes in
      skill_targets.md / skill_attack.md.
- [ ] **Stealth, detection, transforms, summons, traps** (`hide` 47, `dttp` 36, `msch` 12, `summ`
      24, `trap` 25): body modes 6/7 on the wire, spawned objects. skill_support.md has the reads.
- [ ] **Defensive links** (`dmgr`, `lkdr`, `lkdd`, `lkag`, `abnb`, `lkdh`): act on blows a
      character takes (FUN_005a0b80); need the monster-strike path's hook.
- [ ] **Weapon-scaled heals** (`mwhh`/`mwmh`/`mwhs`, Formula_WeaponAvgDamagePercent), the `eshp`
      group aura, the resurrection's EXP return and `rmut` buff, the `defp` cap, `pdmg`.
- [ ] **The plain swing's blocked hit with a percentage** (below) is fixed for skills
      (skillhit.go: a blocked hit is kind 2, 0 damage); `performAttack` (the combat lane) keeps it.
- [ ] **Client (r785-skill-cli)**: draw the 0xAB action block (skill_hit_block.md): per-target
      hits, knockdown/knockback positions, the chain links' OpSkillCast, debuff icons on monsters
      (OpBuffStart ownerKind 1), the 0x3080 kind 4/8 resurrection box.

## Round 746 follow-ups (the review: the skill rows are skilldataenc's)

- [x] **DECIDED in round 785: `skills.csv` comes from the ENC tables, as retail's own data does.**
      `export-refdata -mode skills -enc-exe <the player's sro_client.exe>` decrypts the files
      `skilldataenc.txt` names (the key tables read from the player's own executable, never
      copied). MEASURED: the 33,632 ENC ids (last-wins over the 26 conflicting duplicates) equal
      the user's shard `_RefSkill` on EVERY exported column, raw Params included; the shard holds
      2,512 more ids (a private server's additions -- 400 SKILL_CH_, 512 SKILL_EU_ among them) that
      the client cannot display, so they are left out. The retail GameServer reads `_REFSKILL`
      from its database (READ: no skilldata file name in its strings), and that database is the
      ENC set. 35004/35005 are gone and 36791 is at 110. deploy/README.md has the steps.
      ~~**The server's `skills.csv` comes from the plain skilldata index, not retail's
      `skilldataenc.txt`** (the review of round 746, finding 8; MEASURED). It carries 66 ids
      retail lacks, among them 35004/35005 (`SKILL_CH_WATER_BATTLEA_OVERHEAL_A/B_01`, a Europe
      cleric's leftovers in the plain `skilldata_36000`). It also has 36791
      (`SKILL_CH_LIGHT_SAINTA_ABNORMAL_A_01`) at a required mastery level of 10, where both ENC
      parts say 110. So the server would accept a learn retail refuses. The client's skill board
      reads the old cover, which matches the ENC rows, so the board does not show them. This
      predates round 746. The options: export from the decrypted ENC rows (the key tables are in
      the player's own `sro_client.exe`, `docs/protocol/magic_state_board.md`), or drop the 66 ids
      and take 36791 from `skilldata_35000`. **For the user to decide.**~~
- [ ] **characterdata duplicates** (the review of round 746, finding 7): the by-name monster
      fallback changes its winner for `"large gate phase i"` and a junk key `"0"`. `NPC_SOSUN`
      (61183) is the one code-keyed id whose parts disagree (`chinaman_spidey.bsr` first,
      `sd_m_area_merchant.bsr` last). Retail's duplicate rule for characterdata is not READ.

## The party epic (round 709+, requested 2026-10-04)

The user asked for the whole party system "fully working", matching the original down to the
opcodes. **Round 709 specified it from all three binaries** (client, GameServer, and
SR_ShardManager.exe, which owns the party): `docs/protocol/party_protocol.md` (every message and
byte layout, and the **implementation lanes** at its end), `party_rules.md` (types and caps, EXP/SP
and item sharing, jobs, party monsters, party matching) and `party_gui.md` (party window, settings,
matching, join popup and progress bar, HUD member boxes). Next: the lanes S1 server core, S2
sharing and party monsters, S3 party matching, C1 client net and party window, C2 matching
windows, C3 HUD member boxes, each with a live multi-client test. The OPEN items that still block
a lane are tabled in round 709's WORLD_ISSUES entry.

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
      `ifoption*.txt` family); its Audio tab works, and its Video tab since round 694 (below,
      "The Option window's Video tab"). Still open: its Input and Game tabs (our UI scale / chat
      font / name range stay on the Ctrl+F3 debug panel).
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
      a guild short of points gets `0x18c5`, after the gold flag. OpenSRO charges only the gold,
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
        (`CGObjNPCNPC::Create`, `0x4c677f` / `0x4c736f`). OpenSRO derives it from the codename
        (`NpcServiceReader.offers_repair`) and hides both buttons at every other store. A headless
        test drives `_show_repair_buttons` on a synthetic store window (check (j) of
        `npc_service_reader_test.gd`). Not yet seen in a running client: a `OPENSRO_QA_SHOP` run
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
      (2026-09-19): eleven packages' tests share the local `opensro_test` PostgreSQL database, and
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
      OpenSRO flushes it on disconnect (`session.GuildPointsDisconnectHandler`) and at a clean stop
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
      `0x4b2bd0`, round 531). OpenSRO charges only the itemdata gold, so a guildless player who
      sends the buy gets the crest. To build: (1) import each good's device-8 amount
      (`refpricepolicyofitem` joined through `refscrapofpackageitem`); (2) in `shop.Service.Buy`,
      after the gold test, as `GObjPC::CheckCurrencyRequirement` (`0x617360`) orders them, refuse
      `0x18c4` `UIIT_MSG_GUILD_STORE_BUY_LIMIT` to a buyer with no guild or who is not the master
      and `0x18c5` `UIIT_MSG_GUILD_LACK_GP` when `Guild.GatheredSP` is below the amount; (3) spend
      the points. Where the engine spends them is NOT followed yet: `0x618930`'s flag-8 arm copies
      the amount into the purchase record (`+0xa8`), and the reduction of the guild's total after
      that was not traced. `OpShopBuy` names only the item, which is all a price-keyed check needs.
      See `character_state.md`, "What the server checks at a guild store (round 530)".
- [ ] **The monster world (the 2026-09-30 request): every species, every nest.** Round 654 built
      the base: `export-refdata -mode monsters` and `-monsters-csv` (`server/internal/species`)
      hold all 7,604 characterdata monster species (TypeID 1,2,1,x), the roster's eleven re-derive
      from it exactly (`roster_changed=0` on a retail export), and a GM `/spawn` takes any of them
      by code name, id or English name. Who spawns where is unchanged. Open, each with its round:
      - **round 655**: whether the retail CLIENT draws the Org row's model (col 4) for the 156
        species whose own model (col 52) is "xxx" -- 89 of them are placed (4,649 npcpos rows).
        The table records the Org's model and `ModelFromOrg`; nothing draws by it yet.
      - ~~place every nest~~ -- **done for the field (round 660, `-full-map`)**: 10,124 field rows
        as nests; the dungeons (1,915 rows) are not placed; the uniques rotate over their 70
        spots (round 661), and the Pharaoh temple's 90 rows are left to their instance worlds.
        See "The monster world's nests (round 660)" below.
      - cols 75 'era' and 77 'hra' per species: combat still computes both as `2*level + 25`
        (`combat.MonsterRate`), which holds for both columns on 2,581 of the 7,604 species (MEASURED,
        round 654; round 380 had ~37 % over its own row set). The table
        carries both (`Col75`, `Col77`); the next step is reading which param the hit roll uses.
      - col 76 'bri' (block) is carried but not handed to combat (`combatSpeciesOf`): fix the
        blocked-hit item below first.
      - TypeID4 (1 field, 2/3 job-trade thieves/hunters, 4 structures and quest rows) is carried;
        what the server does with it -- and where a monster's party-support nibble
        (`+0x1cd8 & 0xf0`, combat.MonsterHPPercent) comes from -- is not read.
      - 18 species name 49 skill ids the skills export does not hold; they swing what resolves.
      - with a skills table from before round 654 (no AI_AttackChance) a non-roster species
        swings its primary skill only; opensro-01 needs the re-export (deploy/README.md).
      - the classic uniques in this archive are the "[INT]" rows at level 110 -- MOB_CH_TIGERWOMAN
        is "Tiger Girl[INT]" -- so `/spawn tiger girl` finds nothing; the code name (or id) works.
        188 display names are shared by 7,087 rows, and a name picks the first in table order;
        the reply names the code and id it picked.
      - GM-ONLY caveat: a spawned monster's fallback EXP is the disclosed `combat.ExpFor(maxHP)`
        over the rarity-scaled HP -- paid when no level table with an exp_unit column is loaded
        (session/combat.go's kill path; with one, the real leveldata col 5 at min(levels) wins) --
        so a giant-HP species pays absurd EXP there (MOB_TQ_WHITESNAKE: 250M). Nothing the roster
        spawns is affected. Settle it before round 657 places table species.
      - a GM-spawned rarity-3 or non-(1,2,1) species hatches at a random heading, where the
        engine takes its nest row's (combat.SpawnSpecies' DISCLOSED note).
- [ ] **Monsters move only with `-monster-ai` on, and do not chase or notice anyone yet.** They
      strike only when struck (round 254's cadence cap; the counter is still a synchronous reply in
      the player's attack handler). **Round 537 built the monster AI tick** (`session.RunMonsterAI`,
      `server/internal/session/monsterai.go`) behind cmd/server's `-monster-ai` flag
      (`OPENSRO_MONSTER_AI`), which is **off by default**: SPAWN -> IDLE -> the 76-in-100 WANDER
      roll, legs at the walk speed pushed to the zone as `OpMonsterMoved 0x007C`, IDLE never
      stopping a leg under way (`0x559c80`), HOMING at the run speed past a 200-unit roam radius
      (own design), one `OpMonsterMotionList 0x007F` after each monster list, and an interim hold
      that stops a struck monster at the blow and keeps it in BATTLE while a keep-up of any player in
      its zone is on it, released only after two ticks in a row without one (round 539). It stands on round 536's core (the roster's real speeds, `combat.MoverStep` with both
      of the engine's clamps, the hub motion API, the pure rules) and round 533's client, first
      released in v0.1.435. Every stand-in is in `docs/protocol/monster_ai.md`, "OpenSRO's
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
        `OpReviveResult 0x0029` decoded, `OPENSRO_QA_REVIVE_AFTER`), the server half in round 549
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
        flipped; (2) the render-box live check (`OPENSRO_PLAYER_DEAD_STATE=1`, `/spawn` a killer,
        `--attack`, assert HP 0 then "Revived." after the button or `OPENSRO_QA_REVIVE_AFTER`);
        (3) the flag's flip (`deploy/README.md`, "Player dead state (off by default)"). Stand-ins,
        each disclosed at its line: reviving in place above max level 10 (retail returns the
        character to `_CHAR.AppointedTeleport`, `CGObjPC::ResolveRevivePoint` -- OpenSRO has no
        appointed teleport; its town gates, round 576, move a player but record no return point -- kept since round 686), the empty request against retail 0x7053's u8
        option, the fallback and its 30 s, the refusal wording, the pick-up / duel / zone-change / GM
        refusals (their retail handlers not read for a life-state test), the item kind usable while
        dead (`(tid & 0xf800) == 0x3000` in `Item_HandleUseItem`), the duel's own death path (still
        `ResetHP`, alive: which death kind a duel is remains unread), and revive at entry rather than
        staying dead across sessions. Not modelled: the siege countdown gate, the cause-2 branch.
        **Round 665 (retail's resurrect choices, `character_state.md`, "The resurrect choices"):**
        the dead window offers retail's two buttons and `OpRevive` carries retail's option byte --
        option 1 to the return point, option 2 in place at level 10 or under; the 30 s in-place
        auto-revive is gone (retail has none); a character leaving dead is saved at the return
        point; with the flag off a kill's respawn is moved to the return point. **OPEN, in order**:
        (1) ~~the bind point~~ -- DONE in round 686: a town gate's "Designate as return/recall
        point" sets `_CHAR.AppointedTeleport` (`GObjPC_HandleDesignateRecallMsg_059`, READ), the return point is that
        gate's point, else the race's gate (`STORE_CH_GATE` / `STORE_EU_GATE`, SR_ShardManager
        `FUN_0042bb20`, READ) -- see "Town teleporters" below for what is left;
        (2) ~~body mode 2 after a revive and the world entry~~ -- DONE in round 786 (6.0 s, the
        world's slot `0x70` = `0x5eb2d0`; held until 0x3012 first; `protocol/arrival_guard.md`); (3) resurrection by
        another player and by scroll (`trs_wait_response::vslot_002`, `FUN_0049ff20`), which the
        "Waiting for other player's help." button stands for -- shown disabled today, while
        retail's click closes the box; (4) the retail message box art
        (`msgbox_rebirth_button.ddj`) for the window; (5) whether to default `-player-dead-state`
        on -- retail has one death, the dead state (a user decision); (6) with the flag off, a
        death writes no `[n]Experience Points lost.` line to the system window -- the status
        label carries the loss, but `World3D._show_own_strike` (~16966) only adds that line
        through `_enter_dead_state` (pre-existing; the release's final review, LOW).
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
        -- is not carried: OpenSRO's blows have no hate value, and the magnitudes wait on
        mob-threat-retarget. Live check not feasible with one driven client.
      - Then the threat table's retarget rules (round 259, `ai.ThreatTable`, mob-threat-retarget),
        the AI-skill triggers (round 260, mob-ai-skill-triggers; the second attack skill is built,
        round 554), the HOMING wobble, and the server-side blocked probe that stops legs
        crossing walls (mob-server-geometry-probe; whether to turn the flag on before it exists is
        a user decision).
      Background, still true: a monster moves in retail by issuing the client's own movement
      request `0x7021` (`FUN_00540f70`; payload in `docs/protocol/opcodes/movement.md`, round 364),
      the retail shape OpenSRO's placeholder push will eventually give way to
      (`PROTOCOL_DECISION.md`); the server's unprompted pushes are the 0x3NNN group of
      `docs/protocol/server_senders.tsv` (round 368).
- [x] **Four roster species are drawn as capsules: their characterdata rows name no model (round
      533).** Done in round 655: the client draws a row whose own model (col 52) is `xxx` with the
      model of the row its col 4 (OrgObjCodeName) names, one level only (READ,
      `CICMonster::vslot_025` 0x9d3850; docs/protocol/characterdata.md). The four now draw as
      bigeyeghost, gyo, waterghost and tombstone; 120 of the table's 142 `MOB_*_CLON` rows take
      their Org's model (MEASURED, `probe_monster_build.gd`). Still open: col 48 (Scale), which
      CICMonster applies as scale / 100 from the row's own record (a `_CLON` is often smaller than
      its base: `MOB_CH_TIGER_CLON` is 80), is not applied to any monster.
- [x] ~~NPC facing is a stand-in until `Tab_RefNest` is imported~~ -- **done, round 708**: the server
      spawns every NPC as the original does (retail 0x3017/0x3019/0x3018 group spawns per 320-unit
      block of the player's window, `docs/protocol/npc_spawn.md`) at its nest's position, facing its
      nest's `wInitialDir`; the client builds no NPC of its own. The chain is READ end to end:
      `Nest_Hatch` 0x5607b0 -> `EnterWorld` 0x485360 -> SetHeading (cos a, sin a) -> the record's
      `atan2` u16 (0x487ce0/0x488050) = wInitialDir -> the client's `h = angle + pi/2`
      (0x9c3a70/0x9c40b0) facing (sin h, -cos h) = (cos a, sin a). 230 of the 257 npcpos NPC rows get
      their nest's angle (MEASURED, the user's shard, EXTERNAL; two of them through the review's
      200-unit same-region pass, OURS); the other 27 have no nest of their own in that database and
      keep `NpcFacing` (OpNpcFacingUnknown 0x00B6, OURS).
- [ ] **The 27 nest-less NPC rows** (round 708): Jangan's teleport soldier "Soldier Choiyoung
      [Teleport]" (`NPC_CH_SOLDIER_EM1`) and its gate-mates `_SO1`, `_EA2`, `_WE1`, the Europe
      advisers, the SD agents, the treasure boxes ... have their `Tab_RefTactics` rows but no
      `Tab_RefNest` row in the user's shard (nest ids 47-50 beside `_EM2`'s 51 are missing: INFERRED
      deleted by the shard), so they face by the `NpcFacing` stand-in -- the retail screenshot shows
      Choiyoung facing south beside Fengil. The two gacha NPCs have nests only in other regions.
      Needs a shard whose database has them; nothing in the client archive carries the angle, and
      retail has no "no angle" form.
- [ ] **NPCs the shard adds** (round 708, OURS): the server spawns npcpos's NPC rows, not the
      database's nests, so six custom world-1 nests in Donwhang (`NPC_TITLES`, `AVATARS`,
      `GOLDMINER`, `QUESTS`, `EGY`, a second `NPC_CH_SPECIAL`) are not spawned. Spawning from the
      nests (the original's own source) is the alternative; it would bring the shard's customs in.
- [ ] **Town teleport gates as server-sent objects** (round 708): retail spawns the gates through the
      same 0x3015/0x3017 path as a `CITeleportGate` (class link 0xef1dac) with its own body reader
      (CITeleportGate slot 25, not read). OpenSRO still binds them client-side from teleportbuilding
      (`_bind_region_gates`). Read the gate record, spawn the teleportbuilding rows from the server.
- [ ] **The talk menu from the spawn's interaction set** (round 708): the client keeps a record's
      interaction ids on the holder (`npc_interactions`) but builds its talk menu from its own
      archive; the retail client builds it from the set at +0x500 (`FUN_00700440`). Needs
      `-npcs-csv` on the server for the list to be non-empty.
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
- [x] **Chain skills, link by link -- done in round 785** (`session/skillchain.go`): the server
      walks Basic_ChainCode itself (READ: the tick is the SERVER's CGCharAutoCommandActor), each
      link its own blow, gate and 0xB070-shaped OpSkillCast at its own time (the 500 ms budget
      rule), the last link's AutoAttackType decides the hand-off. ~~The skill tick (`0x4ae590`) plays a row with a non-zero
      `Basic_ChainCode` (col 9, `+0x68`, exported since round 502) as a sequence. Phase 2 makes it
      the current link with its ActionDuration as the remaining time, less what is left of
      `+0x28`. The action's release (`FUN_004ac920`, `sAutoCommand::ReleaseAndClear` `0x4ac980`)
      seeds `+0x28 = 500` and zeroes `+0x2c`. On the link where `+0x28` runs out, the remainder
      moves into `+0x2c`, and phase 3 adds `+0x2c` to the final link's wait, so the final link
      waits up to 500 ms longer (`docs/protocol/auto_command.md`, phase 2). Phase 3 re-enters
      phase 2 with the next link's row, and only the LAST link's `AutoAttackType` decides the
      hand-off. OpenSRO resolves only the row the player cast, so a row with a non-zero
      `Basic_ChainCode` resolves one row's blow and does not hand off (round 502's disclosed
      departure). Counted in round 507 on the player rows: 1,246 carry one, 582 true heads that no
      other row names (e.g. `SKILL_CH_SWORD_SMASH_D_01` -> 7140 `..._D2_01`) and 664 intermediate
      links. A head's `AutoAttackType` always equals its final link's (463 type 1, 49 type 2, 70
      type 0), so the departure costs the hand-off on the 463 type-1 true heads. (Round 502's "1,012 chain heads"
      was the type-1 rows with a non-zero column 9: 463 heads and 549 intermediate links.) Next:
      resolve each link's blow on its own timing, then apply the last link's hand-off rule.~~
- [x] **Self-cast and ground-cast skills (client) -- round 617; round 785 replaced the ground pick.**
      Round 785 (READ, `FUN_0081ba10`): a `tele` / `tel2` row casts at once at the point under the
      cursor -- retail has no pick mode, so the cross-cursor pick below is gone -- and OpSkillMove
      slides the caster there at 500 u/s with its WAIT clip, effect and afterimages
      (`FUN_00a51320` / `FUN_00a50f70`) instead of snapping it. Round 617's note follows.
      Grass Walk, the imbues and every
      Target_Required 0 row cast with nothing selected (OpUseSkill targetType 0); Ghost Walk picks a
      ground point (targetType 2; right click / Escape cancels); OpBuffStart/End/OpSkillMove are
      decoded (`NetClient.buff_started` / `buff_ended` / `skill_moved`, `send_buff_cancel`), the
      buff's `runSpeed` sets the run speed and OpSkillMove snaps the player. Still open:
      the server half (round 616) was not live-tested with it; the Ghost Walk move is a snap
      (duration OPEN, `tele` value[0] = 500 unread); retail's ground-pick cue (round 697: retail
      sets NO cursor for a ground cast -- every caller of its cursor manager was read,
      docs/protocol/CURSOR.md -- so the cross is ours; round 698 READ the cue retail shows instead:
      the selection ring's object with `select_02` in range / `select_04` beyond, `FUN_00629fa0`
      -- not built; once it is, the cross goes); the retail answer for a Target_Required 1 heal with nothing selected
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
      nothing reaches it -- though since round 654 the species table carries col 76 for every species
      (938 species read 20, one 40), so wiring it is one field once this is fixed. Next: skip `ApplySkillPercent` for a blocked blow, with a test, before
      monster block is wired.
- [x] **Mastery on the real rows -- casts done in round 785** (`session/skillmastery.go`, the
      Params column carries `getv MAAT`; both mastery slots). LEFT for the combat lane: the plain
      swing still passes mastery 0 (`plainSwingOf`/`performAttack`); `skillMasteryPercent(ctx,
      skills, id, baseRow)` is the call. ~~**Mastery on the real rows: export `getv MAAT`.** Stage 1 of the damage pipeline scales
      the roll by the caster's mastery level, but `Skill_GetRequiredMasteryLevel` (`0x59e770`)
      returns 0 unless the row's `CRefSkill+0x574` is non-zero, and the only writer of `+0x574`
      is the row's own `getv MAAT` parameter (`SkillGlobal::RefSkill_ParseParams` `0x587630`).
      Measured on the retail rows (`/var/tmp/allskills.txt`): of the rows carrying `att`, 2,027
      of 2,028 `SKILL_CH_` rows carry MAAT but only 24 of 1,502 `SKILL_EU_` rows do (the EU staff
      and both wand base attacks among them). refdata exports no MAAT flag, so OpenSRO gets it
      wrong both ways:
      - plain swings pass mastery 0 (round 505), where the engine scales the CH, staff and wand
        swings;
      - the cast path (`useSkillHandler`, `session/skill.go`, the `ref.Mastery1 != 0` block)
        scales every skill with a mastery slot, so it also scales EU attack rows the engine
        leaves alone (1,478 of the 1,502 EU rows carrying `att` lack MAAT).
      Next: export a MAAT flag in the skill CSV (a new trailing column, the round-504 pattern),
      then gate both paths on it (`combat.MasteryDamagePercent`'s `hasSkill` becomes "has a row
      with MAAT"), and give the plain swing the caster's level in the base row's mastery.~~
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
      cast are too. **Round 519 built the walk on the client** (OpenSRO's server does not drive
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
      - ~~a keep-up repeat that finds the target out of reach ends the run (the engine walks again)~~
        -- **round 785**: the repeat now says so ("too far away" naming the monster, after the
        monster's server position as an `OpMonsterMoved` resync) and the client walks back into reach
        and clicks again, at most 3 times running without a blow; a click inside the base attack's
        re-use delay is armed for when it ends instead of dropped (`combat_presentation.md`);
      - **a filed server departure**: OpenSRO's server reach-gates the `Target_Required` 0 rows
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
        released walks again, up to `CombatNet.APPROACH_RETRY_CAP` (3, OpenSRO's own) times -- a
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
- [x] **Linear fog between the real planes** -- round 702. `WorldFog`: a full-screen pass, first in
      the transparent sort, reads the opaque depth and blends the zone's READ fog colour at
      `(view depth - start) / (end - start)`, start/end = channels 10/11 x the Background Sight
      Range's view distance (READ, `Map::FUN_00a26f60`); terrain overlays and water are drawn before
      it, blended MTRL mods fog themselves (`srr_fog_*` shader globals); Godot's exponential fog
      (OURS density, sun scatter and aerial perspective) draws nothing. A **temporary** Video row
      "Fog (temporary)" (the user's request, on = the original) is to be removed once the user
      decides. Left: the indoor branch (world+0x26bb set: start -200, end far / 10 -- when the flag
      is set is INFERRED, not drawn); the per-frame easing toward a new zone's planes (and the
      environment following the camera's block at all: `Map::FUN_00a1baf0` takes its record from
      the first drawn block, the camera's -- MapmWater.environment_at -- every frame, lerping
      by dt x 0.5 unless a snap flag is set; here only the water follows the camera, the fog, sky
      and light stay the grid centre's); fading-in characters (AppearFade) are not fogged during
      their 2 s fade; the blended MTRL mods' own FOG still mixes in linear light under Forward+.
      **Round 705:** the Forward+ pass mixes in display values (`BLEND_FORWARD`), as Direct3D 9
      and Compatibility do -- exactly at a reference destination shown at 0.2 (OURS) and at full
      fog, within 17/255 elsewhere; the exact mix needs the screen read, +1.4 ms at 4K (MEASURED),
      so it was not kept. **The user's near fog (v0.1.486 on macOS/CrossOver) was not
      reproduced at the default settings** on the box: at the user's spot the pass applies 0 to
      the dragon (view depth 1018) and the gate (1450-1520), probe-measured. Background Sight
      Range 1 (planes 911..1200, the READ rule) reproduces the shape of their picture; their fog
      colour is greyer than ours, unexplained. Ask for their log's `World3D: video options
      applied ... background_sight_range=... fog=A..B` and `environment fog (READ)` lines.
- [ ] **Shadow Detail "Detail": the original's projected character shadows** (READ in round 702
      and its review: `SWorld::vslot_025` 0xa17ab0, `Map::FUN_009f35f0`, `FUN_009f2f80`): up to ten
      characters within 300 units of the player (key `(int)(dist x 10)` <= 3000), each drawn into a
      96 x 96 target from the sun and kept as 32 x 32, the ground cells under it redrawn with it
      projected; the ground keeps 1 - 150/255 of its colour under a solid silhouette, fading over the
      17 units below. **Built in the review (closest match, OURS method):** characters are the only
      shadow casters, the sun's map reaches 400, and a multiplying next pass on each terrain base
      (`ShadowCatcher`, k = 0.412 decoded) shows their shadows on the terrain. Left: the fade with
      height; the catcher under Compatibility (its shadowed sun is an additive pass: no catcher
      there, so no ground shadow on terrain in Detail under Compatibility); the 96 x 96 silhouette
      method itself.
- [x] **The Bloom row's look** -- round 702 review and rework: `RetailBloom` draws the original's
      bloom, READ in full (`Map::FUN_00a1d790`; OPTION_VIDEO.md), computed per 512 texel on a vertex
      grid under Forward+ (per pixel under Compatibility since round 707); Godot's glow is off for
      good. Overlays (name plates, damage numbers, party marks,
      name boxes) are drawn after it (`OverlayView`). Left (OURS, each noted by the rework review):
      under Compatibility the per-pixel taps sample the screen between 512 texels where retail
      mixes two texels' samples (mean 0.95/255 from retail's pipeline at 1280 x 720, 2.1 at
      3840 x 2160; round 707); the 4K cost, most of it Godot's full-screen back-buffer copy
      (round 702's rework entry); **the lens-flare sun sprite and the character-select
      characters are bloomed** (retail draws the flare after the bloom, and the select screen's
      characters and names after its slot 5); BerserkFlash may belong after the bloom too
      (PLAUSIBLE, not read); the character-create preview is not bloomed (PLAUSIBLE that retail's
      is); the screen texture is sampled CLAMP at the edges where retail's target may WRAP (not
      read).
- [x] **Compatibility + the Bloom row rendered black frames** (round 705 found, round 707 fixed).
      Cause (READ, Godot 4.2.2 gles3 `copy_scene_to_backbuffer`; MEASURED): WorldFog's 3D pass reads
      the depth texture, which makes Godot create the render target's back buffer with a depth copy
      and no colour texture; the canvas then never makes its own, and every canvas screen read
      (RetailBloom's, and the brightness pass's) samples texture 0 -- black. A Compatibility
      player on Middle saw a black world under the interface from round 702 on (MEASURED on the
      box: mean 5/255 with the HUD, 0 without); one with Bloom off from the start and Brightness
      off Normal saw a wholly black screen (the pass is over the interface; MEASURED: mean 0). Fixed in `RetailBloom`: a 3D anchor
      that reads the screen and draws nothing gives the back buffer its colour texture, and the
      Compatibility pass evaluates retail's pipeline per pixel from texelFetch (no mip path; the
      vertex grid cannot read the screen in GLES3). Guard: `tools/retail_bloom_box_test.sh`
      (FAILS on base 65e5d8a8: frame mean 0) and `retail_bloom_test.gd`. Left: the Compatibility
      pass costs 0.32 ms at 1280 x 720 and 2.9 ms at 3840 x 2160 on the RX 7600 (perf gate: +0.2 SAME
      at 720, about +2.3 at 4K -- for the user; round 707's
      entry), against Forward+'s grid; an upstream report of the Godot 4.2 back-buffer bug (not
      filed); any other canvas screen reader added later in the world needs the anchor shown
      (`RetailBloom._sync_anchor`).
- [x] **The camera's field of view** -- round 706: 60 degrees VERTICAL at any aspect (READ: the
      camera constructor `FUN_00bae0a0` stores 60.0 at +0x50; `CGFXVideo3d::FUN_00bae810` hands it
      x pi/180 and width / height to `FUN_00aa4ef0`, a PerspectiveFovLH with m11 = cot(fov / 2) and
      m00 = m11 / aspect), which is Camera3D.fov under KEEP_HEIGHT (`World3D.CAMERA_FOV_DEG`, the
      scene's camera). MEASURED at the user's spot: the dragon is 12.5 % of the frame's height
      here, 12.4 % in the original. ~~Left: the zoom range (20..90) is still the OURS framing choice
      of round 55, chosen at 75 degrees.~~ Done in round 778 (below).
- [x] **The game camera** -- round 778 (READ, `RetailCamera`; WORLD_ISSUES "Round 778 (part): the
      camera"): pitch +-61.35 degrees (it looks up), zoom 10..150 by 6 a notch, 0.005 rad a pixel,
      the look-at point 14.2..16.2 over the feet by distance, looking up pulls the camera in
      (40 + 110 (1 - sin(...))), a ray 5 short of what it hits, the views' drag rules, and the own
      model fading out over 0.5 s past 51.57 degrees up. Left (OPEN): `config\cameradata.txt`'s
      two entry cameras, the mounted look-at branch, the camera shake, and whether the shadow and
      attached effects take the model's alpha.
- [x] **The day phase** (round 705 finding; **settled in round 786, READ**): the latter is right.
      `CPSMission::vslot_012` (0x84c300) calls `FUN_0084ac90` every frame, which reads the game
      clock (started by the server's 0x3020 at world entry, 0x3027 on the operator's set-hour) and
      sets SWorld's phase through vtable +0x50 on the SWorld at 0x1101950 -- clock 04:00-20:00 ->
      sky 06:00-18:00, 20:00-04:00 -> 18:00-06:00, a 28 min 48 s day -- unless the console's
      TimeOff has locked it. Round 226 missed the vtable call. Implemented: GameClock, DayCycle,
      TerrainLight, the sun disc, the moon and the flare (`docs/protocol/game_clock.md`,
      ENVIRONMENT_FORMAT.md "The day phase", WORLD_ISSUES round 786 "Server time, day/night
      cycle, and the sun's colour"). Left OPEN there: the night lights (material flag 0x8, night
      particles), the flare's ghost geometry, 0x34be. The light direction +0x209a's readers were
      followed in the round 786 part "Nights are dark, and shadows follow the sun (OURS)": dead
      code (READ) -- retail's shadows keep one direction; ours follow the sun, and nights are
      darkened to a set share of noon (both OURS rows). Open with the user: wrapping the server's
      day count so the moon keeps showing after day 28.
- [ ] **The tone map (finding, round 702; no change made).** World3D's environment is Filmic
      (tonemap_mode 2, an OURS choice of the 2026-08-26 atmosphere pass); Direct3D 9 shows the
      shader's output as is. MEASURED at the Jangan spawn: Linear draws the same ground patches
      about 13 luma darker (70 -> 57) with the same contrast relative to brightness (0.32 / 0.30)
      and lower saturation in absolute terms -- Filmic is not what washes the picture out, but it is
      not the original's mapping either. Changing it re-tunes every lit surface (the Forward+ sun
      scale, the undo passes of the water, clouds, select screen); the user's call. **Round 705**,
      at the user's spot looking at the dragon (Forward+, Middle): Linear against Filmic -- gate
      wall 37 / 47 luma, dirt 50 / 65, paving 41 / 51, sky 211 / 238 (saturation 0.44 / 0.26). The
      original there: 81, 83, 61, 190. Linear moves every surface further from the original
      except the sky's saturation; the darkness is the object lighting (above), not Filmic.
      **Round 706:** objects and characters now undo Filmic after the original's formula
      (`ObjectLight.srr_obj_present`, as the select screen's bodies and the fog pass already did),
      so they show the formula's display values: MEASURED at the user's spot, bloom off, the gate
      wall 82 against the original's 81 with the undo and about 90-97 without. The terrain, the
      water and the sky still go through Filmic.
- [x] ~~Day/night cycle~~ -- **done in round 786; round 226's "not a gap" was wrong** (see "The day
      phase" above): the fixed 0.5 was SWorld's constructor value and its own dormant advance
      (0.0005/s) is indeed unused, but the game clock (0x3020, not the wall clock 0x34be) sets the
      phase every frame through `FUN_0084ac90`. The world now follows the server's clock; the sun
      angle `(phase-0.25)*2pi` is the drawn sun's.
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
      read in the same pass (`docs/protocol/character_state.md`). Left: OpenSRO's server carries
      no battle-state byte, so other players do not see the stance.

## Next up

### 0. Monster HP bars, click-to-attack, target window, damage numbers — **done** (rounds 146-149)
Monsters show a name plate and a billboarded red HP bar that shrinks on each hit (the bar was
ours and is gone since round 673, at the user's request: the health shows in the target window), a left click
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

**Facing is done (round 708)**: `npcpos.txt` has no facing, but the server's `Tab_RefNest.wInitialDir`
does; the server now spawns the NPCs with it (the item above, `docs/protocol/npc_spawn.md`). (This
paragraph used to call facing "settled as a negative" -- true of the client archive only.)

**Blocking is done** (hundred-and-twenty-second round): each NPC carries a capsule sized from its
own geometry, on the layer the player masks and the camera does not. `OPENSRO_QA_NPCBODY=1`
reports the capsule and whether a ray is actually stopped — 5 of 5 in Jangan town.

**What is left**: nothing on this item. NPCs stand, animate, are named, and are solid.

**Animated, and properly skinned** (hundred-and-tenth round). `.bms` does carry per-vertex
skinning after all -- a bone palette and two weighted influences per vertex, in their own section
pointed at by header word `0x10`, which is why an audit of the 44-byte vertex record found none.
NPCs now deform correctly and animate; `OPENSRO_NO_IDLE_ANIM=1` turns animation off.

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
  with a matching glow row; it overrides the material state entirely. Not modelled yet. Round 733
  specced it, with the tables, the tiers, the particles and the lanes: `docs/protocol/weapon_glow.md`.
- **Object-space skin entry.** An empty skin slot lands on the client's palette entry 0, drawn
  here in the model's own space (BMS_FORMAT.md). That entry 0 is the object transform is
  INFERRED, not read from the vertex shader's constant upload.
- ~~**Object brightness against the client**~~ -- **done in round 706** (WORLD_ISSUES has the
  measurements). Every object and character draws the original's own object lighting
  (`ObjectLight`, all READ): `saturate(2 x texture x saturate(object x La + max(0, N.L) x
  material x Ld))` in display values, per vertex, unshaded, with Godot's Filmic undone after it.
  La = channel 3 clamped; Ld = channel 2 clamped x 0.8 with the Bloom row on (world+0x2e54, the
  bloom target) and x 0.6 off; the material is the .bmt layer's SECOND colour (`CPrimMtrl::
  vslot_001` -> `FUN_00bf9270` put the file's second colour at the D3DMATERIAL9's Diffuse, which
  c11 reads); the light's direction is normalize(-1, -1, 0), set once (`Map::FUN_00a2f370`); the
  object colour is 0.6 for every placed object (CCompoundObj's constructor, the setter's only
  callers being the decoration records and the characters) and, for a character on a terrain
  cell, the region's .t ShadowMap byte under it / 384 (`GlobalDataManager::FUN_009cf530`,
  `SWorld::vslot_041`; `CharacterLight`). The first colour, the sun's energy 0.3 and the Forward+
  x4 no longer reach objects. Left:
  - **The Jangan dragon is about 1.3x brighter than the original's** (gold pixels (127, 98, 30)
    against (91, 79, 33), bloom off), while the gate wall beside it matches (82 / 81) and the
    diffuse term adds only 18 luma on it (`objdiag=1`): the ambient term alone draws it at
    (119, 94, 29). The user confirmed their original ran with Bloom OFF, so the bloom-off rows are
    the comparison. The ratio is not uniform (R 1.40, G 1.24, B 0.91). Ruled out (review): the
    clamp order; alpha as a colour mask; Metallic Sheen's env-map mod -- the dragon's `.bsr`
    (`res\bldg\china\jangan01\cj_jang_gate_dragon.bsr`) carries no mod at all
    (`tools/probe_bsr_mods.gd`: env_map_flags -1, 0 material mods), so `CRTModEnvMap::vslot_004`
    (0xc83690) never runs for it; the MODULATE-1x / lighting-off path of `FUN_00c42a60` (flag 8
    with FUN_00bc0fd0) -- the layer's flag word is 0x140, no bit 3. Left unread: whatever else
    makes that layer differ (its Power 1.48 and near-white specular are its only distinct
    fields, and the vertex shaders use neither), the texture as the original samples it.
  - ~~GL Compatibility has no instance uniforms~~ -- the review moved characters to per-level
    material copies (`ObjectLight.with_object_color`), so both renderers agree (the soldier at
    0.398: luma 50.7 Forward+, 48.6 Compatibility).
  - A character's colour follows its tile on a visit every few frames (CharacterLight, OURS
    cadence), not with every position as the original's setter; the dungeon branch (1.0 in a
    region with id bit 0x8000) is not reached.
  - **The user's original appears to have Bloom off** (MEASURED, the gate roof's edge against the
    sky: the original falls from 200 to 73 in one pixel with no halo; ours with RetailBloom keeps
    +20 for 4 pixels inside the edge, without it none). Ask; every comparison above is bloom off.
  - Detail's shadow map no longer lands on objects (the plaza deck): unshaded objects receive no
    light, and the original projects character shadows on ground cells only (READ, round 702).
  - **Two pipelines** (round 706 review, M2, recorded): objects show the formula's display values
    (Filmic undone), the terrain still goes through Filmic. Moving the world to Linear needs a
    terrain round first; the seam between the two is not measured.
- [ ] **The sky at the user's spot** (round 706 review): ours 220 (bloom off) against the
  original's 190 and bluer (179, 229, 252) against (170, 195, 200); the original's sky there is
  mostly cloud. A sky / fog item of its own: the sky dome's colours, the cloud layer's cover and
  RetailBloom's +20 on it, none measured against the original yet.
- **Metallic Sheen and the dragon** (round 705, INFERRED): the Jangan dragon's layer is the only
  one in `cj_jang_gate01.bmt` with a Power (1.48) and a near-white specular; the Middle preset's
  Metallic Sheen (case 0xc -> object renderer +0x194) is drawn as nothing here.
  Round 706 review: not the dragon's -- its `.bsr` has no env-map mod (above).
- **MTRL blend pairs drawn OURS** (BMT_FORMAT.md): 7 pairs drop a term. BLENDFACTOR's live
  value for objects is OPEN. TFACTOR is drawn white, although the mod's own colour is available.
- **The 355 bit-9 item layers with no ENVMAP mod** are cut at 128 by the READ rule. That is right
  for the 1-bit hats. `light_02_ha` (91% graded alpha) is cut the same way; a render of it
  against the original would confirm it.
- ~~**The body under armour.**~~ Done in round 687: a worn item whose `.bsr` attachable block has
  flag 1 hides the body pieces it lists, READ from `CCompChar::FUN_00c1f790` / `FUN_00c1f890`
  (BSR_FORMAT.md). The world's players, the paper doll and the portrait take it through
  `_build_assembled_character`; the create preview through `CharacterPreview.dress`; and
  `CharacterAppearance` (which no lobby screen uses yet). Still OPEN: what the block's first two
  words (+0x314, +0x318) mean, that part id 1 is the body (INFERRED), and another player's body is
  not redressed when their equipment changes, so its hides follow what they wore when they came
  into view.
- **The faint translucent shape beside the tester's character** (v0.1.457 screenshot) is not
  from the equipment chain: no worn piece's mesh reaches there, and the one translucent-authored
  item mesh found (`heavy_11_set_b_fly`) belongs to a `_fullset` model v0.1.457 could not load.
  Likely a buff's effect (the efp lane); unmeasured.

### Rendering against a real server
`qa_shot.sh --server` starts the server in memory on a spare port and signs the client in
(`OPENSRO_QA_SERVER`, `--say` to send a chat message). Every render before this was of a client
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

- [x] Unique signs (round 786) -- a monster of rarity 3 or 8 is drawn with
      `interface\minimap\mm_sign_unique.ddj` (`+0x3b0`, stored `0x6610d7`) instead of the monster
      sign, READ from vslot_013's class checks (`0x663790..0x6637ac`; `+0x7ac` is the spawn's
      class byte's low nibble, `0x9d38e1`). `HudMinimap` draws monster, unique, NPC and
      other-player signs, and (round 785) the tracked quest's NPC signs and arrows at 47.0.
      **The party's dots and arrows are drawn (round 717, `party_gui.md` section 9)**; the quest
      marks go between the party's arrows and the player's arrow in `MapMarks`.
- [ ] Animal signs -- `mm_sign_animal.ddj` (`+0x3c8`, `0x66137f`) is drawn for a CICCos (a pet,
      horse or transport; READ, `0x6637ae..0x6637c4`); this client builds no such body yet.
- [ ] **Move the NPC / monster / unique / other-player signs over the frame** (round 717 review, finding 1):
      vslot_013 draws every mark over `mm_window` (INFERRED, `party_gui.md` section 9), but these
      signs still sit in the map's clip under the frame, and they reach 44.5 + 4 = 48.5 px where the
      ring starts at 43.5-53.75 px. Draw them first in `MapMarks` (before the party's dots).
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

### The mouse cursor (round 697) — **the game's cursors from the player's sro_client.exe on every screen, at the UI scale; these are left**

`docs/protocol/CURSOR.md` has every id the client sets and the hover's class rules.

- [ ] **The player must have sro_client.exe** beside Data.pk2, one folder above it, or beside our
      exe (`sro_client_NODLL.exe` also accepted). Without it the system arrow stays and the log
      lists every path tried. Nothing is shipped.
- [x] **Round 700: "no game cursor on Windows" (v0.1.483)** was the missing exe (the user had not
      put sro_client.exe beside the pk2s). Now the login screen and the system messages say where
      it goes, and a renamed client exe in the same folders is found by its cursors. Wine 10.0 is
      on the box for the Windows build (docs/RENDER_BOX.md, "Wine").
- [x] **The hover's reach** (round 700): no class has a range in retail's hover; the bound is the
      3 x 3 message blocks of 320 the server sends, now applied to every hover class here
      (CURSOR.md, "How far the hover reaches"; the gate is a spawned object, READ in the review).
      Left: the click (round 701) still reaches NPCs and gates outside the window.
- [ ] **Stall (0xa3)** is wired (`GameCursor.KIND_IDS`, `player_kind`'s `stalling`) and
      unreachable: no other player's stall state (the 0x30b8 broadcast) reaches this client.
- [ ] **Hostile players** show 0xa0 only with Alt held: teams (+0x81d), fortress war, job modes,
      the murder state and the list `0x992a90` reads are not in this client. Each plugs into
      `GameCursor.player_kind` / `player_hostile` when it arrives; guards and fortress structures
      likewise (no CICGuard / CICATStruct here).
- [ ] **Not built:** the forced cursors (store repair 0x96, item applied to a slot 0xa6, socket
      0xae / 0xaf) wait for those windows; the Option window's camera-rotate **method 2** (the cursor hidden
      while the camera turns and put back at the press point, `0x77b140` behind +0x82d, set only
      when settings+0x1c is non-zero, `0x77c535` / `0x77c6c1`, chosen at `0x5fcf40`) -- retail's
      default, method 1, leaves the cursor free, as here; the job-monster test reads the code name,
      not the TypeID column (equivalent on the box's archive, MEASURED).
- [ ] **The window frame and resize borders** show the OS's shapes (retail's WM_SETCURSOR sets its
      own there too; Godot leaves the non-client area to the OS).
- [ ] **A window opened under a still mouse** keeps the world's cursor until the mouse moves
      (retail re-tests the window under the mouse every tick; Godot 4.2 has no hovered-control
      query).
- [ ] **Scale** (OURS, the user's decision 2026-10-03): nearest-neighbour by the UI scale. A
      native macOS build would double it again (NSImage points); the CrossOver run is not
      measured.

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
copies equal to `docs/`; (5) the GM run's `OPENSRO_QA_COMMANDS` verification used frame ticks
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
and both timings); the tester's `user://logs/opensro.log` from a reconnect — the second
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

### The renderer — **decided 2026-10-02: Forward+ the default, Compatibility a per-install choice (round 693)**

The user decided on 2026-10-02: "Let's make forward+ the default build." From round 581 to 692
players ran GL Compatibility (decided 2026-09-26). Before round 581 releases ran Forward+ by
accident: project.godot's `#` comments swallowed the setting. Round 693 (docs/WORLD_ISSUES.md) did
the following:

- **The box renders Forward+ on the RX 7600.** Vulkan presents through `client/tools/xwl_run.sh`
  (headless weston + Xwayland). Xvfb silently falls back to llvmpipe (docs/RENDER_BOX.md, "Vulkan
  (Forward+)"). `qa_shot.sh` and `perf_gate.sh` run each copy's own renderer, and `RENDERER=` /
  `--renderer` / `--ab-renderer` pick one.
- **The client's own shaders keep Compatibility's colour arithmetic** (`ShaderColour`). Under
  Forward+ the portrait, the select bodies, the mod stages, the particles, the cloud layer, the water
  reflection and every vertex-coloured terrain or water material would otherwise draw too bright.
- **SSAO and glow** go through `WorldPostEffects.apply` (off until a record says otherwise). Since
  round 694 the Option window's Video tab sets them: Bloom Effect is the glow, and retail's default,
  Middle -- the user's chosen default -- has it ON; SSAO (OURS) is off.
- **Compatibility stays available.** It is chosen per install in `override.cfg` beside the game
  (`RendererChoice`), written from `setting/config.yaml`'s `display.renderer` or by the release's
  `opensro-compatibility.bat` / `.sh`. Godot 4.2.2 does not fall back from Vulkan to OpenGL by
  itself (READ).

**Still open:**
- [ ] **Blending space.** Forward+ blends half-transparent surfaces in linear space; retail (D3D9) and
      Compatibility blend in display values. MEASURED (`client/tools/measure_blend_space.gd`): up to
      13 levels at a 50 % terrain-overlay feather, 21 for water's 200/255 over sand, 9-12 for
      additive glow. The cloud layer is done (round 693's review: it computes Compatibility's blend
      against the analytic sky). The others cannot be fixed per material without the colour
      underneath. The options are a second pass, or accepting it (the user's call).
- [ ] **A machine without Vulkan:** the native library restarts the game on OpenGL by itself
      (round 693's review, native/src/vk_fallback.rs), MEASURED on Linux. **Not run on Windows**
      (spawn + TerminateProcess): the first tester report from a Vulkan-less Windows PC is the check.
      Without the library there is no fall back, only the launcher. Whether the official 4.2.2
      Windows templates link ANGLE (for a GPU without GL 3.3) is unverified.
- [ ] **The low-end hardware test** (the user's). On the box's RX 7600 Forward+ draws the Jangan spawn in
      2.97 ms against Compatibility's 8.75, and the 500-monster view in 3.29 against 10.09. Entry and
      freezes are the same (round 693's perf gate). A low-end or integrated GPU is not measured.
- [x] ~~**Compatibility's shadowed sun was brighter.**~~ GLES3 adds a shadow-casting sun in a separate
      pass in display values. **Decided by the user 2026-10-02, "Raise it to match":** under
      Forward+ the sun is x4.0 (`WorldPostEffects.FORWARD_PLUS_SUN_SCALE`, OURS, calibrated by
      measurement in round 693). Lit areas are now within -2.4 to +1.6 luma of Compatibility.
- [x] **The Options window** shows the renderer and the SSAO and glow toggles -- round 694 (the
      renderer row writes `override.cfg` in an exported build only).
- [ ] **Retail's Bloom effect's look** (round 694 READ its default: ON in Middle, the default; it
      builds screen-size and 512 x 512 targets, SWorld::vslot_043 case 1). Its parameters are
      unread, so glow's are still the 2026-08-26 guess.
- [ ] **The first tester report from a Forward+ release** is the one to read against the box.
- [x] **Cut-out textures drawn as solid quads under Forward+** (the user, v0.1.480: tree leaves,
      hair) -- round 695: 4.2.2's RD renderers upload DXT1 as BC1_RGB with alpha forced to one
      (READ); DdjReader decodes a DXT1 with transparent texels to RGBA8 there (exact, MEASURED
      on nine real cards and in the Hotan desert).
- [ ] **Their memory.** Those textures cost 8x their DXT1 under Forward+ (11.2 MB more in the
      Hotan desert at radius 1, MEASURED). The 2,468 lightmaps among the 4,024 are never loaded (no
      client code reads `Prim\LightMap`); the other 1,503 are 122 MB as DXT1, 976 MB as RGBA8 if
      all were loaded -- monsters 327, items 209, NPCs 132, world 109, characters 35 MB. Items and
      avatars are the target: the four 2048x2048 `avatar_w_*arctic*` textures, no mips, are 16 MB
      each as RGBA8. Decoding only what an alpha-tested or blended material uses needs the
      material's alpha use to reach the loader.
- [x] **The 3D previews at a UI scale** (the user: the inventory character "much lower resolution
      than the game" at 2.0) -- round 695: the paper doll, the customize preview and the portrait
      render at their picture's size in physical pixels (`ViewportPixels`).

### The Option window's Video tab (round 694) -- **built: retail's rows, presets, Graphic 1 / 2, brightness curve and sight ladders READ; SSAO and Bloom (glow) through one environment function; these are left**

`docs/protocol/OPTION_VIDEO.md` has the record and the mapping table.

- [x] **The default** -- decided by the user 2026-10-02: retail's Middle (bloom on, reflection
      off) for every record with no saved section, pre-694 files included; a stored `[world]
      water_reflection` still wins; Default restores Middle and leaves the window mode alone.
      Under Forward+ this turns glow on by default, against round 693's "glow off" -- the user's
      decision is the later one.
- [x] **The saved record reaches the world at start-up** -- round 702. Until then the first
      `apply_video_options` compared the record with itself and applied nothing, so every start drew
      the scene's defaults (sun shadow map on in Circle, no glow, no MSAA, no mip bias) until a row
      was changed (OPTION_VIDEO.md, "Applied at start-up"). Middle's glow and MSAA now show from
      the first frame (Forward+).
- [ ] **Rows kept that draw nothing here:** Metallic Sheen (no env-map sheen pass), Light Effect
      (no torch / sun light effect), Dynamic Animation (no cloth or hair; TEXANI and DYVERTEX are
      their own items above), Display Friendly/Enemy (no battle outfits).
- [ ] **Readers not found:** Character Sight Range (case 9) and Water Detail (case 7) are stored
      and never read by the three probes tried; Texture Filtering's byte 0xc has no reader found
      either. Their effects here are OURS (draw distance, reflection rows) and INFERRED (MSAA from
      the tooltip). Next: the object renderer's draw path for +0x2e74, and a D3D sampler-state
      search for the filter.
- [ ] **Water Reflection applies at the next login**: a region's water is built for one mode.
      Live would mean rebuilding every loaded region's water and mirror terrain.
- [ ] **Inferred, not read:** a hand-set row switching the record to User (the slot's change
      handler); the scroll bar's line step; Effect Quality 1's two owner tests (FUN_00b94b70 on
      DAT_00ef1a84 / b44). The combo's field, arrow and text rects are READ (round 696), and its
      open list's fill 0xb4000000, placement, insets, line height, colours and hover bar (round
      697; ComboList from round 700, with the line corrected to 13 and the width to the field's);
      the six-piece frame's UVs (`0x49a140` / `0x49a7d0`: the
      top and bottom edges are drawn transposed, MEASURED against the user's picture) are not.
- [x] **The open list is drawn by this client** (round 700, `ComboList`): translucent over the
      rows below (the PopupMenu's opaque Window drew it grey), every item centred (MEASURED in the
      user's picture of the original; the user's instruction), 13-unit lines (font 9 pt + 4, READ
      and MEASURED; round 697 had 18), the field's width. Left: **no pressed colour** (0xff8080ff
      while the button is held); where the video rows get their centred alignment (the slot's
      combo, `0x6f7200`'s neighbours) was not read; retail's outside-click handling (CNIFPopup)
      was not read -- ours eats the click; the list's keys are OURS.
- [ ] **Resolution** is the window's size; in full screen Godot keeps the desktop's (no mode
      change in 4.2.2). A 3D render scale would be the Godot way to honour it there. In a window
      the OS window takes the size, a maximised one restored first (round 696). Retail's window
      cannot be resized or maximised by hand (style 0xC80000, no WS_THICKFRAME); ours can --
      whether to lock it like retail is the user's call.
- [ ] **Texture Detail has little to act on, even under Forward+** (round 694 review): the terrain
      textures are built without mipmaps (`mapm_terrain_builder.gd`), so the mipmap bias does not
      reach them. Generating mipmaps would also cut distant shimmer; measure its VRAM, load time and
      the gate first. Texture Filtering (MSAA 2x) works but shows little.
- [ ] **SSAO is a light effect** (round 694 review, MEASURED): the terrain is unshaded and the object
      mods write EMISSION, which Godot's SSAO does not darken; tuned (radius 16, intensity 4, light
      affect 1) it darkens about 1.7x the frame noise. A real effect needs those shaders to take
      light, or an AO term of their own.
- [ ] **Character Sight Range does not reach NPCs**: they are built into the region's
      RealTerrain_* group, not other_entities. The original's rule is unread (no reader found).
- [ ] **Texture Detail and Texture Filtering under Compatibility.** MEASURED: 4.2.2's GLES3
      draws the same picture with `msaa_3d` 2x and `texture_mipmap_bias` 2, so both rows are
      greyed there (they work under Forward+). A bias in this client's own shaders (a global
      uniform) would give Compatibility a Texture Detail.

### Culling and level of detail -- **queued (the user, 2026-10-02): a round after the Video options tab (round 694)**

Today:
- **Frustum culling** is Godot's own.
- **Region streaming** gives a 3x3 window, with the far plane at 7680 and fog beyond.
- **The server's AOI cells** limit which monsters and players exist on the client.
- **Retail's distance rules:** animated map objects stop beyond 2020 units (MapAnimation) and names hide beyond 300.
- **Missing:** no mesh has a `visibility_range`, no LODs are generated (the runtime ArrayMeshes have no `generate_lods`), and there is no occlusion culling.

- [ ] **Per-object draw distance from the Video tab's Background/Character Sight Range.** READ what retail culls at each setting.
- [ ] **LODs.** First check whether retail's .bms/.bsr carry their own LOD meshes. Otherwise generate them at load (ImporterMesh.generate_lods, or a cached simplification); OURS.
- [ ] **Occlusion culling:** ArrayOccluder3D / OccluderInstance3D built from building collision when a region loads. It works in both renderers; the perf gate decides whether its CPU cost pays.
- [ ] **Measure with the perf gate in a crowded town and on the low-end profile,** under both renderers.

### Bots and clientless play -- **noted by the user 2026-10-01; not scheduled**

- **A macro bot built into the game client.** With it, players don't need to go clientless to
  automate.
- **An external bot that supports clientless play properly.** The original game never supported it.
- **A "clientless" option for players.** This is the low-end choice the user wants to offer, instead
  of a switch to turn off the 3D title (round 678's `title_3d` switch was removed for that reason).

Nothing is designed yet. When it comes up, start from the protocol docs (docs/protocol/) and the
gateway's TLS and session handling.

### Asset packs: `.pk3` beside `.pk2` -- **started in round 789: the rules, the Go side and the converter are built; the client is lane K's**

The rules every reader follows are written once in docs/protocol/asset_packs.md ("Rules"); the
operator steps are in deploy/README.md, "Asset packs".

Shipping new or changed assets should not require injecting them into a `.pk2`. A `.pk3` is a
plain zip archive; `.zip` is accepted too. The client reads the same formats from it that it reads
from a `.pk2` today: models, textures, audio, rigs and particles. Modder-friendly formats (glTF,
PNG, OGG, WAV) can come later. Everything here is OURS: retail has only `.pk2`.

**The user's decisions:**
- **Source mode, one setting:** `pk2` only (today's behaviour), `pk3` only (the retail content
  converted once, then no `.pk2` needed), or `mixed`, the default, where packs layer over the
  archives.
- **Packs cascade by name, and a later name wins,** whether `.pk2` or `.pk3`: `z_assets` overrides
  `assets`.
- **The order a lookup checks the layers in, highest priority first.** The first layer that has
  the path serves it:
  1. the loose `custom/` folder (development, and round 678's branding files);
  2. `z_assets.pk3`;
  3. `z_assets.pk2`;
  4. `assets.pk3`;
  5. the retail base archives (`Data`, `Map`, `Media`, `Music` and `Particles`: five, the user
     2026-10-16; as `.pk2` or converted `.pk3`). These are always the bottom layer whatever their names, or `assets.pk3` would sort
     before `Data.pk2` and lose to it.
- **The name sort ignores case.** For two packs with the same name, the `.pk3` wins over the
  `.pk2`.
- **Paths inside a pack are the pk2's own paths,** matched case-insensitively with `/` and `\`
  treated alike. So `prim/mtrl/foo.ddj` in a pack replaces `Prim\Mtrl\foo.ddj`, and overriding an
  asset or adding a new one is the same operation.

**The work:**
- [ ] **One virtual file system** under every reader (client GDScript, the Rust native readers and
      the Go tools: `export-refdata`, `pk2list` and the server's own reads). No reader knows which
      layer a file came from. **Go: done (round 789, `server/internal/assetfs`)**: pk2list,
      export-refdata and export-leveldata read through it (`-archives`); the server itself reads no
      archive at runtime. The base archives turned out not to be one namespace (40 paths in two of
      them, 5 differing, MEASURED), so a lookup names its volume (asset_packs.md rule 3). Client
      GDScript and Rust: lane K.
- [ ] **A `.pk3` reader:** stored and deflated entries, and zip64, since a converted `Map.pk2` is
      several GB. Read stored entries without unpacking where we can. **Go: done (round 789;
      archive/zip, zip64 end record and >4 GiB offsets MEASURED).** Client: lane K.
- [x] **A pk2 → pk3 converter.** It keeps every entry's path, so its output drops in for the
      original archive. It stores already-compressed types (`.ddj`, `.ogg`) and deflates text,
      tables and meshes. It checks every entry comes out byte-identical. It runs on the operator's
      own archives, and its output is game data: never committed (docs/LEGAL.md). **Done in round
      789: `cmd/pk2topk3`** (and `cmd/pk3pack`, the pack builder). Measured, `.ddj` is not
      "already compressed": it deflates to 25-80%, so it is deflated (`-store .ddj` keeps it
      stored); `.ogg`, `.png`, `.rar` are stored. All five retail archives converted, every file
      byte-identical (asset_packs.md, "Measured").
- [ ] **Safety:** reject entry names that escape the archive (`..`, absolute paths), cap the
      unpacked size to stop zip bombs, and log every override at load. **Go: done (round 789;
      the limits and their measured basis in asset_packs.md rule 6).** Client: lane K.
- [ ] **A QA/debug command** that answers "which layer served this path?". **Go: `pk2list
      -archives <folder> -which <path>` (round 789).** The client's QA hook: lane K.
- [ ] **The server names the packs a client needs,** with their hashes (idTech's "pure server"),
      and the auto-updater fetches them. Then every player sees the same content, and a modified
      local pack cannot change what the server assumes (walls, navmesh).
- [ ] **Measure loading against `.pk2`** (perf gate). The `.pk2` directory's Blowfish decrypt was
      the top loading cost in round 667, and a zip's index has no such step.

### Native (Rust) readers (round 667) -- **the pk2 reader and the `.ddj` per-pixel decodes are native; these are left**

Round 667's spike moved the pk2 reader (the directory's Blowfish decrypt, the name index, the
path lookup and the file read) and DdjReader's two per-pixel decodes into a GDExtension. The build,
the parity check, the negative and the Windows cross-build are in native/README.md. The
measurement, warm and cold, is in WORLD_ISSUES.md, round 667. The rest of the parse time, ranked by
what the same `OPENSRO_PARSE_PROFILE=1` Jangan entry measured with the native readers ON:

- [x] **`BmsReader.parse`**, with `to_arrays`, `BanReader.parse` and `BskReader.parse`: native
      in round 669 (native/README.md, "The model readers"; the numbers in WORLD_ISSUES.md, round
      669). Left from it:
  - [ ] **`BsrReader.parse`** (34 ms on the main thread and 79 on the workers at the mobs entry,
        plus 34 ms on the main thread before it): not ported. It is the largest and least regular
        reader (1,281 lines: the section table, the forward scan, the mod sets and sound sets),
        and its result is nested Dictionaries and objects. Round 669's finer timers (Jangan entry,
        main thread) put 19.5 of its 36 ms in `parse_sound_section`, run 314 times for 90 parses:
        every parse that takes the section table reads the same bytes three times
        (`material_mods`, `env_map_materials`, and `env_map_flags` through `material_mods`
        again), a character a fourth (`_attach_sound_sets`). `parse_sections` is another 12 ms.
        Reading the section once per parse is a GDScript change, not a port.
  - [ ] **`BmsReader.parse_collision`** (6 ms main, 43 ms workers at the mobs entry) and
        **`BmtReader.parse`** (4 / 22 ms): under the round's ~20 ms main-thread bar; not ported.
  - [ ] **The `.ban` keyframes are still objects.** The native parse is flat, but `BanReader`
        builds one `Keyframe` per key (9.7 million across Data.pk2) because the per-frame pose
        code reads `track.keyframes` directly. Moving MonsterCrowd/Skeleton3DBuilder onto flat
        arrays would remove the rest of the `.ban` cost; that is an API change, not a port.
  - [ ] **12 real `.bms` files make the GDScript reader fail on a script error**, not a null:
        `_read_len_prefixed_string` answers `[]` where its callers test for `null`. The native
        reader returns `{error}` for them and GDScript then fails as it always has. Not fixed:
        this round changes no GDScript answer.
- [ ] **`MapmReader.parse` and `NvmReader.parse`**: 557 and 453 ms on the workers per 25-region
      entry. Off the main thread, so they cost entry time only while the drain waits for
      them.
- [x] **The text tables** (round 671; WORLD_ISSUES.md, "Six-hundred-and-seventy-first round"):
      the boot tables (`character/item/NPC tables loaded in`) and the NPC tables at the centre
      cell (`npcs [tables]`) were profiled function by function, and every reader over 20 ms an
      entry is native (`native/src/core/tables.rs`): NpcTableReader's ten parsers,
      `ItemTableReader.parse`, `UiTextTable.parse`, `SkillEffectReader.parse_all`. Parity on all
      680 `.txt` files of the four archives (`client/tools/table_parity.gd`). The boot tables went
      from 1,023 to 187 ms and the centre cell's `npcs [tables]` from 582 to 113. Left from it:
  - [ ] **Building the `Item` objects** is now most of what is left of the boot tables (83 ms
        in `text.items`, MEASURED): the row work is native, `Item.new()` and
        its ~30 fields are not. Faster needs a different API (a packed item store read lazily),
        which these rounds leave out.
  - [ ] **Each characterdata reader decodes its part again**: the boot runs four readers over
        the same seven parts, the entry three, the first monster three, the name-key task one.
        Natively that is 1.5-2.5 ms a part a reader (MEASURED); one decode shared per part is the caching
        round's, not a port.
  - [ ] **Not ported, under 20 ms an entry** (MEASURED, round 671's profile): `ShopReader.load`
        (18 ms with its six reads), `TeleportReader.load` (4 ms), `NpcServiceReader`'s
        shop and greeting tables (under 1 ms), and the readers not on the boot or entry path
        (skill, mastery, level, worldmap, sound tables).
- [ ] **`BmsReader.parse`**: the largest parser left, at 326 ms on the main thread and 879 ms on
      the workers per Jangan entry (plus `to_arrays`, 58 / 72). The parse builds one `Vertex` object per vertex, and
      `to_arrays` turns them back into packed arrays. A native parse that hands back the packed
      arrays and keeps them on `ParsedMesh` saves both. Callers that read `mesh.vertices`
      (character, monster and skinned assemblers, `bms_collision`) still need the objects, or
      need moving onto the arrays.
- [~] **The terrain readers** (round 670, WORLD_ISSUES.md).
  - Done: `MapmTerrainBuilder.lightmap_term`'s per-byte loop is native. It took 28 ms a region
    in GDScript and takes 1.2 ms. That saves about 0.7 s of worker time and 27 ms of the
    centre cell's main thread per Jangan entry.
  - Done: the `.m` and `.nvm` decodes are ported and proven on every real file
    (`MapmReader.parse_native`, `NvmReader.parse_native`). They are not on the load path,
    because the reader's objects cost as much to build from the columns as the GDScript
    parse costs whole. The decode is 0.1 ms; the build is 13 ms a `.m` and 12 ms a `.nvm`.
  - Not ported, too small: `.o2` (13 ms an entry), the object index (`ObjidxReader`, 7 ms once), `tile2d.ifo`
    (2 ms once) and `.t` (33 ms an entry, mostly the engine's DXT1 decompress).
- [ ] **101 `.nvm` files that no reader parses** (round 670's review, MEASURED). All of them are
      in Data.pk2's `navmesh\`, and both readers refuse them with "truncated reading the real
      HeightMap". They are a short-heightmap variant:
      - the header, cells, edges and tiles are valid;
      - then come only 952 bytes: 193 height floats instead of 9,409, 36 zero plane types, and
        36 plane heights of -20.0.

      None of those regions has a `.m` in Map.pk2, so no region the client loads loses its
      navigation today. The server lane may care: what 193 heights cover, and whether the
      server's own reader accepts the variant, is not known.
- [ ] **Keep the terrain columns on the region (an API change).** This is what makes the
      `.m`/`.nvm` port pay. `ParsedRegion` would carry the packed heights and extras (and for
      `.nvm`, the tiles), and its readers would move onto them:
      `TerrainCollision.heights_from_region`, `MapmTerrainBuilder._full_region_cells`,
      `MapmWater`, `NvmCollision`, `NavGraph` and `anim_sounds.material_at`. The
      per-vertex and per-tile objects then go away. Worker time per Jangan entry at stake:
      524 ms `.m` + 460 ms `.nvm` + 88 ms heights. `parse_native` and
      `native_parity_terrain.gd` are already the proven decode.
- [ ] **The terrain mesh build** (`prep.terrain.mesh`, `MapmTerrainBuilder.build_full_region_surfaces_textured`).
      It is the largest item in the terrain prepare: 2.9 s of worker time and 90 ms of the
      centre cell's main thread per Jangan entry (round 670, MEASURED). It is geometry and
      lighting over the region's grid (normals, per-vertex light, the texture passes), not a
      parse. Porting it means holding float32 vector and colour arithmetic to GDScript's bits,
      or agreeing on a tolerance. Its own round.
- [ ] **The NPC text tables** (`npcs [tables]`, about 570 ms on the main thread at the centre
      cell, unchanged by round 667): `NpcTableReader.parse_models`/`parse_codes`/`parse_names`
      and `UiTextTable.parse` over characterdata and textdata_object. These are UTF-16 split and
      scan, a natural fit for one native call per file that returns packed columns.
- [ ] **The boot tables** (`character/item/NPC tables loaded in` about 1.1 s, before the loading
      screen): not profiled function by function yet. ParseProfile's `before the entry` window
      covers only the readers it wraps.
- [x] **Ship it** (round 668). release.yml builds both libraries, both zips carry them, and the
      auto-updater installs them over a DLL the game has loaded (native/README.md, "CI";
      docs/NATIVE_ON_WINDOWS.md). Left from it:
  - [ ] **The user's Windows test.** Nothing of the DLL or of the updater's rename-aside install
        has run on Windows. The user's exclusion-and-rename test is the first evidence; the
        lines to expect are in docs/NATIVE_ON_WINDOWS.md.
  - [ ] **A `.pck` held open blocks an update.** If Windows has the old `.pck` open without
        FILE_SHARE_DELETE at the moment of the update (Godot's own `_wfsopen(_SH_DENYNO)`
        handles, file_access_windows.cpp:146), it cannot be moved aside. The update is then
        rolled back and reported as failed. Godot opens the `.pck` per resource read and closes
        it again, and the update runs at the Boot screen, so this is INFERRED to be rare. Not
        seen.
  - [ ] **The relaunch on Windows** is a batch file polling `tasklist` (AutoUpdater
        `windows_relaunch_script`). If it fails, the update is still installed and the player
        starts the game by hand.
  - [ ] **Signing.** The DLL and the exe are unsigned. If antivirus quarantines the DLL for
        players, the options are an Authenticode certificate or a static link into custom
        export templates (native/README.md, "Windows").
  - [x] **Licence texts** (round 668's review, L9): THIRD_PARTY_NOTICES.txt now carries every
        crate's licence text, the Rust standard library's, and Godot Engine's own licence with
        its third-party notices.
  - [ ] **Non-ASCII install paths never auto-updated before this release** (PRE-EXISTING, found
        by round 668's review). v0.1.464's batch file writes the install path into a file that
        cmd.exe reads in the OEM code page. Such installs will not get the first native release
        automatically; docs/NATIVE_ON_WINDOWS.md tells them to copy it once by hand. From this
        release on, the batch file holds no path.
  - [ ] **A second client started from the same folder** while one updates (review L5). The
        second still holds the old exe and DLL. They are moved aside like the first one's, and
        the next start deletes them once both have exited. The two clients then run different
        versions until the second is restarted. Not handled, and not seen.
  - [ ] **The Linux relaunch waits on `kill -0`** (review L6). An exited client stays a zombie
        until whatever started it (a shell, a desktop launcher) reaps it, and `kill -0` succeeds
        on a zombie. With a parent that reaps at once this costs nothing. Under one that never
        reaps, the helper waits out its 30 s cap and then starts the game anyway. On the box the relaunched client came up in each of the
        six real update runs, which allow it 30 s. How long it took was not timed.
  - [ ] **Download trust for the CI tools** (review L10). rustup is fetched from sh.rustup.rs
        over TLS without a pinned sum. zig comes from ziglang.org, a single host that asks
        heavy users to use mirrors. Both are fine for a few builds a day.
- [ ] **Low-end hardware.** The user will emulate a slow CPU and slow storage. `perf_gate.sh
      --ab-env OPENSRO_NATIVE=0 --cold` is the reproducible run (client/tools/README.md,
      "Native readers A/B").

### The 3D title screen (round 678) — **built: retail's intro flown over the world's own regions, the archive's frame and login window at READ positions, the operator's theme; these are left**

`docs/protocol/intro_script.md` has the format, the path, the camera and the screen, all READ;
deploy/README.md "Branding your front-end" the operator's side; FRONTEND_CHECKLIST.md section 6 the
front-end's next steps.

- **The [SCRIPT] section** (GScript): rm.txt's `S_SetWorldTime 22` and seven `roc_smoke.efp`
  effects, ruby_baghdad's 333 lines (objects created by index with `#rand`, `S_ObjectEquipSet`,
  `S_ObjectMoveTo`, `S_CameraShake`). Kept as text by IntroScript; the interpreter is
  `FUN_004779a0` / `FUN_00477ca0` and the title-time flag `FUN_0056b380` (whether [SCRIPT] runs at the
  title at all is still OPEN). Their cameras fly over empty scenes until then.
- **Constantinople's crowd** (`AREA=EUROP_CONSTANTINOPLE`, `FUN_00520580` -> `FUN_0051dea0`).
- **The sun at the title hour**: the environment colours follow the random phase; the sun's
  direction (`SWorld::vslot_004`, (phase - c) * 2 pi) does not. `SWorld::vslot_043(0x17, 0)` at the
  title is unread.
- **The scenes after the title** -- character select (105/81 harbour), race select (box.bsr, idols,
  lizard), create China (98/168) / Europe (105/79): READ and recorded, not built
  (FRONTEND_CHECKLIST.md section 6). The theme's `charselect` / `create` slots wait for them.
- **Measured costs** (round 678): the screen is interactable ~0.2 s and fully faded in ~0.7 s after
  launch with a click at its first frame (the 0.5 s is retail's own login fade), against ~0.12 s for
  the old 2D screen; no frame over 100 ms in its first 12 s once the world's scene compiles on a
  worker (it froze 1.3 s when loaded on demand).
- **Memory on Linux** (round 678's review): ~205-230 MB more resident memory once in the world than
  without the 3D title -- glibc keeping what the title's worker threads freed (equal to base under
  `MALLOC_ARENA_MAX=2`); ~150-190 MB of it is the World3D compile on the loader thread, kept to avoid
  a 1.2 s freeze. Open: a Linux launcher with `MALLOC_ARENA_MAX=2` (also -215 MB on the base world). The 3D
  title is not a player option (the user, 2026-10-01: players get a "clientless" mode later instead).
  Windows not measured.
- **Pop-in during the fly: fixed (round 680)** -- the whole scene (TitleCellPlan: the 3x3 window
  around the camera's target along the whole path) is built under the still before the camera
  moves, and nothing streams or unloads while it flies: 0 in-view pops on the four plain intros
  (16-57 before). A plan past `TitleCellPlan.PLAN_MAX_CELLS` (36, OURS; the archive's largest is 28)
  falls back to round 678's streaming. Left: one cell's commit is 100-340 ms for a dense
  Constantinople cell, felt as a hitch while typing during the preload; splitting a cell's object
  placement over frames would remove it.
- **The loaded world's edge in the distance (OPEN, predates round 680; round 702 changed the
  fog).** The title's camera far plane is 7680 units (`REGION_SPAN * (radius + 1) * 2`). Until round
  702 the fog was exponential at density 0.00005 (~88-90 % of a colour still showed at 2000-2700
  units); since round 702 it is retail's linear fog, complete at the zone's end plane (Jangan
  2250), so the 3x3 window's edge past that is fog-coloured -- re-measure the census with the new
  fog before choosing an option below. MEASURED: round 680's review
  counted 23-84 unplanned terrain cells entering the frustum per intro; `title_plan_census.gd`
  counts the cells with terrain that the view frustum meets along the path within the far plane
  against those planned -- roc 49 vs 24, constantinople 114 vs 28, china_wharf 28 vs 10,
  jupiter_login 43 vs 12. Planning the frustum within 2500 units fills it but costs too much (round
  680: constantinople 67 cells, fly at 10.7 s, 2042 MB, 301 MB video). Options, not chosen: a
  cheaper far ring (terrain only, no objects), a nearer far plane or retail's linear fog end at the
  title.

### Character appearance and the creatable catalogue (round 683) — **built: `CharacterAppearance` dresses any of the 52 bodies at the READ Height and Volume, `CharCatalog` derives the create screens' choices from the archive; these are left**

- **The world does not use it yet** (lane W, after S1): bodies by RefObjID + scale through
  `CharacterAppearance`, replacing `GENDER_BODY_CODE`. That round runs `perf_gate.sh`. It can also
  turn on the missing-palette-bone rule (`attach_item_from_archive(..., true)`), which the world
  leaves off today. With it off, a Europe man's heavy legs (`Bone03`) are not drawn in the world. The
  world also draws no dual axe: the archive has only `axe_01_l/_r.bsr`, which the world never asks
  for.
- **The weight half of the missing-bone rule** (`ResObject::FUN_00be2f80` leaves the missing bone's
  weight out of the sum): not modelled. The position at rest is right.
- **What vslot 0x34 reads** (INFERRED "a woman": it picks the women's Volume table and the harp's
  `_f`). Trace `CCompChar` 0xc1f0d0 -> 0xc2bb40's resource +0x28.
- **Avatars:** attached on top (READ `FUN_00a60ef0`). Which visual wins a slot bit is
  `charactervisualchange.txt`'s Slot / OverlapSlot / Priority (READ, round 683 review); not modelled.
- **The body through the armour** (round 683 review; round 687 applied retail's rule): the worst
  case went from 21.30 % to 5.58 % of a worn armour's pixels (`appearance_probe.gd --showthrough=1`,
  MEASURED). What is left is body pieces no worn item lists (the China woman's light set hides only
  three of her meshes), which the client draws too (READ, `FUN_00c1f790`). A retail screenshot of the China woman
  in the light set would show whether anything else covers them.
- **The world reads only 7 of itemdata.txt's 63 parts** (`ItemTableReader.TABLE_PATHS`): 3,566 of
  15,338 item ids, avatars among them, are unknown to World3D and not drawn. The builder and
  catalogue read through the index (`CharCatalog.index_parts`). Switching the world costs a parse of
  all 63 parts (~285 ms with the native readers, MEASURED) and needs `perf_gate.sh`.
- **The plus glow** (INFERRED that plus drives it): the plus is kept on `Body.worn`, not drawn.
- **`CharacterPreview`** (`ui/character_preview.gd`) no longer has a user in round 685's tree: the
  customize screen draws through `CharCreatePreview`. Delete it once lane A's select (round 684)
  is merged and confirmed not to use it.

### The select screen (rounds 684, 688) — **built: retail's CPSCharacterSelect and race select; round 688 fixed the lizard's loop, the "Name Check" overflow and the hour's re-pick; these are left**

`docs/protocol/charselect.md` sections 2 and 3; WORLD_ISSUES rounds 684 and 688.
- **The front-end's hour is the user's call** (charselect.md section 8, decision 13): retail draws
  select and customize at the hour the title picked (READ, round 688), so one title visit in four
  is 23:00, measured 24 % darker than 14:00. Kept as retail.
- ~~**The lizard's setter's 200**~~ READ (round 688's review): the one-shot's 200 ms fade-out
  (`CRTAniOneShot::vslot_002` case 4 -> 5, `AniMixer::FUN_00c554e0(clip, 0, 200)`), fade-in 0; no
  visible effect with one clip, not modelled.
- ~~**In-world characters use Godot's tuned lighting, not retail's character formula**~~ -- done
  in round 706: the world's players, NPCs and monsters draw the original's formula too
  (`ObjectLight`; their object colour by the tile under them, `CharacterLight`).
- **Model fades do not draw on GL Compatibility** (READ, Godot 4.2.2 source, not measured on screen):
  `GeometryInstance3D.transparency` is stored as `force_alpha` in
  `RenderGeometryInstanceBase::set_transparency` and never read by the GLES3 renderer
  (`rasterizer_scene_gles3.cpp` uses its own `force_alpha` only for the overdraw debug mode). So the
  select models' READ 1.0 s fade-in and the 0xcc opacity of a character pending deletion (round 684,
  `CharSelectStage._apply_alpha`) are likely invisible. Measure, then drive the opacity through the
  characters' material (an alpha uniform) instead.
- **The sun's direction from the hour** (`SWorld::vslot_004`) is not applied anywhere (round 678's
  OPEN); a night select keeps the day's light direction.
- **QA hooks** (round 688, `CharSelectQa`): `OPENSRO_QA_SELECT_RACE`, `OPENSRO_QA_LIZARD_PROBE`,
  `OPENSRO_QA_SELECT_LUMA` (with each body against its preview), `OPENSRO_QA_SELECT_FRAMES`,
  `OPENSRO_QA_SELECT_GODOT_LIGHT` (the old materials, for a before/after); `client/tools/frontend_at_scale.tscn` measures every front-end
  button's words against its art at a UI scale.

### The customize screens (round 685) — **built: China and Europe from their own layouts, every control, the READ ranges and rules, the preview with the READ spin, zoom and idle, the turning 98/168 and 105/79 backdrops; these are left**

`docs/protocol/charselect.md` section 4 has everything READ; WORLD_ISSUES round 685 the evidence.
- ~~**The name's character test** is OURS.~~ Done round 788 (lane N): `NameFilter` applies
  retail's 0x8c3cb0 on the player's own abusefilter.txt for type.txt's Language group, and the
  server `server/internal/namefilter` (charselect.md, "The name rule: the AbuseFilter test").
- **Branding:** the create screens draw the archive's red/blue bands only. Whether an operator's
  theme band art should replace them as it does the title's is the user's call (the reference
  shots are a private server's reskin).
- **INFERRED, not read:** the slider's thumb travel (x 20..104 from the 84-pixel track) and its
  drag; the confirm box's Cancel and Create fading it over 0.5 s; the clock behind the backdrop's
  turn being milliseconds; the preview lit by the backdrop's zone light; ANI_STAND1 looked up in the
  weapon's group; the sex buttons' ClientRect as a text inset.
- **OURS:** the backdrop's window radius 1 (9 cells) and the black fade held until its first view
  (at most 8 s); China when the screen opens with no race chosen; Enter in the name field confirms.
- **The message line's colour** (FUN_00860ca0's value) is OPEN: the layout's white is used.
- **Europe women 12/13** (DEVIL, SUCCUBUS): the tooltip is taken by code name (OURS) until the
  retail order is known.
- **Default wear** (round 685's review): drawn on the create preview, the select bodies
  (`CharacterAppearance`) and the world's characters (`World3D._build_assembled_character`).
  Left: an avatar's own visual record (ConditionID 2) is not consulted for the mask, so default
  wear can draw under an avatar dress (OPEN, with the avatar arbitration); `CGame+0x129` is
  assumed clear (OURS, as the Protector minimum).
- **China's backdrop** does not reproduce fe_ref4's lion-and-gate view at any yaw of the READ
  pose; Europe's matches fe_ref3 at yaw ~2.6 (the reviewer's sheets, scratchpad `rv685/shots/`).
  Whether the reference server moved the China camera, or the READ target is read wrong, is OPEN.

### The server list and setting/ (round 679) — **built: setting/config.yaml with named servers, the LIST window with each server's status, the logo clear of the box, centred fields and a `*` password; these are left**

`docs/protocol/server_list.md` has everything READ (the status bands and colours, the window, the
refresh, DIVISIONINFO / GATEPORT, the agent hand-off, the edit alignment and mask); deploy/README.md
"Configuring the client" the operator's side.

- **The client's own saved settings in `setting/`** (the user: "client save data like display,
  sound, hotbar"): today they are in `user://settings.cfg` (ClientSettings), unmoved this round.
  Next: decide the file(s) (one YAML per area?), migrate on first launch, keep the old file readable.
- **Settings a server hands the client** (the user's idea, 2026-10-01; beside PROTOCOL_DECISION.md's
  addendum): config an operator wants kept out of the client's file, supplied during the server list
  or after login. Not designed; it belongs with the negotiated extension messages of the addendum's
  item 2, and a server value would sit above `setting/config.yaml` in the order the theme uses.
- **Legacy servers (round 681, `type: legacy`)** show a retail gateway's own shard list and status
  (`docs/protocol/opcodes/gateway.md`). Left: **the user's test against a real private server**
  (the fake gateway and the transcripts are all that has been tried); **the 37 checksum tables**
  that cannot be generated (the client reconnects; reading them from the player's own
  sro_client.exe at run time is possible and is the user's call, handshake.md; a proxy with a FIXED
  seed on one of them fails every time, not 0.3 %); **the client's
  farm-byte mode word** (`CClientNet+4`, its writer OPEN; the gateway's content-id rule is used);
  whether a gateway takes 0x6101 before 0x6100; the 0xA100 refusal codes past [2, 4]; logging in
  over the original protocol (not started: Connect refuses a legacy server); our own server speaking
  it (the superset plan).
- **`agent` is parsed, not used:** this server is one process. When the gateway/agent split exists
  (retail's 0xA102 redirect; its handler's address is still OPEN), a configured agent stands in for
  the address the gateway names.
- **`global.region` is reserved:** vSRO reads no region (DIVISIONINFO's locale byte is skipped by its
  loader; no "Located In" code). Candidates: the content id byte (net-state+0, who sets it OPEN) or
  option.txt's `Language` key (what it does OPEN).
- **The list's polish:** the 0.5 s fades (FUN_00864870), the farm column, the name's gold colour for
  the entry's +0x28 flag (meaning OPEN), the slider's drag; the 0xA101 parser in the exe (not found:
  no 0xa101 immediate).
- **-max-players counts characters in the world**, not sessions at character select; the
  `-gm-accounts` names pass the inspection and full gates (ours; retail exempts by privileged IP and
  the account's security bytes, INFERRED). Since round 788 the gates are `LoginService`'s, for 0x0001 and 0x6102 alike.

### The character lobby (round 682) — **built: retail's 0x7007/0x7001 on our framing, create with the READ checks and the player's own items, 4 an account, the 7-day delete and restore, per-race start spawns; these are left**

- [ ] **Deploy on opensro-01**: export `chargen.csv` and pass `-chargen-csv` (deploy/README.md,
      "Character lobby"). Until then every create there is refused with 0x403. The schema migrates
      itself; players need the new client.
- [x] ~~**Blocked on the shard DB**~~ -- **done in round 692** (the user approved the export,
      2026-10-02): `_RefCharGen`'s 104 ids are exactly the rule's (server and client, MEASURED); a new
      character gets its race's `_RefCharDefault_*` masteries (level 0) and skills, and its level-1
      quests recorded by code; the ammunition is the procedure's 250; the 7-day delay and the
      restore rule are READ and agree; Str/Int 20 and HP/MP 200 are READ (were OWN DESIGN).
      charselect.md section 5, "`_AddNewChar`, read".
- [ ] **Deploy round 692 on opensro-01**: stage the three `_RefCharDefault_*` CSVs and `_RefCharGen.csv`
      and set `OPENSRO_CHARDEFAULTS_DIR` (deploy/README.md, "Character defaults"). Until then new
      characters get no defaults; the server says so at boot.
- [ ] **Default quests are recorded, not given** (round 692; round 785 update): `character_default_quests`
      holds each new character's level-1 default quests by code at Status 1 (China 3, Europe 2). The
      real catalogue exists since round 785 (`docs/protocol/quests.md`), but none of the default codes
      (`QTUTORIAL_CH`, `QEVENT_GUIDE`, ...) has a setup in the server's scripts or a class OpenSRO can
      read, so there is nothing to open (MEASURED, the exporter's `-quest-report`). The higher-level
      default rows (RequiredLevel 5..60) are not given at create and when they are is OPEN.
- [ ] **Quests, round 785 OPEN items** (`docs/protocol/quests.md` section 7): party kill credit
      (`LuaSetDivideType`, 125 quests), time-limited quests (`LuaSetRealTime`, 58), job quests
      (`LuaSetJobTypeStartCondition`, 33), `LuaSetAchievedPoint` (30), the change-item mission class
      (blocks QNO_EU_EASTEU_1/2/3), 5 compiled classes missing from the decompilation, the reward
      choice block (refqusetreward cols 5-9), and the second level value (`LuaSetStartCodition`'s last
      argument). Coverage today: 618 of 696 playable, 564 reachable.
- [ ] **Deploy round 785 on opensro-01**: export the quest catalogue on the render box and set
      `OPENSRO_QUESTS_DIR` (deploy/README.md, "Quests").
- [ ] **Characters created before round 692** have no default masteries or skills (the procedure runs
      only at create). A one-off backfill is possible (OURS); not done.
- [ ] **Decisions 10-12 in charselect.md section 8**: the procedure's 2,000,000 gold and 5,000,000 SP
      (not taken), the shard's `_A_RARE` starting-kit edit (not taken), Europe's missing tutorial
      quest row.
- [ ] **A level-0 mastery row now exists for every race mastery** (round 692): any rule that counts a
      character's masteries ("at most N chosen") must count levels above 0, not rows.
- [ ] **Two sources for the race masteries** (round 692's review): 692 seeds the level-0 rows from the
      export (the authority: what `_AddNewChar` writes); euroskill691's `skill/race.go` hard-codes
      the same 13 ids. Keep them equal; move 691 to reading the seeded rows once older characters
      are backfilled (charselect.md section 9).
- [x] ~~**The name rule's OPEN half**~~ (round 788, lane N): READ and applied on both sides --
      the server's 0x40f200 (space, quotes, the 54 SQL words, the AbuseFilter group's bitmap,
      substring and whole-word lists; `-abuse-filter` / `-abuse-filter-locale`, deploy/README.md)
      for character and guild names, the client's 0x8c3cb0 / 0x8c3de0 from Media.pk2 (charselect.md,
      "The name rule: the AbuseFilter test"). Still OPEN: what the deployed client's vPlus DLL sets
      CGame+0x858 to at runtime (the exe jumps over the Vietnam compare); CGame+0x858's constructor
      value (an unknown Language; OpenSRO uses English); the GameServer's locale map (it loads the
      file for pet names, aliases and a guild function); which of the two retail AbuseFilter
      copies is unmodified. OURS: Windows-1252 for the code page on both sides; the no-file
      charset `[0-9A-Za-z_]` (retail refuses nothing without the file).
- [ ] **Ammunition**: a bow's arrows and a crossbow's bolts go into the bag (OURS), 250 of them
      (READ `_AddNewChar`, round 692; was one full stack): the equipment slot has no quantity and
      ammunition is not modelled (session/skill.go).
- [ ] **The purge removes the characters row only**: the bag, worn items, skills, quests and guild
      rows of a purged character stay, as `Store.Delete` always left them.
- [ ] **Europe in the world**: bodies are drawn as the China default until lane W (RefObjID + scale on
      the entity wire); death returns and the warp home go to Jangan, not `STORE_EU_GATE`;
      `leveldata.KillExp`'s Europe arm is never selected (the killer's race is not passed); Europe's
      NPCs and shops are unexercised.
- [ ] **Item plus and avatars** in the list record are 0 / none: OpenSRO keeps no plus and no avatars.
- [ ] **Restore's asynchronous error**: u8 in the server, u16 in the client (READ both); u16 is sent.
- [ ] **recovered_names**: rename `SendNameCheckRequest_858c00` (it is the delete/restore confirm
      sender) once the rename is applied in Ghidra too.
- [ ] **`OpEnterWorld` 0x0020** is still accepted beside Start (it refuses a pending character too);
      retire it when the world handoff is retail.

### The account PIN, "Character Lock" (round 788, lane P) — **built: OURS throughout (retail has none), server store + rules + lobby gate, the client's window and select-screen hook; these are left** (`docs/protocol/pin.md`)

- [ ] **The window's look** (the user, 2026-10-16, after v0.1.549: "the PIN interface doesn't look
      exactly the original but we can fix that later"). "The original" here is the reference
      screenshot (https://i.imgur.com/zugaKQC.png, a private server's reskin; retail has no PIN):
      match its layout, art and spacing.
- [x] **The legacy select path** (round 788 lane C's adapter for retail-protocol servers) must skip
      `CharSelectLock.query()`: 0x0120 means nothing to a retail server. Done in round 788's merge
      (`CharacterSelect.gd`: `not NetClient.is_retail()`).
- [ ] **No GM command clears a player's PIN or lock**; the operator deletes the rows by hand
      (deploy/README.md, "Account PIN (Character Lock)").
- [ ] **The lock's numbers are constants** (5 tries, 30 minutes, 16 remembered PCs): flags if an
      operator asks.
- [ ] **A retail client on an account with a PIN** can list but not start, delete or restore (0x40e,
      "Failed to connect to server."); there is no retail way to ask it for a PIN.
- [ ] **The "Pin Code" button** stands one column left of Start; on a screen narrower than ~700 px
      the select screen's message line (x = 26) can run under it, as under Start.

### Europe: what a Europe character still lacks (round 692 notes)

The user (2026-10-02): "euros probably have their own quests too, make sure you consider that."

- [ ] **Europe's default quests.** The shard's `_RefCharDefault_Quest` has no Race 1 row: a Europe
      character is given only the two Race 3 quests, China also its Race 0 tutorial. The archive has `QTUTORIAL_EU` (questdata id 210, category 1) and
      `QTUTORIAL_EU_2` (225), `QTUTORIAL2_EU_1..7`, `QNO_EU_TUTORIAL_1..7` and the `QNO_EU_CONS_*`
      chain (MEASURED, questdata / questcontentsdata). Whether retail gave `QTUTORIAL_EU` at create
      is OPEN (charselect.md decision 12).
- [x] **Europe's quest content** (round 785): the Constantinople chain QNO_EU_CONS_1..12 is real and
      reachable end to end (CONS_1 and the compiled CONS_2 played by `partybot -mode quest` on the
      box); East Europe to EASTEU_18 except EASTEU_1/2/3/5 and the `_1` variants. `QTUTORIAL_EU`,
      `QTUTORIAL_EU_2` and `QNO_EU_TUTORIAL_1..7` have no setup anywhere (OPEN: the client tutorial).
- [ ] **Europe's default masteries and skills** are given at create (round 692: masteries 513-518 at
      level 0, and 10 skills: the bare-hand attack and a basic attack per weapon family). Their use -- Europe's mastery
      rules and skill window -- is lane euroskill691's.

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
      `OPENSRO_QA_GROUND_RAYS`, is the check.
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

- [x] **The return point** (round 686, `teleport_network.md` "The return point (round 686)"): a town
      gate's "Designate as return/recall point" is retail's 0x059 handler (`OpRecallDesignate`
      0x0111 -> 0x0112 in 0xb059's shape), kept in `characters.appointed_teleport`; option 1, the
      flag-off respawn and a dead logout go there, else to the race's gate. Left open:
  - [ ] **"Teleport to return point"** (interaction id 9, item 0x10): READ as the teleport request's
        kind 1 -> `GObjPC::Revive(0)` (`CMainProcess::FUN_004f2b50`, 0x1c10 with a cart). No town
        gate offers it; the client still answers "not available yet".
  - [ ] **Return scrolls**: `UseByKind` (`0x49c2b0`) cases 1-3 cast the item's linked skill (ref
        object `+0x2a0`, `FUN_0059b8d0`); the skill effect that moves the player is unread, and
        OpenSRO refuses every return scroll. When built, it goes to `returnPointFor`.
  - [ ] **An unknown designated gate** falls back to the race's gate (OURS); retail falls back to
        `LatestRegion` / `Pos`.
  - [ ] **A Europe character's return, live.** Since round 682 is on dev, `characterCountry`
        reads the body's race (`RaceOf`) and the tests return a Europe character to
        Constantinople's gate with no stub; no live run with a created Europe character yet.
  - [ ] **The agreement box's art and button labels** are the talk prompts' panel and "OK" /
        "Cancel" (OURS): kind 5's button controls were not read.
- [x] **The gate's click, and the return point's height** (round 690, `teleport_network.md` "The
      gate's pick box and the arrival's height (round 690)"). A town gate is clicked through
      retail's box (BCRadius / BCHeight at the table point, READ). Alexandria North is clickable,
      and Jangan's click is the stone, not the whole pavilion. A return to the return point and a
      dead logout's restored entry stand on the walkable graph, as a gate teleport does (Hotan was
      12.19 under its plaza). Left open:
  - [ ] **The pick's 3 x 3 ray grid.** `FUN_0078ee20` casts a 3 x 3 grid around the cursor, the
        step INFERRED to be 1.6 % of the screen; a nearer hit replaces the best, and a centre hit
        replaces an outer best whatever its distance. OpenSRO casts the centre ray only.
  - [ ] **A ray from inside a gate's box** does not take it (Godot's `hit_from_inside` is off). It
        is unknown whether retail's triangle test `FUN_00a5b000` hits back faces. A camera inside
        Alexandria's 140-unit box cannot click that gate until the player steps back.
  - [ ] **The spawn position of a structure** is INFERRED to be its teleportbuilding row. The
        server's structure spawn was not read.
  - [ ] **Retail's arrival height**: the server copies the table's y unchanged (READ). Whether the
        client or the re-entry snaps it to the navmesh is unread. OpenSRO lands on the graph.
- [ ] **Which objects offer id 8 is stood in for.** Retail registers id 8 ("Select teleport area") on
      a link source's object when a byte of the point's record (`+0x34`, the last
      `RefTeleport_ExtractData` reads, `0x6a7f45`) is 1. The client's teleportdata.txt has no column
      for it. OpenSRO offers the line on every point with an outgoing link, server and client. The
      server's database column is the source, and this project has no copy of it.
- [ ] **Walk-in portals are not served.** 69 retail links leave a point with no associated object:
      64 in and out of the Qin-Shi tomb (`GATE_JINSI_*`), two for the Donwhang cave
      (`GATE_DUNGEON_DH_*`), the two desert temples' exits, and the Roc gate's return. Retail
      moves a player through them from a region event, not a talk: `CGObjPC::vslot_309` (`0x4ef480`) compares its event's string with `"TELEPORT"` and takes the
      link from `GObjPC::FUN_004f88d0`. The server refuses such a point with code 2, and the client
      offers nothing there. MEASURED over the export: 68 of the 69 start or end in a dungeon (a negative
      region), which OpenSRO cannot place, and the 69th is the Roc gate's return from world 40.
- [ ] **Instanced destinations are refused** (OURS; code 0, nothing charged): every destination
      whose teleportdata column 12 (`WorldID`) is not 1. That covers the fortress gates (worlds 2,
      4, 7), the Roc gate (40), the Pharaoh tombs (57-59), the desert temples (60) and the survival,
      arena and garden maps. Retail enters the world (`GameWorldMgr_FindByID`, `0x5137ac`);
      OpenSRO has one world.
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
      test in `HandleTeleportUse`) is still not modelled: an OpenSRO teleport completes inside one
      request. With the range in place it no longer lets a second request through from the old
      gate; its lifetime is unread.
- [x] **Donwhang's and Samarkand's gates could not be clicked** (round 650). Round 643's one-object-
      per-key placement put their portals in the neighbouring region's container, where the gate
      bind did not look. The bind now searches every loaded region in world x/z and retries after
      each later commit (`World3D._bind_gate`, `_rebind_pending_gates`), and the real-input run
      Hotan -> Donwhang -> Jangan went through.
- [ ] **Alexandria (North)'s gate `STORE_SD_GATE2` is not clickable**, on dev e5bf2ba and after round
      650. Whether it was before round 643 is not known: round 577 did not run Alexandria. MEASURED
      (boot at GATE_SD2, 92/51 (111, 524), radius 1): the nearest placed object to the table's point
      (92/50 (1719, 760)) is `alex_portal` at 15.1 units, past the 10-unit stand-in radius. Whether
      that portal is the gate is not established. Widening the radius would be a guess. Alexandria
      (South) binds its `alex_portal` at 8.4.
- [ ] **"After I died, the Jangan teleport stopped working" (round 675) is not reproduced.**
      opensro-01's log shows the player's client never sent OpTeleportUse (0 in the whole
      session) after the option-1 revive took it to Jangan, though it ran into the gate's AOI cell
      and clicked around for about 4 s; six dev runs with the live flags (QA hook, real X input,
      the user's saved place and `/speed 3`, the native readers, 4K at UI scale 1.95) all went
      through. Next: the player's client log for 18:04:20-18:04:37 UTC on 2026-10-01 (its `PICK:`,
      `NPCTALK` and `World3D: teleport` lines; round 675's `CLICK:` lines from the next release).
      WORLD_ISSUES round 675 has the timeline.
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

- [x] **A hard guard on the monster list before the flip** (round 571's review) -- **done in round
      656**: the list is the player's area of interest (the 5x5 regions around it) and is paged
      over as many frames as it needs (`session/monsterlist.go`; `docs/protocol/monster_ai.md`,
      "The area of interest, the paged list and the sleep"). `TestMonsterListLargerThanAFramePages`
      lists 1,500 monsters in several frames; on the base it fails with `proto: payload of 96004
      bytes too large for a single frame`.
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

### Monster scale: the area of interest (round 656) — **built: cell index, AOI, paged list, sleep, one respawn scheduler, send deadline; these are left**

Round 656 made the server carry ~10,000 monsters (`docs/protocol/monster_ai.md`, "The area of
interest, the paged list and the sleep"; WORLD_ISSUES.md, round 656). Left:

- [ ] **An older client gets a degraded view.** Pages go only to a request carrying the capability
      byte (0x01, round 656's review). An older client gets one frame holding the nearest monsters
      that fit, which is short of the window once about 480 monsters share it (round 657's full
      map). It ignores `OpMonsterLeft` 0x00B5, so bodies that leave its window stay drawn where
      they were last seen. Release the round-656 client before round 657's flip.
- [x] **The AOI window is retail's since round 664** (READ): the 3 x 3 message blocks of 320
      units around the player's block (`combat.CellSpan`, `AOIRadius` = 1;
      docs/protocol/monster_ai.md, "What a player is sent: retail's message blocks").
- [ ] **The sleep is OURS.** "A monster no player's window holds does not run" stands in for
      retail's object-update rule, UNREAD; since round 664 the window is 960 units wide, so the
      awake area around each player is too. A monster left mid-leg by the last player resumes the
      leg when one returns; one that was chasing a player who teleported away resumes BATTLE and
      then releases on its target test. Since round 666 a sleeping monster's brain is dropped and
      only its `brainMemory` is filed (state, dwell, heading, cooldowns, timers 1 and 6, the
      aggression roll, a unique's triggers), so the brains are the awake monsters. Left: a memory
      of a monster that died asleep is swept 64 a pass (`asleepSweepPerTick`, OURS), not at the
      death; and the aggro link now never gathers a sleeping monster (before round 666 it gathered
      one only if its brain happened to survive from an earlier visit -- history-dependent either
      way, since the engine walks the owner's regions: UNREAD which it wakes).
- [ ] **The client still asks for the whole window's list after every hit** (World3D ~15825,
      ~17529) -- up to 60 KB for a dense window. Round 655's lane (the client's monster drawing).
- [x] **A slow or stalled client held its writers up to its blocking budget** -- fixed in round
      662: every session has its own outbound queue and writer goroutine, so no sender waits on a
      peer. A client is closed when its queue passes `gateway.SendQueueLimit` (2 MB, OURS, about 8x
      the measured busiest 4 s) or its writer's blocked time passes the budget (unchanged).
- [x] **The client's packet reader waited for a whole payload in the kernel buffer** -- fixed in
      round 663: it reads what is available into its own buffer on every poll. (Round 662 §4,
      MEASURED). `packet_reader.gd` read a frame only once `get_available_bytes()` covered its
      payload. Over loopback a server that wrote its queue in one write left the client's receive
      buffer full of part-read ~52 KB segments (skmem r137152 of rb138172) holding 31,250 bytes,
      short of a 32,735-byte list page: both sides stopped. The server now writes a frame per write,
      which MITIGATES it and does not fix it: under a backlog (the client's window shut by a load
      freeze) Linux's tcp_sendmsg coalesces writes into the unsent tail skb, so large segments come
      back.)
- [ ] **The send queue's limit and drain are OURS** (round 662). `SendQueueLimit` 2 MB was sized
      from one live client over loopback at ~50 monsters a region; a real link was not measured, and
      a legitimate burst bigger than the paged list (none is known) would close its client.
      `SendDrainTimeout` 2 s bounds how long an ending session writes out what is queued. There is
      no kick, no logout reply (`OpLogoutRequest` 0x7005 is unhandled) and no shutdown notice; a
      future one must send and then end the session through the gateway's drain, not `Close`.
- [x] ~~A session the server closes at the title, character select or create lands on the login
      screen with no reason given~~ -- round 788: retail's drop box (`NetOffBox`, READ slot 40
      0x862450: MsgBoxINIF titled `UIIT_STT_CONFIRM_BOX`, `UIIT_MSG_MSGBOX_NETOFF`, Confirm only),
      whose Confirm **quits the client** as retail's does (0x641eb0 -> CPSQuit).
- [ ] **In the world, a session the server closes still lands on the login screen with no reason.**
      `World3D._on_disconnected` changes to `Login.tscn`. Retail (READ, CPSMission::vslot_040
      0x84ae90) shows the same NETOFF box and quits on Confirm (to the title only when a logout or
      restart was already under way, +0x39c == 2). Not changed in round 788: the QA reconnect hooks
      (`OPENSRO_QA_RECONNECT_VIA_LOGIN`, round 558) ride the return to the title.
- [ ] **Round 788 (OPEN): the "[Block Detail]" button** of a punishment whose reason ends in '#'
      (READ 0x86c136..0x86c416: id 800, 15 s, opens the address in Internet Explorer) is not built;
      the message shows the text before the '#'.
- [ ] **Round 788 (OPEN): `UIO_MSG_ERROR_THERE_IS_NO_ACCOUNT_INFO`** (0xA102 2/3) also opens a dialog
      in retail (RESEARCH section 1); only its text is shown.
- [ ] **Round 788: 0x6102 on OpenSRO's server is not behind `session.LoginGate`** (inspection, the
      GM gate), which wraps only OpLogin 0x0001; the client now logs in with 0x6102. The server
      lane's LoginService is where the gate belongs.
- [ ] **With `-monster-spawn-push` off (the default), a respawn is never announced.** Its first leg
      then reaches clients that do not have the body, and they ask for the list: the pre-656
      discovery path, kept. With the push on, the push leaves at once and a brain's first leg waits
      out an IDLE dwell (2001 ms or more). (The respawn scheduler can no longer be held up on a slow
      client: round 662's send queue.)
- [ ] **The request paths' broadcasts still copy the zone's entities** (`monsterWatchers` filters
      `EntitiesInZone`): fine at 100 players; the AI tick uses the runtime's watcher index instead.
- [x] ~~The respawn is still the flat 10 s~~ -- round 660 runs the READ nest rules in the one
      scheduler (`internal/nest`); 10 s is now only the stand-in nest's window.

### Towns (round 674) — **built: a monster that walks into a town region, or is placed in one, is removed (READ: CGObjMob::SetCurRegion 0x4c1270); these are left**

Round 674 (`docs/protocol/monster_ai.md`, "Towns"; WORLD_ISSUES.md, round 674). Needs `-regions-csv`
on opensro-01 (`deploy/README.md`, "Towns"). Left:

- [ ] **The player's side of the town byte** (READ, not built): a player-vs-player attack where
      either side stands in a town is refused `0x3018` ITS_NOT_A_BATTLE_FIELD (CGObjPC slot 394,
      0x5293a0); an offensive skill cast FROM a town is refused `0x3018` (`0x3009` for a quest skill;
      the skill gate's row 13, 0x58e186, `FUN_00589d20` the "offensive" test); a thief with a cart
      cannot cross into a town (`0x0c01`, CGObjPC slot 220, 0x4eb220). OpenSRO lets a player in
      town attack a monster outside.
- [ ] **Whether the nest counts a removal as a loss** (INFERRED yes: OpenSRO re-arms the nest as
      for a death). The engine's hook, `AI::CNest::OnHatchedRemoved` 0x560d00, still has no caller
      found.
- [x] **What the players are sent** for a removal (round 677, READ): the despawn `0x3016`.
      `FUN_00417090` -> `FUN_00489fc0` -> slot 0x354 (`CGObjMob::ReleaseAndClear` 0x4c0eb0) -> slot
      0x358 (0x4c10b0 -> `CGObjChar::vslot_214` -> `CGObj::vslot_214` 0x484a80) -> slot 0x364 (the
      leave-world 0x485150) -> slot 0x3b0(0, 0, 0) (0x4c1e00 -> 0x485bb0) -> the block's slot 3
      (0x5344b0) -> `FUN_00534050`, `0x3016` with the object's id to the nine blocks' players. The
      client fades it out over 1.5 s; OpenSRO's `OpMonsterLeft` now draws the same fade.
- [ ] **A monster whose leg ends exactly on a z region line** is checked only at its next cell
      crossing (OURS: the cell index files the line on the field side, worldmap.FromWorld on the
      town side). Immaterial in play.
- [ ] **Six retail placements stand in town regions** (Alexandria, 90/49 and 91/51): with
      `-full-map` they hatch, are removed and hatch again after their window while a player is
      near -- what the engine would do (INFERRED). Logged at Debug, with one INFO count a minute (review).

### The monster world's nests (round 660) — **built: every field row a nest, the DB's numbers where a row joins one, champion/giant/party, per-monster tactics; these are left**

Round 660 (`docs/protocol/monster_ai.md`, "Nests on the map"; WORLD_ISSUES.md, round 660). Left:

- [ ] **Tiger Girl stands sunk into the ground at her spot-0 nest** (the user, 2026-10-03, on
      opensro-01: found her with `/tp -18864 13644`, "she was in the ground"). The server logged her
      hatch at x -18864.1, z 13643.6 (nest 5908, spot 0 of 11). Not yet read whether the height comes
      from the nest row, the server's ResolveCellAndHeight, or the client's placement of a unique;
      check the other six uniques' spots too. Related: a GM `/spawn` monster on the Jangan plaza deck is
      drawn on the terrain 14.2 below the deck (round 701 found it; `_terrain_hit_height` uses the
      terrain-only mask).
- [ ] **`/goto <unique>`** does not know a full-map unique's current spot (`gmSpeciesLookup` marks
      table species Unplaced). A `/goto` that follows a unique's rotation, and a `/uniques` list, were
      offered to the user 2026-10-03; not asked for yet.
- [x] ~~The uniques~~ -- **round 661**: the seven field uniques rotate over their 70 spots (the
      build pin 0x55efe0, the re-pin at death with its last-nest bias 0x55eec0, every nest of a
      capped hive re-armed 0x560e50), fight with their own skills under their tactics, summon by
      Summon_A/B, and Captain Ivy's trigger fires; only Cerberus's summons spawn (its Ladons --
      the other six uniques' tuples read 0..0, and the READ executor spawns nothing for them).
      What is left:
  - [ ] **Minions accumulate.** Nothing removes a minion (READ: no list, and the unbinding command
        0xc's one sender is the pet path 0x4d2109). At retail's counts only Cerberus summons, about
        2..3 Ladons at each of its tenths above 80 % and 1..2 elites between 40 and 60 %, so an
        abandoned fight leaves a bounded pack (`TestMinionsFromManyKillsAreBoundedBySpawns`).
  - [ ] **The leader-bound behaviours are OPEN.** `combat.Monster.Leader` (the minion's ctx+0x14c,
        command 0xb) is written but never read. The engine reads ctx+0x14c in 0x540d20, 0x5460d0,
        0x5485b0, 0x5487b0 and 0x5488b0 (the follow and give-up gates: a leader too far away,
        200.0 or the leader's own radius + a constant, returns 2) and in PickWanderLeg's bias
        (0x5459f0); what their return codes do to the state machine is unread.
  - [ ] **Summon_C** (tactics 0x970e/0x9722) is not modelled: no field unique runs it.
  - [ ] The summon has no cast push: the client sees the minions appear, not the unique cast.
        The periodic trigger's phase alignment (round 260) is simplified.
  - [ ] `/spawnunique`'s uniques still carry the disclosed attack curve and no skills; a rotation's
        unique carries its own.
  - [ ] **MOB_SD_APIS** (rarity 8, region 74/73) has no nest of its own in the shard (its spot's
        nest is the shard's DEADWARRIOR at cap 0); not placed until a real nest is known.
  - [ ] **The Pharaoh temple** (worlds 57-59, `INS_PHARAOH_*`, EXTERNAL): its 90 npcpos rows --
        the SD elites and the fifteen bosses -- belong to instance worlds OpenSRO does not run.
- [ ] **The dungeons.** 1,915 npcpos rows in regions >= 0x8000 are not placed (only 330 of them
      have a shard nest at their spot, round 658).
- [x] ~~The swapped spots run stand-in nests~~ -- the user's decision (round 660's review): the
      6,041 swapped spots take their own DB nest's cap, window, radii and champion chance
      (EXTERNAL); `-nest-swapped-stand-in` (OURS) is the one-monster fallback. Left: 3,695 of them
      run the stand-in behaviour (their species has no tactics row left in the shard), and a
      swapped nest's hive cap is not applied (the shard regrouped those nests).
- [ ] **132 matched nests have a cap of 0** (MOB_OA_DESERTTRUNKZ 60, its _CLON2 46, the Jangan
      bandits 22, ...): the pass's `alive < cap` never holds, so they hatch nothing, in the shard
      too. Faithful to the DB; whether retail's rows were 0 is unknown.
- [ ] **Not modelled from the hatch path**: the hive population rate (`btKeepMonsterCountType` 1 on
      2,355 of the placed nests' hives; its region sample is unread; it would only shorten a 1-3 s
      window); the event-monster substitution; the level > 110 refusal; a failed placement (no
      server navmesh -- `nest.HalvedDelayMs` is tested, never reached).
- [ ] **Tactics columns carried but not run**: column 9's retarget by hate (every matched row says
      2; the runtime keeps the first attacker until the threat table has hate values), column 39
      `btAggressTypeOnHoming` (no reader found), column 34 `btTraceType` (2 on 66 rows, no reader),
      and the flag word's bits 2/7 give-up gate (`ai.GiveUpCode`; no placed row sets them).
- [ ] **Champion, giant and party rewards**: a champion or giant pays the level table's EXP and
      the species' gold like a normal one. ~~Retail's reward scaling by rank is unread.~~ **READ
      (round 709, `docs/protocol/party_rules.md`):** `CGObjMob::vslot_359` (`0x4c15c0`) multiplies
      EXP **and SP** by 7.5 for a party monster, then by rank ×2 champion, ×15 giant, ×60 (5),
      ×4 elite, ×30 (7); the live kill path is `CGObjMob::vslot_399` → `CGObjPC::vslot_420`. What
      its base (`slot 332`) returns is still OPEN; party lane S2 builds it. Where to
      start (round 660's review): `Formula_MonsterExpReward` 0x4105d0 has no rank factor, but its
      only callers are `GObjPC_OnDeath` 0x4e6980 and `FUN_004e6d60`, which may be the PvP path --
      so the real monster-kill EXP path is not located yet.
- [ ] ~~**The party arming's reference point is INFERRED** (the dead monster, 1000 units): the object
      GObjPC::FUN_005bca60 measures from was read as the victim, not proved.~~ **READ (round 709):
      it is the kill credit** (the biggest hitter of the most-damaging group; `0x5bcacb`-`0x5bcb29`),
      same world, horizontal with 1920-unit region steps; only exp-share kills arm, and instance
      worlds gate on `PARTYMONSTER_SPAWN`. The code still measures from the dead monster and arms
      for any party: party lane S2 fixes it (`docs/protocol/party_rules.md`, gap 12).
- [ ] **The client**: the species' own scale percent (ref+0x110, column unread) is not applied on
      top of the class scale; the party mark's size is ours (the plate is ours); the target
      window's party re-centring (0x69b890..0x69b98d) is not done; class 7's "Elite" name prefix
      on the overhead plate is not drawn (no class-7 monster is placed).
- [ ] **Scale at full occupancy**: with the swapped spots on their nests the densest window holds
      4,716 monsters (region cell -116/8; 1,516 at cell -59/3 before the review). The client's build
      budget (round 655) was sized for ~500 in view; see the entry's measurement.
- [ ] **The join is one row per nest, greedily** (own species first, then nearest; OURS): 5 placed
      rows have more than one nest within the 1.0 tolerance (co-located nests), none lost its nest.

### Status effects on monsters and players (round 659) — **built: receive, give, DoT kills, stun/freeze/sleep/root/slow, the 0x3057 mask and its icons; these are left**

Round 659 (`docs/protocol/status_effects.md`, "What OpenSRO does"; WORLD_ISSUES.md round 659).
Left:

- [ ] **Burn deals 0 a tick.** Its damage is `table[value2]` from the server binary's 0xc63c94 word
      table, which is not copied into the repository (docs/LEGAL.md). `statuseffect.SetBurnTable`
      takes it; nothing loads it yet (an operator-supplied file, read from their own binary).
- [ ] **The client draws a state only as a target-window icon.** READ but not built: the per-bit
      body effect (`0x9cd5e0` -> `0xa950a0("PARAM_<label>")` -> `0xa54020`), the colour lerps
      (`vtable +0x48`, 1000 ms; the colours are the floats at `0xde2488..0xde24c4`), freeze's pose
      (`+0xbd`, animation state 9) and the animation-speed change for frostbite and slow (`+0xc0`).
      Nor does the player's own buff bar show its abnormal states (`UI_STATE::0x7836d0`), nor the
      tooltip's description line.
- [ ] **A character resists nothing.** Params 27..32 / 145..150 (item magic options, buffs) are not
      published; `statuseffect.Target` takes them.
- [ ] **Unpublished params**: myopia's range cut (183, `combat.ApproachBand`), dark's attack rate
      (11), electric shock's parry (9), the curses (3, 4, 5, 6, 178..181), param 140 under
      frostbite/slow, and all of them on a character. The mask shows; the numbers do not move.
- [ ] **Unread blocks**: the halving loop the slow, bleeding and stun blocks run on the chance (its
      count; OpenSRO rolls the base chance, never lower than retail's); the stun block's own guards
      (`[esp+0x43]`, the call's fifth argument); 'tb' (+0x474, not applied) and 'csmp' (no
      applier, not applied); the target flags word whose bits 4 and 8 withhold states
      (`0x58f3f4`); fear's AI message 0x14.
- [ ] **A player's speed is not slowed**: the client moves its own character; the server applies
      frostbite and slow only to monster legs (a moving monster's leg is restarted at the new speed
      on the next AI tick, up to 100 ms after retail's immediate republish).
- [ ] **A death by a tick is reported as `OpMonsterAttacked` with the status-tick flag 0x08** (OURS,
      round 659's review): retail's message for it is not read. The victim's client enters the dead
      state from it, and other clients play her hit clip, as for a blow's death.
- [ ] **One status application per cast** when any of its hits got through (OURS): retail's call
      sites sit per hit (`0x58f429`..`0x58feda`), whether each unblocked hit rolls again is not read.
- [ ] **INFERRED**: that a frozen, stunned or sleeping monster starts no attack (the motion state is
      read; the attack path's test on it is not), and that a DoT tick naming its caster is the
      monster's struck event and is booked on its damage list (vslot 0x4fc,
      `Char_ForwardToAttachedObject` 0x4a7500, forwards to an unread object). Sleep is not broken
      by damage (unread). A death by a tick releases every monster in BATTLE on her, a blow's
      death only its killer (OURS). A zero-damage status cast is
      measured for reach like a damaging one (the gate's exemption, if any, is unread).
- [ ] **OURS**: the 100 ms pass (`StatusTick`); the first tick one interval after the state lands
      (`record+0x68`'s first value is unread); states ending at logout; character masks going to
      the whole zone (monster masks go to the area of interest's watchers).
- [ ] **A kill by a tick shows no EXP line** in the killer's system window: the reward is granted
      and `OpLevelUp` sent, but no `OpAttackResult` carries `ExpGained` for it.
- [x] ~~A kill by a tick never armed a party nest~~ -- round 666: `dealMonsterTick` tells the nests
      (`noteMonsterKilled`) with the tick's credited applier as the killer, as a blow's kill does. A
      tick that names nobody (a dead poisoner, `statuseffect.SourceRule`) counts no party.
- [ ] **A skills table imported before round 659 lands no status, anywhere.** Round 666 made the
      boot WARN (`skills store has NO status params`), and the opensro-01 procedure
      (deploy/README.md, "Deploying the monster-epic release to opensro-01") re-imports it; the
      server still boots and runs without statuses on such a table, by design (never an exit).

### Other bodies' facing (round 637 and its review follow-up) — **built: every body, this player's too, turns to face where it goes at 3 pi rad/s, and an arrival faces the way it last walked; these are left**

READ and measured in `docs/WORLD_ISSUES.md`'s 637th round; the rule is `RemoteFacing`.
`OPENSRO_QA_FACING_LOG=1` plus `client/tools/facing_measure.py` is the measurement.

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
      mover's current POSITION (`+0x54/+0x58`). OpenSRO streams positions about 2.5 units apart
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

### Over and on monsters (round 673) — **built: no bar over a monster's head, every name within 300 of the player from any camera, every monster model turns to its path and its target; these are left**

READ and measured in `docs/WORLD_ISSUES.md`'s 673rd round; the name rule is `NamePlates`
(docs/protocol/monster_ai.md, "The overhead name").

- [ ] **Retail's own over-head gauge is not built.** The user: "There's a toggle in the original
      game to see mob and player health bars above them but it's much smaller but let's ignore it
      for now." It is `CICharactor` vslot 38 (0x9d0da0): an HP (and MP) gauge drawn only under the
      option flags it tests (`FUN_00b94b90` on 0xeef6f0 / 0xef1a84 / 0xef1bc0) and within the
      name's 300 of the player (`FUN_009cef40`). Its art, size and the option's place in the
      Option window are unread.
- [ ] **What lets a name show at any distance** (`object+0xf0`, tested before the 300 at 0x9d0ac3)
      is unread, as are the name pass's other early returns (a vcall at +0xb0 on
      `FUN_009edd60`'s object; the bits `+0xd4 & 2` and `+0x464 & 2`) and the global byte
      0xec4b58 the overlay pass is drawn under -- one of them is likely the Option window's
      "show names" switch.
- [ ] **The plates' look: monsters matched to a retail picture, the rest still ours.** Monster
      names are white, no outline, 12 px in the client's face on a black box at 0.29, 1:1 pixels
      (MEASURED from the user's retail screenshot, round 673). Still open: the face (the text call
      under `FUN_008b4d90` is not traced), the height over the head (retail: position + height +
      2.0 projected, then lifted by half the short at +0x4c2 plus 10 px when `FUN_008b2d20()` is 0,
      from LAB_009d0d3c; +0x4c2 untraced), and the
      player's and NPCs' plates (cream on a black outline, Godot's font, round 672's item under
      "Text crispness") -- the retail picture's player plate also carries the HP/MP gauge and an
      icon.
- [ ] **The sweep is OURS**: a sixth of the plates is re-tested a frame (`NamePlates.SWEEP_FRAMES`),
      so a name can show or hide up to 0.1 s after its owner crosses 300; retail measures every
      object every frame.
- [ ] **Every name box draws before every name** (render priority 0 against 1; round 673's
      review): where two monsters' plates overlap, the far one's text draws over the near one's
      box. Needs the box and its text sorted as one item (one mesh, or a screen-space draw).
- [ ] **Two models read +Z, 36 settle nothing** (`probe_monster_front.gd --all=1`): the event
      Jinn pets (`cos\p_jinn*.bsr`) on one weak head reading each, and the models with no
      toe/head/pelvis bones or disagreeing readings. All turn as -Z (INFERRED, one heading
      convention); a render of a walking Jinn would settle it.

### The click walk's arrival (round 649) — **the /speed stutter fixed: the step is cut to land on the point, as retail's is; these are left**

Measured in `docs/WORLD_ISSUES.md`'s 649th round (`OPENSRO_QA_MOVE_LOG=1`, a trace every tick).
The rule is `ClickWalk.step`, READ from the mover tick `FUN_009e0e60` (`docs/protocol/opcodes/movement.md`).

- [x] ~~A walk into something solid holds its order and runs in place~~ -- **done in round 649's
      follow-up**. A click walk the graph blocks dead now ends, as retail's mover ends a refused
      step (READ: bit `0x10000000` in `FUN_009e0e60`). The live run measured 0 held episodes;
      the base had 26.
  - [x] ~~What "dead" means is OURS (1 % of the step)~~ -- **decided and done in round 653's
        follow-up**. Round 653 read the query: retail does not slide. `CRegionManagerBody::vslot_012`
        -> the terrain walk `0x4047a0` answers a blocking edge with the crossing point (nudged at
        most 0.2) and bit 0, and the mover then ends, for every movement kind. The user's request
        decided it: "stop in place like the original game". Every order now walks with the no-slide
        walk and ends at its first blocked step. A walk at an angle into a door frame now stops at
        the frame, where it used to slide into the doorway (`click_walk_test.gd`, synthetic doorway).
  - [x] ~~An attack's approach against a wall still holds~~ -- round 653's follow-up. The wall ends
        the approach's move. `World3D._step_move_order` re-issues it on the next tick, as retail's
        attack tick re-issues `MoveTowardObject` (phase 1, READ). While the approach's point stays
        within 0.5 of the one the wall stopped (OURS), the body stands at the wall facing its target
        and the reach is tested every tick. It walks on when the target moves.
    - [ ] **What a retail body shows then** (the client's display of a server-side re-issue every
          30 ms at most) was not read. OpenSRO's body stands.
    - [ ] **The pick-up walk** ends at the wall and asks for the item from there
          (`_ask_pickup_after_walk`); the server judges the 10 units. Retail's pick-up approach was
          not read.
  - [ ] **The physics fallback walk** (a region with no `.nvm`, `move_and_slide`) ends an order on
        `is_on_wall` (round 653's follow-up, OURS). It still slides for the tick that meets the wall.
- [ ] **The early stop (`MOVE_TARGET_STOP_DISTANCE`, 2.39) is OURS.** Retail lands on the point
      exactly. The stop is kept only because `CombatNet.approach_aim` is built on it.
- [ ] **The server does not police speed** (round 636, `gm.go`). It relays whatever a client sends.
      A client that still has the old rule (a release before this round) ping-pongs for everyone.

### The sky click (round 653) — **built: a click on the sky, or on ground beyond 1000 units, runs the character on its heading until a wall stops it; these are left**

Read in `docs/protocol/opcodes/movement.md`, "The heading move". The code is `SkyRun` and
`World3D._move_by_pick_ray` / `_start_heading_run`.

- [ ] **The server does not run the heading move itself.** OpenSRO's movement is client-authoritative
      positions. The server relays each position with the heading form and faces the character that
      way, but it does not step a `CGObjMoverByCmd` of its own.
- [ ] **Whether retail's server tells the watchers of the stop** (a stop message when its own
      navmesh ends the run) was not read. OpenSRO's watchers settle on the last position.
- [x] ~~`+0x6e8`~~ is the mover's `+0x80`, the move kind (round 653's review, READ). The window
      keeps only a heading run, and OpenSRO tests `_has_move_target and _move_heading_run`.
      `+0x65c` bit 9 meaning "moving" is still INFERRED.
- [ ] **Requests that do not end a run yet** (round 653's review; retail's skill-start and
      pick-up-start paths were not read for a mover stop): a self or ground cast, an attack sent
      with no walk (the `no_walk`, no-BCRadius and wall-root paths), a friendly skill on a
      monster, an in-reach pick-up, and an NPC talk.
- [ ] **The arrow keys** send the same heading form, with commands 1, 0x10 and 0x20 (READ). They are
      not bound (the key table's `NOT_BOUND`, round 608).
- [ ] **`0x70c5`** is sent in place of `0x7021` when `FUN_00b94b90(0xef1b44)` is false (probably a
      ride or transport). Not built.
- [ ] **The physics fallback** (no `.nvm`) ends any order on `is_on_wall` (OURS).
- [x] ~~Click walks still slide~~ -- round 653's follow-up: every order stops at the wall, as retail's
      does (the section above).

### The ring on the ground (round 698) — **built: the click marker and the selection circle are one decal, as in retail (READ; docs/protocol/ground_markers.md); these are left**

`GroundMarkers` (`client/scripts/world/ground_markers.gd`): a ground click moves the ring to the
point with `select_01` (pale grey-cyan), a selection puts it under the character -- `select_04`
(orange-red) for a monster or a COS, `select_03` (blue) for a player, `select_02` (yellow-green)
for anything else -- draped on the 3 x 3 terrain cells round the point, 12 units across, never
scaled; a heading run hides it; arrival, deselecting and death leave it; a despawn or a hidden
body hides it. There is no hostility or rarity test in the ring's code (round 698, the whole
census of its texture writes).

- [x] **No walk within 20 units of an NPC** (round 698's review, READ `FUN_009ec570`): a ground
      click within 20 of an NPC at non-zero scale does nothing, logged as `CLICK: ... ignored`.
- [ ] **The pick mode's ring** (`UI_SILKMALL::FUN_00629fa0`, modes 1 and 4): `select_02` at the
      picked point within (R - 5), `select_04` beyond, hidden under 0.25. Probably the ground-target
      cursor round 617 drew with the system cross; the modes and R (`[FUN_008ba440()+0x254]`) are
      not read.
- [x] **On a placed floor the ring is draped on the floor** (round 701, OURS: the user's decision
      of 2026-10-03 after checking a live retail server, which draws no ring on the plaza deck --
      retail's drape is terrain only, READ). A point more than 1 above the terrain whose short ray
      down meets a placed object (layer 1 without the terrain-only bit) takes a drape sampled on a
      2-unit grid from 2 above the point (roofs never met), triangles with a miss or a step over 1
      left out; the terrain drape is unchanged. Rebuilt per 6-unit cell, samples cached.
      ground_markers.md, "On a placed floor".
- [ ] **The floor drape's open edges.** OURS and untested on the real archive beyond the Jangan
      plaza: a stair steeper than 1 in 2 loses its triangles (the step rule), and an awning lower
      than 2 above a floor would be sampled as the floor. Neither was met at Jangan (round 701's
      live lines: every corner at the deck + 0.05).
- [ ] **A monster GM-spawned on the plaza deck is drawn on the ground under it.** MEASURED in
      round 701's live run: `/spawn mangyang 1` at the Jangan spawn put the body at y -43.90, on
      the terrain 14.2 under the deck (-30.12); its ring followed it there, and the attack
      answered "too far away". `_terrain_hit_height` places a still monster with the terrain-only
      mask; how retail places a monster on a placed object's navmesh is not read. Not the ring's
      code (round 701 stayed in its lane).
- [x] **A click on an NPC or a gate out of reach walks first** (round 701, READ 0x793570 /
      `FUN_009ec6b0` / `FUN_009ec380`): beyond 240 (a gate 800) the walk goes to a random point
      20..240 (640) short of it on the line to the player, the ring there; the talk opens on
      arrival within the server's 300 / 800. A monster click selects; the next click (or Ctrl, or
      a double click) attacks.
- [ ] **The server's range on shop and storage.** Retail's shop handler (0x510250) measures the
      player against the NPC (`IsWithinInteractionRange`, 300); OpenSRO's shop and storage
      requests carry no NPC, so the server cannot (round 701). A select or talk request naming the
      NPC would let it. The teleport request has applied the range since round 642.
- [ ] **A stall's approach** (100 / 80, arrival flag 2 -> `FUN_0081e170`) is read, not built: no
      stalls yet.
- [ ] **Who walks a monster attack into reach.** READ: the server (attack tick 0x4ad8e0 ->
      `GObjPC::MoveTowardObject`; the client sends 0x7074 with no walk). OpenSRO's client walks
      (OURS) because OpenSRO's server does not chase.
- [x] **A held left button does nothing** (round 701, READ: WM_LBUTTONDOWN is the only click,
      0x77c4a7 -> 0x793570; no reader of the left button byte +0x258 walks; timer 7 is the sky
      run's re-plot). Ours clicked on the release and steered toward the cursor while held.
- [ ] **The cell diagonal.** Retail's drape alternates the diagonal by cell parity (0x9f3c10); ours
      follows OUR terrain mesh's single diagonal so it lies on what is drawn. Whether retail's
      terrain mesh alternates too (and so ours is wrong) is not read.
- [ ] **The heading hide's timing**: retail hides on the local player's 0xB021 heading echo, one
      round trip after the run starts; ours when it starts (no echo in our protocol).
- [ ] **vslot 0x50's other tests** (byte +0xbc, global 0xeef5f4, `FUN_009d0560`) are not mapped;
      ours hides on a body that is gone or not visible in the tree.
- [ ] **Pets, horses, transports (CICCos)** get `select_04` when the client draws them; **items**
      get `select_02` if a selection of one is ever built; **dungeons** (no height map) draw no ring
      (INFERRED from `FUN_009ef640` failing).
- [ ] **The unique's "purple circle and red arrow"** the user remembered are not in this client
      (two probes: the code, and every effect in the archives; the protocol doc has both). The only
      marker a monster's spawn attaches is the quest-monster parchment (`SYSTEM_QUEST_MARK`), gated
      on characterdata column 102, 0 on every row. Ask the user which client they remember.

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
- [ ] **Abnormal states** (the target's `+0x2c4` bits go in the second list). OpenSRO sends no
      one's abnormal states to the client.
- [ ] **0xB0BE**, the type-3 buff that carries a name (the tooltip's "Target :" line). What it is
      in retail is unread, and OpenSRO sends nothing like it.
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
- [ ] **Pets** (the CICCos branch shows the viewer too). OpenSRO's pets cannot be targeted yet.

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
      - the academy slots' portraits (same constants, not drawn); the party's are drawn since
        round 715 (`HudQuickParty`, the member's bare model by its id, `party_gui.md` §7);
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

### Text crispness (round 672) — **built: glyphs rasterised at the UI scale and drawn unfiltered, every in-game text node in the client's face, Buttons guarded against the lost last glyph; these are left**

docs/WORLD_ISSUES.md round 672 has the measurement (`client/tools/measure_text_crispness.gd`) and
the READ mechanisms. Every HUD, chat, notice, window and code-made Button text measures one level
and a 1-pixel edge at 1.0-2.5, as the original's GGO_BITMAP glyphs are.

- [ ] **Arial or Tahoma: compare later** (the user, 2026-10-01: "keep Arial for now and maybe we can
      compare later, especially if I don't like it"). The client uses the archive's first
      `UIC_STT_FONTNAME` row, Arial, as vSRO does. Its `*` in the password field is a small raised
      glyph. A private server's login (scratchpad reference `login_pw_ref.png`) likely uses Tahoma,
      the archive's second row, whose `*` is larger and centred. Options: switch the login fields,
      switch the whole UI, or a `setting/config.yaml` key.

- **Name plates and damage numbers** (`World3D._name_plate`, `_floating_damage`): Label3D in
  Godot's anti-aliased default font at 32 px, scaled by `pixel_size` 0.0004 under `fixed_size`,
  linear-mipmap filtered -- 64-79 % of their pixels part-covered at every scale. Label3D can be
  crisp (the client's face, NEAREST, `pixel_size = 2 tan(fov/2) / viewport height` so a texel is a
  pixel, re-set on resize and on the camera's fov), but that sets the plate to the UI font's 12 px
  x scale on screen; retail's name text is screen-space (CICMonster vslot 15, `0x9d3e70`, places
  the party mark at pixel offsets from the name box `FUN_008b2d30` gives) and its draw call under
  `FUN_009cf1b0` is not found yet -- find it, read the face and size, then build the plate to it.
- **Texture-styled Buttons** (CompositeItemWindow's) keep the linear filter, so their text is
  oversampled but filtered at a fractional scale. The fix is a TextLayer for their text, as the
  chat tabs and the notice have.
- **The Button guard is probabilistic**: a fractional width that lands within ~1e-5 under a whole
  number after the guard's +0.0019 per glyph would still lose its last glyph. A Label-based button
  (text drawn without the TextLine clip) would close it for good.
- **The front-end** keeps its own sizes (Godot's 16 px in the client's face); only the filter and
  the Button guard reach it.
- **The help window's headings** (`md_to_bbcode.gd`: 26/22/19/17/16/15 px) are OURS; its body is
  now FontIndex 0's 12 px, as retail's guide layout is. Retail draws no Markdown -- if the window is
  to match a retail one, its heading sizes need a source.
- **Outside the UI root**: the debug panel (under `$UI`, a sibling of `ui_control`) keeps Godot's
  default font and is not covered by text_crispness_test.

### Chat (round 634) -- **the retail window, channels, globals and notices built; these are left**

docs/protocol/chat.md has every address. Built: the five tabs with their filters and lamps, the
per-type colours and captions, the hanging wrap indent, the left scroll bar (arrows, thumb, wheel,
drag), the channel marks `# @ % & $`, R's `$name ` reply, the sender's echo and the 0xB025
refusals, the global chatting item's "Chat to all" window, the GM notice's line and banner, and
`/notice`.

- **Union and academy chat have no audience**: OpenSRO forms no alliances and has no academy, so
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
  range of ordinary chat (OpenSRO: the zone bucket); the wheel
  step. The user's screenshot (a private server) draws notices cyan (0, 174, 195) without the
  "(Notice):" prefix; the binary says pink `0xffffaec3` with the prefix -- OpenSRO follows the
  binary; the private client's source for the cyan is not known.
- "Remaining turns" in the global window overruns into its count (the authored static is 55 px
  wide; our font draws the caption wider).

### Notice banners and the area banner (round 703) — **built; these are left**

What round 703 read and built is in `docs/protocol/notice_banner.md`: CIFNotify's band drawn as
CIFStretchWnd lays it out (the fill over the text, the 40 x 8 fades outside it), the bold notice
text, and CIFRegionView's area banner from regioncode.txt and textzonename.txt.

- **The fortress town's third line** (`0x665d00`: UIIT_MSG_FORTRESS_TOWN_GUILD_NAME with the owning
  guild) is not built: this client keeps no fortress data, so the line keeps its `_03` text.
- **The weight-600 face** is the system's bold file of the UI face when it has one (arialbd.ttf on
  Windows and macOS), else GDI's simulated bold drawn by hand: each glyph at x and x + 1, its
  advance one pixel wider (OURS as code). The face asked for is the archive's Arial
  (UIC_STT_FONTNAME); the box has no system Arial Bold, so every bold render there is the
  simulated one -- as Linux players, and possibly CrossOver ones, see it.
- **EUROPE_SYSTEM.** The area banner's window is under `#ifdef EUROPE_SYSTEM` and the binary uses it
  with no NULL check (READ), while pstitle.txt's front-end art was taken as the `#else` branch
  (INFERRED, frontend_frame.gd). The IFTVariable lookup that decides it is not read: OPEN.
- **The area banner under the loading screen** is held and raised when the screen lifts (OURS);
  retail's loading state at `0x786f30` is not read.
- **The text manager's miss** (`0x8c9bb0` for a key it lacks) is not read; OpenSRO shows nothing.
  MEASURED: every one of the box archive's 146 region codes has its `_01` text.
- **Which notices stack over the area banner** (draw order between interface children 0x14, 0x23
  and 0x53) is not read; OpenSRO draws the area banner under both notices.
- **The user's reference pictures** (a private server) show the town title as "Western China
  Donwhang" in (169, 246, 253); the box's archive says "Donwhang" and ifregionview.txt
  (61, 253, 255). OpenSRO follows the archive.

### The system message window and the saved quick slots (round 639) — **built; these are left**

What round 639 read and built is in `docs/protocol/system_message.md`.

- **The filter board** (GDR_SYETEM_MESSAGE_OPTBOARD, CIFChatOptionBoard, `ifchatoptionboard.txt`):
  its five checkboxes, their art (set in code, not read) and `Setting\chop.dat`. The filter button
  does nothing yet; the filters stay at the no-file defaults (FIGHT off, the rest on).
- **The system window's auto-hide option** (round 641 read it: `settings+7`, the Game options'
  "System UI Autohide", `Setting\SROptionSet.dat` tag 0x7d8). OpenSRO keeps auto-hide always on at
  the user's request, with no option. OPEN: retail's default with no file (the block's initializer
  was not found), and the Game options checkbox itself, if the user later wants the toggle.
- **The chat's whisper list** (ID 51) and its button (ID 14, `0x7a99d0`) are not built. The
  auto-hide's rect test already counts the list's hidden rect above the window (READ, round 641).
- **Guide lines.** The window shows retail's type-6 "[Guide]" tips (`0x789e53`) when they arrive;
  OpenSRO's server sends none. (The unique notices are built: round 657.)
- **Unique notices (round 657, open parts).** Built: 0x0C05/0x0C06 in `OpUniqueNotice 0x0110`, the
  top-damage-group killer, the line choice and the blue GDR_WARNING_WND banner
  (`docs/protocol/unique_notice.md`). Round 661's rotation announces each hatch through the spawn
  hook (live-checked). OPEN: the killer's `vtable +0x53c` (silences a kill) and `+0xec`/`+0xf0` (which
  name); the tie order of the damage list; whether the damage-list credit `0x52a940` is passed the
  blow clipped to the HP left (ours books it unclipped); a unique spawned by
  `/spawnunique` carries the disclosed attack curve and no attack skill. A GM-spawned unique's model
  load stalls the frame (round 657's live check); round 661 measured a rotation's respawn in view
  (see its WORLD_ISSUES entry).
- **Retail's messages for OpenSRO's refusals.** The server sends English text; retail sends a code
  that `0x7b8b40` turns into the UIIT_ message.
- **Quest EXP** writes no line (only a kill's result carries the EXP).
- **The quick slots on the server.** Retail saves them with 0x7158 and loads them from the character
  data (`0x8a7c50`); OpenSRO keeps them client-side at the user's request (OURS,
  `user://quickslots.cfg`). A new character's default slots (`0x786f30`) and dragging a slot off the
  bar to clear it (vslot 26 `0x60c1b0`) are still not wired, as before.
- **The paper doll's step** is 36 degrees a click at the user's request (OURS); a held arrow repeats
  it after 1000 ms and then every 250 ms (144 degrees a second, OURS). Retail's step is a frame's
  worth, frame_ms * 0.0015 rad, repeated every 50 ms.
- **Skill withdrawal** has no server side here; the bar's withdrawal rebind (`0x60c230` with 0) is
  built and tested but reached by nothing.
- **The EXP line at the level cap** reports what was added (0 once full); what retail's server
  sends there was not read.

### The Additional Quick Slot and the extra bars (round 788) — **built: retail's bar as READ, OpenSRO's extra bars with pages; these are left**

`docs/protocol/ext_quick_slot.md` has what is READ and what is OURS.

- **The private server's real pager** (the reference screenshots' second bar): what its pages bind
  to, whether a key turns them, how many there are. Ours: separate slots 51.. (its page F5 is empty
  while the retail bar is full), labels F5.., arrows only, no key.
- **Icon fade under Transparent.** The proxy draws the bottom bar's slot with that slot's own draw
  (`0x65fb00`); whether the proxy's alpha reaches the icon is not traced. Ours: the icons do not
  fade (the screenshots agree).
- **The 0x4009 help bubble's place.** `0x65fb90` re-places the help window beside the proxy with
  `0x776c00` (right + 8, flipped left at the screen edge, top + 8); ours uses HudPanels' bubble
  placement. The `+0x24(0xc4)` call in `0x776c00` is not identified.
- **The option window's close X** reaching vslot 43 is INFERRED; Escape and the option window are
  not read (here Escape leaves it open). The base directory of `SRExtQSOption.dat`
  (`DAT_0110f7d0+0x134`) and `0x65f580`'s per-byte offsets in the asm.
- **0 extra bars** can only be set (and undone) in `settings.cfg`; the count row lives in the extra
  bars' option window, retail's being kept exact.

### The inventory window (round 633) — **pages, purse colours, slot art, avatar view, preview built; these are left**

What round 633 read and built is in `docs/protocol/inventory_window.md`.

- ~~**Carrying an item across pages the way the client does.**~~ **Read in round 652**: the held
  icon's filter (`0x6523d0`) lets a click on a page tab through, so retail turns the page with a
  click while holding the item. Ours does the same since round 652 (the hover-turn is gone).
- **The selected tab's text flag 2** (`0x64cc30` → `0x8b44b0(0,2)` → the glyph mode in
  `0x8b39e0`). What it draws is not read, so nothing is drawn for it.
- **The preview's pose advances while hidden.** It no longer renders while hidden (round 633's
  review), but the idle is still stepped by World3D. Retail steps it only while shown
  (`vslot_012` `0x6ab6b0` tests `0xb8f530`).
- **The academy's rank and leader marks.** Their show code is read (`0x6e9de3..0x6e9e6f`, the rank
  byte's art) but not built: this client keeps no academy data. The party's are built.
- **The party race mark always shows China's art**, because the server does not send the leader's
  race. **(round 709)** The original sends no race field either: the client takes the race from the
  member record's model id (the reference's `+0x9c` byte, `0x93f630`; `docs/protocol/party_gui.md`).
  Party lane C1 draws it from the retail member record.
- **The avatar skill strip** (`GDR_AVATAR_SKILL_WND`, ID 500) needs avatar items with its type
  bit. This server has none.
- **The retail starting inventory size** is a `_CHAR.InventorySize` database default that neither
  executable carries. `-inventory-size` 96 is ours. The engine's growth caps (77, or 99 with the
  quest, counting 13 equipment slots) mean retail never fills the third page by its own means.
- **The exchange window's gold boxes** are coloured and filled from the trade events. The
  exchange window itself is still not opened by a trade (World3D's debug trade labels do that
  work).

### The icon on the cursor (round 652) — **click up, click down, for every icon window; these are left**

What round 652 read and built is in `docs/protocol/held_icon.md`.

- ~~Honour the clicked slot on an unequip~~ -- **decided: the original's rule.** Retail's server
  puts an unequipped item in the first free slot (`DetachEquipItem` `0x5258c6`); the user chose
  "Match original", so ours does too. The client still sends the clicked slot, as retail's does.
- **The stack split.** Shift+click on a stack opens retail's split box (`0x6b3fa0`); its OK moves
  the amount into the first empty slot (`0x6b62d0`). Not built: our move op has no quantity.
- **Ctrl+click quick-sell / quick-store** (`0x680fa0`'s Ctrl branch). Not built; a click now picks
  the item up whatever window is open, as retail's does.
- **The ground drop.** Retail asks `UIIT_MSG_DROP_WARNING_1/2` and sends 0x7034 type 7; our server
  has no player drop, so a bag item put down on the world does nothing.
- **Warehouse slots.** Retail's deposit and withdraw name the target slot (types 2 and 3); ours
  carry none, so the server places them, and warehouse-to-warehouse moves (type 1) do nothing.
- **A worn item on the quick slot bar** (CIFUnderBar takes kind 0x47). Nothing happens.
- **A cancelled quick slot.** Retail's bar probably removes a quick slot let go with the right
  button (`CIFUnderBar::vslot_026` clears the slot when `+0x3b1` is set; the flag's meaning is
  INFERRED). Ours keeps it on the bar.
- **When retail lets go on its own** (death, zone change, the source window closing, the slot
  changing) is not read; ours lets go in all of them (OURS).
- **The slot left behind** is dimmed (OURS); how retail draws it while its icon is on the cursor
  is not read.

### Invisible walls on objects (round 644) — **the bridge walls fixed; these are left**

Round 644 made the on-object walk go cell by cell, as the client's does, and loads each object's
one navigation mesh (the `.bsr` header word 0x28). The Black Robber Den's four bridges and the
Temple of fertility's two cross end to end; Hotan's four were already walkable (their problem is
drawing, round 643). Left:
- **A click whose ray lies exactly in a heightfield grid plane finds no ground and is dropped**
  (pre-existing; the release review, 2026-09-30, MEASURED). `_ground_point_at` does not use round
  572's grid-line workaround: at the den's south bridge, x = 980 = 49 x 20 with yaw 0, every
  centre-column click after the first found no ground on any layer, and the player stood still --
  round 644's live walk read that as the clicks running out. A real player needs a camera ray exactly
  in a grid plane, rare but possible from spots on the grid (Jangan's spawn z 1020 = 51 x 20). Fix:
  nudge the ray off the grid, or fall back to `TerrainCollision`'s method.
- **The Temple of fertility bridge's navmesh has 39 of 139 cells with nothing drawn over or under
  them** (the release review, MEASURED from the drawn triangles, the same on every placement; the
  terrain is 141-393 below). Either the model's navmesh is walkable over a gap, or a drawn piece is
  dropped. OPEN. The den's, Bijeokdan's and Hotan's bridges put every walkable cell on the drawn
  deck (the den's other cells are its pier feet).
- **`.cpd` compound objects get no navigation mesh.** 105 entries of the navigation index; the
  client loads them through `MapLoader::FUN_0042bc00` (not read). Where one is placed a player
  walks through it.
- **The mover's cell is inferred, not carried** (`NavGraph._start_cells`). The client keeps a cell
  pointer in the position; carrying it (`StepResult`, World3D's `_nav_footing`) would remove the
  inference and the three guards it needs (a walk must end in its cell; the fallback stays at the
  mover's level, `LEVEL_REACH`; an entry landing outside every cell starts from the nearest one),
  each pinned in `nav_graph_test`'s `_inferred_cell_guards`.
- **A walk step on Hotan's castle costs about 9 ms at worst** (the round 644 review's
  measurement; `oas_hot_c1_castle`, 985 cells). It predates round 644: every step on an object scans all
  of its cells three times (`step_tracked`'s footing check and final height, both
  `_surface_near`, and `_cells_under` for the walk's start cell), and the castle is the largest mesh a player walks on. No fix
  needed yet; the cure is the same as above -- carry the cell -- or a per-object cell grid like
  the one the file already stores for edges (`RTNavMeshObj::FUN_00448540`).
- **A landing inside a sealed object footprint holds the player there.** 105/80 local
  (1892.2, 649.9) is inside `ruin_takla_tent05_01[45]` (10 outline edges, all `0x03`); the
  footing settles on the tent (its floor is 0.68 below the terrain there, inside
  `SURFACE_REACH_UP`), and the client's walk lets no one out of an all-`0x03` outline (READ,
  `collide_mode` is 1 on every walk). How the real client settles the footing for a position
  that arrives inside such a footprint is not read.
- **Linked edges (`0x08`)** still hand over by position (`_seam_object_at`), not through the
  `.nvm` link table the per-instance test reads (`RTNavMeshTerrain::FUN_00404060`, instance
  `+0xa0`). Hotan's north bridge and the temple bridges end in such edges and walk; not measured
  elsewhere.
- **Duplicate navmesh files.** Data.pk2 carries a second set of `nv_*.nvm` names repeating other
  files' placements with their own region ids (`nv_16b7` repeats `nv_5b93`'s bridge). What the
  client does with them is not read.
- **The footing was re-settled every frame for 10 frames** of the live Hotan run (GM `/speed 4`,
  91/135 local z 340-370, NAV ticks 849-858): the player was found more than
  `NAV_FOOTING_RESETTLE_DISTANCE` (1.0) from where the walk left it, so something else moved it
  between frames. The walk carried on; the cause is not chased.

### Seasonal event decorations — **hidden by default (round 583)**
The user decided on 2026-09-26 that early testing gets no seasonal decorations. Christmas,
Halloween, the China open-beta (OBT) event set and the summer festival set are left out of every
region's objects before any model is read (`SeasonalObjects`; `World3D._objects_prepare`). Each set
comes back on its own with `OPENSRO_SEASONAL=christmas,halloween,obt,summer` (any subset), or with
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
- **The `.o2` skip bit** (below, "`.o2` list semantics"): tested since round 643, so the 1,000
  records retail does not build are not drawn either. None of them is seasonal.

### Buffs on the server (skills epic, round 616) — **started: the book, Grass Walk's speed, cancel, Ghost Walk**
The server starts an action-kind-3 cast as a record in the caster's book, ends it at its time or
on cancel, and moves the caster for a Ghost Walk; the wire and every rule's source are in
`docs/protocol/skill_buffs.md`. opensro-01 needs the skills CSV re-exported and re-imported
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
- [x] **Skill body animations from skillaniset2 for every cast -- round 785.** `SkillDeco` runs
      retail's decoration (`FUN_00a54f00` / `FUN_00a534d0` / `FUN_00a52fe0`): the record's READY,
      WAIT and SHOT clips in its AniGroup, the per-cast pick (`+0xe4` = rand()), effect groups on the
      clips' hit events, hits at the DMG groups. The clip-name route and the weapon-swing stand-in
      are gone. MEASURED: every clip the China (464) and Europe (399) records ask for resolves in
      the bodies (`tools/probe_skill_deco_coverage.gd`). Still OPEN: the order READY and WAIT show
      in (retail starts WAIT first, READY over it -- here READY then the WAIT loop); the Hide
      Weapon column. (The skill window's re-use sweep, slot kind 0x49, was built in round 786 --
      `docs/protocol/skill_reuse_display.md`.)
- [x] **The recast rule's other branches** (round 636): all of FUN_0059d870 read and built -- the
      `dttp` and `efr` kind-2 (`+0x290`) branches, and the book's state bit set that Action_Overlap
      and `ovl2` fill (`SkillBook::SetGroupBits` 0x59dc00 / `FUN_0059db10`). Fire Protection no longer
      stacks; a second Grass Walk variant is refused 0x300c while one runs, as retail refuses it. The
      whole table is driven by `TestRecastRuleCensus` (`OPENSRO_SKILLS_CSV`). Still open:
      - the `lnks` path `FUN_0059dc80` is built (round 636's review and its follow-up: the gate's
        call for the 32 trap rows, the target test's for the 276 Target_Required 1 rows, through
        the caster's link entries). Still open there: retail's link record ending the target's
        record when it ends (a caster's death or logout leaves the target's buff running here);
        whether a trap's record ends with its object;
      - row 16's `hide` rule (the caster's vslot 0x100 state 4: which state is not read);
      - the running-action half of `FUN_0059db10` (a buff between its cast and its engage; OpenSRO
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
      - summons, mercenary scrolls and mounting while walled (retail refuses them; OpenSRO has
        none), and knockback/knockdown skipped on a walled target (OpenSRO's blows have none);
      - the attacker's-imbue term of the absorb test;
      - player-versus-player blows on a wall (OpenSRO has none);
      - which sounds retail plays for a kind-7 entry (the monster's blow sound is kept).
- [ ] **The duration extension** (`ctx+0x24`): `RPBU`/`STDU`/`DTDR` through `FUN_005a0330`'s map at
      book `+0x244` -- needs whatever files entries there (passive skills, INFERRED).
- [ ] **Retail's death and teleport rules for buffs** (ours: a death clears, a zone change keeps)
      and buffs restored at login (ctx+0xc bits 4|8). (The `skc` category end on a skill use is
      built, round 636.)
- [x] **Buffs on entering view -- round 646.** READ: retail's spawn record (0x3015 / the group
      spawn) carries the owner's buffs and the client attaches them to the new body with the start
      effect skipped (skill_buffs.md "Entering view"). OpenSRO's replay of `OpBuffStart`s after the
      body was already sent; the client now keeps them per connection (`BuffRoster`) and applies
      them whenever a body is built (world entry, a zone change's arrival, `OpEntityEntered`, a
      monster body), and a walled caster's warp landing is taken. Left open:
      - whether a retail teleport re-spawns the object for observers (0x3016 then 0x3015; the view
        wrappers `0x534340` / `0x5344b0` were not traced to the teleport code);
      - `OpEntityEntered` carrying the buff block itself, as retail's spawn does (a contract change;
        the separate replay stands in for it);
      - the `efta` creator byte (the Bard guards and dances, the Cleric group recovery pick a
        different effect variant for their caster, `FUN_00a53850` `+0xbc`), not on OpenSRO's wire;
      - the server's own arrival is still the centre region's middle (`worldmap.Landing`), and the
        client moves a Jangan arrival onto its spawn spot itself. Since the review, the server knows
        that spot (`worldmap.LandingSpot`, kept in step with `ZONE_SPAWN_LOCAL` by hand), but it
        does not land there;
      - view ranges: OpenSRO's server has none (a zone -- under `-single-frame` the whole world --
        is one broadcast bucket), so "walks out of view and back" does not occur yet.

### Berserk's look and mechanics (round 651) -- **the look, the sounds and the view built; the speed is OPEN**

Done (docs/protocol/berserk_look.md): every berserk body -- this player's and every other player's --
is drawn in the pulsing red of `SYSTEM_CH_HWANMODE`'s SCT_MAT (64,16,0 <-> 140,32,0 every 1 s),
grows to x1.1 over 1 s, carries the seven kept fire effects, and plays system_hwan_motion.efp +
hwanchange.wav at the start and system_hwan_disappear.efp + hwanreturn.wav at the end; the own
player's screen flashes white (alpha 128/255 in 0.2 s, back in 0.5 s). An arrival (world entry,
zone change, relog) is told who is berserk (`sendBodyModesInView`), and a body built later takes
it from NetClient's `body_modes`. Left:

- **The berserk move speed (and the defence cut): OPEN, the value.** READ: SetBodyMode(1) applies
  the `_RefHWANLevel` row of the PC's byte `+0x1c58` -- `'SPDU'` v sets params 23/24's scale slot to
  v % (undone to 100), `'DABR'` v takes v off params 174-177 -- and republishes the speed. The
  values are DB rows that neither Media.pk2 nor the box's server package carries. With a value,
  the change is: scale the run speed by v/100 on activation and back at the end, through the buff
  book's speed packet (as `/speed` does), and cut 174-177 in the damage pipeline.
- **The hwan level (`+0x764` client, `+0x1c58` server)**: `SYSTEM_CH_HWAN2MODE` (blue, x1.2) and the
  party link mode (`SYSTEM_CH_HWAN2LINK*`, extra byte 1) are not drawn; OpenSRO has no hwan level.
- **skillaniset2's SYSTEM_CH_HWANMODE row**: DamageEfp `hiteffect\hit_4_hwan.efp` and the weapon trail
  (160, 200/255/255/255, ONE, `mirage_texture_hwan.ddj`) while berserk -- where the client swaps
  them in is not traced; OpenSRO draws neither.
- **The teleport's first link.** That a zone change ends berserk rests on the re-entry chain
  (CharDataSavingCompleted -> 0x34b5 -> 0x34b6 -> the entry rebuilt, whose world entry sets body
  mode 2/4); the step from `GObjPC::HandleTeleportUse` (0x513590) to the char-data save is not traced.
- **The flash's starting RGB**: the weather manager's constructor colour (`_DAT_00de523c`) is not
  read; OpenSRO flashes white.
- **The look's light terms.** Retail replaces the material's diffuse and scales the ambient light
  by the pulse colour (c11/c10/c14); OpenSRO's one albedo stands for both (INFERRED mapping).

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
  AddHwanCount -- INFERRED a movement stop (it may send `0xB023`); no OpenSRO item use stops
  movement. Read what `0xB023` carries and what `+0x4c0` tests before mirroring it.
- **Other composite kinds** (UIU1 of a TypeID4-4 item, BCS1, BFI1, PSU1, UQL1, USL1, USU1) are
  refused; only the Energy of life's UIL1 + 0x706874 UIU1 is modelled. UIL1's "P" flag and the
  0x3161 refill (`0x653a40`) are read but unused by any modelled row.
- **CIFCompositeItemWnd's resize** for several buttons and a zero-count button's look
  (`UI_SILKMALL::FUN_00655ec0`) are not recovered; ours disables it.
- **Quest items 5921/10491**: the use path's quest gates are item-agnostic -- `0x185f` is
  `CGObjPC::QB_IsBlocked(8)` over a quest-script block mask (`pc+0x217c`), and the event-0xc
  listener list (`FUN_0063d4a0`/`FUN_0063d190`) can veto -- OpenSRO has neither state, so
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
- **The flight of AT_MOV_\* rows** (projectiles): round 785 flies them from the caster's StartBone
  to the target's TargetBone at the mean of MovTypeSpeed's last two values (INFERRED), the DMG
  row's hit landing on arrival. Still OPEN: the mover itself (MOV_UPR's arc, MOV_ROUND,
  MOV_PIERCE, the first value), and the Act Option column (Ghost Walk's READY row carries
  `true,0,0,10,1000,false`; the afterimages' look and life are OURS).
- **The skill phase clips -- DONE (round 785, SkillDeco).** The note below is round 620's.
  Retail advances READY → WAIT → SHOT on each phase clip's end, and
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

- **Tree sway — done in round 645.** Trees, reeds, tentacles (the Tarim thorn vines and the
  Taklamakan pits) and the other skeletal map models play their `default` type-0 clip as retail
  does: 144 models, 2,275 placements. See the next section.
- **MTRL mod details:**
  - its animated colour (the keyframes) replaces the layer's in retail, and that is not drawn;
  - the TEXTUREFACTOR argument is taken as white;
  - D3DBLEND pairs other than mix, add and multiply are drawn as mix.
- **Env-map reflection:** the mod's own texture stages are not drawn; only its alpha rule is.
- **Unread flag bits:** `0x40`, `0x100` and `0x2000` are not read. `0x4` (specular) and `0x8`
  (lighting off) are read but not drawn.
- **Mod sets:** only the always-on `ambient` set is applied; clip-bound sets are not.

### Map objects that move (round 645): the skeletal clips play as retail plays them. These are left:

- **The alpha fade.** Retail fades an animated (and every list-2) object in and out over 255/512 s
  at the 2,020 edge (`SWorld::FUN_00a38a50`). The client switches it.
- **2,020 for still scenery.** Retail's fade state applies to every list-2 object, not only the
  animated ones: still scenery also ends at `dist - radius < 2020` from the camera. That is a
  visibility change for the loading lane; the client applies it to animated objects only.
- **The cost (round 647).** Clips that start together at the same clock now share one pose, and
  the driver's per-sector bounds and a held camera leave it almost nothing to do; the saving and the
  split are in WORLD_ISSUES, round 647. What is left:
  - **Drawing the skinned instances.** At the reeds (98/157 at 900, 900, 1280×720) the animated
    objects still cost +4.94 ms over `OPENSRO_NO_MAP_ANIM=1` (11.11 against 6.17 ms), with 40
    reeds on one pose. Pausing every pose changes nothing (+0.20, the drift); drawing them unskinned
    takes 4.70 ms off and the GPU time from 3.79 to 1.50 ms at the same 1,013 draws. So it is Godot
    4.2's GL Compatibility cost of drawing skinned instances, pose or no pose (MEASURED; that the
    per-instance transform-feedback buffers are why is INFERRED). Godot 4.2 cannot draw one skinned
    result at several transforms, so no exact cut is known. At the Jangan spawn what is left is
    +0.60 ms.
  - **Shared poses fragment in play.** Retail pauses each object on its own
    (`SWorld::FUN_00a38a50`, READ), so an object crossing the 2,020 edge alone leaves its group
    for good, and a group never re-forms (a start never joins a running pose). A player walking
    away from the spawn ends with 15 clips running on 14 poses (round 647's walk). Also a moving
    camera still view-tests every in-range sector each tick (74–79 at Jangan, 172–301 µs).
- **The per-sector view test can hide an object whose mesh reaches into view.** The sector's
  320-unit cell is tested as a sphere against the frustum (OURS: retail rasterises the frustum onto
  the sector grid, `Map::FUN_00a2b370`, READ), and an object in a sector out of view keeps its
  drawn state but stops. The integration review of rounds 641-646 found
  `Obj_oas_tarim_thorng01_01_7` at 95/147 local (700, 800) reporting visible false while in the
  frustum (MEASURED there; not re-measured in round 647). The per-sector rule is retail's (READ);
  the sphere standing in for the sector's footprint is OURS, and whether retail's rasterised
  footprint would cover that object is OPEN.
- **The pose pool is never trimmed within a zone** (the release review, 2026-09-30, MEASURED).
  `Driver._pool` is keyed by the Animation, but a region release frees that region's templates, so
  their Animations never come back: over a 12-hop region tour the pose nodes grew 19 -> 60 (32 idle
  at the end) and the pooled clip keys 1 -> 28, holding the freed templates' Animations and skeleton
  copies until the next zone change (which does reset them). Fix: key the pool by model path, drop a
  clip's pooled nodes when `ObjectTemplateCache.release_region` frees its template, or free nodes
  idle for N ticks. Also unpinned by any test: pooling a released group node only at the next tick
  (a mutation that pools it in the same tick passes ALL PASS).
- **Skin binds: the file's, or composed (round 648).** Retail's skin matrix is the `.bsk`'s own
  stored inverse bind times the bone's animated world (READ, `RTSkeleton::FUN_00c49f20`;
  BSK_FORMAT.md, "How the client skins"). This client binds to the inverse of the rest it composes
  from the locals (OURS). The two agree only where the file's world binds match the composed rest:
  855 of Data.pk2's 1,208 skeletons have a bone more than 0.05 units or 1 degree apart (MEASURED,
  `client/tools/census_bsk_bind.gd`). Round 648 fixed the roots of the 11 whose root is unset (the
  reeds' streaks, the Tarim rope bridge, thief_boss and others); after it, 850 skeletons are still
  off (round 648's review), among them `Spine_Base` in thief_boss, flame_spirit, elemental,
  penon_die and uruchidragon (8-41 units, 130-180 degrees). Whether those draw visibly off, and whether
  moving to the stored binds is safe for characters (the "two spaces" history in BSK_FORMAT.md), is
  OPEN. The skeleton scale at skeleton+0xa4 (`FUN_00c4bcb0`) is 1.0 on map objects (READ, round
  721's review: constructor `FUN_00c513c0` `fld1`; the map never calls `CCompChar` slot 9). Not
  read: who sets a bone's `+0x84` bit 2, whose palette `RTSkeleton::FUN_00c4a180` scales by `+0x88`.
  - **Round 721 took the stored binds for MAP objects where they are only a root shift**
    (`Skeleton3DBuilder.consistent_stored_binds`). That fixed the Alexandria gate portal's rings,
    the quest teleporter, the demon altars and the fortress doors, and moved `arabianf_bujok03`
    from 481 to 8.7 off its mesh (BSK_FORMAT.md, round 721; `client/tools/probe_map_bind.gd`).
  - **Left (map objects):**
    - **8 unexplained models** -- `tre_willow03`, `tre_tree01_big`, `tre_bamboo04`,
      `oas_hot_tree_stone` and the four `demon_wall_deco*`. Their stored binds are not a root shift
      of their locals (the willow's chain is scaled by 1.793), and by our readers the client's rule
      would draw them off their meshes (the willow 58.4 units; table in BSK_FORMAT.md, round 721).
      The map's skeleton scale is 1.0, so nothing undoes it. Either retail draws them off, or one of
      our readers is wrong: settle against retail. They keep the composed bind (OURS) meanwhile;
    - `arabianf_bujok03`'s remaining 8.7.
- **Character path: the root mismatch, the portal's own case (round 721's review, MEASURED).**
  `census_bsk_bind.gd` finds sane roots that disagree with where their children's stored binds put
  them in **35 `mob`** skeletons, plus **313 `Item`**, **3 `COS`** and **3 `Artifact`** (and 14
  Bldg, 2 Dun, 2 Nature, 2 etc, 1 quest on the map path). On every monster `.bsr` with a finite
  root except `reflection_shield` and `ivy`, every clip keys the root where the binds put it, so the
  composed bind the character path still uses draws these monsters off where the original draws
  them, by the root shift (measured on the skeleton, not rendered; pre-existing):
  `mustafa` 50.17, `event_winter_whiteknight` 48.16, `baal_weapon` 32.62, `haroeris_t2` 14.76,
  `ghost_undine` 11.36, `jupiter` 6.71 (the rest in `docs/rounds/r721_review.md`, finding 3).
  Round 721's condition would take 52 of the 61 affected monster `.bsr`, but not `mustafa` /
  `mustafa_dark`, `reflection_shield`, or the NaN-rooted `venefica` / `flame_spirit` family; `ivy`
  keys at its stored local. Taking the stored binds on the character path is the next step.
- **`cj_ferry_boat_old`.** Its `.bsk` is a root with no other bone, which `BskReader` refuses
  (1 placement).
- **Rigid pieces of a skeletal object.** 20 animated models, such as `bagh_city_portal` and the
  Tarim rope bridges, have unskinned pieces that stay put. Whether retail hangs them on a bone is
  OPEN; mesh+0x3c bit 0x400 is the lead.
- ~~**TEXANI sprite animation**~~ -- drawn since round 722 (docs/rounds/r722.md).
- **Cloth**, the DYVERTEX/DYJOINT/DYLATTICE mods (143 models, 550 placements: tents, sails, banners,
  including the Taklamakan `ruin_takla_tent*`). Not read.
- **`.o2` list +0x24** objects update only in the 9 nearest sectors at range 480. This client does
  not draw the list (round 75).
- **The view-distance option** does not exist here. It sets `DAT_00ec54b0` to 1,200 / 2,000 /
  2,500, which makes the animation and draw range 720 / 1,520 / 2,020; the client uses 2,020.

### Dense monster fields (round 664) — **built: retail's 3 x 3 message-block window on the server (READ); the clip tick once per rendered frame, sounds only within the core's 600 cull (READ), indexed posing, far bodies posed every 2nd/4th frame, quiet bodies tested every 2nd frame, the minimap once a frame; these are left**

- [ ] **The `crowd` gate site (2,500 monsters within 1,920 of the Jangan spawn) is over 16.7 ms.**
      Round 664 took it from 176 ms to about 25 (WORLD_ISSUES round 664 has the split); the Jangan
      scene alone is 9.6. What is left a frame: the clip tick's walk over every animated body
      (about 4 ms at 2,500, GDScript's cost per body), the pose and the renderer's re-skin of the
      ~46 bodies posed (about 2 + 5 ms), the minimap's walk over every body (1.7 ms). The next
      step is to stop walking the bodies nobody sees: an engine-side on-screen set
      (VisibleOnScreenNotifier3D) and a periodic pass for range and hearing, or AnimationPlayer
      clips (C++) for monsters as MapAnimation plays map objects. With the READ window a server
      no longer sends a player a crowd like this one (the live check in WORLD_ISSUES round 664).
- [ ] **Retail's mesh LOD is not drawn.** sro_client passes the object's distance / 800
      (0x9c4c05) to the model's draw when graphics option 0x17 is on, and the draw picks an index
      set (`pFDB->Indices[iLOD]`). Which files carry the LOD index sets, and what option 0x17 is
      in the options window, are not read.
- [ ] **The animation LOD is OURS** (`MonsterCrowd.pose_interval`: every frame within 300 of the
      camera, every 2nd to 900, every 4th to 2,020). Retail's own rule for character animation
      updates is unread.
- [ ] **Object regions (dungeons) and far-sent objects.** The READ window is the field's
      (`CRgnTerrain`'s 6 x 6 blocks). The `CMsgBlockObject` blocks of `CRgnObject` regions and any
      object sent from farther (uniques, structures) were not read.
- [ ] **Players and ground items still use the zone-wide window** (round 664 review, L2).
      Retail's block insert (slot 2, 0x534340) handles every object kind, so its players and
      ground items use the same 3 x 3 blocks as monsters. Ours still send them zone-wide
      (`othersInZoneLocked` in server/internal/world/world.go:154, `EntitiesInZone` in
      session/grounditem.go:283,500), which under -single-frame is the whole world. A player
      can see another player fighting 2,000 away but not the monster, or a drop without the
      monster that dropped it. Move players and ground items onto the block window.
- [ ] **After a hitch a one-shot clip can start partway through** (round 664 review, L1,
      PLAUSIBLE, cosmetic). On a frame that runs several physics steps, `TickGate` holds the
      steps' time for the next frame, and a one-shot started meanwhile records its start before
      that time is added (World3D.gd ~13430), so it begins up to ~117 ms into its clip.
- [ ] **Detection can reach past the window's 320 minimum** (round 664 review, L5, PLAUSIBLE;
      the same geometry as retail). A monster with a very large BCRadius (about 130+ at the
      x1.4 reach) sleeping 320-640 away on its block's far side cannot acquire a player its
      radius covers. BCRadius data was not checked.

### Many monsters (round 655) — **built: species templates, budgeted builds, posing culled, bodies only in loaded regions, no list per hit; these are left**

The server will send hundreds of monsters per view (the densest 5 x 5-region window of the field
spawns holds about 500). Round 655 made the client draw them: one template per species model
(`MonsterDraw.Templates`), bodies built a frame budget at a time, clips posed only in range and in
view, no body outside the loaded regions, and no full monster list after a hit, a kill or an own
attack result. `OPENSRO_QA_MOBS=<N>` and the perf gate's `mobs` site measure it.

- [ ] **A species seen for the first time is still assembled on the main thread**: 4-14 ms for most
      Chinese field species, 133 ms for the first (cold archive) and 791 ms for
      `MOB_CH_TIGERWOMAN` (69 bones, 7 pieces; MEASURED, `probe_monster_build.gd`). The budget
      lets one through per frame, so each new species is one freeze of that length. Next: prepare
      the `.bsr`/`.bsk`/`.bms`/texture reads on a WorkerThreadPool task (the objects job's pattern,
      rounds 565-566) and commit on the main thread.
- [ ] **The pose range is OURS**: the map objects' READ range (2020 from the camera) applied to
      characters. Retail's render slot for a monster (`CICMonster` slot 10, 0x9d20d0) has no
      distance test and the object slot `FUN_009c4aa0` only a frustum test; the entity manager's
      per-frame tick was not read. Monster models out of range are hidden (OURS, as map objects
      are); NPCs out of range are drawn, not posed. A capsule monster or one with no idle clip is
      never hidden (the rule runs in the idle tick).
- [ ] **Respawns on a server without the spawn push.** With no list per hit, a respawn appears
      through OpMonsterSpawned (`-monster-spawn-push`, off by default, on on the public server),
      a move for an unknown monster (`-monster-ai`, rate-limited list), a zone change, a GM
      refresh, or -- until a spawn push has been seen -- one list after a death has played out,
      at most every 10 s (OURS). A respawn with no death after it waits. The AOI lane's enter
      pushes remove the limit.
- [ ] **A monster walking out of the loaded regions keeps its body** until its region unloads
      (the region gate runs when a cell loads or unloads, not per step).
- [ ] **Scale (characterdata col 48)** is not applied to any monster (see the `_CLON` item above).

### Characters fade into existence (round 676) — **built: monsters and other players fade in over 2.0 s, linear, as retail's CIDecoAppear (READ; docs/protocol/appear_fade.md); these are left**

- [x] **The despawn fade-out** (round 677): built. A monster that leaves the area or enters a
      town (`OpMonsterLeft`), another player who leaves, a ground item taken away, and a dead
      monster once its corpse's DecayTime has run fade out over 1.5 s (`CIDecoDisappear`, READ)
      and free themselves; docs/protocol/appear_fade.md. Left from it:
  - [ ] **The corpse's time is the client's.** Retail's server keeps a dead monster in life
        state 2 until `CGObj::Update` (0x484d10) finds its dead time past its DecayTime
        (characterdata column 13; 5 s for most monsters), then deletes it and sends `0x3016`
        (READ). OpenSRO's server drops the monster at its death and sends nothing more, so the
        client holds the corpse for the species' DecayTime from when it learns of the death and
        fades it then (OURS). A server-sent removal would put it on the server's clock.
  - [ ] **The CICMonster +0x7b0 branch** (a 0 s fade-out for the monster whose ref is the id at
        `DAT_00ef1a7c`, CGame+0x4f8[3] looked up by `FUN_0093f710`): which monster that is, not read.
  - [ ] **What a click on a fading body does.** Retail's pick (`FUN_0078ee20`) walks the
        CIGIDObject class list, which keeps the object until it is deleted, so a fading body can
        still be hit; its id is 0 by then (`FUN_009c3270`). Ours drops the click collider at the
        start (OURS).
  - [ ] **Whether retail's mover runs on during the fade.** Ours stops a walking body where it
        is and stands it (OURS).
  - [ ] **A ground item's name** while it fades: ours hides it (OURS); not read. And that a
        pickup reaches the client as `0x3016` is INFERRED (the item leaves its block as any
        object does; the pickup path was not followed).
  - [ ] **CICUser modes 4/6/7** leave at once in retail (0x9daf10 passes 1); this client has no
        such modes for other players yet.
- [ ] **Shadow and effects** are not faded. Retail writes the alpha to the model's compound
      (`CCompChar` +0x4c) only; who reads it in the draw is not read. (The name plate stays at
      full alpha in retail: `FUN_008b4d90(point, 0xff)`, READ in round 673.)
- [ ] **NPCs, guards and pets** fade in retail (the same `FUN_009d17e0` for CICNPC, CICGuard and
      CICCos); ours are built from the map's data at region load (NPCs) or not drawn yet, and
      appear at once.
- [ ] **A cold driver shader cache hitches on a monster's opaque material** (130-240 ms the first
      time a material kind is drawn, MEASURED in round 676's review; the base pays it as the
      monster appears, this client as its fade ends). The fade twins are warmed while the world
      loads (`AppearFade.warm`); the opaque monster shaders could be warmed the same way. An MTRL
      mod shader first made after loading still compiles its fade twin on first sight.
- [ ] **The player's own character** is not faded. `CICPlayer::vslot_009` drives its alpha every
      frame from its own interpolator (+0x2068, `FUN_009d4e80`); whether a spawn fade shows is
      not settled.
- [ ] **A material with no fade twin pops in** (`AppearFade.Fades.unfadable`). Every monster
      surface has one today (`measure_appear_fade.gd --census`); a new shader needs its twin in
      `ObjectLoader.appear_fade_shader`.

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
- ~~**Depth precision (round 648).**~~ **DONE, round 729:** the world camera's near is now retail's 1.0
  (`CameraPlanes`); the camera arm's radius-3 sphere keeps colliders outside the near plane's
  corners (`camera_near_test.gd`), and building layers stopped z-fighting (docs/rounds/r729.md).
  The original note: Retail's world camera has near 1.0, far the view distance
  (3,500 by default) and a 24-bit depth buffer (READ; MAPM_FORMAT.md, "Depth"). This client's camera
  keeps Godot's default near 0.05, with far 1920 x (radius + 1) x 2, which gives about 20 times less
  depth precision at any distance. Water that lies under the ground, hidden only by the depth test,
  is a few hundred to a few thousand square units a region (MEASURED, `waterat -region y/x -hidden`:
  the ferry region 90/143 has 45, with 25 of them within 0.1 of the plane). So this was not the
  user's Donwhang report (the reeds were), but it is a real difference. Moving the near plane to 1.0
  also moves where the camera clips close geometry, so it needs the camera lane's collision margins
  checked first.
- **Walking under water is authentic** (the user, 2026-09-28): it happens in the original game too.
  Leave movement alone.

### Scenery still off the ground — **re-measure after round 643**
83 objects fell to 60 once each `.o2` entry was assigned to the region whose heightmap explains
its height (eighty-fifth round). Round 643 replaced that height test with the record's own owner
field (bytes 28-29, READ): every object now stands in its owner region's frame. The 60 have not
been re-counted under the new rule (`OPENSRO_QA_FLOAT`).

### The `cj_s` city wall's copies — **one object since round 643**
The wall is one key (owner 97/168), listed by five regions; `World3D._placed_objects` places it
once, in its owner's frame, whichever region commits first. The luck the eighty-sixth round
recorded is no longer involved.

### Objects you could walk inside — **fixed** (hundred-and-twenty-third round)
It was 232 objects world-wide, not the eight Jangan ones the count named. The graph resolved an
object by its **first** mesh only, and a building's walkable surface is one piece among many in
alphabetical order — `cj_luxu_floor.bms` is the fourth of twelve. All of an object's meshes are
read and merged now. Every region around Jangan places 100% of its objects, and `OPENSRO_QA_SCAN`
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

### `.o2` list semantics — **what the world builds is settled (round 643); what the lists mean is not**
Round 643 read that the loader builds `lists[1]` and `lists[2]` alike, one object per key, and
measured that a record's position is in its owner region's frame; the world now does the same
(`World3D.region_placements`, `_placed_objects`; MAPO2_FORMAT.md, "Round 643"). The old reading,
"list 2 is a region's own objects and the others are cross-references", was wrong: 52,366 of the
75,564 objects are in `lists[1]` alone, Hotan's stable and bridges and the Fertility Temple among
them. Left open:
- **What separates the two lists.** A key is in one or the other (7 of 75,564 in both). The
  loader does one thing more for a `lists[1]` record whose object has +0x1a bit 0 set (a link
  through a map at +0x247b: a portal or warp candidate), not read further.
- **The key registry's holder is the first region to commit.** An object moves to another lister
  when its holder streams out (`_release_region_objects`); retail keeps a refcount instead. A
  listed object whose last loaded lister streams out goes with it, as in retail.
- **20 models the map places are not in Data.pk2** (222 placements: `res\dun\asiam\r2_cv\field\`
  ruins and statues, `st_part01`..`03`, `pha_crypt`, `res\testsize\aa.bsr`): nothing to load.
- **`oas_hot_etc03`** (one piece of `oas_hot_etc`, Hotan): an MTRL mod tests at 128 and its DXT3
  texture's alpha is below 128 everywhere, so it draws nothing here. Whether its stage-0 alpha op
  reads the texture (the MTRL animated colour is still open, round 625) decides whether retail
  draws it.
- **Two regions with a populated `.o` and no `.o2`** (51/84, 93/211) draw no objects, as retail.
- **force_addobject.txt's fortress state** (round 643's review; MAPO2_FORMAT.md, "Round 643's
  review"). Every loaded row is drawn (32 fortress flags, 3 Bijeokdan bridges). Whether a fortress
  state hides a row is OPEN: the world's callback (`LAB_004ff8c0`) was read up to its vtable
  calls. The flags wear no guild or alliance emblem (OURS); the emblem needs the fortress
  owner, which the server does not send yet.

Round 583 read three record fields in the loader (`FUN_00a361b0`;
[protocol/MAPO2_FORMAT.md](protocol/MAPO2_FORMAT.md), "Corrected (round 583)"). Bytes 22-23 are
the object's uid and bytes 28-29 its owner region, and together they are the key the loader files
the object under. Byte 27 bit 0 is a skip bit: in `lists[1]` and `lists[2]` a record with the bit
set is not built. `World3D` tests the bit since round 643, as the loader does, so the 240
`lists[2]` records (Baghdad's `bagh_masin_lightwall` (120), guild barricades (48), Baghdad's event
barricades (46), Petra's fires (24) and `piety_golddoor` (2)) and 760 `lists[1]` ones are no
longer drawn. **Open**: what does put them in the world (a siege, an event) is not traced.

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
