extends SceneTree

## Round 741: the equipment particles turn with their bone.
##
## The user's +9 spear showed its sparks as a column a few units beside the
## shaft, lined up with it only when looking south-east. Round 734's EquipFx
## put each holder at the bone's POSITION only, so the effect's offsets (the
## +8 enchant's SetPosition space 7: 0, -1.2 .. -4.8 along the effect's X)
## ran along fixed world axes. Retail hands the effect the bone's whole
## matrix times the world's (READ: CRTModParticle::FUN_00c81190, 0xc811c5 ..
## 0xc81288, then CEFEffect::vslot_007).
##
## Checks, all synthetic (no game data):
## - holder_transform: the bone's world frame, its rotation and mirror kept,
##   its scale replaced by the row's x the body's;
## - an effect-space offset lands along the bone's own axis at every heading;
## - use_shared_turn switches billboard plates and pipes to the per-camera
##   shaders and leaves ViewNone nodes alone;
## - a turned plate's instance data, and the shader's billboard (replayed
##   here in GDScript) against the per-weapon path's at an unturned holder,
##   and facing the camera at a turned one;
## - pipe_turn's vertices plus the shader's side (replayed) against
##   pipe_ribbon's at an unturned holder.
##   godot4 --headless --path client --script res://scripts/assets/equip_fx_turn_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _near(a: Vector3, b: Vector3, eps := 1e-3) -> bool:
	return a.distance_to(b) < eps

func _initialize() -> void:
	await process_frame
	_test_holder_transform()
	_test_use_shared_turn()
	_test_plate_turn()
	_test_pipe_turn()
	print("FAILURES: %d" % _failures if _failures > 0 else "all passed")
	quit(1 if _failures > 0 else 0)

## A skeleton under a body turned by `yaw`, its one bone "ai_end" posed at
## `bone_pose` in the skeleton.
func _skel(yaw: float, bone_pose: Transform3D, body_scale := 1.0, mirror := false) -> Skeleton3D:
	var root := Node3D.new()
	if mirror:
		root.scale = Vector3(1, 1, -1)
	get_root().add_child(root)
	var body := Node3D.new()
	body.rotation.y = yaw
	body.scale = Vector3.ONE * body_scale
	body.position = Vector3(100, 5, -40)
	root.add_child(body)
	var s := Skeleton3D.new()
	s.add_bone("ai_end")
	s.set_bone_rest(0, bone_pose)
	s.reset_bone_poses()
	body.add_child(s)
	return s

func _test_holder_transform() -> void:
	# A bone whose X axis points along the blade's world direction: turned 30
	# degrees about Z and 50 about Y in the skeleton, 9 units up the arm.
	var pose := Transform3D(Basis(Vector3.UP, deg_to_rad(50)) * Basis(Vector3.BACK, deg_to_rad(30)), Vector3(3, 9, 1))
	var scale := 2.3
	for yaw_deg in [0, 45, 90, 135, 180, 225, 270, 315]:
		var s := _skel(deg_to_rad(yaw_deg), pose, 1.06)
		var h := EquipFx.holder_transform(s, 0, scale)
		var bone_world: Transform3D = s.global_transform * s.get_bone_global_pose(0)
		var ok := _near(h.origin, bone_world.origin)
		# The +8 enchant's offset -1.2 along the effect's X (space 7, in the
		# parent's frame, which follows the effect's rotation): it must lie
		# on the bone's own -X, scaled by the row and the body.
		var off := h * Vector3(-1.2, 0, 0)
		var want := bone_world.origin - bone_world.basis.x.normalized() * 1.2 * scale * 1.06
		ok = ok and _near(off, want)
		ok = ok and absf(h.basis.x.length() - scale * 1.06) < 1e-4 and absf(h.basis.z.length() - scale * 1.06) < 1e-4
		_check(ok, "heading %d: the holder sits at the bone and an effect offset runs along the bone's -X (%s vs %s)" % [yaw_deg, str(off), str(want)])
		s.get_parent().get_parent().queue_free()
	# Round 734's placement (position only) puts that offset along world -X:
	# off the blade at every heading but one -- the user's column of sparks.
	var s2 := _skel(deg_to_rad(90), pose)
	var bw: Transform3D = s2.global_transform * s2.get_bone_global_pose(0)
	var old := bw.origin + Vector3(-1.2 * scale, 0, 0)
	var new := EquipFx.holder_transform(s2, 0, scale) * Vector3(-1.2, 0, 0)
	_check(old.distance_to(new) > 1.0, "the position-only placement put the offset %.2f units off the blade at heading 90" % old.distance_to(new))
	s2.get_parent().get_parent().queue_free()
	# A mirrored body (the select screen's (1, 1, -1) root): the effect frame
	# mirrors with the weapon, so its offsets still run along the blade.
	var s3 := _skel(deg_to_rad(20), pose, 1.0, true)
	var h3 := EquipFx.holder_transform(s3, 0, scale)
	var bw3: Transform3D = s3.global_transform * s3.get_bone_global_pose(0)
	_check(h3.basis.determinant() < 0.0 and _near(h3 * Vector3(-1.2, 0, 0), bw3.origin - bw3.basis.x.normalized() * 1.2 * scale),
		"a mirrored body: the holder keeps the mirror and the offset stays on the blade")
	s3.get_parent().get_parent().queue_free()

