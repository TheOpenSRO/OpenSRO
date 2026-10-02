extends Control
class_name ServerListWindow

## The login screen's server list (round 679), opened by LIST: retail's
## window 10 built from the archive's own layout and art, listing
## setting/config.yaml's servers with each one's status (ServerStatus).
##
## READ (pstitle.txt; CPSTitle, sro_client.exe):
## - The window: Title section id 10 GDR_STA_SERVERWINDOW,
##   interface\outer\server_window.ddj, 240x340, unscaled, at
##   (max(cx - 0x78, 0), max(mid - 0xaf, 0)) around the same centre line as
##   the login box (FUN_00866760, 0x8668c1..0x866959).
## - Select (id 56, UIO_CTL_SELECT) at (x + 0x15, y + 0x15e) and Cancel (id 55,
##   UIO_COMMON_CTL_CANCEL) at (x + 0x82, y + 0x15e), button.ddj 91x40.
## - The list: Server section id 51 GDR_LIST_SERVER at 7,32 200x300 in the
##   window; its slider id 54 at 214,28 20x306 (Slider section: server_up.ddj
##   0,0 20x20, server_down.ddj 0,286, server_mov.ddj thumb 0,20).
## - Columns (FUN_0080eed0(x, width), FUN_00869cd0): the name at x 15 (width
##   120) in 0xFFFFFFFF, the status at x 152 (width 45) in its band's colour;
##   the farm column (x 100) is filled only for a multi-farm list and is
##   left out. The list's default text colour 0xFFB4B4B4 (FUN_008b2ba0(3)).
## - 13 rows visible (FUN_0080e4d0(0xd)); the selection rect 0,0 204x20
##   (FUN_0080cd50), so rows 20 apart (INFERRED); the selected row's art
##   server_select.ddj, the hovered row's server_rollover.ddj.
## - LIST (FUN_00864870(1, 0)): asks for the list, pre-selects the row whose
##   name is the Server field's, fades the window and its buttons in and the
##   logo, login box, Connect and Exit out over 0.5 s, snd_window_open.
##   Cancel: the reverse, snd_window_close. Select (FUN_00866eb0): the row's
##   name into the Server field, the list closed; a double click selects too
##   (FUN_00866f80, INFERRED double click).
## - The list is asked for again every 5.0 s while it is visible
##   (ServerStatus.REFRESH_S).
##
## OURS: retail's list comes from its one gateway; this one asks each listed
## server (ServerStatus), all at once. The fades are left out (the window
## shows and hides at once); the slider's thumb is drawn where the scroll
## puts it, and the wheel and the arrows scroll.
##
## Round 681 (OURS): a `type: legacy` server is asked the original way and
## answers with its own shard list; each shard gets a row, named
## "<config name> - <shard name>" (just the config name when the two are the
## same), with its own band. Before the answer, and when there is none, the
## server has one row under its config name, as a srrevamp server does.
## Choosing any of its rows chooses the server. The content id and version
## a legacy gateway is told are read from Media.pk2 (RetailClientInfo).

signal chosen(entry: ClientConfig.ServerEntry)
signal closed()

const ID_SERVERWINDOW := 10
const ID_LIST := 51
const ID_SLIDER := 54
const ID_SELECT := 56
const ID_CANCEL := 55
const ID_SLIDER_PREV := 61
const ID_SLIDER_NEXT := 62
const ID_SLIDER_THUMB := 63
const WINDOW_DDJ := "interface\\outer\\server_window.ddj"
const SELECT_DDJ := "interface\\outer\\server_select.ddj"
const ROLLOVER_DDJ := "interface\\outer\\server_rollover.ddj"
const VISIBLE_ROWS := 13
const ROW_HEIGHT := 20
const ROW_WIDTH := 204
const COL_NAME_X := 15
const COL_NAME_W := 120
const COL_STATUS_X := 152
const COL_STATUS_W := 45
const NAME_COLOR := 0xFFFFFFFF
## The fallback window when the archive has no layout (a dev run): retail's
## size, OURS placement (centred).
const WINDOW_SIZE := Vector2(240, 340)

