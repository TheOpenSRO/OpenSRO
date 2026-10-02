extends SceneTree

## Round 688: the user's three front-end reports, headless, on synthetic data
## (no archive):
##   1. the race-select lizard plays a clip that is not cyclic ONCE and keeps
##      its last pose -- it no longer snaps back off-screen every loop (READ:
##      CRTAniOneShot, docs/protocol/BSR_FORMAT.md; MEASURED: the archive's
##      interface_lizard_move is not cyclic and walks 4.16 units);
##   2. the front-end hour is picked once and kept when no title set it;
##   2b. (the review) a select body wears the characters' own light, not
##      Godot's lit materials;
##   3. a create-screen button's words fill the button (less its ClientRect)
##      and stay centred when the face in the tree is narrower than the
##      default face the label was first measured in -- the "Name Check"
##      overflow.
## `godot4 --headless --path client --script res://scripts/frontend/frontend_fixes_test.gd`
##
## NEGATIVE: on the base (bf25e7e, with this file and CharSelectQa copied
## in) check 1 FAILs (the clip loops: the bone is back at 2.0 at 1.5 s),
## check 2 FAILs (no front_end_phase) and check 3 FAILs ("Name Check" keeps
## the default face's width, its words right of centre).

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	# The autoloads (NetClient, which CharacterCreate.gd names) are in only
	# after the first frame.
	await process_frame
	_lizard()
	_phase()
	_select_light()
	await _button_text()
	print("ALL PASS" if _failures == 0 else "FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

## A one-bone clip whose bone walks from x = 4 to x = 0 over 1 s.
func _walk(cyclic: bool) -> BanReader.ParsedAnimation:
	var a := BanReader.ParsedAnimation.new()
	a.animation_name = "synthetic_move"
	a.duration_ms = 1000
	a.cyclic = cyclic
	a.key_times = PackedInt32Array([0, 1000])
	var track := BanReader.Bone.new()
	track.bone_name = "Bip01"
	for x in [4.0, 0.0]:
		var k := BanReader.Keyframe.new()
		k.rotation = Quaternion.IDENTITY
		k.position = Vector3(x, 0, 0)
		track.keyframes.append(k)
	a.bones.append(track)
	return a

## The stage's own per-frame posing of the lizard at times 0.5, 1.5, 2.5.
func _lizard_xs(cyclic: bool) -> Array:
	var stage := CharSelectStage.new()
	var sk := Skeleton3D.new()
	sk.add_bone("Bip01")
	var holder := Node3D.new()
	holder.add_child(sk)
	stage.props["lizard"] = holder
	stage.set("_lizard_skeleton", sk)
	stage.set("_lizard_anim", _walk(cyclic))
	stage.set("_lizard_anim_start", 0.0)
	var xs := []
	for dt in [0.5, 1.0, 1.0]:
		stage._process(dt)
		xs.append(snappedf(sk.get_bone_pose_position(0).x, 0.001))
	holder.free()
	stage.free()
	return xs

func _lizard() -> void:
	var once := _lizard_xs(false)
	_check(once[0] == 2.0, "a clip that is not cyclic: half-way at 0.5 s (got %s)" % str(once[0]))
	_check(once[1] == 0.0 and once[2] == 0.0, "a clip that is not cyclic plays once and keeps its last pose at 1.5 s and 2.5 s (got %s, %s)" % [str(once[1]), str(once[2])])
	var loops := _lizard_xs(true)
	_check(loops[1] == 2.0 and loops[2] == 2.0, "a cyclic clip still loops (got %s, %s)" % [str(loops[1]), str(loops[2])])

## Round 688's review: a select body wears the characters' own light
## (PlayerPortrait's materials: the client's formula) with the backdrop's
## tone mapping undone -- not Godot's lit materials.
func _select_light() -> void:
	var stage := CharSelectStage.new()
	var has := stage.has_method("_dress")
	_check(has, "CharSelectStage dresses its bodies (_dress exists)")
	if not has:
		stage.free()
		return
	var body := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	var src := StandardMaterial3D.new()
	src.albedo_color = Color(0.588, 0.588, 0.588)
	mi.material_override = src
	body.add_child(mi)
	stage.call("_dress", body)
	var m := mi.material_override as ShaderMaterial
	var code := m.shader.code if m != null and m.shader != null else ""
	_check(code.contains("modulate_scale") and code.contains("material_color"), "the body's material is the characters' formula (PlayerPortrait's)")
	_check(code.contains("undo_tonemap(clamp(modulate_scale * t.rgb * lit, 0.0, 1.0))"), "its colour goes through the tone-mapping undo")
	_check(m != null and m.get_shader_parameter("material_color") == Color(0.588, 0.588, 0.588), "the material's own colour is kept")
	body.free()
	stage.free()

func _phase() -> void:
	# Called through the script, so the suite still runs (and says FAIL) on a
	# tree without it.
	var handoff := load("res://scripts/frontend/charselect_handoff.gd") as GDScript
	var has := false
	for m in handoff.get_script_method_list():
		has = has or m["name"] == "front_end_phase"
	_check(has, "CharSelectHandoff.front_end_phase exists")
	if not has:
		return
	var saved := CharSelectHandoff.day_phase
	CharSelectHandoff.day_phase = -1.0
	var a: float = handoff.call("front_end_phase")
	var b: float = handoff.call("front_end_phase")
	_check(a in TitleIntro.TITLE_PHASES and a == b and CharSelectHandoff.day_phase == a,
		"with no title's hour, one of the title's four is picked once and kept (%.4f, %.4f)" % [a, b])
	CharSelectHandoff.day_phase = 0.75
	_check(float(handoff.call("front_end_phase")) == 0.75, "the title's hour, when set, is the one used")
	CharSelectHandoff.day_phase = saved

func _button_text() -> void:
	# The face in the tree is narrower than Godot's default face the label is
	# first measured in (the client's Arial against the fallback face: 71
	# against 98 units for "Name Check", MEASURED round 688).
	var holder := Control.new()
	holder.size = Vector2(400, 200)
	var theme := Theme.new()
	var narrow := FontVariation.new()
	narrow.base_font = ThemeDB.fallback_font
	narrow.spacing_glyph = -3
	theme.default_font = narrow
	holder.theme = theme
	root.add_child(holder)
	var screen = (load("res://scripts/CharacterCreate.gd") as GDScript).new()
	for spec in [["UIO_NEWCHAR_CTL_CHECK_OVERLAP", Rect2i(156, 57, 75, 25), Rect2i()],
			["UIO_NEWCHAR_CTL_FEMALE", Rect2i(166, 95, 70, 25), Rect2i(0, 0, 20, 0)]]:
		var d := UiLayoutParser.ControlDef.new()
		d.text = spec[0]
		d.rect = spec[1]
		d.client_rect = spec[2]
		d.font_index = 0
		d.font_color = Color.WHITE
		var b: TextureButton = screen._button(d)
		holder.add_child(b)
		await process_frame
		await process_frame
		var label := b.get_node("Text") as Label
		var inset: Rect2i = spec[2]
		var want := Rect2(b.global_position + Vector2(inset.position), b.size - Vector2(inset.position + inset.size))
		var got := label.get_global_rect()
		_check(got.position.distance_to(want.position) < 0.51 and got.size.distance_to(want.size) < 0.51,
			"'%s': the words' box is the button less its ClientRect, %s (got %s)" % [label.text, want, got])
		var tr := CharSelectQa.text_rect(b)
		_check(absf(tr.get_center().x - want.get_center().x) < 0.51 and absf(tr.get_center().y - want.get_center().y) < 0.51,
			"'%s': the words are centred in it (text %s)" % [label.text, tr])
		_check(b.get_global_rect().encloses(tr), "'%s': the words stay inside the button %s" % [label.text, b.get_global_rect()])
		# A resize carries the words with it (the layout's own rect is fixed;
		# a future resize must not strand them).
		b.size = Vector2(b.size.x + 20, b.size.y)
		await process_frame
		_check(absf(label.get_global_rect().size.x - (b.size.x - inset.position.x - inset.size.x)) < 0.51, "'%s': the words' box follows the button's size" % label.text)
	screen.free()
	holder.queue_free()
