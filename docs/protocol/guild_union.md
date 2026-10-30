# Unions (guild alliances), the players' flow (round 844, lane U)

The request, the answer, leave, expel, the union broken, the union pane in the guild window, union chat
and the union's crest, both sides. Labels: **READ** (`c:` sro_client.exe, `s:` SR_GameServer.exe, `sm:`
the ShardManager), **MEASURED**, **INFERRED**, **OURS**, **OPEN**. Round 842 (guild_plate.md, "Colour";
WORLD_ISSUES lane P) built the union record (0x3102, 0x38F5 types 0x0d / 0x12) and the green lines;
alliance.go has round 717's reading of the validator. Code: `server/internal/guild/union844.go`,
`server/internal/session/unionops.go`, `unionops_crest.go`; `client/scripts/net/union_ops.gd`,
`client/scripts/ui/hud/union_pane.gd`, `client/scripts/world/union_world.gd`.

## The request (READ)

- **Who and from where.** Only the union pane's Apply button (51, `UIIT_STT_GUILD_RESPECT_ALLY_JOIN`
  "Apply") sends it: the pane's dispatcher `c:0x57d060` jumps to `SendGuildMsg_0fb` (`c:0x8201b0`), whose
  only caller that is. There is no target-menu or chat route. The sender takes the selected object
  (`c:0x778b70`); a pet stands for its owner (its `+0xf8`); nothing is sent with no selection or with the
  player selected.
- **0x70FB** `{u32 target uid}` (`GObjPC_HandleGuildMsg_0fb s:0x5170b0`): the target in reach (else 3),
  a siege period's 0x4c75 (OpenSRO has no sieges), then `Guild_ValidateAllianceRequest` (`s:0x5c6550`)
  in this order: the requester dead 0x4c07; no guild 0x4c0d; not its master 0x4c1e; **in a union whose
  first guild is not the requester's: 0x4c1e** (`s:0x5b9260` slot 0 against the requester's guild -- only
  the union's lead guild asks more guilds in); the requester's guild level < 2 0x4c2a; the target not a
  live player 3; the target with no guild 0x4c25; the target's guild hostile 0x4c42
  (`UIIT_MSG_QUESTION_GUILD_RESPECT_ALLY_NOTALLY` "Cannot propose an alliance to a hostile guild." -- the
  test is the target guild's vslot 0x1c; that it is hostility is INFERRED from the message); the same
  guild 0x4c26; the target's level < 2 0x4c2b; the target's guild in a union 0x4c28; the target not its
  guild's master 0x4c24; then the wait response of **kind 6** (`s:0x5c66dc mov bl,0x6` into
  `s:0x4ea0d0`), which sends the target **0x3080 `{6, u32 requester uid}`**; a target already waiting on
  one makes the maker fail and the validator answer 3. A valid request sends the requester nothing.
- **Refusals** go back as **0xB0FB `{2, u16 code}`**; the client (`c:0x881dd0`) shows them through the guild
  category (`c:0x7ba32b`, `UIIT_MSG_GUILDERR_*`). Codes with no row there show nothing: 0x4c10, 0x4c2e,
  0x4c2f, 0x4c30 (MEASURED: the index bytes at `0x7bbc80` give 0x41, the silent default).
- **The box** (`NetProcessInInterface::FUN_0088aa60` case 6, `c:0x88afb4`): dropped unless the requester is
  a spawned player with a guild record (`c:0x9db0f0`); else box **0x1d** with that guild's name
  (`UI_SILKMALL::FUN_00644c90` case `0x647a01`): resized to 0x1d6 x 0x90 (470 x 144), title
  `UIIT_STT_GUILD_RESPECT_ALLY_JOIN` "Apply", +0x840 `UIIT_MSG_QUESTION_GUILD_RESPECT_ALLY_JOIN` "The leader
  of [%s] guild proposed an alliance with you. Do you accept?" moved 0x4c right, OK and Cancel 0x51 right,
  +0x808 hidden, the box's timer armed (`0x644650`). Its answer (`c:0x797d90` case `0x798667`): Yes
  `{1, 1}`, No **`{2, u16 0}`** (a zero code, where the guild invitation's No sends 0x4c16).
- **The answer** (`trs_wait_response::FUN_005c8510` kind 6): either side gone 2; a No **0x4c2e** to the
  requester (no text: the requester sees nothing). A Yes is the ShardManager's job 0xb (`sm:0x438f..`):
  the requester's guild gone 0x4c0d, the target's 0x4c25, the target's guild in a union 0x4c28, the
  target not its master 0x4c24, the requester's union with no free slot **0x4c29 ALLIANCE_FULL** (the
  ShardManager raises it -- `sm:0x434300` finds the first free slot of eight; this corrects alliance.go's
  "raised nowhere", which searched only the GameServer); then `_AllianceCreate` (a new union, the
  requester's guild first) or the target's guild into the requester's union. A success sends no 0xB0FB
  (`s:0x5c8990` case 0xb does nothing). **30 s** with no answer: 0xB0FB {2, 0x4c10} to the requester only
  (`s:0x46ce51`); the target's box closes by its own timer.
- **Who leads.** The created union's first guild is the ShardManager message's first (`s:0x5ca5a0` puts it in
  slot 0); that it is the requester's is INFERRED from the validator (a union's slot-0 guild alone may
  invite) and from the refusal names (`TOO_LOW_CREATOR_ALLIANCE` for the requester).

