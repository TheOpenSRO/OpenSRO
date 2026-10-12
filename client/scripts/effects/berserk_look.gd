extends RefCounted

## What a character looks and sounds like while berserk (round 651): the red
## pulse on its body, the 10 % growth, the kept fire on its spine, arms, hand
## and calves, the burst and the sound when it starts, the burst and the sound
## when it ends, and -- for this client's own player only -- the white flash
## over the screen. Every body that is berserk carries it, this player's and
## every other player's (the server broadcasts the body mode, 0x30BF kind 4,
## and replays it to an arrival; round 651's server half).
##
## Everything below is READ out of sro_client.exe and Media.pk2's own tables
## unless it says otherwise (docs/protocol/berserk_look.md has the addresses).
##
## WHICH EFFECT (READ). 0x30BF kind 4 (0x8a80a0) calls the object's body-mode
## setter FUN_009cf880(mode, 0, extra) on ANY object in view, not only the
## player's own; mode 1 runs FUN_009dd620(1, ...), which attaches the system
## effect 0x80000000 through the decoration factory FUN_00a54020 when the
## object's hwan level (+0x764) is 0. The client's name table at 0x00ec73f8
## maps 0x80000000 to L"SYSTEM_CH_HWANMODE", and that id's rows are
## skilleffect.txt's `#section skilleffectset` rows of the same name
## (EFFECT_ID). A hwan level above 0 uses SYSTEM_CH_HWAN2MODE instead; the
## server has no hwan level, so that branch is OPEN here.
##
## THE ROWS (MEASURED on the box's Media.pk2, and read by `parse_rows`, never
## hard-coded here): one ACT_S AT_ONE_FOLLOW row (system_hwan_motion.efp at
## Bip01, SndBegin player\hwanchange.wav), seven ACT_L AT_LOOP rows
## (system_hwan_keep.efp at Bip01 Spine with the SCT_MAT script,
## system_hwan_keep_s.efp at L UpperArm with SCT_CHAR_SCALE, and at R UpperArm,
## L HandMid, R Finger2, L Calf, R Calf) and one DEACT row
## (system_hwan_disappear.efp, SndBegin player\hwanreturn.wav).
##
## ARRIVING BERSERK (READ). A spawned object's body mode comes in its state
## block (0x9d1300 reads it to +0x470) and FUN_009d17e0 applies it with
## FUN_009cf880(mode, 1, 0): arg 1 makes FUN_00a53850 skip the start effect
## (round 646), so a body that is already berserk when it is drawn gets the
## kept rows, the colour and the size, without the burst or the sound.
## `start(host, instant = true)` is that.
##
## THE COLOUR (READ). The Script column's `SCT_MAT,r1,g1,b1,r2,g2,b2,ms` is
## script flag 0x800 (the SCT_ name table at 0x00ec7378); the row parser
## GlobalEffectManager::FUN_00a9d0f0 packs the two colours as 0xFFrrggbb and
## keeps the int ms. The decoration's apply (IDecoSkill::FUN_00a513a0) divides
## each byte by 255.0 and hands both colours and the ms to the character's
## compound object (vtable +0x48, CObjRendererVS::FUN_00c25800). Its per-frame
## update CCompChar::FUN_00c26ff0 lerps from colour 1 to colour 2 over the ms,
## then back, and again -- a triangle wave of period 2 x ms (`pulse`). While
## it runs, CObjRendererVS::FUN_00c27180 replaces the material colour the
## renderer uses (FUN_00bf0e20 multiplies the light by the mesh material's
## diffuse, `fld [edi]`) with the pulse colour: vertex-shader constants c11 =
## light diffuse x colour, c10 = light ambient x colour, c14 = second light x
## colour. The end clears it (slot +0x4c, FUN_00c258b0), so the next draw is
## the material's own again. HERE (round 706) the character's materials
## compute the client's vertex colour themselves (ObjectLight), so the pulse
## is their `object_tint`: c10 = ambient x pulse, c11 = diffuse x pulse, on
## every piece of the body -- the skin, the clothes, the worn items -- and
## the original material goes back at the end.
##
## THE SIZE (READ). `SCT_CHAR_SCALE,s,ms` is flag 0x1000: the apply sets the
## character's scale target to s, reached over ms x 0.001 s (FUN_00a513a0,
## +0x734/+0x744); the end (IDecoSkill::FUN_00a4db00) sends it back to the
## scale it saved (+0xc8) over the same time. The in-between is linear, READ
## (round 651's review): each frame FUN_009d1d60 runs FUN_009c7bc0 on the
## +0x72c record -- t += rate x dt, clamped at 1, value = base + t x delta --
## and hands +0x72c to the render object's scale (vtable +0x24).
##
## THE FLASH (READ, own player only): the handler, for the player's own id and
## a non-zero mode, starts the weather manager's colour fade (0x8a827b) to
## (255, 255, 255, 128) over 0.2 s (0xd85284 = 255.0, 0xd821dc = 128.0,
## 0xda95f8 = 0.2) with 0.5 s (0xe1b7e0) to hold for the way back; its update
## (CGWeatherManager::vslot_009) sends any finished fade with a non-zero
## alpha back to alpha 0 over that 0.5 s. While a fade runs, vslot_010 draws a
## screen quad (FUN_00a43270: D3DRS_TEXTUREFACTOR = the colour, SRCBLEND
## SRCALPHA, DESTBLEND SRCCOLOR -- dst + alpha x white). `flash_alpha`.
##
## THE SOUNDS are the rows' SndBegin cells (above), played at the body, as
## SkillAudio plays a cast's.
##
## OURS: a looping effect is re-found on a rebuilt skeleton by EfpEffect's own
## follow (round 620); the mesh list is re-scanned every RESCAN_S seconds so
## an equipment change mid-berserk takes the colour too.

