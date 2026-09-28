extends SceneTree

## The interface sounds of round 615, measured through the running "Audio"
## autoload: which synthetic sound is playing after each action. Synthetic
## effect rows, synthetic WAVs and synthetic layouts only (docs/LEGAL.md);
## every click and key goes through Viewport.push_input:
##   godot4 --headless --path client --script res://scripts/audio/ui_sounds_test.gd
##
## Checked:
## - I (a hotkey) opens the main popup and sounds the window-open row once;
##   I again closes it and sounds the window-close row once;
## - a key that switches the popup's tab sounds the open again (0x79b062);
## - a plain button (the equipment pane's avatar switch) is silent;
## - Q (the quest window, 0x7990e0) is silent;
## - the level-up plays UI:snd_levup:-:CHINESS:-:-;
## - the equip-token, drop-token and durability rules on synthetic type ids;
## - the Option window (a synthetic optionwnd.2dt with the real ids): its
##   Audio tab's sliders and mute boxes drive the three buses, Default sets
##   50/50/50, and Cancel puts the saved values back.
##
## Every new script is reached through load / call / get, so a tree without
## them FAILS here rather than failing to parse.

const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"
const UI_SOUNDS_PATH := "res://scripts/audio/ui_sounds.gd"
const READER_PATH := "res://scripts/ui/twodt_reader.gd"
const RECORD := 0x3d0
const MFRAME := "interface\\frame\\mframe_wnd_"
const POPUP_LAYOUT := "resinfo\\ifmainpopup.txt"

## Synthetic rows: key -> path (made up here; the keys are the client's).
const ROWS := {
	"UI:snd_window_open:-:-:-:-": "prim\\snd\\test\\t_open.wav",
	"UI:snd_window_close:-:-:-:-": "prim\\snd\\test\\t_close.wav",
	"UI:snd_levup:-:CHINESS:-:-": "prim\\snd\\test\\t_levup.wav",
	"UI:snd_button_click:-:-:-:-": "prim\\snd\\test\\t_click.wav",
}

var _failures := 0
var _svc: Node
var _streams: Dictionary = {}

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

var _ran := false
func _process(_delta: float) -> bool:
	if not _ran:
		_ran = true
		_start()
	return false

func _start() -> void:
	await _run()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

# --- the audio side ---------------------------------------------------------------

func _install_audio() -> bool:
	_svc = root.get_node_or_null("Audio")
	_check(_svc != null and _svc.has_method("set_effect_table"), "the probe: the 'Audio' autoload runs")
	if _svc == null:
		return false
	var st: GDScript = load("res://scripts/audio/sound_table.gd")
	var bank: GDScript = load("res://scripts/audio/audio_bank.gd")
	var table := {}
	for key in ROWS:
		var wav := AudioStreamWAV.new()
		wav.format = AudioStreamWAV.FORMAT_16_BITS
		wav.mix_rate = 22050
		var pcm := PackedByteArray()
		pcm.resize(44100)
		wav.data = pcm
		bank.inject_for_test(ROWS[key], wav)
		_streams[key] = wav
		var row = st.Row.new()
		row.volume = 0.8
		row.path = ROWS[key]
		table[key] = [row]
	_svc.set_effect_table(table)
	return true

func _stop_all() -> void:
	for c in _svc.get_children():
		if c is AudioStreamPlayer or c is AudioStreamPlayer3D:
			c.stop()

## How many voices are playing the synthetic sound of `key`.
func _playing(key: String) -> int:
	var n := 0
	for c in _svc.get_children():
		if (c is AudioStreamPlayer) and c.playing and c.stream == _streams.get(key):
			n += 1
	return n

func _any_playing() -> int:
	var n := 0
	for key in ROWS:
		n += _playing(key)
	return n

# --- fixtures ----------------------------------------------------------------------

func _control(control_name: String, type: String, rect: String, ddj: String = "", id: int = 0) -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"%s\"\n\t\tID=INTEGER,\"%d\"\n\t\tRect=RECT,\"%s\"\n\t\tText=STRING,\"\"\n\t}\n" % [
		control_name, type, ddj, id, rect]

func _layout(body: String) -> String:
	return "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n%s}\n" % body

func _registry() -> String:
	return _layout(_control("GDR_MAINPOPUP", "CIFMainPopup", "595,262,388,408", MFRAME, 25))