var _entries: Array = [] # of ClientConfig.ServerEntry
## Round 681: the rows shown, rebuilt from the answers: {entry, shard (-1
## for the server's own row), name}.
var _display: Array = []
## The selected row as (entry, shard), kept across rebuilds.
var _selected_entry := -1
var _selected_shard := -1
## Legacy: the archive's content id and version (RetailClientInfo), set by
## open() from Media.pk2 unless a test set it first; and a test's fixed key
## exchange value (-1 random).
var legacy_info := {}
var legacy_private_x := -1
var _queries: Array = [] # of ServerStatus: each row's last finished answer, or null
var _asking: Array = [] # of ServerStatus: each row's question in flight, or null
var _selected_index := -1
var _hover_index := -1
var _scroll := 0
var _refresh_left := 0.0
var _thresholds := Vector2i(ServerStatus.LO_FALLBACK, ServerStatus.HI_FALLBACK)
var _text: UiTextTable = null
var _frame: FrontEndFrame = null
var _media: Pk2Reader = null

var window: Control = null
var list: Control = null
var select_button: Button = null
var cancel_button: Button = null
var _rows: Array = [] # of {art: TextureRect, name: Label, status: Label}
var _select_tex: Texture2D = null
var _rollover_tex: Texture2D = null
var _thumb: Control = null
var _slider_rect := Rect2()
var _last_click_ms := 0
var _last_click_index := -1
var _closing := false

## Builds the window over the screen and starts asking every server.
func open(media: Pk2Reader, frame: FrontEndFrame, text: UiTextTable, entries: Array, selected: ClientConfig.ServerEntry) -> void:
	_media = media
	_frame = frame
	_text = text
	_entries = entries
	_thresholds = ServerStatus.thresholds(text)
	if legacy_info.is_empty():
		for e in entries:
			if (e as ClientConfig.ServerEntry).type == ServerStatus.TYPE_LEGACY:
				legacy_info = RetailClientInfo.from_media(media)
				print("SERVERLIST: legacy servers are told %s" % (
					"content id %d, version %d (Media.pk2: DIVISIONINFO.TXT, SV.T)" % [legacy_info["content_id"], legacy_info["version"]]
					if legacy_info.has("content_id") else "nothing: " + str(legacy_info.get("error", ""))))
				break
	print("SERVERLIST: %d servers, bands at %d %% / %d %% (textuisystem UIO_STT_SERVER_35 / _75)" % [
		entries.size(), _thresholds.x, _thresholds.y])
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	_selected_entry = entries.find(selected)
	_selected_shard = -1
	_rebuild_display()
	_scroll_to(_selected_index)
	if _frame != null:
		_frame.resized.connect(_layout)
	_layout()
	refresh_now()
	UiSounds.window_opened("server list")

func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_refresh_left -= delta
	if _refresh_left < 0.0:
		refresh_now()

## Asks every listed server for its status now (and again REFRESH_S later).
## A server still being asked is not asked twice; a row keeps its last answer
## until the new one is in.
func refresh_now() -> void:
	_refresh_left = ServerStatus.REFRESH_S
	while _queries.size() < _entries.size():
		_queries.append(null)
		_asking.append(null)
	for i in range(_entries.size()):
		if _asking[i] != null:
			continue
		var e: ClientConfig.ServerEntry = _entries[i]
		var q := ServerStatus.new()
		q.name = "Status%d" % i
		add_child(q)
		q.finished.connect(_on_status.bind(i))
		_asking[i] = q
		q.private_x = legacy_private_x
		q.start_for(e, legacy_info)
	_update_rows()

func _on_status(q: ServerStatus, why: String, i: int) -> void:
	if _closing or i >= _queries.size():
		q.queue_free()
		return
	_asking[i] = null
	var old: ServerStatus = _queries[i]
	if old != null and is_instance_valid(old):
		old.queue_free()
	_queries[i] = q
	var e: ClientConfig.ServerEntry = _entries[i]
	var b := q.band_with(_thresholds)
	var what := "no answer -> CLOSED"
	if q.answered_ok and q.server_type == ServerStatus.TYPE_LEGACY:
		var parts := PackedStringArray()
		for sh in q.shards:
			parts.append("'%s' %d/%d state %d -> %s" % [sh["name"], sh["current"], sh["capacity"], sh["state"],
				ServerStatus.Band.keys()[ServerStatus.shard_band(sh, _thresholds)]])
		what = "legacy, %d shard(s): %s" % [q.shards.size(), ", ".join(parts)]
	elif q.answered_ok:
		what = "%d/%d state %d -> %s" % [q.current, q.capacity, q.state, ServerStatus.Band.keys()[b]]
	print("SERVERLIST: %s (%s, %s) %s -- %s" % [e.name, e.gateway_address(), e.type, what, why])
	_update_rows()

