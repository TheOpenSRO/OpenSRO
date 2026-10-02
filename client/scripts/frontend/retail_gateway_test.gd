extends SceneTree

## Round 681: the server list's status from a server speaking the ORIGINAL
## gateway protocol (`type: legacy`).
##   - The primitives -- count seeds and bytes, the checksum tables, the key
##     mixing, modpow, Blowfish with little-endian halves -- against the Go
##     implementation's known answers (testdata/retail_gateway_transcripts.json,
##     written by server/internal/retailgw's TestClientTranscripts).
##   - Every scenario of that file replayed by a fake gateway here: the server
##     frames the Go fake sent, and the client's frames compared BYTE FOR BYTE
##     with the Go client's (the same private value): each band including
##     Check, several shards, one shard, no farm byte, a plain 0xA100, an
##     encrypted 0xA101, no key exchange, a checksum table that cannot be
##     built (the client hangs up before sending anything and reconnects),
##     a refusal, a wrong version, a server that sends its 0x5000 and stalls,
##     a wrong challenge, a non-zero check byte, a truncated list, a malformed
##     list, a frame cut in half, an oversized frame, a server that is not a
##     gateway, a flood of small frames (the frame cap) and of large ones (the
##     byte cap) -- each a row that reads "Closed" with a log line, never a
##     crash.
##   - The window: a legacy server's shards as rows with retail's words.
##   - The types: srrevamp asks 0x0007 at once and never waits for a 0x5000;
##     legacy never sends 0x0007 (against a server that speaks first: ours
##     does not, so it shows Closed).
##   - SV.T: a synthetic file decrypted and atoi'd as the client does.
##
## NEGATIVE: before round 681 RetailSecurity, RetailGatewayClient and
## ServerStatus.start_for do not exist -- this suite does not parse.

const TRANSCRIPTS := "res://scripts/frontend/testdata/retail_gateway_transcripts.json"

## What each scenario must end in here (the Go test's own words differ).
const EXPECT := {
	"bands": "",
	"single_shard": "",
	"no_farm_byte": "",
	"plain_patch_reply": "",
	"encrypted_list": "",
	"no_key_exchange": "",
	"unknown_crc_index_reconnects": "",
	"crc_seed_zero_is_index_1": "",
	"refused": "not in service",
	"wrong_version": "result 2, code 2",
	"stall_after_hello": "no answer within",
	"bad_signature": "challenge does not match",
	"check_byte": "check byte 0x5a",
	"truncated_list": "0xA101",
	"malformed_list": "is 7, not 0 or 1",
	"truncated_frame": "closed without an answer",
	"oversize_frame": "over 4096 bytes",
	"not_gateway": "AgentServer",
	"flood": "more than 64 frames",
	"flood_bytes": "more than 65536 bytes",
}

var _failures := 0
var _data := {}

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	await process_frame
	var f := FileAccess.open(TRANSCRIPTS, FileAccess.READ)
	_check(f != null, "the transcripts file is there")
	if f == null:
		_finish()
		return
	_data = JSON.parse_string(f.get_as_text())
	f.close()
	_vectors()
	_payloads()
	_sv_t()
	for name in EXPECT:
		await _scenario(name)
	_check(_data["scenarios"].size() == EXPECT.size(), "every transcript scenario is played (%d)" % _data["scenarios"].size())
	await _window()
	await _srrevamp_asks_at_once()
	await _legacy_never_asks_0007()
	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit()

static func _hex(b: PackedByteArray) -> String:
	return b.hex_encode()

static func _unhex(h: String) -> PackedByteArray:
	var out := PackedByteArray()
	for i in range(0, h.length(), 2):
		out.append(("0x" + h.substr(i, 2)).hex_to_int())
	return out

# --- Known answers --------------------------------------------------------------

