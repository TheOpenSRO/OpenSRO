extends Node3D

## The one real client scene, reached directly from CharacterSelect.gd: a
## player-controlled CharacterBody3D moving over a placeholder flat ground,
## synced to the server over OpMove/OpEntityEntered/OpEntityMoved/
## OpEntityLeft. Other connected characters render as simple labeled
## capsules at their real, server-authoritative positions, or a real
## assembled character if real game data is loaded (see below). Its full
## UI (chat, monsters/combat, inventory, equipment, quests, shop, party,
## guild, duel, trade, friends) was ported here from the original 2D
## World.tscn, which has since been deleted -- see docs/PROGRESS.md.
##
## The ground is a placeholder collision box by default, but both its
## *visual* mesh and its *collision* shape are replaced by real terrain if
## you set SRREVAMP_MAPM_PATH to a real Map.pk2 region .m file (see below)
## -- .mapm's grid width (17) is now a real, mechanistically confirmed
## constant (see docs/protocol/MAPM_FORMAT.md and MapmTerrainBuilder), not
## the unresolved blocker it used to be. The real collision shape is a
## ConcavePolygonShape3D built directly from the same real triangle data as
## the visual mesh (Mesh.create_trimesh_shape() -- no separate collision
## geometry to keep in sync), so the player physically walks on the actual
## real terrain surface, not a flat box, whenever real terrain data loads.
## The terrain's real world position/scale relative to a player's actual
## spawn coordinate is still unconfirmed -- it's placed near the player for
## visibility, not at a confirmed real-world offset. Other entities are
## still labeled capsules -- there's no confirmed mapping from a
## server-side character to
## a specific real asset (this project's server doesn't track a
## race/gender/equipment loadout per character yet), so every *other*
## player shows the same placeholder regardless of who they really are.
##
## The *player's own* body is no longer a placeholder if you point this
## project at your own real game data (this project ships with none --
## BYO, see docs/LEGAL.md): set SRREVAMP_PK2_PATH to a real pk2 archive
## (e.g. Data.pk2) and this scene auto-loads a real assembled character --
## a real .bsk skeleton plus real body-part .bms meshes rigidly attached to
## it via CharacterAssembler -- using the conventional real path layout
## found during reverse-engineering (Prim/Skel/Char/China/chinaman_skel.bsk
## + Prim/Mesh/Char/China/man/*.bms). It also wears a real, fixed 6-piece
## armor set (Prim/Mesh/Item/China/man_item/clothes_03_*.bms -- arm, body,
## foot, head, leg, shoulder), attached the same rigid way via
## CharacterAssembler.assemble_equipment, plus a real, fixed one-handed
## weapon (Prim/Mesh/Item/China/weapon/blade_01.bms) attached to the real
## confirmed hand bone via CharacterAssembler.assemble_weapon. Real
## per-account race/gender selection now exists (see character.Gender
## server-side and CharacterSelect.tscn's gender picker), but this is
## otherwise a fixed body per gender (always the same China-man or
## China-woman class/skin pick) -- there's no confirmed mapping to vary
## that automatically. Which armor *pieces* show, and whether the weapon
## shows, is real, per-piece, though: gated on the player's actual,
## server-authoritative equip state across a real, decompiler-confirmed
## 8-slot layout (HELM/MAIL/SHOULDERGUARD/PANTS/BOOTS/WEAPON/SHIELD/EXTRA
## -- see docs/protocol/EQUIP_SLOTS.md and _real_player_equipped_slots()),
## not one all-or-nothing bundle. A newly-created character has nothing
## equipped, so it renders bare-skinned and bare-handed until the player
## actually equips real pieces -- mixing e.g. a real helm with no other
## armor renders correctly, not just "some vs. none". Falls back to the
## placeholder capsule if the body itself isn't found.
##
## Other connected players use their own real Gender's body too (see
## _build_assembled_character()) rather than a capsule, when
## SRREVAMP_PK2_PATH is set -- their armor pieces, weapon, and shield are
## real per-player as well: the server broadcasts each entity's actual
## live per-piece equip state as part of OpEnterWorldResult/
## OpEntityEntered (WorldNet.EntitySnapshot.armor_slots_mask/has_weapon/
## has_shield -- see server/internal/session/world.go's equippedSlots), so
## other players only show the real pieces their own account actually
## equipped, same as the local player. Falls back to the labeled capsule
## per-entity if the shared character assets never loaded.
##
## SRREVAMP_PK2_PATH + SRREVAMP_BSR_PATH also loads one real, textured
## static scenery object nearby via ObjectLoader, and
## SRREVAMP_BSK_PATH + SRREVAMP_BAN_PATH loads a real animated decoration
## skeleton (its own separate .bsk/.ban pair, not the player's body) via
## Skeleton3DBuilder -- both accept either a loose file path or a path
## inside SRREVAMP_PK2_PATH (see AssetSource). SRREVAMP_MAPM_PATH loads real
## terrain (a real Map.pk2 region's .m file, e.g. "100\\100.m") via
## MapmTerrainBuilder -- Map.pk2 is a separate archive from Data.pk2 in a
## real retail install, so it accepts either a loose file or a path inside
## SRREVAMP_MAP_PK2_PATH (its own separate pk2 env var, not
## SRREVAMP_PK2_PATH). SRREVAMP_MAPM_TEXTURE_PATH additionally textures that
## terrain with a real per-region minimap image (e.g. "minimap\\100x100.ddj",
## matching the same region number as SRREVAMP_MAPM_PATH) -- these live in
## Media.pk2, a third separate archive, so it accepts either a loose file or
## a path inside its own SRREVAMP_MEDIA_PK2_PATH. Falls back to real
## per-tile vertex-color variation (see MapmTerrainBuilder) if unset -- no
## real-time 3D ground-texture system has been found yet (see
## docs/protocol/MAPM_FORMAT.md), so a region's own real minimap art is the
## closest real, region-accurate substitute currently available.
## SRREVAMP_MAPO_PATH loads real placed objects (a real Map.pk2 region's
## .o file, e.g. "0\\0.o", via SRREVAMP_MAP_PK2_PATH) and renders each with
## its real resolved .bsr model -- not a placeholder marker -- via a real
## type-ID-to-resource-path lookup (a real, root-level "object.ifo" file
## inside SRREVAMP_PK2_PATH's Data.pk2, see docs/protocol/MAPO_FORMAT.md
## for how this was found; it was a confirmed dead end earlier in this
## project). Any
## variable left unset is skipped gracefully (a printed hint, not an error)
## -- this scene works fine with none of them set, same as always.
##
## The server now has a real multi-zone concept: OpChangeZone/
## OpChangeZoneResult (NetClient.change_zone/change_zone_result) let a
## character warp between zone labels. This scene reacts to a successful
## change (_on_change_zone_result): it tears down whatever real
## terrain/map-object nodes are currently loaded ("RealTerrain"/
## "RealMapObjects") and reloads them for the new zone, via _zone_paths --
## a zone label shaped like this project's real Map.pk2 region naming
## ("<x>/<y>", e.g. "100/100") resolves to that region's real internal
## paths ("100\\100.m", "100\\100.o", "minimap\\100x100.ddj"), the same
## convention SRREVAMP_MAPM_PATH/SRREVAMP_MAPO_PATH's doc comments above
## already describe. The server's own default spawn zone, "jangan", is a
## special case resolved by _resolve_zone_region to the real region this
## project found Jangan actually lives in (JANGAN_ZONE_REGION, "89/182" --
## **corrected 2026-08-26**, see docs/WORLD_ISSUES.md: the original "98/168"
## came from an earlier, smaller/incomplete scan (32 matching real
## placements); a full re-scan across all 4,050 real regions in a real
## Map.pk2 found "89/182" has 279 real Jangan-named placements, an order of
## magnitude stronger real match, and it's the same region an earlier
## session already independently found for the real south gate -- which
## makes sense, since the south gate belongs to Jangan) rather than falling
## through to "nothing to load" the way it used to before Jangan was found
## at all. Any other zone not shaped like a real region still clears back to
## the placeholder ground with nothing loaded -- honest "nothing to load",
## not a guessed path. The *initial* load in _ready() still reads the raw
## env vars directly rather than going through a zone label, since the very
## first EnterWorldResult's zone isn't available yet at that point.

const MOVE_SPEED := 6.0
const GRAVITY := 20.0

## Real Silkroad-style mouse controls: right-drag orbits the camera around
## the player (independent of the player's own facing), left-click on the
## ground walks the player there, and the scroll wheel zooms. WASD/arrow
## keys (the original, still-supported controls) immediately cancel any
## active click-to-move target, matching the normal MMO convention that
## manual movement input always overrides a pending destination.
const CAMERA_ORBIT_SENSITIVITY := 0.3 # degrees of camera rotation per pixel of mouse drag
## Real, empirically-confirmed sign convention (2026-08-26, see
## docs/WORLD_ISSUES.md): SpringArm3D pushes its child to local *+Z*, not
## -Z, so a *negative* CameraArm pitch is what lifts the camera above and
## behind the player -- the previous +42 base pitch (with a compensating
## 180 yaw and a 180 yaw flip on Camera3D itself) actually pushed the
## camera down and in *front* of the player, immediately collapsing
## against the ground via the spring's own collision check. That's the
## real root cause of the reported "FPS-like camera" bug, confirmed via a
## headless SpringArm3D probe (spring pushes a child to local (0,0,+L)).
## -80 (nearly straight overhead) to -10 (nearly flat behind) is the real
## valid range for a top-down-behind view under this corrected convention.
const CAMERA_PITCH_MIN_DEGREES := -80.0
const CAMERA_PITCH_MAX_DEGREES := -10.0
const CAMERA_ZOOM_STEP := 1.0
const CAMERA_ZOOM_MIN := 3.0
const CAMERA_ZOOM_MAX := 25.0
## How close player must get to a click-to-move target before it's
## considered reached and cleared -- without this, the player would
## oscillate forever trying to reach an exact point every physics frame.
const MOVE_TARGET_STOP_DISTANCE := 0.3

var _camera_orbiting := false
var _has_move_target := false
var _move_target := Vector3.ZERO
## Minimum real-world distance moved, and minimum time elapsed, before
## sending another OpMove -- avoids flooding the connection with a packet
## every single physics frame while walking.
const MIN_SEND_INTERVAL := 0.1
const MIN_SEND_DISTANCE := 0.05
## Plausible (unconfirmed) .ban playback rate -- see docs/protocol/BAN_FORMAT.md.
const BAN_FPS := 30.0

## Real, per-Gender asset path layout found during reverse-engineering
## (private server package data plus, for the woman/gender-parity check,
## direct confirmation against a real retail Data.pk2 -- see
## docs/PROGRESS.md). Real client pk2 archives are expected to mirror the
## same Prim/ tree; not confirmed as the *only* layout they use. Keyed by
## the same real Gender strings as character.GenderChinaMan/GenderChinaWoman
## (server/internal/character/character.go) -- only these two, since this
## project's available real client data has complete, parallel body/
## skeleton/armor asset sets for exactly these two and not for any other
## real race found in that data (see character.go's doc comment).
##
## Body-part meshes are shared across every class/skin choice within a
## gender, so any class's .bmt works for "material" -- "warrior" is an
## arbitrary fixed pick per gender, confirmed real by direct inspection
## (each gender's man_thigh/woman_thigh.bms material_name field matches a
## real layer_name inside that gender's chinaman_warrior.bmt/
## chinawoman_warrior.bmt). "clothes_03" is likewise an arbitrary fixed
## pick among many real numbered armor sets found for each gender -- not a
## real per-account equipment loadout (see this file's top comment).
##
## China-man's real forearm mesh is "man_arm_lower"; China-woman's real
## equivalent is "woman_arm_fore" -- different real filename convention,
## same real bones (see CharacterAssembler.BODY_PART_BONES).
## idle_anim/walk_anim: real generic (not weapon/skill-specific) locomotion
## clips found live (2026-08-22) against a real retail Data.pk2, under each
## gender's real "fighter" class subtree -- matching the "warrior" material
## already picked above, so the animation and the outfit are at least from
## the same real class family. Real, but same "one arbitrary pick among
## many" honesty level as every other GENDER_ASSET_PATHS entry (there are
## also merchant/monkey/tattoo/etc. variants this project didn't check).
const GENDER_ASSET_PATHS := {
	"china_man": {
		"skeleton": "Prim\\Skel\\Char\\China\\chinaman_skel.bsk",
		"mesh_dir": "Prim\\Mesh\\Char\\China\\man",
		"body_parts": ["man_pelvis", "man_torso_lower", "man_torso_upper", "man_thigh", "man_calf", "man_arm_upper", "man_arm_lower"],
		"material": "Prim\\Mtrl\\Char\\China\\man\\chinaman_warrior.bmt",
		"equipment_mesh_dir": "Prim\\Mesh\\Item\\China\\man_item",
		"equipment_material_dir": "Prim\\Mtrl\\Item\\China\\man_item",
		"equipment_part_suffixes": ["aa", "ba", "fa", "ha", "la", "sa"],
		"idle_anim": "Prim\\Ani\\Char\\China\\man\\chinaman_fighter_standcity.ban",
		"walk_anim": "Prim\\Ani\\Char\\China\\man\\chinaman_fighter_walkforward.ban",
	},
	"china_woman": {
		"skeleton": "Prim\\Skel\\Char\\China\\chinawoman_skel.bsk",
		"mesh_dir": "Prim\\Mesh\\Char\\China\\woman",
		"body_parts": ["woman_pelvis", "woman_torso_lower", "woman_torso_upper", "woman_thigh", "woman_calf", "woman_arm_upper", "woman_arm_fore"],
		"material": "Prim\\Mtrl\\Char\\China\\woman\\chinawoman_warrior.bmt",
		"equipment_mesh_dir": "Prim\\Mesh\\Item\\China\\woman_item",
		"equipment_material_dir": "Prim\\Mtrl\\Item\\China\\woman_item",
		"equipment_part_suffixes": ["aa", "ba", "fa", "ha", "la", "sa"],
		"idle_anim": "Prim\\Ani\\Char\\China\\woman\\chinawoman_fighter_standcity.ban",
		"walk_anim": "Prim\\Ani\\Char\\China\\woman\\chinawoman_fighter_walkforward.ban",
	},
}
## Falls back to this real gender's assets when a requested gender's assets
## didn't load (or a peer reports an unrecognized gender string) -- matches
## character.DefaultGender server-side.
const DEFAULT_GENDER := "china_man"

## Real, individually-verified weapon mesh/material pairs (2026-08-22),
## found under a faction-wide (not per-gender) real folder --
## Prim\Mesh\Item\China\weapon\ has no man/woman split, unlike body/armor
## meshes. Each mesh's own real material_name field was directly checked
## against real .bmt files in the same folder (not assumed from a naming
## formula -- e.g. blade_14's material_name didn't match its own number the
## way most others do, and shield_14 was dropped entirely because its
## material_name ("China_shield_14") didn't match any real file at all).
## The local player picks one of these per real equipped weapon item ID
## (see _real_player_equipped_slots/_try_apply_real_player_character) so
## different real weapons actually look different; other players still
## always show WEAPON_VARIANTS[0]/SHIELD_VARIANTS[0], since the wire
## protocol broadcasting their equipment to everyone else only carries a
## has_weapon/has_shield boolean, not a real item ID, yet -- a real,
## honestly-scoped follow-up, not an oversight.
const WEAPON_VARIANTS := [
	{"mesh": "Prim\\Mesh\\Item\\China\\weapon\\blade_01.bms", "material": "Prim\\Mtrl\\Item\\China\\weapon\\blade1_5.bmt"},
	{"mesh": "Prim\\Mesh\\Item\\China\\weapon\\blade_02.bms", "material": "Prim\\Mtrl\\Item\\China\\weapon\\blade1_5.bmt"},
	{"mesh": "Prim\\Mesh\\Item\\China\\weapon\\blade_03.bms", "material": "Prim\\Mtrl\\Item\\China\\weapon\\blade1_5.bmt"},
	{"mesh": "Prim\\Mesh\\Item\\China\\weapon\\blade_04.bms", "material": "Prim\\Mtrl\\Item\\China\\weapon\\blade1_5.bmt"},
	{"mesh": "Prim\\Mesh\\Item\\China\\weapon\\blade_05.bms", "material": "Prim\\Mtrl\\Item\\China\\weapon\\blade1_5.bmt"},
	{"mesh": "Prim\\Mesh\\Item\\China\\weapon\\blade_06.bms", "material": "Prim\\Mtrl\\Item\\China\\weapon\\blade1_5.bmt"},
	{"mesh": "Prim\\Mesh\\Item\\China\\weapon\\blade_07.bms", "material": "Prim\\Mtrl\\Item\\China\\weapon\\blade6_10.bmt"},
	{"mesh": "Prim\\Mesh\\Item\\China\\weapon\\blade_08.bms", "material": "Prim\\Mtrl\\Item\\China\\weapon\\blade6_10.bmt"},
	{"mesh": "Prim\\Mesh\\Item\\China\\weapon\\blade_09.bms", "material": "Prim\\Mtrl\\Item\\China\\weapon\\blade6_10.bmt"},
	{"mesh": "Prim\\Mesh\\Item\\China\\weapon\\blade_10.bms", "material": "Prim\\Mtrl\\Item\\China\\weapon\\blade_10_12.bmt"},
	{"mesh": "Prim\\Mesh\\Item\\China\\weapon\\blade_11.bms", "material": "Prim\\Mtrl\\Item\\China\\weapon\\blade_11.bmt"},
	{"mesh": "Prim\\Mesh\\Item\\China\\weapon\\blade_12.bms", "material": "Prim\\Mtrl\\Item\\China\\weapon\\blade_12.bmt"},
	{"mesh": "Prim\\Mesh\\Item\\China\\weapon\\blade_13.bms", "material": "Prim\\Mtrl\\Item\\China\\weapon\\blade_13.bmt"},
	{"mesh": "Prim\\Mesh\\Item\\China\\weapon\\blade_14.bms", "material": "Prim\\Mtrl\\Item\\China\\weapon\\blade_14.bmt"},
	{"mesh": "Prim\\Mesh\\Item\\China\\weapon\\blade_15.bms", "material": "Prim\\Mtrl\\Item\\China\\weapon\\blade_15.bmt"},
]

