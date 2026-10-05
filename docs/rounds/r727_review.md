# Round 727 review: the NPC select/open/end on the retail opcodes, and the menu from the ids

Independent adversarial review of `dev..a381a1a6` (lane C1 of the NPC GUI epic). Every address
below was read in `srgs.asm` / `sro_client.asm` (objdump) or the dumps on the render box. No code
was changed.

**Verdict: not mergeable as is.** The select reply is one byte short of the original's. A
deployment without `-npcs-csv`, which includes opensro-01, loses every NPC menu line. The id-10
registrar exists, and it is the herbalist's "Withdrawing Skill".

## Findings, most severe first

### 1. BUG: `0xB045` is missing the NPC's u8 before the id count

- **Files:** `server/internal/npctalk/wire.go:129` (`EncodeSelectNPC`), `:145` (`DecodeSelectNPC`);
  `client/scripts/net/npc_talk_net.gd:74` (`decode_select`); the golden bytes in `wire_test.go:20-27`
  and `npc_talk_net_test.gd:30-38`; `docs/protocol/npc_gui.md:425`.
- **Evidence, server:**
  - `PublishAvailableInteractions` calls the target's slot `+0x4d8` with `(1, msg)` (`0x4a973a..0x4a9747`).
    It does so before it appends the count byte (`0x4a9749..0x4a975f`).
  - `CGObjNPCNPC`'s vtable (`0xaef674`) holds `0x4c79f0` at `+0x4d8`. That function appends one
    byte, 0: `0x4c79ff mov byte [esp+7],0`, then `0x4c7a04 call 0x404090` with `eax = 1`.
  - Its `+0x38c` is `0x4a95a0`, so the call is made for every NPC select.
- **Evidence, client:**
  - In `0x88b200`'s NPC branch, the object passes `IsKindOf(CICUser 0xef1bc0)` false
    (`0x88b363..0x88b371`). The client then reads a u8 at `0x88b37c`.
  - When bit 0 of that byte is set, it reads a u32 (`0x88b385..0x88b393`, then `0x9c7870` and
    `0x9c78a0`). Bits 1 and 2 are asserts (`0x88b3b0`, `0x88b3d1`).
  - Only after that does it read the count (`0x88b3fb`) and the ids (`0x88b419`).
- **What this breaks:**
  - The retail herbalist reply, for a player of level 20 or more, is
    `01 | 23 01 00 7f | 00 | 03 | 01 02 0a | 00`. OpenSRO sends
    `01 | 23 01 00 7f | 02 | 01 02 | 00`.
  - A retail client would read OpenSRO's count as that flag byte. OpenSRO's two halves agree with
    each other, which is why the live run passed.
- **Fix:**
  - Write a u8 0 after the entity in `EncodeSelectNPC` (READ, `0x4c79f0`).
  - In `decode_select`, read it, and read a u32 when bit 0 is set.
  - Update both sets of golden bytes and §8's table.

### 2. REGRESSION: without `-npcs-csv`, every NPC shows only "End conversation"

- **Files:** `server/cmd/server/npcs.go:77-90`, `server/internal/npcspawn/place.go:228-234`,
  `deploy/README.md:441-450` (not updated by the round).
- **How it happens:**
  - Without `-npcs-csv`, `info` is nil and `n.Code` stays "". `interactions` then returns
    `0, nil`, so every `0xB045` carries an empty set.
  - The client no longer derives any line itself: `services_for` is removed, and `_client_talk_ids`
    covers only teleport points.
  - So every NPC lists "End conversation" alone. The store, storage, guild and job lines are lost,
    along with the teleport NPCs' lines.
- **Who it hits:** `deploy/README.md:441-450` says opensro-01 runs with `-npcpos-csv`,
  `-monsters-csv` and `-nest-db-dir`. It calls `-npcs-csv` "optional ... the OpenSRO client builds
  its talk menus from its own archive either way". That stops being true with this round.
