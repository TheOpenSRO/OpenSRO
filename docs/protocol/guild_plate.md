# The guild line over a character, and the grant name (round 814)

The original draws a character's guild above its name, `[Guild * Grant]`, or `[Guild]` with no grant
name. The grant name is the member's guild nickname. Retail lets only the guild master assign it.
OpenSRO lets each member set **their own**, at the user's request (OURS).

Labels: **READ** = from the binaries (client decompile `/var/tmp/decomp_client`, asm
`/var/tmp/sro_client.asm`; server dump via `/var/tmp/rebox.py`, all on the render box); **MEASURED**;
**INFERRED**; **OURS**; **OPEN**.

Code:
- server: `server/internal/guild/nickname.go`, `server/internal/session/guildplate.go`, `pcspawn`'s guild block;
- client: `client/scripts/net/guild_plate_net.gd`, NetClient's `user_guilds` / `own_guild_line`,
  World3D's `_apply_guild_line`, the guild window's grant-name button, the console's `/grantname`.

## What the client keeps (READ, the spawn reader `GlobalDataManager::FUN_009ddc40`)

| field | where | read at |
|---|---|---|
| guild name | CICUser `+0x7e4` | the string after the trade-rank byte, whatever the job state (asm 0x9ddf4b) |
| guild id | (handed to the plate builder) | the guild block's first u32, only with job state 4 (0x9ddfbe) |
| grant name (nickname) | `+0x7c8` | the block's string, set by `FUN_009dc520` only when non-empty (0x9de08c, `add ecx,0x7c8` at 0x9dc549) |
| crest revision, union id, union crest revision | (plate builder) | three u32 |
| a byte (`FUN_005cffe0`'s on the server) | | u8; with a non-zero guild id and 0 the client files the guild (`FUN_00469a60`), with 1 another set (`FUN_00469e00`) -- OPEN what either is |
| fortress role | `+0x81c`, its title at `+0x800` | u8 through `UI_FORT::FUN_009dc590`: 1 Commander, 2 Subcommander, 4 Battle manager, 8 Product manager, 0x10 Trainer manager, 0x20 Engineer (`UIIT_STT_FORT_GUILD_*`) |

The plate itself is built when the guild name is non-empty (`+0x7f8`): `FUN_009dc460`, then
`FUN_009a4f40`.

## How it is drawn (READ)

CICUser slot 15, event 4 (`GlobalDataManager::FUN_009dea30`, asm 0x9df082..0x9df21f):

- **Gating.** It is drawn when:
  - a plate exists (`+0x7c4`);
  - the job state is 4, i.e. no suit (vslot `0xac`, 0x9df099);
  - the game option byte `FUN_004f9d00()+0x10` is set (OPEN which option; OpenSRO: always on).
- **Text.** The constants are `[` 0xe18b24, ` * ` 0xde3050, `(` 0xdbbfcc, `)` 0xda8fa8 and `]` 0xe18b28.
  - With a grant name: `"[" + guild + " * " + grant` + (`"(" + fortress role + ")"` when that is set and
    the check `FUN_00939a60` / `FUN_0093a610` on 0xeedf08 passes, OPEN) + `"]"`.
  - With no grant name: `"[" + guild` + the same optional role + `"]"`.
  - OpenSRO draws no role: it has no fortress roles.
- **Plate.** It is its own plate item (`FUN_008b4f30`), set through the name setter `FUN_008b3bd0`. That
  is font 0 with the box 0x40000000, the same plate the name uses (round 811).
- **Position.** It is drawn at the name plate's projected point less **20.0 px** in y (`fsub [0xe1b830]`,
  20.0, on `+0x4f4` at 0x9df0c0). So it is 20 px above the name line and centred where the name block is
  centred.
  - That makes it ride a mount with the name (round 811's `FUN_009d0a80` mount path).
  - MEASURED in the user's 2x private-server screenshot: 40 px apart, both centred near x = 270.
- **Crests.** They are drawn left of it (`+0x34`, `+0x38`). OPEN: OpenSRO has no crests.
- **Colour.**
  - The own character (an exact CICPlayer, `FUN_009dc460` at 0x9dc4d4): **0xfffead2e** = (254, 173, 46),
    orange.
  - Everyone else (`FUN_009a4f40`):
    - **0xffa0fe68** (green) if the guild name is in the list at manager `+0x98` (`FUN_00996d60`);
    - else **0xffff0000** (red) if it is in the list at `+0xa4` (`FUN_00992a90`);
    - else **0xff66b9ff** = (102, 185, 255), light blue.
  - INFERRED: the two lists are allied guilds and war enemies. OpenSRO forms neither (`guild/alliance.go`
    and `guild/war.go` hold rules only), so green and red are OPEN; OpenSRO uses light blue.

## The grant name (READ, server unless marked)

- **Request `0x7256`** (`GObjPC_HandleGuildMsg_256` 0x517b70): u32 target character id, then the name.
  - It is answered `{u8 2, u16 code}` on a refusal (`Msg_SendTwoFieldReply`).
  - `FUN_005c7560` checks, in order:
    1. in a guild, else `0x4c0d`;
    2. the guild's level at least 4, else **`0x4c51`** (no name in the client's table);
    3. the guild master, else `0x4c1e` PERMISSION_DENIED;
    4. the name's byte length under 13 and the name filter `FUN_004184a0`, else `0x4c4d`
       GUILD_ERROR_NAME_GRANT_SPECIAL_LETTER.
  - Then it sends ShardManager job `0x25`.
