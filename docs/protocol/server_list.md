# The login screen's server list, its status, and what retail needs to connect (round 679)

Labels: READ (`/var/tmp/decomp_client`, `/var/tmp/sro_client.asm` on the render box, and constants
read out of `sro_client.exe`), MEASURED (the box's retail install, `/opt/sro-files/client`), INFERRED,
OURS, OPEN. The client side is `client/scripts/frontend/server_list_window.gd`,
`server_status.gd`, `gateway_query.gd` and `client/scripts/setting/`; the server side
`server/internal/session/serverstatus.go`. The operator's guide is deploy/README.md, "Configuring the
client: setting/config.yaml".

## The logo above the login box

- **READ, `FUN_00866760` (0x8667e4..0x866803):** the logo (pstitle Title id 8, `logo.ddj`, rect
  540,403 508x172 in the 1600x1200 design space, scaled by `CPSTitle::OnCreate`'s `FUN_00849c70` by
  w/1600 and h/1200 -- the floats 1600.0 and 1200.0 at 0xed7cc8 / 0xed7ccc, READ from the exe's
  .data) is placed at `(cx - w/2, mid + 6 - 0x78)`, whatever its height; the login window (id 9) at
  `(cx - 0x90, mid + 6)` (0x866860), unscaled.
- So the logo clears the box only while its scaled height is at most 0x78 = 120: a screen at most
  837 tall. At 1024x768 (the iSRO reference) it is 325x110, 10 above the box. At 1920x1080 it is
  610x155 and reaches 35 into the box; on a 3840x2160 screen at UI scale 1.95 (a 1969x1107 canvas)
  625x159 and 39 into it -- the "ONLINE" line behind the box in the user's screenshot.
- **OURS (round 679):** where retail's placement would overlap, the logo is lifted until it clears
  the box by 10 (`FrontEndFrame.LOGO_GAP`: retail's own clearance at 1024x768, INFERRED as the
  intended padding); where it does not, it stays exactly where retail puts it; its size is retail's.
  MEASURED in the client (`client/tools/login_at_scale.tscn`, `LOGINRECT`): 1024x768 logo 325x110 at
  y 270, box at 390 (retail's place, gap 10); 1920x1080 610x155 at 382, box 547; 3840x2160 at 1.95
  625x159 at 391, box 560.

## The login window's fields

- **Alignment, READ:** the layout parser stores `HAlign` (string 0xdd2764) as a u16 at
  descriptor+0x88 (0x82c76e..0x82c7a3). CIFEdit's text placement (vtable slot 13, `FUN_00637b70`,
  vtable 0xd9ae3c) reads it: 0 left; 1 centre, `left + (right - left - textWidth) * 0.5` (0.5 at
  0xe1b7d0); 2 right, `right - textWidth - 2.0` (0xe1b898). pstitle's Login section gives
  GDR_EDIT_ID (41), GDR_EDIT_PASS (42) and GDR_STA_SERVER (43) HAlign=1 and the labels 0: the ID and
  PW text is centred (READ); the server static's centring is INFERRED (CIFStatic's own text code not
  read).
- **The password character, READ:** `CPSTitle::OnCreate` sets style bit 2 on edit 42
  (`FUN_00652d20(2)`, call at 0x86bba6, ORed into +0x188); the edit's draw `FUN_00636330` tests it
  (`FUN_00652da0(2)`, 0x6363c8) and replaces the text with one `*` (0x2a) per character
  (`mov eax,0x2a002a; rep stos` at 0x6363d9). OnCreate also sets edit flags 0xa on 42 (0x86bbaf) and 2
  on 41 (0x86bb6d) -- OPEN what they mean.