- **Older servers:** a client from this round on a server older than this round sends `0x7045`, gets
  no answer, and no NPC window opens at all.
- **Fix:**
  - Make `-npcs-csv` required wherever NPCs are spawned: fail, or at least `Error`, at boot.
  - Update `deploy/README.md`'s NPC section and its rollout order (server and `npcs.csv` first).
  - Deploy `npcs.csv` to opensro-01 before the client release ships.

### 3. DEPARTURE: id 10 has a registrar, and the herbalist offers it from level 20

The lane's census covered only `[vtable+0x164]` (AddAvailableInteraction, the NPC's own list
`+0x130`). Id 10 goes into the per-select set `+0x1c78` instead, through slot `+0x270`,
`IGObj::SetAvailableInteractionPerGObj` (`igobj_vtable.md` row 156). That slot is reached only
virtually; `character_state.md` already names it as the writer of `+0x1c78`.

- **The only two `[reg+0x270]` vtable calls in `srgs.asm`** (28 `+0x270]` hits; the rest are data
  fields at `0x5226xx`, `0x588cxx` and `0x5960xx`):
  - `CQSP_ALL_POTION_1::vslot_002` (`0x88b760`, the quest's event handler, which switches on the
    event). Event `0xb` goes to `0x88b791`:
    - `0x88b796` calls the player's `+0x124` (`IGObj::GetLevel`), and `0x88b79e cmp al,0x14; jb out`
      skips the rest below level 20;
    - then `0x88b7ab mov eax,[edx+0x270]; push 0xa; call eax` on the NPC (`[ebp+8]`).
  - `CQSP_ALL_POTION_2::vslot_002` (`0x88d240`): the same, at `0x88d28b`.
- **Which NPCs:**
  - `CQSP_ALL_POTION_1::vslot_017` (`0x88b3db..0x88b448`) walks the table at `0xc805d4`:
    `NPC_CH_POTION`, `NPC_WC_POTION`, `NPC_KT_POTION`, `NPC_EU_POTION` and `NPC_CA_POTION`.
  - It finds each by codename (`[0xc8277c]+0x1c`) and subscribes the quest to events `0x12`, 1 and
    `0xb` (`+0x138` at `0x88b412`, `0x88b429`, `0x88b441`).
- **Who raises the events:**
  - `0xb` comes from `PublishAvailableInteractions` on every select of an NPC by a player:
    `0x4a9719..0x4a9728`, `RaiseEvent(0xb, 0, player)`. `0x485f60` dispatches it to the
    subscribers, before the count is written (`0x4a9749`).
  - `0x12` comes from the open's id-10 case (`0x5105f1..0x510607`). It goes to
    `CQSP_ALL_POTION_1` `0x88b7be`, the withdrawal itself, which again checks for level 20.
- **The client** adds an id only from the message: `0x6fcd00` has exactly two callers, both in
  `0x88b200`.
- **Verdict:**
  - The herbalist's set is {1, 2, 10} for a player of level 20 or more, and the menu is
    `tcHCl0v.png`'s four lines.
  - Below level 20 it is {1, 2}, and OpenSRO's three lines are right.
  - The quests being in service is INFERRED, as it is for id 2.
- **Fix:**
  - `handleNPCSelect` adds 10 to the reply's set for the five `NPC_*_POTION` codenames when the
    player's level is 20 or more, and keeps that per-session set.
  - `handleNPCOpen`'s offered test reads that per-select set, as `HasAvailableInteraction`
    (`0x50cd80`) reads `+0x1c78`.
  - The open of 10 answers `{1, 2}` with mode 5, as it does now. The client says "not available
    yet" until the withdrawal is built.
  - Correct §8's ruled-out list, OPEN 1 and 7, and `r727.md`.

### 4. WRONG-LABEL: id 2 is not "for every player alike"

