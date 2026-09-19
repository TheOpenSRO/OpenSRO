# Drops lane: items lie on the ground and are picked up

The user: "items don't drop on the ground when it dies." They did not drop at
all -- the kill dropped straight into the killer's bag (`OpLootDropped`), and on
the public server `monster_drops` is empty so nothing dropped even there. The
real game leaves items on the ground as objects the killer walks to and picks
up. Built that.

## What the engine does, read from SR_GameServer.exe

A dropped stack is a `CGItem` (`CGItem : CGObj : IGObj : CBase`), in world
state 2 ("on the ground"), its fields recovered from the constructor
(`CGItem::vslot_000`, `0x0048f8a0`) and `CGItem::Update` (`0x0048f9b0`):

- **Pick permission** is the `IGObj::CanPick` virtual, vtable **slot 53**
  (named by the engine's own `"## Illegal ##  IGObj::CanPick Entered!"` stub at
  `0x0057df40`). A ground item answers yes; picking a non-pickable object is
  refused `0x1839`.
- **The pick itself** is `GObjPC::CheckCanPickUp` (`0x004a9050`), reached via
  `CGObjPC::vslot_387`. It reads the item's owner at `+0x150` and busy flag at
  `+0x14c`, and takes a **range** as an argument: the player path passes
  `.rdata 0xb45b44 = 10.0`, the pet path `0xb462b4 = 2000.0`. Beyond range it
  sets result **4**; someone else's item inside the window is **0x1812**; an
  item already being picked is **0x1813**; the distance is the plain 3-D
  `sqrt(dx²+dy²+dz²)` of `FUN_00405270`.
- **The ownership window** is in `CGItem::Update`: the elapsed-time field at
  `+0x158` accumulates the frame delta and is compared against
  `.rdata 0xb45e58 = 30.0` seconds, then `GObjPC::FUN_004901c0` clears the owner
  (`+0x150 = 0`) and broadcasts `0x304D`. Inside it, only the owner (and, from
  `CheckCanPickUp`'s tail, a same-party member when the party shares items,
  `FUN_004ea200() & 2`) may pick.
- **The lifetime** before an unclaimed item vanishes was NOT found: `CGItem::
  DoJob` (`0x00491750`) is an assert stub and no per-item despawn sweep turned
  up. So it is own design, disclosed: 3 minutes.

Six names added to `recovered_names.tsv` would duplicate the coordinator's file;
they are cited inline in `internal/grounditem/grounditem.go` and
`docs/protocol/ground_items.md` (new) instead.

## Built

- **`internal/grounditem`** -- the ground-item hub with those rules
  (`PickRange` 10, `OwnershipWindow` 30 s, the refusal codes, `Lifetime` 3 min
  own design). Unit-tested: range at exactly 10 units, the 30 s window and the
  one-shot ownership release, a party member picking a shared drop, the busy
  flag, and expiry.
- **Server wire** (additive, `session/grounditem.go`): `OpGroundItemList
  0x006a`/`Result 0x006b`; `OpGroundItemSpawned 0x006c`, `Removed 0x006d`,
  `OwnerReleased 0x006e` broadcast to the zone; `OpPickUp 0x006f`/`Result
  0x0079`. `performAttack` (plain attack AND skill kill) drops the kill's gold
  as the pile the engine spawns (`ITEM_ETC_GOLD_03`, id 3, picked up as gold)
  and `combat.LootTables`' rolls as ground items within 2 units of the corpse
  (scatter own design), owned by the killer; a 1 s sweep releases windows and
  expires stale items. **The drop CONTENT is still the placeholder table** --
  the real per-monster drop tables are DB-only and in no reachable archive
  (RE_COMPLETION "Loot is DB-only, censused"); this changes where a drop goes,
  not what drops. `OpLootDropped` is no longer sent (a hub is always wired in
  `main.go`); the `nil`-hub path keeps it for the existing tests.
- **Client**: `GroundItemsNet` (decoders), `NetClient` signals/senders, and a
  `GroundItems` node that draws each stack with its `drop_model_path` model out
  of Data.pk2, a name plate, and a layer-7 click collider. `_try_pick_up_item`
  ray-tests that layer, asks the server, and walks to the item so the arrival
  re-asks if out of reach.

## Verified by measurement (render box, in-memory server, Jangan farmland)

Killing Mangyangs: two ground items spawn within the 2-unit scatter of the
corpse, owner = the killer; the list returns them; a pick from 50 units is
refused with server code 4 and the logged distance; stepping on and picking
returns code 0, puts "49 gold" on the character and the potion (id 4, x2) in
the bag, and broadcasts the removal -- zero refusals in range. Frame:
`scratchpad/drops/f00000149.png` (a drop on the grass at the fighter's feet,
target window up, EXP climbing). The full Go suite is green on a private test
DB; the shared `srrevamp_test` is clobbered by the other lanes running
concurrently.

## For the coordinator

Add the pick-up to `_unhandled_input`'s left-click chain, before the attack:
`if not _try_pick_up_item(p) and not _try_talk_to_npc(p) and not
_try_attack_monster(p): _try_set_move_target(p)`.

## Open / disclosed

- Drop **content** is the placeholder table (real drop tables unavailable).
- The unclaimed-item **lifetime** (3 min) is own design.
- The **drop scatter** (2 units) is own design; the engine's spread was not read.
- The item **name plate** for non-gold drops shows raw text -- item-name
  resolution is the tooltip lane's, not touched here.
- The server measures range in the horizontal plane only at the call site
  (monsters/drops sit at a placeholder y=0 while clients report real terrain
  height); the `internal/grounditem` rule is the engine's full 3-D distance.