## The band shown for row i: the last finished answer, or PENDING before the
## first.
func band_of(i: int) -> int:
	if i < 0 or i >= _queries.size() or _queries[i] == null:
		return ServerStatus.Band.PENDING
	var q: ServerStatus = _queries[i]
	if not q.is_done():
		return ServerStatus.Band.PENDING
	return q.band_with(_thresholds)

## The rows: a server's own row until it lists shards, then one per shard.
func _rebuild_display() -> void:
	_display.clear()
	for i in range(_entries.size()):
		var e: ClientConfig.ServerEntry = _entries[i]
		var q: ServerStatus = _queries[i] if i < _queries.size() else null
		if q != null and q.is_done() and q.answered_ok and q.server_type == ServerStatus.TYPE_LEGACY and not q.shards.is_empty():
			for k in range(q.shards.size()):
				var shard_name := str(q.shards[k]["name"])
				_display.append({"entry": i, "shard": k, "name": e.name if shard_name == e.name or shard_name == "" else "%s - %s" % [e.name, shard_name]})
		else:
			_display.append({"entry": i, "shard": -1, "name": e.name})
	_selected_index = -1
	for r in range(_display.size()):
		if _display[r]["entry"] == _selected_entry and (_display[r]["shard"] == _selected_shard or _selected_index < 0):
			_selected_index = r
	if _scroll > maxi(_display.size() - VISIBLE_ROWS, 0):
		_scroll = maxi(_display.size() - VISIBLE_ROWS, 0)

func row_count() -> int:
	return _display.size()

## Row r's band.
func display_band(r: int) -> int:
	var d: Dictionary = _display[r]
	var i: int = d["entry"]
	if int(d["shard"]) < 0:
		return band_of(i)
	return ServerStatus.shard_band((_queries[i] as ServerStatus).shards[int(d["shard"])], _thresholds)

## Row r: [name, status word, status colour].
func row_text(r: int) -> Array:
	var b := display_band(r)
	return [_display[r]["name"], ServerStatus.band_text(b, _text), ServerStatus.band_color(b)]

func close() -> void:
	if _closing:
		return
	_closing = true
	UiSounds.window_closed("server list")
	for q in _asking:
		if q != null and is_instance_valid(q):
			(q as ServerStatus).abandon("the list closed")
	closed.emit()
	queue_free()

func select_current() -> void:
	if _selected_index >= 0 and _selected_index < _display.size():
		chosen.emit(_entries[int(_display[_selected_index]["entry"])])
	close()

## Selects row r.
func _select_row(r: int) -> void:
	_selected_index = r
	if r >= 0 and r < _display.size():
		_selected_entry = _display[r]["entry"]
		_selected_shard = _display[r]["shard"]

# --- Building -----------------------------------------------------------------

func _def(section: String, id: int) -> UiLayoutParser.ControlDef:
	if _frame == null or _frame.layout == null or not _frame.layout.sections.has(section):
		return null
	return FrontEndFrame.by_id(_frame.layout.sections[section], id)

func _tex(path: String) -> Texture2D:
	return FrontEndUi.load_ddj(_media, path) if _media != null else null

