extends SceneTree

## Round 663: PacketReader must read whatever has arrived into its own buffer
## on every poll, never wait for a whole payload to sit in the peer's buffer.
## Round 662's live check (docs/WORLD_ISSUES.md round 662 §4) measured the old
## reader wedged for good: the kernel's receive buffer was full of part-read
## segments holding 31,250 bytes while the reader waited for a 32,735-byte
## list page. And over TLS a peer only ever reports one record (at most 16,384
## bytes) as available.
##
## The frames are fed through a fake peer (a StreamPeerBuffer that is handed
## its bytes a fragment at a time by poll(), and holds at most `cap` unread
## bytes, as a kernel buffer does) in odd fragment sizes; every pattern must
## decode to exactly the frames that were sent, in order. Then a real TLS
## loopback carries a 32,735-byte page. Only poll(), Packet and the reader's
## _buf (read with get(), so an older reader without it fails that one check
## instead of the file) are used, so the file runs against the old reader too
## (the negative).
## Run headless: `godot4 --headless --path client --script res://scripts/net/packet_reader_fragments_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A peer whose bytes arrive a fragment per poll(), holding at most cap
## unread bytes (the rest waits, as behind a shut TCP window).
class FakePeer extends StreamPeerBuffer:
	var pending := PackedByteArray()
	var frag := 1
	var cap := 1 << 30

	func poll() -> int:
		var room := cap - get_available_bytes()
		var n := mini(mini(frag, pending.size()), room)
		if n <= 0:
			return OK
		var at := get_position()
		seek(get_size())
		put_data(pending.slice(0, n))
		seek(at)
		pending = pending.slice(n)
		return OK

## The frames every pattern carries: small ones, an empty one, a full-size
## list page (32,735 bytes, the one round 662 wedged on), and the small ones
## after it that the wedged client never saw.
func _frames() -> Array:
	var out: Array = []
	out.append(Packet.new(0x0027, "zone".to_utf8_buffer()))
	out.append(Packet.new(0x007f, PackedByteArray()))
	for i in range(5):
		var d := PackedByteArray()
		d.resize(29)
		for j in range(29):
			d[j] = (i * 31 + j) & 0xff
		out.append(Packet.new(0x007c, d))
	var page := PackedByteArray()
	page.resize(32735)
	for j in range(page.size()):
		page[j] = (j * 7 + 3) & 0xff
	out.append(Packet.new(0x0066, page))
	out.append(Packet.new(0x00f2, "healed".to_utf8_buffer()))
	var max_frame := PackedByteArray()
	max_frame.resize(Packet.MAX_PAYLOAD)
	max_frame.fill(0x5a)
	out.append(Packet.new(0x0066, max_frame))
	out.append(Packet.new(0x0110, "Tiger Girl".to_utf8_buffer()))
	return out

## Feeds frames through a FakePeer (fragment size frag, receive buffer cap)
## and returns what the reader decoded. It stops once every frame is in, or
## once 200 polls in a row move no byte and decode nothing (wedged).
func _run(frames: Array, frag: int, cap: int) -> Array:
	var peer := FakePeer.new()
	for f in frames:
		peer.pending.append_array((f as Packet).encode())
	peer.frag = frag
	peer.cap = cap
	var reader := PacketReader.new()
	var got: Array = []
	var still := 0
	while got.size() < frames.size() and still < 200:
		var before := Vector2i(peer.pending.size(), peer.get_available_bytes())
		var p := reader.poll(peer)
		if p != null:
			got.append(p)
			still = 0
		elif Vector2i(peer.pending.size(), peer.get_available_bytes()) != before:
			still = 0
		else:
			still += 1
	return got

## Same frames, same order, byte for byte.
func _same(got: Array, want: Array) -> String:
	if got.size() != want.size():
		return "%d of %d frames decoded" % [got.size(), want.size()]
	for i in range(want.size()):
		var g: Packet = got[i]
		var w: Packet = want[i]
		if g.opcode != w.opcode:
			return "frame %d is opcode 0x%04x, want 0x%04x" % [i, g.opcode, w.opcode]
		if g.data != w.data:
			return "frame %d (0x%04x) payload differs: %d bytes, want %d" % [i, w.opcode, g.data.size(), w.data.size()]
	return ""

func _test_fragments() -> void:
	var frames := _frames()
	var patterns := [
		["one byte at a time", 1, 1 << 30],
		["splits across headers (3-byte fragments)", 3, 1 << 30],
		["7-byte fragments", 7, 1 << 30],
		["several frames in one chunk (all at once)", 1 << 20, 1 << 30],
		["52 KB pieces, as loopback carried round 662's big writes", 53248, 1 << 30],
		["16,384-byte pieces (one TLS record at a time)", 16384, 1 << 30],
	]
	for pat in patterns:
		var why := _same(_run(frames, pat[1], pat[2]), frames)
		_check(why == "", "%s: every frame decodes identically%s" % [pat[0], "" if why == "" else " -- " + why])

