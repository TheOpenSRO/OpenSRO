extends RefCounted
class_name EfpNativeParity

## Round 763: the comparisons that hold EfpSimNative (the effect simulation in
## Rust) to EfpSim (GDScript), shared by efp_native_test (synthetic effects)
## and client/tools/efp_native_parity.gd (the real files). Each builds, from a
## GDScript sim, what the native side reports -- in the same layout as
## SrEfpSim.dump / take_draws / take_chains (native/src/gd_efp.rs) -- with
## the GDScript's own code (EfpEffect.particle_transform, turn_custom,
## EfpSim.color_of, EfpLinks.gather_from), and compares them BIT FOR BIT:
## floats through their bytes, so a -0.0 against +0.0 or two NaNs of different
## payloads differ.

## Floats a particle takes in a dump (gd_efp.rs dump's order).
const PF := 70

## A GDScript sim's state in SrEfpSim.dump's layout.
static func gd_dump(s: EfpSim) -> Dictionary:
	var n := s.particles.size()
	var at := {}
	for i in n:
		at[s.particles[i]] = i
	var pi := PackedInt64Array()
	pi.resize(5 * n)
	var pf := PackedFloat32Array()
	pf.resize(PF * n)
	for i in n:
		var p: EfpSim.Particle = s.particles[i]
		pi[5 * i] = p.tpl
		pi[5 * i + 1] = p.age
		pi[5 * i + 2] = (1 if p.alive else 0) | (2 if p.dying else 0) | (4 if p.changed else 0) | (8 if p.has_rvel else 0) | (16 if p.has_shape_vel else 0)
		pi[5 * i + 3] = p.color
		pi[5 * i + 4] = int(at.get(p.link, -1)) if p.link != null else -1
		var f := PF * i
		_v(pf, f, p.pos)
		_v(pf, f + 3, p.vel)
		EfpSimNative.put_rows(pf, f + 6, p.rot)
		EfpSimNative.put_rows(pf, f + 15, p.rvel)
		EfpSimNative.put_rows(pf, f + 24, p.shape)
		EfpSimNative.put_rows(pf, f + 33, p.shape_vel)
		_v(pf, f + 42, p.scale)
		pf[f + 45] = p.uv.x
		pf[f + 46] = p.uv.y
		pf[f + 47] = p.uv.z
		pf[f + 48] = p.uv.w
		_v(pf, f + 49, p.old_pos)
		EfpSimNative.put_rows(pf, f + 52, p.old_rot)
		EfpSimNative.put_rows(pf, f + 61, p.delta)
	var ei := PackedInt64Array()
	var ea := PackedFloat64Array()
	for e in s.emitters:
		ei.append(e.tpl)
		ei.append(1 if e.done else 0)
		ei.append(e.dying)
		ea.append(e.acc)
	return {"p_int": pi, "p_f32": pf, "e_int": ei, "e_acc": ea,
		"counters": PackedInt64Array([s.age, s.dropped, s.spawned, s.revived, n]),
		"acc": s._acc, "rng_state": s._rng.state, "origin": s.origin()}

static func _v(a: PackedFloat32Array, at: int, v: Vector3) -> void:
	a[at] = v.x
	a[at + 1] = v.y
	a[at + 2] = v.z

## "" when the two dumps are the same, bit for bit, else the first difference.
static func compare(want: Dictionary, got: Dictionary) -> String:
	if got.is_empty():
		return "no native dump"
	var wc: PackedInt64Array = want["counters"]
	var gc: PackedInt64Array = got["counters"]
	if wc != gc:
		return "counters (age, dropped, spawned, revived, count) %s against %s" % [str(gc), str(wc)]
	if int(want["rng_state"]) != int(got["rng_state"]):
		return "random state"
	if not _same64(PackedFloat64Array([float(want["acc"])]), PackedFloat64Array([float(got["acc"])])):
		return "step clock %.17g against %.17g" % [float(got["acc"]), float(want["acc"])]
	var wi: PackedInt64Array = want["p_int"]
	var gi: PackedInt64Array = got["p_int"]
	if wi != gi:
		for k in mini(wi.size(), gi.size()):
			if wi[k] != gi[k]:
				return "particle %d's %s: %d against %d" % [k / 5, ["tpl", "age", "flags", "colour", "link"][k % 5], gi[k], wi[k]]
		return "particle ints: %d against %d" % [gi.size(), wi.size()]
	var wf: PackedFloat32Array = want["p_f32"]
	var gf: PackedFloat32Array = got["p_f32"]
	if wf.to_byte_array() != gf.to_byte_array():
		var wb := wf.to_byte_array()
		var gb := gf.to_byte_array()
		for k in mini(wf.size(), gf.size()):
			if wb.decode_u32(4 * k) != gb.decode_u32(4 * k):
				return "particle %d's %s: %.9g against %.9g" % [k / PF, field_name(k % PF), gf[k], wf[k]]
		return "particle floats: %d against %d" % [gf.size(), wf.size()]
	if PackedInt64Array(want["e_int"]) != PackedInt64Array(got["e_int"]):
		return "emitters (tpl, done, dying)"
	if not _same64(want["e_acc"], got["e_acc"]):
		return "emitters' accumulators"
	if Vector3(want["origin"]) != Vector3(got["origin"]):
		return "origin"
	return ""

