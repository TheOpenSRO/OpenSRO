extends Node2D
class_name DamageText

## The combat number over a body: retail's CIDamageText (round 786), READ from
## sro_client.exe (dump /var/tmp/decomp_client, objdump /var/tmp/sro_client.asm,
## constants read out of the PE image). docs/protocol/damage_text.md has the
## whole reading; this header is its summary.
##
## **Who makes one (READ).** CIDecoDamageEffect's hit apply FUN_00a49290 calls
## FUN_00a47bf0(target, hit, !byCharacter, 0) for every entry of a skill's or a
## swing's hit block, when the hit lands -- under the target's +0x65c & 1 and
## +0xbc, the global byte 0xec4b58, and `target+0x24c < 200.0` (0xe1b8b8, the
## target's distance from the local player, written at 0x9d6f7e -- NamePlates'
## header) OR the attacker being the local player (DAT_00eef5ec). So another
## player's fight shows numbers too, within 200 units of this player.
## FUN_00a47bf0 creates a CIDamageText (runtime class 0x110a730, a
## CIOBillboard, 0x1e8 bytes) and fills it with FUN_00a47720 (this, target,
## hit, noCharacterAttacker, arena). Two other callers: a state's damage tick
## (NetProcessInNavAndSkill::FUN_008a4b00 case 1 -> FUN_00a56230 ->
## FUN_00a47bf0(.., 1, 0): no attacker) and UI_ARENA's FUN_004de6a0 (.., 0, 1).
##
## **The art (READ, FUN_00a92f70).** One digit set, `interface\hitcount\
## hitcount_0..9.ddj` with a `_shadow` twin each, and three words with
## shadows: `critical`, `blocking`, `resist`. The fill art is white and the
## colour is a tint (D3DRS_TEXTUREFACTOR 0x3c, GlobalDataManager::FUN_00a62860):
## each sprite draws its `_shadow` texture with the factor `colour &
## 0xff000000` (black at the number's alpha) and then the fill with the
## colour. Media.pk2 also holds hitcount_enemy_/_player_ digit sets, miss_*,
## critical_enemy/_player: this client never names them (MEASURED: not in
## its strings), so they are not used.
##
## **Which art (READ, FUN_00a47720 0xa47733..0xa47771).** Hit kind 0 or 4
## with hitFlags & 2: the critical; kind 0 or 4 otherwise, and every other kind
## but 2 (5 the knockback, 7 a wall, 8 void): a plain number; kind 2: the
## block word. Then hitFlags & 0x10 with statusBits 0 (an effect-only hit that
## landed no state) overrides it to the resist word. Digits only for the number
## and the critical, and only when the damage is non-zero; the words alone
## carry no digits. A plain number of 0 is nothing at all.
##
## **The colour (READ, 0xa47771..0xa477cf).** With a character attacker
## (CICharactor, runtime class 0xef1a5c -- monsters are characters too): on a
## CICUser target (any player, this one included; runtime class 0xef1bc0) 0xFF3A3A
## red, on anything else white. With none (a state's tick): 0xFFD33A on a
## player, 0xFF713A on anything else. The arena's call: 0x3A3AFF.
##
## **The layout (READ),** in a 1600 x 1200 reference screen
## (0xde54c8 = 1600.0, 0xde54c0 = 1200.0 -- CIDamageText::vslot_009 scales
## x by width / 1600 and y by height / 1200): a sprite is centred on the
## anchor (FUN_00a62340: -w/2, -h/2). Digits 24 x 40 advancing 22, a
## critical's 36 x 60 advancing 33 (0xec5c78), the row centred
## (x -= ((n - 1) / 2 - i) * advance, 0xa47b7d..0xa47b96). The words (0xec5c48):
## critical 96 x 24, 45 below the digits' centre (0xde5538 = 45.0); blocking
## and resist 60 x 28 at a scale of 2.0 (the +0x1a0 track, 0xa478bd).
##
## **The motion (READ).** The anchor is the target's position when the hit
## landed plus 20 world units up (0xe1b830 = 20.0; the arena's: half the
## body's height), fixed in the world (copied at creation, 0xa477dc). Over
## 1.0 s it rises 50 reference pixels, linearly (the +0x180 track 0 -> 50.0,
## 0xd851a0, duration 1.0, FUN_009c7bc0); its alpha track runs 2.0 -> 0 over
## the same second (0xd86ecc), drawn as 255 while >= 1 -- opaque for 0.5 s,
## then a linear fade to nothing at 1.0 s. No scale pop, no bounce. The object
## lives 3000 ms (vslot_009: `+0x3c < 0xbb9`); here it is freed at 1.0 s,
## when it is already invisible (OURS). Hidden when its point is behind the
## camera or past the far plane (FUN_00a62860's projected-z test).
##
## **Stacking (READ):** none. Every number of every hit is its own object at
## the same anchor; a multi-hit skill separates them only by its hits' times.

