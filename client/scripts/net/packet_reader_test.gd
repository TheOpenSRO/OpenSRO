extends SceneTree

## Exercises PacketReader against a real loopback TCP connection, since the
## whole point of this class is correct behavior when a frame arrives in
## pieces across multiple poll() calls -- something encode/decode-only unit
## tests (see packet_test.gd) can't exercise. Run headless:
## `godot4 --headless --path client --script res://scripts/net/packet_reader_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## Sets up a real loopback TCP pair: a TCPServer accepting on 127.0.0.1,
## and a client StreamPeerTCP connected to it. Returns [server_side_peer,
## client_side_peer] once both are connected, or null on failure.
func _make_loopback_pair() -> Array:
	var server := TCPServer.new()
	var err := server.listen(0, "127.0.0.1")
	if err != OK:
		push_error("PacketReaderTest: TCPServer.listen failed: %s" % err)
		return []
	var port := server.get_local_port()

	var client := StreamPeerTCP.new()
	client.connect_to_host("127.0.0.1", port)

	var server_peer: StreamPeerTCP = null
	for i in range(200):
		client.poll()
		if server.is_connection_available():
			server_peer = server.take_connection()
		if server_peer != null and client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			break
		OS.delay_msec(5)

	server.stop()
	if server_peer == null or client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		push_error("PacketReaderTest: loopback pair failed to connect")
		return []
	return [server_peer, client]

func _test_split_frame_across_polls() -> void:
	var pair := _make_loopback_pair()
	if pair.is_empty():
		_check(false, "loopback pair connected")
		return

	var server_peer: StreamPeerTCP = pair[0]
	var client_peer: StreamPeerTCP = pair[1]
	var reader := PacketReader.new()

	var full := Packet.new(0x1234, "hello".to_utf8_buffer()).encode()
	var header := full.slice(0, Packet.HEADER_SIZE)
	var payload := full.slice(Packet.HEADER_SIZE, full.size())

	# Send only the header first.
	server_peer.put_data(header)
	# Give the bytes a moment to actually arrive over the loopback socket.
	for i in range(50):
		client_peer.poll()
		if client_peer.get_available_bytes() >= header.size():
			break
		OS.delay_msec(2)

	var p := reader.poll(client_peer)
	_check(p == null, "poll() returns null with only the header buffered (not a full frame)")

	# Now send the rest of the payload.
	server_peer.put_data(payload)
	for i in range(50):
		client_peer.poll()
		if client_peer.get_available_bytes() >= payload.size():
			break
		OS.delay_msec(2)

	p = reader.poll(client_peer)
	_check(p != null, "poll() returns the completed frame once the payload arrives")
	if p != null:
		_check(p.opcode == 0x1234, "opcode round-trips")
		_check(p.data.get_string_from_utf8() == "hello", "payload round-trips")

	client_peer.disconnect_from_host()
	server_peer.disconnect_from_host()

func _test_two_frames_in_one_poll() -> void:
	var pair := _make_loopback_pair()
	if pair.is_empty():
		_check(false, "loopback pair connected")
		return

	var server_peer: StreamPeerTCP = pair[0]
	var client_peer: StreamPeerTCP = pair[1]
	var reader := PacketReader.new()

	var first := Packet.new(0x0001, "a".to_utf8_buffer()).encode()
	var second := Packet.new(0x0002, "bb".to_utf8_buffer()).encode()
	server_peer.put_data(first)
	server_peer.put_data(second)

	var total_size := first.size() + second.size()
	for i in range(50):
		client_peer.poll()
		if client_peer.get_available_bytes() >= total_size:
			break
		OS.delay_msec(2)

	var p1 := reader.poll(client_peer)
	var p2 := reader.poll(client_peer)
	_check(p1 != null and p1.opcode == 0x0001, "first frame decodes correctly out of a combined read")
	_check(p2 != null and p2.opcode == 0x0002, "second frame decodes correctly out of a combined read")

	client_peer.disconnect_from_host()
	server_peer.disconnect_from_host()

## Round 762: drain() empties the socket into the reader's buffer without
## cutting frames; the frames come out of the buffer afterwards, in order,
## with the socket already empty.
func _test_drain_then_frames() -> void:
	var pair := _make_loopback_pair()
	if pair.is_empty():
		_check(false, "loopback pair connected")
		return
	var server_peer: StreamPeerTCP = pair[0]
	var client_peer: StreamPeerTCP = pair[1]
	var reader := PacketReader.new()
	var total := 0
	for i in range(40):
		var f := Packet.new(0x0100 + i, PackedByteArray([i, i, i])).encode()
		total += f.size()
		server_peer.put_data(f)
	for i in range(50):
		client_peer.poll()
		if client_peer.get_available_bytes() >= total:
			break
		OS.delay_msec(2)
	_check(reader.drain(client_peer) >= 1, "drain reads what the socket holds")
	client_peer.poll()
	_check(client_peer.get_available_bytes() == 0, "the socket is empty after drain")
	var ok := true
	for i in range(40):
		var p := reader.poll(client_peer)
		if p == null or p.opcode != 0x0100 + i:
			ok = false
			break
	_check(ok, "the 40 frames come out of the buffer in order")
	client_peer.disconnect_from_host()
	server_peer.disconnect_from_host()

func _init() -> void:
	_test_split_frame_across_polls()
	_test_two_frames_in_one_poll()
	_test_drain_then_frames()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
