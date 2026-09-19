## Debug lane: a console in the chat line, GM commands behind a gate, and a Help window

"Give me more debug tools to test the client" — after a playtest crash in the
storage deposit that arrived as an impression ("it crashed") rather than a fact.
Testers had F1, F3 (with Copy), `/unstuck`, the log file, and the `SRREVAMP_QA_*`
hooks that only work in render-box runs. Now they have tools that work **in
play**, with every result going to chat and the log.

**All of this is srrevamp's own design.** The original client has no slash
console and no GM console for players; its help and notices went through an
embedded Internet Explorer control (an ifhelp/web-board panel) that Godot has no
equivalent for, and **the original's help dialogs were not recovered** — this
round did not decompile what the ESC Help button opens. What *is* grounded is
the slot: the System window's Help button (`GDR_SYSTEM_BTN_HELP`, text token
`UIIT_STT_HELP`, round 138) and the authored game-guide frame
(`resinfo\ifgameguide.txt`, loaded by `CIFGameGuide::Create` at `0x00765920`
together with `interface\guide\gd_scroll_*.ddj` and the strings
`UIIT_STT_GAMEGUIDE_START_1/2`; its left menu `CIFGGMenu` names
`UIIT_STT_GAMEGUIDE`, `UIIT_STT_QUESTGUIDE2`, `UIIT_STT_GAMEEVENTGUIDE`). The
Help window reuses that frame for its chrome; what sits inside it — a document
list and a RichTextLabel — is ours.

### The chat console (`client/scripts/ui/console.gd`)

Any chat line beginning with `/` goes through `Console.submit`. Client-side:
`/help` (prints the one-line list, and with no argument opens the Help window),
`/where` (zone, region y/x, local and world coordinates, walkable height under
the player), `/log` (the log path; opens the folder on desktop), `/copy` (the F3
payload to the clipboard), `/fps`, `/entities` (monsters / name plates / other
players / ground items), `/wire on|off` (NetClient prints every received
packet's opcode and size — `WIRE recv opcode=0x.... size=N`), `/cam free|orbit`
(`set_camera_view`: free, or the fixed-pitch Quarter Angle view), `/errors` (the
last 20 script-error lines, read back from the session log), plus `/w` and
`/unstuck`, which moved here from `_send_chat`. **An unknown command answers
with the help line, never silence.** The console reaches the world only through
a dictionary of Callables (`World3D._console_host`), so it is tested headless
with recording stubs (`console_test.gd`, 28 checks).

### The GM commands (`server/internal/gm`, `server/internal/session/gm.go`)

ONE additive op pair: `OpGMCommand 0x00F1` (character name, the line as typed,
the selected monster id) and `OpGMCommandResult 0x00F2` (is_gm, refused, text,
optional position/zone, level-up, refresh bits). New commands are new words in
the line, not new opcodes.

The gate is an account-username list: `-gm-accounts` / env
`SRREVAMP_GM_ACCOUNTS` (comma-separated, trimmed, case as stored in
`accounts.username`; default none). The username is stored on the session at
login (`AuthenticatedUsername`; `authenticate` now takes it) because the account
Store has no by-id lookup. A non-GM's command is refused with a chat reply; the
enter-world **probe** (an empty line) is answered silently with `is_gm`, which
is how the client learns whether to show the GM tooltip/section and greet a GM
once. Every command — allowed or refused — is logged server-side with the
account, the character and the line.

The commands call existing store methods only: `/tp <x> <z>` and `/goto
<zone|monster>` reply with a position the client applies (movement is
client-authoritative; the same path `/unstuck` uses; a cross-zone `/goto`
changes zone first and stands at the position when the zone loads); `/give
<item id> [qty]` checks the item table and uses the shop's `AddItem` (the client
resolves an item code to its id from its own itemdata); `/gold <n>`
(`AddGold`/`DeductGold`); `/level <n>` applies the combat path's own level-up
arithmetic (`+leveldata.StatPointsPerLevel` points and
`+character.StatGrowthPerLevel` Str/Int per level, `ResetHP`, mana refill to
`MaxMPFor`), only upwards, capped at the table's max level, refused without a
level table; `/heal` (`ResetHP` + mana refill); `/spawn <monster> [n]`
(`SpawnSpecies` with the roster's own stats — `cmd/server.gmSpecies()`
converts `monsterSpecs` the way `maintainMonster` does — n ≤ 20, 4 units apart,
no respawn); `/kill` (the hub's `ApplyDamage` to zero on the client's selected
monster, `OpMonsterDied` to the rest of the zone; **no exp, gold, drops or
quest credit**); `/durability <slot 0-8> <n>` (`SetDurability`); `/sp <n>`
(`AddSkillPoints`). Own choices, all disclosed in the replies: the spawn cap and
spacing, level-down refused, GM kills pay nothing.

