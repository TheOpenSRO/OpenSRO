extends Control
class_name HudRegionView

## The area banner (round 703): "Donwhang / A gateway city of Silk Road that
## connects China and Central Asia" across the top of the screen when the
## player walks into a named area. ginterface.txt's GDR_REGION_INFO_VIEW, a
## CIFRegionView, interface child 0x53 (ID 83), inside `#ifdef
## EUROPE_SYSTEM`. docs/protocol/notice_banner.md has every address.
##
## Labels: READ = read from the binary or the data; MEASURED = counted from
## real files or reference pixels; INFERRED = follows from what was read but
## was not read itself; OURS = srrevamp's choice.
##
## **When (READ).** Every position update of the player
## (GlobalDataManager::FUN_00783610) and the world's set-up on entry
## (0x786f30, at 0x787609..0x787660) take the player's region id (+0x7c),
## and when it is not 0 ask 0x665aa0 whether to show:
##
##   - the region's code from CGame's map (CGame::FUN_00842a00, filled from
##     `textdata\regioncode.txt` by Game::FUN_00844310: a row is kept when
##     its service column is not 0 and its region id column is set, unless
##     the code is exactly "xxx");
##   - no code (an unnamed region): the remembered code (+0x36c) is cleared
##     and nothing shows -- so walking out of a town into unnamed ground and
##     back shows the town again;
##   - the remembered code: nothing shows;
##   - another code: 0x665d00 sets the texts and remembers the code, and
##     0x6526e0(0, 255, 0.5 s, 0, 1) fades the window in from 0.
##
## So it is not only towns: every one of regioncode.txt's 147 codes (over
## 1,862 region ids; fields, dungeons, ferries, fortresses) has its banner.
## MEASURED: all 147 have a `_01` text in textzonename.txt. Id 22478 is
## listed twice (RN_JUPITER_GOD, then RN_JUPITER_SEA; the first wins), and
## the 14 ids above 32767 and the one negative id (dungeons) cannot come out
## of TextZoneNameReader.region_id(x, y) in this client.
##
## **Why the window exists (READ).** It is inside ginterface.txt's `#ifdef
## EUROPE_SYSTEM`, but 0x783667..0x783685 fetches child 0x53 and calls
## 0x665aa0 and 0x665d00 on it with no NULL check, so the shipping client
## has the window: the build defines EUROPE_SYSTEM. (frontend_frame.gd and
## docs/protocol/intro_script.md inferred the `#else` art for pstitle.txt;
## that conflict is recorded in notice_banner.md. How the client resolves
## the symbol -- its IFTVariable lookup -- is not read.)
##
## **The texts (READ, 0x665d00).** The code plus `_01` (`0xda10ac`) is the
## title (child 1), plus `_02` the description (child 0xb), plus `_03` the
## third line (child 0xc), each through the text manager 0x8c9bb0 (which
## loads textzonename.txt with the other text tables). The description and
## third line are blanked when their text is exactly "xxx" (`0xd81d38`,
## compared with length 3). A fortress town's third line is replaced by
## UIIT_MSG_FORTRESS_TOWN_GUILD_NAME with the owning guild (OPEN here: this
## client keeps no fortress data, so the line keeps its `_03` text).
##
## **Timing (READ).** The fade (0x6552f0) is linear, truncated to a byte:
## alpha = from * (1 - t) + to * t over 0.5 s (`0xe1b7e0`). vslot_012
## (0x6656f0) starts the fade out, 255 -> 0 over 0.5 s, once more than
## 3000 ms have passed since the texts were set (+0x388); the fade's end
## hides the window (0x652850: target alpha 0 and +0x20c set). The texts
## fade with it (a child's alpha is its own times its parent's, 0x652670).
##
## **Layout (READ, 0x6657f0 / 0x665740 on a W-wide screen; W/2 by `shr` in
## 0x6657f0, by `sar` at 0x66575a in 0x665740 -- the same for any screen).**
##
##   window   744 x 104 (0x2e8 x 0x68) at (W/2 - 372, 95)
##   title    child 1 at x = W/2 - trunc(w * 1.5 * 0.5),
##            y = 119 - trunc(h * 1.5 * 0.25), w x h its text's extent
##   line 2   child 0xb at (W/2 - 343, 156), 691 x 13, centred both ways
##   line 3   child 0xc at (W/2 - 214, 177), 427 x 11, centred both ways
##
## (`0xb42d10` truncates: cvttsd2si.) The window's art is ginterface.txt's
## `interface\game\area_deco.ddj` -- MEASURED: 708 x 104, A8R8G8B8, one
## colour (0, 37, 73), alpha 4 at both ends rising to 151 across the middle
## 110 columns, the same in every row. INFERRED: CIFWnd draws it over the
## window's rect, so it is stretched to 744 wide.
##
## **The text (READ, resinfo\ifregionview.txt and Create 0x665be0).**
##
##   title    GDR_STA_REGIONNAME   FontIndex 4 (20 px), FontColor
##            (255,61,253,255) -- cyan (61, 253, 255) -- drawn at scale 1.5
##            (+0xcc = 1.5f, `0xd819ec`), text flags 3: weight 600 and the
##            drop shadow
##   line 2   GDR_STA_REGIONEXPLAIN FontIndex 3 (15 px), white, flags 1:
##            the drop shadow
##   line 3   GDR_STA_LVEXPLAIN    FontIndex 1 (11 px), (255, 255, 92),
##            flags 1
##
## The shadow is the glyph drawn first one screen pixel right and down in
## black at the text's alpha (0x8b2290). A glyph drawn at a scale other than
## 1 is sampled linearly, at 1 point-sampled (0x8b2290's sampler states), so
## the title is the 20 px face's one-bit glyphs magnified 1.5x and smoothed
## -- the "pixel font" look.

