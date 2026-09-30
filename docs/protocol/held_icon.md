# The icon on the cursor (round 652)

How retail moves an icon between windows: one click picks it up, the icon
sticks to the cursor, the next click puts it down. Read from `sro_client.exe`
(the client dump, `/var/tmp/decomp_client`) and `SR_GameServer.exe` (the
server dump, `/var/tmp/decomp_server`, and `srv.asm`). The client's
implementation is `client/scripts/ui/hud/held_icon.gd`.

Labels: **READ** (read from the binary), **INFERRED** (follows from what was
read, not read directly), **OURS** (our choice).

## The engine's globals (READ)

sriflib keeps four window pointers, each with a setter that tells the old and
the new window:

| Global | Getter | Setter | What |
|---|---|---|---|
| `0x0110f5fc` | `0xb9d9a0` | `0xb9d980` (message `0x4007`) / release `0xb9d9c0` | the mouse capture |
| `0x0110f600` | `0xb9da40` | `0xb9d9f0` (message `0x4008`) | the keyboard focus |
| `0x0110f604` | `0xb9db60` | `0xb9db10` | **the held icon** |
| `0x0110f608` | `0xb9dc00` | `0xb9dbb0` (messages `0x4009` enter / `0x400a` leave) | the window under the cursor |

`0xb9db10(wnd)`: if another window is held, its vslot 26 (`+0x68`) is called
(let go); then `wnd`'s vslot 25 (`+0x64`) is asked whether it may be picked
up, and the global is cleared again when it answers no. A window's
destructor (`0xb9d7a0`) clears the global if it is the held one.

`CIFDraggedStatic` (`0xee9518`, 0x6349d0..0x634b10) is a small CIFStatic that
keeps one int at `+0x380` (`0x634a30` set, `0x634a40` get); the drop handlers
test for it next to `CIFSlotWithHelp`, but the pick-up path below never
creates one. What creates it is not read.

## Picking up (READ)

- CIFWnd's message handler (`0x652540`, vslot 17 of 240+ classes) routes
  `0x202` (WM_LBUTTONUP) to the pick-up when the cursor is the normal one
  (`0x00eb6a48 != 0`; `0x777e70` clears it while a command cursor is up), none
  of Ctrl, Shift or Alt is down (`GetKeyState(0x11/0x10/0x12)`), and the
  window is pickable (`+100`, `0xb9db00`). Then, with no window capturing the
  mouse, `0xb9db10(this)`, and the release is consumed. Otherwise the release
  goes to the window's own vslot 29 (`+0x74`).
- Every `CIFSlotWithHelp` is created pickable: its constructor (`0x673c80`)
  pushes 1 to `0xb9daf0` at `0x673cf4`.
- `CIFSlotWithHelp` vslot 25 (`0x667fa0`): refuses an empty slot (`0x667ab0`:
  `+0x174 == 0`), else asks its parent window's vslot 25.
