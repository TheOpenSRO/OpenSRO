# Debug tools for testers

These are OpenSRO's own testing tools. None of them come from the original
client; they exist so a playtest report arrives as **facts** — a position, a
level, an error line — instead of impressions. Everything a command shows is
disclosed, not read from real game data.

There are two kinds:

- **Client commands** anyone can use. They report into the chat window and the
  log file. They change nothing on the server.
- **GM commands** that change the game (teleport, give items, set your level).
  These run on the server and only for accounts an operator has enabled.

Type a command on the chat input line, the same line you chat on. An unknown
command always answers with the help line — it never stays silent.

## The chat console

| Command | What it does |
|---|---|
| `/help` | Opens the Help window and prints the one-line command list in chat. |
| `/where` | Zone, region y/x, your local and world coordinates, and the walkable height under you. |
| `/log` | Prints the log file's path; on desktop, opens the folder holding it. |
| `/copy` | Copies the full debug report (build, server, position, equipment, entities, archives, loading, performance, the last log lines and script errors) to the clipboard, ready to paste into a report. Works in every build; the developer panel's Copy is the same report. |
| `/uiscale <n>` | Scales the interface, 0.5 to 3 (1 is the original's size); remembered. |
| `/names <n>` | How near (0 to 400) a name plate shows; remembered. |
| `/duel <name>`, `/duel accept`, `/duel decline`, `/duel hit` | This server's own duel (not the original's): challenge a player, answer a challenge, strike. Its answers show in the system window. |
| `/fps` | The current frame rate. |
| `/entities` | Counts of the monsters, NPCs, other players and ground items currently in view. |
| `/wire on` / `/wire off` | Starts or stops logging every network packet's opcode and size to the log — for chasing a desync or a crash. |
| `/cam free` / `/cam orbit` | Switches the camera between free-look and orbit. |
| `/errors` | The last 20 script errors this session (also in `/copy` and the log). |
| `/unstuck` | Returns you to the zone's entry point if you wedge into geometry. |
| `/groundprobe` | If the ground looks **white** (or wrong in any other way), type this while you can see it and hold still until chat says it is done (a few seconds; longer on a large screen). It records how the ground is being drawn — your graphics card and driver, the ground textures and materials under you, and a few quick checks during which the ground may flash red, magenta, blue or flat grey — and saves it all to a `groundprobe-….txt` file in the log folder (`/log` opens it). Send us that file. `/groundprobe quick` skips the checks. The developer panel's (Shift+F3, developer builds) **Ground probe** button does the same. |
| `/w <name> <message>` | Whispers another player. |
| `/grantname <name>` | Sets your own grant name in your guild, the second part of the `[Guild * Grant]` line over your name (round 814; at most 12 letters and the name filter applies; any guild level since round 815). `/grantname` alone clears it. The guild window's grant-name button does the same. |
| `/layer <path>` | Which layer of the game's archives serves an archive path (round 789): the loose `custom/` folder, an asset pack (`.pk3`, by its file name) or a base archive (`base Data.pk2`, `base Media.pk3`, ...), and which layers under it hold the same path, e.g. `/layer prim\mtrl\foo.ddj` -> `z_assets.pk3 (...); also in assets.pk3, base Data.pk2`. Paths are matched case-insensitively, `/` and `\` alike, empty segments ignored. |

## Asset packs: which layer served a file (round 789)

The client reads its archives as layers: `custom/`, then the asset packs (`*.pk3`, `*.zip`, extra
`*.pk2`, a later name winning), then the retail base archives (deploy/README.md, "Asset packs").
Three ways to ask which one serves a path, all OURS:

- **In the game:** `/layer <path>` in chat (above). The `/copy` report's "archives" lines list the
  source mode, the base archives and the packs, highest first.
- **In a QA run:** `OPENSRO_QA_WHICH="path;path;..."` logs one `QA WHICH <path> -> <layer>
  (<file>); also in ...` line a path when the archive set opens (any run: the world, a front-end
  scene, qa_shot.sh).
- **Without a game:** `client/tools/which_layer.gd` prints the set and the same answers headless
  (client/tools/README.md, "Asset packs").

The load log names every override once (`AssetArchives: Data: 3 path(s) of Data.pk2 overridden:
...`); `OPENSRO_PACK_LOG=all` lists all of them instead of the first 10. `OPENSRO_ASSET_SOURCE=pk2|
pk3|mixed` and `OPENSRO_PACK_DIR=<folder>` set the source mode and the pack folder for a test run.