const UiBuilder = preload("res://scripts/ui/ui_builder.gd")

const REGION_CODE_PATH := "server_dep\\silkroad\\textdata\\regioncode.txt"
const ZONE_TEXT_PATH := "server_dep\\silkroad\\textdata\\textzonename.txt"
const ART_DDJ := "interface\\game\\area_deco.ddj"

const WINDOW_SIZE := Vector2(744, 104)
const WINDOW_LEFT := 372
const WINDOW_Y := 95
const TITLE_BASE_Y := 119
const TITLE_SCALE := 1.5
const LINE2_LEFT := 343
const LINE2_Y := 156
const LINE2_SIZE := Vector2(691, 13)
const LINE3_LEFT := 214
const LINE3_Y := 177
const LINE3_SIZE := Vector2(427, 11)

const TITLE_FONT_INDEX := 4
const LINE2_FONT_INDEX := 3
const LINE3_FONT_INDEX := 1
const TITLE_COLOR := Color(61.0 / 255.0, 253.0 / 255.0, 1.0)
const LINE2_COLOR := Color.WHITE
const LINE3_COLOR := Color(1.0, 1.0, 92.0 / 255.0)

const FADE_MS := 500
const HOLD_MS := 3000

## {region id -> code}.
var codes: Dictionary = {}
## The code shown last (+0x36c); "" after an unnamed region.
var current_code := ""
var title := ""
var line2 := ""
var line3 := ""

var _texts: UiTextTable
var _art: Texture2D
## The title's face and its bold file (null: the synthetic bold, HudNotice.draw_bold).
var _title_font: Font
var _title_bold: Font
var _line2_font: Font
var _line3_font: Font
## The window's alpha, 0..255, and the fade it is in.
var _alpha := 0
var _fade_from := 0
var _fade_to := 0
var _fade_ms := 0
var _fade_elapsed := 0
var _fading := false
## ms since the texts were set; -1 once the fade out has started.
var _since_set := -1
## Whether the loading screen covers the HUD now (World3D sets it; null:
## never). OURS (round 703's review, M2): retail's world set-up (0x786f30)
## and its loading state were not read, but a world entry or a teleport here
## keeps "NOW LOADING" up for 5-7 s, longer than the banner's whole 3.5 s,
## so a banner raised under it is held and starts -- fade, hold and all --
## the frame the screen lifts.
var covered := Callable()
var _held := false