enum Art { NUMBER = 0, CRITICAL = 1, BLOCK = 2, RESIST = 3 }

## READ: the reference screen (0xde54c8, 0xde54c0).
const REF_WIDTH := 1600.0
const REF_HEIGHT := 1200.0
## READ: the rise, reference pixels (0xd851a0), and its time (0xa4781f fld1).
const RISE := 50.0
const SECONDS := 1.0
## READ: the alpha track's start (0xd86ecc), falling to 0 over SECONDS.
const ALPHA_START := 2.0
## READ: the anchor's height over the target's feet, world units (0xe1b830).
const ANCHOR_HEIGHT := 20.0
## READ: a number shows within this distance of the local player, or for a
## blow of the local player's own (0xe1b8b8 compared at 0xa49697).
const SHOW_RANGE := 200.0
## READ (0xec5c78): {size, advance} of a digit, plain and critical.
const DIGIT_SIZE := [Vector2(24, 40), Vector2(36, 60)]
const DIGIT_ADVANCE := [22.0, 33.0]
## READ (0xec5c48, three floats per art; the third is 0 for all three).
const WORD_SIZE := {Art.CRITICAL: Vector2(96, 24), Art.BLOCK: Vector2(60, 28), Art.RESIST: Vector2(60, 28)}
## READ: the critical word drops 45 below the digits (0xde5538).
const CRITICAL_WORD_DROP := 45.0
## READ: the +0x1a0 scale track's constant (0xa478bd: 1.0, or 2.0 = 0xd86ecc
## for the blocking and resist words).
const ART_SCALE := {Art.NUMBER: 1.0, Art.CRITICAL: 1.0, Art.BLOCK: 2.0, Art.RESIST: 2.0}

## READ (FUN_00a47720): the D3DCOLORs.
const COLOUR_PLAYER := Color8(0xFF, 0x3A, 0x3A)
const COLOUR_OTHER := Color8(0xFF, 0xFF, 0xFF)
const COLOUR_TICK_PLAYER := Color8(0xFF, 0xD3, 0x3A)
const COLOUR_TICK_OTHER := Color8(0xFF, 0x71, 0x3A)
const COLOUR_ARENA := Color8(0x3A, 0x3A, 0xFF)

## READ: the hit kinds and flags this reads (FUN_00a55e00).
const KIND_HIT := 0
const KIND_BLOCK := 2
const KIND_KNOCKDOWN := 4
const FLAG_CRITICAL := 0x02
const FLAG_EFFECT_ONLY := 0x10

## The art's files (READ, FUN_00a92f70), under interface\hitcount\.
const ART_DIR := "interface\\hitcount\\"
const WORD_FILE := {Art.CRITICAL: "critical", Art.BLOCK: "blocking", Art.RESIST: "resist"}

## Loaded textures by file stem ("hitcount_3", "critical_shadow", ...), filled
## once by load_art. Empty without Media.pk2: the number is then drawn in the
## default font (OURS fallback).
static var _art: Dictionary = {}
static var _art_loaded := false

