# Playtest, 2026-09-20 (second report)

Twelve items from a live session. Verbatim, with what was found and what was
done. The first report of the day is `PLAYTEST_2026_09_20.md`.

| # | Reported | State |
|---|---|---|
| 1 | "i used a skill, no animation" | **FIXED** (disclosed fallback; see below) |
| 2 | "skills should be drag and drop" | **ALREADY WORKS** — `_on_skill_drop_requested`; drag a skill onto a quickslot |
| 3 | "the first slot on the hotbar you press with 1, it should be middle mouse button and rebindable in the settings" | **HALF-FIXED** — MMB fires slot 1; rebinding needs a key-bindings UI |
| 4 | "hotbars are assigned to f keys, it just says 1 now, and F1-F4 should scroll through them" | **FIXED** |
| 5 | "when i drag and unequip my sword, it doesnt go off of my character" | **FIXED** |
| 6 | "i cant unequip my clothes" | **FIXED** |
| 7 | "when i try to use this hp berry it just says malformed request" | **ADDRESSED** — consumables can now go on the bar; the exact refusal is still unreproduced |
| 8 | "when i click on a mangyang its health bar appears but then my health shoots all the way down to 0" | **FIXED** |
| 9 | "there is such thing as hp recovery, its a stat for the player and it passively restores health" | **FIXED** |
| 10 | "i can still see my butt in my cotton clothes" | OPEN (carried from the first report, item 6) |
| 11 | "clothes/armor are not unequippable" | **FIXED** (same as 6) |
| 12 | "i picked up gold ... it told me that i could not pick it up because my inventory might be full, it was not" | **FIXED** |

## 12 — the gold pick-up that succeeded and reported failure

Both halves of this were real, and the second is the worse one.

`_try_pick_up_item` set a walk target **unconditionally**, even when the player
was already standing on the drop. The movement code's arrival branch then fires
immediately and sends a **second** `pick_up` for the same id. The server grants
the first, removes the item, and answers the duplicate with `0x1839`.

Gold falls at your feet when a monster dies, so this was near-certain for gold
and rare for anything else — exactly the shape of the report.

Fixed by walking only when the drop is actually out of `PICK_RANGE`, and by
tracking a request in flight so the arrival branch cannot duplicate one.

**And the message was an invention.** `0x1839` is "no such pickable item" — the
drop is gone. The client rendered it as *"your inventory may be full"*, a cause
the server never gave and which was false here. It now says "That drop is no
longer there", and `ERR_TOO_FAR`, which had no line at all, says so too.

## 9 — passive HP recovery

The player is right, and the mechanic was already recovered: `internal/mana`
holds `CGObjPC::vslot_362` — a percentage of the **current** pool, floored at 1,
capped at half the current pool, on a **real** 4-second interval
(`.rdata 0x00b45dc0` = 4.0, unit read in round 223).

**Nothing ever called it.** `RegenPerTick` had no callers outside its own tests.

`session.RunRegen` now ticks every online character on that interval, heals
through the store and pushes the refreshed stats so the bar moves. Two details
of the engine's arithmetic survive and are tested: a character on **1 point does
not regenerate at all** (the half-of-current cap truncates the floored 1 to 0 —
a mechanic the engine spends four instructions on), and a character on 0 stays
on 0, so regen cannot revive the dead.

The percentage itself remains disclosed — `'mprg'` is 0 on every real row, and
`mana.go` says so at the constant.

## 5, 6, 11 — unequip

Two independent faults, which is why it looked total.

**The 3D body was never redressed.** `_on_equipment_result` updated a text
widget and nothing else; the character model was built once at login by
`_try_apply_real_player_character` and never rebuilt. A successful unequip
therefore emptied the slot and left the sword in the hand. The rebuild is now
split into `_apply_player_equipment_visual`, which the equipment result calls
directly — it cannot re-ask, because it is inside that signal's own handler.
The old skeleton is freed first; without that the change would stack a second
dressed body on the player on every equip.

**The drop target was too strict, and failed silently.** `_drop_worn_item`
required the release to land on an exact bag grid cell; a few pixels into a
gutter did nothing and said nothing. Anywhere over the open inventory window now
takes the item off. The server still chooses the bag slot — the drop point was
never sent — so this changes where you may let go, not where the item lands.

## 7 — "malformed request" on the HP berry

Not reproduced yet, and the obvious suspect is cleared: the client's
`UseItemNet.encode_use` (u16 name length, name, s64 slot) matches
`DecodeUseItemRequest` exactly, and `"malformed request"` in the use-item
handler is reachable **only** from a decode failure.

