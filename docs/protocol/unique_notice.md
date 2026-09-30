# Unique monster notices (round 657)

"Tiger Girl has appeared on Tiger Mountain." when a unique hatches, "[Aria] killed Tiger girl from
Tiger Mountain." when one dies: a line in the system window and the blue banner at the top of the
screen. Built in `server/internal/session/uniquenotice.go` and `client/scripts/net/unique_notice.gd`.

Labels: READ = read from the binary or the data; MEASURED = counted from real files; INFERRED =
follows from what was read but was not read itself; OURS = srrevamp's choice.

## Wire

Retail sends `0x300C` with a u16 word and a payload. srrevamp sends the same payload behind its own
opcode, `OpUniqueNotice 0x0110` (OURS; `PROTOCOL_DECISION.md`, the monster epic's decision D11):

| Word | Payload | Sent |
|---|---|---|
| `0x0C05` | u32 RefObjID | a class-3 monster appeared |
| `0x0C06` | u32 RefObjID, u16 length + killer name | a class-3 monster was killed |

READ, client: the handler `0x874ea0` reads the word (`0x874ee4`), then 4 bytes for `0x0C05`
(`push 4` at `0x8752ad`) and 4 bytes plus a string for `0x0C06` (`0x875521`, `0x875541`
`0x4f7a70`, an ASCII string widened by `0x4fc700`). srrevamp's name is UTF-8 with a u16 byte length
(the project's string shape, `encodeStrings`).

## Server (READ, SR_GameServer.exe)

- **Spawn.** `0x5f6eb0` builds the relay message `0x7808` carrying `0x300C` / `0x0C05` and the new
  object's RefObjID when the object's class (vslot 300, `+0x12c`) is 3 and the spawn's kind flag is
  1 (`iStack_c == 1`, what that flag means is OPEN). The relay goes to every world (`0x414970` ->
  `0x5f8620`, the planner's read).
- **Kill.** CGObjMob vslot 398 (`0x4c1c80`), called from the death path vslot 311 (`0x4c42f0`) with
  the killer that vslot 399 (`0x4c44a0`) picks:
  - class 3 only (`cmp al,3` at `0x4c1ccb`): the rank-8 bosses are not announced;
  - no killer, no notice (`test ebp,ebp; je` at `0x4c1cd7`);
  - a killer for which vslot `0x53c` answers 1 is not announced (what that vslot is: OPEN);
  - the name: `"???"` (the string at `0xaedda4`) when the killer's vslot `0x1c` answers 0, else
    the name by vslot `0xec` for a killer whose vslot `0x11c` is 4 and by `0xf0` otherwise (which
    name each gives: OPEN; srrevamp sends the character's name).
- **The killer (vslot 399, `0x4c44a0`).** Over the monster's damage list (`+0x1ca4`, entries with
  the attacker id at `+0x10` and its damage at `+0x14`): an attacker that is a pet is mapped to its
  owner (`+0x736*4`), one that is not a player is skipped (vslot `0x1c`). The group is the player's
  party when the party shares experience (`+0x72e*4` non-null, flag bit 0), else the player. A
  group's damage is summed; within it the member with the most damage is kept (`[9] < damage`);
  the group with the most damage wins (`uVar4 < [6]`) and its kept member is the killer. Both
  comparisons are strict; the order the entries are met in is a map's, not read (OURS: first-hit
  order, so the first of a tie wins).
- **The suppress key.** `CONTROL_NOTIFY_SPAWN_UNIQUE_MONSTER_MSG` is read at `0x60936f`; equal to
  `"ON"` (`0xb012f4`) it sets the world's `+0x108` (`0x6093b1`), which `0x608350` returns. Both
  notices ask the world first (`0x5f9910`, a world vslot; INFERRED to be that getter) and are
  skipped when it is set. Absent, both are sent.

srrevamp (OURS unless marked): `-unique-notice-off` is the key (default off: announce). The damage
list is `combat.Hub`'s, booked per attacker in first-hit order on every blow a player lands
(`ApplyDamageFrom`); the booked damage is the blow's as dealt, not clipped to the HP left
(INFERRED: the engine's credit site was not read). Every srrevamp party shares experience, and a
party of one is no party (the engine never makes one), so a group is a party of two or more. A
killer no longer in the world is `"???"` (INFERRED match for vslot `0x1c`). The notice goes to every
character on the server.

GM tools (OURS, not retail): `/spawnunique <id|name>` puts a unique down beside the GM and
announces it; `/damage <n>` deals a blow booked to the GM; `/kill` books nothing, and a unique it
kills with nobody on the list is announced with `"???"` (retail has no GM kill; its rule would say
nothing).

## Client (READ, sro_client.exe `0x874ea0`)

The line is chosen by the monster's name key -- the characterdata row's `SN_` string, the
reference object's `+0x60` (`0x93f630` looks the row up by RefObjID) -- compared with five keys:

| Key (`0x874ea0` strings) | Appeared | Killed, `"???"` | Killed by a player |
|---|---|---|---|
| `SN_MOB_CH_TIGERWOMAN` (`0xdda1f4`) | UIIT_MSG_APPEAR_TIGER_GIRL | UIIT_MSG_DEAD_TIGER_GIRL | UIIT_MSG_ANYONE_DEAD_TIGER_GIRL |
| `SN_MOB_KK_ISYUTARU` (`0xdda194`) | UIIT_MSG_APPEAR_IYUTARU | UIIT_MSG_DEAD_IYUTARU | UIIT_MSG_ANYONE_DEAD_IYUTARU |
| `SN_MOB_OA_URUCHI` (`0xdda140`) | UIIT_MSG_APPEAR_URRUCHI | UIIT_MSG_DEAD_URRUCHI | UIIT_MSG_ANYONE_DEAD_URRUCHI |
| `SN_MOB_TK_BONELORD` (`0xdda0e8`) | UIIT_MSG_APPEAR_BONELORD | UIIT_MSG_DEAD_BONELORD | UIIT_MSG_ANYONE_DEAD_BONELORD |
| `SN_MOB_RM_TAHOMET` (`0xdda090`) | UIIT_MSG_APPEAR_TAHOMET | UIIT_MSG_DEAD_UNIC (name) | UIIT_MSG_ANYONE_DEAD_TAHOMET |
| any other | UIIT_MSG_APPEAR_UNIC (name) | UIIT_MSG_DEAD_UNIC (name) | UIIT_MSG_ANYONE_DEAD_UNIC (killer, name) |

- ANYONE_DEAD vs DEAD is the killer's name compared with `"???"` (`0xdda02c`, `0x875593`): DEAD
  (". . . has disappeared") for `"???"`, ANYONE_DEAD with the killer's name otherwise. It is not
  about whether this player made the kill.
- A named APPEAR_ line is shown as it stands; every other line is `swprintf`'d (`0xb434fc`) into a
  0x200-character buffer: a named DEAD_ line with no argument, ANYONE_DEAD_ with the killer,
  APPEAR_UNIC / DEAD_UNIC with the monster's name (`0x8c9bb0` on the key; for Tahomet the key's text
  through `0x8c9c30`), ANYONE_DEAD_UNIC with the killer then the name.
- The comparisons are exact: the `_L2` / `_L3` rows (`SN_MOB_CH_TIGERWOMAN_L2`) take the generic
  lines.
- Five uniques are named, not seven.
- The texts are the archive's (textuisystem.txt), for example `[%s] killed Tiger girl from Tiger
  Mountain.` and `[%s] has killed [%s].` (READ from the box's archive; not copied into the repo).

Every line goes to both:

- **the system window**: `0x7781b0` with type 0 (`push 0` / `push ebp`, ebp 0): colour
  `0xffdbc99b` (types other than 6 draw `0xffdbc99b`; 6 draws `0xffbacff2`);
- **GDR_WARNING_WND**: `0x77b580` fetches interface child `0x23` (`0x8b51f0(0x23, 1)`) and hands
  it the text (`0x7b3eb0`), when the text is not empty (`+0x14 != 0`).

## The banner (READ)

GDR_WARNING_WND is a CIFNotify (ginterface.txt, ID 35), the class GDR_NOTICE is too. `0x7b3eb0`:
life 7000 ms, the window sized to the measured text, x = screen width / 2 - text width / 2, y =
`+0x7d4`; the update `0x7b3e20` fades the alpha to `remaining * 255 / 2000` over the last 2000 ms.

What makes this instance the blue one is CGInterface's setup (`0x78cbbe..0x78ce3b`), which
configures each CIFNotify after creating it:

| | GDR_NOTICE (child 0x14) | GDR_WARNING_WND (child 0x23) | child 0x2a |
|---|---|---|---|
| y (`0x7b3d40` -> `+0x7d4`) | 100 (`push 0x64`) | 130 (`push 0x82`) | 160 (`push 0xa0`) |
| frame (`0x819690`, `0x8199e0`) | com_notice_* (class default, `0x7b3fe0`) | com_warning_edge / edge2 / corner | com_quest_* |
| fill (`0x7b3d10` -> `+0x7d8..+0x7da`) | (128, 45, 67) | (0, 52, 92) | (0, 91, 66) |

- The fill is drawn by vslot 13 (`0x7b3cb0`) while the banner is up (`+0x7cc`, set by
  `0x7b3d50`): a quad (`0x654d10`) in `(a' << 24) | (r << 16) | (g << 8) | b` with
  `a' = -0x80 - (0xff - a) / 2` for the window alpha `a` (`+0x12d`) -- 128 at full alpha -- then the
  stretch frame (`0x81a450`).
- MEASURED (the box's Media.pk2, A8R8G8B8): every `com_warning_*` texel is (0, 52, 92), alpha 0..128
  (edge 4x8 mostly 128; corner and edge2 40x8 fading); every `com_notice_*` texel (128, 45, 67).
  So the banner is a translucent dark blue: the user's "blue banner".
- The text is ifnotify.txt's GDR_NOTIFY_TXT, FontColor (255, 255, 255, 255): white.
- The layout's `Color=COLOR,"255,119,119,251"` on GDR_WARNING_WND is not read by the client (the
  resinfo parser `0x82c1d0` reads no `Color` field; docs/WORLD_ISSUES.md) -- the blue is not from there.
- INFERRED: the fill quad covers the window's rect (its vertices come from the window; not read in
  detail); the frame is laid out as a stretch frame over it.
- The constructor sets `+0x7d4` to 0 (`0x7b3c40`); round 634 took that for GDR_NOTICE's y. The setup
  overwrites it: GDR_NOTICE sits at 100 and GDR_WARNING_WND at 130.

## Open

- What `0x5f6eb0`'s kind flag (`iStack_c == 1`) selects, and whether a unique's minions or a
  quest spawn are announced.
- Killer vslots `0x53c` (no notice when 1), `0xec` / `0xf0` (which name for which kind).
- The order ties are met in (the damage list's map order).
- The uniques' placement and rotation (round 660); until then only a GM spawn is announced.