func _vectors() -> void:
	var v: Dictionary = _data["vectors"]
	_check(_hex(RetailSecurity.count_seeds(0x12345678)) == v["count_seeds_12345678"], "count seeds of 0x12345678: %s" % _hex(RetailSecurity.count_seeds(0x12345678)))
	_check(_hex(RetailSecurity.count_seeds(0)) == v["count_seeds_0"], "a count seed of 0 is 0x9abfb3b6's")
	var st := RetailSecurity.count_seeds(0x12345678)
	var rolls := PackedByteArray()
	for _i in range(6):
		rolls.append(RetailSecurity.next_count(st))
	_check(_hex(rolls) == v["count_bytes_12345678"], "six count bytes: %s" % _hex(rolls))
	var frame := PackedByteArray([0x00, 0x00, 0x01, 0x61, 0x00, 0x00])
	var checks := []
	for idx in [1, 7, 100, 239]:
		checks.append(RetailSecurity.check_byte(RetailSecurity.crc_table_for(idx), frame))
	_check(str(checks) == str(v["check_6101_idx_1_7_100_239"].map(func(x): return int(x))), "check bytes of a 0x6101 at tables 1, 7, 100, 239: %s" % [checks])
	_check(_hex(RetailSecurity.key_transform(PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8]), 0xdeadbeef, 5)) == v["transform_0102030405060708_deadbeef_5"], "the key mixing")
	_check(RetailSecurity.modpow(2147483629, 0x07654321, 2147483647) == int(v["modpow_2147483629_7654321_2147483647"]), "modpow near 2^31 (no 64-bit overflow)")
	var bf := Blowfish.new(PackedByteArray([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]))
	_check(_hex(bf.encrypt_le(PackedByteArray([0, 1, 2, 3, 4, 5, 6, 7]))) == v["blowfish_le_1122334455667788_0001020304050607"], "Blowfish with little-endian halves")
	_check(bf.decrypt_le(bf.encrypt_le(PackedByteArray([9, 8, 7, 6, 5, 4, 3, 2]))) == PackedByteArray([9, 8, 7, 6, 5, 4, 3, 2]), "and back")
	_check(str(RetailSecurity.UNKNOWN_CRC_INDICES) == str(v["unknown_crc_indices"].map(func(x): return int(x))), "the same 37 unknown tables as the Go side")
	_check(RetailSecurity.crc_index(0x100) == 1 and not RetailSecurity.crc_index_known(18) and RetailSecurity.crc_index_known(7), "seed low byte 0 -> table 1; 18 unknown, 7 known")
	# The standard CRC-32 itself falls out of table 1's builder fed 0xedb88320's table: entry 1 of it is 0x77073096 (public).
	_check(RetailSecurity._reflected_table(0xEDB88320)[1] == 0x77073096, "the public CRC-32 table's entry 1")

func _payloads() -> void:
	var l := RetailGatewayClient.decode_shard_list(PackedByteArray([1, 1, 1, 0, 0x46, 0, 1, 3, 0, 2, 0, 0x41, 0x62, 5, 0, 100, 0, 1, 1, 0]), true)
	_check(not l.has("error") and l["shards"].size() == 1 and l["shards"][0]["name"] == "Ab" and l["shards"][0]["capacity"] == 100 and l["farms"][0]["name"] == "F",
		"a one-shard list read field by field: %s" % [l])
	_check(RetailGatewayClient.decode_shard_list(PackedByteArray([1, 1, 1, 0, 0x46, 0, 1, 3, 0, 2, 0, 0x41, 0x62, 5, 0, 100, 0, 1, 1, 0]), false).has("error"), "the wrong layout is refused")
	_check(not RetailGatewayClient.decode_shard_list_for(PackedByteArray([0, 1, 3, 0, 0, 0, 5, 0, 100, 0, 1, 0]), 22).has("error"), "a list without farm bytes for content id 22 falls back")
	_check(RetailGatewayClient.decode_shard_list(PackedByteArray([0, 1, 3, 0, 0xff, 0xff]), false).has("error"), "a name longer than the payload")
	_check(RetailGatewayClient.decode_name(PackedByteArray([0x41, 0x09, 0x42])) == "AB", "control characters dropped from a name")
	_check(RetailGatewayClient.decode_name(PackedByteArray([0x43, 0xe9])) == "Cé", "a non-UTF-8 byte read as Latin-1")
	_check(RetailGatewayClient.decode_hello(PackedByteArray([0x0e, 1])).has("error"), "a short 0x5000")
	_check(RetailGatewayClient.decode_hello(PackedByteArray([0x00, 9])).has("error"), "a 0x5000 with a byte past its fields")
	_check(RetailSecurity.frame_len(PackedByteArray([0xff, 0x7f])) == -1, "a 32 KiB frame is refused")
	_check(RetailSecurity.frame_len(PackedByteArray([0x02, 0x80, 0, 0])) == 0 and RetailSecurity.frame_len(PackedByteArray([0x02, 0x80]) + PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0])) == 10,
		"an encrypted 2-byte payload is 2 + 8 bytes on the wire")
	var plain := RetailSecurity.new()
	_check(plain.decode(PackedByteArray([0x00, 0x80, 1, 2, 3, 4, 5, 6, 7, 8])).has("error"), "an encrypted frame before Blowfish (the client's 0x8011)")