- **Pre-filled, READ:** OnCreate fills the ID edit from 0xeed578+0x10 and the server static from
  0xeed578+0x30 (0x86bb8b, 0x86bbda). The last server is stored in the registry, HKCU
  `Software\Joymax\Silkroad` value `RECENTSERVER`: read at OnCreate (0x86ba94), written on a
  successful login (`FUN_00865b10`, 0x865c25), and pre-selected after each list fill
  (`FUN_00866c30(RECENTSERVER)`, 0x86aceb). Ours keeps the name in `user://settings.cfg`
  (`[server] server_name`).

## The server list window

- **The request, READ:** `CClientNet::vslot_002` (0x4c9410) sends 0x6101 with no payload. A login
  needs a shard: `CClientNet::vslot_004` (0x4c92c4) sends 0x6102 only when the list is non-empty:
  the content-id byte, the id, the password, a u16 shard id.
- **The fill, READ:** `CPSTitle::vslot_006` (0x86bfc0) handles the internal message 0xff2 with
  `FUN_00869cd0`, which fills list control 51 from `CClientNet`'s list (`DAT_0115b0bc+0xf4`, via
  `CClientNet::vslot_015`).
- **The entry, READ (as the list code reads it):** +0 u16 shard id, +4 the name (narrow), +0x20 u16
  current users, +0x22 u16 max users, +0x24 state byte, +0x25 farm id byte, +0x28 a flag byte, +0x2c
  the name (wide, the one shown). ~~The 0xA101 parser itself is not found~~ **Found in round 681:**
  `CClientProcess::FUN_004cda30` (via `vslot_016`) fills these fields from the wire, and
  GatewayServer's writer (0x405800, 0x412c80) agrees; the farm byte is conditional on both sides.
  The layout is in `opcodes/gateway.md`.
- **The status, READ (`FUN_00869cd0`, 0x86a703..0x86ac51):** per entry, `FUN_0080e130(row, 2, text,
  ARGB)`:

  | Test | Text key | English | ARGB |
  |---|---|---|---|
  | state == 0 | `UIO_STT_SERVER_TEST` | Check | 0xFFC0BDFF (0x86a97f) |
  | r = (float)cur / (float)max < lo | `UIO_STT_EXCELLENT` | Easy | 0xFF6DFFEF |
  | r < hi | `UIO_STT_CROWDEDNESS` | Populated | 0xFFFFDA49 |
  | r < 1.0 | `UIO_STT_SERVER_FULL` | Crowded | 0xFFFFB541 |
  | otherwise | `UIO_STT_SERVER_MAX_FULL` | FULL | 0xFFFF5858 |

  lo and hi are text, not code constants: `UIO_STT_SERVER_35` and `UIO_STT_SERVER_75` times 0.01
  (`DAT_00e1b820`). MEASURED in the box's textuisystem: `UIO_STT_SERVER_35` is 35 in the Korean and
  English columns; `UIO_STT_SERVER_75` is 65 in the Korean column and **97** in the English. This
  client's text table yields 35 and 97 (MEASURED: the row's columns read with dump_text_table.gd,
  column 2 = 65, columns 8 and 9 = 97, and parsed by the client's UiTextTable in
  server_list_test.gd). A max of 0: cur > 0 makes r inf, FULL; 0/0 is NaN, whose unordered x87
  compare takes the `jp` branches to Crowded (READ in round 679's review). Ours compares in integers,
  cur * 100 < pct * max, so 97/100 is Crowded exactly as retail's (a float32 0.97 had put it in
  Populated). A dword at 0xeed578+0x160, which 0x832a68 sets to 5 unconditionally
  (nop padding after it: INFERRED a binary patch), turns "FULL" and "Crowded" red (0xFFFF5858, the
  word "Crowded"): this vSRO client never shows FULL. Ours shows retail's unpatched FULL.
  `UIO_STT_TEST` ("Closed") is in the text table but no code names it (string scan).
- **The name's colour, READ (0x86a85b..0x86a8ac):** 0xFFFFDC50 when the entry's +0x28 flag is set,
  else 0xFFFFFFFF; the flag's meaning is OPEN. The list's default text colour 0xFFB4B4B4
  (`FUN_008b2ba0(3, ...)`).
