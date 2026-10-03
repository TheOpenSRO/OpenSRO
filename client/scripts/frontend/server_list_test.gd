extends SceneTree

## Round 679: the server list's status.
##   - The bands, thresholds and colours (READ, FUN_00869cd0), and the text
##     keys' English words.
##   - The server's exact OpServerStatus frame (server/internal/session
##     TestServerStatusEncodeExact).
##   - A server that does not answer shown as "Closed" in the list's grey
##     (OURS) -- on a real connection to a port nobody listens on, through
##     the ServerListWindow the LIST button opens.
##
## NEGATIVE: before round 679 neither ServerStatus nor ServerListWindow
## exists -- this suite does not parse.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	# The root (and the autoloads' _ready) are in the tree after a frame.
	await process_frame
	_bands()
	_wire()
	await _unreachable()
	await _connect_by_name()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit()

# --- The bands -----------------------------------------------------------------

func _bands() -> void:
	var lo := ServerStatus.LO_FALLBACK
	var hi := ServerStatus.HI_FALLBACK
	_check(lo == 35 and hi == 97, "the thresholds without a text table: 35 % and 97 % (MEASURED, the archive's English column)")
	var B := ServerStatus.Band
	for c in [
		[10, 100, 1, B.EASY, "10/100"],
		[34, 100, 1, B.EASY, "34/100"],
		[35, 100, 1, B.POPULATED, "35/100"],
		[50, 100, 1, B.POPULATED, "50/100"],
		[96, 100, 1, B.POPULATED, "96/100"],
		[97, 100, 1, B.CROWDED, "97/100"],
		[99, 100, 1, B.CROWDED, "99/100"],
		[100, 100, 1, B.FULL, "100/100"],
		[150, 100, 1, B.FULL, "150/100"],
		[0, 0, 1, B.CROWDED, "0/0 (retail: NaN takes the jp branches to Crowded)"],
		[5, 0, 1, B.FULL, "5/0 (retail: inf)"],
		[0, 100, 0, B.CHECK, "state 0 at 0/100"],
		[100, 100, 0, B.CHECK, "state 0 at 100/100"],
	]:
		var got := ServerStatus.band_for(c[0], c[1], c[2], lo, hi)
		_check(got == c[3], "%s -> %s (got %s)" % [c[4], B.keys()[c[3]], B.keys()[got]])
	_check(ServerStatus.band_for(50, 100, 1, 35, 65) == B.POPULATED and ServerStatus.band_for(70, 100, 1, 35, 65) == B.CROWDED,
		"the thresholds are parameters (the Korean column's 65)")
	# Through the text table the client really reads, rows shaped as the
	# archive's are (round 679's review: a float32 0.97 from the table put
	# 97/100 in Populated). Numbers only -- the row shape MEASURED with
	# dump_text_table.gd: the Korean value in column 2, the English in 8 and 9.
	var rows := PackedStringArray([
		"1\tUIO_STT_SERVER_35\t35\t0\t0\t0\t0\t0\t35\t35\t0\t0\t0\t0\t0\t0",
		"1\tUIO_STT_SERVER_75\t65\t0\t0\t0\t0\t0\t97\t97\t0\t0\t0\t0\t0\t0",
	])
	var table := UiTextTable.parse("\n".join(rows).to_utf16_buffer())
	var t := ServerStatus.thresholds(table)
	_check(t == Vector2i(35, 97), "the table's thresholds read as 35 and 97: %s" % [t])
	for c in [[34, 1000, B.EASY], [349, 1000, B.EASY], [350, 1000, B.POPULATED], [35, 100, B.POPULATED],
			[969, 1000, B.POPULATED], [96, 100, B.POPULATED], [970, 1000, B.CROWDED], [97, 100, B.CROWDED], [999, 1000, B.CROWDED]]:
		var got := ServerStatus.band_for(c[0], c[1], 1, t.x, t.y)
		_check(got == c[2], "through the table, %d/%d -> %s (got %s)" % [c[0], c[1], B.keys()[c[2]], B.keys()[got]])
	var words := {B.CHECK: "Check", B.EASY: "Easy", B.POPULATED: "Populated", B.CROWDED: "Crowded", B.FULL: "FULL", B.UNREACHABLE: "Closed", B.PENDING: ""}
	for b in words:
		_check(ServerStatus.band_text(b, null) == words[b], "%s reads '%s'" % [B.keys()[b], words[b]])
	var colours := {B.CHECK: Color8(0xC0, 0xBD, 0xFF), B.EASY: Color8(0x6D, 0xFF, 0xEF), B.POPULATED: Color8(0xFF, 0xDA, 0x49),
		B.CROWDED: Color8(0xFF, 0xB5, 0x41), B.FULL: Color8(0xFF, 0x58, 0x58), B.UNREACHABLE: Color8(0xB4, 0xB4, 0xB4)}
	for b in colours:
		_check(ServerStatus.band_color(b).is_equal_approx(colours[b]), "%s in %s" % [B.keys()[b], colours[b].to_html()])

