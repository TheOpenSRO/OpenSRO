extends SceneTree

## Round 762 (QA): what a player group spawn's decode costs the client's main
## thread (UserSpawnNet.read_group, NetClient's 0x3018 handling), for 1,000 /
## 3,000 / 4,000 records: user_spawn_test's pinned record (the Go encoder's
## bytes: Aria, two items, sitting, berserk) repeated with a new unique id each.
## Prints `BENCH decode n=<n> bytes=<b> ms=<t> us_per_record=<t/n>`.
##
##   remote_godot.sh script res://tools/group_decode_bench.gd

const SINGLE := "73070000220000006d023b0e000000300e00000705000001000000a86100807a440000604000007f44004000010000400100040100008041000048420000c8420004004172696100000000000000000000000000000000000000000000000000000000000000ff04"

func _initialize() -> void:
	var rows := {}
	for e in [[3643, [3, 1, 1, 3]], [3632, [3, 1, 6, 2]], [10730, [3, 1, 6, 2]], [11000, [3, 1, 7, 2]], [62, [3, 3, 4, 1]]]:
		var it := ItemTableReader.Item.new()
		it.id = e[0]
		it.type_ids = PackedInt32Array(e[1])
		rows[e[0]] = it
	var types := UserSpawnNet.Types.new(rows)
	var rec := SINGLE.hex_decode()
	rec = rec.slice(0, rec.size() - 1)
	# The unique id's offset: the first record field after the items and the
	# avatar list; found as the u32 1 Aria's record carries.
	var uid_at := -1
	for i in range(rec.size() - 4):
		if rec.decode_u32(i) == 1 and i > 20:
			uid_at = i
			break
	for n in [1000, 3000, 4000]:
		var buf := PackedByteArray([1, n & 0xff, (n >> 8) & 0xff])
		for k in range(n):
			var r := rec.duplicate()
			if uid_at >= 0:
				r.encode_u32(uid_at, 1000 + k)
			buf.append_array(r)
		var t0 := Time.get_ticks_usec()
		var g := UserSpawnNet.read_group(buf, types)
		var us := Time.get_ticks_usec() - t0
		print("BENCH decode n=%d bytes=%d ms=%.1f us_per_record=%.1f players=%d error=%s" % [n, buf.size(), us / 1000.0,
			float(us) / n, g.users.size(), g.error])
	quit()