**Server packs** (round 789, lane U; docs/protocol/asset_packs.md "Server packs"). While a server
that names its packs is connected, `QA WHICH` and `/layer` name its packs (`z_akatsuki.pk3
(<pack folder>/servers/<host>_<port>/z_akatsuki.pk3)`), and the `/copy` report says `packs of
server <host>_<port>`. `OPENSRO_QA_WHICH` answers once per archive set, so a run that reopens the
set for a server prints the lines twice: before (the player's own set) and after. Every step of
the fetch is a `PACKS:` line in the client log -- the question and the answer (`PACKS:
127.0.0.1:15897 names 2 pack(s), listener port 15898: ...`), the plan per pack (`ready (verified
before)`, `hash (...)`, `fetch (not here)`), each download (`resuming after <n> of <m> bytes`,
`HTTP 302 -> ...`, `<n> bytes, sha256 verified -- in place`), the result (`2 pack(s) of ... ready:
2 downloaded, 0 checked, 0 verified before (220 ms)`) and whether the set was reopened; a failure
is `PACKS: NOT READY: <the words the login screen shows>`. The set's own log says what is set aside
(`AssetArchives:   set aside while that server is connected: pack a_mine.pk3`). On the server,
`-client-packs` logs the list at startup and one `client pack served` line per download. A QA run
with `OPENSRO_QA_SERVER` fetches the packs too (QaSignIn), so `qa_shot.sh --server` renders with
them; `OPENSRO_PACK_DIR=<empty folder>` gives a run a clean pack folder.

## Sending a report

1. Type `/copy` in chat (in a developer build, Shift+F3 then **Copy** does the same).
2. Paste that into your report. It carries the build, your position, what is
   loaded, the entities around you, and the last log lines and script errors.
3. Attach the log file if you can — `/log` prints where it is
   (`user://logs/opensro.log`; the desktop build opens the folder).
4. If the ground is white, type `/groundprobe` while you can see it, hold
   still until chat says it is done, and attach the `groundprobe-….txt` file
   it names (it sits beside the log).

<!-- gm-only -->
## GM commands

These are shown here because your account is a GM. They run on the server,
which logs every one with your account name. A command that cannot run in the
current state (no target, no room, past the level cap) refuses with a reason
and changes nothing.

| Command | What it does |
|---|---|
| `/tp <x> <z>` | Teleports you to world coordinates in the current zone (behind the loading screen, then 6 s untouchable, as every teleport). |
| `/goto <zone\|monster>` | Travels to a named zone's entry, or to where a monster species is kept. |
| `/give <item id> [qty]` | Puts an item in your bag by its numeric id (unknown ids are refused). Avatars and devil's spirits too (round 789): they arrive +0 with no options, a devil's spirit not awakened. |
| `/avatar` | Lists your avatar slots 0..4: each item's id, plus and option count, and a devil's spirit's state (not awakened / awake for how long / expired) (round 789; a test tool, not a retail command). |
| `/avatar spirit <bag slot> <seconds\|0>` | Sets the expiry of the devil's spirit in that bag slot: awake for *seconds* from now, or `0` not awakened (round 789; a test tool). Lets you wear one at once (a sleeping one is refused 0x18f9) and watch it expire while worn: `/avatar spirit 0 60`, put it on, and a minute later its stats go and the server sends `0x3078 {3, slot}`. |
| `/gold <n>` | Adds gold (a negative number takes it away). |
| `/level <n>` | Raises you to level *n* through the real level-up path, so stats, HP and MP follow. Only goes up. |
| `/heal` | Refills HP and MP to their maximums. |
| `/spawn <monster> [n]` | Spawns *n* of a monster species next to you (no respawn). |
| `/spawnunique <id\|name>` | Spawns one unique monster next to you (round 657; a test tool, not a retail command): Tiger Girl (1954), Isyutaru (2002), Uruchi (1982), Lord Yarkan (3810), Demon Shaitan (3875) or Cerberus (5871), by id or name. Every player sees the appearance notice. No respawn. |
| `/kill` | Kills the monster you have selected. No exp, gold, drops or quest credit — a GM kill is not a kill. A unique killed this way is announced as "... has disappeared" unless players had hit it, when the player who dealt the most (in the party that dealt the most) is named. |
| `/damage <n> [id]` | Deals *n* damage to the monster you have selected (or the monster with that id, as `/spawnunique` prints it), as your blow (round 657; a test tool, not a retail command). If it dies it is a GM kill (no rewards), and a unique's death names you when you dealt the most. |
| `/durability <slot> <n>` | Sets a worn item's durability. Slots: 0 helm, 1 mail, 2 shoulder, 3 gauntlet, 4 pants, 5 boots, 6 weapon, 7 shield, 8 job suit. |
| `/sp <n>` | Adds skill points (a negative number takes them away). |
| `/hwan <0-5>` | Sets the berserk orbs held (round 629; a test tool, not a retail command). Five light the ready circle. |
| `/guildlevel <1-5>` | Raises your own guild to that level through the normal level-up, crediting you the guild points it needs and taking no gold (round 814; a test tool, not a retail command). It never lowers a level. |
| `/notice <text>` | Sends a GM notice to every player (round 634): a pink "(Notice):" line in every chat tab and the notice banner at the top of the screen for 7 seconds. The command is ours; the line and banner are the game's. |
| `/invsize [1-96\|default]` | Shows or sets your bag's size in slots (round 633; a test tool, not a retail command). The bag shows 32 slots a page, up to three pages, and locks the slots of the last page past the size. `default` goes back to the server's `-inventory-size` (96 unless the operator set another). Refused below a slot that holds an item. |
| `/hurt <hp> [mp]` | Takes *hp* (and *mp*) off your own character, never below 1 HP (round 786; a test tool, not a retail command) -- for the auto potion. |
| `/afflict <code> <values...>` | Lands one abnormal state on your own character without a roll, as a monster skill's run would: the skilldata code and its values, e.g. `/afflict ps 34 100 16` (a poison of strength 34, 16 a tick), `/afflict bu 30 100 5`, `/afflict se 20000 100 2` (a level-2 sleep of 20 s) (round 786; a test tool) -- for the cure pills and the auto potion's abnormal row. |
| `/hour <0-23>` | Sets the game clock's hour for the whole world, keeping its day and minute (round 786; the original operator tool's set-hour). Every character in the world is told at once and the sky follows: clock 04:00-20:00 is the sky's day, 20:00-04:00 its night, and a full game day takes 28 min 48 s. With Night Darkness on Dim or Dark (round 786, OURS) the world darkens from about 19:30 and is fully dark from about 20:40 to 03:20. |
| `/speed [x\|off]` | Multiplies your run speed by *x* (0.1 to 10) on top of any buff, so testing covers ground faster (round 636; a test tool, not a retail command). `off` (or `1`) goes back to normal; `/speed` alone prints the multiplier and the speed. The server sends the new speed down the buff speed path (an `OpBuffEnd` with no tokens), and the multiplier outlasts a zone change and a death until you turn it off or log out. The server does no movement-speed check, so nothing refuses the faster moves. |

