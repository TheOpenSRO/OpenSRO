extends SceneTree

## CharacterAppearance on synthetic skeletons and templates (never real game
## data), run headless:
## `godot4 --headless --path client --script res://scripts/ui/character_appearance_test.gd`
##
## What it holds the builder to: the scale byte's READ decode and tables, the
## READ bone-group names, Volume as a skin bind scaled across the bone (never
## along it) and per character, Height as the node's uniform scale, one
## visual per slot, the dual-weapon and harp model rules, and the weapon's
## animation group. The real-archive checks (all 52 Figures dressed, the
## measured heights, build times) are client/tools/appearance_probe.gd's.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _near(a: float, b: float, eps: float = 1e-4) -> bool:
	return absf(a - b) <= eps

func _vnear(a: Vector3, b: Vector3, eps: float = 1e-3) -> bool:
	return a.distance_to(b) <= eps

## A body skeleton: Bip01 at the origin, a spine turned 90 degrees about Z (its
## own X runs up the world's Y, as a Biped spine's does) and a thigh, plus one
## skinned body mesh bound to both.
func _skeleton() -> Skeleton3D:
	var s := Skeleton3D.new()
	s.add_bone("Bip01")
	s.set_bone_rest(0, Transform3D.IDENTITY)
	s.add_bone("Bip01 Spine")
	s.set_bone_parent(1, 0)
	s.set_bone_rest(1, Transform3D(Basis(Vector3(0, 0, 1), PI / 2.0), Vector3(0, 10, 0)))
	s.add_bone("Bip01 L Thigh")
	s.set_bone_parent(2, 0)
	s.set_bone_rest(2, Transform3D(Basis(Vector3(1, 0, 0), PI), Vector3(2, 8, 0)))
	for i in range(s.get_bone_count()):
		s.reset_bone_pose(i)
	s.force_update_all_bone_transforms()
	var mi := MeshInstance3D.new()
	mi.name = "body_piece"
	mi.mesh = BoxMesh.new()
	s.add_child(mi)
	mi.skin = _skin(s, ["Bip01 Spine", "Bip01 L Thigh"])
	mi.skeleton = mi.get_path_to(s)
	return s

func _skin(s: Skeleton3D, bones: Array) -> Skin:
	var skin := Skin.new()
	for name in bones:
		var b := s.find_bone(name)
		skin.add_bind(b, s.get_bone_global_rest(b).affine_inverse())
	return skin

## A worn item's template as CharacterAppearance keeps one: a holder whose mesh
## is skinned to the body skeleton two levels up.
func _item_template(name: String, s: Skeleton3D) -> Node3D:
	var holder := Node3D.new()
	holder.name = name
	var mi := MeshInstance3D.new()
	mi.name = name + "_mesh"
	mi.mesh = BoxMesh.new()
	mi.skin = _skin(s, ["Bip01 Spine"])
	holder.add_child(mi)
	mi.skeleton = NodePath("../..")
	holder.set_meta("bone_count", s.get_bone_count())
	return holder

func _bind_of(mi: MeshInstance3D, s: Skeleton3D, bone_name: String) -> Transform3D:
	for i in range(mi.skin.get_bind_count()):
		if mi.skin.get_bind_bone(i) == s.find_bone(bone_name):
			return mi.skin.get_bind_pose(i)
	return Transform3D()

func _mesh_named(root: Node, name: String) -> MeshInstance3D:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and String(n.name) == name:
			return n
		for c in n.get_children():
			stack.append(c)
	return null

