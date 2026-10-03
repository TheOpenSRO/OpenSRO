extends RefCounted
class_name VideoOptions

## The Option window's Video tab, as data (round 694): what the original
## offers, the original's own presets, and what this client keeps between
## runs. OptionWindow edits a copy; World3D applies one (apply_to_world).
## Labels: **READ** (sro_client.exe; addresses below), **MEASURED**, **INFERRED**,
## **OURS**. docs/protocol/OPTION_VIDEO.md has the whole record.
##
## **The page (READ, CNIFOption's video page builder 0x5fef70).** Fifteen
## combo rows, entry 0..13 and 15 (14 is never listed: 0x5fef70's slot loop
## steps over it), each a label and a tooltip from the text table
## and its choices:
##   0 Graphic Quality   Low / Middle / High / Large scale battle / User control
##   1 Shadow Detail     Nothing / Circle / Detail
##   2 Background Sight Range  1..5      3 Character Sight Range  1..5
##   4 Water Reflection  Off / On        5 Water Detail  Low / Middle / High
##   6 Metallic Sheen    Off / On        7 Light Effect  Off / On
##   8 Texture Filtering Off / On        9 Texture Detail  Low / Middle / High
##  10 Lens Flare        Off / On       11 Bloom Effect  Off / On
##  12 Dynamic Animation Off / On       13 Effect Quality  Turn Off All Effects /
##                                         See Hit Effects / See All Effects
##  15 Display Friendly/Enemy  Friend/Enemy Dress / General
## Above them: Resolution (every adapter mode at least 800x600 in a 24/32-bit
## format, "%d x %d"), Set Brightness (Very Dark / Dark / Normal / Light /
## Very bright), Window Mode (Full screen / Window screen) and View (Free
## Movement / Third Person / Quarter Angle). Two sub-tabs, Graphic 1 and
## Graphic 2, are two whole records of these values; the one shown when
## Apply is pressed is the one used (NIFOption 0x5fd5f0 switches records,
## SROptionSet.dat tag 9999 keeps which).
##
## **The presets (READ, 0x5015a0).** Choosing a Graphic Quality fills every
## row from its table (PRESETS); "User control" puts back the player's own
## values (the record's second copy). After loading the file the client
## re-applies the preset of every record whose quality is not User
## (0x502680's tail, 0x503180..0x503192), so only User keeps hand-set rows.
##
## **The original's default (READ):** the record constructor (0x5f75e0) and
## the Default button (0x5fc340 on the video tab) both choose Middle, Normal
## brightness; the constructor 1024x768. Middle turns Bloom, Lens Flare,
## Filtering and Metallic Sheen ON and Water Reflection OFF. (So the shipped
## shipped SROptionSet.dat's record 0 is Middle, and the loader re-applies
## Middle's preset. Tag i holds entry i (jump table 0x5031ac): its tag 4,
## Water Reflection, is 0; the tag 5 = 1 round 628 read as the reflection is
## Water Detail.)
##
## **This client's default: retail's Middle** -- the user's decision,
## 2026-10-02 ("Original's Middle"), for every record with no saved
## [video_graphic*] section, older settings files included: Middle's preset,
## Normal brightness, the player's own copy filled from it as the constructor
## fills it (0x5f75e0). Bloom ON (glow, under Forward+), Water Reflection OFF.
## The window mode is not part of that choice: it stays as the file has it (a
## window by default), and Default (the button) restores Middle without
## touching it. Round 694 first shipped "User control with the look before
## this round" as the default; the user replaced it.
##
## **Storage (OURS).** ClientSettings' file (user://settings.cfg), sections
## `video` (shared: profile, fullscreen, resolution) and `video_graphic1` /
## `video_graphic2` (one per sub-tab: quality, brightness and every row by
## name, the User values). The View row keeps its existing key, [ui]
## camera_view (F9 and the debug panel write it too). The renderer is not
## here: it lives in override.cfg (round 693, RendererChoice). The user plans
## to move client save data into the `setting/` folder; these sections move
## as they are.

const SECTION := "video"
const PROFILE_SECTIONS := ["video_graphic1", "video_graphic2"]
const KEY_PROFILE := "profile"
const KEY_FULLSCREEN := "fullscreen"
const KEY_RESOLUTION := "resolution"
const KEY_QUALITY := "quality"
const KEY_BRIGHTNESS := "brightness"

# --- the rows -------------------------------------------------------------------

const QUALITY := 0
const SHADOW := 1
const SCENERY := 2
const CHARACTER := 3
const WATER_REFLECTION := 4
const WATER_DETAIL := 5
const METAL := 6
const LIGHT := 7
const FILTERING := 8
const TEXTURE := 9
const LENS_FLARE := 10
const BLOOM := 11
const DYNAMIC_ANIMATION := 12
const EFFECT := 13
const FRIEND_ENEMY := 15
## OURS rows after retail's: screen-space ambient occlusion (the user's request,
## 2026-10-02; retail has no such option), and the renderer, which is not a
## per-profile value but is listed with the others.
const SSAO := 16
const RENDERER := 17
## The values a profile holds, by entry (QUALITY is held apart).
const VALUE_ENTRIES := [SHADOW, SCENERY, CHARACTER, WATER_REFLECTION, WATER_DETAIL, METAL, LIGHT,
	FILTERING, TEXTURE, LENS_FLARE, BLOOM, DYNAMIC_ANIMATION, EFFECT, FRIEND_ENEMY, SSAO]

const QUALITY_LOW := 0
const QUALITY_MIDDLE := 1
const QUALITY_HIGH := 2
const QUALITY_WAR := 3
const QUALITY_USER := 4