## The camera the anchor is projected through.
var camera: Camera3D = null
var _anchor := Vector3.ZERO
var _sprites: Array = []
var _colour := Color.WHITE
var _art_kind := Art.NUMBER
var _damage := 0
var _down := false
var _t := 0.0

## Loads the art through `read(path) -> Texture2D or null` (a Media.pk2 lookup
## by World3D), once.
static func load_art(read: Callable) -> void:
	if _art_loaded:
		return
	_art_loaded = true
	var stems: Array = []
	for d in 10:
		stems.append("hitcount_%d" % d)
	for w in WORD_FILE.values():
		stems.append(String(w))
	for s in stems:
		for name in [String(s), String(s) + "_shadow"]:
			var tex = read.call(ART_DIR + name + ".ddj")
			if tex != null:
				_art[name] = tex

## Whether the art is loaded (every digit's fill).
static func has_art() -> bool:
	for d in 10:
		if not _art.has("hitcount_%d" % d):
			return false
	return true

## The art of one hit record (READ, FUN_00a47720).
static func art_of(kind: int, hit_flags: int, status_bits: int) -> int:
	var art := Art.NUMBER
	if kind == KIND_HIT or kind == KIND_KNOCKDOWN:
		if (hit_flags & FLAG_CRITICAL) != 0:
			art = Art.CRITICAL
	elif kind == KIND_BLOCK:
		art = Art.BLOCK
	if (hit_flags & FLAG_EFFECT_ONLY) != 0 and status_bits == 0:
		art = Art.RESIST
	return art

## The tint (READ, FUN_00a47720): `on_player` the target is a player
## character, `by_character` the hit has a character attacker (a monster
## counts), `arena` UI_ARENA's call.
static func colour_of(on_player: bool, by_character: bool, arena: bool = false) -> Color:
	if not by_character:
		return COLOUR_TICK_PLAYER if on_player else COLOUR_TICK_OTHER
	if arena:
		return COLOUR_ARENA
	return COLOUR_PLAYER if on_player else COLOUR_OTHER

## Whether a number is made at all (READ, FUN_00a49290 0xa49697): the local
## player's own blow always, any other within SHOW_RANGE of the local player.
static func shows(distance_to_player: float, by_me: bool) -> bool:
	return by_me or distance_to_player < SHOW_RANGE

## The number of digits of `damage` (FUN_00b49590 log10, +1).
static func digit_count(damage: int) -> int:
	return str(absi(damage)).length()

## The sprites of one number, in the order retail fills its vector (the word
## first): [{"file": stem, "pos": top-left offset from the anchor, "size":
## size}], both in reference pixels BEFORE the art's scale (ART_SCALE)
## multiplies them. Empty when nothing is drawn.
static func sprites_of(art: int, damage: int) -> Array:
	var out: Array = []
	if art != Art.NUMBER:
		var ws: Vector2 = WORD_SIZE[art]
		var wpos := -ws * 0.5
		if art == Art.CRITICAL:
			wpos.y += CRITICAL_WORD_DROP
		out.append({"file": WORD_FILE[art], "pos": wpos, "size": ws, "digit": -1})
	if damage == 0 or (art != Art.NUMBER and art != Art.CRITICAL):
		return out
	var crit := 1 if art == Art.CRITICAL else 0
	var ds: Vector2 = DIGIT_SIZE[crit]
	var adv: float = DIGIT_ADVANCE[crit]
	var text := str(absi(damage))
	var n := text.length()
	# Retail fills them from the last digit (i = n-1, the rightmost) down;
	# the place is the same.
	for i in n:
		var pos := -ds * 0.5
		pos.x -= (float(n - 1) * 0.5 - float(i)) * adv
		var d := int(text.substr(i, 1))
		out.append({"file": "hitcount_%d" % d, "pos": pos, "size": ds, "digit": d})
	return out

