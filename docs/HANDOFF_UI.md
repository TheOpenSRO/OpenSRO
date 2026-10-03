# Handoff: the client UI

For the agent taking the **UI lane**. Written 2026-09-08, at commit `c475885` on `dev`.

There are two lanes running in parallel right now:

| Lane | Owns | Handoff |
|---|---|---|
| **UI** (this doc) | Everything the player looks at and clicks | this file |
| **World** | NPCs, format readers, terrain, object placement | [HANDOFF.md](HANDOFF.md) |

Read **[the "Do not collide" section](#do-not-collide)** before your first edit. It is the one
thing in here that will cost real time if skipped.

## Read these first

1. **`AGENTS.md`** (repo root) — the hard rules and the traps. Non-optional.
2. **`docs/REFERENCE_GAPS.md`** — observed differences against a live reference server, each with
   its evidence. Item 5 is the minimap; that is your headline feature.
3. **`docs/TODO.md`** — items 4 (minimap) and 5 (breaking up `World3D.gd`) are yours.

Three rules from `AGENTS.md` that apply to UI work as much as anything:

- **Never commit game data.** No `.pk2`, no extracted textures — not even as test fixtures. Users
  bring their own archives; the client reads them at runtime. If you build a theme from real UI
  art, it must be *loaded at runtime from the user's `Media.pk2`*, never checked in.
- **Never present a guessed value as a real one.** If a colour, size, or offset was not read out
  of real data, either verify it or leave it out — and say which it is.
- **A claim about the world needs a measurement, not a screenshot.** For UI this is softer, since
  layout genuinely is a visual matter — but "the panel is 240px because the reference looks like
  it" is a guess, and should be labelled one.

## What the UI is right now — measured, not impression

All of it lives in **one scene**, `client/scenes/World3D.tscn` (654 lines), under a single
`UI` `CanvasLayer` → `Control`, and is driven entirely from `client/scripts/World3D.gd`:

- A `ChatPanel` (log, input, send), `ZoneLabel`, `CharacterLabel`, `HelpLabel`, a zone-change
  `LineEdit` + button, a `DisconnectButton`, and a `HideUIButton`.
- One `ActionTabs` `TabContainer` with **ten** tabs — Monsters, Inventory, Equipment, Quests,
  Skills, Shop, Party, Guild, Trade, Friends. Every one is the same shape: an `ItemList`, a row of
  `Button`s, and a `StatusLabel`.

How much of `World3D.gd` that is: **79 of its `@onready` node references and 75 of its 162
functions are UI** (`_on_*` handlers), with 96 `.connect(` calls wiring them in code — the scene
file has only 2 `[connection]` entries, so essentially all signal wiring is in the script.

That is a **developer's debug UI**, not a game UI, and it is honest about that. It exists so a
human could exercise the network layer by hand. Nothing about it is precious.

## The good news: the data layer is done

Every system the UI would show is already implemented, wired to the server, and unit-tested. Under
`client/scripts/net/`, each with its own `_test.gd`:

`auth`, `character`, `chat`, `combat`, `duel`, `equipment`, `friend`, `guild`, `inventory`,
`packet`/`packet_reader`, `party`, `quest`, `shop`, `skill`, `trade`, `world`.

`NetClient` (`scripts/net/net_client.gd`, 538 lines) is an **autoload**, so any scene can reach it
without plumbing. This means UI work here is *presentation on solved data* — you should almost
never need to touch the protocol. If you think you do, that is worth a second look.

## Do not collide

`client/scripts/World3D.gd` is 5,259 lines and is the single file both lanes would otherwise fight
over. The world lane is actively editing it (region streaming, object placement, and shortly NPC
spawning).

**So your first task is also the deconfliction**, and it is already item 5 on `docs/TODO.md`:

> **Extract the UI out of `World3D.gd` and `World3D.tscn` into its own scripts and scene(s).**

Roughly 75 handler functions and 79 node references move out, which is close to half the file by
function count, and afterwards the two lanes touch disjoint files. Suggested shape — a suggestion,
not a mandate, and you should adjust it to what the code actually wants:

```
client/scenes/ui/HUD.tscn          the CanvasLayer, instanced by World3D.tscn
client/scripts/ui/hud.gd           owns the panels, talks to NetClient
client/scripts/ui/panels/*.gd      one per tab, each independently testable
```

The seam to aim for: **the HUD talks to `NetClient`, not to `World3D`.** Where a panel genuinely
needs the world (the minimap needs the player's position and heading; the zone box needs to ask
for a region change), define a small explicit interface — a couple of signals, or a narrow node
reference set once — rather than letting the HUD reach into `World3D`'s internals. That interface
is the contract between the two lanes; keep it small and say so in a comment when you add to it.

Two more practical points:

- **Do this incrementally and keep it green.** Move one tab, run the suite, commit. A big-bang
  refactor of a 5,000-line file that two agents are editing will not merge.
- **Announce the seam in the commit message** so the world lane can read it.

Also note `World3D.gd` carries a ~600-line **QA harness** at the bottom (`_qa_*` functions, driven
by `OPENSRO_QA_*` env hooks). That is diagnostics for the world lane, not UI — leave it where it
is. `docs/TODO.md` lists extracting it separately.

## The real client's UI art is available, and already decodable

**Verified 2026-09-08** by listing a real `Media.pk2`: it contains **8,538 files under
`interface\`**, which is the retail client's own interface art. The subdirectories map directly
onto the panels you would build:

| Directory | Files | What |
|---|---:|---|
| `interface\worldmap\` | 5,320 | world-map tiles |
| `interface\ifcommon\` | 643 | shared widgets, borders, arrows |
| `interface\outer\` | 346 | — |
| `interface\loading\` | 211 | loading screens (these are `.dds`, not `.ddj`) |
| `interface\frame\` | 175 | window frames |
| `interface\guild\` | 160 | |
| `interface\underbar\` | 93 | the action bar along the bottom |
| `interface\skill\` | 89 | |
| `interface\character\` | 77 | |
| `interface\chattingwnd\` | 59 | chat window |
| `interface\option\` | 56 | |
| `interface\equipment\`, `quest\`, `game\`, … | 40–50 each | |

These are `.ddj`, the same texture format this project already decodes — `client/scripts/ddj/`
plus `client/tools/dump_ddj.gd`, which writes any `.ddj` out as a PNG and reports its fourCC and
opacity breakdown. So authentic UI art is a solved input, not a research problem.

**The naming convention is a gift**: buttons come as `X.ddj`, `X_focus.ddj`, `X_press.ddj` —
normal, hover, pressed. That maps one-to-one onto a Godot `StyleBoxTexture` in a `Theme`. Building
a `Theme` at runtime from the user's own `Media.pk2` is very likely the highest-leverage single
thing you can do, because every panel then inherits the real look for free.

Whether the archive also contains a *layout* description (window positions and sizes, rather than
just the art) is **not established** — there are a handful of non-`.ddj` files under `interface\`
and a `jsonconfig.txt` under `vplus\`, but nobody has looked at them. Worth ten minutes before you
hand-place anything.

## Your headline feature: the minimap

`docs/TODO.md` item 4, `docs/REFERENCE_GAPS.md` item 5. The reference server shows a live minimap
with the region's art, the player's heading, and an X/Y readout; this project has a text zone
label. **Both halves of the hard part are already solved** — this is UI work on known data.

**The art.** Per-region minimap images live in `Media.pk2` as `minimap\<y>x<x>.ddj`. That spelling
is load-bearing: the reverse spelling names real but *wrong* regions, which cost this project time
once already. Decoding is done (`dump_ddj.gd`).

**The chrome.** `interface\minimap\` holds 25 files, verified present, and it is the whole widget:

```
mm_window.ddj          the frame          mm_alpha.ddj        the circular mask (21 KB)
mm_zoomin/out(.._focus/_press)            mm_map_button(.._focus/_press)
mm_sign_character.ddj  the player         mm_sign_npc.ddj     mm_sign_questnpc.ddj
mm_sign_monster.ddj    mm_sign_otherplayer.ddj                mm_sign_party.ddj
mm_sign_partyarrow.ddj mm_sign_questarrow.ddj                 mm_sign_location.ddj
mm_sign_animal.ddj     mm_sign_unique.ddj  mm_dungeonfloor.ddj
mm_sign_apprenticeship(.._arrow).ddj
```

**The coordinates**, recovered in the ninety-seventh round — this is the client's own readout
formula, not an approximation:

```
displayed X = (region_y - 135) * 192 + local_x / 10
displayed Y = (region_x - 92)  * 192 + local_z / 10
```

`server/cmd/wherecoord` implements it if you want to check a value.

**The axes**, which are the classic trap here and are settled — do not re-derive:

- region **y** → world **X**, region **x** → world **Z**
- region span is **1920** units; local coordinates run `[0, 1920)`
- the terrain group has `scale.z = -1` (a world Z mirror), so a naive world→minimap mapping will
  come out flipped; expect it rather than discovering it

**Suggested order**: static region art in a frame → player dot at the right spot → heading arrow →
X/Y readout → the sign icons for NPCs and monsters → zoom. Each step is independently checkable.

## Reading the reference screenshots

The user has supplied screenshots from a running private server (DUCKROAD). Two cautions, from
`docs/REFERENCE_GAPS.md`:

- It is a **private** server, so some content is custom — a Ducky Dungeon, Santa NPCs, event
  decorations — and must not be treated as the base game.
- Its **client is the real one**, so anything structural it shows is ground truth.

For UI specifically that split matters: the *window shapes and layout* are the real client and are
trustworthy; custom buttons and event banners are not.

## Running and verifying

```
godot4 --headless --path client --import --quit      # then run something that executes the code
for t in $(find client/scripts -name '*_test.gd'); do
  godot4 --headless --path client --script "res://${t#client/}" || echo "FAILED $t"
done
cd server && go build ./... && go test ./...
```

**A clean `--import` is not proof scripts compile.** It has reported 0 errors while serving cached
scripts, and a real run then showed hundreds. Always execute something. Also: a new `class_name`
is not visible to other scripts until after an `--import`.

**Headless tests do not catch UI bugs.** This is recorded feedback from the user, not a
hypothetical — a previous round of headless verification missed real WASD, camera, click and
texture bugs that only showed up in a live client. So caveat "verified" claims honestly: say
"tests pass" when tests pass, and "verified in a render" only when you have looked at a picture.

**To look at the UI**, `client/tools/qa_shot.sh` runs the real client and collects frames; see
`client/tools/README.md` first. `OPENSRO_QA_NOUI` exists to hide the UI for world shots — for
your purposes you want it *off*. Startup dominates (~65 s of loading against ~0.33 s a frame), so
batch viewpoints with `--shots` rather than taking one picture per run.

**GDScript traps that bite**: `for d in [-1, 0]` then `var t := r + d` fails to infer — write
`var t: int = r + d`. Same for `var x := f()` where `f` returns an untyped `Array`/`null` union;
use `var x = ...`.

## Conventions

- Work on **`dev`**, never push to `main`.
- The project's docs carry their reasoning, not just their conclusions — when you find something
  non-obvious, append a numbered round to `docs/WORLD_ISSUES.md` with the evidence. That file is
  the project's memory and it is why nothing here had to be re-derived.
- Update `docs/REFERENCE_GAPS.md` when you close a gap. Its rule: **"done" means verified in a
  render, not merely implemented.**
