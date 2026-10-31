# Playing the client

A short guide to what the client actually does today. If something here does
not work, that is a bug worth reporting (see **Debug tools**, or type `/copy`
in chat for a full report on your clipboard).

## Moving

- **Click** the ground to walk there. Holding the button does nothing more, as in the original: click again to change where you are going.
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
| R | Reply to the last whisper (opens the chat line with `$<name> `, the game's own whisper line) |
| 1 ... 9, 0 | Use the hotbar's slots on the current page |
| F1 ... F4 | Hotbar pages 1 to 4 |
| Space + 1 ... 0 | Use quick slots 41 to 50: the Additional Quick Slot bar's ten |
| Alt + 1 ... 0 | Use the extra bar's slots on its current page (this client's own; see **The extra quick slot bars**) |
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
keys type into it; the F keys and Print Screen still work.

As in the original, Ctrl, Shift and Alt do not change a key: Ctrl+S opens
Skills like S. The exceptions are Ctrl+1 to 8 (select), Shift+F10 (hides the
interface; press it again to bring it back) and Alt+1 to 0 (the extra quick
slot bar, this client's own); Alt+Tab, Alt+F4 and Alt+Space are left to your
system.

Click an NPC to talk, buy, or use storage. An NPC or a teleport gate too far
away is walked to first, as in the original: the ring shows where you are
going, and the talk window opens when you get there. **Click a monster once
to select it, and again to attack it** (a double click, or Ctrl+click, attacks
straight away). As in the original, your character walks into reach and keeps
swinging at the weapon's own pace until it is dead, walking back in if the
monster gets out of reach. Walking away stops the attack. A melee skill hands
back to plain attacks when its animation ends; the staff, wand and harp bolts
do not.

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

**Click a learned skill to pick it up, then click a quickslot** of the underbar
to put it there -- as in the original, the icon sticks to the cursor between
the two clicks. Right-click a skill in the window to cast it. The number keys
**1..9 and 0** cast the current page's ten quickslots, or **right-click** a
slot; a left click picks the slot's icon up (click another slot to swap the
two, or anywhere off the bar to take it off). The arrows beside the slots flip
between four pages -- also while an icon is on the cursor, to put it on another
page. A skill needs a **target**: click a monster first, then
cast.

## The extra quick slot bars

**The Additional Quick Slot** is the original's: a bar of ten more quick
slots, always on screen (at first on the right, under the minimap). Its slots
are quick slots 41 to 50, used with **Space + 1 ... 0** or a right click, and
filled like the bottom bar's -- click a skill or item, then a slot; click a
slot to pick its icon up. Hovering a skill shows its tooltip beside the slot.
It has four buttons on its header:

- the long arrow folds the bar down to its header, and opens it again;
- the right arrow lays it out in a row, the down arrow in a column;
- the four-way cross opens its **Option** window: *Transparent* (see the
  world through the bar), *Lock Slots* (a click no longer picks an icon up;
  you can still put one down), *Lock Toolbar* (the bar can no longer be
  dragged) and *Two Lines* (two rows or columns of five instead of one of
  ten). **Apply** applies and keeps the window open, **Confirm** applies and
  closes it, the close button closes it without applying.

Drag the bar by its header to move it.

**The extra bars are this client's own.** Beside the original bar there is
one more of the same kind, with pages: the arrows at its foot (or right end)
turn the pages, labelled F5, F6, ... ; each page is ten slots of its own.
**Alt + 1 ... 0** uses the first extra bar's current page. Its Option window
has one more row, **Bars** and **Pages**: set how many extra bars to show (1
to 4) and how many pages each has (1 to 5), then Apply or Confirm. The
original bar's options, every bar's options, and where each bar was left are
remembered between sessions, in the `[ext_quick_slot]` section of
`settings.cfg` (the original game forgets the place when it closes). What the
slots hold is kept with the rest of your hotbar, for each character.

## Moving items

Every icon moves the original's way: **click it once and it sticks to the
cursor, click again where it should go**. A right click lets go of it without
moving anything.

- In the bag: click an item, then another slot (to swap or stack). To reach
  another page, click the page's tab while holding the item, then the slot.
- Worn gear: click it on the character, then the bag. As in the original, it
  goes into the first free slot of the bag, whichever slot you click. A bag
  item clicked onto the character is put on, and what was worn takes the bag
  slot it came from.
- At a shop: click a bag item, then the shop window, to sell it; click a shop
  item, then your bag, to buy it.
- At the warehouse: click a bag item, then the warehouse, to store it; click a
  stored item, then your bag, to take it out.

## Chat and commands

The chat line takes messages and slash commands. `/help` opens this help and
lists the commands. See **Debug tools** for the full list of testing commands.

The first character of a line picks who hears it, as in the original game:

| You type | Goes to |
|---|---|
| `hello` | everyone near you |
| `$Name hello` | a whisper to Name (`/w Name hello` works too); **R** fills in `$<last whisperer> ` |
| `#hello` | your party |
| `@hello` | your guild |
| `%hello` | your union (unions do not exist yet, so this is refused) |
| `&hello` | your academy (academies do not exist yet, so this is refused) |

The tabs across the top of the chat window -- All, #Party, @Guild, %Union and
&Academy -- filter what you see: All shows everything, a group's tab shows
that group's lines plus whispers and notices. Picking a tab also puts its mark
in an empty chat line. Scroll back with the arrows, the thumb or the mouse
wheel.

**Globals** go to every player: right-click a *Global chatting* item in your
bag, type the message in the "Chat to all" window and press **Use** (or
Enter). Each message uses one item.

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
kept in the `[audio]` section of `settings.cfg` (next to the log). The Input
and Game tabs are drawn but do nothing yet. Type `/uiscale <0.5 to 3>` in chat
to scale the interface (1 is the original's size) and `/names <0 to 400>` for
how near a name shows; both are remembered.

**Night and shadows (this client's own Video rows):** **Night Darkness**
decides how dark the night gets -- *Original* (the default) draws it exactly as the
zone's own lighting sets it (in many zones nearly as bright as day), *Dim* and
*Dark* lower the world's light after sunset. **Shadows Follow the Sun**
(on by default) turns the shadows with the sun through the day -- long at dawn
and dusk, short at noon, faint from the moon at night; it shows with **Shadow
Detail** on *Detail*. Off keeps the original's one fixed shadow direction. Without `Music.pk2` in your `pk2`
folder the world is silent and the log says so.

## Reports and the developer panel

- **`/copy`** in chat puts a full report on your clipboard: build, position,
  entities, loading and performance.
- **Log out** is the system menu's **Restart** (Escape), as in the original.
- **Shift+F3** — the debug panel (build, position, entities, loading,
  performance, zone travel), in a developer build only: a run from source, or
  a release build started with `OPENSRO_DEV=1` or with `tools=true` under
  `[dev]` in `settings.cfg`. In a player's build Shift+F3 is F3. (Shift+F1's
  zone box and Log Out and Shift+F2's debug tabs were the first prototype's;
  the original's windows replaced them.)

Your session writes a log to `user://logs/opensro.log`; type `/log` to see
exactly where, or to open the folder on desktop.
