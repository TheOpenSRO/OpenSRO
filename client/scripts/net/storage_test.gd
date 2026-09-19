extends SceneTree

## StorageNet: the warehouse list is the bag's list plus a trailing u16
## capacity (session/storage.go's StorageListResult). The client pages the
## authored 30-slot lattice from it, so reading it -- and reading 0 from an
## older server that sends none -- is what these check.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _list(error: String, slots: Array, durabilities: Array) -> PackedByteArray:
	var out := PackedByteArray()
	var error_bytes := error.to_utf8_buffer()
	var head := PackedByteArray()
	head.resize(2)
	head.encode_u16(0, error_bytes.size())
	out.append_array(head)
	out.append_array(error_bytes)
	var count := PackedByteArray()
	count.resize(2)
	count.encode_u16(0, slots.size())
	out.append_array(count)
	for s in slots:
		var buf := PackedByteArray()
		buf.resize(16)
		buf.encode_u32(0, s[0])
		buf.encode_s64(4, s[1])
		buf.encode_u32(12, s[2])
		out.append_array(buf)
	var dcount := PackedByteArray()
	dcount.resize(2)
	dcount.encode_u16(0, durabilities.size())
	out.append_array(dcount)
	for d in durabilities:
		var buf := PackedByteArray()
		buf.resize(12)
		buf.encode_u32(0, d[0])
		buf.encode_s32(4, d[1])
		buf.encode_s32(8, d[2])
		out.append_array(buf)
	return out

func _with_capacity(payload: PackedByteArray, capacity: int) -> PackedByteArray:
	var tail := PackedByteArray()
	tail.resize(2)
	tail.encode_u16(0, capacity)
	return payload + tail

func _test_capacity_after_empty_block() -> void:
	var r := StorageNet.decode_list_result(_with_capacity(_list("", [[2, 3645, 1], [31, 10, 7]], []), 50))
	_check(r.error == "" and r.slots.size() == 2, "two slots decode")
	_check(r.capacity == 50, "capacity 50 read after an empty durability block (got %d)" % r.capacity)
	_check(r.slots[1].slot_index == 31, "a slot on page 2 (index 31) survives")

func _test_capacity_after_durabilities() -> void:
	var r := StorageNet.decode_list_result(_with_capacity(_list("", [[2, 3645, 1]], [[2, 40, 62]]), 112))
	_check(r.durabilities.size() == 1 and r.durabilities[0].maximum == 62, "durability entry read")
	_check(r.capacity == 112, "capacity 112 read after one durability entry (got %d)" % r.capacity)

func _test_old_server_sends_no_capacity() -> void:
	var r := StorageNet.decode_list_result(_list("", [[0, 1, 1]], []))
	_check(r.error == "" and r.slots.size() == 1, "old payload still lists")
	_check(r.capacity == 0, "capacity stays 0 when not sent (got %d)" % r.capacity)

func _test_error_carries_no_capacity() -> void:
	var r := StorageNet.decode_list_result(_with_capacity(_list("not authenticated", [], []), 50))
	_check(r.error == "not authenticated", "error round-trips")
	_check(r.capacity == 0, "an error reply reports no capacity")

func _init() -> void:
	_test_capacity_after_empty_block()
	_test_capacity_after_durabilities()
	_test_old_server_sends_no_capacity()
	_test_error_carries_no_capacity()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