## The rows in the order the page lists them (READ for 0..15, OURS after),
## with the config key (OURS), the label and tooltip text-table keys and the
## choices' keys (READ, the pushes in 0x5fef70; "1".."5" are literal there).
## `fallback` is the English text for a key the archive's table lacks (an
## OURS row has no key at all).
const ROWS := [
	{"entry": QUALITY, "key": "quality", "label": "UILM_TEXT_GRAPHIC_QUALITY", "tip": "UIIT_STT_VIDIO_TTDESC_03",
		"choices": ["UIIT_STT_LOW", "UIIT_STT_MIDDLE", "UIIT_STT_HIGH", "UIIT_STT_GRAPHIC_QUALITY_CONTROL_WAR", "UIIT_STT_GRAPHIC_QUALITY_CONTROL_USER"],
		"fallback": ["Graphic Quality", "Low", "Middle", "High", "Large scale battle", "User control"]},
	{"entry": SHADOW, "key": "shadow_detail", "label": "UIIT_STT_SHADOW_DETAIL", "tip": "UIIT_STT_VIDIO_TTDESC_04",
		"choices": ["UIIT_STT_NONE", "UIIT_STT_CIRCLE", "UIIT_STT_DETAIL"],
		"fallback": ["Shadow Detail", "Nothing", "Circle", "Detail"]},
	{"entry": SCENERY, "key": "background_sight_range", "label": "UIIT_STT_SCENERY_SIGHT_RANGE", "tip": "UIIT_STT_VIDIO_TTDESC_05",
		"choices": ["1", "2", "3", "4", "5"], "fallback": ["Background Sight Range", "1", "2", "3", "4", "5"]},
	{"entry": CHARACTER, "key": "character_sight_range", "label": "UIIT_STT_CHAR_SIGHT_RANGE", "tip": "UIIT_STT_VIDIO_TTDESC_06",
		"choices": ["1", "2", "3", "4", "5"], "fallback": ["Character Sight Range", "1", "2", "3", "4", "5"]},
	{"entry": WATER_REFLECTION, "key": "water_reflection", "label": "UIIT_STT_WATER_REFLECTION", "tip": "UIIT_STT_VIDIO_TTDESC_07",
		"choices": ["UIIT_STT_OFF", "UIIT_STT_ON"], "fallback": ["Water Reflection", "Off", "On"]},
	{"entry": WATER_DETAIL, "key": "water_detail", "label": "UIIT_STT_WATER_DETAIL", "tip": "UIIT_STT_VIDIO_TTDESC_08",
		"choices": ["UIIT_STT_LOW", "UIIT_STT_MIDDLE", "UIIT_STT_HIGH"], "fallback": ["Water Detail", "Low", "Middle", "High"]},
	{"entry": METAL, "key": "metallic_sheen", "label": "UIIT_STT_METAL_DETAIL", "tip": "UIIT_STT_VIDIO_TTDESC_09",
		"choices": ["UIIT_STT_OFF", "UIIT_STT_ON"], "fallback": ["Metallic Sheen", "Off", "On"]},
	{"entry": LIGHT, "key": "light_effect", "label": "UIIT_STT_LIGHT_EFFECT", "tip": "UIIT_STT_VIDIO_TTDESC_10",
		"choices": ["UIIT_STT_OFF", "UIIT_STT_ON"], "fallback": ["Light Effect", "Off", "On"]},
	{"entry": FILTERING, "key": "texture_filtering", "label": "UIIT_STT_FILTERING", "tip": "UIIT_STT_VIDIO_TTDESC_15",
		"choices": ["UIIT_STT_OFF", "UIIT_STT_ON"], "fallback": ["Texture Filtering", "Off", "On"]},
	{"entry": TEXTURE, "key": "texture_detail", "label": "UIIT_STT_TEXTER_DETAIL", "tip": "UIIT_STT_VIDIO_TTDESC_11",
		"choices": ["UIIT_STT_LOW", "UIIT_STT_MIDDLE", "UIIT_STT_HIGH"], "fallback": ["Texture Detail", "Low", "Middle", "High"]},
	{"entry": LENS_FLARE, "key": "lens_flare", "label": "UIIT_STT_LENS_FLAIR", "tip": "UIIT_STT_VIDIO_TTDESC_12",
		"choices": ["UIIT_STT_OFF", "UIIT_STT_ON"], "fallback": ["Lens Flare", "Off", "On"]},
	{"entry": BLOOM, "key": "bloom", "label": "UIIT_STT_BLOOM_EFFECT", "tip": "UIIT_STT_VIDIO_TTDESC_13",
		"choices": ["UIIT_STT_OFF", "UIIT_STT_ON"], "fallback": ["Bloom Effect", "Off", "On"]},
	{"entry": DYNAMIC_ANIMATION, "key": "dynamic_animation", "label": "UIIT_STT_DYNAMIC_ANIMATION", "tip": "UIIT_STT_VIDIO_TTDESC_14",
		"choices": ["UIIT_STT_OFF", "UIIT_STT_ON"], "fallback": ["Dynamic Animation", "Off", "On"]},
	{"entry": EFFECT, "key": "effect_quality", "label": "UIIT_STT_EFFECT_QUALITY", "tip": "UIIT_STT_VIDIO_TTDESC_16",
		"choices": ["UIIT_STT_EFFECT_ALL_OFF", "UIIT_STT_EFFECT_DAMEGE_ON", "UIIT_STT_EFFECT_ALL_ON"],
		"fallback": ["Effect Quality", "Turn Off All Effects", "See Hit Effects", "See All Effects"]},
	{"entry": FRIEND_ENEMY, "key": "display_friend_enemy", "label": "UIIT_STT_OPTIMIZE_A_E_EXPRESSION", "tip": "UIIT_STT_VIDIO_TTDESC_17",
		"choices": ["UIIT_STT_OPTIMIZE_A_E_CLOTHES", "UIIT_CTL_WARENETWORK_DETAIL_NORMAL"],
		"fallback": ["Display Friendly/Enemy", "Friend/Enemy Dress", "General"]},
	{"entry": SSAO, "key": "ssao", "label": "", "tip": "",
		"choices": ["", ""], "fallback": ["SSAO (Ambient Occlusion)", "Off", "On"]},
	{"entry": RENDERER, "key": "renderer", "label": "", "tip": "",
		"choices": ["", ""], "fallback": ["Renderer (on restart)", "Forward+", "Compatibility"]},
]