func _init() -> void:
	# --- the scale byte (READ 0xa5b960 / 0xa5b7e0) ---
	_check(CharacterAppearance.height_index(0x22) == 2 and CharacterAppearance.volume_level(0x22) == 2, "0x22 is height 2, volume 2")
	_check(CharacterAppearance.height_index(0x04) == 4, "low nibble 4 is height 4")
	_check(CharacterAppearance.height_index(0x05) == 0, "a height above 4 reads 0")
	_check(CharacterAppearance.volume_level(0x40) == 4, "high nibble 4 is volume 4")
	_check(CharacterAppearance.volume_level(0x70) == 4, "a volume of 5..7 clamps to 4")
	_check(CharacterAppearance.volume_level(0x80) == 0, "a volume above 7 reads 0")
	var hf := [0.94, 0.97, 1.00, 1.03, 1.06]
	for i in range(5):
		_check(_near(CharacterAppearance.height_factor(i), hf[i]), "height %d scales by %.2f" % [i, hf[i]])
	_check(_near(CharacterAppearance.height_factor(0xff), 1.0), "0xFF changes nothing")
	_check(CharacterAppearance.volume_bone_scales(0xff, false).is_empty(), "0xFF scales no bone")

	# --- Volume's factors and groups ---
	_check(_near(CharacterAppearance.volume_factor(0, 0.88, 1.10), 0.88), "volume 0 is the group's min")
	_check(_near(CharacterAppearance.volume_factor(1, 0.88, 1.10), 0.94), "volume 1 is halfway from min to 1")
	_check(_near(CharacterAppearance.volume_factor(2, 0.88, 1.10), 1.0), "volume 2 is neutral")
	_check(_near(CharacterAppearance.volume_factor(3, 0.88, 1.10), 1.05), "volume 3 is halfway from 1 to max")
	_check(_near(CharacterAppearance.volume_factor(4, 0.88, 1.10), 1.10), "volume 4 is the group's max")
	var names: Array = CharacterAppearance.BONE_GROUP_NAMES
	_check(names.size() == 38, "38 bone-group names (0xed9b68)")
	_check(names[1] == "Bip01 Pelvis" and names[2] == "Bip01 Spine" and names[3] == "Bip01 Spine1", "groups 1-3: pelvis, spine, spine1")
	_check(names[8] == "Bip01 L UpperArm" and names[19] == "Bip01 R UpperArm", "groups 8 and 19: the upper arms")
	_check(names[29] == "Bip01 L Thigh" and names[33] == "Bip01 R Thigh", "groups 29 and 33: the thighs")
	_check(names[37] == "Bone01", "group 37: Bone01")
	var men := CharacterAppearance.volume_bone_scales(0x42, false)
	var women := CharacterAppearance.volume_bone_scales(0x42, true)
	_check(men.size() == 7 and women.size() == 8, "the men's table scales 7 bones, the women's 8")
	_check(_near(men["Bip01 Spine"], 1.10) and _near(men["Bip01 L UpperArm"], 1.20) and _near(men["Bip01 Pelvis"], 1.00), "men at volume 4: spine 1.10, arms 1.20, pelvis 1.00")
	_check(_near(women["Bone01"], 1.18) and not men.has("Bone01"), "only the women's table scales Bone01")
	_check(_near(CharacterAppearance.volume_bone_scales(0x02, false)["Bip01 Spine"], 0.88), "men at volume 0: spine 0.88")
	for v in CharacterAppearance.volume_bone_scales(0x22, true).values():
		_check(_near(v, 1.0), "volume 2 leaves every group at 1.0")
		break

	# --- Volume on a skin: across the bone, not along it ---
	var s := _skeleton()
	var mi := s.get_child(0) as MeshInstance3D
	CharacterAppearance.apply_volume(s, {"Bip01 Spine": 1.2})
	var rest := s.get_bone_global_rest(s.find_bone("Bip01 Spine"))
	var skin_m := rest * _bind_of(mi, s, "Bip01 Spine")
	var along := rest.origin + rest.basis.x * 3.0
	var across_y := rest.origin + rest.basis.y * 3.0
	var across_z := rest.origin + rest.basis.z * 3.0
	_check(_vnear(skin_m * along, along), "a vertex along the spine stays put (%s)" % str(skin_m * along))
	_check(_vnear(skin_m * across_y, rest.origin + rest.basis.y * 3.6), "a vertex on the spine's Y moves out by 1.2")
	_check(_vnear(skin_m * across_z, rest.origin + rest.basis.z * 3.6), "a vertex on the spine's Z moves out by 1.2")
	_check(_vnear(skin_m * rest.origin, rest.origin), "the bone's own origin stays put")
	var thigh_m := s.get_bone_global_rest(2) * _bind_of(mi, s, "Bip01 L Thigh")
	_check(thigh_m.is_equal_approx(Transform3D.IDENTITY), "a bone not in the table keeps its plain bind")
	CharacterAppearance.apply_volume(s, {})
	skin_m = rest * _bind_of(mi, s, "Bip01 Spine")
	_check(skin_m.is_equal_approx(Transform3D.IDENTITY), "re-applying neutral restores the plain bind")
	_check(s.get_bone_global_pose(s.find_bone("Bip01 L Thigh")).is_equal_approx(s.get_bone_global_rest(2)), "Volume moves no bone")

	# --- a palette bone the body lacks (READ ResObject::FUN_00be2f80: entry 0) ---
	_check(Skeleton3DBuilder.build_skin(s, PackedStringArray(["Bip01 Spine", "Bone03"])) == null,
		"by default a missing palette bone refuses the skin (the world's behaviour, unchanged)")
	var lenient := Skeleton3DBuilder.build_skin(s, PackedStringArray(["Bip01 Spine", "Bone03"]), false, true)
	_check(lenient != null and lenient.get_bind_count() == 2, "opted in, the skin keeps both palette entries")
	if lenient != null and lenient.get_bind_count() == 2:
		_check(s.get_bone_name(lenient.get_bind_bone(1)) == Skeleton3DBuilder.OBJECT_SPACE_BONE \
			and lenient.get_bind_pose(1).is_equal_approx(Transform3D.IDENTITY), "the missing bone binds to the still object-space bone")
		_check(s.get_bone_name(lenient.get_bind_bone(0)) == "Bip01 Spine", "the present bone binds to itself")

	# --- building from templates: dressed, one visual per slot, per-character skins ---
	var app := CharacterAppearance.new()
	var body_path := "char\\test\\body.bsr"
	app.add_body(1907, body_path)
	var tmpl := SkinnedBsrAssembler.AssembledCharacter.new()
	tmpl.skeleton = _skeleton()
	app._body_templates[body_path] = tmpl
	var bones := tmpl.skeleton.get_bone_count()
	app._items[5001] = {"models": PackedStringArray(["item\\chest_a.bsr"]), "type_ids": PackedInt32Array([3, 1, 1, 3])}
	app._items[5002] = {"models": PackedStringArray(["item\\chest_b.bsr"]), "type_ids": PackedInt32Array([3, 1, 1, 3])}
	app._items[5003] = {"models": PackedStringArray(["item\\earring.bsr"]), "type_ids": PackedInt32Array([3, 1, 5, 1])}
	app._items[5004] = {"models": PackedStringArray(["item\\axe_01.bsr"]), "type_ids": PackedInt32Array([3, 1, 6, 9])}
	app._full_items_loaded = true
	for p in ["item\\chest_a.bsr", "item\\chest_b.bsr", "item\\axe_01_l.bsr", "item\\axe_01_r.bsr"]:
		var key := "%s|%d|%s" % [body_path, bones, p.to_lower()]
		app._item_templates[key] = _item_template(p.get_file().get_basename(), tmpl.skeleton)
	var kit := [{"id": 5001, "plus": 3}, {"id": 5002, "plus": 7}, 5003, {"id": 5004, "plus": 1}]
	var b1 := app.build(1907, 0x44, kit)
	_check(b1 != null and b1 is Node3D, "build returns a Node3D")
	if b1 == null:
		_finish()
		return
	_check(b1.skeleton != null and b1.skeleton.get_parent() == b1, "the body's skeleton is its child")
	_check(_mesh_named(b1, "chest_b_mesh") != null, "the later chest is worn")
	_check(_mesh_named(b1, "chest_a_mesh") == null, "the earlier chest in the same slot is replaced")
	_check(_mesh_named(b1, "earring_mesh") == null, "an earring draws nothing")
	_check(_mesh_named(b1, "axe_01_l_mesh") != null and _mesh_named(b1, "axe_01_r_mesh") != null, "a dual axe wears its _l and _r models")
	var slots := []
	for w in b1.worn:
		slots.append(int(w["slot"]))
	_check(slots == [CharacterAppearance.SLOT_CHEST, CharacterAppearance.SLOT_WEAPON], "worn: chest then weapon (got %s)" % str(slots))
	_check(int(b1.worn[0]["plus"]) == 7 and int(b1.worn[1]["plus"]) == 1, "plus is kept per item")
	_check(b1.weapon_kind == 9 and b1.weapon_group == "dual_axe", "the dual axe picks the dual_axe group")
	_check(_vnear(b1.scale, Vector3.ONE * 1.06), "height 4: the node scales by 1.06 (got %s)" % str(b1.scale))
	_check(_near(b1.height_factor, 1.06) and b1.scale_byte == 0x44, "the body records its scale")

	var b2 := app.build(1907, 0x22, kit)
	_check(app.stats["builds"] == 2, "two builds")
	var spine := b1.skeleton.find_bone("Bip01 Spine")
	var r := b1.skeleton.get_bone_global_rest(spine)
	var m1 := r * _bind_of(_mesh_named(b1, "body_piece"), b1.skeleton, "Bip01 Spine")
	var m2 := r * _bind_of(_mesh_named(b2, "body_piece"), b2.skeleton, "Bip01 Spine")
	var mt := r * _bind_of(_mesh_named(tmpl.skeleton, "body_piece"), tmpl.skeleton, "Bip01 Spine")
	var probe := r.origin + r.basis.y * 2.0
	_check(_vnear(m1 * probe, r.origin + r.basis.y * 2.2), "volume 4 (a man): the body's spine is 1.10 across")
	_check(_vnear(m2 * probe, probe), "a second character at volume 2 is unaffected")
	_check(_vnear(mt * probe, probe), "the template is unaffected")
	var worn_spine := r * _bind_of(_mesh_named(b1, "chest_b_mesh"), b1.skeleton, "Bip01 Spine")
	_check(_vnear(worn_spine * probe, r.origin + r.basis.y * 2.2), "a worn piece skinned to the body follows Volume too")
	_check(_mesh_named(b1, "chest_b_mesh").mesh == _mesh_named(b2, "chest_b_mesh").mesh, "two characters share the worn mesh")
	_check(_mesh_named(b1, "body_piece").mesh == _mesh_named(tmpl.skeleton, "body_piece").mesh, "a character shares the template's body mesh")
	b1.set_scale_byte(0xff)
	m1 = r * _bind_of(_mesh_named(b1, "body_piece"), b1.skeleton, "Bip01 Spine")
	_check(_vnear(m1 * probe, r.origin + r.basis.y * 2.2) and _vnear(b1.scale, Vector3.ONE * 1.06),
		"0xFF changes nothing: Height 4 and Volume 4 stay (READ 0xa5b960)")
	_check(b1.scale_byte == 0xff, "0xFF is still stored")
	b1.set_scale_byte(0x20)
	m1 = r * _bind_of(_mesh_named(b1, "body_piece"), b1.skeleton, "Bip01 Spine")
	_check(_vnear(m1 * probe, probe) and _vnear(b1.scale, Vector3.ONE * 0.94), "set_scale_byte re-applies: volume 2, height 0")
	_check(app.build(4242, 0x22, []) == null, "an unknown model id builds nothing")

	# A dagger whose `_r` does not load falls back to the plain model (READ
	# 0xa5f4f0 -> LAB_00a5f851); its `_l` has no fallback.
	app._items[5005] = {"models": PackedStringArray(["item\\dagger_01.bsr"]), "type_ids": PackedInt32Array([3, 1, 6, 13])}
	app._item_templates["%s|%d|%s" % [body_path, bones, "item\\dagger_01.bsr"]] = _item_template("dagger_01", tmpl.skeleton)
	var b3 := app.build(1907, 0x22, [5005])
	_check(b3 != null and b3.worn.size() == 1 and Array(b3.worn[0]["drawn"]) == ["item\\dagger_01.bsr"],
		"a missing _r falls back to the plain path, a missing _l draws nothing (got %s)" % (str(b3.worn[0]["drawn"]) if b3 != null and not b3.worn.is_empty() else "none"))
	if b3 != null:
		b3.free()

	# --- item rules ---
	var tid := func(a: Array) -> PackedInt32Array: return PackedInt32Array(a)
	_check(CharacterAppearance.visual_slot(tid.call([3, 1, 1, 3])) == CharacterAppearance.SLOT_CHEST, "TypeID4 3 is the chest")
	_check(CharacterAppearance.visual_slot(tid.call([3, 1, 10, 6])) == CharacterAppearance.SLOT_FEET, "Europe light feet")
	_check(CharacterAppearance.visual_slot(tid.call([3, 1, 6, 2])) == CharacterAppearance.SLOT_WEAPON, "TypeID3 6 is the weapon")
	_check(CharacterAppearance.visual_slot(tid.call([3, 1, 4, 1])) == CharacterAppearance.SLOT_SHIELD, "3/1/4/1 is a shield")
	_check(CharacterAppearance.visual_slot(tid.call([3, 1, 4, 2])) == CharacterAppearance.SLOT_SHIELD, "3/1/4/2 is a shield")
	_check(CharacterAppearance.visual_slot(tid.call([3, 1, 4, 3])) == -1, "3/1/4/3 is not (IsShieldItem 0x56fab0 wants TypeID4 1 or 2)")
	_check(CharacterAppearance.visual_slot(tid.call([3, 1, 13, 1])) == CharacterAppearance.SLOT_AVATAR, "TypeID3 13 is an avatar")
	_check(CharacterAppearance.visual_slot(tid.call([3, 3, 1, 1])) == -1, "a consumable is worn nowhere")
	_check(Array(CharacterAppearance.item_models("item\\europe\\weapon\\dagger_01.bsr", tid.call([3, 1, 6, 13]), false)) \
		== ["item\\europe\\weapon\\dagger_01_l.bsr", "item\\europe\\weapon\\dagger_01_r.bsr"], "a dagger is drawn from _l and _r")
	_check(Array(CharacterAppearance.item_models("item\\europe\\weapon\\harp_01.bsr", tid.call([3, 1, 6, 14]), true)) \
		== ["item\\europe\\weapon\\harp_01_f.bsr"], "a woman's harp is _f")
	_check(Array(CharacterAppearance.item_models("item\\europe\\weapon\\harp_01.bsr", tid.call([3, 1, 6, 14]), false)) \
		== ["item\\europe\\weapon\\harp_01.bsr"], "a man's harp is the plain model")
	_check(Array(CharacterAppearance.item_models("item\\china\\weapon\\sword_01.bsr", tid.call([3, 1, 6, 2]), true)) \
		== ["item\\china\\weapon\\sword_01.bsr"], "a sword is its own model")

	# --- the weapon -> animation group table is World3D's ---
	# Read from World3D.gd's source: the script cannot be loaded without its
	# autoloads, which a --script run does not have.
	var world_groups := _world_weapon_groups()
	_check(not world_groups.is_empty() and world_groups == CharacterAppearance.WEAPON_ANIMATION_GROUP,
		"WEAPON_ANIMATION_GROUP matches World3D's (%d entries read)" % world_groups.size())

	for n in [b1, b2]:
		n.free()

	# --- the template cache goes with the appearance (NOTIFICATION_PREDELETE) ---
	var tmpl_id := tmpl.skeleton.get_instance_id()
	var item_ids := []
	for key in app._item_templates:
		if app._item_templates[key] != null:
			item_ids.append((app._item_templates[key] as Node).get_instance_id())
	var orphans_before := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	app = null
	var orphans_after := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	_check(not is_instance_id_valid(tmpl_id), "dropping the appearance frees its body template")
	var alive := 0
	for i in item_ids:
		if is_instance_id_valid(i):
			alive += 1
	_check(item_ids.size() > 0 and alive == 0, "and its %d item templates (%d left)" % [item_ids.size(), alive])
	_check(orphans_after < orphans_before, "orphan nodes drop when the appearance goes (%d -> %d)" % [orphans_before, orphans_after])
	s.free()
	_finish()

## World3D.WEAPON_ANIMATION_GROUP's `N: "group"` pairs, from its source text.
func _world_weapon_groups() -> Dictionary:
	var out := {}
	var f := FileAccess.open("res://scripts/World3D.gd", FileAccess.READ)
	if f == null:
		return out
	var inside := false
	var re := RegEx.create_from_string("(\\d+)\\s*:\\s*\"([a-z_]+)\"")
	while not f.eof_reached():
		var line := f.get_line()
		if line.begins_with("const WEAPON_ANIMATION_GROUP"):
			inside = true
			continue
		if inside:
			if line.begins_with("}"):
				break
			for m in re.search_all(line.split("#")[0]):
				out[int(m.get_string(1))] = m.get_string(2)
	return out

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(0)
