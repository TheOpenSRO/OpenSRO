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
| `/copy` | Copies the full debug report (the Shift+F3 panel's payload, plus the last log lines and script errors) to the clipboard, ready to paste into a report. |
| `/fps` | The current frame rate. |
| `/entities` | Counts of the monsters, NPCs, other players and ground items currently in view. |
| `/wire on` / `/wire off` | Starts or stops logging every network packet's opcode and size to the log — for chasing a desync or a crash. |
| `/cam free` / `/cam orbit` | Switches the camera between free-look and orbit. |
| `/errors` | The last 20 script errors this session (also in `/copy` and the log). |
| `/unstuck` | Returns you to the zone's entry point if you wedge into geometry. |
| `/groundprobe` | If the ground looks **white** (or wrong in any other way), type this while you can see it and hold still until chat says it is done (a few seconds; longer on a large screen). It records how the ground is being drawn — your graphics card and driver, the ground textures and materials under you, and a few quick checks during which the ground may flash red, magenta, blue or flat grey — and saves it all to a `groundprobe-….txt` file in the log folder (`/log` opens it). Send us that file. `/groundprobe quick` skips the checks. The Shift+F3 panel's **Ground probe** button does the same. |
| `/w <name> <message>` | Whispers another player. |

## Sending a report

1. If it is a visual problem, press **Shift+F3**, then **Copy** (or type `/copy`).
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
| `/give <item id> [qty]` | Puts an item in your bag by its numeric id (unknown ids are refused). |
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
| `/notice <text>` | Sends a GM notice to every player (round 634): a pink "(Notice):" line in every chat tab and the notice banner at the top of the screen for 7 seconds. The command is ours; the line and banner are the game's. |
| `/invsize [1-96\|default]` | Shows or sets your bag's size in slots (round 633; a test tool, not a retail command). The bag shows 32 slots a page, up to three pages, and locks the slots of the last page past the size. `default` goes back to the server's `-inventory-size` (96 unless the operator set another). Refused below a slot that holds an item. |
| `/hurt <hp> [mp]` | Takes *hp* (and *mp*) off your own character, never below 1 HP (round 786; a test tool, not a retail command) -- for the auto potion. |
| `/afflict <code> <values...>` | Lands one abnormal state on your own character without a roll, as a monster skill's run would: the skilldata code and its values, e.g. `/afflict ps 34 100 16` (a poison of strength 34, 16 a tick), `/afflict bu 30 100 5`, `/afflict se 20000 100 2` (a level-2 sleep of 20 s) (round 786; a test tool) -- for the cure pills and the auto potion's abnormal row. |
| `/hour <0-23>` | Sets the game clock's hour for the whole world, keeping its day and minute (round 786; the original operator tool's set-hour). Every character in the world is told at once and the sky follows: clock 04:00-20:00 is the sky's day, 20:00-04:00 its night, and a full game day takes 28 min 48 s. With Night Darkness on Dim or Dark (round 786, OURS) the world darkens from about 19:30 and is fully dark from about 20:40 to 03:20. |
| `/speed [x\|off]` | Multiplies your run speed by *x* (0.1 to 10) on top of any buff, so testing covers ground faster (round 636; a test tool, not a retail command). `off` (or `1`) goes back to normal; `/speed` alone prints the multiplier and the speed. The server sends the new speed down the buff speed path (an `OpBuffEnd` with no tokens), and the multiplier outlasts a zone change and a death until you turn it off or log out. The server does no movement-speed check, so nothing refuses the faster moves. |

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
