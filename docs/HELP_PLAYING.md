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

Click an NPC to talk, buy, or use storage. Click a monster to target it, then
attack.

## Chat and commands

The chat line takes messages and slash commands. `/help` opens this help and
lists the commands; `/w <name> <message>` whispers. See **Debug tools** for the
full list of testing commands.

## Developer and debug panels

- **F1** — developer tools: zone travel and log out.
- **F3** — the debug panel: build, position, entities, loading and performance,
  with a **Copy** button that puts a full report on your clipboard.

Your session writes a log to `user://logs/srrevamp.log`; type `/log` to see
exactly where, or to open the folder on desktop.
