extends SceneTree

## NpcSpawnNet (round 708) against testdata/npc_spawn_golden.json -- the bytes
## server/internal/npcspawn TestGolden encodes -- and the facing conversion.
## `godot4 --headless --path client --script res://scripts/net/npc_spawn_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _unhex(s: String) -> PackedByteArray:
	return s.replace(" ", "").replace("|", "").hex_decode()

func _golden() -> Dictionary:
	var f := FileAccess.open("res://scripts/net/testdata/npc_spawn_golden.json", FileAccess.READ)
	_check(f != null, "npc_spawn_golden.json opens")
	return JSON.parse_string(f.get_as_text()) if f != null else {}

func _check_record(rec: NpcSpawnNet.Record, g: Dictionary, label: String) -> void:
	_check(rec != null, "%s decodes" % label)
	if rec == null:
		return
	_check(rec.ref_id == int(g.ref_id), "%s ref id %d" % [label, rec.ref_id])
	_check(rec.uid == int(g.uid), "%s uid %d" % [label, rec.uid])
	_check(rec.region == int(g.region) and rec.region_x == (int(g.region) >> 8) and rec.region_y == (int(g.region) & 0xff), "%s region %d" % [label, rec.region])
	_check(rec.local_position == Vector3(g.x, g.y, g.z), "%s position %s" % [label, rec.local_position])
	_check(rec.angle == int(g.angle), "%s angle %d" % [label, rec.angle])
	_check(rec.flags == int(g.flags), "%s flags %d" % [label, rec.flags])
	_check(rec.name == String(g.name), "%s name '%s'" % [label, rec.name])
	var want := PackedByteArray()
	for v in g.interactions:
		want.append(int(v))
	_check(rec.interactions == want, "%s interactions %s" % [label, rec.interactions])

func _test_golden() -> void:
	var g := _golden()
	if g.is_empty():
		return
	for key in ["record_a", "record_b"]:
		var r := NpcSpawnNet.Reader.new(_unhex(g[key].hex))
		var rec := NpcSpawnNet.read_record(r)
		_check(r.error == "" and r.pos == r.data.size(), "%s reads to its end (%s)" % [key, r.error])
		_check_record(rec, g[key], key)
	# A group spawn split over two data frames, as the server may chunk it.
	var body := _unhex(g.record_a.hex) + _unhex(g.record_b.hex)
	var grp := NpcSpawnNet.Group.new()
	grp.begin(_unhex(g.group_begin_spawn))
	grp.append(body.slice(0, 17))
	grp.append(body.slice(17))
	var out := grp.finish()
	_check(out.error == "" and out.kind == NpcSpawnNet.GROUP_SPAWN and out.records.size() == 2, "group spawn: 2 records (%s)" % out.error)
	if out.records.size() == 2:
		_check_record(out.records[0], g.record_a, "group record 0")
		_check_record(out.records[1], g.record_b, "group record 1")
	grp.begin(_unhex(g.group_begin_despawn))
	grp.append(_unhex(g.despawn_body))
	out = grp.finish()
	_check(out.error == "" and out.kind == NpcSpawnNet.GROUP_DESPAWN and out.uids == [int(g.record_a.uid)], "group despawn names record a's uid")
	_check(grp.finish().error != "", "a 0x3018 with no 0x3017 is refused")
	var single := NpcSpawnNet.decode_single_spawn(_unhex(g.record_a.hex) + _unhex(g.single_spawn_tail))
	_check_record(single, g.record_a, "0x3015")
	_check(single != null and single.spawn_type == 5, "0x3015 spawn type byte")
	_check(NpcSpawnNet.decode_single_despawn(_unhex(g.single_despawn)) == int(g.record_a.uid), "0x3016 uid")
	var unfaced := NpcSpawnNet.decode_facing_unknown(_unhex(g.facing_unknown))
	_check(unfaced == [int(g.record_b.uid)], "OpNpcFacingUnknown names record b")
	# A record cut short is refused, not half-read.
	var cut := NpcSpawnNet.Reader.new(_unhex(g.record_a.hex).slice(0, 30))
	_check(NpcSpawnNet.read_record(cut) == null and cut.error != "", "a cut-short record is refused")

func _test_roster() -> void:
	var g := _golden()
	if g.is_empty():
		return
	var roster := NpcSpawnNet.Roster.new()
	roster.facing_unknown([int(g.record_b.uid)])
	var a := roster.spawn(NpcSpawnNet.read_record(NpcSpawnNet.Reader.new(_unhex(g.record_a.hex))))
	var b := roster.spawn(NpcSpawnNet.read_record(NpcSpawnNet.Reader.new(_unhex(g.record_b.hex))))
	_check(a.has_angle and not b.has_angle, "the uid OpNpcFacingUnknown named has no angle; the other keeps its own")
	_check(roster.npcs.size() == 2, "the roster holds both")
	_check(roster.despawn(a.uid) and not roster.despawn(a.uid) and roster.npcs.size() == 1, "a despawn drops once")
	roster.clear()
	_check(roster.npcs.is_empty(), "clear empties it")

## The holder's drawn front (its body's -Z) for an angle, as a region-local
## direction (x east, z north).
func _front(angle: int) -> Vector3:
	var holder := Node3D.new()
	holder.rotation.y = NpcSpawnNet.holder_yaw(NpcSpawnNet.heading_of(angle))
	var f := holder.basis * Vector3(0, 0, -1)
	holder.free()
	return f

func _test_compass() -> void:
	# The server's heading of angle a is (cos a, sin a); the client's h =
	# a + pi/2 faces (sin h, -cos h) -- the same: 0 east, 16384 north,
	# 32768 west, 49152 south.
	var want := {0: Vector3(1, 0, 0), 16384: Vector3(0, 0, 1), 32768: Vector3(-1, 0, 0), 49152: Vector3(0, 0, -1)}
	for angle in want:
		var f := _front(angle)
		_check(f.distance_to(want[angle]) < 1e-3, "angle %d draws facing %s (want %s)" % [angle, f, want[angle]])
	# And for every angle: the drawn front is (cos a, 0, sin a).
	var worst := 0.0
	for angle in range(0, 65536, 97):
		var a := float(angle) / 65535.0 * TAU
		worst = maxf(worst, _front(angle).distance_to(Vector3(cos(a), 0, sin(a))))
	_check(worst < 1e-3, "every angle draws the server's heading (worst %.5f)" % worst)

func _init() -> void:
	_test_golden()
	_test_roster()
	_test_compass()
	if _failures > 0:
		print("%d failure(s)" % _failures)
		quit(1)
	else:
		print("all npc spawn checks passed")
		quit(0)
