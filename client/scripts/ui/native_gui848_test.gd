extends SceneTree

## Round 848: the native GUI guard. Every non-test `.gd` and `.tscn` under
## the client is scanned for Godot's own widgets -- the class names in
## TOKENS, and `tooltip_text` (Godot's native tooltip popup) -- and each
## (file, token) count is held to ALLOWED, where every entry says why that
## use is allowed. A new native widget anywhere fails this suite until it is
## replaced by the original's control or listed here with its reason.
##
## What counts (the same rules as round 848's census script): in a `.gd`,
## every whole-word occurrence of a token in code, comments stripped (a
## `Button.new()`, an `extends Button`, an `as Button` or `is Button`, a
## `"Button"` class name passed to find_children); in a `.tscn`, every
## `type="<token>"` node and every `tooltip_text` property. A count that
## grew, or a (file, token) not listed, fails. A count that fell prints a
## TRIM line (the entry can shrink or go): not a failure, so a lane fixing
## its sites does not break another's merge.
##
## Reasons: "dev-only ..." (never in a player's build or never shown to a
## player), "references only ..." (type checks or casts on controls built
## elsewhere; creates none), "styled with the original's art: ..." (the
## widget is Godot's but draws the original's art, font and colours), and
## "LANE F/H/T pending: ..." -- round 848's other lanes are replacing or
## auditing those (F the front end, H the HUD and builders, T tooltips,
## scroll bars and context menus): trim them at merge.
##
##   godot4 --headless --path client --script res://scripts/ui/native_gui848_test.gd

const TYPES := ["Button", "LineEdit", "TextEdit", "OptionButton", "ItemList", "SpinBox", "HSlider", "VSlider",
	"CheckBox", "CheckButton", "TabContainer", "ScrollContainer", "PanelContainer", "Panel",
	"ConfirmationDialog", "AcceptDialog", "PopupMenu", "MenuButton"]
const TOOLTIP := "tooltip_text"

const DEV_PANEL := "dev-only debug panel (DebugPanel: built only where DevTools.enabled -- never in a release build; Shift+F3)"
const CENSUS := "references only: NativeGuiCensus's own class list (the QA measurement of what is shown); creates none"
const DEV_TOOL := "dev-only: a client/tools measurement script, never part of the game"
const LT := "LANE T pending: Godot's native tooltip popup for "