## The union told (READ)

- **Formed** (`s:0x5ca5a0`): both guilds 0x3102. **Joined** (`s:0x5ca740`): the new guild 0x3102, every other
  guild 0x38F5 type 0x0d with its entry (`s:0x5b8f80` -> `s:0x5c44f0`), whose client prints
  `UIIT_MSG_GUILD_ALLY_JOIN_RESULT` "An alliance with [%s]guild has been formed.". 0x3102 prints nothing
  (`c:0x87fd00`): the requester's own side sees the pane and the green lines, no line.
- **Out** (`s:0x5ca850` -> `Alliance_RemoveGuild s:0x5b8cf0`): 0x38F5 `{0x12, how, u32 guild}` to every guild
  of the union **including the one going** (its client clears its union, `c:0x988a60`); then, when the
  ShardManager answers 3 -- **the guild gone was the union's first, or fewer than two are left**
  (`sm:0x4369f0`: `leader == guild || count < 2`) -- the union broken: `{0x12, 3}` to the guilds still in it
  (`sm:0x43d290` -> `s:0x5b8dd0`), "Guild alliance has been broken.". OpenSRO dissolves the store's union
  then (`UnionBreaker`). A disbanded guild leaves its union the same way (INFERRED: the same job).

## Leave and expel (READ)

