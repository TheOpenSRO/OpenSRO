extends SceneTree

## Round 788: logging in to a `type: legacy` server, the whole path.
##   - Every scenario of testdata/retail_login_transcripts.json (written by
##     server/internal/retailgw's TestLoginTranscripts: the Go client RunLogin
##     against the fake gateway + agent) replayed here against RetailLogin
##     over real sockets: the client's bytes must equal the Go client's, BYTE
##     FOR BYTE, on the gateway connection (handshake, 0x6100, 0x6101, 0x6102,
##     0x6323) and on the agent's (handshake, 0x6103, 0x7007 [2]); the
##     player-facing steps must be the Go run's; the character list decodes
##     (LobbyNet) to the lobby golden's two characters.
##   - The image: the transcript's 0x2322 blob (the writer's layout, a zlib
##     stream of a 1-bit picture) decodes to 200 x 64 with the pattern the Go
##     side drew, pixel by pixel (RetailCaptcha); RetailCaptcha.encode
##     round-trips; a short or wrong blob is refused.
##   - The pieces: the shard is picked by name, or the only one; 0x6103's
##     layout with the ID lower-cased; the keep-alive frame; a refused
##     0xA102 leaves the connection open for a retry.
##   - NetClient's adapter (round 788): a legacy agent link attached, the
##     lobby's list request goes out in the original framing and the 0xB007
##     comes back as character_list_result; anything but the lobby is not
##     sent; the link closing emits `disconnected`.
##
## NEGATIVE: before round 788 RetailLogin, RetailCaptcha and the
## transcripts do not exist and this suite does not parse.

const TRANSCRIPTS := "res://scripts/frontend/testdata/retail_login_transcripts.json"
const GwTest = preload("res://scripts/frontend/retail_gateway_test.gd")

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
	_image()
	_pieces()
	var names: Array = _data["scenarios"].keys()
	names.sort()
	for name in names:
		await _scenario(name)
	_check(names.size() == 7, "every login scenario is played (%d)" % names.size())
	await _adapter()
	await _keep_alive()
	_finish()

## READ (0x4cf990): an idle link sends an empty plain 0x2002 once nothing has
## gone out for 5 s, looked at every 1.666 s -- so the first lands 5.0-6.7 s
## after the last send, and no other frame.
func _keep_alive() -> void:
	var server := _listen()
	var link := RetailLink.new("127.0.0.1", server.get_local_port(), func() -> RetailGatewayClient:
		var c := RetailGatewayClient.new(22, 1000, 1)
		c.sec = RetailSecurity.new()
		c.state = RetailGatewayClient.St.LOBBY
		return c)
	link.start()
	var peer: StreamPeerTCP = null
	var got := PackedByteArray()
	var first_ms := -1
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 7500:
		if peer == null and server.is_connection_available():
			peer = server.take_connection()
		link.poll()
		if peer != null:
			peer.poll()
			var n := peer.get_available_bytes()
			if n > 0:
				got.append_array(peer.get_partial_data(n)[1])
				if first_ms < 0:
					first_ms = Time.get_ticks_msec() - t0
		await process_frame
	_check(got.hex_encode() == "000002200000", "one keep-alive in 7.5 s idle, an empty plain 0x2002: %s" % got.hex_encode())
	_check(first_ms >= 5000 and first_ms <= 6800, "it went out %d ms after the connect (5000-6700, READ)" % first_ms)
	link.close()
	server.stop()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit()

# --- The image -----------------------------------------------------------------

static func _on(x: int, y: int) -> bool:
	return (x + 2 * y) % 16 < 3 or x == y

func _image() -> void:
	var blob := GwTest.Replay.unhex(_data["image"])
	var r := RetailCaptcha.decode(blob)
	_check(not r.has("error") and r["width"] == 200 and r["height"] == 64, "the transcript's image is 200 x 64: %s" % [r.get("error", "")])
	if r.has("error"):
		return
	var img: Image = r["image"]
	var bad := 0
	for y in range(64):
		for x in range(200):
			var want := Color.WHITE if _on(x, y) else Color.BLACK
			if img.get_pixel(x, y) != want:
				bad += 1
	_check(bad == 0, "every pixel is the Go side's pattern, set bits white (%d wrong)" % bad)
	var px := PackedByteArray()
	px.resize(16 * 8)
	px[0] = 1
	px[17] = 1
	px[127] = 1
	var back := RetailCaptcha.decode(RetailCaptcha.encode(16, 8, px))
	_check(not back.has("error") and back["image"].get_pixel(0, 0) == Color.WHITE and back["image"].get_pixel(1, 1) == Color.WHITE
		and back["image"].get_pixel(15, 7) == Color.WHITE and back["image"].get_pixel(1, 0) == Color.BLACK, "encode and decode round-trip")
	_check(RetailCaptcha.decode(blob.slice(0, 7)).has("error"), "a blob under its header is refused")
	_check(RetailCaptcha.decode(blob.slice(0, blob.size() - 4)).has("error"), "a cut zlib stream is refused")
	var odd := blob.duplicate()
	odd.encode_u16(4, 201)
	_check(RetailCaptcha.decode(odd).has("error"), "a width that is not a multiple of 8 is refused")