## Real, individually-verified shield mesh/material pairs -- see
## WEAPON_VARIANTS' doc comment for the same real per-item verification
## process and its honest scope. shield_91's own real material_name field
## is "shield_11" (a real, confirmed reuse, not a mistake here).
const SHIELD_VARIANTS := [
	{"mesh": "Prim\\Mesh\\Item\\China\\weapon\\shield_11.bms", "material": "Prim\\Mtrl\\Item\\China\\weapon\\shield_11.bmt"},
	{"mesh": "Prim\\Mesh\\Item\\China\\weapon\\shield_15.bms", "material": "Prim\\Mtrl\\Item\\China\\weapon\\shield_15.bmt"},
	{"mesh": "Prim\\Mesh\\Item\\China\\weapon\\shield_16.bms", "material": "Prim\\Mtrl\\Item\\China\\weapon\\shield_16.bmt"},
	{"mesh": "Prim\\Mesh\\Item\\China\\weapon\\shield_90.bms", "material": "Prim\\Mtrl\\Item\\China\\weapon\\shield_90.bmt"},
	{"mesh": "Prim\\Mesh\\Item\\China\\weapon\\shield_91.bms", "material": "Prim\\Mtrl\\Item\\China\\weapon\\shield_11.bmt"},
]

## Real armor "look" numbers -- confirmed live (2026-08-22) that the
## clothes_03 set GENDER_ASSET_PATHS already used is one of many identically
## real-shaped sets (clothes_<NN>_<part>.bms + a matching clothes_<NN>.bmt in
## the same folder, same real part-suffix convention). 02-09 is the range
## confirmed to exist for *both* real genders in the sample checked (00/01
## have real gaps for one gender or the other) -- not every possible real
## number, just a verified-safe subset. The local player picks one per real
## equipped armor item ID, same honest scope as WEAPON_VARIANTS.
const ARMOR_SET_NUMBERS := ["02", "03", "04", "05", "06", "07", "08", "09"]

## Real file inside Data.pk2 (SRREVAMP_PK2_PATH) mapping a real .mapo
## placement's type ID to a real .bsr resource path -- see
## docs/protocol/MAPO_FORMAT.md and ObjidxReader for the full derivation.
## This was a confirmed dead end earlier in this project (no such mapping
## had been found); it turned up once server/internal/pk2's directory-chain
## bug was fixed, since this file lives inside a real archive folder that
## bug was silently dropping from every listing. **Corrected (2026-08-22,
## from a real live playtest against a real retail client)**: this is under
## a real `navmesh\` folder, not pk2 root as this project originally
## assumed -- MAPO_FORMAT.md's "root level" claim was wrong.
const OBJECT_INDEX_PATH := "navmesh\\object.ifo"
## Real per-vertex ground-tile classification table -- see
## docs/protocol/TILE2D_FORMAT.md (TileIndexReader). Confirmed present at
## this real path (and, identically, at pk2 root) in a real Data.pk2.
const TILE_INDEX_PATH := "navmesh\\tile2d.ifo"
## How many real *placements* from SRREVAMP_MAPO_PATH's region to
## instantiate -- an arbitrary, honestly-scoped cap, not a real engine
## limit. Distinct real .bsr models are only parsed once each and
## duplicated for repeat placements (see _try_load_real_map_objects), so
## this mostly bounds real node/instance count, not real file parsing.
## **Raised from 300 (2026-08-26, see docs/WORLD_ISSUES.md)**: a real
## side-by-side comparison against a real live server screenshot of Jangan
## showed most of the real ground-cover grass and decoration missing --
## Jangan's own real region has 863 real placements (.o + .o2 combined),
## so the old 300 cap was silently dropping most of them, in placement
## order, well before reaching the grass/decoration entries. Since the
## expensive part (parsing each *distinct* real .bsr) already happens once
## per unique model regardless of this cap, and the rest is cheap
## duplication, raising it is low-cost -- not perf-verified against a real
## very dense region beyond Jangan's 863, but comfortably covers it with
## headroom.
const MAX_MAP_OBJECTS := 2000

## World-space spacing between adjacent *regions* in _load_region_neighborhood.
## **Real, confirmed value (2026-08-22)**: a real per-region world size
## decompiled directly out of a real cross-region movement function in
## `sro_client.exe` (`RegionManagerBody.cpp`) -- see
## docs/protocol/MAPM_FORMAT.md. Independent of TILE_SIZE (an earlier
## same-day version of this constant derived it from TILE_SIZE, which
## conflated "one region" with "one sub-patch" -- corrected, see
## MapmTerrainBuilder.TILE_SIZE's doc comment). Real per-region *adjacency*
## (whether the real world even lays regions out on a uniform grid at all)
## still isn't confirmed, but the *spacing magnitude* is.
const REGION_SPAN := 1920.0
## How many real regions out from the center region to try loading in each
## direction -- radius 2 means a 5x5 grid (25 regions attempted, however many
## actually exist as real files). Raised from 1 (2026-08-26, see
## docs/WORLD_ISSUES.md) now that Pk2Reader caches directory reads (this
## session's ~3-minute-load-time fix) -- the real per-region cost was
## dominated by redundant pk2 directory re-reads, not mesh building, so this
## should mostly trade a larger loaded-terrain footprint (fewer real
## "edge of loaded world" holes a player can walk to and see sky through)
## for a smaller relative load-time increase than radius 2 would have cost
## before that fix. Not yet perf-verified against a real large pk2 dataset
## in this environment -- flagged honestly, not asserted as free.
const REGION_LOAD_RADIUS := 2

## Real region streaming (2026-08-24): the original fixed 3x3 grid only
## ever loaded once, centered on wherever a zone's initial spawn/entry
## point was -- a player who kept walking in one direction would
## eventually walk off the edge of loaded terrain into the placeholder
## void, since nothing re-triggered loading as they moved. These track
## enough state for _maybe_stream_regions() (called every
## _physics_process) to load/unload real region cells as the player
## actually moves, keeping a real REGION_LOAD_RADIUS window centered on
## wherever they are, not just where they started.
##
## _grid_origin_region/_grid_origin_world anchor the mapping between real
## region coordinates and Godot world space: _grid_origin_world is
## whatever world position the real (dx=0, dy=0) cell's own terrain_group
## ended up at (captured once, right after it loads) -- every other real
## cell's world position is `_grid_origin_world + Vector3(dx, 0, dy) *
## REGION_SPAN` by construction (see _load_region_cell), so this doesn't
## need to know the exact real per-cell placement bias
## (aabb.size.x/2 + rotation) in closed form, just that it's identical for
## every cell. This mapping stays fixed for a zone's whole lifetime, even
## as cells stream in/out around it, so already-placed nodes never need to
## move.
var _grid_origin_region := Vector2i.ZERO
var _grid_origin_world := Vector3.ZERO
var _grid_shared_anchor_height := NAN
var _grid_has_origin := false
var _loaded_cells := {} # "dx_dy" (relative to _grid_origin_region) -> true
var _last_stream_cell := Vector2i(0x7fffffff, 0x7fffffff) # sentinel so the first real check always runs

@onready var player: CharacterBody3D = $Player
@onready var player_mesh: MeshInstance3D = $Player/Mesh
@onready var camera_arm: SpringArm3D = $Player/CameraArm
@onready var camera_3d: Camera3D = $Player/CameraArm/Camera3D
@onready var ground_mesh: MeshInstance3D = $Ground/Mesh
@onready var ground_collision: CollisionShape3D = $Ground/Collision
@onready var other_entities: Node3D = $OtherEntities
@onready var zone_label: Label = $UI/Control/ZoneLabel
@onready var character_label: Label = $UI/Control/CharacterLabel
@onready var ui_control: Control = $UI/Control
@onready var hide_ui_button: Button = $UI/HideUIButton
@onready var zone_input: LineEdit = $UI/Control/ZoneInput
@onready var chat_log: RichTextLabel = $UI/Control/ChatPanel/ChatLog
@onready var chat_input: LineEdit = $UI/Control/ChatPanel/ChatInputRow/ChatInput
@onready var send_button: Button = $UI/Control/ChatPanel/ChatInputRow/SendButton

## Action-tab panels, ported from the 2D World.gd HUD (see docs/PROGRESS.md)
## -- this scene is becoming the one real client, so its UI needs to cover
## everything the 2D view used to.
@onready var monster_list: ItemList = $UI/Control/ActionTabs/Monsters/MonsterList
@onready var monster_refresh_button: Button = $UI/Control/ActionTabs/Monsters/MonsterButtonRow/RefreshButton
@onready var attack_button: Button = $UI/Control/ActionTabs/Monsters/MonsterButtonRow/AttackButton
@onready var monster_status_label: Label = $UI/Control/ActionTabs/Monsters/MonsterStatusLabel

@onready var inventory_list: ItemList = $UI/Control/ActionTabs/Inventory/InventoryList
@onready var inventory_refresh_button: Button = $UI/Control/ActionTabs/Inventory/InventoryButtonRow/RefreshButton
@onready var equip_weapon_button: Button = $UI/Control/ActionTabs/Inventory/InventoryButtonRow/EquipWeaponButton
@onready var equip_armor_slot_option: OptionButton = $UI/Control/ActionTabs/Inventory/InventoryButtonRow/EquipArmorSlotOption
@onready var equip_armor_button: Button = $UI/Control/ActionTabs/Inventory/InventoryButtonRow/EquipArmorButton
@onready var inventory_status_label: Label = $UI/Control/ActionTabs/Inventory/InventoryStatusLabel

@onready var equipment_list: ItemList = $UI/Control/ActionTabs/Equipment/EquipmentList
@onready var equipment_refresh_button: Button = $UI/Control/ActionTabs/Equipment/EquipmentButtonRow/RefreshButton
@onready var unequip_weapon_button: Button = $UI/Control/ActionTabs/Equipment/EquipmentButtonRow/UnequipWeaponButton
@onready var unequip_armor_slot_option: OptionButton = $UI/Control/ActionTabs/Equipment/EquipmentButtonRow/UnequipArmorSlotOption
@onready var unequip_armor_button: Button = $UI/Control/ActionTabs/Equipment/EquipmentButtonRow/UnequipArmorButton
@onready var equipment_status_label: Label = $UI/Control/ActionTabs/Equipment/EquipmentStatusLabel

## Real, decompiler-confirmed armor slot names (see
## docs/protocol/EQUIP_SLOTS.md), shown in that same real order in both
## armor-slot pickers.
const ARMOR_SLOT_LABELS := {
	EquipmentNet.SLOT_HELM: "Helm",
	EquipmentNet.SLOT_MAIL: "Mail",
	EquipmentNet.SLOT_SHOULDER_GUARD: "Shoulder Guard",
	EquipmentNet.SLOT_PANTS: "Pants",
	EquipmentNet.SLOT_BOOTS: "Boots",
}

@onready var quest_list: ItemList = $UI/Control/ActionTabs/Quests/QuestList
@onready var quest_refresh_button: Button = $UI/Control/ActionTabs/Quests/QuestButtonRow/RefreshButton
@onready var quest_accept_button: Button = $UI/Control/ActionTabs/Quests/QuestButtonRow/AcceptButton
@onready var quest_status_label: Label = $UI/Control/ActionTabs/Quests/QuestStatusLabel

@onready var skill_list: ItemList = $UI/Control/ActionTabs/Skills/SkillList
@onready var skill_refresh_button: Button = $UI/Control/ActionTabs/Skills/SkillButtonRow/SkillRefreshButton
@onready var skill_learn_button: Button = $UI/Control/ActionTabs/Skills/SkillButtonRow/SkillLearnButton
@onready var skill_use_button: Button = $UI/Control/ActionTabs/Skills/SkillButtonRow/SkillUseButton
@onready var skill_status_label: Label = $UI/Control/ActionTabs/Skills/SkillStatusLabel

@onready var shop_list: ItemList = $UI/Control/ActionTabs/Shop/ShopList
@onready var shop_refresh_button: Button = $UI/Control/ActionTabs/Shop/ShopButtonRow/RefreshButton
@onready var shop_buy_button: Button = $UI/Control/ActionTabs/Shop/ShopButtonRow/BuyButton
@onready var shop_status_label: Label = $UI/Control/ActionTabs/Shop/ShopStatusLabel

@onready var party_list: ItemList = $UI/Control/ActionTabs/Party/PartyList
@onready var party_create_button: Button = $UI/Control/ActionTabs/Party/PartyButtonRow/CreateButton
@onready var party_leave_button: Button = $UI/Control/ActionTabs/Party/PartyButtonRow/LeaveButton
@onready var party_join_id_input: LineEdit = $UI/Control/ActionTabs/Party/PartyJoinRow/JoinIdInput
@onready var party_join_button: Button = $UI/Control/ActionTabs/Party/PartyJoinRow/JoinButton
@onready var party_status_label: Label = $UI/Control/ActionTabs/Party/PartyStatusLabel

@onready var guild_list: ItemList = $UI/Control/ActionTabs/Guild/GuildList
@onready var guild_name_input: LineEdit = $UI/Control/ActionTabs/Guild/GuildCreateRow/GuildNameInput
@onready var guild_create_button: Button = $UI/Control/ActionTabs/Guild/GuildCreateRow/CreateButton
@onready var guild_join_id_input: LineEdit = $UI/Control/ActionTabs/Guild/GuildJoinRow/JoinIdInput
@onready var guild_join_button: Button = $UI/Control/ActionTabs/Guild/GuildJoinRow/JoinButton
@onready var guild_leave_button: Button = $UI/Control/ActionTabs/Guild/GuildJoinRow/LeaveButton
@onready var guild_status_label: Label = $UI/Control/ActionTabs/Guild/GuildStatusLabel

@onready var duel_target_input: LineEdit = $UI/Control/ActionTabs/Duel/ChallengeRow/TargetInput
@onready var duel_challenge_button: Button = $UI/Control/ActionTabs/Duel/ChallengeRow/ChallengeButton
@onready var duel_invite_label: Label = $UI/Control/ActionTabs/Duel/InviteRow/InviteLabel
@onready var duel_accept_button: Button = $UI/Control/ActionTabs/Duel/InviteRow/AcceptButton
@onready var duel_decline_button: Button = $UI/Control/ActionTabs/Duel/InviteRow/DeclineButton
@onready var duel_attack_button: Button = $UI/Control/ActionTabs/Duel/AttackButton
@onready var duel_status_label: Label = $UI/Control/ActionTabs/Duel/DuelStatusLabel

@onready var trade_target_input: LineEdit = $UI/Control/ActionTabs/Trade/RequestRow/TargetInput
@onready var trade_request_button: Button = $UI/Control/ActionTabs/Trade/RequestRow/RequestButton
@onready var trade_invite_label: Label = $UI/Control/ActionTabs/Trade/InviteRow/InviteLabel
@onready var trade_accept_button: Button = $UI/Control/ActionTabs/Trade/InviteRow/AcceptButton
@onready var trade_decline_button: Button = $UI/Control/ActionTabs/Trade/InviteRow/DeclineButton
@onready var trade_gold_input: LineEdit = $UI/Control/ActionTabs/Trade/OfferRow/GoldInput
@onready var trade_item_slot_input: LineEdit = $UI/Control/ActionTabs/Trade/OfferRow/ItemSlotInput
@onready var trade_quantity_input: LineEdit = $UI/Control/ActionTabs/Trade/OfferRow/QuantityInput
@onready var trade_set_offer_button: Button = $UI/Control/ActionTabs/Trade/OfferRow/SetOfferButton
@onready var trade_their_offer_label: Label = $UI/Control/ActionTabs/Trade/TheirOfferLabel
@onready var trade_confirm_button: Button = $UI/Control/ActionTabs/Trade/TradeButtonRow/ConfirmButton
@onready var trade_cancel_button: Button = $UI/Control/ActionTabs/Trade/TradeButtonRow/CancelButton
@onready var trade_status_label: Label = $UI/Control/ActionTabs/Trade/TradeStatusLabel

@onready var friend_list: ItemList = $UI/Control/ActionTabs/Friends/FriendList
@onready var friend_remove_button: Button = $UI/Control/ActionTabs/Friends/RemoveButton
@onready var friend_pending_list: ItemList = $UI/Control/ActionTabs/Friends/PendingList
@onready var friend_accept_button: Button = $UI/Control/ActionTabs/Friends/PendingButtonRow/AcceptButton
@onready var friend_decline_button: Button = $UI/Control/ActionTabs/Friends/PendingButtonRow/DeclineButton
@onready var friend_target_input: LineEdit = $UI/Control/ActionTabs/Friends/RequestRow/TargetInput
@onready var friend_request_button: Button = $UI/Control/ActionTabs/Friends/RequestRow/RequestButton
@onready var friend_refresh_button: Button = $UI/Control/ActionTabs/Friends/RefreshButton
@onready var friend_status_label: Label = $UI/Control/ActionTabs/Friends/FriendStatusLabel

# Parallel to monster_list/inventory_list's items -- ItemList doesn't carry
# structured data per row on its own, so track what each row actually is.
var _monsters: Array[CombatNet.MonsterSnapshot] = []
var _inventory_slots: Array[InventoryNet.Slot] = []
var _quests: Array[QuestNet.Entry] = []
var _skills: Array[SkillNet.SkillSnapshot] = []
var _shop_entries: Array[ShopNet.CatalogEntry] = []

# Name of whoever last challenged/requested-trade-with us, so Accept/
# Decline know who to respond to (the server needs it explicitly).
var _pending_duel_challenger := ""
var _pending_trade_requester := ""

var _friends: Array[FriendNet.FriendEntry] = []
var _pending_friend_requests: Array[FriendNet.PendingRequest] = []

# equipment_result fires for OpEquipmentList *and* equip/unequip acks (see
# NetClient.equipment_result's doc comment: a successful equip/unequip ack
# just has an empty items array, same shape as "nothing equipped"). Track
# whether we're expecting an ack so an empty response isn't misread as
# "you have nothing equipped" right after a successful equip.
var _awaiting_equip_ack := false

var _other_bodies := {} # character_id -> Node3D
var _monster_bodies := {} # monster_id -> Node3D
var _last_sent_pos := Vector3.ZERO
var _time_since_send := 0.0

var _player_skeleton: Skeleton3D
var _player_gender := DEFAULT_GENDER
var _player_anim_time := 0.0

var _real_skeleton: Skeleton3D
var _real_skeleton_track: BanReader.Bone
var _real_skeleton_time := 0.0

