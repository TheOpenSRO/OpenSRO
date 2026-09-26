# Debug tools for testers

These are srrevamp's own testing tools. None of them come from the original
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
| `/copy` | Copies the full debug report (the Ctrl+F3 panel's payload, plus the last log lines and script errors) to the clipboard, ready to paste into a report. |
| `/fps` | The current frame rate. |
| `/entities` | Counts of the monsters, NPCs, other players and ground items currently in view. |
| `/wire on` / `/wire off` | Starts or stops logging every network packet's opcode and size to the log — for chasing a desync or a crash. |
| `/cam free` / `/cam orbit` | Switches the camera between free-look and orbit. |
| `/errors` | The last 20 script errors this session (also in `/copy` and the log). |
| `/unstuck` | Returns you to the zone's entry point if you wedge into geometry. |
| `/groundprobe` | If the ground looks **white** (or wrong in any other way), type this while you can see it and hold still until chat says it is done (a few seconds; longer on a large screen). It records how the ground is being drawn — your graphics card and driver, the ground textures and materials under you, and a few quick checks during which the ground may flash red, magenta, blue or flat grey — and saves it all to a `groundprobe-….txt` file in the log folder (`/log` opens it). Send us that file. `/groundprobe quick` skips the checks. The Ctrl+F3 panel's **Ground probe** button does the same. |
| `/w <name> <message>` | Whispers another player. |

## Sending a report

1. If it is a visual problem, press **Ctrl+F3**, then **Copy** (or type `/copy`).
2. Paste that into your report. It carries the build, your position, what is
   loaded, the entities around you, and the last log lines and script errors.
3. Attach the log file if you can — `/log` prints where it is
   (`user://logs/srrevamp.log`; the desktop build opens the folder).
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
| `/tp <x> <z>` | Teleports you to world coordinates in the current zone. |
| `/goto <zone\|monster>` | Travels to a named zone's entry, or to where a monster species is kept. |
| `/give <item id> [qty]` | Puts an item in your bag by its numeric id (unknown ids are refused). |
| `/gold <n>` | Adds gold (a negative number takes it away). |
| `/level <n>` | Raises you to level *n* through the real level-up path, so stats, HP and MP follow. Only goes up. |
| `/heal` | Refills HP and MP to their maximums. |
| `/spawn <monster> [n]` | Spawns *n* of a monster species next to you (no respawn). |
| `/kill` | Kills the monster you have selected. No exp, gold, drops or quest credit — a GM kill is not a kill. |
| `/durability <slot> <n>` | Sets a worn item's durability. Slots: 0 helm, 1 mail, 2 shoulder, 3 gauntlet, 4 pants, 5 boots, 6 weapon, 7 shield, 8 job suit. |
| `/sp <n>` | Adds skill points (a negative number takes them away). |

`/goto` and `/spawn` with no valid name list the zones and monster code names
they accept. `/give` takes the item's numeric id; the client resolves an item
code to its id when you hover it in a window.
<!-- /gm-only -->

## For operators: enabling GM accounts

The server reads the allowed accounts from the `-gm-accounts` flag, or the
`SRREVAMP_GM_ACCOUNTS` environment variable it defaults to:

```
SRREVAMP_GM_ACCOUNTS="alice,bob" ./srrevamp-server ...
# or
./srrevamp-server -gm-accounts="alice,bob" ...
```

The value is a comma-separated list of **account usernames**, matched exactly
as stored (case-sensitive), whitespace around each name ignored. With none
set, nobody is a GM and the console shows only the client commands. Every GM
command is logged server-side with the account, the character and the command
line, whether it was allowed or refused.