var _title_layer: Control
var _text_layer: UiBuilder.TextLayer

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The title is magnified 1.5x and sampled linearly (0x8b2290).
	_title_layer = Control.new()
	_title_layer.name = "TitleLayer"
	_title_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title_layer.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_title_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_title_layer.draw.connect(_draw_title)
	add_child(_title_layer)
	# The two lines are drawn 1:1, point-sampled.
	_text_layer = UiBuilder.TextLayer.new(_draw_lines)
	add_child(_text_layer)

## Reads the region codes, the zone texts, the art and the faces from the
## builder's archive. Without one (tests) set_tables gives the data.
func setup(builder: UiBuilder) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false
	var font: Font = null
	if builder != null:
		font = builder.font_at(0)
		_art = builder.load_texture(ART_DDJ)
		var archive := builder.media_archive()
		if archive != null:
			var t := Time.get_ticks_msec()
			var entry := ObjectLoader.find_file(archive, REGION_CODE_PATH)
			if entry != null:
				codes = parse_region_codes(archive.read_file(entry))
			entry = ObjectLoader.find_file(archive, ZONE_TEXT_PATH)
			if entry != null:
				_texts = UiTextTable.parse(archive.read_file(entry))
			print("HudRegionView: %d region codes from %s, %d zone texts, in %d ms" % [
				codes.size(), REGION_CODE_PATH, _texts.count() if _texts != null else 0,
				Time.get_ticks_msec() - t])
	if font == null:
		font = ThemeDB.fallback_font
	_title_font = font
	_title_bold = HudNotice.bold_file(font)
	_line2_font = font
	_line3_font = font

## The tables without an archive (tests): {region id -> code} and the text
## table the `_01`/`_02`/`_03` keys resolve through.
func set_tables(region_codes: Dictionary, texts: UiTextTable) -> void:
	codes = region_codes
	_texts = texts

## Parses regioncode.txt (READ: Game::FUN_00844310): tab-separated ANSI
## rows of service, region id, code name and a Korean note. A row is kept
## when atol(service) is not 0 and the region id column is not empty, and
## its code is not exactly "xxx"; the first row of an id wins (a std::map
## insert, 0x8433c0).
static func parse_region_codes(data: PackedByteArray) -> Dictionary:
	var out := {}
	if data.is_empty():
		return out
	# The rows are ASCII up to the Korean note (CP949 bytes), which is not
	# read; decoded byte for byte, the note never matters.
	var text := data.get_string_from_ascii()
	for raw in text.split("\n"):
		var cols := raw.split("\t")
		if cols.size() < 3:
			continue
		if _atol(cols[0]) == 0 or cols[1].strip_edges() == "":
			continue
		var code := cols[2].strip_edges()
		if code == "xxx":
			continue
		var id := _atol(cols[1])
		if not out.has(id):
			out[id] = code
	return out

## C's atol: leading blanks, an optional sign, then digits; 0 for none.
static func _atol(s: String) -> int:
	var t := s.strip_edges()
	var sign := 1
	var i := 0
	if i < t.length() and (t[i] == "-" or t[i] == "+"):
		sign = -1 if t[i] == "-" else 1
		i += 1
	var v := 0
	while i < t.length() and t[i] >= "0" and t[i] <= "9":
		v = v * 10 + (t.unicode_at(i) - 48)
		i += 1
	return sign * v

## The code of a region, or "" for an unnamed one.
func code_for(region_id: int) -> String:
	return String(codes.get(region_id, ""))