- **File:** `server/internal/npcspawn/questtalk.go:34-38`, and §8's id-2 row.
- **The engine filters id 2 per player.** `PublishAvailableInteractions` copies `+0x130` into
  `+0x1c78`, then:
  - **when the requester is a PC and the target is an NPCNPC** (`0x4a967c..0x4a969b`):
    `0x4c93d0` removes the siege ids;
  - **`0x4a96b2`:** if the NPC's `IsFirstTalkMenuEnable` holds, `0x4a9711` (`FUN_004f0420`)
    copies the NPC's talk-menu items into the player's list `+0x2198`. The quests register those
    items when they register id 2: `FUN_00926ed0` calls slots `0x280` and `0x284` after its
    `push 2`;
  - **`0x4a9724`:** event `0xb` goes to the NPC (see 3);
  - **`0x4a9735`:** the NPC's slot `0x640`, which is `0x4c9310`. When the NPC has a talk menu, it
    finds 2 (`0x4c933b mov byte [esp+0x13],2`). It erases 2 (`0x4c9375`) when the player's
    `IsFirstTalkMenuEnable` (`0x4f0730`: `+0x2280 == 1.0` and `+0x219c != 0`) is false.
- **Answers to the brief's questions:**
  - **Quest-less server:** in the original, nothing but the quest classes pushes 2. A server with
    no quests in service would not show "Talk to this person." With quests in service, a player
    left with no talk item loses the line.
  - **The 89 codenames:** the list is derived correctly. A recount of every
    `*(param_1[0xc4] + n) = "NPC_..."` store gives the same 86. The three direct pushes add
    `NPC_CH_ISLAM`, `NPC_WC_PRIEST3` and `NPC_WC_SOLDIER_SO`. The pushes at `0x926f94` and
    `0x927104` are `push 2`.
- **Fix:** label OpenSRO's static id 2 as a stand-in for the per-player result (OURS). Name the
  READ filter (`0x4c9310`) and the `+0x2280` / `+0x219c` state that is not modelled.

### 5. WRONG-LABEL: what id 2 sends is readable, and has been read here (OPEN 2/3)

- **Files:** `docs/protocol/npc_gui.md:387` and `:472-476`, `docs/rounds/r727.md` OPEN 2, the
  comment at `server/internal/session/npctalk.go:189-194`.
- **The open's id-2 case** (`0x510584`) sets INTERACTMODE 5. Then:
  - **The NPC has no talk menu:** it sends `RaiseEvent(1, 0, player)` to the NPC
    (`0x51059b..0x5105aa`). That is the quest event; `ShowFirstTalkMenu` does not run.
  - **It has one:** the player's `+0x28c` runs, `CGObjPC::ShowFirstTalkMenu` (`0x4f05d0`), as
    follows.
- **What `ShowFirstTalkMenu` does:**
  1. With no target, or a target that is not an NPCNPC, it calls `EndInteraction`.
  2. If the NPC has no talk menu, it sends nothing.
  3. Otherwise it collects the enabled items (`+0x10 != 0`) of the player's list `+0x2198`. It
     calls the player's slot `+0x150` with `(0, 4, NPC+0x1d20 title, items, n, 0, 0, 0)`
     (`0x4f06c9..0x4f06e6`).
  4. That slot is `CGObjPC::ShowMenu` (`0x4ec930`), which allocates opcode **`0x30D4`**
     (`0x4ec97a push 0x30d4` into `+0x278`).
- **The client's answer** is `0x70D4`, which `GObjPC_HandleTalkMenuSelectMsg_0d4` (`0x516670`)
  handles: a u8 choice, then `EndInteraction`.
- **Fix:** record `0x30D4` and `0x70D4` as id 2's follow-up in §8, and keep the payload's field
  read as the next step. Remove "the decompile is lost there".

### 6. DEPARTURE (minor): id 0xc's INTERACTMODE is conditional

