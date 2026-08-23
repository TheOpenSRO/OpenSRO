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
## already describe. A zone not shaped that way (e.g. the default spawn
## zone, "jangan") just clears back to the placeholder ground with nothing
## loaded -- honest "nothing to load", not a guessed path. The *initial*
## load in _ready() still reads the raw env vars directly rather than going
## through a zone label, since the very first EnterWorldResult doesn't
## necessarily carry a region-shaped zone (again, "jangan" by default).

const MOVE_SPEED := 6.0
const GRAVITY := 20.0
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
## How many real *placements* from SRREVAMP_MAPO_PATH's region to
## instantiate -- an arbitrary, honestly-scoped cap, not a real engine
## limit. Distinct real .bsr models are only parsed once each and
## duplicated for repeat placements (see _try_load_real_map_objects), so
## this mostly bounds real node/instance count, not real file parsing.
const MAX_MAP_OBJECTS := 300

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
## direction -- radius 1 means a 3x3 grid (9 regions attempted, however many
## actually exist as real files). Kept small since each region is a real
## parse + mesh build; raise once real perf headroom is confirmed.
const REGION_LOAD_RADIUS := 1

@onready var player: CharacterBody3D = $Player
@onready var player_mesh: MeshInstance3D = $Player/Mesh
@onready var ground_mesh: MeshInstance3D = $Ground/Mesh
@onready var ground_collision: CollisionShape3D = $Ground/Collision
@onready var other_entities: Node3D = $OtherEntities
@onready var zone_label: Label = $UI/Control/ZoneLabel
@onready var character_label: Label = $UI/Control/CharacterLabel
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
	var pk2_path := OS.get_environment("SRREVAMP_PK2_PATH")
	var bsr_path := OS.get_environment("SRREVAMP_BSR_PATH")
	if pk2_path == "" or bsr_path == "":
		print("World3D: SRREVAMP_PK2_PATH/SRREVAMP_BSR_PATH not set -- no real scenery loaded")
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

## Opens SRREVAMP_PK2_PATH if it's set, or returns null if it's unset or
## fails to open. Used so AssetSource can fall back to an in-archive path
## for any of the loose-file-shaped environment variables.
func _open_pk2_if_set() -> Pk2Reader:
	var pk2_path := OS.get_environment("SRREVAMP_PK2_PATH")
	if pk2_path == "":
		return null
	return Pk2Reader.open(pk2_path)

## Opens SRREVAMP_MAP_PK2_PATH if it's set, or returns null if it's unset or
## fails to open. Map.pk2 is a separate archive from SRREVAMP_PK2_PATH's
## Data.pk2 in a real retail install (confirmed from the user's own real
## client file listing: Data.pk2, Media.pk2, Map.pk2, Particles.pk2 are all
## separate files) -- so terrain gets its own pk2 env var rather than
## reusing SRREVAMP_PK2_PATH.
func _open_map_pk2_if_set() -> Pk2Reader:
	var map_pk2_path := OS.get_environment("SRREVAMP_MAP_PK2_PATH")
	if map_pk2_path == "":
		return null
	return Pk2Reader.open(map_pk2_path)

## Opens SRREVAMP_MEDIA_PK2_PATH if it's set, or returns null if it's unset
## or fails to open. A real client's per-map-region minimap image (see
## SRREVAMP_MAPM_TEXTURE_PATH below) lives in Media.pk2, a third separate
## archive from both Data.pk2 and Map.pk2 in a real retail install.
func _open_media_pk2_if_set() -> Pk2Reader:
	var media_pk2_path := OS.get_environment("SRREVAMP_MEDIA_PK2_PATH")
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