### Kicking and blocking players (round 788)

| Command | What it does |
|---|---|
| `/ban <character>` | **Kicks** the character out of the game: its connection is closed and the player sees the "disconnected" box. This is the original game's own GM `Ban`, and the original's Ban is a kick too -- nothing is stored, the player may log straight back in. Refused for a character not in the world. To keep someone out, use `/block`. |
| `/block <character\|@account> <duration> [reason...]` | Blocks the account from logging in and disconnects it if it is connected (in the world or at character select). Name a character (any of the account's, online or not, any case) or the account itself with `@`, e.g. `@alice`. Duration: a number and `m`, `h` or `d` (`30m`, `12h`, `7d`, up to `3650d`), or `forever`. The reason is shown to the player at the login screen under "Account Ban Reason:", with the end date and time (the server's local time; `forever` shows a date 100 years ahead). No reason: "Blocked by a game master." Text after a `#` in the reason opens the client's separate "Block Detail" window. Refused for a GM account and for an account already blocked (`/unblock` first). |
| `/unblock <character\|@account>` | Ends the account's active login blocks, including the automatic one for wrong passwords. Refused when it is not blocked. |
| `/blockinfo <character\|@account>` | Lists the account's blocks, newest first (at most 5): number, kind, active or ended, since when, who set it, and the reason. |

