extends SceneTree

## The underbar and the minimap build once (round 585). World3D added each to
## the tree -- whose _ready runs setup() -- and then called setup() again,
## which built a second copy of every control stacked exactly on the first.
## Here each widget is set up, put in the tree and set up again, as World3D
## did; there must be one copy of each authored control. The layouts are
## synthetic, with real control names and rects (never real game data); the
## underbar's is the synthetic nifundermenubar.2dt in underbar_fixture.gd:
##   godot4 --headless --path client --script res://scripts/ui/hud/hud_build_once_test.gd

const WORLD_PATH := "res://scripts/World3D.gd"
const UnderbarFixture = preload("res://scripts/ui/hud/underbar_fixture.gd")

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _control(control_name: String, type: String, rect: String) -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"\"\n\t\tRect=RECT,\"%s\"\n\t\tText=STRING,\"\"\n\t}\n" % [control_name, type, rect]

func _layout(body: String) -> String:
	return "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n" + body + "}\n"

func _minimap() -> String:
	return _layout(_control("GDR_MINIMAP_ZOOMIN", "CIFButton", "107,136,20,20")
		+ _control("GDR_MINIMAP_TEXT_POS_X", "CIFStatic", "8,32,56,11"))

func _copies(root: Node, control_name: String) -> int:
	return root.find_children(control_name, "", true, false).size()

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the live checks never reported (a script error stopped them)")
		quit(1))
	await process_frame
	var hud := Control.new()
	root.add_child(hud)

	# Button4 is the menu button, Static14 the EXP caption, Wnd40 quick slot 1.
	var ub_builder := UnderbarFixture.builder()
	var bar := HudUnderbar.new(ub_builder, null, null)
	bar.setup()
	hud.add_child(bar)
	var bar_children := bar.get_child_count()
	bar.setup()
	for n in ["Button4", "Static14", "Wnd40"]:
		_check(_copies(bar, n) == 1, "underbar: one %s after a second setup() (got %d)" % [n, _copies(bar, n)])
	_check(bar.get_child_count() == bar_children, "underbar: a second setup() adds no children (%d -> %d)" % [bar_children, bar.get_child_count()])
	# The slot handlers are the first build's: a click fires once.
	var fired: Array = []
	bar.quickslot_activated.connect(func(idx: int) -> void: fired.append(idx))
	var slot := bar.find_child("Wnd40", true, false) as Control
	if slot != null:
		# A right click is the use (round 652: CIFSlotWithHelp's
		# right-button-up); it acts on the release.
		for pressed in [true, false]:
			var click := InputEventMouseButton.new()
			click.button_index = MOUSE_BUTTON_RIGHT
			click.pressed = pressed
			click.global_position = slot.get_global_rect().get_center()
			slot.gui_input.emit(click)
	_check(fired == [1], "underbar: a right click on quick slot 1 fires it once (got %s)" % [fired])

	var minimap := HudMinimap.new(UiBuilder.new(null, null), null, null)
	minimap.setup(_minimap())
	hud.add_child(minimap)
	var mm_children := minimap.get_child_count()
	minimap.setup(_minimap())
	for n in ["GDR_MINIMAP_ZOOMIN", "GDR_MINIMAP_TEXT_POS_X", "MinimapFrame", "MapClip"]:
		_check(_copies(minimap, n) == 1, "minimap: one %s after a second setup() (got %d)" % [n, _copies(minimap, n)])
	_check(minimap.get_child_count() == mm_children, "minimap: a second setup() adds no children (%d -> %d)" % [mm_children, minimap.get_child_count()])

	# A widget put in the tree unbuilt is built by its _ready, once.
	var late := HudMinimap.new(UiBuilder.new(null, null), null, null)
	hud.add_child(late)
	_check(_copies(late, "MinimapFrame") == 1, "minimap: _ready builds a widget added unbuilt (got %d frames)" % _copies(late, "MinimapFrame"))

	# World3D no longer calls setup() on the two widgets after adding them.
	# A reading of its source, since World3D's HUD needs the archive to build:
	# the lines between each add_child and the next widget's construction.
	var src := FileAccess.get_file_as_string(WORLD_PATH)
	var init_at := src.find("func _try_initialize_pk2_ui()")
	var body := src.substr(init_at, src.find("\nfunc ", init_at + 10) - init_at) if init_at >= 0 else ""
	_check(body != "", "World3D._try_initialize_pk2_ui is found")
	_check(not body.contains("_hud_minimap.setup()") and not body.contains("_hud_underbar.setup()"),
		"World3D._try_initialize_pk2_ui calls neither _hud_minimap.setup() nor _hud_underbar.setup() (add_child builds them)")

	hud.free()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
