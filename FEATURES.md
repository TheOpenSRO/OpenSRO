# Current Features Supported

What OpenSRO (server and client) handles today, what works in part, and what is not built yet. Client **v0.1.607** plus what is merged on `dev`; updated 2026-10-29.

**Legend:** ✅ Supported · 🟡 Partial · 🔧 In progress · ❌ Not yet · 🆕 merged on `dev`, ships in the next release

## Summary

| Area | ✅ | 🟡 | 🔧 | ❌ | Total |
|---|--:|--:|--:|--:|--:|
| [Account & login](#account--login) | 14 |  |  |  | 14 |
| [World & movement](#world--movement) | 16 | 3 |  | 2 | 21 |
| [NPCs](#npcs) | 8 | 3 |  |  | 11 |
| [Monsters](#monsters) | 14 | 3 |  |  | 17 |
| [Combat](#combat) | 11 | 4 |  | 3 | 18 |
| [Skills & masteries](#skills--masteries) | 7 | 1 |  | 2 | 10 |
| [Items](#items) | 17 | 4 |  | 3 | 24 |
| [Economy](#economy) | 8 |  |  | 2 | 10 |
| [Social](#social) | 12 | 4 |  | 4 | 20 |
| [Job / trade](#job--trade) | 6 |  |  |  | 6 |
| [Pets & mounts](#pets--mounts) | 5 |  |  |  | 5 |
| [Events / special](#events--special) |  | 1 |  | 9 | 10 |
| [UI / HUD](#ui--hud) | 14 | 4 |  | 1 | 19 |
| [Graphics & effects](#graphics--effects) | 14 | 1 |  |  | 15 |
| [Audio](#audio) | 5 |  |  |  | 5 |
| [Server / ops](#server--ops) | 7 |  | 1 | 1 | 9 |
| [Plugins & customization](#plugins--customization) | 4 | 1 |  | 3 | 8 |
| [Bots](#bots) |  |  |  | 2 | 2 |
| [Client platforms](#client-platforms) | 6 | 1 |  |  | 7 |
| **All** | **165** | **30** | **1** | **33** | **229** |

## Biggest gaps

- No consignment
- No open-world PvP, fortress war or arena events
- Instanced dungeons (Job Temple, Pharaoh's tomb, Medusa) not available
- Guilds: no ranks, notice, storage, union requests or wars yet
- Players cannot drop items
- Friends: letters and the block list not done

## Notes

- Monster AI, aggro, battle and player death are server options (default off); the public server runs them on.
- The Test Items NPC is a server option (OPENSRO_TEST_ITEMS_NPC), off by default.

## Account & login

Retail login wire and messages, retail-style lobby, both races and every creatable body.

| Feature | Status | Notes |
|---|---|---|
| Login server | ✅ Supported | Single Go gateway on port 15779; optional TLS |
| Login messages | ✅ Supported | The original's refusals and texts: wrong password with attempts used, ban reason and unban date, already connected, full, inspection, IP limit; disconnect box |
| Server list | ✅ Supported | Named servers from setting/config.yaml with live population and state |
| Account registration | ✅ Supported | Register button on the login screen; no auto-create on first login |
| 3D title screen and intro | ✅ Supported | Retail intro flown over the world; operator can set logo, music, intro |
| Character select | ✅ Supported | Retail select screen on a 3D stage; four characters per account |
| Character create: China | ✅ Supported | All Chinese bodies with height and volume sliders |
| Character create: Europe | ✅ Supported | All European bodies and customisation controls |
| All 52 creatable bodies | ✅ Supported | Checked against the game's own character-creation table |
| Character delete and restore | ✅ Supported | 7-day delete delay, restore, automatic purge |
| Name checks | ✅ Supported | The original filter: AbuseFilter.txt word lists, allowed characters and SQL-word check, for characters and guilds |
| Retail login, both ways | ✅ Supported | The original client logs in to OpenSRO up to character select; our client logs in to original servers (image code, agent) and lists characters |
| Account bans | ✅ Supported | Timed or permanent blocks with reason and unban date; auto block after 3 wrong passwords; GM /block, /unblock, /blockinfo |
| Account PIN (Character Lock) | ✅ Supported | 4-digit PIN at character select, shuffled keypad, 30-minute lockout, remember this PC; operator can require it |

## World & movement

The whole retail world streamed from your own Map.pk2, with click-to-walk travel.

| Feature | Status | Notes |
|---|---|---|
| Terrain, objects and region streaming | ✅ Supported | Seamless world from Map.pk2; regions load off the main thread |
| Click-to-walk | ✅ Supported | Click the ground to walk; arrival lands exactly on the point |
| Sky-click run | ✅ Supported | Clicking sky or far ground runs on that heading until blocked |
| Keyboard (arrow keys) movement | ✅ Supported | Up runs where the character faces, Left/Right turn it on the spot (seated too); as in retail the server hears a turn in 45° steps and exactly on release |
| Trace (follow a player) | ✅ Supported | From the action window, a hotbar slot or the right-click player menu. Follows as the original server does: runs to just short of the player and keeps up, and stops when they die or move out of range, or when you sit, are stunned, trade, mount or click to walk |
| Walk/run toggle and sitting | ✅ Supported | Walk/run, sit and stand through the action window and keys; a click while seated stands up first, as retail |
| Movement animation | ✅ Supported | Retail blending: a run starts from its first frame and fades in, a stop lets the stride finish, 5 s battle stance, idle fidgets for players and NPCs, footprints in sand and snow |
| Collision | 🟡 Partial | Terrain and buildings on the game's own navigation mesh, on the client and now on the server too: walks and monsters stop at walls, wandering monsters turn back from them; compound objects, gates and doors, and dungeons on the server still to come |
| Dungeons: Donwhang Cave and Qin-Shi Tomb | ✅ Supported | All Qin-Shi floors and Donwhang Cave load, with dungeon minimaps |
| Instanced dungeons | ❌ Not yet | Job Temple, Pharaoh's tomb, Medusa rooms refused at the gate |
| Town teleport gates | ✅ Supported | Destinations listed in the gate's talk box; fee charged |
| Teleport NPCs (ferries, tunnels) | ✅ Supported | Ferry, boat and tunnel routes through NPC talk lines |
| Return scroll | ✅ Supported | Cast bar, then back to the recall point designated at a town NPC |
| Reverse return scroll | ✅ Supported | Last recall point, death point, or a point picked on the world map |
| Arrival guard | ✅ Supported | Hidden while loading after a teleport, then 6 s of protection |
| Saved position on logout | ✅ Supported | Server option, on for the public server; recall and death points always saved |
| Minimap | ✅ Supported | NPC, monster, player, party, quest NPC and unique signs; no pet or horse sign |
| World map | 🟡 Partial | Map, dungeon floors and city icons; guide list and sign tooltips missing |
| Time of day | ✅ Supported | Server clock and retail's day/night cycle: sky, light, fog, sun, moon and lens flare; lit windows, lanterns, street lights and night-only fires turn on from 20:00:01 to 03:59:59 game time, as retail; optional darker nights (Night Darkness) |
| Weather (rain, snow) | ❌ Not yet | No weather system yet |
| Fog and water | ✅ Supported | Retail fog planes; animated water with reflection option |
| Seasonal decorations | 🟡 Partial | Christmas, Halloween and others available but off by default |

## NPCs

Retail NPCs in their retail spots, with talk menus, shops, storage and quests.

| Feature | Status | Notes |
|---|---|---|
| NPC spawns and models | ✅ Supported | Every retail NPC position spawned with its own model; props such as the storage keepers' chests stand still beside them, as in the original |
| NPC facing | 🟡 Partial | 230 of 257 NPCs face their retail direction; 27 use a fallback |
| NPC talk window | ✅ Supported | Retail talk box titled with the NPC's name and service lines |
| NPC shops | ✅ Supported | Retail goods and prices; buy, sell, buyback, Ctrl+click quick-sell |
| Storage (warehouse) | ✅ Supported | Per-account items and gold with deposit fee |
| Repair NPCs | ✅ Supported | The original's flow: Repair All shows the cost in its own Yes/No box and mends worn gear and bag items alike; Repair turns the cursor into a hammer that mends the item you click; broken items pay their revive fee; each repaired item flashes and plays the repair sound |
| Quests | 🟡 Partial | 564 of 696 quests reachable, NPC quest marks; the original's talk pages (Accept/Refuse, OK closes the talk, the reward's "Quest completed." notice), party-only quests and their refusals; timed and job quests missing |
| Guild manager NPC | 🟡 Partial | Create, leave and disband (the master) with the original's confirm boxes; level-up, master hand-over and the other lines not done |
| Test Items NPC | ✅ Supported | Jangan NPC; free +12 full-blue gear, elixirs, stones; server option |
| Test Items NPC: level-101 Nova | ✅ Supported | Sells the unlocked level-101 Seal of Nova instead of level 111 |
| Test Items NPC: +12 full-blue listing | ✅ Supported | Store slots and tooltips show the +12 full-blue piece you get |

## Monsters

Every field nest of the game populated, with retail AI, uniques and drops.

| Feature | Status | Notes |
|---|---|---|
| Field spawns from nests | ✅ Supported | About 10,000 field spawn points placed from the game's nest data |
| Respawn timing | ✅ Supported | Each nest's own retail respawn window |
| Monster models and animations | ✅ Supported | Retail models with idle, walk, attack and death clips; each species' own skin (clones, champions), mounts and platforms (Tiger Girl's tiger, Uruchi's dragon, Ishade's ice), death models, and the particles their models carry |
| Wander, chase and leash | ✅ Supported | Idle wander, battle chase, return home when pulled too far; a monster stands through each swing before it follows, re-aims its chase as the original does and backs off a target it stands inside; a chaser that comes within reach between server ticks swings, as the original's every-frame reach test does |
| Aggro on sight | ✅ Supported | Aggressive monsters notice nearby players; detection radius is an estimate |
| Linked aggro | ✅ Supported | Nearby monsters join when a party member attacks, as retail |
| Threat / hate retarget | 🟡 Partial | Threat is tracked but monsters stay on their first attacker |
| Monster skills | 🟡 Partial | Monsters cast skills and statuses with their retail effects (ice pillars, ice stars, thrown stones); area hits and knockback on players missing |
| Field uniques | ✅ Supported | Tiger Girl, Uruchi, Isyutaru, Yarkan, Shaitan, Cerberus, Ivy, with summons |
| Unique rotation | ✅ Supported | Uniques respawn on retail windows across their retail spawn spots |
| Unique notices | ✅ Supported | Server-wide 'appeared' and 'killed by' notices |
| Unique minimap sign | ✅ Supported | Uniques show their own sign on the minimap |
| Champions, giants, elites | ✅ Supported | Retail rank roll and HP multipliers; rank shown in target window |
| Party monsters | ✅ Supported | Party-only monsters with x10 HP and party label |
| Dungeon monsters | 🟡 Partial | Served dungeons partly populated; many dungeon spawns not placed yet |
| Item and gold drops | ✅ Supported | Retail drop tables if imported; killer owns loot for 30 s |
| EXP and SP rewards | ✅ Supported | Retail damage-share formulas with level-difference scaling |

## Combat

Retail auto-attack, skills, statuses and berserk; PvP limited to duels and job PvP.

| Feature | Status | Notes |
|---|---|---|
| Auto-attack | ✅ Supported | One click fights to the death; server-checked weapon reach |
| Skill attacks | ✅ Supported | Retail skill damage and cast animations; chains play link by link |
| Self and party buffs | ✅ Supported | Buff bar with timers, right-click cancel; debuffs shown on monsters |
| Status effects | ✅ Supported | Freeze, burn, poison, shock, stun, sleep, root, fear, bleed, curses and more |
| Imbues and passives | ✅ Supported | Imbues add elemental damage; passive skills apply their stats |
| Passive skills | ✅ Supported | Passives apply their stats |
| Heals | 🟡 Partial | Flat, percent and area heals; weapon-scaled cleric heals missing |
| Critical, block, evade | 🟡 Partial | Player rolls retail; monster hit and evade rates are estimates |
| Damage numbers | ✅ Supported | Retail damage text art, colours, critical/block/resist and motion |
| Knockdown and knockback | 🟡 Partial | Players can knock monsters down/back; monsters cannot do it to players |
| Death and resurrection | ✅ Supported | Dead state; revive in town, or on the spot up to level 10 |
| Resurrection skill | 🟡 Partial | Server supports it; client has no accept box yet |
| Resurrection scroll | ❌ Not yet | Scroll item refused |
| Duels | ✅ Supported | Challenge, accept and fight 1v1 |
| PK / murder / PvP cape | ❌ Not yet | No open-world PvP yet (job PvP is under Job / trade) |
| Berserk (Hwan) | ✅ Supported | Hwan orbs fill from kills; berserk mode with its look and sounds |
| Berserk potions | ✅ Supported | Berserk potion and Energy of Life work |
| Stealth, detection, transforms, traps | ❌ Not yet | These skill types do nothing yet |

## Skills & masteries

Retail skill window and mastery economy for both races.

| Feature | Status | Notes |
|---|---|---|
| Skill window | ✅ Supported | Retail layout with weapon/force tabs, mastery tabs and practice box |
| Mastery leveling | ✅ Supported | Spend SP to raise masteries; China 330 total, Europe 2x level |
| Learning skills | ✅ Supported | Learn and level skills with SP earned from kills |
| Chinese masteries | ✅ Supported | All seven Chinese masteries learnable and castable |
| European masteries | 🟡 Partial | Learn and cast; stances, stealth and weapon-scaled heals incomplete |
| Skill tooltips | ✅ Supported | Retail blue tooltip window |
| Skill cooldowns | ✅ Supported | Server-enforced, including shared cooldown groups |
| Cooldown overlay | ✅ Supported | Full-icon sweep on hotbar and skill window; hotbar slots also count down the time left with the original's digit images (seconds in white, minutes in yellow, hours in blue) |
| Buffs kept over relog | ❌ Not yet | Buffs end on logout |
| Skill withdraw | ❌ Not yet | Lowering masteries and forgetting skills not available |

## Items

Retail items with real stats, blues, alchemy and potions.

| Feature | Status | Notes |
|---|---|---|
| Inventory window | ✅ Supported | 96-slot bag over pages; drag, move and swap |
| Stacking, merging, splitting | ✅ Supported | Retail stack sizes; Shift+click opens the split box |
| Equipment and paper doll | ✅ Supported | 13 worn slots with live 3D preview; others see your gear; drop an item anywhere on the equipment window and it goes to its own slot (a ring to the empty ring slot first), as in the original |
| Item requirements | ✅ Supported | Level, race, gender and mastery checked; unmet shown in red |
| Item tooltips | ✅ Supported | Retail tooltip with white stats %, blues, plus, durability, requirements |
| Pick up drops | ✅ Supported | Click items or gold on the ground to pick up; the pick-up animation plays out before you can walk or pick again, as in the original |
| Drop items on the ground | ❌ Not yet | Players cannot drop items or gold yet |
| Durability and broken items | ✅ Supported | Gear wears in combat; broken gear gives no stats; a broken item's slot shows the original's red box and a worn-out one (6 points or fewer) its pulsing warning; the gear figure under the top-right corner shows the worn-out pieces yellow and the broken ones red; the break and warning sounds play |
| Alchemy +N (elixirs) | ✅ Supported | Retail success rates, lucky powder, failure and destroy rules |
| Alchemy window | 🟡 Partial | Reinforce and stones work; advanced elixir, other tabs, sockets missing |
| Magic options (blues) | ✅ Supported | Drop with blues, apply when worn, shown in tooltips |
| Sockets | ❌ Not yet | No socket system yet |
| Seal of Star/Moon/Sun/Nova items | ✅ Supported | Seal items usable; the original's spinning star drawn round their icons in every window that holds items: bag, equipment, storage, NPC shop and buy-back, exchange, your stall and others' stalls, the stall network, pet bags, alchemy, quick slots and the icon on the cursor |
| Seal effects | ✅ Supported | Each seal piece shows its own Seal of Star/Moon/Sun/Nova effects, on you and others; dual axes and daggers show them on both hands |
| Plus glows | ✅ Supported | Weapons and shields glow by plus (+3, then +5 to +14); +8 sparkle; armour never glows, as retail |
| HP/MP potions and vigors | ✅ Supported | Retail recovery amounts and reuse locks |
| Cure pills | ✅ Supported | Universal and purification pills cure statuses |
| Auto potion | ✅ Supported | HP, MP and cure thresholds; settings saved on the server |
| Item cooldowns | 🟡 Partial | Server-enforced; potions, pills and items with a cooldown show the sweep and the time left on hotbar slots, using the original client's timings; the bag doesn't show the sweep yet, and a few special item kinds aren't timed |
| Speed scrolls and drugs | ❌ Not yet | Refused as unusable |
| Composite items | 🟡 Partial | Only the Energy of Life scroll kind works |
| Avatars | ✅ Supported | Hat, dress, attachment and flag slots; worn avatars cover your gear for you and others, on the select screen too; avatar stats and blues apply |
| Avatar magic options | ✅ Supported | The blacksmith grants avatar blues, free, up to the original's per-kind limits |
| Devil's Spirit | ✅ Supported | Worn, awakened and expires on time; its plus-level abilities and skill strip from the original server's own tables (the angel's spirits' missing +6..+10 options filled from their sibling spirits); its skills' buffs end when it is taken off; an awakened spirit's icon sparkles as in the original, and one whose time has run out is tinted blue |

## Economy

Gold, NPC trade, storage, player stalls and the stall network work; consignment is not built yet.

| Feature | Status | Notes |
|---|---|---|
| Buy and sell at NPCs | ✅ Supported | Retail prices, buyback and quick-sell |
| Storage gold | ✅ Supported | Deposit and withdraw gold in the warehouse |
| Exchange (player trade) | ✅ Supported | The original's exchange: request from the right-click menu, the action window or a selected player, its Accept / Refuse box; the window with up to 12 items and gold a side (drop an item on it, Alt+click, or its gold button); the other side's offer appears when they Confirm, then both Approve; offered items greyed in your bag, the "not in your Guild/Union/Friend" warning; ends on cancel, death, a warp or logging off. On by default (Extra Settings): the larger window private servers show, with both players' portraits, a pulsing red warning behind someone not in your friends or guild, and the exchange's message log -- the original's own controls, which its layout keeps off screen; the compact window when the screen is too small at your UI scale |
| Player stalls | ✅ Supported | The original's stalls: Stall in the action window, a title, a greeting, up to 10 items from your bag at your own prices (whole stacks), Open / Modify; others see your booth (default or your stall decoration) and the stall's name over you, click to enter (the stall cursor), buy, and chat in the stall window; no tax; up to 7 visitors; closes on death, teleport or logout. The decoration booths move with their own animation, a jinn pet you have out takes the vendor pose with you, the stall's name sits above your guild line in its own box (the name's box keeps the name's width), titles with the original's banned words are refused, and a chat- or trade-banned player is refused as in the original. Opening your stall or entering someone else's opens your inventory with it, Escape closes the stall the way its X does, and the stall window's log starts empty each time the window opens again (a closed or sold-out stall's log is gone, as in the original) |
| Stall network | ✅ Supported | The original's Stall Network window (F, or Stall network in the bottom menu, in a town; F again closes it): pick a class, type and degree, search, 15 results a page with Number, Level, Item, Name, Quantity and Price (click a column to sort), hover a result's icon for the item's full description (plus, white stats, blue options, as in your bag; the durability shown at its maximum, as the original shows it there), select a row to see the seller and whisper them, Purchase with the confirmation box -- the item comes straight to your bag, no walking to the stall; a new search after 10 seconds. Sellers put their stall on the network when they open it in a town (Yes to "Register items with stall network?"); a network sale costs the seller 1% commission (at least 1, at most 100,000 gold) and both sides see who bought what. The menu entry, the F key and the question are this client's own disabled parts switched on (OpenSRO add-on) |
| Consignment | ❌ Not yet | No consignment trading yet |
| Item mall (silk) | ✅ Supported | The original's in-game Item Mall (F10, after its "Enter Item Mall" warning): categories and sub-tabs, the main page's New / Best / Recommend lists, the HOT shop and the Reserved list, search, badges, buying with Silk, Gift Silk and points, "Buy Item Worn" and Buy All, the Buying list. Hover an item's icon for its full description. The Avatar tab sells the archive's avatars (hats, dresses, attachments). Try avatars on before buying: hats, dresses, flags and pets on a 3D preview you turn with the left mouse button and move with the right. Your Silk balances are kept by the server; GMs can grant them with /silk |
| Item mall items | ✅ Supported | Everything the mall sells does what its description says. Visual scrolls (wings, horns, crowns, capes, trails) and Godbless wings show on your character for everyone, one look at a time, and survive relog and death; Boots of Speed, speed drugs and damage absorption scrolls; silk scrolls, Lucky Dice and the lottery tickets (a GM draws with /lottery draw); the job, guild and premium removers and the red-stat remover; skill, stat and skill+stat resets and the Skill Leveler; name change at next login; name and title colours; starter packages into the item chest; Pet Level Up; title scrolls and the custom title; the Random Wing Scroll; the gender, avatar, devil-spirit and flag switchers, the weapon type switchers and the model switchers (right-click, then click the item); the switched item's slot flashes as in the original; silk pets, fellow pets, rides and carts; the Clock of Reincarnation and the pet growth potion; devil's and angel's spirits with their plus-level abilities and skills, the Nasrun extension and magic stone; GoldTime PLUS (Gold Time with pause, free return and reverse scroll uses); the repair hammer, storage expansion (twice per account), arrows and bolts that are spent and reloaded, coloured global chatting, the skin change window, Magic POP cards, the special reverse scroll (party member and saved locations) and the EU accessories' absorption. Stall decorations are stored but show once player stalls exist |
| Item chest | ✅ Supported | An OpenSRO add-on. A chest icon under the minimap: mall purchases that do not fit your bag wait there; take one or all, and see the last 7 days in the Take Log |
| Guild storage | ✅ Supported | The original's guild storage: "Use guild storage" at the guild manager (shown in red until the guild reaches level 2), for the master and members given the storage permission; 30, 60, 90 or 120 slots by guild level, and the guild's own gold. The window opens with your inventory beside it; drop items in (whole stacks, half the warehouse's fee), take them out, move them about, put gold in and take it out. One member at a time ("guild member ... is using guild storage"), and that member cannot leave or be expelled, nor the guild disbanded, until it is closed. Everything is saved with the guild, and goes when the guild is disbanded |

## Social

Chat, full party system, party matching and basic guilds.

| Feature | Status | Notes |
|---|---|---|
| Chat channels | ✅ Supported | All, whisper, party, guild and global chat |
| GM notices | ✅ Supported | Notice banners from GMs |
| Chat window | ✅ Supported | Retail chat window with five tabs and the whole-chat window |
| Party | ✅ Supported | Invite, leave, kick; survives disconnects |
| Party EXP and item sharing | ✅ Supported | Retail share modes and formulas |
| Party HUD | ✅ Supported | Live member HP/MP boxes, party window, minimap and world map marks |
| Party matching | ✅ Supported | Register, browse, request to join and answer |
| Guild creation | ✅ Supported | Create a guild at the guild manager |
| Guild invites | ✅ Supported | Invite the selected player from the guild window, the original's Agreement box, accept or refuse, 30 s timeout; ban a member; 72 h penalty after leaving, a ban or a disband |
| Guild ranks and permissions | 🟡 Partial | Invite and Ban follow your permission bits (the master has all); granting rights, union chat and the notice not done |
| Guild window | 🟡 Partial | Level, GP, members n / cap, notice title and the member list (online lamps, ranks, GP), live updates as members join, leave, log on and off; select a member to ban; its grant-name button sets your own grant name (or `/grantname`) |
| Guild names over characters | ✅ Supported | `[Guild * Grant]` (or `[Guild]`) 20 px above the name with no box behind it, orange for you and every member of your guild, green for a guild in your union, blue for others (the original's colours and rule), recoloured at once when you or they join or leave a guild or a union, riding a mount with the name and hidden in a job suit; each member sets their own grant name (window button or /grantname), at any guild level |
| Guild points and levels | 🟡 Partial | Points earned, guild levels up; spending points not done |
| Guild emblems | 🟡 Partial | Register and delete a guild's emblem with the emblem scrolls (guildmark.bmp, 16 x 16 24-bit, beside Media.pk2; guild level 4, the master); shown beside the guild name over every member; union emblems wait for unions |
| Union | 🟡 Partial | Unions are kept by the server and sent to every member (their guild lines turn green, live); a GM forms and leaves them with /union, the players' own union request, the union window and union chat are not built yet |
| Friends list | ✅ Supported | The original's friends: ask by name (the Community window's Add friend, the right-click menu, /friend or /invite), its Agreement box with Accept / No and a 30 s wait, 20 friends a side; online lamps, race icons and the count in the Community window, Whisper and Delete friend (both sides); "Friend [name] has logged on / off" lines |
| Mail / letters | ❌ Not yet | Letter pane drawn, no backend |
| Block list | ❌ Not yet | Block pane drawn, no backend |
| Academy | ❌ Not yet | Not yet |
| Emotes | ✅ Supported | Seven retail emotes from the action window |

## Job / trade

The trader, hunter and thief jobs from the original's own rules: the job guilds, the suits, the specialty trade, job PvP and the NPC thieves and hunters.

| Feature | Status | Notes |
|---|---|---|
| Trader, hunter, thief jobs | ✅ Supported | Join at the job guild NPCs (fee, 7-day penalty on leaving), aliases, last week's rankings, the weekly reward pools, the previous job |
| Job suits | ✅ Supported | The 10-second change with its bar over the head; the job name and icon on the plates (your own too, over the rider on every mount, centred with the title as the original lays it out), the job target window, the job rows of the character window; optional job titles on the plates (on by default) |
| Trade goods and specialty runs | ✅ Supported | Buy goods into a transport at a trade center, sell at another town's quotation (each sale lowers the price, which recovers every 10 minutes), trade scale stars, job EXP, contribution, Trade Export Details; stolen goods sell only at the thief den; dropped goods show their owner's job name. The trade center's store opens your transport's goods window instead of your inventory, as the original's does |
| Job PvP | ✅ Supported | Thieves against traders and hunters outside towns, with the original's rules (party, level 20, the one-star safe trade's protection from player thieves; NPC thief waves round a trader's caravan are a server switch, off by default); opposed names drawn red, the original's click and Alt-click, skills on a player or a transport; a job death costs job and character EXP and nothing else, the killer earns job EXP and EXP |
| Safe trade | ✅ Supported | A trader's one-star run of normal goods is protected from player thieves, eight times a day, with its icon and messages |
| NPC thieves and hunters | ✅ Supported | Every 60 to 120 seconds a trade run outside town draws a wave of NPC thieves (round a trader) or NPC hunters (round a thief), its size from the goods carried, its level from the trader's; they go for the trader and the transport, and a transport they kill drops its goods; drawn as the original draws them, in thief and hunter suits with their weapons |

## Pets & mounts

Pets, horses, the item mall's rides and the trade transports from the original's own rules.

| Feature | Status | Notes |
|---|---|---|
| Ability (pickup) pets | ✅ Supported | Pick up gold, equipment and other items by their settings; gold to the owner, the rest to the pet's own bag |
| Growth and fellow pets | ✅ Supported | Follow, fight what the owner attacks, gain EXP and level up, hunger, naming once |
| Horses and rides | ✅ Supported | Horses, tigers, beetles, ostriches and the other ride scrolls: summoned at the owner's level bracket, ridden at the mount's speed; Walk or Run on a mount plays its walk or run (a pegasus flies only at a run); mounts, pets and monsters lean with the slope they stand on, by each one's own factors from the game's data, and a rider leans with its mount (players and NPCs stay upright, as retail) |
| Pet controls | ✅ Supported | Pet window, status slot, command bar, the retail pet keys, pet potions (on the current pet, transports included), revival and clocks; the Test Items NPC sells pets and rides. A summoned pet's scroll glows round its icon, a dead pet's scroll is tinted blue, and a revival or a longer rent flashes the scroll once, as in the original |
| Trade transports | ✅ Supported | For a trader or thief in a suit: the original's one-slot goods bag (its size rule caps by level, its transports hold one stack), the 100 m leash, goods dropped when it dies or is dismissed, no teleport scrolls with a cart (the thief den's excepted) |

## Events / special

Large-scale events and instanced content are still to come.

| Feature | Status | Notes |
|---|---|---|
| Fortress war | ❌ Not yet | Rules recovered, not playable |
| Capture the flag | ❌ Not yet | Not yet |
| Battle arena | ❌ Not yet | Rules recovered, not playable |
| Survival arena | ❌ Not yet | Not yet |
| Jupiter temple | ❌ Not yet | Not yet |
| Job temple | ❌ Not yet | Instanced; refused at the gate |
| Pharaoh's tomb (King's Valley) | ❌ Not yet | Instanced; gates not usable |
| Holy Water Temple (Medusa) | ❌ Not yet | Instanced; refused at the gate |
| Alexandria | 🟡 Partial | Town region loads; content beyond NPCs and shops unverified |
| Forgotten World | ❌ Not yet | Not yet |

## UI / HUD

Retail windows rebuilt from the game's own layout files.

| Feature | Status | Notes |
|---|---|---|
| Hotbar | ✅ Supported | Four pages on F1-F4; slot numbers and quantities on every page; the gold frame marks the slot last used and fades out over 4 seconds; a weapon, shield or other gear on the bar is put on when pressed, and its key works again once it is swapped back into the bag |
| Drag to hotbar | ✅ Supported | Skills, items, gear and actions; swap and clear slots; a stack keeps showing its count while you carry it |
| Additional quick slot bars | ✅ Supported | The original's movable extra bar (Space+1-0) with its options, plus paged extra bars (Alt+1-0) |
| Saved hotbar | 🟡 Partial | Saved on your PC per character, not on the server |
| Character window | ✅ Supported | Stats, attack/defence ranges, balance; spend STR/INT points |
| Player info (HP/MP/Hwan) | ✅ Supported | Live HP/MP bars and Hwan orbs |
| Buff bar | ✅ Supported | Icons with timers; right-click cancel |
| Target window with buffs | ✅ Supported | Target's HP, rank and buff/debuff icons |
| Quest window | 🟡 Partial | Quest list and objectives; counts and timers partly missing |
| System message window and banners | ✅ Supported | System messages, notice banners and area names |
| Action window | ✅ Supported | Sit, walk/run, emotes, auto attack, trace, exchange, party, auto grab |
| Right-click player menu | ✅ Supported | Whisper, Exchange, Add friend, Invite party and Trace, as the original; always on (the original's option is gone), and ready for entries of our own below Trace (such as View items) |
| NPC talk and message boxes | 🟡 Partial | Retail talk box; some dialogs not yet retail layouts |
| Option window: Video | ✅ Supported | Retail rows, presets, brightness, sight range |
| Option window: Audio | ✅ Supported | Volume sliders |
| Option window: Key Map | ✅ Supported | The original's tab: click a row and press a key to rebind it (a key already in use is taken from its old row, as the original does), the two mouse layouts (shortcut on the wheel or on the right button), Default and Apply; a Stall network row (F) after the original's 33 (OpenSRO add-on) |
| Option window: Setting (Game) tab | ❌ Not yet | Drawn but not wired |
| Option window: Extra Settings | ✅ Supported | OpenSRO add-ons, switched by a check mark: a Ping / FPS box you can drag anywhere (a private-server feature), and the exchange window's portraits and log (on by default) |
| Keybinds | ✅ Supported | The original's 33 rebindable keys, saved per PC, plus F for the stall network (OpenSRO add-on, rebindable like the rest; a saved key map that already used F keeps it); the rest of the retail key table (F1-F4 pages, digits, Space/Ctrl chords) is fixed, as in the original |
| Escape menu and Help window | ✅ Supported | Option, Help, Restart, Exit; in-client help |
| Game cursors | ✅ Supported | Retail cursors read from your own sro_client.exe |
| Debug panel and tester console | ✅ Supported | Shift+F3 panel and /help chat commands for bug reports |

## Graphics & effects

Retail models, particles and lighting re-created in Godot.

| Feature | Status | Notes |
|---|---|---|
| Character models | ✅ Supported | Retail bodies dressed from the item table's models, drawn the right way round: weapons in the right hand, shields and bows on the left, as retail |
| Equipment visuals | ✅ Supported | Worn weapons and armour drawn on every character |
| Particle effects (EFP) | ✅ Supported | Retail particle effects for skill casts, projectiles, hits and level-up; an effect's layers draw in the original's order every frame (quest marks over NPCs hold steady) |
| Effects stay on moving bodies | ✅ Supported | Effects follow their holder at any frame rate |
| Lighting and shadows | ✅ Supported | Sun, character light, shadow detail options; shadows follow the sun (option) |
| Bloom and ambient occlusion | ✅ Supported | Retail-style bloom and SSAO options |
| Trees, foliage and map objects | ✅ Supported | Retail materials; animated map objects |
| Placed object effects | ✅ Supported | Every placed object's ambient effects (fountain sprays, waterfall mist, lanterns, burners); they play out to the fog and fade into it (to the horizon with fog off), and lantern glows hide behind walls at once; scrolling water on fountains and waterfalls |
| Fade-in of characters | ✅ Supported | Monsters and players fade in over 2 s, as retail |
| Berserk look | ✅ Supported | Berserk aura, colour and sounds |
| Camera shake | ✅ Supported | The skills that shake the screen in the original (Bash, the falling force bolts and more), and your own critical and berserk blows |
| Cloth and hair (Dynamic Animation) | ✅ Supported | Robes, dresses, capes, wings, hair, tassels, banners, flags and tents sway and fall as in retail; the Video option turns it on and off |
| Worn item effects | ✅ Supported | Talisman glows, the Europe talisman's turning ornaments, wing flaps and fullset shimmer from the items' own files |
| Crowd rendering | ✅ Supported | GPU skinning for large crowds |
| Level of detail and culling | 🟡 Partial | Frustum and sight-range culling; no mesh LOD |

## Audio

Retail music, ambience and sound effects from your own archives.

| Feature | Status | Notes |
|---|---|---|
| Zone music | ✅ Supported | Music changes by region |
| Ambient sounds | ✅ Supported | Region ambient beds |
| Combat and skill sounds | ✅ Supported | Swings, hits and skill sounds |
| Footsteps and voices | ✅ Supported | Footsteps by ground type; hurt and death voices |
| Volume controls | ✅ Supported | Per-channel volume in the Audio tab |

## Server / ops

Go server with Postgres persistence and operator tooling.

| Feature | Status | Notes |
|---|---|---|
| Postgres persistence | ✅ Supported | Characters, items, storage, skills, quests, guilds, friends saved |
| Docker Compose setup | ✅ Supported | Server and Postgres in one command |
| Server auto-update | ✅ Supported | Timer pulls, rebuilds, health-checks and rolls back on failure |
| Max players | ✅ Supported | Configurable cap, default 1000 |
| Rates | ✅ Supported | EXP, party EXP, drop, gold and Hwan rates, capped at 2.5x |
| GM commands | ✅ Supported | Teleport, give items, level, spawn, notices and more |
| GM kick and ban commands | ✅ Supported | /ban kicks as the original does; /block and /unblock for timed or permanent bans; /chatban and /tradeban (and their un- forms) for the original's chat and trade bans, which refuse chat lines, the global chat item, exchanges and stalls with the original's message |
| Original client in the world | ❌ Not yet | The original client stops at character select; its in-world protocol is not built |
| Crowd performance | 🔧 In progress | Interest management done; 1000-player target not met yet |

## Plugins & customization

A major goal: plugins that extend the server and client without modifying the shipped executables and libraries, so private servers can be customized as far as their operators want.

**Asset packs (`.pk3`).** New or changed models, textures, sounds and tables ship as a plain zip (`.pk3`, or `.zip`) beside the original `.pk2` archives, with no injecting into a `.pk2`. A file in a pack uses the same path it has in the `.pk2`, so replacing an asset and adding a new one are the same step. Packs layer by name and a later name wins (`z_assets` over `assets`); the original archives are always the bottom layer and a loose `custom/` folder the top. One setting picks `pk2` only, `pk3` only (the original archives converted once) or `mixed`, the default. The server can name the packs a client needs, with their hashes, so every player sees the same content.

| Feature | Status | Notes |
|---|---|---|
| Server plugins | ❌ Not yet | Planned: load new server features without rebuilding or patching the server |
| Client plugins | ❌ Not yet | Planned: add windows, content and behaviour without modifying the client |
| Plugin API and SDK | ❌ Not yet | Planned: stable hooks, packaging, versioning and docs for plugin authors |
| Data-driven game tables | ✅ Supported | Items, monsters, skills, NPCs, spawns, teleports and quests load from CSV/DB; swap without rebuilding |
| Server options | ✅ Supported | Gameplay systems toggled by command-line flags and environment variables |
| Custom NPCs | 🟡 Partial | Test Items NPC is rule-defined but built in; no loader for operator NPCs |
| Asset packs (.pk3) | ✅ Supported | Zip packs layered over the .pk2 archives, a loose custom/ folder on top, a pk2 → pk3 converter; the server names the packs a client needs and the client fetches and verifies them |
| Client server list | ✅ Supported | Servers, addresses and login screen set in setting/config.yaml |

## Bots

Automated play: an outside program that plays a character, and a macro system inside the game.

| Feature | Status | Notes |
|---|---|---|
| External Bot | ❌ Not yet | No support yet for a separate program that logs in and plays a character |
| Macro Bot | ❌ Not yet | No in-game hunting macro yet; auto potion is the only built-in automation |

## Client platforms

Windows and Linux builds; bring your own retail game files.

| Feature | Status | Notes |
|---|---|---|
| Windows | ✅ Supported | Windows 10+ 64-bit; prebuilt zip each release |
| Linux | ✅ Supported | 64-bit, glibc 2.28+; prebuilt zip each release |
| macOS | 🟡 Partial | Windows build reported working under CrossOver; no native build |
| Vulkan renderer (Forward+) | ✅ Supported | Default renderer |
| OpenGL renderer (Compatibility) | ✅ Supported | Launcher or config option; automatic fallback without Vulkan |
| Auto-updater | ✅ Supported | Offers new releases at start; never applies silently |
| Bring your own game files | ✅ Supported | Reads Data, Map and Media.pk2 from a pk2 folder |