func _sv_t() -> void:
	var bf := Blowfish.new("SILKROAD".to_ascii_buffer())
	var text := "188".to_ascii_buffer()
	text.resize(8)
	var file := PackedByteArray()
	file.resize(4)
	file.encode_u32(0, 3)
	file.append_array(bf.encrypt_le(text))
	var v := RetailClientInfo.parse_sv_t(file)
	_check(v.get("version", -1) == 188, "a synthetic SV.T (length 3, '188' under key SILKROAD) reads 188: %s" % [v])
	file.encode_u32(0, 9)
	_check(RetailClientInfo.parse_sv_t(file).has("error"), "a length past the file is refused")
	_check(RetailClientInfo.atoi(" 42x".to_ascii_buffer()) == 42 and RetailClientInfo.atoi("x".to_ascii_buffer()) == -1, "atoi: spaces, digits, stop at the rest")
	_check(RetailClientInfo.from_media(null).has("error"), "no Media.pk2: no guess")

# --- The replayed gateway -----------------------------------------------------

## Plays one scenario's connections against whatever connects to `server`,
## comparing the client's bytes; returns once `done` says so or the time is
## up. Fills `log` with mismatches.
class Replay:
	var server: TCPServer
	var conns: Array
	var k := -1
	var peer: StreamPeerTCP = null
	var ev := 0
	var got := PackedByteArray()
	var pending := PackedByteArray()
	var problems: PackedStringArray = []
	var connections := 0

	func _init(p_server: TCPServer, p_conns: Array) -> void:
		server = p_server
		conns = p_conns

	func step() -> void:
		if peer == null:
			if server.is_connection_available():
				peer = server.take_connection()
				k += 1
				connections += 1
				ev = 0
				got = PackedByteArray()
				pending = PackedByteArray()
			else:
				return
		peer.poll()
		var n := peer.get_available_bytes()
		if n > 0:
			var r := peer.get_partial_data(n)
			if r[0] == OK:
				got.append_array(r[1])
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			# The client hung up: what it sent before still counts.
			_match_client()
			peer = null
			return
		if not pending.is_empty():
			var w := peer.put_partial_data(pending)
			if w[0] == OK:
				pending = pending.slice(int(w[1]))
			return
		var events: Array = conns[k] if k < conns.size() else []
		while ev < events.size():
			var e: Dictionary = events[ev]
			if e.has("close"):
				# The Go fake hung up here itself.
				peer.disconnect_from_host()
				peer = null
				ev += 1
				return
			if e.has("s"):
				var b := unhex(e["s"])
				for _i in range(maxi(int(e.get("repeat", 1)), 1)):
					pending.append_array(b)
				ev += 1
				return
			if not _match_client():
				return
		if not got.is_empty():
			problems.append("connection %d: %d bytes from the client past the transcript: %s" % [k, got.size(), got.slice(0, 32).hex_encode()])
			got = PackedByteArray()

	## Matches the client event due, if its bytes are in; false to wait.
	func _match_client() -> bool:
		var events: Array = conns[k] if k < conns.size() else []
		if ev >= events.size() or not (events[ev] as Dictionary).has("c"):
			return false
		var want := unhex(events[ev]["c"])
		if got.size() < want.size():
			return false
		if got.slice(0, want.size()) != want:
			problems.append("connection %d event %d: the client sent %s, the Go client %s" % [k, ev, got.slice(0, want.size()).hex_encode(), want.hex_encode()])
		got = got.slice(want.size())
		ev += 1
		_match_client()
		return true

	## Events of the transcript that never happened are problems too (the
	## fake's own hang-up excepted: the client may hang up first).
	func finish_check() -> void:
		for c in range(maxi(k, 0), conns.size()):
			var events: Array = conns[c]
			var from := ev if c == k else 0
			var left := 0
			for i in range(from, events.size()):
				if not (events[i] as Dictionary).has("close"):
					left += 1
			if c > k or left > 0:
				problems.append("connection %d: %d transcript event(s) never happened (at %d)" % [c, left, from])

	func close() -> void:
		if peer != null:
			peer.disconnect_from_host()
		server.stop()

	static func unhex(h: String) -> PackedByteArray:
		var out := PackedByteArray()
		for i in range(0, h.length(), 2):
			out.append(("0x" + h.substr(i, 2)).hex_to_int())
		return out

func _listen() -> TCPServer:
	var s := TCPServer.new()
	for p in range(48300, 48700):
		if s.listen(p, "127.0.0.1") == OK:
			return s
	return null

