class_name BuffRoster
extends RefCounted
## Every owner's active buffs as the server last told this connection
## (round 646): OpBuffStart adds a token, OpBuffEnd removes tokens, an owner's
## OpEntityLeft drops it, and a world entry or a zone change starts it over --
## the server re-sends every buff of the zone after each (sendBuffsInView).
##
## NetClient keeps it, so it outlives a scene: the in-view buffs the server
## sends straight after OpEnterWorldResult arrive while CharacterSelect is
## swapping in World3D, before World3D exists to hear buff_started (MEASURED
## in round 646: a relogged B's log has `BUFF start: owner 1 ... skill 113`
## and then no handler line and no aura). World3D replays the roster when it
## is ready, and re-attaches an owner's auras from it whenever it builds that
## owner's body -- on entry, on a zone change's arrival list, and on every
## OpEntityEntered.
##
## The retail client keeps a spawned object's buffs on the object itself:
## the spawn record's buff block (u8 count, {u32 skill id, u32 token}) goes to
## a pending list that FUN_009cf270 turns into IDecoSkill objects on the new
## body, the start effect skipped (READ, docs/protocol/skill_buffs.md
## "Entering view"). OpenSRO's bodies are rebuilt from its own messages, so
## the list is kept here, beside the connection, and applied to the body when
## it exists.

## "character:<id>" / "monster:<id>" -> {token: {"start": BuffStart,
## "at_ms": when it arrived}}, arrival order.
var _owners: Dictionary = {}
## owner key -> the last non-zero runSpeed an OpBuffStart or OpBuffEnd
## carried for it (round 646's review): the owner's current run speed, which
## a /speed-only OpBuffEnd (no tokens) at world entry carries too.
var _speeds: Dictionary = {}

static func key_of(owner_id: int, owner_kind: int) -> String:
	return "%s:%d" % ["monster" if owner_kind == SkillNet.OWNER_MONSTER else "character", owner_id]

## OpBuffStart. A start for a token already held replaces it (a re-send).
func start(bs: SkillNet.BuffStart, now_ms: int) -> void:
	if bs == null or bs.token == 0:
		return
	var key := key_of(bs.owner_id, bs.owner_kind)
	if bs.run_speed > 0:
		_speeds[key] = bs.run_speed
	var m: Dictionary = _owners.get(key, {})
	m[bs.token] = {"start": bs, "at_ms": now_ms}
	_owners[key] = m

## OpBuffEnd: its tokens go.
func end(be: SkillNet.BuffEnd) -> void:
	if be == null:
		return
	var key := key_of(be.owner_id, be.owner_kind)
	if be.run_speed > 0:
		_speeds[key] = be.run_speed
	var m: Dictionary = _owners.get(key, {})
	for t in be.tokens:
		m.erase(int(t))
	if m.is_empty():
		_owners.erase(key)

## An owner left view (OpEntityLeft, a monster's death): its buffs went with
## its body; if it comes back, the server sends them again.
func drop(key: String) -> void:
	_owners.erase(key)
	_speeds.erase(key)

func clear() -> void:
	_owners.clear()
	_speeds.clear()

## The owner's run speed as the last packet that set one said; 0 when none
## did since the roster started over.
func run_speed_of(key: String) -> int:
	return int(_speeds.get(key, 0))

func owners() -> Array:
	return _owners.keys()

func count() -> int:
	var n := 0
	for k in _owners:
		n += (_owners[k] as Dictionary).size()
	return n

## The owner's held starts as they stand at now_ms: a copy of each with its
## remaining time counted down since it arrived. A timed buff whose time has
## run out is left out -- its OpBuffEnd is due, and an aura started for it
## would outlive it (OURS). Arrival order.
func starts_of(key: String, now_ms: int) -> Array:
	var out: Array = []
	var m: Dictionary = _owners.get(key, {})
	for t in m:
		var held: Dictionary = m[t]
		var src: SkillNet.BuffStart = held["start"]
		var bs := SkillNet.BuffStart.new()
		bs.owner_id = src.owner_id
		bs.skill_id = src.skill_id
		bs.token = src.token
		bs.duration_ms = src.duration_ms
		bs.run_speed = src.run_speed
		bs.owner_kind = src.owner_kind
		bs.owner_kind_sent = src.owner_kind_sent
		bs.remaining_ms = src.remaining_ms
		if src.remaining_ms > 0:
			bs.remaining_ms = src.remaining_ms - maxi(now_ms - int(held["at_ms"]), 0)
			if bs.remaining_ms <= 0:
				continue
		out.append(bs)
	return out

## Every owner's held starts (starts_of for each), owner by owner.
func all_starts(now_ms: int) -> Array:
	var out: Array = []
	for k in _owners:
		out.append_array(starts_of(String(k), now_ms))
	return out