## Cached, parsed real character assets, one entry per real Gender (see
## GENDER_ASSET_PATHS), loaded once by _load_character_assets() and reused
## by _build_assembled_character() to build a fresh Skeleton3D per
## character instance (player or other) -- reparsing the same .bms/.bmt
## files for every single connected player would be real, avoidable waste.
## Keyed by gender string; a gender with no entry here means its assets
## weren't found (or SRREVAMP_PK2_PATH isn't set at all) -- callers fall
## back to DEFAULT_GENDER, and to the placeholder capsule if even that
## didn't load.
var _character_assets: Dictionary = {}

## Cached, parsed real weapon mesh+material pairs, one entry per
## WEAPON_VARIANTS, shared across every gender/character instance -- real
## weapon meshes aren't gender-split, unlike body/armor. Each entry is
## {"mesh": BmsReader.ParsedMesh, "materials": Dictionary}; a variant whose
## real files weren't found in the archive is simply absent (shorter than
## WEAPON_VARIANTS), not a null placeholder -- see _build_assembled_character
## for the resulting index-wrapping behavior.
var _weapon_variants: Array = []

## Same as _weapon_variants, for SHIELD_VARIANTS.
var _shield_variants: Array = []

func _ready() -> void:
	character_label.text = "Character: %s" % NetClient.current_character_name

	_load_character_assets()

	var result := NetClient.last_enter_world_result
	if result != null and result.ok:
		zone_label.text = "Zone: %s" % result.zone
		player.position = Vector3(result.x, result.y, result.z)
		_last_sent_pos = player.position
		for other in result.others:
			_spawn_or_update_other(other.character_id, other.char_name, Vector3(other.x, other.y, other.z), other.armor_slots_mask, other.gender, other.has_weapon, other.has_shield)

	NetClient.entity_entered.connect(_on_entity_entered)
	NetClient.entity_moved.connect(_on_entity_moved)
	NetClient.entity_left.connect(_on_entity_left)
	NetClient.change_zone_result.connect(_on_change_zone_result)
	NetClient.chat_message.connect(_on_chat_message)
	NetClient.chat_whisper_message.connect(_on_chat_whisper_message)
	NetClient.disconnected.connect(_on_disconnected)
	send_button.pressed.connect(_on_send_pressed)
	chat_input.text_submitted.connect(func(_text: String): _on_send_pressed())
	hide_ui_button.pressed.connect(_toggle_ui_visibility)

	NetClient.monster_list_result.connect(_on_monster_list_result)
	NetClient.attack_result.connect(_on_attack_result)
	NetClient.monster_damaged.connect(_on_monster_damaged)
	NetClient.monster_died.connect(_on_monster_died)
	NetClient.loot_dropped.connect(_on_loot_dropped)
	NetClient.inventory_list_result.connect(_on_inventory_list_result)
	NetClient.equipment_result.connect(_on_equipment_result)
	NetClient.quest_list_result.connect(_on_quest_list_result)
	NetClient.quest_accept_result.connect(_on_quest_accept_result)
	NetClient.quest_completed.connect(_on_quest_completed)
	NetClient.skill_list_result.connect(_on_skill_list_result)
	NetClient.learn_skill_result.connect(_on_learn_skill_result)
	NetClient.shop_list_result.connect(_on_shop_list_result)
	NetClient.shop_buy_result.connect(_on_shop_buy_result)

	NetClient.party_create_result.connect(_on_party_result)
	NetClient.party_join_result.connect(_on_party_result)
	NetClient.party_leave_result.connect(_on_party_leave_result)
	NetClient.party_member_joined.connect(_on_party_member_joined)
	NetClient.party_member_left.connect(_on_party_member_left)
	NetClient.party_info_result.connect(_on_party_result)

	NetClient.guild_create_result.connect(_on_guild_result)
	NetClient.guild_join_result.connect(_on_guild_result)
	NetClient.guild_leave_result.connect(_on_guild_leave_result)
	NetClient.guild_info_result.connect(_on_guild_result)

	NetClient.duel_challenge_result.connect(_on_duel_challenge_result)
	NetClient.duel_invite.connect(_on_duel_invite)
	NetClient.duel_respond_result.connect(_on_duel_respond_result)
	NetClient.duel_started.connect(_on_duel_started)
	NetClient.duel_declined.connect(_on_duel_declined)
	NetClient.duel_attack_result.connect(_on_duel_attack_result)
	NetClient.duel_opponent_damaged.connect(_on_duel_opponent_damaged)
	NetClient.duel_ended.connect(_on_duel_ended)

	NetClient.trade_request_result.connect(_on_trade_request_result)
	NetClient.trade_invite.connect(_on_trade_invite)
	NetClient.trade_respond_result.connect(_on_trade_respond_result)
	NetClient.trade_started.connect(_on_trade_started)
	NetClient.trade_declined.connect(_on_trade_declined)
	NetClient.trade_offer_result.connect(_on_trade_offer_result)
	NetClient.trade_offer_updated.connect(_on_trade_offer_updated)
	NetClient.trade_confirm_result.connect(_on_trade_confirm_result)
	NetClient.trade_completed.connect(_on_trade_completed)
	NetClient.trade_cancelled.connect(_on_trade_cancelled)

	NetClient.friend_request_result.connect(_on_friend_request_result)
	NetClient.friend_request_received.connect(_on_friend_request_received)
	NetClient.friend_accept_result.connect(_on_friend_accept_result)
	NetClient.friend_accepted.connect(_on_friend_accepted)
	NetClient.friend_decline_result.connect(_on_friend_decline_result)
	NetClient.friend_list_result.connect(_on_friend_list_result)
	NetClient.friend_remove_result.connect(_on_friend_remove_result)
	NetClient.friend_pending_list_result.connect(_on_friend_pending_list_result)

	monster_refresh_button.pressed.connect(func(): NetClient.list_monsters())
	attack_button.pressed.connect(_on_attack_pressed)
	inventory_refresh_button.pressed.connect(func(): NetClient.list_inventory(NetClient.current_character_name))
	for slot in EquipmentNet.ARMOR_SLOTS:
		equip_armor_slot_option.add_item(ARMOR_SLOT_LABELS[slot], slot)
		unequip_armor_slot_option.add_item(ARMOR_SLOT_LABELS[slot], slot)

	equip_weapon_button.pressed.connect(func(): _on_equip_pressed(EquipmentNet.SLOT_WEAPON))
	equip_armor_button.pressed.connect(func(): _on_equip_pressed(equip_armor_slot_option.get_selected_id()))
	equipment_refresh_button.pressed.connect(func(): NetClient.list_equipment(NetClient.current_character_name))
	unequip_weapon_button.pressed.connect(func(): _on_unequip_pressed(EquipmentNet.SLOT_WEAPON))
	unequip_armor_button.pressed.connect(func(): _on_unequip_pressed(unequip_armor_slot_option.get_selected_id()))
	quest_refresh_button.pressed.connect(func(): NetClient.list_quests(NetClient.current_character_name))
	quest_accept_button.pressed.connect(_on_quest_accept_pressed)
	skill_refresh_button.pressed.connect(func(): NetClient.list_skills(NetClient.current_character_name))
	skill_learn_button.pressed.connect(_on_skill_learn_pressed)
	skill_use_button.pressed.connect(_on_skill_use_pressed)
	shop_refresh_button.pressed.connect(func(): NetClient.list_shop())
	shop_buy_button.pressed.connect(_on_shop_buy_pressed)

	party_create_button.pressed.connect(func(): NetClient.create_party(NetClient.current_character_name))
	party_leave_button.pressed.connect(func(): NetClient.leave_party(NetClient.current_character_name))
	party_join_button.pressed.connect(_on_party_join_pressed)

	guild_create_button.pressed.connect(_on_guild_create_pressed)
	guild_join_button.pressed.connect(_on_guild_join_pressed)
	guild_leave_button.pressed.connect(func(): NetClient.leave_guild(NetClient.current_character_name))

	duel_challenge_button.pressed.connect(_on_duel_challenge_pressed)
	duel_accept_button.pressed.connect(func(): _on_duel_respond_pressed(true))
	duel_decline_button.pressed.connect(func(): _on_duel_respond_pressed(false))
	duel_attack_button.pressed.connect(func(): NetClient.duel_attack(NetClient.current_character_name))

	trade_request_button.pressed.connect(_on_trade_request_pressed)
	trade_accept_button.pressed.connect(func(): _on_trade_respond_pressed(true))
	trade_decline_button.pressed.connect(func(): _on_trade_respond_pressed(false))
	trade_set_offer_button.pressed.connect(_on_trade_set_offer_pressed)
	trade_confirm_button.pressed.connect(func(): NetClient.trade_confirm(NetClient.current_character_name))
	trade_cancel_button.pressed.connect(func(): NetClient.trade_cancel(NetClient.current_character_name))

	friend_request_button.pressed.connect(_on_friend_request_pressed)
	friend_accept_button.pressed.connect(_on_friend_accept_pressed)
	friend_decline_button.pressed.connect(_on_friend_decline_pressed)
	friend_remove_button.pressed.connect(_on_friend_remove_pressed)
	friend_refresh_button.pressed.connect(_refresh_friends)

	# Guarded, unlike 2D World.gd's equivalent block: this scene doubles as a
	# standalone dev/asset-preview tool loaded with no live server connection
	# (see _real_player_equipped_slots' doc comment) -- these would just
	# spam "_send called while not connected" errors otherwise.
	if NetClient.is_connected_to_server():
		NetClient.list_monsters()
		NetClient.list_inventory(NetClient.current_character_name)
		NetClient.list_equipment(NetClient.current_character_name)
		NetClient.list_quests(NetClient.current_character_name)
		NetClient.list_skills(NetClient.current_character_name)
		NetClient.list_shop()
		NetClient.party_info(NetClient.current_character_name)
		NetClient.guild_info(NetClient.current_character_name)
		_refresh_friends()

	_try_load_real_scenery()
	_try_load_real_decoration_skeleton()
	_try_apply_real_player_character()
	_load_initial_region_neighborhood()

## Loads real static scenery through the exact same pk2 -> BsrReader ->
## ObjectLoader pipeline client/tools/render_asset.gd verifies standalone,
## live in this scene -- if SRREVAMP_PK2_PATH and SRREVAMP_BSR_PATH are
## both set. Skips gracefully (a printed hint, not an error) otherwise,
## since this project ships with no game data.
func _try_load_real_scenery() -> void:
	var pk2_path := Pk2Config.data_path()
	var bsr_path := OS.get_environment("SRREVAMP_BSR_PATH")
	if pk2_path == "" or bsr_path == "":
		print("World3D: Data.pk2/SRREVAMP_BSR_PATH not set -- no real scenery loaded")
		return

	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("World3D: could not open pk2 archive at ", pk2_path)
		return

	var obj := ObjectLoader.load_object(archive, bsr_path)
	if obj == null:
		printerr("World3D: could not load ", bsr_path, " from ", pk2_path)
		return

	# +Z is behind the third-person camera (it sits at a +Z/+Y offset from
	# the player looking back toward -Z) -- place scenery on the -Z side
	# so it's actually in view near spawn.
	obj.position = Vector3(4, 0, -4)
	add_child(obj)
	print("World3D: loaded real scenery %s from %s" % [bsr_path, pk2_path])

## Loads a real .bsk skeleton + .ban animation through Skeleton3DBuilder
## (see client/tools/render_skeleton3d_animated.gd for the standalone
## verification of this same pipeline), live in this scene as an animated
## decoration (not the player's own body -- see _try_load_real_player_character())
## -- if SRREVAMP_BSK_PATH and SRREVAMP_BAN_PATH are both set. Each accepts
## either a loose file path or a path inside SRREVAMP_PK2_PATH (see
## AssetSource). Skips gracefully otherwise.
func _try_load_real_decoration_skeleton() -> void:
	var bsk_path := OS.get_environment("SRREVAMP_BSK_PATH")
	var ban_path := OS.get_environment("SRREVAMP_BAN_PATH")
	if bsk_path == "" or ban_path == "":
		print("World3D: SRREVAMP_BSK_PATH/SRREVAMP_BAN_PATH not set -- no real decoration skeleton loaded")
		return

	var archive := _open_pk2_if_set()
	var bsk_bytes := AssetSource.read_bytes(bsk_path, archive)
	var ban_bytes := AssetSource.read_bytes(ban_path, archive)
	if bsk_bytes.is_empty() or ban_bytes.is_empty():
		printerr("World3D: could not find .bsk/.ban at ", bsk_path, " / ", ban_path)
		return

	var skel := BskReader.parse(bsk_bytes)
	var anim := BanReader.parse(ban_bytes)
	if skel == null or anim == null or anim.bones.is_empty():
		printerr("World3D: could not parse .bsk/.ban at ", bsk_path, " / ", ban_path)
		return

	_real_skeleton = Skeleton3DBuilder.build_skeleton3d(skel)
	_real_skeleton_track = anim.bones[0]
	_real_skeleton.position = Vector3(-6, 0, -6)
	# Real .bsk bind-pose data uses a much larger native scale than this
	# scene's ~2-unit-tall player capsule (position values in the hundreds
	# -- see docs/protocol/BSK_FORMAT.md) -- scale down so the whole
	# creature is visible near the player instead of dwarfing the scene.
	_real_skeleton.scale = Vector3.ONE * 0.02
	add_child(_real_skeleton)
	# A bare Skeleton3D has no visual representation of its own -- see
	# Skeleton3DBuilder.build_debug_visualization()'s doc comment.
	Skeleton3DBuilder.build_debug_visualization(_real_skeleton)
	print("World3D: loaded real skeleton %s + animation %s (%d bones, %d keyframes on track %s)" % [
		bsk_path, ban_path, skel.bones.size(), _real_skeleton_track.keyframes.size(), _real_skeleton_track.bone_name])

## Opens the real Data.pk2 -- SRREVAMP_PK2_PATH if set, else a real
## "pk2/Data.pk2" next to the running executable (see Pk2Config) -- or
## returns null if neither resolves or the open fails. Used so AssetSource
## can fall back to an in-archive path for any of the loose-file-shaped
## environment variables.
func _open_pk2_if_set() -> Pk2Reader:
	var pk2_path := Pk2Config.data_path()
	if pk2_path == "":
		return null
	return Pk2Reader.open(pk2_path)

var _tile_index_cache: TileIndexReader.Table
var _tile_index_load_attempted := false

## Loads and caches the real tile2d.ifo table (see TILE_INDEX_PATH) from
## SRREVAMP_PK2_PATH's Data.pk2, for MapmTerrainBuilder's real per-vertex
## ground-tile-type coloring. Only ever parsed once per scene lifetime --
## every real region shares the same real table. Returns null (logged
## once) if SRREVAMP_PK2_PATH isn't set or the file can't be found/parsed;
## callers already treat a null table as "fall back to the generic hue
## sweep," so this isn't a hard failure.
func _load_tile_index() -> TileIndexReader.Table:
	if _tile_index_load_attempted:
		return _tile_index_cache
	_tile_index_load_attempted = true

	var archive := _open_pk2_if_set()
	if archive == null:
		return null
	var bytes := AssetSource.read_bytes(TILE_INDEX_PATH, archive)
	if bytes.is_empty():
		print("World3D: could not find real tile index at ", TILE_INDEX_PATH, " -- terrain color falls back to a generic hue sweep")
		return null
	_tile_index_cache = TileIndexReader.parse(bytes)
	if _tile_index_cache == null:
		printerr("World3D: could not parse real tile index at ", TILE_INDEX_PATH)
	else:
		print("World3D: loaded real tile index (%d real tile types) from %s" % [_tile_index_cache.entries.size(), TILE_INDEX_PATH])
	return _tile_index_cache

## Real per-.ddj-filename texture cache, shared across every region loaded
## this run -- most real tile2d.ifo IDs a region uses (grass/dirt/stone,
## etc) repeat across many regions, so this avoids re-reading and
## re-decoding the same real Tile2D\*.ddj file over and over. A null entry
## means "already tried, no real file/decode" -- also cached, so a
## consistently-missing ID doesn't retry every region load.
static var _ground_texture_cache: Dictionary = {}

## Loads every real per-vertex ground texture `region` actually
## references, keyed by the real TextureInfo.ID MapmTerrainBuilder's
## _vertex_color already decodes -- see docs/protocol/DDJ_FORMAT.md and
## TILE2D_FORMAT.md's 2026-08-23 correction. Resolves each real ID through
## tile_table to a real tile2d.ifo filename, then loads that file from
## SRREVAMP_MAP_PK2_PATH's real `Tile2D\` folder (confirmed 2026-08-23 to
## be where these actually live -- see server/cmd/pk2list's real listing
## against a real Map.pk2). Returns {} (not an error) if tile_table is
## null or SRREVAMP_MAP_PK2_PATH isn't set -- callers already treat an
## empty lookup as "use the flat tile-type color instead."
func _load_real_ground_textures(region: MapmReader.ParsedRegion, tile_table: TileIndexReader.Table) -> Dictionary:
	var result := {}
	if tile_table == null:
		return result
	var archive := _open_map_pk2_if_set()
	if archive == null:
		return result

	var ids := {}
	for block in region.blocks:
		for vertex in block.vertices:
			if vertex.extra.size() < 2:
				continue
			ids[vertex.extra.decode_u16(0) & 0x3ff] = true

	for id in ids.keys():
		var entry := tile_table.lookup(id)
		if entry == null or entry.filename == "":
			continue
		var tex := _load_ground_texture_file(entry.filename, archive)
		if tex != null:
			result[id] = tex
	return result

## Loads and caches one real Tile2D\<filename>.ddj -- see
## _load_real_ground_textures's doc comment for the cache's purpose.
func _load_ground_texture_file(filename: String, archive: Pk2Reader) -> Texture2D:
	if _ground_texture_cache.has(filename):
		return _ground_texture_cache[filename]
	var bytes := AssetSource.read_bytes("Tile2D\\%s" % filename, archive)
	var tex: Texture2D = null
	if not bytes.is_empty():
		var parsed := DdjReader.parse(bytes)
		if parsed != null:
			tex = DdjReader.to_texture(parsed)
	_ground_texture_cache[filename] = tex
	return tex

## Opens the real Map.pk2 -- SRREVAMP_MAP_PK2_PATH if set, else a real
## "pk2/Map.pk2" next to the running executable (see Pk2Config) -- or
## returns null if neither resolves or the open fails. Map.pk2 is a separate
## archive from Data.pk2 in a real retail install (confirmed from the
## user's own real client file listing: Data.pk2, Media.pk2, Map.pk2,
## Particles.pk2 are all separate files) -- so terrain resolves its own real
## pk2 path rather than reusing Data.pk2's.
func _open_map_pk2_if_set() -> Pk2Reader:
	var map_pk2_path := Pk2Config.map_path()
	if map_pk2_path == "":
		return null
	return Pk2Reader.open(map_pk2_path)

