extends SceneTree

## Round 795: the COS messages as the client reads them, from the bytes
## server/internal/cos encodes (cos.AppendSpawnRecord, AppendData,
## AppendItemTail, ExpUpdate, RideAck): a growth pet's 0x3015, a ride's group
## record walking to a point, an ability pet's record, a growth pet's 0x30C8,
## the two pet scrolls' item tails, a negative EXP update and a mount. And
## CosTable's row parse.
## `godot4 --headless --path client --script res://scripts/net/cos_net_test.gd`

const GROWTH := "da1700000200007ea8610000c9420000284200106144004000000000400100000000004842000096420000c8420000030052657804004b696c6f04000100000001"
const RIDE := "125b00000200007ea8610000c942000028420010614400400101a86196002a0084030100000000004842000096420000c8420000"
const ABILITY := "812800000200007ea8610000c9420000284200106144004000000000400100000000004842000096420000c8420000030052657804004b696c6f0401000000"
const DATA := "0200007eda1700006801000000000000141a99be1c000000071c2501000000030052657800010000000f"
const TAIL_GROWTH := "02da170000030052657800"
const TAIL_ABILITY := "03812800000000100e000000"
const EXP := "0200007e03ceffffffffffffff9e010000"
const RIDE_ACK := "0101000000010100007e"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _kind(ref: int) -> int:
	return {6106: 3, 10369: 4, 23314: 1}.get(ref, 0)

func _init() -> void:
	var g := CosSpawnNet.decode_single_spawn(GROWTH.hex_decode(), 3)
	_check(g != null and g.uid == 0x7e000002 and g.ref_id == 6106 and g.name == "Rex" and g.owner_name == "Kilo" \
		and g.owner_job == 4 and g.owner_pvp == 0 and g.owner_uid == 1 and g.spawn_type == 1 and g.run == 75.0,
		"a growth pet's 0x3015: its name, its owner's name, job, PvP and uid, the spawn type")
	var r := NpcSpawnNet.Reader.new(RIDE.hex_decode())
	var ride := CosSpawnNet.read_record(r, 1)
	_check(ride != null and r.pos == RIDE.length() / 2 and ride.owner_uid == 0 and ride.has_dest \
		and ride.dest_local == Vector3i(150, 42, 900) and ride.name == "",
		"a ride's record ends at its flags and carries its destination")
	var a := NpcSpawnNet.Reader.new(ABILITY.hex_decode())
	var ab := CosSpawnNet.read_record(a, 4)
	_check(ab != null and a.pos == ABILITY.length() / 2 and ab.owner_uid == 1 and ab.name == "Rex",
		"an ability pet's record has no PvP byte")
	var d := CosNet.decode_data(DATA.hex_decode(), Callable(self, "_kind"))
	_check(d.error == "" and d.kind == 3 and d.hp == 360 and d.exp == 123456789012 and d.level == 7 and d.hgp == 9500 \
		and d.pet_option == 1 and d.name == "Rex" and d.inv_size == 0 and d.owner_uid == 1 and d.item_slot == 2,
		"a growth pet's 0x30C8: EXP, level, HGP, its option and name, its item's bag slot")
	ItemInstance.cos_kind_of = Callable(self, "_kind")
	ItemInstance.types_of = func(ref: int) -> PackedInt32Array:
		return PackedInt32Array([3, 2, 1, 1]) if ref == 7488 else PackedInt32Array([3, 2, 1, 2])
	var rec := PackedByteArray([0, 0, 0, 0, 0x40, 0x1d, 0, 0])
	rec.append_array(TAIL_GROWTH.hex_decode())
	var gi := ItemInstance.read_record(rec, 0)
	_check(gi[0] != null and gi[1] == rec.size() and (gi[0] as ItemInstance).cos_state == 2 \
		and (gi[0] as ItemInstance).cos_name == "Rex" and not (gi[0] as ItemInstance).is_equipment,
		"a growth pet's scroll: summoned, its pet named")
	var rec2 := PackedByteArray([0, 0, 0, 0, 0x7d, 0x28, 0, 0])
	rec2.append_array(TAIL_ABILITY.hex_decode())
	var ai := ItemInstance.read_record(rec2, 0)
	_check(ai[0] != null and ai[1] == rec2.size() and (ai[0] as ItemInstance).cos_rent_secs == 3600,
		"an ability pet's scroll: its rent's seconds")
	ItemInstance.types_of = Callable()
	ItemInstance.cos_kind_of = Callable()
	var u := CosNet.decode_update(EXP.hex_decode())
	_check(u.type == CosNet.UPDATE_EXP and u.exp_delta == -50 and u.source == 414, "a loss of EXP reads negative")
	var ack := CosNet.decode_ride_ack(RIDE_ACK.hex_decode())
	_check(bool(ack["ok"]) and int(ack["rider"]) == 1 and bool(ack["mounted"]) and int(ack["cos"]) == 0x7e000001,
		"0xB0CB: the rider mounted the COS")
	var t := CosTable.new()
	var cols := PackedStringArray()
	cols.resize(105)
	for i in cols.size():
		cols[i] = "0"
	cols[1] = "6106"
	cols[2] = "COS_P_WOLF_001"
	cols[4] = "COS_P_WOLF_001"
	cols[5] = "SN_COS_P_WOLF_01"
	cols[6] = "COS_P_WOLF_002"
	cols[9] = "1"
	cols[10] = "2"
	cols[11] = "3"
	cols[12] = "3"
	cols[46] = "50"
	cols[47] = "75"
	cols[52] = "cos\\p_wolf_01.bsr"
	cols[54] = "cos\\cos_p_wolf_01.ddj"
	cols[57] = "1"
	cols[59] = "360"
	# The parts are UTF-16LE with a BOM, as the archive ships them.
	var bytes := PackedByteArray([0xFF, 0xFE])
	bytes.append_array(("\t".join(cols) + "\n").to_utf16_buffer())
	t.parse(bytes)
	var w := t.row(6106)
	_check(w != null and w.type4 == 3 and w.run == 75.0 and w.next_code == "COS_P_WOLF_002" and w.max_hp == 360 \
		and w.model == "cos\\p_wolf_01.bsr" and w.icon == "icon\\cos\\cos_p_wolf_01.ddj" and t.kind_of(6106) == 3,
		"CosTable reads a growth pet's row")
	print("%d failure(s)" % _failures)
	quit(1 if _failures > 0 else 0)
