extends RefCounted
class_name ExpOrbs

## Round 859 (lane B): the orbs a kill sends to this player -- small lights
## that pop out of the dying monster, hang a moment, curve back and sink into
## the player's chest with a soft chime. All READ from sro_client.exe unless
## marked (labels READ / MEASURED / INFERRED / OURS / OPEN).
##
## WHO SENDS THEM (READ). 0x3056 (Client_ApplyExpAndLevelUp c:0x8a97c0, after
## the EXP lines): when the source object (u32, the packet's first field) is
## in view and IsKindOf CICharactor (c:0xef1a5c), an EXP gain adds
## count_for(exp / the level record's +0x28) to the object's byte +0x759, an
## SP gain count_for(sp / 100.0) to +0x75a. The level record is the player's
## (after the gain's level-up): RefParse_leveldata c:0x97aab0 stores its sixth
## token, column 5 (the exp unit, `GUST_Mob_Exp`), at the object's +0x30, and
## FUN_00937f20 returns object + 8, so +0x28 is column 5 (READ; MEASURED 24 at
## level 1, 5170 at level 80). 0x304E kind 4 (c:0x8a70d0, the hwan count)
## adds the count's rise to +0x75b (violet) and 0x30C9 (c:0x8aa340, a COS's
## EXP) to +0x75c with the COS's id at +0x760.
## The object then launches them (FUN_009cb7c0) at once when it IsKindOf
## CICNPC (c:0xef1ac4); otherwise its DEAD state's animation event of type 100
## does (c:0xa59e30: `param_3 == 100`), or its destructor if that never comes
## (GlobalDataManager::FUN_009d2900). A monster is not a CICNPC (its RTTI
## chain is CICMonster : CICNonuser : CICharactor), so a kill's orbs wait for
## the die clip's type-100 key.
## FUN_009cb7c0: nothing while loading (DAT_0110f7d8 + 0x3c) or with no own
## player; with the display row's +0xd below 2 (INFERRED Effect Quality: "See
## All Effects" is 2) only the violet count reaches the berserk gauge and the
## counts are dropped; else the orbs start at the object's `Bip01` (its
## position when it has none) and ICPlayer::FUN_009d9400 spawns them on this
## player.
##
## THE ORBS (READ, ICPlayer::FUN_009d9400 c:0x9d9400). For each kind 0..3, in
## order, `count` orbs: a particle record whose effect is FLY[kind] made kept
## (slot 4 with 1), placed at the start; an angle of (rand() % 120 - 60)
## degrees; a mover inited (Mover.init) from the start toward this player's
## `Bip01 Spine1` (c:0xde2d18 via DAT_00ec4e0c; with no such bone the body's
## position + 10.0 up, c:0xe1b840). Each frame (CICPlayer::FUN_009d8820)
## the target is this player's spine again -- kind 3's is the COS's -- and
## the mover steps by the frame's ms (FUN_009eac50 with DAT_0110f7f8); the
## effect is placed at the mover's point. When the mover reports done, the
## flying effect is freed at once (slot 2), ABSORB[kind] is made at the point
## (placed once), `prim\snd\ui\hyanget.wav` plays there (the sound manager's
## +0x30 with 1.0), and a violet orb adds one to the berserk gauge's display
## (FUN_009d4ad0(1); round 860: `arrived` hands each arrival's kind to the
## owner -- World3D's HwanGauge steps the display). The absorb effect plays
## to its end and is freed.
const KIND_EXP := 0
const KIND_SP := 1
const KIND_HWAN := 2
const KIND_COS := 3
const FLY := ["battle\\hwan_g.efp", "battle\\hwan_y.efp", "battle\\hwan_v.efp", "battle\\hwan_g.efp"]
const ABSORB := ["battle\\hwn_blue_indraft.efp", "battle\\hwn_red_indraft.efp",
	"battle\\hwn_violet_indraft.efp", "battle\\hwn_blue_indraft.efp"]
const ABSORB_SOUND := "prim\\snd\\ui\\hyanget.wav"
const SOURCE_BONE := "Bip01"
const TARGET_BONE := "Bip01 Spine1"
const NO_BONE_RISE := 10.0
## The Effect Quality the orbs need (READ `cmp byte [row+0xd], 2; jb`).
const QUALITY_NEEDED := 2
## SP's divisor (READ, c:0xe1b7d8 = 100.0).
const SP_UNIT := 100.0
## The DEAD state's event that launches them (READ c:0xa59e30: `param_3 ==
## 100`). 100 is the animation mixer's clip-end call: AniMixer::FUN_00c53e80
## (c:0xc53f01, c:0xc5400c) calls the owner's callback slot 0 with (100, the
## animation, 0) when an animation's update reports it ended (bit 4), and
## CCompChar::FUN_00c53c90 (c:0xc53d87) the same as it drops one (READ). That
## the DEAD state's third argument is that first one is INFERRED (the body's
## forwarding was not read). MEASURED (tools/census_die_events.gd, 8,309
## bodies under res in Data.pk2): no die clip carries a key event of type
## 100 (583 die clips; 2 carry a type-1 key), so it is no key event. So the
## orbs leave as the monster's die clip ends.
const DEATH_EVENT := 100