- **Files:** `server/internal/session/npctalk.go:187-200`, `npc_gui.md:437-438`.
- **Evidence:** the open's jump table (`0x510624`, indices at `0x510638`) has these cases:

  | ids | case | what it does |
  |---|---|---|
  | 2 | `0x510584` | mode 5 |
  | 10 | `0x5105f1` | mode 5 |
  | 0xc | `0x5105ca` | when the NPC's `+0x1cf0` is 0, return with **no mode** (`0x5105d1 je 0x510428`); otherwise `0x4c8a60`, then mode 6 |
  | 0x23 | `0x510428` | return with no mode |
  | the rest | `0x510612` | mode 6 |

  OpenSRO sets mode 6 for 0xc in every case.
- **Fix:** give 0xc no mode while the NPC's `+0x1cf0` is unmodelled (or OpenSRO's equivalent is
  empty), and label it.

### 7. MINOR: other paths in the handlers that are neither modelled nor labelled

- **The end's state** (`npctalk.go:213-217`) clears `selected` on every successful end. The
  original (`EndInteraction` `0x5107c0`):
  - clears `+0x1ca0` only when the mode was 5 (`0x51090d..0x510913`), or when the mode is 0 with
    the flag set (`0x5107f0..0x5107f9`);
  - so after a mode-6 end (storage opened straight from a select), a second `0x704B` gets `{1}` in
    the original, where OpenSRO refuses `0x1C0D`.
- **The open:**
  - It refuses `0x1C0B` when the player's slot `0x5a0` is non-zero (`0x5102bc..0x5102e2`), not only
    on INTERACTMODE.
  - Its range check passes the type filter `0x146` (`0x510336`), and a mismatch there is code 3.
  - For id 1, `FUN_00619c10` returning 0 is code 3 (`0x5103ba..0x5103c3`).
  - For id 1 at `NPC_SD_MERCHANT_CHANGER` (`0xaf6c04`) and `NPC_SD_THIEF_AGENT_CHANGER`
    (`0xaeedd8`), the player's job state refuses `0x1C26` (`0x510431..0x510480`).
  - For 0x23, `FUN_0051b580`'s code is sent as the refusal (`0x510486..0x51049d`).
