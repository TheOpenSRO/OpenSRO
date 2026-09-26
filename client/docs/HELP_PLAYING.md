# Playing the client

A short guide to what the client actually does today. If something here does
not work, that is a bug worth reporting (see **Debug tools**, or press F3 →
Copy).

## Moving

- **Click** the ground to walk there.
- **W A S D** move relative to the camera.
- **Drag** with a mouse button to turn the camera; the **mouse wheel** zooms.
- Wedged in scenery? Type `/unstuck` to return to the zone's entry point.

## The camera

Three views (the names the original's own Option window uses):

- **Free Movement** — the camera follows you; you turn it with a drag.
- **Third Person** — the camera turns with your character.
- **Quarter Angle** — a fixed downward pitch; you turn it left and right.

`/cam free` and `/cam orbit` switch between free-look and orbit from chat.

## Windows and their keys

| Key | Window |
|---|---|
| I / O | Inventory (with the equipment paper doll) |
| K | Skills |
| Q | Quests |
| P | Party |
| U | Community |
| G | Guild |
| M | World map / minimap |
| Escape | System menu (Option, Help, Restart, Exit); or close the top window |

Click an NPC to talk, buy, or use storage. **Click a monster once to attack
it**: as in the original, your character keeps swinging at the weapon's own
pace until it is dead. Walking away stops the attack, and so does going out of
reach (the original walks you back in; this client does not yet, so step
closer and click again). A melee skill hands back to plain attacks when its
animation ends; the staff, wand and harp bolts do not.

**Balance note (server round 505).** A plain attack on a monster is now the
weapon's own basic attack skill, as in the original, so most plain hits got
stronger: a Chinese sword hits twice at 60% each (120% in all), bare hands hit
for 150%, and a staff hits for 180% of its magic damage. A Chinese bow hits for
84%, a little weaker than before. Mastery does not raise plain attacks yet. A
monster's defence against a staff, wand or harp swing is the same single
Defense value as against a sword. Duels have not changed yet: a plain hit on
another player is still the old single physical blow.

## Skills and the hotbar

Open **Skills** (K). A skill you can learn shows a **+** under its icon; learning
costs the SP shown and needs your mastery at the level shown -- and, as in the
original, some skills need another skill first (the tooltip says which, e.g.
*Requires: Power Strike Lv 9*), and each level needs the one before it.

**Drag a learned skill out of the window and drop it on a quickslot** of the
underbar (a plain click also puts it on the next free slot). The number keys
**1..9 and 0** cast the current page's ten quickslots, or click a slot; the
arrows beside the slots flip between four pages. A skill needs a **target**:
click a monster first, then cast.

## Chat and commands

The chat line takes messages and slash commands. `/help` opens this help and
lists the commands; `/w <name> <message>` whispers. See **Debug tools** for the
full list of testing commands.

**Enter** opens the chat line (plain Enter; not with Shift, Ctrl or Alt held),
and Enter sends what you typed, exactly as typed. The line keeps the keyboard
after a message, so you can type the next one. **Enter on an empty line** or
**Escape** closes it (with the bar's menu up, the first Escape closes the line
and the next one the menu). A left click on the open world, on a window or on
the bottom bar also closes it, including a window drawn over the chat; a click on the chat window
itself, or on the part of the line that overlaps the bottom bar, keeps it
open. While the line is open, the letter and number keys type into it instead
of opening windows or casting.

## Developer and debug panels

- **F1** — developer tools: zone travel and log out.
- **F3** — the debug panel: build, position, entities, loading and performance,
  with a **Copy** button that puts a full report on your clipboard.

Your session writes a log to `user://logs/srrevamp.log`; type `/log` to see
exactly where, or to open the folder on desktop.