## READ, 0x5015a0: each Graphic Quality's row values, by entry (index 0 and 14
## unused; Large scale battle is "War" in the client's own name).
const PRESETS := {
	QUALITY_LOW:    [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0],
	QUALITY_MIDDLE: [0, 1, 2, 2, 0, 1, 1, 1, 1, 1, 1, 1, 1, 2, 0, 0],
	QUALITY_HIGH:   [0, 2, 4, 4, 1, 2, 1, 1, 1, 2, 1, 1, 1, 2, 0, 0],
	QUALITY_WAR:    [0, 0, 2, 4, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0],
}

## The player's own values in a new record: Middle's preset (READ, 0x5015a0;
## the constructor 0x5f75e0 copies the preset into the second copy), and SSAO
## (OURS, no preset names it) off.
const DEFAULTS := {
	SHADOW: 1, SCENERY: 2, CHARACTER: 2, WATER_REFLECTION: 0, WATER_DETAIL: 1, METAL: 1,
	LIGHT: 1, FILTERING: 1, TEXTURE: 1, LENS_FLARE: 1, BLOOM: 1, DYNAMIC_ANIMATION: 1,
	EFFECT: 2, FRIEND_ENEMY: 0, SSAO: 0,
}
## The user's decision (2026-10-02): retail's default, Middle (READ).
const DEFAULT_QUALITY := QUALITY_MIDDLE
## READ, 0x5fc340 / 0x5f75e0: Normal.
const DEFAULT_BRIGHTNESS := 2

## READ, SWorld::vslot_043 case 0 (0xa194c1..0xa195e8): the gamma ramp is
## 65535 * pow(i / 255 * B, A), clamped, for each brightness choice
## (A at [esp+0x14], B at [esp+0x10]; floats 0xde4c60/64/68, 0xde3148,
## 0xd86fc0). Very Dark, Dark, Normal, Light, Very bright.
const BRIGHTNESS_POW := [1.4, 1.2, 1.0, 0.8, 0.6]
const BRIGHTNESS_MUL := [0.8, 0.9, 1.0, 1.2, 1.4]
const BRIGHTNESS_KEYS := ["UIIT_STT_VERY_DARK", "UIIT_STT_DARK", "UIIT_STT_NORMAL", "UIIT_STT_LIGHT", "UIIT_STT_VERY_LIGHT"]
const BRIGHTNESS_FALLBACK := ["Very Dark", "Dark", "Normal", "Light", "Very bright"]

## READ, SWorld::vslot_043 case 8: Background Sight Range sets the world's
## far plane (world+0x2729: 1500 / 2500 / 3500 / 4500 / 5500, floats
## 0xde4c5c, 0xde34c0, 0xde4c58, 0xde4c54, 0xde4c50) and the view distance
## DAT_00ec54b0 = min(far * 0.8, 2500) (double 0xd99a88, float 0xde34c0),
## which scales the fog planes (ENVIRONMENT_FORMAT.md) and the map
## objects' animation range (MapAnimation, view distance - 480). It also
## sets world+0x23db to 800 / 1000 / 1200 / 1500 / 2048, whose reader was
## not found.
const SCENERY_FAR := [1500.0, 2500.0, 3500.0, 4500.0, 5500.0]
const VIEW_DISTANCE_SCALE := 0.8
const VIEW_DISTANCE_MAX := 2500.0

## OURS: Character Sight Range. Retail stores it (SWorld+0x2e74, case 9) and
## no reader was found (three probes, round 694's entry), so no distance is
## READ. Here it is how far another player or a monster is drawn (NPCs are
## part of their region's build here and are not reached): 600 and
## 1200 world units at 1 and 2, unlimited (as before) at 3 to 5 -- nothing
## past the server's own range is sent anyway.
const CHARACTER_RANGE := [600.0, 1200.0, 0.0, 0.0, 0.0]

## OURS: Water Detail -> the reflection target's rows. Retail's target is
## 512 x 512 (READ, SWorld::vslot_043 case 6); Middle keeps it. Retail's own
## reader of Water Detail (case 7) was not found.
const WATER_ROWS := [256, 512, 1024]

## READ, SWorld::vslot_043 case 5: Texture Detail calls every texture's
## IDirect3DBaseTexture9::SetLOD (vtable +0x2c) with 2 - value, dropping the
## top 2, 1 or 0 mip levels. Godot has no per-texture LOD drop at run time;
## a mipmap bias of the same count samples the same levels (INFERRED
## equivalent look, not the memory saving).
const TEXTURE_MIP_BIAS := [2.0, 1.0, 0.0]

## READ (0x5fef70): retail lists only modes wider than 799 and taller than
## 599. Here that is the smallest VIEW -- the window's size over the UI scale
## (round 672's content_scale_factor) -- the client lays out in: the Option
## window alone is 700 x 500, and at the user's scale 2.0 a 1280 x 720 window
## is a 640 x 360 view that leaves its buttons off the screen (round 696
## review, M1).
const MIN_VIEW := Vector2i(800, 600)

