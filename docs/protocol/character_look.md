# What a character looks like: CharacterLook (round 847)

The user (2026-10-30): "another bug to fix: the character selection doesn't reflect model
changers. Make sure it shows what it's supposed to show from now on. Shouldn't there be a class
or something that is basically the visual rep of the character and things can call it so we're
not changing it in 30 places?"

Labels: **READ** (the decompiled `sro_client.exe`, `/var/tmp/decomp_client` on the render box),
**MEASURED**, **INFERRED**, **OURS** (OpenSRO's design), **OPEN**.

Code: `client/scripts/ui/character_look.gd` (the value), `client/scripts/ui/character_appearance.gd`
(the builder), `server/internal/session/lobby.go` and `lobbyhandler.go` (the list). Tests:
`character_look847_test.gd`, `lobby847_test.go`, the golden vectors in
`client/scripts/net/testdata/lobby_golden.json`.

## 1. What retail's select screen draws (READ)

The list handler (`FUN_0085f840`) reads a u8 count, then per character
the record (`FUN_0085e620`, the layout in `charselect.md` section 5) and dresses the model
(`PSCharacterSelect::FUN_0085a580`). Nothing is read after the last record.

- **The record per worn item:** u32 RefItemID and u8 plus, at most 9 (equip slots 0..8, the
  job suit's slot 8 among them); per avatar u32 RefItemID and a u8 the client discards, at most 5.
  No own id, no model, no slot: the slot is the item's (`ResolveVisualSlotForItem` 0x9db5e0).
- **Each item** goes through `CObjCharacter::InstallEquipVisual(vslot, RefItemID, plus, 0)`
  (0xa61010): one visual per slot, the plus stored beside it (`this + (vslot * 3 + 0xf) * 4`).
  When the item's resource has loaded, `FUN_00a60a90` calls `FUN_00a5f3e0` for the weapon and
  shield attachments with that RefItemID and plus: the glow row (`itemoption.txt` /
  `itemtypenumber.txt`) and the seal's and the +8 sparkle's particles (`itemrare.txt`,
  `itemoptionefp.txt`). This is the world's path. **So the select screen draws the glow and the
  seal effects** (READ; `charselect.md` had it INFERRED).
- **The job suit** (TypeID3 7) resolves to vslot 8 and is installed like any other item: the
  select screen draws the suit when it is worn (READ, no job-state test in `FUN_0085a580`).
- **Avatars:** only an item that is 3/1/13 (the 0x680 test on its TypeID word in `FUN_0085a580`) is attached (`FUN_00a60ef0`, no plus); a devil's spirit (3/1/14) is not.
  OpenSRO's builder draws a devil's spirit as nothing too (`CharacterVisualChange`, round 789).
- **The scale byte:** `FUN_00a5b960(record scale, 0)`: Height and Volume as in the world.

So retail's select screen shows exactly what the record names, as the world would draw it. A
model switcher is not retail's (`item_switchers.md` section 3); the record has no room for the
item's own id.

## 2. The fix for the select screen (OURS)

- **The record names the drawn row** (`lobbyhandler.go` `record`): a switched item is listed as
  its `_SWITCHnn` row (`displayRef`), as the spawn record and 0x3038 have named it to other
  players since round 838. Its plus is unchanged.
- **The item's own id rides a trailer** (`LobbyResult.Encode` -> `appendOwnTrailer`), the
  0x3038 `Own` of round 843 for the list: after the last record, written only when some listed
  item is switched,

  ```
  u16 count
  per entry: u8 character index (the list's order), u8 item index (that record's items), u32 own RefItemID
  ```

  A retail client reads the records and stops, so it never sees it; OpenSRO's client
  (`LobbyNet._decode_own_trailer`) puts it on the item as `"own"`, and an entry that names no
  listed item is a decode error. The golden file holds both sides to the same bytes.
- **The select screen builds the record's look** (`CharSelectStage.set_characters` ->
  `CharacterLook.from_lobby`): the twin is drawn, and where its row has no glow or seal rows the
  item's own stand in (`CharacterAppearance.glow_sources`, round 843): the twin's mesh, the plain
  twin's glow type, the unlocked item's seal and sparkle.

## 3. The model: CharacterLook (OURS)

One plain value (`RefCounted`, no scene, no archive): everything that decides how a character is
drawn.

| Field | What |
|---|---|
| `ref_obj_id` | the body's characterdata row (0 when a source names only a gender) |
| `gender`, `race`, `body` | World3D's gender code, 0 China / 1 Europe (-1 unknown), World3D's body key when a source named one |
| `scale` | the scale byte: Height low nibble, Volume high nibble (READ `FUN_00a5b960`) |
| `worn` | key -> the RefItemID **drawn** (a model switcher's row for a switched item) |
| `pluses` | key -> the plus byte the glow is chosen by (OptLevel + advanced elixir); a key it lacks is +0 |
| `own` | key -> the item's **own** RefItemID where `worn` names a model switcher's row |

Keys are the equip slot (0..12) where the source names one, the item's place in its list where
it does not (the 0xB007 record, the create kit), and `AVATAR_KEY_BASE + n` (200..204) for the
avatars -- the avatar inventory's dresses, hats, attachments, wings, flags and the devil's spirit
(round 838's mall visuals are avatars). The builder reads an item's visual slot from its TypeIDs,
never from its key.

- **The job suit** is `worn[8]` (`suit()`); the job state the plate and colours follow is derived
  from it (`FUN_009dbcc0`), not kept beside it.
- **Not in it, MEASURED by the census:** a mount changes no input of the body's build -- a rider
  is seated on the COS (`World3D._cos_seat`) without a rebuild -- and a weapon swap is slots 6 and
  7 changing (round 831's pose carry is the body's animation state, not its look).

**Sources (one builder each):**

| Builder | From |
|---|---|
| `from_lobby(LobbyNet.Character)` | the 0xB007 record and its own-id trailer |
| `from_spawn(WorldNet.EntitySnapshot, body)` and `spawned(...)` | the 0x3015 / group spawn snapshot; a repeat spawn of a drawn body (its items only when it names some; round 739's rule) |
| `from_equipment(equipped, instances, avatars, avatar_pluses, qa_pluses)` | the own character: the worn list (true ids), its instances (the models block, OptLevel, elixir), the avatar inventory; a QA loadout's pluses with no server |
| `apply_broadcast(slot, ref, plus, own, avatar)` | a 0x3038 / 0x3039 on a look held: the item, its plus, round 843's own-id trailer, an avatar by RefItemID under the first free key |
| `from_ids(ref, scale, ids)` / `bare(ref, scale)` | the create screen's kit, an NPC thief's outfit; a body alone (the party portrait) |
| `on_body`, `arms_only`, `with_avatars` | derived looks: the skin-change preview's model, its arms-only case off the player's sex, the item mall's try-on |

**What is made of it:** `items(drawable)` -- the builder's list, `{"id", "plus"[, "fx"]}` per
worn key in the map's order, "fx" only for a switched item (so lists, kinds and far-recipe keys
are what they were) -- and `kind(body)`, the string the crowd's template readiness is kept under.

**No reference cycle.** The look's code never names CharacterAppearance (the scale and avatar-key
constants live in the look; the builder's are aliases of them). With a reference both ways, every
script naming both cost more to load: World3D.gd's load took 83.1 MB of static memory against the
base's 70.8 MB, and 70.8 MB again once the look stopped naming the builder (MEASURED, a headless
load of each in one project). The guard test checks it.

**The builder consumes it:** `CharacterAppearance.build_look(look, ref, drawable)`,
`far_recipe_look(...)` (the crowd's GPU ghosts), `kind_ready_look(kind, look, ...)`. The raw
`build(ref, scale, items)` stays for the probes and tests that feed a list.

## 4. The census: every site that draws a character

Before round 847 each site assembled the builder's input itself; after, each builds or holds a
CharacterLook.

| Site | Before | After |
|---|---|---|
| Select screen (`frontend/charselect_stage.gd` `set_characters`) | `r.items + r.avatars` into `build`; the record named the item's own row: **a switched item drawn as its original model** | `build_look(CharacterLook.from_lobby(r))`; the record names the model, the trailer the own id |
| Select screen QA luma (`CharacterSelect._qa_body_luma`) | the same list into `CharCreatePreview.show_character` | `show_character(CharacterLook.from_lobby(record))` |
| Create preview (`CharacterCreate._rebuild` -> `CharCreatePreview.show_character`) | `CharCreateModel.preview_items()` dicts | `CharCreateModel.preview_look()` (`from_ids`); `preview_items()` is its `items()` |
| `CharCatalog.sample_kit` (tests' kit) | its own `{id, plus}` dicts | `from_ids(...).items()` |
| Own body (`World3D._apply_player_equipment_visual`) | `_display_equipped` + `_with_player_avatars` + `_player_pluses` + `_player_fx`, kept apart in `_player_pluses_last` / `_player_models_last` | `_player_look(equipped)` = `CharacterLook.from_equipment`, kept as `_player_look_last` |
| Equipment window doll (`_refresh_paper_doll`) | the same four helpers, again (and again for the late doll) | `_player_look_last` |
| HUD player portrait (`_refresh_player_portrait`) | a copy of the body; the four helpers for the weapon group | a copy of the body; `_player_look_last.worn` for the group |
| Item mall preview (`MallModels.build_body`) | `_display_equipped`, avatar keys stripped from the map and `_player_pluses_last`, try-on avatars keyed 200+k, `_player_fx()` | `_player_look_last.with_avatars(try-on refs)` |
| Skin-change preview (`_skin_preview_body`) | `_player_equipped_last` filtered, `_display_equipped`, `_with_player_avatars`, `_player_pluses_last`, `_player_fx()` | `_player_look_last.on_body(model, scale)`, `.arms_only()` off the player's sex |
| Exchange portraits (`_exchange_portraits`) | own: a body copy (`_with_player_avatars` for the group); a partner not dressed yet: the spawn's items **without pluses or own ids** | own: `_player_look_last`; the partner not dressed yet: its look (**with** its pluses and own ids, as its body is dressed) |
| Party portrait (`_party_portrait_body`) | `_build_assembled_character({}, body, 0x22)` | `CharacterLook.bare(ref)` |
| Other players, near (`_dress_other`, `_redress_other`) | `_other_build_args.equipped/scale` or `_other_equipped`, `_other_pluses`, `_other_fx` | `_other_looks[id]` |
| Other players, crowd (`_other_template_ready`, `_ghost_other_now`; CrowdGpu / CrowdAnim consume the far recipe) | `_other_build_spec` + `_wear_item`, a kind string built in place | `kind_ready_look` / `far_recipe_look` of `_other_looks[id]`, `look.kind(body)` |
| Spawns (`_spawn_or_update_other`, `_note_other_pluses`) | `_other_equipped`, `_other_pluses`, `_other_build_args` written apart | `look.spawned(...)`, `look.pluses` |
| 0x3038 / 0x3039 (`_on_other_equipment_changed`) | worn, pluses and fx edited in three maps; `avatar_broadcast_into` | `look.apply_broadcast(...)` (`CharacterLook.avatar_into`); a kept arrival snapshot through `from_spawn` |
| Own avatars by broadcast (`_set_player_avatars`) | `avatar_broadcast_into` | `CharacterLook.avatar_into` |
| Job suit of another (`_wears_job_suit`) | `_other_equipped[id][8]` | `_other_look(id).suit()` |
| NPC thief / hunter (`_dress_job_mob`, `JobMobDress.outfit`) | its own `{id, plus: 0}` list into `build` | `build_look(CharacterLook.from_ids(...))` |
| QA crowd probe, QA lineup, debug panel | `_other_equipped` / `_other_pluses` | `_other_look(id)` / `_other_worn(id)` |
| Wire records (`net/lobby.gd`, `net/user_spawn.gd`, `net/avatar_net.gd`) | parse the messages | unchanged: the looks are built from them |
| `ui/default_wear.gd`, `CharacterVisualChange`, `ItemGlowTables`, `EquipGlow`, `WornItemFx` | inside the builder | unchanged |

Gone from World3D: `_wear_item`, `_display_equipped`, `_player_fx`, `_player_pluses`,
`_with_player_avatars`, `_equipment_models`, `_other_build_spec`, `avatar_broadcast_into`, and the
maps `_other_equipped`, `_other_pluses`, `_other_fx`, `_player_pluses_last`.
`_build_assembled_character` takes `(look, body)`.

**The guard** (`character_look847_test.gd` `_test_guard`): no script under `client/scripts` but
`character_look.gd` and `character_appearance.gd` calls the builder's list entry points
(`build`, `far_recipe`, `kind_ready`, `templates_ready`, `prepare`, `template_paths` on an
appearance), no script makes an item entry literal (`{"id": ..., "plus": ...}`) but the look, the
builder and the three wire decoders (and the select screen's QA sample, a fake 0xB007 record), every
census site names CharacterLook, and none of the removed World3D helpers returns. It fails on the
pre-847 lines (its own negative case).

## 5. Behaviour kept, and the two changes

Every site draws what it drew (the before/after frames are in the round's WORLD_ISSUES entry),
but for:

1. **The select screen** draws a switched item as its model with its glow and seal (the fix).
2. **The exchange window's partner portrait**, when the partner is not dressed yet (a crowd
   ghost or still queued), is dressed from its look with its pluses and switched items' own ids,
   as its body will be; before, from the spawn's items alone, without glow (OURS consistency;
   retail clones the partner's character with its equipment, `c:0x7b2a20` -> `0xa61c30`).

## 6. OPEN

- Whether retail's ShardManager writes the avatar's OptLevel into the record's discarded byte
  (`AVATAR_RESEARCH.md` 4.2; OpenSRO writes it, no effect on the drawing).
- The Nova seal's scale on another model (round 843).
