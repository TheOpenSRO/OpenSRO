extends SceneTree

## Round 672: every in-game text node is drawn in the client's own aliased
## face at its 12 px and sampled NEAREST, and the window's font oversampling
## is on at every UI scale, fractional ones included.
##
## What it guards against, each measured on the render box in round 672
## (docs/WORLD_ISSUES.md): text rasterised at 1x and magnified at a
## fractional scale (84-97 % of text pixels part-covered at 1.25/1.5/1.95),
## a Control made in code falling back to Godot's anti-aliased default font,
## and a glyph texture magnified by a linear filter (60-70 % part-covered
## even when oversampled).
##
## Everything is reached by path and call(), so against a client without
## round 672 this prints FAIL lines instead of failing to compile. No archive
## is read: the UI font is Godot's own default face loaded through
## UiBuilder's font path (the flags are the client's, the face is a stand-in).
##
## `godot4 --headless --path client --script res://scripts/ui/text_crispness_test.gd`

const BUILDER_PATH := "res://scripts/ui/ui_builder.gd"
const CHAT_PATH := "res://scripts/ui/hud/hud_chat.gd"
const NOTICE_PATH := "res://scripts/ui/hud/hud_notice.gd"
const SETTINGS_PATH := "res://scripts/client_settings.gd"
const WORLD_PATH := "res://scripts/World3D.gd"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_run()