## Resolution choices (OURS): Godot cannot list an adapter's modes, so the
## usual sizes no larger than the screen, as retail lists modes from
## 800 x 600 up (READ: 0x5fef70, width > 799 and height > 599).
const RESOLUTIONS := [
	Vector2i(800, 600), Vector2i(1024, 768), Vector2i(1152, 864), Vector2i(1280, 720),
	Vector2i(1280, 768), Vector2i(1280, 800), Vector2i(1280, 960), Vector2i(1280, 1024),
	Vector2i(1360, 768), Vector2i(1366, 768), Vector2i(1440, 900), Vector2i(1600, 900),
	Vector2i(1600, 1200), Vector2i(1680, 1050), Vector2i(1920, 1080), Vector2i(1920, 1200),
	Vector2i(2560, 1080), Vector2i(2560, 1440), Vector2i(2560, 1600), Vector2i(3440, 1440),
	Vector2i(3840, 2160),
]

## One sub-tab's record.
class Profile:
	var quality: int = DEFAULT_QUALITY
	var brightness: int = DEFAULT_BRIGHTNESS
	## The player's own values (retail's second copy), by entry.
	var user: Dictionary = {}

	func _init() -> void:
		user = DEFAULTS.duplicate()

	## The value in force: the preset's for Low..War, else the player's.
	## SSAO is OURS and no preset names it: the player's in every quality.
	func value(entry: int) -> int:
		if quality != QUALITY_USER and PRESETS.has(quality) and entry < 16:
			return int(PRESETS[quality][entry])
		return int(user.get(entry, DEFAULTS.get(entry, 0)))

	func copy() -> Profile:
		var p := Profile.new()
		p.quality = quality
		p.brightness = brightness
		p.user = user.duplicate()
		return p

var profiles: Array = [Profile.new(), Profile.new()]
## Which sub-tab is in force, 0 (Graphic 1) or 1 (Graphic 2).
var active := 0
var fullscreen := false
## The window size asked for; Vector2i.ZERO leaves the window as it is.
var resolution := Vector2i.ZERO
## Whether the player picked a Resolution in the window since the last store,
## even the one already stored (round 696 review, L1: a stored 1280 x 720
## re-picked while the window is maximised must resize it). Not saved and
## not copied by duplicate_options; OptionVideoPage.store hands it on once.
var resolution_touched := false
## A line for the player about the last store (a renderer choice that could
## not be written, say); "" for none. Not saved.
var notice := ""
## The View row as the window left it ("free" / "third_person" / "quarter",
## World3D.CAMERA_VIEWS), "" for unchanged. Not saved here: [ui] camera_view
## is its key.
var camera_view := ""

func current() -> Profile:
	return profiles[clampi(active, 0, 1)]

## A row's value in force in the active profile.
func value(entry: int) -> int:
	return current().value(entry)

func duplicate_options() -> VideoOptions:
	var o := VideoOptions.new()
	o.profiles = [profiles[0].copy(), profiles[1].copy()]
	o.active = active
	o.fullscreen = fullscreen
	o.resolution = resolution
	o.camera_view = camera_view
	return o

## The number of choices a row offers.
static func choice_count(entry: int) -> int:
	for r in ROWS:
		if int(r["entry"]) == entry:
			return (r["choices"] as Array).size()
	return 0

static func row_of(entry: int) -> Dictionary:
	for r in ROWS:
		if int(r["entry"]) == entry:
			return r
	return {}

## Sets a row in `profile` the way the page does. Graphic Quality fills the
## rows from the preset (READ, 0x5015a0) -- and User puts the player's back --
## while any other row is the player's own: it switches the record to User
## (INFERRED: the slot's change handler was not read; a hand-set row could
## not survive otherwise, since a non-User record is re-filled on load).
## When it switches, the rows in force so far become the player's.
static func set_row(profile: Profile, entry: int, v: int) -> void:
	if entry == QUALITY:
		profile.quality = clampi(v, QUALITY_LOW, QUALITY_USER)
		return
	if entry == RENDERER:
		return
	v = clampi(v, 0, maxi(choice_count(entry) - 1, 0))
	if entry == SSAO:
		profile.user[SSAO] = v
		return
	if profile.quality != QUALITY_USER:
		for e in VALUE_ENTRIES:
			profile.user[e] = profile.value(e)
		profile.quality = QUALITY_USER
	profile.user[entry] = v

# --- derived values -------------------------------------------------------------

## READ (see SCENERY_FAR): the view distance of a Background Sight Range.
static func view_distance(scenery: int) -> float:
	return minf(SCENERY_FAR[clampi(scenery, 0, 4)] * VIEW_DISTANCE_SCALE, VIEW_DISTANCE_MAX)

static func far_plane(scenery: int) -> float:
	return SCENERY_FAR[clampi(scenery, 0, 4)]

static func character_range(v: int) -> float:
	return CHARACTER_RANGE[clampi(v, 0, 4)]

static func water_rows(v: int) -> int:
	return WATER_ROWS[clampi(v, 0, 2)]

static func mip_bias(v: int) -> float:
	return TEXTURE_MIP_BIAS[clampi(v, 0, 2)]

## READ (BRIGHTNESS_POW / _MUL): the ramp's output for one input level.
static func brightness_curve(choice: int, x: float) -> float:
	var i := clampi(choice, 0, 4)
	return clampf(pow(clampf(x * BRIGHTNESS_MUL[i], 0.0, 1.0e9), BRIGHTNESS_POW[i]), 0.0, 1.0)

# --- the renderer -----------------------------------------------------------------

## Whether the running renderer is Forward+ (or Mobile): a RenderingDevice
## exists there and never under Compatibility (as RendererChoice.running).
static func forward_plus_running() -> bool:
	return RenderingServer.get_rendering_device() != null

## SSAO and glow exist only under Forward+ (4.2.2's GLES3 has neither pass);
## so do MSAA and the mipmap bias (MEASURED, OptionVideoPage.available).
static func post_effects_available() -> bool:
	return forward_plus_running()

