extends SceneTree

## Round 681's review: the costs a hostile or busy legacy gateway can put on
## a frame of the login screen, measured.
##   client/tools/remote_godot.sh script res://tools/bench_retail_gateway.gd
## Prints BENCH lines: Blowfish.new (the key schedule), decode_name of a
## 32 KB name (valid ASCII, invalid UTF-8), and RetailGatewayClient.feed() of
## a 0xA101 carrying a 32 KB name gathered from 0x600D parts.

func _ms(t0: int) -> float:
	return (Time.get_ticks_usec() - t0) / 1000.0

func _initialize() -> void:
	var key := PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8])
	var t0 := Time.get_ticks_usec()
	for _i in range(20):
		Blowfish.new(key)
	print("BENCH Blowfish.new: %.2f ms each (20 runs)" % (_ms(t0) / 20.0))
	for kind in ["ascii", "invalid_utf8"]:
		var b := PackedByteArray()
		b.resize(32000)
		b.fill(0x41 if kind == "ascii" else 0xE9)
		t0 = Time.get_ticks_usec()
		var s := RetailGatewayClient.decode_name(b)
		print("BENCH decode_name 32000 bytes %s: %.2f ms -> %d chars" % [kind, _ms(t0), s.length()])
	# A 0xA101 with one shard whose name is 32000 bytes of 0xE9, in 0x600D parts.
	var list := PackedByteArray([0, 1, 7, 0])
	var name_len := PackedByteArray([0, 0])
	name_len.encode_u16(0, 32000)
	list.append_array(name_len)
	var name := PackedByteArray()
	name.resize(32000)
	name.fill(0xE9)
	list.append_array(name)
	list.append_array(PackedByteArray([1, 0, 10, 0, 1, 1, 0]))
	var parts: Array = []
	var off := 0
	while off < list.size():
		var end := mini(off + 4000, list.size())
		parts.append(PackedByteArray([0]) + list.slice(off, end))
		off = end
	var hdr := PackedByteArray([1, 0, 0, 0x01, 0xA1])
	hdr.encode_u16(1, parts.size())
	var sec := RetailSecurity.new()
	var buf := PackedByteArray()
	for p in [hdr] + parts:
		var f := PackedByteArray([0, 0, 0x0D, 0x60, 0, 0])
		f.encode_u16(0, (p as PackedByteArray).size())
		f.append_array(p)
		buf.append_array(f)
	var c := RetailGatewayClient.new(22, 1000, 1)
	c.state = RetailGatewayClient.St.LIST
	c.sec = sec
	t0 = Time.get_ticks_usec()
	var r := c.feed(buf)
	print("BENCH feed 0xA101 with a 32000-byte invalid-UTF-8 name in %d parts: %.2f ms, done %s, error '%s', name %d chars" % [
		parts.size(), _ms(t0), c.done(), r["error"], (c.shards[0]["name"] as String).length() if c.done() else -1])
	quit()