`/block`, `/unblock` and `/blockinfo` are this server's own commands: the
original game blocked accounts from its operator console, outside the game.
Every block records who set it (your account name) and when, and the server
logs the command line.

### Chat and trade bans (round 840)

| Command | What it does |
|---|---|
| `/chatban <character\|@account> <duration> [reason...]` | Bans the account from chat (the operator console's "block chat", kind 4), in the same records `/block` writes. While it holds, every chat line the player sends -- all, whisper, party, guild, union, academy, the stall's chat -- and the global chatting item are dropped, and the player sees "Chat restricted by GM. Can chat from ..." with the end time, in the blue banner and the system window. A stall the player opens takes the character's name and one of the original's eleven suffixes ("'s Shop", " ^_^;", ...) instead of the title typed. Duration as `/block`'s. Refused while one holds. Takes effect at once. |
| `/tradeban <character\|@account> <duration> [reason...]` | Bans the account from trading ("block p2p trade", kind 3): an exchange request, opening a stall and entering one are dropped. The original client's archive misspells the trade line's text key, so with the retail Media.pk2 the player sees no message (as in the original); an archive with the right key shows "Trading restricted by GM. ...". |
| `/unchatban`, `/untradeban <character\|@account>` | Ends the ban. Refused when there is none. |
| `/questblock <character> <mask>` / `/questblock <character> clear [mask]` | Sets (or releases) bits of an in-world character's quest block, the mask the original's quests set to stop actions (a test tool, not a retail command). `0x200` is the stall's: opening a stall is refused (code 0x3c32) and entering one (0x3c33); no quest of the original sets it. The block goes when the character logs out. |

Unlike `/block`, the two bans may be put on a GM's account (neither keeps
anyone out). `/blockinfo` lists them with the login blocks.

`/goto` and `/spawn` with no valid name list the zones and monster code names
they accept. `/give` takes the item's numeric id; the client resolves an item
code to its id when you hover it in a window.

**Testing berserk:** `/give 23944 5` gives five *Energy of life* scrolls (1st
degree; 23945-23947 are the 2nd-4th). Right-click one in the bag: its icon
appears on the buff bar by your HP bar. Left-click that icon, press *Hwan
regeneration fill(1)* in the window that opens, and all five orbs fill; then
press Tab. While the scroll's hour runs your berserk also lasts 5 s longer
(8/11/14 s for the higher degrees) -- until you use the fill, which ends it, as
in the game. The fill cannot be used while berserk is on or with five orbs
already. `/give 24331 10` gives ten *Berserker Regeneration Potions*, which fill
the orbs straight from the bag. For a normal player the fill has the game's own
20-minute reuse delay (the next scroll waits for it); **a GM account skips it**
-- that is this server's own rule, not the game's.

**Testing avatars (round 789):** `/give <id>` an avatar (the item table's id
of a hat, dress, attachment or flag, or a devil's spirit), open the equipment
window's avatar view and drop it on the avatar slots; take it off by dropping
it on the bag. The Test Items NPC (when switched on) sells a sample of each
kind per gender. A dress with an attachment comes off with it (two free bag
slots needed). To grant options, talk to a town blacksmith ("Grant magic
option on avatar item"), drop a hat, dress or attachment in the window, pick
an option, confirm. A devil's spirit must be awakened before it can be worn:
use it from the bag (it lasts its item's period), or `/avatar spirit <bag
slot> <seconds>`. docs/protocol/avatars.md has the rules.
<!-- /gm-only -->

## For operators: enabling GM accounts

The server reads the allowed accounts from the `-gm-accounts` flag, or the
`OPENSRO_GM_ACCOUNTS` environment variable it defaults to:

```
OPENSRO_GM_ACCOUNTS="alice,bob" ./opensro-server ...
# or
./opensro-server -gm-accounts="alice,bob" ...
```

The value is a comma-separated list of **account usernames**, matched exactly
as stored (case-sensitive), whitespace around each name ignored. With none
set, nobody is a GM and the console shows only the client commands. Every GM
command is logged server-side with the account, the character and the command
line, whether it was allowed or refused.

A GM cannot `/block` a GM account (round 788): to block one, take it off
`-gm-accounts` and restart first. The login rules themselves (the wrong-password
limit and its automatic block, one session per account, the per-IP limit) are
in deploy/README.md, "Logging in".