func _mainpopup() -> String:
	var body := ""
	for pane in [["GDR_APPRENTICESHIP", "CIFApprenticeShip", 77, "13,38,365,355"],
			["GDR_PLAYERINFO", "CIFPlayerInfo", 75, "13,38,364,356"],
			["GDR_ACTION", "CIFAction", 74, "13,38,364,357"],
			["GDR_SKILL", "CIFSkill", 73, "13,63,364,333"],
			["GDR_PARTY", "CIFParty", 72, "13,38,364,337"],
			["GDR_EQUIPMENT", "CIFEquipment", 71, "198,41,178,355"],
			["GDR_INVENTORY", "CIFInventory", 70, "13,63,176,333"]]:
		body += _control(pane[0], pane[1], pane[3], "", pane[2])
	body += _control("GDR_MAINPOPUP_BG_TILE", "CIFStatic", "40,154,308,124", "", 3)
	return _layout(body)

func _single(frame: String, rect: String) -> String:
	return _layout(_control(frame, "CIFFrame", rect, "", 1))

func _equipment() -> String:
	return _layout(_control("GDR_EQ_BTN_CHANGE_EQUIP_SLOT", "CIFButton", "1,305,40,40", "", 14)
		+ _control("GDR_EQ_BTN_CHANGE_AVATAR_SLOT", "CIFButton", "1,305,40,40", "", 13)
		+ _control("GDR_EQ_FRAME", "CIFFrame", "0,0,178,355", "", 4))

func _ifdef_key(path: String, defines: Array) -> String:
	return "%s%s%s" % [path, char(1), char(2).join(PackedStringArray(defines))]

func _rec(f: Dictionary) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(RECORD)
	b.fill(0)
	for pair in [[0x000, "name"], [0x140, "tex"], [0x240, "textid"]]:
		var bytes: PackedByteArray = str(f.get(pair[1], "")).to_ascii_buffer()
		for i in bytes.size():
			b[pair[0] + i] = bytes[i]
	b.encode_u32(0x340, f.get("type", 5))
	b.encode_u32(0x344, f.get("id", 0))
	b.encode_u32(0x348, f.get("parent", 0))
	b.encode_u32(0x34c, f.get("gp", 0))
	b.encode_u32(0x358, 0xffffffff)
	var r: Rect2i = f.get("rect", Rect2i())
	b.encode_s32(0x35c, r.position.x)
	b.encode_s32(0x360, r.position.y)
	b.encode_s32(0x364, r.size.x)
	b.encode_s32(0x368, r.size.y)
	b.encode_u32(0x38c, f.get("group", 0))
	b.encode_u32(0x390, f.get("pane", 0xffffffff))
	b.encode_u32(0x394, 1 if f.get("root", false) else 0)
	return b

## optionwnd.2dt's window, tabs, buttons, panes and audio page: the ids,
## types, parents and rects of the real file's records; no art, no text.
func _optionwnd() -> PackedByteArray:
	var recs := [{"type": 0, "id": 98, "name": "CNIFOption", "root": true, "rect": Rect2i(49, 60, 700, 500), "textid": "UIIT_CTL_OPTION"}]
	for b in [[5, 143], [6, 275], [8, 406], [9, 537]]:
		recs.append({"type": 4, "id": b[0], "parent": 98, "rect": Rect2i(b[1], 521, 112, 24)})
	for t in [[10, 79, 78], [14, 204, 269], [15, 329, 109], [16, 454, 149]]:
		recs.append({"type": 16, "id": t[0], "parent": 98, "rect": Rect2i(t[1], 105, 120, 24), "group": 10, "pane": t[2]})
	recs.append({"type": 18, "id": 149, "parent": 98, "rect": Rect2i(62, 144, 668, 376)})
	recs.append({"type": 18, "id": 269, "parent": 98, "rect": Rect2i(63, 132, 669, 264)})
	for f in [[250, 136, 173, 170], [259, 227, 264, 261], [264, 318, 355, 352]]:
		recs.append({"type": 1, "id": f[0], "parent": 269, "gp": 98, "rect": Rect2i(66, f[1], 665, 76)})
		recs.append({"type": 11, "id": 254, "parent": f[0], "gp": 269, "rect": Rect2i(695, f[2], 16, 16)})
		recs.append({"type": 19, "id": 258, "parent": f[0], "gp": 269, "rect": Rect2i(79, f[3], 520, 24),
			"tex": "interface\\option\\opt_volume2.ddj"})
	recs.append({"type": 18, "id": 109, "parent": 98, "rect": Rect2i(62, 127, 655, 378)})
	recs.append({"type": 18, "id": 78, "parent": 98, "rect": Rect2i(62, 226, 662, 287)})
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, recs.size())
	for r in recs:
		out.append_array(_rec(r))
	return out