## Splits a zone label shaped like this project's real Map.pk2 region
## naming (an (x, y) folder/filename pair -- see docs/protocol/
## MAPM_FORMAT.md/MAPO_FORMAT.md, e.g. "100/100", "102/101") into the real
## internal paths those regions live at. Returns {} for anything not shaped
## "<x>/<y>" with both parts non-empty -- e.g. the default spawn zone
## ("jangan") isn't a real region coordinate, so this deliberately doesn't
## guess a path for it.
static func _zone_paths(zone: String) -> Dictionary:
	var parts := zone.split("/")
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
## REGION_SPAN as the grid spacing -- this project's own design for how
## multiple real regions fit together (see REGION_SPAN's doc comment: real
## per-region world scale/adjacency isn't confirmed, so this is walkable
## scaffolding, not a claim about the real game's true spatial layout).
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

	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if dx == 0 and dy == 0:
				continue # center cell already loaded above
			var region_x := center_x + dx
			var region_y := center_y + dy
			var suffix := "_%d_%d" % [region_x, region_y]
			var offset := Vector3(dx * REGION_SPAN, 0.0, dy * REGION_SPAN)
			_try_load_real_terrain("%d\\%d.m" % [region_x, region_y], "", offset, suffix, false, center_near_height)
			_try_load_real_map_objects("%d\\%d.o" % [region_x, region_y], offset, suffix)