# --- The pieces ----------------------------------------------------------------

func _pieces() -> void:
	var list := [{"id": 64, "name": "A"}, {"id": 65, "name": "B"}]
	_check(RetailGatewayClient.pick_shard(list, "B") == 65 and RetailGatewayClient.pick_shard(list, "C") == -1, "a shard by its name, none for an unknown one")
	_check(RetailGatewayClient.pick_shard([{"id": 9, "name": "X"}], "C") == 9, "the only shard when none matches (OURS)")
	var p := RetailGatewayClient.encode_agent_login(1, "TeStEr", "pw", 22, PackedByteArray([1, 2, 3, 4, 5, 6]))
	_check(p.hex_encode() == "01000000" + "0600746573746572" + "02007077" + "16" + "010203040506", "0x6103: token, ID lower-cased, password, content id, 6 bytes (the Go codec's bytes)")
	var c := RetailGatewayClient.new(22, 1000, 1)
	_check(c.keep_alive().is_empty(), "no keep-alive before the session is secured")
	c.sec = RetailSecurity.new()
	c.state = RetailGatewayClient.St.LOBBY
	var ka := c.keep_alive()
	_check(ka.hex_encode() == "000002200000", "the keep-alive: an empty plain 0x2002")
	_check(c.send_lobby(LobbyNet.OP_LOBBY, LobbyNet.encode_list()).size() > 0, "a lobby request in the lobby")
	c.state = RetailGatewayClient.St.LOGIN
	_check(c.send_lobby(LobbyNet.OP_LOBBY, LobbyNet.encode_list()).is_empty(), "no lobby request before 0xA103")
	_check(c.submit_captcha("1").is_empty() and c.resubmit("a", "b").is_empty(), "no answer without an image, no retry without a refusal")

# --- The replayed login --------------------------------------------------------

func _listen() -> TCPServer:
	var s := TCPServer.new()
	for p in range(48700, 49100):
		if s.listen(p, "127.0.0.1") == OK:
			return s
	return null

## Go's event kinds as the title sees them: 0xA102's success is RetailLogin's
## own business, 0xA103's is "logged_in", the list arrives on the link.
static func _title_kinds(go: Array) -> Array:
	var out: Array = []
	for k in go:
		match str(k):
			"login_ok", "frame":
				pass
			"agent_ok":
				out.append("logged_in")
			_:
				out.append(str(k))
	return out

## One step of RetailLogin in a replayed scenario.
func _on_step(ev: Dictionary, rl: RetailLogin, st: Dictionary, answers: Array, name: String) -> void:
	var k := str(ev["kind"])
	st["kinds"].append(k)
	match k:
		"captcha":
			_check(RetailCaptcha.decode(ev["blob"]).get("width", 0) == 200, "%s: the image decodes" % name)
			var code: String = answers[st["answers"]] if st["answers"] < answers.size() else ""
			st["answers"] += 1
			rl.submit_captcha(code)
		"login_failed":
			st["retry"] = rl.can_resubmit()
			st["done"] = true
		"agent_failed", "closed", "connect_failed", "agent_connect_failed":
			st["done"] = true
		"logged_in":
			# READ: character select asks for the list (0x7007 [2]).
			var link: RetailLink = ev["link"]
			st["link"] = link
			link.send(link.conv.send_lobby(LobbyNet.OP_LOBBY, LobbyNet.encode_list()))