Tests: `gm_test.go` (gate: trimmed/case/empty/nil; every command's effect on
the mem stores; unknown/empty → the help line; missing deps refuse rather than
panic) and `session/gm_test.go` (wire round-trips; the gate over a real socket:
GM probe answered with the help, non-GM probe silent, non-GM command refused
with `is_gm=false`).

### Error capture and the Copy payload

`project.godot` already writes SCRIPT ERRORs to `user://logs/srrevamp.log`
(file logging on, 10 files kept). The F3 Copy payload (`debug_panel.gd
diagnostics()`) now ends with `== script errors (N)` (the last 20 error lines
in the log) and `== last 20 log lines`, so a pasted report carries what a
tester would otherwise have to attach the log for. `/errors` and `/copy` read
the same file.

### The Help window (`client/scripts/ui/help_window.gd`, `md_to_bbcode.gd`)

Opened from ESC → Help (which used to print a controls line), from `/help` with
no arguments, and by `SRREVAMP_QA_HELP=1`. A one-line "Type /help …" hint prints
once on entering the world instead of a popup (the original's login notice was
a web panel; not recovered, so nothing is claimed about it). The window is a
`HudWindow` built from `ifgameguide.txt` (a plain sized panel if an operator's
archive lacks it), with a left `ItemList` of documents and a `RichTextLabel`
fed by `MdToBbcode.convert` — headings, bold/italic, code spans and fences,
bullet/numbered lists, links as plain "text (url)", tables as monospace rows;
brackets escaped one-pass (`md_to_bbcode_test.gd`, 25 checks). The docs are
bundled by `client/tools/bundle_docs.sh`: it copies `docs/DEBUG_TOOLS.md` and
`docs/HELP_PLAYING.md` into `client/docs/` and generates
`client/docs/RELEASE_NOTES.md` from the last 20 `v*` tags (`git tag -n`); the
copies are committed because the release runner's checkout may be shallow, and
the notes file says it is a snapshot. `export_presets.cfg` gained
`include_filter="docs/*.md"` so the PCK ships them; `remote_godot.sh` ships
`client/docs` to the box. The GM section of DEBUG_TOOLS.md sits between
`<!-- gm-only -->` sentinels and is stripped for a non-GM.

### Discoverability

The chat input line and the underbar's menu button carry a tooltip (our
wording) listing the client commands, plus the GM line when `is_gm`. A GM sees
`GM tools: /tp /give /level /spawn /heal /gold /durability /sp /kill /goto --
type /help` once in chat on enter-world.

### Verification

Go: `go build ./... && go vet ./... && go test -count=1 -p 1 ./...` all green
(the `gm` and `session` packages included; `server/README.md`'s guard test sees
the new `-gm-accounts` row). Box: `remote_godot.sh check` → `ALL LOAD` (229
scripts, 5 scenes); `gm_test.gd`, `console_test.gd`, `md_to_bbcode_test.gd` →
`ALL PASS`. Two `--server` renders with `SERVER_BIN=/var/tmp/srv-debug` and
`SRREVAMP_QA_COMMANDS` feeding lines through the same parser as the chat: the
GM run (`SRREVAMP_GM_ACCOUNTS=qa`) and the non-GM run (unset) -- both from the
lane's own client copy (`CLIENT_DIR=/opt/srrevamp-client-debug`; the first two
attempts rendered the default `/opt/srrevamp-client` and proved nothing, which
is the trap to remember: `qa_shot.sh` does `cd "$CLIENT_DIR"`).

GM run, client log (`Console:`/`QA COMMAND:`/`CONSOLE:`/`GM REPLY:` are the
markers):