## _ready()'s own entry point into the region grid: reads SRREVAMP_MAPM_PATH
## the same way this scene always has, but now treats it as the *center* of
## a real multi-region neighborhood (see _load_region_neighborhood) instead
## of the one and only region loaded. Falls back to the original
## single-region behavior for a path that isn't shaped like a real region
## coordinate (e.g. a loose dev file with no real (x, y) meaning).
func _load_initial_region_neighborhood() -> void:
	var mapm_path := OS.get_environment("SRREVAMP_MAPM_PATH")
	if mapm_path == "":
		print("World3D: SRREVAMP_MAPM_PATH not set -- ground stays a placeholder")
		return
	var coords := _parse_region_coords(mapm_path)
	if coords.is_empty():
		_try_load_real_terrain()
		_try_load_real_map_objects()
		return
	_load_region_neighborhood(coords["x"], coords["y"], REGION_LOAD_RADIUS, OS.get_environment("SRREVAMP_MAPM_TEXTURE_PATH"))

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

	var coords := _parse_region_coords(zone)
	if coords.is_empty():
		print("World3D: zone %s isn't shaped like a real region (x/y) -- no per-zone assets to load" % zone)
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

	# Real, fully deterministic full-region assembly (2026-08-23) -- see
	# MapmTerrainBuilder.build_full_region_mesh's doc comment and
	# MAPM_FORMAT.md. MapmReader now parses a region's real, confirmed 6x6
	# block grid directly (no more row/column guessing), so this always
	# produces the complete real 97x97 mesh on a successful parse.
	var terrain_mesh := MapmTerrainBuilder.build_full_region_mesh(region)
	if terrain_mesh == null:
		printerr("World3D: parsed ", region.blocks.size(), " real blocks from ", mapm_path, " but couldn't build a mesh from them")
		return NAN

	var terrain_group := Node3D.new()
	terrain_group.name = "RealTerrain" + node_suffix

	var mat := StandardMaterial3D.new()
	var real_texture := _load_real_terrain_texture(texture_override)
	var aabb := terrain_mesh.get_aabb()
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
	# Real .t lightmap, applied as ambient occlusion -- see
	# _load_real_terrain_lightmap's doc comment and
	# docs/protocol/MAPT_FORMAT.md. Corrects an earlier same-day attempt
	# that decoded the wrong bytes entirely (before .t's real structure --
	# a ShadowMap plus a properly-headered embedded DDS -- was found via
	# public documentation) and applied the result as direct detail-albedo
	# color, which looked like broken color-noise static and was reverted.
	# The real embedded texture is a genuine grayscale shadow map (white =
	# fully lit), which Godot's ao_texture consumes directly with no
	# custom shader needed. Uses the mesh's own UV1 (ao_on_uv2 defaults to
	# false), same channel the albedo/detail textures above use.
	var lightmap := _load_real_terrain_lightmap(mapm_path, archive)
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
	var near_arrays := terrain_mesh.surface_get_arrays(0)
	var near_positions: PackedVector3Array = near_arrays[Mesh.ARRAY_VERTEX]
	var near_height := near_positions[MapmTerrainBuilder.GRID_WIDTH / 2].y
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
			printerr("World3D: could not find %s skeleton at %s in %s" % [gender, paths["skeleton"], OS.get_environment("SRREVAMP_PK2_PATH")])
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
			gender, skel.bones.size(), parts.size(), equipment_sets.size(), idle_anim != null, walk_anim != null, OS.get_environment("SRREVAMP_PK2_PATH")])

	for variant in WEAPON_VARIANTS:
		var weapon_bytes := AssetSource.read_bytes(variant["mesh"], archive)
		if weapon_bytes.is_empty():
			continue
		var weapon_mesh := BmsReader.parse(weapon_bytes)
		if weapon_mesh == null:
			continue
		_weapon_variants.append({"mesh": weapon_mesh, "materials": _load_real_materials(archive, variant["material"])})
	print("World3D: cached %d/%d real weapon variants from %s" % [_weapon_variants.size(), WEAPON_VARIANTS.size(), OS.get_environment("SRREVAMP_PK2_PATH")])

	for variant in SHIELD_VARIANTS:
		var shield_bytes := AssetSource.read_bytes(variant["mesh"], archive)
		if shield_bytes.is_empty():
			continue
		var shield_mesh := BmsReader.parse(shield_bytes)
		if shield_mesh == null:
			continue
		_shield_variants.append({"mesh": shield_mesh, "materials": _load_real_materials(archive, variant["material"])})
	print("World3D: cached %d/%d real shield variants from %s" % [_shield_variants.size(), SHIELD_VARIANTS.size(), OS.get_environment("SRREVAMP_PK2_PATH")])

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
		placements.append({"type_id": obj.type_id, "position": obj.position})
	var mapo2_path := mapo_path + "2"
	var mapo2_bytes := AssetSource.read_bytes(mapo2_path, map_archive)
	var o2_count := 0
	if not mapo2_bytes.is_empty():
		var region2 := MapO2Reader.parse(mapo2_bytes)
		if region2 != null:
			for sector in region2.sectors:
				for list in sector.lists:
					for entry in list:
						placements.append({"type_id": entry.type_id, "position": entry.position})
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
	container.position = world_offset
	add_child(container)

	# Real world-space alignment with the player's own spawn position isn't
	# confirmed (same honest caveat as terrain/scenery elsewhere in this
	# file) -- cluster real objects relative to the region's own first
	# placement and offset that cluster near the player for visibility,
	# rather than trusting the raw absolute coordinates to land near
	# wherever the player happens to spawn.
	var origin: Vector3 = placements[0]["position"]
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
		# Placed further out than the single-scenery-object offset above --
		# a real region's real objects can cluster tightly around their
		# own real relative positions (see docs/PROGRESS.md), so centering
		# the cluster at the same close distance as one lone object left
		# the player standing in the middle of it rather than able to see
		# it as a recognizable cluster.
		var pos: Vector3 = placement["position"]
		node.position = (pos - origin) + Vector3(20, 0, -30)
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
	input_dir.x = Input.get_axis("ui_left", "ui_right")
	input_dir.z = Input.get_axis("ui_up", "ui_down")
	if input_dir.length() > 0.0:
		input_dir = input_dir.normalized()

	player.velocity.x = input_dir.x * MOVE_SPEED
	player.velocity.z = input_dir.z * MOVE_SPEED
	if not player.is_on_floor():
		player.velocity.y -= GRAVITY * delta
	else:
		player.velocity.y = 0.0
	player.move_and_slide()

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

	# Real per-frame walk-cycle playback for the player's own assembled body
	# (see GENDER_ASSET_PATHS' idle_anim/walk_anim doc comment) -- picks
	# whichever of the two real clips matches whether input_dir is
	# non-zero this frame, and loops it by real frame count rather than a
	# fixed guessed duration. No-op if the shared character assets never
	# loaded (SRREVAMP_PK2_PATH unset, or this gender's animations weren't
	# found in the archive) -- the assembled body stays in its real bind
	# pose in that case, same as before this existed.
	if _player_skeleton != null:
		var assets: Dictionary = _character_assets.get(_player_gender, {})
		var anim: BanReader.ParsedAnimation = assets.get("walk_anim") if input_dir.length() > 0.0 else assets.get("idle_anim")
		if anim != null and not anim.bones.is_empty():
			_player_anim_time += delta
			var frame_count: int = anim.bones[0].keyframes.size()
			if frame_count > 1:
				var frame_idx := int(_player_anim_time * BAN_FPS) % frame_count
				Skeleton3DBuilder.apply_ban_pose(_player_skeleton, anim, frame_idx)

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