## Opens the real Media.pk2 -- SRREVAMP_MEDIA_PK2_PATH if set, else a real
## "pk2/Media.pk2" next to the running executable (see Pk2Config) -- or
## returns null if neither resolves or the open fails. A real client's
## per-map-region minimap image (see SRREVAMP_MAPM_TEXTURE_PATH below) lives
## in Media.pk2, a third separate archive from both Data.pk2 and Map.pk2 in
## a real retail install.
func _open_media_pk2_if_set() -> Pk2Reader:
	var media_pk2_path := Pk2Config.media_path()
	if media_pk2_path == "":
		return null
	return Pk2Reader.open(media_pk2_path)

## Loads a real per-region minimap image (SRREVAMP_MAPM_TEXTURE_PATH, e.g.
## "minimap\100x100.ddj") as the terrain's real ground texture, if set.
## Accepts either a loose file path or a path inside SRREVAMP_MEDIA_PK2_PATH
## (see AssetSource) -- a real client's minimap images live in Media.pk2,
## confirmed via this project's own real-file search tooling
## (server/cmd/pk2list) against a real client install.
##
## This is an honest substitution, not a claim that this is the literal
## real-time 3D ground texture: no real-time multi-layer terrain-texture
## system (nor a lookup from a per-tile byte to a specific real texture
## file) has been found anywhere in this project's available real data --
## see docs/protocol/MAPM_FORMAT.md for that search. A region's own real
## minimap art is genuine, region-specific real game data (grass/dirt/rock
## color baked from that exact region), and looks far closer to the real
## game than the flat/procedural fallback color this function returns null
## for -- but it's a real top-down painted image, not sampled per-tile 3D
## terrain texture data.
## path_override lets a zone reload (see _reload_zone_assets) pass a
## specific real path instead of reading SRREVAMP_MAPM_TEXTURE_PATH -- empty
## string (the default) means "use the env var", same as every call site
## before zone reloading existed.
func _load_real_terrain_texture(path_override: String = "") -> Texture2D:
	var tex_path := path_override if path_override != "" else OS.get_environment("SRREVAMP_MAPM_TEXTURE_PATH")
	if tex_path == "":
		return null

	var archive := _open_media_pk2_if_set()
	var bytes := AssetSource.read_bytes(tex_path, archive)
	if bytes.is_empty():
		printerr("World3D: could not find terrain texture at ", tex_path)
		return null

	var parsed := DdjReader.parse(bytes)
	if parsed == null:
		printerr("World3D: could not parse terrain texture at ", tex_path)
		return null

	return DdjReader.to_texture(parsed)

## Loads a region's real .t file (the same base path as mapm_path, with
## its extension swapped) as a real ambient-occlusion-style lightmap --
## see docs/protocol/MAPT_FORMAT.md for the real structure and how this
## project confirmed it (public documentation, verified byte-for-byte
## against a real sample, cross-decoded two independent ways). The real
## embedded texture is a genuine grayscale shadow map (white = fully lit,
## gray = shadowed) -- a natural fit for Godot's built-in AO darkening,
## unlike an earlier same-day attempt to show a *different*, wrongly-
## decoded payload as literal detail-albedo color (reverted after live
## testing looked wrong -- see MAPT_FORMAT.md's own account). Not every
## region has a `.t` file (only newer-generation "Shape B" regions do --
## see MAPM_FORMAT.md's Shape A/B split), so a missing file here is the
## normal, expected case, not an error.
func _load_real_terrain_lightmap(mapm_path: String, archive: Pk2Reader) -> Texture2D:
	if mapm_path == "" or not mapm_path.ends_with(".m"):
		return null
	var mapt_path := mapm_path.substr(0, mapm_path.length() - 1) + "t"
	var bytes := AssetSource.read_bytes(mapt_path, archive)
	if bytes.is_empty():
		return null
	var region := MapTReader.parse(bytes)
	if region == null:
		return null
	return region.texture

## The real Jangan region, found 2026-08-24 (revised 2026-08-26). The
## original discovery scanned real region placements for
## "Res\Bldg\China\Jangan01..06\..." resource paths (see
## server/cmd/findregionassets) but only ever checked a small, incomplete
## subset of real regions, landing on "98/168" (32 matching real
## placements) -- a real match, just not the densest one. A full re-scan of
## every real region in a real Map.pk2 (server/cmd/scanlandmarks, new this
## session, the general multi-keyword form of findregionassets) found
## "89/182" has 279 real Jangan-named placements -- almost 9x stronger, and
## the same region an earlier session already independently found for the
## real south gate (which makes sense: the south gate belongs to Jangan).
## Corrected to this real, much better-supported match.
const JANGAN_ZONE_REGION := "89/182"

## The real Dunhuang region, found 2026-08-26 the same way as
## JANGAN_ZONE_REGION (server/cmd/scanlandmarks scanning for real
## "Res\Bldg\China\Dunhuang\..." resource paths across all 4,050 real
## regions) -- "98/157" has 279 matching real placements, the densest real
## match found.
const DUNHUANG_ZONE_REGION := "98/157"

## Resolves a zone label to a real region coordinate string ("<x>/<y>").
## The server's own symbolic default spawn zone, "jangan" (case-
## insensitive, see server/internal/session/world.go's spawnZone), maps to
## JANGAN_ZONE_REGION -- previously this project had no known real region
## coordinate for it at all (an honest gap, before this project had found
## where Jangan actually is). "dunhuang" (also case-insensitive) maps to
## DUNHUANG_ZONE_REGION the same way, for manual zone-change testing. Any
## other zone label is returned unchanged, for
## _zone_paths/_parse_region_coords to interpret (or reject) as usual.
static func _resolve_zone_region(zone: String) -> String:
	var lower := zone.to_lower()
	if lower == "jangan":
		return JANGAN_ZONE_REGION
	if lower == "dunhuang":
		return DUNHUANG_ZONE_REGION
	return zone

## Splits a zone label shaped like this project's real Map.pk2 region
## naming (an (x, y) folder/filename pair -- see docs/protocol/
## MAPM_FORMAT.md/MAPO_FORMAT.md, e.g. "100/100", "102/101") into the real
## internal paths those regions live at, after resolving it via
## _resolve_zone_region. Returns {} for anything not shaped "<x>/<y>" with
## both parts non-empty.
static func _zone_paths(zone: String) -> Dictionary:
	var parts := _resolve_zone_region(zone).split("/")
	if parts.size() != 2 or parts[0] == "" or parts[1] == "":
		return {}
	var x := parts[0]
	var y := parts[1]
	return {
		"m": "%s\\%s.m" % [x, y],
		"o": "%s\\%s.o" % [x, y],
		"minimap": "minimap\\%sx%s.ddj" % [x, y],
	}

## Parses a real region coordinate pair out of either a zone label ("100/100")
## or a loose/env-var-style file path ("100\100.m", "100/100.m") -- accepts
## either separator and strips a trailing extension if present. Returns {}
## for anything not shaped "<int>/<int>[.ext]", same convention as
## _zone_paths, so a non-region path (e.g. a loose dev file with no real
## coordinate meaning) is left alone rather than guessed at.
static func _parse_region_coords(path: String) -> Dictionary:
	var parts := path.replace("/", "\\").split("\\")
	if parts.size() < 2:
		return {}
	var x_part := parts[-2]
	var y_part := parts[-1].get_basename()
	if not x_part.is_valid_int() or not y_part.is_valid_int():
		return {}
	return {"x": int(x_part), "y": int(y_part)}

## Removes every previously-loaded region grid node (see
## _load_region_neighborhood) so a zone change or a fresh load doesn't leave
## stale terrain/objects from a different region behind.
func _clear_region_grid() -> void:
	for child in get_children():
		if child.name.begins_with("RealTerrain") or child.name.begins_with("RealMapObjects"):
			child.queue_free()

## Loads a real (2*radius+1)x(2*radius+1) grid of regions centered on
## (center_x, center_y), one real Map.pk2 .m/.o pair per cell, tiled using
## REGION_SPAN as the grid spacing -- REGION_SPAN's own doc comment notes
## real per-region *adjacency* (whether the real world lays regions out on
## a uniform grid at all) isn't independently confirmed, but a real,
## live-verified consistency check now backs it up: since MapmReader's
## deterministic full-region parsing (2026-08-23), a region's own real
## mesh footprint (97 vertices x TILE_SIZE = exactly 1920 world units) now
## matches REGION_SPAN's real 1920.0 value *exactly* -- and a real 3x3
## grid of these regions, live-rendered from a top-down debug view,
## tiles together with zero visible gaps or overlaps between neighbors.
## That's a real, positive signal for uniform-grid adjacency (an
## unrelated real per-tile size and a real per-region spacing constant,
## both independently decompiled from different functions, wouldn't
## coincidentally match this exactly if regions weren't meant to tile
## this way) -- still not a hard confirmation of the real game's true
## spatial layout, but no longer just "this project's own design" either.
## Missing neighbor files (very likely near a real world's edge, or simply
## because this project only has a handful of real regions to test with) are
## skipped the same honest way a single missing region already was --
## _try_load_real_terrain/_try_load_real_map_objects print and move on
## rather than treating it as fatal. Only the center cell (0,0) snaps the
## player onto its terrain (see _snap_player_onto_terrain) -- that's real
## spawn-adjacent ground, not any of the speculative neighbors.
##
## Loads the center cell first and reuses its own real near_height as every
## other cell's shared_vertical_anchor (see _try_load_real_terrain's doc
## comment on why -- without this, every tile independently resets its own
## near edge to Y=0, guaranteeing a cliff at *every* seam and trapping the
## camera in overlapping geometry, confirmed live 2026-08-22). If the center
## cell itself fails to load (missing file, bad data), neighbors fall back
## to each calibrating themselves independently (NAN anchor) -- the original
## behavior -- since there's no real center reference to share in that case.
func _load_region_neighborhood(center_x: int, center_y: int, radius: int = REGION_LOAD_RADIUS, texture_override: String = "") -> void:
	var center_near_height := _try_load_real_terrain("%d\\%d.m" % [center_x, center_y], texture_override, Vector3.ZERO, "_%d_%d" % [center_x, center_y], true)
	_try_load_real_map_objects("%d\\%d.o" % [center_x, center_y], Vector3.ZERO, "_%d_%d" % [center_x, center_y])

	_grid_origin_region = Vector2i(center_x, center_y)
	_grid_shared_anchor_height = center_near_height
	_grid_has_origin = true
	_loaded_cells.clear()
	_loaded_cells["0_0"] = true
	_last_stream_cell = Vector2i(0x7fffffff, 0x7fffffff)
	var center_node := get_node_or_null("RealTerrain_%d_%d" % [center_x, center_y])
	_grid_origin_world = center_node.position if center_node != null else Vector3.ZERO

	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if dx == 0 and dy == 0:
				continue # center cell already loaded above
			_load_region_cell(center_x + dx, center_y + dy, dx, dy, center_near_height)

## Loads one real region cell (terrain + objects) at grid position (dx, dy)
## relative to _grid_origin_region, and marks it loaded in _loaded_cells.
## Shared by the initial neighborhood load and _maybe_stream_regions --
## dx/dy must always be relative to the fixed _grid_origin_region, never
## to wherever the player currently is, so every cell's real world
## position stays consistent as the player moves and more cells stream in
## around them (see _grid_origin_world's own doc comment).
func _load_region_cell(region_x: int, region_y: int, dx: int, dy: int, shared_anchor: float) -> void:
	var suffix := "_%d_%d" % [region_x, region_y]
	var offset := Vector3(dx * REGION_SPAN, 0.0, dy * REGION_SPAN)
	_try_load_real_terrain("%d\\%d.m" % [region_x, region_y], "", offset, suffix, false, shared_anchor)
	_try_load_real_map_objects("%d\\%d.o" % [region_x, region_y], offset, suffix)
	_loaded_cells["%d_%d" % [dx, dy]] = true

## Streams additional real region cells in as the player moves, keeping a
## real REGION_LOAD_RADIUS window centered on whichever real region
## they're currently standing over rather than the fixed spot they
## started at -- see _grid_origin_region's own doc comment for why this
## exists. Cheap to call every physics frame: the real region-coordinate
## check is trivial, and the expensive part (loading/unloading real
## regions) only runs on the real cell boundary crossings that actually
## need it, which happen roughly once per REGION_SPAN (1920 units)
## traveled, not every frame.
func _maybe_stream_regions() -> void:
	if not _grid_has_origin:
		return
	var rel := player.position - _grid_origin_world
	var cur := Vector2i(int(round(rel.x / REGION_SPAN)), int(round(rel.z / REGION_SPAN)))
	if cur == _last_stream_cell:
		return
	_last_stream_cell = cur

	for dy in range(cur.y - REGION_LOAD_RADIUS, cur.y + REGION_LOAD_RADIUS + 1):
		for dx in range(cur.x - REGION_LOAD_RADIUS, cur.x + REGION_LOAD_RADIUS + 1):
			var key := "%d_%d" % [dx, dy]
			if _loaded_cells.has(key):
				continue
			_load_region_cell(_grid_origin_region.x + dx, _grid_origin_region.y + dy, dx, dy, _grid_shared_anchor_height)

	# Unload real cells now well outside the real load radius, so a player
	# walking through a real, large world doesn't accumulate every region
	# they've ever passed through as permanently-loaded nodes.
	var unload_margin := REGION_LOAD_RADIUS + 1
	for key in _loaded_cells.keys().duplicate():
		var parts := (key as String).split("_")
		var kdx := int(parts[0])
		var kdy := int(parts[1])
		if absi(kdx - cur.x) <= unload_margin and absi(kdy - cur.y) <= unload_margin:
			continue
		var suffix := "_%d_%d" % [_grid_origin_region.x + kdx, _grid_origin_region.y + kdy]
		var terrain_node := get_node_or_null("RealTerrain" + suffix)
		if terrain_node != null:
			terrain_node.queue_free()
		var objects_node := get_node_or_null("RealMapObjects" + suffix)
		if objects_node != null:
			objects_node.queue_free()
		_loaded_cells.erase(key)

## _ready()'s own entry point into the region grid: reads SRREVAMP_MAPM_PATH
## the same way this scene always has, but now treats it as the *center* of
## a real multi-region neighborhood (see _load_region_neighborhood) instead
## of the one and only region loaded. Falls back to the original
## single-region behavior for a path that isn't shaped like a real region
## coordinate (e.g. a loose dev file with no real (x, y) meaning).
func _load_initial_region_neighborhood() -> void:
	var mapm_path := OS.get_environment("SRREVAMP_MAPM_PATH")
	if mapm_path != "":
		var coords := _parse_region_coords(mapm_path)
		if coords.is_empty():
			_try_load_real_terrain()
			_try_load_real_map_objects()
			return
		_load_region_neighborhood(coords["x"], coords["y"], REGION_LOAD_RADIUS, OS.get_environment("SRREVAMP_MAPM_TEXTURE_PATH"))
		return

	# No dev/testing env var set -- the real, normal path for an actual
	# logged-in player: load whatever real zone the server itself already
	# placed them in (NetClient.last_enter_world_result.zone), the exact
	# same resolution _reload_zone_assets uses for a later zone change.
	# Without this, a real downloaded client with real pk2 files in its
	# local pk2/ folder (see Pk2Config) and no env vars set at all would
	# never load any terrain/objects on a normal login -- the env-var path
	# above was the only one ever wired to real region loading, which only
	# ever exercised this project's own dev/testing workflow, never a real
	# player's actual first spawn.
	var result := NetClient.last_enter_world_result
	if result != null and result.ok and result.zone != "":
		_reload_zone_assets(result.zone)
	else:
		print("World3D: no real zone to load (no SRREVAMP_MAPM_PATH set and no real logged-in session) -- ground stays a placeholder")

## Tears down whatever real terrain/map-object nodes are currently loaded
## and reloads them for zone, resolving real per-zone paths via _zone_paths
## instead of the fixed SRREVAMP_MAPM_PATH/SRREVAMP_MAPO_PATH env vars this
## scene's initial _ready() load still uses. If zone isn't shaped like a
## real region coordinate (see _zone_paths), this just clears back to the
## placeholder ground with no objects -- same honest "nothing to load"
## behavior as an unset env var, not a guess.
func _reload_zone_assets(zone: String) -> void:
	_clear_region_grid()
	ground_mesh.visible = true
	ground_collision.disabled = false

	var region := _resolve_zone_region(zone)
	var coords := _parse_region_coords(region)
	if coords.is_empty():
		print("World3D: zone %s isn't shaped like a real region (x/y) -- no per-zone assets to load" % zone)
		# _clear_region_grid() above already removed every real region node
		# -- also drop the real streaming state that referenced them, so
		# _maybe_stream_regions doesn't keep trying to grow a grid around a
		# real origin cell that no longer exists.
		_grid_has_origin = false
		_loaded_cells.clear()
		return

	var paths := _zone_paths(zone)
	_load_region_neighborhood(coords["x"], coords["y"], REGION_LOAD_RADIUS, paths.get("minimap", ""))

## Reacts to a successful real zone change (see NetClient.change_zone/
## OpChangeZoneResult): updates the zone label and reloads this scene's
## terrain/map objects for the new real zone. A failed zone change (bad
## request, already in that zone, ...) is left to whatever UI triggered it
## to report -- this scene doesn't render its own error text for that.
func _on_change_zone_result(result: WorldNet.ChangeZoneResult) -> void:
	if not result.ok:
		return
	zone_label.text = "Zone: %s" % result.zone
	player.position = Vector3(result.x, result.y, result.z)
	_last_sent_pos = player.position

	# Whoever was rendered as an "other" belonged to the *old* zone -- the
	# server only broadcasts OpEntityLeft to people left behind, never back
	# to the mover, so without this their stale capsules/bodies would keep
	# showing here even though this player can no longer interact with them
	# (see docs/PROGRESS.md for this bug, caught right after the initial
	# OpChangeZone implementation shipped).
	for character_id in _other_bodies.keys():
		_other_bodies[character_id].queue_free()
	_other_bodies.clear()
	for other in result.others:
		_spawn_or_update_other(other.character_id, other.char_name, Vector3(other.x, other.y, other.z), other.armor_slots_mask, other.gender, other.has_weapon, other.has_shield)

	# Same stale-body bug as _other_bodies above, for monsters -- the old
	# zone's monster list result never gets superseded on its own, so
	# without this their capsules would keep showing here too.
	for monster_id in _monster_bodies.keys():
		_monster_bodies[monster_id].queue_free()
	_monster_bodies.clear()
	NetClient.list_monsters()

	_reload_zone_assets(result.zone)