- **Secede** (52, enabled for any union guild's master): the question `UIIT_MSG_GUILD_QUESTION_ALLY_EXIT`
  "Will you leave the guild alliance?" under `UIIT_STT_GUILD_RESPECT_ALLY_EXIT` "Secede" (`c:0x57ce70(1)`:
  `GInterface 0x788270`, MsgBoxSimple 360 x 151, style 1 Yes / No; one question at a time, +0x7cc). Yes:
  **0x70FC** (no body, `c:0x8202f0`). Server (`s:0x5171d0` -> `s:0x5c6710`, `sm:0x4391d0`): no guild 0x4c0d,
  not the master 0x4c1e, no union 0x4c2f; then the out above with how 1, and **0xB0FC {1}** between the
  0x12 and the break.
- **Expel** (53, the lead guild's master only, a guild selected): `UIIT_MSG_QUESTION_GUILD_RESPECT_ALLY_EXPEL`
  "Will you ban [%s]guild from the guild alliance?" under `UIIT_STT_GUILD_RESPECT_ALLY_EXPULSION` "Expel";
  Yes: **0x70FD `{u32 guild id}`** (the box's "ban_guild_id", `c:0x57ac10`). Server (`s:0x517250` ->
  `s:0x5c67a0`, `sm:0x439350`): no guild 0x4c0d, not the master 0x4c1e, no union 0x4c2f, not the union's
  first guild 0x4c1e, the guild not in the union 0x4c30 (the ShardManager: gone 0x4c25); then the out with
  how 2 ("[%s]guild has been banned from the guild alliance."), **0xB0FD {1}**, and the break rule.

## The union pane (READ; CNIFAllianceGuild, `guild_r.2dt` record 86)

It is the Relations tab's (73) first sub-tab (87 "Union"; 88 is the hostile guilds', lane V). MEASURED
from the archive: a left frame "<Union guild information>" (174) with Lead guild (175) and its mark
(178) and name (158), Guild master (176) with the race mark (149) and name (179), Number of guilds (177)
"%d/%d" over 8 (151); a lower frame "<Details>" (152) for the selected guild -- Name (156) with its mark
(161) and name (155), Guild master (153) with race (162) and name (148), Number (159) "%d/%d" its members
over its level's cap (160; `0xd8c434`: 15, 20, 25, 35, 50); the list with the Name (56) and Lv (60) headers
and ten rows (CNIFAllianceSlot 271..307: 127 name, 128 "Lv %d", 131 mark); Apply 51, Secede 52, Expel 53;
"Not in the alliance" (137) and "No guild is selected." (136).

- **Refresh** (`c:0x57c6f0`) and **the rows** (`0x5804a0 -> 0x57fff0 -> 0x57e6f0 -> 0x57d0a0`): the lead
  guild is the entry whose id is 0x3102's third u32 (`0x996ed0`, the record's +0x240 -- which settles round
  842's INFERRED "slot 0's guild, the leader"); its row's name and level are drawn **0xffffb451** (`0x57d148`),
  the others white; the race mark from the entry's u32 after the master's name (the master's model: READ,
  `0x93f370 -> +0x9c`); the selected guild's members are the entry's last byte (READ). The rows' order:
  sort mode 2 at construction (`0x57f8a9`, the union map's order, ascending ids); the Name header sorts by
  name, the Lv header by level (the multimap walked from its end, so the highest first -- INFERRED from the
  walk).
- **Selection**: a left press on a filled row (`0x57e820`) selects it (`0x57e680`): the bars follow
  (`com_bar01select_Left` / `com_bar01_Left`, `0x57d240`) and the lower frame fills.
- **Buttons** (`0x57bfc0`): all off; a guild master: Apply on; in a union led by the player's guild:
  Secede and Expel on as well; another union guild's master: Apply off, Secede on.
- **When**: its ShowWindow (`0x580600`) and the guild window's show (`0x5bb0e1`); 0x3102 (`0x87fd00`),
  0x38F5 0x0d (`0x580650`), 0x12 (`0x580630` / `0x580720`) -- these refresh with no guild selected.

## Union chat (READ)

- The client puts **"-<own guild>): "** before a union line's text (`c:0x7ada5a`, `L"-%s): "`), so every
  reader shows `name(Union-Guild): text` (`UIIT_STT_GUILD_RESPECT_ALLY` "Union", colour 0xffc2f573, the
  %Union tab; docs/protocol/chat.md).
- The server (`GObjPC::FUN_004b1750` case 0xb): no guild **0x200b**, no union **0x200c** (both
  `UIIT_CHATERR_ALLIANCE_PERMISSION_DENIED`), neither the guild's master nor holding permission bit
  **0x04** (`CGuild::HasPermission(4)` `s:0x5d0f80`: `perm & 4 == 4` -- the bit guild.go left unnamed)
  **0x200e** `UIIT_MSG_GUILD_UNION_CHAT_LIMIT`; else the line to the union's every guild (`s:0x5c36c0` ->
  0x78fe to the ShardManager), and each client drops the copy with its own name (`c:0x8780f1`, the
  default case of 0x3026's switch) and shows its own from 0xB025.
- The bit is granted in the guild window (button 38 `UIIT_CTL_GUILD_UNION_CHAT_GRANT` / `_CONFIRM`, the
  permission update `s:0x5c69f0`): at most **12** holders per guild (`s:0x5c49a0`: the set must stay
  under 0xd), else 0x4c4b `UIIT_MSG_GUILD_UNION_CHAT_FULL`. That window is the guild permissions' (lane G).

## The union crest (READ)

- Register / delete (`s:0x5c7710` / `s:0x5c77d0`, after round 824's guild level < 5 0x4c4a and the master
  0x4c1e): no union 0x4c2f, the guild not the union's first 0x4c1e, a crest already 0x4c4e / none 0x4c4f;
  the ShardManager's job 0x28 / 0x29.
- 0x3257 type 2 (`c:0x8958e3`): `{u32 union id, u8 n, n x str guild name, u32 rev}`; each named guild's
  crest cache entry takes the union's crest, and the own union's revision is kept when the id is the own
  union's (`c:0x895a3b`).
- Drawn on the plate 36 px left of the guild text (`0x9df4ad..0x9df5ea`: the entry's +0x38 texture, the
  same 16 x 16 quad as the guild's at 20 px, `0xde3048` = 36.0).
- OURS as for the guild's: the bytes come from this server (OpCrestGet kind 2), not an FTP host; the
  revision is one past the union's last (`guild_unions.crest_last_rev`, INFERRED as the guild's).
- The union pane's marks (178, 161, the rows' 131) keep the archive's `gil_mark01.ddj`: no setter for
  them was found in the pane's code (OPEN whether something else draws crests there).

## OPEN

- What the target guild's vslot 0x1c tests (0x4c42, INFERRED hostility); lane V's guild wars can set
  `unionHostile` (unionops.go).
- The union crest's box texts: the register box (0x18) refuses an existing crest by the own union's
  revision (INFERRED from the guild's 0x15).
- Whether a disbanded lead guild breaks its union: INFERRED yes (the same ShardManager job).
- The siege period's refusals 0x4c75..0x4c77 (no sieges).