- **The layout, READ (`FUN_00866760` 0x8668c1..0x866959; `CPSTitle::OnCreate` 0x86b947..0x86ba35):**
  window 10 (`server_window.ddj`, 240x340) at `(max(cx - 0x78, 0), max(mid - 0xaf, 0))`; Select (id
  56, `UIO_CTL_SELECT`) at `(x + 0x15, y + 0x15e)`, Cancel (55, `UIO_COMMON_CTL_CANCEL`) at
  `(x + 0x82, y + 0x15e)`. Columns (`FUN_0080eed0(x, width)`): name (15, 120), farm (100, 45; filled
  only when `DAT_0115b0c0[1] == 1`, aligned 2 by `FUN_0080e390(1, 2)`), status (152, 45). 13 rows
  visible (`FUN_0080e4d0(0xd)`; the slider 54 gets count - 13); the selection rect 0,0 204x20
  (`FUN_0080cd50`; 20-px rows INFERRED); the selected row's art `server_select.ddj`, the hovered
  one's `server_rollover.ddj`.
- **Behaviour, READ (CPSTitle's message map at 0xec34e0):** LIST (id 0x2c) -> 0x864c80 =
  `FUN_00864870(1, 0)`: sends 0x6101, selects the row named like window 43's text, fades window 10,
  Select and Cancel in and the logo, login box, Connect and Exit out over 0.5 s, `snd_window_open`.
  Cancel (0x37) -> `FUN_00864870(0, 0)`, the reverse and `snd_window_close`. Select (0x38) ->
  `FUN_00866eb0`: the selected row's column 0 into window 43 (`FUN_00866c30`), list hidden. List
  message 0x806d selects a row (0x864cb0); 0x806e (a double click, INFERRED) acts as Select with
  `snd_button_click` (`FUN_00866f80`).
- **The refresh, READ:** `CPSTitle::FUN_00864840` sends 0x6101 and sets +0x13c to 5.0 (0xe1b86c);
  `CPSTitle::vslot_012` (0x8691b0) counts it down by the frame time (the global 0x0110f7fc; frame time
  INFERRED) only while window 10 is visible and re-sends below 0: every 5.0 s while the list is open.
- **Unreachable, READ:** `CClientNet::vslot_000` (0x4c8ca0) returns failure codes 5-10 (10 the host
  lookup failed, 9 every gateway address failed); the title shows `UIO_MSG_ERROR_SEVER_CONNECT`
  "Failed to connect to server." with "(C<code>)" (`FUN_00861890`). Other refusals: code 3 on 0xff1
  `UIO_MSG_ERROR_NOT_SERVICE_TIME`; 0xff3 code 3/2 `UIO_MSG_ERROR_ACCOUNT_CONNECT_IMPOSSIBILE`
  ("Cannot connect to the server because the server is now in inspection."); code 6
  `UIO_MSG_ERROR_SERVER_BUSY_CONNECT_IMPOSSIBILE` ("The server is full, please try again later.").
  Retail has one gateway, so its whole list fails together: no per-row state (INFERRED).

## What retail needs to connect

- **DIVISIONINFO.TXT, MEASURED (35 bytes in the box's Media.pk2):** u8 locale (22), u8 division
  count (1); per division a u32 name length, the name (`DIV01`), a NUL, u8 gateway count (1); per
  gateway a u32 length, the host (one DNS name), a NUL.
- **Its reader, READ (`CGame::FUN_008469c0`):** opens `divisioninfo.txt` (0xdd3ed0, 0x846cc9; failure
  "divisioninfo.txt open fail" 0xdd3eb4); **skips the locale byte** (0x846dde..0x846e2a; nothing
  stores it); reads the count (0x846e45) and each division (name 0x846e9f, host count 0x846f03, the
  host loop 0x846f63..0x846fce). The gateway is `divisions[CGame+0x814].hosts[CGame+0x818]`
  (0x847040..0x847085), copied to CGame+0x744 (0x8470ab) -- not random. The two indices come from the
  command line: `sscanf("%d %d %d")` (0xdd3f18, 0x846b40) on the text after `/` into +0x810, +0x814,
  +0x818 (INFERRED: the launcher's `/22 0 0`); +0x810 picks the text-data folder (1
  `Silkroad_TestIn`, 6 `Silkroad_TestExt`, else `server_dep\Silkroad`; 0x848487..0x8484b2).
- **GATEPORT.TXT, READ/MEASURED:** `gateport.txt` (0xdd3ea4, 0x84712e), up to 8 bytes, atoi into a
  u16 at CGame+0x7e6 (0x847191). The box's says 31729 (a private server's port, not 15779).
- **The agent hand-off, READ:** `CClientProcess::vslot_014` (0x4ce9d0) branches on the server's
  identity name: `GatewayServer` (0xe1b310, 0x4cea72) -> it sends 0x6100 (the content-id byte, a
  string, a u32); `AgentServer` (0xe1b320, 0x4ceb36) -> 0x6103 (the u32 token the gateway gave, the
  username, the password, the content-id byte, a 6-byte MAC). So the agent is a second connection
  presenting the gateway's token; its address comes from the gateway's login reply. The 0xA102
  handler's address is OPEN (gateway replies reach the title as internal messages 0xff1..0xffc;
  `CPSTitle::vslot_006` compares 0xa106 at 0x86c006). Nothing lets the client choose the agent
  (INFERRED): a config-supplied agent is a proxy / private-server feature, OURS.
