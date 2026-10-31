extends RefCounted
class_name StateLook

## What an abnormal state looks like on a body (round 785): the state's
## system effect, its colour pulse and its effect on the body's clip speed.
## Labels: READ (sro_client.exe), MEASURED, INFERRED, OURS, OPEN.
##
## READ, FUN_009cd5e0 -- the object's mask setter, which 0x3057 (StatusNet)
## reaches -- walks the 32 bits low to high over (old mask XOR new mask):
## - a bit that came on starts the system decoration named "PARAM_" + the
##   state's label (UI_PARAM::AbnormalState_IconAndLabelForMask(bit, 1),
##   StatusNet.label; FUN_00a950a0 resolves the name, FUN_00a54020 starts
##   it) -- skilleffect.txt's `PARAM_<label>` rows (MEASURED: ACT_L AT_LOOP
##   battle\status_bad_<state>.efp for BU, ES, FB, PS, ZB, BLOOD, DISEASE,
##   STUN, DN, SLEEP, CHAOS, FEAR, MYOPIA, CURSE_HP, TIME_BOMB, FZ, ROOT,
##   STONE, SLOW; a DEACT row for FZ and STONE);
## - a bit that went off ends it (GlobalDataManager::FUN_009cd2b0), which
##   plays the DEACT rows; round 847 (READ): that end (FUN_00a53120 ->
##   FUN_00a4db00) fades the aura out over its row's Fade, 300 ms on every
##   PARAM_ row, and frees it (SkillEffects._end_kept) -- it no longer plays
##   its particles out (up to 4 s; confusion's never ended, 30 s);
## - and, for some bits, the body (unless it is the player riding, +0x2c2 1,
##   or an object of kind 2, +0x448):
##     0x1 FZ        the motion state 9 (FUN_009c8810(9)) and +0xbd = 1; off:
##                   +0xbd = 0
##     0x2 FB        a colour pulse (below) and the clip speed +0xc0 = 0.5
##                   (0xe1b7e0); off: the pulse ends, +0xc0 = 1.0
##     0x4 ES, 0x8 BU, 0x10 PS, 0x20 ZB, 0x2000 DN, 0x4000 STUN
##                   a colour pulse; off: it ends (vtable +0x4c)
##     0x100 SLOW    +0xc0 = 0.75 (0xdd8eec); off: 1.0
## - the pulse is the renderer's vtable +0x48 with two colours and 1000 ms:
##   CObjRendererVS::FUN_00c25800, BerserkLook's SCT_MAT pulse (its header:
##   a triangle wave from colour 1 to colour 2 and back, period 2 x ms). The
##   colours are floats in .rdata, READ per bit below (0xde2488..0xde24c4).
## HERE:
## - the effects are SkillEffects auras keyed by (owner, STATE_TOKEN - bit),
##   ended with their DEACT rows;
## - one pulse per body, the last one set in the walk wins and any tinted bit
##   going off ends it, as the walk does;
## - +0xc0 is the body's clip speed (INFERRED from the values: 0.5 for
##   frostbite, 0.75 for slowness); FZ's motion state 9 is taken as a held
##   pose -- clip speed 0 (INFERRED; the state table that would say what
##   state 9 plays is filled at run time and was not read, OPEN).

const BerserkLook = preload("res://scripts/effects/berserk_look.gd")

## Aura tokens for the states: STATE_TOKEN - bit, never a server token.
const STATE_TOKEN := -1000
const PULSE_MS := 1000.0

## The pulse colours per bit value (READ, FUN_009cd5e0's literals).
const TINTS := {
	0x2: [Color(0.47058824, 0.54901963, 1.0), Color(0.3137255, 0.38431373, 1.0)],
	0x4: [Color(1.0, 1.0, 0.2509804), Color(0.627451, 1.0, 0.0)],
	0x8: [Color(1.0, 0.3137255, 0.3137255), Color(1.0, 0.5647059, 0.1254902)],
	0x10: [Color(0.10980392, 0.19607843, 0.0627451), Color(0.2509804, 0.35686275, 0.1764706)],
	0x20: [Color(0.40784314, 0.3137255, 1.0), Color(0.3137255, 0.1882353, 0.6039216)],
	0x2000: [Color(1.0, 1.0, 0.2509804), Color(0.627451, 1.0, 0.0)],
	0x4000: [Color(1.0, 1.0, 0.2509804), Color(0.627451, 1.0, 0.0)],
}
const BIT_FZ := 0x1
const BIT_FB := 0x2
const BIT_SLOW := 0x100
const SPEED_FB := 0.5
const SPEED_SLOW := 0.75