func _scenario(name: String) -> void:
	var sc: Dictionary = _data["scenarios"].get(name, {})
	_check(not sc.is_empty(), "%s: in the transcripts" % name)
	if sc.is_empty():
		return
	var server := _listen()
	var replay := Replay.new(server, sc["connections"])
	var q := ServerStatus.new()
	root.add_child(q)
	var entry := ClientConfig.ServerEntry.new()
	entry.name = name
	entry.type = ServerStatus.TYPE_LEGACY
	entry.gateway_host = "127.0.0.1"
	entry.gateway_port = server.get_local_port()
	q.private_x = int(_data["private_x"])
	var result := {"why": "", "done": false}
	q.finished.connect(func(_s, why: String) -> void:
		result["why"] = why
		result["done"] = true)
	q.start_for(entry, {"content_id": int(_data["content_id"]), "version": int(_data["version"])})
	if int(sc.get("timeout_ms", 0)) > 0:
		q.timeout_ms = int(sc["timeout_ms"])
	var started := Time.get_ticks_msec()
	while not result["done"] and Time.get_ticks_msec() - started < 8000:
		replay.step()
		await process_frame
	# The client's last frames, and its hang-up, are read too.
	for _i in range(5):
		replay.step()
		await process_frame
	replay.close()
	replay.finish_check()
	_check(replay.problems.is_empty(), "%s: the client's bytes are the Go client's%s" % [name, "" if replay.problems.is_empty() else ": " + "; ".join(replay.problems)])
	var want_err: String = EXPECT[name]
	var conns: int = sc["connections"].size()
	_check(replay.connections == conns, "%s: %d connection(s), want %d" % [name, replay.connections, conns])
	if want_err == "":
		var want: Array = sc["shards"]
		var got_names := q.shards.map(func(s): return s["name"])
		var ok := q.answered_ok and q.shards.size() == want.size()
		for i in range(mini(q.shards.size(), want.size())):
			var a: Dictionary = q.shards[i]
			var b: Dictionary = want[i]
			ok = ok and a["id"] == int(b["ID"]) and a["name"] == b["Name"] and a["current"] == int(b["Current"]) \
				and a["capacity"] == int(b["Capacity"]) and a["state"] == int(b["State"]) and a["farm"] == int(b["Farm"])
		_check(ok, "%s: the shards %s (%s)" % [name, got_names, result["why"]])
	else:
		_check(result["done"] and not q.answered_ok and q.band_with(Vector2i(35, 97)) == ServerStatus.Band.UNREACHABLE,
			"%s: no answer, the row reads Closed" % name)
		_check(str(result["why"]).contains(want_err), "%s: the log line says why: '%s' (want '%s')" % [name, result["why"], want_err])
	q.queue_free()
	await process_frame

# --- The window ---------------------------------------------------------------

func _window() -> void:
	var sc: Dictionary = _data["scenarios"]["bands"]
	var server := _listen()
	var replay := Replay.new(server, sc["connections"])
	var w := PackedStringArray()
	var cfg := ClientConfig.from_text("servers:\n  Legacy:\n    type: legacy\n    gateway: { address: 127.0.0.1, port: %d }\n" % server.get_local_port(), "t", w)
	_check(w.is_empty() and cfg.servers.size() == 1 and cfg.servers[0].type == "legacy", "a legacy entry loads: %s" % [w])
	var list := ServerListWindow.new()
	list.legacy_info = {"content_id": int(_data["content_id"]), "version": int(_data["version"])}
	list.legacy_private_x = int(_data["private_x"])
	root.add_child(list)
	list.open(null, null, null, cfg.servers, cfg.servers[0])
	_check(list.row_count() == 1 and list.row_text(0)[0] == "Legacy" and list.row_text(0)[1] == "", "before the answer: one row, the config name, no status")
	var started := Time.get_ticks_msec()
	while list.row_count() < 5 and Time.get_ticks_msec() - started < 6000:
		replay.step()
		await process_frame
	replay.close()
	replay.finish_check()
	_check(replay.problems.is_empty(), "the window's query plays the transcript: %s" % "; ".join(replay.problems))
	var rows := []
	for r in range(list.row_count()):
		var t := list.row_text(r)
		rows.append("%s|%s" % [t[0], t[1]])
	_check(rows == ["Legacy - Check|Check", "Legacy - Easy|Easy", "Legacy - Populated|Populated", "Legacy - Crowded|Crowded", "Legacy - Full|FULL"],
		"each shard a row with retail's word: %s" % [rows])
	_check((list.row_text(0)[2] as Color).is_equal_approx(Color8(0xC0, 0xBD, 0xFF)) and (list.row_text(4)[2] as Color).is_equal_approx(Color8(0xFF, 0x58, 0x58)),
		"in retail's colours")
	var shown := ""
	for n in list.find_children("*", "Label", true, false):
		shown += (n as Label).text + "|"
	_check(shown.contains("Legacy - Populated|Populated|"), "the window's labels show them: %s" % shown.left(120))
	var chose := []
	list.chosen.connect(func(e): chose.append(e))
	list._select_row(3)
	list.select_current()
	_check(chose.size() == 1 and chose[0] == cfg.servers[0], "choosing a shard row chooses its server")
	await process_frame