func _build() -> void:
	window = Control.new()
	window.name = "ServerWindow"
	var wd := _def("Title", ID_SERVERWINDOW)
	window.size = Vector2(wd.rect.size) if wd != null else WINDOW_SIZE
	add_child(window)
	var art_tex := _tex(wd.ddj if wd != null and wd.ddj != "" else WINDOW_DDJ)
	if art_tex != null:
		var art := TextureRect.new()
		art.texture = art_tex
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_SCALE
		art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		window.add_child(art)
	else:
		var plate := FrontEndUi.plate()
		plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		window.add_child(plate)
	_select_tex = _tex(SELECT_DDJ)
	_rollover_tex = _tex(ROLLOVER_DDJ)

	var ld := _def("Server", ID_LIST)
	list = Control.new()
	list.name = "List"
	list.position = Vector2(ld.rect.position) if ld != null else Vector2(7, 32)
	list.size = Vector2(ld.rect.size) if ld != null else Vector2(200, 300)
	list.mouse_filter = Control.MOUSE_FILTER_STOP
	list.clip_contents = true
	list.gui_input.connect(_on_list_input)
	list.mouse_exited.connect(func() -> void:
		_hover_index = -1
		_update_rows())
	window.add_child(list)
	var font_size: int = UiBuilder.FONT_SIZES[clampi(ld.font_index if ld != null else 0, 0, UiBuilder.FONT_SIZES.size() - 1)]
	for r in range(VISIBLE_ROWS):
		var row_art := TextureRect.new()
		row_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		row_art.stretch_mode = TextureRect.STRETCH_SCALE
		row_art.position = Vector2(0, r * ROW_HEIGHT)
		row_art.size = Vector2(ROW_WIDTH, ROW_HEIGHT)
		row_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		list.add_child(row_art)
		var name_label := _cell(list, COL_NAME_X, COL_NAME_W, r, font_size)
		var status_label := _cell(list, COL_STATUS_X, COL_STATUS_W, r, font_size)
		_rows.append({"art": row_art, "name": name_label, "status": status_label})

	_build_slider()

	var sd := _def("Title", ID_SELECT)
	select_button = _button(sd, "UIO_CTL_SELECT", "Select")
	select_button.pressed.connect(select_current)
	add_child(select_button)
	var cd := _def("Title", ID_CANCEL)
	cancel_button = _button(cd, "UIO_COMMON_CTL_CANCEL", "Cancel")
	cancel_button.pressed.connect(close)
	add_child(cancel_button)

## One cell, added to `parent` before it is sized (round 679's review: sized
## outside the tree, a 20-tall row came out ~23).
func _cell(parent: Control, x: int, w: int, r: int, font_size: int) -> Label:
	var l := Label.new()
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.clip_text = true
	l.add_theme_font_size_override("font_size", font_size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	l.position = Vector2(x, r * ROW_HEIGHT)
	l.size = Vector2(w, ROW_HEIGHT)
	return l

func _build_slider() -> void:
	var sd := _def("Server", ID_SLIDER)
	_slider_rect = Rect2(Vector2(sd.rect.position), Vector2(sd.rect.size)) if sd != null else Rect2(214, 28, 20, 306)
	var prev := _art_control(_def("Slider", ID_SLIDER_PREV), "interface\\outer\\server_up.ddj", Rect2(0, 0, 20, 20))
	var next := _art_control(_def("Slider", ID_SLIDER_NEXT), "interface\\outer\\server_down.ddj", Rect2(0, 286, 20, 20))
	_thumb = _art_control(_def("Slider", ID_SLIDER_THUMB), "interface\\outer\\server_mov.ddj", Rect2(0, 20, 20, 20))
	for c in [prev, next, _thumb]:
		(c as Control).position += _slider_rect.position
		window.add_child(c)
	prev.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_scroll_by(-1))
	next.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_scroll_by(1))

func _art_control(d: UiLayoutParser.ControlDef, fallback_ddj: String, fallback_rect: Rect2) -> TextureRect:
	var t := TextureRect.new()
	t.texture = _tex(d.ddj if d != null and d.ddj != "" else fallback_ddj)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_SCALE
	t.position = Vector2(d.rect.position) if d != null else fallback_rect.position
	t.size = Vector2(d.rect.size) if d != null else fallback_rect.size
	t.mouse_filter = Control.MOUSE_FILTER_STOP
	return t

func _button(d: UiLayoutParser.ControlDef, key: String, fallback: String) -> Button:
	var b := Button.new()
	var t := fallback
	if _text != null and _text.has(key):
		t = _text.get_text(key, fallback)
	b.text = t
	b.size = Vector2(d.rect.size) if d != null else Vector2(91, 40)
	b.custom_minimum_size = b.size
	b.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[clampi(d.font_index if d != null else 2, 0, UiBuilder.FONT_SIZES.size() - 1)])
	b.add_theme_color_override("font_color", d.font_color if d != null else Color.WHITE)
	var base := d.ddj if d != null and d.ddj != "" else "interface\\outer\\button.ddj"
	var styles := ["normal", "hover", "pressed"]
	var suffixes := ["", "_focus", "_press"]
	for i in range(3):
		var tex := _tex(base.get_basename() + suffixes[i] + ".ddj")
		if tex == null:
			continue
		var sb := StyleBoxTexture.new()
		sb.texture = tex
		b.add_theme_stylebox_override(styles[i], sb)
		if i == 1:
			b.add_theme_stylebox_override("focus", sb)
	return b