- **Region / locale, READ:** the content id is the u8 at net-state+0 sent in 0x6100, 0x6102 and
  0x6103 (who sets it is OPEN); DIVISIONINFO's locale byte is never read; no "Located In" string
  exists in the exe (ASCII or UTF-16; round 678 found its art unused too); option.txt's parser
  compares a `Language` key (0xdd3e24, 0x847b5e) but the box's option.txt has none, and what it does
  is OPEN. So `global.region` maps to nothing READ: parsed, kept, reserved.
- **Retail's `Setting\` folder, READ:** `%s\Setting\%s` (0xd960b4) with `SROptionSet.dat` (0xd960c4),
  `wndpos.dat` (0xdba05c), `chop.dat` (0xdbb6a0), `SRExtQSOption.dat` (0xda0528),
  `SRChattingBlockingList.dat` (0xd8d9f4), `gmwpfort.dat` (0xd881bc), `gmwp.dat` (0xd8831c), `srch.txt`
  (0xd87a34), `GNGWCRank.txt` (0xd89364), `Exception.dat` (0xdd2e98), `Setting\` and `Setting\*.*`
  (0xdd2f2c, 0xdd2f38). The box's install also holds `GameStatus.dat`, `SRExtQSOption2.dat` and
  `dances.dat` there (MEASURED). Retail keeps its client options beside the exe in `Setting\`; ours
  is `setting/`.

## Legacy servers (round 681)

Each server in `setting/config.yaml` now says which protocol it speaks: `type: opensro` (round 679's
0x0007 question below) or `type: legacy` -- the ORIGINAL gateway protocol, asked the way the retail
client asks for its list. `type` is required; an entry without it, or with another word, is skipped
with a `SETTING:` warning naming the server and the two values (OURS, the user's decision of
2026-10-01). The plain editable host:port field (no config) is our own server and keeps the
OpenSRO question.

- **The question (READ, `opcodes/gateway.md`):** the server's 0x5000, the key exchange, 0x9000, the
  client's 0x2001 "SR_Client", the server's 0x2001 "GatewayServer", 0x6100 (content id,
  "SR_Client", version), 0xA100 (a massive 0x600D pair from GatewayServer), 0x6101, 0xA101. Then the
  connection is closed (OURS): nothing that looks like a login is ever sent.
- **The content id and the version are the player's archive's** (`RetailClientInfo`): the first
  byte of Media.pk2's `divisioninfo.txt` (READ: what the launcher passes as the first command-line
  number) and the number in `sv.t` (READ: Blowfish with "SILKROAD", atoi; an interoperability fact
  read from the binary, no public source cited). MEASURED in the box's
  Media.pk2: 22 and 1000. Without Media.pk2 a legacy row is "Closed" with the reason logged: nothing
  is guessed.
- **The rows (OURS):** a legacy server that answered has one row per shard it lists, named
  `<config name> - <shard name>` (the config name alone when the two are the same), each with its
  own band by the same compare as before (`ServerStatus.shard_band`, state 0 = Check). Before the
  answer, and when there is none, it has one row under its config name, as an OpenSRO server. Any
  of its rows chooses the server. Retail shows only shard names because it has one gateway; a
  config may list several, so the server's name stays in front.
- **Limits (OURS):** 4 s for the whole question, up to 3 connections (a session given a checksum
  table that cannot be built is ended before anything is sent and tried again: `handshake.md`), 64
  KiB read per connection, frames of at most 4096 bytes (READ for encrypted ones), 64 frames, a
  strict reading of every message. Every failure is "Closed" with a `SERVERLIST:` line saying why;
  the 5 s refresh is retail's.
- **What a legacy server is never sent:** this project's 0x0007 (status) and 0x0005 (theme: the
  login screen skips its theme question for a legacy server and keeps its own intro). Round 788:
  Connect logs in to it the original way on a connection of its own (opcodes/gateway.md, "Logging
  in"), the chosen row's shard name giving 0x6102's shard id; the world past character select is
  not supported yet (OURS).
- **Testing without anyone's server:** `go run ./cmd/retailgw serve -listen 127.0.0.1:15779
  -shards "Name:120/1000:1,Other:0/500:0"` runs a fake retail gateway (the server side of the
  handshake, READ); `client/tools/retail_status_probe.gd -- --gateway=127.0.0.1:15779` asks it as
  the list does and prints the values the archive gives.

## Ours (round 679)

- **setting/config.yaml** (`ClientConfig`, `YamlLite`): `global.loginScreen`, `global.region`,
  `servers.<name>.gateway` / `.agent`; the folder is `<exe dir>/setting` or `OPENSRO_SETTING_DIR`.
  Data only.
- **The status exchange:** `OpServerStatusRequest` 0x0007 (no payload) -> `OpServerStatus` 0x0008:
  `u8 version (1) | u16 LE current | u16 LE max | u8 state` -- retail's three entry fields in retail's
  order, state 0 = Check, 1 = open. Answered before login, once per connection; an unauthenticated
  asker's connection is ended after it (as the theme's). Current = characters in the world
  (`world.Hub.Count`), not sessions at character select; max = `-max-players` (default 1000, OURS);
  state 0 under `-inspection`. The connection, packet and disconnection log lines of these
  one-question connections (and the theme's) are at Debug (`gateway.Server.Quiet`). The
  client asks every listed server at once on its own connections (`GatewayQuery`, a 2 s timeout, a
  host name resolved without blocking and its IPv4 address preferred), and again every 5 s while
  the list is open.
- **Unreachable:** the row shows `UIO_STT_TEST` "Closed" in the list's default 0xFFB4B4B4. Connect
  to such a server shows retail's "Failed to connect to server." (without the code).
- **The gate:** under `-inspection`, or with `-max-players` characters in the world, a login gets
  retail's inspection or full message (`session.LoginGate`); the `-gm-accounts` names pass both.
- **Connect resolves a name the way the status does** (`NetClient`, round 679's review): without
  blocking, its IPv4 address first (`GatewayQuery.pick_address`); the TLS name stays the host name.
- **Left out:** the 0.5 s fades of the list (it shows and hides at once), the farm column, the
  name's gold flag, the slider's drag (wheel and arrows scroll).