## Loads real terrain from a real Map.pk2 region .m file via MapmReader +
## MapmTerrainBuilder, replacing both the placeholder ground's visual mesh
## and its collision shape (see this file's top comment) -- if
## SRREVAMP_MAPM_PATH is set. Accepts either a loose file path or a path
## inside SRREVAMP_MAP_PK2_PATH (see AssetSource). Skips gracefully
## otherwise. path_override/texture_override let _reload_zone_assets pass
## real per-zone paths it resolved itself instead of reading the env vars --
## empty (the default) preserves the original env-var-only behavior for
## _ready()'s own call. world_offset/node_suffix/snap_player let
## _load_region_neighborhood place multiple of these side by side as a real
## multi-region grid instead of always the one env-var-driven region at the
## scene origin -- defaults preserve the original single-region behavior.
##
## shared_vertical_anchor (NAN by default) is the fix for a real bug found
## live (2026-08-22): without it, *every* tile independently forces its own
## near-row-middle vertex to world Y=0 (see the vertical-offset comment
## below), which guarantees a cliff at *every* seam between two tiles in the
## grid, since neighboring tiles' real height data has no known relationship
## to begin with -- confirmed live to trap the camera inside overlapping
## geometry. Passing the center tile's own near_height as every other
## tile's anchor instead means only the center tile still calibrates itself
## to Y=0; every neighbor renders at whatever height its own real data
## implies *relative to that one shared reference* rather than each also
## independently resetting to zero. This doesn't (and can't, without real
## cross-region alignment data this project doesn't have) make neighboring
## tiles seamlessly continuous -- real per-tile terrain remains genuinely
## steep on its own (confirmed live even for a single region, see
## MAPM_FORMAT.md) -- it just stops the grid from *compounding* that with a
## guaranteed reset at every single seam. Returns the near_height this call
## used (NAN on any failure path) so a caller building a grid can capture
## the center tile's value and pass it to every other cell.
func _try_load_real_terrain(path_override: String = "", texture_override: String = "", world_offset: Vector3 = Vector3.ZERO, node_suffix: String = "", snap_player: bool = true, shared_vertical_anchor: float = NAN) -> float:
	var mapm_path := path_override if path_override != "" else OS.get_environment("SRREVAMP_MAPM_PATH")
	if mapm_path == "":
		print("World3D: SRREVAMP_MAPM_PATH not set -- ground stays a placeholder")
		return NAN

	var archive := _open_map_pk2_if_set()
	var bytes := AssetSource.read_bytes(mapm_path, archive)
	if bytes.is_empty():
		printerr("World3D: could not find terrain at ", mapm_path)
		return NAN

	var region := MapmReader.parse(bytes)
	if region == null:
		printerr("World3D: could not parse terrain at ", mapm_path)
		return NAN

	# Real .t lightmap, loaded up front so it's available to whichever mesh
	# builder runs below -- see _load_real_terrain_lightmap's doc comment
	# and docs/protocol/MAPT_FORMAT.md. Corrects an earlier same-day
	# attempt that decoded the wrong bytes entirely (before .t's real
	# structure -- a ShadowMap plus a properly-headered embedded DDS --
	# was found via public documentation) and applied the result as direct
	# detail-albedo color, which looked like broken color-noise static and
	# was reverted. The real embedded texture is a genuine grayscale
	# shadow map (white = fully lit), which Godot's ao_texture consumes
	# directly with no custom shader needed.
	var lightmap := _load_real_terrain_lightmap(mapm_path, archive)
	var tile_table := _load_tile_index()

	# Real per-quad ground textures (2026-08-23) -- see
	# docs/protocol/DDJ_FORMAT.md and MapmTerrainBuilder's top comment for
	# the correction: these actually live in Map.pk2's real Tile2D\
	# folder, an archive/folder an earlier search never checked. Only
	# used if at least one of this region's real texture IDs actually
	# resolved to a real file -- otherwise the flat tile-type color
	# (build_full_region_mesh) is a strictly better fallback than a
	# multi-surface mesh where every single surface is the color fallback
	# anyway.
	var ground_textures := _load_real_ground_textures(region, tile_table)
	var textured := not ground_textures.is_empty()

	# Real, fully deterministic full-region assembly (2026-08-23) -- see
	# MapmTerrainBuilder.build_full_region_mesh's doc comment and
	# MAPM_FORMAT.md. MapmReader now parses a region's real, confirmed 6x6
	# block grid directly (no more row/column guessing), so this always
	# produces the complete real 97x97 mesh on a successful parse.
	var terrain_mesh: ArrayMesh
	if textured:
		terrain_mesh = MapmTerrainBuilder.build_full_region_mesh_textured(region, tile_table, ground_textures, lightmap)
	else:
		terrain_mesh = MapmTerrainBuilder.build_full_region_mesh(region, tile_table)
	if terrain_mesh == null:
		printerr("World3D: parsed ", region.blocks.size(), " real blocks from ", mapm_path, " but couldn't build a mesh from them")
		return NAN

	var terrain_group := Node3D.new()
	terrain_group.name = "RealTerrain" + node_suffix

	# Real per-quad textures (see above) already carry their own
	# per-surface materials (including the real .t lightmap) from
	# MapmTerrainBuilder -- material_override would apply one material to
	# every surface uniformly and stomp that, so it's left null and the
	# mesh's own per-surface materials show through. The single-flat-
	# material path below is unchanged for the untextured fallback.
	var aabb := terrain_mesh.get_aabb()
	var mat: StandardMaterial3D = null
	if not textured:
		mat = StandardMaterial3D.new()
		var real_texture := _load_real_terrain_texture(texture_override)
		var row_count_estimate := aabb.size.z / MapmTerrainBuilder.TILE_SIZE + 1
		if real_texture != null:
			mat.albedo_texture = real_texture
			# The mesh's own UVs (see MapmTerrainBuilder) stretch 0..1 across
			# the whole recovered strip, which can be dozens of real rows long
			# -- squishing one square minimap image over that whole length
			# reads as heavy streaking rather than ground detail. Repeating it
			# roughly once per GRID_WIDTH rows (a real, confirmed value -- see
			# MapmTerrainBuilder) keeps each repeat closer to the image's own
			# roughly-square real aspect ratio instead of one giant stretch.
			mat.uv1_scale = Vector3(1.0, max(row_count_estimate / float(MapmTerrainBuilder.GRID_WIDTH), 1.0), 1.0)
		else:
			mat.vertex_color_use_as_albedo = true
		if lightmap != null:
			mat.ao_enabled = true
			mat.ao_texture = lightmap
			mat.ao_light_affect = 1.0
	# Real world-space alignment with the player's own spawn position isn't
	# confirmed (see top comment) -- centered near the player purely for
	# visibility, same as the scenery/decoration-skeleton placement choices
	# elsewhere in this file. The vertical offset uses the real height of
	# the mesh's own first-row, middle-column vertex (the part of the mesh
	# that ends up nearest the player/camera once placed) rather than the
	# whole mesh's average -- terrain height varies enormously row to row,
	# so a global average can land nowhere near where the player actually
	# is; this keeps the offset tied to the specific real vertex the player
	# spawns next to.
	#
	# MapmTerrainBuilder lays successive rows out along local +Z, but this
	# scene's third-person camera looks down -Z (+Z is behind it -- see the
	# scenery-placement comment in _try_load_real_scenery()), so an
	# unrotated terrain mesh would extend almost entirely behind the
	# camera. Rotating 180 degrees around Y flips both axes consistently
	# (a pure rotation, so front-face winding/normals stay correct) so
	# successive rows extend further *into* view instead.
	# Read directly from the parsed region rather than the built mesh --
	# see near_row_middle_height's doc comment: the textured mesh path
	# above can split row 0 across several surfaces, so surface 0 alone
	# no longer reliably holds this vertex the way the old single-surface
	# mesh did.
	var near_height := MapmTerrainBuilder.near_row_middle_height(region)
	var anchor_height := near_height if is_nan(shared_vertical_anchor) else shared_vertical_anchor
	terrain_group.rotation.y = PI
	terrain_group.position = Vector3(aabb.size.x / 2.0, -anchor_height, 0) + world_offset
	add_child(terrain_group)
	ground_mesh.visible = false
	ground_collision.disabled = true

	# History, kept for context: an earlier same-day attempt tiled a single
	# parsed sub-patch's data across a synthetic 6x6 grid of *copies* to
	# fill a region's real footprint (see git history / PROGRESS.md), and
	# was reverted after live testing showed it made the camera-in-geometry
	# problem worse (a steep boundary every 320 units instead of every
	# 1920). That approach is now obsolete: terrain_mesh above is already
	# the real stitched multi-sub-patch mesh (build_full_region_mesh), not
	# one repeated patch, so there is exactly one real node to build here.
	var patch_body := StaticBody3D.new()
	var patch_shape := CollisionShape3D.new()
	patch_shape.shape = terrain_mesh.create_trimesh_shape()
	patch_body.add_child(patch_shape)
	var single_patch := MeshInstance3D.new()
	single_patch.name = "SubPatch"
	single_patch.mesh = terrain_mesh
	single_patch.material_override = mat
	single_patch.add_child(patch_body)
	terrain_group.add_child(single_patch)

	# The vertical calibration above only guarantees one specific mesh vertex
	# lines up near world Y=0 -- it says nothing about the height of whatever
	# real terrain happens to sit under the player's actual server-given
	# spawn X/Z, which can be wildly different (see this function's own doc
	# comment on why real spawn/terrain alignment isn't confirmed yet). Left
	# alone, the player can end up embedded in or floating above the mesh.
	# Deferred one frame so the collision shape above is actually registered
	# with the physics server before the raycast below queries it. Only the
	# grid's center region (see _load_region_neighborhood) does this --
	# snapping onto every speculative neighbor as it loads would fight over
	# the player's position for no reason.
	if snap_player:
		call_deferred("_snap_player_onto_terrain")

	print("World3D: loaded real terrain from %s (%d real blocks, %d rows stitched, real collision shape built)" % [
		mapm_path, region.blocks.size(), terrain_mesh.get_aabb().size.z / MapmTerrainBuilder.TILE_SIZE + 1])
	return near_height

## Practical safety net for the real terrain-alignment gap noted where this
## is called: raycasts straight down (and up, to cover an embedded start)
## through the player's current X/Z and snaps them onto whatever real
## surface it hits, so movement always starts from solid, walkable ground
## regardless of how far off the terrain's heuristic placement is from the
## player's real spawn point. Not a fix for the underlying alignment
## question -- just keeps the game playable until that's reverse-engineered.
func _snap_player_onto_terrain() -> void:
	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		player.position + Vector3(0.0, 1000.0, 0.0),
		player.position + Vector3(0.0, -1000.0, 0.0))
	query.exclude = [player.get_rid()]
	var hit := space_state.intersect_ray(query)
	if hit.is_empty():
		return
	player.position.y = hit.position.y + 0.05
	player.velocity = Vector3.ZERO
	_avoid_spawning_under_roof()

## Real, general safety net (2026-08-26, see docs/WORLD_ISSUES.md): a real
## fixed server spawnPos of (0,0,0) can genuinely land inside a real
## building's interior in a densely-built real zone (confirmed for Jangan's
## own real region, 863 real placements in one region) -- this isn't
## something a fixed spawn coordinate can reliably avoid on its own, since
## "the most open point" in a real palace complex still isn't very open.
## Rather than try to precompute a real building-free spawn point (would
## need real per-object footprint data this project doesn't have, not just
## placement anchors), this checks *after* landing on real terrain whether
## there's a real low ceiling directly overhead (a real room, not open sky)
## and, if so, tries nearby real ground positions in a widening ring until
## one has clear sky above, snapping there instead. Bounded and best-effort:
## if every tried position is still covered, leaves the player at the
## original terrain-snapped position rather than searching forever.
## **Corrected 2026-08-26** (see docs/WORLD_ISSUES.md): a real playtest
## found the original 30.0 never triggered the escape search at all --
## real placed objects render at their own native scale (unlike the
## player's own body, deliberately rescaled to a fixed 1.8-unit height in
## _build_assembled_character), and a direct check of real Jangan-region
## meshes found real building pieces up to ~44.5 real units tall
## (`jangan03\cj_pal_dam_left02.bsr`) and real trees up to ~140 -- 30.0
## couldn't even clear a single real wall piece, let alone a real room.
## Raised with real margin above the tallest real piece measured.
const ROOF_CHECK_HEIGHT := 200.0
## Also raised in proportion -- a real building tall enough to need the
## new ROOF_CHECK_HEIGHT plausibly has a footprint on a similar real
## scale, not the old, much smaller assumption.
const ROOF_ESCAPE_STEP := 60.0
const ROOF_ESCAPE_RINGS := 10
const ROOF_ESCAPE_DIRECTIONS := 8

func _avoid_spawning_under_roof() -> void:
	if not _has_roof_overhead(player.position):
		return
	var space_state := get_world_3d().direct_space_state
	for ring in range(1, ROOF_ESCAPE_RINGS + 1):
		var radius := ring * ROOF_ESCAPE_STEP
		for i in range(ROOF_ESCAPE_DIRECTIONS):
			var angle := TAU * i / ROOF_ESCAPE_DIRECTIONS
			var candidate_xz := player.position + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
			var query := PhysicsRayQueryParameters3D.create(
				candidate_xz + Vector3(0.0, 1000.0, 0.0),
				candidate_xz + Vector3(0.0, -1000.0, 0.0))
			query.exclude = [player.get_rid()]
			var hit := space_state.intersect_ray(query)
			if hit.is_empty():
				continue
			var candidate: Vector3 = hit.position + Vector3(0.0, 0.05, 0.0)
			if not _has_roof_overhead(candidate):
				player.position = candidate
				player.velocity = Vector3.ZERO
				return
	# Every tried ring was still covered -- a real, honest "couldn't find
	# open ground nearby" outcome (e.g. deep inside a real dense palace
	# complex), not silently pretending success.
	printerr("World3D: spawn point has a real roof overhead and no nearby open ground was found within %d real units -- leaving the player here" % (ROOF_ESCAPE_RINGS * ROOF_ESCAPE_STEP))

## True if a real raycast straight up from pos hits something within
## ROOF_CHECK_HEIGHT real units -- a real low ceiling/roof, not open sky.
func _has_roof_overhead(pos: Vector3) -> bool:
	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		pos + Vector3(0.0, 0.5, 0.0),
		pos + Vector3(0.0, ROOF_CHECK_HEIGHT, 0.0))
	query.exclude = [player.get_rid()]
	var hit := space_state.intersect_ray(query)
	return not hit.is_empty()

## Auto-loads a real assembled character (real .bsk skeleton + real
## body-part .bms meshes via CharacterAssembler) as the player's own body,
## using the conventional real path layout this project found during
## reverse-engineering -- see this file's top comment for the honest scope
## of what "auto" means here (a fixed default, not real per-account
## selection). Only needs SRREVAMP_PK2_PATH; falls back to leaving the
## placeholder capsule visible if the conventional paths aren't found in
## that archive (e.g. a real archive laid out differently than the one
## sample this project could check against).
## Parses and caches, once at scene startup, real character assets for
## *every* real Gender in GENDER_ASSET_PATHS -- both _try_apply_real_
## player_character and every _spawn_or_update_other call reuse this same
## parsed data (keyed by gender, see _character_assets) rather than
## re-reading/re-parsing the same real .bms/.bmt files per character. A
## gender whose conventional real paths aren't found in the archive simply
## gets no entry (not an error -- see _build_assembled_character's
## DEFAULT_GENDER fallback). Leaves _character_assets empty if
## SRREVAMP_PK2_PATH isn't set at all.
func _load_character_assets() -> void:
	var archive := _open_pk2_if_set()
	if archive == null:
		print("World3D: SRREVAMP_PK2_PATH not set -- characters stay placeholders")
		return

	for gender in GENDER_ASSET_PATHS:
		var paths: Dictionary = GENDER_ASSET_PATHS[gender]

		var bsk_bytes := AssetSource.read_bytes(paths["skeleton"], archive)
		if bsk_bytes.is_empty():
			printerr("World3D: could not find %s skeleton at %s in %s" % [gender, paths["skeleton"], Pk2Config.data_path()])
			continue
		var skel := BskReader.parse(bsk_bytes)
		if skel == null:
			printerr("World3D: could not parse %s skeleton at %s" % [gender, paths["skeleton"]])
			continue

		var parts := {}
		for part_name in paths["body_parts"]:
			var bytes := AssetSource.read_bytes(paths["mesh_dir"] + "\\" + part_name + ".bms", archive)
			if bytes.is_empty():
				continue
			var mesh := BmsReader.parse(bytes)
			if mesh != null:
				parts[part_name] = mesh
		if parts.is_empty():
			printerr("World3D: found the %s skeleton but no body-part meshes under %s" % [gender, paths["mesh_dir"]])
			continue

		# One equipment_sets entry per real armor "look" number (see
		# ARMOR_SET_NUMBERS) -- a set missing from this specific archive
		# (real gaps do exist, see ARMOR_SET_NUMBERS' doc comment) is simply
		# absent from the dict rather than a null placeholder.
		var equipment_sets := {}
		for set_number in ARMOR_SET_NUMBERS:
			var equipment_parts := {}
			for suffix in paths["equipment_part_suffixes"]:
				var part_name := "clothes_%s_%s" % [set_number, suffix]
				var eq_bytes := AssetSource.read_bytes(paths["equipment_mesh_dir"] + "\\" + part_name + ".bms", archive)
				if eq_bytes.is_empty():
					continue
				var eq_mesh := BmsReader.parse(eq_bytes)
				if eq_mesh != null:
					equipment_parts[part_name] = eq_mesh
			if equipment_parts.is_empty():
				continue
			var equipment_materials := _load_real_materials(archive, paths["equipment_material_dir"] + "\\clothes_" + set_number + ".bmt")
			equipment_sets[set_number] = {"parts": equipment_parts, "materials": equipment_materials}

		var idle_anim: BanReader.ParsedAnimation = null
		var idle_bytes := AssetSource.read_bytes(paths["idle_anim"], archive)
		if not idle_bytes.is_empty():
			idle_anim = BanReader.parse(idle_bytes)

		var walk_anim: BanReader.ParsedAnimation = null
		var walk_bytes := AssetSource.read_bytes(paths["walk_anim"], archive)
		if not walk_bytes.is_empty():
			walk_anim = BanReader.parse(walk_bytes)

		_character_assets[gender] = {
			"skel": skel,
			"body_parts": parts,
			"body_materials": _load_real_materials(archive, paths["material"]),
			"equipment_sets": equipment_sets,
			"idle_anim": idle_anim,
			"walk_anim": walk_anim,
		}
		print("World3D: cached real %s character assets (%d bones, %d body parts, %d armor sets, idle_anim=%s, walk_anim=%s) from %s" % [
			gender, skel.bones.size(), parts.size(), equipment_sets.size(), idle_anim != null, walk_anim != null, Pk2Config.data_path()])

	for variant in WEAPON_VARIANTS:
		var weapon_bytes := AssetSource.read_bytes(variant["mesh"], archive)
		if weapon_bytes.is_empty():
			continue
		var weapon_mesh := BmsReader.parse(weapon_bytes)
		if weapon_mesh == null:
			continue
		_weapon_variants.append({"mesh": weapon_mesh, "materials": _load_real_materials(archive, variant["material"])})
	print("World3D: cached %d/%d real weapon variants from %s" % [_weapon_variants.size(), WEAPON_VARIANTS.size(), Pk2Config.data_path()])

	for variant in SHIELD_VARIANTS:
		var shield_bytes := AssetSource.read_bytes(variant["mesh"], archive)
		if shield_bytes.is_empty():
			continue
		var shield_mesh := BmsReader.parse(shield_bytes)
		if shield_mesh == null:
			continue
		_shield_variants.append({"mesh": shield_mesh, "materials": _load_real_materials(archive, variant["material"])})
	print("World3D: cached %d/%d real shield variants from %s" % [_shield_variants.size(), SHIELD_VARIANTS.size(), Pk2Config.data_path()])

