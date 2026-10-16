extends RefCounted

## Test servers for the server-pack suites (round 789, lane U), polled in the
## test's own loop: TestHttp (pack downloads) and FakeGateway (the pack
## question on this project's framing). Test code only.

## A minimal HTTP/1.1 server: one request a connection, then closed. Each
## route is {body, mode, ...}: "range" (206 for a Range), "norange" (always
## 200), "cut" (closes after `cut` body bytes, `cuts` times), "lie" (sends
## 10 bytes more than its body, and says so), "404", "redirect" (302 to
## `location`).
class TestHttp:
	var tcp := TCPServer.new()
	var port := 0
	var conns: Array = []
	var routes := {}
	var requests: Array = []

	func start() -> bool:
		if tcp.listen(0, "127.0.0.1") != OK:
			return false
		port = tcp.get_local_port()
		return true

	func stop() -> void:
		for c in conns:
			(c["peer"] as StreamPeerTCP).disconnect_from_host()
		conns.clear()
		tcp.stop()

	func poll() -> void:
		while tcp.is_connection_available():
			conns.append({"peer": tcp.take_connection(), "buf": PackedByteArray(), "out": PackedByteArray(), "sent": 0, "close_at": -1, "answered": false})
		for c in conns.duplicate():
			var peer := c["peer"] as StreamPeerTCP
			peer.poll()
			if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				conns.erase(c)
				continue
			if not c["answered"]:
				var n := peer.get_available_bytes()
				if n > 0:
					c["buf"].append_array(peer.get_data(n)[1])
				var text: String = (c["buf"] as PackedByteArray).get_string_from_ascii()
				if text.find("\r\n\r\n") < 0:
					continue
				c["answered"] = true
				_answer(c, text)
			var out: PackedByteArray = c["out"]
			var sent: int = c["sent"]
			if sent < out.size():
				var stop_at: int = out.size() if int(c["close_at"]) < 0 else mini(out.size(), int(c["close_at"]))
				var r := peer.put_partial_data(out.slice(sent, mini(stop_at, sent + 16384)))
				if r[0] == OK:
					c["sent"] = sent + int(r[1])
			if int(c["sent"]) >= out.size() or (int(c["close_at"]) >= 0 and int(c["sent"]) >= int(c["close_at"])):
				peer.disconnect_from_host()
				conns.erase(c)

	func _answer(c: Dictionary, text: String) -> void:
		var lines := text.split("\r\n")
		var path := lines[0].split(" ")[1]
		var headers := {}
		for i in range(1, lines.size()):
			var at := lines[i].find(":")
			if at > 0:
				headers[lines[i].substr(0, at).to_lower()] = lines[i].substr(at + 1).strip_edges()
		requests.append([path, headers])
		var route: Dictionary = routes.get(path, {"mode": "404"})
		var body: PackedByteArray = route.get("body", PackedByteArray())
		var mode := str(route["mode"])
		var status := "200 OK"
		var extra := ""
		var send := body
		match mode:
			"404":
				status = "404 Not Found"
				send = "no".to_utf8_buffer()
			"redirect":
				status = "302 Found"
				extra = "Location: %s\r\n" % route["location"]
				send = PackedByteArray()
			"lie", "lie_nolen":
				send = body.duplicate()
				send.append_array("0123456789".to_utf8_buffer())
			"range", "cut":
				if headers.has("range"):
					var from := str(headers["range"]).trim_prefix("bytes=").trim_suffix("-").to_int()
					status = "206 Partial Content"
					extra = "Content-Range: bytes %d-%d/%d\r\n" % [from, body.size() - 1, body.size()]
					send = body.slice(from)
		var head := "HTTP/1.1 %s\r\nContent-Length: %d\r\nConnection: close\r\n%s\r\n" % [status, send.size(), extra]
		if mode == "lie_nolen":
			head = "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n"
		var out := head.to_ascii_buffer()
		out.append_array(send)
		c["out"] = out
		if mode == "cut" and int(route.get("cuts", 0)) > 0:
			route["cuts"] = int(route["cuts"]) - 1
			c["close_at"] = head.length() + int(route["cut"])

## Answers OpClientPacksRequest with `payload` (null: never answers, like a
## server from before round 789), on this project's framing, and counts the
## requests.
class FakeGateway:
	var tcp := TCPServer.new()
	var port := 0
	var conns: Array = []
	var payload: Variant = null
	var asked := 0

	func start() -> bool:
		if tcp.listen(0, "127.0.0.1") != OK:
			return false
		port = tcp.get_local_port()
		return true

	func stop() -> void:
		for c in conns:
			(c["peer"] as StreamPeerTCP).disconnect_from_host()
		conns.clear()
		tcp.stop()

	func poll() -> void:
		while tcp.is_connection_available():
			conns.append({"peer": tcp.take_connection(), "buf": PackedByteArray()})
		for c in conns.duplicate():
			var peer := c["peer"] as StreamPeerTCP
			peer.poll()
			if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				conns.erase(c)
				continue
			var n := peer.get_available_bytes()
			if n > 0:
				c["buf"].append_array(peer.get_data(n)[1])
			var buf: PackedByteArray = c["buf"]
			if buf.size() >= Packet.HEADER_SIZE and buf.decode_u16(2) == PackManifest.OP_REQUEST:
				asked += 1
				c["buf"] = PackedByteArray()
				if payload != null:
					peer.put_data(Packet.new(PackManifest.OP_MANIFEST, payload).encode())
					peer.disconnect_from_host()
					conns.erase(c)