## Round 662's wedge: a receive buffer that holds at most 31,250 unread bytes
## (what ss measured) never has a 32,735-byte page in it at once. A reader
## that waits for the whole payload there waits for ever; one that takes what
## is there gets the page and every frame after it.
func _test_page_through_a_full_receive_buffer() -> void:
	var frames := _frames()
	var got := _run(frames, 53248, 31250)
	var why := _same(got, frames)
	_check(why == "", "a 32,735-byte page through a receive buffer holding 31,250 bytes decodes, and every frame after it%s" % ("" if why == "" else " -- " + why))

## The reader's own buffer stays bounded: it reads only while it lacks a
## whole frame, and drops what it consumed before each read, so _buf never
## reaches one frame plus one read (PacketReader.MAX_BUFFER). Six full-size
## frames all waiting at once put the most pressure on it.
func _test_buffer_is_bounded() -> void:
	var peer := FakePeer.new()
	for i in range(6):
		var d := PackedByteArray()
		d.resize(Packet.MAX_PAYLOAD)
		d.fill(i)
		peer.pending.append_array(Packet.new(0x0066, d).encode())
	peer.frag = 1 << 20
	var reader := PacketReader.new()
	var most := 0
	var frames := 0
	for i in range(40):
		if reader.poll(peer) != null:
			frames += 1
		var buf = reader.get("_buf")
		most = maxi(most, (buf as PackedByteArray).size() if buf is PackedByteArray else 1 << 30)
	var bound := Packet.HEADER_SIZE + Packet.MAX_PAYLOAD + 65536
	_check(frames == 6 and most < bound, "the reader's buffer stays under one frame plus one 64 KB read (%d frames, largest buffer %d bytes, bound %d)" % [frames, most, bound])

## It reads only while it lacks a whole frame: 20 small frames (under one
## read) followed by 200 KB more are all waiting; the first poll reads once,
## and the next 19 polls are served from the buffer without reading again.
func _test_reads_only_when_it_lacks_a_frame() -> void:
	var peer := FakePeer.new()
	for i in range(20):
		peer.pending.append_array(Packet.new(0x007c, "leg %02d".to_utf8_buffer()).encode())
	var tail := PackedByteArray()
	tail.resize(Packet.MAX_PAYLOAD)
	for i in range(6):
		peer.pending.append_array(Packet.new(0x0066, tail).encode())
	peer.frag = 1 << 20
	var reader := PacketReader.new()
	var first := reader.poll(peer)
	var waiting := peer.get_available_bytes()
	var extra_reads := 0
	for i in range(19):
		var p := reader.poll(peer)
		if peer.get_available_bytes() != waiting:
			extra_reads += 1
			waiting = peer.get_available_bytes()
		if p == null or p.opcode != 0x007c:
			extra_reads += 100
	_check(first != null and extra_reads == 0, "with 20 whole frames buffered, the next 19 polls read nothing more from the peer (%d reads)" % extra_reads)