## What one mask change does, walked as FUN_009cd5e0 walks it. `state` is the
## body's look so far ({"tint": [] or [c1, c2], "speed": float,
## "frozen": bool}); returns {"on": [bits came on], "off": [bits went off],
## "tint", "speed", "frozen"} -- the look after the change.
static func walk(old_mask: int, new_mask: int, state: Dictionary) -> Dictionary:
	var tint: Array = state.get("tint", [])
	var speed := float(state.get("speed", 1.0))
	var frozen := bool(state.get("frozen", false))
	var on: Array = []
	var off: Array = []
	var changed := (old_mask ^ new_mask) & 0xffffffff
	for bit in 32:
		var v := 1 << bit
		if changed & v == 0:
			continue
		var set := (new_mask & v) != 0
		if set:
			on.append(bit)
			if TINTS.has(v):
				tint = TINTS[v]
			if v == BIT_FB:
				speed = SPEED_FB
			elif v == BIT_SLOW:
				speed = SPEED_SLOW
			elif v == BIT_FZ:
				frozen = true
		else:
			off.append(bit)
			if TINTS.has(v):
				tint = []
			if v == BIT_FB or v == BIT_SLOW:
				speed = 1.0
			elif v == BIT_FZ:
				frozen = false
	return {"on": on, "off": off, "tint": tint, "speed": speed, "frozen": frozen}

## The clip speed a look gives the body: 0 while frozen, else its speed.
static func clip_speed(look: Dictionary) -> float:
	if bool(look.get("frozen", false)):
		return 0.0
	return float(look.get("speed", 1.0))

## The system decoration a state bit starts: "PARAM_" + its label, "" for a
## bit with no label (StatusNet.STATES: bits 12 and 23).
static func effect_id(bit: int) -> String:
	var label := StatusNet.label(bit)
	return "PARAM_" + label if label != "" else ""

# --- the colour pulse ---------------------------------------------------------

const ORIGINAL_META := "state_original_material"
## host instance id -> {host, c1, c2, t0, meshes}
static var _pulses: Dictionary = {}
static var _clock := 0.0

## Starts (or replaces) `host`'s pulse; an empty `tint` ends it.
static func set_tint(host: Node3D, tint: Array) -> void:
	if host == null or not is_instance_valid(host):
		return
	var key := host.get_instance_id()
	if tint.size() != 2:
		_end(key)
		return
	var p: Dictionary = _pulses.get(key, {"host": host, "meshes": {}})
	p["c1"] = tint[0]
	p["c2"] = tint[1]
	p["t0"] = _clock
	_pulses[key] = p
	_paint(p)

static func tinted(host: Node3D) -> bool:
	return host != null and is_instance_valid(host) and _pulses.has(host.get_instance_id())

static func tick(delta: float) -> void:
	_clock += maxf(delta, 0.0)
	for key in _pulses.keys():
		var p: Dictionary = _pulses[key]
		if not is_instance_valid(p["host"]):
			_pulses.erase(key)
			continue
		_paint(p)

## Round 785's client review, finding 8: a mesh the berserk look holds now
## (its own copy on it, BerserkLook.ORIGINAL_META) is left to it -- only this
## pulse's mark goes; berserk's end puts the real material back. Before, the
## state's end put the shared original under berserk's pulse, which then
## painted every body sharing it, and berserk's end put the state's stale
## copy back.
static func _end(key: int) -> void:
	var p: Dictionary = _pulses.get(key, {})
	_pulses.erase(key)
	for id in (p.get("meshes", {}) as Dictionary).keys():
		var mi = instance_from_id(id)
		if mi != null and is_instance_valid(mi) and (mi as Node).has_meta(ORIGINAL_META):
			if not (mi as Node).has_meta(BerserkLook.ORIGINAL_META):
				(mi as MeshInstance3D).material_override = (mi as Node).get_meta(ORIGINAL_META)
			(mi as Node).remove_meta(ORIGINAL_META)

static func _paint(p: Dictionary) -> void:
	var host: Node3D = p["host"]
	# A berserk body keeps the berserk pulse (OURS: one pulse slot, and the
	# berserk look owns the materials while it runs).
	if BerserkLook.active(host):
		return
	var skel := SkillEffects.skeleton_of(host)
	if skel == null:
		return
	var meshes: Dictionary = p["meshes"]
	for n in skel.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.is_queued_for_deletion() or meshes.has(mi.get_instance_id()):
			continue
		if BerserkLook._in_effect(mi, skel):
			continue
		var orig := AppearFade.original_material(mi)
		if orig == null or not (orig is StandardMaterial3D or orig is ShaderMaterial):
			continue
		mi.set_meta(ORIGINAL_META, orig)
		mi.material_override = orig.duplicate()
		meshes[mi.get_instance_id()] = true
	var c := BerserkLook.pulse((_clock - float(p["t0"])) * 1000.0, p["c1"], p["c2"], PULSE_MS)
	for id in meshes.keys():
		var mi = instance_from_id(id)
		if mi == null or not is_instance_valid(mi):
			meshes.erase(id)
			continue
		BerserkLook._paint((mi as MeshInstance3D).material_override, c)

static func clear() -> void:
	for key in _pulses.keys():
		_end(key)
	_pulses.clear()