## FUN_008a65b0 (READ): how many orbs a gain worth `f` same-level units sends.
## f >= 1: 10 at 64 or more, one fewer for each halving down to 4 at [1, 2);
## below 1: 3 - int((1 - f) * 5.0), at least 1; never more than 10.
static func count_for(f: float) -> int:
	var n := 0
	if f >= 1.0:
		n = 10
		var p := 64.0
		while true:
			if not (p > f):
				break
			p *= 0.5
			n -= 1
			if n <= 3:
				break
	else:
		n = 3 - int((1.0 - f) * 5.0)
	if n < 1:
		return 1
	return mini(n, 10)

## The EXP count's fraction: the gain over the level's exp unit (column 5);
## 0 when the table has none (READ: the unit is read as unsigned).
static func exp_fraction(exp_gain: int, exp_unit: int) -> float:
	if exp_unit == 0:
		return 0.0
	var unit := float(exp_unit) if exp_unit > 0 else float(exp_unit) + 4294967296.0
	return float(exp_gain) / unit

## The counts a 0x3056 gain adds: [exp, sp] (0 for a gain of nothing; READ:
## each test is `gain > 0`).
static func gain_counts(exp_gain: int, sp_gain: int, exp_unit: int) -> Array:
	var out := [0, 0]
	if exp_gain > 0:
		out[0] = count_for(exp_fraction(exp_gain, exp_unit))
	if sp_gain > 0:
		out[1] = count_for(float(sp_gain) / SP_UNIT)
	return out

## The mover (READ, FUN_009eaaa0 init and FUN_009eac50 step; the original's
## frame -- the world here has z mirrored, World3D converts at the edges).
class Mover:
	var v := Vector3.ZERO ## +0x00, units a second
	var p := Vector3.ZERO ## +0x0c
	var t := Vector3.ZERO ## +0x18
	var state := 0 ## +0x24: 1 waiting, 2 turning, 3 homing, 0 done
	var elapsed := 0 ## +0x28, ms
	var delay := 0 ## +0x2c, ms
	var k := 1.0 ## +0x30

	## FUN_009eaaa0(start, target, angle, scale, speed). `rand` answers 0..32767
	## (the CRT's rand()); its four draws are taken in the original's order.
	func init(start: Vector3, target: Vector3, angle: float, scale: float, speed: float, rand: Callable) -> void:
		p = start
		var dx := start.x - target.x
		var dz := start.z - target.z
		var s := sin(angle)
		var c := cos(angle)
		var hx := c * dx + s * dz
		# READ (c:0x9eab08..0x9eab1c): the z takes the NEW x, not dx -- the
		# original's own arithmetic.
		var hz := dz * c - s * hx
		var h := _unit(Vector3(hx, 0.0, hz))
		h.y = float(int(rand.call()) % 400) / 1000.0 + 0.1
		h = _unit(h)
		var r := float(int(rand.call()) % 25) + 50.0
		v = h * (r * scale)
		t = target
		elapsed = 0
		state = 1
		delay = int(rand.call()) % 800
		k = (float(int(rand.call()) % 400) / 1000.0 + 0.9) * speed

	## One step of `dt_ms`; false once done (the step after the arrival).
	func step(dt_ms: int) -> bool:
		if state == 0:
			return false
		if dt_ms == 0:
			return true
		elapsed += dt_ms
		var d := t - p
		var dist := d.length()
		if dist == 0.0:
			state = 0
			return false
		var dir := d / dist
		var timed := false
		if elapsed > delay + 0x898:
			var m0 := v.length()
			state = 3
			timed = true
			v = dir * m0
		if elapsed > delay + 0xdac:
			p = t
			state = 0
		var s := float(dt_ms) / 1000.0
		match state:
			1:
				if elapsed >= delay:
					state = 2
				return true
			2:
				if _unit(v).dot(dir) > k * 0.5:
					state = 3
				v += dir * (k * 78.4 * s)
				p += v * s
				return true
			3:
				v += dir * (k * 392.0 * s)
				var m := v.length()
				var h := _unit(v / m * 0.5 + dir * 0.5) if m > 0.0 else dir
				var arrive_test := timed
				if not timed:
					if h.dot(dir) > 0.93:
						h = dir
						arrive_test = true
				if arrive_test and m * s >= dist:
					p = t
					state = 0
					return true
				v = h * m
				p += v * s
				return true
		return true

	static func _unit(a: Vector3) -> Vector3:
		var l := a.length()
		return a / l if l > 0.0 else Vector3.ZERO

# --- the live orbs (World3D owns one) ------------------------------------------

## Where carriers and absorb effects go (the world's root).
var parent: Node = null
## path -> EfpEffect or null (World3D: EfpEffect.create on Particles.pk2).
var factory: Callable = Callable()
## (path, world position) -> void: the absorb chime.
var sound: Callable = Callable()
## Round 860: (kind) -> void, each orb's arrival (the violet one's gauge step).
var arrived: Callable = Callable()
## () -> int 0..32767.
var rand: Callable = func() -> int: return randi() & 0x7fff
## Orbs launched and absorbed (QA, tests).
var launched := 0
var absorbed := 0
var _orbs: Array = [] # of {kind, mover: Mover, carrier: Node3D, fx, target: Node3D}