## 0x665aa0 and the callers' show: the player is now in `region_id`.
## Returns true when the banner is raised.
func enter_region(region_id: int) -> bool:
	if region_id == 0:
		return false
	var code := code_for(region_id)
	if code == "":
		current_code = ""
		return false
	if code == current_code:
		return false
	show_code(code)
	return true

## 0x665d00 then 0x6526e0(0, 255, 0.5, 0, 1): the code's texts, faded in
## from 0.
func show_code(code: String) -> void:
	current_code = code
	title = _text(code + "_01")
	line2 = _blank_xxx(_text(code + "_02"))
	line3 = _blank_xxx(_text(code + "_03"))
	if _is_covered():
		# Held until the loading screen lifts (see `covered`).
		_held = true
		_since_set = -1
		_fading = false
		_alpha = 0
		visible = false
		print("REGION BANNER: %s title '%s' line2 '%s' line3 '%s' held under the loading screen at frame %d" % [
			code, title, line2, line3, Engine.get_frames_drawn()])
		return
	_raise()
	print("REGION BANNER: %s title '%s' line2 '%s' line3 '%s' at frame %d" % [code, title, line2, line3,
		Engine.get_frames_drawn()])

func _raise() -> void:
	_held = false
	_since_set = 0
	_start_fade(0, 255)
	visible = true
	_redraw()

func _is_covered() -> bool:
	return covered.is_valid() and bool(covered.call())

## Whether a banner is waiting for the loading screen to lift.
func held() -> bool:
	return _held

## A key's text, or "" when the table has none (INFERRED: the text manager's
## miss is not read).
func _text(key: String) -> String:
	if _texts == null or not _texts.has(key):
		return ""
	return _texts.get_text(key)

static func _blank_xxx(s: String) -> String:
	return "" if s == "xxx" else s

func _start_fade(from: int, to: int) -> void:
	_fade_from = from
	_fade_to = to
	_fade_ms = FADE_MS
	_fade_elapsed = 0
	_fading = true
	_alpha = from

## The fade's alpha after `elapsed` of `duration` ms (0x6552f0).
static func fade_alpha(from: int, to: int, elapsed: int, duration: int) -> int:
	if elapsed <= 0:
		return from
	if elapsed >= duration:
		return to
	var t := float(elapsed) / float(duration)
	return int(float(from) * (1.0 - t) + float(to) * t)

func alpha() -> int:
	return _alpha

func _process(delta: float) -> void:
	if _held:
		if not _is_covered():
			_raise()
			print("REGION BANNER: %s raised as the loading screen lifted, at frame %d" % [current_code,
				Engine.get_frames_drawn()])
		return
	if visible:
		advance(int(delta * 1000.0))

## One update of `ms` (vslot_012 and the fade's step).
func advance(ms: int) -> void:
	if _since_set >= 0:
		_since_set += ms
		if _since_set > HOLD_MS:
			_since_set = -1
			_start_fade(255, 0)
			print("REGION BANNER: %s fades out at frame %d" % [current_code, Engine.get_frames_drawn()])
			# The fade starts on this update's step, as 0x6528a0 runs first.
			ms = 0
	if _fading:
		_fade_elapsed += ms
		var a := fade_alpha(_fade_from, _fade_to, _fade_elapsed, _fade_ms)
		if _fade_elapsed >= _fade_ms:
			_fading = false
			if _fade_to == 0:
				visible = false
		if a != _alpha:
			_alpha = a
			_redraw()

func _redraw() -> void:
	queue_redraw()
	_title_layer.queue_redraw()
	_text_layer.queue_redraw()

func _half_width() -> int:
	return int(size.x) >> 1

## The window's rect on the parent (0x6657f0).
func window_rect() -> Rect2:
	return Rect2(float(_half_width() - WINDOW_LEFT), float(WINDOW_Y), WINDOW_SIZE.x, WINDOW_SIZE.y)

