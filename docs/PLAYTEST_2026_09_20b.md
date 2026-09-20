# Playtest, 2026-09-20 (second report)

Twelve items from a live session. Verbatim, with what was found and what was
done. The first report of the day is `PLAYTEST_2026_09_20.md`.

| # | Reported | State |
|---|---|---|
| 1 | "i used a skill, no animation" | OPEN |
| 2 | "skills should be drag and drop" | OPEN — a drop path exists; needs checking end to end |
| 3 | "the first slot on the hotbar you press with 1, it should be middle mouse button and rebindable in the settings" | OPEN |
| 4 | "hotbars are assigned to f keys, it just says 1 now, and F1-F4 should scroll through them" | OPEN |
| 5 | "when i drag and unequip my sword, it doesnt go off of my character" | **FIXED** |
| 6 | "i cant unequip my clothes" | **FIXED** |
| 7 | "when i try to use this hp berry it just says malformed request" | OPEN — see below |
| 8 | "when i click on a mangyang its health bar appears but then my health shoots all the way down to 0" | OPEN |
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

## 8 — HP to zero on clicking a monster

Unreproduced and serious. There is no target-select opcode; clicking is
client-side targeting, so something in the attack/counterattack path is
draining the bar. Worth capturing an `F3 -> Copy` from the moment it happens:
position, target and the packet log would separate "the server dealt it" from
"the bar is being drawn wrong".