func _builder() -> UiBuilder:
	var builder := UiBuilder.new(null, null)
	var cache: Dictionary = builder.get("_layout_cache")
	cache[_ifdef_key(POPUP_LAYOUT, ["APPLY_MENTOR_SYSTEM"])] = UiLayoutParser.parse(_mainpopup(), true, PackedStringArray(["APPLY_MENTOR_SYSTEM"]))
	cache["resinfo\\ifinventory.txt"] = UiLayoutParser.parse(_single("GDR_INVENTORY_FRAME", "0,0,176,308"))
	cache["resinfo\\ifequipment.txt"] = UiLayoutParser.parse(_equipment())
	cache["resinfo\\ifplayerinfo_trijob2.txt"] = UiLayoutParser.parse(_single("GDR_PI_SUBFRAME", "0,0,364,356"))
	cache["resinfo\\ifskill.txt"] = UiLayoutParser.parse(_single("GDR_SKILL_FRAME", "0,0,364,333"))
	cache["resinfo\\ifaction.txt"] = UiLayoutParser.parse(_single("GDR_ACTION_BG_CTRL", "0,0,364,117"))
	cache["resinfo\\ifparty.txt"] = UiLayoutParser.parse(_single("GDR_PARTY_FRAMEL", "0,0,364,303"))
	cache["resinfo\\ifapprenticeship.txt"] = UiLayoutParser.parse(_single("GDR_APPRENTICESHIP_FRAMEL", "0,0,364,303"))
	builder.set("_window_registry", UiLayoutParser.parse(_registry()))
	builder.set("_window_registry_loaded", true)
	builder.set("_window_registry_data", _registry())
	var twodt = builder.get("_twodt_cache")
	var Reader = load(READER_PATH)
	if twodt is Dictionary and Reader != null:
		twodt["res_ui\\optionwnd.2dt"] = Reader.parse(_optionwnd())
	return builder

# --- input -------------------------------------------------------------------------

func _mouse(at: Vector2, pressed: bool) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	root.push_input(motion)
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = at
	ev.global_position = at
	root.push_input(ev)

func _click(at: Vector2) -> void:
	_mouse(at, true)
	_mouse(at, false)

func _key(code: Key, unicode: int = 0) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.physical_keycode = code
		ev.key_label = code
		ev.unicode = unicode if pressed else 0
		ev.pressed = pressed
		root.push_input(ev)

func _centre(c: Control) -> Vector2:
	return c.get_global_rect().get_center() if c != null else Vector2(-1, -1)

func _frames(n: int = 2) -> void:
	for i in n:
		await process_frame

# --- the checks ---------------------------------------------------------------------