const EFFECT_ID := "SYSTEM_CH_HWANMODE"
const SKILLEFFECT_PATH := "server_dep\\silkroad\\textdata\\skilleffect.txt"
const SECTION := "skilleffectset"
## The SCT_ script flags (READ, the name table at 0x00ec7378).
const SCT_MAT := 0x800
const SCT_CHAR_SCALE := 0x1000
## The flash (READ, 0x8a827b..0x8a82be; see the header).
const FLASH_ALPHA := 128.0 / 255.0
const FLASH_IN_S := 0.2
const FLASH_OUT_S := 0.5
## OURS: how often a berserk body's meshes are looked for again.
const RESCAN_S := 0.25
## The meta a tinted mesh keeps its own material under.
const ORIGINAL_META := "berserk_original_material"
const SCALE_META := "berserk_base_scale"

# Fallback column indices (0-based, the skilleffectset header's own order).
const C_ID := 1
const C_ANI := 2
const C_ACT := 13
const C_PATH := 17
const C_NAME := 18
const C_BONE := 19
const C_OFFSET := 20
const C_SCRIPT := 25
const C_SND_BEGIN := 26
const C_SND_END := 27

static var _rows: Array = []
static var _loaded := false
static var _particles: Pk2Reader = null
## Test seams: Callable(path) -> EfpEffect or null; Callable(path, pos).
static var effect_factory: Callable = Callable()
static var sound_player: Callable = Callable()
## host instance id -> the look's state (see _new_look).
static var _looks: Dictionary = {}
static var _clock := 0.0

# --- the table (pure) ------------------------------------------------------------