func _wire() -> void:
	# The server's exact payload for 50/100, open (server_test: TestServerStatusEncodeExact).
	var frame := PackedByteArray([6, 0, 0x08, 0x00, 0, 0, 1, 50, 0, 100, 0, 1])
	var r := ServerStatus.parse_frames(frame)
	_check(r.get("status", {}) == {"current": 50, "capacity": 100, "state": 1}, "the server's frame reads as 50/100 open: %s" % [r])
	_check(ServerStatus.parse_frames(frame.slice(0, 8)).is_empty(), "half a frame: keep waiting")
	var theme := PackedByteArray([2, 0, 0x06, 0x00, 0, 0, 0, 0])
	_check(ServerStatus.parse_frames(theme).has("error"), "another frame first is an error")
	_check(GatewayQuery.pick_address(["::1", "127.0.0.1"]) == "127.0.0.1", "a name's IPv4 address first ('localhost' gave ::1 first on the box)")
	_check(GatewayQuery.pick_address(["::1"]) == "::1" and GatewayQuery.pick_address([]) == "", "else its first; none, none")
	var v2 := frame.duplicate()
	v2[6] = 2
	_check(ServerStatus.parse_frames(v2).has("error"), "an unknown version is an error")

# --- Not reachable -------------------------------------------------------------

## A port nobody listens on: found by binding one and closing it.
func _dead_port() -> int:
	var tcp := TCPServer.new()
	for p in range(47900, 48100):
		if tcp.listen(p, "127.0.0.1") == OK:
			tcp.stop()
			return p
	return 1

func _unreachable() -> void:
	var port := _dead_port()
	var w := PackedStringArray()
	var cfg := ClientConfig.from_text("servers:\n  Gone:\n    type: opensro\n    gateway: { address: 127.0.0.1, port: %d }\n" % port, "t", w)
	var list := ServerListWindow.new()
	root.add_child(list)
	list.open(null, null, null, cfg.servers, cfg.servers[0])
	var row := list.row_text(0)
	_check(row[0] == "Gone" and row[1] == "", "before the answer: the name and no status yet")
	var started := Time.get_ticks_msec()
	while list.band_of(0) == ServerStatus.Band.PENDING and Time.get_ticks_msec() - started < 5000:
		await process_frame
	row = list.row_text(0)
	_check(list.band_of(0) == ServerStatus.Band.UNREACHABLE, "a server that does not answer is UNREACHABLE (%s, %d ms)" % [
		ServerStatus.Band.keys()[list.band_of(0)], Time.get_ticks_msec() - started])
	_check(row[0] == "Gone" and row[1] == "Closed" and (row[2] as Color).is_equal_approx(Color8(0xB4, 0xB4, 0xB4)),
		"its row reads 'Gone  Closed' in the list's grey: %s" % [row])
	var shown := ""
	for n in list.find_children("*", "Label", true, false):
		shown += (n as Label).text + "|"
	_check(shown.contains("Gone|Closed|"), "the window's labels show it: %s" % shown.left(80))
	list.close()
	await process_frame

# --- Connect resolves a name as the status does -------------------------------

## Round 679's review: "localhost" showed Check in the list (the status
## prefers IPv4) and then Connect went to ::1 and failed. NetClient now
## resolves a name the same way: a server listening on 127.0.0.1 ONLY is
## reached by the name "localhost".
func _connect_by_name() -> void:
	var server := TCPServer.new()
	var port := 0
	for p in range(48100, 48300):
		if server.listen(p, "127.0.0.1") == OK:
			port = p
			break
	_check(port != 0, "a listener on 127.0.0.1")
	var net: Node = root.get_node_or_null("NetClient")
	_check(net != null, "the NetClient autoload")
	if net == null or port == 0:
		return
	var result := {"ok": false, "failed": false}
	var on_ok := func() -> void: result["ok"] = true
	var on_fail := func() -> void: result["failed"] = true
	net.connect("connected", on_ok)
	net.connect("connection_failed", on_fail)
	net.call("connect_to_server", "localhost", port)
	var started := Time.get_ticks_msec()
	while not result["ok"] and not result["failed"] and Time.get_ticks_msec() - started < 5000:
		await process_frame
	_check(result["ok"], "Connect to 'localhost' reaches a server on 127.0.0.1 only (%s after %d ms)" % [
		"connected" if result["ok"] else ("connection_failed" if result["failed"] else "nothing"), Time.get_ticks_msec() - started])
	net.disconnect("connected", on_ok)
	net.disconnect("connection_failed", on_fail)
	if net.call("is_connected_to_server"):
		net.call("disconnect_from_server")
	server.stop()