## Where the title's text starts (0x665740), for its unscaled extent.
static func title_origin(half_w: int, extent: Vector2) -> Vector2:
	return Vector2(float(half_w - int(extent.x * TITLE_SCALE * 0.5)),
		float(TITLE_BASE_Y - int(extent.y * TITLE_SCALE * 0.25)))

func _title_extent() -> Vector2:
	var px: int = UiBuilder.FONT_SIZES[TITLE_FONT_INDEX]
	var face: Font = _title_bold if _title_bold != null else _title_font
	return Vector2(ceilf(HudNotice.bold_width(_title_font, _title_bold, title, px)), face.get_height(px))

## The banner's parts on the parent, for the QA log: window, title, lines.
func layout() -> Dictionary:
	var hw := _half_width()
	var e := _title_extent() if _title_font != null else Vector2.ZERO
	return {
		"window": window_rect(),
		"title": Rect2(title_origin(hw, e), e * TITLE_SCALE),
		"line2": Rect2(float(hw - LINE2_LEFT), float(LINE2_Y), LINE2_SIZE.x, LINE2_SIZE.y),
		"line3": Rect2(float(hw - LINE3_LEFT), float(LINE3_Y), LINE3_SIZE.x, LINE3_SIZE.y),
	}

func _draw() -> void:
	if _art != null:
		draw_texture_rect(_art, window_rect(), false, Color(1, 1, 1, float(_alpha) / 255.0))

func _draw_title(_unused = null) -> void:
	if _title_font == null or title == "":
		return
	var px: int = UiBuilder.FONT_SIZES[TITLE_FONT_INDEX]
	var at := title_origin(_half_width(), _title_extent())
	var a := float(_alpha) / 255.0
	var face: Font = _title_bold if _title_bold != null else _title_font
	var base := Vector2(0, face.get_ascent(px))
	var s := Vector2(TITLE_SCALE, TITLE_SCALE)
	# The shadow, one screen pixel right and down, then the glyphs.
	_title_layer.draw_set_transform(at + Vector2.ONE, 0.0, s)
	HudNotice.draw_bold(_title_layer, _title_font, _title_bold, base, title, px, Color(0, 0, 0, a))
	_title_layer.draw_set_transform(at, 0.0, s)
	HudNotice.draw_bold(_title_layer, _title_font, _title_bold, base, title, px, Color(TITLE_COLOR, a))
	_title_layer.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_lines(on: CanvasItem) -> void:
	var hw := _half_width()
	_draw_centred(on, line2, _line2_font, UiBuilder.FONT_SIZES[LINE2_FONT_INDEX], LINE2_COLOR,
		Rect2(float(hw - LINE2_LEFT), float(LINE2_Y), LINE2_SIZE.x, LINE2_SIZE.y))
	_draw_centred(on, line3, _line3_font, UiBuilder.FONT_SIZES[LINE3_FONT_INDEX], LINE3_COLOR,
		Rect2(float(hw - LINE3_LEFT), float(LINE3_Y), LINE3_SIZE.x, LINE3_SIZE.y))

## A line centred both ways in its static's rect (HAlign 1, VAlign 1), with
## its drop shadow.
func _draw_centred(on: CanvasItem, s: String, font: Font, px: int, color: Color, r: Rect2) -> void:
	if font == null or s == "":
		return
	var w := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x
	var h := font.get_height(px)
	var at := Vector2(floorf(r.position.x + (r.size.x - w) / 2.0),
		floorf(r.position.y + (r.size.y - h) / 2.0) + font.get_ascent(px))
	var a := float(_alpha) / 255.0
	on.draw_string(font, at + Vector2.ONE, s, HORIZONTAL_ALIGNMENT_LEFT, -1, px, Color(0, 0, 0, a))
	on.draw_string(font, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, px, Color(color, a))