## READ placement (FUN_00866760): around the centre line between the bands.
func _layout() -> void:
	var c := Vector2i(int(get_viewport_rect().size.x) >> 1, int(get_viewport_rect().size.y) >> 1)
	if _frame != null and _frame.def(FrontEndFrame.ID_SCREENUP) != null:
		c = _frame.centre_line()
		window.position = Vector2(maxi(c.x - 0x78, 0), maxi(c.y - 0xaf, 0))
	else:
		window.position = Vector2(c) - window.size * 0.5
	select_button.position = window.position + Vector2(0x15, 0x15e)
	cancel_button.position = window.position + Vector2(0x82, 0x15e)

# --- Rows ---------------------------------------------------------------------

func _update_rows() -> void:
	_rebuild_display()
	for r in range(_rows.size()):
		var i := _scroll + r
		var row: Dictionary = _rows[r]
		if i >= _display.size():
			(row["name"] as Label).text = ""
			(row["status"] as Label).text = ""
			(row["art"] as TextureRect).texture = null
			continue
		var t := row_text(i)
		(row["name"] as Label).text = t[0]
		(row["name"] as Label).add_theme_color_override("font_color", ServerStatus.argb_color(NAME_COLOR))
		(row["status"] as Label).text = t[1]
		(row["status"] as Label).add_theme_color_override("font_color", t[2])
		(row["art"] as TextureRect).texture = _select_tex if i == _selected_index else (_rollover_tex if i == _hover_index else null)
	if _thumb != null:
		var span := _slider_rect.size.y - 60.0
		var steps := maxi(_display.size() - VISIBLE_ROWS, 0)
		var f := float(_scroll) / float(steps) if steps > 0 else 0.0
		_thumb.position = _slider_rect.position + Vector2(0, 20.0 + span * f)

func _row_at(pos: Vector2) -> int:
	var r := int(floor(pos.y / ROW_HEIGHT))
	if pos.x < 0 or pos.x >= ROW_WIDTH or r < 0 or r >= VISIBLE_ROWS:
		return -1
	var i := _scroll + r
	return i if i < _display.size() else -1

func _on_list_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion:
		var h := _row_at((ev as InputEventMouseMotion).position)
		if h != _hover_index:
			_hover_index = h
			_update_rows()
	elif ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
		var mb := ev as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_scroll_by(-1)
			MOUSE_BUTTON_WHEEL_DOWN:
				_scroll_by(1)
			MOUSE_BUTTON_LEFT:
				var i := _row_at(mb.position)
				if i < 0:
					return
				var now := Time.get_ticks_msec()
				var twice := mb.double_click or (i == _last_click_index and now - _last_click_ms < 400)
				_last_click_ms = now
				_last_click_index = i
				_select_row(i)
				_update_rows()
				if twice:
					select_current()

func _scroll_by(d: int) -> void:
	_scroll = clampi(_scroll + d, 0, maxi(_display.size() - VISIBLE_ROWS, 0))
	_update_rows()

func _scroll_to(i: int) -> void:
	if i < 0:
		return
	if i < _scroll:
		_scroll = i
	elif i >= _scroll + VISIBLE_ROWS:
		_scroll = i - VISIBLE_ROWS + 1
	_scroll_by(0)

func _unhandled_key_input(ev: InputEvent) -> void:
	var k := ev as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	match k.keycode:
		KEY_ESCAPE:
			close()
		KEY_ENTER, KEY_KP_ENTER:
			select_current()
		KEY_UP:
			if _selected_index > 0:
				_select_row(_selected_index - 1)
				_scroll_to(_selected_index)
		KEY_DOWN:
			if _selected_index < _display.size() - 1:
				_select_row(_selected_index + 1)
				_scroll_to(_selected_index)
		_:
			return
	get_viewport().set_input_as_handled()