## A real TLS loopback (a self-signed certificate made here): a 32,735-byte
## page and a small frame after it. StreamPeerTLS reports only the current
## record as available (at most 16,384 bytes), so the page is never "all
## available" at once.
func _test_tls_page() -> void:
	var crypto := Crypto.new()
	var key := crypto.generate_rsa(2048)
	var cert := crypto.generate_self_signed_certificate(key, "CN=127.0.0.1,O=srrevamp,C=US")
	var server := TCPServer.new()
	if server.listen(0, "127.0.0.1") != OK:
		_check(false, "TLS: loopback listen")
		return
	var tcp_client := StreamPeerTCP.new()
	tcp_client.connect_to_host("127.0.0.1", server.get_local_port())
	var tcp_server: StreamPeerTCP = null
	for i in range(400):
		tcp_client.poll()
		if tcp_server == null and server.is_connection_available():
			tcp_server = server.take_connection()
		if tcp_server != null and tcp_client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			break
		OS.delay_msec(5)
	server.stop()
	if tcp_server == null:
		_check(false, "TLS: loopback pair connected")
		return
	var tls_server := StreamPeerTLS.new()
	var tls_client := StreamPeerTLS.new()
	var serr := tls_server.accept_stream(tcp_server, TLSOptions.server(key, cert))
	# client_unsafe as NetClient uses it, but trusting the test's own
	# certificate: with no chain Godot falls back to its default CA bundle,
	# which a --script run has not loaded ("SSL module failed to initialize!",
	# tls_context_mbedtls.cpp init_client).
	var cerr := tls_client.connect_to_stream(tcp_client, "127.0.0.1", TLSOptions.client_unsafe(cert))
	if serr != OK or cerr != OK:
		_check(false, "TLS: handshake started (server %s, client %s)" % [serr, cerr])
		return
	for i in range(1000):
		tls_server.poll()
		tls_client.poll()
		if tls_server.get_status() == StreamPeerTLS.STATUS_CONNECTED and tls_client.get_status() == StreamPeerTLS.STATUS_CONNECTED:
			break
		OS.delay_msec(2)
	if tls_client.get_status() != StreamPeerTLS.STATUS_CONNECTED:
		_check(false, "TLS: handshake finished")
		return
	var page := PackedByteArray()
	page.resize(32735)
	for j in range(page.size()):
		page[j] = (j * 13 + 1) & 0xff
	var frames := [Packet.new(0x0066, page), Packet.new(0x00f2, "after".to_utf8_buffer())]
	for f in frames:
		tls_server.put_data((f as Packet).encode())
	# Wait, without touching the reader, until every encrypted byte is in the
	# client's socket: at least the two frames plus a record header each.
	var want_bytes := 32741 + 11 + 3 * 5
	var seen := -1
	var steady := 0
	for i in range(500):
		tls_server.poll()
		tcp_client.poll()
		var n := tcp_client.get_available_bytes()
		steady = steady + 1 if n == seen else 0
		seen = n
		if n >= want_bytes and steady >= 10:
			break
		OS.delay_msec(2)
	var reader := PacketReader.new()
	var got: Array = []
	var polls_for_page := 0
	var end := Time.get_ticks_msec() + 3000
	while got.size() < frames.size() and Time.get_ticks_msec() < end:
		var p := reader.poll(tls_client)
		if got.is_empty():
			polls_for_page += 1
		if p != null:
			got.append(p)
		else:
			OS.delay_msec(1)
	var why := _same(got, frames)
	_check(why == "", "TLS: a 32,735-byte page and the frame after it decode within 3 s%s" % ("" if why == "" else " -- " + why))
	# NetClient drains poll() until the first null, once a game frame. The
	# page spans more than one TLS record; with them all arrived it must come
	# out of the first poll -- one game frame -- not one record per game frame
	# (a reader that reads only the current record takes 2 here).
	_check(polls_for_page == 1, "TLS: with its records all arrived, the page comes out of the first poll (took %d; %d bytes were waiting)" % [polls_for_page, seen])
	# A clean close (close_notify) ends the stream without an error line.
	# The reader is polled as NetClient polls it -- only while the peer says
	# it is connected -- and the runner checks that nothing between the two
	# marker lines is an ERROR.
	print("TLS close begins")
	tls_server.disconnect_from_stream()
	var after_close: Packet = null
	for i in range(20):
		if tls_client.get_status() == StreamPeerTLS.STATUS_CONNECTED:
			var p := reader.poll(tls_client)
			if p != null:
				after_close = p
		OS.delay_msec(2)
	_check(after_close == null and tls_client.get_status() != StreamPeerTLS.STATUS_CONNECTED,
		"TLS: after the server's close_notify the reader returns nothing and the peer is closed")
	print("TLS close polled")
	tls_client.disconnect_from_stream()

## Size's top bit is a reserved flag (Packet.MAX_PAYLOAD, PACKET_FORMAT.md):
## the reader masks it off, as it always has. A frame whose Size field is
## 0x8000 | 5 carries 5 bytes, and the frame after it is found.
func _test_size_flag_bit_is_masked() -> void:
	var raw := PackedByteArray()
	raw.resize(6)
	raw.encode_u16(0, 0x8000 | 5)
	raw.encode_u16(2, 0x1234)
	raw.append_array("hello".to_utf8_buffer())
	var after := Packet.new(0x00f2, "after".to_utf8_buffer())
	raw.append_array(after.encode())
	var peer := FakePeer.new()
	peer.pending = raw
	peer.frag = 1 << 20
	var reader := PacketReader.new()
	var got: Array = []
	for i in range(10):
		var p := reader.poll(peer)
		if p != null:
			got.append(p)
	var why := _same(got, [Packet.new(0x1234, "hello".to_utf8_buffer()), after])
	_check(why == "", "a Size field with its top bit set carries its low 15 bits of payload%s" % ("" if why == "" else " -- " + why))

func _init() -> void:
	_test_fragments()
	_test_page_through_a_full_receive_buffer()
	_test_buffer_is_bounded()
	_test_reads_only_when_it_lacks_a_frame()
	_test_size_flag_bit_is_masked()
	_test_tls_page()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
