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
## SROptionSet.dat's tag 5 = 1 is overwritten on load: its record 0 is Middle,
## and Middle's preset has Water Reflection off. Round 627/628 read the tag
## and missed the re-application.)
##
## **This client's default (OURS):** "User control" with the values that draw
## exactly what the client drew before this round (DEFAULTS), so a player who
## never opens the window sees no change and the perf gate's default views
## are unchanged. Retail's Middle is one click away in the Graphic Quality
## row. Default (the button) restores these, not Middle -- a deliberate
## difference, recorded here and in the round's entry.
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

## OURS: the values this client used before the window existed (see the
## header): Detail shadows (the blob and the sun's shadow map), sight 3 and 3
## (the READ default view distance), reflection on, the 512-row reflection
## target, no MSAA, full-resolution textures, the sun glow, no glow pass,
## every effect. SSAO off (round 693). Metallic Sheen, Light Effect and
## Dynamic Animation draw nothing here (see apply notes) and sit at Off.
const DEFAULTS := {
	SHADOW: 2, SCENERY: 2, CHARACTER: 2, WATER_REFLECTION: 1, WATER_DETAIL: 1, METAL: 0,
	LIGHT: 0, FILTERING: 0, TEXTURE: 2, LENS_FLARE: 1, BLOOM: 0, DYNAMIC_ANIMATION: 0,
	EFFECT: 2, FRIEND_ENEMY: 0, SSAO: 0,
}
const DEFAULT_QUALITY := QUALITY_USER
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
## READ. Here it is how far another player, monster or NPC is drawn: 600 and
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

## SSAO and glow exist only under Forward+ (4.2.2's GLES3 has neither pass).
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
		return
	env.ssao_enabled = ssao
	env.glow_enabled = glow

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
	# (round 628); it seeds both records' Water Reflection when it is set.
	var has_legacy := file.has_section_key(ClientSettings.SECTION_WORLD, ClientSettings.KEY_WATER_REFLECTION)
	var legacy_water := bool(file.get_value(ClientSettings.SECTION_WORLD, ClientSettings.KEY_WATER_REFLECTION, true))
	for i in 2:
		var p: Profile = o.profiles[i]
		if has_legacy:
			p.user[WATER_REFLECTION] = 1 if legacy_water else 0
		var sec: String = PROFILE_SECTIONS[i]
		if not file.has_section(sec):
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
## with `current` added when it is not one of them.
static func resolution_choices(screen: Vector2i, current_size: Vector2i) -> Array:
	var out: Array = []
	for r in RESOLUTIONS:
		if screen.x <= 0 or (r.x <= screen.x and r.y <= screen.y):
			out.append(r)
	if current_size.x > 0 and not out.has(current_size):
		out.append(current_size)
		out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x < b.x or (a.x == b.x and a.y < b.y))
	return out

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
	print("VideoOptions: SRREVAMP_QA_VIDEO=%s -> graphic %d quality %d" % [spec, o.active + 1, o.current().quality])

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
static func apply_display(window: Window, o: VideoOptions) -> void:
	if window == null or o == null:
		return
	if DisplayServer.get_name() == "headless":
		return
	if o.fullscreen:
		if window.mode != Window.MODE_FULLSCREEN and window.mode != Window.MODE_EXCLUSIVE_FULLSCREEN:
			window.mode = Window.MODE_FULLSCREEN
		return
	if window.mode == Window.MODE_FULLSCREEN or window.mode == Window.MODE_EXCLUSIVE_FULLSCREEN:
		window.mode = Window.MODE_WINDOWED
	if o.resolution.x > 0 and o.resolution.y > 0 and window.size != o.resolution:
		window.size = o.resolution
		var screen := DisplayServer.window_get_current_screen()
		var area := DisplayServer.screen_get_usable_rect(screen)
		window.position = area.position + (area.size - o.resolution) / 2

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