- **Reply `0xB256`** (client `FUN_0088f9e0`): `u8 1`, u32 (INFERRED the guild's id), u32 the target (looked up
  in the roster, `FUN_00996040`), the name.
  - The client shows `UIIT_MSG_GUILD_NAME_GRANT_RESULT` and sets the named character's nickname.
- **Broadcast `0x3256`** (client `FUN_008905d0`; server `CMainProcess::FUN_005cc070`, from the job reply
  `FUN_005c9bd0`): u32 (INFERRED the guild's id), the member's name, the grant name.
  - The character found by that name gets the nickname, and so does the guild window's row.
  - INFERRED: it goes to the guild.
- **Plate update `0x30FF`** (client `FUN_0088a420`): u32 uid, u32 guild id, the guild name. With a name, then
  the grant name, three u32, the role byte, then the `FUN_005cffe0` byte.
  - Note that order: role then membership, the reverse of the spawn's.
  - The server sends it from `FUN_004ea2f0`, called by the create and join job replies (`FUN_005c8bf0`,
    `FUN_005c8d40`), `CGObjPC::vslot_391` and `FUN_005c50b0`.
  - An empty name changes nothing in the original's client. How it drops a line is OPEN.
- **Window (client).** CNIFGuildWnd's fourth command button (47 → 40; the dispatcher `0x5b63e0`, index 3)
  opens `UI_SILKMALL 0x641f40`'s grant-name box (purpose 3, asm 0x642555..0x642748) for the selected
  member (`+0x79c`). The box:
  - 360x170;
  - title at (67, 57) 225x14: `UIIT_MSG_GUILD_NAME_GRANT_INPUT` formatted with the member's name;
  - frame (control 11) at (51, 78) 260x28, backing tile (control 12) at (55, 82) 252x20;
  - an edit of 12 at (58, 82) 243x20;
  - OK at (95, 124), Cancel at (183, 124).
  - Index 2 (button 39) is the expulsion question and index 4 (button 41) the position grant.

## OpenSRO

- **Store.** `guild.Member.Nickname` is `guild_members.nickname`, added with `ADD COLUMN IF NOT EXISTS`
  (MemStore and SQLStore).
  - `Store.SetNickname(actor, target, name, filter)` runs `guild.CheckNickname`: the retail order, with
    the master test replaced by **actor == target** (OURS, refused `0x4c1e`). The level gate is one
    constant, `guild.MinLevelForNickname` = 4.
  - An empty name clears it (OURS: INFERRED the original's handler takes length 0).
  - Leaving drops it with the membership.
- **Server.**
  - `0x7256` → `0xB256`, then `0x3256` to the guild's online members.
  - `0x30FF` to every viewer (and the character itself) on a create, a join, a leave and a grant name.
    OURS: the original does it on a create and a join. The rest keep a viewer's line from going stale.
  - A character entering the world is sent its own `0x30FF`. OURS: retail's own-character data is not
    modelled.
  - The spawn record (`pcspawn`) carries the name, the id and the grant name, from a per-character cache
    (`guildPlateOf`) that every change refreshes.
  - The block's other fields are written 0.
- **Client.**
  - The line is a Label3D "GuildLine" beside the "Name" plate (`_apply_guild_line`), in the plate's
    look.
  - Laid out with the name (`_layout_guild_line` from `_layout_job_decor`) and raised with it
    (`_set_plate_y`).
  - Removed in a job suit, or with no guild.
  - Grant name: `/grantname <name>` (up to 12 bytes; nothing clears it), or the guild window's button
    40, which opens the box for the player's own name. This client fills no member rows yet, so the box
    is not tied to a row (OPEN). The result is shown in the chat (`ErrorText.grant_name_line`).
  - GM tool (OURS): `/guildlevel <1-5>` raises the GM's guild through the store's own level-up, so a
    grant name can be tried at level 4.

## OPEN

- Green and red lines (alliances, wars), crests, fortress roles and their `(role)` suffix.
- The display option, and how the original drops a line.
- The membership byte's meaning, and `0x4c51`'s text.
- Member rows in the guild window.
- Whether the level-4 gate stays: the user is asked.
