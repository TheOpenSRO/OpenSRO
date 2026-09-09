# UI reference screenshots

Screenshots from a running DUCKROAD server (a private server on the real client), supplied
2026-09-09, used as the visual target for the HUD work in [../../UI_TODO.md](../../UI_TODO.md).

**The image files are deliberately not committed** (see the `.gitignore` here). `docs/LEGAL.md`
rule 1 is "no original assets in-repo", and a screenshot of the running client embeds its UI
artwork and its server's branding; the project's existing precedent agrees, since
`REFERENCE_GAPS.md` describes reference screenshots in prose and commits none of them. This
catalogue is committed, so the filenames are stable and can be linked from `UI_TODO.md` — put the
PNGs in this directory and they line up.

Fourteen of them are present in a working checkout as of 2026-09-09, supplied as an archive. Rows
marked **(not supplied)** were only ever pasted into a chat session and have no file.

Two cautions carried over from [../../REFERENCE_GAPS.md](../../REFERENCE_GAPS.md): this is a
*private* server, so some content is custom and must not be treated as the base game; but its
client is the real one, so window shapes, layout and chrome are ground truth.

## What each screenshot shows

| Filename | Window | Authored layout | Notes |
|---|---|---|---|
| `hud-full.png` **(not supplied)** | The whole HUD in Donwhang | — | Player mini info top-left, minimap + zone name + X/Y top-right, underbar bottom, MENU popup, right-side quick buttons, chat bottom-left |
| `menu-popup.png` **(not supplied)** | MENU list (in `hud-full.png`) | `ifggmenu.txt`? | Party (P), Party Match (E), Guild (U), Academy (L), Guardian Matching, Action (A), Community (U), Quest (Q), Alchemy (Y), Craft, Collection book, Stall, Auto Potion (T), System (Esc) |
| `action.png` **(not supplied)** | Action | `ifaction.txt` | Character Control, Control created monster, Control summoned monster, Action Emoticon — 52 `CIFSlotWithHelp` in 4 `CIFSubFrame` groups |
| `party.png` | Party | `ifparty.txt` | 7 `CIFPartySlot` rows, Item Free-For-All / Exp Auto Share, Invite / Set / Party match |
| `party-match.png` | Party Matching | `ifpartymatch.txt` | Search filters, results table, Join/Whisper/Auto match/Form party/Change entry/Delete entry |
| `guild.png` **(not supplied)** | Guild | `ifguild.txt` | 3 tabs, member table, notice, Join/Check authority/Withdraw/Grant name/Position allocating |
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
| `entire-map.png` **(not supplied)** | Entire map | `ifworldmap.txt` | Continent view; `interface\worldmap\` holds 5,320 tiles |