func _run() -> void:
	root.size = Vector2i(1152, 648)
	await _frames()
	if not _install_audio():
		return
	var ao: GDScript = load("res://scripts/audio/audio_options.gd")
	var saved_options = _svc.options.duplicate_options()
	var o = ao.new()
	_svc.set_options(o, false)
	var US = load(UI_SOUNDS_PATH)
	_check(US != null, "scripts/audio/ui_sounds.gd loads")

	var ui := Control.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(ui)
	var panels: Control = load(PANELS_PATH).new(_builder())
	ui.add_child(panels)
	await _frames(3)

	# (1) I opens the popup: one window-open, no close.
	_stop_all()
	_key(KEY_I, "i".unicode_at(0))
	await _frames()
	_check(panels.call("is_open", "inventory"), "the probe: I opens the inventory tab")
	_check(_playing("UI:snd_window_open:-:-:-:-") == 1, "I (hotkey) sounds snd_window_open once (%d)" % _playing("UI:snd_window_open:-:-:-:-"))
	_check(_playing("UI:snd_window_close:-:-:-:-") == 0, "and no snd_window_close")

	# (2) A plain button inside the window is silent.
	_stop_all()
	var popup_window := panels.find_child("Window_mainpopup", true, false) as Control
	var avatar_btn: Control = popup_window.find_child("GDR_EQ_BTN_CHANGE_AVATAR_SLOT", true, false) if popup_window != null else null
	if avatar_btn == null and popup_window != null:
		avatar_btn = popup_window.find_child("GDR_EQ_BTN_CHANGE_EQUIP_SLOT", true, false)
	_check(avatar_btn != null and avatar_btn.is_visible_in_tree(), "the probe: an ordinary button of the equipment pane is on screen")
	_click(_centre(avatar_btn))
	await _frames()
	_check(_any_playing() == 0, "a plain button click is silent (%d sounds)" % _any_playing())

	# (3) S switches the tab of the popup already up: the open again.
	_stop_all()
	_key(KEY_S, "s".unicode_at(0))
	await _frames()
	_check(panels.call("is_open", "skill"), "the probe: S switches the popup to the skill tab")
	_check(_playing("UI:snd_window_open:-:-:-:-") == 1, "a tab switch by key sounds snd_window_open (0x79ae00 -> 0x79a7e0)")

	# (4) S again closes it: one window-close.
	_stop_all()
	_key(KEY_S, "s".unicode_at(0))
	await _frames()
	_check(not panels.call("is_open", "skill"), "the probe: S again hides the popup")
	_check(_playing("UI:snd_window_close:-:-:-:-") == 1, "closing by its key sounds snd_window_close once (%d)" % _playing("UI:snd_window_close:-:-:-:-"))
	_check(_playing("UI:snd_window_open:-:-:-:-") == 0, "and no snd_window_open")

	# (5) Q: the quest window toggle is silent in retail.
	_stop_all()
	_key(KEY_Q, "q".unicode_at(0))
	await _frames()
	_check(_any_playing() == 0, "Q (0x7990e0) is silent (%d sounds)" % _any_playing())

	# (6) The level-up key.
	_stop_all()
	if US != null:
		US.call("level_up", "test")
	await _frames(1)
	_check(_playing("UI:snd_levup:-:CHINESS:-:-") == 1, "the level-up plays UI:snd_levup:-:CHINESS:-:-")

	# (7) The item rules on synthetic type ids.
	if US != null:
		_check(US.call("equip_token", PackedInt32Array([3, 1, 6, 2])) == "SWORD", "a TypeID 3/1/6/2 weapon moves as SWORD")
		_check(US.call("equip_token", PackedInt32Array([3, 1, 6, 16])) == "HAMMER", "3/1/6/16 is HAMMER")
		_check(US.call("equip_token", PackedInt32Array([3, 1, 1, 3])) == "ROBE", "a garment chest (3/1/1/3) is ROBE")
		_check(US.call("equip_token", PackedInt32Array([3, 1, 3, 3])) == "BREASTPLATE", "an armour chest (3/1/3/3) is BREASTPLATE")
		_check(US.call("equip_token", PackedInt32Array([3, 1, 4, 1])) == "SHIELD", "3/1/4/1 is SHIELD")
		_check(US.call("equip_token", PackedInt32Array([3, 1, 12, 3])) == "RING", "3/1/12/3 is RING")
		_check(US.call("equip_token", PackedInt32Array([3, 3, 1, 1])) == "POTION", "3/3/1/1 is POTION")
		_check(US.call("equip_token", PackedInt32Array([3, 3, 9, 9])) == "", "an unlisted class has no token (silent)")
		_check(US.call("drop_key", PackedInt32Array(), true) == "ITEM:snd_dropitem:-:GOLD:-:-", "a gold drop's key")
		_check(US.call("drop_token", PackedInt32Array([3, 3, 10, 1]), false) == "ELIXIR", "a 3/3/10/1 drop is ELIXIR")
		_check(US.call("drop_token", PackedInt32Array([3, 1, 6, 2]), false) == "-", "an ordinary drop builds no row's token (the BOX/BAG rows are commented out)")
		var keys: Array = US.call("durability_keys", {6: 0, 1: 10, 2: 40}, {6: 30, 1: 50, 2: 40})
		_check(keys == ["UI:snd_repair:-:-:-:-", "UI:snd_revive:-:-:-:-"], "a repair: slot 1 rose (repair), slot 6 from 0 (revive), slot 2 unchanged (%s)" % [keys])
		_check(bool(US.call("is_potion_class", PackedInt32Array([3, 3, 1, 1]))) and not bool(US.call("is_potion_class", PackedInt32Array([3, 3, 3, 1]))), "snd_potion only for TypeID 3/3/1 and 3/3/2")

	# (8) The Option window: the Audio tab's sliders and boxes drive the buses.
	var opt = null
	if panels.has_method("toggle_option"):
		opt = panels.call("toggle_option")
	_check(opt != null, "the Option window builds from res_ui\\optionwnd.2dt")
	if opt == null:
		_restore(saved_options)
		return
	await _frames(3)
	var audio_tab: Control = opt.call("control", [14])
	var audio_pane: Control = opt.call("control", [269])
	_check(opt.call("current_tab") == 10 and audio_pane != null and not audio_pane.visible, "it opens on the Video tab, the audio pane hidden (0x600850)")
	_click(_centre(audio_tab))
	await _frames()
	_check(audio_pane != null and audio_pane.is_visible_in_tree(), "a click on the Audio tab shows the audio pane")
	# A press on the BGM slider where value 80's thumb sits.
	var bgm_slider: Control = opt.call("slider", 0)
	var thumb: Control = opt.call("thumb", 0)
	var x0: float = thumb.position.x - float(opt.call("thumb_offset", int(o.bgm)))
	var at := bgm_slider.get_global_transform() * Vector2(x0 + float(opt.call("thumb_offset", 80)) + thumb.size.x * 0.5, 12)
	_click(at)
	await _frames()
	var bgm_idx := AudioServer.get_bus_index("BGM")
	_check(is_equal_approx(AudioServer.get_bus_volume_db(bgm_idx), -4.0), "BGM slider at 80 -> BGM bus -4 dB (v/5 - 20) (got %s)" % AudioServer.get_bus_volume_db(bgm_idx))
	_check(is_equal_approx(thumb.position.x, x0 + float(int(80 * 452 / 100))), "the thumb sits at prev + 1 + 80 * 452 / 100")
	var eff_box: BaseButton = opt.call("mute_box", 1)
	_click(_centre(eff_box))
	await _frames()
	var eff_idx := AudioServer.get_bus_index("Effect")
	_check(AudioServer.is_bus_mute(eff_idx), "the Effect mute box mutes the Effect bus")
	var env_slider: Control = opt.call("slider", 2)
	var env_thumb: Control = opt.call("thumb", 2)
	var env_x0: float = env_thumb.position.x - float(opt.call("thumb_offset", int(o.env)))
	_click(env_slider.get_global_transform() * Vector2(env_x0 + float(opt.call("thumb_offset", 25)) + env_thumb.size.x * 0.5, 12))
	await _frames()
	var env_idx := AudioServer.get_bus_index("Env")
	_check(is_equal_approx(AudioServer.get_bus_volume_db(env_idx), -15.0), "Env slider at 25 -> Env bus -15 dB (got %s)" % AudioServer.get_bus_volume_db(env_idx))
	# Default on the audio tab: 50/50/50, boxes clear (0x5f6660).
	_click(_centre(opt.call("control", [5])))
	await _frames()
	_check(is_equal_approx(AudioServer.get_bus_volume_db(bgm_idx), -10.0) and not AudioServer.is_bus_mute(eff_idx), "Default: every slider 50 (-10 dB), mutes off")
	# Cancel: the saved values back, the window gone, no window sound.
	_stop_all()
	_click(_centre(opt.call("control", [8])))
	await _frames()
	_check(is_equal_approx(AudioServer.get_bus_volume_db(bgm_idx), AudioOptions.slider_db(o.bgm)), "Cancel puts the saved BGM volume back")
	_check(panels.call("option_window") == null, "Cancel closes the Option window")
	_check(_any_playing() == 0, "the Option window closes silently (0x6f5100 has no sound)")
	_restore(saved_options)

func _restore(saved_options) -> void:
	_stop_all()
	_svc.set_options(saved_options, false)
	var bank: GDScript = load("res://scripts/audio/audio_bank.gd")
	bank.clear()