## skilleffect.txt bytes -> EFFECT_ID's rows (or `id`'s), each
## {ani, act, path, bone, offset, script (parse_script), snd_begin, snd_end}.
## A row with no effect file still counts for its script and sounds.
static func parse_rows(bytes: PackedByteArray, id: String = EFFECT_ID) -> Array:
	var out: Array = []
	var in_section := false
	var col := {"act": C_ACT, "path": C_PATH, "name": C_NAME, "bone": C_BONE, "offset": C_OFFSET,
		"script": C_SCRIPT, "begin": C_SND_BEGIN, "end": C_SND_END}
	for raw in SkillAudio._utf16_lines(bytes):
		var line: String = raw
		if line.begins_with("#section"):
			var parts := line.replace("\t", " ").split(" ", false)
			in_section = parts.size() >= 2 and parts[1] == SECTION
			continue
		if not in_section:
			continue
		if line.begins_with("//"):
			var header := line.substr(2).split("\t")
			var names := {"ActType": "act", "Obj Path": "path", "ObjName": "name", "StartBone": "bone",
				"StartOffset": "offset", "Script": "script", "SndBegin": "begin", "SndEnd": "end"}
			for h in names:
				var at := header.find(h)
				if at >= 0:
					col[names[h]] = at
			continue
		var cols := line.split("\t")
		if cols.size() <= C_ANI or cols[C_ID].strip_edges() != id:
			continue
		var ani_name := cols[C_ANI].strip_edges()
		if not SkillAudio.ANI_TYPES.has(ani_name):
			continue
		var cell := func(k: String) -> String:
			var i := int(col[k])
			return cols[i].strip_edges() if cols.size() > i else ""
		var obj: String = cell.call("name")
		var path := ""
		if obj != "" and obj.to_lower() != "none" and obj.to_lower().ends_with(".efp"):
			var dir: String = cell.call("path")
			path = ("" if dir.to_lower() == "none" else dir) + obj
		var bone: String = cell.call("bone")
		out.append({
			"ani": int(SkillAudio.ANI_TYPES[ani_name]),
			"act": SkillEffects.ACT_TYPES.find(cell.call("act")),
			"path": path,
			"bone": bone if bone != "" else "none",
			"offset": SkillEffects.parse_offset(cell.call("offset")),
			"script": parse_script(cell.call("script")),
			"snd_begin": SkillAudio._sound_path(cell.call("begin")),
			"snd_end": SkillAudio._sound_path(cell.call("end")),
		})
	return out

## A Script cell -> {} for "none", else {"flag": SCT_MAT, "c1", "c2": Color,
## "ms": int} or {"flag": SCT_CHAR_SCALE, "scale": float, "secs": float}. The
## fields as FUN_00a9d0f0 reads them: SCT_MAT's six colour bytes and an int,
## SCT_CHAR_SCALE's float and int ms (x 0.001). Other scripts: {"flag": 0,
## "name": ...} (not drawn here).
static func parse_script(cell: String) -> Dictionary:
	var parts := cell.strip_edges().split(",")
	var name := String(parts[0]).strip_edges() if parts.size() > 0 else ""
	if name == "" or name.to_lower() == "none":
		return {}
	var nums: Array = []
	for i in range(1, parts.size()):
		nums.append(String(parts[i]).strip_edges())
	if name == "SCT_MAT" and nums.size() >= 7:
		var b := func(s: String) -> int: return clampi(int(s), 0, 255)
		return {"flag": SCT_MAT,
			"c1": Color8(b.call(nums[0]), b.call(nums[1]), b.call(nums[2])),
			"c2": Color8(b.call(nums[3]), b.call(nums[4]), b.call(nums[5])),
			"ms": maxi(int(nums[6]), 0)}
	if name == "SCT_CHAR_SCALE" and nums.size() >= 2:
		return {"flag": SCT_CHAR_SCALE, "scale": float(nums[0]), "secs": maxf(int(nums[1]) * 0.001, 0.0)}
	return {"flag": 0, "name": name}

## The body colour `elapsed_ms` after the start (CCompChar::FUN_00c26ff0):
## colour 1 at 0, colour 2 at `ms`, colour 1 again at 2 x `ms`, and so on.
static func pulse(elapsed_ms: float, c1: Color, c2: Color, ms: float) -> Color:
	if ms <= 0.0:
		return c1
	var cycle := fposmod(maxf(elapsed_ms, 0.0), 2.0 * ms)
	var f := cycle / ms if cycle <= ms else (2.0 * ms - cycle) / ms
	return c1.lerp(c2, f)

## The screen flash's alpha `t` seconds after an own activation (0 before and
## after it): up to FLASH_ALPHA over FLASH_IN_S, then down over FLASH_OUT_S.
static func flash_alpha(t: float) -> float:
	if t < 0.0 or t >= FLASH_IN_S + FLASH_OUT_S:
		return 0.0
	if t < FLASH_IN_S:
		return FLASH_ALPHA * t / FLASH_IN_S
	return FLASH_ALPHA * (1.0 - (t - FLASH_IN_S) / FLASH_OUT_S)

# --- the loaded table ----------------------------------------------------------------

static func set_archive(particles: Pk2Reader) -> void:
	_particles = particles