func _run() -> void:
	await process_frame
	await process_frame
	var builder_script := load(BUILDER_PATH) as GDScript
	var builder: RefCounted = builder_script.new(null, null)
	var font: FontFile = null
	var src := ThemeDB.fallback_font as FontFile
	if builder.has_method("use_font_data") and src != null:
		font = builder.call("use_font_data", src.data)
	_check(font != null and font != ThemeDB.fallback_font,
		"a UI font of its own, distinct from Godot's default (UiBuilder.use_font_data)")
	if font != null:
		_check(font.antialiasing == TextServer.FONT_ANTIALIASING_NONE, "the UI font is aliased, as GGO_BITMAP glyphs are")

	var root := Control.new()
	root.name = "UI"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	get_root().add_child(root)
	_check(builder.has_method("apply_ui_theme"), "UiBuilder.apply_ui_theme exists")
	if builder.has_method("apply_ui_theme"):
		builder.call("apply_ui_theme", root)

	# Text nodes made in code the way the HUD's dialogs make them: no font of
	# their own. Some before the theme's watch sees them, some added after,
	# one nested two levels down inside a container added after.
	var texts: Array[Control] = []
	var label := Label.new()
	label.text = "Phy. balance"
	root.add_child(label)
	texts.append(label)
	var button := Button.new()
	button.text = "Withdraw"
	root.add_child(button)
	texts.append(button)
	var edit := LineEdit.new()
	edit.text = "deadass3"
	root.add_child(edit)
	texts.append(edit)
	var box := VBoxContainer.new()
	root.add_child(box)
	var inner := PanelContainer.new()
	box.add_child(inner)
	var deep := Label.new()
	deep.text = "added later, two levels down"
	inner.add_child(deep)
	texts.append(deep)
	var rich := RichTextLabel.new()
	rich.text = "help"
	root.add_child(rich)
	var items := ItemList.new()
	items.add_item("Jangan")
	root.add_child(items)
	await process_frame

	for c in texts:
		var f := c.get_theme_font("font")
		# A Button's is the client's face behind its guard (see below).
		if c is Button and f is FontVariation:
			f = (f as FontVariation).base_font
		_check(f != null and f == font, "%s '%s' draws in the client's face, not Godot's default (got %s)" % [
			c.get_class(), String(c.get("text")), "Godot's default" if f == ThemeDB.fallback_font else str(f)])
		_check(c.get_theme_font_size("font_size") == 12, "%s '%s' is at FontIndex 0's 12 px (got %d)" % [
			c.get_class(), String(c.get("text")), c.get_theme_font_size("font_size")])
		_check(c.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST, "%s '%s' samples its glyphs NEAREST (got %d)" % [
			c.get_class(), String(c.get("text")), c.texture_filter])
	# A dialog built off-tree and added in one go, the way HudPanels makes its
	# buy/sell, gold, revive and guild dialogs: Buttons and a Label nested
	# three deep, text set before the add and, on one Button, after it. The
	# watcher must handle each node once it is IN the tree, where it resolves
	# the root's face -- handled from its ancestor's signal it was guarded in
	# Godot's default face and kept it (round 672's review, H1).
	var dialog := PanelContainer.new()
	var col := VBoxContainer.new()
	dialog.add_child(col)
	var row := HBoxContainer.new()
	col.add_child(row)
	var nested: Array[Control] = []
	for t in ["Buy", "Cancel"]:
		var nb := Button.new()
		nb.text = t
		row.add_child(nb)
		nested.append(nb)
	var later := Button.new()
	row.add_child(later)
	nested.append(later)
	var nl := Label.new()
	nl.text = "Quantity"
	col.add_child(nl)
	nested.append(nl)
	root.add_child(dialog)
	later.text = "Withdraw"
	await process_frame
	for c in nested:
		var f := c.get_theme_font("font")
		var face := (f as FontVariation).base_font if f is FontVariation else f
		_check(face == font, "nested %s '%s' in a dialog added in one go draws in the client's face (got %s)" % [
			c.get_class(), String(c.get("text")), "Godot's default" if face == ThemeDB.fallback_font else str(face)])
		_check(c.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST, "nested %s '%s' samples NEAREST" % [
			c.get_class(), String(c.get("text"))])
		if c is Button:
			_check(f is FontVariation and (f as FontVariation).variation_embolden > 0.0,
				"nested Button '%s' wears the guarded face" % String(c.get("text")))

	# Controls that draw theme icons beside their text keep their filter.
	var check := CheckBox.new()
	check.text = "Show names"
	root.add_child(check)
	var option := OptionButton.new()
	option.add_item("1.95")
	root.add_child(option)
	await process_frame
	_check(check.texture_filter == CanvasItem.TEXTURE_FILTER_PARENT_NODE, "a CheckBox keeps its icons' filter")
	_check(option.texture_filter == CanvasItem.TEXTURE_FILTER_PARENT_NODE, "an OptionButton keeps its arrow's filter")

	_check(rich.get_theme_font("normal_font") == font, "a RichTextLabel's body is in the client's face")
	_check(rich.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST, "a RichTextLabel samples NEAREST")
	_check(items.get_theme_font("font") == font, "an ItemList is in the client's face")
	_check(items.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST, "an ItemList samples NEAREST")

	# The UI's ART keeps its filter: a texture control, a container, and a
	# Button wearing a texture style (CompositeItemWindow's) are left alone.
	var art := TextureRect.new()
	root.add_child(art)
	var art_button := Button.new()
	art_button.text = "Elixir(3)"
	var sb := StyleBoxTexture.new()
	sb.texture = PlaceholderTexture2D.new()
	for st in ["normal", "hover", "pressed", "disabled", "focus"]:
		art_button.add_theme_stylebox_override(st, sb)
	root.add_child(art_button)
	await process_frame
	_check(art.texture_filter == CanvasItem.TEXTURE_FILTER_PARENT_NODE, "a TextureRect keeps its inherited (linear) filter")
	_check(box.texture_filter == CanvasItem.TEXTURE_FILTER_PARENT_NODE, "a container keeps its inherited filter")
	_check(art_button.texture_filter == CanvasItem.TEXTURE_FILTER_PARENT_NODE, "a Button wearing texture art keeps its filter")

	# Custom-drawn text: the chat's lines and the notice banner's text.
	# A ChatList is the chat's and the system window's line view.
	var chat_script := load(CHAT_PATH) as GDScript
	var list_class: Variant = chat_script.get("ChatList")
	var list: Control = list_class.new() if list_class != null else null
	if list != null:
		root.add_child(list)
	_check(list != null and list.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST, "the chat's lines sample NEAREST")
	var notice_script := load(NOTICE_PATH) as GDScript
	var notice: Control = notice_script.new()
	root.add_child(notice)
	notice.call("setup", builder)
	notice.call("show_notice", "Unique Tiger Girl has been defeated.")
	await process_frame
	var layer := notice.get_node_or_null("TextLayer") as CanvasItem
	_check(layer != null and layer.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"the notice banner's text is on an unfiltered layer")
	# The one piece of UI art that is point-sampled by the client itself
	# (CIFStretchWnd's 0x819d80 sets sampler states 5/6 to 1; round 703).
	_check(notice.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST, "the notice banner's frame is point-sampled, as 0x819d80 draws it")

	# A Button's last glyph (the 2026-09-11 "Registe", round 672's "Sel"): a
	# Button draws its text clipped to the ceiling of its own width, so a
	# fractional width that sums to a whole number lost its last glyph. Its
	# face is guarded (UiBuilder.guard_button_font): for every string and
	# scale here, the glyphs' running end -- accumulated in single precision,
	# as shaped_text_draw's Vector2 does -- stays inside that ceiling.
	var bfont := button.get_theme_font("font")
	var guarded := bfont is FontVariation and (bfont as FontVariation).base_font == font \
		and (bfont as FontVariation).variation_embolden > 0.0
	_check(guarded, "a text Button draws in the guarded face of the client's font")
	var settings := load(SETTINGS_PATH) as GDScript
	var ts := TextServerManager.get_primary_interface()
	if guarded:
		var words := ["Sell", "Buy", "Register", "Cancel", "Deposit", "Withdraw", "LEVEL UP", "Close", "OK",
			"Resurrect at the specified point.", "Elixir(3)", "Jangan", "Accept", "Decline", "+", "-", "X"]
		# At 1.0 the guard changes nothing: every width is the plain face's.
		var differ := 0
		for w in words:
			for size in [11, 12, 15, 16, 20]:
				if bfont.get_string_size(w, HORIZONTAL_ALIGNMENT_LEFT, -1, size) != font.get_string_size(w, HORIZONTAL_ALIGNMENT_LEFT, -1, size):
					differ += 1
		_check(differ == 0, "at UI scale 1.0 the guarded face lays out every string exactly as the plain one (%d differ)" % differ)
		var over := 0
		var tried := 0
		for scale in [1.25, 1.5, 1.75, 1.95, 2.35, 2.5]:
			settings.call("apply_ui_scale", get_root(), scale)
			await process_frame
			for w in words:
				for size in [11, 12, 15, 16, 20]:
					var line := TextLine.new()
					line.add_string(w, bfont, size)
					var clip := line.get_size().x
					var run := Vector2.ZERO
					for g in ts.shaped_text_get_glyphs(line.get_rid()):
						run.x += float(g["advance"])
					tried += 1
					if run.x > clip:
						over += 1
						print("  '%s' %d px at %.2f: glyphs end at %.6f, past the clip %.1f" % [w, size, scale, run.x, clip])
		_check(over == 0, "no Button string loses its last glyph: %d of %d strings x sizes x scales end past their clip" % [over, tried])
	root.queue_free()

	# Oversampling at every scale, the fractional ones included: on, and the
	# text server's value is the scale (the window owns it).
	for scale in [1.25, 1.5, 1.95, 2.35, 2.0, 1.0]:
		settings.call("apply_ui_scale", get_root(), scale)
		await process_frame
		_check(get_root().is_using_font_oversampling(), "UI scale %.2f: the window drives font oversampling" % scale)
		_check(is_equal_approx(ts.font_get_global_oversampling(), scale),
			"UI scale %.2f: glyphs are rasterised at %.2f (got %.3f)" % [scale, scale, ts.font_get_global_oversampling()])

	# The game's own UI root gets the theme: World3D applies it to
	# ui_control right after making its builder.
	var world_src := FileAccess.get_file_as_string(WORLD_PATH)
	_check(world_src.contains("_ui_builder.apply_ui_theme(ui_control)"), "World3D gives its UI root the client's text theme")

	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit(1 if _failures > 0 else 0)
