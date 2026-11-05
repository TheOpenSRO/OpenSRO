# The return scrolls' cast: the casting bar, its length, its cancel

Round 779. Read from `sro_client.exe` (the dump `/var/tmp/decomp_client`, the disassembly
`/var/tmp/sro_client.asm`) and `SR_GameServer.exe` (`/var/tmp/decomp_server`, `/var/tmp/srv.asm`) on
the render box, and from the Media.pk2 files there. Labels: **READ** (the binary or the archive
says so), **MEASURED** (counted on the box), **INFERRED**, **OURS** (this project's choice),
**OPEN**. `docs/protocol/reverse_return_scroll.md` has the reverse scroll's box, map and
destinations (round 778); this file is the cast every return scroll shares.

OpenSRO's implementation: `server/internal/session/scroll.go` (the cast, its state, the cancel),
`teleport.go` / `walkin.go` (the refusals), `monsterstrike.go` (a death's cancel);
`client/scripts/ui/hud/delay_info_bar.gd` (the bar), `hud_panels.gd` (open/close),
`World3D.gd` (`_on_use_item_result`, `_on_teleport_state`, `_on_cast_cancel_requested`).

## 1. Which items (READ, MEASURED)

Every TypeID 3/3/3/1 (the return scroll) and 3/3/3/3 (the reverse return scroll) item takes the
same path on both sides: the server's `CGItemExpendable::vslot_307` cases 1 (`FUN_004a0380`) and 3
(`FUN_004a00c0`), the client's `Item_OnUseItemResult` (0x87a7b0) cases 1 (0x87ad78) and 3 (0x87adfb),
both of which open the casting bar of kind 0. MEASURED, the rows of the box's itemdata
(`/var/tmp/tables/itemdata_all.utf8.txt`, field 119 = Param1, 121 = Param2, 124 = Param3's
descriptor):

| ID | CodeName128 | Type | Param1 | Param2 | Desc3 | Cast |
|---|---|---|---|---|---|---|
| 61 | `ITEM_ETC_SCROLL_RETURN_01` | 3/3/3/1 | 30000 | 1 | RESURRECT | **30 s** |
| 10382 | `ITEM_ETC_SCROLL_RETURN_NEWBIE_01` | 3/3/3/1 | 30000 | 1 | RESURRECT | **30 s** |
| 2198 | `ITEM_ETC_SCROLL_RETURN_02` | 3/3/3/1 | 15000 | 1 | RESURRECT | **15 s** |
| 2199 | `ITEM_ETC_SCROLL_RETURN_03` | 3/3/3/1 | 5000 | 1 | RESURRECT | **5 s** |
| 3661 | `ITEM_ETC_E041225_SANTA_WINGS` | 3/3/3/1 | 5000 | 1 | RESURRECT | **5 s** |
| 3769 | `ITEM_MALL_RETURN_SCROLL_HIGH_SPEED` | 3/3/3/1 | 1000 | 1 | RESURRECT | **1 s** |
| 24448 | `ITEM_EVENT_RETURN_SCROLL_HIGH_SPEED` | 3/3/3/1 | 1000 | 1 | RESURRECT | **1 s** |
| 9233, 10505 | `ITEM_QNO_WC_SMITH_3_02`, `ITEM_QNO_CA_POTION_1_01` (quest) | 3/3/3/1 | 1000 | 1 | RESURRECT | 1 s |
| 2128 | `ITEM_ETC_SCROLL_RETURN_THIEFDEN_01` | 3/3/3/1 | 300000 | 0 | THIEFDEN | 300 s (a thief only) |
| 59669 | `ITEM_ETC_SCROLL_RETURN_THIEFDEN_02` | 3/3/3/1 | 165000 | 0 | THIEFDEN | 165 s (a thief only) |
| 3795, 24449, 36772, 62530 | the four reverse return scrolls | 3/3/3/3 | 1000 | 1 | RESURRECT | **1 s** |
| 9230 | `ITEM_QNO_WC_FERRY2_1_01` (quest) | 3/3/3/3 | 1000 | 1 | RESURRECT | 1 s |

(The box's table also holds 3/3/3/1 rows of a private server's add-on -- `ITEM_PET_LEVEL`,
`ITEM_DURABILITY_REMOVER` and others, Param1 1000 -- which this binary would treat as 1 s return
scrolls.)

## 2. The length (READ) -- round 778's OPEN, settled

- **The server** passes ref `+0x2a0` (Param1's slot) to `FUN_004a0380` / `FUN_004a00c0`
  (0x49ba9e, 0x49bac6), which hands it to the job as `(float)` (0x4a0576 `fild`). But the item
  loader `RefObjItem::ExtractData` (0x6a3d50) first rewrites it: for element 0 of a 3/3/3/1
  (`(tid & 0xf800) == 0x800`) or 3/3/3/3 (`== 0x1800`) row whose descriptor is not `xxx` and holds no
  `cooltime`, `+0x2a0 = +0x2a0 / 1000` -- an integer division. The PC's job manager
  (`FUN_004065d0`) counts a job down by the elapsed GetTickCount ms / 1000.0 (`fdiv` of the double
  1000.0 at 0xb45c68, 0x406605), and `AJStateChanger::vslot_002` subtracts that from its float at
  +0x10. So **the cast lasts Param1 / 1000 whole seconds**, with `FUN_004e0b50`'s floor: a delay
  <= 1e-6 (0xb45c84) becomes 0.1 (0xb45eb8).
- **The client** agrees: the item tooltip for TypeID4 1 (0x677759..0x6777bf) prints
  `"%s %d%s"` with `PARAM_RECALL_TIME` ("Return time"), `+0x2b4 / 1000` and `PARAM_SECOND`
  ("Second"); the casting bar counts the same `+0x2b4` as milliseconds (below). `+0x2b4` is the
  client record's Param1: INFERRED from those two uses and from the buff timer (0x805a40 case 3)
  multiplying the same field by 1000 for the 1800-second EXP scrolls.

## 3. The client's casting bar (READ)

**Classes.** `CIFDelayGaugeBoard` (the board, window got by `FUN_007994d0`) holds a list (+0x374,
count +0x378) of `CIFDelayInfo` entries (`CreateObject` 0x7b1ae0, 0x388 bytes; RTTI
`CIFDelayInfo : CIFWnd`).

**Opening.** `FUN_007b15a0(kind, ref, a, b)` removes the kind's entry if any, creates a
`CIFDelayInfo` (gwnd 0xba20b0, class 0xeec1c8, id 100 + kind, rect `{0, 0, 0xc0, 0x24}`), gives it
the texture `interface\ifcommon\com_casting_window.ddj` (+0x84 vslot 0x34), fills it
(`FUN_007b1bf0`), appends it and lays the board out (`FUN_007b1470`). Kinds 1, 3 and 4 also set the
board's busy byte +0x36c (0x7b16d4..0x7b171b); kinds 0 and 2 do not.

**The window (READ `CIFDelayInfo::Create` 0x7b1b70, layout `resinfo\ifdelayinfo.txt` at
0xdbcd20, section "Create"; MEASURED the file and the art):**

| Control | ID | Member | Rect | Art / text |
|---|---|---|---|---|
| `GDR_DI_GAUGE_DELAY` (CIFGauge) | 10 | +0x37c | 6, 27, 184 x 8 | set by the kind (below) |
| `GDR_DI_CANCEL` (CIFButton) | 11 | +0x380 | 171, 4, 20 x 20 | `com_casting_cancel.ddj` (+ `_focus`, `_press`), 20 x 20 |
| `GDR_DI_NAME` (CIFStatic) | 12 | +0x384 | 0, 7, 167 x 12 | HAlign 1 (centred), FontColor 255,255,255,255 |

The window art is 192 x 36: a half-transparent dark panel (alpha 128) over x < ~165 and an opaque
box on the right where the cancel button sits. The `Color=` lines are editor ids (the resinfo
parser reads no `Color`, round 102).

**Kind 0's content (`FUN_007b1bf0` case 0).** The gauge's own texture becomes
`interface\ifcommon\com_casting_gauge_return.ddj` (184 x 8, MEASURED: rows 0..4 of columns 0..181
green -- (0,197,131), (82,255,189), (0,230,148), (0,172,106), (0,115,74) -- the rest transparent);
no back texture is set. The name is the item's name (ref +0x60, the NameStrID, through the text
table 0x8c9bb0). The total (+0x370) and the remaining (+0x36c) are ref +0x2b4, **Param1 as
milliseconds**; the gauge's value (+0x380) and target (+0x384) 0. Other kinds: 1 a collection
(`com_casting_gauge_collection.ddj`, 0x88d570), 2 a guild recall (`UIIT_MSG_GUILD_RECALL_MESSAGE`,
seconds * 1000, 0x88d910), 3 a fixed 5000 ms item cast (0x629f00), 4 a skill (0x8a4de0).

**Where (`FUN_007b1470`).** The board sits at x = (w - 0xc0) / 2 (0x195 when w is 800), y = h - 0xa5;
entry i is moved to the board's y + 0x4c - 0x26 * i, newest lowest. One bar: top-left
((w - 192) / 2, h - 89), its bottom 53 px above the screen's edge -- just over the hotbar
(`ub_window_01` is 52 high). OPEN: at exactly 800 x 600 with window 0x27's +0x36d flag
(`FUN_00810f50`) the board is at h - 0xc6.

**The fill (`CIFDelayInfo::vslot_012` 0x7b1960).** Each frame, while the remaining is not 0, it
drops by `DAT_0110f7f8` -- the frame's milliseconds, capped at 3000 (0xba4106 and its writer) --
and the gauge's value and target are both (total - remaining) / total: **empty to full, left to
right** (CIFGauge crops its right edge and u together, as the buff board's gauge). At 0,
`FUN_007b1800(kind)` runs, which for kind 0 does nothing: the full bar waits for the server.

**The cancel.** The window's message map (.data 0xebf008: ids 11..11, handler at +0x18 = 0x7b1a10,
filled by the static initialiser at 0xd71bb0) sends control 11 to `UI_SILKMALL::FUN_007b1a10`,
which calls `FUN_0081ee60(kind, ref)`: case 0 logs "Teleport Casting Cancel" and sends **0x705B
with no body**; case 2 sends 0x705B as well; case 1 sends 0x70DB with the u32; case 4 a magic-state
message. For kinds 3 and 4 the entry is also removed at once; **kind 0's stays** until the state's
end arrives. There is no confirmation box: `UIIT_STT_TRANSITION_CANCEL` ("The return scroll will
disappear after you cancel the teleport...") is in textuisystem.txt but not referenced by this
binary.

**Closing.** The 0x30BF handler (0x8a80a0) case 0xb stores the value on the object (+0x7c0, via
`FUN_009db090`; nothing found reads it) and, for this player and value 0: if the board holds any
entry (+0x378), shows `UIIT_MSG_TRANSITION_CANCEL_RESULT` ("The teleportation has been
cancelled.", `FUN_007781b0(0, text)`), then removes kinds 0 and 2. The zone reset (`FUN_00787860`)
and this player's death (`FUN_0077b000`, 0x30BF kind 0 value 2) clear the whole board
(`FUN_007b1300`) silently. The 0xB05B handler (`FUN_008727a0`) shows the same text on a result 1
-- which this server never sends -- and nothing for a refusal.

**Input.** The busy byte the action senders and the key handler ask
(`FUN_0077c8e0`, called from `SendMagicStateMsg_074` and `GInterfaceSend::FUN_00793b00`) is not set
for kind 0; the use-item sender's own test (0x796752) reads the same byte. The 0x30BF value stored
on the object (+0x7c0) is read by nothing: its only getter, 0x9db0a0, has no caller and no pointer
to it (round 860, MEASURED over the whole binary). So the client itself refuses nothing during a
return scroll's bar -- it sends the click and the keys as ever. **The server refuses them** (section
4, "The hold", round 860), and the retail client walks only on its move's echo, so nothing moves.

## 4. The server (READ)

- **The stop.** `FUN_004a0380` (0x4a0561..0x4a0574) and `FUN_004a00c0` (0x4a0314..0x4a031c) call
  vtable slot 300 (0x4b0, `GObjPC::FUN_004a9430`) with its send argument 1: a moving character's
  mover stops and 0xB023 goes to the 3 x 3, the user included.
- **The state.** `FUN_004e0b50(value, 3, delay, option)` broadcasts **0x30BF {u32 id, u8 0xb, u8
  value}** (`GObjPC::BroadcastStateChange`) and sets chardata +0x10; value = (Param2 == 0) + 1
  (0x4a0459), so 1 for the RESURRECT rows and 2 for the thief-den rows. The spawn record carries
  it (field 26). The job's end (`AJStateChanger::vslot_002` case 0xb) warps (vslot 0x378) and then
  calls `FUN_004e0b50(0, 0xff, 0, 0)`: value 0 broadcast. A character locked at expiry waits 1.0 s.
- **The cancel.** 0x705B is `GObjPC::FUN_00513ea0`: no state -> **0xB05B {u8 2, u16 6}**
  (`Msg_SendTwoFieldReply(6)`, the only 0xb05b this binary emits); otherwise, unless the job's option
  is 6, the job 0xb is removed (`FUN_004066c0(0xb, 0xb)`) and `FUN_004e0b50(0, ...)` sets and
  broadcasts 0. No success reply. **No refund**: the item went at the use (DoJob decrements after
  the use answers 1, round 778).
- **A death cancels.** `CGObjPC` vslot_306 (0x529be9) and vslot_307 (0x52ce59), the death paths,
  build a 0x705B and run that handler when the state is set.
- **Damage does not.** No other caller of `FUN_004e0b50` or of `FUN_004066c0(0xb)` is a combat
  path (the callers: the dispatcher `SetCharacterState`, `vslot_309`, `UpdateCharRefObjIDAndScale`,
  `BanToDefaultWorld`, `CMainProcess::FUN_005ba520/FUN_005ba690`).
- **What the state refuses** (every caller of `GetTeleportState`, vslot 0x120, 0x4ddc90):
  another scroll (0x185d); the NPC teleport (`HandleTeleportUse` 0x513634: **0x1c14**
  `UIIT_MSG_INTERACTION_FAIL_TELESCROLL_ALREADY_WORKING`, before the range; category 0xd entry 13 ->
  0x7ba0d7); the walk-in zones (`vslot_309`); a pet summon (DoJob TypeID4 2 and
  `CGItemCOSSummoner::CheckCanUse`: 0x1869 while the value is 1); the logout request
  (`FUN_0050eff0`, 0x802 -- that the client's text for it is
  `UIIT_MSG_LOGOUT_ERR_CANT_LOGOUT_WHILE_TELEPORT_WORKING` is INFERRED); a guild summon; a thief's
  pick-up of a special good (`FUN_00526090`, 0x186e, only for job state 2 and a trade good); some
  quest scripts. The movement request (`GObjPC::FUN_004b0ea0`), the action request (0x4acc40)
  and `Skill_CheckUseConditions` do not ask it themselves -- **but they never see the request**
  (next item). Round 779 stopped at the handlers and concluded "no lock"; that was wrong.
- **The hold (READ, round 860).** The PC's message pump `GObjPC::FUN_004a8ad0` (from
  `CMainProcess::FUN_00413b30`) asks CGObjPC vtable slot 0x610 (`GObjPC::FUN_004aa310`, vtable
  0xaf59fc + 0x610) before slot 0x5e0 (`CGObjPC::DispatchClientMessage` 0x50eee0) runs a message's
  handler; a refused message goes to slot 0x598 (`CGObjPC::vslot_358` 0x4ecbc0). Slot 0x610 is the
  filter `GObjPC::FUN_004296a0` over the tables `RegisterValueListFilters` (0x427d90) builds at
  0xcc3fe4: 17 groups of 0x1c bytes, one per state, each a vector of records by the state's value,
  a record an allow list (kind 0, `ValueIsInList`) or a deny list (kind 1, `ValueIsNotInList`) of
  opcodes; no record passes. The scroll state is group 11 (0xcc4118; the filter's `call
  [edx+0x120]` then `lea edi,[ebp+0x138]` at 0x429814..0x429834). It has 4 values and **one record:
  value 1, an allow list of 0x7025 (chat), 0x704C (item use), 0x705B (the cancel), 0x7005 and
  0x34BF** (0x429337..0x4293ab). So while the state is 1 the move 0x7021, the arrow keys' 0x7023 /
  0x7024, the action 0x7074 (attacks, skills, pick-ups, the trace), 0x70C5, NPC talk, inventory and
  exchange requests are all refused. Values 2 (the thief-den scrolls) and 3 have no record: not
  held. The refusal (vslot_358): 0x7074 runs its handler with the refused flag, answering **0xB074
  {3, 0x4004}** (silent on the client); 0x7034 answers 0x181d, 0x7045 0x6006, 0x7046 0x1c0b; the
  moves get **no answer**.
- **The thief-den scrolls.** `FUN_004a0380` compares Param3's descriptor with "RESURRECT" /
  "THIEFDEN" (0xaeb294 / 0xaeb2a0; neither -> 2); a THIEFDEN row needs job state 2 (vslot 0x11c,
  chardata +0xf) or answers **0x186a** `UIIT_MSG_STRGERR_ONLY_ROBBER_CAN_USE_THIS_ITEM`, then takes a
  record by Param4's descriptor and uses option 1.

## 5. OpenSRO (OURS where it differs)

- Durations, the stop, the 0x30BF kind 0xb (start 1/2, end and cancel 0), the 0x705B / 0xB05B
  cancel, the death's cancel, the spawn record's field 26, the NPC teleport's 0x1c14 and the
  walk-in's silent refusal are the retail rules above. OURS: the reply OpUseItemResult carries the
  item's ref id after `cast_ms` (retail's client finds it through the slot); the client takes the
  bar's total from its own item table's Param1 and falls back to `cast_ms`.
- OURS: when a reverse scroll's stored point has gone by the end, the state still returns to 0
  (retail's job returns without resetting it).
- OURS: the thief-den rows are told by their code name (the export has no descriptor column);
  every character is refused 0x186a (no job system).
- Not modelled (nothing to refuse): pets, logout, guild summon, thieves' goods, quests.
- Round 860, the hold (`session/scrollhold.go`, READ above): while the state is 1 the server refuses
  0x7021 (and a rider's 0x70C5 move), 0x7023, 0x7024, OpMove's walked positions and stops (OURS'
  stream; a relocation passes), 0x7074 ({3, 0x4004}) and OpenSRO's own OpAttack / OpUseSkill (the
  silent end). OURS: a refused move is answered with 0xB023 to the mover at the server's position
  (retail answers nothing; OpenSRO's client walks a click at once). The client (`ScrollHold`,
  `World3D._scroll_hold`) sends none of them while its own state is 1: no click walk, sky run, arrow
  key, walk into reach, attack or skill.
- Round 862, the rest (`ScrollHoldGate`, in front of every handler): every retail request
  (0x7000..0x7FFF) outside group 11's allow list is refused with the server's own answer (READ,
  `CGObjPC::vslot_358` 0x4ecbc0..0x4ece3e, each `Msg_SendTwoFieldReply` 0x4e7250 a {u8 2, u16 code}
  on the request's reply): 0x7034 -> 0xB034 {2, 0x181d}; 0x7045 -> 0xB045 {2, 0x6006}; 0x7046 ->
  0xB046 {2, 0x1c0b}; 0x70C5 command 2 -> 0xB0C5 {2, 2, u16 0x3009, u32 cos}, command 8 -> {2, 8,
  u16 0x4414, u32 cos, u32 item}, any other command nothing; 0x7155 -> 0xB155 {2, 0x5814} unless its
  byte is 1 (not built: OpenSRO's alchemy is OpAlchemy); 0x7158 runs as if allowed
  (`GObjPC::FUN_00518c20`); the rest -- 0x704F (sit), 0x70B1 / 0x70BA (stall), 0x7081 (exchange),
  0x706C (party match) -- get nothing. The emote 0x3091 too. The client shows none of these codes
  (0xB0C5's handler c:0x872590 sends 0x3009 under category 4 and 0x4414 under category 0xc of the
  error dispatcher c:0x7b8b40, neither of which has a case for them; 0x181d and 0x6006 the same).
  OpenSRO's own twins get the same silent refusal: OpInventoryMove, OpEquip / OpUnequip (an error
  text the client logs and shows nowhere) and OpPickUp (OpPickUpResult 0x4004, shown nowhere).
  **MEASURED** during a return scroll's cast: a bag move and taking the weapon off -> {2, 0x181d}, the
  item stays, nothing shown; a click on an NPC in reach -> {2, 0x6006}, no window, nothing shown; a
  pick-up (0x7074 kind 2) -> {3, 0, 0x4004}; the sit, an emote, the stall's title box Confirm, the party
  match window's 0x706C and a ground click get no answer and nothing happens; chat and a potion work;
  another return scroll -> 0x185d, shown in the warning banner and the system log (READ: category 1's
  0x185d case jumps to 0x7b8ccc, the banner 0x77b580 before the line; 0x185f, 0x1875 and 0x187a
  too; every other code of the table goes to 0x7b966d, the line only). Nothing of it cancels the cast:
  it ends on time and warps; the cancel button is the only early end. The 15 s special return scroll
  holds the same way (MEASURED: state 1, a ground click unanswered, a bag move {2, 0x181d}); the
  reverse return scroll's recall point sets the same state 1 (MEASURED, 0x30BF kind 0xb value 1) but
  its 1 s cast warped before a request could be tried.
- Left alone (unsure; the original refuses them too): the stall network's 0x7461..0x7463 (OpenSRO's
  own way in) and OpenSRO's own requests with no retail twin (the GM console, guild, party, storage
  and alchemy messages).

## 6. Verification

- Server: `go test ./internal/session -run 'Round77[89]'` (`scroll779_test.go`): the per-row
  delays, the state value, the 0x30BF before the reply and after the move, the spawn record's
  value, the cancel (no reply, state 0, nothing moves, the scroll stays spent, a new cast may
  start), the refusal 0xB05B {2, 6}, a death's cancel, the stop of a walker (0xB023 before the
  0x30BF), the NPC teleport's 0x1c14 before the range, the thief-den 0x186a, the reply's item id.
- Client: `scripts/ui/hud/return_scroll_cast779_test.gd` (the window and its rects, the fill and
  its 3000 ms cap, staying full, the cancel signal, the screen position at three sizes, the wire,
  the two codes' names).
- Round 860: `go test ./internal/session -run Round860` (`scroll860_test.go`: a click, an arrow turn
  and stop, a walked position, a stop report and 0x7074 refused while held, nothing moves, the
  cancel releases; the reverse scroll holds until its end; only value 1 holds) and
  `scripts/world/scroll_hold860_test.gd` (World3D's gates).
- Live on the render box: `/var/tmp/r779-cast/cast_shot.sh` (round 779's WORLD_ISSUES part).