## Reads the rows from Media.pk2 once.
static func warm() -> void:
	if _loaded:
		return
	_loaded = true
	set_rows(parse_rows(AudioBank.read_table("media", SKILLEFFECT_PATH)))

## Test seam, and warm's end.
static func set_rows(rows: Array) -> void:
	_loaded = true
	_rows = rows
	var scripts := PackedStringArray()
	for r in _rows:
		if not (r["script"] as Dictionary).is_empty():
			scripts.append(str(r["script"]))
	print("BERSERK look: %d row(s) of %s; scripts %s" % [_rows.size(), EFFECT_ID, ", ".join(scripts)])

static func rows() -> Array:
	return _rows

# --- bodies ----------------------------------------------------------------------------

static func _valid(n) -> bool:
	return n != null and is_instance_valid(n) and n is Node3D and not (n as Node).is_queued_for_deletion()

static func _make(path: String) -> EfpEffect:
	if effect_factory.is_valid():
		return effect_factory.call(path)
	if _particles == null:
		return null
	return EfpEffect.create(path, _particles)

static func _play_sound(path: String, host: Node3D) -> void:
	if path == "":
		return
	var pos = host.global_position if host.is_inside_tree() else null
	if sound_player.is_valid():
		sound_player.call(path, pos)
	else:
		SoundTable.play_file(path, pos)
	AudioLog.line("berserk:%s" % path, "AUDIO berserk: %s at %s" % [path, host.name])

## Plays `ani`'s rows on `host`: their effects (kept when AT_LOOP) and their
## SndBegin. Returns the effects started.
static func _play(ani: int, host: Node3D, own: bool, sounds: bool) -> Array:
	var started: Array = []
	for r in _rows:
		if int(r["ani"]) != ani:
			continue
		if sounds:
			_play_sound(String(r["snd_begin"]), host)
		if String(r["path"]) == "":
			continue
		var fx := _make(String(r["path"]))
		if fx == null:
			print("BERSERK look: %s did not load (%s)" % [r["path"], EfpEffect.last_error])
			continue
		var act := int(r["act"])
		fx.loop = SkillEffects.kept_act(act) # round 785: AT_LOOP alone (READ)
		fx.static_host = act == SkillEffects.AT_STOP
		fx.reserved = own
		SkillEffects.attach(fx, host, String(r["bone"]), r["offset"])
		started.append(fx)
	return started

## The script of `flag` among `ani`'s rows, or {}.
static func _script(ani: int, flag: int) -> Dictionary:
	for r in _rows:
		if int(r["ani"]) == ani and int((r["script"] as Dictionary).get("flag", 0)) == flag:
			return r["script"]
	return {}

## `host` goes berserk. `instant`: it already was when it came into view (the
## spawn's arg 1): no burst, no sound. `own`: this client's player (the
## effects may use the reserved particle share). A body already berserk keeps
## its look. Returns the state (tests, logs).
static func start(host: Node3D, instant: bool = false, own: bool = false) -> Dictionary:
	if not _valid(host):
		return {}
	warm()
	var key := host.get_instance_id()
	if _looks.has(key) and not bool(_looks[key]["ending"]):
		return _looks[key]
	if _looks.has(key):
		_restore(_looks[key])
	var mat := _script(SkillAudio.ACT_L, SCT_MAT)
	var grow := _script(SkillAudio.ACT_L, SCT_CHAR_SCALE)
	var look := {"host": host, "own": own, "t0": _clock, "loops": [], "meshes": {}, "rescan": 0.0,
		"mat": mat, "grow": grow, "scale": 1.0, "scale_from": 1.0, "scale_to": 1.0,
		"scale_t0": _clock, "scale_secs": 0.0, "ending": false, "skeleton": null}
	if not instant:
		_play(SkillAudio.ACT_S, host, own, true)
	look["loops"] = _play(SkillAudio.ACT_L, host, own, not instant)
	if not grow.is_empty():
		look["scale_to"] = float(grow["scale"])
		look["scale_secs"] = float(grow["secs"])
	_looks[key] = look
	_update(look)
	print("BERSERK look on %s%s: %d kept effect(s), colour %s, size x%s" % [host.name,
		" (already berserk when drawn)" if instant else "", (look["loops"] as Array).size(),
		"%s -> %s every %d ms" % [mat["c1"], mat["c2"], mat["ms"]] if not mat.is_empty() else "none",
		str(look["scale_to"])])
	return look