## [file under res://, token, count at round 848's base, reason]
const ALLOWED := [
	# --- lane W's own (World3D, the debug panel, the census) -------------------
	["scripts/World3D.gd", "LineEdit", 4, "references only: the typing test (focus is LineEdit or TextEdit) and QA reads of original-built edits (job alias box, the QA focus report); creates none"],
	["scripts/World3D.gd", "TextEdit", 1, "references only: the typing test (focus is LineEdit or TextEdit); creates none"],
	["scripts/World3D.gd", "tooltip_text", 3, LT + "the chat line, the chat window and the underbar MENU button (the command hint)"],
	["scripts/ui/debug_panel.gd", "Button", 2, DEV_PANEL],
	["scripts/ui/debug_panel.gd", "CheckButton", 2, DEV_PANEL],
	["scripts/ui/debug_panel.gd", "HSlider", 4, DEV_PANEL],
	["scripts/ui/debug_panel.gd", "LineEdit", 4, DEV_PANEL],
	["scripts/ui/debug_panel.gd", "OptionButton", 4, DEV_PANEL],
	["scripts/ui/debug_panel.gd", "PanelContainer", 1, DEV_PANEL],
	["scripts/ui/debug_panel.gd", "ScrollContainer", 1, DEV_PANEL],
	["scripts/ui/native_gui_census.gd", "AcceptDialog", 1, CENSUS],
	["scripts/ui/native_gui_census.gd", "Button", 4, CENSUS],
	["scripts/ui/native_gui_census.gd", "CheckBox", 1, CENSUS],
	["scripts/ui/native_gui_census.gd", "CheckButton", 1, CENSUS],
	["scripts/ui/native_gui_census.gd", "ConfirmationDialog", 1, CENSUS],
	["scripts/ui/native_gui_census.gd", "HSlider", 1, CENSUS],
	["scripts/ui/native_gui_census.gd", "ItemList", 1, CENSUS],
	["scripts/ui/native_gui_census.gd", "LineEdit", 6, CENSUS],
	["scripts/ui/native_gui_census.gd", "MenuButton", 1, CENSUS],
	["scripts/ui/native_gui_census.gd", "OptionButton", 1, CENSUS],
	["scripts/ui/native_gui_census.gd", "Panel", 1, CENSUS],
	["scripts/ui/native_gui_census.gd", "PanelContainer", 1, CENSUS],
	["scripts/ui/native_gui_census.gd", "PopupMenu", 1, CENSUS],
	["scripts/ui/native_gui_census.gd", "ScrollContainer", 1, CENSUS],
	["scripts/ui/native_gui_census.gd", "SpinBox", 1, CENSUS],
	["scripts/ui/native_gui_census.gd", "TabContainer", 1, CENSUS],
	["scripts/ui/native_gui_census.gd", "TextEdit", 2, CENSUS],
	["scripts/ui/native_gui_census.gd", "VSlider", 1, CENSUS],
	["scripts/ui/key_input.gd", "LineEdit", 1, "references only: line_edit_as_42, the key handling every original-built edit line takes (round 754); creates none"],
	["tools/measure_text_crispness.gd", "Button", 6, DEV_TOOL],
	["tools/measure_text_crispness.gd", "LineEdit", 2, DEV_TOOL],

	# --- lane F: the front end ---------------------------------------------------
	["scripts/Boot.gd", "ConfirmationDialog", 1, "LANE F pending: the 'Update available' box is Godot's ConfirmationDialog (player-reachable on every launch with an update)"],
	["scripts/CharacterCreate.gd", "Button", 1, "LANE F pending: the no-archive fallback's Cancel button (default theme)"],
	["scripts/CharacterCreate.gd", "LineEdit", 2, "LANE F pending: the name edit"],
	["scripts/CharacterSelect.gd", "Button", 15, "LANE F pending: the select screen's buttons (Button over the layout's art) and their casts"],
	["scripts/CharacterSelect.gd", "Panel", 1, "LANE F pending: a no-art fallback Panel"],
	["scripts/Login.gd", "Button", 9, "LANE F pending: the login screen's buttons (art Buttons, the Register and text buttons)"],
	["scripts/Login.gd", "LineEdit", 10, "LANE F pending: the login screen's edit lines"],
	["scripts/Login.gd", "PanelContainer", 1, "LANE F pending: the register plate (StyleBoxFlat, ours)"],
	["scripts/Login.gd", "tooltip_text", 3, LT + "the server address field"],
	["scripts/frontend/captcha_window.gd", "Button", 3, "LANE F pending: the captcha window's buttons"],
	["scripts/frontend/captcha_window.gd", "LineEdit", 4, "LANE F pending: the captcha edit"],
	["scripts/frontend/charselect_lock.gd", "Button", 2, "LANE F pending: the PIN button's no-builder fallback"],
	["scripts/frontend/charselect_qa.gd", "Button", 3, "references only (QA): reads the select screen's buttons; creates none"],
	["scripts/frontend/netoff_box.gd", "Button", 3, "LANE F pending: the disconnect box's CIFButton as a Button"],
	["scripts/frontend/server_list_window.gd", "Button", 4, "LANE F pending: the server list's buttons"],
	["scripts/ui/character_lock_window.gd", "Button", 4, "LANE F pending: the PIN pad's tiles (Buttons skinned with the pad's ddj by _skin)"],
	["scripts/ui/frontend_ui.gd", "Button", 2, "LANE F pending: FrontEndUi.button, a StyleBoxFlat plate (ours)"],
	["scripts/ui/frontend_ui.gd", "PanelContainer", 2, "LANE F pending: FrontEndUi.plate, a StyleBoxFlat plate (ours)"],
	["scripts/ui/loading_screen.gd", "Panel", 1, "LANE F pending: the loading bar's trough (StyleBoxFlat plate, ours)"],

	# --- lane H: the HUD and the builders -----------------------------------------
	["scripts/ui/help_window.gd", "Button", 1, "LANE H pending: the help window's close Button"],
	["scripts/ui/help_window.gd", "ItemList", 2, "LANE H pending: the help window's document list (default-theme ItemList, MEASURED shown on H)"],
	["scripts/ui/ui_builder.gd", "Button", 5, "references only: the text-node test and the Button font guard; creates none"],
	["scripts/ui/ui_builder.gd", "CheckBox", 2, "references only: a node name and the text-node test; creates none"],
	["scripts/ui/ui_builder.gd", "CheckButton", 1, "references only: the text-node test; creates none"],
	["scripts/ui/ui_builder.gd", "ItemList", 1, "references only: the text-node test; creates none"],
	["scripts/ui/ui_builder.gd", "LineEdit", 3, "styled with the original's art: CIFEdit (_build_edit: the layout's ddj slice or no box on normal/focus/read_only, the archive face at FontIndex)"],
	["scripts/ui/ui_builder.gd", "OptionButton", 1, "references only: the text-node test; creates none"],
	["scripts/ui/twodt_builder.gd", "Button", 1, "references only: the .2dt short type name \"Button\" (a string); creates none"],
	["scripts/ui/twodt_builder.gd", "LineEdit", 6, "styled with the original's art: a .2dt edit (_edit: no box of Godot's, the record's colour and FontIndex)"],
	["scripts/ui/hud/alchemy_window.gd", "tooltip_text", 3, LT + "the alchemy window's mode and slot hints"],
	["scripts/ui/hud/auto_potion_window.gd", "OptionButton", 11, "LANE H pending: the auto potion combos (OptionButton with ComboList)"],
	["scripts/ui/hud/combo_list.gd", "OptionButton", 2, "LANE H pending: ComboList, the original's combo list over an OptionButton"],
	["scripts/ui/hud/composite_item_window.gd", "Button", 4, "LANE H pending: the composite item window's buttons"],
	["scripts/ui/hud/gacha_select_window.gd", "OptionButton", 5, "LANE H pending: the Magic POP select combos"],
	["scripts/ui/hud/guild_donate_window.gd", "LineEdit", 2, "references only: the original-built edit (builder); creates none"],
	["scripts/ui/hud/guild_notice_write.gd", "LineEdit", 7, "LANE H pending: the notice title edit and its host"],
	["scripts/ui/hud/guild_notice_write.gd", "TextEdit", 3, "LANE H pending: the notice body (a Godot TextEdit)"],
	["scripts/ui/hud/guild_war_request_box.gd", "LineEdit", 1, "references only: the original-built edit; creates none"],
	["scripts/ui/hud/guild_war_request_box.gd", "OptionButton", 5, "LANE H pending: the war request's combos"],
	["scripts/ui/hud/guild_window.gd", "LineEdit", 3, "references only: original-built edits; creates none"],
	["scripts/ui/hud/guild_window.gd", "tooltip_text", 2, LT + "the guild window's hints"],
	["scripts/ui/hud/hud_action_pane.gd", "tooltip_text", 3, LT + "the action window's slots"],
	["scripts/ui/hud/hud_buff_board.gd", "Button", 2, "LANE H pending: the buff board's OK / Cancel prompt buttons"],
	["scripts/ui/hud/hud_buff_board.gd", "PanelContainer", 1, "LANE H pending: the buff board's prompt panel"],
	["scripts/ui/hud/hud_chat.gd", "LineEdit", 2, "LANE H pending: the chat line's own LineEdit (flat, but Godot's focus box and caret show: MEASURED round 848, frame 1175)"],
	["scripts/ui/hud/hud_chat.gd", "tooltip_text", 1, LT + "the chat window's buttons"],
	["scripts/ui/hud/hud_cos_boxes.gd", "LineEdit", 5, "references only: the original-built edit (GDR_MB_INSERT_MSG_EDIT); creates none"],
	["scripts/ui/hud/hud_cos_command.gd", "tooltip_text", 2, LT + "the pet command buttons (a helper named tooltip_text)"],
	["scripts/ui/hud/hud_panels.gd", "Button", 10, "LANE H pending: the talk prompts' and the use-on box's buttons"],
	["scripts/ui/hud/hud_panels.gd", "LineEdit", 5, "LANE H pending: the talk prompt's name edit; the rest references"],
	["scripts/ui/hud/hud_panels.gd", "PanelContainer", 7, "LANE H pending: the talk prompts and the use-on box"],
	["scripts/ui/hud/hud_panels.gd", "TextEdit", 2, "references only: the typing tests; creates none"],
	["scripts/ui/hud/hud_panels.gd", "tooltip_text", 3, LT + "the HUD's buttons and icons"],
	["scripts/ui/hud/hud_player_info.gd", "tooltip_text", 1, LT + "the player block's buttons"],
	["scripts/ui/hud/hud_quick_party.gd", "tooltip_text", 2, LT + "the quick party window"],
	["scripts/ui/hud/hud_underbar.gd", "LineEdit", 1, "references only: the typing test; creates none"],
	["scripts/ui/hud/hud_underbar.gd", "TextEdit", 1, "references only: the typing test; creates none"],
	["scripts/ui/hud/hud_underbar.gd", "tooltip_text", 1, LT + "the underbar's buttons"],
	["scripts/ui/hud/hud_whole_chat.gd", "LineEdit", 2, "references only: the original-built edit; creates none"],
	["scripts/ui/hud/hud_window.gd", "Button", 1, "references only: the hit-test filter; creates none"],
	["scripts/ui/hud/hud_window.gd", "ItemList", 1, "references only: the hit-test filter; creates none"],
	["scripts/ui/hud/hud_window.gd", "LineEdit", 1, "references only: the hit-test filter; creates none"],
	["scripts/ui/hud/hud_window.gd", "Panel", 1, "references only: the hit-test filter; creates none"],
	["scripts/ui/hud/hud_window.gd", "PanelContainer", 1, "references only: the hit-test filter; creates none"],
	["scripts/ui/hud/hud_window.gd", "TextEdit", 1, "references only: the hit-test filter; creates none"],
	["scripts/ui/hud/hud_worldmap.gd", "tooltip_text", 4, LT + "the world map's signs and buttons"],
	["scripts/ui/hud/item_chest_icon.gd", "tooltip_text", 2, LT + "the item chest icon"],
	["scripts/ui/hud/item_chest_window.gd", "tooltip_text", 2, LT + "the item chest rows"],
	["scripts/ui/hud/item_mall_controller.gd", "LineEdit", 2, "references only: the original-built search edit; creates none"],
	["scripts/ui/hud/job_alias_box.gd", "LineEdit", 1, "references only: the original-built edit; creates none"],
	["scripts/ui/hud/mall_confirm_buy.gd", "LineEdit", 4, "references only: original-built edits; creates none"],
	["scripts/ui/hud/mall_message_box.gd", "LineEdit", 4, "references only: original-built edits; creates none"],
	["scripts/ui/hud/mall_use_point.gd", "LineEdit", 3, "references only: original-built edits; creates none"],
	["scripts/ui/hud/nif_page_manager.gd", "Button", 3, "LANE H pending: the page manager's page buttons"],
	["scripts/ui/hud/option_video_page.gd", "OptionButton", 11, "LANE H pending: the Video tab's combos (OptionButton with ComboList)"],
	["scripts/ui/hud/option_video_page.gd", "tooltip_text", 5, LT + "the Video tab's combos"],
	["scripts/ui/hud/party_match_box.gd", "LineEdit", 2, "references only: original-built edits; creates none"],
	["scripts/ui/hud/party_match_qa.gd", "LineEdit", 4, "references only (QA): original-built edits; creates none"],
	["scripts/ui/hud/party_match_register.gd", "LineEdit", 7, "references only: original-built edits; creates none"],
	["scripts/ui/hud/party_match_window.gd", "LineEdit", 7, "references only: original-built edits; creates none"],
	["scripts/ui/hud/party_match_window.gd", "OptionButton", 1, "LANE H pending: the party matching combo"],
	["scripts/ui/hud/quest_hud.gd", "ConfirmationDialog", 1, "LANE H pending: a quest confirmation is Godot's ConfirmationDialog"],
	["scripts/ui/hud/reverse_return_box.gd", "Button", 7, "LANE H pending: the reverse return box's CIFButton as a Button"],
	["scripts/ui/hud/silk_history_window.gd", "OptionButton", 1, "LANE H pending: the silk history combo"],
	["scripts/ui/hud/skill_board.gd", "Button", 1, "references only: a node name; creates none"],
	["scripts/ui/hud/skill_board.gd", "tooltip_text", 1, LT + "the skill board (cleared)"],
	["scripts/ui/hud/skill_practice_box.gd", "LineEdit", 2, "references only: an original-built edit; creates none"],
	["scripts/ui/hud/stall_network_window.gd", "OptionButton", 4, "LANE H pending: the stall network's combos"],
	["scripts/ui/hud/stall_network_window.gd", "tooltip_text", 1, LT + "the stall network's scan button"],
	["scripts/ui/hud/stall_window_view.gd", "LineEdit", 2, "references only: the original-built chat input; creates none"],
	["scripts/ui/hud/stall_window_view.gd", "tooltip_text", 1, LT + "the stall's modify button"],
	["scripts/ui/hud/store_message_box.gd", "LineEdit", 15, "references only: original-built edits; creates none"],
]

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## The line without its comment: the first `#` outside a string literal.
static func strip_comment(line: String) -> String:
	var quote := ""
	var i := 0
	while i < line.length():
		var c := line[i]
		if quote != "":
			if c == "\\":
				i += 2
				continue
			if c == quote:
				quote = ""
		elif c == "\"" or c == "'":
			quote = c
		elif c == "#":
			return line.substr(0, i)
		i += 1
	return line

