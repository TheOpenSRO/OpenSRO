# Playing the client

A short guide to what the client actually does today. If something here does
not work, that is a bug worth reporting (see **Debug tools**, or press Ctrl+F3
→ Copy).

## Moving

- **Click** the ground to walk there, or hold the left button to steer.
  There is no keyboard walking: the keys are the original game's, where
  W, A and S are the pet-switch, action and skill keys.
- **Drag** with the right mouse button to turn the camera (not in the Third
  Person view, which stays behind you); the **mouse wheel** zooms.
- Wedged in scenery? Type `/unstuck` to return to the zone's entry point.

## The camera

Three views (the names the original's own Option window uses):

- **Free Movement** — the camera follows you; you turn it with a drag.
- **Third Person** — the camera turns with your character.
- **Quarter Angle** — a fixed downward pitch; you turn it left and right.

**F9** switches to the next view (free, third person, quarter, then free
again), as the original's F9 does. `/cam free` and `/cam orbit` switch from
chat.

## The keys

The keys are the original game's own defaults (its key table, read from the
client). Keys for things this client does not have yet (pets, the item mall)
do nothing for now. A window to change the keys is not built yet.

| Key | Does |
|---|---|
| C | Character |
| I | Inventory (with the equipment beside it) |
| S | Skills |
| A | Actions (emotes, sit) |
| P | Party |
| Q | Quests |
| U | Guild |
| M | World map |
| T | Auto potion |
| E | Party matching |
| Y | Alchemy |
| L | Academy |
| H | Help (this window) |
| Tab | Berserk, when the five orbs are full |
| N | Sit down / stand up |
| G | Pick up the nearest item on the ground (within 50; you walk to it) |
| **Hold V** | Hide other players and monsters, so you can see NPCs |
| **Hold Z** | Show the names of items on the ground nearby (within 300) |
| X | Use the "m" slot of the hotbar (as the middle mouse button does) |
| R | Reply to the last whisper (opens the chat line with `/w <name> `) |
| 1 ... 9, 0 | Use the hotbar's slots on the current page |
| F1 ... F4 | Hotbar pages 1 to 4 |
| Space + 1 ... 0 | Use hidden quick slots 41 to 50 |
| F9 | Next camera view |
| F10 | Hide or show the UI (the original's F10 is the item mall, which this client does not have) |
| Print Screen | Save a screenshot: a `.jpg` in the `screenshots` folder beside the `logs` folder that `/log` opens (the chat line says the full path) |
| Enter | Open the chat line |
| Escape | Close the top window, or open the System menu (Option, Help, Restart, Exit) |
| Ins, Home, Page Up, Del, End, Page Down, W | Pet commands: info, ride, dismiss, follow, attack, AI, switch. There are no pets yet, so these do nothing. |
| Ctrl+1 / Ctrl+2 ... 8 | Select yourself / a party member. Not built yet: the target window shows monsters only. |

An item's name shows while the mouse is on it, or while you hold **Z**; it is
hidden otherwise, as in the original.

While the chat line (or any other text box) is open, the letter and number
keys type into it; the F keys, Ctrl+F1 to F3 and Print Screen still work.

As in the original, Ctrl, Shift and Alt do not change a key: Ctrl+S opens
Skills like S. The exceptions are Ctrl+1 to 8 (select) and Ctrl+F1 to F3
(developer panels); Alt+Tab, Alt+F4 and Alt+Space are left to your system.

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

Open **Skills** (S). A skill you can learn shows a **+** under its icon; learning
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

## Sound

Sound is on. Each town and area plays its own music from your `Music.pk2`, and
its own wind, birds and other ambience from `Data.pk2`; the login, character
select and character create screens play the title theme. Changing area
fades the old music out over about two and a half seconds and starts the new
one; areas that share a track keep it playing. The loading screen is silent.

The interface makes the original's sounds, and only where the original does:
a swoosh when the character, inventory, skill, action, party or academy window
opens or closes by its key (switching between them by key swooshes too), for
the world map (M), party matching (E), auto potion (T), the alchemy window
(Y), the System menu (Escape), a shop or warehouse opened from an NPC, and a
window's close button. The quest (Q) and guild (U) windows, the NPC talk box
opening and ordinary buttons are silent, as in the original. You also hear the
level-up, drinking a potion, moving or wearing an item (by kind: sword, robe,
ring...), gold and elixir drops, repairs, and an error beep when the login is
refused. Footsteps and combat sounds come from their own rounds.

**Options:** Escape -> System -> **Option** opens the original Option window.
It opens on its Video tab; click **Audio** for three sliders -- Music (BGM),
Effects and Environment, 0 to 100 -- each with a mute box beside it. Changes
are heard at once. **Confirm** saves and closes, **Apply** saves, **Default**
sets all three to 50 and clears the mutes, and **Cancel**, the close button or
Escape put back what was saved. The starting volumes are the original's:
**Music 30, Effects 50, Environment 50** (0 is -20 dB, 100 is full). They are
kept in the `[audio]` section of `settings.cfg` (next to the log). The Video,
Input and Game tabs are drawn but do nothing yet; the debug panel (Ctrl+F3)
still has the UI scale and camera settings. Without `Music.pk2` in your `pk2`
folder the world is silent and the log says so.

## Developer and debug panels

- **Ctrl+F1** — developer tools: zone travel and log out.
- **Ctrl+F2** — the old debug tabs (inventory, shop, party and the rest).
- **Ctrl+F3** — the debug panel: build, position, entities, loading and
  performance, with a **Copy** button that puts a full report on your
  clipboard.

Your session writes a log to `user://logs/srrevamp.log`; type `/log` to see
exactly where, or to open the folder on desktop.