## `host`'s berserk ends: the kept effects stop, the DEACT rows play, the
## colour goes at once and the size goes back over its time.
static func stop(host: Node3D) -> bool:
	if host == null or not is_instance_valid(host):
		return false
	var key := host.get_instance_id()
	if not _looks.has(key) or bool(_looks[key]["ending"]):
		return false
	var look: Dictionary = _looks[key]
	for fx in look["loops"]:
		if is_instance_valid(fx):
			(fx as EfpEffect).stop()
	look["loops"] = []
	_restore_materials(look)
	look["ending"] = true
	look["scale_from"] = float(look["scale"])
	look["scale_to"] = 1.0
	look["scale_t0"] = _clock
	if _valid(host):
		_play(SkillAudio.DEACT, host, bool(look["own"]), true)
	print("BERSERK look off %s" % host.name)
	_update(look)
	return true

## A body mode other than 1 for `host`: the ordinary end (stop), or, when
## `rebuilt` -- this player's own body on a zone change's arrival -- the
## silent drop. Returns whether a look was ended.
static func end(host: Node3D, rebuilt: bool) -> bool:
	return drop(host) if rebuilt else stop(host)

## `host`'s look goes at once and silently: no DEACT effect or sound, the
## colour and the size back to its own this frame. For a body the original
## client rebuilds rather than ends -- this player's own on a zone change's
## arrival (World3D._berserk_apply): a teleport is a re-entry (INFERRED,
## docs/protocol/berserk_look.md), whose new object is spawned with its body
## mode instead of playing the old one's end. Returns whether a look was held.
static func drop(host: Node3D) -> bool:
	if host == null or not is_instance_valid(host):
		return false
	var key := host.get_instance_id()
	if not _looks.has(key):
		return false
	_restore(_looks[key])
	_looks.erase(key)
	print("BERSERK look dropped from %s (no end effect)" % host.name)
	return true

## Whether `host` wears the look (and is not on its way out of it).
static func active(host: Node3D) -> bool:
	if host == null or not is_instance_valid(host):
		return false
	var look: Dictionary = _looks.get(host.get_instance_id(), {})
	return not look.is_empty() and not bool(look["ending"])

## The colour `host`'s body is drawn with now, or null when it has none.
static func tint_of(host: Node3D):
	var look: Dictionary = _looks.get(host.get_instance_id(), {}) if host != null and is_instance_valid(host) else {}
	if look.is_empty() or bool(look["ending"]) or (look["mat"] as Dictionary).is_empty():
		return null
	return _colour(look)

## `host`'s current size factor (1.0 without the look).
static func scale_of(host: Node3D) -> float:
	var look: Dictionary = _looks.get(host.get_instance_id(), {}) if host != null and is_instance_valid(host) else {}
	return float(look["scale"]) if not look.is_empty() else 1.0

## How many bodies wear or are leaving the look (tests).
static func count() -> int:
	return _looks.size()

## Forgets every look without drawing anything (a world unload).
static func clear() -> void:
	for key in _looks.keys():
		_restore(_looks[key])
	_looks.clear()

static func _colour(look: Dictionary) -> Color:
	var mat: Dictionary = look["mat"]
	return pulse((_clock - float(look["t0"])) * 1000.0, mat["c1"], mat["c2"], float(mat["ms"]))

## Advances every look by `delta` seconds. World3D calls it every frame.
static func tick(delta: float) -> void:
	_clock += maxf(delta, 0.0)
	for key in _looks.keys():
		var look: Dictionary = _looks[key]
		if not _valid(look["host"]):
			_looks.erase(key)
			continue
		_update(look)
		if bool(look["ending"]) and float(look["scale"]) == 1.0:
			_restore(look)
			_looks.erase(key)

