# Ground items: dropping and picking up

How the real server (SR_GameServer.exe) handles an item lying on the ground,
recovered by reading the pick-up path, and what srrevamp built on it.

## The object

A dropped stack is a `CGItem` (`CGItem : CGObj : IGObj : CBase`). Its fields,
from the constructor `CGItem::vslot_000` (`0x0048f8a0`) and `CGItem::Update`
(`0x0048f9b0`):

| offset | meaning |
|---|---|
| `+0x14c` | busy: a pick is in progress (refuse others with `0x1813`) |
| `+0x150` | owner id; 0 = anyone may pick it |
| `+0x158` | elapsed seconds since the drop (accumulated in `Update`) |
| `+0x160/+0x164` | the drop's world position (set in `CGItem::Create`, `0x0048f930`) |

## Picking up

`GObjPC::CheckCanPickUp` (`0x004a9050`), reached through `CGObjPC::vslot_387`,
decides a pick. In order:

1. `IGObj::CanPick` -- vtable **slot 53**, named by the engine's own
   `"## Illegal ##  IGObj::CanPick Entered! TypeID: %u"` stub (`0x0057df40`).
   A ground item says yes; anything else is refused `0x1839`.
2. **Range**: the caller passes a limit -- the player path
   `.rdata 0xb45b44 = 10.0` (`CGObjPC::vslot_387`), the pet path
   `0xb462b4 = 2000.0`. The distance is the plain 3-D
   `sqrt(x²+y²+z²)` of `FUN_00405270`; beyond it, result **4**.
3. **Ownership**: the item's `+0x150`. The owner may pick; a same-party member
   may when the party shares items (the tail's `FUN_004ea200() & 2`); anyone
   else is refused **0x1812** until the window passes.

## The ownership window

`CGItem::Update` (`0x0048f9b0`) adds the frame delta to `+0x158` and compares it
against `.rdata 0xb45e58 = 30.0` seconds; past it, `GObjPC::FUN_004901c0`
(`0x004901c0`) clears the owner and sends `0x304D [u32 id]` to the zone. So a
drop is the killer's for 30 s, then anyone's.

## Not recovered

- **How long an unclaimed item lies there before it vanishes.** `CGItem::DoJob`
  (`0x00491750`) is an assert stub, and no per-item despawn sweep was located.
  srrevamp uses 3 minutes, own design.
- **The drop's scatter around the corpse.** Set in the spawn path, not in
  `CGItem`; srrevamp uses a 2-unit disc, own design.

## srrevamp's protocol (own, additive)

Server `internal/session/grounditem.go`, client `scripts/net/ground_items.gd`:

| op | dir | payload |
|---|---|---|
| `OpGroundItemList 0x006a` | c→s | (empty) -- what lies in my zone |
| `OpGroundItemListResult 0x006b` | s→c | u16 count, then snapshots |
| `OpGroundItemSpawned 0x006c` | s→zone | one snapshot |
| `OpGroundItemRemoved 0x006d` | s→zone | s64 id, s64 reason (0 picked / 1 expired), s64 picker |
| `OpGroundItemOwnerReleased 0x006e` | s→zone | s64 id (the real 0x304D) |
| `OpPickUp 0x006f` | c→s | name string, s64 ground id |
| `OpPickUpResult 0x0079` | s→c | s64 code (0 or an Err*), s64 ground id, s64 item id, u32 qty, u8 gold |

A snapshot is: s64 id, s64 item id, u32 quantity, u8 gold, f32 x/y/z, s64 owner
(0 = free). The refusal codes are the engine's (`4`, `0x1812`, `0x1813`,
`0x1839`). The drop CONTENT (`combat.LootTables`) stays placeholder own design;
the real per-monster drop tables are DB-only and unavailable.