## Round 693's RendererChoice, when this build has it (looked up by its
## class name, so this file loads with or without it). null otherwise.
static func renderer_choice_script() -> Script:
	return _global_script(&"RendererChoice")

static func _global_script(class_name_: StringName) -> Script:
	for c in ProjectSettings.get_global_class_list():
		if StringName(c.get("class", "")) == class_name_:
			return load(String(c["path"])) as Script
	return null

# --- the environment ------------------------------------------------------------

## The one place the window's choices reach the WorldEnvironment (round 694):
## SSAO (OURS) and glow, which is the Bloom Effect row (READ: retail's bloom
## builds screen-size and 512 x 512 render targets, SWorld::vslot_043 case 1
## -- a glow pass; the look's parameters are not read and stay round 693's).
## Round 693's WorldPostEffects.apply is used when this build has it, so its
## defaults and these toggles are one path; without it the flags are set here.
## Under Compatibility both flags are inert.
static func apply_post_effects(env: Environment, ssao: bool, glow: bool) -> void:
	if env == null:
		return
	var post := _global_script(&"WorldPostEffects")
	if post != null and post.has_method("apply"):
		post.call("apply", env, ssao, glow)
	else:
		env.ssao_enabled = ssao
		env.glow_enabled = glow
	if ssao:
		env.ssao_radius = SSAO_RADIUS
		env.ssao_intensity = SSAO_INTENSITY
		env.ssao_light_affect = SSAO_LIGHT_AFFECT

## SSAO's look (OURS, round 694 review). Godot's defaults (radius 1, intensity
## 2, light affect 0) drew nothing measurable here: MEASURED under Forward+ at
## the Jangan spawn, SSAO on darkened 9.9k pixels by more than 8 luma against
## 11.4k between two frames with it on -- within the frame-to-frame noise.
## Why: a radius of 1 is a hand's width at this world's scale, and SSAO only
## darkens light a material receives -- the terrain is drawn unshaded and the
## object mods write EMISSION, which it never touches. A radius of 16, intensity
## 4 and the AO applied to direct light too: 19.5k pixels darkened against
## 11-12k between two frames with the same setting (dluma -0.55 over the
## frame, at the buildings' feet and the ground band), about +0.1 ms a frame.
## Still a light effect. A stronger one needs the client's own shaders to take
## light (or an AO term) instead of emission -- a restructuring this row does
## not do.
const SSAO_RADIUS := 16.0
const SSAO_INTENSITY := 4.0
const SSAO_LIGHT_AFFECT := 1.0

# --- storage --------------------------------------------------------------------

static func load_saved(path: String = ClientSettings.PATH) -> VideoOptions:
	var o := VideoOptions.new()
	var file := ConfigFile.new()
	if file.load(path) != OK:
		return o
	o.active = clampi(int(file.get_value(SECTION, KEY_PROFILE, 1)) - 1, 0, 1)
	o.fullscreen = bool(file.get_value(SECTION, KEY_FULLSCREEN, false))
	o.resolution = parse_resolution(str(file.get_value(SECTION, KEY_RESOLUTION, "")))
	# Before round 694 the one video setting was [world] water_reflection
	# (round 628). A record with no section of its own starts as Middle (the
	# user's decision); a stored explicit choice there still wins -- as the
	# window would take it, a hand-set row (set_row: User control with
	# Middle's other rows). No key: Middle's value (off).
	var has_legacy := file.has_section_key(ClientSettings.SECTION_WORLD, ClientSettings.KEY_WATER_REFLECTION)
	var legacy_water := 1 if bool(file.get_value(ClientSettings.SECTION_WORLD, ClientSettings.KEY_WATER_REFLECTION, false)) else 0
	for i in 2:
		var p: Profile = o.profiles[i]
		var sec: String = PROFILE_SECTIONS[i]
		if not file.has_section(sec):
			if has_legacy and p.value(WATER_REFLECTION) != legacy_water:
				set_row(p, WATER_REFLECTION, legacy_water)
			continue
		p.quality = clampi(int(file.get_value(sec, KEY_QUALITY, DEFAULT_QUALITY)), QUALITY_LOW, QUALITY_USER)
		p.brightness = clampi(int(file.get_value(sec, KEY_BRIGHTNESS, DEFAULT_BRIGHTNESS)), 0, 4)
		for e in VALUE_ENTRIES:
			var key: String = row_of(e)["key"]
			p.user[e] = clampi(int(file.get_value(sec, key, DEFAULTS[e])), 0, maxi(choice_count(e) - 1, 0))
	return o

## Writes every video key, keeping the rest of the file. False when the file
## could not be written.
func save(path: String = ClientSettings.PATH) -> bool:
	var file := ConfigFile.new()
	file.load(path)
	file.set_value(SECTION, KEY_PROFILE, active + 1)
	file.set_value(SECTION, KEY_FULLSCREEN, fullscreen)
	file.set_value(SECTION, KEY_RESOLUTION, format_resolution(resolution))
	for i in 2:
		var p: Profile = profiles[i]
		var sec: String = PROFILE_SECTIONS[i]
		file.set_value(sec, KEY_QUALITY, p.quality)
		file.set_value(sec, KEY_BRIGHTNESS, p.brightness)
		for e in VALUE_ENTRIES:
			file.set_value(sec, String(row_of(e)["key"]), int(p.user.get(e, DEFAULTS[e])))
	# The old key follows the record in force, so a client before round 694
	# reading this file draws the same water.
	file.set_value(ClientSettings.SECTION_WORLD, ClientSettings.KEY_WATER_REFLECTION, value(WATER_REFLECTION) == 1)
	return file.save(path) == OK