static func _same64(a: PackedFloat64Array, b: PackedFloat64Array) -> bool:
	return a.to_byte_array() == b.to_byte_array()

## The dump field a float offset falls in.
static func field_name(k: int) -> String:
	var names := [[0, "pos"], [3, "vel"], [6, "rot"], [15, "rvel"], [24, "shape"], [33, "shape_vel"],
		[42, "scale"], [45, "uv"], [49, "old_pos"], [52, "old_rot"], [61, "delta"]]
	var out := "?"
	for nm in names:
		if k >= int(nm[0]):
			out = "%s[%d]" % [nm[1], k - int(nm[0])]
	return out

## What EfpEffect._update_draws writes for `fx`'s draw nodes from GDScript sim
## `s` (the MultiMesh buffer layout: rows and origin, colour, custom data), the
## first `count` instances of each node: [counts, buffers...].
static func gd_draws(fx: EfpEffect, s: EfpSim, cam_rot: Basis) -> Array:
	var by_tpl := {}
	for p in s.particles:
		if not by_tpl.has(p.tpl):
			by_tpl[p.tpl] = []
		(by_tpl[p.tpl] as Array).append(p)
	var counts := PackedInt32Array()
	var out: Array = [counts]
	for d in fx._draws:
		var ps: Array = by_tpl.get(int(d[0]), [])
		var turn: bool = d.size() > 3 and bool(d[3])
		var buf := PackedFloat32Array()
		buf.resize(ps.size() * EfpSimNative.STRIDE)
		for i in ps.size():
			var p: EfpSim.Particle = ps[i]
			var t: Transform3D
			var custom: Color
			if turn:
				t = Transform3D(Basis.from_scale(p.scale), p.pos)
				custom = EfpEffect.turn_custom(p)
			else:
				t = EfpEffect.particle_transform(p, String(d[2]), cam_rot)
				custom = Color(p.uv.x, p.uv.y, p.uv.z, p.uv.w)
			var c := EfpSim.color_of(p.color)
			var o := EfpSimNative.STRIDE * i
			var b := t.basis
			var row := [b.x.x, b.y.x, b.z.x, t.origin.x, b.x.y, b.y.y, b.z.y, t.origin.y, b.x.z, b.y.z, b.z.z, t.origin.z,
				c.r, c.g, c.b, c.a, custom.r, custom.g, custom.b, custom.a]
			for k in EfpSimNative.STRIDE:
				buf[o + k] = row[k]
		counts.append(ps.size())
		out.append(buf)
	out[0] = counts
	return out

## "" when the native draws (take_draws) hold the GDScript ones, else why not.
static func compare_draws(want: Array, got: Array) -> String:
	if got.size() != want.size():
		return "draw nodes %d against %d" % [got.size() - 1, want.size() - 1]
	var wc: PackedInt32Array = want[0]
	var gc: PackedInt32Array = got[0]
	if wc != gc:
		return "instance counts %s against %s" % [str(gc), str(wc)]
	for i in range(1, want.size()):
		var w: PackedFloat32Array = want[i]
		var g: PackedFloat32Array = got[i]
		if g.size() < w.size():
			return "node %d's buffer holds %d floats for %d" % [i - 1, g.size(), w.size()]
		var gb := g.slice(0, w.size()).to_byte_array()
		var wb := w.to_byte_array()
		if gb != wb:
			for k in w.size():
				if gb.decode_u32(4 * k) != wb.decode_u32(4 * k):
					return "node %d instance %d float %d: %.9g against %.9g" % [i - 1, k / EfpSimNative.STRIDE, k % EfpSimNative.STRIDE, g[k], w[k]]
	return ""