## Maps CharacterAssembler's real 2-letter equipment-slot codes (see
## EQUIPMENT_SLOT_BONES) to the real, decompiler-confirmed slot constants
## in EquipmentNet (see docs/protocol/EQUIP_SLOTS.md). "aa" (arm/forearm)
## has no confirmed real slot name of its own -- rendered together with
## "ba" (MAIL/body) below, the same bundling this project's one fixed
## armor set always used before per-piece slots existed.
const EQUIPMENT_CODE_TO_SLOT := {
	"ha": EquipmentNet.SLOT_HELM,
	"ba": EquipmentNet.SLOT_MAIL,
	"sa": EquipmentNet.SLOT_SHOULDER_GUARD,
	"la": EquipmentNet.SLOT_PANTS,
	"fa": EquipmentNet.SLOT_BOOTS,
}

## Filters parts (CharacterAssembler-shaped part_name -> ParsedMesh) down
## to only the pieces whose real slot bit is set in armor_slots_mask (see
## EQUIPMENT_CODE_TO_SLOT and EquipmentNet.ARMOR_SLOTS for the bit
## meaning). A part whose code isn't in EQUIPMENT_CODE_TO_SLOT (i.e. "aa")
## is included whenever "ba" (MAIL) is, per that const's doc comment.
func _filter_equipped_parts(parts: Dictionary, armor_slots_mask: int) -> Dictionary:
	var mail_bit_index := EquipmentNet.ARMOR_SLOTS.find(EquipmentNet.SLOT_MAIL)
	var mail_equipped := mail_bit_index != -1 and (armor_slots_mask & (1 << mail_bit_index)) != 0

	var out := {}
	for part_name in parts:
		var code: String = CharacterAssembler._equipment_slot(part_name)
		if not EQUIPMENT_CODE_TO_SLOT.has(code):
			if code == "aa" and mail_equipped:
				out[part_name] = parts[part_name]
			continue
		var slot: int = EQUIPMENT_CODE_TO_SLOT[code]
		var bit_index := EquipmentNet.ARMOR_SLOTS.find(slot)
		if bit_index != -1 and (armor_slots_mask & (1 << bit_index)) != 0:
			out[part_name] = parts[part_name]
	return out

## Builds one fresh, independent Skeleton3D + assembled body/equipment from
## the cached data _load_character_assets() parsed for the requested real
## gender -- each character instance (player or other) needs its own
## Skeleton3D node, so this re-runs CharacterAssembler against the shared
## parsed meshes rather than reparsing files. Falls back to DEFAULT_GENDER
## if gender's assets never loaded (or gender is empty/unrecognized -- e.g.
## an older peer, or the local player's own EnterWorldResult didn't carry
## one yet). Returns null only if even the default's assets never loaded.
## armor_set_number/weapon_variant_idx/shield_variant_idx select which real
## look to render (see ARMOR_SET_NUMBERS/WEAPON_VARIANTS/SHIELD_VARIANTS) --
## defaults ("03"/0/0) reproduce this project's original single-fixed-look
## behavior, which is what every caller except _try_apply_real_player_character
## still uses (see WEAPON_VARIANTS' doc comment on why other players don't
## get real per-item variety yet).
func _build_assembled_character(armor_slots_mask: int = 0, gender: String = DEFAULT_GENDER, include_weapon: bool = false, include_shield: bool = false, armor_set_number: String = "03", weapon_variant_idx: int = 0, shield_variant_idx: int = 0) -> Skeleton3D:
	var assets: Dictionary = _character_assets.get(gender, _character_assets.get(DEFAULT_GENDER, {}))
	if assets.is_empty():
		return null

	var skeleton := Skeleton3DBuilder.build_skeleton3d(assets["skel"])
	var fallback_mat := StandardMaterial3D.new()
	fallback_mat.albedo_color = Color(0.85, 0.7, 0.55)
	CharacterAssembler.assemble(skeleton, assets["body_parts"], fallback_mat, assets["body_materials"])

	var equipment_sets: Dictionary = assets["equipment_sets"]
	var chosen_set: Dictionary = equipment_sets.get(armor_set_number, equipment_sets.get("03", {}))
	if not chosen_set.is_empty():
		var equipped_parts := _filter_equipped_parts(chosen_set["parts"], armor_slots_mask)
		if not equipped_parts.is_empty():
			CharacterAssembler.assemble_equipment(skeleton, equipped_parts, null, chosen_set["materials"])

	if include_weapon and not _weapon_variants.is_empty():
		var weapon: Dictionary = _weapon_variants[weapon_variant_idx % _weapon_variants.size()]
		var weapon_mesh: BmsReader.ParsedMesh = weapon["mesh"]
		var weapon_material: Material = weapon["materials"].get(weapon_mesh.material_name, null)
		CharacterAssembler.assemble_weapon(skeleton, weapon_mesh, weapon_material)
	if include_shield and not _shield_variants.is_empty():
		var shield: Dictionary = _shield_variants[shield_variant_idx % _shield_variants.size()]
		var shield_mesh: BmsReader.ParsedMesh = shield["mesh"]
		var shield_material: Material = shield["materials"].get(shield_mesh.material_name, null)
		CharacterAssembler.assemble_shield(skeleton, shield_mesh, shield_material)

	# Real bind-pose data uses a different native scale than this scene's
	# ~1.8-unit-tall placeholder capsule -- rescale so the assembled
	# character's own bind-pose height matches it, rather than a fixed
	# guessed factor (real body-part scale isn't necessarily the same
	# across every character/skeleton pair -- see
	# docs/protocol/BSK_FORMAT.md).
	var min_y := INF
	var max_y := -INF
	for i in range(skeleton.get_bone_count()):
		var y: float = skeleton.get_bone_global_rest(i).origin.y
		min_y = min(min_y, y)
		max_y = max(max_y, y)
	var real_height := max_y - min_y
	if real_height > 0.01:
		skeleton.scale = Vector3.ONE * (1.8 / real_height)

	return skeleton

## Attaches a freshly-built real assembled character (see
## _build_assembled_character()) to the player node, hiding the
## placeholder capsule -- if the shared character assets loaded. Leaves
## the placeholder capsule visible otherwise.
##
## Whether the assembled character wears its armor/weapon is now driven by
## the real, server-authoritative equip state (EquipmentNet/OP_LIST via
## NetClient.list_equipment), not shown unconditionally -- a newly-created
## character has nothing equipped by default, so this makes the previous
## "everyone always wears the one fixed armor set" behavior more honest:
## the armor/weapon meshes are real either way, but now they only appear
## once the player has actually equipped something in that real slot.
func _try_apply_real_player_character() -> void:
	var equipped := await _real_player_equipped_slots()
	var gender := DEFAULT_GENDER
	if NetClient.last_enter_world_result != null and NetClient.last_enter_world_result.gender != "":
		gender = NetClient.last_enter_world_result.gender

	# Real per-item visual variety (see ARMOR_SET_NUMBERS/WEAPON_VARIANTS/
	# SHIELD_VARIANTS): a deterministic pick from the real equipped item ID,
	# so a different real item actually looks different, without needing a
	# real item-to-model mapping this project couldn't find (see those
	# consts' doc comments). Item ID 0 (nothing equipped in that slot)
	# harmlessly picks index 0 -- moot either way, since
	# _build_assembled_character only renders a slot that's actually
	# equipped/included.
	var armor_item_id: int = equipped[3]
	var weapon_item_id: int = equipped[4]
	var shield_item_id: int = equipped[5]
	var armor_set_number: String = ARMOR_SET_NUMBERS[armor_item_id % ARMOR_SET_NUMBERS.size()] if not ARMOR_SET_NUMBERS.is_empty() else "03"
	var weapon_variant_idx: int = weapon_item_id % max(_weapon_variants.size(), 1)
	var shield_variant_idx: int = shield_item_id % max(_shield_variants.size(), 1)

	var skeleton := _build_assembled_character(equipped[0], gender, equipped[1], equipped[2], armor_set_number, weapon_variant_idx, shield_variant_idx)
	if skeleton == null:
		return
	player.add_child(skeleton)
	player_mesh.visible = false
	_player_skeleton = skeleton
	_player_gender = gender

## Queries the real server for the local player's actual equipped items
## (the same EquipmentNet protocol the 2D equipment HUD already uses) and
## reports [armor_slots_mask, has_weapon, has_shield, armor_item_id,
## weapon_item_id, shield_item_id] -- a real per-piece bitmask (see
## EquipmentNet.ARMOR_SLOTS), whether SLOT_WEAPON/SLOT_SHIELD are occupied,
## and the real equipped item ID for each (0 if none) -- used to pick a real
## per-item visual (see ARMOR_SET_NUMBERS/WEAPON_VARIANTS/SHIELD_VARIANTS).
## armor_item_id is just one representative real ID (the first armor slot
## found, MAIL preferred) rather than one per slot -- this project's own
## armor "look" system only supports one visual set for the whole body at
## once (see ARMOR_SET_NUMBERS), not fully composable per-slot outfits, so
## picking one real ID to represent the whole look is consistent with that
## existing scope, not a new simplification. Returns all-zero/false without
## querying if there's no live server connection -- e.g. the standalone
## dev-tool/screenshot contexts used throughout this project's asset work,
## which load World3D.tscn directly with SRREVAMP_* env vars set but no real
## login/enter-world flow, so a query would otherwise await a signal that
## can never fire.
func _real_player_equipped_slots() -> Array:
	if not NetClient.is_connected_to_server() or NetClient.current_character_name == "":
		return [0, false, false, 0, 0, 0]
	NetClient.list_equipment(NetClient.current_character_name)
	var items: Array = (await NetClient.equipment_result)[0]
	var armor_slots_mask := 0
	var has_weapon := false
	var has_shield := false
	var armor_item_id := 0
	var weapon_item_id := 0
	var shield_item_id := 0
	for item in items:
		var bit_index := EquipmentNet.ARMOR_SLOTS.find(item.slot)
		if bit_index != -1:
			armor_slots_mask |= 1 << bit_index
			if armor_item_id == 0 or item.slot == EquipmentNet.SLOT_MAIL:
				armor_item_id = item.item_id
		elif item.slot == EquipmentNet.SLOT_WEAPON:
			has_weapon = true
			weapon_item_id = item.item_id
		elif item.slot == EquipmentNet.SLOT_SHIELD:
			has_shield = true
			shield_item_id = item.item_id
	return [armor_slots_mask, has_weapon, has_shield, armor_item_id, weapon_item_id, shield_item_id]

## Loads a real Map.pk2 region's real object placements (SRREVAMP_MAPO_PATH,
## e.g. "0\\0.o", via SRREVAMP_MAP_PK2_PATH -- same archive as
## SRREVAMP_MAPM_PATH) and renders up to MAX_MAP_OBJECTS of them with their
## real resolved .bsr models, via a real type-ID lookup
## (OBJECT_INDEX_PATH, from SRREVAMP_PK2_PATH's Data.pk2) -- see
## docs/protocol/MAPO_FORMAT.md for how this real mapping was found (it was
## a confirmed dead end earlier in this project). Skips gracefully if
## either env var is unset, or if a specific placement's type ID isn't in
## the index (real, expected -- not every real object type is necessarily
## resolvable, and this project doesn't try to hide that by falling back
## to a placeholder marker here). path_override lets _reload_zone_assets
## pass a real per-zone path it resolved itself instead of reading
## SRREVAMP_MAPO_PATH -- empty (the default) preserves the original
## env-var-only behavior for _ready()'s own call. world_offset/node_suffix
## let _load_region_neighborhood place multiple of these side by side --
## defaults preserve the original single-region behavior. Also tries the
## same region's real .o2 file (mapo_path + "2") and merges its real
## placements in, if present -- .o2 only exists for newer-generation
## ("Shape B") regions alongside .o (see docs/protocol/MAPO2_FORMAT.md and
## MAPM_FORMAT.md's Shape A/B split), so a missing .o2 is the normal,
## expected case for Shape A regions, not an error.
func _try_load_real_map_objects(path_override: String = "", world_offset: Vector3 = Vector3.ZERO, node_suffix: String = "") -> void:
	var mapo_path := path_override if path_override != "" else OS.get_environment("SRREVAMP_MAPO_PATH")
	if mapo_path == "":
		print("World3D: SRREVAMP_MAPO_PATH not set -- no real map objects loaded")
		return

	var map_archive := _open_map_pk2_if_set()
	var mapo_bytes := AssetSource.read_bytes(mapo_path, map_archive)
	if mapo_bytes.is_empty():
		printerr("World3D: could not find map objects at ", mapo_path)
		return
	var region := MapoReader.parse(mapo_bytes)
	if region == null:
		printerr("World3D: could not parse map objects at ", mapo_path)
		return

	# Real .o2 placements are collected the same way as .o's: same type ID
	# + world position shape (see docs/protocol/MAPO2_FORMAT.md), just
	# indexed into a real 6x6 sector grid of 3 lists each rather than one
	# flat resync-scanned list. .o2 only exists for newer-generation
	# ("Shape B") regions -- see docs/protocol/MAPM_FORMAT.md's Shape A/B
	# split -- so a missing .o2 here (Shape A, or no real objects/sectors
	# unpopulated) is the normal, expected case, not an error.
	var placements: Array = []
	for obj in region.objects:
		placements.append({"type_id": obj.type_id, "position": obj.position, "rotation": obj.rotation})
	var mapo2_path := mapo_path + "2"
	var mapo2_bytes := AssetSource.read_bytes(mapo2_path, map_archive)
	var o2_count := 0
	if not mapo2_bytes.is_empty():
		var region2 := MapO2Reader.parse(mapo2_bytes)
		if region2 != null:
			for sector in region2.sectors:
				for list in sector.lists:
					for entry in list:
						# Real yaw rotation -- see MapO2Reader.Entry.rotation's
						# doc comment for how this was confirmed (same
						# real-range empirical check as .o's own rotation
						# field, against a live region).
						placements.append({"type_id": entry.type_id, "position": entry.position, "rotation": entry.rotation})
						o2_count += 1

	if placements.is_empty():
		printerr("World3D: no real objects parsed from ", mapo_path)
		return

	var data_archive := _open_pk2_if_set()
	if data_archive == null:
		printerr("World3D: SRREVAMP_PK2_PATH not set -- can't resolve real object type IDs")
		return
	var idx_bytes := AssetSource.read_bytes(OBJECT_INDEX_PATH, data_archive)
	if idx_bytes.is_empty():
		printerr("World3D: could not find real object index at ", OBJECT_INDEX_PATH)
		return
	var table := ObjidxReader.parse(idx_bytes)
	if table == null:
		printerr("World3D: could not parse real object index at ", OBJECT_INDEX_PATH)
		return

	var container := Node3D.new()
	container.name = "RealMapObjects" + node_suffix

	# Real world-space alignment: SOLVED (2026-08-24) via a real, public,
	# non-reverse-engineered source -- JellyBitz's xSROMap
	# (https://github.com/JellyBitz/xSROMap), whose own real coordinate-
	# conversion JS confirms a region's local coordinates span exactly
	# [0, 1920) and a region ID packs as `(ySector << 8) | xSector` --
	# exactly the real REGION_SPAN (1920.0) and region-folder-name
	# convention ("98\168.m" = xSector 98, ySector 168) this project's own
	# region-streaming grid already uses for real terrain, confirming that
	# grid's math is really correct, not just internally consistent. So a
	# `.o` object's raw position is already real, absolute-within-its-
	# region data needing no artificial recentering -- it only needs the
	# exact same rotation+offset transform `_try_load_real_terrain` already
	# applies to that region's terrain (180-degree Y rotation + the
	# aabb.size.x/2 real-vertex anchor offset), so parenting this container
	# under that exact terrain node (found by its real, shared node-name
	# convention) inherits that transform automatically instead of
	# duplicating it. Falls back to the old world_offset-only placement if
	# that terrain node isn't loaded (e.g. a real `.o` with no matching
	# `.m`, or this function's own standalone/env-var call path where no
	# node_suffix was given) -- better than dropping the objects entirely.
	var terrain_node := get_node_or_null("RealTerrain" + node_suffix) if node_suffix != "" else null
	if terrain_node != null:
		terrain_node.add_child(container)
	else:
		container.position = world_offset
		add_child(container)

	var loaded := 0
	var skipped_unresolved := 0
	# A real region repeats the same handful of real object types across
	# dozens/hundreds of placements (see docs/PROGRESS.md -- a real 58-
	# object region had only 4 distinct types) -- load each distinct real
	# .bsr once and duplicate the built node for repeat placements, rather
	# than re-parsing the same real .bms/.bmt/.ddj chain per placement.
	var templates := {} # resolved .bsr path -> loaded template Node3D
	for placement in placements:
		if loaded >= MAX_MAP_OBJECTS:
			break
		var entry := table.lookup(placement["type_id"])
		if entry == null:
			skipped_unresolved += 1
			continue

		var node: Node3D
		if templates.has(entry.path):
			node = templates[entry.path].duplicate()
		else:
			var template := ObjectLoader.load_object(data_archive, entry.path)
			if template == null:
				continue
			templates[entry.path] = template
			node = template.duplicate()
		# Real, absolute-within-its-region position -- see this function's
		# own doc comment above (container placement) for how this is now
		# known correct rather than an artificial recentering.
		node.position = placement["position"]
		# Real yaw rotation -- see MapoReader.ObjectPlacement.rotation's doc
		# comment for how this was confirmed (decompiled cos/sin construction
		# plus a 100%-real-range empirical check against a live region).
		node.rotation.y = placement["rotation"]
		container.add_child(node)
		loaded += 1

	print("World3D: loaded %d/%d real map objects from %s (%d real .o + %d real .o2, %d unresolved type IDs skipped, %d distinct real models)" % [
		loaded, placements.size(), mapo_path, region.objects.size(), o2_count, skipped_unresolved, templates.size()])