static func format_resolution(r: Vector2i) -> String:
	return "" if r.x <= 0 or r.y <= 0 else "%dx%d" % [r.x, r.y]

static func parse_resolution(s: String) -> Vector2i:
	var parts := s.to_lower().replace(" ", "").split("x")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return Vector2i.ZERO
	var r := Vector2i(int(parts[0]), int(parts[1]))
	return r if r.x >= 320 and r.y >= 200 else Vector2i.ZERO

## The resolution choices for a screen of `screen` pixels (see RESOLUTIONS),
## with `current` added when it is not one of them -- only those whose view at
## UI scale `scale` is at least MIN_VIEW (READ minimum, round 696 review). If
## the screen has none at that scale, the largest size that fits it (OURS: the
## list is never empty; apply_display raises it as far as the screen allows).
static func resolution_choices(screen: Vector2i, current_size: Vector2i, scale: float = 1.0) -> Array:
	var out: Array = []
	var fitting: Array = []
	for r in RESOLUTIONS:
		if screen.x <= 0 or (r.x <= screen.x and r.y <= screen.y):
			fitting.append(r)
			if view_fits(r, scale):
				out.append(r)
	if current_size.x > 0 and not out.has(current_size) and view_fits(current_size, scale):
		out.append(current_size)
	if out.is_empty() and not fitting.is_empty():
		out.append(fitting[-1])
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x < b.x or (a.x == b.x and a.y < b.y))
	return out

## Whether a window of `size` at UI scale `scale` is a view of at least
## MIN_VIEW.
static func view_fits(size: Vector2i, scale: float) -> bool:
	var m := min_window(scale)
	return size.x >= m.x and size.y >= m.y

## The smallest window whose view at `scale` is MIN_VIEW.
static func min_window(scale: float) -> Vector2i:
	var k := maxf(scale, 0.01)
	return Vector2i(ceili(MIN_VIEW.x * k - 0.001), ceili(MIN_VIEW.y * k - 0.001))

## The process-wide copy in force: loaded on first use, replaced by apply.
static var _in_force: VideoOptions = null

static func in_force() -> VideoOptions:
	if _in_force == null:
		_in_force = load_saved()
		_qa_override(_in_force)
	return _in_force

## QA hook (round 694, OURS): SRREVAMP_QA_VIDEO="quality=0,shadow_detail=2,..."
## sets rows of the record in force for one run -- `quality`, `brightness`,
## `profile` (1 or 2) or a row's key (ROWS) -- in the order given, as the
## window would (set_row: a row after a quality switches to User). Nothing
## is saved. For measuring each setting's cost and look.
static func _qa_override(o: VideoOptions) -> void:
	var spec := OS.get_environment("SRREVAMP_QA_VIDEO")
	if spec == "":
		return
	apply_spec(o, spec)
	print("VideoOptions: SRREVAMP_QA_VIDEO=%s -> graphic %d quality %d" % [spec, o.active + 1, o.current().quality])

## Sets rows of `o` from "key=value,..." (see _qa_override).
static func apply_spec(o: VideoOptions, spec: String) -> void:
	for pair in spec.split(",", false):
		var kv := pair.split("=")
		if kv.size() != 2 or not kv[1].strip_edges().is_valid_int():
			continue
		var key := kv[0].strip_edges()
		var v := int(kv[1])
		match key:
			"profile":
				o.active = clampi(v - 1, 0, 1)
			"quality":
				set_row(o.current(), QUALITY, v)
			"brightness":
				o.current().brightness = clampi(v, 0, 4)
			_:
				for r in ROWS:
					if String(r["key"]) == key:
						set_row(o.current(), int(r["entry"]), v)

static func set_in_force(o: VideoOptions) -> void:
	_in_force = o

# --- applying what the world does not own ------------------------------------

## The brightness pass's node, a child of the root window so it covers every
## scene, the login screen included, as retail's gamma ramp covers the screen.
const BRIGHTNESS_LAYER := "VideoBrightness"
## Above the UI: the world scene's UI CanvasLayer is layer 1 (the default)
## and no script makes one higher (round 694, a grep of the scripts).
const BRIGHTNESS_LAYER_INDEX := 120
const BRIGHTNESS_SHADER := """
shader_type canvas_item;
// Round 694: retail's gamma ramp (SWorld::vslot_043 case 0), out =
// clamp(pow(in * mul, power)), over the finished screen.
uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;
uniform float mul = 1.0;
uniform float power = 1.0;
void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	COLOR = vec4(clamp(pow(max(c * mul, vec3(0.0)), vec3(power)), 0.0, 1.0), 1.0);
}
"""

## Set Brightness. READ: retail loads the ramp into the display's gamma
## (SetDeviceGammaRamp), and only while full screen -- in a window it puts
## the desktop's own ramp back (case 0's DAT_0110f7ec+0xa0 branch). OURS:
## Godot has no display gamma, so the same curve is a full-screen pass over
## the finished frame, in a window too (a setting that did nothing in a
## window would read as broken). Normal draws no pass at all.
static func apply_brightness(root: Node, choice: int) -> CanvasLayer:
	if root == null:
		return null
	var layer := root.get_node_or_null(BRIGHTNESS_LAYER) as CanvasLayer
	var i := clampi(choice, 0, 4)
	if i == DEFAULT_BRIGHTNESS:
		if layer != null:
			layer.visible = false
		return layer
	if layer == null:
		layer = CanvasLayer.new()
		layer.name = BRIGHTNESS_LAYER
		layer.layer = BRIGHTNESS_LAYER_INDEX
		var rect := ColorRect.new()
		rect.name = "Pass"
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var sh := Shader.new()
		sh.code = BRIGHTNESS_SHADER
		var mat := ShaderMaterial.new()
		mat.shader = sh
		rect.material = mat
		layer.add_child(rect)
		root.add_child.call_deferred(layer)
	layer.visible = true
	var pass_rect := layer.get_node_or_null("Pass") as ColorRect
	if pass_rect != null and pass_rect.material is ShaderMaterial:
		(pass_rect.material as ShaderMaterial).set_shader_parameter("mul", BRIGHTNESS_MUL[i])
		(pass_rect.material as ShaderMaterial).set_shader_parameter("power", BRIGHTNESS_POW[i])
	return layer

