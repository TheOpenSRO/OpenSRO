# Per-instance durability, built end to end

Durability was fully READ (durability.md: the creation roll, the max formula,
the loss rolls, the broken rule, the client update, the repair cost) but
srrevamp carried none of it -- every item was indestructible and the shop's
repair buttons were inert. This builds it, every number from the spec's
citations, nothing invented.

## The instance

`internal/durability` is the pure rules, each constant cited to
SR_GameServer.exe: `RollWhiteStatUnit` (the min of three `rand()/32767`
draws), `RollVariance` (twelve 5-bit groups), `MaxDurability`
(`round(Dur_L + v0/31*(Dur_U-Dur_L))`, group 0 / 31), `LossChancePercent`
(`min(2*rate,100)`), the armour walk (slots 0..7 except the weapon, first
success), and `Apply` (clamp, refuse below 0, report the break). 20-case
table test; the min-of-three mean is checked at 0.25 over 100k draws.

An item instance now carries `Variance uint64` and `Durability int`
(`inventory.Slot`, `equipment.Equipped`), rolled once when the item is
created (`inventory.FreshInstance`) and carried unchanged wherever it goes:
equip/unequip, the warehouse, a trade, a ground drop picked up, the shop's
sell-rollback (`AddItemInstance` replaces the re-rolling `AddItem` on every
transfer path). Persisted in both stores (memory and the two SQL containers,
with `ADD COLUMN IF NOT EXISTS` migrations); a row from before this existed
reads `-1` (Untracked) and gets a real instance, once, on first read.

## Consumption

`performAttack` wears gear the way `Combat_ResolveDamage` +
`RollDurabilityLoss` do: a landed blow rolls the weapon (slot 6) once at
rate = hits; the counterattack rolls one armour piece per hit, or the shield
on a block. Every loss is -1 through `durability.Apply`; at 0 the item is
broken, and a broken weapon deals the unarmed damage while broken armour and
a broken shield defend for nothing (the three combat stat sums skip it, which
is how the engine's ParamKeeper removal shows up here). `SRREVAMP_DURABILITY_LOSS_ALWAYS=1`
is a QA accelerant (2%/hit is hundreds of swings otherwise), disclosed.

## Repair

`OpRepair` (0x007a/0x007b): repair one worn slot or all, charging the gold
`repair.Estimate` asks (unit price = itemdata col 28 / max, floor 1.0, cap
100000), restoring durability to max, refusing with the engine's own codes
(0x1c07 not enough money, 0x1c09 nothing to repair). The store window's two
authored buttons -- `GDR_STORE_BTN_REPAIR`, `GDR_STORE_BTN_REPAIRALL`,
read from `ifstore.txt` -- are wired to it.

## On the wire, additively

Inventory, equipment, move and repair results gain a **trailing** durability
block (u16 count, then per slot u32/s32/s32): it rides after the counted
records, so a client built before it stops at the count and never sees it,
while a newer client reads it. Tested: the slot bytes are byte-identical with
or without the block. The client shows real `Durability cur / max` in the
item tooltip (replacing the placeholder `L / L`) and dims a broken item's
icon (the exact original treatment is not recovered; the grey is ours).

## Verified

- `go test -p 1 ./...`: 55 packages ok. New: `internal/durability` (rules),
  `inventory` (fresh roll / instance carry / SetDurability / legacy init),
  `session` (repair over the wire + gold charged + full afterwards, the
  additive-block byte-identity, broken weapon -> unarmed, one-point wear +
  break).
- Live on the render box (`--server`, in-memory, YOUR build): the worn
  weapon rolled max **62**, and each landed hit dropped it 62 -> 61 -> ...
  -> 32 over 31 hits, persisted and logged (`durability lost ... slot=6`).
  A break + damage-drop is covered by the unit test rather than a
  multi-minute drain render.

## Disclosed / not done

- The durability tooltip line is on hover, which an offscreen QA frame does
  not capture; verified by the wire test and the server log, not a picture.
- Single-slot "Repair" falls back to "Repair All" -- there is no per-slot
  selection UI yet.
- The warehouse LIST does not emit the block yet (the instance still
  survives storage; the warehouse tooltip just will not show durability
  until a later pass).
- The broken-icon dim is our grey, not the original's treatment.