## The world point an orb flies to: `body`'s TARGET_BONE, else its position
## + NO_BONE_RISE (READ, the no-bone branch).
static func target_point(body: Node3D) -> Vector3:
	return bone_or_rise(body, TARGET_BONE)

static func bone_or_rise(body: Node3D, bone: String) -> Vector3:
	var skel := SkillEffects.skeleton_of(body)
	if skel != null and skel.is_inside_tree() and skel.find_bone(bone) >= 0:
		return SkillEffects.bone_point(body, bone, Vector3.ZERO)
	return body.global_position + Vector3(0, NO_BONE_RISE, 0)

## The original's frame from the world's and back: z mirrored.
static func to_orig(w: Vector3) -> Vector3:
	return Vector3(w.x, w.y, -w.z)

## Spawns `counts` ([exp, sp, hwan, cos]) orbs at world point `start`, flying
## to `player` (kind 3 to `cos_body`, when given). Returns how many started.
func launch(start: Vector3, counts: Array, player: Node3D, cos_body: Node3D = null) -> int:
	if parent == null or not is_instance_valid(parent) or player == null or not is_instance_valid(player):
		return 0
	var aim := to_orig(target_point(player))
	var from := to_orig(start)
	var n := 0
	for kind in range(4):
		var count := int(counts[kind]) if kind < counts.size() else 0
		var target: Node3D = player
		if kind == KIND_COS:
			if cos_body == null or not is_instance_valid(cos_body):
				continue
			target = cos_body
		for _i in range(count):
			var angle := (float(int(rand.call()) % 120) - 60.0) * 0.01745329238474369
			var m := Mover.new()
			m.init(from, aim, angle, 1.0, 1.0, rand)
			var carrier := Node3D.new()
			carrier.name = "ExpOrb"
			parent.add_child(carrier)
			carrier.global_position = start
			var fx = factory.call(FLY[kind]) if factory.is_valid() else null
			if fx != null:
				# READ: made kept (slot 4 with 1).
				fx.loop = true
				carrier.add_child(fx)
				fx.follow_host(carrier, "none", Vector3.ZERO)
			_orbs.append({"kind": kind, "mover": m, "carrier": carrier, "fx": fx, "target": target})
			n += 1
	launched += n
	return n

## Moves every orb by `delta` seconds (the frame's ms, truncated as the
## original's DWORD).
func tick(delta: float) -> void:
	if _orbs.is_empty():
		return
	var dt := int(delta * 1000.0)
	var keep: Array = []
	for o in _orbs:
		var carrier = o["carrier"]
		if carrier == null or not is_instance_valid(carrier):
			continue
		var m: Mover = o["mover"]
		var tgt = o["target"]
		if tgt != null and is_instance_valid(tgt):
			m.t = to_orig(target_point(tgt))
		if m.step(dt):
			(carrier as Node3D).global_position = to_orig(m.p)
			keep.append(o)
			continue
		_absorb(o)
	_orbs = keep

func _absorb(o: Dictionary) -> void:
	var carrier: Node3D = o["carrier"]
	var at := carrier.global_position
	var fx = o["fx"]
	if fx != null and is_instance_valid(fx):
		(fx as EfpEffect).stop()
	carrier.queue_free()
	absorbed += 1
	var kind := int(o["kind"])
	var ab = factory.call(ABSORB[kind]) if factory.is_valid() else null
	if ab != null:
		var anchor := Node3D.new()
		anchor.name = "ExpOrbAbsorb"
		parent.add_child(anchor)
		anchor.global_position = at
		anchor.add_child(ab)
		ab.static_host = true
		ab.follow_host(anchor, "none", Vector3.ZERO)
		ab.tree_exited.connect(func() -> void:
			if is_instance_valid(anchor) and not anchor.is_queued_for_deletion():
				anchor.queue_free(), CONNECT_ONE_SHOT)
	if sound.is_valid():
		sound.call(ABSORB_SOUND, at)
	if arrived.is_valid():
		arrived.call(kind)

## Orbs in flight (tests, QA).
func live() -> int:
	return _orbs.size()

## Round 860: drops the orbs of one kind in flight (READ, FUN_009d8610: the
## hwan count's reset deletes the violet orbs). Returns how many.
func drop_kind(kind: int) -> int:
	var keep: Array = []
	var n := 0
	for o in _orbs:
		if int(o["kind"]) == kind:
			var c = o["carrier"]
			if c != null and is_instance_valid(c):
				(c as Node).queue_free()
			n += 1
		else:
			keep.append(o)
	_orbs = keep
	return n

## Orbs of one kind in flight.
func live_of(kind: int) -> int:
	var n := 0
	for o in _orbs:
		if int(o["kind"]) == kind:
			n += 1
	return n

## Drops every orb at once (a world teardown).
func clear() -> void:
	for o in _orbs:
		var c = o["carrier"]
		if c != null and is_instance_valid(c):
			(c as Node).queue_free()
	_orbs.clear()