## Window Mode and Resolution. READ: retail switches the device between full
## screen and a window and sets the chosen mode. OURS: Godot's full screen
## keeps the desktop's resolution (4.2.2 changes no display mode), so the
## Resolution row sizes the window and is unavailable in full screen.
##
## **In a window the OS window itself takes the size (round 696).** READ,
## retail's resolution apply in a window (`FUN_00835510`, from the Video
## tab's store `0x5fdae0`): it gives the window a caption and system menu
## (style |= 0xC80000), turns the chosen client size into the frame's size
## with AdjustWindowRect, and MoveWindow's the frame there, centred at
## ((SM_CXFULLSCREEN - frame w) / 2, (SM_CYFULLSCREEN - frame h) / 2); the
## device is then reset to the new size (`FUN_004694d0`, `FUN_008354c0`).
## Its style has no WS_THICKFRAME / WS_MAXIMIZEBOX, so retail's window is
## never maximised.
##
## Ours can be, and the user's was (3840 x 2019, a maximised window on a
## 4K screen). The black border was this (READ, Godot 4.2.2):
## `Window::set_size` stores the size and sizes the viewport from it
## (`_update_window_size` -> `_update_viewport_size`, scene/main/window.cpp),
## but `DisplayServerWindows::window_set_size` returns at once while the
## window is maximised (`if (wd.fullscreen || wd.maximized) return;`), and
## so does `window_set_position`. The OS window kept its maximised size, no
## resize event came back to correct the node, and the game drew a 1280 x
## 720 viewport in the corner of a 3840 x 2019 window: the rest black.
##
## So (OURS, retail's steps where it has them): a maximised or minimised
## window is restored first; the size is the chosen one, no larger than the
## usable area of the window's screen less the window's own frame (round
## 694's clamp, now with the title bar counted, so the frame never leaves the
## screen); the frame is centred in that area (retail centres it on the
## primary screen's full-screen area); and afterwards the node's size is
## checked against the OS window's (`sync_window_size`), so a size the OS
## did not take can never leave a viewport smaller than its window.
static func apply_display(window: Window, o: VideoOptions) -> void:
	if window == null or o == null:
		return
	if DisplayServer.get_name() == "headless":
		return
	_watch_window(window)
	if o.fullscreen:
		if window.mode != Window.MODE_FULLSCREEN and window.mode != Window.MODE_EXCLUSIVE_FULLSCREEN:
			window.mode = Window.MODE_FULLSCREEN
		_log_display(window, o)
		return
	var restored := restore_for_size(window.mode)
	if restored:
		window.mode = Window.MODE_WINDOWED
	if o.resolution.x > 0 and o.resolution.y > 0:
		var id := window.get_window_id()
		var area := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen(id))
		var inset := frame_insets(DisplayServer.window_get_position(id), DisplayServer.window_get_size(id),
			DisplayServer.window_get_position_with_decorations(id), DisplayServer.window_get_size_with_decorations(id))
		var placed := window_placement(o.resolution, area, inset, window.content_scale_factor)
		if placed.size != o.resolution:
			print("VideoOptions: %s asked; %s is what this screen and UI scale %.2f allow (a view of at least %s, READ minimum)" % [
				format_resolution(o.resolution), format_resolution(placed.size), window.content_scale_factor, format_resolution(MIN_VIEW)])
		if window.size != placed.size or restored:
			window.size = placed.size
			window.position = placed.position
	sync_window_size(window)
	_log_display(window, o)

## One line for a tester's log: the window node, the OS window and the view's
## render-target size -- the three that differed in the black-border report.
static func _log_display(window: Window, o: VideoOptions) -> void:
	print("VideoOptions: window %s, %s at %s (asked %s); OS window %s; view %s" % [
		_mode_name(window.mode), format_resolution(window.size), str(window.position),
		format_resolution(o.resolution) if o.resolution.x > 0 else "(as started)",
		format_resolution(DisplayServer.window_get_size(window.get_window_id())),
		format_resolution(Vector2i(window.get_texture().get_size())) if window.get_texture() != null else "?"])

## A line in the log when the window's view has changed size afterwards --
## a full-screen switch or a maximise the window manager finishes later, a
## drag -- with the OS window's size beside the view's, so a tester's log
## shows whether they differ (round 696). Logged once the size has SETTLED:
## no further change for RESIZE_SETTLE_MS (OURS), so a drag on Windows, which
## resizes every frame, writes one line, not one a frame (round 696 review, L2).
const RESIZE_SETTLE_MS := 300
const _WATCH_META := &"video_options_watch"
const _WATCH_STAMP := &"video_options_watch_ms"

static func _watch_window(window: Window) -> void:
	if window.has_meta(_WATCH_META):
		return
	window.set_meta(_WATCH_META, false)
	window.size_changed.connect(func() -> void: _on_watched_resize(window))

static func _on_watched_resize(window: Window) -> void:
	if not is_instance_valid(window) or not window.is_inside_tree():
		return
	window.set_meta(_WATCH_STAMP, Time.get_ticks_msec())
	if bool(window.get_meta(_WATCH_META, false)):
		return
	window.set_meta(_WATCH_META, true)
	_check_settled(window)