- **The select** lets INTERACTMODE 1 through when `+0x1cc0` (`param_1[0x730]`) is set (`0x50faf0`'s first test).
- **Fix:** label each of these in `npctalk.go`, at least the job-changer gate, which a spawned NPC
  can reach.

### 8. WRONG-LABEL (minor): the warehouse line hides the window before it sends

- **Files:** `docs/rounds/r727.md:44`, `npc_gui.md:445`, the comment at
  `client/scripts/ui/hud/hud_panels.gd` (round 727's storage note).
- **Evidence:**
  - Kind 3 is case `0x70242d` of `0x7020c0`'s table (`0x703c6c`; index byte `0x703d2c+3` = 2).
  - The talk window's `+0x5c(0)` (SHOW/HIDE) runs at `0x70242f..0x70243c`, before
    `0x841780(0x7046)` and the send at `0x702466..0x702487`.
- **Why the wire still matches:** OpenSRO sends the request first and hides after it. Its bytes
  equal the original's only because ShowWindow(0) sends nothing, which the lane also states.
  `0x7040b0` is the one that sends `0x704B`, and it refuses to close while a `0x7046` is in flight
  (`0x7040d4..0x7040e3`).
- **Fix:**
  - Say "hide first; the hide sends nothing (ShowWindow, not the close slot)".
  - Note that OpenSRO's window is already hidden when `NpcTalkNet.end()` declines, where the
    original's stays open.

### 9. MINOR: the tooling and the cleanup

- **QA talk without a server:** `OPENSRO_QA_TALK` without `--server` now shows no store or storage
  line (`_client_talk_ids`). Round 725/726's offline render recipes (`docs/rounds/r725.md`) need
  `--server` from now on. Note it there or in `client/tools/README.md`.
- **The cleanup:** `ForgetNPCInteraction`'s comment (`npctalk.go:64`) says "a disconnect or a zone
  change". Only the disconnect calls it (`cmd/server/main.go:2139`).

## Verified, no finding

- **The requests:**
  - `0x7045`, and `0x704B`'s single `u32`. `0x7046`'s `{u32, u8}`: the client's `0x702316..0x702323`
    path and the server's `0x5102e7..0x510336`.
- **The `0xB045` shape:**
  - The success path is `{1, u32}` (`0x50fc38..0x50fc4d`).
  - The refusal is `{2, u16 code}`, with the range code as a u16 (`0x50fd02..0x50fd18`), and code 3
    at `0x50fd41`.
  - `IsWithinInteractionRange` returns 1, 3 or 4, and 0 for no target.
  - **Range (READ):** `IsNPCNPC` (slot `0x24`) picks `0xb45c40` = **300.0**, and the distance is
    3-D (`0x4a8e10`: 600 for a PC, 320 by default).
- **The ids and the tail:**
  - The ids go out in set order. The 0x1f u16 is appended at `0x4a97ed`, read at `0x88b691`. The
    NPC's u8 (`0x645790`) is read under CICNPC at `0x88b6af`. The 0x21 u16 is read at `0x88b6dc`.
- **`0xB046`:**
  - The `0x1C0B`, 3/4, 3 (not an NPCNPC), and 5 (`HasAvailableInteraction` on `+0x1c78`) checks
    come in that order.
  - 10 is echoed as 2 (`0x5104ad..0x5104b5`).
  - The extra u8 for 0xc is the world-config byte `+0x42405` (`0x5104f4..0x51050d`).
- **`0xB04B`** is `{1}`, or the refusal `0x1C0D` (`0x510808`).
- **The store's and storage's close send `0x704B`.** The store line's close slot `0x7040b0` sends
  `0x704B` (via `0x78fc20`, `push 0x704b`) before the store's `0x7046 {1}` (`0x7022f7..0x702323`).
  The client-side order matches.
- **The builder `FUN_00700440`'s order:** 2, 1 (gates `0x9870e0` and `0x989d20`), 3, academy
  (`0x700b96 cmp [+0x868],0x3c; jb`), Honor Rank, 0x20, 7, 9, 8, 6, 0x1e, 0x0f, 0x13, 10, 0x14,
  0x16, 0x15, 0x11, 0x12, 0x23, 0xc, 0x1c, 0x27, 0x29.
  - It equals `services_from_ids`. The tokens for items 4, 0x16 and 0x2d-0x2f were checked in
    `0x6fcd60`.
  - Not modelled, and harmless for the NPCs OpenSRO spawns:
    - the body-text paragraphs for 0xc (`UIIT_MSG_SAFETRADE_PROGRESS_NUMBER`, `0x700770..0x7008b8`)
      and 0x13 (`UIIT_MSG_XMAS_EVENT_SO-OK`, `0x7008cb..0x700911`);
    - id 8's desert-gate `%d%%` text (`STORE_DESERT_*`, `0x700d36..0x700f78`), which is the tax side.
- **The gates:** the set {7, 8} gives the lines in the order 7 → 9 → 8, and the menu equals
  `1llywhJ.png`.
- **The menus before and after:**
  - A store NPC shows the same store lines.
  - A smith now also shows "Grant magic option on avatar item" (id 0x20, READ at `0x700bd2`, and
    the server registers 0x20 on smiths).
  - The storage keepers now also show Honor Rank, and Academy Establishment from level 60 (READ).
  - The guild and job lines come from the server's Create rules, unchanged.
  - No line was lost wherever the server has `npcs.csv` (see finding 2 where it does not).

## Tests

- `go test -count=1 -p 1 ./...` (server): **green**.
- On the box, `remote_godot.sh` with `RENDER_DIR=/opt/opensro-client-r727rev` and
  `GODOT_LOCK=/var/tmp/r727rev/lock`:
  - `check`: **ALL LOAD**, 620 scripts and 9 scenes;
  - `tests`: **238 suites, 0 failing**.
- The tests pass because the server's and the client's codecs agree with each other. The golden
  bytes do not match the original's (finding 1).