## Resolves a real .bmt at bmt_path (via ObjectLoader, the same
## pk2 -> BmtReader -> DdjReader pipeline already verified for scenery) into
## a Dictionary keyed by each layer's own real layer_name -- ready to pass
## straight into CharacterAssembler.assemble/assemble_equipment's
## materials_by_name, which looks parts up by their own real material_name
## field (the two are the same string in real data -- see
## GENDER_ASSET_PATHS's doc comment, confirmed true for real equipment
## materials too, e.g. clothes_03.bmt's layers name-match
## clothes_03_*.bms's own material_name fields). Returns an empty
## Dictionary (not an error) if the .bmt isn't found at that path, since
## CharacterAssembler falls back to a flat/no color in that case.
func _load_real_materials(archive: Pk2Reader, bmt_path: String) -> Dictionary:
	var material := ObjectLoader.load_material(archive, bmt_path)
	if material == null:
		printerr("World3D: could not load material at ", bmt_path, " -- falling back to a flat color")
		return {}

	var by_name := {}
	for layer in material.layers:
		var godot_material := ObjectLoader.build_godot_material(archive, bmt_path, layer)
		if godot_material != null:
			by_name[layer.layer_name] = godot_material
	return by_name

func _physics_process(delta: float) -> void:
	var input_dir := Vector3.ZERO
	# Real, dedicated move_* actions (WASD + arrow keys both bound, see
	# project.godot) -- previously used Godot's built-in ui_left/ui_right/
	# ui_up/ui_down actions, which only bind arrow keys by default. That
	# silently left WASD non-functional in every real exported build (a
	# real playtest bug, 2026-08-26 -- see docs/WORLD_ISSUES.md) despite
	# every prior headless verification pass looking correct, since none
	# of those ever pressed a real W/A/S/D key.
	input_dir.x = Input.get_axis("move_left", "move_right")
	input_dir.z = Input.get_axis("move_forward", "move_back")
	var manual_input := input_dir.length() > 0.0
	if manual_input:
		input_dir = input_dir.normalized()
		_has_move_target = false # manual movement always cancels a pending click-to-move
		player.velocity.x = input_dir.x * MOVE_SPEED
		player.velocity.z = input_dir.z * MOVE_SPEED
	elif _has_move_target:
		var to_target := _move_target - player.position
		to_target.y = 0.0
		if to_target.length() <= MOVE_TARGET_STOP_DISTANCE:
			_has_move_target = false
			player.velocity.x = 0.0
			player.velocity.z = 0.0
		else:
			var dir := to_target.normalized()
			player.velocity.x = dir.x * MOVE_SPEED
			player.velocity.z = dir.z * MOVE_SPEED
			player.rotation.y = atan2(dir.x, dir.z)
	else:
		player.velocity.x = 0.0
		player.velocity.z = 0.0

	if not player.is_on_floor():
		player.velocity.y -= GRAVITY * delta
	else:
		player.velocity.y = 0.0
	player.move_and_slide()

	_maybe_stream_regions()

	_time_since_send += delta
	if _time_since_send >= MIN_SEND_INTERVAL and player.position.distance_to(_last_sent_pos) >= MIN_SEND_DISTANCE:
		NetClient.move_to(player.position.x, player.position.y, player.position.z)
		_last_sent_pos = player.position
		_time_since_send = 0.0

	if _real_skeleton != null and _real_skeleton_track.keyframes.size() > 1:
		_real_skeleton_time += delta
		var frame_count := _real_skeleton_track.keyframes.size()
		var frame_idx := int(_real_skeleton_time * BAN_FPS) % frame_count
		Skeleton3DBuilder.apply_ban_keyframe(_real_skeleton, _real_skeleton_track, frame_idx)
		Skeleton3DBuilder.update_debug_visualization(_real_skeleton.get_node("DebugVisualization"), _real_skeleton)

	# DISABLED (2026-08-26, see docs/WORLD_ISSUES.md) -- a real playtest found
	# the assembled player body's limbs fly wildly apart the instant this
	# runs, instead of playing a walk/idle cycle. Root-caused with real data:
	# apply_ban_pose (via Skeleton3DBuilder.apply_ban_pose) treats a .ban
	# track's own keyframe[0] rotation as if it equals the bone's rest
	# rotation the skeleton was built with (Skeleton3DBuilder.build_skeleton3d
	# uses Basis.IDENTITY for every bone's rest, per that function's own doc
	# comment -- a real .bsk file's own bind-pose rotation quaternion is
	# parsed but deliberately not used, since this project never confirmed it
	# composes the way Skeleton3D's rest hierarchy expects). Pulling a real
	# chinaman_skel.bsk and chinaman_fighter_standcity.ban and comparing the
	# two directly confirms they're NOT the same orientation for several real
	# bones -- e.g. "Bip01 R UpperArm"'s real .bsk bind quaternion is
	# [0.056,-0.017,-0.062,0.996] (near-identity) but the .ban's own
	# keyframe[0] for that same bone is [0.142,-0.015,0.534,0.834] (a
	# substantially different orientation, not a small idle sway). Treating
	# that mismatched keyframe[0] as the reference for a *delta* rotation
	# applies a wrong rotation outright, and that error compounds down the
	# kinematic chain (upper arm -> forearm -> hand), which is exactly why
	# the arms/hands were the most dramatically displaced in the real
	# screenshot, not the spine/pelvis. Properly fixing this needs
	# Skeleton3DBuilder to build each bone's *real* .bsk bind rotation into
	# its rest transform (not identity) and apply_ban_pose to compute deltas
	# against that real rest, not against the anim's own frame 0 -- a real
	# rework, not a one-line patch, so left disabled rather than shipping the
	# even-more-broken "limbs fly apart" result. The assembled body now stays
	# in its real (bind-pose, T-stance) pose, the same honest fallback this
	# code already used whenever idle_anim/walk_anim failed to load.

func _spawn_or_update_other(character_id: int, char_name: String, pos: Vector3, armor_slots_mask: int = 0, gender: String = DEFAULT_GENDER, has_weapon: bool = false, has_shield: bool = false) -> void:
	if _other_bodies.has(character_id):
		_other_bodies[character_id].position = pos
		return

	var body := Node3D.new()
	body.position = pos

	# Real assembled character if the shared assets loaded, using this
	# player's own real Gender (WorldNet.EntitySnapshot.gender, from the
	# server's live character-store lookup -- see genderOf in
	# server/internal/session/world.go) -- falls back to the labeled
	# placeholder capsule otherwise. Armor, weapon, and shield are real
	# too: all come straight from the server's live equipment-store lookup
	# (equippedSlots), the same real signal that already gates the local
	# player's own equipment -- armor_slots_mask is a real per-piece
	# bitmask (see EquipmentNet.ARMOR_SLOTS), not one all-or-nothing flag.
	var skeleton := _build_assembled_character(armor_slots_mask, gender, has_weapon, has_shield)
	if skeleton != null:
		body.add_child(skeleton)
	else:
		var mesh := MeshInstance3D.new()
		var capsule := CapsuleMesh.new()
		capsule.radius = 0.4
		capsule.height = 1.8
		mesh.mesh = capsule
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.9, 0.3, 0.3)
		mesh.material_override = mat
		mesh.position.y = 0.9
		body.add_child(mesh)

	var label := Label3D.new()
	label.text = char_name
	label.position.y = 2.2
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	body.add_child(label)

	other_entities.add_child(body)
	_other_bodies[character_id] = body

func _on_entity_entered(snapshot: WorldNet.EntitySnapshot) -> void:
	_spawn_or_update_other(snapshot.character_id, snapshot.char_name, Vector3(snapshot.x, snapshot.y, snapshot.z), snapshot.armor_slots_mask, snapshot.gender, snapshot.has_weapon, snapshot.has_shield)
	_log_system("%s entered the zone." % snapshot.char_name)

func _on_entity_moved(moved: WorldNet.EntityMoved) -> void:
	if _other_bodies.has(moved.character_id):
		_other_bodies[moved.character_id].position = Vector3(moved.x, moved.y, moved.z)

func _on_entity_left(character_id: int) -> void:
	if _other_bodies.has(character_id):
		var body: Node3D = _other_bodies[character_id]
		var departing_name := "Someone"
		for child in body.get_children():
			if child is Label3D:
				departing_name = child.text
				break
		body.queue_free()
		_other_bodies.erase(character_id)
		_log_system("%s left the zone." % departing_name)

func _on_disconnect_pressed() -> void:
	NetClient.disconnect_from_server()

## Sends a real OpChangeZone for whatever's typed in zone_input.
## _on_change_zone_result (connected in _ready()) handles the reply --
## success updates zone_label and reloads real terrain/objects for the new
## zone, failure is silently ignored here (no dedicated error UI for this
## yet, same honest scope as the rest of this scene's dev-facing controls).
func _on_change_zone_pressed() -> void:
	var zone := zone_input.text.strip_edges()
	if zone == "":
		return
	NetClient.change_zone(zone)

## Chat panel, ported from the 2D World.gd HUD (see docs/PROGRESS.md) --
## this scene is becoming the one real client, so its UI needs to cover
## everything the 2D view used to.
func _on_chat_message(message: ChatNet.Message) -> void:
	if message == null:
		return
	chat_log.add_text("%s: %s\n" % [message.sender_name, message.message_text])

func _on_chat_whisper_message(message: ChatNet.Message) -> void:
	if message == null:
		return
	chat_log.add_text("[%s whispers]: %s\n" % [message.sender_name, message.message_text])

func _log_system(text: String) -> void:
	chat_log.add_text("* %s\n" % text)

## Toggles the whole hideable UI panel (character/zone labels, chat, action
## tabs, etc.) -- see HideUIButton's own doc-free scene node and the
## "toggle_ui" (F10) input action wired in _unhandled_input. HideUIButton
## itself lives outside ui_control (a sibling under the UI CanvasLayer, not
## a child of Control) specifically so it stays clickable to toggle the UI
## back on even while everything else is hidden.
func _toggle_ui_visibility() -> void:
	ui_control.visible = not ui_control.visible
	hide_ui_button.text = "Show UI" if not ui_control.visible else "Hide UI"

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_ui"):
		_toggle_ui_visibility()

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_camera_orbiting = event.pressed
		elif event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_try_set_move_target(event.position)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			camera_arm.spring_length = clampf(camera_arm.spring_length - CAMERA_ZOOM_STEP, CAMERA_ZOOM_MIN, CAMERA_ZOOM_MAX)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			camera_arm.spring_length = clampf(camera_arm.spring_length + CAMERA_ZOOM_STEP, CAMERA_ZOOM_MIN, CAMERA_ZOOM_MAX)
	elif event is InputEventMouseMotion and _camera_orbiting:
		camera_arm.rotation_degrees.y -= event.relative.x * CAMERA_ORBIT_SENSITIVITY
		camera_arm.rotation_degrees.x = clampf(
			camera_arm.rotation_degrees.x - event.relative.y * CAMERA_ORBIT_SENSITIVITY,
			CAMERA_PITCH_MIN_DEGREES, CAMERA_PITCH_MAX_DEGREES)

## Real Silkroad-style click-to-move: raycasts from the camera through the
## real clicked screen position into the 3D world (real terrain/object
## collision -- both now real, solid bodies, see ObjectLoader's own real
## collision fix) and, on a hit, sets that as the player's real destination
## for _physics_process to walk toward every subsequent frame until reached
## or cancelled by manual WASD/arrow input.
func _try_set_move_target(screen_pos: Vector2) -> void:
	var from := camera_3d.project_ray_origin(screen_pos)
	var dir := camera_3d.project_ray_normal(screen_pos)
	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 2000.0)
	var hit := space_state.intersect_ray(query)
	if hit.is_empty():
		return
	_move_target = hit["position"]
	_has_move_target = true

func _on_send_pressed() -> void:
	var text := chat_input.text.strip_edges()
	if text.is_empty():
		return
	chat_input.text = ""

	if text.begins_with("/w "):
		var rest := text.substr(3)
		var space_index := rest.find(" ")
		if space_index == -1:
			_log_system("Usage: /w <name> <message>")
			return
		var target_name := rest.substr(0, space_index)
		var whisper_text := rest.substr(space_index + 1)
		NetClient.whisper(target_name, whisper_text)
		return

	NetClient.say(text)

func _on_disconnected() -> void:
	get_tree().change_scene_to_file("res://scenes/Login.tscn")

# --- Monsters tab ---------------------------------------------------------

## Raycasts straight down (and up, to cover terrain that loaded after this
## was called) through pos's X/Z and returns the real surface height found,
## or pos.y unchanged if nothing was hit -- the same practical safety net
## _snap_player_onto_terrain uses for the player, reused here so monsters
## don't spawn embedded in or floating above the real terrain grid either.
func _terrain_height_at(pos: Vector3) -> float:
	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		pos + Vector3(0.0, 1000.0, 0.0),
		pos + Vector3(0.0, -1000.0, 0.0))
	var hit := space_state.intersect_ray(query)
	if hit.is_empty():
		return pos.y
	return hit.position.y + 0.05

## Creates or moves the real 3D body representing one live server-tracked
## monster (see CombatNet.MonsterSnapshot's real X/Y/Z -- this project's own
## placeholder spawn positions, not real per-monster coordinate data; see
## combat.Hub.Spawn). A plain colored capsule for now, same honest
## "placeholder until a real per-species model mapping exists" approach
## World3D already uses for other players before a real character loads --
## no real monster model/skeleton mapping has been found or attempted yet
## (a real next step, not this one).
func _spawn_or_update_monster(monster: CombatNet.MonsterSnapshot) -> void:
	var pos := Vector3(monster.x, monster.y, monster.z)
	pos.y = _terrain_height_at(pos)

	if _monster_bodies.has(monster.monster_id):
		var existing: Node3D = _monster_bodies[monster.monster_id]
		existing.position = pos
		var existing_label: Label3D = existing.get_node("Label")
		existing_label.text = "%s (%d/%d)" % [monster.monster_name, monster.hp, monster.max_hp]
		return

	var body := Node3D.new()
	body.position = pos

	var mesh := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.5
	capsule.height = 1.6
	mesh.mesh = capsule
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.15, 0.1) # dark red -- visually distinct from other players' capsules
	mesh.material_override = mat
	mesh.position.y = 0.8
	body.add_child(mesh)

	var label := Label3D.new()
	label.name = "Label"
	label.text = "%s (%d/%d)" % [monster.monster_name, monster.hp, monster.max_hp]
	label.position.y = 2.0
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	body.add_child(label)

	other_entities.add_child(body)
	_monster_bodies[monster.monster_id] = body

## Reconciles _monster_bodies against live, the authoritative full monster
## list for the player's current zone (see _on_monster_list_result) --
## creates/updates a body for everything in live, removes any tracked body
## no longer present (dead, or the player changed zones), the same
## snapshot-driven approach world.Hub's own zone-change teardown uses rather
## than trying to diff individual damaged/died events.
func _sync_monster_bodies(live: Array) -> void:
	var live_ids := {}
	for m in live:
		live_ids[m.monster_id] = true
		_spawn_or_update_monster(m)

	for monster_id in _monster_bodies.keys():
		if not live_ids.has(monster_id):
			_monster_bodies[monster_id].queue_free()
			_monster_bodies.erase(monster_id)

func _on_monster_list_result(monsters: Array, error: String) -> void:
	if error != "":
		monster_status_label.text = "Error: %s" % error
		return
	_monsters.assign(monsters)
	monster_list.clear()
	for m in _monsters:
		monster_list.add_item("%s (HP %d/%d)" % [m.monster_name, m.hp, m.max_hp])
	_sync_monster_bodies(_monsters)

func _on_attack_pressed() -> void:
	var selected := monster_list.get_selected_items()
	if selected.is_empty():
		monster_status_label.text = "Select a monster first."
		return
	var target: CombatNet.MonsterSnapshot = _monsters[selected[0]]
	NetClient.attack(NetClient.current_character_name, target.monster_id)

func _on_attack_result(result: CombatNet.AttackResult) -> void:
	if result == null:
		return
	if result.error != "":
		monster_status_label.text = "Attack failed: %s" % result.error
		return
	if result.monster_died:
		monster_status_label.text = "Hit for %d -- it died!" % result.monster_damage
		# A kill may have progressed a quest's kill count even without
		# completing it (OpQuestCompleted only fires on completion), so
		# refresh here rather than only on _on_quest_completed.
		NetClient.list_quests(NetClient.current_character_name)
	else:
		monster_status_label.text = "Hit for %d (%d HP left). Took %d damage (HP %d)." % [
			result.monster_damage, result.monster_remaining_hp, result.player_damage_taken, result.player_hp
		]
	NetClient.list_monsters()
	# OpUseSkill's response reuses this same OpAttackResult (see
	# SkillNet's doc comment) -- refresh here too so a just-used skill's
	# updated cooldown shows up in the Skills tab. Harmless no-op extra
	# traffic for a plain (non-skill) attack, same tradeoff the quest
	# refresh above already makes.
	NetClient.list_skills(NetClient.current_character_name)