## An effect with a billboard plate, a ViewNone plate and a pipe.
func _fake_fx() -> EfpEffect:
	var fx := EfpEffect.new()
	var tmpl := EfpSim.Template.new()
	for i in 10:
		var tp := EfpSim.Tpl.new()
		tp.index = i
		tmpl.tpls.append(tp)
	fx.sim = EfpSim.new(tmpl)
	fx.sim.clear()
	for v in ["ViewBillboard", "ViewNone", "ViewYBillboard"]:
		var mmi := MultiMeshInstance3D.new()
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = QuadMesh.new()
		mmi.multimesh = mm
		mmi.material_override = EfpEffect.material_for(PlaceholderTexture2D.new(), null, v != "ViewNone")
		fx.add_child(mmi)
		fx._draws.append([fx._draws.size(), mmi, v])
	var mi := MeshInstance3D.new()
	mi.mesh = ArrayMesh.new()
	mi.material_override = EfpEffect.link_material_for(PlaceholderTexture2D.new(), EfpReader.EfpRenderState.new())
	fx.add_child(mi)
	fx._links.append([9, mi, "RenderLinkPipe", EfpLinks.Out.new(), EfpLinks.Buf.new(), EfpLinks.Buf.new(), 1])
	fx._has_billboard = true
	fx._has_pipe = true
	return fx

func _test_use_shared_turn() -> void:
	var fx := _fake_fx()
	var before_none: Material = (fx._draws[1][1] as MultiMeshInstance3D).material_override
	fx.use_shared_turn()
	var bb := (fx._draws[0][1] as MultiMeshInstance3D).material_override as ShaderMaterial
	var yb := (fx._draws[2][1] as MultiMeshInstance3D).material_override as ShaderMaterial
	var none := (fx._draws[1][1] as MultiMeshInstance3D).material_override
	_check(bb.shader.code.contains("skip_vertex_transform") and bb.shader.code.contains("INSTANCE_CUSTOM")
		and bb.shader.code.contains("INV_VIEW_MATRIX[1].xyz"), "a ViewBillboard plate takes the per-camera billboard shader (camera up)")
	_check(yb.shader.code.contains("vec3 srr_up = vec3(0.0, 1.0, 0.0)"), "a ViewYBillboard plate's billboard keeps world up (READ)")
	_check(none == before_none, "a ViewNone node keeps its material: it turns with the holder, as its particles' rotation should")
	_check(bool(fx._draws[0][3]) and bool(fx._draws[2][3]) and not (fx._draws[1].size() > 3 and bool(fx._draws[1][3])),
		"the billboard draws are marked, the ViewNone draw is not")
	_check(not fx._has_billboard and not fx._has_pipe, "nothing is rewritten when only the camera turns")
	var link: Array = fx._links[0]
	var lm := (link[1] as MeshInstance3D).material_override as ShaderMaterial
	_check((link[3] as EfpLinks.Out).turn and lm.shader.code.contains("CUSTOM0") and lm.shader.code.contains("skip_vertex_transform"),
		"a pipe builds its side per camera (pipe_turn and its shader)")
	_check(bb.shader.code.contains("void fragment()") and bb.shader.code.count("void vertex()") == 1,
		"the fragment stage is kept and the vertex stage replaced once")
	fx.free()

## The billboard the turn shader builds (TURN_VERTEX), replayed: the world
## position of `vertex` on the instance (basis = particle scale, origin =
## particle position, custom = shape quaternion) under `holder`, for a camera
## with basis `cam`.
func _turn_vertex(holder: Transform3D, inst: Transform3D, q: Quaternion, vertex: Vector3, cam: Basis, y_up := false) -> Vector3:
	var model := holder * inst
	var sc := Vector3(model.basis.x.length(), model.basis.y.length(), model.basis.z.length())
	var v := q * (vertex * sc)
	var up := Vector3.UP if y_up else cam.y
	return model.origin + cam.x * v.x + up * v.y - cam.z * v.z