## EfpEffect._update_links' gathering from GDScript sim `s` in take_chains'
## layout.
static func gd_chains(fx: EfpEffect, s: EfpSim) -> Dictionary:
	var meta := PackedInt32Array()
	var pos := PackedVector3Array()
	var col := PackedInt64Array()
	var w := PackedFloat32Array()
	var y := PackedVector3Array()
	var b := EfpLinks.Buf.new()
	for p in s.particles:
		if p.link != null:
			continue
		var di: int = fx._link_tpls.get(p.tpl, -1)
		if di < 0:
			continue
		var obj := int(fx._links[di][6]) == 2
		EfpLinks.gather_from(p, obj, b)
		meta.append(di)
		meta.append(b.n)
		for k in b.n:
			pos.append(b.pos[k])
			col.append(b.col[k])
			w.append(b.w[k])
			y.append(b.y[k] if obj else Vector3.ZERO)
	return {"meta": meta, "pos": pos, "col": col, "w": w, "y": y}

static func compare_chains(want: Dictionary, got: Dictionary) -> String:
	for k in ["meta", "col"]:
		if want[k] != got.get(k):
			return "chains' %s" % k
	for k in ["pos", "y"]:
		var a: PackedVector3Array = want[k]
		var b: PackedVector3Array = got.get(k, PackedVector3Array())
		if a.to_byte_array() != b.to_byte_array():
			return "chains' %s" % k
	if (want["w"] as PackedFloat32Array).to_byte_array() != (got.get("w", PackedFloat32Array()) as PackedFloat32Array).to_byte_array():
		return "chains' widths"
	return ""

## EfpEffect._update_links' strips from GDScript sim `s` for `fx`'s Link nodes
## (the real EfpLinks code into fresh Outs), in take_strips' layout: per node
## [vertex count, verts, colours, uvs, custom0, custom1].
static func gd_strips(fx: EfpEffect, s: EfpSim) -> Array:
	var outs: Array = []
	for d in fx._links:
		var o := EfpLinks.Out.new()
		o.turn = (d[3] as EfpLinks.Out).turn
		outs.append(o)
	var a := EfpLinks.Buf.new()
	var b := EfpLinks.Buf.new()
	for p in s.particles:
		if p.link != null:
			continue
		var di: int = fx._link_tpls.get(p.tpl, -1)
		if di < 0:
			continue
		var d: Array = fx._links[di]
		var out: EfpLinks.Out = outs[di]
		EfpLinks.gather_from(p, int(d[6]) == 2, a)
		match int(d[6]):
			2:
				EfpLinks.obj_ribbon(a, out)
			1:
				EfpLinks.spline(a, b)
				if out.turn:
					EfpLinks.pipe_turn(b, out)
			_:
				if out.turn:
					EfpLinks.pipe_turn(a, out)
	var res: Array = []
	for o in outs:
		var out: EfpLinks.Out = o
		var arr := out.arrays()
		res.append([out.nv, arr[Mesh.ARRAY_VERTEX], arr[Mesh.ARRAY_COLOR], arr[Mesh.ARRAY_TEX_UV],
			arr[Mesh.ARRAY_CUSTOM0] if out.turn else PackedFloat32Array(), arr[Mesh.ARRAY_CUSTOM1] if out.turn else PackedFloat32Array()])
	return res

## "" when every natively built strip (take_strips) is the GDScript's, bit for
## bit, else the first difference. A node the native side leaves to GDScript
## (null) is skipped.
static func compare_strips(want: Array, got: Array) -> String:
	if got.size() != want.size():
		return "link nodes %d against %d" % [got.size(), want.size()]
	var names := ["vertex count", "verts", "colours", "uvs", "custom0", "custom1"]
	for i in want.size():
		if got[i] == null:
			continue
		var w: Array = want[i]
		var g: Array = got[i]
		if int(w[0]) != int(g[0]):
			return "link node %d: %d vertices against %d" % [i, int(g[0]), int(w[0])]
		for k in range(1, 6):
			if var_to_bytes(w[k]) != var_to_bytes(g[k]):
				return "link node %d's %s" % [i, names[k]]
	return ""