static func _is_word_char(c: String) -> bool:
	if c == "":
		return false
	var u := c.unicode_at(0)
	return (u >= 48 and u <= 57) or (u >= 65 and u <= 90) or (u >= 97 and u <= 122) or u == 95

## Whole-word occurrences of `word` in `text`.
static func count_word(text: String, word: String) -> int:
	var n := 0
	var start := 0
	while true:
		var i := text.find(word, start)
		if i < 0:
			return n
		var before := text[i - 1] if i > 0 else ""
		var after := text[i + word.length()] if i + word.length() < text.length() else ""
		if not _is_word_char(before) and not _is_word_char(after):
			n += 1
		start = i + word.length()
	return n

## {"<file>|<token>": count} for one file's text.
static func scan_text(rel: String, text: String, out: Dictionary) -> void:
	var tokens: Array = TYPES + [TOOLTIP]
	for line in text.split("\n"):
		if rel.ends_with(".gd"):
			var code := strip_comment(line)
			for t in tokens:
				var c := count_word(code, t)
				if c > 0:
					out[rel + "|" + t] = int(out.get(rel + "|" + t, 0)) + c
		else:
			for t in TYPES:
				var c := line.count("type=\"%s\"" % t)
				if c > 0:
					out[rel + "|" + t] = int(out.get(rel + "|" + t, 0)) + c
			if line.begins_with(TOOLTIP):
				out[rel + "|" + TOOLTIP] = int(out.get(rel + "|" + TOOLTIP, 0)) + 1