# --- The two types --------------------------------------------------------------

func _srrevamp_asks_at_once() -> void:
	var server := _listen()
	var q := ServerStatus.new()
	root.add_child(q)
	var entry := ClientConfig.ServerEntry.new()
	entry.name = "Ours"
	entry.type = ServerStatus.TYPE_SRREVAMP
	entry.gateway_host = "127.0.0.1"
	entry.gateway_port = server.get_local_port()
	var result := {"done": false}
	q.finished.connect(func(_s, _why: String) -> void: result["done"] = true)
	q.start_for(entry, {})
	var peer: StreamPeerTCP = null
	var got := PackedByteArray()
	var started := Time.get_ticks_msec()
	while got.size() < 6 and Time.get_ticks_msec() - started < 3000:
		if peer == null and server.is_connection_available():
			peer = server.take_connection()
		if peer != null:
			peer.poll()
			var n := peer.get_available_bytes()
			if n > 0:
				got.append_array(peer.get_partial_data(n)[1])
		await process_frame
	_check(got.size() == 6 and got.decode_u16(2) == ServerStatus.OP_REQUEST, "srrevamp sends 0x0007 at once, without waiting for a 0x5000 (%s after %d ms)" % [got.hex_encode(), Time.get_ticks_msec() - started])
	if peer != null:
		peer.put_data(PackedByteArray([6, 0, 0x08, 0x00, 0, 0, 1, 50, 0, 100, 0, 1]))
	started = Time.get_ticks_msec()
	while not result["done"] and Time.get_ticks_msec() - started < 3000:
		await process_frame
	_check(q.answered_ok and q.band_with(Vector2i(35, 97)) == ServerStatus.Band.POPULATED, "and our server's 0x0008 is its status (50/100 Populated)")
	server.stop()
	q.queue_free()
	await process_frame

func _legacy_never_asks_0007() -> void:
	var server := _listen()
	var q := ServerStatus.new()
	root.add_child(q)
	var entry := ClientConfig.ServerEntry.new()
	entry.name = "OursAsLegacy"
	entry.type = ServerStatus.TYPE_LEGACY
	entry.gateway_host = "127.0.0.1"
	entry.gateway_port = server.get_local_port()
	var result := {"done": false, "why": ""}
	q.finished.connect(func(_s, why: String) -> void:
		result["done"] = true
		result["why"] = why)
	q.start_for(entry, {"content_id": 22, "version": 188})
	q.timeout_ms = 800
	var peer: StreamPeerTCP = null
	var got := PackedByteArray()
	var started := Time.get_ticks_msec()
	while not result["done"] and Time.get_ticks_msec() - started < 3000:
		if peer == null and server.is_connection_available():
			peer = server.take_connection()
		if peer != null:
			peer.poll()
			var n := peer.get_available_bytes()
			if n > 0:
				got.append_array(peer.get_partial_data(n)[1])
		await process_frame
	_check(peer != null and got.is_empty(), "legacy connects and sends nothing first (our server speaks second): %d bytes" % got.size())
	_check(result["done"] and not q.answered_ok and str(result["why"]).contains("no answer within"), "it gives up within its time and shows Closed: %s" % result["why"])
	server.stop()
	q.queue_free()
	# Without the archive's content id and version: Closed at once, the log says why.
	var q2 := ServerStatus.new()
	root.add_child(q2)
	var r2 := {"why": ""}
	q2.finished.connect(func(_s, why: String) -> void: r2["why"] = why)
	q2.start_for(entry, {"error": "no Media.pk2"})
	await process_frame
	await process_frame
	_check(q2.is_done() and q2.band_with(Vector2i(35, 97)) == ServerStatus.Band.UNREACHABLE and str(r2["why"]).contains("no Media.pk2"),
		"a legacy server without the archive's numbers: Closed, '%s'" % r2["why"])
	q2.queue_free()
	await process_frame