static func _check_settled(window: Window) -> void:
	if not is_instance_valid(window) or not window.is_inside_tree():
		return
	var quiet := Time.get_ticks_msec() - int(window.get_meta(_WATCH_STAMP, 0))
	if quiet < RESIZE_SETTLE_MS:
		window.get_tree().create_timer((RESIZE_SETTLE_MS - quiet) / 1000.0).timeout.connect(func() -> void: _check_settled(window))
		return
	window.set_meta(_WATCH_META, false)
	print("VideoOptions: view resized -- window %s, %s; OS window %s; view %s" % [
		_mode_name(window.mode), format_resolution(window.size),
		format_resolution(DisplayServer.window_get_size(window.get_window_id())),
		format_resolution(Vector2i(window.get_texture().get_size())) if window.get_texture() != null else "?"])

## Whether a window in `mode` must be restored before a size can take: a
## maximised (or minimised) window ignores window_set_size on Windows (READ,
## DisplayServerWindows::window_set_size, 4.2.2). Full screen is left by the
## mode switch before it.
static func restore_for_size(mode: Window.Mode) -> bool:
	return mode == Window.MODE_MAXIMIZED or mode == Window.MODE_MINIMIZED \
		or mode == Window.MODE_FULLSCREEN or mode == Window.MODE_EXCLUSIVE_FULLSCREEN

## The window's frame around its client area: `position` is the client's
## offset inside the frame (the left border and the title bar), `size` the
## frame's extra width and height. Zero where the OS reports no frame (a box
## X server with no window manager).
static func frame_insets(client_pos: Vector2i, client_size: Vector2i, frame_pos: Vector2i, frame_size: Vector2i) -> Rect2i:
	var lead := _at_least(client_pos - frame_pos, Vector2i.ZERO)
	var extra := _at_least(frame_size - client_size, Vector2i.ZERO)
	return Rect2i(lead, _at_least(extra, lead))

## Where a window's client area goes for a chosen size: the size at least
## min_window(scale) -- a view of MIN_VIEW at the UI scale, so a size saved by
## an older build or at another scale cannot strand the player at start-up
## (round 696 review, M1) -- and no larger than the usable `area` less the
## frame (`inset`, frame_insets), which wins where the two disagree; the frame
## centred in the area, never above or left of it. Returns the client's rect
## (what Window.position / Window.size take).
static func window_placement(want: Vector2i, area: Rect2i, inset: Rect2i, scale: float = 1.0) -> Rect2i:
	var room := area.size - inset.size if area.size.x > 0 and area.size.y > 0 else Vector2i.ZERO
	var size := fit_resolution(_at_least(want, min_window(scale)), room)
	var frame := size + inset.size
	var at := area.position + _at_least((area.size - frame) / 2, Vector2i.ZERO)
	return Rect2i(at + inset.position, size)

## Makes the window node's size the OS window's when they differ (see
## apply_display): the viewport is sized from the node, so a node size the
## OS did not take is the black border. Returns whether it corrected one.
static func sync_window_size(window: Window) -> bool:
	if window == null or DisplayServer.get_name() == "headless":
		return false
	var real := DisplayServer.window_get_size(window.get_window_id())
	if real.x <= 0 or real.y <= 0 or real == window.size:
		return false
	print("VideoOptions: the window is %s, not the %s asked; the view follows the window" % [format_resolution(real), format_resolution(window.size)])
	window.size = real
	return true

## Each component no less than `floor`'s (Vector2i has no max() in 4.2).
static func _at_least(v: Vector2i, floor: Vector2i) -> Vector2i:
	return Vector2i(maxi(v.x, floor.x), maxi(v.y, floor.y))

## Whether an Apply of `o` must size the window although its Resolution did
## not change (round 696 review, L1): the row was picked again and the window
## is maximised / minimised, or is not the size `o` gives it here.
static func needs_resize(window: Window, o: VideoOptions) -> bool:
	if window == null or o == null or o.fullscreen or not o.resolution_touched or o.resolution.x <= 0:
		return false
	if restore_for_size(window.mode):
		return true
	var id := window.get_window_id()
	var area := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen(id))
	var inset := frame_insets(DisplayServer.window_get_position(id), DisplayServer.window_get_size(id),
		DisplayServer.window_get_position_with_decorations(id), DisplayServer.window_get_size_with_decorations(id))
	return window.size != window_placement(o.resolution, area, inset, window.content_scale_factor).size

static func _mode_name(mode: Window.Mode) -> String:
	match mode:
		Window.MODE_WINDOWED: return "windowed"
		Window.MODE_MINIMIZED: return "minimized"
		Window.MODE_MAXIMIZED: return "maximized"
		Window.MODE_FULLSCREEN: return "fullscreen"
		Window.MODE_EXCLUSIVE_FULLSCREEN: return "exclusive fullscreen"
	return str(mode)

## A window size no larger than `screen` (the usable area); ZERO screen keeps it.
static func fit_resolution(want: Vector2i, screen: Vector2i) -> Vector2i:
	if screen.x <= 0 or screen.y <= 0:
		return want
	return Vector2i(mini(want.x, screen.x), mini(want.y, screen.y))

## Texture Filtering and Texture Detail on the 3D viewport (see the
## constants and the apply notes in World3D.apply_video_options).
## Texture Filtering: INFERRED from its own tooltip, UIIT_STT_VIDIO_TTDESC_15
## "Compensates rough outlines to produce more natural-looking objects" --
## anti-aliasing; its reader in the client was not found. OURS: MSAA 2x.
static func apply_viewport(vp: Viewport, o: VideoOptions) -> void:
	if vp == null or o == null:
		return
	vp.msaa_3d = Viewport.MSAA_2X if o.value(FILTERING) == 1 else Viewport.MSAA_DISABLED
	vp.texture_mipmap_bias = mip_bias(o.value(TEXTURE))
