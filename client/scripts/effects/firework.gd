extends Node3D
class_name Firework

## A firework set off (round 860): the item's own model stands where the user
## stood, and its bursts go up from it every two seconds -- for the user and
## for every player around (the 0x305C every accepted use sends, round 859).
## Labels: READ (sro_client.exe, c:), MEASURED (the box's archives), INFERRED,
## OURS. docs/protocol/item_use_effects.md, "The fireworks", has the record.
##
## WHO MAKES IT (READ, 0x305C's handler NetProcessInInner::FUN_008735d0): for
## a 3/3/6 item (FUN_00666ce0) it calls the entity manager's create
## FUN_00ba36d0(&DAT_00eef6d0, {u32 the RefItemID, the user object})
## (c:0x8737d0..0x8737e8); DAT_00eef6d0 is CIParticleObj's class link
## (CIParticleObj::vslot_000 c:0x9c5090 returns it) -- a CICharactor of 0x79c
## bytes (CreateObject c:0x9c5140). Nothing is drawn on the user's body.
##
## ITS SET-UP (READ, CIParticleObj::vslot_007, c:0x9c5340):
##  - the user's +0x74 (7 dwords), +0x6b4 (7 dwords) and position +0x90..0x98
##    are copied: it stands where the user stood, as the user was turned
##    (here: the body's position and its yaw, at the 0x305C);
##  - its decoration record +0x798 = g_sSkillEffMapStr[the item's code name]
##    (FUN_00a95f10 on the map 0x110abe0 -- the skilleffect.txt rows filed by
##    SkillEffectID; the item's CodeName128 is its ref record +8);
##  - its model: FUN_009c4ec0(ref + 0x140, 1) -- the item ref's +0x140, the
##    drop model (itemdata column 53, AssocFileDrop128, the same field a
##    ground item CIItem draws, c:0x9e1492): `item\etc\firework_*.bsr`
##    (MEASURED, all ten);
##  - its bound's top +0xb0 is raised by 500.0 (.rdata 0xdd24b8): its
##    effects are not culled with the small model (Godot culls each effect
##    on its own; nothing to do here);
##  - the burst count +0x790 = byte +9 of the record's first ACT_S row (the
##    rows at +0xd4, first group, first 0xa0-byte row): the row parser
##    GlobalEffectManager::FUN_00a9d0f0 stores column 11, CreateCnt, there
##    (c:0xa9d5f8). MEASURED: 1 for the bombs, star shower and cross star,
##    8 for the chain bomb and the tadpole;
##  - +0x78c (bursts fired) = 0, +0x794 (the interval) = 2000 ms.
##
## ITS FRAME (READ, CIParticleObj::vslot_009, c:0x9c5460), after the
## character's own (FUN_009d1d60): while fired < count and
## fired x 2000 <= its age (+0x3c, the entity manager's per-frame sum of the
## frame ms, c:0xba35a1, added after the update): fired += 1, a new
## decoration (DAT_0110a820) is started on it with
## FUN_00a53850(0, this, record, 0, 1, 0) -- the ACT_S and ACT_L rows, ended
## at once (the fifth argument 1, as an item use's) -- while its height +0x94
## is raised by 8.0 (.rdata 0xd89240), and attached to it
## (GlobalDataManager::FUN_009cd050). So a burst every two seconds, the
## first on its first frame. Once all have gone and its decoration list is
## empty (+0x28c == 0), the entity manager deletes it at once
## (entitymanager::FUN_00ba3770 -- no fade).
##
## THE ROWS (MEASURED, skilleffect.txt): every firework's rows are ACT_S,
## AT_STOP, StartBone none: the shot (`system\firework_*.efp` /
## `item_firework_bomb_*.efp` with `firework\firework_shot_0n.wav`) and a
## sound-only row whose MovTypeSpeed delays its explosion
## (`firework_explosion_0n.wav`, 1300 ms; the chain bomb's 600 ms; the
## cross star's spark at 2000 ms). AT_STOP is placed once, when made, so
## each burst's effect stays at the lift point (8 above the model's foot),
## and the sounds are queued with that point (ItemUseEffect.sound_rows).
##
## NOT BUILT: an item with no rows -- SPIN and SPRAY (service 1, no
## skilleffect rows, MEASURED) and the fortress shock bomb: the original
## reads the null record's +0xd4 (c:0x9c53e9) and would fault; here nothing
## is made (OURS).

const INTERVAL_MS := 2000   ## +0x794 (READ c:0x9c5444)
const LIFT := 8.0           ## +0x94 raised while a burst starts (READ .rdata 0xd89240)
const BOUND_TOP := 500.0    ## +0xb0 raised (READ .rdata 0xdd24b8); kept for the record
## OURS: a firework whose effects never end is let go after this.
const MAX_LIFE_MS := 60000