- The slot's own press (vslot 30, `0x46fd60`) and mouse move (vslot 35,
  `0x46fd10`) return 0. **There is no press-drag-release**: a press does
  nothing, a move does nothing, and a release picks up what is under it.
  (Vtable `0xda18e4`, read out of the exe's `.rdata`.)
- With a modifier the slot's vslot 29 (`0x680fa0`) runs instead: Ctrl+click
  with a store open is the quick-sell family; **Shift+click on a stack of
  more than one** opens the split box (`0x6b3fa0`, range 1..count-1), whose
  OK (`0x6b62d0`, message `0x8076`) moves that many into the **first empty**
  bag slot (`0x6b6280`).

## While something is held (READ)

The message pump (`gfxmainframe 0xba4450`) offers every mouse message to the
held window first, through its vslot 18 (`+0x48`, CIFWnd's `0x6523d0`):

| Message | What happens |
|---|---|
| `0x200` mouse move | passes on (returns 0) |
| `0x100` / `0x101` / `0x104` / `0x105` keys | pass on |
| `0x201` left press | swallowed, unless the window under the cursor is a `CIFButton` (`0xee9828`) or a `CIFSelectableArea` (`0xee96c0`, the bag's page tabs) |
| `0x202` left release | over a capturing CIFButton or a CIFSelectableArea: passes on. Otherwise the held window is offered to the window under the cursor and then to each of its parents (vslot 28, `+0x70`, with the depth) until one returns true; then **let go whatever the answer** (`0xb9db10(0)`) |
| `0x204` right press | let go: **the cancel** |
| anything else | swallowed (double clicks, the right release, the wheel) |

So an item is carried to another page of the bag by clicking the page tab
while holding it: the tab takes the press (tabs act on the press, `0x64cb80`).
This settles round 633's open question.

`CGame 0x8423d0` draws the held window each frame at `mouse - size/2` (its
vslot 24): the icon is centred on the cursor.

## Putting down (READ)

`CIFSlotWithHelp` vslot 28 (`0x666560`) forwards to its window's vslot 28
with `(held, this, depth + 1)`. The windows:

- **`CIFInventory::vslot_028`** (`0x6b5b80`): by the held slot's window kind
  (`0x666700`): `0x46` the bag, `0x47`/`0x4e` the worn slots, `0x0f` the
  store, `0x13`/`0x91` the warehouse, `0x1a` the exchange, `0x7a` the guild
  storage, `0xa8` alchemy, `0x21`, `0x45`, `0x52`, `0x9c`. Most end in
  `FUN_007950b0`, the 0x7034 sender. A bag-to-bag drop passes quantity `-1`:
  the whole stack.
- **`CIFUnderBar::vslot_028`** (`0x68dd10`): kind `0x0c` (a quick slot) swaps
  the two slots; `0x19` (the skill window) puts the skill there; `0x46`,
  `0x47`, `0x4e`, `0x25`, `0x49`, `0x4a` put the item there. It sets `+0x3b1`
  to 1 for everything but the swap. **`CIFUnderBar::vslot_026`** (`0x68d140`,
  the let-go hook): with `+0x3b1` set it clears the let-go slot (`0x67ece0`)
  and saves it (`0x68cec0`); so a quick slot's icon put down anywhere but the
  bar comes off the bar. (The flag's meaning is INFERRED from those two.)
- **`CGInterface::vslot_028`** (`0x78abe0`), the world (depth 0): a bag item
  opens the drop confirmation (`UIIT_MSG_DROP_WARNING_1` / `_2`, storing
  `invenitem_ParentWndKind`, `invenitem_refID`, `invenitem_slotIndex`); a worn
  item writes system message `0x186d`,
  `UIIT_MSG_STRGERR_CANT_DROP_EQUIPED_ITEM_DIRECTLY`; anything else is simply
  let go.

## Using with the right button (READ)

`CIFSlotWithHelp` vslot 32 (`0x6665b0`, right press) captures the mouse;
vslot 33 (`0x685ee0`, right release) releases it and, for a filled slot, runs
`0x682040` by window kind: `0x0c` a quick slot is used (`0x60bb80`), `0x19` a
skill in the skill window is **cast** (`0x81ba10`, the same call a quick slot
holding a skill makes, `0x60b850`), `0x46` a bag item is used when nothing is
held, `0x47` a worn item toggles a sub-view (`0x680cf0`).

## The 0x7034 move request (READ, `FUN_007950b0`)

Built as `type` (byte at +0), source (+3), destination (+4), quantity (u16 at
+6); a drop on the slot it came from sends nothing (`src != dst` test). Bag
slots are sent as `slot + 13` (the 13 worn slots come first).

| From → to | Type | Source | Destination |
|---|---|---|---|
| bag → bag | 0 (0x27 / 0x28 in two stack cases not read) | bag + 13 | bag + 13; quantity the whole stack |
| bag → worn | 0 | bag + 13 | worn slot |
| **worn → bag** | 0 | worn slot | **bag + 13: the clicked slot** (the server ignores it, below) |
| worn → worn | 0 | worn | worn |
| bag → ground | 7 | bag + 13 | — |
| worn → ground | 7 | worn | — (the world refuses it first, above) |
| bag → store | 9 | bag + 13 | — (quantity) |
| store → bag | 8 (0x2b in one branch) | `tab*16 + slot` | — **no bag slot is sent** |
| bag → warehouse | 2 | bag + 13 | warehouse slot (`0x6cce10`) |
| warehouse → bag | 3 | warehouse slot | bag + 13 |
| warehouse → warehouse | 1 | slot | slot |
| bag → exchange | 4 | bag + 13 | — |

## Where the server puts it (READ, SR_GameServer)

`FUN_00523860` dispatches move type 0 by the two slots: bag→bag
`FUN_004b2450` (move / merge / swap); bag→worn `CGObjPC::AttachEquipItem`
(`0x524cd0`, slot 8 `0x524950`); worn→bag `CGObjPC::DetachEquipItem`
(`0x5255e0`, slot 8 `0x524b20`).

- **AttachEquipItem swaps**: `CGStorage::SwapItem(bag, worn)` -- the item that
  was worn goes into the bag slot the new one came from.
- **DetachEquipItem does not honour the destination.** It requires a free bag
  slot (`0x1807` otherwise) and then, for armour and accessories,
  `push 0xd; call CGStorage::FindFirstEmptySlot; mov [edi+0x4],al` at
  `0x5258c6` -- the request's destination overwritten with the first empty
  slot -- before `CGStorage::MoveItem(src, that)`. The weapon branch does the
  same (and moves the arrows at slot 7 to the next empty one). Retail's server
  therefore puts an unequipped item in the first free slot whatever was
  clicked.

srrevamp does the same (READ, by the user's choice, 2026-09-30: "Match
original"): the client sends the clicked slot as retail's does (a trailing
int32 on OpUnequip), and the server parses it and puts the item in the first
free bag slot, as DetachEquipItem does -- no swap onto an occupied slot. Equip
swaps as AttachEquipItem does. (Round 652's first build, 9b40d12, honoured the
clicked slot as OURS; that is gone.)

## Not read

- What creates a `CIFDraggedStatic`, and what the slot left behind looks like
  while its icon is on the cursor (ours dims it).
- The storage-to-storage and warehouse-slot placement on our server (our
  deposit and withdraw carry no slot).
- The ground drop (our server has no player drop).