So the request that failed was probably not `OpUseItem`. The hotbar holds
**skills only** (`_quickslot_skills`), which is also items 2 and 3 of this
report, so a berry placed there would go down a skill path. That is the next
thing to read, together with item 2.

## 8 — HP to zero on clicking a monster: the server said zero, and meant nothing by it

Found and fixed. `AttackResult.PlayerHP` is what the client paints the health
bar from, and an `int32` left at its zero value is indistinguishable from *you
are dead*.

The handler has three branches after a blow lands: the monster died, the monster
is **inside its attack skill's re-use delay**, or it counterattacks. Only the
first and third ever wrote `PlayerHP`. The middle one is a comment and nothing
else -- there is genuinely no reply to compute -- so it shipped the field at 0.

Mangyang's re-use delay is **3000 ms** and a player swings faster than that, so
the second swing of any fight hit that branch and emptied the bar. The health
was never lost; only the number sent to draw it.

`PlayerHP` is now seeded from the character's real HP where the result is built,
before any branch runs, and every branch that changes HP overwrites it.
`TestAttackResultNeverReportsZeroHealthForALivingPlayer` swings twice so the
second is inside the delay by construction, and checks the reported value
against the store. Reverting the fix makes it fail with
`PlayerHP = 0 while the character really has 198`.

## 3 and 4 — the hotbar keys

The bar already had four pages of ten slots and a page indicator; the "1" was
that indicator, working. What was missing was a way to choose a page with the
keyboard, so **F1..F4 now select pages 1..4** directly.

**This moved two developer keys**, which is worth saying plainly: F1 was the
dev-UI toggle and F3 the debug panel, and the debug panel is how visual bugs get
reported (`F3 -> Copy`). They are now **Ctrl+F1** and **Ctrl+F3**.

The middle mouse button now fires the current page's first quickslot. The 1 key
still addresses the same slot, so this adds a binding rather than removing one.
**Rebinding is not done**: it needs a key-bindings section in the options window,
which does not exist -- the same gap as "the old silkroad had a graphics section
under options" from the first report.


## 1 — the skill that played no animation

Measured rather than guessed, and the answer is that most skills have no clip.

The lookup rule is right: `Prim\Ani\Char\China\<gender>\<base>.ban` where
the base is the Basic_Code lowercased with its level suffix dropped. A
truncated directory listing briefly suggested the `skill_ch_` prefix was not
used in filenames — it is, in **135 of the 334** clips, and the numbers said so
before the guess got anywhere (18.3 % of rows against 1.9 % for the stripped
form).

**But of the 338 distinct clip names the China skill rows derive, only 59
exist.** Stripping the prefix as a fallback gains exactly one. Scanning every
skilldata column for an animation filename turned up one candidate, column 5 at
half the rows, which is the skill's own base code matching itself.

So 82 % of skills ship no cast clip, and casting one played **nothing at all**.
The client now falls back to the weapon's ordinary attack animation, so a cast
always shows something. That is a **disclosed stand-in**, not recovered
behaviour: what the original plays for those skills is unknown, and the effect
layer (`.efp`) is where to look next.

## 2 — drag and drop

Already implemented: `_on_skill_drop_requested` puts a skill dragged out of the
skill window onto the quickslot under the mouse, and clicking a skill assigns it
to the next free slot. If it is not working in play that is a different bug from
the one reported, and worth a fresh description.

**Items can now go on the bar too** — see below.

## 7 — consumables on the quickslot bar

The quickslots held **skills only**, so a potion could not be put there at all.
Dragging a bag item out of the inventory and releasing it over the bar did
nothing: `_drop_bag_item` handled a bag slot and the paper doll and then simply
returned.

Bag items now reach the bar through a new `item_drop_requested` signal, and
activating such a slot sends `OpUseItem` for the item's bag slot.

**The binding is re-resolved on every inventory refresh**, which is the part
with a real bug in it if done naively. A quickslot stores a BAG SLOT, because
that is what `OpUseItem` addresses -- but spending, moving or selling shifts
what lives in a slot, so a binding left alone would point at whatever took its
place and use the wrong item. `HudUnderbar.resolve_item_binding` prefers the
slot the binding already names, then finds the item anywhere, then unbinds; six
cases are tested, including two stacks of the same item.

**The reported message itself is still unreproduced.** `"malformed request"` is
reachable only from a decode failure, the use-item encoder and decoder match
byte for byte, and dragging an item onto the bar previously sent nothing at all
-- so whatever failed was some other request. If it recurs, the opcode is what
identifies it.