func _scenario(name: String) -> void:
	var sc: Dictionary = _data["scenarios"][name]
	var server := _listen()
	var replay = GwTest.Replay.new(server, sc["connections"])
	var entry := ClientConfig.ServerEntry.new()
	entry.name = name
	entry.type = ServerStatus.TYPE_LEGACY
	entry.gateway_host = "127.0.0.1"
	entry.gateway_port = server.get_local_port()
	# The config's `agent:` entry stands in for the address 0xA102 names
	# (OURS, ClientConfig): the Go run dialled the fake again too.
	entry.agent_host = "127.0.0.1"
	entry.agent_port = server.get_local_port()
	var rl := RetailLogin.new()
	rl.private_x = int(_data["private_x"])
	rl.keep_alive = false
	root.add_child(rl)
	var st := {"kinds": [], "answers": 0, "done": false, "link": null, "lobby": null, "retry": false}
	var answers: Array = sc.get("answers", [])
	rl.step.connect(_on_step.bind(rl, st, answers, name))
	var login: Dictionary = sc["login"]
	rl.start(entry, {"content_id": int(_data["content_id"]), "version": int(_data["version"])},
		str(login["Username"]), str(login["Password"]), str(login["Shard"]))
	var want := _title_kinds(sc["events"])
	# Where the fake hung up after a refusal (READ: the gateway closes after
	# every GlobalManager refusal), the title hears it too -- the Go client
	# had stopped reading by then.
	var gw_events: Array = sc["connections"][0]
	if not gw_events.is_empty() and (gw_events[-1] as Dictionary).has("close") and want.size() > 0 and want[-1] == "login_failed":
		want.append("closed")
	var started := Time.get_ticks_msec()
	while not (st["done"] and st["kinds"].size() >= want.size()) and Time.get_ticks_msec() - started < 8000:
		replay.step()
		var link: RetailLink = st["link"]
		if link != null:
			for ev in link.poll():
				if str(ev["kind"]) == "frame" and int(ev["opcode"]) == LobbyNet.OP_LOBBY_RESULT:
					st["lobby"] = LobbyNet.decode_result(ev["data"])
					st["done"] = true
		await process_frame
	for _i in range(5):
		replay.step()
		await process_frame
	rl.cancel()
	if st["link"] != null:
		(st["link"] as RetailLink).close()
	replay.close()
	replay.finish_check()
	_check(replay.problems.is_empty(), "%s: the client's bytes are the Go client's%s" % [name, "" if replay.problems.is_empty() else ": " + "; ".join(replay.problems)])
	_check(str(st["kinds"]) == str(want), "%s: the steps %s (the Go run's %s)" % [name, st["kinds"], want])
	if (sc["events"] as Array).has("frame"):
		var res: LobbyNet.Result = st["lobby"]
		_check(res != null and res.error == "" and res.ok and res.characters.size() == 2 and res.characters[0].char_name == "Aria",
			"%s: the character list arrives on the agent and decodes" % name)
	if name == "wrong_password":
		_check(st["retry"], "%s: below the tolerance the connection stays open for a retry" % name)
	rl.queue_free()
	await process_frame

# --- NetClient's adapter --------------------------------------------------------

## A link in the lobby over a local socket pair: NetClient sends the list
## request through it and dispatches the 0xB007 it gets back.
func _adapter() -> void:
	var nc: Node = root.get_node_or_null("NetClient")
	_check(nc != null, "the NetClient autoload is there")
	if nc == null:
		return
	var server := _listen()
	var link := RetailLink.new("127.0.0.1", server.get_local_port(), func() -> RetailGatewayClient:
		var c := RetailGatewayClient.new(22, 1000, 1)
		c.sec = RetailSecurity.new() # plain frames, no security bytes
		c.state = RetailGatewayClient.St.LOBBY
		return c)
	link.keep_alive = false
	link.start()
	var peer: StreamPeerTCP = null
	var t0 := Time.get_ticks_msec()
	while (peer == null or not link.is_connected_now()) and Time.get_ticks_msec() - t0 < 3000:
		if peer == null and server.is_connection_available():
			peer = server.take_connection()
		link.poll()
		await process_frame
	_check(peer != null and link.is_connected_now(), "the link connects")
	if peer == null:
		return
	nc.attach_retail(link)
	_check(nc.is_retail() and nc.is_connected_to_server(), "attached: NetClient is connected, on a legacy agent")
	var got := {"list": null, "disc": false}
	var on_list := func(chars: Array, err: String) -> void: got["list"] = [chars.size(), err]
	var on_disc := func() -> void: got["disc"] = true
	nc.character_list_result.connect(on_list)
	nc.disconnected.connect(on_disc)
	nc.list_characters()
	nc.enter_world("Aria") # not the lobby: never sent
	var sent := PackedByteArray()
	t0 = Time.get_ticks_msec()
	while sent.size() < 7 and Time.get_ticks_msec() - t0 < 2000:
		peer.poll()
		var n := peer.get_available_bytes()
		if n > 0:
			sent.append_array(peer.get_partial_data(n)[1])
		await process_frame
	await process_frame
	peer.poll()
	if peer.get_available_bytes() > 0:
		sent.append_array(peer.get_partial_data(peer.get_available_bytes())[1])
	_check(sent.hex_encode() == "01000770000002", "only 0x7007 [2] went out, in the original framing: %s" % sent.hex_encode())
	# The server's 0xB007: the lobby golden's empty list, plain.
	peer.put_data(PackedByteArray([3, 0, 0x07, 0xB0, 0, 0, 2, 1, 0]))
	t0 = Time.get_ticks_msec()
	while got["list"] == null and Time.get_ticks_msec() - t0 < 2000:
		await process_frame
	_check(got["list"] != null and got["list"][0] == 0 and got["list"][1] == "", "0xB007 came back as character_list_result: %s" % [got["list"]])
	peer.disconnect_from_host()
	t0 = Time.get_ticks_msec()
	while not got["disc"] and Time.get_ticks_msec() - t0 < 2000:
		await process_frame
	_check(got["disc"] and not nc.is_retail() and not nc.is_connected_to_server(), "the agent hanging up is NetClient's `disconnected`")
	nc.character_list_result.disconnect(on_list)
	nc.disconnected.disconnect(on_disc)
	server.stop()