var item_code := ""
var count := 1
var fired := 0
var age_ms := 0.0
var _fx: Array = []
var _pending_sounds := 0
## A test seam: Callable(effect_id, ani_type, host) -> Array of effects.
var play_rows: Callable = Callable()
## A test seam: Callable(rows, pos, label, alive) for the sounds.
var play_sounds_with: Callable = Callable()
var _lift: Node3D = null

signal burst(index: int, effects: int)

## The burst count for an effect id's rows: the first ACT_S row's CreateCnt
## (READ, see the header), at least 1; 0 when the id has no ACT_S row -- the
## original's record lookup fails there and nothing is made here.
static func burst_count(rows: Array) -> int:
	for r in rows:
		if int(r.get("ani", -1)) == SkillAudio.ACT_S:
			return maxi(int(r.get("cnt", 1)), 1)
	return 0

## Whether a burst is due: CIParticleObj::vslot_009's test (READ).
static func burst_due(fired_n: int, count_n: int, age: float) -> bool:
	return fired_n < count_n and float(fired_n * INTERVAL_MS) <= age

## The effect id's ACT_S rows as SkillEffects keeps them (bare: every row).
static func rows_of(code: String) -> Array:
	return SkillEffects.rows_named(code, SkillAudio.ACT_S, true)

## Makes the firework for `code` with `model` (may be null) standing at
## `at`, turned by `yaw`. Null when the code has no rows.
static func make(code: String, model: Node3D, at: Vector3, yaw: float) -> Firework:
	var n := burst_count(rows_of(code))
	if n <= 0:
		if model != null:
			model.free()
		return null
	var fw := Firework.new()
	fw.name = "Firework_%s" % code
	fw.item_code = code
	fw.count = n
	fw.position = at
	fw.rotation.y = yaw
	if model != null:
		model.name = "Model"
		fw.add_child(model)
	return fw

func _ready() -> void:
	_lift = Node3D.new()
	_lift.name = "Lift"
	_lift.position = Vector3(0, LIFT, 0)
	add_child(_lift)
	print("FIREWORK %s at %s: %d burst(s) every %d ms" % [item_code, global_position, count, INTERVAL_MS])

func _process(delta: float) -> void:
	step(delta * 1000.0)

## One frame: the burst test on the age so far, then the age (READ order:
## vslot_009 runs before the manager adds the frame's ms).
func step(ms: float) -> void:
	if burst_due(fired, count, age_ms):
		fired += 1
		_burst()
	elif fired >= count and _done():
		print("FIREWORK %s done after %d ms (%d burst(s))" % [item_code, int(age_ms), fired])
		queue_free()
		return
	age_ms += ms
	if age_ms > MAX_LIFE_MS:
		queue_free()

func _done() -> bool:
	if _pending_sounds > 0:
		return false
	for fx in _fx:
		if is_instance_valid(fx) and not (fx as Node).is_queued_for_deletion():
			return false
	return true

func _burst() -> void:
	var started: Array = []
	if play_rows.is_valid():
		started = play_rows.call(item_code, SkillAudio.ACT_S, _lift)
		started.append_array(play_rows.call(item_code, SkillAudio.ACT_L, _lift))
	else:
		started = SkillEffects.play_named(item_code, SkillAudio.ACT_S, _lift)
		started.append_array(SkillEffects.play_named(item_code, SkillAudio.ACT_L, _lift))
		for fx in started:
			if is_instance_valid(fx):
				(fx as EfpEffect).release()
	_fx.append_array(started)
	var rows := ItemUseEffect.sound_rows(item_code)
	var at := _lift.global_position if _lift.is_inside_tree() else position + Vector3(0, LIFT, 0)
	var label := "%s burst %d" % [item_code, fired]
	if play_sounds_with.is_valid():
		play_sounds_with.call(rows, at, label, Callable(self, "_alive"))
	else:
		for r in rows:
			if int(r["delay_ms"]) > 0:
				_pending_sounds += 1
				get_tree().create_timer(int(r["delay_ms"]) / 1000.0, false).timeout.connect(
					func() -> void: _pending_sounds -= 1)
		ItemUseEffect.play_sounds(rows, at, get_tree() if is_inside_tree() else null, label, Callable(self, "_alive"))
	var paths := PackedStringArray()
	for fx in started:
		if is_instance_valid(fx):
			paths.append((fx as EfpEffect).path)
	print("FIREWORK %s burst %d/%d at %.0f ms: %d effect(s) [%s], %d sound(s)" % [item_code, fired, count, age_ms,
		started.size(), ", ".join(paths), rows.size()])
	burst.emit(fired, started.size())

func _alive() -> bool:
	return is_instance_valid(self) and not is_queued_for_deletion()