func _on_monster_damaged(_damaged: CombatNet.MonsterDamaged) -> void:
	NetClient.list_monsters()

func _on_monster_died(_monster_id: int) -> void:
	NetClient.list_monsters()

func _on_loot_dropped(dropped: CombatNet.LootDropped) -> void:
	if dropped == null:
		return
	for d in dropped.drops:
		_log_system("Looted %dx item #%d." % [d.quantity, d.item_id])
	NetClient.list_inventory(NetClient.current_character_name)

# --- Inventory tab ---------------------------------------------------------

func _on_inventory_list_result(slots: Array, error: String) -> void:
	if error != "":
		inventory_status_label.text = "Error: %s" % error
		return
	_inventory_slots.assign(slots)
	inventory_list.clear()
	for s in _inventory_slots:
		inventory_list.add_item("Slot %d: item #%d x%d" % [s.slot_index, s.item_id, s.quantity])

func _on_equip_pressed(slot: int) -> void:
	var selected := inventory_list.get_selected_items()
	if selected.is_empty():
		inventory_status_label.text = "Select an item first."
		return
	var chosen: InventoryNet.Slot = _inventory_slots[selected[0]]
	_awaiting_equip_ack = true
	NetClient.equip(NetClient.current_character_name, slot, chosen.slot_index)

# --- Equipment tab ---------------------------------------------------------

func _on_equipment_result(items: Array, error: String) -> void:
	if error != "":
		equipment_status_label.text = "Error: %s" % error
		_awaiting_equip_ack = false
		return

	if _awaiting_equip_ack:
		# This empty-items response is the equip/unequip ack, not a real
		# "nothing equipped" list -- re-request the real list, and refresh
		# inventory since equip/unequip moves an item between the two.
		_awaiting_equip_ack = false
		equipment_status_label.text = "Equipment updated."
		NetClient.list_equipment(NetClient.current_character_name)
		NetClient.list_inventory(NetClient.current_character_name)
		return

	equipment_list.clear()
	for e in items:
		var slot_name: String = "Weapon" if e.slot == EquipmentNet.SLOT_WEAPON else ARMOR_SLOT_LABELS.get(e.slot, "Slot %d" % e.slot)
		equipment_list.add_item("%s: item #%d" % [slot_name, e.item_id])

func _on_unequip_pressed(slot: int) -> void:
	_awaiting_equip_ack = true
	NetClient.unequip(NetClient.current_character_name, slot)

# --- Quests tab --------------------------------------------------------

func _on_quest_list_result(entries: Array, error: String) -> void:
	if error != "":
		quest_status_label.text = "Error: %s" % error
		return
	_quests.assign(entries)
	quest_list.clear()
	for q in _quests:
		var state := "completed" if q.completed else ("accepted" if q.accepted else "available")
		quest_list.add_item("%s: kill %s (%d/%d) for %dg [%s]" % [
			q.quest_name, q.monster_name, q.kills, q.target_kills, q.gold_reward, state
		])

func _on_quest_accept_pressed() -> void:
	var selected := quest_list.get_selected_items()
	if selected.is_empty():
		quest_status_label.text = "Select a quest first."
		return
	var chosen: QuestNet.Entry = _quests[selected[0]]
	NetClient.accept_quest(NetClient.current_character_name, chosen.quest_id)

func _on_quest_accept_result(ok: bool, reason: String) -> void:
	quest_status_label.text = "Quest accepted." if ok else "Accept failed: %s" % reason
	NetClient.list_quests(NetClient.current_character_name)

func _on_quest_completed(completed: QuestNet.Completed) -> void:
	if completed == null:
		return
	_log_system("Quest complete! +%dg" % completed.gold_reward)
	NetClient.list_quests(NetClient.current_character_name)

# --- Skills tab ------------------------------------------------------------

func _on_skill_list_result(skills: Array, error: String) -> void:
	if error != "":
		skill_status_label.text = "Error: %s" % error
		return
	_skills.assign(skills)
	skill_list.clear()
	for s in _skills:
		var state: String
		if not s.known:
			state = "not learned"
		elif s.ready_seconds > 0:
			state = "cooldown %ds" % s.ready_seconds
		else:
			state = "ready"
		skill_list.add_item("%s (+%d dmg, %ds cooldown) [%s]" % [s.skill_name, s.damage_bonus, s.cooldown_seconds, state])

func _on_skill_learn_pressed() -> void:
	var selected := skill_list.get_selected_items()
	if selected.is_empty():
		skill_status_label.text = "Select a skill first."
		return
	var chosen: SkillNet.SkillSnapshot = _skills[selected[0]]
	NetClient.learn_skill(NetClient.current_character_name, chosen.skill_id)

func _on_learn_skill_result(ok: bool, reason: String) -> void:
	skill_status_label.text = "Skill learned." if ok else "Learn failed: %s" % reason
	NetClient.list_skills(NetClient.current_character_name)

## Uses the selected skill on whichever monster is currently selected in the
## Monsters tab -- reuses that tab's own selection/target list rather than
## duplicating a second monster picker just for skills.
func _on_skill_use_pressed() -> void:
	var selected := skill_list.get_selected_items()
	if selected.is_empty():
		skill_status_label.text = "Select a skill first."
		return
	var target_selected := monster_list.get_selected_items()
	if target_selected.is_empty():
		skill_status_label.text = "Select a target in the Monsters tab first."
		return
	var chosen: SkillNet.SkillSnapshot = _skills[selected[0]]
	var target: CombatNet.MonsterSnapshot = _monsters[target_selected[0]]
	NetClient.use_skill(NetClient.current_character_name, chosen.skill_id, target.monster_id)

# --- Shop tab ------------------------------------------------------------

func _on_shop_list_result(entries: Array, error: String) -> void:
	if error != "":
		shop_status_label.text = "Error: %s" % error
		return
	_shop_entries.assign(entries)
	shop_list.clear()
	for e in _shop_entries:
		shop_list.add_item("Item #%d (class %d, atk %.1f/def %.1f) -- %dg" % [
			e.item_id, e.item_class, e.phys_attack_max, e.phys_defense_max, e.price
		])

func _on_shop_buy_pressed() -> void:
	var selected := shop_list.get_selected_items()
	if selected.is_empty():
		shop_status_label.text = "Select an item first."
		return
	var chosen: ShopNet.CatalogEntry = _shop_entries[selected[0]]
	NetClient.shop_buy(NetClient.current_character_name, chosen.item_id, 1)

func _on_shop_buy_result(ok: bool, reason: String) -> void:
	shop_status_label.text = "Purchased." if ok else "Purchase failed: %s" % reason
	if ok:
		NetClient.list_inventory(NetClient.current_character_name)

# --- Party tab -------------------------------------------------------------

func _refresh_party_list(result: PartyNet.Result) -> void:
	party_list.clear()
	for m in result.members:
		party_list.add_item(m.member_name)

func _on_party_result(result: PartyNet.Result) -> void:
	if result == null:
		return
	if result.error != "":
		party_status_label.text = "Error: %s" % result.error
		return
	if result.party_id == 0:
		party_status_label.text = "Not in a party."
		party_list.clear()
		return
	party_status_label.text = "Party #%d (%d member(s))." % [result.party_id, result.members.size()]
	_refresh_party_list(result)

func _on_party_join_pressed() -> void:
	var id_text := party_join_id_input.text.strip_edges()
	if not id_text.is_valid_int():
		party_status_label.text = "Enter a numeric party ID."
		return
	NetClient.join_party(NetClient.current_character_name, id_text.to_int())

func _on_party_leave_result(ok: bool, reason: String) -> void:
	if ok:
		party_status_label.text = "Left the party."
		party_list.clear()
	else:
		party_status_label.text = "Leave failed: %s" % reason

func _on_party_member_joined(member: PartyNet.MemberJoined) -> void:
	if member == null:
		return
	_log_system("%s joined your party." % member.member_name)
	NetClient.party_info(NetClient.current_character_name)

func _on_party_member_left(character_id: int) -> void:
	_log_system("A party member left (character #%d)." % character_id)
	NetClient.party_info(NetClient.current_character_name)

# --- Guild tab -------------------------------------------------------------

func _refresh_guild_list(result: GuildNet.Result) -> void:
	guild_list.clear()
	for m in result.members:
		var role_name := "Leader" if m.role == GuildNet.ROLE_LEADER else "Member"
		guild_list.add_item("%s [%s]" % [m.member_name, role_name])

func _on_guild_result(result: GuildNet.Result) -> void:
	if result == null:
		return
	if result.error != "":
		guild_status_label.text = "Error: %s" % result.error
		return
	if result.guild_id == 0:
		guild_status_label.text = "Not in a guild."
		guild_list.clear()
		return
	guild_status_label.text = "%s (#%d, %d member(s))." % [result.guild_name, result.guild_id, result.members.size()]
	_refresh_guild_list(result)

func _on_guild_create_pressed() -> void:
	var guild_name := guild_name_input.text.strip_edges()
	if guild_name.is_empty():
		guild_status_label.text = "Enter a guild name first."
		return
	NetClient.create_guild(NetClient.current_character_name, guild_name)

func _on_guild_join_pressed() -> void:
	var id_text := guild_join_id_input.text.strip_edges()
	if not id_text.is_valid_int():
		guild_status_label.text = "Enter a numeric guild ID."
		return
	NetClient.join_guild(NetClient.current_character_name, id_text.to_int())

func _on_guild_leave_result(ok: bool, reason: String) -> void:
	if ok:
		guild_status_label.text = "Left the guild."
		guild_list.clear()
	else:
		guild_status_label.text = "Leave failed: %s" % reason

# --- Duel tab --------------------------------------------------------------

func _on_duel_challenge_pressed() -> void:
	var target := duel_target_input.text.strip_edges()
	if target.is_empty():
		duel_status_label.text = "Enter a target name first."
		return
	NetClient.duel_challenge(NetClient.current_character_name, target)

func _on_duel_challenge_result(ok: bool, reason: String) -> void:
	duel_status_label.text = "Challenge sent." if ok else "Challenge failed: %s" % reason

func _on_duel_invite(invite: DuelNet.Invite) -> void:
	if invite == null:
		return
	_pending_duel_challenger = invite.challenger_name
	duel_invite_label.text = "%s challenges you to a duel!" % invite.challenger_name

func _on_duel_respond_pressed(accept: bool) -> void:
	if _pending_duel_challenger.is_empty():
		duel_status_label.text = "No pending challenge to respond to."
		return
	NetClient.duel_respond(NetClient.current_character_name, _pending_duel_challenger, accept)
	_pending_duel_challenger = ""
	duel_invite_label.text = "(no pending challenge)"

func _on_duel_respond_result(ok: bool, reason: String) -> void:
	if not ok:
		duel_status_label.text = "Respond failed: %s" % reason

func _on_duel_started(started: DuelNet.Started) -> void:
	if started == null:
		return
	duel_status_label.text = "Dueling %s! Attack away." % started.opponent_name

func _on_duel_declined(declined: DuelNet.Declined) -> void:
	if declined == null:
		return
	duel_status_label.text = "%s declined your challenge." % declined.target_name

func _on_duel_attack_result(result: DuelNet.AttackResult) -> void:
	if result == null:
		return
	if result.error != "":
		duel_status_label.text = "Attack failed: %s" % result.error
		return
	if result.opponent_died:
		duel_status_label.text = "Hit for %d -- you won!" % result.damage
	else:
		duel_status_label.text = "Hit for %d (opponent HP %d)." % [result.damage, result.opponent_hp]

func _on_duel_opponent_damaged(damaged: DuelNet.OpponentDamaged) -> void:
	if damaged == null:
		return
	duel_status_label.text = "Took %d damage (HP %d)." % [damaged.damage, damaged.remaining_hp]

func _on_duel_ended(ended: DuelNet.Ended) -> void:
	if ended == null:
		return
	duel_status_label.text = "Duel over -- %s won." % ended.winner_name

# --- Trade tab ---------------------------------------------------------

func _on_trade_request_pressed() -> void:
	var target := trade_target_input.text.strip_edges()
	if target.is_empty():
		trade_status_label.text = "Enter a target name first."
		return
	NetClient.trade_request(NetClient.current_character_name, target)

func _on_trade_request_result(ok: bool, reason: String) -> void:
	trade_status_label.text = "Trade request sent." if ok else "Request failed: %s" % reason

func _on_trade_invite(invite: TradeNet.Invite) -> void:
	if invite == null:
		return
	_pending_trade_requester = invite.requester_name
	trade_invite_label.text = "%s wants to trade with you!" % invite.requester_name

func _on_trade_respond_pressed(accept: bool) -> void:
	if _pending_trade_requester.is_empty():
		trade_status_label.text = "No pending request to respond to."
		return
	NetClient.trade_respond(NetClient.current_character_name, _pending_trade_requester, accept)
	_pending_trade_requester = ""
	trade_invite_label.text = "(no pending request)"

func _on_trade_respond_result(ok: bool, reason: String) -> void:
	if not ok:
		trade_status_label.text = "Respond failed: %s" % reason

func _on_trade_started(started: TradeNet.Started) -> void:
	if started == null:
		return
	trade_status_label.text = "Trading with %s. Set your offer below." % started.partner_name
	trade_their_offer_label.text = "Their offer: (none yet)"

func _on_trade_declined(declined: TradeNet.Declined) -> void:
	if declined == null:
		return
	trade_status_label.text = "%s declined your trade request." % declined.target_name

func _on_trade_set_offer_pressed() -> void:
	var gold_text := trade_gold_input.text.strip_edges()
	var slot_text := trade_item_slot_input.text.strip_edges()
	var qty_text := trade_quantity_input.text.strip_edges()
	var gold := int(gold_text) if gold_text.is_valid_int() else 0
	var item_slot := int(slot_text) if slot_text.is_valid_int() else TradeNet.ITEM_SLOT_NONE
	var quantity := int(qty_text) if qty_text.is_valid_int() else 0
	NetClient.trade_set_offer(NetClient.current_character_name, gold, item_slot, quantity)

func _on_trade_offer_result(ok: bool, reason: String) -> void:
	if not ok:
		trade_status_label.text = "Offer failed: %s" % reason

func _on_trade_confirm_result(ok: bool, reason: String) -> void:
	trade_status_label.text = "Confirmed. Waiting on the other side." if ok else "Confirm failed: %s" % reason

func _on_trade_offer_updated(updated: TradeNet.OfferUpdated) -> void:
	if updated == null:
		return
	var item_desc := "no item" if updated.offer.item_slot < 0 else "slot %d x%d" % [updated.offer.item_slot, updated.offer.quantity]
	trade_their_offer_label.text = "Their offer: %dg, %s" % [updated.offer.gold, item_desc]

func _on_trade_completed(completed: TradeNet.Completed) -> void:
	if completed == null:
		return
	_log_system("Trade complete! Received %dg%s" % [
		completed.received_gold,
		(" and %dx item #%d" % [completed.received_quantity, completed.received_item_id]) if completed.received_item_id != 0 else ""
	])
	NetClient.list_inventory(NetClient.current_character_name)

func _on_trade_cancelled(cancelled: TradeNet.Cancelled) -> void:
	if cancelled == null:
		return
	var by_whom := cancelled.cancelled_by_name if cancelled.cancelled_by_name != "" else "the system"
	trade_status_label.text = "Trade cancelled by %s." % by_whom
	trade_their_offer_label.text = "Their offer: (none yet)"

# --- Friends tab -----------------------------------------------------------

func _refresh_friends() -> void:
	NetClient.friend_list(NetClient.current_character_name)
	NetClient.friend_pending_list(NetClient.current_character_name)

func _on_friend_request_pressed() -> void:
	var target := friend_target_input.text.strip_edges()
	if target.is_empty():
		friend_status_label.text = "Enter a target name first."
		return
	NetClient.friend_request(NetClient.current_character_name, target)

func _on_friend_request_result(ok: bool, reason: String) -> void:
	friend_status_label.text = "Request sent." if ok else "Request failed: %s" % reason

func _on_friend_request_received(received: FriendNet.RequestReceived) -> void:
	if received == null:
		return
	_log_system("%s sent you a friend request." % received.requester_name)
	_refresh_friends()

func _on_friend_accept_pressed() -> void:
	var selected := friend_pending_list.get_selected_items()
	if selected.is_empty():
		friend_status_label.text = "Select a pending request first."
		return
	var chosen: FriendNet.PendingRequest = _pending_friend_requests[selected[0]]
	NetClient.friend_accept(NetClient.current_character_name, chosen.requester_id)

func _on_friend_accept_result(ok: bool, reason: String) -> void:
	friend_status_label.text = "Friend added." if ok else "Accept failed: %s" % reason
	if ok:
		_refresh_friends()

func _on_friend_accepted(accepted: FriendNet.Accepted) -> void:
	if accepted == null:
		return
	_log_system("%s accepted your friend request." % accepted.accepter_name)
	_refresh_friends()

func _on_friend_decline_pressed() -> void:
	var selected := friend_pending_list.get_selected_items()
	if selected.is_empty():
		friend_status_label.text = "Select a pending request first."
		return
	var chosen: FriendNet.PendingRequest = _pending_friend_requests[selected[0]]
	NetClient.friend_decline(NetClient.current_character_name, chosen.requester_id)

func _on_friend_decline_result(ok: bool, reason: String) -> void:
	friend_status_label.text = "Declined." if ok else "Decline failed: %s" % reason
	if ok:
		_refresh_friends()

func _on_friend_list_result(friends: Array, error: String) -> void:
	if error != "":
		friend_status_label.text = "Error: %s" % error
		return
	_friends.assign(friends)
	friend_list.clear()
	for f in _friends:
		friend_list.add_item("%s [%s]" % [f.friend_name, "online" if f.online else "offline"])

func _on_friend_remove_pressed() -> void:
	var selected := friend_list.get_selected_items()
	if selected.is_empty():
		friend_status_label.text = "Select a friend first."
		return
	var chosen: FriendNet.FriendEntry = _friends[selected[0]]
	NetClient.friend_remove(NetClient.current_character_name, chosen.character_id)

func _on_friend_remove_result(ok: bool, reason: String) -> void:
	friend_status_label.text = "Removed." if ok else "Remove failed: %s" % reason
	if ok:
		_refresh_friends()

func _on_friend_pending_list_result(requests: Array, error: String) -> void:
	if error != "":
		return
	_pending_friend_requests.assign(requests)
	friend_pending_list.clear()
	for r in _pending_friend_requests:
		friend_pending_list.add_item(r.requester_name)
