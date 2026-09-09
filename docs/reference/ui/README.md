# UI reference screenshots

Screenshots from a running DUCKROAD server (a private server on the real client), supplied
2026-09-09, used as the visual target for the HUD work in [../../UI_TODO.md](../../UI_TODO.md).

**The image files are not in the repo.** They were pasted into a chat session, which does not
write them to disk, so what is preserved here is the catalogue below rather than the pixels. Drop
the PNGs in this directory using the filenames in the table if you want them alongside it — the
names are referenced from `UI_TODO.md`.

Two cautions carried over from [../../REFERENCE_GAPS.md](../../REFERENCE_GAPS.md): this is a
*private* server, so some content is custom and must not be treated as the base game; but its
client is the real one, so window shapes, layout and chrome are ground truth.

## What each screenshot shows

| Filename | Window | Authored layout | Notes |
|---|---|---|---|
| `hud-full.png` | The whole HUD in Donwhang | — | Player mini info top-left, minimap + zone name + X/Y top-right, underbar bottom, MENU popup, right-side quick buttons, chat bottom-left |
| `menu-popup.png` | MENU list (in `hud-full.png`) | `ifggmenu.txt`? | Party (P), Party Match (E), Guild (U), Academy (L), Guardian Matching, Action (A), Community (U), Quest (Q), Alchemy (Y), Craft, Collection book, Stall, Auto Potion (T), System (Esc) |
| `action.png` | Action | `ifaction.txt` | Character Control, Control created monster, Control summoned monster, Action Emoticon — 52 `CIFSlotWithHelp` in 4 `CIFSubFrame` groups |
| `party.png` | Party | `ifparty.txt` | 7 `CIFPartySlot` rows, Item Free-For-All / Exp Auto Share, Invite / Set / Party match |
| `party-match.png` | Party Matching | `ifpartymatch.txt` | Search filters, results table, Join/Whisper/Auto match/Form party/Change entry/Delete entry |
| `guild.png` | Guild | `ifguild.txt` | 3 tabs, member table, notice, Join/Check authority/Withdraw/Grant name/Position allocating |
| `academy.png` | Academy | `ifapprenticeship.txt` | Member list, notice, Invite / Matching |
| `community.png` | Community | `ifcommunity.txt` | 3 tabs, friends list (`0 / 20`), Whisper / Add friend / Delete friend |
| `quest-list.png` | Quest list | `ifquest.txt` | Quest rows with objective and Done state |
| `alchemy.png` | Alchemy | `ifalchemyprocess.txt` etc. | 4 tabs, item slot, 4 stone slots, Strengthen |
| `collection-book.png` | Collection book | — | Theme list + card grid |
| `input-window.png` | Input window (stall name) | `ifinputbox.txt`? | Generic prompt: label, line edit, Confirm / Cancel |
| `auto-potion.png` | Auto Potion | `ifautopotion.txt` | Character/Pet tabs, HP/MP/Vigor rows with %, belt, quickslot, sliders, delay |
| `system.png` | System | `ifsystem.txt`? | Option / Help / Restart / Exit |
| `character.png` | Character | `ifplayerinfo.txt` | Exp, stat points, Str/Int with HP/MP bars, phy/mag attack, defence, balance, hit, parry, job |
| `inventory.png` | Inventory | `ifinventory.txt` | 3 pages, 8x5 grid, equipment doll, gold, Auto Order / Auto Sort |
| `skill.png` | Skill | `ifskill.txt` | Weapon/Force tabs, mastery tabs, skill rows, Skill point / Mastery level total |
| `regional-map.png` | Regional map — Donwhang | `ifworldmap.txt` | Town map with named landmark icons |
| `entire-map.png` | Entire map | `ifworldmap.txt` | Continent view; `interface\worldmap\` holds 5,320 tiles |