func _test_plate_turn() -> void:
	var fx := _fake_fx()
	fx.use_shared_turn()
	var p := EfpSim.Particle.new()
	p.tpl = 0
	p.pos = Vector3(-1.2, 0.5, 0.25)
	p.scale = Vector3(2.0, 3.0, 1.0)
	p.shape = Basis(Vector3.BACK, deg_to_rad(90))
	fx.sim.particles.append(p)
	fx._update_draws()
	var mm := (fx._draws[0][1] as MultiMeshInstance3D).multimesh
	_check(mm.visible_instance_count == 1, "the turned plate's MultiMesh holds the particle")
	# The instance as _update_draws writes it (the headless renderer keeps no
	# MultiMesh buffer to read back): scale and position, shape in custom.
	var t := Transform3D(Basis.from_scale(p.scale), p.pos)
	var c := EfpEffect.turn_custom(p)
	var q := Quaternion(c.r, c.g, c.b, c.a)
	_check(q.is_equal_approx(p.shape.get_rotation_quaternion()), "a turned plate's custom data is its shape's quaternion")
	# At an unturned holder (uniform scale s) the shader's billboard equals the
	# per-weapon path's: holder * particle_transform(p, ViewBillboard, cam).
	var cam := Basis.looking_at(Vector3(-0.3, -0.6, -1).normalized(), Vector3.UP)
	var s := 2.3
	var holder := Transform3D(Basis.from_scale(Vector3.ONE * s), Vector3(10, 2, -5))
	var max_err := 0.0
	for vtx in [Vector3(-0.5, -0.5, 0), Vector3(0.5, -0.5, 0), Vector3(0.5, 0.5, 0), Vector3(-0.5, 0.5, 0)]:
		var old: Vector3 = holder * (EfpEffect.particle_transform(p, "ViewBillboard", cam) * vtx)
		var new := _turn_vertex(holder, t, q, vtx, cam)
		max_err = maxf(max_err, old.distance_to(new))
	_check(max_err < 1e-4, "unturned holder: the shader's billboard is the per-weapon path's (max error %.6f)" % max_err)
	# At a turned holder the plate still faces the camera, at the turned position.
	var turned := Transform3D(Basis(Vector3(0.3, 1, 0.2).normalized(), 1.1) * s, Vector3(10, 2, -5))
	var a := _turn_vertex(turned, t, q, Vector3(-0.5, -0.5, 0), cam)
	var b := _turn_vertex(turned, t, q, Vector3(0.5, -0.5, 0), cam)
	var d := _turn_vertex(turned, t, q, Vector3(-0.5, 0.5, 0), cam)
	var n := (b - a).cross(d - a).normalized()
	var centre := _turn_vertex(turned, t, q, Vector3.ZERO, cam)
	_check(absf(absf(n.dot(cam.z)) - 1.0) < 1e-4 and _near(centre, turned * p.pos),
		"turned holder: the plate faces the camera and sits at the turned position")
	_check(absf((b - a).length() - s * 2.0) < 1e-3 or absf((b - a).length() - s * 3.0) < 1e-3,
		"turned holder: the plate keeps its size (%.3f)" % (b - a).length())
	fx.free()

## pipe_turn plus the shader's side (PIPE_TURN_VERTEX), replayed for one
## camera, against pipe_ribbon's vertices.
func _test_pipe_turn() -> void:
	var buf := EfpLinks.Buf.new()
	buf.add(Vector3(0, 0, 0), 0xFFFF8040, 0.5)
	buf.add(Vector3(1, 0.2, -0.3), 0xFFFF8040, 0.7)
	buf.add(Vector3(2.1, 0.1, -0.2), 0xFFFF8040, 0.4)
	var cam_t := Transform3D(Basis.looking_at(Vector3(0.2, -0.4, -1).normalized(), Vector3.UP), Vector3(1, 3, 12))
	var proj := Projection.create_perspective(50.0, 16.0 / 9.0, 0.1, 1000.0)
	var holder := Transform3D(Basis.from_scale(Vector3.ONE * 1.5), Vector3(4, 0, 2))
	# pipe_ribbon in the holder's space, as EfpEffect._link_view hands it.
	var vp := proj * Projection(cam_t.affine_inverse() * holder)
	var inv := holder.basis.inverse()
	var cb := cam_t.basis.orthonormalized()
	var ref := EfpLinks.Out.new()
	EfpLinks.pipe_ribbon(buf, vp, inv * cb.x, inv * cb.y, ref)
	var out := EfpLinks.Out.new()
	out.turn = true
	EfpLinks.pipe_turn(buf, out)
	_check(out.nv == ref.nv and out.format_flags() != 0 and (out.arrays()[Mesh.ARRAY_CUSTOM0] as PackedFloat32Array).size() == 4 * out.nv,
		"pipe_turn writes as many vertices as pipe_ribbon, with two custom channels (%d, %d)" % [out.nv, ref.nv])
	var view := cam_t.affine_inverse()
	var max_err := 0.0
	for i in out.nv:
		var c0 := Vector4(out.c0[4 * i], out.c0[4 * i + 1], out.c0[4 * i + 2], out.c0[4 * i + 3])
		var c1 := Vector3(out.c1[4 * i], out.c1[4 * i + 1], out.c1[4 * i + 2])
		var a := view * (holder * Vector3(c0.x, c0.y, c0.z))
		var b := view * (holder * c1)
		var k := Vector2(absf(proj.x.x), absf(proj.y.y))
		var dd := k * Vector2(a.x, a.y) / -a.z - k * Vector2(b.x, b.y) / -b.z
		var side := cam_t.basis.x * dd.y - cam_t.basis.y * dd.x
		var w := holder * out.verts[i]
		if side.length() > 0.0:
			w += side * (c0.w * holder.basis.x.length() / side.length())
		max_err = maxf(max_err, w.distance_to(holder * ref.verts[i]))
	_check(max_err < 1e-3, "the shader's pipe vertices are pipe_ribbon's at an unturned holder (max error %.6f)" % max_err)