```
Console: GM probe sent for QaTester
Console: ready (help window authored frame, log .../SRRevamp/logs/srrevamp.log)
GM REPLY: GM: /tp <x> <z>, /goto <zone|monster>, /give <item id> [qty], /gold <n>, /level <n>, /heal, /spawn <monster> [n], /kill, /durability <slot> <n>, /sp <n>
QA HELP: opened the Help window
QA COMMAND: /where          -> CONSOLE: zone: jangan / local: 42.0, 1860.0 / world: 42.0, -30.1, -60.0 / walkable height ...
QA COMMAND: /fps            -> CONSOLE: FPS: 3.0            (a movie-writer run)
QA COMMAND: /entities       -> CONSOLE: monsters 23, npcs (name plates) 95, other players 0, ground items 0
QA COMMAND: /cam orbit      -> CONSOLE: Camera: orbit.
QA COMMAND: /frobnicate     -> CONSOLE: Unknown command /frobnicate. Commands: /help /where ... + the GM tools line
QA COMMAND: /give 3 5       -> GM REPLY: gave 5 x item 3
QA COMMAND: /give 3645 1    -> GM REPLY: gave 1 x item 3645
QA COMMAND: /gold 500       -> GM REPLY: gold now 1500
QA COMMAND: /level 3        -> GM REPLY: level 1 -> 3: +6 stat points (6 unspent), Str 22, Int 22, HP 229, MP 229
QA COMMAND: /heal           -> GM REPLY: healed: HP 229/229, MP 229/229
QA COMMAND: /sp 5           -> GM REPLY: skill points now 5
QA COMMAND: /durability 6 3 -> GM REPLY: slot 6 durability set to 3
QA COMMAND: /spawn MOB_CH_MANGNYANG 2 -> GM REPLY: spawned 2 x Mangyang (level 1, HP 54) at 48, -60 -- ids 25,26; no respawn
QA COMMAND: /tp -300 -880   -> GM REPLY: teleporting to -300.0, -880.0
QA COMMAND: /errors         -> CONSOLE: No script errors logged this session.
QA COMMAND: /copy           -> CONSOLE: Copied the debug report (4253 chars) to the clipboard.
QA COMMAND: /log            -> CONSOLE: Log file: .../srrevamp.log / Opened the log folder.
```

(`/spawn MOB_CH_MANGYANG` in the first pass was refused with the list of real
code names -- the roster spells it `MOB_CH_MANGNYANG` -- which is the "refuses
unknown, lists what it knows" behaviour working. The HUD in frame 150 shows
`Lv 3`, `229 / 229` after `/level 3`: the level-up went through to the stats
packet.) `/heal` did not reach the server in that first pass: `heal` was
missing from the console's forwarded-word list and fell to "unknown command";
fixed, and `console_test.gd` now checks every GM word forwards.

GM run, server log (every command with the account):

```
"GM accounts enabled" accounts=[qa]
"gm command" account=qa character=QaTester line="give 3 5" refused=false reply="gave 5 x item 3"
"gm command" account=qa character=QaTester line="level 3" refused=false reply="level 1 -> 3: ..."
"gm command" account=qa character=QaTester line=heal refused=false reply="healed: HP 229/229, MP 229/229"
"gm command" account=qa character=QaTester line="spawn MOB_CH_MANGNYANG 2" refused=false reply="spawned 2 x Mangyang ..."
"gm command" account=qa character=QaTester line="tp -300 -880" refused=false reply="teleporting to -300.0, -880.0"
```

Non-GM run (gate unset): the probe is silent (no GM line, no GM tools in
`/help`), and

```
QA COMMAND: /give 3 5       -> GM REPLY: GM commands are not enabled for your account.
QA COMMAND: /tp -300 -880   -> GM REPLY: GM commands are not enabled for your account.
QA COMMAND: /help           -> CONSOLE: Commands: /help /where /log /copy /fps /entities /wire on|off /cam free|orbit /errors /unstuck /w <name> <msg>
server: "no GM accounts set (-gm-accounts / SRREVAMP_GM_ACCOUNTS) -- the GM console is off"
server: "gm command refused: not a GM" account=qa character=QaTester line="give 3 5"
server: "gm command refused: not a GM" account=qa character=QaTester line="tp -300 -880"
```

`/where`'s first version printed `region y/x: 0/-1` -- arithmetic on the
world origin, i.e. the cell *relative to the zone centre*, not the real
region. It now finds the loaded `RealTerrain_<x>_<y>` cell whose own space
contains the player (the inverse of `_place_at_region_local`) and reports
that, plus the walkable graph's height and the terrain ray's.

### Left out (see docs/TODO.md)

- The original's help dialogs and the web panel were not recovered; the Help
  window's interior is ours.
- `/give` by item **code** is resolved client-side only when the code→id map
  is loaded; the server takes numeric ids.
- `/spawn` is not announced to *other* clients until their next monster list.
- The release notes are a committed snapshot; the release workflow does not
  yet regenerate them at build time (needs tags in the runner's checkout).