static func scan_dir(dir_path: String, rel: String, out: Dictionary) -> int:
	var files := 0
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return 0
	for sub in dir.get_directories():
		if sub.begins_with("."):
			continue
		files += scan_dir(dir_path.path_join(sub), rel.path_join(sub) if rel != "" else sub, out)
	for f in dir.get_files():
		if not (f.ends_with(".gd") or f.ends_with(".tscn")) or f.ends_with("_test.gd"):
			continue
		var path := dir_path.path_join(f)
		var text := FileAccess.get_file_as_string(path)
		scan_text(rel.path_join(f) if rel != "" else f, text, out)
		files += 1
	return files

func _init() -> void:
	# The probe first: the scanner's own rules on known text.
	var probe := {}
	scan_text("a.gd", "var b := Button.new() # a Button in a comment\nvar t := TextureButton.new()\nx.tooltip_text = \"#\"; var c := CheckBox.new()\n", probe)
	_check(probe == {"a.gd|Button": 1, "a.gd|tooltip_text": 1, "a.gd|CheckBox": 1},
		"the probe: one Button (not the comment's, not TextureButton), and a # inside a string starts no comment (got %s)" % [probe])
	var scene_probe := {}
	scan_text("s.tscn", "[node name=\"B\" type=\"Button\" parent=\".\"]\ntooltip_text = \"x\"\n[node name=\"T\" type=\"TextureButton\" parent=\".\"]\n", scene_probe)
	_check(scene_probe == {"s.tscn|Button": 1, "s.tscn|tooltip_text": 1}, "the probe: a .tscn's Button node and tooltip (got %s)" % [scene_probe])

	var found := {}
	var files := scan_dir("res://", "", found)
	_check(files > 500, "the scan read the client (%d .gd / .tscn files)" % files)
	_check(int(found.get("scripts/ui/debug_panel.gd|Button", 0)) > 0, "the probe: the scan finds the debug panel's Buttons")

	var allowed := {}
	for e in ALLOWED:
		_check(String(e[3]).strip_edges() != "", "%s %s has a reason" % [e[0], e[1]])
		allowed[String(e[0]) + "|" + String(e[1])] = int(e[2])
	var keys := found.keys()
	keys.sort()
	var unlisted: Array = []
	for k in keys:
		var n := int(found[k])
		if not allowed.has(k):
			unlisted.append("%s x%d" % [k, n])
		elif n > int(allowed[k]):
			unlisted.append("%s x%d (allowed %d)" % [k, n, int(allowed[k])])
	_check(unlisted.is_empty(), "no native widget or native tooltip outside the allowlist (new: %s)" % [unlisted])
	for k in allowed:
		var n := int(found.get(k, 0))
		if n < int(allowed[k]):
			print("TRIM %s: %d now, %d allowed" % [k, n, int(allowed[k])])

	# NEGATIVE (fails before round 848): World3D.tscn's prototype UI.
	var scene := FileAccess.get_file_as_string("res://scenes/World3D.tscn")
	_check(scene != "" and not scene.contains("ActionTabs") and not scene.contains("HideUIButton") and not scene.contains("ChatPanel")
		and not scene.contains("ZoneInput") and not scene.contains("DisconnectButton"),
		"World3D.tscn holds none of the prototype's native UI (ActionTabs, HideUIButton, ChatPanel, ZoneInput, DisconnectButton)")
	var world_hits := []
	for k in found:
		if String(k).begins_with("scenes/World3D.tscn|"):
			world_hits.append(k)
	_check(world_hits.is_empty(), "World3D.tscn has no native-type node (%s)" % [world_hits])

	# The debug panel is a developer's only (DevTools): off forces Shift+F3 to
	# retail's page 3, on gives the panel.
	DevTools.override = 0
	_check(not DevTools.enabled() and KeyMap.resolve(KEY_F3, false, false, false, false, true) == ["page", 3],
		"with developer tools off Shift+F3 is F3, page 3 (got %s)" % [KeyMap.resolve(KEY_F3, false, false, false, false, true)])
	DevTools.override = 1
	_check(DevTools.enabled() and KeyMap.resolve(KEY_F3, false, false, false, false, true) == ["debug_panel", 0],
		"with developer tools on Shift+F3 is the debug panel")
	DevTools.override = -1
	_check(DevTools.enabled() == (OS.get_environment("OPENSRO_DEV") != "0" and (OS.get_environment("OPENSRO_DEV") != "" or OS.is_debug_build()
		or bool(ClientSettings.get_value(DevTools.SECTION, DevTools.KEY_TOOLS, false)))),
		"DevTools follows OPENSRO_DEV, the settings key and the build")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