static func _update(look: Dictionary) -> void:
	var host: Node3D = look["host"]
	# The size: a linear fade to the target over its time.
	var secs := float(look["scale_secs"])
	var f := 1.0 if secs <= 0.0 else clampf((_clock - float(look["scale_t0"])) / secs, 0.0, 1.0)
	look["scale"] = lerpf(float(look["scale_from"]), float(look["scale_to"]), f)
	var skel := SkillEffects.skeleton_of(host)
	if skel != null:
		if not skel.has_meta(SCALE_META):
			skel.set_meta(SCALE_META, skel.scale)
		var base: Vector3 = skel.get_meta(SCALE_META)
		skel.scale = base * float(look["scale"])
	if bool(look["ending"]) or (look["mat"] as Dictionary).is_empty():
		return
	# The colour, on every piece of the body.
	if skel != look["skeleton"] or _clock >= float(look["rescan"]):
		look["skeleton"] = skel
		look["rescan"] = _clock + RESCAN_S
		_take_meshes(look, skel)
	var c := _colour(look)
	for id in (look["meshes"] as Dictionary).keys():
		var mi = instance_from_id(id)
		if mi == null or not is_instance_valid(mi):
			(look["meshes"] as Dictionary).erase(id)
			continue
		_paint((mi as MeshInstance3D).material_override, c)

## The body's meshes that are not an effect's: each gets its own copy of its
## material, the original kept in ORIGINAL_META.
static func _take_meshes(look: Dictionary, skel: Skeleton3D) -> void:
	if skel == null:
		return
	for n in skel.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.is_queued_for_deletion() or _in_effect(mi, skel):
			continue
		if (look["meshes"] as Dictionary).has(mi.get_instance_id()):
			continue
		# A body fading into existence (AppearFade, round 676) draws with a
		# blended twin for two seconds; its own material is the one to copy.
		var orig := AppearFade.original_material(mi)
		if orig == null or not (orig is StandardMaterial3D or orig is ShaderMaterial):
			continue
		mi.set_meta(ORIGINAL_META, orig)
		mi.material_override = orig.duplicate()
		(look["meshes"] as Dictionary)[mi.get_instance_id()] = true

static func _in_effect(n: Node, stop_at: Node) -> bool:
	var p := n.get_parent()
	while p != null and p != stop_at:
		if p is EfpEffect:
			return true
		p = p.get_parent()
	return false

static func _paint(m: Material, c: Color) -> void:
	if m is StandardMaterial3D:
		var sm := m as StandardMaterial3D
		sm.albedo_color = Color(c.r, c.g, c.b, sm.albedo_color.a)
	elif m is ShaderMaterial:
		var sh := m as ShaderMaterial
		if sh.shader != null and sh.shader.code.contains("srr_obj_od0") or _includes_object_light(sh.shader):
			# The object shaders (round 706, ObjectLight): the pulse stands in
			# for both the material's and the object's colour (c11 and c10),
			# as the original's does. A Vector4: as given in both renderers.
			sh.set_shader_parameter("object_tint", Vector4(c.r, c.g, c.b, 1.0))
			return
		var was = sh.get_shader_parameter("albedo")
		if was is Color:
			sh.set_shader_parameter("albedo", Color(c.r, c.g, c.b, (was as Color).a))

## Whether a file shader is built on the object lighting include (its code
## names the include, not the functions).
static func _includes_object_light(shader: Shader) -> bool:
	return shader != null and shader.code.contains("object.gdshaderinc")

static func _restore_materials(look: Dictionary) -> void:
	for id in (look["meshes"] as Dictionary).keys():
		var mi = instance_from_id(id)
		if mi != null and is_instance_valid(mi) and (mi as Node).has_meta(ORIGINAL_META):
			(mi as MeshInstance3D).material_override = (mi as Node).get_meta(ORIGINAL_META)
			(mi as Node).remove_meta(ORIGINAL_META)
	(look["meshes"] as Dictionary).clear()

static func _restore(look: Dictionary) -> void:
	for fx in look["loops"]:
		if is_instance_valid(fx):
			(fx as EfpEffect).stop()
	look["loops"] = []
	_restore_materials(look)
	var host = look["host"]
	if host != null and is_instance_valid(host):
		var skel := SkillEffects.skeleton_of(host)
		if skel != null and skel.has_meta(SCALE_META):
			var base: Vector3 = skel.get_meta(SCALE_META)
			skel.scale = base
			skel.remove_meta(SCALE_META)