## READ: the rise at `t` seconds, reference pixels (the +0x180 track).
static func rise_at(t: float) -> float:
	return RISE * clampf(t / SECONDS, 0.0, 1.0)

## READ: the alpha at `t` seconds (the +0x1c0 track, vslot_009's byte).
static func alpha_at(t: float) -> float:
	var a := ALPHA_START + (0.0 - ALPHA_START) * clampf(t / SECONDS, 0.0, 1.0)
	return clampf(a, 0.0, 1.0)

## A number for one hit at `anchor` (the target's feet, world units). Returns
## null when retail draws nothing (a zero plain number).
static func create(anchor_feet: Vector3, art: int, damage: int, colour: Color, arena_height: float = -1.0) -> DamageText:
	var sprites := sprites_of(art, damage)
	if sprites.is_empty():
		return null
	var n := DamageText.new()
	n.name = "DamageText"
	n._sprites = sprites
	n._art_kind = art
	n._damage = damage
	n._colour = colour
	n._down = arena_height >= 0.0
	n._anchor = anchor_feet + Vector3(0.0, arena_height * 0.5 if n._down else ANCHOR_HEIGHT, 0.0)
	return n

## The world point it hangs from.
func anchor() -> Vector3:
	return _anchor

func art() -> int:
	return _art_kind

func colour() -> Color:
	return _colour

func damage() -> int:
	return _damage

## Where the anchor falls on screen now, or null when it is not drawn.
func screen_point() -> Variant:
	var cam := camera if camera != null and is_instance_valid(camera) else get_viewport().get_camera_3d()
	if cam == null or cam.is_position_behind(_anchor):
		return null
	return cam.unproject_position(_anchor)

func _ready() -> void:
	z_index = 0

func _process(delta: float) -> void:
	_t += delta
	if _t >= SECONDS:
		queue_free()
		return
	queue_redraw()

func _draw() -> void:
	var p = screen_point()
	if p == null:
		return
	var view := get_viewport_rect().size
	var art_scale: float = ART_SCALE[_art_kind]
	var sx := art_scale * view.x / REF_WIDTH
	var sy := art_scale * view.y / REF_HEIGHT
	# vslot_009: the rise is scaled by height / 1200 alone (not by the art's
	# scale); upward is -y (the arena's goes down).
	var rise := rise_at(_t) * view.y / REF_HEIGHT * (1.0 if _down else -1.0)
	var a := alpha_at(_t)
	if a <= 0.0:
		return
	var origin := (p as Vector2) + Vector2(0.0, rise)
	var fill := Color(_colour.r, _colour.g, _colour.b, a)
	var shadow := Color(0.0, 0.0, 0.0, a)
	for s in _sprites:
		var size: Vector2 = s["size"]
		var pos: Vector2 = s["pos"]
		var rect := Rect2(origin + Vector2(pos.x * sx, pos.y * sy), Vector2(size.x * sx, size.y * sy))
		var stem := String(s["file"])
		var tex: Texture2D = _art.get(stem)
		if tex == null:
			_draw_fallback(s, rect, fill, shadow)
			continue
		var shadow_tex: Texture2D = _art.get(stem + "_shadow")
		if shadow_tex != null:
			draw_texture_rect(shadow_tex, rect, false, shadow)
		draw_texture_rect(tex, rect, false, fill)

## OURS: without Media.pk2's art, the digit or the word in the default font,
## filling the sprite's rect, with a one-pixel dark edge.
func _draw_fallback(s: Dictionary, rect: Rect2, fill: Color, shadow: Color) -> void:
	var font := ThemeDB.fallback_font
	if font == null:
		return
	var digit := int(s["digit"])
	var text := str(digit) if digit >= 0 else String(s["file"]).capitalize()
	var size := maxi(int(rect.size.y), 6)
	var base := Vector2(rect.position.x, rect.position.y + rect.size.y * 0.85)
	for off in [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1)]:
		draw_string(font, base + off, text, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, size, shadow)
	draw_string(font, base, text, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, size, fill)
