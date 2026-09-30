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

Vtable calls are written as the byte offset the code uses (`vtable +0x12c` is `call [eax+0x12c]`,
slot 75); `vslot 398`/`399`/`311` are RTTI slot numbers.

- **Spawn.** `0x5f6eb0` builds the relay message `0x7808` carrying `0x300C` / `0x0C05` and the new
  object's RefObjID when its 13th argument, the announce flag, is 1 (`cmp [esp+0x74],1` at
  `0x5f71bd`) and the object's rank is 3 (`vtable +0x12c`, slot 75 -- the rank getter
  `combat/rarity.go` names -- then `cmp al,3` at `0x5f71d4`). The relay goes to every world
  (`0x414970` -> `0x5f8620`, the planner's read).
- **The announce flag (round 657 review, READ).** Nest_Hatch (`0x5607b0`) asks the world at
  `0x560c32` (`0x5f9910`) and passes `answer == 0` (`neg; sbb; add 1`, pushed first at `0x560c44`,
  i.e. the 13th argument) -- so a nest's hatch is announced only while the world's suppress flag is
  clear. The other callers push a constant 1: the GM command handler
  GObjPC_MsgHandler_SpecialCommand (`push 1` at `0x520bd5`), the minion executor `0x596e50`
  (`0x5977a4`), the trigger action MONSTER_LOAD_MONSTER (`0x5f9107`), `0x49e620` (`0x49e973`). So a
  GM-spawned unique is announced whatever the key says; the rank test still limits it to class 3.
- **Kill.** CGObjMob vslot 398 (`0x4c1c80`), called from the death path vslot 311 (`0x4c42f0`) with
  the killer that vslot 399 (`0x4c44a0`) picks:
  - rank 3 only (`vtable +0x12c`, `cmp al,3` at `0x4c1ccb`): the rank-8 bosses are not announced;
  - no killer, no notice (`test ebp,ebp; je` at `0x4c1cd7`);
  - not for a world whose suppress flag is set (`0x5f9910` at `0x4c1d06`);
  - not when the killer's `vtable +0x53c` answers 1 (what that is: OPEN);
  - the name: `"???"` (the string at `0xaedda4`, `0x4c1dd1`) when the killer's `vtable +0x1c`
    answers 0, else the name by `vtable +0xec` for a killer whose `vtable +0x11c` is 4 and by
    `+0xf0` otherwise (which name each gives: OPEN; srrevamp sends the character's name). Vslot 399
    has already dropped every entry whose `vtable +0x1c` answers 0, so from this caller the "???"
    branch is not reached.
- **The killer (vslot 399, `0x4c44a0`).** Over the monster's damage list (`+0x1ca4`, entries with
  the attacker id at `+0x10` and its damage at `+0x14`): each id is resolved to its object
  (`0x485d90` -> `0x41ccf0`, a map lookup that answers 0 for an object no longer in the world) and
  a null one is skipped; a pet is mapped to its owner (`+0x736*4`); one whose `vtable +0x1c`
  answers 0 (not a player) is skipped. The group is the player's party when the party shares
  experience (`+0x72e*4` non-null, flag bit 0), else the player. A group's damage is summed;
  within it the member with the most damage is kept (`[9] < damage`); the group with the most
  damage wins (`uVar4 < [6]`) and its kept member is the killer. Both comparisons are strict; the
  order the entries are met in is a map's, not read (OURS: first-hit order, so the first of a tie
  wins).
- **The damage list's credit (round 657 review, READ; the clipping OPEN).** The only writer that
  adds to an entry is `0x52a940` (CGObjNPC's override at `vtable +0x4f4`, slot 317; the dump's
  `CanBeEquipedAt` there is a propagated name, wrong for this override): a pet attacker is mapped to
  its owner (`+0x736*4`), a new entry is inserted (`0x52b820`) or the found one's `+0x14` gets the
  damage argument added, and the base `CGObjChar` slot is then called with the same arguments.
  Whether its caller passes the blow's damage or the damage clipped to the HP left was not traced
  (its callers reach it through the vtable and a forwarding thunk, `0x605140`, with no direct call).
  srrevamp books the blow unclipped: INFERRED, so an overkill finisher is credited the whole blow.
- **The suppress key.** `CONTROL_NOTIFY_SPAWN_UNIQUE_MONSTER_MSG` is read at `0x60936f`; equal to
  `"ON"` (`0xb012f4`) it sets the world's `+0x108` (`0x6093b1`), which `0x608350` returns;
  `0x5f9910` finds the world and calls a vtable getter (INFERRED to be that one). Absent: nest
  hatches and kills are announced.

srrevamp (OURS unless marked): `-unique-notice-off` is the key (default off: announce); it silences
the roster's (nest) spawns and every kill, not a GM spawn (READ, above). The damage list is
`combat.Hub`'s, booked per attacker in first-hit order on every blow a player lands
(`ApplyDamageFrom`). The attackers no longer in the world are dropped before the rule runs (READ:
`0x485d90`), so a departed top-damager does not win and the notice never carries "???" from a
player's kill. Every srrevamp party shares experience, and a party of one is no party (the engine
never makes one), so a group is a party of two or more. The notice goes to every character on the
server, queued per recipient off the killer's goroutine (since round 662 by the general per-session send
queue; round 657's notice-only queue is folded into it).

GM tools: `/spawnunique <id|name>` is OURS as a command (retail's GM spawn command is its own); its
announcement follows retail's GM spawn, which passes the announce flag as 1. `/damage <n> [id]`
(OURS) deals a blow booked to the GM. `/kill` (OURS) books nothing; a unique it kills with nobody
on the list is announced with `"???"` (retail has no GM kill; its rule would say nothing).

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

- Killer `vtable +0x53c` (no notice when 1), `+0xec` / `+0xf0` (which name for which kind).
- Whether the damage-list credit (`0x52a940`) is passed the clipped damage.
- The order ties are met in (the damage list's map order).
- The uniques' placement and rotation (round 660); until then only a GM spawn is announced.
