extends SceneTree

## Round 840 (lane B): the stall booth's own clip, the title's height, the
## owner's pets' vendor loop data, the 0x3405 line and the title's word
## filter. The booth's clip runs on the synthetic map-animation tree (no game
## data); the real booths and pets are checked against the box's Data.pk2
## when it is there (skipped otherwise).
##   godot4 --headless --path client --script res://scripts/world/stall840_test.gd

const F := preload("res://scripts/world/map_animation_fixture.gd")
const DATA := "/opt/sro-files/client/Data.pk2"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	await _run()
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)

## The skeleton's bone poses, for comparing two moments.
func _pose(skel: Skeleton3D) -> Array:
	var out := []
	for b in skel.get_bone_count():
		out.append(skel.get_bone_pose_rotation(b))
		out.append(skel.get_bone_pose_position(b))
	return out

func _same(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if a[i] is Quaternion and not (a[i] as Quaternion).is_equal_approx(b[i]):
			return false
		if a[i] is Vector3 and not (a[i] as Vector3).is_equal_approx(b[i]):
			return false
	return true

func _run() -> void:
	# --- the booth's clip (c:0x9dd16a): played at once, from t = 0, speed 1 ---
	var archive = F.archive()
	var booth := ObjectLoader.load_object(archive, "res\\sway.bsr")
	_check(booth != null, "the synthetic animated booth loads")
	if booth != null:
		root.add_child(booth)
		_check(StallWorld.start_booth(booth) == 1, "a booth with a default type-0 clip plays it")
		var player := booth.get_node_or_null(MapAnimation.PLAYER_NODE) as AnimationPlayer
		var skel := booth.get_node_or_null(MapAnimation.SKELETON_NODE) as Skeleton3D
		_check(player != null and player.is_playing() and player.active and is_equal_approx(player.speed_scale, 1.0),
			"its player runs, active, at speed 1.0")
		if player != null and skel != null:
			_check(is_zero_approx(player.current_animation_position), "it starts at t = 0 (no random phase)")
			player.advance(0.0)
			var at0 := _pose(skel)
			player.advance(0.4)
			_check(not _same(at0, _pose(skel)), "its bones move as the clock runs")
		booth.queue_free()
	var still := ObjectLoader.load_object(archive, "res\\still.bsr")
	if still != null:
		_check(StallWorld.start_booth(still) == 0, "a booth with no skeleton stands still")
		still.free()

	# --- the title over the name (c:0x9d0d4d..0x9d0d78 after c:0x9df0cd) ---
	_check(is_equal_approx(StallWorld.TITLE_RAISE_PX, 37.0), "the title stands 20 + 14/2 + 10 = 37 px over the name's point")
	var world_script := load("res://scripts/World3D.gd") as GDScript
	_check(StallWorld.TITLE_RAISE_PX > float(world_script.get_script_constant_map().get("GUILD_LINE_RAISE_PX", 0.0)),
		"the title is above the guild line, not on it")

	# --- 0x3405 (c:0x86e5b0) ---
	var v := (26 & 0x3f) | (11 << 6) | (3 << 10) | (14 << 15) | (25 << 20) | (9 << 26)
	var data := PackedByteArray([0, 0, 0, 0, 0])
	data.encode_u32(1, v)
	var d := PunishNet.decode(data)
	_check(d.get("kind") == 0 and d.get("year") == 2026 and d.get("month") == 11 and d.get("day") == 3
		and d.get("hour") == 14 and d.get("minute") == 25, "0x3405 decodes the packed end")
	var texts := {
		"UIIT_MSG_GM_PUNISHMENT_CHAT_BLOCK": "Chat restricted by GM. Can chat from %dyear %dmonth %ddate %s %dhour %dminute(s).",
		"UIIT_STT_LETTER_FORENOON": "Forenoon", "UIIT_STT_LETTER_AFTEMOON": "Afternoon",
	}
	var resolve := func(k: String) -> String: return String(texts.get(k, ""))
	_check(PunishNet.text(d, resolve) == "Chat restricted by GM. Can chat from 2026year 11month 3date Afternoon 2hour 25minute(s).",
		"the chat ban's line: 12-hour clock, afternoon (got '%s')" % PunishNet.text(d, resolve))
	d["hour"] = 12
	_check(PunishNet.text(d, resolve).contains("Afternoon 12hour"), "12:xx is afternoon 12")
	d["hour"] = 0
	_check(PunishNet.text(d, resolve).contains("Forenoon 0hour"), "00:xx is forenoon 0")
	d["kind"] = 1
	_check(PunishNet.text(d, resolve) == "", "a key the archive lacks (the trade row) shows nothing")
	d["kind"] = 7
	_check(PunishNet.text(d, resolve) == "", "another kind shows nothing")
	_check(PunishNet.decode(PackedByteArray([1, 2])).is_empty(), "a short 0x3405 is dropped")

	# --- the title's word filter (f4, c:0x8c3f10) ---
	var f := NameFilter.load_bytes(_filter_file(), NameFilter.LANGUAGE_ENGLISH)
	_check(f.counts().get("stall_substr") == 1 and f.counts().get("stall_whole") == 1, "f4's two lists are read")
	_check(f.stall_title_ok("My stall") and f.stall_title_ok("cheaper goods") and f.stall_title_ok("[Aria]'s stall!!"),
		"clean titles pass, with no character table")
	_check(not f.stall_title_ok("No SCAMS here") and not f.stall_title_ok("Cheap") and not f.stall_title_ok("all cheap stuff"),
		"an f4 substring anywhere or an f4 whole word as a token is refused")
	_check(f.name_ok("Cheap"), "the name test does not read f4")

	# --- the title box's OK refuses a filtered title (c:0x6bb159) ---
	var c := StallController.new(FakePanels.new())
	var net := FakeNet.new()
	c.net = net
	c.name_filter = f
	c.title_entered("cheap")
	_check(net.sent == ["close"], "a refused first title sends 0x70B2 and no 0x70B1 (got %s)" % [net.sent])
	_check((c.panels as FakePanels).codes == [0x3c38], "and shows 0x3c38")
	_check(not c.active, "and the stall is not waiting")
	net.sent.clear()
	c.title_entered("Aria's goods")
	_check(net.sent.size() == 2 and net.sent[0] == "open Aria's goods", "a clean title opens (got %s)" % [net.sent])
	c.on_restricted(PunishNet.KIND_TRADE)
	_check(not c.active, "a trade ban's 0x3405 frees the controller")

	# --- the real archive ---
	if not FileAccess.file_exists(DATA):
		print("SKIP the real booths and pets (no %s)" % DATA)
		return
	var pk2 := Pk2Reader.open(DATA)
	await process_frame
	for name in ["booth_mob_bigeyeghost", "booth_mob_earthghost", "booth_mob_mangyang", "booth_special_monster_01"]:
		var b := StallBooth.build(pk2, "res\\item\\avatar\\%s.bsr" % name)
		_check(b != null, "%s loads" % name)
		if b == null:
			continue
		root.add_child(b)
		var n := StallWorld.start_booth(b)
		var skel := b.get_node_or_null(MapAnimation.SKELETON_NODE) as Skeleton3D
		var player := b.get_node_or_null(MapAnimation.PLAYER_NODE) as AnimationPlayer
		var moved := false
		if n == 1 and skel != null and player != null:
			player.advance(0.0)
			var a := _pose(skel)
			player.advance(0.8)
			moved = not _same(a, _pose(skel))
		_check(n == 1 and moved, "%s plays its own clip and its bones move" % name)
		b.queue_free()
	for p in [StallBooth.CHINA_DEFAULT, StallBooth.EUROPE_DEFAULT]:
		var b := StallBooth.build(pk2, p)
		if b != null:
			_check(StallWorld.start_booth(b) == 0, "%s has no clip and stands still" % p)
			b.free()
	for pet in [["res\\cos\\p_jinn.bsr", true], ["res\\cos\\p_jinn_02.bsr", true], ["res\\cos\\p_wolf_white_01.bsr", false],
			["res\\cos\\p_fox02.bsr", false]]:
		var e := ObjectLoader.find_file(pk2, String(pet[0]))
		var obj := BsrReader.parse(pk2.read_file(e)) if e != null else null
		var has80 := obj != null and obj.animation_for(StallWorld.VENDOR_ACTION, "default") != ""
		_check(obj != null and has80 == bool(pet[1]), "%s %s a type-80 clip" % [pet[0], "has" if pet[1] else "has no"])

## A small AbuseFilter.txt (never the real one): group 4 lets a..z through,
## "scam" is an f4 substring, "cheap" an f4 whole word, "gm" an f1 word.
func _filter_file() -> PackedByteArray:
	var lines := []
	var pad := "\t".repeat(24)
	lines.append(pad + "#ALLOW_ID_TABLE\t0x0061\t0x007A")
	lines.append(pad + "scam\t0\t0\t0\t2\t")
	lines.append(pad + "cheap\t0\t0\t0\t1\t")
	lines.append(pad + "gm\t2\t0\t0\t0\t")
	var text := "\r\n".join(lines) + "\r\n"
	var out := PackedByteArray([0xff, 0xfe])
	out.append_array(text.to_utf16_buffer())
	return out

class FakeNet extends RefCounted:
	var sent: Array = []
	var own_character_id := 1
	var current_character_name := "Aria"
	func stall_open(t: String) -> void: sent.append("open " + t)
	func stall_close() -> void: sent.append("close")
	func stall_update(body: PackedByteArray) -> void: sent.append("update %d" % body[0])

class FakePanels extends RefCounted:
	var _windows := {}
	var codes: Array = []
	func stall_code_message(code: int) -> void: codes.append(code)
	func _resolve_ui(_k: String, fallback: String) -> String: return fallback
